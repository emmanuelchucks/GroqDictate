import Foundation

enum GroqAPI {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldUsePipelining = true
        return URLSession(configuration: config)
    }()
    private static let maxFileSize = 25 * 1024 * 1024  // 25MB Groq limit

    /// Pre-warm TCP+TLS connection to Groq so first transcription skips handshake (~100-300ms)
    static func warmConnection() {
        guard let url = URL(string: "https://api.groq.com") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        session.dataTask(with: req) { _, _, _ in }.resume()
    }

    static func transcribe(
        fileURL: URL,
        config: Config,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let apiURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")
        else {
            completion(.failure(APIError.invalidURL))
            return
        }

        // Memory-map large files to avoid full copy into heap
        let audioData: Data
        do {
            audioData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            completion(.failure(APIError.fileReadFailed(error.localizedDescription)))
            return
        }

        if audioData.count > maxFileSize {
            let sizeMB = audioData.count / (1024 * 1024)
            completion(.failure(APIError.fileTooLarge(sizeMB)))
            return
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let ext = fileURL.pathExtension.lowercased()
        let mimeType = ext == "flac" ? "audio/flac" : "audio/wav"

        var body = Data()
        body.reserveCapacity(audioData.count + 512)

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
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(ext)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n")

        request.httpBody = body

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(APIError.noResponse))
                return
            }

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                let raw = String(data: data, encoding: .utf8) ?? "Unknown"
                completion(.failure(APIError.httpError(httpResponse.statusCode, raw)))
                return
            }

            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            {
                completion(.success(text))
            } else {
                completion(.failure(APIError.emptyTranscription))
            }
        }.resume()
    }

    enum APIError: LocalizedError {
        case invalidURL
        case noResponse
        case fileReadFailed(String)
        case fileTooLarge(Int)
        case httpError(Int, String)
        case emptyTranscription

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid API URL"
            case .noResponse: return "No response from server"
            case .fileReadFailed(let reason): return "Can't read audio: \(reason)"
            case .fileTooLarge(let mb): return "Recording too large (\(mb)MB, max 25MB)"
            case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
            case .emptyTranscription: return "Empty transcription"
            }
        }
    }
}

extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
