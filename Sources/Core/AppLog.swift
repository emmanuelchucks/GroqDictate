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
    private static let lock = NSLock()

    static func debug(_ message: @autoclosure () -> String, category: Category = .app) {
        guard AppConstants.Diagnostics.debugLoggingEnabled else { return }
        write(level: "debug", message: message(), category: category)
    }

    static func event(_ message: @autoclosure () -> String, category: Category = .app) {
        write(level: "event", message: message(), category: category)
    }

    static func error(_ message: @autoclosure () -> String, category: Category = .app) {
        write(level: "error", message: message(), category: category)
    }

    private static func write(level: String, message: String, category: Category) {
        let line = "\(prefix)[\(category.rawValue)][\(level)]: \(message)"
        NSLog("%@", line)
        appendToFile(line)
    }

    private static func appendToFile(_ line: String) {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        let logDirectory = AppConstants.Diagnostics.logDirectory
        let logFile = AppConstants.Diagnostics.logFile

        do {
            try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            rotateIfNeeded(at: logFile)

            if !fm.fileExists(atPath: logFile.path) {
                fm.createFile(atPath: logFile.path, contents: nil)
            }

            let handle = try FileHandle(forWritingTo: logFile)
            defer { try? handle.close() }
            try handle.seekToEnd()

            let timestamp = ISO8601DateFormatter().string(from: Date())
            if let data = "\(timestamp) \(line)\n".data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            // Avoid recursive logging path here.
        }
    }

    private static func rotateIfNeeded(at logFile: URL) {
        let fm = FileManager.default
        guard
            let attrs = try? fm.attributesOfItem(atPath: logFile.path),
            let size = attrs[.size] as? NSNumber,
            size.intValue >= AppConstants.Diagnostics.maxLogBytes
        else { return }

        let rotated = logFile.deletingPathExtension().appendingPathExtension("old.log")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: logFile, to: rotated)
    }
}
