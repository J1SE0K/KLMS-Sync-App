import Foundation
import KLMSShared
import XCTest

final class CompanionDisplayRulesTests: XCTestCase {
    func testAccessibilitySentenceAddsPeriodOnlyWhenMissing() {
        XCTAssertEqual(KLMSCompanionText.accessibilitySentence(""), "")
        XCTAssertEqual(KLMSCompanionText.accessibilitySentence("  \n "), "")
        XCTAssertEqual(KLMSCompanionText.accessibilitySentence(" 상태 "), "상태.")
        XCTAssertEqual(KLMSCompanionText.accessibilitySentence("완료."), "완료.")
        XCTAssertEqual(KLMSCompanionText.accessibilitySentence("실패!"), "실패!")
        XCTAssertEqual(KLMSCompanionText.accessibilitySentence("확인?"), "확인?")
        XCTAssertEqual(KLMSCompanionText.accessibilitySentence("끝。"), "끝。")
        XCTAssertEqual(KLMSCompanionText.accessibilitySentence("주의！"), "주의！")
        XCTAssertEqual(KLMSCompanionText.accessibilitySentence("질문？"), "질문？")
    }

    func testActiveStatusTextForItemAndSettingActions() {
        XCTAssertEqual(KLMSCompanionText.activeStatusText(ServerRelayItemActionStatus.pending), "대기 중입니다.")
        XCTAssertEqual(KLMSCompanionText.activeStatusText(ServerRelayItemActionStatus.running), "처리 중입니다.")
        for status in [ServerRelayItemActionStatus.completed, .failed, .macUnavailable] {
            XCTAssertEqual(KLMSCompanionText.activeStatusText(status), "\(status.displayName) 상태입니다.")
        }
        XCTAssertEqual(KLMSCompanionText.activeStatusText(ServerRelaySettingActionStatus.pending), "대기 중입니다.")
        XCTAssertEqual(KLMSCompanionText.activeStatusText(ServerRelaySettingActionStatus.running), "처리 중입니다.")
        for status in [ServerRelaySettingActionStatus.completed, .failed, .macUnavailable] {
            XCTAssertEqual(KLMSCompanionText.activeStatusText(status), "\(status.displayName) 상태입니다.")
        }
    }

    func testRefreshFailureMessageUsesTrimmedReason() {
        XCTAssertEqual(
            KLMSCompanionText.refreshFailureMessage(reason: " \n"),
            "새로고침에 실패했습니다. 설정과 네트워크 상태를 확인해 주세요."
        )
        XCTAssertEqual(KLMSCompanionText.refreshFailureMessage(reason: " 서버 오류 "), "새로고침 실패 · 서버 오류")
    }

    func testUserFacingMessageMapsURLErrors() {
        XCTAssertEqual(KLMSCompanionText.userFacingMessage(for: URLError(.notConnectedToInternet)), "인터넷 연결을 확인해 주세요.")
        XCTAssertEqual(KLMSCompanionText.userFacingMessage(for: URLError(.networkConnectionLost)), "인터넷 연결을 확인해 주세요.")
        XCTAssertEqual(
            KLMSCompanionText.userFacingMessage(for: URLError(.timedOut)),
            "서버 응답 시간이 초과됐습니다. 잠시 뒤 다시 시도해 주세요."
        )
        for code in [URLError.Code.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed] {
            XCTAssertEqual(
                KLMSCompanionText.userFacingMessage(for: URLError(code)),
                "서버 URL을 찾지 못했습니다. 연결 설정의 서버 URL을 확인해 주세요."
            )
        }
        for code in [
            URLError.Code.secureConnectionFailed,
            .serverCertificateUntrusted,
            .serverCertificateHasBadDate,
            .serverCertificateNotYetValid,
        ] {
            XCTAssertEqual(
                KLMSCompanionText.userFacingMessage(for: URLError(code)),
                "서버 보안 연결을 확인하지 못했습니다. HTTPS 주소와 인증서를 확인해 주세요."
            )
        }
    }

    func testUserFacingMessageFallsBackToDescriptionOrDefault() {
        struct Described: LocalizedError {
            var errorDescription: String?
        }
        XCTAssertEqual(KLMSCompanionText.userFacingMessage(for: Described(errorDescription: "  토큰 만료 ")), "토큰 만료")
        XCTAssertEqual(
            KLMSCompanionText.userFacingMessage(for: Described(errorDescription: "  ")),
            "요청을 완료하지 못했습니다. 서버 연결 설정과 네트워크 상태를 확인해 주세요."
        )
    }

