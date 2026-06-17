import Foundation

public struct LegacySyncState: Decodable, Sendable, Equatable {
    public var status: String
    public var generatedAt: String
    public var content: Content

    enum CodingKeys: String, CodingKey {
        case status
        case generatedAt = "generated_at"
        case content
    }

    public init(status: String = "missing", generatedAt: String = "", content: Content = Content()) {
        self.status = status
        self.generatedAt = generatedAt
        self.content = content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.decodeIfPresentDefault(String.self, forKey: .status, default: "missing")
        generatedAt = container.decodeIfPresentDefault(String.self, forKey: .generatedAt, default: "")
        content = container.decodeIfPresentDefault(Content.self, forKey: .content, default: Content())
    }

    public struct Content: Decodable, Sendable, Equatable {
        public var kind: String
        public var assignments: [StateItem]
        public var completedAssignments: [StateItem]
        public var assignmentRecords: [StateItem]
        public var assignmentCandidates: [StateItem]
        public var examItems: [StateItem]
        public var examCandidates: [StateItem]
        public var pastExams: [StateItem]
        public var examRecords: [StateItem]
        public var helpDeskItems: [StateItem]

        enum CodingKeys: String, CodingKey {
            case kind
            case assignments
            case completedAssignments = "completed_assignments"
            case assignmentRecords = "assignment_records"
            case assignmentCandidates = "assignment_candidates"
            case examItems = "exam_items"
            case examCandidates = "exam_candidates"
            case pastExams = "past_exams"
            case examRecords = "exam_records"
            case helpDeskItems = "help_desk_items"
        }

        public init(
            kind: String = "",
            assignments: [StateItem] = [],
            completedAssignments: [StateItem] = [],
            assignmentRecords: [StateItem] = [],
            assignmentCandidates: [StateItem] = [],
            examItems: [StateItem] = [],
            examCandidates: [StateItem] = [],
            pastExams: [StateItem] = [],
            examRecords: [StateItem] = [],
            helpDeskItems: [StateItem] = []
        ) {
            self.kind = kind
            self.assignments = assignments
            self.completedAssignments = completedAssignments
            self.assignmentRecords = assignmentRecords
            self.assignmentCandidates = assignmentCandidates
            self.examItems = examItems
            self.examCandidates = examCandidates
            self.pastExams = pastExams
            self.examRecords = examRecords
            self.helpDeskItems = helpDeskItems
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = container.decodeIfPresentDefault(String.self, forKey: .kind, default: "")
            assignments = container.decodeIfPresentDefault([StateItem].self, forKey: .assignments, default: [])
            completedAssignments = container.decodeIfPresentDefault([StateItem].self, forKey: .completedAssignments, default: [])
            assignmentRecords = container.decodeIfPresentDefault([StateItem].self, forKey: .assignmentRecords, default: [])
            assignmentCandidates = container.decodeIfPresentDefault([StateItem].self, forKey: .assignmentCandidates, default: [])
            examItems = container.decodeIfPresentDefault([StateItem].self, forKey: .examItems, default: [])
            examCandidates = container.decodeIfPresentDefault([StateItem].self, forKey: .examCandidates, default: [])
            pastExams = container.decodeIfPresentDefault([StateItem].self, forKey: .pastExams, default: [])
            examRecords = container.decodeIfPresentDefault([StateItem].self, forKey: .examRecords, default: [])
            helpDeskItems = container.decodeIfPresentDefault([StateItem].self, forKey: .helpDeskItems, default: [])
        }
    }
}

public struct StateItem: Decodable, Sendable, Equatable, Identifiable {
    public var url: String
    public var type: String
    public var category: String
    public var course: String
    public var title: String
    public var due: String
    public var submission: String
    public var syncDue: String
    public var syncStart: String
    public var location: String
    public var coverageSummary: String
    public var autoCompleted: Bool
    public var recordStatus: String
    public var completionReason: String

    public var id: String { url.isEmpty ? "\(course)-\(title)-\(syncDue)" : url }

