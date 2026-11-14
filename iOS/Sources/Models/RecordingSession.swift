import Foundation

struct RecordingSession: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        case recording
        case interrupted
        case processing
        case complete
        case failed
    }

    struct Segment: Codable, Identifiable, Equatable {
        enum State: String, Codable {
            case recording
            case pending
            case transcribing
            case complete
            case failed
            case unavailable
        }

        let id: UUID
        let index: Int
        /// The take's file. A take is one run of the recorder, from Record
        /// or Resume to Stop or a pause, and its parts share its file.
        let fileName: String
        /// Where the part starts and ends in the file; nil is the file's
        /// start or end. Older recordings have a file per part.
        let startByte: Int?
        var endByte: Int?
        let startedAt: Date
        var endedAt: Date?
        var state: State
        /// Cleaned text: phantom phrases over silence removed.
        var transcript: String?
        /// Groq's text before cleaning, so a wrong removal can be recovered.
        var rawTranscript: String?
        var lastError: String?

        init(index: Int, fileName: String, startByte: Int? = nil, startedAt: Date = Date()) {
            id = UUID()
            self.index = index
            self.fileName = fileName
            self.startByte = startByte
            endByte = nil
            self.startedAt = startedAt
            endedAt = nil
            state = .recording
            transcript = nil
            rawTranscript = nil
            lastError = nil
        }

        /// Ends a part whose recorder has stopped, from the audio it holds
        /// (nil: the file couldn't be read, so Groq judges it).
        mutating func end(recorded audio: RecordedAudio?, at now: Date = Date()) {
            lastError = nil
            guard let audio else {
                endedAt = now
                state = .pending
                return
            }
            endedAt = startedAt.addingTimeInterval(audio.seconds)
            if audio.seconds == 0 {
                state = .unavailable
                lastError = "This segment was not recorded"
            } else if startByte != nil, audio.frames == 1 {
                // Only the frame shared with the part before: the recorder
                // stopped just after a rollover, so nothing is missing.
                transcript = ""
                state = .complete
            } else {
                state = .pending
            }
        }

        /// The first part of a new take. Takes are raw AAC (ADTS): every
        /// frame stands alone, so a take cut off by the app being killed is
        /// readable up to the cut, and a finished part can be read while the
        /// recorder is still writing the next one. Groq doesn't take ADTS, so
        /// uploads repackage each part as M4A first.
        static func firstOfTake(in session: RecordingSession) -> Segment {
            let takes = Set(session.segments.map(\.fileName)).count
            return Segment(index: session.segments.count, fileName: String(format: "take-%02d.aac", takes + 1))
        }

        /// The part after `previous` in the same take, from `byte` on.
        static func following(_ previous: Segment, in session: RecordingSession, at byte: Int, startedAt: Date) -> Segment {
            Segment(index: session.segments.count, fileName: previous.fileName, startByte: byte, startedAt: startedAt)
        }
    }

    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var state: State
    var segments: [Segment]
    var transcript: String

    init(id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.createdAt = createdAt
        updatedAt = createdAt
        state = .recording
        segments = []
        transcript = ""
    }

    var duration: TimeInterval {
        segments.reduce(0) { total, segment in
            total + (segment.endedAt ?? Date()).timeIntervalSince(segment.startedAt)
        }
    }

    var assembledTranscript: String {
        segments
            .sorted { $0.index < $1.index }
            .compactMap(\.transcript)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Groq's text before cleaning, for when cleaning removed something.
    var originalTranscript: String? {
        let parts = segments.sorted { $0.index < $1.index }
        guard parts.contains(where: { $0.rawTranscript != nil && $0.rawTranscript != $0.transcript }) else { return nil }
        return parts
            .compactMap { $0.rawTranscript ?? $0.transcript }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Parts that were never recorded don't stop the rest from completing.
    var finishedState: State {
        let recorded = segments.filter { $0.state != .unavailable }
        return !recorded.isEmpty && recorded.allSatisfy { $0.state == .complete } ? .complete : .failed
    }

    var pendingCount: Int {
        segments.filter { $0.state == .pending || $0.state == .failed }.count
    }
}

/// Audio in a part: whole AAC frames for a part of a take; for a part that is
/// a whole file, its readable length (frames unknown).
struct RecordedAudio: Equatable {
    let seconds: TimeInterval
    let frames: Int?
}
