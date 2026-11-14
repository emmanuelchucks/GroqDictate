import Foundation

/// Raw AAC as `AVAudioRecorder` writes it for a `.aac` file: frames that
/// each carry a header with their own length, so a file can be read up to
/// its last whole frame while it is still being written or after a kill.
enum ADTS {
    struct Frames: Equatable {
        var count = 0
        /// Bytes from the start of the data to the end of the last whole frame.
        var byteCount = 0
        var seconds = 0.0
        /// Where the last whole frame starts, and its length in seconds.
        var lastFrameStart = 0
        var lastFrameSeconds = 0.0
    }

    private static let sampleRates: [Double] = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350,
    ]

    /// Whole frames from the start of `data`, stopping at the first byte that
    /// doesn't start a frame or at a frame cut short.
    static func wholeFrames(in data: Data) -> Frames {
        var frames = Frames()
        var offset = data.startIndex
        while offset + 7 <= data.endIndex {
            let header = data[offset..<(offset + 7)].map { $0 }
            guard header[0] == 0xFF, header[1] & 0xF6 == 0xF0 else { break }
            let rateIndex = Int((header[2] >> 2) & 0x0F)
            let length = Int(header[3] & 0x03) << 11 | Int(header[4]) << 3 | Int(header[5]) >> 5
            guard rateIndex < sampleRates.count, length >= 7, offset + length <= data.endIndex else { break }
            let seconds = Double((Int(header[6] & 0x03) + 1) * 1024) / sampleRates[rateIndex]
            frames.count += 1
            frames.lastFrameStart = offset - data.startIndex
            frames.lastFrameSeconds = seconds
            frames.seconds += seconds
            offset += length
        }
        frames.byteCount = offset - data.startIndex
        return frames
    }
}
