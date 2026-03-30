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

    private let performTranscription: PerformTranscription

    init(performTranscription: @escaping PerformTranscription = GroqAPI.transcribe) {
        self.performTranscription = performTranscription
    }

    @discardableResult
    func transcribe(
        fileURL: URL,
        config: Config,
        completion: @escaping (Result<String, TranscriptionEngineError>) -> Void
    ) -> TranscriptionRequestHandle {
        let request = performTranscription(fileURL, config) { result in
            completion(result.mapError(TranscriptionEngineError.init))
        }

        return TranscriptionRequestHandle(cancelAction: {
            request.cancel()
        })
    }
}
