import Cocoa
import XCTest
@testable import GroqDictate

final class AppBootstrapCoordinatorTests: XCTestCase {
    func testPrepareForRuntimeUse_waitsForMicrophoneAccessBeforeStartingHotkeys() {
        var microphoneCompletion: ((PermissionService.MicrophoneStatus) -> Void)?
        var hotkeyStartCount = 0

        let coordinator = makeCoordinator(
            preflightMicrophone: { .notDetermined },
            requestMicrophoneAccess: { completion in
                microphoneCompletion = completion
            },
            startHotkeys: {
                hotkeyStartCount += 1
                return .ready
            }
        )

        coordinator.prepareForRuntimeUse()

        XCTAssertEqual(hotkeyStartCount, 0)
        XCTAssertNotNil(microphoneCompletion)

        microphoneCompletion?(.authorized)

        XCTAssertEqual(hotkeyStartCount, 1)
    }

    func testPrepareForRuntimeUse_requestsSystemPermissionPromptsWithoutExtraGuidanceState() {
        var accessibilityPromptValues: [Bool] = []
        var listenEventPromptCount = 0

        let coordinator = makeCoordinator(
            preflightAccessibility: { .notTrusted },
            requestAccessibilityAccess: { prompt in
                accessibilityPromptValues.append(prompt)
            },
            preflightListenEventAccess: { .denied },
            requestListenEventAccess: {
                listenEventPromptCount += 1
            }
        )

        coordinator.prepareForRuntimeUse()

        XCTAssertEqual(accessibilityPromptValues, [true])
        XCTAssertEqual(listenEventPromptCount, 1)
    }

    func testPrepareForRuntimeUse_reactivatesAfterHotkeysStartWhenRequested() {
        var events: [String] = []

        let coordinator = makeCoordinator(
            startHotkeys: {
                events.append("hotkeys")
                return .ready
            },
            reactivateApp: { _ in
                events.append("reactivate")
            }
        )

        coordinator.prepareForRuntimeUse(reactivateAppAfterBootstrap: true)

        XCTAssertEqual(events, ["hotkeys", "reactivate"])
    }

    private func makeCoordinator(
        preflightMicrophone: @escaping () -> PermissionService.MicrophoneStatus = { .authorized },
        requestMicrophoneAccess: @escaping (@escaping (PermissionService.MicrophoneStatus) -> Void) -> Void = { _ in },
        preflightAccessibility: @escaping () -> PermissionService.AccessibilityStatus = { .trusted },
        requestAccessibilityAccess: @escaping (Bool) -> Void = { _ in },
        preflightListenEventAccess: @escaping () -> PermissionService.EventAccessStatus = { .granted },
        requestListenEventAccess: @escaping () -> Void = {},
        startHotkeys: @escaping () -> HotkeyMonitor.StartStatus = { .ready },
        reactivateApp: @escaping (NSRunningApplication?) -> Void = { _ in }
    ) -> AppBootstrapCoordinator {
        AppBootstrapCoordinator(
            preflightMicrophone: preflightMicrophone,
            requestMicrophoneAccess: requestMicrophoneAccess,
            preflightAccessibility: preflightAccessibility,
            requestAccessibilityAccess: requestAccessibilityAccess,
            preflightListenEventAccess: preflightListenEventAccess,
            requestListenEventAccess: requestListenEventAccess,
            startHotkeys: startHotkeys,
            reactivateApp: reactivateApp,
            dispatchToMain: { $0() }
        )
    }
}
