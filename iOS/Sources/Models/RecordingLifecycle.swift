import Foundation

enum RecordingLifecycleAction: Equatable {
    case start
    case stop
}

enum RecordingLifecycle: Equatable {
    case idle
    case starting
    case recording
    case stopping
    case interrupted
    case resuming

    var isCapturing: Bool {
        self == .recording
    }

    var presentsActiveControls: Bool {
        self == .recording || self == .interrupted || self == .resuming
    }

    var showsResume: Bool {
        self == .interrupted
    }

    mutating func beginResume() -> Bool {
        guard self == .interrupted else { return false }
        self = .resuming
        return true
    }

    mutating func requestToggle() -> RecordingLifecycleAction? {
        switch self {
        case .idle:
            self = .starting
            return .start
        case .recording, .interrupted:
            self = .stopping
            return .stop
        case .starting, .stopping, .resuming:
            return nil
        }
    }
}

enum TranscriptionVocabulary {
    static let maximumCharacters = 500

    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maximumCharacters))
    }
}
