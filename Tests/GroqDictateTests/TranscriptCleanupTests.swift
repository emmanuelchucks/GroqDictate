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
            (0, 4, " Can you check the build and the deploy logs?"),
            (4, 30, " Thank you."),
            (30, 32, " Thank you."),
            (32, 34, " And the logs too."),
        ])
        var asked: [ClosedRange<Double>] = []
        let cleaned = await TranscriptCleanup.cleaned(transcript) { ranges in
            asked = ranges
            return [0, 1.5]
        }
        XCTAssertEqual(asked, [3.5...30.5, 29.5...32.5], "half a second either side, as Whisper's timings are loose")
        XCTAssertEqual(cleaned, "Can you check the build and the deploy logs? Thank you. And the logs too.")
    }

    func testGroqsTextStaysExactlyWhenNothingCanBeRemoved() async {
        let plain = Self.transcript([(0, 1.5, " Hello there."), (1.5, 4, " Thank you for the fix.")])
        let notChecked = await TranscriptCleanup.cleaned(plain) { _ in
            XCTFail("no candidates and no thin stretches, so no speech check")
            return []
        }
        XCTAssertEqual(notChecked, "Hello there. Thank you for the fix.")

        let phantom = Self.transcript([(0, 1.5, " Hello there."), (1.5, 30, " Thank you.")])
        let unreadable = await TranscriptCleanup.cleaned(phantom) { _ in nil }
        XCTAssertEqual(unreadable, "Hello there. Thank you.", "audio that can't be read removes nothing")

        let mismatched = GroqTranscript(text: "Hello there, friend. Thank you.", segments: phantom.segments, duration: 30)
        let kept = await TranscriptCleanup.cleaned(mismatched) { _ in [0] }
        XCTAssertEqual(kept, "Hello there, friend. Thank you.", "segments that don't add up to the text change nothing")
    }

    func testAPhraseOverAVoiceIsReplacedOnlyByRealWordsFromASecondRequest() async {
        let transcript = Self.transcript([
            (0, 4, " Can you check the build and the deploy logs?"),
            (4, 30, " Thank you."),
            (30, 31, " Okay."),
            (31, 33, " Thank you."),
            (33, 35, " And the logs too."),
        ])
        var asked: [ClosedRange<Double>] = []
        let recovered = await TranscriptCleanup.cleaned(
            transcript,
            voicedSeconds: { _ in [3, 1] },
            retranscribe: { range in
                asked.append(range)
                return range.lowerBound < 10 ? " and the Wrangler config. " : "Thank you."
            }
        )
        XCTAssertEqual(asked, [4...30, 31...33], "half a second either side, never into a neighbour")
        XCTAssertEqual(recovered, "Can you check the build and the deploy logs? and the Wrangler config. Okay. Thank you. And the logs too.")

        let failed = await TranscriptCleanup.cleaned(transcript, voicedSeconds: { _ in [3, 1] }, retranscribe: { _ in nil })
        XCTAssertEqual(failed, transcript.text, "a failed second request changes nothing")
    }

    func testNeighbouringPhrasesOverAVoiceGoAsOneStretch() async {
        let transcript = Self.transcript([
            (0, 4, " Can you check the build and the deploy logs?"),
            (4, 5, " Thank you."),
            (5, 6, " Thank you."),
            (6, 7, " Thank you."),
            (7, 10, " the global config for the whole team."),
        ])
        var asked: [ClosedRange<Double>] = []
        let cleaned = await TranscriptCleanup.cleaned(
            transcript,
            voicedSeconds: { _ in [1, 1, 1] },
            retranscribe: { range in
                asked.append(range)
                return " so the fixes you are suggesting to the"
            }
        )
        XCTAssertEqual(asked, [4...7])
        XCTAssertEqual(cleaned, "Can you check the build and the deploy logs? so the fixes you are suggesting to the global config for the whole team.")
    }

    func testWordsTheStretchCaughtFromANeighbourAreNotRepeated() async {
        let transcript = Self.transcript([(0, 4, " Proceed with what you said is next also"), (4, 6, " Thank you.")])
        let echoOnly = await TranscriptCleanup.cleaned(transcript, voicedSeconds: { _ in [1] }, retranscribe: { _ in "also" })
        XCTAssertEqual(echoOnly, transcript.text, "an answer that only repeats a neighbour leaves the phrase")

        let more = await TranscriptCleanup.cleaned(transcript, voicedSeconds: { _ in [1] }, retranscribe: { _ in "next also, and the tests." })
        XCTAssertEqual(more, "Proceed with what you said is next also and the tests.")
    }

    /// 17 Nov: Groq wrote "you." over the last 15 s of a 66 s dictation, the
    /// same twice; sent alone, the stretch gave his words back.
    func testAFewWordsOverMuchVoiceAreSentAgain() async {
        let transcript = Self.transcript([
            (0, 4.1, " the ghana card or the business registration and what should we pursue"),
            (4.1, 18.9, " you."),
        ], duration: 20.2)
        var asked: [ClosedRange<Double>] = []
        let recovered = await TranscriptCleanup.cleaned(
            transcript,
            voicedSeconds: { ranges in
                asked = ranges
                return [8.2]
            },
            retranscribe: { _ in " pursue we do have the soft copy already though" }
        )
        XCTAssertEqual(asked, [4.1...18.9], "a gap under two seconds isn't checked")
        XCTAssertEqual(recovered, "the ghana card or the business registration and what should we pursue we do have the soft copy already though")

        let same = await TranscriptCleanup.cleaned(transcript, voicedSeconds: { _ in [8.2] }, retranscribe: { _ in "you" })
        XCTAssertEqual(same, transcript.text, "an answer with no more words keeps Groq's text")

        let pause = await TranscriptCleanup.cleaned(transcript, voicedSeconds: { _ in [0.8] }, retranscribe: { _ in
            XCTFail("a word over a short voice is a pause, not missing words")
            return nil
        })
        XCTAssertEqual(pause, transcript.text)
    }

    /// 26 Oct: twelve words over 11.4 s of voice; the user's last sentence
    /// was inside it.
    func testASlowSegmentIsSentAgain() async {
        let words = " I don't understand why the hook is preventing you from deleting it."
        let transcript = Self.transcript([(0, 15.4, words)])
        let recovered = await TranscriptCleanup.cleaned(
            transcript,
            voicedSeconds: { _ in [11.4] },
            retranscribe: { _ in words + " Because I don't remember what the hook is supposed to achieve." }
        )
        XCTAssertEqual(recovered, "I don't understand why the hook is preventing you from deleting it. Because I don't remember what the hook is supposed to achieve.")
    }

    func testVoiceWithNoSegmentIsSentAgain() async {
        let transcript = Self.transcript([(0, 3, " First we check the build."), (12, 14, " And then the logs.")], duration: 20)
        var asked: [ClosedRange<Double>] = []
        let recovered = await TranscriptCleanup.cleaned(
            transcript,
            voicedSeconds: { ranges in
                asked = ranges
                return [4, 0.5]
            },
            retranscribe: { range in range.lowerBound == 3 ? "then we ship it." : nil }
        )
        XCTAssertEqual(asked, [3...12, 14...20], "gaps between segments and after the last")
        XCTAssertEqual(recovered, "First we check the build. then we ship it. And then the logs.")
    }

    func testAPhraseBesideAGapKeepsItsHalfSecond() async {
        let transcript = Self.transcript([(0, 2, " Hello there my friend."), (5, 6, " Thank you."), (9, 10, " Bye now and see you.")])
        var asked: [ClosedRange<Double>] = []
        _ = await TranscriptCleanup.cleaned(transcript, voicedSeconds: { _ in [0, 1, 0] }, retranscribe: { range in
            asked.append(range)
            return nil
        })
        XCTAssertEqual(asked, [4.5...6.5], "a gap has no words to stay out of")
    }

    func testAPhantomPhraseInTheAnswerIsLeftOut() async {
        let transcript = Self.transcript([(0, 4, " First we check the build and the deploy logs.")], duration: 12)
        let recovered = await TranscriptCleanup.cleaned(transcript, voicedSeconds: { _ in [5] }, retranscribe: { _ in
            " Thank you. and then we ship it. Thank you."
        })
        XCTAssertEqual(recovered, "First we check the build and the deploy logs. and then we ship it.")
        XCTAssertEqual(PhantomPhrases.trimmed("Thank you for the fix."), "Thank you for the fix.", "a phrase inside a sentence stays")
        XCTAssertEqual(PhantomPhrases.trimmed("I agree, thank you."), "I agree, thank you.")
    }

    func testAtMostFiveStretchesPerPartAreSentAgainTheOnesWithMostVoice() async {
        let parts = (0..<8).map { (Double($0 * 4), Double($0 * 4 + 1), " one two three.") }
        let transcript = Self.transcript(parts)
        var asked: [Double] = []
        _ = await TranscriptCleanup.cleaned(transcript, voicedSeconds: { _ in [2.1, 3, 2.2, 3.1, 3.2, 3.3, 3.4] }, retranscribe: { range in
            asked.append(range.lowerBound)
            return nil
        })
        XCTAssertEqual(asked, [5, 13, 17, 21, 25])
    }

    private static func transcript(_ parts: [(Double, Double, String)], duration: Double? = nil) -> GroqTranscript {
        let segments = parts.map { TranscriptSegment(start: $0.0, end: $0.1, text: $0.2) }
        return GroqTranscript(
            text: segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
            segments: segments,
            duration: duration ?? segments.last?.end ?? 0
        )
    }

    func testVoiceInAStretchCounts() {
        let windows = [
            SpeechWindow(start: 0, end: 1, confidence: 0.9),
            SpeechWindow(start: 10, end: 11, confidence: 0.2),
        ]
        XCTAssertEqual(SpeechCheck.voicedSeconds(in: 0.5...5, windows: windows), 0.5, accuracy: 0.001)
        XCTAssertEqual(SpeechCheck.voicedSeconds(in: 1...5, windows: windows), 0, "outside the range")
        XCTAssertEqual(SpeechCheck.voicedSeconds(in: 5...20, windows: windows), 0, "a quiet window isn't voice")
        XCTAssertEqual(SpeechCheck.voicedSeconds(in: 30...32, windows: []), 2, "no windows: all of it counts")
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
