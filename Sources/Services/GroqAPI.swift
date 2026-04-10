import Foundation

enum GroqAPI {
    private struct PreparedUpload {
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

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            let uploadFileURL = task == nil ? self.uploadFileURL : nil
            if task == nil {
                self.uploadFileURL = nil
            }
            lock.unlock()

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

    private static func buildRequest(fileURL: URL, config: Config) throws -> PreparedUpload {
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
        try field("language", config.language)
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
                logTransportError(
                    nsError,
                    attempt: attempt,
                    elapsedMs: totalMs,
                    audioFileBytes: audioFileBytes,
                    uploadFileBytes: uploadFileBytes,
                    willRetry: attempt == 1 && isRetryableTransport
                )

                if attempt == 1 && isRetryableTransport {
                    shouldCleanupUpload = false
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
                        attempt: 2,
                        startedAt: startedAt,
                        readMs: readMs,
                        buildMs: buildMs,
                        completion: completion
                    )
                    return
                }

                log("error=\(transportErrorName(for: nsError))", statusCode: nil)
                completion(.failure(nsError.code == NSURLErrorTimedOut ? .timedOut : .other("Network error")))
                return
            }

            guard let http else {
                log("invalid-response", statusCode: nil)
                completion(.failure(.other("Invalid server response")))
                return
            }

            let payload = data ?? Data()

            guard http.statusCode == 200 else {
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

    private static func extractTranscription(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let segments = json["segments"] as? [[String: Any]]
        else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var kept = 0
        var dropped = 0
        var lastEnd: Double = 0

        let text = segments.compactMap { segment -> String? in
            let start = segment["start"] as? Double ?? 0
            let end = segment["end"] as? Double ?? 0
            let compressionRatio = segment["compression_ratio"] as? Double ?? 0
            let gap = start - lastEnd

            if gap > AppConstants.Transcription.maxSegmentGapSeconds && compressionRatio < AppConstants.Transcription.minCompressionRatio {
                dropped += 1
                return nil
            }

            lastEnd = end
            kept += 1
            return segment["text"] as? String
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)

        AppLog.metric(
            "transcription_segments",
            category: .network,
            level: .debug,
            values: [
                "dropped": String(dropped),
                "kept": String(kept)
            ]
        )
        return text.isEmpty ? nil : text
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
            let retryAfter = headers.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) ?? 10
            return .rateLimited(retryAfter)
        case 498:
            return .capacityExceeded
        case 500, 502, 503:
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
