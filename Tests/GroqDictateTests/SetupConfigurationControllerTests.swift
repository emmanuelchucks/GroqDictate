import XCTest
@testable import GroqDictate

final class SetupConfigurationControllerTests: XCTestCase {
    func testModelOptionsUseAccurateDefaultAndExcludeRemovedDistilModel() {
        XCTAssertEqual(Config.DefaultValue.model, "whisper-large-v3")
        XCTAssertEqual(Config.modelOptions.map(\.id), ["whisper-large-v3", "whisper-large-v3-turbo"])
        XCTAssertEqual(Config.resolvedModelID("distil-whisper-large-v3-en"), Config.DefaultValue.model)
    }

    func testMakeState_filtersAggregateDevicesAndRestoresSavedSelections() {
        let controller = makeController(
            loadAPIKey: { "gsk_existing" },
            loadSelectedModelID: { "whisper-large-v3" },
            loadSelectedMicrophoneID: { "usb-mic" },
            loadInputGain: { 4.2 },
            loadInputDevices: {
                [
                    AudioDevice(uid: "CADefaultDeviceAggregate-1", name: "System Aggregate", deviceID: 1),
                    AudioDevice(uid: "built-in", name: "MacBook Microphone", deviceID: 2),
                    AudioDevice(uid: "usb-mic", name: "USB Mic", deviceID: 3)
                ]
            }
        )

        let state = controller.makeState()

        XCTAssertEqual(
            state,
            SetupConfigurationState(
                existingAPIKey: "gsk_existing",
                selectedModelID: "whisper-large-v3",
                modelOptions: Config.modelOptions,
                microphoneOptions: [
                    .init(id: "built-in", title: "MacBook Microphone"),
                    .init(id: "usb-mic", title: "USB Mic")
                ],
                selectedMicrophoneID: "usb-mic",
                inputGain: 4.2
            )
        )
    }

    func testMakeState_fallsBackWhenSavedSelectionsAreNoLongerAvailable() {
        let controller = makeController(
            loadSelectedModelID: { "distil-whisper-large-v3-en" },
            loadSelectedMicrophoneID: { "missing-mic" },
            loadInputGain: { 0 },
            loadInputDevices: {
                [AudioDevice(uid: "built-in", name: "MacBook Microphone", deviceID: 1)]
            }
        )

        let state = controller.makeState()

        XCTAssertEqual(state.selectedModelID, Config.DefaultValue.model)
        XCTAssertNil(state.selectedMicrophoneID)
        XCTAssertEqual(state.inputGain, Config.DefaultValue.inputGain)
    }

    func testSave_rejectsInvalidKeysWithoutPersisting() {
        var savedAPIKeys: [String] = []
        var savedPreferences: [(String, String?, Float)] = []

        let controller = makeController(
            saveAPIKey: { key in
                savedAPIKeys.append(key)
            },
            savePreferences: { model, mic, gain in
                savedPreferences.append((model, mic, gain))
            }
        )

        assertSave(controller, request: .init(apiKey: "   ", selectedModelID: Config.DefaultValue.model, selectedMicrophoneID: nil, inputGain: 5), equals: .failure(.emptyAPIKey))
        assertSave(controller, request: .init(apiKey: "abc123", selectedModelID: Config.DefaultValue.model, selectedMicrophoneID: nil, inputGain: 5), equals: .failure(.invalidAPIKey))
        XCTAssertTrue(savedAPIKeys.isEmpty)
        XCTAssertTrue(savedPreferences.isEmpty)
    }

