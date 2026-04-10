import Foundation

struct Config {
    let apiKey: String
    let model: String
    let language: String
    let inputGain: Float
    let micUID: String?

    enum DefaultsKey {
        static let model = "groq-model"
        static let micUID = "mic-uid"
        static let inputGain = "input-gain"
    }

    enum KeychainKey {
        static let apiKey = "groq-api-key"
    }

    enum DefaultValue {
        static let model = "whisper-large-v3"
        static let language = "en"
        static let inputGain: Float = 2.0
    }

    struct ModelOption: Equatable {
        let id: String
        let title: String
    }

    static let modelOptions: [ModelOption] = [
        ModelOption(id: "whisper-large-v3", title: "Whisper Large V3 (most accurate)"),
        ModelOption(id: "whisper-large-v3-turbo", title: "Whisper Large V3 Turbo"),
        ModelOption(id: "distil-whisper-large-v3-en", title: "Distil Whisper V3")
    ]

    static func load() -> Config? {
        guard let apiKey = KeychainHelper.load(key: KeychainKey.apiKey), !apiKey.isEmpty else {
            return nil
        }

        let defaults = UserDefaults.standard
        let gain = defaults.float(forKey: DefaultsKey.inputGain)
        let mic = defaults.string(forKey: DefaultsKey.micUID)

        return Config(
            apiKey: apiKey,
            model: defaults.string(forKey: DefaultsKey.model) ?? DefaultValue.model,
            language: DefaultValue.language,
            inputGain: gain > 0 ? gain : DefaultValue.inputGain,
            micUID: (mic?.isEmpty ?? true) ? nil : mic
        )
    }

    static func saveAPIKey(_ key: String) throws {
        try KeychainHelper.save(key: KeychainKey.apiKey, value: key)
    }

    static func savePreferences(model: String, micUID: String?, inputGain: Float) {
        let defaults = UserDefaults.standard
        defaults.set(model, forKey: DefaultsKey.model)
        defaults.set(micUID ?? "", forKey: DefaultsKey.micUID)
        defaults.set(inputGain, forKey: DefaultsKey.inputGain)
    }

    static var hasAPIKey: Bool {
        guard let key = KeychainHelper.load(key: KeychainKey.apiKey) else { return false }
        return !key.isEmpty
    }
}
