import XCTest
@testable import GroqDictate

final class SetupWindowCoordinatorTests: XCTestCase {
    func testShow_reusesExistingWindowWithoutRefreshingReturnApp() {
        let firstWindow = FakeSetupWindow()
        var madeWindows = 0
        var activationCount = 0
        var currentAppCalls = 0

        let coordinator = SetupWindowCoordinator(
            makeWindow: {
                madeWindows += 1
                return firstWindow
            },
            activateApp: {
                activationCount += 1
            },
            currentExternalApp: {
                currentAppCalls += 1
                return nil
            },
            reactivateApp: { _ in },
            handleSave: { _ in }
        )

        coordinator.show(isOnboarding: false)
        coordinator.show(isOnboarding: false)

        XCTAssertEqual(madeWindows, 1)
        XCTAssertEqual(firstWindow.makeFrontCallCount, 2)
        XCTAssertEqual(activationCount, 2)
        XCTAssertEqual(currentAppCalls, 1)
    }

    func testUnsavedNonOnboardingCloseReactivatesCapturedReturnApp() {
        let window = FakeSetupWindow()
        let returnApp = NSRunningApplication.current
        var reactivatedApp: NSRunningApplication?

        let coordinator = SetupWindowCoordinator(
            makeWindow: { window },
            activateApp: {},
            currentExternalApp: { returnApp },
            reactivateApp: { app in
                reactivatedApp = app
            },
            handleSave: { _ in }
        )

        coordinator.show(isOnboarding: false)
        window.onClose?(false)

        XCTAssertEqual(reactivatedApp, returnApp)
    }

    func testOnboardingCloseDoesNotReactivatePreviousApp() {
        let window = FakeSetupWindow()
        var didReactivate = false

        let coordinator = SetupWindowCoordinator(
            makeWindow: { window },
            activateApp: {},
            currentExternalApp: { NSRunningApplication.current },
            reactivateApp: { _ in
                didReactivate = true
            },
            handleSave: { _ in }
        )

        coordinator.show(isOnboarding: true)
        window.onClose?(false)

        XCTAssertFalse(didReactivate)
    }

    func testSavePassesCapturedReturnAppToSaveHandler() {
        let window = FakeSetupWindow()
        let returnApp = NSRunningApplication.current
        var savedReturnApp: NSRunningApplication?

        let coordinator = SetupWindowCoordinator(
            makeWindow: { window },
            activateApp: {},
            currentExternalApp: { returnApp },
            reactivateApp: { _ in },
            handleSave: { app in
                savedReturnApp = app
            }
        )

        coordinator.show(isOnboarding: false)
        window.onSave?()

        XCTAssertEqual(savedReturnApp, returnApp)
    }
}

private final class FakeSetupWindow: SetupWindowing {
    var onSave: (() -> Void)?
    var onClose: ((Bool) -> Void)?
    private(set) var makeFrontCallCount = 0

    func makeKeyAndOrderFront(_ sender: Any?) {
        makeFrontCallCount += 1
    }
}
