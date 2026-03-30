import XCTest
@testable import GroqDictate

final class AppShellCoordinatorTests: XCTestCase {
    func testLaunchAtLoginMenuPresentation_disablesUnsupportedSystems() {
        XCTAssertEqual(
            AppShellCoordinator.launchAtLoginMenuPresentation(isSupported: false, isEnabled: true),
            .init(isEnabled: false, isOn: false)
        )
    }

    func testLaunchAtLoginMenuPresentation_reflectsEnabledStateWhenSupported() {
        XCTAssertEqual(
            AppShellCoordinator.launchAtLoginMenuPresentation(isSupported: true, isEnabled: true),
            .init(isEnabled: true, isOn: true)
        )
        XCTAssertEqual(
            AppShellCoordinator.launchAtLoginMenuPresentation(isSupported: true, isEnabled: false),
            .init(isEnabled: true, isOn: false)
        )
    }

    func testToggleLaunchAtLogin_enablesWhenCurrentlyDisabled() {
        var setValues: [Bool] = []

        let coordinator = makeCoordinator(
            isLaunchAtLoginSupported: { true },
            isLaunchAtLoginEnabled: { false },
            setLaunchAtLoginEnabled: { enabled in
                setValues.append(enabled)
            }
        )

        coordinator.toggleLaunchAtLogin()

        XCTAssertEqual(setValues, [true])
    }

    func testShowAbout_dismissReactivatesCapturedApp() {
        let returnApp = NSRunningApplication.current
        var reactivatedApp: NSRunningApplication?
        var openedURLs: [URL] = []

        let coordinator = makeCoordinator(
            currentExternalApp: { returnApp },
            reactivateApp: { app in
                reactivatedApp = app
            },
            openURL: { url in
                openedURLs.append(url)
            },
            presentAboutDialog: { _ in .dismiss }
        )

        coordinator.showAbout()

        XCTAssertEqual(reactivatedApp, returnApp)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testShowAbout_openGitHubUsesProjectURL() {
        var openedURLs: [URL] = []

        let coordinator = makeCoordinator(
            openURL: { url in
                openedURLs.append(url)
            },
            presentAboutDialog: { _ in .openGitHub }
        )

        coordinator.showAbout()

        XCTAssertEqual(openedURLs, [AppConstants.URLs.projectGitHub])
    }

    private func makeCoordinator(
        activateApp: @escaping () -> Void = {},
        currentExternalApp: @escaping () -> NSRunningApplication? = { nil },
        reactivateApp: @escaping (NSRunningApplication?) -> Void = { _ in },
        openURL: @escaping (URL) -> Void = { _ in },
        currentVersion: @escaping () -> String? = { nil },
        presentAboutDialog: @escaping (String?) -> AboutDialog.Action = { _ in .dismiss },
        showSettings: @escaping () -> Void = {},
        isLaunchAtLoginSupported: @escaping () -> Bool = { false },
        isLaunchAtLoginEnabled: @escaping () -> Bool = { false },
        setLaunchAtLoginEnabled: @escaping (Bool) throws -> Void = { _ in }
    ) -> AppShellCoordinator {
        AppShellCoordinator(
            activateApp: activateApp,
            currentExternalApp: currentExternalApp,
            reactivateApp: reactivateApp,
            openURL: openURL,
            currentVersion: currentVersion,
            presentAboutDialog: presentAboutDialog,
            showSettings: showSettings,
            isLaunchAtLoginSupported: isLaunchAtLoginSupported,
            isLaunchAtLoginEnabled: isLaunchAtLoginEnabled,
            setLaunchAtLoginEnabled: setLaunchAtLoginEnabled
        )
    }
}
