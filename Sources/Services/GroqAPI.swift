import Foundation

enum GroqAPI {
    struct PreparedUpload {
        let request: URLRequest
        let uploadFileURL: URL
        let audioFileBytes: Int
        let uploadFileBytes: Int
    }

    final class TranscriptionRequest {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false
        private var uploadFileURL: URL?
        private var pendingRetryWork: DispatchWorkItem?

        func setTask(_ task: URLSessionTask) {
            lock.lock()
            defer { lock.unlock() }

            self.task = task
            if cancelled {
                task.cancel()
            }
        }

        func setUploadFileURL(_ uploadFileURL: URL) {
            var shouldDelete = false

            lock.lock()
            if cancelled {
                shouldDelete = true
            } else {
                self.uploadFileURL = uploadFileURL
            }
            lock.unlock()

            if shouldDelete {
                try? FileManager.default.removeItem(at: uploadFileURL)
            }
        }

        func scheduleRetry(after delay: TimeInterval, _ retry: @escaping () -> Void) {
            let work = DispatchWorkItem { retry() }

            lock.lock()
            if cancelled {
                lock.unlock()
                return
            }
            pendingRetryWork?.cancel()
            pendingRetryWork = work
            lock.unlock()

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
        }

        func clearPendingRetry(_ work: DispatchWorkItem? = nil) {
            lock.lock()
            if work == nil || pendingRetryWork === work {
                pendingRetryWork = nil
            }
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            let pendingRetryWork = self.pendingRetryWork
            self.pendingRetryWork = nil
            let uploadFileURL = self.uploadFileURL
            self.uploadFileURL = nil
            lock.unlock()

            pendingRetryWork?.cancel()
            task?.cancel()
            if let uploadFileURL {
                try? FileManager.default.removeItem(at: uploadFileURL)
            }
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func finish() {
            lock.lock()
            let uploadFileURL = self.uploadFileURL
            self.uploadFileURL = nil
            lock.unlock()

            if let uploadFileURL {
                try? FileManager.default.removeItem(at: uploadFileURL)
            }
        }
    }

    private static let baseURL = AppConstants.URLs.groqTranscriptions
    private static let maxFileSize = 25 * 1024 * 1024
    private static let requestTimeout: TimeInterval = 12
    private static let resourceTimeout: TimeInterval = 30
    private static let latencyLogThresholdMs: Double = 2500
    private static let maxTranscriptionAttempts = 3
    private static let uploadChunkSize = 64 * 1024
    private static let transcriptionSessionProfile = "fresh_ephemeral"

    private static let warmupSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func warmConnection() {
        var request = URLRequest(url: AppConstants.URLs.groqAPIHost)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        warmupSession.dataTask(with: request) { _, _, _ in }.resume()
    }

    static func makeTranscriptionSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        return config
    }

    static func shouldRetryTransportError(_ nsError: NSError) -> Bool {
        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut, .networkConnectionLost, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    static func transcriptionError(for nsError: NSError) -> TranscriptionError {
        guard nsError.domain == NSURLErrorDomain else {
            return .other("Network error")
        }

        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut:
            return .timedOut
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .secureConnectionFailed:
            return .networkUnavailable
        default:
            return .other("Network error")
        }
    }

