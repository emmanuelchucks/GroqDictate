import AVFoundation
import ApplicationServices
import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    struct PostEventDeniedHandling: Equatable {
        let shouldReactivateTargetOnDismiss: Bool
        let noticeMessage: String
    }

    enum ErrorKind {
        case retryable
        case tooLarge
        case invalidKey
        case micDenied
        case restrictedAccount
        case other
    }

    enum DictationState {
        case idle
        case recording
        case processing
        case notice
        case error(ErrorKind)
    }

    private var state: DictationState = .idle

    private let panel = FloatingPanel()
    private let recorder = AudioRecorder()
    private let focusTracker = FocusTracker()
    private let pasteTargetInspector = PasteTargetInspector()
    private let hotkeys = HotkeyMonitor()

    private var statusItem: NSStatusItem?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var setupWindow: SetupWindow?
    private var settingsReturnApp: NSRunningApplication?
    private var dictationTargetApp: NSRunningApplication?

    private var hasRequestedPostEventAccess = false
    private var shownPermissionGuidanceActions = Set<PermissionService.GuidanceAction>()
    private var lastAudioFileURL: URL?
    private var panelNoticeToken = UUID()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.debug("application did finish launching", category: .app)
        buildAppMenu()
        buildMenuBar()
        wireFocusTracking()
        wireHotkeys()

        if Config.hasAPIKey {
            applyConfig()
            GroqAPI.warmConnection()
            requestPermissionsAndStartHotkeys()
        } else {
            showSetup(isOnboarding: true)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshLaunchAtLoginMenuState()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppLog.debug("reopen requested while state=\(describe(state))", category: .app)
        switch state {
        case .idle:
            showSetup(isOnboarding: !Config.hasAPIKey)
        case .recording, .processing, .notice, .error:
            panel.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.focusTracker.reactivate(self?.dictationTargetApp)
            }
        }
        return false
    }

    private func wireFocusTracking() {
        focusTracker.onExternalAppActivated = { [weak self] app in
            guard let self else { return }
            switch state {
            case .recording, .processing:
                dictationTargetApp = app
                AppLog.debug("dictation target updated to \(describe(app))", category: .focus)
            case .idle, .notice, .error:
                break
            }
        }
    }

    private func wireHotkeys() {
        hotkeys.onRightCommandPress = { [weak self] in self?.toggle() }
        hotkeys.onEscapePress = { [weak self] in self?.handleEscape() }
        hotkeys.shouldConsumeEscape = { [weak self] in
            guard let self else { return false }
            switch self.state {
            case .idle:
                return false
            case .recording, .processing, .notice, .error:
                return true
            }
        }
    }

    private func applyConfig() {
        guard let config = Config.load() else { return }
        recorder.inputGain = config.inputGain
        recorder.selectedDeviceUID = config.micUID
    }

    private func buildAppMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: AppStrings.Menu.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: AppStrings.EditMenu.title)
        editMenu.addItem(NSMenuItem(title: AppStrings.EditMenu.undo, action: #selector(UndoManager.undo), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: AppStrings.EditMenu.redo, action: #selector(UndoManager.redo), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: AppStrings.EditMenu.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: AppStrings.EditMenu.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: AppStrings.EditMenu.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: AppStrings.EditMenu.selectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func buildMenuBar() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: AppStrings.App.iconAccessibilityDescription)

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: AppStrings.Menu.about, action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: AppStrings.Menu.triggerHint, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: AppStrings.Menu.cancelHint, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let launchAtLoginItem = NSMenuItem(title: AppStrings.Menu.launchAtLogin, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        launchAtLoginMenuItem = launchAtLoginItem
        refreshLaunchAtLoginMenuState()

        menu.addItem(NSMenuItem(title: AppStrings.Menu.settings, action: #selector(showSetupFromMenu), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: AppStrings.Menu.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        self.statusItem = statusItem
    }

    @objc private func showSetupFromMenu() {
        showSetup(isOnboarding: false)
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }

        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                AppLog.event("launch-at-login disabled", category: .app)
            } else {
                try SMAppService.mainApp.register()
                AppLog.event("launch-at-login enabled", category: .app)
            }
        } catch {
            AppLog.error("failed to toggle launch-at-login (\(error.localizedDescription))", category: .app)
        }

        refreshLaunchAtLoginMenuState()
    }

    private func refreshLaunchAtLoginMenuState() {
        guard let item = launchAtLoginMenuItem else { return }
        guard #available(macOS 13.0, *) else {
            item.state = .off
            item.isEnabled = false
            return
        }

        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        item.isEnabled = true
    }

    @objc private func showAbout() {
        let returnApp = focusTracker.currentExternalApp()
        NSApp.activate(ignoringOtherApps: true)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        switch AboutDialog.present(version: version) {
        case .openGitHub:
            NSWorkspace.shared.open(AppConstants.URLs.projectGitHub)
        case .dismiss:
            focusTracker.reactivate(returnApp)
        }
    }

    private func showSetup(isOnboarding: Bool) {
        if let setupWindow {
            setupWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        settingsReturnApp = isOnboarding ? nil : focusTracker.currentExternalApp()

        let window = SetupWindow()
        window.onSave = { [weak self] in
            self?.applyConfig()
            self?.handlePostSettingsSave()
        }
        window.onClose = { [weak self] didSave in
            guard let self else { return }
            setupWindow = nil

            if didSave {
                return
            }

            if !isOnboarding {
                focusTracker.reactivate(settingsReturnApp)
            }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow = window
    }

    private func handlePostSettingsSave() {
        requestPermissionsAndStartHotkeys(reactivateSettingsReturnApp: true)
    }

    private func requestPermissionsAndStartHotkeys(reactivateSettingsReturnApp: Bool = false) {
        let complete: () -> Void = { [weak self] in
            guard let self else { return }
            self.requestAccessibilityAndListenEventAccessIfNeeded()

            let hotkeyStatus = self.hotkeys.start()
            self.handleHotkeyMonitorStartStatus(hotkeyStatus)

            if reactivateSettingsReturnApp {
                self.focusTracker.reactivate(self.settingsReturnApp)
            }
        }

        if PermissionService.shared.preflightMicrophone() == .notDetermined {
            PermissionService.shared.requestMicrophoneAccess { _ in
                DispatchQueue.main.async {
                    complete()
                }
            }
            return
        }

        complete()
    }

    private func requestAccessibilityAndListenEventAccessIfNeeded() {
        if PermissionService.shared.preflightAccessibility() == .notTrusted {
            AppLog.event("accessibility not trusted, prompting user", category: .app)
            _ = PermissionService.shared.requestAccessibilityAccess(prompt: true)
        } else {
            AppLog.debug("accessibility already trusted", category: .app)
        }

        if PermissionService.shared.preflightListenEventAccess() == .denied {
            AppLog.event("listen-event access not granted, prompting user", category: .app)
            _ = PermissionService.shared.requestListenEventAccess()
        }

        presentPermissionGuidanceIfNeeded()
    }

    private func presentPermissionGuidanceIfNeeded() {
        let snapshot = PermissionService.shared.preflight()
        let actions = PermissionService.guidanceActions(for: snapshot)

        for action in actions where !shownPermissionGuidanceActions.contains(action) {
            shownPermissionGuidanceActions.insert(action)
            presentPermissionGuidanceAlert(for: action)
        }
    }

    @discardableResult
    private func presentPermissionGuidanceAlert(for action: PermissionService.GuidanceAction) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning

        switch action {
        case .accessibilityDenied:
            alert.messageText = AppStrings.Permissions.accessibilityDeniedTitle
            alert.informativeText = AppStrings.Permissions.accessibilityDeniedMessage
        case .inputMonitoringDenied:
            alert.messageText = AppStrings.Permissions.inputMonitoringDeniedTitle
            alert.informativeText = AppStrings.Permissions.inputMonitoringDeniedMessage
        case .postEventDenied:
            alert.messageText = AppStrings.Permissions.postEventDeniedTitle
            alert.informativeText = AppStrings.Permissions.postEventDeniedMessage
        }

        alert.addButton(withTitle: AppStrings.Permissions.openSystemSettings)
        alert.addButton(withTitle: AppStrings.Permissions.notNow)

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return false }

        switch action {
        case .accessibilityDenied:
            NSWorkspace.shared.open(AppConstants.URLs.accessibilityPrivacySettings)
        case .inputMonitoringDenied:
            NSWorkspace.shared.open(AppConstants.URLs.inputMonitoringPrivacySettings)
        case .postEventDenied:
            NSWorkspace.shared.open(AppConstants.URLs.postEventPrivacySettings)
        }

        return true
    }

    private func handleHotkeyMonitorStartStatus(_ status: HotkeyMonitor.StartStatus) {
        switch status {
        case .ready:
            AppLog.debug(status.startupDescription, category: .hotkey)
        case .degraded:
            AppLog.event(status.startupDescription, category: .hotkey)
        case .failed:
            AppLog.error("\(status.startupDescription); app remains usable from menu", category: .hotkey)
        }
    }

    private func toggle() {
        AppLog.debug("toggle received in state=\(describe(state))", category: .hotkey)
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopAndTranscribe()
        case .processing, .notice:
            break
        case .error(let kind):
            handleErrorAction(kind)
        }
    }

    private func handleEscape() {
        AppLog.debug("escape received in state=\(describe(state))", category: .hotkey)
        switch state {
        case .recording, .processing:
            cancel()
        case .notice:
            dismissNotice()
        case .error:
            dismissError()
        case .idle:
            break
        }
    }

    private func startRecording() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .denied || micStatus == .restricted {
            AppLog.event("recording blocked: microphone permission denied", category: .audio)
            showError(kind: .micDenied, message: AppStrings.Errors.micDenied, action: .settings)
            return
        }

        dictationTargetApp = focusTracker.currentExternalApp()
        AppLog.debug("recording requested, target=\(describe(dictationTargetApp))", category: .audio)
        invalidatePanelNotice()
        applyConfig()

        panel.waveformView.setRecording(levelSource: recorder)
        panel.show()

        do {
            try recorder.start()
            transition(to: .recording, reason: "recording started")
        } catch {
            recorder.cleanup()
            AppLog.error("failed to start recording (\(error.localizedDescription))", category: .audio)
            showError(kind: .other, message: AppStrings.Errors.micError, action: .dismissOnly)
        }
    }

    private func stopAndTranscribe() {
        guard case .recording = state else { return }

        transition(to: .processing, reason: "recording stopped, preparing transcription")
        panel.waveformView.setProcessing()

        recorder.stop { [weak self] fileURL in
            guard let self else { return }
            guard case .processing = state else { return }
            AppLog.debug("audio captured at \(fileURL.path)", category: .audio)
            lastAudioFileURL = fileURL

            guard let config = Config.load() else {
                recorder.cleanup()
                lastAudioFileURL = nil
                showError(kind: .invalidKey, message: AppStrings.Errors.invalidKey, action: .settings)
                return
            }

            transcribe(fileURL: fileURL, config: config)
        }
    }

    private func transcribe(fileURL: URL, config: Config) {
        AppLog.debug("starting transcription model=\(config.model) file=\(fileURL.lastPathComponent)", category: .network)
        GroqAPI.transcribe(fileURL: fileURL, config: config) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard case .processing = self.state else { return }

                switch result {
                case .success(let text):
                    AppLog.debug("transcription success chars=\(text.count)", category: .network)
                    self.recorder.cleanup()
                    self.lastAudioFileURL = nil
                    self.pasteText(text)
                case .failure(let error):
                    AppLog.debug("transcription failed: \(error.errorDescription ?? "unknown")", category: .network)
                    self.showTranscriptionError(error)
                }
            }
        }
    }

    private func retryTranscription() {
        guard let fileURL = lastAudioFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            AppLog.debug("retry requested but no last audio file; starting new recording", category: .network)
            transition(to: .idle, reason: "retry fallback to new recording")
            panel.dismiss()
            startRecording()
            return
        }

        AppLog.debug("retrying transcription for \(fileURL.lastPathComponent)", category: .network)

        guard let config = Config.load() else {
            showError(kind: .invalidKey, message: AppStrings.Errors.invalidKey, action: .settings)
            return
        }

        transition(to: .processing, reason: "retry transcription")
        panel.waveformView.setProcessing()
        transcribe(fileURL: fileURL, config: config)
    }

    private func cancel() {
        AppLog.debug("cancel requested in state=\(describe(state))", category: .app)
        if case .recording = state {
            recorder.stop(processRecording: false) { _ in }
        }
        resetToIdle(reason: "cancel")
    }

    private func dismissNotice() {
        AppLog.debug("dismissing notice state", category: .app)
        invalidatePanelNotice()
        transition(to: .idle, reason: "notice dismissed")
        panel.dismiss()
    }

    private func dismissError() {
        AppLog.debug("dismissing error state", category: .app)
        resetToIdle(reason: "error dismissed")
    }

    private func showTranscriptionError(_ error: GroqAPI.TranscriptionError) {
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
        case .forbidden(let message), .badRequest(let message), .unprocessable(let message), .other(let message):
            presentation = (.other, message, .dismissOnly)
        case .notFound:
            presentation = (.other, AppStrings.Errors.resourceNotFound, .dismissOnly)
        }

        showError(kind: presentation.kind, message: presentation.message, action: presentation.action)
    }

    private func showError(kind: ErrorKind, message: String, action: WaveformView.ErrorAction) {
        AppLog.debug("showing error kind=\(describe(kind)) message=\(message)", category: .ui)
        invalidatePanelNotice()
        transition(to: .error(kind), reason: "error shown")
        panel.waveformView.showError(message, action: action)
        panel.show()
    }

    private func handleErrorAction(_ kind: ErrorKind) {
        AppLog.debug("error action invoked for kind=\(describe(kind))", category: .ui)
        switch kind {
        case .retryable:
            retryTranscription()
        case .tooLarge:
            resetToIdle(reason: "too-large error action", reactivateTarget: false)
            startRecording()
        case .invalidKey, .restrictedAccount:
            panel.dismiss()
            transition(to: .idle, reason: "open settings from error action")
            showSetup(isOnboarding: false)
        case .micDenied:
            NSWorkspace.shared.open(AppConstants.URLs.microphonePrivacySettings)
            panel.dismiss()
            transition(to: .idle, reason: "open mic settings from error action")
        case .other:
            break
        }
    }

    private func resetToIdle(reason: String, reactivateTarget: Bool = true) {
        recorder.cleanup()
        lastAudioFileURL = nil
        invalidatePanelNotice()
        transition(to: .idle, reason: reason)
        panel.dismiss()
        if reactivateTarget {
            focusTracker.reactivate(dictationTargetApp)
        }
    }

    private func pasteText(_ text: String) {
        AppLog.debug("pasting transcription chars=\(text.count) target=\(describe(dictationTargetApp))", category: .app)

        guard writeToClipboard(text) else {
            AppLog.error("failed to write transcription to clipboard", category: .app)
            showTransientPanelNotice(AppStrings.Panel.clipboardWriteFailed)
            return
        }

        if pasteTargetInspector.canAutoPaste(into: dictationTargetApp) {
            panel.dismiss()
            transition(to: .idle, reason: "transcription pasted")
            focusTracker.reactivate(dictationTargetApp)

            DispatchQueue.main.asyncAfter(deadline: .now() + AppConstants.Timing.simulatedPasteDelay) { [weak self] in
                self?.simulatePasteOrFallBackToClipboardNotice()
            }
            return
        }

        AppLog.debug("focused element not pasteable; keeping transcription in clipboard", category: .focus)
        showTransientPanelNotice(AppStrings.Panel.copiedToClipboard, reactivateTargetOnDismiss: true)
    }

    private func writeToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private func invalidatePanelNotice() {
        panelNoticeToken = UUID()
    }

    private func showTransientPanelNotice(
        _ message: String,
        duration: TimeInterval = AppConstants.Timing.noticeDuration,
        reactivateTargetOnDismiss: Bool = false
    ) {
        invalidatePanelNotice()
        let token = panelNoticeToken

        transition(to: .notice, reason: "panel notice shown")
        panel.waveformView.showNotice(message)
        panel.show()

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.panelNoticeToken == token else { return }
            guard case .notice = self.state else { return }
            self.transition(to: .idle, reason: "panel notice dismissed")
            self.panel.dismiss()
            if reactivateTargetOnDismiss {
                self.focusTracker.reactivate(self.dictationTargetApp)
            }
        }
    }

    private func transition(to newState: DictationState, reason: String) {
        let oldState = state
        state = newState
        AppLog.debug("state \(describe(oldState)) -> \(describe(newState)) (\(reason))", category: .app)
    }

    private func describe(_ state: DictationState) -> String {
        switch state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .processing: return "processing"
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

    private func simulatePasteOrFallBackToClipboardNotice() {
        guard ensurePostEventAccessForSimulatedPaste() else {
            AppLog.event("post-event access unavailable; keeping transcription in clipboard", category: .app)
            handlePostEventPermissionDenied()
            return
        }

        simulatePaste()
    }

    private func ensurePostEventAccessForSimulatedPaste() -> Bool {
        switch PermissionService.shared.preflightPostEventAccess() {
        case .granted, .unavailable:
            return true
        case .denied:
            guard !hasRequestedPostEventAccess else { return false }

            hasRequestedPostEventAccess = true
            AppLog.event("post-event access not granted, prompting user", category: .app)
            let status = PermissionService.shared.requestPostEventAccess()
            return status == .granted || status == .unavailable
        }
    }

    private func handlePostEventPermissionDenied() {
        let shouldPresentGuidance = Self.shouldPresentPostEventDeniedGuidance(
            shownActions: shownPermissionGuidanceActions
        )
        var openedSystemSettings = false

        if shouldPresentGuidance {
            shownPermissionGuidanceActions.insert(.postEventDenied)
            openedSystemSettings = presentPermissionGuidanceAlert(for: .postEventDenied)
        }

        let handling = Self.postEventDeniedHandling(openedSystemSettings: openedSystemSettings)
        showTransientPanelNotice(handling.noticeMessage, reactivateTargetOnDismiss: handling.shouldReactivateTargetOnDismiss)
    }

    static func shouldPresentPostEventDeniedGuidance(
        shownActions: Set<PermissionService.GuidanceAction>
    ) -> Bool {
        !shownActions.contains(.postEventDenied)
    }

    static func postEventDeniedHandling(openedSystemSettings: Bool) -> PostEventDeniedHandling {
        PostEventDeniedHandling(
            shouldReactivateTargetOnDismiss: !openedSystemSettings,
            noticeMessage: AppStrings.Panel.copiedToClipboardAutoPasteDenied
        )
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
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
