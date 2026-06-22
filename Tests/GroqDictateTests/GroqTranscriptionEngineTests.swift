import Foundation
import XCTest
@testable import GroqDictate

final class GroqTranscriptionEngineTests: XCTestCase {
    func testTranscribe_mapsGroqErrorsIntoAppOwnedErrors() {
        let engine = GroqTranscriptionEngine { _, _, completion in
            completion(.failure(.failedDependency("Provider dependency issue")))
            return GroqAPI.TranscriptionRequest()
        }

        var received: Result<String, TranscriptionEngineError>?

        _ = engine.transcribe(
            fileURL: URL(fileURLWithPath: "/tmp/audio.wav"),
            config: sampleConfig()
        ) { result in
            received = result
        }

        XCTAssertEqual(received, .failure(.failedDependency("Provider dependency issue")))
    }

    func testTranscriptionEngineError_usesAppOwnedCopyWhilePreservingDiagnostics() {
        let forbidden = TranscriptionEngineError(.forbidden("Provider says forbidden for org"))
        XCTAssertEqual(forbidden.errorDescription, AppStrings.Errors.accessDenied)
        XCTAssertEqual(forbidden.diagnosticSummary, "Provider says forbidden for org")
        XCTAssertEqual(forbidden.diagnosticCode, "forbidden")

        let badRequest = TranscriptionEngineError(.badRequest("Provider validation details"))
        XCTAssertEqual(badRequest.errorDescription, AppStrings.Errors.requestRejected)
        XCTAssertEqual(badRequest.diagnosticSummary, "Provider validation details")
        XCTAssertEqual(badRequest.diagnosticCode, "bad_request")

        let networkUnavailable = TranscriptionEngineError(.networkUnavailable)
        XCTAssertEqual(networkUnavailable.errorDescription, AppStrings.Errors.networkUnavailable)
        XCTAssertNil(networkUnavailable.diagnosticSummary)
        XCTAssertEqual(networkUnavailable.diagnosticCode, "network_unavailable")

        let unknown = TranscriptionEngineError(.other("HTTP 418"))
        XCTAssertEqual(unknown.errorDescription, AppStrings.Errors.unexpectedTranscriptionError)
        XCTAssertEqual(unknown.diagnosticSummary, "HTTP 418")
        XCTAssertEqual(unknown.diagnosticCode, "other")
    }

    func testGroqTranscriptionRequest_cancelRemovesPreparedUploadEvenWithActiveTask() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("groq-request-cancel-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let uploadURL = directory.appendingPathComponent("upload.multipart")
        try Data("upload".utf8).write(to: uploadURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        let request = GroqAPI.TranscriptionRequest()
        request.setUploadFileURL(uploadURL)
        request.setTask(URLSession.shared.dataTask(with: URL(string: "https://example.com")!))

        request.cancel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: uploadURL.path))
        XCTAssertTrue(request.isCancelled)
    }

    func testTranscriptionRequestHandle_cancelCancelsUnderlyingGroqRequest() {
        var underlyingRequest: GroqAPI.TranscriptionRequest?
        let engine = GroqTranscriptionEngine { _, _, _ in
            let request = GroqAPI.TranscriptionRequest()
            underlyingRequest = request
            return request
        }

        let handle = engine.transcribe(
            fileURL: URL(fileURLWithPath: "/tmp/audio.wav"),
            config: sampleConfig()
        ) { _ in
            XCTFail("Completion should not be called in cancel test")
        }

        XCTAssertFalse(handle.isCancelled)
        XCTAssertFalse(underlyingRequest?.isCancelled ?? true)

        handle.cancel()

        XCTAssertTrue(handle.isCancelled)
        XCTAssertTrue(underlyingRequest?.isCancelled ?? false)
    }

    private func sampleConfig() -> Config {
        Config(
            apiKey: "gsk_test",
            model: Config.DefaultValue.model,
            inputGain: Config.DefaultValue.inputGain,
            micUID: nil
        )
    }
}
