import XCTest
@testable import GroqDictate

final class SetupConfigurationControllerTests: XCTestCase {
    func testModelOptionsUseAccurateDefault() {
        XCTAssertEqual(Config.DefaultValue.model, "whisper-large-v3")
        XCTAssertEqual(Config.modelOptions.map(\.id), ["whisper-large-v3", "whisper-large-v3-turbo"])
        XCTAssertEqual(Config.resolvedModelID("removed-model"), Config.DefaultValue.model)
    }

    func testVocabularyHintsNormalization_trimsSeparatesAndDeduplicates() {
        XCTAssertEqual(
            Config.normalizedVocabularyHints(" GroqDictate, Kasoa\nGROQDICTATE, Kizito ,, "),
            "GroqDictate, Kasoa, Kizito"
        )
    }

    func testMakeState_filtersAggregateDevicesAndRestoresSelections() {
        let controller = makeController(
            loadAPIKey: { "gsk_existing" },
            loadSelectedModelID: { "whisper-large-v3" },
            loadSelectedMicrophoneID: { "usb-mic" },
            loadInputGain: { 4.2 },
            loadVocabularyHints: { " GroqDictate, Kasoa\nGROQDICTATE " },
            loadInputDevices: {
                [
                    AudioDevice(uid: "CADefaultDeviceAggregate-1", name: "System Aggregate", deviceID: 1),
                    AudioDevice(uid: "built-in", name: "MacBook Microphone", deviceID: 2),
                    AudioDevice(uid: "usb-mic", name: "USB Mic", deviceID: 3)
                ]
            }
        )

        XCTAssertEqual(
            controller.makeState(),
            SetupConfigurationState(
                existingAPIKey: "gsk_existing",
                selectedModelID: "whisper-large-v3",
                modelOptions: Config.modelOptions,
                microphoneOptions: [.init(id: "built-in", title: "MacBook Microphone"), .init(id: "usb-mic", title: "USB Mic")],
                selectedMicrophoneID: "usb-mic",
                inputGain: 4.2,
                vocabularyHints: "GroqDictate, Kasoa"
            )
        )
    }

    func testSave_rejectsInvalidKeysAndOverlongHintsWithoutPersistence() {
        var didPersist = false
        var didValidate = false
        let controller = makeController(
            saveAPIKey: { _ in didPersist = true },
            savePreferences: { _, _, _, _ in didPersist = true },
            validateRemotely: { _, _, _ in didValidate = true }
        )

        assertSave(controller, .init(apiKey: " ", selectedModelID: Config.DefaultValue.model, selectedMicrophoneID: nil, inputGain: 1, vocabularyHints: ""), .failure(.emptyAPIKey))
        assertSave(controller, .init(apiKey: "sk_wrong", selectedModelID: Config.DefaultValue.model, selectedMicrophoneID: nil, inputGain: 1, vocabularyHints: ""), .failure(.invalidAPIKey))
        assertSave(
            controller,
            .init(apiKey: "gsk_test", selectedModelID: Config.DefaultValue.model, selectedMicrophoneID: nil, inputGain: 1, vocabularyHints: String(repeating: "a", count: 501)),
            .failure(.vocabularyHintsTooLong)
        )
        XCTAssertFalse(didPersist)
        XCTAssertFalse(didValidate)
    }

    func testSave_persistsNormalizedValuesAfterValidation() {
        var saved: (String, String, String?, Float, String)?
        let controller = makeController(
            loadInputDevices: { [AudioDevice(uid: "built-in", name: "MacBook Microphone", deviceID: 1)] },
            saveAPIKey: { key in
                if let prior = saved { saved = (key, prior.1, prior.2, prior.3, prior.4) }
                else { saved = (key, "", nil, 0, "") }
            },
            savePreferences: { model, mic, gain, hints in
                let key = saved?.0 ?? ""
                saved = (key, model, mic, gain, hints)
            },
            validateRemotely: { _, _, completion in completion(.valid) }
        )

        assertSave(
            controller,
            .init(apiKey: " gsk_live ", selectedModelID: "whisper-large-v3", selectedMicrophoneID: "missing", inputGain: 3.5, vocabularyHints: " GroqDictate, Kasoa\ngroqdictate "),
            .success(())
        )
        XCTAssertEqual(saved?.0, "gsk_live")
        XCTAssertEqual(saved?.1, "whisper-large-v3")
        XCTAssertNil(saved?.2)
        XCTAssertEqual(saved?.3, 3.5)
        XCTAssertEqual(saved?.4, "GroqDictate, Kasoa")
    }

    func testSave_blocksDefinitiveRemoteFailures() {
        let cases: [(GroqModelValidationResult, SetupSaveError)] = [
            (.invalidKey, .remoteInvalidKey),
            (.accountRestricted, .remoteAccountRestricted),
            (.modelUnavailable, .remoteModelUnavailable),
            (.other("bad response"), .remoteValidationFailed("bad response"))
        ]
        for (result, expected) in cases {
            assertSave(
                makeController(validateRemotely: { _, _, completion in completion(result) }),
                .init(apiKey: "gsk_test", selectedModelID: Config.DefaultValue.model, selectedMicrophoneID: nil, inputGain: 1, vocabularyHints: ""),
                .failure(expected)
            )
        }
    }

    private func assertSave(
        _ controller: SetupConfigurationController,
        _ request: SetupSaveRequest,
        _ expected: Result<Void, SetupSaveError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = expectation(description: "save")
        var received: Result<Void, SetupSaveError>?
        controller.save(request) { received = $0; expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        switch (received, expected) {
        case (.success, .success): break
        case (.failure(let lhs), .failure(let rhs)): XCTAssertEqual(lhs, rhs, file: file, line: line)
        default: XCTFail("Expected \(expected), got \(String(describing: received))", file: file, line: line)
        }
    }

    private func makeController(
        loadAPIKey: @escaping () -> String? = { nil },
        loadSelectedModelID: @escaping () -> String? = { nil },
        loadSelectedMicrophoneID: @escaping () -> String? = { nil },
        loadInputGain: @escaping () -> Float = { 0 },
        loadVocabularyHints: @escaping () -> String? = { nil },
        loadInputDevices: @escaping () -> [AudioDevice] = { [] },
        saveAPIKey: @escaping (String) throws -> Void = { _ in },
        savePreferences: @escaping (String, String?, Float, String) -> Void = { _, _, _, _ in },
        validateRemotely: @escaping SetupConfigurationController.RemoteValidation = { _, _, completion in completion(.networkUnavailable) }
    ) -> SetupConfigurationController {
        SetupConfigurationController(
            loadAPIKey: loadAPIKey,
            loadSelectedModelID: loadSelectedModelID,
            loadSelectedMicrophoneID: loadSelectedMicrophoneID,
            loadInputGain: loadInputGain,
            loadVocabularyHints: loadVocabularyHints,
            loadInputDevices: loadInputDevices,
            saveAPIKey: saveAPIKey,
            savePreferences: savePreferences,
            validateRemotely: validateRemotely
        )
    }
}
