import XCTest
@testable import GroqDictateIOS

final class ADTSTests: XCTestCase {
    func testCountsWholeFramesAndTheirAudio() {
        let data = Self.frame(length: 100) + Self.frame(length: 120) + Self.frame(length: 90)
        XCTAssertEqual(ADTS.wholeFrames(in: data), ADTS.Frames(
            count: 3, byteCount: 310, seconds: 3 * 1024 / 16_000, lastFrameStart: 220, lastFrameSeconds: 1024 / 16_000
        ))
    }

    func testStopsBeforeAFrameCutShort() {
        let data = Self.frame(length: 100) + Self.frame(length: 120).prefix(50)
        XCTAssertEqual(ADTS.wholeFrames(in: data).byteCount, 100)
        XCTAssertEqual(ADTS.wholeFrames(in: data).count, 1)
        XCTAssertEqual(ADTS.wholeFrames(in: Self.frame(length: 100).prefix(5)).byteCount, 0, "a cut header")
    }

    func testStopsAtBytesThatArentAFrame() {
        let data = Self.frame(length: 100) + Data(repeating: 0, count: 300)
        XCTAssertEqual(ADTS.wholeFrames(in: data).byteCount, 100)
        XCTAssertEqual(ADTS.wholeFrames(in: Data()), ADTS.Frames())
    }

    func testReadsFromASliceOfALargerFile() {
        let file = Self.frame(length: 100) + Self.frame(length: 80)
        XCTAssertEqual(ADTS.wholeFrames(in: file[100...]).byteCount, 80)
        XCTAssertEqual(ADTS.wholeFrames(in: file[100...]).lastFrameStart, 0, "offsets are from the slice's start")
    }

    /// A 16 kHz mono AAC-LC frame header, no CRC, one raw block, padded to `length`.
    private static func frame(length: Int) -> Data {
        var bytes: [UInt8] = [0xFF, 0xF1, 0x60, 0x40, 0, 0, 0xFC]
        bytes[2] = (1 << 6) | (8 << 2)
        bytes[3] = 0x40 | UInt8((length >> 11) & 0x03)
        bytes[4] = UInt8((length >> 3) & 0xFF)
        bytes[5] = UInt8((length & 0x07) << 5) | 0x1F
        return Data(bytes + [UInt8](repeating: 0x21, count: length - 7))
    }
}
