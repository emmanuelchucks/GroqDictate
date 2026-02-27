import Foundation

enum AppStrings {
    enum App {
        static let name = "GroqDictate"
        static let iconAccessibilityDescription = "GroqDictate"
    }

    enum Menu {
        static let triggerHint = "Right ⌘ — start / stop"
        static let cancelHint = "Esc — cancel"
        static let about = "About GroqDictate"
        static let settings = "Settings…"
        static let quit = "Quit GroqDictate"
    }

    enum About {
        static let title = "GroqDictate"
        static let github = "GitHub"
        static let dismiss = "OK"
        static let shortcutsTitle = "Shortcuts"
        static let triggerShortcut = "Right ⌘  Start/stop"
        static let cancelShortcut = "Esc  Cancel/dismiss"
    }

    enum EditMenu {
        static let title = "Edit"
        static let undo = "Undo"
        static let redo = "Redo"
        static let cut = "Cut"
        static let copy = "Copy"
        static let paste = "Paste"
        static let selectAll = "Select All"
    }

    enum Panel {
        static let recording = "● Recording"
        static let transcribing = "⟳ Transcribing…"
        static let copiedToClipboard = "✓ Copied to clipboard"
        static let clipboardWriteFailed = "⚠ Clipboard unavailable"
        static let escCancel = "esc to cancel"
        static let escDismiss = "esc to dismiss"
        static let retry = "⌘ retry"
        static let newRecording = "⌘ new"
        static let settings = "⌘ settings"
    }

    enum Setup {
        static let title = "GroqDictate Settings"
        static let apiKeyLabel = "OpenAI API Key"
        static let micLabel = "Microphone"
        static let inputGainLabel = "Input Gain"
        static let keyHint = "From platform.openai.com → Stored in Keychain"
        static let done = "Done"
        static let systemDefaultMic = "System Default"

        static let keyEmpty = "API key cannot be empty."
        static func keychainError(_ message: String) -> String { "Keychain error: \(message)" }
    }

    enum Errors {
        static let micDenied = "Mic access denied"
        static let micError = "Mic error"
        static let invalidKey = "Invalid API key"
        static let orgRestricted = "Organization restricted"
        static let resourceNotFound = "Resource not found"
        static let tryAgain = "Try again"
        static let recordingTooLarge = "Recording too large"
    }
}