    static func transportErrorName(for nsError: NSError) -> String {
        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut: return "timed_out"
        case .networkConnectionLost: return "network_connection_lost"
        case .secureConnectionFailed: return "secure_connection_failed"
        case .notConnectedToInternet: return "not_connected_to_internet"
        case .cannotConnectToHost: return "cannot_connect_to_host"
        case .cannotFindHost: return "cannot_find_host"
        case .dnsLookupFailed: return "dns_lookup_failed"
        default: return "code_\(nsError.code)"
        }
    }

    static func transcribe(
        fileURL: URL,
        config: Config,
        completion: @escaping (Result<String, TranscriptionError>) -> Void
    ) -> TranscriptionRequest {
        let requestHandle = TranscriptionRequest()
        let startedAt = CFAbsoluteTimeGetCurrent()

        let fileSize: Int
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            completion(.failure(.other("Can't read audio file")))
            return requestHandle
        }

        let readMs = elapsedMs(since: startedAt)

        guard fileSize <= maxFileSize else {
            completion(.failure(.tooLarge))
            return requestHandle
        }

        let requestBuildStartedAt = CFAbsoluteTimeGetCurrent()
        let preparedUpload: PreparedUpload
        do {
            preparedUpload = try buildRequest(fileURL: fileURL, config: config)
        } catch {
            requestHandle.finish()
            completion(.failure(.other("Upload preparation failed")))
            return requestHandle
        }

        requestHandle.setUploadFileURL(preparedUpload.uploadFileURL)
        let buildMs = elapsedMs(since: requestBuildStartedAt)

        send(
            preparedUpload.request,
            uploadFileURL: preparedUpload.uploadFileURL,
            audioFileBytes: preparedUpload.audioFileBytes,
            uploadFileBytes: preparedUpload.uploadFileBytes,
            requestHandle: requestHandle,
            attempt: 1,
            startedAt: startedAt,
            readMs: readMs,
            buildMs: buildMs,
            completion: completion
        )
        return requestHandle
    }

    static func buildRequest(fileURL: URL, config: Config) throws -> PreparedUpload {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let ext = fileURL.pathExtension.lowercased()
        let mime = ext == "flac" ? "audio/flac" : "audio/wav"
        let uploadFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("groqdictate-upload-\(UUID().uuidString).multipart", isDirectory: false)
        var completed = false

        FileManager.default.createFile(atPath: uploadFileURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: uploadFileURL)
        defer {
            try? outputHandle.close()
            if !completed {
                try? FileManager.default.removeItem(at: uploadFileURL)
            }
        }

        func field(_ name: String, _ value: String) throws {
            try outputHandle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            try outputHandle.write(contentsOf: Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            try outputHandle.write(contentsOf: Data("\(value)\r\n".utf8))
        }

        try field("model", config.model)
        try field("language", "en")
        try field("response_format", "verbose_json")
        try field("temperature", "0")

        try outputHandle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
        try outputHandle.write(
            contentsOf: Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(ext)\"\r\n".utf8)
        )
        try outputHandle.write(contentsOf: Data("Content-Type: \(mime)\r\n\r\n".utf8))

        let inputHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? inputHandle.close() }

        while true {
            let chunk = try inputHandle.read(upToCount: uploadChunkSize) ?? Data()
            if chunk.isEmpty { break }
            try outputHandle.write(contentsOf: chunk)
        }

        try outputHandle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))

        let uploadSize = (try FileManager.default.attributesOfItem(atPath: uploadFileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        request.setValue(String(uploadSize), forHTTPHeaderField: "Content-Length")
        completed = true
        let audioSize = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        return PreparedUpload(
            request: request,
            uploadFileURL: uploadFileURL,
            audioFileBytes: audioSize,
            uploadFileBytes: uploadSize
        )
    }

    private static func send(
        _ request: URLRequest,
        uploadFileURL: URL,
        audioFileBytes: Int,
        uploadFileBytes: Int,
        requestHandle: TranscriptionRequest,
        attempt: Int,
        startedAt: CFAbsoluteTime,
        readMs: Double,
        buildMs: Double,
        completion: @escaping (Result<String, TranscriptionError>) -> Void
    ) {
        guard !requestHandle.isCancelled else {
            requestHandle.finish()
            return
        }

        logAttemptStart(
            attempt: attempt,
            elapsedMs: elapsedMs(since: startedAt),
            audioFileBytes: audioFileBytes,
            uploadFileBytes: uploadFileBytes
        )

        // Use a fresh session for each upload to avoid carrying forward bad connection state between requests.
        let activeSession = URLSession(configuration: makeTranscriptionSessionConfiguration())
        let task = activeSession.uploadTask(with: request, fromFile: uploadFileURL) { data, response, error in
            var shouldCleanupUpload = true
            defer {
                activeSession.invalidateAndCancel()
                if shouldCleanupUpload {
                    requestHandle.finish()
                }
            }

            guard !requestHandle.isCancelled else { return }

            let totalMs = elapsedMs(since: startedAt)
            let http = response as? HTTPURLResponse
            let requestID = http?.value(forHTTPHeaderField: "x-request-id") ?? "n/a"

            func log(_ note: String, statusCode: Int? = http?.statusCode) {
                logLatency(
                    totalMs: totalMs,
                    readMs: readMs,
                    buildMs: buildMs,
                    attempt: attempt,
                    audioFileBytes: audioFileBytes,
                    uploadFileBytes: uploadFileBytes,
                    statusCode: statusCode,
                    requestID: requestID,
                    note: note
                )
            }

            if let error {
                let nsError = error as NSError
                let isRetryableTransport = shouldRetryTransportError(nsError)
                let retryDelay: TimeInterval? = isRetryableTransport && attempt < maxTranscriptionAttempts ? 0 : nil
                logTransportError(
                    nsError,
                    attempt: attempt,
                    elapsedMs: totalMs,
                    audioFileBytes: audioFileBytes,
                    uploadFileBytes: uploadFileBytes,
                    willRetry: retryDelay != nil
                )

                if let retryDelay {
                    shouldCleanupUpload = false
                    scheduleRetry(
                        request,
                        uploadFileURL: uploadFileURL,
                        audioFileBytes: audioFileBytes,
                        uploadFileBytes: uploadFileBytes,
                        requestHandle: requestHandle,
                        attempt: attempt,
                        nextAttempt: attempt + 1,
                        delay: retryDelay,
                        startedAt: startedAt,
                        readMs: readMs,
                        buildMs: buildMs,
                        reason: "transport_\(transportErrorName(for: nsError))",
                        completion: completion
                    )
                    return
                }

                log("error=\(transportErrorName(for: nsError))", statusCode: nil)
                completion(.failure(transcriptionError(for: nsError)))
                return
            }

            guard let http else {
                log("invalid-response", statusCode: nil)
                completion(.failure(.other("Invalid server response")))
                return
            }

            let payload = data ?? Data()
            logRateLimitHeaders(http, attempt: attempt, statusCode: http.statusCode, requestID: requestID)

            guard http.statusCode == 200 else {
                if let retryDelay = httpRetryDelay(status: http.statusCode, headers: http, body: payload, attempt: attempt) {
                    log("http-retry status=\(http.statusCode) delay_ms=\(String(format: "%.0f", retryDelay * 1000))")
                    shouldCleanupUpload = false
                    scheduleRetry(
                        request,
                        uploadFileURL: uploadFileURL,
                        audioFileBytes: audioFileBytes,
                        uploadFileBytes: uploadFileBytes,
                        requestHandle: requestHandle,
                        attempt: attempt,
                        nextAttempt: attempt + 1,
                        delay: retryDelay,
                        startedAt: startedAt,
                        readMs: readMs,
                        buildMs: buildMs,
                        reason: "http_\(http.statusCode)",
                        completion: completion
                    )
                    return
                }

                log("http-error")
                completion(.failure(mapHTTPError(status: http.statusCode, headers: http, body: payload)))
                return
            }

            let text = extractTranscription(from: payload)

            guard let text, !text.isEmpty else {
                log("empty-transcription")
                completion(.failure(.emptyTranscription))
                return
            }
            log("ok")
            completion(.success(text))
        }

        requestHandle.setTask(task)
        task.resume()
    }

    private static func scheduleRetry(
        _ request: URLRequest,
        uploadFileURL: URL,
        audioFileBytes: Int,
        uploadFileBytes: Int,
        requestHandle: TranscriptionRequest,
        attempt: Int,
        nextAttempt: Int,
        delay: TimeInterval,
        startedAt: CFAbsoluteTime,
        readMs: Double,
        buildMs: Double,
        reason: String,
        completion: @escaping (Result<String, TranscriptionError>) -> Void
    ) {
        AppLog.metric(
            "transcription_retry_scheduled",
            category: .network,
            level: .debug,
            values: [
                "attempt": String(attempt),
                "delay_ms": String(format: "%.0f", delay * 1000),
                "next_attempt": String(nextAttempt),
                "reason": reason,
                "session_profile": transcriptionSessionProfile
            ]
        )

        requestHandle.scheduleRetry(after: delay) {
            requestHandle.clearPendingRetry()
            guard !requestHandle.isCancelled else {
                requestHandle.finish()
                return
            }
            send(
                request,
                uploadFileURL: uploadFileURL,
                audioFileBytes: audioFileBytes,
                uploadFileBytes: uploadFileBytes,
                requestHandle: requestHandle,
                attempt: nextAttempt,
                startedAt: startedAt,
                readMs: readMs,
                buildMs: buildMs,
                completion: completion
            )
        }
    }

    static func httpRetryDelay(status: Int, headers: HTTPURLResponse, body: Data, attempt: Int) -> TimeInterval? {
        guard attempt < maxTranscriptionAttempts else { return nil }

        switch status {
        case 429:
            return parseRetryAfter(headers.value(forHTTPHeaderField: "Retry-After")) ?? 10
        case 498:
            return jitteredBackoff(base: 0.7, attempt: attempt)
        case 500, 502, 503, 504:
            return jitteredBackoff(base: 0.5, attempt: attempt)
        case 424:
            let message = (parseAPIErrorMessage(from: body) ?? "").lowercased()
            guard message.contains("tempor") || message.contains("dependency") || message.contains("try again") else {
                return nil
            }
            return jitteredBackoff(base: 0.5, attempt: attempt)
        default:
            return nil
        }
    }

    static func parseRetryAfter(_ rawValue: String?) -> TimeInterval? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = TimeInterval(trimmed), value >= 0 else { return nil }
        return value
    }

    private static func jitteredBackoff(base: TimeInterval, attempt: Int) -> TimeInterval {
        let multiplier = pow(2, Double(max(0, attempt - 1)))
        let jitter = Double.random(in: 0...0.25)
        return min(5, base * multiplier + jitter)
    }

    private static func logRateLimitHeaders(
        _ headers: HTTPURLResponse,
        attempt: Int,
        statusCode: Int,
        requestID: String
    ) {
        let headerNames = [
            "retry-after",
            "x-ratelimit-limit-requests",
            "x-ratelimit-remaining-requests",
            "x-ratelimit-reset-requests",
            "x-ratelimit-limit-audio-seconds",
            "x-ratelimit-remaining-audio-seconds",
            "x-ratelimit-reset-audio-seconds"
        ]

        var values: [String: String] = [
            "attempt": String(attempt),
            "request_id": requestID,
            "status": String(statusCode)
        ]

        for name in headerNames {
            if let value = headers.value(forHTTPHeaderField: name), !value.isEmpty {
                values[name.replacingOccurrences(of: "-", with: "_")] = value
            }
        }

        guard values.count > 3 else { return }
        AppLog.metric("groq_rate_limit_headers", category: .network, level: .debug, values: values)
    }

    private static func elapsedMs(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private static func logLatency(
        totalMs: Double,
        readMs: Double,
        buildMs: Double,
        attempt: Int,
        audioFileBytes: Int,
        uploadFileBytes: Int,
        statusCode: Int?,
        requestID: String,
        note: String
    ) {
        guard AppConstants.Diagnostics.debugLoggingEnabled || attempt > 1 || totalMs >= latencyLogThresholdMs else { return }

        AppLog.metric(
            "transcription_latency",
            category: .network,
            level: .debug,
            values: [
                "attempt": String(attempt),
                "audio_bytes": String(audioFileBytes),
                "build_ms": String(format: "%.0f", buildMs),
                "note": note,
                "read_ms": String(format: "%.0f", readMs),
                "request_id": requestID,
                "session_profile": transcriptionSessionProfile,
                "status": statusCode.map(String.init) ?? "n/a",
                "total_ms": String(format: "%.0f", totalMs),
                "upload_bytes": String(uploadFileBytes)
            ]
        )
    }

    private static func logAttemptStart(
        attempt: Int,
        elapsedMs: Double,
        audioFileBytes: Int,
        uploadFileBytes: Int
    ) {
        AppLog.metric(
            "transcription_attempt",
            category: .network,
            level: .debug,
            values: [
                "attempt": String(attempt),
                "audio_bytes": String(audioFileBytes),
                "elapsed_ms": String(format: "%.0f", elapsedMs),
                "phase": "start",
                "session_profile": transcriptionSessionProfile,
                "upload_bytes": String(uploadFileBytes)
            ]
        )
    }

    private static func logTransportError(
        _ nsError: NSError,
        attempt: Int,
        elapsedMs: Double,
        audioFileBytes: Int,
        uploadFileBytes: Int,
        willRetry: Bool
    ) {
        AppLog.metric(
            "transcription_transport_error",
            category: .network,
            level: .debug,
            values: [
                "attempt": String(attempt),
                "audio_bytes": String(audioFileBytes),
                "elapsed_ms": String(format: "%.0f", elapsedMs),
                "error_code": String(nsError.code),
                "error_domain": nsError.domain,
                "error_name": transportErrorName(for: nsError),
                "retryable": shouldRetryTransportError(nsError) ? "true" : "false",
                "session_profile": transcriptionSessionProfile,
                "upload_bytes": String(uploadFileBytes),
                "will_retry": willRetry ? "true" : "false"
            ]
        )
    }

    static func extractTranscription(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let topLevelText = trimmedText(json["text"] as? String)

        guard let segments = json["segments"] as? [[String: Any]] else {
            return topLevelText ?? String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        logSegmentDiagnostics(segments)

        if let topLevelText {
            return topLevelText
        }

        let segmentText = segments.compactMap { segment in
            segment["text"] as? String
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)

        return segmentText.isEmpty ? nil : segmentText
    }

    private static func trimmedText(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func logSegmentDiagnostics(_ segments: [[String: Any]]) {
        var suspect = 0
        var lastEnd: Double = 0

        for segment in segments {
            let start = segment["start"] as? Double ?? 0
            let end = segment["end"] as? Double ?? lastEnd
            let compressionRatio = segment["compression_ratio"] as? Double ?? 0
            let gap = start - lastEnd

            if gap > AppConstants.Transcription.maxSegmentGapSeconds && compressionRatio < AppConstants.Transcription.minCompressionRatio {
                suspect += 1
            }

            lastEnd = end
        }

        AppLog.metric(
            "transcription_segments",
            category: .network,
            level: .debug,
            values: [
                "dropped": "0",
                "kept": String(segments.count),
                "suspect": String(suspect)
            ]
        )
    }

    static func mapHTTPError(status: Int, headers: HTTPURLResponse, body: Data) -> TranscriptionError {
        let message = parseAPIErrorMessage(from: body)

        switch status {
        case 400:
            return .badRequest(message ?? "Invalid request")
        case 401:
            return .invalidKey
        case 403:
            let lower = (message ?? "").lowercased()
            if lower.contains("restricted") || lower.contains("organization") {
                return .accountRestricted
            }
            return .forbidden(message ?? "Forbidden")
        case 404:
            return .notFound
        case 413:
            return .tooLarge
        case 422:
            return .unprocessable(message ?? "Couldn't process audio")
        case 424:
            return .failedDependency(message ?? "Temporary dependency error")
        case 429:
            let retryAfter = headers.value(forHTTPHeaderField: "Retry-After")
                .flatMap(parseRetryAfter)
                .map { Int(ceil($0)) } ?? 10
            return .rateLimited(retryAfter)
        case 498:
            return .capacityExceeded
        case 500, 502, 503, 504:
            return .serverError
        default:
            if let message, !message.isEmpty {
                return .other(message)
            }
            return .other("HTTP \(status)")
        }
    }

    static func parseAPIErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return sanitize(message)
        }

        if let raw = String(data: data, encoding: .utf8), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sanitize(raw)
        }

        return nil
    }

    private static func sanitize(_ raw: String) -> String {
        let condensed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if condensed.count <= 80 { return condensed }
        return String(condensed.prefix(80))
    }

    enum TranscriptionError: LocalizedError {
        case rateLimited(Int)
        case serverError
        case timedOut
        case emptyTranscription
        case tooLarge
        case invalidKey
        case accountRestricted
        case forbidden(String)
        case badRequest(String)
        case notFound
        case unprocessable(String)
        case failedDependency(String)
        case capacityExceeded
        case networkUnavailable
        case other(String)

        var diagnosticCode: String {
            switch self {
            case .rateLimited: return "rate_limited"
            case .serverError: return "server_error"
            case .timedOut: return "timed_out"
            case .emptyTranscription: return "empty_transcription"
            case .tooLarge: return "too_large"
            case .invalidKey: return "invalid_key"
            case .accountRestricted: return "account_restricted"
            case .forbidden: return "forbidden"
            case .badRequest: return "bad_request"
            case .notFound: return "not_found"
            case .unprocessable: return "unprocessable"
            case .failedDependency: return "failed_dependency"
            case .capacityExceeded: return "capacity_exceeded"
            case .networkUnavailable: return "network_unavailable"
            case .other: return "other"
            }
        }

        var errorDescription: String? {
            switch self {
            case .rateLimited(let seconds): return "Rate limited, wait \(seconds)s"
            case .serverError: return AppStrings.Errors.groqUnavailable
            case .timedOut: return AppStrings.Errors.transcriptionTimedOut
            case .emptyTranscription: return AppStrings.Errors.noSpeechDetected
            case .tooLarge: return AppStrings.Errors.recordingTooLarge
            case .invalidKey: return AppStrings.Errors.invalidKey
            case .accountRestricted: return AppStrings.Errors.orgRestricted
            case .forbidden: return AppStrings.Errors.accessDenied
            case .badRequest: return AppStrings.Errors.requestRejected
            case .notFound: return AppStrings.Errors.resourceNotFound
            case .unprocessable: return AppStrings.Errors.couldntProcessAudio
            case .failedDependency: return AppStrings.Errors.temporaryServiceIssue
            case .capacityExceeded: return AppStrings.Errors.serviceAtCapacity
            case .networkUnavailable: return AppStrings.Errors.networkUnavailable
            case .other: return AppStrings.Errors.unexpectedTranscriptionError
            }
        }

        var diagnosticSummary: String? {
            switch self {
            case .forbidden(let message),
                 .badRequest(let message),
                 .unprocessable(let message),
                 .failedDependency(let message),
                 .other(let message):
                return message
            default:
                return nil
            }
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
