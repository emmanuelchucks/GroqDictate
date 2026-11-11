import Foundation

actor SessionStore {
    enum StoreError: LocalizedError {
        case sessionNotFound

        var errorDescription: String? { "Recording session not found" }
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, rootURL: URL? = nil) throws {
        self.fileManager = fileManager
        let base = try rootURL ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.rootURL = base.appendingPathComponent("GroqDictate/Sessions", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    func createSession() throws -> RecordingSession {
        let session = RecordingSession()
        try fileManager.createDirectory(at: directory(for: session.id), withIntermediateDirectories: true)
        return try save(session)
    }

    /// Applies `change` to the latest saved copy. Every write goes through
    /// here so concurrent writers can't overwrite each other's changes.
    @discardableResult
    func update(
        _ id: UUID,
        _ change: @Sendable (inout RecordingSession) throws -> Void
    ) throws -> RecordingSession {
        var session = try load(id)
        try change(&session)
        return try save(session)
    }

    func delete(_ id: UUID) throws {
        try fileManager.removeItem(at: directory(for: id))
    }

    @discardableResult
    private func save(_ session: RecordingSession) throws -> RecordingSession {
        var value = session
        value.updatedAt = Date()
        let data = try encoder.encode(value)
        try data.write(to: manifestURL(for: value.id), options: .atomic)
        return value
    }

    func load(_ id: UUID) throws -> RecordingSession {
        guard fileManager.fileExists(atPath: manifestURL(for: id).path) else {
            throw StoreError.sessionNotFound
        }
        return try decoder.decode(RecordingSession.self, from: Data(contentsOf: manifestURL(for: id)))
    }

    func loadAll() throws -> [RecordingSession] {
        let directories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try directories.compactMap { url in
            let manifest = url.appendingPathComponent("session.json")
            guard fileManager.fileExists(atPath: manifest.path) else { return nil }
            return try decoder.decode(RecordingSession.self, from: Data(contentsOf: manifest))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func recoverInterruptedSessions() throws -> [RecordingSession] {
        var sessions = try loadAll()
        for sessionIndex in sessions.indices {
            var changed = false
            for segmentIndex in sessions[sessionIndex].segments.indices {
                let segmentState = sessions[sessionIndex].segments[segmentIndex].state
                let fileURL = audioURL(
                    sessionID: sessions[sessionIndex].id,
                    fileName: sessions[sessionIndex].segments[segmentIndex].fileName
                )
                let contentState = fileContentState(fileURL)
                let isDefinitelyEmpty = contentState == .missing || contentState == .empty

                switch segmentState {
                case .recording:
                    sessions[sessionIndex].segments[segmentIndex].endedAt = Date()
                    sessions[sessionIndex].segments[segmentIndex].state = isDefinitelyEmpty ? .unavailable : .pending
                    sessions[sessionIndex].segments[segmentIndex].lastError = isDefinitelyEmpty ? "This segment was not recorded" : nil
                    changed = true
                case .transcribing:
                    sessions[sessionIndex].segments[segmentIndex].state = isDefinitelyEmpty ? .unavailable : .pending
                    sessions[sessionIndex].segments[segmentIndex].lastError = isDefinitelyEmpty ? "This segment was not recorded" : nil
                    changed = true
                case .pending where isDefinitelyEmpty, .failed where isDefinitelyEmpty:
                    sessions[sessionIndex].segments[segmentIndex].state = .unavailable
                    sessions[sessionIndex].segments[segmentIndex].lastError = "This segment was not recorded"
                    changed = true
                case .pending, .complete, .failed, .unavailable:
                    break
                }
            }
            // Nothing records or uploads after a relaunch, so every session's
            // state follows from its parts.
            let recoveredState = sessions[sessionIndex].pendingCount > 0
                ? RecordingSession.State.failed
                : sessions[sessionIndex].finishedState
            if sessions[sessionIndex].state != recoveredState {
                sessions[sessionIndex].state = recoveredState
                changed = true
            }
            if changed { sessions[sessionIndex] = try save(sessions[sessionIndex]) }
        }
        return sessions
    }

    nonisolated func audioURL(sessionID: UUID, fileName: String) -> URL {
        directory(for: sessionID).appendingPathComponent(fileName)
    }

    func hasAudio(sessionID: UUID, fileName: String) -> Bool {
        fileHasContent(audioURL(sessionID: sessionID, fileName: fileName))
    }

    private nonisolated func directory(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func manifestURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("session.json")
    }

    private enum FileContentState {
        case missing
        case empty
        case content
        case unknown
    }

    private func fileContentState(_ url: URL) -> FileContentState {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize
        else { return .unknown }
        return size > 0 ? .content : .empty
    }

    private func fileHasContent(_ url: URL) -> Bool {
        fileContentState(url) == .content
    }
}
