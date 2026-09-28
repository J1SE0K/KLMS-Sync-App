import XCTest
@testable import KLMSShared

/// CompanionItemActionRules.swift 의 동작 검사. 예전에는 DashboardDataModelTests 가 iOS 앱 소스에
/// 같은 switch 가 적혀 있는지를 문자열로 확인했다.
final class CompanionItemActionRulesTests: XCTestCase {
    private let stamp = "2026-09-29T10:00:00Z"

    private func item(kind: String = "assignment", status: String = "제출 전", hidden: Bool = false) -> ServerRelaySyncItem {
        ServerRelaySyncItem(id: "i1", kind: kind, title: "과제", status: status, updatedAt: "old", isHidden: hidden)
    }

    private func applied(_ action: ServerRelayItemActionKind, to base: ServerRelaySyncItem) -> ServerRelaySyncItem {
        var next = base
        next.applyCompanionDisplayAction(action, updatedAt: stamp)
        return next
    }

    func testServerDisplayOnlyActionsExcludeFileTrashAndCalendar() {
        let displayOnly = Set(ServerRelayItemActionKind.allCases.filter(\.isServerDisplayOnlyAction))
        XCTAssertEqual(displayOnly, [
            .assignmentComplete, .assignmentRestore, .assignmentHide, .assignmentUnhide,
            .examPromote, .examIgnore, .examRestore,
            .noticeRead, .noticeUnread, .noticeImportant, .noticeUnimportant, .noticeHide, .noticeUnhide,
            .fileHide, .fileUnhide, .mailDashboardAdd, .mailDashboardRemove,
        ])
    }

    func testImmediateDisplayAddsOnlyFileTrash() {
        for kind in ServerRelayItemActionKind.allCases {
            XCTAssertEqual(
                kind.isCompanionImmediateDisplayAction,
                kind.isServerDisplayOnlyAction || kind == .fileTrash,
                "\(kind)"
            )
        }
        XCTAssertTrue(ServerRelayItemActionKind.fileTrash.isCompanionImmediateDisplayAction)
        XCTAssertFalse(ServerRelayItemActionKind.calendarApply.isCompanionImmediateDisplayAction)
    }

    func testSuccessFeedbackIsSuppressedOnlyForActionsThatRemoveTheItem() {
        let suppressed = Set(ServerRelayItemActionKind.allCases.filter(\.suppressesImmediateSuccessFeedback))
        XCTAssertEqual(suppressed, [
            .assignmentComplete, .assignmentHide, .examIgnore, .noticeHide, .fileHide, .fileTrash, .mailDashboardRemove,
        ])
    }

    func testAssignmentCompleteAndRestore() {
        let done = applied(.assignmentComplete, to: item(hidden: true))
        XCTAssertEqual(done.kind, "completedAssignment")
        XCTAssertEqual(done.status, "완료")
        XCTAssertFalse(done.isHidden)
        XCTAssertEqual(done.updatedAt, stamp)

        let restored = applied(.assignmentRestore, to: done)
        XCTAssertEqual(restored.kind, "assignment")
        XCTAssertEqual(restored.status, "")
        XCTAssertFalse(restored.isHidden)

        // 완료 기록이 아닌 항목은 kind 를 바꾸지 않는다.
        let unhidden = applied(.assignmentUnhide, to: item(kind: "notice", hidden: true))
        XCTAssertEqual(unhidden.kind, "notice")
        XCTAssertFalse(unhidden.isHidden)
    }

    func testHideAndExamActions() {
        let hidden = applied(.assignmentHide, to: item())
        XCTAssertEqual(hidden.status, "숨김")
        XCTAssertTrue(hidden.isHidden)

        let exam = applied(.examPromote, to: item(hidden: true))
        XCTAssertEqual(exam.kind, "exam")
        XCTAssertEqual(exam.status, "시험")
        XCTAssertFalse(exam.isHidden)

        let ignored = applied(.examIgnore, to: item(kind: "exam"))
        XCTAssertEqual(ignored.status, "시험 아님")
        XCTAssertTrue(ignored.isHidden)

        let examRestored = applied(.examRestore, to: ignored)
        XCTAssertEqual(examRestored.status, "")
        XCTAssertFalse(examRestored.isHidden)
    }

    func testNoticeFlagsAndVisibility() {
        let base = item(kind: "notice")
        XCTAssertTrue(applied(.noticeRead, to: base).isRead)
        XCTAssertFalse(applied(.noticeUnread, to: applied(.noticeRead, to: base)).isRead)
        XCTAssertTrue(applied(.noticeImportant, to: base).isImportant)
        XCTAssertFalse(applied(.noticeUnimportant, to: applied(.noticeImportant, to: base)).isImportant)
        XCTAssertTrue(applied(.noticeHide, to: base).isHidden)
        XCTAssertTrue(applied(.fileHide, to: base).isHidden)
        XCTAssertFalse(applied(.noticeUnhide, to: item(hidden: true)).isHidden)
        XCTAssertFalse(applied(.fileUnhide, to: item(hidden: true)).isHidden)
        XCTAssertFalse(applied(.mailDashboardAdd, to: item(hidden: true)).isHidden)
    }

    func testTrashAndCalendarRequestsMarkDeletionExceptOpen() {
        for action in [ServerRelayItemActionKind.fileTrash, .calendarVerify, .calendarApply, .calendarCreate, .calendarEdit, .calendarDelete] {
            let next = applied(action, to: item())
            XCTAssertEqual(next.status, "삭제 요청", "\(action)")
            XCTAssertTrue(next.isHidden, "\(action)")
        }
        // 캘린더 열기와 메일 목록 빼기는 시각만 바꾸고 나머지는 그대로 둔다.
        for action in [ServerRelayItemActionKind.calendarOpen, .mailDashboardRemove] {
            let base = item(status: "그대로", hidden: false)
            var expected = base
            expected.updatedAt = stamp
            XCTAssertEqual(applied(action, to: base), expected, "\(action)")
        }
    }
}
