import XCTest
@testable import GroqDictate

final class SetupConfigurationControllerTests: XCTestCase {
    func testMakeState_filtersAggregateDevicesAndRestoresSavedSelections() {
        let controller = makeController(
            loadAPIKey: { "gsk_existing" },
            loadSelectedModelID: { "whisper-large-v3-turbo" },
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
                selectedModelID: "whisper-large-v3-turbo",
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
            loadSelectedModelID: { "missing-model" },
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

        let emptyKeyResult = controller.save(
            .init(apiKey: "   ", selectedModelID: Config.DefaultValue.model, selectedMicrophoneID: nil, inputGain: 5)
        )
        if case .failure(.emptyAPIKey) = emptyKeyResult {
        } else {
            XCTFail("Expected empty API key validation failure")
        }

        let invalidKeyResult = controller.save(
            .init(apiKey: "abc123", selectedModelID: Config.DefaultValue.model, selectedMicrophoneID: nil, inputGain: 5)
        )
        if case .failure(.invalidAPIKey) = invalidKeyResult {
        } else {
            XCTFail("Expected invalid API key validation failure")
        }
        XCTAssertTrue(savedAPIKeys.isEmpty)
        XCTAssertTrue(savedPreferences.isEmpty)
    }

    func testSave_persistsTrimmedKeyAndCanonicalPreferences() {
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
            }
        )

        let result = controller.save(
            .init(
                apiKey: "  gsk_live_key  ",
                selectedModelID: "missing-model",
                selectedMicrophoneID: "missing-mic",
                inputGain: 3.5
            )
        )

        if case .success = result {
        } else {
            XCTFail("Expected successful save result")
        }
        XCTAssertEqual(savedAPIKey, "gsk_live_key")
        XCTAssertEqual(savedModel, Config.DefaultValue.model)
        XCTAssertNil(savedMicrophone)
        XCTAssertEqual(savedGain, 3.5)
    }

    private func makeController(
        loadAPIKey: @escaping () -> String? = { nil },
        loadSelectedModelID: @escaping () -> String? = { nil },
        loadSelectedMicrophoneID: @escaping () -> String? = { nil },
        loadInputGain: @escaping () -> Float = { 0 },
        loadInputDevices: @escaping () -> [AudioDevice] = { [] },
        saveAPIKey: @escaping (String) throws -> Void = { _ in },
        savePreferences: @escaping (String, String?, Float) -> Void = { _, _, _ in }
    ) -> SetupConfigurationController {
        SetupConfigurationController(
            loadAPIKey: loadAPIKey,
            loadSelectedModelID: loadSelectedModelID,
            loadSelectedMicrophoneID: loadSelectedMicrophoneID,
            loadInputGain: loadInputGain,
            loadInputDevices: loadInputDevices,
            saveAPIKey: saveAPIKey,
            savePreferences: savePreferences
        )
    }
}
