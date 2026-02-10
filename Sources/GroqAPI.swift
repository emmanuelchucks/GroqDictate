import Foundation

enum GroqAPI {
    static func transcribe(
        fileURL: URL,
        config: Config,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let apiURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions") else {
            completion(.failure(APIError.invalidURL))
            return
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        // Generous timeout: 60s should handle even long recordings
        request.timeoutInterval = 60

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        // Detect content type from extension
        let ext = fileURL.pathExtension.lowercased()
        let mimeType = ext == "flac" ? "audio/flac" : "audio/wav"
        let fileName = "audio.\(ext)"

        // Build multipart body
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        // Use turbo model for max speed; specify language for faster processing
        field("model", config.model)
        field("language", config.language)
        // "text" format = fastest response (no JSON overhead)
        field("response_format", "text")

        // Attach audio file
        body.append("--\(boundary)\r\n")
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        if let audioData = try? Data(contentsOf: fileURL) {
            body.append(audioData)
        }
        body.append("\r\n--\(boundary)--\r\n")

        request.httpBody = body

        // Use a dedicated ephemeral session for zero caching overhead
        let session = URLSession(configuration: .ephemeral)
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

            // response_format=text returns plain text (no JSON wrapping)
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
        case httpError(Int, String)
        case emptyTranscription

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid API URL"
            case .noResponse: return "No response from server"
            case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
            case .emptyTranscription: return "Empty transcription"
            }
        }
    }
}

// Convenience for building multipart data
extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
