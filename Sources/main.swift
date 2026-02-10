import AVFoundation
import Carbon.HIToolbox
import Cocoa
import CoreAudio

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - State

    enum ErrorKind {
        case retryable(String)
        case tooLarge
        case invalidKey
        case micDenied
        case other(String)
    }

    enum DictationState {
        case idle, recording, processing, error(ErrorKind)
    }

    private var state: DictationState = .idle
    private let panel = FloatingPanel()
    private let recorder = AudioRecorder()
    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var setupWindow: SetupWindow?
    private var rightCommandDown = false
    private var targetApp: NSRunningApplication?

    private var accessibilityObserver: NSObjectProtocol?
    private var permissionAnchor: NSWindow?
    private var lastAudioFileURL: URL?

    // MARK: - Lifecycle

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        switch state {
        case .idle:
            showSetup(previousApp: targetApp ?? NSWorkspace.shared.menuBarOwningApplication)
        case .recording, .processing, .error:
            panel.orderFront(nil)
        }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildAppMenu()
        buildMenuBar()

        if Config.hasAPIKey {
            applyConfig()
            GroqAPI.warmConnection()
            requestPermissionsIfNeeded()
        } else {
            showSetup(isOnboarding: true)
        }
    }

    private func applyConfig() {
        guard let config = Config.load() else { return }
        recorder.inputGain = config.inputGain
        recorder.selectedDeviceUID = config.micUID
    }

    // MARK: - Permissions

    private func requestPermissionsIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            requestAccessibilityThenStart()
            endPermissionFlow()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self?.requestAccessibilityThenStart()
                    self?.endPermissionFlow()
                }
            }
        case .denied, .restricted:
            requestAccessibilityThenStart()
            endPermissionFlow()
        @unknown default:
            requestAccessibilityThenStart()
            endPermissionFlow()
        }
    }

    /// Offscreen anchor window keeps the .accessory app active for system permission dialogs.
    private func startPermissionFlow() {
        let anchor = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless], backing: .buffered, defer: false)
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

    private func requestAccessibilityThenStart() {
        installEventTap()
        guard !AXIsProcessTrusted() else { return }

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard let self, AXIsProcessTrusted() else { return }
                if let obs = self.accessibilityObserver {
                    DistributedNotificationCenter.default().removeObserver(obs)
                    self.accessibilityObserver = nil
                }
                self.installEventTap()
            }
        }
    }

    // MARK: - App Menu (enables Cmd+C/V/X/A in text fields for LSUIElement apps)

    private func buildAppMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit GroqDictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status Bar

    private func buildMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "GroqDictate")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Right ⌘ — start / stop", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Esc — cancel", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSetupFromMenu), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit GroqDictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - Settings

    @objc private func showSetupFromMenu() { showSetup() }

    private func showSetup(isOnboarding: Bool = false, previousApp: NSRunningApplication? = nil) {
        let prev = isOnboarding ? nil : (previousApp ?? NSWorkspace.shared.frontmostApplication)
        let window = SetupWindow(previousApp: prev)
        window.onSave = { [weak self] in
            self?.setupWindow = nil
            self?.applyConfig()
            if isOnboarding { self?.startPermissionFlow() } else { self?.installEventTap() }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow = window
    }

    // MARK: - Event Tap

    private func installEventTap() {
        removeAllMonitors()

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let ptr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                return Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
                    .handleCGEvent(type: type, event: event)
            },
            userInfo: ptr
        ) else {
            installNSEventMonitors()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func installNSEventMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] in self?.handleNSEvent($0) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] in self?.handleNSEvent($0); return $0 }
    }

    private func removeAllMonitors() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
            eventTap = nil; runLoopSource = nil
        }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    // MARK: - Event Handling

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if macOS disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Esc — cancel recording/processing, dismiss error
        if type == .keyDown && keyCode == 53 {
            switch state {
            case .recording, .processing:
                DispatchQueue.main.async { self.cancel() }
                return nil
            case .error:
                DispatchQueue.main.async { self.dismissError() }
                return nil
            case .idle:
                return Unmanaged.passUnretained(event)
            }
        }

        // Right ⌘ (keyCode 54) — consume both down and up to prevent stuck modifier
        if type == .flagsChanged && keyCode == 54 {
            let cmdDown = event.flags.contains(.maskCommand)
            if cmdDown && !rightCommandDown {
                rightCommandDown = true
                DispatchQueue.main.async { self.toggle() }
                return nil
            } else if !cmdDown && rightCommandDown {
                rightCommandDown = false
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleNSEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 {
            switch state {
            case .recording, .processing: DispatchQueue.main.async { self.cancel() }
            case .error: DispatchQueue.main.async { self.dismissError() }
            case .idle: break
            }
            return
        }

        guard event.type == .flagsChanged else { return }
        if event.modifierFlags.contains(.command) && event.keyCode == 54 && !rightCommandDown {
            rightCommandDown = true
            DispatchQueue.main.async { self.toggle() }
        } else if !event.modifierFlags.contains(.command) && rightCommandDown {
            rightCommandDown = false
        }
    }

    // MARK: - Dictation Flow

    private func toggle() {
        switch state {
        case .idle:               startRecording()
        case .recording:          stopAndTranscribe()
        case .processing:         break
        case .error(let kind):    handleErrorAction(kind)
        }
    }

    private func startRecording() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic == .denied || mic == .restricted {
            showError(.micDenied, message: "Mic access denied", action: .settings)
            return
        }

        targetApp = NSWorkspace.shared.frontmostApplication
        applyConfig()

        panel.waveformView.setRecording(levelSource: recorder)
        panel.show()

        do {
            try recorder.start()
            state = .recording
        } catch {
            recorder.cleanup()
            showError(.other("Mic error"), message: "Mic error", action: .dismissOnly)
        }
    }

    private func stopAndTranscribe() {
        guard case .recording = state else { return }
        guard let config = Config.load() else {
            showError(.invalidKey, message: "Invalid API key", action: .settings)
            return
        }

        state = .processing
        panel.waveformView.setProcessing()

        recorder.stop { [weak self] fileURL in
            guard let self, case .processing = state else { return }
            lastAudioFileURL = fileURL
            transcribe(fileURL: fileURL, config: config)
        }
    }

    private func transcribe(fileURL: URL, config: Config) {
        GroqAPI.transcribe(fileURL: fileURL, config: config) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, case .processing = self.state else { return }

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
        guard let url = lastAudioFileURL, FileManager.default.fileExists(atPath: url.path) else {
            state = .idle; panel.dismiss(); startRecording()
            return
        }
        guard let config = Config.load() else {
            showError(.invalidKey, message: "Invalid API key", action: .settings)
            return
        }

        state = .processing
        panel.waveformView.setProcessing()
        transcribe(fileURL: url, config: config)
    }

    private func cancel() {
        if case .recording = state { recorder.stop { _ in } }
        recorder.cleanup()
        lastAudioFileURL = nil
        state = .idle
        panel.dismiss()
        refocus()
    }

    private func dismissError() {
        recorder.cleanup()
        lastAudioFileURL = nil
        state = .idle
        panel.dismiss()
        refocus()
    }

    private func handleErrorAction(_ kind: ErrorKind) {
        switch kind {
        case .retryable:
            retryTranscription()
        case .tooLarge:
            recorder.cleanup(); lastAudioFileURL = nil; startRecording()
        case .invalidKey:
            panel.dismiss(); state = .idle; showSetup()
        case .micDenied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            panel.dismiss(); state = .idle
        case .other:
            break
        }
    }

    // MARK: - Helpers

    private func showTranscriptionError(_ error: GroqAPI.TranscriptionError) {
        let msg = error.errorDescription ?? "Unknown error"
        switch error {
        case .rateLimited, .serverError, .timedOut, .emptyTranscription:
            showError(.retryable(msg), message: msg, action: .retry)
        case .tooLarge:
            showError(.tooLarge, message: msg, action: .newRecording)
        case .invalidKey:
            showError(.invalidKey, message: msg, action: .settings)
        case .other:
            showError(.other(msg), message: msg, action: .dismissOnly)
        }
    }

    private func showError(_ kind: ErrorKind, message: String, action: WaveformView.ErrorAction) {
        state = .error(kind)
        panel.waveformView.showError(message, action: action)
        panel.show()
    }

    private func pasteText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        panel.dismiss()
        state = .idle
        refocus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.simulatePaste() }
    }

    private func refocus() {
        if let app = targetApp, !app.isTerminated { app.activate() }
    }

    private func simulatePaste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        let v: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }


}

// MARK: - Launch

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
