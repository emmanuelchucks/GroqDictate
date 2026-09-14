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
        try await store.save(session)

        let loaded = try await store.load(session.id)
        XCTAssertEqual(loaded.id, session.id)
        XCTAssertEqual(loaded.segments.first?.state, .pending)
        XCTAssertEqual(loaded.pendingCount, 1)
    }

    func testRecoveryPreservesRecordedFileAsPending() async throws {
        var session = try await store.createSession()
        let segment = RecordingSession.Segment(index: 0, fileName: "segment-0001.m4a")
        session.segments.append(segment)
        try await store.save(session)
        let audioURL = await store.audioURL(sessionID: session.id, fileName: segment.fileName)
        try Data([1, 2, 3]).write(to: audioURL)

        let recovered = try await store.recoverInterruptedSessions()
        let value = try XCTUnwrap(recovered.first { $0.id == session.id })
        XCTAssertEqual(value.state, .interrupted)
        XCTAssertEqual(value.segments.first?.state, .pending)
    }

    func testRecoveryMarksMissingAudioAsNonRetryable() async throws {
        var session = try await store.createSession()
        var segment = RecordingSession.Segment(index: 0, fileName: "segment-0001.m4a")
        segment.state = .failed
        segment.endedAt = Date()
        segment.lastError = "Network unavailable"
        session.segments.append(segment)
        session.state = .failed
        try await store.save(session)

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
        try await store.save(session)
        let audioURL = await store.audioURL(sessionID: session.id, fileName: segment.fileName)
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
        try await store.save(session)
        let audioURL = await store.audioURL(sessionID: session.id, fileName: segment.fileName)
        try Data([1, 2, 3]).write(to: audioURL)

        let recovered = try await store.recoverInterruptedSessions()
        let value = try XCTUnwrap(recovered.first { $0.id == session.id })
        XCTAssertEqual(value.state, .failed)
        XCTAssertEqual(value.segments.first?.state, .pending)
        XCTAssertEqual(value.pendingCount, 1)
    }

}
