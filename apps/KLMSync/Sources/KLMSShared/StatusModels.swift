import Foundation

public struct SyncReport: Decodable, Sendable, Equatable {
    public var status: String
    public var runs: [String: RunSummary]
    public var state: StateCounts
    public var notices: NoticeCounts
    public var files: FileCounts
    public var calendar: CalendarCounts
    public var slowest: [SlowStage]

    public init(
        status: String = "missing",
        runs: [String: RunSummary] = [:],
        state: StateCounts = StateCounts(),
        notices: NoticeCounts = NoticeCounts(),
        files: FileCounts = FileCounts(),
        calendar: CalendarCounts = CalendarCounts(),
        slowest: [SlowStage] = []
    ) {
        self.status = status
        self.runs = runs
        self.state = state
        self.notices = notices
        self.files = files
        self.calendar = calendar
        self.slowest = slowest
    }

    public var needsAttention: Bool {
        files.quarantine > 0 || status != "ok"
    }

    public struct RunSummary: Decodable, Sendable, Equatable {
        public var scope: String
        public var status: String
        public var completedAt: String
        public var elapsedMS: Int
        public var slowestStages: [SlowStage]

        enum CodingKeys: String, CodingKey {
            case scope
            case status
            case completedAt = "completed_at"
            case elapsedMS = "elapsed_ms"
            case slowestStages = "slowest_stages"
        }

        public init(
            scope: String = "",
            status: String = "missing",
            completedAt: String = "",
            elapsedMS: Int = 0,
            slowestStages: [SlowStage] = []
        ) {
            self.scope = scope
            self.status = status
            self.completedAt = completedAt
            self.elapsedMS = elapsedMS
            self.slowestStages = slowestStages
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scope = container.decodeIfPresentDefault(String.self, forKey: .scope, default: "")
            status = container.decodeIfPresentDefault(String.self, forKey: .status, default: "missing")
            completedAt = container.decodeIfPresentDefault(String.self, forKey: .completedAt, default: "")
            elapsedMS = container.decodeIfPresentDefault(Int.self, forKey: .elapsedMS, default: 0)
            slowestStages = container.decodeIfPresentDefault([SlowStage].self, forKey: .slowestStages, default: [])
        }

        public var elapsedSecondsText: String {
            TimeDisplay.secondsText(milliseconds: elapsedMS)
        }
    }

    public struct StateCounts: Decodable, Sendable, Equatable {
        public var assignments: Int
        public var exams: Int
        public var helpdesk: Int

        public init(assignments: Int = 0, exams: Int = 0, helpdesk: Int = 0) {
            self.assignments = assignments
            self.exams = exams
            self.helpdesk = helpdesk
        }
    }

    public struct NoticeCounts: Decodable, Sendable, Equatable {
        public var total: Int
        public var new: Int
        public var updated: Int
        public var ignored: Int

        public init(total: Int = 0, new: Int = 0, updated: Int = 0, ignored: Int = 0) {
            self.total = total
            self.new = new
            self.updated = updated
            self.ignored = ignored
        }
    }

    public struct FileCounts: Decodable, Sendable, Equatable {
        public var total: Int
        public var newFiles: Int
        public var quarantine: Int
        public var pruned: Int
        public var archivePruned: Int

        enum CodingKeys: String, CodingKey {
            case total
            case newFiles = "new_files"
            case quarantine
            case pruned
            case archivePruned = "archive_pruned"
        }

        public init(total: Int = 0, newFiles: Int = 0, quarantine: Int = 0, pruned: Int = 0, archivePruned: Int = 0) {
            self.total = total
            self.newFiles = newFiles
            self.quarantine = quarantine
            self.pruned = pruned
            self.archivePruned = archivePruned
        }
    }

    public struct CalendarCounts: Decodable, Sendable, Equatable {
        public var created: Int
        public var updated: Int
        public var deleted: Int

        public init(created: Int = 0, updated: Int = 0, deleted: Int = 0) {
            self.created = created
            self.updated = updated
            self.deleted = deleted
        }
    }
}

public struct CalendarSyncResult: Decodable, Sendable, Equatable {
    public var backend: String
    public var generatedAt: String
    public var summaries: [CalendarSyncSummary]
    public var changes: [CalendarChange]

    enum CodingKeys: String, CodingKey {
        case backend
        case generatedAt = "generated_at"
        case summaries
        case changes
    }

