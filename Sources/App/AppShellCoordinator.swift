import Cocoa

struct LaunchAtLoginMenuPresentation: Equatable {
    let isEnabled: Bool
    let isOn: Bool
}

final class AppShellCoordinator: NSObject {
    private let activateApp: () -> Void
    private let currentExternalApp: () -> NSRunningApplication?
    private let reactivateApp: (NSRunningApplication?) -> Void
    private let openURL: (URL) -> Void
    private let currentVersion: () -> String?
    private let presentAboutDialog: (String?) -> AboutDialog.Action
    private let showSettings: () -> Void
    private let isLaunchAtLoginSupported: () -> Bool
    private let isLaunchAtLoginEnabled: () -> Bool
    private let setLaunchAtLoginEnabled: (Bool) throws -> Void

    private var statusItem: NSStatusItem?
    private var launchAtLoginMenuItem: NSMenuItem?

    init(
        activateApp: @escaping () -> Void,
        currentExternalApp: @escaping () -> NSRunningApplication?,
        reactivateApp: @escaping (NSRunningApplication?) -> Void,
        openURL: @escaping (URL) -> Void,
        currentVersion: @escaping () -> String?,
        presentAboutDialog: @escaping (String?) -> AboutDialog.Action = AboutDialog.present,
        showSettings: @escaping () -> Void,
        isLaunchAtLoginSupported: @escaping () -> Bool,
        isLaunchAtLoginEnabled: @escaping () -> Bool,
        setLaunchAtLoginEnabled: @escaping (Bool) throws -> Void
    ) {
        self.activateApp = activateApp
        self.currentExternalApp = currentExternalApp
        self.reactivateApp = reactivateApp
        self.openURL = openURL
        self.currentVersion = currentVersion
        self.presentAboutDialog = presentAboutDialog
        self.showSettings = showSettings
        self.isLaunchAtLoginSupported = isLaunchAtLoginSupported
        self.isLaunchAtLoginEnabled = isLaunchAtLoginEnabled
        self.setLaunchAtLoginEnabled = setLaunchAtLoginEnabled
    }

    func installMenus() {
        buildAppMenu()
        buildMenuBar()
    }

    func refreshLaunchAtLoginMenuState() {
        guard let item = launchAtLoginMenuItem else { return }
        let presentation = Self.launchAtLoginMenuPresentation(
            isSupported: isLaunchAtLoginSupported(),
            isEnabled: isLaunchAtLoginEnabled()
        )
        item.state = presentation.isOn ? .on : .off
        item.isEnabled = presentation.isEnabled
    }

    @objc func showSettingsFromMenu() {
        showSettings()
    }

    @objc func toggleLaunchAtLogin() {
        guard isLaunchAtLoginSupported() else { return }

        let shouldEnable = !isLaunchAtLoginEnabled()
        do {
            try setLaunchAtLoginEnabled(shouldEnable)
            AppLog.event(
                shouldEnable ? "launch-at-login enabled" : "launch-at-login disabled",
                category: .app
            )
        } catch {
            AppLog.error("failed to toggle launch-at-login (\(error.localizedDescription))", category: .app)
        }

        refreshLaunchAtLoginMenuState()
    }

    @objc func showAbout() {
        let returnApp = currentExternalApp()
        activateApp()

        switch presentAboutDialog(currentVersion()) {
        case .openGitHub:
            openURL(AppConstants.URLs.projectGitHub)
        case .dismiss:
            reactivateApp(returnApp)
        }
    }

    static func launchAtLoginMenuPresentation(
        isSupported: Bool,
        isEnabled: Bool
    ) -> LaunchAtLoginMenuPresentation {
        guard isSupported else {
            return .init(isEnabled: false, isOn: false)
        }

        return .init(isEnabled: true, isOn: isEnabled)
    }

    private func buildAppMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: AppStrings.Menu.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: AppStrings.EditMenu.title)
        editMenu.addItem(NSMenuItem(title: AppStrings.EditMenu.undo, action: #selector(UndoManager.undo), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: AppStrings.EditMenu.redo, action: #selector(UndoManager.redo), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: AppStrings.EditMenu.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: AppStrings.EditMenu.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: AppStrings.EditMenu.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: AppStrings.EditMenu.selectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func buildMenuBar() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: AppStrings.App.iconAccessibilityDescription
        )

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: AppStrings.Menu.about, action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: AppStrings.Menu.triggerHint, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: AppStrings.Menu.cancelHint, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let launchAtLoginItem = NSMenuItem(
            title: AppStrings.Menu.launchAtLogin,
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        launchAtLoginMenuItem = launchAtLoginItem
        refreshLaunchAtLoginMenuState()

        let settingsItem = NSMenuItem(
            title: AppStrings.Menu.settings,
            action: #selector(showSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: AppStrings.Menu.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        self.statusItem = statusItem
    }
}
