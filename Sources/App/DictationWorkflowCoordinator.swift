import AVFoundation
import ApplicationServices
import Cocoa

final class DictationWorkflowCoordinator {
    struct PostEventDeniedHandling: Equatable {
        let shouldReactivateTargetOnDismiss: Bool
        let noticeMessage: String
    }

    enum ErrorKind: Equatable {
        case retryable
        case tooLarge
        case invalidKey
        case micDenied
        case restrictedAccount
        case other
    }

    enum DictationState: Equatable {
        case idle
        case recording
        case processing
        case pendingPaste
        case notice
        case error(ErrorKind)
    }

    enum ToggleAction: Equatable {
        case startRecording
        case stopAndTranscribe
        case handleError(ErrorKind)
        case ignore
    }

    enum EscapeAction: Equatable {
        case cancelActiveWork
        case dismissNotice
        case dismissError
        case ignore
    }

    enum PasteDisposition: Equatable {
        case clipboardWriteFailed
        case autoPaste
        case clipboardOnly
    }

    struct UI {
        let dismissPanel: () -> Void
        let orderFrontPanel: () -> Void
        let showError: (String, WaveformView.ErrorAction) -> Void
        let showNotice: (String) -> Void
        let showProcessing: () -> Void
        let showRecording: (AudioRecorder) -> Void
    }

    private let recorder: AudioRecorder
    private let focusTracker: FocusTracker
    private let pasteTargetInspector: PasteTargetInspector
    private let transcriptionEngine: any TranscriptionEngine
    private let permissionService: PermissionService
    private let loadConfig: () -> Config?
    private let openMicrophoneSettings: () -> Void
    private let showSettings: () -> Void
    private let ui: UI
    private let dispatchAfter: (TimeInterval, @escaping () -> Void) -> Void

    private(set) var state: DictationState = .idle
    private(set) var dictationTargetApp: NSRunningApplication?

    private var hasRequestedPostEventAccess = false
    private var shownPermissionGuidanceActions = Set<PermissionService.GuidanceAction>()
    private var lastAudioFileURL: URL?
    private var currentTranscriptionRequest: TranscriptionRequestHandle?
    private var currentWorkflowID: String?
    private var panelNoticeToken = UUID()
    private var panelNoticeWorkflowOutcome: String?
    private var pendingPasteToken = UUID()

    init(
        recorder: AudioRecorder,
        focusTracker: FocusTracker,
        pasteTargetInspector: PasteTargetInspector,
        transcriptionEngine: any TranscriptionEngine,
        permissionService: PermissionService = .shared,
        loadConfig: @escaping () -> Config?,
        openMicrophoneSettings: @escaping () -> Void,
        showSettings: @escaping () -> Void,
        ui: UI,
        dispatchAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.recorder = recorder
        self.focusTracker = focusTracker
        self.pasteTargetInspector = pasteTargetInspector
        self.transcriptionEngine = transcriptionEngine
        self.permissionService = permissionService
        self.loadConfig = loadConfig
        self.openMicrophoneSettings = openMicrophoneSettings
        self.showSettings = showSettings
        self.ui = ui
        self.dispatchAfter = dispatchAfter
    }

    var shouldTrackFocusedApp: Bool {
        switch state {
        case .recording, .processing, .pendingPaste:
            return true
        case .idle, .notice, .error:
            return false
        }
    }

    var shouldConsumeEscape: Bool {
        switch state {
        case .idle:
            return false
        case .recording, .processing, .pendingPaste, .notice, .error:
            return true
        }
    }

    var currentStateDescription: String {
        describe(state)
    }

    func handleFocusedAppUpdate(_ app: NSRunningApplication?) {
        guard shouldTrackFocusedApp else { return }
        dictationTargetApp = app
        AppLog.audit(
            "dictation target updated to \(describe(app))",
            category: .focus,
            metadata: workflowMetadata(includeTargetApp: true)
        )
    }

    func presentRuntimePanelForReopen() {
        ui.orderFrontPanel()
        dispatchAfter(0.05) { [weak self] in
            self?.focusTracker.reactivate(self?.dictationTargetApp)
        }
    }