    public init(
        backend: String = "",
        generatedAt: String = "",
        summaries: [CalendarSyncSummary] = [],
        changes: [CalendarChange] = []
    ) {
        self.backend = backend
        self.generatedAt = generatedAt
        self.summaries = summaries
        self.changes = changes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backend = container.decodeIfPresentDefault(String.self, forKey: .backend, default: "")
        generatedAt = container.decodeIfPresentDefault(String.self, forKey: .generatedAt, default: "")
        summaries = container.decodeIfPresentDefault([CalendarSyncSummary].self, forKey: .summaries, default: [])
        changes = container.decodeIfPresentDefault([CalendarChange].self, forKey: .changes, default: [])
    }
}

public struct CalendarSyncSummary: Decodable, Sendable, Equatable, Identifiable {
    public var raw: String
    public var calendar: String
    public var bucket: String
    public var created: Int
    public var updated: Int
    public var deleted: Int
    public var total: Int

    public var id: String {
        "\(calendar)-\(bucket)-\(created)-\(updated)-\(deleted)-\(total)-\(raw)"
    }

    enum CodingKeys: String, CodingKey {
        case raw
        case calendar
        case bucket
        case created
        case updated
        case deleted
        case total
    }

    public init(
        raw: String = "",
        calendar: String = "",
        bucket: String = "",
        created: Int = 0,
        updated: Int = 0,
        deleted: Int = 0,
        total: Int = 0
    ) {
        self.raw = raw
        self.calendar = calendar
        self.bucket = bucket
        self.created = created
        self.updated = updated
        self.deleted = deleted
        self.total = total
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        raw = container.decodeIfPresentDefault(String.self, forKey: .raw, default: "")
        calendar = container.decodeIfPresentDefault(String.self, forKey: .calendar, default: "")
        bucket = container.decodeIfPresentDefault(String.self, forKey: .bucket, default: "")
        created = container.decodeIfPresentDefault(Int.self, forKey: .created, default: 0)
        updated = container.decodeIfPresentDefault(Int.self, forKey: .updated, default: 0)
        deleted = container.decodeIfPresentDefault(Int.self, forKey: .deleted, default: 0)
        total = container.decodeIfPresentDefault(Int.self, forKey: .total, default: 0)
    }
}

public struct CalendarChange: Decodable, Sendable, Equatable, Identifiable {
    public var action: String
    public var calendar: String
    public var bucket: String
    public var identifier: String
    public var title: String
    public var course: String
    public var url: String
    public var startAt: String
    public var dueAt: String
    public var location: String
    public var changes: [String]
    public var raw: String
    public var parseError: String

    public var id: String {
        [
            action,
            calendar,
            bucket,
            identifier,
            title,
            startAt,
            dueAt,
            raw,
        ].joined(separator: "|")
    }

    public var actionDisplayName: String {
        switch action {
        case "created":
            "생성"
        case "updated":
            "수정"
        case "deleted":
            "삭제"
        default:
            action.isEmpty ? "변경" : action
        }
    }

    enum CodingKeys: String, CodingKey {
        case action
        case calendar
        case bucket
        case identifier
        case title
        case course
        case url
        case startAt = "start_at"
        case dueAt = "due_at"
        case location
        case changes
        case raw
        case parseError = "parse_error"
    }

    public init(
        action: String = "",
        calendar: String = "",
        bucket: String = "",
        identifier: String = "",
        title: String = "",
        course: String = "",
        url: String = "",
        startAt: String = "",
        dueAt: String = "",
        location: String = "",
        changes: [String] = [],
        raw: String = "",
        parseError: String = ""
    ) {
        self.action = action
        self.calendar = calendar
        self.bucket = bucket
        self.identifier = identifier
        self.title = title
        self.course = course
        self.url = url
        self.startAt = startAt
        self.dueAt = dueAt
        self.location = location
        self.changes = changes
        self.raw = raw
        self.parseError = parseError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = container.decodeIfPresentDefault(String.self, forKey: .action, default: "")
        calendar = container.decodeIfPresentDefault(String.self, forKey: .calendar, default: "")
        bucket = container.decodeIfPresentDefault(String.self, forKey: .bucket, default: "")
        identifier = container.decodeIfPresentDefault(String.self, forKey: .identifier, default: "")
        title = container.decodeIfPresentDefault(String.self, forKey: .title, default: "")
        course = container.decodeIfPresentDefault(String.self, forKey: .course, default: "")
        url = container.decodeIfPresentDefault(String.self, forKey: .url, default: "")
        startAt = container.decodeIfPresentDefault(String.self, forKey: .startAt, default: "")
        dueAt = container.decodeIfPresentDefault(String.self, forKey: .dueAt, default: "")
        location = container.decodeIfPresentDefault(String.self, forKey: .location, default: "")
        changes = container.decodeIfPresentDefault([String].self, forKey: .changes, default: [])
        raw = container.decodeIfPresentDefault(String.self, forKey: .raw, default: "")
        parseError = container.decodeIfPresentDefault(String.self, forKey: .parseError, default: "")
    }
}

