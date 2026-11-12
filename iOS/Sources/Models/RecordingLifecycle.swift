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

/// Whisper's prompt: the end of the previous part, so a part that starts
/// mid-sentence continues it. On the user's recordings it also halved the
/// phantom "thank you"s (docs/transcript-cleanup.md). Groq caps the prompt at
/// 224 tokens; English runs about four characters a token.
enum TranscriptionPrompt {
    static let previousTextCharacters = 200

    static func make(previousText: String?) -> String {
        previousText.map(Self.tail) ?? ""
    }

    private static func tail(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > previousTextCharacters else { return trimmed }
        let suffix = trimmed.suffix(previousTextCharacters)
        guard let space = suffix.firstIndex(of: " ") else { return String(suffix) }
        return String(suffix[suffix.index(after: space)...])
    }
}
