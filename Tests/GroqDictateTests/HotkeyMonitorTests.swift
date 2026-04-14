import XCTest
@testable import GroqDictate

final class HotkeyMonitorTests: XCTestCase {
    func testHandleRightCommandTransition_triggersOncePerPressUntilReleased() {
        let monitor = HotkeyMonitor(dispatchToMain: { work in work() })
        var pressCount = 0
        monitor.onRightCommandPress = { pressCount += 1 }

        XCTAssertTrue(monitor.handleRightCommandTransition(isDown: true, isFallback: false))
        XCTAssertFalse(monitor.handleRightCommandTransition(isDown: true, isFallback: false))
        XCTAssertEqual(pressCount, 1)

        XCTAssertTrue(monitor.handleRightCommandTransition(isDown: false, isFallback: false))
        XCTAssertFalse(monitor.handleRightCommandTransition(isDown: false, isFallback: false))

        XCTAssertTrue(monitor.handleRightCommandTransition(isDown: true, isFallback: true))
        XCTAssertEqual(pressCount, 2)
    }

    func testConsumeEscapeIfNeeded_onlyDispatchesWhenStateAllowsIt() {
        let monitor = HotkeyMonitor(dispatchToMain: { work in work() })
        var escapeCount = 0
        monitor.onEscapePress = { escapeCount += 1 }

        monitor.shouldConsumeEscape = { false }
        XCTAssertFalse(monitor.consumeEscapeIfNeeded(isFallback: false))
        XCTAssertEqual(escapeCount, 0)

        monitor.shouldConsumeEscape = { true }
        XCTAssertTrue(monitor.consumeEscapeIfNeeded(isFallback: true))
        XCTAssertEqual(escapeCount, 1)
    }

    func testHandleFallbackEvent_reportsEscapeConsumptionForLocalSuppression() {
        let monitor = HotkeyMonitor(dispatchToMain: { work in work() })
        monitor.shouldConsumeEscape = { true }

        XCTAssertTrue(
            monitor.handleFallbackEvent(type: .keyDown, keyCode: 53, commandModifierActive: false)
        )
    }

    func testHandleFallbackEvent_tracksRightCommandTransitionsInFallbackMode() {
        let monitor = HotkeyMonitor(dispatchToMain: { work in work() })
        var pressCount = 0
        monitor.onRightCommandPress = { pressCount += 1 }

        XCTAssertTrue(
            monitor.handleFallbackEvent(type: .flagsChanged, keyCode: 54, commandModifierActive: true)
        )
        XCTAssertFalse(
            monitor.handleFallbackEvent(type: .flagsChanged, keyCode: 54, commandModifierActive: true)
        )
        XCTAssertEqual(pressCount, 1)

        XCTAssertTrue(
            monitor.handleFallbackEvent(type: .flagsChanged, keyCode: 54, commandModifierActive: false)
        )
        XCTAssertFalse(
            monitor.handleFallbackEvent(type: .flagsChanged, keyCode: 54, commandModifierActive: false)
        )
    }

    func testFloatingPanel_handleKeyDown_dispatchesEscapeOnly() {
        let panel = FloatingPanel()
        var escapeCount = 0
        panel.onEscapePress = { escapeCount += 1 }

        XCTAssertFalse(panel.handleKeyDown(keyCode: 0))
        XCTAssertEqual(escapeCount, 0)

        XCTAssertTrue(panel.handleKeyDown(keyCode: 53))
        XCTAssertEqual(escapeCount, 1)
    }
}
