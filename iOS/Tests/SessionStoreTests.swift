import AVFoundation
import XCTest
@testable import GroqDictateIOS

final class SessionStoreTests: XCTestCase {
    private var rootURL: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        store = try SessionStore(rootURL: rootURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func testSessionAndPendingSegmentRoundTrip() async throws {
        var session = try await store.createSession()
        var segment = RecordingSession.Segment(index: 0, fileName: "segment-0001.m4a")
        segment.state = .pending
        segment.endedAt = Date()
        session.segments.append(segment)
        session.state = .processing
        try await store.update(session.id) { [session] stored in stored = session }

        let loaded = try await store.load(session.id)
        XCTAssertEqual(loaded.id, session.id)
        XCTAssertEqual(loaded.segments.first?.state, .pending)
        XCTAssertEqual(loaded.pendingCount, 1)
    }

    func testConcurrentUpdatesToDifferentSegmentsAllPersist() async throws {
        let session = try await store.createSession()
        for _ in 0..<20 {
            try await store.update(session.id) { session in let next = RecordingSession.Segment.next(in: session); session.segments.append(next) }
        }
        let segmentIDs = try await store.load(session.id).segments.map(\.id)
        await withThrowingTaskGroup(of: Void.self) { group in
            for (offset, segmentID) in segmentIDs.enumerated() {
                group.addTask { [store] in
                    try await store!.update(session.id) { session in
                        let index = session.segments.firstIndex { $0.id == segmentID }!
                        session.segments[index].state = .complete
                        session.segments[index].transcript = "part \(offset)"
                    }
                }
            }
        }

        let loaded = try await store.load(session.id)
        XCTAssertTrue(loaded.segments.allSatisfy { $0.state == .complete })
        XCTAssertEqual(loaded.assembledTranscript, (0..<20).map { "part \($0)" }.joined(separator: " "))
    }

    func testDeleteRemovesSessionAndAudio() async throws {
        var session = try await store.createSession()
        session = try await store.update(session.id) { session in let next = RecordingSession.Segment.next(in: session); session.segments.append(next) }
        let audioURL = store.audioURL(sessionID: session.id, fileName: session.segments[0].fileName)
        try Data([1, 2, 3]).write(to: audioURL)

        try await store.delete(session.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        let all = try await store.loadAll()
        XCTAssertFalse(all.contains { $0.id == session.id })
    }

    func testRecoveryFinishesASessionKilledAfterItsLastPartCompleted() async throws {
        var session = try await store.createSession()
        var done = RecordingSession.Segment(index: 0, fileName: "segment-0001.m4a")
        done.state = .complete
        done.transcript = "Hello."
        done.endedAt = Date()
        var lost = RecordingSession.Segment(index: 1, fileName: "segment-0002.m4a")
        lost.state = .unavailable
        session.segments = [done, lost]
        session.state = .processing
        try await store.update(session.id) { [session] stored in stored = session }
        let audioURL = store.audioURL(sessionID: session.id, fileName: done.fileName)
        try Data([1, 2, 3]).write(to: audioURL)

        let recovered = try await store.recoverInterruptedSessions()
        let value = try XCTUnwrap(recovered.first { $0.id == session.id })
        XCTAssertEqual(value.state, .complete, "a part that was never recorded doesn't block completion")
    }

    func testPartCutOffByAKillIsRecoveredUpToTheCut() async throws {
        var session = try await store.createSession()
        let segment = RecordingSession.Segment(index: 0, fileName: "segment-0001.aac", startedAt: Date(timeIntervalSinceNow: -3600))
        session.segments.append(segment)
        try await store.update(session.id) { [session] stored in stored = session }
        let audioURL = store.audioURL(sessionID: session.id, fileName: segment.fileName)
        try Self.writeAAC(seconds: 4, to: audioURL)
        let full = try Data(contentsOf: audioURL)
        try full.prefix(full.count / 2).write(to: audioURL)

        let recovered = try await store.recoverInterruptedSessions()
        let value = try XCTUnwrap(recovered.first { $0.id == session.id })
        let part = try XCTUnwrap(value.segments.first)
        XCTAssertEqual(value.state, .failed)
        XCTAssertEqual(part.state, .pending)
        XCTAssertEqual(value.pendingCount, 1)
        let seconds = try XCTUnwrap(part.endedAt).timeIntervalSince(part.startedAt)
        XCTAssertGreaterThan(seconds, 1, "the half before the cut is still readable")
        XCTAssertLessThan(seconds, 3, "the part ends where its audio does, not at relaunch")
    }

    func testPartWithNoReadableAudioIsMarkedNotRecorded() async throws {
        var session = try await store.createSession()
        let segment = RecordingSession.Segment(index: 0, fileName: "segment-0001.aac")
        session.segments.append(segment)
        try await store.update(session.id) { [session] stored in stored = session }
        try Data([1, 2, 3]).write(to: store.audioURL(sessionID: session.id, fileName: segment.fileName))

        let recovered = try await store.recoverInterruptedSessions()
        let value = try XCTUnwrap(recovered.first { $0.id == session.id })
        XCTAssertEqual(value.segments.first?.state, .unavailable)
        XCTAssertEqual(value.pendingCount, 0)
    }

    /// Raw AAC (ADTS), like the recorder writes for a `.aac` URL.
    private static func writeAAC(seconds: Double, to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ])
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) {
            samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 16_000)) * 0.3
        }
        try file.write(from: buffer)
    }

    func testRecoveryMarksMissingAudioAsNonRetryable() async throws {
        var session = try await store.createSession()
        var segment = RecordingSession.Segment(index: 0, fileName: "segment-0001.m4a")
        segment.state = .failed
        segment.endedAt = Date()
        segment.lastError = "Network unavailable"
        session.segments.append(segment)
        session.state = .failed
        try await store.update(session.id) { [session] stored in stored = session }

        let recovered = try await store.recoverInterruptedSessions()
        let value = try XCTUnwrap(recovered.first { $0.id == session.id })
        XCTAssertEqual(value.state, .failed)
        XCTAssertEqual(value.segments.first?.state, .unavailable)
        XCTAssertEqual(value.segments.first?.lastError, "This segment was not recorded")
        XCTAssertEqual(value.pendingCount, 0)
    }

    func testRecoveryKeepsAudioBearingPendingSegmentPendingAcrossRepeatedRuns() async throws {
        var session = try await store.createSession()
        var segment = RecordingSession.Segment(index: 0, fileName: "segment-0001.m4a")
        segment.state = .pending
        segment.endedAt = Date()
        session.segments.append(segment)
        session.state = .failed
        try await store.update(session.id) { [session] stored in stored = session }
        let audioURL = store.audioURL(sessionID: session.id, fileName: segment.fileName)
        try Data([1, 2, 3]).write(to: audioURL)

        _ = try await store.recoverInterruptedSessions()
        let recoveredAgain = try await store.recoverInterruptedSessions()
        let value = try XCTUnwrap(recoveredAgain.first { $0.id == session.id })
        XCTAssertEqual(value.segments.first?.state, .pending)
        XCTAssertEqual(value.pendingCount, 1)
    }

    func testRecoveryRetriesUploadInterruptedByRelaunch() async throws {
        var session = try await store.createSession()
        var segment = RecordingSession.Segment(index: 0, fileName: "segment-0001.m4a")
        segment.state = .transcribing
        segment.endedAt = Date()
        session.segments.append(segment)
        session.state = .processing
        try await store.update(session.id) { [session] stored in stored = session }
        let audioURL = store.audioURL(sessionID: session.id, fileName: segment.fileName)
        try Data([1, 2, 3]).write(to: audioURL)

        let recovered = try await store.recoverInterruptedSessions()
        let value = try XCTUnwrap(recovered.first { $0.id == session.id })
        XCTAssertEqual(value.state, .failed)
        XCTAssertEqual(value.segments.first?.state, .pending)
        XCTAssertEqual(value.pendingCount, 1)
    }

}