public struct SlowStage: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var durationMS: Int
    public var status: String

    public var id: String { "\(name)-\(durationMS)-\(status)" }

    enum CodingKeys: String, CodingKey {
        case name
        case durationMS = "duration_ms"
        case status
    }

    public init(name: String = "", durationMS: Int = 0, status: String = "") {
        self.name = name
        self.durationMS = durationMS
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.decodeIfPresentDefault(String.self, forKey: .name, default: "")
        durationMS = container.decodeIfPresentDefault(Int.self, forKey: .durationMS, default: 0)
        status = container.decodeIfPresentDefault(String.self, forKey: .status, default: "")
    }

    public var durationSecondsText: String {
        TimeDisplay.secondsText(milliseconds: durationMS)
    }
}

public struct StageTimingReport: Decodable, Sendable, Equatable {
    public var status: String
    public var runStartedAt: String
    public var completedAt: String
    public var elapsedMS: Int
    public var noticeRenderResults: [NoticeRenderResult]
    public var slowestEvents: [SlowEvent]

    enum CodingKeys: String, CodingKey {
        case status
        case runStartedAt = "run_started_at"
        case completedAt = "completed_at"
        case elapsedMS = "elapsed_ms"
        case noticeRenderResults = "notice_render_results"
        case slowestEvents = "slowest_events"
    }

    public init(
        status: String = "missing",
        runStartedAt: String = "",
        completedAt: String = "",
        elapsedMS: Int = 0,
        noticeRenderResults: [NoticeRenderResult] = [],
        slowestEvents: [SlowEvent] = []
    ) {
        self.status = status
        self.runStartedAt = runStartedAt
        self.completedAt = completedAt
        self.elapsedMS = elapsedMS
        self.noticeRenderResults = noticeRenderResults
        self.slowestEvents = slowestEvents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.decodeIfPresentDefault(String.self, forKey: .status, default: "missing")
        runStartedAt = container.decodeIfPresentDefault(String.self, forKey: .runStartedAt, default: "")
        completedAt = container.decodeIfPresentDefault(String.self, forKey: .completedAt, default: "")
        elapsedMS = container.decodeIfPresentDefault(Int.self, forKey: .elapsedMS, default: 0)
        noticeRenderResults = container.decodeIfPresentDefault([NoticeRenderResult].self, forKey: .noticeRenderResults, default: [])
        slowestEvents = container.decodeIfPresentDefault([SlowEvent].self, forKey: .slowestEvents, default: [])
    }

    public var elapsedSecondsText: String {
        TimeDisplay.secondsText(milliseconds: elapsedMS)
    }

    public func markingStaleRunningIfNeeded(
        now: Date = Date(),
        maxRunningAge: TimeInterval = 30 * 60
    ) -> StageTimingReport {
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "running",
              completedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let startedAt = Self.parseDate(runStartedAt),
              now.timeIntervalSince(startedAt) > maxRunningAge else {
            return self
        }

        var copy = self
        copy.status = "interrupted"
        return copy
    }

    private static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }
}

public struct NoticeRenderResult: Decodable, Sendable, Equatable, Identifiable {
    public var target: String
    public var status: String
    public var output: String

    public var id: String { "\(target)-\(status)-\(output)" }

    enum CodingKeys: String, CodingKey {
        case target
        case status
        case output
    }

    public init(target: String = "", status: String = "", output: String = "") {
        self.target = target
        self.status = status
        self.output = output
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = container.decodeIfPresentDefault(String.self, forKey: .target, default: "")
        status = container.decodeIfPresentDefault(String.self, forKey: .status, default: "")
        output = container.decodeIfPresentDefault(String.self, forKey: .output, default: "")
    }
}

public struct SlowEvent: Decodable, Sendable, Equatable, Identifiable {
    public var group: String
    public var name: String
    public var stage: String
    public var durationMS: Int
    public var status: String
    public var command: [String]

    public var id: String { "\(group)-\(name)-\(stage)-\(durationMS)-\(status)" }

    enum CodingKeys: String, CodingKey {
        case group
        case name
        case stage
        case durationMS = "duration_ms"
        case status
        case command
    }

