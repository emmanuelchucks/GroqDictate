import Foundation

enum IOSAppStrings {
    enum Recording {
        static let ready = "Ready"
        static let recording = "Recording"
        static let paused = "Paused"
        static let resume = "Resume"
        static let resuming = "Resuming…"
        static let resumeMicBusy = "The mic is in use, maybe by a call. Tap Resume when it's free."
        static let resumeFailed = "Couldn't resume. Recording so far is saved."
        static let transcribing = "Transcribing"
        static let copied = "Copied"
        static let notTranscribed = "Not transcribed"
        static let delete = "Delete"
        static let deleteTitle = "Delete this recording?"
        static let deleteMessage = "Its audio and transcript are removed from this iPhone."
    }

    enum Transcription {
        static let pendingKey = "Add a Groq API key to transcribe"
        static let audioSafe = "Transcription stopped. Audio saved."
        static let retry = "Retry transcription"
        static let readyTapToCopy = "Tap to copy"
    }

    enum Errors {
        static let micDenied = "Mic access denied"
        static let micStopped = "Microphone stopped. Recording so far is saved."
        static let invalidKey = "Invalid API key"
        static let recordingTooLarge = "Recording too large"
        static let requestRejected = "Request rejected"
        static let couldntProcessAudio = "Couldn't process audio"
        static let serviceAtCapacity = "Service at capacity"
        static let networkUnavailable = "Check connection"
        static let groqUnavailable = "Groq unavailable"
        static let noSpeechDetected = "No speech detected"
        static let unreadableAudio = "This part's audio can't be read"
    }
}
