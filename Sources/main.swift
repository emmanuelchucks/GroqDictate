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
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var setupWindow: SetupWindow?
    private var rightCommandDown = false
    private var targetApp: NSRunningApplication?
    private var dismissWorkItem: DispatchWorkItem?
    private var accessibilityObserver: NSObjectProtocol?

    /// Prevent ghost window when relaunched from Raycast/Spotlight
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
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
        if let config = Config.load() {
            recorder.inputGain = config.inputGain
            if let micUID = config.micUID {
                AudioDeviceHelper.setPreferredInput(uid: micUID)
            }
        }
    }

    // MARK: - Permissions (mic first → accessibility second, one at a time)

    private func requestPermissionsIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            requestAccessibilityThenStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self?.requestAccessibilityThenStart()
                }
            }
        case .denied, .restricted:
            requestAccessibilityThenStart()
        @unknown default:
            requestAccessibilityThenStart()
        }
    }

    private func requestAccessibilityThenStart() {
        installEventTap()

        if AXIsProcessTrusted() { return }  // already granted

        // Show the system prompt
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        // Listen for accessibility permission changes via DistributedNotification
        // macOS posts "com.apple.accessibility.api" when the user toggles Accessibility
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Small delay — the notification fires before TCC db is fully updated
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard let self = self else { return }
                if AXIsProcessTrusted() {
                    // Remove observer — no longer needed
                    if let obs = self.accessibilityObserver {
                        DistributedNotificationCenter.default().removeObserver(obs)
                        self.accessibilityObserver = nil
                    }
                    self.installEventTap()
                }
            }
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
            if isOnboarding {
                self?.requestPermissionsIfNeeded()
            } else {
                self?.installEventTap()
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow = window
    }

    // MARK: - Event Tap (captures and consumes Esc during recording)

    private func installEventTap() {
        removeAllMonitors()

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
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
            installNSEventMonitors()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func installNSEventMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
            [weak self] event in
            self?.handleNSEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
            [weak self] event in
            self?.handleNSEvent(event)
            return event
        }
    }

    private func removeAllMonitors() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    // MARK: - Event Handlers

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Esc (53) — consume during recording/processing
        if type == .keyDown && keyCode == 53 {
            if state == .recording || state == .processing {
                DispatchQueue.main.async { [weak self] in self?.cancel() }
                return nil  // consumed
            }
            return Unmanaged.passUnretained(event)
        }

        // Right ⌘ (54)
        if type == .flagsChanged && keyCode == 54 {
            let cmdDown = event.flags.contains(.maskCommand)
            if cmdDown && !rightCommandDown {
                rightCommandDown = true
                DispatchQueue.main.async { [weak self] in self?.toggle() }
            } else if !cmdDown && rightCommandDown {
                rightCommandDown = false
            }
        }

        return Unmanaged.passUnretained(event)
    }

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

        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        targetApp = NSWorkspace.shared.frontmostApplication

        if let config = Config.load() {
            recorder.inputGain = config.inputGain
        }

        do {
            panel.waveformView.setRecording(levelSource: recorder)
            panel.show()
            try recorder.start()
            state = .recording
        } catch {
            recorder.cleanup()
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
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

        let work = DispatchWorkItem { [weak self] in
            self?.panel.dismiss()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

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