    func toggle(source: String = "unknown") {
        AppLog.audit(
            "toggle received source=\(source) state=\(describe(state))",
            category: .hotkey,
            metadata: workflowMetadata(["input_source": source], includeTargetApp: true)
        )
        switch Self.toggleAction(for: state) {
        case .startRecording:
            startRecording(triggerSource: source)
        case .stopAndTranscribe:
            stopAndTranscribe()
        case .handleError(let kind):
            handleErrorAction(kind)
        case .ignore:
            break
        }
    }

    func handleEscape(source: String = "unknown") {
        AppLog.audit(
            "escape received source=\(source) state=\(describe(state))",
            category: .hotkey,
            metadata: workflowMetadata(["input_source": source], includeTargetApp: true)
        )
        switch Self.escapeAction(for: state) {
        case .cancelActiveWork:
            cancel()
        case .dismissNotice:
            dismissNotice()
        case .dismissError:
            dismissError()
        case .ignore:
            break
        }
    }

    private func startRecording(triggerSource: String = "unknown") {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .denied || micStatus == .restricted {
            AppLog.event("recording blocked: microphone permission denied", category: .audio)
            showError(kind: .micDenied, message: AppStrings.Errors.micDenied, action: .settings)
            return
        }

        dictationTargetApp = focusTracker.currentExternalApp()
        beginWorkflow(triggerSource: triggerSource)
        AppLog.audit(
            "recording requested",
            category: .audio,
            metadata: workflowMetadata(["input_source": triggerSource], includeTargetApp: true)
        )
        invalidatePanelNotice()
        applyConfig()

        ui.showRecording(recorder)

        do {
            try recorder.start()
            transition(to: .recording, reason: "recording started")
        } catch {
            recorder.cleanup()
            completeWorkflowIfNeeded(outcome: "recording_start_failed", reason: "recorder start failed")
            AppLog.error("failed to start recording (\(error.localizedDescription))", category: .audio)
            showError(kind: .other, message: AppStrings.Errors.micError, action: .dismissOnly)
        }
    }

    private func stopAndTranscribe() {
        guard case .recording = state else { return }

        transition(to: .processing, reason: "recording stopped, preparing transcription")
        ui.showProcessing()

        recorder.stop { [weak self] fileURL in
            guard let self else { return }
            guard Self.shouldHandleRecorderStopCallback(for: self.state) else {
                AppLog.debug("ignoring late recorder stop callback after state reset", category: .audio)
                return
            }
            AppLog.debug("audio capture ready", category: .audio)
            self.lastAudioFileURL = fileURL

            guard let config = self.loadConfig() else {
                self.recorder.cleanup()
                self.lastAudioFileURL = nil
                self.showError(kind: .invalidKey, message: AppStrings.Errors.invalidKey, action: .settings)
                return
            }

            self.transcribe(fileURL: fileURL, config: config)
        }
    }

