import Foundation

protocol AudioPreprocessor {
    func processRecording(wavURL: URL, compressedOutputURL: URL) -> URL
}

protocol SpeechBoundaryDetector {
    func detectSpeechBounds(samples: [Int16], sampleRate: Float64) -> Range<Int>?
}

struct DefaultAudioPreprocessor: AudioPreprocessor {
    typealias CompressionHandler = (URL, URL) -> Bool

    private let speechBoundaryDetector: any SpeechBoundaryDetector
    private let compressionThresholdBytes: Int
    private let compressionHandler: CompressionHandler

    init(
        speechBoundaryDetector: any SpeechBoundaryDetector = RMSAudioSpeechBoundaryDetector(),
        compressionThresholdBytes: Int = 10 * 1024 * 1024,
        compressionHandler: @escaping CompressionHandler = Self.compressWAVToFLAC
    ) {
        self.speechBoundaryDetector = speechBoundaryDetector
        self.compressionThresholdBytes = compressionThresholdBytes
        self.compressionHandler = compressionHandler
    }

    func processRecording(wavURL: URL, compressedOutputURL: URL) -> URL {
        trimSilenceEdgesIfNeeded(wavURL: wavURL)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int) ?? 0
        guard fileSize >= compressionThresholdBytes else {
            return wavURL
        }

        try? FileManager.default.removeItem(at: compressedOutputURL)

        guard compressionHandler(wavURL, compressedOutputURL),
              FileManager.default.fileExists(atPath: compressedOutputURL.path)
        else {
            return wavURL
        }

        try? FileManager.default.removeItem(at: wavURL)
        return compressedOutputURL
    }

    private func trimSilenceEdgesIfNeeded(wavURL: URL) {
        guard let data = try? Data(contentsOf: wavURL, options: .mappedIfSafe), data.count > 44 else { return }

        let sampleByteCount = data.count - 44
        guard sampleByteCount >= 2 else { return }

        let sampleCount = sampleByteCount / 2
        var samples = [Int16](repeating: 0, count: sampleCount)
        _ = samples.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination, from: 44..<(44 + sampleCount * 2))
        }

        guard var speechBounds = speechBoundaryDetector.detectSpeechBounds(
            samples: samples,
            sampleRate: RMSAudioSpeechBoundaryDetector.sampleRate
        ) else {
            return
        }

        let leadingPadding = Int(
            RMSAudioSpeechBoundaryDetector.sampleRate * RMSAudioSpeechBoundaryDetector.trimLeadingPaddingMs / 1000
        )
        let trailingPadding = Int(
            RMSAudioSpeechBoundaryDetector.sampleRate * RMSAudioSpeechBoundaryDetector.trimTrailingPaddingMs / 1000
        )

        speechBounds = max(0, speechBounds.lowerBound - leadingPadding)..<min(sampleCount, speechBounds.upperBound + trailingPadding)

        let minLeadingTrim = Int(
            RMSAudioSpeechBoundaryDetector.sampleRate * RMSAudioSpeechBoundaryDetector.trimMinLeadingTrimMs / 1000
        )
        let minTrailingTrim = Int(
            RMSAudioSpeechBoundaryDetector.sampleRate * RMSAudioSpeechBoundaryDetector.trimMinTrailingTrimMs / 1000
        )

        let adjustedStart = speechBounds.lowerBound < minLeadingTrim ? 0 : speechBounds.lowerBound
        let adjustedEnd = (sampleCount - speechBounds.upperBound) < minTrailingTrim ? sampleCount : speechBounds.upperBound

        guard adjustedStart < adjustedEnd else { return }
        guard !(adjustedStart == 0 && adjustedEnd == sampleCount) else { return }

        let minResultSamples = Int(
            RMSAudioSpeechBoundaryDetector.sampleRate * RMSAudioSpeechBoundaryDetector.trimMinResultMs / 1000
        )
        guard (adjustedEnd - adjustedStart) >= minResultSamples else { return }

        let trimmedSamples = Array(samples[adjustedStart..<adjustedEnd])
        let trimmedPCM = trimmedSamples.withUnsafeBytes { Data($0) }

        var trimmedWAV = Data(capacity: 44 + trimmedPCM.count)
        trimmedWAV.append(ascii: "RIFF")
        trimmedWAV.append(uint32: UInt32(36 + trimmedPCM.count))
        trimmedWAV.append(ascii: "WAVE")
        trimmedWAV.append(ascii: "fmt ")
        trimmedWAV.append(uint32: 16)
        trimmedWAV.append(uint16: 1)
        trimmedWAV.append(uint16: 1)
        trimmedWAV.append(uint32: UInt32(RMSAudioSpeechBoundaryDetector.sampleRate))
        trimmedWAV.append(uint32: UInt32(RMSAudioSpeechBoundaryDetector.sampleRate * 2))
        trimmedWAV.append(uint16: 2)
        trimmedWAV.append(uint16: 16)
        trimmedWAV.append(ascii: "data")
        trimmedWAV.append(uint32: UInt32(trimmedPCM.count))
        trimmedWAV.append(trimmedPCM)

        do {
            try trimmedWAV.write(to: wavURL, options: .atomic)
        } catch {
            AppLog.error("failed to trim silence (\(error.localizedDescription))", category: .audio)
        }
    }

    private static func compressWAVToFLAC(wavURL: URL, compressedOutputURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "flac", "-d", "flac", "-c", "1", wavURL.path, compressedOutputURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        return (try? process.run()).map {
            process.waitUntilExit()
            return process.terminationStatus == 0
        } ?? false
    }
}

