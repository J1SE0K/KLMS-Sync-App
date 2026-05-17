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
    public var message: String

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case status
        case message
    }

    public init(name: String = "", status: String = "", message: String = "") {
        self.name = name
        self.status = status
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.decodeIfPresentDefault(String.self, forKey: .name, default: "")
        status = container.decodeIfPresentDefault(String.self, forKey: .status, default: "")
        message = container.decodeIfPresentDefault(String.self, forKey: .message, default: "")
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
