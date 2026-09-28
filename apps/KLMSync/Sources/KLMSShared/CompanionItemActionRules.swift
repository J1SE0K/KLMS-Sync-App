import Foundation

// iOS 앱이 서버 항목 요청을 화면에 바로 반영할 때 쓰던 규칙. 앱 타깃은 테스트에서 가져올 수 없어서
// 예전에는 앱 소스 문자열을 검사했다. 여기로 옮겨 동작으로 검사한다(CompanionItemActionRulesTests).
// Xcode 빌드는 이 파일을 iOS 앱과 같은 모듈로 묶으므로 앱 쪽에 같은 이름을 다시 선언하면 안 된다.

public extension ServerRelayItemActionKind {
    /// Mac 을 거치지 않고 서버 화면 상태만 바꾸는 요청.
    var isServerDisplayOnlyAction: Bool {
        switch self {
        case .assignmentComplete,
             .assignmentRestore,
             .assignmentHide,
             .assignmentUnhide,
             .examPromote,
             .examIgnore,
             .examRestore,
             .noticeRead,
             .noticeUnread,
             .noticeImportant,
             .noticeUnimportant,
             .noticeHide,
             .noticeUnhide,
             .fileHide,
             .fileUnhide,
             .mailDashboardAdd,
             .mailDashboardRemove:
            true
        case .fileTrash,
             .calendarVerify,
             .calendarApply,
             .calendarCreate,
             .calendarEdit,
             .calendarDelete,
             .calendarOpen:
            false
        }
    }

    /// 서버 응답을 기다리지 않고 동반 앱 화면에 먼저 반영하는 요청. 파일 휴지통은 Mac 을 거치지만 화면에서는 바로 감춘다.
    var isCompanionImmediateDisplayAction: Bool {
        isServerDisplayOnlyAction || self == .fileTrash
    }

    /// 항목이 화면에서 사라지는 요청이라 따로 성공 알림을 띄우지 않는다.
    var suppressesImmediateSuccessFeedback: Bool {
        switch self {
        case .assignmentComplete,
             .assignmentHide,
             .examIgnore,
             .noticeHide,
             .fileHide,
             .fileTrash,
             .mailDashboardRemove:
            true
        case .assignmentRestore,
             .assignmentUnhide,
             .examPromote,
             .examRestore,
             .noticeRead,
             .noticeUnread,
             .noticeImportant,
             .noticeUnimportant,
             .noticeUnhide,
             .fileUnhide,
             .calendarVerify,
             .calendarApply,
             .calendarCreate,
             .calendarEdit,
             .calendarDelete,
             .calendarOpen,
             .mailDashboardAdd:
            false
        }
    }
}

public extension ServerRelaySyncItem {
    /// 요청 하나를 항목에 반영한 모습. 서버가 확인해 주기 전 화면에 먼저 보일 상태다.
    /// iOS 앱의 즉시 반영(applyServerVisibleItemActionLocally)과 최근 요청 덮어쓰기(syncItemsOverlayingRecentDisplayActions)가
    /// 같은 switch 를 두 벌 들고 있던 것을 합쳤다.
    mutating func applyCompanionDisplayAction(_ action: ServerRelayItemActionKind, updatedAt: String) {
        self.updatedAt = updatedAt
        switch action {
        case .assignmentComplete:
            kind = "completedAssignment"
            status = "완료"
            isHidden = false
        case .assignmentRestore, .assignmentUnhide:
            if kind == "completedAssignment" {
                kind = "assignment"
            }
            status = ""
            isHidden = false
        case .assignmentHide:
            status = "숨김"
            isHidden = true
        case .examPromote:
            kind = "exam"
            status = "시험"
            isHidden = false
        case .examIgnore:
            status = "시험 아님"
            isHidden = true
        case .examRestore:
            status = ""
            isHidden = false
        case .noticeRead:
            isRead = true
        case .noticeUnread:
            isRead = false
        case .noticeImportant:
            isImportant = true
        case .noticeUnimportant:
            isImportant = false
        case .noticeHide, .fileHide:
            isHidden = true
        case .noticeUnhide, .fileUnhide:
            isHidden = false
        case .mailDashboardRemove:
            break
        case .mailDashboardAdd:
            isHidden = false
        case .fileTrash,
             .calendarVerify,
             .calendarApply,
             .calendarCreate,
             .calendarEdit,
             .calendarDelete:
            status = "삭제 요청"
            isHidden = true
        case .calendarOpen:
            break
        }
    }
}
