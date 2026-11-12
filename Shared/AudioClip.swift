import Foundation
#if canImport(AVFoundation)
import AVFoundation

enum AudioClip {
    /// A temporary M4A of one stretch of a recording, so that stretch can be
    /// sent to Groq on its own. The recording itself is never changed; the
    /// caller deletes the clip.
    static func m4a(from fileURL: URL, range: ClosedRange<Double>) async -> URL? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("groqdictate-clip-\(UUID().uuidString).m4a")
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: fileURL), presetName: AVAssetExportPresetAppleM4A)
        else { return nil }
        export.outputURL = output
        export.outputFileType = .m4a
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: 1000),
            end: CMTime(seconds: range.upperBound, preferredTimescale: 1000)
        )
        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        return output
    }
}
#endif