    func testHeaderStatusText() {
        XCTAssertEqual(KLMSCompanionText.headerStatusText(isRefreshing: true, lastRefreshAt: Date()), "갱신 중")
        XCTAssertEqual(KLMSCompanionText.headerStatusText(isRefreshing: false, lastRefreshAt: nil), "갱신 전")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            KLMSCompanionText.headerStatusText(isRefreshing: false, lastRefreshAt: date),
            date.formatted(date: .omitted, time: .shortened)
        )
    }

    func testCancelButtonTitlePrefersAlreadyRequested() {
        XCTAssertEqual(KLMSCompanionText.cancelButtonTitle(cancelAlreadyRequested: true, isSubmitting: true), "중단 요청됨")
        XCTAssertEqual(KLMSCompanionText.cancelButtonTitle(cancelAlreadyRequested: false, isSubmitting: true), "요청 중")
        XCTAssertEqual(KLMSCompanionText.cancelButtonTitle(cancelAlreadyRequested: false, isSubmitting: false), "중단")
    }

    func testConnectionStateTextOrder() {
        XCTAssertEqual(KLMSCompanionText.connectionStateText(recoveryRequired: true, hasUnsavedChanges: true, isConfigured: true), "복구 필요")
        XCTAssertEqual(KLMSCompanionText.connectionStateText(recoveryRequired: false, hasUnsavedChanges: true, isConfigured: true), "저장 필요")
        XCTAssertEqual(KLMSCompanionText.connectionStateText(recoveryRequired: false, hasUnsavedChanges: false, isConfigured: true), "저장됨")
        XCTAssertEqual(KLMSCompanionText.connectionStateText(recoveryRequired: false, hasUnsavedChanges: false, isConfigured: false), "미설정")
    }

    func testCompactTabRowsSplitBySize() {
        let tabs = [1, 2, 3, 4, 5, 6, 7]
        XCTAssertEqual(KLMSCompanionText.compactTabRows(tabs, isAccessibilitySize: false), [[1, 2, 3, 4], [5, 6, 7]])
        XCTAssertEqual(KLMSCompanionText.compactTabRows(tabs, isAccessibilitySize: true), [[1, 2, 3], [4, 5], [6, 7]])
    }

    func testItemListInputKeyDebouncesOnlyQueryOnlyChanges() {
        let base = CompanionItemListInputKey(
            itemsRevision: 1,
            category: "files",
            query: "a",
            sortOption: "recent",
            visibilityFilter: "visible",
            statusFilter: "all",
            selectedCourse: "all",
            selectedYear: "all",
            selectedSemester: "all",
            newOnly: false,
            recentOnly: false
        )
        XCTAssertFalse(base.shouldDebounceComparedTo(nil))
        XCTAssertFalse(base.shouldDebounceComparedTo(base))

        var queryOnly = base
        queryOnly.query = "ab"
        XCTAssertTrue(queryOnly.shouldDebounceComparedTo(base))

        let otherChanges: [(inout CompanionItemListInputKey) -> Void] = [
            { $0.itemsRevision = 2 },
            { $0.category = "notices" },
            { $0.sortOption = "title" },
            { $0.visibilityFilter = "hidden" },
            { $0.statusFilter = "new" },
            { $0.selectedCourse = "CS101" },
            { $0.selectedYear = "2026" },
            { $0.selectedSemester = "fall" },
            { $0.newOnly = true },
            { $0.recentOnly = true },
        ]
        for change in otherChanges {
            var key = queryOnly
            change(&key)
            XCTAssertFalse(key.shouldDebounceComparedTo(base))
        }
    }

    func testServerSyncRowSnapshotBuildsNoticeMetadata() {
        var item = ServerRelaySyncItem(id: "n1", kind: "notice", title: "")
        item.course = "CS101"
        item.academicTerm = "2026 가을"
        item.timestamp = "09-29"
        item.attachmentCount = 2
        item.isRead = false
        item.isImportant = true
        let snapshot = ServerSyncRowSnapshot(item: item)
        XCTAssertEqual(snapshot.kindName, "공지")
        XCTAssertEqual(snapshot.systemImage, "note.text")
        XCTAssertEqual(snapshot.title, "제목 없음")
        XCTAssertEqual(snapshot.metadata, "CS101 · 2026 가을 · 09-29 · 첨부 2 · 안 읽음 · 중요")
        XCTAssertEqual(snapshot.accessibilityLabel, "공지, 제목 없음, CS101 · 2026 가을 · 09-29 · 첨부 2 · 안 읽음 · 중요")
    }

    func testServerSyncRowSnapshotKindsAndEmptyMetadata() {
        let expectations: [(String, String, String)] = [
            ("assignment", "과제", "checklist"),
            ("completedAssignment", "완료 과제", "checklist"),
            ("assignmentCandidate", "과제 후보", "checklist"),
            ("exam", "시험", "calendar"),
            ("examCandidate", "시험 후보", "calendar"),
            ("helpDesk", "헬프데스크", "person.2"),
            ("file", "파일", "doc"),
            ("other", "other", "circle"),
        ]
        for (kind, name, image) in expectations {
            let snapshot = ServerSyncRowSnapshot(item: ServerRelaySyncItem(id: kind, kind: kind, title: "제목"))
            XCTAssertEqual(snapshot.kindName, name, kind)
            XCTAssertEqual(snapshot.systemImage, image, kind)
            XCTAssertEqual(snapshot.metadata, "세부 정보 없음", kind)
            XCTAssertEqual(snapshot.accessibilityLabel, "\(name), 제목, 세부 정보 없음", kind)
        }
    }
}
