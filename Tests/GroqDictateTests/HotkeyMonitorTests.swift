import XCTest
@testable import GroqDictate

final class HotkeyMonitorTests: XCTestCase {
    func testStartStatusStartupDescription_explainsDegradedModes() {
        XCTAssertEqual(
            HotkeyMonitor.StartStatus.degraded(.listenEventDenied).startupDescription,
            "degraded: Input Monitoring denied; fallback monitors active with best-effort hotkeys"
        )
        XCTAssertEqual(
            HotkeyMonitor.StartStatus.degraded(.eventTapUnavailable).startupDescription,
            "degraded: event tap unavailable; fallback monitors active with best-effort hotkeys"
        )
    }

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
}
