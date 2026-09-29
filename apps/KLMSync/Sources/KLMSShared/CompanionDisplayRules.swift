import Foundation

// iOS 앱 화면이 쓰는 짧은 문구와 목록 판정 규칙. 앱 타깃은 테스트에서 가져올 수 없어서 예전에는
// iOS 앱 소스 문자열을 검사했다. 여기로 옮겨 동작으로 검사한다(CompanionDisplayRulesTests).

public enum KLMSCompanionText {
    /// 접근성 요약에 넣을 문장. 비어 있으면 빈 문자열, 문장부호로 끝나지 않으면 마침표를 붙인다.
    public static func accessibilitySentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let last = trimmed.last, ".!?。！？".contains(last) {
            return trimmed
        }
        return "\(trimmed)."
    }

    public static func activeStatusText(_ status: ServerRelayItemActionStatus) -> String {
        switch status {
        case .pending:
            return "대기 중입니다."
        case .running:
            return "처리 중입니다."
        case .completed, .failed, .macUnavailable:
            return "\(status.displayName) 상태입니다."
        }
    }

    public static func activeStatusText(_ status: ServerRelaySettingActionStatus) -> String {
        switch status {
        case .pending:
            return "대기 중입니다."
        case .running:
            return "처리 중입니다."
        case .completed, .failed, .macUnavailable:
            return "\(status.displayName) 상태입니다."
        }
    }

    public static func refreshFailureMessage(reason: String) -> String {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else {
            return "새로고침에 실패했습니다. 설정과 네트워크 상태를 확인해 주세요."
        }
        return "새로고침 실패 · \(trimmedReason)"
    }

    public static func userFacingMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "인터넷 연결을 확인해 주세요."
            case .timedOut:
                return "서버 응답 시간이 초과됐습니다. 잠시 뒤 다시 시도해 주세요."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "서버 URL을 찾지 못했습니다. 연결 설정의 서버 URL을 확인해 주세요."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return "서버 보안 연결을 확인하지 못했습니다. HTTPS 주소와 인증서를 확인해 주세요."
            default:
                break
            }
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty
            ? "요청을 완료하지 못했습니다. 서버 연결 설정과 네트워크 상태를 확인해 주세요."
            : message
    }

    public static func headerStatusText(isRefreshing: Bool, lastRefreshAt: Date?) -> String {
        if isRefreshing {
            return "갱신 중"
        }
        if let lastRefreshAt {
            return lastRefreshAt.formatted(date: .omitted, time: .shortened)
        }
        return "갱신 전"
    }

    public static func cancelButtonTitle(cancelAlreadyRequested: Bool, isSubmitting: Bool) -> String {
        if cancelAlreadyRequested {
            return "중단 요청됨"
        }
        if isSubmitting {
            return "요청 중"
        }
        return "중단"
    }

    public static func connectionStateText(recoveryRequired: Bool, hasUnsavedChanges: Bool, isConfigured: Bool) -> String {
        if recoveryRequired { return "복구 필요" }
        if hasUnsavedChanges { return "저장 필요" }
        return isConfigured ? "저장됨" : "미설정"
    }

    /// 좁은 화면 탭 막대의 줄 나누기. 큰 글자 크기에서는 3·2·나머지, 아니면 4·나머지.
    public static func compactTabRows<Tab>(_ tabs: [Tab], isAccessibilitySize: Bool) -> [[Tab]] {
        if isAccessibilitySize {
            return [
                Array(tabs.prefix(3)),
                Array(tabs.dropFirst(3).prefix(2)),
                Array(tabs.dropFirst(5)),
            ]
        }
        return [Array(tabs.prefix(4)), Array(tabs.dropFirst(4))]
    }
}

