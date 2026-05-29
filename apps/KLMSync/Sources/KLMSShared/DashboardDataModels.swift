import Foundation

public struct ManualOverridesSnapshot: Sendable, Equatable {
    public var assignments: [String: String]
    public var exams: [String: ExamOverride]

    public init(assignments: [String: String] = [:], exams: [String: ExamOverride] = [:]) {
        self.assignments = assignments
        self.exams = exams
    }

    public func assignmentStatus(for item: StateItem) -> String {
        guard let key = assignmentOverrideKey(for: item) else {
            return ""
        }
        return assignments[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    public func isAssignmentHidden(_ item: StateItem) -> Bool {
        ["ignored", "hidden", "skip"].contains(assignmentStatus(for: item))
    }

    public func assignmentOverrideKey(for item: StateItem) -> String? {
        Self.assignmentOverrideCandidateKeys(for: item).first { assignments[$0] != nil }
    }

    public static func preferredAssignmentOverrideKey(for item: StateItem) -> String {
        assignmentOverrideCandidateKeys(for: item).first ?? item.id
    }

    public static func assignmentOverrideCandidateKeys(for item: StateItem) -> [String] {
        let url = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = oneLine(item.title)
        let course = oneLine(item.course)
        let due = oneLine(item.syncDue.isEmpty ? item.due : item.syncDue)
        return [
            url,
            !url.isEmpty && !title.isEmpty ? "\(url)::\(title)" : "",
            !course.isEmpty && !title.isEmpty && !due.isEmpty ? "\(course)::\(title)::\(due)" : "",
            !course.isEmpty && !title.isEmpty ? "\(course)::\(title)" : "",
        ].filter { !$0.isEmpty }
    }

    public func examOverride(for item: StateItem) -> ExamOverride {
        guard let key = examOverrideKey(for: item) else {
            return ExamOverride()
        }
        return exams[key] ?? ExamOverride()
    }

    public func isExamHidden(_ item: StateItem) -> Bool {
        examOverride(for: item).status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ignored"
    }

    public func examOverrideKey(for item: StateItem) -> String? {
        Self.examOverrideCandidateKeys(for: item).first { exams[$0] != nil }
    }

    public static func preferredExamOverrideKey(for item: StateItem) -> String {
        examOverrideCandidateKeys(for: item).first ?? item.id
    }

    public static func examOverrideCandidateKeys(for item: StateItem) -> [String] {
        let url = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = oneLine(item.title)
        let course = oneLine(item.course)
        let due = oneLine(item.due)
        return [
            !url.isEmpty && !title.isEmpty ? "\(url)::\(title)" : "",
            url,
            !course.isEmpty && !title.isEmpty && !due.isEmpty ? "\(course)::\(title)::\(due)" : "",
            !course.isEmpty && !title.isEmpty ? "\(course)::\(title)" : "",
        ].filter { !$0.isEmpty }
    }

    private static func oneLine(_ value: String) -> String {
        value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public struct ExamOverride: Codable, Sendable, Equatable {
    public var status: String
    public var due: String
    public var timingPrecision: String
    public var syncStart: String
    public var syncDue: String
    public var location: String
    public var coverage: String
    public var coverageSummary: String
    public var instructionsAppend: String

    enum CodingKeys: String, CodingKey {
        case status
        case due
        case timingPrecision = "timing_precision"
        case syncStart = "sync_start"
        case syncDue = "sync_due"
        case location
        case coverage
        case coverageSummary = "coverage_summary"
        case instructionsAppend = "instructions_append"
    }

    public init(
        status: String = "",
        due: String = "",
        timingPrecision: String = "",
        syncStart: String = "",
        syncDue: String = "",
        location: String = "",
        coverage: String = "",
        coverageSummary: String = "",
        instructionsAppend: String = ""
    ) {
        self.status = status
        self.due = due
        self.timingPrecision = timingPrecision
        self.syncStart = syncStart
        self.syncDue = syncDue
        self.location = location
        self.coverage = coverage
        self.coverageSummary = coverageSummary
        self.instructionsAppend = instructionsAppend
    }

    public var isEmpty: Bool {
        [
            status,
            due,
            timingPrecision,
            syncStart,
            syncDue,
            location,
            coverage,
            coverageSummary,
            instructionsAppend,
        ].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var jsonObject: [String: String] {
        var object: [String: String] = [:]
        func add(_ key: String, _ value: String) {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                object[key] = text
            }
        }
        add("status", status)
        add("due", due)
        add("timing_precision", timingPrecision)
        add("sync_start", syncStart)
        add("sync_due", syncDue)
        add("location", location)
        add("coverage", coverage)
        add("coverage_summary", coverageSummary)
        add("instructions_append", instructionsAppend)
        return object
    }
}

public struct ManualOverrideStore: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    @discardableResult
    public func mergeMissingOverrides(from sourceURL: URL) throws -> Bool {
        guard sourceURL.standardizedFileURL.path != url.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            return false
        }
        var sourceObject = try ManualOverrideStore(url: sourceURL).loadJSONObject()
        let legacyAssignments = legacyAssignmentObject(from: sourceObject)
        if sourceObject["assignments"] == nil, !legacyAssignments.isEmpty {
            sourceObject = ["assignments": legacyAssignments]
        }
        guard !sourceObject.isEmpty else {
            return false
        }

        var targetObject = try loadJSONObject()
        var changed = false
        for (key, sourceValue) in sourceObject {
            if let sourceDictionary = sourceValue as? [String: Any] {
                var targetDictionary = targetObject[key] as? [String: Any] ?? [:]
                var dictionaryChanged = false
                for (entryKey, entryValue) in sourceDictionary where targetDictionary[entryKey] == nil {
                    targetDictionary[entryKey] = entryValue
                    dictionaryChanged = true
                }
                if dictionaryChanged || targetObject[key] == nil {
                    targetObject[key] = targetDictionary
                    changed = true
                }
            } else if targetObject[key] == nil {
                targetObject[key] = sourceValue
                changed = true
            }
        }

        if changed {
            try saveJSONObject(targetObject)
        }
        return changed
    }

    public func load() throws -> ManualOverridesSnapshot {
        let object = try loadJSONObject()
        let assignmentsSource = object["assignments"] as? [String: Any] ?? legacyAssignmentObject(from: object)
        let assignments = assignmentsSource.compactMapValues { value -> String? in
            let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return text.isEmpty ? nil : text
        }
        let examsSource = object["exams"] as? [String: Any] ?? [:]
        let exams = examsSource.compactMapValues { value -> ExamOverride? in
            guard let item = value as? [String: Any] else {
                return nil
            }
            let override = ExamOverride(
                status: stringValue(item["status"]),
                due: stringValue(item["due"]),
                timingPrecision: stringValue(item["timing_precision"]),
                syncStart: stringValue(item["sync_start"]),
                syncDue: stringValue(item["sync_due"]),
                location: stringValue(item["location"]),
                coverage: stringValue(item["coverage"]),
                coverageSummary: stringValue(item["coverage_summary"]),
                instructionsAppend: stringValue(item["instructions_append"])
            )
            return override.isEmpty ? nil : override
        }
        return ManualOverridesSnapshot(assignments: assignments, exams: exams)
    }

    public func saveAssignmentStatus(_ status: String, for item: StateItem, currentKey: String? = nil) throws {
        let key = ManualOverridesSnapshot.preferredAssignmentOverrideKey(for: item)
        guard !key.isEmpty else {
            return
        }
        var object = try loadJSONObject()
        var assignments = object["assignments"] as? [String: Any] ?? legacyAssignmentObject(from: object)
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let removableKeys = Set(ManualOverridesSnapshot.assignmentOverrideCandidateKeys(for: item) + [currentKey ?? ""])
        if normalized.isEmpty {
            for removableKey in removableKeys where !removableKey.isEmpty {
                assignments.removeValue(forKey: removableKey)
            }
        } else {
            for removableKey in removableKeys where !removableKey.isEmpty && removableKey != key {
                assignments.removeValue(forKey: removableKey)
            }
            assignments[key] = normalized
        }
        object["assignments"] = assignments
        try saveJSONObject(object)
    }

    public func saveExamOverride(_ override: ExamOverride, for item: StateItem, currentKey: String? = nil) throws {
        let key = currentKey ?? ManualOverridesSnapshot.preferredExamOverrideKey(for: item)
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        var object = try loadJSONObject()
        var exams = object["exams"] as? [String: Any] ?? [:]
        if override.isEmpty {
            exams.removeValue(forKey: key)
        } else {
            exams[key] = override.jsonObject
        }
        object["exams"] = exams
        try saveJSONObject(object)
    }

    private func loadJSONObject() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return [:]
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func saveJSONObject(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func legacyAssignmentObject(from object: [String: Any]) -> [String: Any] {
        guard object["exams"] == nil, object["class_times"] == nil, object["notice_filters"] == nil else {
            return [:]
        }
        return object
    }
}

public struct NoticeDigest: Decodable, Sendable, Equatable {
    public var generatedAt: String
    public var noticeCount: Int
    public var newCount: Int
    public var updatedCount: Int
    public var ignoredNoticeCount: Int
    public var importantCandidateCount: Int
    public var courses: [NoticeCourseDigest]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case noticeCount = "notice_count"
        case newCount = "new_count"
        case updatedCount = "updated_count"
        case ignoredNoticeCount = "ignored_notice_count"
        case importantCandidateCount = "important_candidate_count"
        case courses
    }

    public init(
        generatedAt: String = "",
        noticeCount: Int = 0,
        newCount: Int = 0,
        updatedCount: Int = 0,
        ignoredNoticeCount: Int = 0,
        importantCandidateCount: Int = 0,
        courses: [NoticeCourseDigest] = []
    ) {
        self.generatedAt = generatedAt
        self.noticeCount = noticeCount
        self.newCount = newCount
        self.updatedCount = updatedCount
        self.ignoredNoticeCount = ignoredNoticeCount
        self.importantCandidateCount = importantCandidateCount
        self.courses = courses
    }

    public var notices: [NoticeDigestEntry] {
        courses.flatMap { course in
            course.notices.map { notice in
                var item = notice
                if item.course.isEmpty {
                    item.course = course.course
                }
                return item
            }
        }
    }
}

public struct NoticeCourseDigest: Decodable, Sendable, Equatable, Identifiable {
    public var course: String
    public var notices: [NoticeDigestEntry]

    public var id: String { course }

    public init(course: String = "", notices: [NoticeDigestEntry] = []) {
        self.course = course
        self.notices = notices
    }
}

public struct NoticeAttachmentItem: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var relativePath: String
    public var absolutePath: String

    public var id: String { absolutePath.isEmpty ? relativePath : absolutePath }

    enum CodingKeys: String, CodingKey {
        case name
        case relativePath = "relative_path"
        case absolutePath = "absolute_path"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.decodeIfPresentDefault(String.self, forKey: .name, default: "")
        relativePath = container.decodeIfPresentDefault(String.self, forKey: .relativePath, default: "")
        absolutePath = container.decodeIfPresentDefault(String.self, forKey: .absolutePath, default: "")
    }
}

public struct NoticeDigestEntry: Decodable, Sendable, Equatable, Identifiable {
    public var url: String
    public var articleID: String
    public var course: String
    public var boardTitle: String
    public var title: String
    public var postedAt: String
    public var attachments: [String]
    public var attachmentItems: [NoticeAttachmentItem]
    public var summary: String
    public var excerpt: String
    public var bodyText: String
    public var fingerprint: String
    public var changeState: String

