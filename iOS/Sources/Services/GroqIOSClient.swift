import AVFoundation
import Foundation

struct GroqIOSClient {
    enum ClientError: LocalizedError {
        case invalidKey
        case fileTooLarge
        case rateLimited(retryAfter: TimeInterval?)
        case serverUnavailable
        case rejected(String)
        case unreadableAudio
        case network

        var errorDescription: String? {
            switch self {
            case .invalidKey: return IOSAppStrings.Errors.invalidKey
            case .fileTooLarge: return IOSAppStrings.Errors.recordingTooLarge
            case .rateLimited: return IOSAppStrings.Errors.serviceAtCapacity
            case .serverUnavailable: return IOSAppStrings.Errors.groqUnavailable
            case .rejected(let message): return message.isEmpty ? IOSAppStrings.Errors.requestRejected : message
            case .unreadableAudio: return IOSAppStrings.Errors.unreadableAudio
            case .network: return IOSAppStrings.Errors.networkUnavailable
            }
        }
    }

    private let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    private let maximumBytes = 24 * 1024 * 1024
    private let longestRateLimitWait: TimeInterval = 20
    private let session = URLSession(configuration: .default)

    func transcribe(
        fileURL: URL,
        apiKey: String,
        model: String = "whisper-large-v3",
        prompt: String = "",
        sessionID: UUID? = nil
    ) async throws -> String {
        let uploadURL = try await Self.uploadableFile(for: fileURL)
        defer { if uploadURL != fileURL { try? FileManager.default.removeItem(at: uploadURL) } }
        let size = try uploadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw ClientError.fileTooLarge }

        let requestID = UUID()
        var lastError: Error = ClientError.network
        for attempt in 1...3 {
            let started = ProcessInfo.processInfo.systemUptime
            TimingDiagnostics.shared.record(.attemptStarted, requestID: requestID, sessionID: sessionID, attempt: attempt)
            do {
                let text = try await perform(fileURL: uploadURL, apiKey: apiKey, model: model, prompt: prompt,
                                             requestID: requestID, sessionID: sessionID, attempt: attempt)
                TimingDiagnostics.shared.record(.attemptSucceeded, requestID: requestID, sessionID: sessionID,
                                                attempt: attempt, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
                return text
            } catch let error as ClientError {
                TimingDiagnostics.shared.record(.attemptFailed, requestID: requestID, sessionID: sessionID,
                                                attempt: attempt, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
                lastError = error
                guard attempt < 3, let delay = retryDelay(after: error, attempt: attempt) else { throw error }
                TimingDiagnostics.shared.record(.retryScheduled, requestID: requestID, sessionID: sessionID,
                                                attempt: attempt, elapsedSeconds: delay)
                try await Task.sleep(for: .seconds(delay))
            } catch {
                // Only URL error codes; never serialize NSError userInfo or descriptions.
                let code = (error as? URLError)?.code.rawValue
                TimingDiagnostics.shared.record(.attemptFailed, requestID: requestID, sessionID: sessionID,
                                                attempt: attempt, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, code: code)
                lastError = ClientError.network
                guard attempt < 3 else { throw ClientError.network }
                // A transport failure may leave a stalled connection in the pool;
                // flush makes the retry open a new one.
                await session.flush()
                let delay = Self.backoff(attempt: attempt)
                TimingDiagnostics.shared.record(.retryScheduled, requestID: requestID, sessionID: sessionID,
                                                attempt: attempt, elapsedSeconds: delay)
                try await Task.sleep(for: .seconds(delay))
            }
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

        let uploadStarted = ProcessInfo.processInfo.systemUptime
        let observer = UploadMetricsDelegate(requestID: requestID, sessionID: sessionID, attempt: attempt)
        let (data, response) = try await session.upload(for: request, fromFile: bodyURL, delegate: observer)
        TimingDiagnostics.shared.record(.responseReceived, requestID: requestID, sessionID: sessionID,
                                        attempt: attempt, elapsedSeconds: ProcessInfo.processInfo.systemUptime - uploadStarted,
                                        code: (response as? HTTPURLResponse)?.statusCode)
        guard let http = response as? HTTPURLResponse else { throw ClientError.network }
        guard http.statusCode == 200 else {
            switch http.statusCode {
            case 401, 403: throw ClientError.invalidKey
            case 413: throw ClientError.fileTooLarge
            case 429:
                throw ClientError.rateLimited(
                    retryAfter: Self.seconds(fromRetryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                )
            case 500...599: throw ClientError.serverUnavailable
            case 400 where Self.errorCode(from: data) == "invalid_media_file": throw ClientError.unreadableAudio
            default: throw ClientError.rejected(Self.safeMessage(from: data) ?? "Groq rejected this segment")
            }
        }

        return try Self.transcript(from: data)
    }

    /// Silence comes back as empty text, which is a finished part with no words.
    static func transcript(from data: Data) throws -> String {
        struct Response: Decodable { let text: String }
        return try JSONDecoder().decode(Response.self, from: data).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nil` means don't retry automatically; the part stays retryable by hand.
    private func retryDelay(after error: ClientError, attempt: Int) -> TimeInterval? {
        switch error {
        case .rateLimited(let retryAfter?):
            return retryAfter <= longestRateLimitWait ? retryAfter : nil
        case .rateLimited(nil), .serverUnavailable, .network:
            return Self.backoff(attempt: attempt)
        case .invalidKey, .fileTooLarge, .rejected, .unreadableAudio:
            return nil
        }
    }

    private static func backoff(attempt: Int) -> TimeInterval {
        attempt == 1 ? 1 : 3
    }

    /// Groq sends Retry-After as seconds (console.groq.com/docs/rate-limits).
    static func seconds(fromRetryAfter value: String?) -> TimeInterval? {
        guard let value, let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) else { return nil }
        return max(0, seconds)
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

    /// Groq takes M4A but not raw AAC (ADTS), so ADTS parts are rewrapped into
    /// a temporary M4A. Passthrough copies the audio without re-encoding.
    private static func uploadableFile(for fileURL: URL) async throws -> URL {
        guard fileURL.pathExtension == "aac" else { return fileURL }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("groqdictate-ios-\(UUID().uuidString).m4a")
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: fileURL), presetName: AVAssetExportPresetPassthrough)
        else { throw ClientError.unreadableAudio }
        export.outputURL = output
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw ClientError.unreadableAudio
        }
        return output
    }

    private static func errorCode(from data: Data) -> String? {
        struct ErrorResponse: Decodable {
            struct Detail: Decodable { let code: String? }
            let error: Detail
        }
        return try? JSONDecoder().decode(ErrorResponse.self, from: data).error.code
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

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
