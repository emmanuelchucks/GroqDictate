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
        var transcript: String?
        var lastError: String?

        init(index: Int, fileName: String, startedAt: Date = Date()) {
            id = UUID()
            self.index = index
            self.fileName = fileName
            self.startedAt = startedAt
            endedAt = nil
            state = .recording
            transcript = nil
            lastError = nil
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

    var pendingCount: Int {
        segments.filter { $0.state == .pending || $0.state == .failed }.count
    }
}