    public var id: String {
        noticeIdentifier
    }

    public var noticeIdentifier: String {
        if !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return url
        }
        if !articleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "article:\(articleID)"
        }
        return "\(course)|\(Self.oneLine(title))|\(Self.oneLine(postedAt))"
    }

    enum CodingKeys: String, CodingKey {
        case url
        case articleID = "article_id"
        case course
        case boardTitle = "board_title"
        case title
        case postedAt = "posted_at"
        case attachments
        case attachmentItems = "attachment_items"
        case summary
        case excerpt
        case bodyText = "body_text"
        case fingerprint
        case changeState = "change_state"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = container.decodeIfPresentDefault(String.self, forKey: .url, default: "")
        articleID = container.decodeIfPresentDefault(String.self, forKey: .articleID, default: "")
        course = container.decodeIfPresentDefault(String.self, forKey: .course, default: "")
        boardTitle = container.decodeIfPresentDefault(String.self, forKey: .boardTitle, default: "")
        title = container.decodeIfPresentDefault(String.self, forKey: .title, default: "")
        postedAt = container.decodeIfPresentDefault(String.self, forKey: .postedAt, default: "")
        attachments = container.decodeIfPresentDefault([String].self, forKey: .attachments, default: [])
        attachmentItems = container.decodeIfPresentDefault([NoticeAttachmentItem].self, forKey: .attachmentItems, default: [])
        summary = container.decodeIfPresentDefault(String.self, forKey: .summary, default: "")
        excerpt = container.decodeIfPresentDefault(String.self, forKey: .excerpt, default: "")
        bodyText = container.decodeIfPresentDefault(String.self, forKey: .bodyText, default: "")
        fingerprint = container.decodeIfPresentDefault(String.self, forKey: .fingerprint, default: "")
        changeState = container.decodeIfPresentDefault(String.self, forKey: .changeState, default: "")
    }

    private static func oneLine(_ value: String) -> String {
        value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public struct NoticeUserStateFile: Codable, Sendable, Equatable {
    public var version: Int
    public var updatedAt: String
    public var notices: [String: NoticeInteractionState]

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case notices
    }

    public init(version: Int = 1, updatedAt: String = "", notices: [String: NoticeInteractionState] = [:]) {
        self.version = version
        self.updatedAt = updatedAt
        self.notices = notices
    }
}

