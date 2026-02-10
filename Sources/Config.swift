import Foundation

struct Config {
    let apiKey: String
    let model: String
    let language: String
    let inputGain: Float
    let micUID: String?

    private static let keychainKey = "groq-api-key"

    static func load() -> Config? {
        guard let apiKey = KeychainHelper.load(key: keychainKey), !apiKey.isEmpty else {
            return nil
        }

        let defaults = UserDefaults.standard
        return Config(
            apiKey: apiKey,
            model: defaults.string(forKey: "groq-model") ?? "whisper-large-v3-turbo",
            language: "en",
            inputGain: {
                let gain = defaults.float(forKey: "input-gain")
                return gain > 0 ? gain : 5.0
            }(),
            micUID: {
                let uid = defaults.string(forKey: "mic-uid")
                return (uid?.isEmpty ?? true) ? nil : uid
            }()
        )
    }

    static func saveAPIKey(_ key: String) throws {
        try KeychainHelper.save(key: keychainKey, value: key)
    }

    static var hasAPIKey: Bool {
        guard let key = KeychainHelper.load(key: keychainKey) else { return false }
        return !key.isEmpty
    }
}
