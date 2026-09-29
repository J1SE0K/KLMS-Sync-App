import XCTest
@testable import KLMSMac
import KLMSShared

/// 알림 배너와 진행률 막대 규칙. 예전에는 DashboardDataModelTests 가 MenuBarRootView.swift 에
/// 같은 분기 줄이 적혀 있는지를 문자열로 확인했다.
final class MacAlertBannerRulesTests: XCTestCase {
    private func banner(
        authDigits: String? = nil,
        authStatusMessage: String? = nil,
        runningCommandDisplayName: String? = nil,
        currentPhaseText: String? = nil,
        liveProgressLine: String? = nil,
        hasRecentRunFailure: Bool = false,
        needsAttention: Bool = false,
        hasSyncReport: Bool = true,
        firstRunReadinessCompleted: Bool = false,
        loggedIn: Bool = false
    ) -> MacAlertBannerSnapshot {
        MacAlertBannerSnapshot(
            authDigits: authDigits,
            authStatusMessage: authStatusMessage,
            runningCommandDisplayName: runningCommandDisplayName,
            currentPhaseText: currentPhaseText,
            liveProgressLine: liveProgressLine,
            runningProgress: nil,
            hasRecentRunFailure: hasRecentRunFailure,
            recentRunFailureTitle: "전체 동기화 실패",
            recentRunFailureDetail: "종료 코드 1",
            needsAttention: needsAttention,
            hasSyncReport: hasSyncReport,
            firstRunReadinessCompleted: firstRunReadinessCompleted,
            loggedIn: loggedIn
        )
    }

    // MARK: - 알림 배너

    func testIdleBannerIsHiddenAndReportsReadyState() {
        let idle = banner()
        XCTAssertFalse(idle.shouldShow)
        XCTAssertEqual(idle.title, "준비됨")
        XCTAssertEqual(idle.detail, "동기화를 바로 실행할 수 있습니다. 인증번호가 필요하면 여기에 크게 고정됩니다.")
        XCTAssertEqual(idle.chipText, "확인")
        XCTAssertEqual(idle.chipHorizontalPadding, 12)
        XCTAssertEqual(idle.tone, .ready)

        XCTAssertEqual(banner(loggedIn: true).title, "이미 로그인됨")
    }

    func testFirstRunReadinessShowsOnlyBeforeFirstReportAndBeforeCompletion() {
        let firstRun = banner(hasSyncReport: false)
        XCTAssertTrue(firstRun.shouldShow)
        XCTAssertEqual(firstRun.title, "처음 실행 준비")
        XCTAssertEqual(firstRun.detail, "환경 진단을 실행하면 권한, 엔진, 메모/캘린더/미리 알림 상태를 확인합니다.")
        XCTAssertEqual(firstRun.chipText, "검사")
        XCTAssertEqual(firstRun.tone, .warning)

        // 준비를 마쳤으면 보고서가 없어도 배너를 띄우지 않는다.
        let completed = banner(hasSyncReport: false, firstRunReadinessCompleted: true)
        XCTAssertFalse(completed.shouldShow)
        XCTAssertEqual(completed.title, "준비됨")
        XCTAssertEqual(completed.chipText, "확인")
        XCTAssertEqual(completed.tone, .ready)
    }

    func testNeedsAttentionPointsToLogTab() {
        let attention = banner(needsAttention: true, hasSyncReport: false)
        XCTAssertTrue(attention.shouldShow)
        XCTAssertEqual(attention.title, "상태 검사 실패")
        XCTAssertEqual(attention.detail, "로그 탭에서 실패 흐름과 마지막 메시지를 확인할 수 있습니다.")
        XCTAssertEqual(attention.chipText, "로그")
        XCTAssertEqual(attention.chipHorizontalPadding, 12)
        XCTAssertEqual(attention.tone, .warning)
    }

    func testRecentRunFailureWinsOverNeedsAttention() {
        let failure = banner(hasRecentRunFailure: true, needsAttention: true)
        XCTAssertTrue(failure.shouldShow)
        XCTAssertEqual(failure.title, "전체 동기화 실패")
        XCTAssertEqual(failure.detail, "종료 코드 1 · 실행 로그에서 원인을 바로 확인할 수 있습니다.")
        XCTAssertEqual(failure.chipText, "로그")
        XCTAssertEqual(failure.tone, .warning)

        XCTAssertTrue(banner(hasRecentRunFailure: true).shouldShow)
    }

