import Foundation

enum AppConstants {
    enum URLs {
        static let groqAPIHost = URL(string: "https://api.groq.com")!
        static let groqTranscriptions = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        static let microphonePrivacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        static let projectGitHub = URL(string: "https://github.com/emmanuelchucks/GroqDictate")!
    }

    enum Accessibility {
        static let apiNotificationName = Notification.Name("com.apple.accessibility.api")
    }

    enum TempFiles {
        static let wav = "groqdictate.wav"
        static let flac = "groqdictate.flac"
    }

    enum Diagnostics {
        static let debugLoggingEnabled = ProcessInfo.processInfo.environment["GROQDICTATE_DEBUG"] == "1"
    }

    enum Timing {
        static let simulatedPasteDelay: TimeInterval = 0.05
        static let noticeDuration: TimeInterval = 1.2
    }
}
