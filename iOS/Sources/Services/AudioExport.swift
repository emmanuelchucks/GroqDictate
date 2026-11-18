import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers

enum AudioExport {
    /// The recording as M4A at `destination`. A take is raw AAC (ADTS) so it
    /// can be read while it is written; most apps, and Groq, take M4A, so it
    /// is rewrapped without re-encoding. An older part already is M4A.
    static func m4a(from source: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        guard source.pathExtension == "aac" else {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough)
        else { throw CocoaError(.fileReadCorruptFile) }
        export.outputURL = destination
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

/// A recording's audio as shared: an M4A named after when it was recorded,
/// made only when the user picks where to send it.
struct SharedAudio: Transferable {
    let source: URL
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Audio) { audio in
            // One folder for shared copies, emptied each time, so they don't pile up.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Shared audio", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(audio.name).appendingPathExtension("m4a")
            try await AudioExport.m4a(from: audio.source, to: destination)
            return SentTransferredFile(destination)
        }
    }

    /// "GroqDictate 18 Nov 2026 14.05", plus " part 2" when a recording has
    /// more than one take. No colons or slashes, which file names can't hold.
    static func name(recordedAt date: Date, take: Int, of takes: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy HH.mm"
        let base = "GroqDictate \(formatter.string(from: date))"
        return takes > 1 ? "\(base) part \(take)" : base
    }
}
