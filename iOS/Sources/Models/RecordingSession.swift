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
        let fileName: String
        let startedAt: Date
        var endedAt: Date?
        var state: State
        /// Cleaned text: phantom phrases over silence removed.
        var transcript: String?
        /// Groq's text before cleaning, so a wrong removal can be recovered.
        var rawTranscript: String?
        /// Recorded with a Bluetooth mic at some point; nil for older parts.
        var bluetoothInput: Bool?
        var lastError: String?

        init(index: Int, fileName: String, startedAt: Date = Date()) {
            id = UUID()
            self.index = index
            self.fileName = fileName
            self.startedAt = startedAt
            endedAt = nil
            state = .recording
            transcript = nil
            rawTranscript = nil
            lastError = nil
        }

        /// Parts are raw AAC (ADTS): every frame stands alone, so a part cut
        /// off by the app being killed is still readable up to the cut. Groq
        /// doesn't take ADTS, so uploads repackage it as M4A first.
        static func next(in session: RecordingSession) -> Segment {
            let index = session.segments.count
            return Segment(index: index, fileName: String(format: "segment-%04d.aac", index + 1))
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
