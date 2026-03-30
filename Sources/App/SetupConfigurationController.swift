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
}

final class SetupConfigurationController {
    private let loadAPIKey: () -> String?
    private let loadSelectedModelID: () -> String?
    private let loadSelectedMicrophoneID: () -> String?
    private let loadInputGain: () -> Float
    private let loadInputDevices: () -> [AudioDevice]
    private let saveAPIKey: (String) throws -> Void
    private let savePreferences: (String, String?, Float) -> Void

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
            savePreferences: Config.savePreferences
        )
    }

    init(
        loadAPIKey: @escaping () -> String?,
        loadSelectedModelID: @escaping () -> String?,
        loadSelectedMicrophoneID: @escaping () -> String?,
        loadInputGain: @escaping () -> Float,
        loadInputDevices: @escaping () -> [AudioDevice],
        saveAPIKey: @escaping (String) throws -> Void,
        savePreferences: @escaping (String, String?, Float) -> Void
    ) {
        self.loadAPIKey = loadAPIKey
        self.loadSelectedModelID = loadSelectedModelID
        self.loadSelectedMicrophoneID = loadSelectedMicrophoneID
        self.loadInputGain = loadInputGain
        self.loadInputDevices = loadInputDevices
        self.saveAPIKey = saveAPIKey
        self.savePreferences = savePreferences
    }

    func makeState() -> SetupConfigurationState {
        let modelOptions = Config.modelOptions
        let selectedModelID = resolvedSelectedModelID(from: loadSelectedModelID(), options: modelOptions)
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

    func save(_ request: SetupSaveRequest) -> Result<Void, SetupSaveError> {
        let key = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return .failure(.emptyAPIKey)
        }
        guard key.hasPrefix("gsk_") else {
            return .failure(.invalidAPIKey)
        }

        do {
            try saveAPIKey(key)
        } catch {
            return .failure(.keychainFailure(error.localizedDescription))
        }

        let state = makeState()
        let selectedModelID = resolvedSelectedModelID(from: request.selectedModelID, options: state.modelOptions)
        let selectedMicrophoneID = resolvedSelectedMicrophoneID(
            from: request.selectedMicrophoneID,
            options: state.microphoneOptions
        )

        savePreferences(selectedModelID, selectedMicrophoneID, request.inputGain)
        return .success(())
    }

    private func resolvedSelectedModelID(
        from storedValue: String?,
        options: [Config.ModelOption]
    ) -> String {
        guard
            let storedValue,
            options.contains(where: { $0.id == storedValue })
        else {
            return Config.DefaultValue.model
        }

        return storedValue
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