public struct NoticeInteractionState: Codable, Sendable, Equatable {
    public var title: String
    public var course: String
    public var url: String
    public var fingerprint: String
    public var readFingerprint: String?
    public var readAt: String?
    public var important: Bool
    public var importantAt: String?
    public var hidden: Bool
    public var hiddenAt: String?
    public var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case title
        case course
        case url
        case fingerprint
        case readFingerprint = "read_fingerprint"
        case readAt = "read_at"
        case important
        case importantAt = "important_at"
        case hidden
        case hiddenAt = "hidden_at"
        case updatedAt = "updated_at"
    }

    public init(
        title: String = "",
        course: String = "",
        url: String = "",
        fingerprint: String = "",
        readFingerprint: String? = nil,
        readAt: String? = nil,
        important: Bool = false,
        importantAt: String? = nil,
        hidden: Bool = false,
        hiddenAt: String? = nil,
        updatedAt: String = ""
    ) {
        self.title = title
        self.course = course
        self.url = url
        self.fingerprint = fingerprint
        self.readFingerprint = readFingerprint
        self.readAt = readAt
        self.important = important
        self.importantAt = importantAt
        self.hidden = hidden
        self.hiddenAt = hiddenAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.decodeIfPresentDefault(String.self, forKey: .title, default: "")
        course = container.decodeIfPresentDefault(String.self, forKey: .course, default: "")
        url = container.decodeIfPresentDefault(String.self, forKey: .url, default: "")
        fingerprint = container.decodeIfPresentDefault(String.self, forKey: .fingerprint, default: "")
        readFingerprint = try? container.decodeIfPresent(String.self, forKey: .readFingerprint)
        readAt = try? container.decodeIfPresent(String.self, forKey: .readAt)
        important = container.decodeIfPresentDefault(Bool.self, forKey: .important, default: false)
        importantAt = try? container.decodeIfPresent(String.self, forKey: .importantAt)
        hidden = container.decodeIfPresentDefault(Bool.self, forKey: .hidden, default: false)
        hiddenAt = try? container.decodeIfPresent(String.self, forKey: .hiddenAt)
        updatedAt = container.decodeIfPresentDefault(String.self, forKey: .updatedAt, default: "")
    }
}

