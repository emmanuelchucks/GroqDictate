import Foundation

/// One segment of Groq's `verbose_json` response. Groq's `text` is exactly
/// the segments' texts joined, so keeping every segment keeps the text.
struct TranscriptSegment: Decodable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// Groq's text, the segments it is made of, and the audio's length in
/// seconds (0 when Groq didn't say).
struct GroqTranscript: Equatable {
    let text: String
    let segments: [TranscriptSegment]
    let duration: Double
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

    /// The text without listed phrases standing as sentences of their own at
    /// its start or end, so a second request's answer doesn't bring a phantom
    /// back with the user's words. "Thank you for the fix." stays.
    static func trimmed(_ text: String) -> String {
        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let endsSentence = { (token: String) in token.last.map { ".!?".contains($0) } ?? false }
        func isPhrase(_ chunk: ArraySlice<String>) -> Bool {
            let words = chunk.flatMap { normalizedWords($0) }
            return words.isEmpty || phrases.contains(words)
        }
        func lengthAtEnd() -> Int? {
            (1...min(6, tokens.count)).reversed().first { count in
                isPhrase(tokens.suffix(count)) && (count == tokens.count || endsSentence(tokens[tokens.count - count - 1]))
            }
        }
        func lengthAtStart() -> Int? {
            (1...min(6, tokens.count)).reversed().first { count in
                isPhrase(tokens.prefix(count)) && (count == tokens.count || endsSentence(tokens[count - 1]))
            }
        }
        while !tokens.isEmpty, let count = lengthAtEnd() { tokens.removeLast(count) }
        while !tokens.isEmpty, let count = lengthAtStart() { tokens.removeFirst(count) }
        return tokens.joined(separator: " ")
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
            return !segments[index].text.isEmpty
                && (PhantomPhrases.matchesWhole(text) || (text.count >= 20 && prompt.contains(text)))
        }
    }

    /// Whisper sometimes writes a word or two ("you.") over seconds of the
    /// user's speech, or skips it with no segment at all, often at the end of
    /// a part (docs/transcript-cleanup.md). His dictation runs at 1.6 words
    /// per second of voice or more, so a stretch with fewer, and at least two
    /// seconds of voice, is sent again on its own.
    static let fewWordsMinimumSeconds = 2.0
    static let fewWordsPerSecond = 1.5

    /// Whisper's segment timings are loose, so voice within half a second of
    /// a candidate counts as under it. Only removal uses it: it errs toward
    /// keeping text, but would make a slow segment look slower than it is.
    static let timingMargin = 0.5

    /// Second requests per part, the ones over the most voice first; Groq
    /// allows 20 requests a minute and the next part needs one.
    static let maximumResends = 5

    static func hasFewWords(_ segment: TranscriptSegment, voicedSeconds: Double) -> Bool {
        voicedSeconds >= fewWordsMinimumSeconds && Double(wordCount(segment.text)) < voicedSeconds * fewWordsPerSecond
    }

    /// The segments with an empty one in every gap of two seconds or more,
    /// including before the first and after the last, so a skipped stretch
    /// is checked like a segment.
    static func filling(gapsIn segments: [TranscriptSegment], duration: Double) -> [TranscriptSegment] {
        var filled: [TranscriptSegment] = []
        var covered = 0.0
        for segment in segments + [TranscriptSegment(start: duration, end: duration, text: "")] {
            if segment.start - covered >= fewWordsMinimumSeconds {
                filled.append(TranscriptSegment(start: covered, end: segment.start, text: ""))
            }
            filled.append(segment)
            covered = max(covered, segment.end)
        }
        return Array(filled.dropLast())
    }

    static func wordCount(_ text: String) -> Int {
        PhantomPhrases.normalizedWords(text).count
    }

    static func text(of segments: [TranscriptSegment], removing removed: Set<Int>) -> String {
        segments.indices
            .filter { !removed.contains($0) }
            .map { segments[$0].text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes candidates with no voice under them, and sends a stretch to
    /// Groq again when its text may be missing the user's words: a candidate
    /// with a voice under it, or a segment or gap with fewer words than
    /// seconds of voice. `voicedSeconds` gets the stretches' time ranges and
    /// answers for each, in order, or nil when it couldn't check.
    ///
    /// A phantom phrase with a voice under it can be Whisper replacing real
    /// words: sent alone, the stretch gave the user's words back in 7 of 34
    /// such cases (docs/transcript-cleanup.md). The answer replaces the
    /// stretch's text only when it has more of the user's words than the
    /// stretch had; nil leaves the text as it was. Stretches next to each
    /// other go as one, since separate stretches overlap and gave the same
    /// words back twice.
    ///
    /// Groq's text comes back unchanged unless something changed, and when
    /// the segments don't add up to it.
    static func cleaned(
        _ transcript: GroqTranscript,
        prompt: String = "",
        voicedSeconds: ([ClosedRange<Double>]) async -> [Double]?,
        retranscribe: (ClosedRange<Double>) async -> String? = { _ in nil }
    ) async -> String {
        var segments = filling(gapsIn: transcript.segments, duration: transcript.duration)
        guard text(of: segments, removing: []) == transcript.text else { return transcript.text }
        let removable = Set(candidates(in: segments, prompt: prompt))
        let checked = segments.indices.filter { index in
            let segment = segments[index]
            return removable.contains(index) || hasFewWords(segment, voicedSeconds: segment.end - segment.start)
        }
        guard !checked.isEmpty else { return transcript.text }
        let ranges = checked.map { index in
            let margin = removable.contains(index) ? timingMargin : 0
            return (segments[index].start - margin)...(max(segments[index].start, segments[index].end) + margin)
        }
        guard let voice = await voicedSeconds(ranges), voice.count == checked.count else { return transcript.text }
        var removed = Set(zip(checked, voice).filter { removable.contains($0.0) && $0.1 == 0 }.map(\.0))
        let resend = zip(checked, voice).filter { index, seconds in
            removable.contains(index) ? seconds > 0 : hasFewWords(segments[index], voicedSeconds: seconds)
        }
        let voiceUnder = Dictionary(uniqueKeysWithValues: resend)
        let chosen = runs(of: resend.map(\.0))
            .sorted { $0.map { voiceUnder[$0] ?? 0 }.reduce(0, +) > $1.map { voiceUnder[$0] ?? 0 }.reduce(0, +) }
            .prefix(maximumResends)
            .sorted { $0.lowerBound < $1.lowerBound }
        var replaced = false
        for run in chosen {
            let kept = segments.indices.filter { !removed.contains($0) }
            let before = kept.filter { $0 < run.lowerBound }.map { segments[$0].text }.joined()
            let after = kept.filter { $0 > run.upperBound }.map { segments[$0].text }.joined()
            let answer = await retranscribe(stretch(of: run, in: segments)) ?? ""
            let words = PhantomPhrases.trimmed(trimmingRepeats(of: answer, before: before, after: after))
            let userWords = run.filter { !removable.contains($0) }.map { wordCount(segments[$0].text) }.reduce(0, +)
            guard !PhantomPhrases.matchesWhole(words), wordCount(words) > userWords else { continue }
            let first = segments[run.lowerBound]
            segments[run.lowerBound] = TranscriptSegment(start: first.start, end: first.end, text: " " + words)
            removed.formUnion(run.dropFirst())
            replaced = true
        }
        return removed.isEmpty && !replaced ? transcript.text : text(of: segments, removing: removed)
    }

    /// Consecutive indexes grouped, in order.
    static func runs(of indexes: [Int]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        for index in indexes {
            if let last = runs.last, last.upperBound + 1 == index {
                runs[runs.count - 1] = last.lowerBound...index
            } else {
                runs.append(index...index)
            }
        }
        return runs
    }

    /// The run's time with half a second either side for Whisper's loose
    /// timings, but not into neighbours with words, which are already there.
    static func stretch(of run: ClosedRange<Int>, in segments: [TranscriptSegment]) -> ClosedRange<Double> {
        let first = segments[run.lowerBound], last = segments[run.upperBound]
        let previous = segments[..<run.lowerBound].last { !$0.text.isEmpty }
        let next = segments[(run.upperBound + 1)...].first { !$0.text.isEmpty }
        let lower = max(0, first.start - timingMargin, previous?.end ?? 0)
        let upper = min(last.end + timingMargin, next?.start ?? .infinity)
        return lower...max(upper, lower + 1)
    }

    /// The stretch can still catch a neighbour's words at its edges, so an
    /// answer's first words that repeat the text before it, and last words
    /// that repeat the text after it, are dropped (up to five each side).
    static func trimmingRepeats(of answer: String, before: String, after: String) -> String {
        var words = answer.split(whereSeparator: \.isWhitespace).map(String.init)
        let previous = PhantomPhrases.normalizedWords(before), next = PhantomPhrases.normalizedWords(after)
        let key = { (word: String) in PhantomPhrases.normalizedWords(word).joined(separator: " ") }
        if let count = (1...5).reversed().first(where: { count in
            count <= words.count && count <= previous.count
                && words.prefix(count).map(key) == Array(previous.suffix(count))
        }) {
            words.removeFirst(count)
        }
        if let count = (1...5).reversed().first(where: { count in
            count <= words.count && count <= next.count
                && words.suffix(count).map(key) == Array(next.prefix(count))
        }) {
            words.removeLast(count)
        }
        return words.joined(separator: " ")
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
