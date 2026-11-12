import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: GroqDictateAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draftAPIKey: String
    @State private var draftSpellingFixes: String
    @State private var saveError: String?

    init(model: GroqDictateAppModel) {
        self.model = model
        _draftAPIKey = State(initialValue: model.apiKey)
        _draftSpellingFixes = State(initialValue: model.spellingFixesText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("API key") {
                    SecureField("gsk_…", text: $draftAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Stored only in this iPhone's Keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Spelling fixes") {
                    TextField(
                        "Groq: grog, grok",
                        text: $draftSpellingFixes,
                        axis: .vertical
                    )
                    .lineLimit(3...12)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: draftSpellingFixes) { _, value in
                        if value.count > SpellingFixes.maximumCharacters {
                            draftSpellingFixes = String(value.prefix(SpellingFixes.maximumCharacters))
                        }
                    }

                    Text("One name per line: the right spelling, a colon, then how it comes out wrong, separated by commas.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveError = model.saveSettings(
                            apiKey: draftAPIKey,
                            spellingFixes: draftSpellingFixes
                        )
                        if saveError == nil { dismiss() }
                    }
                    .disabled(!hasChanges)
                }
            }
            .alert("Couldn’t save settings", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private var hasChanges: Bool {
        draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) != model.apiKey
            || draftSpellingFixes.trimmingCharacters(in: .whitespacesAndNewlines) != model.spellingFixesText
    }
}
