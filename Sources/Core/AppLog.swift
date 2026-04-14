import Foundation
import OSLog

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

    enum Level: String {
        case audit
        case debug
        case event
        case error
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.groqdictate"

    static func audit(
        _ message: @autoclosure () -> String,
        category: Category = .app,
        metadata: [String: String]? = nil
    ) {
        write(level: .audit, message: message(), category: category, metadata: metadata)
    }

    static func debug(
        _ message: @autoclosure () -> String,
        category: Category = .app,
        metadata: [String: String]? = nil
    ) {
        guard AppConstants.Diagnostics.debugLoggingEnabled else { return }
        write(level: .debug, message: message(), category: category, metadata: metadata)
    }

    static func event(
        _ message: @autoclosure () -> String,
        category: Category = .app,
        metadata: [String: String]? = nil
    ) {
        write(level: .event, message: message(), category: category, metadata: metadata)
    }

    static func error(
        _ message: @autoclosure () -> String,
        category: Category = .app,
        metadata: [String: String]? = nil
    ) {
        write(level: .error, message: message(), category: category, metadata: metadata)
    }

    static func metric(
        _ name: String,
        category: Category = .app,
        level: Level = .event,
        values: [String: String]
    ) {
        let summary = ([("metric", name)] + values.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) })
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: " ")
        write(
            level: level,
            message: summary,
            category: category,
            metadata: ["metric": name].merging(values, uniquingKeysWith: { _, new in new })
        )
    }

    private static func write(level: Level, message: String, category: Category, metadata: [String: String]? = nil) {
        let sanitizedMessage = DiagnosticsStore.sanitize(message)
        let sanitizedMetadata = DiagnosticsStore.sanitize(metadata)

        logToUnifiedLogging(level: level, message: sanitizedMessage, category: category)
        DiagnosticsStore.record(
            level: level.rawValue,
            category: category.rawValue,
            message: sanitizedMessage,
            metadata: sanitizedMetadata
        )
    }

    private static func logToUnifiedLogging(level: Level, message: String, category: Category) {
        let logger = Logger(subsystem: subsystem, category: category.rawValue)

        switch level {
        case .audit:
            logger.notice("\(message, privacy: .public)")
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .event:
            logger.notice("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }
}

enum DiagnosticsStore {
    struct Entry: Codable {
        let schemaVersion: Int
        let timestamp: String
        let source: String
        let category: String
        let level: String
        let message: String
        let metadata: [String: String]?
    }

    private static let schemaVersion = 2
    private static let lock = NSLock()
    private static let runID = UUID().uuidString
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let timestampFormatter = ISO8601DateFormatter()
    private static var preparedStore = false

    static func record(
        level: String,
        category: String,
        message: String,
        metadata: [String: String]? = nil,
        source: String = "runtime"
    ) {
        lock.lock()
        defer { lock.unlock() }

        prepareStoreIfNeededLocked()

        let entry = Entry(
            schemaVersion: schemaVersion,
            timestamp: timestampFormatter.string(from: Date()),
            source: source,
            category: category,
            level: level,
            message: sanitize(message),
            metadata: sanitize(mergedMetadata(metadata))
        )
        appendEntryLocked(entry)
    }

    static func sanitize(_ message: String) -> String {
        var value = message

        value = replacingMatches(
            in: value,
            pattern: #"gsk_[A-Za-z0-9_-]+"#,
            template: "gsk_[redacted]"
        )
        value = replacingMatches(
            in: value,
            pattern: #"text=.*$"#,
            template: "text=<redacted>"
        )
        value = replacingMatches(
            in: value,
            pattern: #"message=.*$"#,
            template: "message=<redacted>"
        )
        value = replacingMatches(
            in: value,
            pattern: #"/(?:Users|private|var|tmp|Applications|System|Library)[^\s)]*"#,
            template: "<path>"
        )

        return value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitize(_ metadata: [String: String]?) -> [String: String]? {
        guard let metadata else { return nil }

        var sanitized: [String: String] = [:]
        for (key, value) in metadata {
            sanitized[key] = sanitize(value)
        }
        return sanitized.isEmpty ? nil : sanitized
    }

    private static func mergedMetadata(_ metadata: [String: String]?) -> [String: String] {
        commonMetadata().merging(metadata ?? [:], uniquingKeysWith: { current, _ in current })
    }

    private static func commonMetadata() -> [String: String] {
        var metadata: [String: String] = [
            "run_id": runID,
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
            "build_config": buildConfigurationDescription(),
            "install_location": installLocationCategory()
        ]

        if let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            metadata["app_version"] = appVersion
        }
        if let buildVersion = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String {
            metadata["build_number"] = buildVersion
        }

        return metadata
    }

    private static func buildConfigurationDescription() -> String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    private static func installLocationCategory() -> String {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path

        if path.hasPrefix("/Applications/") {
            return "applications"
        }
        if path.contains("/DerivedData/") {
            return "derived_data"
        }
        return "other"
    }

    private static func prepareStoreIfNeededLocked() {
        guard !preparedStore else { return }

        do {
            try FileManager.default.createDirectory(
                at: AppConstants.Diagnostics.diagnosticsDirectory,
                withIntermediateDirectories: true
            )
            preparedStore = true
        } catch {
            // Avoid recursive logging while preparing diagnostics.
        }
    }

    private static func appendEntryLocked(_ entry: Entry) {
        let fm = FileManager.default
        let journalFile = AppConstants.Diagnostics.journalFile

        rotateIfNeededLocked(at: journalFile)

        if !fm.fileExists(atPath: journalFile.path) {
            fm.createFile(atPath: journalFile.path, contents: nil)
        }

        guard
            let data = try? encoder.encode(entry),
            let handle = try? FileHandle(forWritingTo: journalFile)
        else {
            return
        }

        defer { try? handle.close() }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
        } catch {
            // Avoid recursive logging while appending diagnostics.
        }
    }

    private static func rotateIfNeededLocked(at journalFile: URL) {
        let fm = FileManager.default
        guard
            let attrs = try? fm.attributesOfItem(atPath: journalFile.path),
            let size = attrs[.size] as? NSNumber,
            size.intValue >= AppConstants.Diagnostics.maxJournalBytes
        else {
            return
        }

        let rotated = journalFile.deletingPathExtension().appendingPathExtension("old.jsonl")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: journalFile, to: rotated)
    }

    private static func replacingMatches(in value: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }
}