public struct NoticeUserStateStore: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> NoticeUserStateFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return NoticeUserStateFile()
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return NoticeUserStateFile()
        }
        return try JSONDecoder().decode(NoticeUserStateFile.self, from: data)
    }

    public func setRead(_ isRead: Bool, notice: NoticeDigestEntry) throws {
        var state = try load()
        let timestamp = Self.timestamp()
        let key = notice.noticeIdentifier
        var item = state.notices[key] ?? NoticeInteractionState()
        item.title = notice.title
        item.course = notice.course
        item.url = notice.url
        item.fingerprint = notice.fingerprint
        item.updatedAt = timestamp
        if isRead {
            item.readFingerprint = notice.fingerprint
            item.readAt = timestamp
        } else {
            item.readFingerprint = nil
            item.readAt = nil
        }
        state.updatedAt = timestamp
        state.notices[key] = item
        try save(state)
    }

    public func setImportant(_ isImportant: Bool, notice: NoticeDigestEntry) throws {
        var state = try load()
        let timestamp = Self.timestamp()
        let key = notice.noticeIdentifier
        var item = state.notices[key] ?? NoticeInteractionState()
        item.title = notice.title
        item.course = notice.course
        item.url = notice.url
        item.fingerprint = notice.fingerprint
        item.important = isImportant
        item.importantAt = isImportant ? timestamp : nil
        item.updatedAt = timestamp
        state.updatedAt = timestamp
        state.notices[key] = item
        try save(state)
    }

    public func setHidden(_ isHidden: Bool, notice: NoticeDigestEntry) throws {
        var state = try load()
        let timestamp = Self.timestamp()
        let key = notice.noticeIdentifier
        var item = state.notices[key] ?? NoticeInteractionState()
        item.title = notice.title
        item.course = notice.course
        item.url = notice.url
        item.fingerprint = notice.fingerprint
        item.hidden = isHidden
        item.hiddenAt = isHidden ? timestamp : nil
        item.updatedAt = timestamp
        state.updatedAt = timestamp
        state.notices[key] = item
        try save(state)
    }

    private func save(_ state: NoticeUserStateFile) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy-MM-dd HH:mm KST"
        return formatter.string(from: Date())
    }
}