    public init(
        group: String = "",
        name: String = "",
        stage: String = "",
        durationMS: Int = 0,
        status: String = "",
        command: [String] = []
    ) {
        self.group = group
        self.name = name
        self.stage = stage
        self.durationMS = durationMS
        self.status = status
        self.command = command
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        group = container.decodeIfPresentDefault(String.self, forKey: .group, default: "")
        name = container.decodeIfPresentDefault(String.self, forKey: .name, default: "")
        stage = container.decodeIfPresentDefault(String.self, forKey: .stage, default: "")
        durationMS = container.decodeIfPresentDefault(Int.self, forKey: .durationMS, default: 0)
        status = container.decodeIfPresentDefault(String.self, forKey: .status, default: "")
        command = container.decodeIfPresentDefault([String].self, forKey: .command, default: [])
    }

    public var durationSecondsText: String {
        TimeDisplay.secondsText(milliseconds: durationMS)
    }

    public var rawCommandText: String {
        command.joined(separator: " ")
    }
}

enum TimeDisplay {
    static func secondsText(milliseconds: Int) -> String {
        let seconds = Double(milliseconds) / 1000
        if milliseconds % 1000 == 0 {
            return "\(milliseconds / 1000)s"
        }
        if seconds >= 100 {
            return String(format: "%.0fs", seconds)
        }
        if seconds >= 10 {
            return String(format: "%.1fs", seconds)
        }
        return String(format: "%.2fs", seconds)
    }
}

public struct DoctorResult: Decodable, Sendable, Equatable {
    public var status: String
    public var checks: [DoctorCheck]

    enum CodingKeys: String, CodingKey {
        case status
        case checks
    }

    public init(status: String = "missing", checks: [DoctorCheck] = []) {
        self.status = status
        self.checks = checks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.decodeIfPresentDefault(String.self, forKey: .status, default: "missing")
        checks = container.decodeIfPresentDefault([DoctorCheck].self, forKey: .checks, default: [])
    }
}

public struct DoctorCheck: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var status: String
    public var detail: String

    public var message: String { detail }

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case status
        case detail
        case message
    }

    public init(name: String = "", status: String = "", detail: String = "", message: String? = nil) {
        self.name = name
        self.status = status
        self.detail = detail.isEmpty ? (message ?? "") : detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.decodeIfPresentDefault(String.self, forKey: .name, default: "")
        status = container.decodeIfPresentDefault(String.self, forKey: .status, default: "")
        detail = container.decodeIfPresentDefault(String.self, forKey: .detail, default: "")
        if detail.isEmpty {
            detail = container.decodeIfPresentDefault(String.self, forKey: .message, default: "")
        }
    }
}

public struct LoginStatus: Decodable, Sendable, Equatable {
    public var checkedAtEpoch: Int
    public var loggedIn: Bool

    enum CodingKeys: String, CodingKey {
        case checkedAtEpoch = "checked_at_epoch"
        case loggedIn = "logged_in"
    }

    public init(checkedAtEpoch: Int = 0, loggedIn: Bool = false) {
        self.checkedAtEpoch = checkedAtEpoch
        self.loggedIn = loggedIn
    }

    public var checkedAt: Date? {
        checkedAtEpoch > 0 ? Date(timeIntervalSince1970: TimeInterval(checkedAtEpoch)) : nil
    }
}

public struct NoticeRenderStatus: Decodable, Sendable, Equatable {
    public var status: String
    public var code: String
    public var userMessage: String
    public var rawFirstLine: String
    public var nonfatal: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case code
        case userMessage = "user_message"
        case rawFirstLine = "raw_first_line"
        case nonfatal
    }

    public init(
        status: String = "missing",
        code: String = "",
        userMessage: String = "",
        rawFirstLine: String = "",
        nonfatal: Bool = false
    ) {
        self.status = status
        self.code = code
        self.userMessage = userMessage
        self.rawFirstLine = rawFirstLine
        self.nonfatal = nonfatal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.decodeIfPresentDefault(String.self, forKey: .status, default: "missing")
        code = container.decodeIfPresentDefault(String.self, forKey: .code, default: "")
        userMessage = container.decodeIfPresentDefault(String.self, forKey: .userMessage, default: "")
        rawFirstLine = container.decodeIfPresentDefault(String.self, forKey: .rawFirstLine, default: "")
        nonfatal = container.decodeIfPresentDefault(Bool.self, forKey: .nonfatal, default: false)
    }
}

