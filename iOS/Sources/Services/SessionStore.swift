import AVFoundation
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
                    // The app was killed mid-part. The part ends where its audio
                    // does; without a whole frame it was never recorded.
                    let segment = sessions[sessionIndex].segments[segmentIndex]
                    // Unreadable now means unreadable later: nothing to send.
                    let audio = recordedAudio(sessionID: sessions[sessionIndex].id, segment: segment)
                    sessions[sessionIndex].segments[segmentIndex].end(recorded: audio ?? RecordedAudio(seconds: 0, frames: 0))
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

    /// Ends the live part at the last whole frame the recorder has written
    /// and starts the next part in the same file. They share that frame: AAC
    /// frames overlap when decoded, so each part's edge decodes cleanly. Nil
    /// when the part isn't recording any more or nothing new is on disk. One
    /// step in the store, so a pause or Stop can't end the part in between.
    func rollOver(sessionID: UUID, partID: UUID) throws -> (session: RecordingSession, next: RecordingSession.Segment)? {
        var session = try load(sessionID)
        guard let index = session.segments.firstIndex(where: { $0.id == partID }),
              session.segments[index].state == .recording,
              let data = bytes(sessionID: sessionID, segment: session.segments[index])
        else { return nil }
        let part = session.segments[index]
        let frames = ADTS.wholeFrames(in: data)
        // A part after the first starts with the shared frame.
        guard frames.count > (part.startByte == nil ? 1 : 2) else { return nil }
        let start = part.startByte ?? 0
        let endedAt = part.startedAt.addingTimeInterval(frames.seconds)
        session.segments[index].endByte = start + frames.byteCount
        session.segments[index].endedAt = endedAt
        session.segments[index].state = .pending
        session.segments[index].lastError = nil
        let next = RecordingSession.Segment.following(
            part, in: session,
            at: start + frames.lastFrameStart,
            startedAt: endedAt.addingTimeInterval(-frames.lastFrameSeconds)
        )
        session.segments.append(next)
        return (try save(session), next)
    }

    /// The audio in the part so far; nil when its file exists but can't be
    /// read.
    func recordedAudio(sessionID: UUID, segment: RecordingSession.Segment) -> RecordedAudio? {
        let url = audioURL(sessionID: sessionID, fileName: segment.fileName)
        guard fileContentState(url) == .content else { return RecordedAudio(seconds: 0, frames: 0) }
        if segment.startByte != nil || segment.endByte != nil {
            return bytes(sessionID: sessionID, segment: segment).map {
                let frames = ADTS.wholeFrames(in: $0)
                return RecordedAudio(seconds: frames.seconds, frames: frames.count)
            }
        }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return RecordedAudio(seconds: Double(file.length) / file.processingFormat.sampleRate, frames: nil)
    }

    /// A file holding just this part's audio. A part that is a whole file
    /// (a take with one part, or a recording from before takes) is the file
    /// itself; a part of a longer take is copied out to a temporary file,
    /// which the caller deletes.
    func partAudio(sessionID: UUID, segment: RecordingSession.Segment) throws -> (url: URL, isCopy: Bool) {
        let fileURL = audioURL(sessionID: sessionID, fileName: segment.fileName)
        guard segment.startByte != nil || segment.endByte != nil else { return (fileURL, false) }
        guard let data = bytes(sessionID: sessionID, segment: segment) else { throw CocoaError(.fileReadUnknown) }
        let copy = fileManager.temporaryDirectory.appendingPathComponent("groqdictate-part-\(UUID().uuidString).aac")
        try data.prefix(ADTS.wholeFrames(in: data).byteCount).write(to: copy)
        return (copy, true)
    }

    private func bytes(sessionID: UUID, segment: RecordingSession.Segment) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: audioURL(sessionID: sessionID, fileName: segment.fileName)) else {
            return nil
        }
        defer { try? handle.close() }
        do {
            let start = segment.startByte ?? 0
            try handle.seek(toOffset: UInt64(start))
            if let end = segment.endByte {
                return try handle.read(upToCount: max(0, end - start)) ?? Data()
            }
            return try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
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
