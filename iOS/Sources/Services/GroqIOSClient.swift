import Foundation

struct GroqIOSClient {
    enum ClientError: LocalizedError {
        case invalidKey
        case fileTooLarge
        case rateLimited
        case serverUnavailable
        case rejected(String)
        case emptyTranscript
        case network

        var errorDescription: String? {
            switch self {
            case .invalidKey: return IOSAppStrings.Errors.invalidKey
            case .fileTooLarge: return IOSAppStrings.Errors.recordingTooLarge
            case .rateLimited: return IOSAppStrings.Errors.serviceAtCapacity
            case .serverUnavailable: return IOSAppStrings.Errors.groqUnavailable
            case .rejected(let message): return message.isEmpty ? IOSAppStrings.Errors.requestRejected : message
            case .emptyTranscript: return IOSAppStrings.Errors.noSpeechDetected
            case .network: return IOSAppStrings.Errors.networkUnavailable
            }
        }
    }

    private let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    private let maximumBytes = 24 * 1024 * 1024

    func transcribe(
        fileURL: URL,
        apiKey: String,
        model: String = "whisper-large-v3",
        prompt: String = "",
        sessionID: UUID? = nil
    ) async throws -> String {
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw ClientError.fileTooLarge }

        let requestID = UUID()
        var lastError: Error = ClientError.network
        for attempt in 1...3 {
            let started = ProcessInfo.processInfo.systemUptime
            TimingDiagnostics.shared.record(.attemptStarted, requestID: requestID, sessionID: sessionID, attempt: attempt)
            do {
                let text = try await perform(fileURL: fileURL, apiKey: apiKey, model: model, prompt: prompt,
                                             requestID: requestID, sessionID: sessionID, attempt: attempt)
                TimingDiagnostics.shared.record(.attemptSucceeded, requestID: requestID, sessionID: sessionID,
                                                attempt: attempt, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
                return text
            } catch let error as ClientError {
                TimingDiagnostics.shared.record(.attemptFailed, requestID: requestID, sessionID: sessionID,
                                                attempt: attempt, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
                lastError = error
                guard attempt < 3, error.isRetryable else { throw error }
            } catch {
                // Only URL error codes; never serialize NSError userInfo or descriptions.
                let code = (error as? URLError)?.code.rawValue
                TimingDiagnostics.shared.record(.attemptFailed, requestID: requestID, sessionID: sessionID,
                                                attempt: attempt, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, code: code)
                lastError = ClientError.network
                guard attempt < 3 else { throw ClientError.network }
            }
            TimingDiagnostics.shared.record(.retryScheduled, requestID: requestID, sessionID: sessionID, attempt: attempt)
            try await Task.sleep(for: .seconds(attempt == 1 ? 1 : 3))
        }
        throw lastError
    }

    private func perform(fileURL: URL, apiKey: String, model: String, prompt: String,
                         requestID: UUID, sessionID: UUID?, attempt: Int) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("groqdictate-ios-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let body = Self.makeMultipartBody(
            fileData: try Data(contentsOf: fileURL, options: .mappedIfSafe),
            model: model,
            prompt: prompt,
            boundary: boundary
        )
        try body.write(to: bodyURL, options: .atomic)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Isolate each attempt so a stalled connection is never reused by a retry.
        let uploadSession = URLSession(configuration: URLSession.shared.configuration)
        defer { uploadSession.finishTasksAndInvalidate() }
        let uploadStarted = ProcessInfo.processInfo.systemUptime
        let observer = UploadMetricsDelegate(requestID: requestID, sessionID: sessionID, attempt: attempt)
        let (data, response) = try await uploadSession.upload(for: request, fromFile: bodyURL, delegate: observer)
        TimingDiagnostics.shared.record(.responseReceived, requestID: requestID, sessionID: sessionID,
                                        attempt: attempt, elapsedSeconds: ProcessInfo.processInfo.systemUptime - uploadStarted,
                                        code: (response as? HTTPURLResponse)?.statusCode)
        guard let http = response as? HTTPURLResponse else { throw ClientError.network }
        guard http.statusCode == 200 else {
            switch http.statusCode {
            case 401, 403: throw ClientError.invalidKey
            case 413: throw ClientError.fileTooLarge
            case 429: throw ClientError.rateLimited
            case 500...599: throw ClientError.serverUnavailable
            default: throw ClientError.rejected(Self.safeMessage(from: data) ?? "Groq rejected this segment")
            }
        }

        struct Response: Decodable { let text: String }
        let text = try JSONDecoder().decode(Response.self, from: data).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClientError.emptyTranscript }
        return text
    }

    static func makeMultipartBody(
        fileData: Data,
        model: String,
        prompt: String,
        boundary: String
    ) -> Data {
        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        addField("model", model)
        addField("language", "en")
        addField("response_format", "verbose_json")
        addField("temperature", "0")
        if !prompt.isEmpty {
            addField("prompt", prompt)
        }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"segment.m4a\"\r\n")
        body.append("Content-Type: audio/mp4\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func safeMessage(from data: Data) -> String? {
        struct ErrorResponse: Decodable {
            struct Detail: Decodable { let message: String }
            let error: Detail
        }
        guard let message = try? JSONDecoder().decode(ErrorResponse.self, from: data).error.message else { return nil }
        return String(message.replacingOccurrences(of: "\n", with: " ").prefix(100))
    }
}

private extension GroqIOSClient.ClientError {
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverUnavailable, .network: return true
        default: return false
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
