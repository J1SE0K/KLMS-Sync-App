import XCTest
@testable import KLMSMac

/// 실시간 출력 버퍼 자르기, 진행 줄 추출, 인증번호 최소 표시 시간 규칙.
/// 예전에는 DashboardDataModelTests 가 KLMSMacModel.swift 의 계산 줄을 문자열로 확인했다.
final class LiveCommandOutputRulesTests: XCTestCase {
    // MARK: - 버퍼 자르기

    func testTrimmedKeepsTextWithinLimit() {
        XCTAssertEqual(KLMSLiveCommandOutputRules.trimmed("0123456789", maxCharacters: 10, omissionPrefix: "..\n"), "0123456789")
    }

    func testTrimmedKeepsSuffixAfterOmissionPrefix() {
        // 12자 > 10자라 접두 3자와 뒤쪽 7자를 남긴다.
        XCTAssertEqual(
            KLMSLiveCommandOutputRules.trimmed("0123456789AB", maxCharacters: 10, omissionPrefix: "..\n"),
            "..\n56789AB"
        )
    }

    func testTrimmedWithPrefixLongerThanLimitKeepsOnlyPrefix() {
        XCTAssertEqual(KLMSLiveCommandOutputRules.trimmed("abcdef", maxCharacters: 2, omissionPrefix: "...."), "....")
    }

    func testAppendingToEmptyBufferTrimsIncomingText() {
        XCTAssertEqual(
            KLMSLiveCommandOutputRules.appending("0123456789AB", to: "", maxCharacters: 10, omissionPrefix: "..\n"),
            "..\n56789AB"
        )
        XCTAssertEqual(
            KLMSLiveCommandOutputRules.appending("abc", to: "", maxCharacters: 10, omissionPrefix: "..\n"),
            "abc"
        )
    }

    func testAppendingWithinLimitConcatenates() {
        XCTAssertEqual(
            KLMSLiveCommandOutputRules.appending("def", to: "abc", maxCharacters: 10, omissionPrefix: "..\n"),
            "abcdef"
        )
        // 합이 정확히 최대와 같으면 자르지 않는다.
        XCTAssertEqual(
            KLMSLiveCommandOutputRules.appending("fghij", to: "abcde", maxCharacters: 10, omissionPrefix: "..\n"),
            "abcdefghij"
        )
    }

    func testAppendingOverLimitTrimsCombinedText() {
        // 6 + 5 = 11 > 10 이라 "abcdefghijk" 를 자른다.
        XCTAssertEqual(
            KLMSLiveCommandOutputRules.appending("ghijk", to: "abcdef", maxCharacters: 10, omissionPrefix: "..\n"),
            "..\nefghijk"
        )
    }

    // MARK: - 진행 줄

    func testLastNonEmptyLineSkipsTrailingBlankLines() {
        XCTAssertEqual(KLMSLiveCommandOutputRules.lastNonEmptyLine(in: "a\nb\n\n  \n"), "b")
        XCTAssertEqual(KLMSLiveCommandOutputRules.lastNonEmptyLine(in: "first\n  second  "), "second")
        XCTAssertEqual(KLMSLiveCommandOutputRules.lastNonEmptyLine(in: "  x  \r\n"), "x")
    }

    func testLastNonEmptyLineIsNilForBlankText() {
        XCTAssertNil(KLMSLiveCommandOutputRules.lastNonEmptyLine(in: ""))
        XCTAssertNil(KLMSLiveCommandOutputRules.lastNonEmptyLine(in: " \n \t\n"))
    }

    // MARK: - 인증번호 최소 표시 시간

    func testRemainingMinimumVisibleTimeWhileStillWithinMinimum() {
        let recordedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            KLMSAuthDigitsDisplayRules.remainingMinimumVisibleNanoseconds(
                recordedAt: recordedAt,
                now: recordedAt,
                minimumVisibleNanoseconds: 6_000_000_000
            ),
            6_000_000_000
        )
        XCTAssertEqual(
            KLMSAuthDigitsDisplayRules.remainingMinimumVisibleNanoseconds(
                recordedAt: recordedAt,
                now: Date(timeIntervalSince1970: 1_002),
                minimumVisibleNanoseconds: 6_000_000_000
            ),
            4_000_000_000
        )
        XCTAssertEqual(
            KLMSAuthDigitsDisplayRules.remainingMinimumVisibleNanoseconds(
                recordedAt: recordedAt,
                now: Date(timeIntervalSince1970: 1_000.5),
                minimumVisibleNanoseconds: 6_000_000_000
            ),
            5_500_000_000
        )
    }

    func testRemainingMinimumVisibleTimeIsNilOnceMinimumPassed() {
        let recordedAt = Date(timeIntervalSince1970: 1_000)
        // 경과 시간이 최소와 같으면 더 기다리지 않는다.
        XCTAssertNil(
            KLMSAuthDigitsDisplayRules.remainingMinimumVisibleNanoseconds(
                recordedAt: recordedAt,
                now: Date(timeIntervalSince1970: 1_006),
                minimumVisibleNanoseconds: 6_000_000_000
            )
        )
        XCTAssertNil(
            KLMSAuthDigitsDisplayRules.remainingMinimumVisibleNanoseconds(
                recordedAt: recordedAt,
                now: Date(timeIntervalSince1970: 1_007),
                minimumVisibleNanoseconds: 6_000_000_000
            )
        )
    }
}
