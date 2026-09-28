import XCTest
@testable import KLMSShared

/// KLMSRemoteSyncControls 의 동작 검사. 예전에는 DashboardDataModelTests 가 iOS 동기화 카드 소스에
/// 같은 조건식이 적혀 있는지를 문자열로 확인했다.
final class RemoteSyncControlRulesTests: XCTestCase {
    func testRunningWhenRequestInFlightOrMacReportsRunning() {
        XCTAssertTrue(KLMSRemoteSyncControls.isRunning(hasInFlightRequest: true, phase: "idle"))
        XCTAssertTrue(KLMSRemoteSyncControls.isRunning(hasInFlightRequest: false, phase: "running"))
        XCTAssertFalse(KLMSRemoteSyncControls.isRunning(hasInFlightRequest: false, phase: "Running"))
        XCTAssertFalse(KLMSRemoteSyncControls.isRunning(hasInFlightRequest: false, phase: ""))
    }

    func testStateTitleShowsRequestLabelWhileRunning() {
        XCTAssertEqual(KLMSRemoteSyncControls.stateTitle(isRunning: true, activeRequestLabel: "전체 동기화 중", isRemoteAvailable: false), "전체 동기화 중")
        XCTAssertEqual(KLMSRemoteSyncControls.stateTitle(isRunning: false, activeRequestLabel: "x", isRemoteAvailable: true), "준비됨")
        XCTAssertEqual(KLMSRemoteSyncControls.stateTitle(isRunning: false, activeRequestLabel: "x", isRemoteAvailable: false), "설정 필요")
    }

    func testActiveCommandNeedsInFlightStatusAndSameKind() {
        let kind = RemoteCommandKind.allCases[0]
        let other = RemoteCommandKind.allCases.first { $0 != kind }
        XCTAssertTrue(KLMSRemoteSyncControls.isCommandActive(kind, latestDisplayStatusIsInFlight: true, latestCommandKind: kind))
        XCTAssertFalse(KLMSRemoteSyncControls.isCommandActive(kind, latestDisplayStatusIsInFlight: false, latestCommandKind: kind))
        XCTAssertFalse(KLMSRemoteSyncControls.isCommandActive(kind, latestDisplayStatusIsInFlight: true, latestCommandKind: nil))
        if let other {
            XCTAssertFalse(KLMSRemoteSyncControls.isCommandActive(kind, latestDisplayStatusIsInFlight: true, latestCommandKind: other))
        }
    }

    func testCommandDisabledRules() {
        // 연결이 없거나 제출 중이면 활성 명령이어도 막는다.
        XCTAssertTrue(KLMSRemoteSyncControls.commandDisabled(isRemoteAvailable: false, isSubmitting: false, hasInFlightRequest: false, isCommandActive: true))
        XCTAssertTrue(KLMSRemoteSyncControls.commandDisabled(isRemoteAvailable: true, isSubmitting: true, hasInFlightRequest: false, isCommandActive: true))
        // 다른 요청이 도는 중이면 실행 중인 그 명령(멈춤 버튼)만 남긴다.
        XCTAssertTrue(KLMSRemoteSyncControls.commandDisabled(isRemoteAvailable: true, isSubmitting: false, hasInFlightRequest: true, isCommandActive: false))
        XCTAssertFalse(KLMSRemoteSyncControls.commandDisabled(isRemoteAvailable: true, isSubmitting: false, hasInFlightRequest: true, isCommandActive: true))
        XCTAssertFalse(KLMSRemoteSyncControls.commandDisabled(isRemoteAvailable: true, isSubmitting: false, hasInFlightRequest: false, isCommandActive: false))
    }
}
