import XCTest
@testable import GroqDictateIOS

final class TimingDiagnosticsTests: XCTestCase {
    func testRequestIDValidationRejectsUnstructuredHeaderContent() {
        XCTAssertEqual(UploadMetricsDelegate.Transaction.safeRequestID("req_123-ABC"), "req_123-ABC")
        for value in ["", "Bearer secret", "https://example.com", "a\nsecret", String(repeating: "a", count: 129)] {
            XCTAssertNil(UploadMetricsDelegate.Transaction.safeRequestID(value))
        }
        XCTAssertNil(UploadMetricsDelegate.Transaction.safeRequestID(nil))
    }

    func testPersistsOnlyAllowlistedMetadataAndRotates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = TimingDiagnostics(directory: root)
        let id = UUID()
        logger.record(.attemptFailed, requestID: id, sessionID: id, attempt: 1, elapsedSeconds: 60, code: -1001)
        logger.flush()
        let current = root.appendingPathComponent("timing.jsonl")
        let data = try Data(contentsOf: current)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(value.keys), Set(["timestamp", "event", "requestID", "sessionID", "attempt", "elapsedSeconds", "code"]))
        XCTAssertEqual(value["code"] as? Int, -1001)
        XCTAssertEqual(value["sessionID"] as? String, id.uuidString)
        for _ in 0..<2000 { logger.record(.attemptStarted, requestID: id, sessionID: id, attempt: 1) }
        logger.flush()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        for file in files {
            XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 256 * 1024)
        }
    }
}