public struct AppUserStateFile: Codable, Sendable, Equatable {
    public var version: Int
    public var updatedAt: String
    public var files: [String: FileInteractionState]
    public var quarantine: [String: FileInteractionState]

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case files
        case quarantine
    }

    public init(
        version: Int = 1,
        updatedAt: String = "",
        files: [String: FileInteractionState] = [:],
        quarantine: [String: FileInteractionState] = [:]
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.files = files
        self.quarantine = quarantine
    }
}

public struct FileInteractionState: Codable, Sendable, Equatable {
    public var title: String
    public var course: String
    public var path: String
    public var url: String
    public var hidden: Bool
    public var hiddenAt: String?
    public var trashedAt: String?
    public var ignored: Bool
    public var ignoredAt: String?
    public var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case title
        case course
        case path
        case url
        case hidden
        case hiddenAt = "hidden_at"
        case trashedAt = "trashed_at"
        case ignored
        case ignoredAt = "ignored_at"
        case updatedAt = "updated_at"
    }

    public init(
        title: String = "",
        course: String = "",
        path: String = "",
        url: String = "",
        hidden: Bool = false,
        hiddenAt: String? = nil,
        trashedAt: String? = nil,
        ignored: Bool = false,
        ignoredAt: String? = nil,
        updatedAt: String = ""
    ) {
        self.title = title
        self.course = course
        self.path = path
        self.url = url
        self.hidden = hidden
        self.hiddenAt = hiddenAt
        self.trashedAt = trashedAt
        self.ignored = ignored
        self.ignoredAt = ignoredAt
        self.updatedAt = updatedAt
    }

    public var isHiddenLike: Bool {
        hidden || ignored || trashedAt != nil
    }
}

