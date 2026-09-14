import ActivityKit
import Foundation

struct GroqRecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let startedAt: Date
    }

    let sessionID: UUID
}
