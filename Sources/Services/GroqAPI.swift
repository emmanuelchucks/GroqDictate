import Foundation

enum GroqAPI {
    private static let baseURL = AppConstants.URLs.groqTranscriptions
    private static let maxFileSize = 25 * 1024 * 1024
    private static let requestTimeout: TimeInterval = 12
    private static let resourceTimeout: TimeInterval = 30
    private static let latencyLogThresholdMs: Double = 2500

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    static func warmConnection() {
        var request = URLRequest(url: AppConstants.URLs.groqAPIHost)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    static func transcribe(
        fileURL: URL,
        config: Config,
        completion: @escaping (Result<String, TranscriptionError>) -> Void
    ) {
        let startedAt = CFAbsoluteTimeGetCurrent()

        let audioData: Data
        do {
            audioData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            completion(.failure(.other("Can't read audio file")))
            return
        }

        let readMs = elapsedMs(since: startedAt)

        guard audioData.count <= maxFileSize else {
            completion(.failure(.tooLarge))
            return
        }

        let requestBuildStartedAt = CFAbsoluteTimeGetCurrent()
        let request = buildRequest(audioData: audioData, fileURL: fileURL, config: config)
        let buildMs = elapsedMs(since: requestBuildStartedAt)

        send(
            request,
            attempt: 1,
            startedAt: startedAt,
            readMs: readMs,
            buildMs: buildMs,
            completion: completion
        )
    }

    private static func buildRequest(audioData: Data, fileURL: URL, config: Config) -> URLRequest {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let ext = fileURL.pathExtension.lowercased()
        let mime = ext == "flac" ? "audio/flac" : "audio/wav"

        var body = Data(capacity: audioData.count + 768)

        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        field("model", config.model)
        field("language", config.language)
        field("response_format", "verbose_json")
        field("temperature", "0")

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(ext)\"\r\n")
        body.append("Content-Type: \(mime)\r\n\r\n")
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n")

        request.httpBody = body
        return request
    }

    private static func send(
        _ request: URLRequest,
        attempt: Int,
        startedAt: CFAbsoluteTime,
        readMs: Double,
        buildMs: Double,
        completion: @escaping (Result<String, TranscriptionError>) -> Void
    ) {
        let activeSession = attempt == 1 ? session : URLSession(configuration: .ephemeral)

        activeSession.dataTask(with: request) { data, response, error in
            if attempt > 1 { activeSession.invalidateAndCancel() }

            let totalMs = elapsedMs(since: startedAt)
            let http = response as? HTTPURLResponse
            let requestID = http?.value(forHTTPHeaderField: "x-request-id") ?? "n/a"

            func log(_ note: String, statusCode: Int? = http?.statusCode) {
                logLatency(
                    totalMs: totalMs,
                    readMs: readMs,
                    buildMs: buildMs,
                    attempt: attempt,
                    statusCode: statusCode,
                    requestID: requestID,
                    note: note
                )
            }

            if let error {
                let nsError = error as NSError
                let isRetryableTransport = nsError.code == NSURLErrorTimedOut
                    || nsError.code == NSURLErrorNetworkConnectionLost
                    || nsError.code == NSURLErrorSecureConnectionFailed

                if attempt == 1 && isRetryableTransport {
                    session.reset {
                        send(
                            request,
                            attempt: 2,
                            startedAt: startedAt,
                            readMs: readMs,
                            buildMs: buildMs,
                            completion: completion
                        )
                    }
                    return
                }

                log("error=\(nsError.code)", statusCode: nil)
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
        }.resume()
    }

    private static func elapsedMs(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private static func logLatency(
        totalMs: Double,
        readMs: Double,
        buildMs: Double,
        attempt: Int,
        statusCode: Int?,
        requestID: String,
        note: String
    ) {
        guard AppConstants.Diagnostics.debugLoggingEnabled || attempt > 1 || totalMs >= latencyLogThresholdMs else { return }

        let status = statusCode.map(String.init) ?? "n/a"
        let message = String(
            format: "transcription latency total=%.0fms read=%.0fms build=%.0fms attempt=%d status=%@ request_id=%@ note=%@",
            totalMs,
            readMs,
            buildMs,
            attempt,
            status,
            requestID,
            note
        )
        AppLog.debug(message, category: .network)
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
                let preview = (segment["text"] as? String ?? "").prefix(40)
                AppLog.debug(
                    String(format: "segment dropped t=%.1f-%.1fs gap=%.1fs compress=%.2f text=%@", start, end, gap, compressionRatio, String(preview)),
                    category: .network
                )
                dropped += 1
                return nil
            }

            lastEnd = end
            kept += 1
            return segment["text"] as? String
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)

        AppLog.debug("segments kept=\(kept) dropped=\(dropped)", category: .network)
        return text.isEmpty ? nil : text
    }

    private static func mapHTTPError(status: Int, headers: HTTPURLResponse, body: Data) -> TranscriptionError {
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

    private static func parseAPIErrorMessage(from data: Data) -> String? {
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

        var errorDescription: String? {
            switch self {
            case .rateLimited(let seconds): return "Rate limited, wait \(seconds)s"
            case .serverError: return "Groq unavailable"
            case .timedOut: return "Timed out"
            case .emptyTranscription: return "No speech detected"
            case .tooLarge: return "Recording too large"
            case .invalidKey: return "Invalid API key"
            case .accountRestricted: return "Organization restricted"
            case .forbidden(let message): return message
            case .badRequest(let message): return message
            case .notFound: return "Resource not found"
            case .unprocessable(let message): return message
            case .failedDependency(let message): return message
            case .capacityExceeded: return "Service at capacity"
            case .other(let message): return message
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
