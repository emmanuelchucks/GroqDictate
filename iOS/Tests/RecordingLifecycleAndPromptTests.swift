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

    func testMultipartBodyIncludesPromptExactlyOnce() throws {
        let body = GroqIOSClient.makeMultipartBody(
            fileData: Data("audio".utf8),
            model: "whisper-large-v3",
            prompt: "so we ship it.",
            boundary: "TestBoundary"
        )
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertEqual(text.components(separatedBy: "name=\"prompt\"").count - 1, 1)
        XCTAssertTrue(text.contains("\r\n\r\nso we ship it.\r\n"))
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
        let fixes = SpellingFixes("Groq: grog")
        var session = RecordingSession()
        session.transcript = "Physical iPhone clipboard test with grog"

        session.state = .processing
        XCTAssertNil(GroqDictateAppModel.automaticClipboardText(for: session, fixes: fixes))

        session.state = .failed
        XCTAssertNil(GroqDictateAppModel.automaticClipboardText(for: session, fixes: fixes))

        session.state = .complete
        XCTAssertEqual(
            GroqDictateAppModel.automaticClipboardText(for: session, fixes: fixes),
            "Physical iPhone clipboard test with Groq"
        )

        session.transcript = "  \n"
        XCTAssertNil(GroqDictateAppModel.automaticClipboardText(for: session, fixes: fixes))
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
        XCTAssertEqual(try GroqIOSClient.transcript(from: Data(#"{"text":"  "}"#.utf8)).text, "")
        let response = #"{"text":" Hello. ","segments":[{"start":0,"end":1.5,"text":" Hello. ","no_speech_prob":0.1}]}"#
        let transcript = try GroqIOSClient.transcript(from: Data(response.utf8))
        XCTAssertEqual(transcript.text, "Hello.")
        XCTAssertEqual(transcript.segments, [TranscriptSegment(start: 0, end: 1.5, text: " Hello. ")])

        var session = RecordingSession()
        for text in ["First.", "", "Third."] {
            var segment = RecordingSession.Segment.next(in: session)
            segment.transcript = text
            segment.state = .complete
            session.segments.append(segment)
        }
        XCTAssertEqual(session.assembledTranscript, "First. Third.")
        XCTAssertNil(session.originalTranscript, "nothing was removed")

        session.segments[1].rawTranscript = "Thank you."
        XCTAssertEqual(session.originalTranscript, "First. Thank you. Third.")
    }

    func testRetryAfterIsReadAsSeconds() {
        XCTAssertEqual(GroqIOSClient.seconds(fromRetryAfter: "7"), 7)
        XCTAssertEqual(GroqIOSClient.seconds(fromRetryAfter: " 2.5 "), 2.5)
        XCTAssertNil(GroqIOSClient.seconds(fromRetryAfter: nil))
        XCTAssertNil(GroqIOSClient.seconds(fromRetryAfter: "soon"))
    }

    func testPromptContinuesFromThePreviousPart() {
        XCTAssertEqual(TranscriptionPrompt.make(previousText: nil), "")
        XCTAssertEqual(TranscriptionPrompt.make(previousText: " so we ship it. "), "so we ship it.")
    }

    func testPromptKeepsOnlyWholeWordsFromTheEndOfALongPart() {
        let words = (1...200).map { "word\($0)" }.joined(separator: " ")
        let prompt = TranscriptionPrompt.make(previousText: words)

        XCTAssertLessThanOrEqual(prompt.count, TranscriptionPrompt.previousTextCharacters)
        XCTAssertTrue(prompt.hasSuffix("word200"))
        XCTAssertTrue(prompt.hasPrefix("word"), "the tail starts at a word boundary")
    }
}
