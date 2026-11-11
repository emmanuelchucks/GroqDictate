import Foundation

/// Local, bounded metadata only. Never accept arbitrary messages or error descriptions.
final class TimingDiagnostics: @unchecked Sendable {
    static let shared = TimingDiagnostics()
    enum Event: String, Codable {
        case launch, active, inactive, background
        case restorationStarted, restorationFinished
        case recordingStarted, recordingStartFailed, recordingStopped
        case interruptionBegan, routeLost, interruptionEnded, recordingResumed, resumeFailed
        case transcriptReady
        case attemptStarted, responseReceived, attemptSucceeded, attemptFailed, retryScheduled, transactionMetrics
    }
    struct Entry: Codable {
        let timestamp: Date
        let event: Event
        let requestID: UUID?
        let sessionID: UUID?
        let attempt: Int?
        let elapsedSeconds: Double?
        let code: Int?
        let audioSeconds: Double?
        let transaction: UploadMetricsDelegate.Transaction?
    }

    private let queue = DispatchQueue(label: "com.groqdictate.timing", qos: .utility)
    private let directory: URL?
    private let maximumBytes = 256 * 1024

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("GroqDictate/Diagnostics", isDirectory: true)
    }

    func record(_ event: Event, requestID: UUID? = nil, sessionID: UUID? = nil,
                attempt: Int? = nil, elapsedSeconds: Double? = nil, code: Int? = nil,
                audioSeconds: Double? = nil, transaction: UploadMetricsDelegate.Transaction? = nil) {
        let entry = Entry(timestamp: Date(), event: event, requestID: requestID,
                          sessionID: sessionID, attempt: attempt, elapsedSeconds: elapsedSeconds, code: code,
                          audioSeconds: audioSeconds, transaction: transaction)
        queue.async { self.append(entry) }
    }

    private func append(_ entry: Entry) {
        guard let directory else { return }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let current = directory.appendingPathComponent("timing.jsonl")
            let previous = directory.appendingPathComponent("timing-previous.jsonl")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(entry)
            data.append(0x0a)
            let size = (try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size + data.count > maximumBytes {
                if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
                try fm.moveItem(at: current, to: previous)
            }
            if !fm.fileExists(atPath: current.path) { fm.createFile(atPath: current.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Diagnostics must never affect recording or transcription.
        }
    }

    func flush() { queue.sync {} }
}
