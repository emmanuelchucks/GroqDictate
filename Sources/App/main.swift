import AVFoundation
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        case error(ErrorKind)
    }

    private var state: DictationState = .idle

    private let panel = FloatingPanel()
    private let recorder = AudioRecorder()
    private let focusTracker = FocusTracker()
    private let hotkeys = HotkeyMonitor()

    private var statusItem: NSStatusItem?
    private var setupWindow: SetupWindow?
    private var settingsReturnApp: NSRunningApplication?
    private var dictationTargetApp: NSRunningApplication?

    private var accessibilityObserver: NSObjectProtocol?
    private var permissionAnchor: NSWindow?

    private var lastAudioFileURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildAppMenu()
        buildMenuBar()
        wireFocusTracking()
        wireHotkeys()

        if Config.hasAPIKey {
            applyConfig()
            GroqAPI.warmConnection()
            requestPermissionsIfNeeded()
        } else {
            showSetup(isOnboarding: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        switch state {
        case .idle:
            showSetup(isOnboarding: !Config.hasAPIKey)
        case .recording, .processing, .error:
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
            case .idle, .error:
                break
            }
        }
    }

    private func wireHotkeys() {
        hotkeys.onRightCommandPress = { [weak self] in self?.toggle() }
        hotkeys.onEscapePress = { [weak self] in self?.handleEscape() }
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
        menu.addItem(NSMenuItem(title: AppStrings.Menu.triggerHint, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: AppStrings.Menu.cancelHint, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: AppStrings.Menu.settings, action: #selector(showSetupFromMenu), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: AppStrings.Menu.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        self.statusItem = statusItem
    }

    @objc private func showSetupFromMenu() {
        showSetup(isOnboarding: false)
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
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            startPermissionFlow()
        } else {
            requestAccessibilityThenStart()
            focusTracker.reactivate(settingsReturnApp)
        }
    }

    private func startPermissionFlow() {
        let anchor = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        anchor.isReleasedWhenClosed = false
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.hasShadow = false
        anchor.ignoresMouseEvents = true
        anchor.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        anchor.isExcludedFromWindowsMenu = true
        anchor.orderFront(nil)

        permissionAnchor = anchor
        NSApp.activate(ignoringOtherApps: true)
        requestPermissionsIfNeeded()
    }

    private func endPermissionFlow() {
        permissionAnchor?.close()
        permissionAnchor = nil
    }

    private func requestPermissionsIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            requestAccessibilityThenStart()
            endPermissionFlow()
            focusTracker.reactivate(settingsReturnApp)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self?.requestAccessibilityThenStart()
                    self?.endPermissionFlow()
                    self?.focusTracker.reactivate(self?.settingsReturnApp)
                }
            }
        case .denied, .restricted:
            requestAccessibilityThenStart()
            endPermissionFlow()
            focusTracker.reactivate(settingsReturnApp)
        @unknown default:
            requestAccessibilityThenStart()
            endPermissionFlow()
            focusTracker.reactivate(settingsReturnApp)
        }
    }

    private func requestAccessibilityThenStart() {
        hotkeys.start()

        guard !AXIsProcessTrusted() else { return }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: AppConstants.Accessibility.apiNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard AXIsProcessTrusted() else { return }
                self.hotkeys.start()
                if let observer = self.accessibilityObserver {
                    DistributedNotificationCenter.default().removeObserver(observer)
                    self.accessibilityObserver = nil
                }
            }
        }
    }

    private func toggle() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopAndTranscribe()
        case .processing:
            break
        case .error(let kind):
            handleErrorAction(kind)
        }
    }

    private func handleEscape() {
        switch state {
        case .recording, .processing:
            cancel()
        case .error:
            dismissError()
        case .idle:
            break
        }
    }

    private func startRecording() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .denied || micStatus == .restricted {
            showError(kind: .micDenied, message: AppStrings.Errors.micDenied, action: .settings)
            return
        }

        dictationTargetApp = focusTracker.currentExternalApp()
        applyConfig()

        panel.waveformView.setRecording(levelSource: recorder)
        panel.show()

        do {
            try recorder.start()
            state = .recording
        } catch {
            recorder.cleanup()
            showError(kind: .other, message: AppStrings.Errors.micError, action: .dismissOnly)
        }
    }

    private func stopAndTranscribe() {
        guard case .recording = state else { return }

        state = .processing
        panel.waveformView.setProcessing()

        recorder.stop { [weak self] fileURL in
            guard let self else { return }
            guard case .processing = state else { return }
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
        GroqAPI.transcribe(fileURL: fileURL, config: config) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard case .processing = self.state else { return }

                switch result {
                case .success(let text):
                    self.recorder.cleanup()
                    self.lastAudioFileURL = nil
                    self.pasteText(text)
                case .failure(let error):
                    self.showTranscriptionError(error)
                }
            }
        }
    }

    private func retryTranscription() {
        guard let fileURL = lastAudioFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            state = .idle
            panel.dismiss()
            startRecording()
            return
        }

        guard let config = Config.load() else {
            showError(kind: .invalidKey, message: AppStrings.Errors.invalidKey, action: .settings)
            return
        }

        state = .processing
        panel.waveformView.setProcessing()
        transcribe(fileURL: fileURL, config: config)
    }

    private func cancel() {
        if case .recording = state {
            recorder.stop { _ in }
        }
        recorder.cleanup()
        lastAudioFileURL = nil
        state = .idle
        panel.dismiss()
        focusTracker.reactivate(dictationTargetApp)
    }

    private func dismissError() {
        recorder.cleanup()
        lastAudioFileURL = nil
        state = .idle
        panel.dismiss()
        focusTracker.reactivate(dictationTargetApp)
    }

    private func showTranscriptionError(_ error: GroqAPI.TranscriptionError) {
        switch error {
        case .rateLimited, .serverError, .timedOut, .emptyTranscription, .failedDependency, .capacityExceeded:
            showError(kind: .retryable, message: error.errorDescription ?? AppStrings.Errors.tryAgain, action: .retry)
        case .tooLarge:
            showError(kind: .tooLarge, message: error.errorDescription ?? AppStrings.Errors.recordingTooLarge, action: .newRecording)
        case .invalidKey:
            showError(kind: .invalidKey, message: AppStrings.Errors.invalidKey, action: .settings)
        case .accountRestricted:
            showError(kind: .restrictedAccount, message: AppStrings.Errors.orgRestricted, action: .settings)
        case .forbidden(let message), .badRequest(let message), .unprocessable(let message), .other(let message):
            showError(kind: .other, message: message, action: .dismissOnly)
        case .notFound:
            showError(kind: .other, message: AppStrings.Errors.resourceNotFound, action: .dismissOnly)
        }
    }

    private func showError(kind: ErrorKind, message: String, action: WaveformView.ErrorAction) {
        state = .error(kind)
        panel.waveformView.showError(message, action: action)
        panel.show()
    }

    private func handleErrorAction(_ kind: ErrorKind) {
        switch kind {
        case .retryable:
            retryTranscription()
        case .tooLarge:
            recorder.cleanup()
            lastAudioFileURL = nil
            state = .idle
            startRecording()
        case .invalidKey, .restrictedAccount:
            panel.dismiss()
            state = .idle
            showSetup(isOnboarding: false)
        case .micDenied:
            NSWorkspace.shared.open(AppConstants.URLs.microphonePrivacySettings)
            panel.dismiss()
            state = .idle
        case .other:
            break
        }
    }

    private func pasteText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        panel.dismiss()
        state = .idle
        focusTracker.reactivate(dictationTargetApp)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.simulatePaste()
        }
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