    func testSave_persistsAfterSuccessfulRemoteValidation() {
        var savedAPIKey: String?
        var savedModel: String?
        var savedMicrophone: String?
        var savedGain: Float?

        let controller = makeController(
            loadInputDevices: {
                [AudioDevice(uid: "built-in", name: "MacBook Microphone", deviceID: 1)]
            },
            saveAPIKey: { key in
                savedAPIKey = key
            },
            savePreferences: { model, mic, gain in
                savedModel = model
                savedMicrophone = mic
                savedGain = gain
            },
            validateRemotely: { _, _, completion in completion(.valid) }
        )

        assertSave(
            controller,
            request: .init(
                apiKey: "  gsk_live_key  ",
                selectedModelID: "whisper-large-v3",
                selectedMicrophoneID: "missing-mic",
                inputGain: 3.5
            ),
            equals: .success(())
        )

        XCTAssertEqual(savedAPIKey, "gsk_live_key")
        XCTAssertEqual(savedModel, "whisper-large-v3")
        XCTAssertNil(savedMicrophone)
        XCTAssertEqual(savedGain, 3.5)
    }

    func testSave_allowsLocallyValidKeyWhenRemoteValidationIsUnavailable() {
        var savedAPIKey: String?
        let controller = makeController(
            saveAPIKey: { savedAPIKey = $0 },
            validateRemotely: { _, _, completion in completion(.networkUnavailable) }
        )

        assertSave(
            controller,
            request: .init(apiKey: "gsk_offline", selectedModelID: Config.DefaultValue.model, selectedMicrophoneID: nil, inputGain: 2),
            equals: .success(())
        )
        XCTAssertEqual(savedAPIKey, "gsk_offline")
    }

    func testSave_blocksDefinitiveRemoteValidationFailures() {
        let cases: [(GroqModelValidationResult, SetupSaveError)] = [
            (.invalidKey, .remoteInvalidKey),
            (.accountRestricted, .remoteAccountRestricted),
            (.modelUnavailable, .remoteModelUnavailable),
            (.other("bad response"), .remoteValidationFailed("bad response"))
        ]

        for (validationResult, expectedError) in cases {
            var didPersist = false
            let controller = makeController(
                saveAPIKey: { _ in didPersist = true },
                savePreferences: { _, _, _ in didPersist = true },
                validateRemotely: { _, _, completion in completion(validationResult) }
            )

            assertSave(
                controller,
                request: .init(apiKey: "gsk_test", selectedModelID: Config.DefaultValue.model, selectedMicrophoneID: nil, inputGain: 2),
                equals: .failure(expectedError)
            )
            XCTAssertFalse(didPersist)
        }
    }

    private func assertSave(
        _ controller: SetupConfigurationController,
        request: SetupSaveRequest,
        equals expected: Result<Void, SetupSaveError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = expectation(description: "save completes")
        var received: Result<Void, SetupSaveError>?

        controller.save(request) { result in
            received = result
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        assertResult(received, expected, file: file, line: line)
    }

    private func assertResult(
        _ received: Result<Void, SetupSaveError>?,
        _ expected: Result<Void, SetupSaveError>,
        file: StaticString,
        line: UInt
    ) {
        switch (received, expected) {
        case (.success, .success):
            break
        case (.failure(let receivedError), .failure(let expectedError)):
            XCTAssertEqual(receivedError, expectedError, file: file, line: line)
        default:
            XCTFail("Expected \(expected), received \(String(describing: received))", file: file, line: line)
        }
    }

    private func makeController(
        loadAPIKey: @escaping () -> String? = { nil },
        loadSelectedModelID: @escaping () -> String? = { nil },
        loadSelectedMicrophoneID: @escaping () -> String? = { nil },
        loadInputGain: @escaping () -> Float = { 0 },
        loadInputDevices: @escaping () -> [AudioDevice] = { [] },
        saveAPIKey: @escaping (String) throws -> Void = { _ in },
        savePreferences: @escaping (String, String?, Float) -> Void = { _, _, _ in },
        validateRemotely: @escaping SetupConfigurationController.RemoteValidation = { _, _, completion in completion(.networkUnavailable) }
    ) -> SetupConfigurationController {
        SetupConfigurationController(
            loadAPIKey: loadAPIKey,
            loadSelectedModelID: loadSelectedModelID,
            loadSelectedMicrophoneID: loadSelectedMicrophoneID,
            loadInputGain: loadInputGain,
            loadInputDevices: loadInputDevices,
            saveAPIKey: saveAPIKey,
            savePreferences: savePreferences,
            validateRemotely: validateRemotely
        )
    }
}
