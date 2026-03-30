import XCTest
@testable import GroqDictate

final class AppDelegateLogicTests: XCTestCase {
    func testToggleAction_matchesDictationState() {
        XCTAssertEqual(AppDelegate.toggleAction(for: .idle), .startRecording)
        XCTAssertEqual(AppDelegate.toggleAction(for: .recording), .stopAndTranscribe)
        XCTAssertEqual(AppDelegate.toggleAction(for: .processing), .ignore)
        XCTAssertEqual(AppDelegate.toggleAction(for: .pendingPaste), .ignore)
        XCTAssertEqual(AppDelegate.toggleAction(for: .notice), .ignore)
        XCTAssertEqual(AppDelegate.toggleAction(for: .error(.retryable)), .handleError(.retryable))
    }

    func testEscapeAction_matchesDismissAndCancelStates() {
        XCTAssertEqual(AppDelegate.escapeAction(for: .idle), .ignore)
        XCTAssertEqual(AppDelegate.escapeAction(for: .recording), .cancelActiveWork)
        XCTAssertEqual(AppDelegate.escapeAction(for: .processing), .cancelActiveWork)
        XCTAssertEqual(AppDelegate.escapeAction(for: .pendingPaste), .cancelActiveWork)
        XCTAssertEqual(AppDelegate.escapeAction(for: .notice), .dismissNotice)
        XCTAssertEqual(AppDelegate.escapeAction(for: .error(.other)), .dismissError)
    }

    func testLateCallbacksAreIgnoredOutsideProcessingState() {
        XCTAssertFalse(AppDelegate.shouldHandleRecorderStopCallback(for: .idle))
        XCTAssertFalse(AppDelegate.shouldHandleRecorderStopCallback(for: .recording))
        XCTAssertTrue(AppDelegate.shouldHandleRecorderStopCallback(for: .processing))
        XCTAssertFalse(AppDelegate.shouldHandleRecorderStopCallback(for: .notice))

        XCTAssertFalse(AppDelegate.shouldHandleTranscriptionCallback(for: .idle))
        XCTAssertFalse(AppDelegate.shouldHandleTranscriptionCallback(for: .recording))
        XCTAssertTrue(AppDelegate.shouldHandleTranscriptionCallback(for: .processing))
        XCTAssertFalse(AppDelegate.shouldHandleTranscriptionCallback(for: .error(.retryable)))
    }

    func testPasteDisposition_coversAutoPasteAndClipboardOnlyPaths() {
        XCTAssertEqual(
            AppDelegate.pasteDisposition(clipboardWriteSucceeded: true, canAutoPaste: true),
            .autoPaste
        )
        XCTAssertEqual(
            AppDelegate.pasteDisposition(clipboardWriteSucceeded: true, canAutoPaste: false),
            .clipboardOnly
        )
        XCTAssertEqual(
            AppDelegate.pasteDisposition(clipboardWriteSucceeded: false, canAutoPaste: true),
            .clipboardWriteFailed
        )
    }

    func testInitialPasteDisposition_requiresOnlyClipboardWrite() {
        XCTAssertEqual(
            AppDelegate.initialPasteDisposition(clipboardWriteSucceeded: true),
            .autoPaste
        )
        XCTAssertEqual(
            AppDelegate.initialPasteDisposition(clipboardWriteSucceeded: false),
            .clipboardWriteFailed
        )
    }

    func testExecutionPasteDisposition_usesExecutionTimeEligibility() {
        XCTAssertEqual(
            AppDelegate.executionPasteDisposition(canAutoPasteNow: true, postEventAccessGranted: true),
            .autoPaste
        )
        XCTAssertEqual(
            AppDelegate.executionPasteDisposition(canAutoPasteNow: false, postEventAccessGranted: true),
            .clipboardOnly
        )
        XCTAssertEqual(
            AppDelegate.executionPasteDisposition(canAutoPasteNow: true, postEventAccessGranted: false),
            .clipboardOnly
        )
    }

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

    func testDiagnosticsSanitize_redactsAPIKeysTranscriptPreviewsAndPaths() {
        let input = "token=gsk_secretkey text=hello world /Users/emmanuelchucks/tmp/file.wav"

        let sanitized = DiagnosticsStore.sanitize(input)

        XCTAssertEqual(sanitized, "token=gsk_[redacted] text=<redacted>")
    }

    func testDiagnosticsSanitizeMetadata_redactsSensitiveValuesButPreservesShape() {
        let metadata = [
            "request_id": "req_123",
            "file": "/private/var/tmp/audio.wav",
            "note": "message=provider says too much"
        ]

        let sanitized = DiagnosticsStore.sanitize(metadata)

        XCTAssertEqual(
            sanitized,
            [
                "request_id": "req_123",
                "file": "<path>",
                "note": "message=<redacted>"
            ]
        )
    }
}
