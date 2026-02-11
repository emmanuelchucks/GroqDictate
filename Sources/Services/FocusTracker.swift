import Cocoa

final class FocusTracker {
    private let selfBundleID = Bundle.main.bundleIdentifier
    private var observer: NSObjectProtocol?

    private(set) var lastExternalApp: NSRunningApplication?
    var onExternalAppActivated: ((NSRunningApplication) -> Void)?

    init() {
        lastExternalApp = currentExternalApp()
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
        guard let app, !app.isTerminated else { return }
        app.activate()
    }

    private func isSelf(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }
        return bundleID == selfBundleID
    }
}
