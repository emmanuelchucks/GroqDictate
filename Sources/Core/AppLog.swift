import Foundation

enum AppLog {
    enum Category: String {
        case app
        case network
        case audio
        case focus
        case hotkey
        case ui
        case animation
    }

    private static let prefix = "GroqDictate"

    static func debug(_ message: @autoclosure () -> String, category: Category = .app) {
        guard AppConstants.Diagnostics.debugLoggingEnabled else { return }
        NSLog("\(prefix)[\(category.rawValue)]: \(message())")
    }

    static func event(_ message: @autoclosure () -> String, category: Category = .app) {
        NSLog("\(prefix)[\(category.rawValue)]: \(message())")
    }

    static func error(_ message: @autoclosure () -> String, category: Category = .app) {
        NSLog("\(prefix)[\(category.rawValue)]: \(message())")
    }
}
