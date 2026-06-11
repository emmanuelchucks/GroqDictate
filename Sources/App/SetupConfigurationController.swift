import Foundation

struct SetupConfigurationState: Equatable {
    struct MicrophoneOption: Equatable {
        let id: String?
        let title: String
    }

    let existingAPIKey: String
    let selectedModelID: String
    let modelOptions: [Config.ModelOption]
    let microphoneOptions: [MicrophoneOption]
    let selectedMicrophoneID: String?
    let inputGain: Float
}

struct SetupSaveRequest: Equatable {
    let apiKey: String
    let selectedModelID: String
    let selectedMicrophoneID: String?
    let inputGain: Float
}

enum SetupSaveError: Error, Equatable {
    case emptyAPIKey
    case invalidAPIKey
    case keychainFailure(String)
    case remoteInvalidKey
    case remoteAccountRestricted
    case remoteModelUnavailable
    case remoteValidationFailed(String)
}

final class SetupConfigurationController {
    typealias RemoteValidation = (String, String, @escaping (GroqModelValidationResult) -> Void) -> Void

    private let loadAPIKey: () -> String?
    private let loadSelectedModelID: () -> String?
    private let loadSelectedMicrophoneID: () -> String?
    private let loadInputGain: () -> Float
    private let loadInputDevices: () -> [AudioDevice]
    private let saveAPIKey: (String) throws -> Void
    private let savePreferences: (String, String?, Float) -> Void
    private let validateRemotely: RemoteValidation

    convenience init() {
        self.init(
            loadAPIKey: {
                KeychainHelper.load(key: Config.KeychainKey.apiKey)
            },
            loadSelectedModelID: {
                UserDefaults.standard.string(forKey: Config.DefaultsKey.model)
            },
            loadSelectedMicrophoneID: {
                UserDefaults.standard.string(forKey: Config.DefaultsKey.micUID)
            },
            loadInputGain: {
                UserDefaults.standard.float(forKey: Config.DefaultsKey.inputGain)
            },
            loadInputDevices: AudioRecorder.availableInputDevices,
            saveAPIKey: Config.saveAPIKey,
            savePreferences: Config.savePreferences,
            validateRemotely: GroqModelValidator.validate
        )
    }

    init(
        loadAPIKey: @escaping () -> String?,
        loadSelectedModelID: @escaping () -> String?,
        loadSelectedMicrophoneID: @escaping () -> String?,
        loadInputGain: @escaping () -> Float,
        loadInputDevices: @escaping () -> [AudioDevice],
        saveAPIKey: @escaping (String) throws -> Void,
        savePreferences: @escaping (String, String?, Float) -> Void,
        validateRemotely: @escaping RemoteValidation = { _, _, completion in completion(.networkUnavailable) }
    ) {
        self.loadAPIKey = loadAPIKey
        self.loadSelectedModelID = loadSelectedModelID
        self.loadSelectedMicrophoneID = loadSelectedMicrophoneID
        self.loadInputGain = loadInputGain
        self.loadInputDevices = loadInputDevices
        self.saveAPIKey = saveAPIKey
        self.savePreferences = savePreferences
        self.validateRemotely = validateRemotely
    }

    func makeState() -> SetupConfigurationState {
        let modelOptions = Config.modelOptions
        let selectedModelID = Config.resolvedModelID(loadSelectedModelID())
        let microphoneOptions = filteredMicrophoneOptions(from: loadInputDevices())
        let selectedMicrophoneID = resolvedSelectedMicrophoneID(
            from: loadSelectedMicrophoneID(),
            options: microphoneOptions
        )
        let savedGain = loadInputGain()
        let inputGain = savedGain > 0 ? savedGain : Config.DefaultValue.inputGain

        return SetupConfigurationState(
            existingAPIKey: loadAPIKey() ?? "",
            selectedModelID: selectedModelID,
            modelOptions: modelOptions,
            microphoneOptions: microphoneOptions,
            selectedMicrophoneID: selectedMicrophoneID,
            inputGain: inputGain
        )
    }

    func save(_ request: SetupSaveRequest, completion: @escaping (Result<Void, SetupSaveError>) -> Void) {
        let key = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            AppLog.metric("setup_validation", category: .app, level: .event, values: ["result": "empty_key", "stage": "local"])
            completion(.failure(.emptyAPIKey))
            return
        }
        guard key.hasPrefix("gsk_") else {
            AppLog.metric("setup_validation", category: .app, level: .event, values: ["result": "invalid_prefix", "stage": "local"])
            completion(.failure(.invalidAPIKey))
            return
        }

        let state = makeState()
        let selectedModelID = Config.resolvedModelID(request.selectedModelID)
        let selectedMicrophoneID = resolvedSelectedMicrophoneID(
            from: request.selectedMicrophoneID,
            options: state.microphoneOptions
        )

        validateRemotely(key, selectedModelID) { [saveAPIKey, savePreferences] validationResult in
            AppLog.metric(
                "setup_validation",
                category: .app,
                level: .event,
                values: [
                    "model": selectedModelID,
                    "result": Self.describe(validationResult),
                    "stage": "remote"
                ]
            )

            switch validationResult {
            case .valid, .networkUnavailable, .serviceUnavailable:
                do {
                    try saveAPIKey(key)
                    savePreferences(selectedModelID, selectedMicrophoneID, request.inputGain)
                    AppLog.metric(
                        "setup_save",
                        category: .app,
                        level: .event,
                        values: [
                            "model": selectedModelID,
                            "remote_validation": Self.describe(validationResult),
                            "result": "saved"
                        ]
                    )
                    completion(.success(()))
                } catch {
                    completion(.failure(.keychainFailure(error.localizedDescription)))
                }
            case .invalidKey:
                completion(.failure(.remoteInvalidKey))
            case .accountRestricted:
                completion(.failure(.remoteAccountRestricted))
            case .modelUnavailable:
                completion(.failure(.remoteModelUnavailable))
            case .other(let message):
                completion(.failure(.remoteValidationFailed(message)))
            }
        }
    }

    private static func describe(_ result: GroqModelValidationResult) -> String {
        switch result {
        case .valid: return "valid"
        case .invalidKey: return "invalid_key"
        case .accountRestricted: return "account_restricted"
        case .modelUnavailable: return "model_unavailable"
        case .networkUnavailable: return "network_unavailable_allowed"
        case .serviceUnavailable: return "service_unavailable_allowed"
        case .other: return "other"
        }
    }

    private func filteredMicrophoneOptions(from devices: [AudioDevice]) -> [SetupConfigurationState.MicrophoneOption] {
        devices.compactMap { device in
            guard !device.uid.contains("CADefaultDeviceAggregate") else { return nil }
            guard !device.name.contains("CADefaultDevice") else { return nil }
            return .init(id: device.uid, title: device.name)
        }
    }

    private func resolvedSelectedMicrophoneID(
        from storedValue: String?,
        options: [SetupConfigurationState.MicrophoneOption]
    ) -> String? {
        guard let storedValue, !storedValue.isEmpty else { return nil }
        guard options.contains(where: { $0.id == storedValue }) else { return nil }
        return storedValue
    }
}