    func testRunningCommandWithPhaseShowsPhaseEverywhere() {
        let running = banner(
            runningCommandDisplayName: "전체 동기화",
            currentPhaseText: "파일",
            liveProgressLine: "다운로드 3/10",
            hasRecentRunFailure: true,
            needsAttention: true
        )
        XCTAssertTrue(running.shouldShow)
        XCTAssertEqual(running.title, "전체 동기화 · 파일")
        XCTAssertEqual(running.detail, "현재 단계: 파일")
        XCTAssertEqual(running.chipText, "파일")
        XCTAssertEqual(running.chipHorizontalPadding, 10)
        XCTAssertEqual(running.tone, .running)
    }

    func testRunningCommandWithoutPhaseFallsBackToLiveLineThenGenericText() {
        let withLiveLine = banner(runningCommandDisplayName: "전체 동기화", liveProgressLine: "다운로드 3/10")
        XCTAssertTrue(withLiveLine.shouldShow)
        XCTAssertEqual(withLiveLine.title, "전체 동기화 실행 중")
        XCTAssertEqual(withLiveLine.detail, "다운로드 3/10")
        XCTAssertEqual(withLiveLine.chipText, "LOG")
        XCTAssertEqual(withLiveLine.chipHorizontalPadding, 12)
        XCTAssertEqual(withLiveLine.tone, .running)

        let withoutLiveLine = banner(runningCommandDisplayName: "전체 동기화")
        XCTAssertEqual(withoutLiveLine.detail, "실시간 로그에서 진행 상황을 확인할 수 있습니다.")
    }

    func testAuthStatusMessageWinsOverRunningCommandForTitleAndTone() {
        let status = banner(authStatusMessage: "인증 완료됨", runningCommandDisplayName: "전체 동기화", currentPhaseText: "로그인")
        XCTAssertTrue(status.shouldShow)
        XCTAssertEqual(status.title, "인증 완료됨")
        XCTAssertEqual(status.detail, "인증 상태가 확인됐습니다. 필요한 경우 다음 단계가 바로 이어집니다.")
        // 칩은 인증 상태 메시지를 따로 보지 않으므로 실행 중 단계가 그대로 보인다.
        XCTAssertEqual(status.chipText, "로그인")
        XCTAssertEqual(status.chipHorizontalPadding, 10)
        XCTAssertEqual(status.tone, .success)

        let statusOnly = banner(authStatusMessage: "이미 로그인됨")
        XCTAssertTrue(statusOnly.shouldShow)
        XCTAssertEqual(statusOnly.title, "이미 로그인됨")
        XCTAssertEqual(statusOnly.chipText, "확인")
        XCTAssertEqual(statusOnly.chipHorizontalPadding, 12)
        XCTAssertEqual(statusOnly.tone, .success)
    }

    func testAuthDigitsWinOverEverything() {
        let digits = banner(
            authDigits: "42",
            authStatusMessage: "인증 완료됨",
            runningCommandDisplayName: "전체 동기화",
            currentPhaseText: "로그인",
            hasRecentRunFailure: true,
            needsAttention: true,
            hasSyncReport: false
        )
        XCTAssertTrue(digits.shouldShow)
        XCTAssertEqual(digits.title, "KAIST 인증 번호")
        XCTAssertEqual(digits.detail, "휴대폰 인증 화면에서 같은 번호를 선택하면 동기화를 계속 진행합니다.")
        XCTAssertEqual(digits.chipText, "42")
        XCTAssertEqual(digits.chipHorizontalPadding, 16)
        XCTAssertEqual(digits.tone, .authDigits)
    }

    // MARK: - 진행률 막대

    func testStagesPerCommand() {
        XCTAssertEqual(MacRunningProgressSnapshot.stages(for: .fullSync), ["로그인", "파일", "과제/시험", "공지", "상태 검사", "정리"])
        XCTAssertEqual(MacRunningProgressSnapshot.stages(for: .filesSync), ["로그인", "파일", "정리"])
        XCTAssertEqual(MacRunningProgressSnapshot.stages(for: .coreSync), ["로그인", "과제/시험", "상태 검사"])
        XCTAssertEqual(MacRunningProgressSnapshot.stages(for: .noticeSync), ["로그인", "공지", "상태 검사"])
        XCTAssertEqual(MacRunningProgressSnapshot.stages(for: .verify), ["상태 검사"])
        XCTAssertEqual(MacRunningProgressSnapshot.stages(for: .doctor), ["환경 진단"])
        XCTAssertEqual(MacRunningProgressSnapshot.stages(for: .report), ["요약 갱신"])
        XCTAssertEqual(MacRunningProgressSnapshot.stages(for: .v2BuildState), ["상태 파일"])
    }

