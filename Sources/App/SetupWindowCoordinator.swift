import Cocoa

protocol SetupWindowing: AnyObject {
    var onSave: (() -> Void)? { get set }
    var onClose: ((Bool) -> Void)? { get set }
    func makeKeyAndOrderFront(_ sender: Any?)
}

extension SetupWindow: SetupWindowing {}

final class SetupWindowCoordinator {
    private let makeWindow: () -> SetupWindowing
    private let activateApp: () -> Void
    private let currentExternalApp: () -> NSRunningApplication?
    private let reactivateApp: (NSRunningApplication?) -> Void
    private let handleSave: (NSRunningApplication?) -> Void

    private var window: SetupWindowing?
    private var returnApp: NSRunningApplication?

    init(
        makeWindow: @escaping () -> SetupWindowing,
        activateApp: @escaping () -> Void,
        currentExternalApp: @escaping () -> NSRunningApplication?,
        reactivateApp: @escaping (NSRunningApplication?) -> Void,
        handleSave: @escaping (NSRunningApplication?) -> Void
    ) {
        self.makeWindow = makeWindow
        self.activateApp = activateApp
        self.currentExternalApp = currentExternalApp
        self.reactivateApp = reactivateApp
        self.handleSave = handleSave
    }

    func show(isOnboarding: Bool) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            activateApp()
            return
        }

        returnApp = isOnboarding ? nil : currentExternalApp()

        let window = makeWindow()
        window.onSave = { [weak self] in
            guard let self else { return }
            self.handleSave(self.returnApp)
        }
        window.onClose = { [weak self] didSave in
            guard let self else { return }
            self.window = nil
            let returnApp = self.returnApp
            self.returnApp = nil

            guard !didSave, !isOnboarding else { return }
            self.reactivateApp(returnApp)
        }

        window.makeKeyAndOrderFront(nil)
        activateApp()
        self.window = window
    }
}
