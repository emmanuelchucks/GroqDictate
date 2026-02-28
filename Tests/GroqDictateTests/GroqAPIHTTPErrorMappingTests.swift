import Foundation
import XCTest
@testable import GroqDictate

final class GroqAPIHTTPErrorMappingTests: XCTestCase {
    func testMapHTTPError_knownStatusMappings() {
        XCTAssertTrue(matches(GroqAPI.mapHTTPError(status: 401, headers: makeResponse(status: 401), body: Data()), .invalidKey))
        XCTAssertTrue(matches(GroqAPI.mapHTTPError(status: 404, headers: makeResponse(status: 404), body: Data()), .notFound))
        XCTAssertTrue(matches(GroqAPI.mapHTTPError(status: 413, headers: makeResponse(status: 413), body: Data()), .tooLarge))
        XCTAssertTrue(matches(GroqAPI.mapHTTPError(status: 498, headers: makeResponse(status: 498), body: Data()), .capacityExceeded))
        XCTAssertTrue(matches(GroqAPI.mapHTTPError(status: 500, headers: makeResponse(status: 500), body: Data()), .serverError))
        XCTAssertTrue(matches(GroqAPI.mapHTTPError(status: 503, headers: makeResponse(status: 503), body: Data()), .serverError))
    }

    func testMapHTTPError_forbiddenRestrictedBecomesAccountRestricted() {
        let body = Data("{\"error\":{\"message\":\"Organization restricted for this model\"}}".utf8)
        let result = GroqAPI.mapHTTPError(status: 403, headers: makeResponse(status: 403), body: body)

        XCTAssertTrue(matches(result, .accountRestricted))
    }

    func testMapHTTPError_rateLimitedUsesRetryAfterHeaderOrDefault() {
        let explicit = GroqAPI.mapHTTPError(
            status: 429,
            headers: makeResponse(status: 429, headers: ["Retry-After": "42"]),
            body: Data()
        )
        let fallback = GroqAPI.mapHTTPError(status: 429, headers: makeResponse(status: 429), body: Data())

        guard case .rateLimited(let explicitSeconds) = explicit else {
            return XCTFail("Expected rateLimited for explicit Retry-After")
        }
        guard case .rateLimited(let fallbackSeconds) = fallback else {
            return XCTFail("Expected rateLimited for missing Retry-After")
        }

        XCTAssertEqual(explicitSeconds, 42)
        XCTAssertEqual(fallbackSeconds, 10)
    }

    func testMapHTTPError_defaultUsesMessageThenStatusCode() {
        let body = Data("{\"error\":{\"message\":\"Custom API error\"}}".utf8)
        let withMessage = GroqAPI.mapHTTPError(status: 418, headers: makeResponse(status: 418), body: body)
        let withoutMessage = GroqAPI.mapHTTPError(status: 418, headers: makeResponse(status: 418), body: Data())

        guard case .other(let message) = withMessage else {
            return XCTFail("Expected other(message) for unknown status with payload")
        }
        XCTAssertEqual(message, "Custom API error")

        guard case .other(let fallbackMessage) = withoutMessage else {
            return XCTFail("Expected other(message) for unknown status without payload")
        }
        XCTAssertEqual(fallbackMessage, "HTTP 418")
    }

    private func makeResponse(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )

        guard let response else {
            fatalError("Failed to create HTTPURLResponse")
        }

        return response
    }

    private func matches(_ lhs: GroqAPI.TranscriptionError, _ rhs: GroqAPI.TranscriptionError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidKey, .invalidKey),
             (.notFound, .notFound),
             (.tooLarge, .tooLarge),
             (.capacityExceeded, .capacityExceeded),
             (.serverError, .serverError),
             (.accountRestricted, .accountRestricted):
            return true
        default:
            return false
        }
    }
}

final class PermissionServiceGuidanceMappingTests: XCTestCase {
    func testGuidanceActions_returnsEmptyWhenPermissionsAreSufficient() {
        let snapshot = PermissionService.Snapshot(
            microphone: .authorized,
            accessibility: .trusted,
            listenEvent: .granted,
            postEvent: .granted
        )

        XCTAssertEqual(PermissionService.guidanceActions(for: snapshot), [])
    }

    func testGuidanceActions_returnsAccessibilityDeniedWhenNotTrusted() {
        let snapshot = PermissionService.Snapshot(
            microphone: .authorized,
            accessibility: .notTrusted,
            listenEvent: .granted,
            postEvent: .granted
        )

        XCTAssertEqual(PermissionService.guidanceActions(for: snapshot), [.accessibilityDenied])
    }

    func testGuidanceActions_returnsInputMonitoringDeniedWhenListenEventDenied() {
        let snapshot = PermissionService.Snapshot(
            microphone: .authorized,
            accessibility: .trusted,
            listenEvent: .denied,
            postEvent: .granted
        )

        XCTAssertEqual(PermissionService.guidanceActions(for: snapshot), [.inputMonitoringDenied])
    }

    func testGuidanceActions_returnsBothActionsInStableOrder() {
        let snapshot = PermissionService.Snapshot(
            microphone: .denied,
            accessibility: .notTrusted,
            listenEvent: .denied,
            postEvent: .denied
        )

        XCTAssertEqual(
            PermissionService.guidanceActions(for: snapshot),
            [.accessibilityDenied, .inputMonitoringDenied]
        )
    }
}
