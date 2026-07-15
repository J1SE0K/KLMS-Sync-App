import XCTest
@testable import KLMSMac
import KLMSShared

final class CommandActionIntentTests: XCTestCase {
    func testRunIntentDoesNotBecomeCancelWhenCommandStartsBeforeTaskExecution() {
        let captured = MacCommandActionIntent.capture(
            command: .fullSync,
            runningIdentity: nil
        )
        let commandThatStartedLater = KLMSMacRunningCommandIdentity(
            command: .fullSync,
            operationID: 41
        )

        XCTAssertEqual(captured, .run(.fullSync))
        XCTAssertNotEqual(captured, .cancel(commandThatStartedLater))
    }

    func testCancelIntentKeepsOriginalRunIdentityAfterCompletionOrReplacement() {
        let tappedRun = KLMSMacRunningCommandIdentity(
            command: .fullSync,
            operationID: 41
        )
        let replacementRun = KLMSMacRunningCommandIdentity(
            command: .fullSync,
            operationID: 42
        )
        let captured = MacCommandActionIntent.capture(
            command: .fullSync,
            runningIdentity: tappedRun
        )

        XCTAssertEqual(captured, .cancel(tappedRun))
        XCTAssertNotEqual(captured, .run(.fullSync))
        XCTAssertNotEqual(captured, .cancel(replacementRun))
    }

    func testSecondaryCommandCapturesItsOwnExpectedIdentity() {
        let runningNotice = KLMSMacRunningCommandIdentity(
            command: .noticeSync,
            operationID: 9
        )

        XCTAssertEqual(
            MacCommandActionIntent.capture(
                command: .noticeSync,
                runningIdentity: runningNotice
            ),
            .cancel(runningNotice)
        )
        XCTAssertEqual(
            MacCommandActionIntent.capture(
                command: .filesSync,
                runningIdentity: runningNotice
            ),
            .run(.filesSync)
        )
    }
}
