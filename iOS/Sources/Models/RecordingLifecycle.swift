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

/// Whisper's prompt: the user's vocabulary, then the end of the previous
/// part so a part that starts mid-sentence continues it. Groq caps the prompt
/// at 224 tokens; hints are capped at 500 characters, and English runs about
/// four characters a token, so the tail stays short.
enum TranscriptionPrompt {
    static let previousTextCharacters = 200

    static func make(hints: String, previousText: String?) -> String {
        let tail = previousText.map(Self.tail) ?? ""
        return [hints, tail].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// On a silent part Whisper can return the prompt itself
    /// (github.com/openai/whisper/discussions/1606). Text long enough to be
    /// more than a stray word, found word for word in the prompt, is that echo.
    static func removingEcho(of prompt: String, from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20, prompt.contains(trimmed) else { return text }
        return ""
    }

    private static func tail(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > previousTextCharacters else { return trimmed }
        let suffix = trimmed.suffix(previousTextCharacters)
        guard let space = suffix.firstIndex(of: " ") else { return String(suffix) }
        return String(suffix[suffix.index(after: space)...])
    }
}

enum TranscriptionVocabulary {
    static let maximumCharacters = 500

    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maximumCharacters))
    }
}