    public init(
        url: String = "",
        type: String = "",
        category: String = "",
        course: String = "",
        title: String = "",
        due: String = "",
        submission: String = "",
        syncDue: String = "",
        syncStart: String = "",
        location: String = "",
        coverageSummary: String = "",
        autoCompleted: Bool = false,
        recordStatus: String = "",
        completionReason: String = ""
    ) {
        self.url = url
        self.type = type
        self.category = category
        self.course = course
        self.title = title
        self.due = due
        self.submission = submission
        self.syncDue = syncDue
        self.syncStart = syncStart
        self.location = location
        self.coverageSummary = coverageSummary
        self.autoCompleted = autoCompleted
        self.recordStatus = recordStatus
        self.completionReason = completionReason
    }

    enum CodingKeys: String, CodingKey {
        case url
        case type
        case category
        case course
        case title
        case due
        case submission
        case syncDue = "sync_due"
        case syncStart = "sync_start"
        case location
        case coverageSummary = "coverage_summary"
        case autoCompleted = "auto_completed"
        case recordStatus = "record_status"
        case completionReason = "completion_reason"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = container.decodeIfPresentDefault(String.self, forKey: .url, default: "")
        type = container.decodeIfPresentDefault(String.self, forKey: .type, default: "")
        category = container.decodeIfPresentDefault(String.self, forKey: .category, default: "")
        course = container.decodeIfPresentDefault(String.self, forKey: .course, default: "")
        title = container.decodeIfPresentDefault(String.self, forKey: .title, default: "")
        due = container.decodeIfPresentDefault(String.self, forKey: .due, default: "")
        submission = container.decodeIfPresentDefault(String.self, forKey: .submission, default: "")
        syncDue = container.decodeIfPresentDefault(String.self, forKey: .syncDue, default: "")
        syncStart = container.decodeIfPresentDefault(String.self, forKey: .syncStart, default: "")
        location = container.decodeIfPresentDefault(String.self, forKey: .location, default: "")
        coverageSummary = container.decodeIfPresentDefault(String.self, forKey: .coverageSummary, default: "")
        autoCompleted = container.decodeIfPresentDefault(Bool.self, forKey: .autoCompleted, default: false)
        recordStatus = container.decodeIfPresentDefault(String.self, forKey: .recordStatus, default: "")
        completionReason = container.decodeIfPresentDefault(String.self, forKey: .completionReason, default: "")
    }
}

public extension LegacySyncState {
    func applyingManualOverrides(_ overrides: ManualOverridesSnapshot) -> LegacySyncState {
        var updated = self
        updated.content = content.applyingManualOverrides(overrides)
        return updated
    }
}

