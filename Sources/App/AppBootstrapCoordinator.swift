import Cocoa

final class AppBootstrapCoordinator {
    private let preflightMicrophone: () -> PermissionService.MicrophoneStatus
    private let requestMicrophoneAccess: (@escaping (PermissionService.MicrophoneStatus) -> Void) -> Void
    private let preflightAccessibility: () -> PermissionService.AccessibilityStatus
    private let requestAccessibilityAccess: (Bool) -> Void
    private let preflightListenEventAccess: () -> PermissionService.EventAccessStatus
    private let requestListenEventAccess: () -> Void
    private let startHotkeys: () -> HotkeyMonitor.StartStatus
    private let reactivateApp: (NSRunningApplication?) -> Void
    private let dispatchToMain: (@escaping () -> Void) -> Void

    convenience init(
        permissionService: PermissionService = .shared,
        startHotkeys: @escaping () -> HotkeyMonitor.StartStatus,
        reactivateApp: @escaping (NSRunningApplication?) -> Void,
        dispatchToMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.init(
            preflightMicrophone: permissionService.preflightMicrophone,
            requestMicrophoneAccess: permissionService.requestMicrophoneAccess,
            preflightAccessibility: permissionService.preflightAccessibility,
            requestAccessibilityAccess: { prompt in
                _ = permissionService.requestAccessibilityAccess(prompt: prompt)
            },
            preflightListenEventAccess: permissionService.preflightListenEventAccess,
            requestListenEventAccess: {
                _ = permissionService.requestListenEventAccess()
            },
            startHotkeys: startHotkeys,
            reactivateApp: reactivateApp,
            dispatchToMain: dispatchToMain
        )
    }

    init(
        preflightMicrophone: @escaping () -> PermissionService.MicrophoneStatus,
        requestMicrophoneAccess: @escaping (@escaping (PermissionService.MicrophoneStatus) -> Void) -> Void,
        preflightAccessibility: @escaping () -> PermissionService.AccessibilityStatus,
        requestAccessibilityAccess: @escaping (Bool) -> Void,
        preflightListenEventAccess: @escaping () -> PermissionService.EventAccessStatus,
        requestListenEventAccess: @escaping () -> Void,
        startHotkeys: @escaping () -> HotkeyMonitor.StartStatus,
        reactivateApp: @escaping (NSRunningApplication?) -> Void,
        dispatchToMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.preflightMicrophone = preflightMicrophone
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.preflightAccessibility = preflightAccessibility
        self.requestAccessibilityAccess = requestAccessibilityAccess
        self.preflightListenEventAccess = preflightListenEventAccess
        self.requestListenEventAccess = requestListenEventAccess
        self.startHotkeys = startHotkeys
        self.reactivateApp = reactivateApp
        self.dispatchToMain = dispatchToMain
    }

    func prepareForRuntimeUse(
        reactivateAppAfterBootstrap: Bool = false,
        appToReactivate: NSRunningApplication? = nil
    ) {
        if preflightMicrophone() == .notDetermined {
            requestMicrophoneAccess { [weak self] _ in
                guard let self else { return }
                self.dispatchToMain {
                    self.finishRuntimeBootstrap(
                        reactivateAppAfterBootstrap: reactivateAppAfterBootstrap,
                        appToReactivate: appToReactivate
                    )
                }
            }
            return
        }

        finishRuntimeBootstrap(
            reactivateAppAfterBootstrap: reactivateAppAfterBootstrap,
            appToReactivate: appToReactivate
        )
    }

    private func finishRuntimeBootstrap(
        reactivateAppAfterBootstrap: Bool,
        appToReactivate: NSRunningApplication?
    ) {
        requestAccessibilityAndListenEventAccessIfNeeded()

        let hotkeyStatus = startHotkeys()
        handleHotkeyMonitorStartStatus(hotkeyStatus)

        if reactivateAppAfterBootstrap {
            reactivateApp(appToReactivate)
        }
    }

    private func requestAccessibilityAndListenEventAccessIfNeeded() {
        if preflightAccessibility() == .notTrusted {
            AppLog.event("accessibility not trusted, prompting user", category: .app)
            requestAccessibilityAccess(true)
        } else {
            AppLog.debug("accessibility already trusted", category: .app)
        }

        if preflightListenEventAccess() == .denied {
            AppLog.event("listen-event access not granted, prompting user", category: .app)
            requestListenEventAccess()
        }
    }

    private func handleHotkeyMonitorStartStatus(_ status: HotkeyMonitor.StartStatus) {
        switch status {
        case .ready:
            AppLog.debug(status.startupDescription, category: .hotkey)
        case .degraded:
            AppLog.event(status.startupDescription, category: .hotkey)
            if let limitations = status.limitationsDescription {
                AppLog.event(limitations, category: .hotkey)
            }
        case .failed:
            AppLog.error("\(status.startupDescription); app remains usable from menu", category: .hotkey)
        }

        AppLog.metric(
            "hotkey_monitor_start",
            category: .hotkey,
            values: [
                "status": status.startupDescription
            ]
        )
    }
}
