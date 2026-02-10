import AVFoundation
import Carbon.HIToolbox
import Cocoa
import CoreAudio

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    enum DictationState {
        case idle
        case recording
        case processing
    }

    private var state: DictationState = .idle
    private let panel = FloatingPanel()
    private let recorder = AudioRecorder()
    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var setupWindow: SetupWindow?
    private var rightCommandDown = false
    private var targetApp: NSRunningApplication?
    // No need to track the URLSessionDataTask — state guards prevent stale results from being used
    private var dismissWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildAppMenu()
        buildMenuBar()

        if Config.hasAPIKey {
            requestPermissionsIfNeeded()
            applyConfig()
            installEventTap()
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
            self?.installEventTap()
            if isOnboarding {
                self?.requestPermissionsIfNeeded()
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow = window
    }

    // MARK: - Event Tap (captures and consumes hotkeys)

    /// CGEventTap lets us intercept AND consume events (unlike NSEvent global monitors).
    /// This prevents Esc from leaking to the focused app during recording.
    private func installEventTap() {
        // Remove existing tap if any
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        // Store self as userInfo pointer for the C callback
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,  // .defaultTap = can modify/consume events
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                    guard let userInfo = userInfo else {
                        return Unmanaged.passUnretained(event)
                    }
                    let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo)
                        .takeUnretainedValue()
                    return delegate.handleCGEvent(type: type, event: event)
                },
                userInfo: userInfo
            )
        else {
            // Accessibility not granted yet — fall back to NSEvent monitors
            installNSEventMonitors()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Fallback for when Accessibility isn't granted (can't consume events).
    private func installNSEventMonitors() {
        NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
            [weak self] event in
            self?.handleNSEvent(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
            [weak self] event in
            self?.handleNSEvent(event)
            return event
        }
    }

    /// CGEventTap callback — returns nil to consume the event, or the event to pass through.
    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle tap being disabled by the system (e.g. timeout)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Esc key (53) — consume when recording/processing to prevent leak
        if type == .keyDown && keyCode == 53 {
            if state == .recording || state == .processing {
                DispatchQueue.main.async { [weak self] in self?.cancel() }
                return nil  // consumed — Esc doesn't reach the focused app
            }
            return Unmanaged.passUnretained(event)  // pass through when idle
        }

        // Right ⌘ (keyCode 54)
        if type == .flagsChanged && keyCode == 54 {
            let flags = event.flags
            let cmdDown = flags.contains(.maskCommand)
            if cmdDown && !rightCommandDown {
                rightCommandDown = true
                DispatchQueue.main.async { [weak self] in self?.toggle() }
            } else if !cmdDown && rightCommandDown {
                rightCommandDown = false
            }
        }

        return Unmanaged.passUnretained(event)  // pass through
    }

    /// NSEvent fallback handler (can't consume events).
    private func handleNSEvent(_ event: NSEvent) {
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
        case .processing: break
        }
    }

    private func startRecording() {
        guard state == .idle else { return }

        // Cancel any pending error dismiss timer
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

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
            showError("Mic error")
        }
    }

    private func cancel() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        if state == .recording {
            recorder.stop { _ in }
        }
        recorder.cleanup()
        state = .idle
        panel.dismiss()
    }

    private func stopAndTranscribe() {
        guard state == .recording else { return }
        guard let config = Config.load() else {
            showError("No API key")
            return
        }

        state = .processing
        panel.waveformView.setProcessing()

        recorder.stop { [weak self] fileURL in
            guard let self = self, self.state == .processing else { return }

            GroqAPI.transcribe(fileURL: fileURL, config: config) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.recorder.cleanup()

                    // Ignore result if user already cancelled
                    guard self.state == .processing else { return }

                    switch result {
                    case .success(let text):
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)

                        self.panel.dismiss()
                        self.state = .idle

                        if let app = self.targetApp, !app.isTerminated {
                            app.activate()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            self.simulatePaste()
                        }

                    case .failure(let error):
                        self.showError(
                            String(error.localizedDescription.prefix(50)))
                    }
                }
            }
        }
    }

    private func showError(_ message: String) {
        state = .idle
        panel.waveformView.showError(message)
        panel.show()

        // Auto-dismiss after 3s, but cancellable if user starts a new recording
        let work = DispatchWorkItem { [weak self] in
            self?.panel.dismiss()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Simulate Cmd+V. Requires Accessibility; silently no-ops if not granted.
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