    private func transcribe(fileURL: URL, config: Config) {
        AppLog.audit(
            "transcription started model=\(config.model)",
            category: .network,
            metadata: workflowMetadata(["model": config.model], includeTargetApp: true)
        )
        currentTranscriptionRequest = transcriptionEngine.transcribe(fileURL: fileURL, config: config) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard Self.shouldHandleTranscriptionCallback(for: self.state) else {
                    AppLog.debug("ignoring late transcription callback after state reset", category: .network)
                    return
                }
                self.currentTranscriptionRequest = nil

                switch result {
                case .success(let text):
                    AppLog.audit(
                        "transcription succeeded chars=\(text.count)",
                        category: .network,
                        metadata: self.workflowMetadata(["transcription_chars": String(text.count)], includeTargetApp: true)
                    )
                    AppLog.debug("transcription success chars=\(text.count)", category: .network)
                    self.recorder.cleanup()
                    self.lastAudioFileURL = nil
                    self.pasteText(text)
                case .failure(let error):
                    AppLog.audit(
                        "transcription failed kind=\(error.diagnosticCode)",
                        category: .network,
                        metadata: self.workflowMetadata(["error_kind": error.diagnosticCode], includeTargetApp: true)
                    )
                    if let detail = error.diagnosticSummary, !detail.isEmpty {
                        AppLog.debug(
                            "transcription failed kind=\(error.diagnosticCode) detail=\(detail)",
                            category: .network
                        )
                    } else {
                        AppLog.debug("transcription failed kind=\(error.diagnosticCode)", category: .network)
                    }
                    self.showTranscriptionError(error)
                }
            }
        }
    }

    private func retryTranscription() {
        guard let fileURL = lastAudioFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            AppLog.debug("retry requested but no last audio file; starting new recording", category: .network)
            completeWorkflowIfNeeded(outcome: "retry_without_audio", reason: "retry requested without retained audio")
            transition(to: .idle, reason: "retry fallback to new recording")
            ui.dismissPanel()
            startRecording(triggerSource: "retry_fallback")
            return
        }

        AppLog.audit("retrying transcription", category: .network, metadata: workflowMetadata(includeTargetApp: true))

        guard let config = loadConfig() else {
            showError(kind: .invalidKey, message: AppStrings.Errors.invalidKey, action: .settings)
            return
        }

        transition(to: .processing, reason: "retry transcription")
        ui.showProcessing()
        transcribe(fileURL: fileURL, config: config)
    }

    private func cancel() {
        AppLog.audit(
            "cancel requested in state=\(describe(state))",
            category: .app,
            metadata: workflowMetadata(includeTargetApp: true)
        )
        if case .recording = state {
            AppLog.audit("recording stop issued process_recording=false", category: .audio, metadata: workflowMetadata())
            recorder.stop(processRecording: false) { _ in }
        }
        if currentTranscriptionRequest != nil {
            AppLog.audit("transcription request cancelled", category: .network, metadata: workflowMetadata())
        }
        currentTranscriptionRequest?.cancel()
        currentTranscriptionRequest = nil
        invalidatePendingPaste()
        completeWorkflowIfNeeded(outcome: "cancelled", reason: "cancel requested")
        resetToIdle(reason: "cancel")
    }

    private func dismissNotice() {
        AppLog.audit("dismissing notice state", category: .app, metadata: workflowMetadata(includeTargetApp: true))
        if let outcome = panelNoticeWorkflowOutcome {
            completeWorkflowIfNeeded(outcome: outcome, reason: "notice dismissed explicitly")
        }
        invalidatePanelNotice()
        transition(to: .idle, reason: "notice dismissed")
        ui.dismissPanel()
    }

    private func dismissError() {
        AppLog.audit("dismissing error state", category: .app, metadata: workflowMetadata(includeTargetApp: true))
        resetToIdle(reason: "error dismissed")
    }

    private func showTranscriptionError(_ error: TranscriptionEngineError) {
        let presentation: (kind: ErrorKind, message: String, action: WaveformView.ErrorAction)

        switch error {
        case .rateLimited, .serverError, .timedOut, .emptyTranscription, .failedDependency, .capacityExceeded:
            presentation = (.retryable, error.errorDescription ?? AppStrings.Errors.tryAgain, .retry)
        case .tooLarge:
            presentation = (.tooLarge, error.errorDescription ?? AppStrings.Errors.recordingTooLarge, .newRecording)
        case .invalidKey:
            presentation = (.invalidKey, AppStrings.Errors.invalidKey, .settings)
        case .accountRestricted:
            presentation = (.restrictedAccount, AppStrings.Errors.orgRestricted, .settings)
        case .forbidden, .badRequest, .unprocessable, .other:
            presentation = (.other, error.errorDescription ?? AppStrings.Errors.unexpectedTranscriptionError, .dismissOnly)
        case .notFound:
            presentation = (.other, AppStrings.Errors.resourceNotFound, .dismissOnly)
        }

        showError(kind: presentation.kind, message: presentation.message, action: presentation.action)
    }

    private func showError(kind: ErrorKind, message: String, action: WaveformView.ErrorAction) {
        AppLog.audit(
            "showing error kind=\(describe(kind))",
            category: .ui,
            metadata: workflowMetadata(["error_kind": describe(kind)], includeTargetApp: true)
        )
        invalidatePanelNotice()
        transition(to: .error(kind), reason: "error shown")
        ui.showError(message, action)
    }

    private func handleErrorAction(_ kind: ErrorKind) {
        AppLog.audit(
            "error action invoked for kind=\(describe(kind))",
            category: .ui,
            metadata: workflowMetadata(["error_kind": describe(kind)], includeTargetApp: true)
        )
        switch kind {
        case .retryable:
            retryTranscription()
        case .tooLarge:
            resetToIdle(reason: "too-large error action", reactivateTarget: false)
            startRecording()
        case .invalidKey, .restrictedAccount:
            ui.dismissPanel()
            transition(to: .idle, reason: "open settings from error action")
            completeWorkflowIfNeeded(outcome: "error_action_open_settings", reason: "open settings from error action")
            showSettings()
        case .micDenied:
            openMicrophoneSettings()
            ui.dismissPanel()
            transition(to: .idle, reason: "open mic settings from error action")
            completeWorkflowIfNeeded(outcome: "error_action_open_mic_settings", reason: "open mic settings from error action")
        case .other:
            break
        }
    }

    private func resetToIdle(reason: String, reactivateTarget: Bool = true) {
        AppLog.audit(
            "resetting to idle reason=\(reason) reactivate_target=\(reactivateTarget)",
            category: .app,
            metadata: workflowMetadata(includeTargetApp: true)
        )
        recorder.cleanup()
        lastAudioFileURL = nil
        currentTranscriptionRequest = nil
        invalidatePendingPaste()
        invalidatePanelNotice()
        transition(to: .idle, reason: reason)
        ui.dismissPanel()
        if reactivateTarget {
            focusTracker.reactivate(dictationTargetApp)
        }
        completeWorkflowIfNeeded(outcome: "reset_to_idle", reason: reason)
    }

    private func pasteText(_ text: String) {
        let clipboardWriteSucceeded = writeToClipboard(text)

        AppLog.metric(
            "paste_path",
            category: .app,
            level: .audit,
            values: [
                "chars": String(text.count),
                "clipboard_write_succeeded": String(clipboardWriteSucceeded),
                "phase": "clipboard_write"
            ].merging(workflowMetadata(includeTargetApp: true) ?? [:], uniquingKeysWith: { current, _ in current })
        )

        switch Self.initialPasteDisposition(clipboardWriteSucceeded: clipboardWriteSucceeded) {
        case .clipboardWriteFailed:
            completeWorkflowIfNeeded(outcome: "clipboard_write_failed", reason: "clipboard write failed")
            AppLog.error("failed to write transcription to clipboard", category: .app)
            showTransientPanelNotice(AppStrings.Panel.clipboardWriteFailed)
        case .autoPaste:
            ui.dismissPanel()
            transition(to: .pendingPaste, reason: "awaiting final paste execution")
            focusTracker.reactivate(dictationTargetApp)
            schedulePendingPasteExecution()
        case .clipboardOnly:
            break
        }
    }

    private func writeToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private func invalidatePanelNotice() {
        panelNoticeToken = UUID()
        panelNoticeWorkflowOutcome = nil
    }

    private func invalidatePendingPaste() {
        pendingPasteToken = UUID()
    }

    private func schedulePendingPasteExecution() {
        invalidatePendingPaste()
        let token = pendingPasteToken

        dispatchAfter(AppConstants.Timing.simulatedPasteDelay) { [weak self] in
            guard let self, self.pendingPasteToken == token else { return }
            guard case .pendingPaste = self.state else { return }
            self.executePendingPaste()
        }
    }

    private func showTransientPanelNotice(
        _ message: String,
        duration: TimeInterval = AppConstants.Timing.noticeDuration,
        reactivateTargetOnDismiss: Bool = false,
        workflowOutcome: String? = nil
    ) {
        invalidatePanelNotice()
        let token = panelNoticeToken
        panelNoticeWorkflowOutcome = workflowOutcome

        transition(to: .notice, reason: "panel notice shown")
        AppLog.audit(
            "panel notice shown reactivate_target=\(reactivateTargetOnDismiss)",
            category: .ui,
            metadata: workflowMetadata(includeTargetApp: true)
        )
        ui.showNotice(message)

        dispatchAfter(duration) { [weak self] in
            guard let self, self.panelNoticeToken == token else { return }
            guard case .notice = self.state else { return }
            if let outcome = self.panelNoticeWorkflowOutcome {
                self.completeWorkflowIfNeeded(outcome: outcome, reason: "notice auto-dismissed")
            }
            AppLog.audit(
                "panel notice auto-dismissed reactivate_target=\(reactivateTargetOnDismiss)",
                category: .ui,
                metadata: self.workflowMetadata(includeTargetApp: true)
            )
            self.transition(to: .idle, reason: "panel notice dismissed")
            self.invalidatePanelNotice()
            self.ui.dismissPanel()
            if reactivateTargetOnDismiss {
                self.focusTracker.reactivate(self.dictationTargetApp)
            }
        }
    }

    private func transition(to newState: DictationState, reason: String) {
        let oldState = state
        state = newState
        AppLog.audit(
            "state \(describe(oldState)) -> \(describe(newState)) reason=\(reason)",
            category: .app,
            metadata: workflowMetadata(includeTargetApp: true)
        )
    }

    private func describe(_ state: DictationState) -> String {
        switch state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .processing: return "processing"
        case .pendingPaste: return "pendingPaste"
        case .notice: return "notice"
        case .error(let kind): return "error(\(describe(kind)))"
        }
    }

    private func describe(_ kind: ErrorKind) -> String {
        switch kind {
        case .retryable: return "retryable"
        case .tooLarge: return "tooLarge"
        case .invalidKey: return "invalidKey"
        case .micDenied: return "micDenied"
        case .restrictedAccount: return "restrictedAccount"
        case .other: return "other"
        }
    }

    private func describe(_ app: NSRunningApplication?) -> String {
        guard let app else { return "n/a" }
        let name = app.localizedName ?? "unknown"
        let bundleID = app.bundleIdentifier ?? "unknown.bundle"
        return "\(name) (\(bundleID))"
    }

    private func executePendingPaste() {
        let canAutoPasteNow = pasteTargetInspector.canAutoPaste(into: dictationTargetApp)
        let postEventAccessGranted = canAutoPasteNow && ensurePostEventAccessForSimulatedPaste()

        AppLog.metric(
            "paste_path",
            category: .app,
            level: .audit,
            values: [
                "auto_paste_eligible": String(canAutoPasteNow),
                "phase": "execution",
                "post_event_access_granted": String(postEventAccessGranted)
            ].merging(workflowMetadata(includeTargetApp: true) ?? [:], uniquingKeysWith: { current, _ in current })
        )

        switch Self.executionPasteDisposition(
            canAutoPasteNow: canAutoPasteNow,
            postEventAccessGranted: postEventAccessGranted
        ) {
        case .autoPaste:
            AppLog.audit("auto-paste execution proceeding", category: .app, metadata: workflowMetadata(includeTargetApp: true))
            transition(to: .idle, reason: "transcription pasted")
            simulatePaste()
            completeWorkflowIfNeeded(outcome: "auto_paste", reason: "simulated paste posted")
        case .clipboardOnly:
            if canAutoPasteNow && !postEventAccessGranted {
                AppLog.event("post-event access unavailable; keeping transcription in clipboard", category: .app)
                handlePostEventPermissionDenied()
            } else {
                AppLog.audit(
                    "focused element not pasteable at paste time; keeping transcription in clipboard",
                    category: .focus,
                    metadata: workflowMetadata(includeTargetApp: true)
                )
                showTransientPanelNotice(
                    AppStrings.Panel.copiedToClipboard,
                    reactivateTargetOnDismiss: true,
                    workflowOutcome: "clipboard_only"
                )
            }
        case .clipboardWriteFailed:
            showTransientPanelNotice(AppStrings.Panel.clipboardWriteFailed)
        }
    }

    private func ensurePostEventAccessForSimulatedPaste() -> Bool {
        switch permissionService.preflightPostEventAccess() {
        case .granted, .unavailable:
            return true
        case .denied:
            guard !hasRequestedPostEventAccess else { return false }

            hasRequestedPostEventAccess = true
            AppLog.event(
                "post-event access not granted, prompting user",
                category: .app,
                metadata: workflowMetadata(includeTargetApp: true)
            )
            let status = permissionService.requestPostEventAccess()
            AppLog.audit(
                "post-event access request completed status=\(describe(status))",
                category: .app,
                metadata: workflowMetadata(["post_event_status": describe(status)], includeTargetApp: true)
            )
            return status == .granted || status == .unavailable
        }
    }

    private func handlePostEventPermissionDenied() {
        AppLog.audit(
            "post-event access denied; clipboard-only notice shown",
            category: .app,
            metadata: workflowMetadata(includeTargetApp: true)
        )
        shownPermissionGuidanceActions.insert(.postEventDenied)
        let handling = Self.postEventDeniedHandling(openedSystemSettings: false)
        showTransientPanelNotice(
            handling.noticeMessage,
            reactivateTargetOnDismiss: handling.shouldReactivateTargetOnDismiss,
            workflowOutcome: "post_event_denied_clipboard_only"
        )
    }

    private func applyConfig() {
        guard let config = loadConfig() else { return }
        recorder.inputGain = config.inputGain
        recorder.selectedDeviceUID = config.micUID
    }

    private func simulatePaste() {
        let eventSource = CGEventSource(stateID: .combinedSessionState)
        eventSource?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let vKey: CGKeyCode = 0x09
        let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: vKey, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: vKey, keyDown: false)
        AppLog.audit(
            "simulated paste posting key_events_created=\((keyDown != nil && keyUp != nil) ? "true" : "false")",
            category: .app,
            metadata: workflowMetadata(includeTargetApp: true)
        )
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func beginWorkflow(triggerSource: String) {
        currentWorkflowID = UUID().uuidString
        AppLog.audit(
            "workflow started trigger=\(triggerSource)",
            category: .app,
            metadata: workflowMetadata(["input_source": triggerSource], includeTargetApp: true)
        )
    }

    private func completeWorkflowIfNeeded(outcome: String, reason: String) {
        guard currentWorkflowID != nil else { return }
        AppLog.audit(
            "workflow finished outcome=\(outcome) reason=\(reason)",
            category: .app,
            metadata: workflowMetadata(["workflow_outcome": outcome], includeTargetApp: true)
        )
        currentWorkflowID = nil
    }

    private func workflowMetadata(
        _ metadata: [String: String] = [:],
        includeTargetApp: Bool = false
    ) -> [String: String]? {
        var values = metadata

        if let currentWorkflowID {
            values["workflow_id"] = currentWorkflowID
        }

        if includeTargetApp, let app = dictationTargetApp {
            values["target_app_name"] = app.localizedName ?? "unknown"
            values["target_app_bundle_id"] = app.bundleIdentifier ?? "unknown.bundle"
            values["target_app_pid"] = String(app.processIdentifier)
        }

        return values.isEmpty ? nil : values
    }

    private func describe(_ status: PermissionService.EventAccessStatus) -> String {
        switch status {
        case .granted: return "granted"
        case .denied: return "denied"
        case .unavailable: return "unavailable"
        }
    }

    static func shouldPresentPostEventDeniedGuidance(
        shownActions: Set<PermissionService.GuidanceAction>
    ) -> Bool {
        !shownActions.contains(.postEventDenied)
    }

    static func toggleAction(for state: DictationState) -> ToggleAction {
        switch state {
        case .idle:
            return .startRecording
        case .recording:
            return .stopAndTranscribe
        case .processing, .pendingPaste, .notice:
            return .ignore
        case .error(let kind):
            return .handleError(kind)
        }
    }

    static func escapeAction(for state: DictationState) -> EscapeAction {
        switch state {
        case .recording, .processing, .pendingPaste:
            return .cancelActiveWork
        case .notice:
            return .dismissNotice
        case .error:
            return .dismissError
        case .idle:
            return .ignore
        }
    }

    static func shouldHandleRecorderStopCallback(for state: DictationState) -> Bool {
        if case .processing = state {
            return true
        }
        return false
    }

    static func shouldHandleTranscriptionCallback(for state: DictationState) -> Bool {
        if case .processing = state {
            return true
        }
        return false
    }

    static func initialPasteDisposition(clipboardWriteSucceeded: Bool) -> PasteDisposition {
        guard clipboardWriteSucceeded else { return .clipboardWriteFailed }
        return .autoPaste
    }

    static func executionPasteDisposition(canAutoPasteNow: Bool, postEventAccessGranted: Bool) -> PasteDisposition {
        guard canAutoPasteNow, postEventAccessGranted else { return .clipboardOnly }
        return .autoPaste
    }

    static func pasteDisposition(clipboardWriteSucceeded: Bool, canAutoPaste: Bool) -> PasteDisposition {
        guard clipboardWriteSucceeded else { return .clipboardWriteFailed }
        return canAutoPaste ? .autoPaste : .clipboardOnly
    }

    static func postEventDeniedHandling(openedSystemSettings: Bool) -> PostEventDeniedHandling {
        PostEventDeniedHandling(
            shouldReactivateTargetOnDismiss: !openedSystemSettings,
            noticeMessage: AppStrings.Panel.copiedToClipboardAutoPasteDenied
        )
    }
}
