import AVFoundation
import Carbon.HIToolbox
import Cocoa
import CoreAudio

// MARK: - Set preferred input device via CoreAudio

func setPreferredInputDevice(uid: String) {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: deviceCount)
    AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices)

    for device in devices {
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &cfUID)

        if (cfUID as String) == uid {
            var defaultAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceID = device
            AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil,
                UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID)
            break
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    enum DictationState {
        case idle
        case recording
        case transcribing
    }

    private var state: DictationState = .idle
    private let panel = FloatingPanel()
    private let recorder = AudioRecorder()
    private var statusItem: NSStatusItem!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var setupWindow: SetupWindow?
    private var rightCommandDown = false
    private var targetApp: NSRunningApplication?  // app that was active before recording

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildAppMenu()
        buildMenuBar()

        if Config.hasAPIKey {
            // Returning user — request permissions silently, then go
            requestPermissionsIfNeeded()
            applyConfig()
            registerHotkey()
        } else {
            // New user — show settings first, permissions come after
            showSetup(isOnboarding: true)
        }
    }

    private func applyConfig() {
        if let config = Config.load() {
            recorder.inputGain = config.inputGain
            if let micUID = config.micUID {
                setPreferredInputDevice(uid: micUID)
            }
        }
    }

    // MARK: - Permissions

    /// Request permissions sequentially: mic first, then accessibility.
    /// Called after settings are saved (onboarding) or on launch (returning user).
    private func requestPermissionsIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            // Mic already granted — check accessibility
            requestAccessibilityIfNeeded()
        case .notDetermined:
            // Ask for mic — when granted, chain to accessibility
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.requestAccessibilityIfNeeded()
                    }
                    // If denied, they can still grant later in System Settings
                }
            }
        case .denied, .restricted:
            // Already denied — still check accessibility
            requestAccessibilityIfNeeded()
        @unknown default:
            requestAccessibilityIfNeeded()
        }
    }

    private func requestAccessibilityIfNeeded() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    // MARK: - App Menu (needed for Cmd+C/V/X/A in text fields)

    private func buildAppMenu() {
        let mainMenu = NSMenu()

        // App menu (hidden but needed)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit GroqDictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu — enables Cmd+C/V/X/A/Z in text fields
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Bar

    private func buildMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform", accessibilityDescription: "GroqDictate")
        }

        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(title: "Right ⌘ — start / stop", action: nil, keyEquivalent: ""))
        menu.addItem(
            NSMenuItem(title: "Esc — cancel recording", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Settings…", action: #selector(showSetupFromMenu),
                keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit GroqDictate", action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - Setup

    @objc private func showSetupFromMenu() {
        showSetup()
    }

    private func showSetup(isOnboarding: Bool = false) {
        // Capture the frontmost app BEFORE we activate ourselves
        let previousApp = NSWorkspace.shared.frontmostApplication
        let window = SetupWindow(previousApp: previousApp)
        window.onComplete = { [weak self] in
            self?.setupWindow = nil
            self?.applyConfig()
            self?.registerHotkey()
            if isOnboarding {
                // Ask for permissions after settings are saved, one at a time
                self?.requestPermissionsIfNeeded()
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow = window
    }

    // MARK: - Global Hotkey

    private func registerHotkey() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
            [weak self] event in
            self?.handleEvent(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
            [weak self] event in
            self?.handleEvent(event)
            return event
        }
    }

    private func handleEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 {
            if state == .recording {
                DispatchQueue.main.async { [weak self] in self?.cancelRecording() }
            }
            return
        }

        guard event.type == .flagsChanged else { return }
        let isRightCmd = event.modifierFlags.contains(.command) && event.keyCode == 54

        if isRightCmd && !rightCommandDown {
            rightCommandDown = true
            DispatchQueue.main.async { [weak self] in self?.toggle() }
        } else if !event.modifierFlags.contains(.command) && rightCommandDown {
            rightCommandDown = false
        }
    }

    // MARK: - Dictation Flow

    private func toggle() {
        switch state {
        case .idle: startRecording()
        case .recording: stopAndTranscribe()
        case .transcribing: break
        }
    }

    private func startRecording() {
        // Remember the app the user is dictating into
        targetApp = NSWorkspace.shared.frontmostApplication

        if let config = Config.load() {
            recorder.inputGain = config.inputGain
        }

        do {
            panel.waveformView.setRecording()
            panel.show()

            try recorder.start { [weak self] level in
                self?.panel.waveformView.pushLevel(CGFloat(level))
            }
            state = .recording
        } catch {
            showError("Mic error: \(error.localizedDescription)")
        }
    }

    private func cancelRecording() {
        _ = recorder.stop()
        recorder.cleanup()
        state = .idle
        panel.dismiss()
    }

    private func stopAndTranscribe() {
        guard let config = Config.load() else {
            showError("No API key — open Settings")
            cancelRecording()
            return
        }

        // Stop recording — this also converts WAV→FLAC for smaller upload
        let fileURL = recorder.stop()
        state = .transcribing
        panel.waveformView.setProcessing()

        GroqAPI.transcribe(fileURL: fileURL, config: config) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.recorder.cleanup()

                switch result {
                case .success(let text):
                    // 1) Copy to clipboard
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)

                    // 2) Dismiss panel
                    self.panel.dismiss()
                    self.state = .idle

                    // 3) Reactivate the target app, then paste
                    if let app = self.targetApp {
                        app.activate()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self.simulatePaste()
                    }

                case .failure(let error):
                    let msg = String(error.localizedDescription.prefix(60))
                    self.showError(msg)
                    self.state = .idle
                }
            }
        }
    }

    private func showError(_ message: String) {
        panel.waveformView.setIdle()
        panel.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.panel.dismiss()
        }
    }

    private func simulatePaste() {
        // Simulate Cmd+V via CGEvent.
        // Requires Accessibility permission — if not granted, this silently does nothing
        // and the text remains on the clipboard for manual Cmd+V.
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let vKey = CGKeyCode(0x09)  // V key
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

// MARK: - Launch

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
