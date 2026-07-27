import Foundation

final class TranscriptionRequestHandle {
    private let lock = NSLock()
    private var cancelAction: (() -> Void)?
    private var cancelled = false

    init(cancelAction: (() -> Void)? = nil) {
        self.cancelAction = cancelAction
    }

    func cancel() {
        let action: (() -> Void)?

        lock.lock()
        if cancelled {
            action = nil
        } else {
            cancelled = true
            action = cancelAction
            cancelAction = nil
        }
        lock.unlock()

        action?()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

enum TranscriptionEngineError: LocalizedError, Equatable {
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

    init(_ groqError: GroqAPI.TranscriptionError) {
        switch groqError {
        case .rateLimited(let seconds):
            self = .rateLimited(seconds)
        case .serverError:
            self = .serverError
        case .timedOut:
            self = .timedOut
        case .emptyTranscription:
            self = .emptyTranscription
        case .tooLarge:
            self = .tooLarge
        case .invalidKey:
            self = .invalidKey
        case .accountRestricted:
            self = .accountRestricted
        case .forbidden(let message):
            self = .forbidden(message)
        case .badRequest(let message):
            self = .badRequest(message)
        case .notFound:
            self = .notFound
        case .unprocessable(let message):
            self = .unprocessable(message)
        case .failedDependency(let message):
            self = .failedDependency(message)
        case .capacityExceeded:
            self = .capacityExceeded
        case .networkUnavailable:
            self = .networkUnavailable
        case .other(let message):
            self = .other(message)
        }
    }

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

protocol TranscriptionEngine {
    @discardableResult
    func transcribe(
        fileURL: URL,
        config: Config,
        completion: @escaping (Result<String, TranscriptionEngineError>) -> Void
    ) -> TranscriptionRequestHandle
}

struct GroqTranscriptionEngine: TranscriptionEngine {
    typealias PerformTranscription = (
        URL,
        Config,
        @escaping (Result<String, GroqAPI.TranscriptionError>) -> Void
    ) -> GroqAPI.TranscriptionRequest
    typealias SelectCandidate = (
        String,
        String,
        String,
        @escaping (String?) -> Void
    ) -> GroqCandidateSelector.Request

    private let performTranscription: PerformTranscription
    private let selectCandidate: SelectCandidate

    init(
        performTranscription: @escaping PerformTranscription = GroqAPI.transcribe,
        selectCandidate: @escaping SelectCandidate = GroqCandidateSelector.select
    ) {
        self.performTranscription = performTranscription
        self.selectCandidate = selectCandidate
    }

    @discardableResult
    func transcribe(
        fileURL: URL,
        config: Config,
        completion: @escaping (Result<String, TranscriptionEngineError>) -> Void
    ) -> TranscriptionRequestHandle {
        guard !config.vocabularyHints.isEmpty else {
            let request = performTranscription(fileURL, config) { result in
                completion(result.mapError(TranscriptionEngineError.init))
            }
            return TranscriptionRequestHandle(cancelAction: request.cancel)
        }

        let coordinator = CandidateTranscriptionCoordinator(
            fileURL: fileURL,
            config: config,
            performTranscription: performTranscription,
            selectCandidate: selectCandidate,
            completion: completion
        )
        coordinator.start()
        return TranscriptionRequestHandle(cancelAction: coordinator.cancel)
    }
}

private final class CandidateTranscriptionCoordinator {
    private typealias ProviderResult = Result<String, GroqAPI.TranscriptionError>

    private let lock = NSLock()
    private let fileURL: URL
    private let config: Config
    private let performTranscription: GroqTranscriptionEngine.PerformTranscription
    private let selectCandidate: GroqTranscriptionEngine.SelectCandidate
    private let completion: (Result<String, TranscriptionEngineError>) -> Void
    private var rawResult: ProviderResult?
    private var hintedResult: ProviderResult?
    private var transcriptionRequests: [GroqAPI.TranscriptionRequest] = []
    private var selectionRequest: GroqCandidateSelector.Request?
    private var cancelled = false
    private var completed = false

    init(
        fileURL: URL,
        config: Config,
        performTranscription: @escaping GroqTranscriptionEngine.PerformTranscription,
        selectCandidate: @escaping GroqTranscriptionEngine.SelectCandidate,
        completion: @escaping (Result<String, TranscriptionEngineError>) -> Void
    ) {
        self.fileURL = fileURL
        self.config = config
        self.performTranscription = performTranscription
        self.selectCandidate = selectCandidate
        self.completion = completion
    }

    func start() {
        let rawConfig = Config(
            apiKey: config.apiKey,
            model: config.model,
            inputGain: config.inputGain,
            micUID: config.micUID,
            vocabularyHints: ""
        )
        let rawRequest = performTranscription(fileURL, rawConfig) { [weak self] result in
            self?.receive(result, hinted: false)
        }
        let hintedRequest = performTranscription(fileURL, config) { [weak self] result in
            self?.receive(result, hinted: true)
        }

        lock.lock()
        if cancelled {
            lock.unlock()
            rawRequest.cancel()
            hintedRequest.cancel()
            return
        }
        transcriptionRequests = [rawRequest, hintedRequest]
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let requests = transcriptionRequests
        let selection = selectionRequest
        lock.unlock()

        requests.forEach { $0.cancel() }
        selection?.cancel()
    }

    private func receive(_ result: ProviderResult, hinted: Bool) {
        lock.lock()
        guard !cancelled, !completed else { lock.unlock(); return }
        if hinted { hintedResult = result } else { rawResult = result }
        guard let rawResult, let hintedResult else { lock.unlock(); return }
        lock.unlock()
        resolve(raw: rawResult, hinted: hintedResult)
    }

    private func resolve(raw: ProviderResult, hinted: ProviderResult) {
        switch (raw, hinted) {
        case (.success(let rawText), .success(let hintedText)):
            guard rawText != hintedText else { finish(.success(rawText)); return }
            let request = selectCandidate(rawText, hintedText, config.apiKey) { [weak self] choice in
                self?.finish(.success(choice == "B" ? hintedText : rawText))
            }
            lock.lock()
            if cancelled || completed {
                lock.unlock()
                request.cancel()
            } else {
                selectionRequest = request
                lock.unlock()
            }
        case (.success(let rawText), .failure):
            finish(.success(rawText))
        case (.failure, .success(let hintedText)):
            finish(.success(hintedText))
        case (.failure, .failure(let error)):
            finish(.failure(TranscriptionEngineError(error)))
        }
    }

    private func finish(_ result: Result<String, TranscriptionEngineError>) {
        lock.lock()
        guard !cancelled, !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        completion(result)
    }
}
