import Foundation

enum GroqAPI {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        return URLSession(configuration: c)
    }()

    private static let maxFileSize = 25 * 1024 * 1024  // Groq limit

    /// Pre-warm TCP+TLS so the first real request skips the handshake (~100-300ms saved).
    static func warmConnection() {
        guard let url = URL(string: "https://api.groq.com") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        session.dataTask(with: req) { _, _, _ in }.resume()
    }

    // MARK: - Transcription

    static func transcribe(
        fileURL: URL,
        config: Config,
        completion: @escaping (Result<String, TranscriptionError>) -> Void
    ) {
        let audioData: Data
        do {
            audioData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            completion(.failure(.other("Can't read audio: \(error.localizedDescription)")))
            return
        }
        guard audioData.count <= maxFileSize else {
            completion(.failure(.tooLarge))
            return
        }

        let request = buildRequest(audioData: audioData, fileURL: fileURL, config: config)
        send(request, attempt: 1, completion: completion)
    }

    // MARK: - Request Building

    private static func buildRequest(audioData: Data, fileURL: URL, config: Config) -> URLRequest {
        let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let ext = fileURL.pathExtension.lowercased()
        let mime = ext == "flac" ? "audio/flac" : "audio/wav"

        var body = Data(capacity: audioData.count + 512)

        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        field("model", config.model)
        field("language", config.language)
        field("response_format", "text")
        field("temperature", "0")

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(ext)\"\r\n")
        body.append("Content-Type: \(mime)\r\n\r\n")
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n")

        req.httpBody = body
        return req
    }

    // MARK: - Send with Retry

    /// Sends the request. On timeout or connection error, retries once with a fresh session
    /// to avoid reusing a stale QUIC connection.
    private static func send(
        _ request: URLRequest,
        attempt: Int,
        completion: @escaping (Result<String, TranscriptionError>) -> Void
    ) {
        let s = attempt == 1 ? session : URLSession(configuration: .ephemeral)

        s.dataTask(with: request) { data, response, error in
            if attempt > 1 { s.invalidateAndCancel() }

            if let error = error {
                let code = (error as NSError).code
                let retryable = code == NSURLErrorTimedOut
                    || code == NSURLErrorNetworkConnectionLost
                    || code == NSURLErrorSecureConnectionFailed

                if attempt == 1 && retryable {
                    session.reset { send(request, attempt: 2, completion: completion) }
                    return
                }
                completion(.failure(code == NSURLErrorTimedOut ? .timedOut : .other(error.localizedDescription)))
                return
            }

            guard let data = data else {
                completion(.failure(.other("No response from server")))
                return
            }

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                completion(.failure(mapHTTPError(http.statusCode, response: http, body: data)))
                return
            }

            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                completion(.success(text))
            } else {
                completion(.failure(.emptyTranscription))
            }
        }.resume()
    }

    // MARK: - Error Mapping

    private static func mapHTTPError(_ status: Int, response: HTTPURLResponse, body: Data) -> TranscriptionError {
        switch status {
        case 401: return .invalidKey
        case 413: return .tooLarge
        case 429:
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) ?? 10
            return .rateLimited(retry)
        case 500, 502, 503: return .serverError
        default:
            let raw = String(data: body, encoding: .utf8) ?? "Unknown"
            return .other(String("HTTP \(status): \(raw)".prefix(80)))
        }
    }

    // MARK: - Error Types

    enum TranscriptionError: LocalizedError {
        case rateLimited(Int)
        case serverError
        case timedOut
        case emptyTranscription
        case tooLarge
        case invalidKey
        case other(String)

        var errorDescription: String? {
            switch self {
            case .rateLimited(let s): return "Rate limited — wait \(s)s"
            case .serverError:        return "Groq unavailable"
            case .timedOut:           return "Timed out"
            case .emptyTranscription: return "No speech detected"
            case .tooLarge:           return "Recording too large"
            case .invalidKey:         return "Invalid API key"
            case .other(let msg):     return msg
            }
        }
    }
}

// MARK: - Data + String Append

extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}
