import AVFoundation
import Carbon.HIToolbox
import Cocoa
import CoreAudio

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    enum DictationState {
        case idle
        case recording
        case processing  // compression + transcription
    }

    private var state: DictationState = .idle
    private let panel = FloatingPanel()
    private let recorder = AudioRecorder()
    private var statusItem: NSStatusItem!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var setupWindow: SetupWindow?
    private var rightCommandDown = false
    private var targetApp: NSRunningApplication?
    private var currentTask: URLSessionDataTask?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildAppMenu()
        buildMenuBar()

        if Config.hasAPIKey {
            requestPermissionsIfNeeded()
            applyConfig()
            registerHotkey()
        } else {
            showSetup(isOnboarding: true)
        }
    }

    private func applyConfig() {
        if let config = Config.load() {
            recorder.inputGain = config.inputGain
            if let micUID = config.micUID {
                AudioDeviceHelper.setPreferredInput(uid: micUID)
            }
        }
    }

    // MARK: - Permissions (sequential: mic → accessibility)

    private func requestPermissionsIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            requestAccessibilityIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.requestAccessibilityIfNeeded() }
                }
            }
        case .denied, .restricted:
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

    // MARK: - App Menu (enables Cmd+C/V/X/A in text fields for LSUIElement apps)

    private func buildAppMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(
                title: "Quit GroqDictate", action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            NSMenuItem(
                title: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z"))
        editMenu.addItem(
            NSMenuItem(
                title: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(
            NSMenuItem(
                title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(
            NSMenuItem(
                title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(
            NSMenuItem(
                title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(
            NSMenuItem(
                title: "Select All", action: #selector(NSText.selectAll(_:)),
                keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status Bar Menu

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
            NSMenuItem(title: "Esc — cancel", action: nil, keyEquivalent: ""))
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

    // MARK: - Settings

    @objc private func showSetupFromMenu() {
        showSetup()
    }

    private func showSetup(isOnboarding: Bool = false) {
        let previousApp = NSWorkspace.shared.frontmostApplication
        let window = SetupWindow(previousApp: previousApp)
        window.onComplete = { [weak self] in
            self?.setupWindow = nil
            self?.applyConfig()
            self?.registerHotkey()
            if isOnboarding {
                self?.requestPermissionsIfNeeded()
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow = window
    }

    // MARK: - Hotkey (Right ⌘ to toggle, Esc to cancel)

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
        // Esc cancels recording or processing
        if event.type == .keyDown && event.keyCode == 53 {
            if state == .recording || state == .processing {
                DispatchQueue.main.async { [weak self] in self?.cancel() }
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
        case .processing: break  // wait for completion
        }
    }

    private func startRecording() {
        guard state == .idle else { return }

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
            panel.waveformView.showError("Mic error")
            panel.show()
            autoDismissPanel()
        }
    }

    private func cancel() {
        currentTask?.cancel()
        currentTask = nil

        if state == .recording {
            recorder.stop { _ in }  // discard result
        }
        recorder.cleanup()
        state = .idle
        panel.dismiss()
    }

    private func stopAndTranscribe() {
        guard state == .recording else { return }
        guard let config = Config.load() else {
            panel.waveformView.showError("No API key")
            autoDismissPanel()
            state = .idle
            return
        }

        state = .processing
        panel.waveformView.setProcessing()

        // Async: stop recording → compress → upload → paste
        recorder.stop { [weak self] fileURL in
            guard let self = self, self.state == .processing else { return }

            GroqAPI.transcribe(fileURL: fileURL, config: config) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.recorder.cleanup()
                    self.currentTask = nil

                    switch result {
                    case .success(let text):
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)

                        self.panel.dismiss()
                        self.state = .idle

                        // Reactivate the target app, then paste
                        if let app = self.targetApp, !app.isTerminated {
                            app.activate()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            self.simulatePaste()
                        }

                    case .failure(let error):
                        let msg = String(error.localizedDescription.prefix(50))
                        self.panel.waveformView.showError(msg)
                        self.autoDismissPanel()
                        self.state = .idle
                    }
                }
            }
        }
    }

    private func autoDismissPanel() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.panel.dismiss()
        }
    }

    /// Simulate Cmd+V. Requires Accessibility permission; silently no-ops if not granted.
    private func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let vKey = CGKeyCode(0x09)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

// MARK: - Audio Device Helper

enum AudioDeviceHelper {
    static func setPreferredInput(uid: String) {
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
}

// MARK: - Launch

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