public struct AppUserStateStore: Sendable {
    public enum Bucket: Sendable {
        case files
        case quarantine
    }

    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> AppUserStateFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AppUserStateFile()
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return AppUserStateFile()
        }
        return try JSONDecoder().decode(AppUserStateFile.self, from: data)
    }

    public func setHidden(
        _ hidden: Bool,
        key: String,
        title: String,
        course: String,
        path: String,
        url sourceURL: String,
        bucket: Bucket
    ) throws {
        try update(key: key, bucket: bucket, title: title, course: course, path: path, url: sourceURL) { item, timestamp in
            item.hidden = hidden
            item.hiddenAt = hidden ? timestamp : nil
            if !hidden {
                item.ignored = false
                item.ignoredAt = nil
                item.trashedAt = nil
            }
        }
    }

    public func setIgnored(
        _ ignored: Bool,
        key: String,
        title: String,
        course: String,
        path: String,
        url sourceURL: String,
        bucket: Bucket
    ) throws {
        try update(key: key, bucket: bucket, title: title, course: course, path: path, url: sourceURL) { item, timestamp in
            item.ignored = ignored
            item.ignoredAt = ignored ? timestamp : nil
            item.hidden = ignored
            item.hiddenAt = ignored ? timestamp : nil
            if !ignored {
                item.trashedAt = nil
            }
        }
    }

    public func markTrashed(
        key: String,
        title: String,
        course: String,
        path: String,
        url sourceURL: String,
        bucket: Bucket
    ) throws {
        try update(key: key, bucket: bucket, title: title, course: course, path: path, url: sourceURL) { item, timestamp in
            item.trashedAt = timestamp
            item.hidden = true
            item.hiddenAt = timestamp
        }
    }

    private func update(
        key: String,
        bucket: Bucket,
        title: String,
        course: String,
        path: String,
        url sourceURL: String,
        mutate: (inout FileInteractionState, String) -> Void
    ) throws {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            return
        }
        var state = try load()
        let timestamp = Self.timestamp()
        var item = item(in: state, bucket: bucket, key: normalizedKey)
        item.title = title
        item.course = course
        item.path = path
        item.url = sourceURL
        item.updatedAt = timestamp
        mutate(&item, timestamp)
        state.updatedAt = timestamp
        setItem(item, in: &state, bucket: bucket, key: normalizedKey)
        try save(state)
    }

    private func item(in state: AppUserStateFile, bucket: Bucket, key: String) -> FileInteractionState {
        switch bucket {
        case .files:
            return state.files[key] ?? FileInteractionState()
        case .quarantine:
            return state.quarantine[key] ?? FileInteractionState()
        }
    }

    private func setItem(_ item: FileInteractionState, in state: inout AppUserStateFile, bucket: Bucket, key: String) {
        switch bucket {
        case .files:
            state.files[key] = item
        case .quarantine:
            state.quarantine[key] = item
        }
    }

    private func save(_ state: AppUserStateFile) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy-MM-dd HH:mm KST"
        return formatter.string(from: Date())
    }
}

public struct CourseFileManifestEntry: Decodable, Sendable, Equatable, Identifiable {
    public var filename: String
    public var relativePath: String
    public var url: String
    public var sourceURL: String
    public var course: String
    public var absolutePath: String
    public var localDownloadedAt: String
    public var bucket: String

    public var id: String {
        url.isEmpty ? relativePath : url
    }

    enum CodingKeys: String, CodingKey {
        case filename
        case relativePath = "relative_path"
        case url
        case sourceURL = "source_url"
        case course
        case absolutePath = "absolute_path"
        case localDownloadedAt = "local_downloaded_at"
        case bucket
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filename = container.decodeIfPresentDefault(String.self, forKey: .filename, default: "")
        relativePath = container.decodeIfPresentDefault(String.self, forKey: .relativePath, default: "")
        url = container.decodeIfPresentDefault(String.self, forKey: .url, default: "")
        sourceURL = container.decodeIfPresentDefault(String.self, forKey: .sourceURL, default: "")
        course = container.decodeIfPresentDefault(String.self, forKey: .course, default: "")
        absolutePath = container.decodeIfPresentDefault(String.self, forKey: .absolutePath, default: "")
        localDownloadedAt = container.decodeIfPresentDefault(String.self, forKey: .localDownloadedAt, default: "")
        bucket = container.decodeIfPresentDefault(String.self, forKey: .bucket, default: "")
    }
}

private func stringValue(_ value: Any?) -> String {
    guard let value else {
        return ""
    }
    return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
}
