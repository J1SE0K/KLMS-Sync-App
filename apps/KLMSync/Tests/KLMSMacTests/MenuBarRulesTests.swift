import XCTest
@testable import KLMSMac

/// 메뉴바 단축키와 아이콘 상태 규칙. 예전에는 DashboardDataModelTests 가 KLMSMacApp.swift 에
/// 같은 case 줄이 적혀 있는지를 문자열로 확인했다.
final class MenuBarRulesTests: XCTestCase {
    func testShortcutsRequireCommandAndRespectShift() {
        XCTAssertEqual(KLMSMenuShortcut(key: "o", hasCommand: true, hasShift: false), .openDashboard)
        XCTAssertEqual(KLMSMenuShortcut(key: "R", hasCommand: true, hasShift: false), .refreshStatus)
        XCTAssertEqual(KLMSMenuShortcut(key: "v", hasCommand: true, hasShift: true), .runVerify)
        XCTAssertEqual(KLMSMenuShortcut(key: "D", hasCommand: true, hasShift: true), .runDoctor)
        XCTAssertEqual(KLMSMenuShortcut(key: "q", hasCommand: true, hasShift: false), .quit)

        XCTAssertNil(KLMSMenuShortcut(key: "o", hasCommand: false, hasShift: false))
        XCTAssertNil(KLMSMenuShortcut(key: "o", hasCommand: true, hasShift: true))
        XCTAssertNil(KLMSMenuShortcut(key: "v", hasCommand: true, hasShift: false))
        XCTAssertNil(KLMSMenuShortcut(key: "q", hasCommand: true, hasShift: true))
        XCTAssertNil(KLMSMenuShortcut(key: "x", hasCommand: true, hasShift: false))
        XCTAssertNil(KLMSMenuShortcut(key: "", hasCommand: true, hasShift: false))
    }

    func testIconStatePriorityIsDigitsThenRunningThenAttention() {
        XCTAssertEqual(KLMSMenuBarStatusIconState(currentAuthDigits: "42", isRunning: true, needsAttention: true), .authDigits("42"))
        XCTAssertEqual(KLMSMenuBarStatusIconState(currentAuthDigits: nil, isRunning: true, needsAttention: true), .running)
        XCTAssertEqual(KLMSMenuBarStatusIconState(currentAuthDigits: nil, isRunning: false, needsAttention: true), .attention)
        XCTAssertEqual(KLMSMenuBarStatusIconState(currentAuthDigits: nil, isRunning: false, needsAttention: false), .ready)
    }

    func testMenuBarTitleShowsOnlyAuthDigits() {
        XCTAssertEqual(KLMSMenuBarStatusIconState.authDigits("17").menuBarTitle, "인증 17")
        XCTAssertEqual(KLMSMenuBarStatusIconState.ready.menuBarTitle, "")
        XCTAssertEqual(KLMSMenuBarStatusIconState.running.menuBarTitle, "")
        XCTAssertEqual(KLMSMenuBarStatusIconState.attention.menuBarTitle, "")
        XCTAssertEqual(KLMSMenuBarStatusIconState.authDigits("17").tooltip, "KLMS Sync 인증 번호 17")
        XCTAssertEqual(KLMSMenuBarStatusIconState.ready.tooltip, "KLMS Sync 준비됨")
        XCTAssertEqual(KLMSMenuBarStatusIconState.running.tooltip, "KLMS Sync 실행 중")
        XCTAssertEqual(KLMSMenuBarStatusIconState.attention.tooltip, "KLMS Sync 확인 필요")
    }
}
