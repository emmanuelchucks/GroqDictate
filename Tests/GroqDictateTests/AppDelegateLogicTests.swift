import XCTest
@testable import GroqDictate

final class AppDelegateLogicTests: XCTestCase {
    func testShouldPresentPostEventDeniedGuidance_onlyOnce() {
        XCTAssertTrue(AppDelegate.shouldPresentPostEventDeniedGuidance(shownActions: []))
        XCTAssertFalse(
            AppDelegate.shouldPresentPostEventDeniedGuidance(shownActions: [.postEventDenied])
        )
    }

    func testPostEventDeniedHandling_reactivatesOnlyWhenSystemSettingsWasNotOpened() {
        XCTAssertEqual(
            AppDelegate.postEventDeniedHandling(openedSystemSettings: false),
            .init(
                shouldReactivateTargetOnDismiss: true,
                noticeMessage: AppStrings.Panel.copiedToClipboardAutoPasteDenied
            )
        )

        XCTAssertEqual(
            AppDelegate.postEventDeniedHandling(openedSystemSettings: true),
            .init(
                shouldReactivateTargetOnDismiss: false,
                noticeMessage: AppStrings.Panel.copiedToClipboardAutoPasteDenied
            )
        )
    }
}