public struct NoticeNoteRenderState: Decodable, Sendable, Equatable {
    public var noteID: String
    public var noteTitle: String
    public var updatedAt: String
    public var styleVersion: String
    public var renderedNoticeCount: Int

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case noteTitle = "note_title"
        case updatedAt = "updated_at"
        case styleVersion = "style_version"
        case renderedNotices = "rendered_notices"
    }

    public init(
        noteID: String = "",
        noteTitle: String = "",
        updatedAt: String = "",
        styleVersion: String = "",
        renderedNoticeCount: Int = 0
    ) {
        self.noteID = noteID
        self.noteTitle = noteTitle
        self.updatedAt = updatedAt
        self.styleVersion = styleVersion
        self.renderedNoticeCount = renderedNoticeCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        noteID = container.decodeIfPresentDefault(String.self, forKey: .noteID, default: "")
        noteTitle = container.decodeIfPresentDefault(String.self, forKey: .noteTitle, default: "")
        updatedAt = container.decodeIfPresentDefault(String.self, forKey: .updatedAt, default: "")
        styleVersion = container.decodeIfPresentDefault(String.self, forKey: .styleVersion, default: "")
        renderedNoticeCount = container.decodeIfPresentDefault([NoticeRenderedStateItem].self, forKey: .renderedNotices, default: []).count
    }
}

private struct NoticeRenderedStateItem: Decodable, Equatable {
    init(from decoder: Decoder) throws {}
}

public struct DryRunReport: Decodable, Sendable, Equatable {
    public var scope: String
    public var status: String
    public var wouldCreate: Int
    public var wouldUpdate: Int
    public var wouldDelete: Int
    public var wouldDownload: Int
    public var wouldPrune: Int
    public var wouldPruneCourseFiles: Int
    public var wouldPruneArchive: Int
    public var skippedSideEffects: [String]
    public var pruneBackupManifest: String
    public var archivePruneBackupManifest: String

    enum CodingKeys: String, CodingKey {
        case scope
        case status
        case wouldCreate = "would_create"
        case wouldUpdate = "would_update"
        case wouldDelete = "would_delete"
        case wouldDownload = "would_download"
        case wouldPrune = "would_prune"
        case wouldPruneCourseFiles = "would_prune_course_files"
        case wouldPruneArchive = "would_prune_archive"
        case skippedSideEffects = "skipped_side_effects"
        case pruneBackupManifest = "prune_backup_manifest"
        case archivePruneBackupManifest = "archive_prune_backup_manifest"
    }

    public init(
        scope: String = "",
        status: String = "missing",
        wouldCreate: Int = 0,
        wouldUpdate: Int = 0,
        wouldDelete: Int = 0,
        wouldDownload: Int = 0,
        wouldPrune: Int = 0,
        wouldPruneCourseFiles: Int = 0,
        wouldPruneArchive: Int = 0,
        skippedSideEffects: [String] = [],
        pruneBackupManifest: String = "",
        archivePruneBackupManifest: String = ""
    ) {
        self.scope = scope
        self.status = status
        self.wouldCreate = wouldCreate
        self.wouldUpdate = wouldUpdate
        self.wouldDelete = wouldDelete
        self.wouldDownload = wouldDownload
        self.wouldPrune = wouldPrune
        self.wouldPruneCourseFiles = wouldPruneCourseFiles
        self.wouldPruneArchive = wouldPruneArchive
        self.skippedSideEffects = skippedSideEffects
        self.pruneBackupManifest = pruneBackupManifest
        self.archivePruneBackupManifest = archivePruneBackupManifest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = container.decodeIfPresentDefault(String.self, forKey: .scope, default: "")
        status = container.decodeIfPresentDefault(String.self, forKey: .status, default: "missing")
        wouldCreate = container.decodeIfPresentDefault(Int.self, forKey: .wouldCreate, default: 0)
        wouldUpdate = container.decodeIfPresentDefault(Int.self, forKey: .wouldUpdate, default: 0)
        wouldDelete = container.decodeIfPresentDefault(Int.self, forKey: .wouldDelete, default: 0)
        wouldDownload = container.decodeIfPresentDefault(Int.self, forKey: .wouldDownload, default: 0)
        wouldPrune = container.decodeIfPresentDefault(Int.self, forKey: .wouldPrune, default: 0)
        wouldPruneCourseFiles = container.decodeIfPresentDefault(Int.self, forKey: .wouldPruneCourseFiles, default: 0)
        wouldPruneArchive = container.decodeIfPresentDefault(Int.self, forKey: .wouldPruneArchive, default: 0)
        skippedSideEffects = container.decodeIfPresentDefault([String].self, forKey: .skippedSideEffects, default: [])
        pruneBackupManifest = container.decodeIfPresentDefault(String.self, forKey: .pruneBackupManifest, default: "")
        archivePruneBackupManifest = container.decodeIfPresentDefault(String.self, forKey: .archivePruneBackupManifest, default: "")
    }
}
