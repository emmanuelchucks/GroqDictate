import Foundation
import XCTest
@testable import GroqDictate

final class GroqTranscriptionEngineTests: XCTestCase {
    func testTranscribe_withoutHintsUsesOneRequestAndMapsErrors() {
        var count = 0
        let engine = GroqTranscriptionEngine { _, _, completion in
            count += 1
            completion(.failure(.failedDependency("Provider dependency issue")))
            return GroqAPI.TranscriptionRequest()
        }
        var received: Result<String, TranscriptionEngineError>?

        _ = engine.transcribe(fileURL: URL(fileURLWithPath: "/tmp/audio.wav"), config: sampleConfig()) { received = $0 }

        XCTAssertEqual(count, 1)
        XCTAssertEqual(received, .failure(.failedDependency("Provider dependency issue")))
    }

    func testWithHintsSelectsBetweenRawAndHintedCandidates() {
        var receivedHints: [String] = []
        var candidates: (String, String)?
        let engine = GroqTranscriptionEngine(
            performTranscription: { _, config, completion in
                receivedHints.append(config.vocabularyHints)
                completion(.success(config.vocabularyHints.isEmpty ? "raw" : "hinted"))
                return GroqAPI.TranscriptionRequest()
            },
            selectCandidate: { raw, hinted, _, completion in
                candidates = (raw, hinted)
                completion("B")
                return GroqCandidateSelector.Request()
            }
        )
        var received: Result<String, TranscriptionEngineError>?

        _ = engine.transcribe(fileURL: URL(fileURLWithPath: "/tmp/audio.wav"), config: sampleConfig(hints: "GroqDictate")) { received = $0 }

        XCTAssertEqual(Set(receivedHints), Set(["", "GroqDictate"]))
        XCTAssertEqual(candidates?.0, "raw")
        XCTAssertEqual(candidates?.1, "hinted")
        XCTAssertEqual(received, .success("hinted"))
    }

    func testSelectionFailureFallsBackToRaw() {
        let engine = GroqTranscriptionEngine(
            performTranscription: { _, config, completion in
                completion(.success(config.vocabularyHints.isEmpty ? "raw" : "hinted"))
                return GroqAPI.TranscriptionRequest()
            },
            selectCandidate: { _, _, _, completion in
                completion(nil)
                return GroqCandidateSelector.Request()
            }
        )
        var received: Result<String, TranscriptionEngineError>?
        _ = engine.transcribe(fileURL: URL(fileURLWithPath: "/tmp/audio.wav"), config: sampleConfig(hints: "GroqDictate")) { received = $0 }
        XCTAssertEqual(received, .success("raw"))
    }

    func testOneSuccessfulCandidateDoesNotRequireSelection() {
        var selected = false
        let engine = GroqTranscriptionEngine(
            performTranscription: { _, config, completion in
                if config.vocabularyHints.isEmpty { completion(.success("raw")) }
                else { completion(.failure(.serverError)) }
                return GroqAPI.TranscriptionRequest()
            },
            selectCandidate: { _, _, _, _ in selected = true; return GroqCandidateSelector.Request() }
        )
        var received: Result<String, TranscriptionEngineError>?
        _ = engine.transcribe(fileURL: URL(fileURLWithPath: "/tmp/audio.wav"), config: sampleConfig(hints: "GroqDictate")) { received = $0 }
        XCTAssertFalse(selected)
        XCTAssertEqual(received, .success("raw"))
    }

    func testCancelWithHintsCancelsBothRequests() {
        var requests: [GroqAPI.TranscriptionRequest] = []
        let engine = GroqTranscriptionEngine(
            performTranscription: { _, _, _ in
                let request = GroqAPI.TranscriptionRequest(); requests.append(request); return request
            },
            selectCandidate: { _, _, _, _ in XCTFail("selection should not start"); return GroqCandidateSelector.Request() }
        )
        let handle = engine.transcribe(fileURL: URL(fileURLWithPath: "/tmp/audio.wav"), config: sampleConfig(hints: "GroqDictate")) { _ in XCTFail("completion") }
        handle.cancel()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy(\.isCancelled))
    }

    func testCandidateSelectorParsesOnlyExactChoices() {
        func payload(_ content: String) -> Data {
            try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        }
        XCTAssertEqual(GroqCandidateSelector.parseChoice(from: payload(" A\n")), "A")
        XCTAssertEqual(GroqCandidateSelector.parseChoice(from: payload("b")), "B")
        XCTAssertNil(GroqCandidateSelector.parseChoice(from: payload("Candidate A")))
    }

    private func sampleConfig(hints: String = "") -> Config {
        Config(apiKey: "gsk_test", model: Config.DefaultValue.model, inputGain: 1, micUID: nil, vocabularyHints: hints)
    }
}