struct RMSAudioSpeechBoundaryDetector: SpeechBoundaryDetector {
    static let sampleRate: Float64 = 16000
    static let trimWindowMs: Float64 = 20
    static let trimActivationRMSThreshold: Float = 0.005
    static let trimContinuationRMSThreshold: Float = 0.0035
    static let trimMinLeadingSpeechWindows = 4
    static let trimMaxInterruptionWindows = 4
    static let trimLeadingPaddingMs: Float64 = 120
    static let trimTrailingPaddingMs: Float64 = 150
    static let trimMinLeadingTrimMs: Float64 = 180
    static let trimMinTrailingTrimMs: Float64 = 120
    static let trimMinResultMs: Float64 = 300

    func detectSpeechBounds(samples: [Int16], sampleRate: Float64) -> Range<Int>? {
        let windowSize = max(1, Int(sampleRate * Self.trimWindowMs / 1000))
        let totalWindows = Int(ceil(Double(samples.count) / Double(windowSize)))
        guard totalWindows > 0 else { return nil }

        var rmsWindows = [Double](repeating: 0, count: totalWindows)
        for index in 0..<totalWindows {
            let start = index * windowSize
            let end = min(samples.count, start + windowSize)
            guard start < end else { continue }

            var sumSquares: Double = 0
            for sample in samples[start..<end] {
                let normalized = Double(sample) / 32768.0
                sumSquares += normalized * normalized
            }

            rmsWindows[index] = sqrt(sumSquares / Double(end - start))
        }

        let activationThreshold = Double(Self.trimActivationRMSThreshold)
        let continuationThreshold = Double(Self.trimContinuationRMSThreshold)
        let leadingRequired = max(1, min(Self.trimMinLeadingSpeechWindows, rmsWindows.count))
        let maxInterruption = max(0, Self.trimMaxInterruptionWindows)

        var firstSpeechWindow: Int?
        var lastSpeechWindow: Int?
        var pendingStart: Int?
        var strongRun = 0
        var activeSegmentStart: Int?
        var silenceRun = 0

        for index in rmsWindows.indices {
            let rms = rmsWindows[index]
            let isStrongSpeech = rms >= activationThreshold

            if activeSegmentStart == nil {
                if isStrongSpeech {
                    if strongRun == 0 {
                        pendingStart = index
                    }
                    strongRun += 1

                    if strongRun >= leadingRequired {
                        activeSegmentStart = pendingStart
                        firstSpeechWindow = firstSpeechWindow ?? pendingStart
                        lastSpeechWindow = index
                        silenceRun = 0
                    }
                } else {
                    strongRun = 0
                    pendingStart = nil
                }
                continue
            }

            let isContinuingSpeech = rms >= continuationThreshold
            if isContinuingSpeech {
                lastSpeechWindow = index
                silenceRun = 0
                continue
            }

            silenceRun += 1
            if silenceRun > maxInterruption {
                activeSegmentStart = nil
                pendingStart = nil
                strongRun = 0
                silenceRun = 0
            }
        }

        guard let firstSpeechWindow, let lastSpeechWindow, firstSpeechWindow <= lastSpeechWindow else {
            return nil
        }

        let startSample = firstSpeechWindow * windowSize
        let endSample = min(samples.count, (lastSpeechWindow + 1) * windowSize)
        return startSample..<endSample
    }
}

private extension Data {
    mutating func append(ascii: String) {
        append(contentsOf: ascii.utf8)
    }

    mutating func append(uint16: UInt16) {
        var value = uint16.littleEndian
        append(Data(bytes: &value, count: 2))
    }

    mutating func append(uint32: UInt32) {
        var value = uint32.littleEndian
        append(Data(bytes: &value, count: 4))
    }
}
