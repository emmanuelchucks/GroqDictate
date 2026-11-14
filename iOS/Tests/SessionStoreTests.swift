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
            try await store.update(session.id) { session in let next = RecordingSession.Segment.firstOfTake(in: session); session.segments.append(next) }
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
        session = try await store.update(session.id) { session in let next = RecordingSession.Segment.firstOfTake(in: session); session.segments.append(next) }
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

    func testRolloverEndsAPartAtTheLastWholeFrameAndRecoveryEndsTheNextAtTheCut() async throws {
        let (session, first, take) = try await Self.takeBeingRecorded(in: store, seconds: 4)
        let url = store.audioURL(sessionID: session.id, fileName: first.fileName)
        let written = take.prefix(take.count / 2 + 3)
        try written.write(to: url)

        let rolledOver = try await store.rollOver(sessionID: session.id, partID: first.id)
        let rolled = try XCTUnwrap(rolledOver)
        let ended = rolled.session.segments[0]
        let frames = ADTS.wholeFrames(in: written)
        XCTAssertEqual(ended.state, .pending)
        XCTAssertEqual(ended.endByte, frames.byteCount, "a frame still being written goes to the next part")
        XCTAssertEqual(rolled.next.startByte, frames.lastFrameStart, "the parts share one frame")
        XCTAssertEqual(rolled.next.state, .recording)
        let noNewFrames = try await store.rollOver(sessionID: session.id, partID: rolled.next.id)
        XCTAssertNil(noNewFrames, "only the shared frame is on disk for the next part")

        try take.write(to: url)
        let recovered = try await store.recoverInterruptedSessions()
        let live = try XCTUnwrap(recovered.first { $0.id == session.id }?.segments.last)
        XCTAssertEqual(live.state, .pending)
        XCTAssertEqual(try XCTUnwrap(live.endedAt).timeIntervalSince(live.startedAt), 2, accuracy: 0.3)
    }

    func testPartEndedJustAfterARolloverHoldsNothingNew() async throws {
        let (session, first, _) = try await Self.takeBeingRecorded(in: store, seconds: 4)
        let rolledOver = try await store.rollOver(sessionID: session.id, partID: first.id)
        let rolled = try XCTUnwrap(rolledOver)
        var next = rolled.next
        next.end(recorded: await store.recordedAudio(sessionID: session.id, segment: next))
        XCTAssertEqual(next.state, .complete)
        XCTAssertEqual(next.transcript, "")
    }

    func testPartAudioIsTheFileForAWholeFilePartAndExactlyItsBytesForAPartOfATake() async throws {
        let (session, first, take) = try await Self.takeBeingRecorded(in: store, seconds: 4)
        let url = store.audioURL(sessionID: session.id, fileName: first.fileName)
        let whole = try await store.partAudio(sessionID: session.id, segment: first)
        XCTAssertEqual(whole.url, url)
        XCTAssertFalse(whole.isCopy)

        try take.prefix(take.count / 2).write(to: url)
        let rolledOver = try await store.rollOver(sessionID: session.id, partID: first.id)
        let rolled = try XCTUnwrap(rolledOver)
        try take.write(to: url)
        let ended = rolled.session.segments[0]
        for (part, bytes) in [
            (ended, take.prefix(try XCTUnwrap(ended.endByte))),
            (rolled.next, take.suffix(from: try XCTUnwrap(rolled.next.startByte))),
        ] {
            let copy = try await store.partAudio(sessionID: session.id, segment: part)
            defer { try? FileManager.default.removeItem(at: copy.url) }
            XCTAssertTrue(copy.isCopy)
            XCTAssertEqual(try Data(contentsOf: copy.url), Data(bytes))
            XCTAssertNotNil(try? AVAudioFile(forReading: copy.url), "each part reads as audio on its own")
        }
    }

    /// A session with one recording part and its take's audio, already on disk.
    private static func takeBeingRecorded(
        in store: SessionStore, seconds: Double
    ) async throws -> (RecordingSession, RecordingSession.Segment, Data) {
        var session = try await store.createSession()
        let first = RecordingSession.Segment.firstOfTake(in: session)
        session.segments.append(first)
        try await store.update(session.id) { [session] stored in stored = session }
        let url = store.audioURL(sessionID: session.id, fileName: first.fileName)
        try writeAAC(seconds: seconds, to: url)
        return (session, first, try Data(contentsOf: url))
    }

    func testARecordingSavedBeforeTakesStillLoads() throws {
        let json = #"""
        {"createdAt":"2026-11-12T19:25:22Z","id":"B2C67642-0000-4000-8000-000000000000","state":"complete",
         "transcript":"Hello.","updatedAt":"2026-11-12T19:30:25Z","segments":[
          {"bluetoothInput":false,"endedAt":"2026-11-12T19:30:23Z","fileName":"segment-0001.aac",
           "id":"0EB4C3F7-0000-4000-8000-000000000000","index":0,"rawTranscript":"Hello.",
           "startedAt":"2026-11-12T19:25:22Z","state":"complete","transcript":"Hello."}]}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(RecordingSession.self, from: Data(json.utf8))
        XCTAssertNil(session.segments[0].startByte)
        XCTAssertNil(session.segments[0].endByte)
        XCTAssertEqual(session.duration, 301)
    }

    func testASecondRolloverStartsFromTheSharedFrame() async throws {
        let (session, first, take) = try await Self.takeBeingRecorded(in: store, seconds: 6)
        let url = store.audioURL(sessionID: session.id, fileName: first.fileName)
        try take.prefix(take.count / 3).write(to: url)
        let one = try await store.rollOver(sessionID: session.id, partID: first.id)
        let second = try XCTUnwrap(one).next
        try take.prefix(2 * take.count / 3).write(to: url)
        let two = try await store.rollOver(sessionID: session.id, partID: second.id)
        let ended = try XCTUnwrap(two?.session.segments[1])
        XCTAssertEqual(ended.startByte, second.startByte)
        XCTAssertEqual(ended.endByte, ADTS.wholeFrames(in: take.prefix(2 * take.count / 3)).byteCount)
        XCTAssertEqual(try XCTUnwrap(ended.endedAt).timeIntervalSince(ended.startedAt), 2, accuracy: 0.3)
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
