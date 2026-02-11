import Foundation

enum AppConstants {
    enum URLs {
        static let groqAPIHost = URL(string: "https://api.groq.com")!
        static let groqTranscriptions = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        static let microphonePrivacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    }

    enum Accessibility {
        static let apiNotificationName = Notification.Name("com.apple.accessibility.api")
    }

    enum TempFiles {
        static let wav = "groqdictate.wav"
        static let flac = "groqdictate.flac"
    }
}
