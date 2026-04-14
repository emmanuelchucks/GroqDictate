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

    enum LaunchAtLoginConfigurationError: LocalizedError {
        case requiresApplicationsInstall

        var errorDescription: String? {
            switch self {
            case .requiresApplicationsInstall:
                return "Launch at login is only supported when GroqDictate is installed in /Applications."
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.audit("application did finish launching", category: .app)
        logRuntimeEnvironment()
        repairLaunchAtLoginRegistrationIfNeeded()
        shellCoordinator.installMenus()
        wireFocusTracking()
        wireHotkeys()

        if Config.hasAPIKey {
            AppLog.audit("startup branch=runtime has_api_key=true", category: .app)
            applyConfig()
            GroqAPI.warmConnection()
            bootstrapCoordinator.prepareForRuntimeUse()
        } else {
            AppLog.audit("startup branch=onboarding has_api_key=false", category: .app)
            setupCoordinator.show(isOnboarding: true)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        shellCoordinator.refreshLaunchAtLoginMenuState()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppLog.audit("reopen requested state=\(workflow.currentStateDescription)", category: .app)
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
        hotkeys.onRightCommandPress = { [weak self] in self?.workflow.toggle(source: "right_command") }
        hotkeys.onEscapePress = { [weak self] in self?.workflow.handleEscape(source: "global_escape") }
        panel.onEscapePress = { [weak self] in self?.workflow.handleEscape(source: "panel_escape") }
        hotkeys.shouldConsumeEscape = { [weak self] in
            self?.workflow.shouldConsumeEscape ?? false
        }
    }

    private func applyConfig() {
        guard let config = Config.load() else { return }
        recorder.inputGain = config.inputGain
        recorder.selectedDeviceUID = config.micUID
        AppLog.metric(
            "config_applied",
            category: .app,
            level: .audit,
            values: [
                "input_gain": String(format: "%.1f", config.inputGain),
                "mic_selected": config.micUID == nil ? "false" : "true",
                "model": config.model
            ]
        )
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
        let bundleURL = Bundle.main.bundleURL

        return AppShellCoordinator(
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
                guard #available(macOS 13.0, *) else { return false }
                return Self.isEligibleForLaunchAtLoginRegistration(bundleURL: bundleURL)
            },
            isLaunchAtLoginEnabled: {
                guard #available(macOS 13.0, *) else { return false }
                guard Self.isEligibleForLaunchAtLoginRegistration(bundleURL: bundleURL) else { return false }
                return SMAppService.mainApp.status == .enabled
            },
            setLaunchAtLoginEnabled: { enabled in
                guard #available(macOS 13.0, *) else { return }
                guard Self.isEligibleForLaunchAtLoginRegistration(bundleURL: bundleURL) else {
                    throw LaunchAtLoginConfigurationError.requiresApplicationsInstall
                }
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

    private func logRuntimeEnvironment() {
        let bundleURL = Bundle.main.bundleURL
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"

        AppLog.metric(
            "runtime_environment",
            category: .app,
            level: .audit,
            values: [
                "bundle_id": bundleIdentifier,
                "install_location": Self.installLocationCategory(for: bundleURL),
                "launch_at_login_eligible": Self.isEligibleForLaunchAtLoginRegistration(bundleURL: bundleURL)
                    ? "true"
                    : "false",
                "launch_at_login_status": launchAtLoginStatusDescription()
            ]
        )
    }

    private func launchAtLoginStatusDescription() -> String {
        guard #available(macOS 13.0, *) else { return "unsupported" }

        switch SMAppService.mainApp.status {
        case .notRegistered:
            return "not_registered"
        case .enabled:
            return "enabled"
        case .requiresApproval:
            return "requires_approval"
        case .notFound:
            return "not_found"
        @unknown default:
            return "unknown"
        }
    }

    private func repairLaunchAtLoginRegistrationIfNeeded() {
        guard #available(macOS 13.0, *) else { return }

        let bundleURL = Bundle.main.bundleURL
        let isRegistered = SMAppService.mainApp.status != .notRegistered
        guard Self.shouldRepairLaunchAtLoginRegistration(
            bundleURL: bundleURL,
            isLaunchAtLoginRegistered: isRegistered
        ) else {
            return
        }

        do {
            try SMAppService.mainApp.unregister()
            AppLog.event(
                "launch-at-login unregistered because app is not installed in /Applications",
                category: .app
            )
        } catch {
            AppLog.error(
                "failed to unregister launch-at-login for non-installed app (\(error.localizedDescription))",
                category: .app
            )
        }
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

    static func installLocationCategory(for bundleURL: URL) -> String {
        let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path

        if path.hasPrefix("/Applications/") {
            return "applications"
        }
        if path.contains("/DerivedData/") {
            return "derived_data"
        }
        return "other"
    }

    static func isEligibleForLaunchAtLoginRegistration(bundleURL: URL) -> Bool {
        installLocationCategory(for: bundleURL) == "applications"
    }

    static func shouldRepairLaunchAtLoginRegistration(
        bundleURL: URL,
        isLaunchAtLoginRegistered: Bool
    ) -> Bool {
        isLaunchAtLoginRegistered && !isEligibleForLaunchAtLoginRegistration(bundleURL: bundleURL)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
