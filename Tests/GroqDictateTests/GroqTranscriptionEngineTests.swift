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

        let unknown = TranscriptionEngineError(.other("HTTP 418"))
        XCTAssertEqual(unknown.errorDescription, AppStrings.Errors.unexpectedTranscriptionError)
        XCTAssertEqual(unknown.diagnosticSummary, "HTTP 418")
        XCTAssertEqual(unknown.diagnosticCode, "other")
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
            language: Config.DefaultValue.language,
            inputGain: Config.DefaultValue.inputGain,
            micUID: nil
        )
    }
}
