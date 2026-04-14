import Cocoa

final class AppBootstrapCoordinator {
    private let preflightMicrophone: () -> PermissionService.MicrophoneStatus
    private let requestMicrophoneAccess: (@escaping (PermissionService.MicrophoneStatus) -> Void) -> Void
    private let preflightAccessibility: () -> PermissionService.AccessibilityStatus
    private let requestAccessibilityAccess: (Bool) -> PermissionService.AccessibilityStatus
    private let preflightListenEventAccess: () -> PermissionService.EventAccessStatus
    private let requestListenEventAccess: () -> PermissionService.EventAccessStatus
    private let preflightPostEventAccess: () -> PermissionService.EventAccessStatus
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
                permissionService.requestAccessibilityAccess(prompt: prompt)
            },
            preflightListenEventAccess: permissionService.preflightListenEventAccess,
            requestListenEventAccess: {
                permissionService.requestListenEventAccess()
            },
            preflightPostEventAccess: permissionService.preflightPostEventAccess,
            startHotkeys: startHotkeys,
            reactivateApp: reactivateApp,
            dispatchToMain: dispatchToMain
        )
    }

    init(
        preflightMicrophone: @escaping () -> PermissionService.MicrophoneStatus,
        requestMicrophoneAccess: @escaping (@escaping (PermissionService.MicrophoneStatus) -> Void) -> Void,
        preflightAccessibility: @escaping () -> PermissionService.AccessibilityStatus,
        requestAccessibilityAccess: @escaping (Bool) -> PermissionService.AccessibilityStatus,
        preflightListenEventAccess: @escaping () -> PermissionService.EventAccessStatus,
        requestListenEventAccess: @escaping () -> PermissionService.EventAccessStatus,
        preflightPostEventAccess: @escaping () -> PermissionService.EventAccessStatus,
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
        self.preflightPostEventAccess = preflightPostEventAccess
        self.startHotkeys = startHotkeys
        self.reactivateApp = reactivateApp
        self.dispatchToMain = dispatchToMain
    }

    func prepareForRuntimeUse(
        reactivateAppAfterBootstrap: Bool = false,
        appToReactivate: NSRunningApplication? = nil
    ) {
        AppLog.audit("runtime bootstrap started", category: .app)
        if preflightMicrophone() == .notDetermined {
            requestMicrophoneAccess { [weak self] status in
                guard let self else { return }
                self.dispatchToMain {
                    AppLog.audit(
                        "microphone access request completed status=\(PermissionService.describe(status))",
                        category: .app
                    )
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
        logPermissionSnapshot(phase: "bootstrap_pre_request")
        requestAccessibilityAndListenEventAccessIfNeeded()
        logPermissionSnapshot(phase: "bootstrap_post_request")

        let hotkeyStatus = startHotkeys()
        handleHotkeyMonitorStartStatus(hotkeyStatus)

        if reactivateAppAfterBootstrap {
            reactivateApp(appToReactivate)
        }
    }

    private func requestAccessibilityAndListenEventAccessIfNeeded() {
        if preflightAccessibility() == .notTrusted {
            AppLog.event("accessibility not trusted, prompting user", category: .app)
            let status = requestAccessibilityAccess(true)
            AppLog.audit(
                "accessibility access request completed status=\(PermissionService.describe(status))",
                category: .app
            )
        } else {
            AppLog.audit("accessibility already trusted", category: .app)
        }

        if preflightListenEventAccess() == .denied {
            AppLog.event("listen-event access not granted, prompting user", category: .app)
            let status = requestListenEventAccess()
            AppLog.audit(
                "listen-event access request completed status=\(PermissionService.describe(status))",
                category: .app
            )
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
            level: .audit,
            values: [
                "status": status.startupDescription
            ]
        )
    }

    private func logPermissionSnapshot(phase: String) {
        let snapshot = PermissionService.Snapshot(
            microphone: preflightMicrophone(),
            accessibility: preflightAccessibility(),
            listenEvent: preflightListenEventAccess(),
            postEvent: preflightPostEventAccess()
        )

        AppLog.metric(
            "permission_snapshot",
            category: .app,
            level: .audit,
            values: PermissionService.snapshotValues(snapshot)
                .merging(["phase": phase], uniquingKeysWith: { _, new in new })
        )
    }
}