/// 항목 목록을 다시 계산할지 정하는 입력 묶음. 검색어만 바뀌었을 때만 입력 지연(debounce)을 건다.
public struct CompanionItemListInputKey: Hashable, Sendable {
    public var itemsRevision: Int
    public var category: String
    public var query: String
    public var sortOption: String
    public var visibilityFilter: String
    public var statusFilter: String
    public var selectedCourse: String
    public var selectedYear: String
    public var selectedSemester: String
    public var newOnly: Bool
    public var recentOnly: Bool

    public init(
        itemsRevision: Int,
        category: String,
        query: String,
        sortOption: String,
        visibilityFilter: String,
        statusFilter: String,
        selectedCourse: String,
        selectedYear: String,
        selectedSemester: String,
        newOnly: Bool,
        recentOnly: Bool
    ) {
        self.itemsRevision = itemsRevision
        self.category = category
        self.query = query
        self.sortOption = sortOption
        self.visibilityFilter = visibilityFilter
        self.statusFilter = statusFilter
        self.selectedCourse = selectedCourse
        self.selectedYear = selectedYear
        self.selectedSemester = selectedSemester
        self.newOnly = newOnly
        self.recentOnly = recentOnly
    }

    public func shouldDebounceComparedTo(_ previous: CompanionItemListInputKey?) -> Bool {
        guard let previous, query != previous.query else { return false }
        return itemsRevision == previous.itemsRevision
            && category == previous.category
            && sortOption == previous.sortOption
            && visibilityFilter == previous.visibilityFilter
            && statusFilter == previous.statusFilter
            && selectedCourse == previous.selectedCourse
            && selectedYear == previous.selectedYear
            && selectedSemester == previous.selectedSemester
            && newOnly == previous.newOnly
            && recentOnly == previous.recentOnly
    }
}

/// 서버 동기화 항목 한 줄에 보여 줄 값.
public struct ServerSyncRowSnapshot: Equatable, Sendable {
    public var id: String
    public var kind: String
    public var kindName: String
    public var systemImage: String
    public var status: String
    public var title: String
    public var metadata: String
    public var isHidden: Bool
    public var accessibilityLabel: String

    public init(item: ServerRelaySyncItem) {
        id = item.id
        kind = item.kind
        kindName = Self.kindName(for: item.kind)
        systemImage = Self.systemImage(for: item.kind)
        status = item.status
        title = item.title.isEmpty ? "제목 없음" : item.title
        metadata = Self.metadata(for: item)
        isHidden = item.isHidden
        accessibilityLabel = [kindName, title, metadata]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private static func metadata(for item: ServerRelaySyncItem) -> String {
        var parts: [String] = []
        if !item.course.isEmpty {
            parts.append(item.course)
        }
        if !item.academicTerm.isEmpty {
            parts.append(item.academicTerm)
        }
        if !item.timestamp.isEmpty {
            parts.append(item.timestamp)
        }
        if item.attachmentCount > 0 {
            parts.append("첨부 \(item.attachmentCount)")
        }
        if item.kind == "notice" {
            parts.append(item.isRead ? "읽음" : "안 읽음")
            if item.isImportant {
                parts.append("중요")
            }
        }
        return parts.isEmpty ? "세부 정보 없음" : parts.joined(separator: " · ")
    }

    private static func kindName(for kind: String) -> String {
        switch kind {
        case "assignment":
            "과제"
        case "completedAssignment":
            "완료 과제"
        case "assignmentCandidate":
            "과제 후보"
        case "exam":
            "시험"
        case "examCandidate":
            "시험 후보"
        case "helpDesk":
            "헬프데스크"
        case "notice":
            "공지"
        case "file":
            "파일"
        default:
            kind
        }
    }

    private static func systemImage(for kind: String) -> String {
        switch kind {
        case "assignment", "completedAssignment", "assignmentCandidate":
            "checklist"
        case "exam", "examCandidate":
            "calendar"
        case "notice":
            "note.text"
        case "file":
            "doc"
        case "helpDesk":
            "person.2"
        default:
            "circle"
        }
    }
}