public extension LegacySyncState.Content {
    func applyingManualOverrides(_ overrides: ManualOverridesSnapshot) -> LegacySyncState.Content {
        var updated = self
        var nextAssignments: [StateItem] = []
        var nextAssignmentCandidates: [StateItem] = []
        var nextCompletedAssignments: [StateItem] = []
        var nextAssignmentRecords: [StateItem] = []
        var nextExamItems: [StateItem] = []
        var nextExamCandidates: [StateItem] = []
        var nextPastExams: [StateItem] = []
        var nextExamRecords: [StateItem] = []
        var nextHelpDeskItems: [StateItem] = []
        var assignmentIndexes: [String: Int] = [:]
        var candidateIndexes: [String: Int] = [:]
        var completedIndexes: [String: Int] = [:]
        var recordIndexes: [String: Int] = [:]
        var examIndexes: [String: Int] = [:]
        var examCandidateIndexes: [String: Int] = [:]
        var pastExamIndexes: [String: Int] = [:]
        var examRecordIndexes: [String: Int] = [:]
        var helpDeskIndexes: [String: Int] = [:]

        func upsert(_ item: StateItem, into items: inout [StateItem], indexes: inout [String: Int]) {
            let key = item.dashboardIdentityKey
            if let index = indexes[key] {
                items[index] = item
            } else {
                indexes[key] = items.count
                items.append(item)
            }
        }

        func upsertExam(_ item: StateItem, into items: inout [StateItem], indexes: inout [String: Int]) {
            let key = item.dashboardExamIdentityKey
            if let index = indexes[key] {
                items[index] = item
            } else {
                indexes[key] = items.count
                items.append(item)
            }
        }

        func appendRecord(_ item: StateItem) {
            upsert(item, into: &nextAssignmentRecords, indexes: &recordIndexes)
        }

        func appendExamRecord(_ item: StateItem) {
            upsertExam(item, into: &nextExamRecords, indexes: &examRecordIndexes)
        }

        func processActive(_ item: StateItem, asCandidate: Bool) {
            let status = overrides.assignmentStatus(for: item)
            if status == "completed" {
                let completed = item.dashboardMarkedCompleted()
                upsert(completed, into: &nextCompletedAssignments, indexes: &completedIndexes)
                appendRecord(completed)
            } else if status.isDashboardIgnoredAssignmentStatus {
                appendRecord(item.dashboardMarkedRecordStatus(status))
            } else if asCandidate {
                upsert(item, into: &nextAssignmentCandidates, indexes: &candidateIndexes)
                appendRecord(item.dashboardMarkedActiveIfNeeded())
            } else {
                upsert(item, into: &nextAssignments, indexes: &assignmentIndexes)
                appendRecord(item.dashboardMarkedActiveIfNeeded())
            }
        }

        func processExam(_ item: StateItem, asCandidate: Bool) {
            let override = overrides.examOverride(for: item)
            let status = override.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if status.isDashboardIgnoredExamStatus {
                appendExamRecord(item.dashboardMarkedExamRecordStatus(status))
                return
            }

            var next = item.dashboardApplyingExamOverride(override)
            if next.isDashboardPastExam {
                if asCandidate || next.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "exam_candidate" {
                    appendExamRecord(next.dashboardMarkedExamRecordStatus("candidate"))
                    return
                }
                let past = next.dashboardMarkedPastExamRecord()
                upsertExam(past, into: &nextPastExams, indexes: &pastExamIndexes)
                appendExamRecord(past)
                return
            }
            if status == "approved" || status == "confirmed" || status == "active" {
                next.type = "exam"
                next.category = "exam"
                let active = next.dashboardMarkedExamRecordStatus("active")
                upsertExam(active, into: &nextExamItems, indexes: &examIndexes)
                appendExamRecord(active)
            } else if asCandidate {
                next.category = "exam_candidate"
                let candidate = next.dashboardMarkedExamRecordStatus("candidate")
                upsertExam(candidate, into: &nextExamCandidates, indexes: &examCandidateIndexes)
                appendExamRecord(candidate)
            } else {
                next.type = "exam"
                next.category = "exam"
                let active = next.dashboardMarkedExamRecordStatus("active")
                upsertExam(active, into: &nextExamItems, indexes: &examIndexes)
                appendExamRecord(active)
            }
        }

        func processHelpDesk(_ item: StateItem) {
            let status = overrides.assignmentStatus(for: item)
            if status == "completed" {
                appendRecord(item.dashboardMarkedCompleted())
            } else if status.isDashboardIgnoredAssignmentStatus {
                appendRecord(item.dashboardMarkedRecordStatus(status))
            } else if item.isDashboardPastScheduleItem {
                let completed = item.dashboardMarkedPastScheduleRecord()
                upsert(completed, into: &nextCompletedAssignments, indexes: &completedIndexes)
                appendRecord(completed)
            } else {
                upsert(item, into: &nextHelpDeskItems, indexes: &helpDeskIndexes)
            }
        }

        for record in assignmentRecords {
            let status = overrides.assignmentStatus(for: record)
            if status == "completed" {
                appendRecord(record.dashboardMarkedCompleted())
            } else if status.isDashboardIgnoredAssignmentStatus {
                appendRecord(record.dashboardMarkedRecordStatus(status))
            } else if record.isDashboardManualCompletedRecord {
                let restored = record.dashboardRestoredActive()
                upsert(restored, into: &nextAssignments, indexes: &assignmentIndexes)
                appendRecord(restored)
            } else {
                appendRecord(record)
            }
        }

        for item in completedAssignments {
            let status = overrides.assignmentStatus(for: item)
            if status == "completed" {
                let completed = item.dashboardMarkedCompleted()
                upsert(completed, into: &nextCompletedAssignments, indexes: &completedIndexes)
                appendRecord(completed)
            } else if status.isDashboardIgnoredAssignmentStatus {
                appendRecord(item.dashboardMarkedRecordStatus(status))
            } else if item.isDashboardManualCompletedRecord {
                let restored = item.dashboardRestoredActive()
                upsert(restored, into: &nextAssignments, indexes: &assignmentIndexes)
                appendRecord(restored)
            } else {
                upsert(item, into: &nextCompletedAssignments, indexes: &completedIndexes)
                appendRecord(item)
            }
        }

        for item in assignments {
            processActive(item, asCandidate: false)
        }
        for item in assignmentCandidates {
            processActive(item, asCandidate: true)
        }

        updated.assignments = nextAssignments.sorted(by: StateItem.dashboardAssignmentSort)
        updated.assignmentCandidates = nextAssignmentCandidates.sorted(by: StateItem.dashboardAssignmentSort)
        updated.completedAssignments = nextCompletedAssignments.sorted(by: StateItem.dashboardAssignmentSort)
        updated.assignmentRecords = nextAssignmentRecords.sorted(by: StateItem.dashboardAssignmentSort)

        for item in examRecords {
            appendExamRecord(item)
        }
        for item in pastExams {
            let past = item.dashboardMarkedPastExamRecord()
            upsertExam(past, into: &nextPastExams, indexes: &pastExamIndexes)
            appendExamRecord(past)
        }
        for item in examItems {
            processExam(item, asCandidate: false)
        }
        for item in examCandidates {
            processExam(item, asCandidate: true)
        }
        updated.examItems = nextExamItems.sorted(by: StateItem.dashboardScheduleSort)
        updated.examCandidates = nextExamCandidates.sorted(by: StateItem.dashboardScheduleSort)
        updated.pastExams = nextPastExams.sorted(by: StateItem.dashboardScheduleSort)
        updated.examRecords = nextExamRecords.sorted(by: StateItem.dashboardScheduleSort)

        for item in helpDeskItems {
            processHelpDesk(item)
        }
        updated.completedAssignments = nextCompletedAssignments.sorted(by: StateItem.dashboardAssignmentSort)
        updated.assignmentRecords = nextAssignmentRecords.sorted(by: StateItem.dashboardAssignmentSort)
        updated.helpDeskItems = nextHelpDeskItems.sorted(by: StateItem.dashboardScheduleSort)
        return updated
    }
}

