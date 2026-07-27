import Foundation

struct Config {
    let apiKey: String
    let model: String
    let inputGain: Float
    let micUID: String?
    let vocabularyHints: String

    enum DefaultsKey {
        static let model = "groq-model"
        static let micUID = "mic-uid"
        static let inputGain = "input-gain"
        static let vocabularyHints = "vocabulary-hints"
    }

    enum KeychainKey {
        static let apiKey = "groq-api-key"
        static let retainedElevenLabsAPIKey = "elevenlabs-api-key"
    }

    enum DefaultValue {
        static let model = "whisper-large-v3"
        static let inputGain: Float = 1.0
    }

    static let maxVocabularyHintsLength = 500

    struct ModelOption: Equatable {
        let id: String
        let title: String
    }

    static let modelOptions: [ModelOption] = [
        ModelOption(id: "whisper-large-v3", title: "Whisper Large V3 (most accurate)"),
        ModelOption(id: "whisper-large-v3-turbo", title: "Whisper Large V3 Turbo")
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
            model: resolvedModelID(defaults.string(forKey: DefaultsKey.model)),
            inputGain: gain > 0 ? gain : DefaultValue.inputGain,
            micUID: (mic?.isEmpty ?? true) ? nil : mic,
            vocabularyHints: normalizedVocabularyHints(
                defaults.string(forKey: DefaultsKey.vocabularyHints) ?? ""
            )
        )
    }

    static func resolvedModelID(_ storedValue: String?) -> String {
        guard
            let storedValue,
            modelOptions.contains(where: { $0.id == storedValue })
        else {
            return DefaultValue.model
        }
        return storedValue
    }

    static func normalizedVocabularyHints(_ value: String) -> String {
        var seen = Set<String>()
        var entries: [String] = []

        for part in value.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            let entry = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let comparisonKey = entry.folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(comparisonKey).inserted else { continue }
            entries.append(entry)
        }

        return entries.joined(separator: ", ")
    }

    static func saveAPIKey(_ key: String) throws {
        try KeychainHelper.save(key: KeychainKey.apiKey, value: key)
    }

    static func savePreferences(model: String, micUID: String?, inputGain: Float, vocabularyHints: String) {
        let defaults = UserDefaults.standard
        defaults.set(model, forKey: DefaultsKey.model)
        defaults.set(micUID ?? "", forKey: DefaultsKey.micUID)
        defaults.set(inputGain, forKey: DefaultsKey.inputGain)
        defaults.set(normalizedVocabularyHints(vocabularyHints), forKey: DefaultsKey.vocabularyHints)
    }

    static var hasAPIKey: Bool {
        guard let key = KeychainHelper.load(key: KeychainKey.apiKey) else { return false }
        return !key.isEmpty
    }
}