    func testPhaseTextIsTrimmedAndMappedToMatchingStage() {
        let files = MacRunningProgressSnapshot(command: .fullSync, phaseText: "  파일 동기화 ")
        XCTAssertEqual(files.phaseText, "파일 동기화")
        XCTAssertEqual(files.currentIndex, 1)
        XCTAssertEqual(files.currentStageText, "파일")
        XCTAssertEqual(files.progressLabel, "2/6 · 파일")
        XCTAssertEqual(files.fraction, 1.55 / 6, accuracy: 1e-9)

        let cleanup = MacRunningProgressSnapshot(command: .fullSync, phaseText: "정리 중")
        XCTAssertEqual(cleanup.currentIndex, 5)
        XCTAssertEqual(cleanup.progressLabel, "6/6 · 정리")
        XCTAssertEqual(cleanup.fraction, 5.55 / 6, accuracy: 1e-9)

        let notices = MacRunningProgressSnapshot(command: .fullSync, phaseText: "공지")
        XCTAssertEqual(notices.currentIndex, 3)

        let tasks = MacRunningProgressSnapshot(command: .fullSync, phaseText: "시험 일정")
        XCTAssertEqual(tasks.currentIndex, 2)

        let verify = MacRunningProgressSnapshot(command: .noticeSync, phaseText: "상태 검사")
        XCTAssertEqual(verify.currentIndex, 2)
        XCTAssertEqual(verify.fraction, 2.55 / 3, accuracy: 1e-9)
    }

    func testEarlierKeywordWinsWhenPhaseMentionsSeveralStages() {
        // "파일" 검사가 "상태" 검사보다 먼저다.
        let mixed = MacRunningProgressSnapshot(command: .fullSync, phaseText: "파일 상태")
        XCTAssertEqual(mixed.currentIndex, 1)
    }

    func testMissingStageFallsBackToSecondOrLastStage() {
        // filesSync 에는 과제/시험 단계가 없어 min(1, 2) = 1 로 간다.
        XCTAssertEqual(MacRunningProgressSnapshot(command: .filesSync, phaseText: "과제").currentIndex, 1)
        // coreSync 에는 공지 단계가 없어 min(1, 2) = 1 로 간다.
        XCTAssertEqual(MacRunningProgressSnapshot(command: .coreSync, phaseText: "공지").currentIndex, 1)
        // coreSync 에는 정리 단계가 없어 마지막 단계로 간다.
        XCTAssertEqual(MacRunningProgressSnapshot(command: .coreSync, phaseText: "정리").currentIndex, 2)
        // 단계가 하나뿐이면 min(1, 0) = 0 이다.
        let verifyFiles = MacRunningProgressSnapshot(command: .verify, phaseText: "파일")
        XCTAssertEqual(verifyFiles.currentIndex, 0)
        XCTAssertEqual(verifyFiles.progressLabel, "1/1 · 상태 검사")
        XCTAssertEqual(verifyFiles.fraction, 0.55, accuracy: 1e-9)
        XCTAssertEqual(MacRunningProgressSnapshot(command: .doctor, phaseText: "검사").currentIndex, 0)
    }

    func testUnknownOrBlankPhaseStartsAtFirstStage() {
        let blank = MacRunningProgressSnapshot(command: .fullSync, phaseText: "   ")
        XCTAssertNil(blank.phaseText)
        XCTAssertEqual(blank.currentIndex, 0)
        XCTAssertEqual(blank.currentStageText, "로그인")
        XCTAssertEqual(blank.fraction, 0.55 / 6, accuracy: 1e-9)

        XCTAssertNil(MacRunningProgressSnapshot(command: .fullSync, phaseText: nil).phaseText)
        XCTAssertEqual(MacRunningProgressSnapshot(command: .fullSync, phaseText: "로그인 준비").currentIndex, 0)
        XCTAssertEqual(MacRunningProgressSnapshot(command: .fullSync, phaseText: "알 수 없음").currentIndex, 0)
    }

    func testEmptyStagesUseFloorFractionAndPhaseText() {
        var progress = MacRunningProgressSnapshot(command: .verify, phaseText: "대기")
        progress.stages = []
        XCTAssertEqual(progress.fraction, 0.08, accuracy: 1e-9)
        XCTAssertEqual(progress.currentStageText, "대기")
        XCTAssertEqual(progress.progressLabel, "1/1 · 대기")

        progress.phaseText = nil
        XCTAssertEqual(progress.currentStageText, "진행 중")
    }
}
