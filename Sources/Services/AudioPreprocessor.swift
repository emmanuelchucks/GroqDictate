import Foundation

protocol AudioPreprocessor {
    func processRecording(wavURL: URL, compressedOutputURL: URL) -> URL
}

struct DefaultAudioPreprocessor: AudioPreprocessor {
    typealias CompressionHandler = (URL, URL) -> Bool
    private static let defaultCompressionThresholdBytes = 1 * 1024 * 1024

    private let compressionThresholdBytes: Int
    private let compressionHandler: CompressionHandler

    init(
        compressionThresholdBytes: Int = defaultCompressionThresholdBytes,
        compressionHandler: @escaping CompressionHandler = Self.compressWAVToFLAC
    ) {
        self.compressionThresholdBytes = compressionThresholdBytes
        self.compressionHandler = compressionHandler
    }

    func processRecording(wavURL: URL, compressedOutputURL: URL) -> URL {
        let originalSize = fileSize(at: wavURL)

        guard originalSize >= compressionThresholdBytes else {
            logPreprocessingResult(
                originalSize: originalSize,
                outputSize: originalSize,
                outputFormat: "wav",
                compressed: false
            )
            return wavURL
        }

        try? FileManager.default.removeItem(at: compressedOutputURL)

        guard compressionHandler(wavURL, compressedOutputURL),
              FileManager.default.fileExists(atPath: compressedOutputURL.path)
        else {
            logPreprocessingResult(
                originalSize: originalSize,
                outputSize: originalSize,
                outputFormat: "wav",
                compressed: false,
                compressionFailed: true
            )
            return wavURL
        }

        let compressedSize = fileSize(at: compressedOutputURL)
        try? FileManager.default.removeItem(at: wavURL)
        logPreprocessingResult(
            originalSize: originalSize,
            outputSize: compressedSize,
            outputFormat: "flac",
            compressed: true
        )
        return compressedOutputURL
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

    private func fileSize(at url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func logPreprocessingResult(
        originalSize: Int,
        outputSize: Int,
        outputFormat: String,
        compressed: Bool,
        compressionFailed: Bool = false
    ) {
        AppLog.metric(
            "audio_preprocess",
            category: .audio,
            level: .debug,
            values: [
                "compressed": compressed ? "true" : "false",
                "compression_failed": compressionFailed ? "true" : "false",
                "original_bytes": String(originalSize),
                "output_bytes": String(outputSize),
                "output_format": outputFormat,
                "threshold_bytes": String(compressionThresholdBytes)
            ]
        )
    }
}
