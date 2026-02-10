import Foundation

struct Config {
    let apiKey: String
    let model: String
    let language: String
    let inputGain: Float
    let micUID: String?

    private static let keychainAPIKeyName = "groq-api-key"

    static func load() -> Config? {
        guard let apiKey = KeychainHelper.load(key: keychainAPIKeyName), !apiKey.isEmpty else {
            return nil
        }

        let defaults = UserDefaults.standard
        let model = defaults.string(forKey: "groq-model") ?? "whisper-large-v3-turbo"
        let language = defaults.string(forKey: "groq-language") ?? "en"
        let gain = defaults.float(forKey: "input-gain")
        let micUID = defaults.string(forKey: "mic-uid")

        return Config(
            apiKey: apiKey,
            model: model,
            language: language,
            inputGain: gain > 0 ? gain : 5.0,  // default to max gain
            micUID: (micUID?.isEmpty ?? true) ? nil : micUID
        )
    }

    static func saveAPIKey(_ key: String) throws {
        try KeychainHelper.save(key: keychainAPIKeyName, value: key)
    }

    static var hasAPIKey: Bool {
        guard let key = KeychainHelper.load(key: keychainAPIKeyName) else { return false }
        return !key.isEmpty
    }
}
