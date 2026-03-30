import Foundation
import XCTest
@testable import GroqDictate

final class AudioPreprocessorTests: XCTestCase {
    func testDetector_keepsWeakTrailingSpeechAfterStrongOnset() {
        let detector = RMSAudioSpeechBoundaryDetector()
        let samples = silentSamples(milliseconds: 200)
            + speechSamples(milliseconds: 240)
            + speechSamples(milliseconds: 120, amplitude: 140)
            + silentSamples(milliseconds: 200)

        let bounds = detector.detectSpeechBounds(
            samples: samples,
            sampleRate: RMSAudioSpeechBoundaryDetector.sampleRate
        )

        XCTAssertEqual(bounds?.count, 5_760)
    }

    func testProcessRecording_trimsLeadingAndTrailingSilence() throws {
        let originalSamples = silentSamples(milliseconds: 300)
            + speechSamples(milliseconds: 500)
            + silentSamples(milliseconds: 300)
        let wavURL = try writeWAV(samples: originalSamples)
        let preprocessor = DefaultAudioPreprocessor(compressionThresholdBytes: .max)

        let outputURL = preprocessor.processRecording(
            wavURL: wavURL,
            compressedOutputURL: wavURL.deletingPathExtension().appendingPathExtension("flac")
        )

        XCTAssertEqual(outputURL, wavURL)
        XCTAssertEqual(readSamples(from: wavURL).count, 12_320)
    }

    func testProcessRecording_preservesWeakTrailingSpeechBeforeApplyingPadding() throws {
        let originalSamples = silentSamples(milliseconds: 300)
            + speechSamples(milliseconds: 240)
            + speechSamples(milliseconds: 120, amplitude: 140)
            + silentSamples(milliseconds: 300)
        let wavURL = try writeWAV(samples: originalSamples)
        let preprocessor = DefaultAudioPreprocessor(compressionThresholdBytes: .max)

        let outputURL = preprocessor.processRecording(
            wavURL: wavURL,
            compressedOutputURL: wavURL.deletingPathExtension().appendingPathExtension("flac")
        )

        XCTAssertEqual(outputURL, wavURL)
        XCTAssertEqual(readSamples(from: wavURL).count, 10_080)
    }

    func testProcessRecording_leavesSilenceOnlyRecordingUntouched() throws {
        let originalSamples = silentSamples(milliseconds: 600)
        let wavURL = try writeWAV(samples: originalSamples)
        let preprocessor = DefaultAudioPreprocessor(compressionThresholdBytes: .max)

        let outputURL = preprocessor.processRecording(
            wavURL: wavURL,
            compressedOutputURL: wavURL.deletingPathExtension().appendingPathExtension("flac")
        )

        XCTAssertEqual(outputURL, wavURL)
        XCTAssertEqual(readSamples(from: wavURL).count, originalSamples.count)
    }

    func testProcessRecording_leavesShortSpeechBurstUntouchedWhenDetectorDoesNotTrigger() throws {
        let originalSamples = silentSamples(milliseconds: 300)
            + speechSamples(milliseconds: 60)
            + silentSamples(milliseconds: 300)
        let wavURL = try writeWAV(samples: originalSamples)
        let preprocessor = DefaultAudioPreprocessor(compressionThresholdBytes: .max)

        let outputURL = preprocessor.processRecording(
            wavURL: wavURL,
            compressedOutputURL: wavURL.deletingPathExtension().appendingPathExtension("flac")
        )

        XCTAssertEqual(outputURL, wavURL)
        XCTAssertEqual(readSamples(from: wavURL).count, originalSamples.count)
    }

    func testProcessRecording_returnsCompressedOutputWhenCompressionSucceeds() throws {
        let wavURL = try writeWAV(samples: speechSamples(milliseconds: 400))
        let compressedOutputURL = wavURL.deletingPathExtension().appendingPathExtension("flac")
        let preprocessor = DefaultAudioPreprocessor(
            compressionThresholdBytes: 1,
            compressionHandler: { _, outputURL in
                do {
                    try Data("flac".utf8).write(to: outputURL)
                    return true
                } catch {
                    XCTFail("Expected test compression output to be writable: \(error)")
                    return false
                }
            }
        )

        let outputURL = preprocessor.processRecording(
            wavURL: wavURL,
            compressedOutputURL: compressedOutputURL
        )

        XCTAssertEqual(outputURL, compressedOutputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: compressedOutputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wavURL.path))
    }

    private func writeWAV(samples: [Int16]) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let wavURL = directoryURL.appendingPathComponent("sample.wav")
        let pcmData = samples.withUnsafeBytes { Data($0) }

        var wavData = Data(capacity: 44 + pcmData.count)
        wavData.append(ascii: "RIFF")
        wavData.append(uint32: UInt32(36 + pcmData.count))
        wavData.append(ascii: "WAVE")
        wavData.append(ascii: "fmt ")
        wavData.append(uint32: 16)
        wavData.append(uint16: 1)
        wavData.append(uint16: 1)
        wavData.append(uint32: 16_000)
        wavData.append(uint32: 32_000)
        wavData.append(uint16: 2)
        wavData.append(uint16: 16)
        wavData.append(ascii: "data")
        wavData.append(uint32: UInt32(pcmData.count))
        wavData.append(pcmData)
        try wavData.write(to: wavURL)

        return wavURL
    }

    private func readSamples(from wavURL: URL) -> [Int16] {
        guard let data = try? Data(contentsOf: wavURL), data.count > 44 else { return [] }
        let sampleCount = (data.count - 44) / 2
        return data[44...].withUnsafeBytes { buffer in
            let pointer = buffer.bindMemory(to: Int16.self)
            return Array(pointer.prefix(sampleCount))
        }
    }

    private func silentSamples(milliseconds: Int) -> [Int16] {
        Array(repeating: 0, count: sampleCount(milliseconds: milliseconds))
    }

    private func speechSamples(milliseconds: Int, amplitude: Int16 = 6_000) -> [Int16] {
        Array(repeating: amplitude, count: sampleCount(milliseconds: milliseconds))
    }

    private func sampleCount(milliseconds: Int) -> Int {
        Int((Double(milliseconds) / 1000) * RMSAudioSpeechBoundaryDetector.sampleRate)
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
