import Foundation

enum IOSAppStrings {
    enum Recording {
        static let ready = "Ready"
        static let recording = "Recording"
        static let pausedSafely = "Paused — audio safe"
        static let resume = "Resume"
    }

    enum Transcription {
        static let pendingKey = "Add your Groq API key — audio remains pending"
        static let audioSafe = "Transcription stopped — audio is safe"
        static let retry = "Retry transcription"
    }

    enum Errors {
        static let micDenied = "Mic access denied"
        static let micError = "Mic error"
        static let invalidKey = "Invalid API key"
        static let recordingTooLarge = "Recording too large"
        static let requestRejected = "Request rejected"
        static let couldntProcessAudio = "Couldn't process audio"
        static let serviceAtCapacity = "Service at capacity"
        static let networkUnavailable = "Check connection"
        static let groqUnavailable = "Groq unavailable"
        static let noSpeechDetected = "No speech detected"
    }
}