public extension StateItem {
    static func dashboardAssignmentSort(_ lhs: StateItem, _ rhs: StateItem) -> Bool {
        dashboardCompare(lhs, rhs, preferStartDate: false)
    }

    static func dashboardScheduleSort(_ lhs: StateItem, _ rhs: StateItem) -> Bool {
        dashboardCompare(lhs, rhs, preferStartDate: true)
    }

    private static func dashboardCompare(_ lhs: StateItem, _ rhs: StateItem, preferStartDate: Bool) -> Bool {
        let leftDate = dashboardSortDate(for: lhs, preferStartDate: preferStartDate)
        let rightDate = dashboardSortDate(for: rhs, preferStartDate: preferStartDate)
        switch (leftDate, rightDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            break
        }

        let left = dashboardSortFallbackComponents(lhs, preferStartDate: preferStartDate)
        let right = dashboardSortFallbackComponents(rhs, preferStartDate: preferStartDate)
        for index in left.indices {
            let comparison = left[index].localizedStandardCompare(right[index])
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
        }
        return false
    }

    private static func dashboardSortDate(for item: StateItem, preferStartDate: Bool) -> Date? {
        let dateCandidates = preferStartDate
            ? [item.syncStart, item.syncDue, item.due]
            : [item.syncDue, item.due, item.syncStart]
        for candidate in dateCandidates {
            if let date = dashboardParseDate(candidate) {
                return date
            }
        }
        return nil
    }

    private static func dashboardParseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let date = try? Date(trimmed, strategy: .iso8601) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    private static func dashboardSortFallbackComponents(_ item: StateItem, preferStartDate: Bool) -> [String] {
        [
            preferStartDate ? item.syncStart : item.syncDue,
            preferStartDate ? item.syncDue : item.due,
            item.course,
            item.title,
            item.url,
        ].map {
            $0
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .lowercased()
        }
    }
}

