import Cocoa

final class FocusTracker {
    private let selfBundleID = Bundle.main.bundleIdentifier
    private var observer: NSObjectProtocol?

    private(set) var lastExternalApp: NSRunningApplication?
    var onExternalAppActivated: ((NSRunningApplication) -> Void)?

    init() {
        lastExternalApp = currentExternalApp()
        AppLog.debug("initialized, last external app=\(describe(lastExternalApp))", category: .focus)

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let self,
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                !self.isSelf(app)
            else { return }

            self.lastExternalApp = app
            AppLog.debug("external app activated: \(describe(app))", category: .focus)
            self.onExternalAppActivated?(app)
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func currentExternalApp() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication, !isSelf(frontmost) {
            return frontmost
        }
        if let menuOwner = NSWorkspace.shared.menuBarOwningApplication, !isSelf(menuOwner) {
            return menuOwner
        }
        return lastExternalApp
    }

    func reactivate(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated else {
            AppLog.debug("reactivate skipped (missing or terminated app)", category: .focus)
            return
        }
        AppLog.debug("reactivating app: \(describe(app))", category: .focus)
        app.activate()
    }

    private func isSelf(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }
        return bundleID == selfBundleID
    }

    private func describe(_ app: NSRunningApplication?) -> String {
        guard let app else { return "n/a" }
        let name = app.localizedName ?? "unknown"
        let bundleID = app.bundleIdentifier ?? "unknown.bundle"
        return "\(name) (\(bundleID))"
    }
}
