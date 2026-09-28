import Foundation
import XCTest
@testable import KLMSShared

/// KLMSAuthStatusPolicy 의 동작 검사. 예전에는 DashboardDataModelTests 가 iOS 앱 소스에
/// 같은 판정 코드가 적혀 있는지를 문자열로 확인했다.
final class AuthStatusPolicyTests: XCTestCase {
    private let digits = SanitizedRemoteStatus(phase: "running", authDigits: "42")
    private let completed = SanitizedRemoteStatus(phase: "running", authStatusMessage: "KAIST 인증 완료")
    private let alreadyLoggedIn = SanitizedRemoteStatus(phase: "running", authStatusMessage: "KLMS 이미 로그인되어 있습니다.")

    func testAlreadyLoggedInMessageMatchesKoreanAndEnglishIgnoringCaseAndSpace() {
        XCTAssertTrue(KLMSAuthStatusPolicy.isAlreadyLoggedInMessage("  KLMS 이미 로그인되어 있습니다. \n"))
        XCTAssertTrue(KLMSAuthStatusPolicy.isAlreadyLoggedInMessage("Already authenticated"))
        XCTAssertFalse(KLMSAuthStatusPolicy.isAlreadyLoggedInMessage("KAIST 인증 완료"))
        XCTAssertFalse(KLMSAuthStatusPolicy.isAlreadyLoggedInMessage(""))
    }

    func testAlreadyLoggedInDoesNotBecomeAuthCompletedTitle() {
        XCTAssertEqual(KLMSAuthStatusPolicy.displayTitle(for: alreadyLoggedIn), "이미 로그인됨")
        XCTAssertEqual(KLMSAuthStatusPolicy.displayTitle(for: completed), "인증 완료")
        XCTAssertEqual(KLMSAuthStatusPolicy.displayTitle(for: SanitizedRemoteStatus(authStatusMessage: "   ")), "인증 완료")
        XCTAssertEqual(KLMSAuthStatusPolicy.displayTitle(for: SanitizedRemoteStatus()), "인증 완료")
    }

    func testCompletionStatusRequiresMessageWithoutDigitsOrLoginRequirement() {
        XCTAssertTrue(KLMSAuthStatusPolicy.hasAuthCompletionStatus(completed))
        XCTAssertFalse(KLMSAuthStatusPolicy.hasAuthCompletionStatus(digits))
        XCTAssertFalse(KLMSAuthStatusPolicy.hasAuthCompletionStatus(
            SanitizedRemoteStatus(loginRequired: true, authStatusMessage: "KAIST 인증 완료")))
        XCTAssertFalse(KLMSAuthStatusPolicy.hasAuthCompletionStatus(
            SanitizedRemoteStatus(authDigits: "42", authStatusMessage: "KAIST 인증 완료")))
        XCTAssertFalse(KLMSAuthStatusPolicy.hasAuthCompletionStatus(SanitizedRemoteStatus()))
    }

    func testCompletionIsHiddenAfterErrorsAndUnsuccessfulCommands() {
        for shown in [RemoteCommandStatus.pending, .running, .completed] {
            XCTAssertTrue(KLMSAuthStatusPolicy.shouldShowAuthCompletion(
                status: completed, errorMessage: "", latestDisplayStatus: shown), "\(shown)")
        }
        XCTAssertTrue(KLMSAuthStatusPolicy.shouldShowAuthCompletion(
            status: completed, errorMessage: " \n", latestDisplayStatus: nil))
        for hidden in [RemoteCommandStatus.failed, .cancelled, .macUnavailable] {
            XCTAssertFalse(KLMSAuthStatusPolicy.shouldShowAuthCompletion(
                status: completed, errorMessage: "", latestDisplayStatus: hidden), "\(hidden)")
        }
        XCTAssertFalse(KLMSAuthStatusPolicy.shouldShowAuthCompletion(
            status: completed, errorMessage: "연결 실패", latestDisplayStatus: .completed))
        XCTAssertFalse(KLMSAuthStatusPolicy.shouldShowAuthCompletion(
            status: digits, errorMessage: "", latestDisplayStatus: .completed))
    }

    func testSuccessIsNotifiedOnlyWhenDigitsClearIntoRealCompletion() {
        XCTAssertTrue(KLMSAuthStatusPolicy.shouldNotifyAuthSuccess(from: digits, to: completed))
        // 이미 로그인된 경우, 숫자 단계를 거치지 않은 경우, 아직 숫자가 남은 경우, 다시 로그인이 필요한 경우는 알리지 않는다.
        XCTAssertFalse(KLMSAuthStatusPolicy.shouldNotifyAuthSuccess(from: digits, to: alreadyLoggedIn))
        XCTAssertFalse(KLMSAuthStatusPolicy.shouldNotifyAuthSuccess(from: SanitizedRemoteStatus(), to: completed))
        XCTAssertFalse(KLMSAuthStatusPolicy.shouldNotifyAuthSuccess(
            from: digits, to: SanitizedRemoteStatus(authDigits: "17", authStatusMessage: "KAIST 인증 완료")))
        XCTAssertFalse(KLMSAuthStatusPolicy.shouldNotifyAuthSuccess(
            from: digits, to: SanitizedRemoteStatus(loginRequired: true, authStatusMessage: "KAIST 인증 완료")))
        XCTAssertFalse(KLMSAuthStatusPolicy.shouldNotifyAuthSuccess(
            from: digits, to: SanitizedRemoteStatus(authStatusMessage: "  ")))
    }

    func testSuccessAlertsDeduplicateByKindForNinetySeconds() {
        XCTAssertEqual(KLMSAuthStatusPolicy.successDeduplicationKey("KAIST 인증 완료"), "auth-completed")
        XCTAssertEqual(KLMSAuthStatusPolicy.successDeduplicationKey("인증이 끝났습니다"), "auth-completed")
        XCTAssertEqual(KLMSAuthStatusPolicy.successDeduplicationKey("already logged in"), "already-logged-in")

        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(KLMSAuthStatusPolicy.shouldPresentSuccessAlert(
            deduplicationKey: "auth-completed", lastDeduplicationKey: "", lastPresentedAt: nil, now: start))
        XCTAssertFalse(KLMSAuthStatusPolicy.shouldPresentSuccessAlert(
            deduplicationKey: "auth-completed", lastDeduplicationKey: "auth-completed",
            lastPresentedAt: start, now: start.addingTimeInterval(90)))
        XCTAssertTrue(KLMSAuthStatusPolicy.shouldPresentSuccessAlert(
            deduplicationKey: "auth-completed", lastDeduplicationKey: "auth-completed",
            lastPresentedAt: start, now: start.addingTimeInterval(90.5)))
        XCTAssertTrue(KLMSAuthStatusPolicy.shouldPresentSuccessAlert(
            deduplicationKey: "already-logged-in", lastDeduplicationKey: "auth-completed",
            lastPresentedAt: start, now: start.addingTimeInterval(1)))
        XCTAssertTrue(KLMSAuthStatusPolicy.shouldPresentSuccessAlert(
            deduplicationKey: "auth-completed", lastDeduplicationKey: "auth-completed",
            lastPresentedAt: nil, now: start))
    }
}