private extension String {
    var isDashboardIgnoredAssignmentStatus: Bool {
        ["ignored", "hidden", "skip"].contains(trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    var isDashboardIgnoredExamStatus: Bool {
        ["ignored", "hidden", "skip", "completed"].contains(trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

private extension StateItem {
    var dashboardIdentityKey: String {
        if let logicalKey = dashboardAssignmentLogicalIdentityKey {
            return logicalKey
        }
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty {
            return url
        }
        return [course, title, syncDue.isEmpty ? due : syncDue, category]
            .map {
                $0
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .joined(separator: "::")
    }

    var dashboardAssignmentLogicalIdentityKey: String? {
        let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedCategory == "assignment" || normalizedCategory == "assignment_candidate" else {
            return nil
        }
        let course = StateItem.dashboardIdentityComponent(course)
        let title = StateItem.dashboardIdentityComponent(title)
        let due = StateItem.dashboardIdentityComponent(syncDue.isEmpty ? due : syncDue)
        guard !course.isEmpty, !title.isEmpty, !due.isEmpty else {
            return nil
        }
        return ["assignment", course, title, due].joined(separator: "::")
    }

    var dashboardExamIdentityKey: String {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? url : "\(url)::\(title)"
        }
        return [course, title, syncDue.isEmpty ? due : syncDue]
            .map {
                $0
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .joined(separator: "::")
    }

    var isDashboardPastExam: Bool {
        let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedCategory == "exam" || normalizedCategory == "exam_candidate" else {
            return false
        }
        return isDashboardPastScheduleItem
    }

    var isDashboardPastScheduleItem: Bool {
        let rawDue = syncDue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawDue.isEmpty, let due = ISO8601DateFormatter().date(from: rawDue) else {
            return false
        }
        return due < Date()
    }

    func dashboardApplyingExamOverride(_ override: ExamOverride) -> StateItem {
        var item = self
        let due = override.due.trimmingCharacters(in: .whitespacesAndNewlines)
        if !due.isEmpty {
            item.due = due
        }
        let syncStart = override.syncStart.trimmingCharacters(in: .whitespacesAndNewlines)
        if !syncStart.isEmpty {
            item.syncStart = syncStart
        }
        let syncDue = override.syncDue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !syncDue.isEmpty {
            item.syncDue = syncDue
        }
        let location = override.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if !location.isEmpty {
            item.location = location
        }
        let coverageSummary = override.coverageSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let coverage = override.coverage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !coverageSummary.isEmpty {
            item.coverageSummary = coverageSummary
        } else if !coverage.isEmpty {
            item.coverageSummary = coverage
        }
        return item
    }

    var isDashboardManualCompletedRecord: Bool {
        recordStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "completed"
            && completionReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "manual_completed"
    }

    func dashboardMarkedCompleted() -> StateItem {
        var item = self
        item.recordStatus = "completed"
        item.completionReason = "manual_completed"
        item.autoCompleted = false
        return item
    }

    func dashboardMarkedRecordStatus(_ status: String) -> StateItem {
        var item = self
        item.recordStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        item.completionReason = ""
        item.autoCompleted = false
        return item
    }

    func dashboardMarkedExamRecordStatus(_ status: String) -> StateItem {
        var item = self
        item.recordStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        item.completionReason = ""
        item.autoCompleted = false
        return item
    }

    func dashboardMarkedPastExamRecord() -> StateItem {
        var item = self
        item.type = "exam"
        item.category = "exam"
        item.recordStatus = "completed"
        item.completionReason = item.completionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "past_due"
            : item.completionReason
        item.autoCompleted = false
        return item
    }

    func dashboardMarkedPastScheduleRecord() -> StateItem {
        var item = self
        item.recordStatus = "completed"
        item.completionReason = item.completionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "past_due"
            : item.completionReason
        item.autoCompleted = true
        return item
    }

    func dashboardMarkedActiveIfNeeded() -> StateItem {
        guard recordStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return self
        }
        return dashboardRestoredActive()
    }

    func dashboardRestoredActive() -> StateItem {
        var item = self
        item.recordStatus = "active"
        item.completionReason = ""
        item.autoCompleted = false
        return item
    }

    static func dashboardIdentityComponent(_ value: String) -> String {
        value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
