import AppIntents

@available(iOS 18.0, *)
struct ToggleGroqRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Toggle GroqDictate Recording"
    static var description = IntentDescription("Starts or stops a retained GroqDictate recording.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if GROQDICTATE_APP
        try await GroqDictateAppModel.shared.toggleFromExternalIntent()
        #endif
        return .result()
    }
}
