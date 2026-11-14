import Foundation
#if canImport(CoreML)
import AVFoundation
import CoreML
#endif

/// One window of the voice detector: how sure it is that someone speaks.
struct SpeechWindow: Equatable {
    let start: Double
    let end: Double
    let confidence: Double
}

enum SpeechCheck {
    /// Silero's probability that a window holds speech. Calibrated on the
    /// user's recordings (docs/transcript-cleanup.md).
    static let threshold = 0.5

    /// Whisper's segment timings are loose, so voice within half a second of
    /// a segment counts as under it. It only ever errs toward keeping text.
    static let margin = 0.5

    /// Seconds Silero hears before a stretch's margin starts. With less, it
    /// answered differently from a whole-file pass on more of the user's
    /// recordings (docs/transcript-cleanup.md).
    static let preroll = 10.0

    static func hasSpeech(in range: ClosedRange<Double>, windows: [SpeechWindow], threshold: Double = threshold) -> Bool {
        let lower = range.lowerBound - margin, upper = range.upperBound + margin
        return windows.contains { $0.end > lower && $0.start < upper && $0.confidence >= threshold }
    }

    #if canImport(CoreML)
    /// For each range, whether anyone speaks in it; nil when the audio or the
    /// model can't be read, and then nothing is removed.
    static func speech(in ranges: [ClosedRange<Double>], fileURL: URL) async -> [Bool]? {
        await Task.detached(priority: .userInitiated) {
            guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
            let duration = Double(file.length) / file.processingFormat.sampleRate
            var answers: [Bool] = []
            for range in ranges {
                // Silero carries state from window to window, so it starts a
                // few seconds early, on the same 256 ms grid as a whole-file
                // pass, to answer as it would there.
                let lower = Silero.gridStart(at: max(0, range.lowerBound - margin - preroll))
                let upper = max(lower, min(duration, range.upperBound + margin + 1))
                guard let windows = await windows(in: file, from: lower, to: upper) else { return nil }
                answers.append(windows.isEmpty || hasSpeech(in: range, windows: windows))
            }
            return answers
        }.value
    }

    /// Runs Silero over part of a file in 256 ms windows. Window times are
    /// seconds into the file.
    static func windows(in file: AVAudioFile, from start: Double, to end: Double) async -> [SpeechWindow]? {
        guard let model = Silero.model,
              let samples = Silero.samples(of: file, from: start, to: end)
        else { return nil }
        var detector = Silero(model: model)
        var windows: [SpeechWindow] = []
        var offset = 0
        while offset < samples.count {
            let chunk = samples[offset..<min(offset + Silero.chunkSize, samples.count)]
            guard let probability = await detector.probability(of: chunk) else { return nil }
            let windowStart = start + Double(offset) / Silero.sampleRate
            windows.append(SpeechWindow(
                start: windowStart,
                end: windowStart + Double(chunk.count) / Silero.sampleRate,
                confidence: probability
            ))
            offset += Silero.chunkSize
        }
        return windows
    }
    #endif
}

#if canImport(CoreML)
/// Silero VAD v6.2.1 as Core ML (Shared/Models/silero-vad-LICENSE): 4096 new
/// samples at 16 kHz after the last 64 of the previous chunk, with the LSTM
/// state carried between chunks.
///
/// CPU only: iOS refuses GPU work from an app in the background
/// (kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted), which is
/// where most checks run. That is also why Apple's built-in sound classifier,
/// which uses the GPU, can't do this job.
struct Silero {
    static let sampleRate = 16_000.0
    static let chunkSize = 4096
    private static let contextSize = 64

    static func gridStart(at seconds: Double) -> Double {
        let window = Double(chunkSize) / sampleRate
        return (seconds / window).rounded(.down) * window
    }
    private static let stateSize = 128

    static let model: MLModel? = {
        guard let url = Bundle.main.url(forResource: "silero-vad", withExtension: "mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        return try? MLModel(contentsOf: url, configuration: configuration)
    }()

    private let model: MLModel
    private var context = [Float](repeating: 0, count: contextSize)
    private var hidden = [Float](repeating: 0, count: stateSize)
    private var cell = [Float](repeating: 0, count: stateSize)

    init(model: MLModel) {
        self.model = model
    }

    /// The chance that this chunk holds speech; a short last chunk is padded
    /// with silence.
    mutating func probability(of chunk: ArraySlice<Float>) async -> Double? {
        do {
            let audio = try MLMultiArray(shape: [1, NSNumber(value: Self.contextSize + Self.chunkSize)], dataType: .float32)
            let padded = Array(chunk) + [Float](repeating: 0, count: Self.chunkSize - chunk.count)
            Self.fill(audio, with: context + padded)
            let hiddenInput = try MLMultiArray(shape: [1, NSNumber(value: Self.stateSize)], dataType: .float32)
            let cellInput = try MLMultiArray(shape: [1, NSNumber(value: Self.stateSize)], dataType: .float32)
            Self.fill(hiddenInput, with: hidden)
            Self.fill(cellInput, with: cell)
            // The async form: the synchronous one isn't safe when two checks
            // share the model (WWDC23 10049).
            let output = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "audio_input": audio, "hidden_state": hiddenInput, "cell_state": cellInput,
            ]))
            guard let probability = output.featureValue(for: "vad_output")?.multiArrayValue,
                  let newHidden = output.featureValue(for: "new_hidden_state")?.multiArrayValue,
                  let newCell = output.featureValue(for: "new_cell_state")?.multiArrayValue
            else { return nil }
            hidden = Self.values(of: newHidden)
            cell = Self.values(of: newCell)
            context = Array(padded.suffix(Self.contextSize))
            return probability[0].doubleValue
        } catch {
            return nil
        }
    }

    /// The stretch as 16 kHz mono samples, whatever the file's format.
    static func samples(of file: AVAudioFile, from start: Double, to end: Double) -> [Float]? {
        let format = file.processingFormat
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target)
        else { return nil }
        file.framePosition = AVAudioFramePosition(start * format.sampleRate)
        var remaining = AVAudioFrameCount(max(0, end - start) * format.sampleRate)
        var samples: [Float] = []
        var readFailed = false
        while true {
            let capacity = AVAudioFrameCount(16_384)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                let count = min(remaining, 16_384)
                guard count > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: count)
                } catch {
                    readFailed = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard input.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                remaining -= min(remaining, input.frameLength)
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error, !readFailed, let channel = output.floatChannelData else { return nil }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
            if status == .endOfStream || output.frameLength == 0 { return samples }
        }
    }

    private static func fill(_ array: MLMultiArray, with values: [Float]) {
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: values.count)
        for index in values.indices { pointer[index] = values[index] }
    }

    private static func values(of array: MLMultiArray) -> [Float] {
        (0..<array.count).map { array[$0].floatValue }
    }
}
#endif
