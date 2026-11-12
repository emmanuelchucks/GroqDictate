import XCTest
@testable import GroqDictate

final class TranscriptCleanupTests: XCTestCase {
    func testOnlyWholeSegmentsOfListedPhrasesAreCandidates() {
        for phantom in ["Thank you.", " Tthank you Tthank you Tthank you.", "T'hank you. Thank you for watching!",
                        "Subtitles by the Amara.org community", "Thank you so much.", ". . . .", ""] {
            XCTAssertTrue(PhantomPhrases.matchesWhole(phantom), phantom)
        }
        for real in ["Thank you for the clarification.", "Thank you, I also agree.", "I don't know.",
                     "you", "Okay.", "Thank you all right", "Tank."] {
            XCTAssertFalse(PhantomPhrases.matchesWhole(real), real)
        }
    }

    func testAPromptEchoIsACandidateButAShortReplyIsNot() {
        let prompt = "and that is how we ship the release."
        let segments = [
            TranscriptSegment(start: 0, end: 30, text: " and that is how we ship the release."),
            TranscriptSegment(start: 30, end: 31, text: " ship"),
            TranscriptSegment(start: 31, end: 34, text: " Next we test the build."),
        ]
        XCTAssertEqual(TranscriptCleanup.candidates(in: segments, prompt: prompt), [0])
    }

    func testRemovesOnlyCandidatesWithNoSpeechUnderThem() async {
        let transcript = Self.transcript([
            (0, 4, " Can you check the build?"),
            (30, 60, " Thank you."),
            (60, 62, " Thank you."),
            (62, 66, " And the logs too."),
        ])
        var asked: [ClosedRange<Double>] = []
        let cleaned = await TranscriptCleanup.cleaned(transcript) { ranges in
            asked = ranges
            return [false, true]
        }
        XCTAssertEqual(asked, [30...60, 60...62])
        XCTAssertEqual(cleaned, "Can you check the build? Thank you. And the logs too.")
    }

    func testGroqsTextStaysExactlyWhenNothingCanBeRemoved() async {
        let plain = Self.transcript([(0, 4, " Hello there."), (4, 8, " Thank you for the fix.")])
        let notChecked = await TranscriptCleanup.cleaned(plain) { _ in
            XCTFail("no candidates, so no speech check")
            return []
        }
        XCTAssertEqual(notChecked, "Hello there. Thank you for the fix.")

        let phantom = Self.transcript([(0, 4, " Hello there."), (30, 60, " Thank you.")])
        let unreadable = await TranscriptCleanup.cleaned(phantom) { _ in nil }
        XCTAssertEqual(unreadable, "Hello there. Thank you.", "audio that can't be read removes nothing")

        let mismatched = GroqTranscript(text: "Hello there, friend. Thank you.", segments: phantom.segments)
        let kept = await TranscriptCleanup.cleaned(mismatched) { _ in [false] }
        XCTAssertEqual(kept, "Hello there, friend. Thank you.", "segments that don't add up to the text change nothing")
    }

    private static func transcript(_ parts: [(Double, Double, String)]) -> GroqTranscript {
        let segments = parts.map { TranscriptSegment(start: $0.0, end: $0.1, text: $0.2) }
        return GroqTranscript(
            text: segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
            segments: segments
        )
    }

    func testVoiceInOrJustBesideASegmentCountsAsSpeech() {
        let windows = [
            SpeechWindow(start: 0, end: 1, confidence: 0.9),
            SpeechWindow(start: 10, end: 11, confidence: 0.2),
        ]
        XCTAssertTrue(SpeechCheck.hasSpeech(in: 0.5...5, windows: windows))
        XCTAssertTrue(SpeechCheck.hasSpeech(in: 1.4...5, windows: windows), "within the margin")
        XCTAssertFalse(SpeechCheck.hasSpeech(in: 1.5...5, windows: windows), "beyond the margin")
        XCTAssertFalse(SpeechCheck.hasSpeech(in: 5...20, windows: windows), "a quiet window isn't voice")
    }

    func testSpellingFixesReplaceWholeWordsIgnoringCase() {
        let fixes = SpellingFixes("""
        XcodeGen: x code gen, xcode jen, code gin
        GroqDictate: grog dictate
        Groq: grog, grok
        not a fix line
        : orphan
        """)
        XCTAssertEqual(
            fixes.apply(to: "Code gin's output, the X CODE GEN file, xcode  jen and Grog dictate on grok."),
            "XcodeGen's output, the XcodeGen file, XcodeGen and GroqDictate on Groq."
        )
        XCTAssertEqual(fixes.apply(to: "grogs and groggy stay"), "grogs and groggy stay")
        XCTAssertEqual(SpellingFixes("").apply(to: "grog"), "grog")
    }
}
