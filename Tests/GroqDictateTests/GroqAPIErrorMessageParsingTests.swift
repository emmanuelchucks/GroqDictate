import Foundation
import XCTest
@testable import GroqDictate

final class GroqAPIErrorMessageParsingTests: XCTestCase {
    func testParseAPIErrorMessage_extractsAndSanitizesJSONMessage() throws {
        let payload = try JSONSerialization.data(
            withJSONObject: ["error": ["message": "  Too\n many\t spaces   here  "]]
        )

        let message = GroqAPI.parseAPIErrorMessage(from: payload)

        XCTAssertEqual(message, "Too many spaces here")
    }

    func testParseAPIErrorMessage_fallsBackToRawBodyAndSanitizes() {
        let payload = Data("   raw\nmessage\twith    spacing   ".utf8)

        let message = GroqAPI.parseAPIErrorMessage(from: payload)

        XCTAssertEqual(message, "raw message with spacing")
    }

    func testParseAPIErrorMessage_truncatesTo80Characters() {
        let raw = String(repeating: "a", count: 120)

        let message = GroqAPI.parseAPIErrorMessage(from: Data(raw.utf8))

        XCTAssertEqual(message?.count, 80)
        XCTAssertEqual(message, String(repeating: "a", count: 80))
    }

    func testParseAPIErrorMessage_returnsNilForEmptyOrUnreadablePayload() {
        XCTAssertNil(GroqAPI.parseAPIErrorMessage(from: Data()))

        let nonUTF8 = Data([0xFF, 0xFE, 0xFD])
        XCTAssertNil(GroqAPI.parseAPIErrorMessage(from: nonUTF8))
    }
}
