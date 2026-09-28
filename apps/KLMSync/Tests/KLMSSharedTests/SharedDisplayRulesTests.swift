import Foundation
import XCTest
@testable import KLMSShared

/// SharedDisplayRules.swift 의 동작 검사. 예전에는 DashboardDataModelTests 가 Mac·iOS 앱 소스에
/// 같은 코드가 적혀 있는지를 문자열로 확인했다.
final class SharedDisplayRulesTests: XCTestCase {
    func testCompactSettingSummaryHidesPathsAndLongValues() {
        XCTAssertEqual(KLMSSettingValueSummary.compact("  \n"), "비어 있음")
        XCTAssertEqual(KLMSSettingValueSummary.compact(" 30 "), "30")
        XCTAssertEqual(KLMSSettingValueSummary.compact("~/Documents/KLMS"), "저장됨")
        XCTAssertEqual(KLMSSettingValueSummary.compact("C:\\KLMS"), "저장됨")
        XCTAssertEqual(KLMSSettingValueSummary.compact(String(repeating: "가", count: 18)), String(repeating: "가", count: 18))
        XCTAssertEqual(KLMSSettingValueSummary.compact(String(repeating: "가", count: 19)), "저장됨")
    }

    func testChoiceTitleNamesKnownChoicesAndFallsBackToCompact() {
        XCTAssertEqual(KLMSSettingValueSummary.choiceTitle("auto"), "자동")
        XCTAssertEqual(KLMSSettingValueSummary.choiceTitle("quick"), "빠른 모드")
        XCTAssertEqual(KLMSSettingValueSummary.choiceTitle("full"), "전체 다시 읽기")
        XCTAssertEqual(KLMSSettingValueSummary.choiceTitle("manual-digits"), "인증번호 직접 선택")
        XCTAssertEqual(KLMSSettingValueSummary.choiceTitle("minimize"), "창 최소화")
        XCTAssertEqual(KLMSSettingValueSummary.choiceTitle("none"), "그대로 두기")
        XCTAssertEqual(KLMSSettingValueSummary.choiceTitle(""), "선택")
        XCTAssertEqual(KLMSSettingValueSummary.choiceTitle("weekly"), "weekly")
        XCTAssertEqual(KLMSSettingValueSummary.choiceTitle("/tmp/klms"), "저장됨")
        // 공백만 있는 값은 "선택"이 아니라 compact 규칙을 따른다(예전 iOS 코드와 같음).
        XCTAssertEqual(KLMSSettingValueSummary.choiceTitle("  "), "비어 있음")
    }

    func testRelayTokenFingerprintKeepsAppStartValueOverTrimmedToken() {
        // 기대값은 앱의 시작값(1_469_598_103_934_665_603, 표준 FNV-1a offset basis 아님)으로 따로 계산한 값이다.
        // 표준 offset basis 였다면 "abc"는 e71fa2190541574b 가 된다. 캐시 키라서 값이 바뀌면 안 된다.
        XCTAssertEqual(KLMSRelayTokenFingerprint.make("abc"), "token-3-e16801510db89efd")
        XCTAssertEqual(KLMSRelayTokenFingerprint.make("  abc \n"), "token-3-e16801510db89efd")
        XCTAssertEqual(KLMSRelayTokenFingerprint.make("relay-secret-토큰"), "token-15-11da74ee405a46d7")
        XCTAssertEqual(KLMSRelayTokenFingerprint.make(""), "missing-token")
        XCTAssertEqual(KLMSRelayTokenFingerprint.make(" \n\t"), "missing-token")
        XCTAssertFalse(KLMSRelayTokenFingerprint.make("abc").contains("abc"))
    }

    func testSecondaryCommandIconPrefersRunningOverDisabled() {
        XCTAssertEqual(KLMSCommandButtonIcon.secondary(isRunning: true, isDisabled: true), "stop.fill")
        XCTAssertEqual(KLMSCommandButtonIcon.secondary(isRunning: true, isDisabled: false), "stop.fill")
        XCTAssertEqual(KLMSCommandButtonIcon.secondary(isRunning: false, isDisabled: true), "lock.fill")
        XCTAssertNil(KLMSCommandButtonIcon.secondary(isRunning: false, isDisabled: false))
    }

    func testBoundedLogKeepsTailAndFitsLimitWithFoldNotice() {
        let short = String(repeating: "a", count: 100)
        XCTAssertEqual(KLMSLogTruncation.bounded(short, maxCharacters: 100), short)

        let long = String(repeating: "a", count: 150) + "TAIL"
        let bounded = KLMSLogTruncation.bounded(long, maxCharacters: 100)
        XCTAssertEqual(bounded.count, 100)
        XCTAssertTrue(bounded.hasPrefix(KLMSLogTruncation.foldedPrefix))
        XCTAssertTrue(bounded.hasSuffix("TAIL"))
        XCTAssertEqual(
            bounded,
            KLMSLogTruncation.foldedPrefix + String(long.suffix(100 - KLMSLogTruncation.foldedPrefix.count))
        )
    }

    func testHighlightSourceKeepsOnlyTailWithoutNotice() {
        let text = String(repeating: "b", count: 50) + "END"
        XCTAssertEqual(KLMSLogTruncation.highlightSource(text, maxCharacters: 53), text)
        let cut = KLMSLogTruncation.highlightSource(text, maxCharacters: 10)
        XCTAssertEqual(cut, "bbbbbbbEND")
        XCTAssertFalse(cut.contains("접었습니다"))
    }
}
