import Foundation

/// One segment of Groq's `verbose_json` response. Groq's `text` is exactly
/// the segments' texts joined, so keeping every segment keeps the text.
struct TranscriptSegment: Decodable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// Groq's text and the segments it is made of.
struct GroqTranscript: Equatable {
    let text: String
    let segments: [TranscriptSegment]
}

/// Whisper writes stock phrases over stretches with no speech. A segment is
/// a candidate only when its whole text is made of these phrases; it is
/// removed only when the audio under it has no speech (`SpeechCheck`).
enum PhantomPhrases {
    static let list: [String] = [
        "thank you",
        "thank you so much",
        "thank you for watching",
        "thanks for watching",
        "thank you for listening",
        "please subscribe",
        "subtitles by the amara org community",
        "i hope you enjoyed this video",
        "so we're going to go ahead and do that",
        "i'm going to go ahead and do that",
        "i'm not sure",
    ]

    private static let phrases: [[String]] = list.map { $0.split(separator: " ").map(String.init) }

    /// True when the text is nothing but listed phrases (any number, in any
    /// order) or nothing but punctuation.
    static func matchesWhole(_ text: String) -> Bool {
        let words = normalizedWords(text)
        guard !words.isEmpty else { return true }
        // covered[i]: words[0..<i] splits exactly into listed phrases.
        var covered = [Bool](repeating: false, count: words.count + 1)
        covered[0] = true
        for i in 0..<words.count where covered[i] {
            for phrase in phrases where i + phrase.count <= words.count
                && Array(words[i..<(i + phrase.count)]) == phrase {
                covered[i + phrase.count] = true
            }
        }
        return covered[words.count]
    }

    /// Lowercased words without punctuation. Whisper's misspelt "thank"
    /// (Tthank, T'hank, Tchank, Ttank) reads as "thank".
    static func normalizedWords(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let spaced = String(lowered.map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " })
        return spaced.split(separator: " ").map { word in
            let trimmed = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            return trimmed.range(of: "^t+'?[ct]?h?ank$", options: .regularExpression) != nil ? "thank" : trimmed
        }.filter { !$0.isEmpty }
    }
}

enum TranscriptCleanup {
    /// Indexes of segments whose whole text is phantom phrases, or repeats
    /// the prompt: on silence Whisper can return the prompt itself
    /// (github.com/openai/whisper/discussions/1606). Text that short could be
    /// a real reply, so only 20 characters or more count as an echo.
    static func candidates(in segments: [TranscriptSegment], prompt: String = "") -> [Int] {
        segments.indices.filter { index in
            let text = segments[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            return PhantomPhrases.matchesWhole(text) || (text.count >= 20 && prompt.contains(text))
        }
    }

    static func text(of segments: [TranscriptSegment], removing removed: Set<Int>) -> String {
        segments.indices
            .filter { !removed.contains($0) }
            .map { segments[$0].text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes candidates the speech check finds no speech under. `hasSpeech`
    /// gets the candidates' time ranges and answers for each, in order, or nil
    /// when it couldn't check.
    ///
    /// A candidate with a voice under it can be Whisper replacing real words
    /// with a stock phrase: sent alone, the stretch gave the user's words back
    /// in 7 of 34 such cases (docs/transcript-cleanup.md). `retranscribe`
    /// sends one stretch to Groq again; its text replaces the phrase only when
    /// it is more than phantom phrases, and nil leaves the phrase as it was.
    ///
    /// Groq's text comes back unchanged unless something changed, and when
    /// the segments don't add up to it.
    static func cleaned(
        _ transcript: GroqTranscript,
        prompt: String = "",
        hasSpeech: ([ClosedRange<Double>]) async -> [Bool]?,
        retranscribe: (ClosedRange<Double>) async -> String? = { _ in nil }
    ) async -> String {
        var segments = transcript.segments
        let candidates = candidates(in: segments, prompt: prompt)
        guard !candidates.isEmpty, text(of: segments, removing: []) == transcript.text else { return transcript.text }
        let ranges = candidates.map { segments[$0].start...max(segments[$0].start, segments[$0].end) }
        guard let speech = await hasSpeech(ranges) else { return transcript.text }
        var removed = Set<Int>()
        var replaced = false
        for (index, voiced) in zip(candidates, speech) {
            guard voiced else {
                removed.insert(index)
                continue
            }
            let words = await retranscribe(stretch(of: index, in: segments))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !PhantomPhrases.matchesWhole(words) else { continue }
            let segment = segments[index]
            segments[index] = TranscriptSegment(start: segment.start, end: segment.end, text: " " + words)
            replaced = true
        }
        return removed.isEmpty && !replaced ? transcript.text : text(of: segments, removing: removed)
    }

    /// The segment's time with half a second either side for Whisper's loose
    /// timings, but not into its neighbours, whose words are already there.
    static func stretch(of index: Int, in segments: [TranscriptSegment]) -> ClosedRange<Double> {
        let segment = segments[index]
        let lower = max(0, segment.start - 0.5, index > 0 ? segments[index - 1].end : 0)
        var upper = segment.end + 0.5
        if index + 1 < segments.count { upper = min(upper, segments[index + 1].start) }
        return lower...max(upper, lower + 1)
    }
}

/// The user's spelling fixes, one line per name: `Right: wrong, wrong`.
/// Each wrong form is replaced as a whole word or phrase, ignoring case.
struct SpellingFixes {
    static let maximumCharacters = 2000

    private(set) var fixes: [String: String] = [:]
    private var pattern: NSRegularExpression?

    init(_ setting: String) {
        for line in setting.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let right = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !right.isEmpty else { continue }
            for wrong in line[line.index(after: colon)...].split(separator: ",") {
                let key = Self.key(String(wrong))
                if !key.isEmpty { fixes[key] = right }
            }
        }
        // Longest first, so "grog dictate" wins over "grog".
        let alternatives = fixes.keys.sorted { $0.count > $1.count }.map { key in
            key.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
        }
        guard !alternatives.isEmpty else { return }
        pattern = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}])",
            options: [.caseInsensitive]
        )
    }

    func apply(to text: String) -> String {
        guard let pattern else { return text }
        let source = text as NSString
        var result = ""
        var last = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let found = source.substring(with: match.range)
            result += fixes[Self.key(found)] ?? found
            last = match.range.location + match.range.length
        }
        return result + source.substring(from: last)
    }

    private static func key(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
