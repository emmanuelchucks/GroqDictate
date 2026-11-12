import Foundation
#if canImport(SoundAnalysis)
import AVFoundation
import SoundAnalysis
#endif

/// One window of Apple's sound classifier: how sure it is that someone speaks.
struct SpeechWindow: Equatable {
    let start: Double
    let end: Double
    let confidence: Double
}

enum SpeechCheck {
    /// Calibrated on 12 Nov 2026 (docs/transcript-cleanup.md): real speech
    /// peaked at 0.74 or more on the iPhone, but short words through a
    /// Bluetooth earpiece at 0.33, so the line sits below that.
    static let threshold = 0.25

    /// Whisper's segment timings are loose, so voice within half a second of
    /// a segment counts as under it. It only ever errs toward keeping text.
    static let margin = 0.5

    static func hasSpeech(in range: ClosedRange<Double>, windows: [SpeechWindow], threshold: Double = threshold) -> Bool {
        let lower = range.lowerBound - margin, upper = range.upperBound + margin
        return windows.contains { $0.end > lower && $0.start < upper && $0.confidence >= threshold }
    }

    #if canImport(SoundAnalysis)
    /// The classifier's labels for a human voice; "speech" alone misses
    /// whispering, shouting and singing.
    static let voiceLabels: Set<String> = [
        "speech", "whispering", "shout", "yell", "children_shouting",
        "singing", "choir_singing", "humming", "chatter", "babble", "crowd",
    ]

    /// For each range, whether anyone speaks in it; nil when the audio can't
    /// be read, and then nothing is removed. Only the ranges (with the
    /// margin) are classified: the whole of a five-minute part took 8.7 s on
    /// an iPhone XR.
    static func speech(in ranges: [ClosedRange<Double>], fileURL: URL) async -> [Bool]? {
        await Task.detached(priority: .userInitiated) {
            guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
            let duration = Double(file.length) / file.processingFormat.sampleRate
            var answers: [Bool] = []
            for range in ranges {
                // A second more audio either side gives the windows at the
                // margin the same surroundings as classifying the whole file.
                let lower = max(0, min(range.lowerBound - margin - 1, duration - 3))
                let upper = min(duration, max(range.upperBound + margin + 1, lower + 3))
                guard let windows = windows(in: file, from: lower, to: upper) else { return nil }
                answers.append(windows.isEmpty || hasSpeech(in: range, windows: windows))
            }
            return answers
        }.value
    }

    /// Classifies part of a file with the built-in sound classifier, in 1 s
    /// windows overlapping by half. Window times are seconds into the file.
    static func windows(in file: AVAudioFile, from start: Double, to end: Double) -> [SpeechWindow]? {
        final class Collector: NSObject, SNResultsObserving {
            var windows: [SpeechWindow] = []
            var failed = false
            func request(_ request: SNRequest, didProduce result: SNResult) {
                guard let result = result as? SNClassificationResult else { return }
                windows.append(SpeechWindow(
                    start: result.timeRange.start.seconds,
                    end: (result.timeRange.start + result.timeRange.duration).seconds,
                    confidence: result.classifications
                        .filter { SpeechCheck.voiceLabels.contains($0.identifier) }
                        .map(\.confidence).max() ?? 0
                ))
            }
            func request(_ request: SNRequest, didFailWithError error: Error) { failed = true }
        }
        let format = file.processingFormat
        let rate = format.sampleRate
        do {
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 1, preferredTimescale: 1000)
            request.overlapFactor = 0.5
            let collector = Collector()
            try analyzer.add(request, withObserver: collector)
            file.framePosition = AVAudioFramePosition(start * rate)
            var remaining = AVAudioFrameCount(max(0, end - start) * rate)
            var position: AVAudioFramePosition = 0
            while remaining > 0 {
                let count = min(remaining, 16_384)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
                try file.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { break }
                analyzer.analyze(buffer, atAudioFramePosition: position)
                position += AVAudioFramePosition(buffer.frameLength)
                remaining -= min(remaining, buffer.frameLength)
            }
            analyzer.completeAnalysis()
            guard !collector.failed else { return nil }
            return collector.windows.map {
                SpeechWindow(start: $0.start + start, end: $0.end + start, confidence: $0.confidence)
            }
        } catch {
            return nil
        }
    }
    #endif
}
