import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    typealias PostEventDeniedHandling = DictationWorkflowCoordinator.PostEventDeniedHandling
    typealias ErrorKind = DictationWorkflowCoordinator.ErrorKind
    typealias DictationState = DictationWorkflowCoordinator.DictationState
    typealias ToggleAction = DictationWorkflowCoordinator.ToggleAction
    typealias EscapeAction = DictationWorkflowCoordinator.EscapeAction
    typealias PasteDisposition = DictationWorkflowCoordinator.PasteDisposition

    private let panel = FloatingPanel()
    private let recorder = AudioRecorder()
    private let focusTracker = FocusTracker()
    private let pasteTargetInspector = PasteTargetInspector()
    private let hotkeys = HotkeyMonitor()
    private let setupConfigurationController = SetupConfigurationController()
    private lazy var shellCoordinator = makeShellCoordinator()
    private lazy var setupCoordinator = makeSetupCoordinator()
    private lazy var bootstrapCoordinator = makeBootstrapCoordinator()
    private lazy var workflow = makeWorkflowCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.debug("application did finish launching", category: .app)
        shellCoordinator.installMenus()
        wireFocusTracking()
        wireHotkeys()

        if Config.hasAPIKey {
            applyConfig()
            GroqAPI.warmConnection()
            bootstrapCoordinator.prepareForRuntimeUse()
        } else {
            setupCoordinator.show(isOnboarding: true)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        shellCoordinator.refreshLaunchAtLoginMenuState()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppLog.debug("reopen requested while state=\(workflow.currentStateDescription)", category: .app)
        switch workflow.state {
        case .idle:
            setupCoordinator.show(isOnboarding: !Config.hasAPIKey)
        case .recording, .processing, .pendingPaste, .notice, .error:
            workflow.presentRuntimePanelForReopen()
        }
        return false
    }

    private func wireFocusTracking() {
        focusTracker.onExternalAppActivated = { [weak self] app in
            guard let self else { return }
            if self.workflow.shouldTrackFocusedApp {
                self.workflow.handleFocusedAppUpdate(app)
            }
        }
    }

    private func wireHotkeys() {
        hotkeys.onRightCommandPress = { [weak self] in self?.workflow.toggle() }
        hotkeys.onEscapePress = { [weak self] in self?.workflow.handleEscape() }
        hotkeys.shouldConsumeEscape = { [weak self] in
            self?.workflow.shouldConsumeEscape ?? false
        }
    }

    private func applyConfig() {
        guard let config = Config.load() else { return }
        recorder.inputGain = config.inputGain
        recorder.selectedDeviceUID = config.micUID
    }

    private func makeBootstrapCoordinator() -> AppBootstrapCoordinator {
        AppBootstrapCoordinator(
            startHotkeys: { [weak self] in
                self?.hotkeys.start() ?? .failed
            },
            reactivateApp: { [weak self] app in
                self?.focusTracker.reactivate(app)
            }
        )
    }

    private func makeShellCoordinator() -> AppShellCoordinator {
        AppShellCoordinator(
            activateApp: {
                NSApp.activate(ignoringOtherApps: true)
            },
            currentExternalApp: { [weak self] in
                self?.focusTracker.currentExternalApp()
            },
            reactivateApp: { [weak self] app in
                self?.focusTracker.reactivate(app)
            },
            openURL: { url in
                NSWorkspace.shared.open(url)
            },
            currentVersion: {
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            },
            showSettings: { [weak self] in
                self?.setupCoordinator.show(isOnboarding: false)
            },
            isLaunchAtLoginSupported: {
                if #available(macOS 13.0, *) {
                    return true
                }
                return false
            },
            isLaunchAtLoginEnabled: {
                if #available(macOS 13.0, *) {
                    return SMAppService.mainApp.status == .enabled
                }
                return false
            },
            setLaunchAtLoginEnabled: { enabled in
                guard #available(macOS 13.0, *) else { return }
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            }
        )
    }

    private func makeSetupCoordinator() -> SetupWindowCoordinator {
        SetupWindowCoordinator(
            makeWindow: { [setupConfigurationController] in
                SetupWindow(configurationController: setupConfigurationController)
            },
            activateApp: {
                NSApp.activate(ignoringOtherApps: true)
            },
            currentExternalApp: { [weak self] in
                self?.focusTracker.currentExternalApp()
            },
            reactivateApp: { [weak self] app in
                self?.focusTracker.reactivate(app)
            },
            handleSave: { [weak self] returnApp in
                guard let self else { return }
                self.applyConfig()
                self.bootstrapCoordinator.prepareForRuntimeUse(
                    reactivateAppAfterBootstrap: true,
                    appToReactivate: returnApp
                )
            }
        )
    }

    private func makeWorkflowCoordinator() -> DictationWorkflowCoordinator {
        DictationWorkflowCoordinator(
            recorder: recorder,
            focusTracker: focusTracker,
            pasteTargetInspector: pasteTargetInspector,
            transcriptionEngine: GroqTranscriptionEngine(),
            loadConfig: Config.load,
            openMicrophoneSettings: { NSWorkspace.shared.open(AppConstants.URLs.microphonePrivacySettings) },
            showSettings: { [weak self] in
                self?.setupCoordinator.show(isOnboarding: false)
            },
            ui: .init(
                dismissPanel: { [weak self] in
                    self?.panel.dismiss()
                },
                orderFrontPanel: { [weak self] in
                    self?.panel.orderFront(nil)
                },
                showError: { [weak self] message, action in
                    self?.panel.waveformView.showError(message, action: action)
                    self?.panel.show()
                },
                showNotice: { [weak self] message in
                    self?.panel.waveformView.showNotice(message)
                    self?.panel.show()
                },
                showProcessing: { [weak self] in
                    self?.panel.waveformView.setProcessing()
                },
                showRecording: { [weak self] recorder in
                    self?.panel.waveformView.setRecording(levelSource: recorder)
                    self?.panel.show()
                }
            )
        )
    }

    static func shouldPresentPostEventDeniedGuidance(
        shownActions: Set<PermissionService.GuidanceAction>
    ) -> Bool {
        DictationWorkflowCoordinator.shouldPresentPostEventDeniedGuidance(shownActions: shownActions)
    }

    static func toggleAction(for state: DictationState) -> ToggleAction {
        DictationWorkflowCoordinator.toggleAction(for: state)
    }

    static func escapeAction(for state: DictationState) -> EscapeAction {
        DictationWorkflowCoordinator.escapeAction(for: state)
    }

    static func shouldHandleRecorderStopCallback(for state: DictationState) -> Bool {
        DictationWorkflowCoordinator.shouldHandleRecorderStopCallback(for: state)
    }

    static func shouldHandleTranscriptionCallback(for state: DictationState) -> Bool {
        DictationWorkflowCoordinator.shouldHandleTranscriptionCallback(for: state)
    }

    static func initialPasteDisposition(clipboardWriteSucceeded: Bool) -> PasteDisposition {
        DictationWorkflowCoordinator.initialPasteDisposition(clipboardWriteSucceeded: clipboardWriteSucceeded)
    }

    static func executionPasteDisposition(canAutoPasteNow: Bool, postEventAccessGranted: Bool) -> PasteDisposition {
        DictationWorkflowCoordinator.executionPasteDisposition(
            canAutoPasteNow: canAutoPasteNow,
            postEventAccessGranted: postEventAccessGranted
        )
    }

    static func pasteDisposition(clipboardWriteSucceeded: Bool, canAutoPaste: Bool) -> PasteDisposition {
        DictationWorkflowCoordinator.pasteDisposition(
            clipboardWriteSucceeded: clipboardWriteSucceeded,
            canAutoPaste: canAutoPaste
        )
    }

    static func postEventDeniedHandling(openedSystemSettings: Bool) -> PostEventDeniedHandling {
        DictationWorkflowCoordinator.postEventDeniedHandling(openedSystemSettings: openedSystemSettings)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
