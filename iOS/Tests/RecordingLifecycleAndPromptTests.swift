import XCTest
@testable import GroqDictateIOS

final class RecordingLifecycleAndPromptTests: XCTestCase {
    func testNormalStopTransitionsAwayFromResumeStateBeforeAsyncWork() {
        var lifecycle = RecordingLifecycle.recording

        XCTAssertEqual(lifecycle.requestToggle(), .stop)
        XCTAssertEqual(lifecycle, .stopping)
        XCTAssertFalse(lifecycle.showsResume)
        XCTAssertFalse(lifecycle.presentsActiveControls)

        XCTAssertTrue(RecordingLifecycle.interrupted.showsResume)
        XCTAssertTrue(RecordingLifecycle.interrupted.presentsActiveControls)
    }

    func testRecordingDurationsStayCompactUntilAnHour() {
        XCTAssertEqual(TimeInterval(5).formattedDuration, "0:05")
        XCTAssertEqual(TimeInterval(754).formattedDuration, "12:34")
        XCTAssertEqual(TimeInterval(3_723).formattedDuration, "1:02:03")
    }

    func testVocabularyNormalizationTrimsAndEnforcesUIBudget() {
        let oversized = "  " + String(repeating: "a", count: TranscriptionVocabulary.maximumCharacters + 25) + "  "
        let normalized = TranscriptionVocabulary.normalized(oversized)

        XCTAssertEqual(normalized.count, TranscriptionVocabulary.maximumCharacters)
        XCTAssertFalse(normalized.hasPrefix(" "))
        XCTAssertFalse(normalized.hasSuffix(" "))
    }

    func testMultipartBodyIncludesVocabularyPromptExactlyOnce() throws {
        let body = GroqIOSClient.makeMultipartBody(
            fileData: Data("audio".utf8),
            model: "whisper-large-v3",
            prompt: "Groq, GroqDictate, XcodeGen",
            boundary: "TestBoundary"
        )
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertEqual(text.components(separatedBy: "name=\"prompt\"").count - 1, 1)
        XCTAssertTrue(text.contains("\r\n\r\nGroq, GroqDictate, XcodeGen\r\n"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"segment.m4a\""))
    }

    func testMultipartBodyOmitsEmptyPrompt() throws {
        let body = GroqIOSClient.makeMultipartBody(
            fileData: Data("audio".utf8),
            model: "whisper-large-v3",
            prompt: "",
            boundary: "TestBoundary"
        )
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertFalse(text.contains("name=\"prompt\""))
    }

    func testAutomaticClipboardTextRequiresCompletedNonblankTranscript() {
        var session = RecordingSession()
        session.transcript = "Physical iPhone clipboard test"

        session.state = .processing
        XCTAssertNil(GroqDictateAppModel.automaticClipboardText(for: session))

        session.state = .failed
        XCTAssertNil(GroqDictateAppModel.automaticClipboardText(for: session))

        session.state = .complete
        XCTAssertEqual(
            GroqDictateAppModel.automaticClipboardText(for: session),
            "Physical iPhone clipboard test"
        )

        session.transcript = "  \n"
        XCTAssertNil(GroqDictateAppModel.automaticClipboardText(for: session))
    }

    func testOnlyAPausedRecordingCanStartOneResume() {
        var lifecycle = RecordingLifecycle.interrupted

        XCTAssertTrue(lifecycle.beginResume())
        XCTAssertEqual(lifecycle, .resuming)
        XCTAssertFalse(lifecycle.beginResume(), "a second resume must not start while one is running")
        XCTAssertTrue(lifecycle.presentsActiveControls)
        XCTAssertFalse(lifecycle.showsResume)
        XCTAssertNil(lifecycle.requestToggle())

        for state in [RecordingLifecycle.idle, .starting, .recording, .stopping] {
            var other = state
            XCTAssertFalse(other.beginResume())
            XCTAssertEqual(other, state)
        }
    }

    func testSilentPartIsAnEmptyTranscriptNotAnError() throws {
        XCTAssertEqual(try GroqIOSClient.transcript(from: Data(#"{"text":"  "}"#.utf8)), "")
        XCTAssertEqual(try GroqIOSClient.transcript(from: Data(#"{"text":" Hello. "}"#.utf8)), "Hello.")

        var session = RecordingSession()
        for text in ["First.", "", "Third."] {
            var segment = RecordingSession.Segment.next(in: session)
            segment.transcript = text
            segment.state = .complete
            session.segments.append(segment)
        }
        XCTAssertEqual(session.assembledTranscript, "First. Third.")
    }

    func testRetryAfterIsReadAsSeconds() {
        XCTAssertEqual(GroqIOSClient.seconds(fromRetryAfter: "7"), 7)
        XCTAssertEqual(GroqIOSClient.seconds(fromRetryAfter: " 2.5 "), 2.5)
        XCTAssertNil(GroqIOSClient.seconds(fromRetryAfter: nil))
        XCTAssertNil(GroqIOSClient.seconds(fromRetryAfter: "soon"))
    }
}
