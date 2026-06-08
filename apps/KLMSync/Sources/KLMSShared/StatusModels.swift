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

public struct CalendarSyncResult: Codable, Sendable, Equatable {
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

public struct CalendarSyncSummary: Codable, Sendable, Equatable, Identifiable {
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

public struct CalendarChange: Codable, Sendable, Equatable, Identifiable {
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
            "정리됨"
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

public struct CalendarEventEdit: Codable, Sendable, Equatable {
    public var title: String
    public var startAt: String
    public var dueAt: String
    public var location: String

    enum CodingKeys: String, CodingKey {
        case title
        case startAt = "start_at"
        case dueAt = "due_at"
        case location
    }

    public init(
        title: String = "",
        startAt: String = "",
        dueAt: String = "",
        location: String = ""
    ) {
        self.title = title
        self.startAt = startAt
        self.dueAt = dueAt
        self.location = location
    }

    public var isEmpty: Bool {
        [title, startAt, dueAt, location].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public static func decodeMessage(_ message: String) throws -> CalendarEventEdit {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw NSError(
                domain: "KLMSync.CalendarEventEdit",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "캘린더 수정 내용이 비어 있습니다."]
            )
        }
        return try JSONDecoder().decode(CalendarEventEdit.self, from: data)
    }

    public func encodedMessage() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "KLMSync.CalendarEventEdit",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "캘린더 수정 내용을 인코딩할 수 없습니다."]
            )
        }
        return text
    }
}

public extension CalendarChange {
    var explanationText: String {
        switch normalizedAction {
        case "created":
            return "KLMS에서 확인된 일정이 Apple Calendar에 없어서 새로 만든 항목입니다."
        case "updated":
            if changes.isEmpty {
                return "KLMS 일정과 Apple Calendar 일정이 달라서 수정한 항목입니다."
            }
            return "KLMS 일정과 Apple Calendar 일정이 달라서 수정한 항목입니다. 바뀐 값: \(changes.joined(separator: ", "))."
        case "deleted":
            return "KLMS 기준으로 더 이상 유지할 일정이 아니어서 Apple Calendar에서 정리한 항목입니다."
        default:
            return "최근 동기화에서 캘린더 상태가 바뀐 항목입니다."
        }
    }

    var nextActionText: String {
        switch normalizedAction {
        case "created":
            return "캘린더 앱에서 시간이 맞는지 확인하세요. 직접 고치려면 ‘내용 수정’을 누르고, Calendar 앱에서 보려면 ‘캘린더에서 열기’를 누르세요."
        case "updated":
            return "변경된 시간이 맞는지 확인하세요. 직접 고친 일정이 덮였거나 값이 이상하면 ‘내용 수정’으로 Calendar 이벤트를 바로 고치세요."
        case "deleted":
            return "동기화 결과에서 정리된 일정입니다. 다시 필요하면 위쪽의 과제/시험 재동기화를 실행하세요."
        default:
            return "결과가 맞는지 확인하고, 이상하면 상태 검사 또는 과제/시험 재동기화를 실행하세요."
        }
    }

    var actionButtonHelpText: String {
        "내용 수정은 Apple Calendar 이벤트 자체를 바꿉니다. 캘린더에서 열기는 Calendar 앱에서 직접 확인하는 기능입니다."
    }

    private var normalizedAction: String {
        action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

public struct KLMSStageDuration: Sendable, Equatable, Identifiable {
    public var stage: String
    public var seconds: Int

    public var id: String { stage }

    public init(stage: String, seconds: Int) {
        self.stage = stage
        self.seconds = seconds
    }

    public var displayName: String {
        switch stage {
        case "core":
            return "과제/시험"
        case "notice":
            return "공지"
        case "files":
            return "파일"
        default:
            return stage
        }
    }

    public var secondsText: String {
        if seconds >= 60 {
            let minutes = seconds / 60
            let remainder = seconds % 60
            return remainder == 0 ? "\(minutes)분" : "\(minutes)분 \(remainder)초"
        }
        return "\(seconds)초"
    }
}

public enum KLMSStageDurationParser {
    public static func parse(from output: String) -> [KLMSStageDuration] {
        let pattern = #"^==\s+(core|notice|files)\s+finish\b.*\bduration_s=(\d+)\s*=="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        var latestByStage: [String: KLMSStageDuration] = [:]
        output.split(whereSeparator: \.isNewline).forEach { line in
            let text = String(line)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 3 else {
                return
            }
            guard
                let stageRange = Range(match.range(at: 1), in: text),
                let secondsRange = Range(match.range(at: 2), in: text),
                let seconds = Int(String(text[secondsRange]))
            else {
                return
            }
            let stage = String(text[stageRange])
            latestByStage[stage] = KLMSStageDuration(stage: stage, seconds: seconds)
        }
        let order = ["core", "notice", "files"]
        return order.compactMap { latestByStage[$0] }
    }
}

public struct KLMSLogHighlight: Sendable, Equatable, Identifiable {
    public var level: String
    public var title: String
    public var detail: String
    public var explanation: String
    public var nextAction: String

    public var id: String { "\(level)-\(title)-\(detail)" }

    public init(level: String, title: String, detail: String, explanation: String = "", nextAction: String = "") {
        self.level = level
        self.title = title
        self.detail = detail
        self.explanation = explanation
        self.nextAction = nextAction
    }
}

public enum KLMSReadableLogParser {
    public static func highlights(from output: String, limit: Int = 8) -> [KLMSLogHighlight] {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var highlights: [KLMSLogHighlight] = []
        var seen = Set<String>()

        func append(_ level: String, _ title: String, _ detail: String) {
            let cleanedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedDetail.isEmpty else { return }
            let key = "\(level)|\(title)|\(cleanedDetail)"
            guard seen.insert(key).inserted else { return }
            let diagnostic = diagnosticText(level: level, title: title, detail: cleanedDetail)
            highlights.append(
                KLMSLogHighlight(
                    level: level,
                    title: title,
                    detail: cleanedDetail,
                    explanation: diagnostic.explanation,
                    nextAction: diagnostic.nextAction
                )
            )
        }

        for line in lines {
            if line.hasPrefix("FAILED") || line.localizedCaseInsensitiveContains(" Error: ") {
                append("error", "실패", compactFailureDetail(line))
                continue
            }

            if line.contains("KLMS 로그인이 풀린") || line.localizedCaseInsensitiveContains("login-prompt notified") {
                append("warning", "로그인 필요", line)
                continue
            }

            if line.contains("KAIST 인증 번호:") {
                append("auth", "인증 번호", line.replacingOccurrences(of: "휴대폰 인증 화면에서 같은 번호를 선택하면 동기화를 계속 진행해.", with: ""))
                continue
            }

            if line == "status=ok stage=authenticated" || line.contains("KLMS 로그인 보조 완료") || line.contains("KLMS 이미 로그인되어 있습니다") {
                append("success", "로그인 확인", line)
                continue
            }

            if let stage = parseStageFinish(line) {
                let status = stage.status == "0" ? "완료" : "실패"
                append(stage.status == "0" ? "success" : "warning", "\(stage.name) \(status)", "소요 시간 \(stage.secondsText) · 종료 코드 \(stage.status)")
                continue
            }

            if line.hasPrefix("status=ok scope=core") {
                append("summary", "과제/시험 요약", compactKeyValueLine(line, preferredKeys: ["assignments", "exams", "help_desk", "assignment_candidates", "exam_candidates", "changed"]))
                continue
            }

            if line.hasPrefix("status=ok scope=notice") {
                append("summary", "공지 요약", compactKeyValueLine(line, preferredKeys: ["notice_count", "new", "updated", "dry_run"]))
                continue
            }

            if line.hasPrefix("file-preview ") {
                append("summary", "파일 변경량", compactKeyValueLine(line, preferredKeys: ["manifest", "new_urls", "moved", "fresh_download_candidates", "prune_candidates", "type_mismatch_candidates"]))
                continue
            }

            if line.hasPrefix("download-summary ") {
                append("summary", "파일 다운로드", compactKeyValueLine(line, preferredKeys: ["total", "skipped_existing", "downloaded_fresh", "new_files_copied", "failed", "quarantine"]))
                continue
            }
        }

        return Array(highlights.prefix(limit))
    }

    private static func parseStageFinish(_ line: String) -> (name: String, status: String, secondsText: String)? {
        let pattern = #"^==\s+(core|notice|files)\s+finish\b.*\bstatus=(\d+)\s+duration_s=(\d+)\s*=="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges >= 4,
              let stageRange = Range(match.range(at: 1), in: line),
              let statusRange = Range(match.range(at: 2), in: line),
              let secondsRange = Range(match.range(at: 3), in: line),
              let seconds = Int(String(line[secondsRange])) else {
            return nil
        }
        let duration = KLMSStageDuration(stage: String(line[stageRange]), seconds: seconds)
        return (duration.displayName, String(line[statusRange]), duration.secondsText)
    }

    private static func compactFailureDetail(_ line: String) -> String {
        if let range = line.range(of: " Error: ") {
            return String(line[range.upperBound...])
        }
        if let range = line.range(of: "Error:") {
            return String(line[range.lowerBound...])
        }
        return line
    }

    private static func compactKeyValueLine(_ line: String, preferredKeys: [String]) -> String {
        let pairs = parseKeyValues(line)
        let preferred = preferredKeys.compactMap { key -> String? in
            guard let value = pairs[key], !value.isEmpty else { return nil }
            return "\(displayName(for: key)) \(value)"
        }
        if !preferred.isEmpty {
            return preferred.joined(separator: " · ")
        }
        return line
    }

    private static func parseKeyValues(_ line: String) -> [String: String] {
        var values: [String: String] = [:]
        for part in line.split(separator: " ") {
            let fields = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { continue }
            values[fields[0]] = fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return values
    }

    private static func displayName(for key: String) -> String {
        switch key {
        case "assignments": return "과제"
        case "exams": return "시험"
        case "help_desk": return "헬프데스크"
        case "assignment_candidates": return "과제 후보"
        case "exam_candidates": return "시험 후보"
        case "changed": return "변경"
        case "notice_count": return "공지"
        case "new": return "신규"
        case "updated": return "수정"
        case "dry_run": return "미리보기"
        case "manifest": return "목록"
        case "new_urls": return "새 URL"
        case "moved": return "이동"
        case "fresh_download_candidates": return "다운로드 후보"
        case "prune_candidates": return "정리 후보"
        case "type_mismatch_candidates": return "종류 불일치"
        case "total": return "전체"
        case "skipped_existing": return "기존 유지"
        case "downloaded_fresh": return "새 다운로드"
        case "new_files_copied": return "새 파일함"
        case "failed": return "실패"
        case "quarantine": return "격리"
        default: return key
        }
    }

    private static func diagnosticText(level: String, title: String, detail: String) -> (explanation: String, nextAction: String) {
        if title == "인증 번호" {
            return (
                "KLMS 로그인 보조가 KAIST 2단계 인증 번호를 읽어 온 상태입니다. 이 번호를 휴대폰 인증 화면에서 선택해야 다음 단계로 넘어갑니다.",
                "휴대폰에서 같은 번호를 누른 뒤, 로그가 ‘로그인 확인’으로 바뀌는지 확인하세요."
            )
        }

        if title == "로그인 확인" {
            return (
                "Safari의 KLMS 세션이 현재 유효하다고 확인된 상태입니다. 이 뒤부터 과제/시험, 공지, 파일 동기화가 진행됩니다.",
                "이후 단계가 실패하면 로그인 자체보다 실패 단계의 상세 로그를 우선 확인하세요."
            )
        }

        if title == "로그인 필요" {
            return (
                "KLMS 대시보드 확인 중 로그인 세션이 유효하지 않다고 판단했습니다. 세션이 풀린 상태에서 동기화를 계속하면 빈 페이지나 누락 데이터가 생길 수 있습니다.",
                "Safari에서 KLMS 로그인을 완료한 뒤 다시 실행하세요. 인증 번호가 뜨면 같은 번호를 선택해야 합니다."
            )
        }

        if title == "과제/시험 요약" {
            return (
                "과제, 시험, 헬프데스크 후보를 읽고 앱 상태 파일에 반영한 결과입니다. 후보 수가 0이 아니면 앱에서 실제 과제/시험으로 바꿔야 할 항목이 남아 있을 수 있습니다.",
                "앱 대시보드의 과제/시험/후보 항목을 열어 누락된 항목이 있는지 확인하세요."
            )
        }

        if title == "공지 요약" {
            return (
                "KLMS 공지 목록을 읽고 Notes 메모에 반영한 결과입니다. 신규/수정 수가 0이어도 전체 공지 렌더링 검증은 별도로 봐야 합니다.",
                "공지 메모 양식이 이상하면 진단 결과의 notice_render 관련 항목과 원본 로그의 Notes 오류를 확인하세요."
            )
        }

        if title == "파일 변경량" {
            return (
                "KLMS 파일 목록을 기존 manifest와 비교해서 새 파일, 이동, 재다운로드 후보, 정리 후보를 계산한 결과입니다. 이 단계 자체는 실제 파일을 지우거나 받지 않습니다.",
                "다운로드 후보가 있을 때만 파일 다운로드 단계에서 새 파일 또는 수정된 파일을 처리합니다."
            )
        }

        if title == "파일 다운로드" {
            return (
                "파일 다운로드 단계의 최종 요약입니다. ‘기존 유지’는 이미 있는 파일을 다시 받지 않았다는 뜻이고, ‘새 다운로드’는 새 파일이나 수정 후보만 받은 수입니다.",
                "실패나 격리가 0보다 크면 파일 탭에서 해당 항목을 열어 원인과 처리 버튼을 확인하세요."
            )
        }

        if title.contains("완료") {
            return (
                "해당 동기화 단계가 정상 종료되었습니다. 소요 시간은 이 단계만의 실행 시간이고, 전체 동기화 시간과는 다를 수 있습니다.",
                "소요 시간이 평소보다 길면 아래 원본 로그에서 fetch, render, download처럼 오래 걸린 세부 단계를 확인하세요."
            )
        }

        if title.contains("실패") || level == "error" || level == "warning" {
            return failureDiagnosticText(detail: detail)
        }

        return (
            "동기화 과정에서 상태를 요약한 로그입니다. 원본 로그를 전부 읽지 않아도 현재 단계의 핵심 결과를 빠르게 보기 위한 항목입니다.",
            "문제가 계속되면 바로 아래 원본 로그에서 같은 시간대의 줄을 확인하세요."
        )
    }

    private static func failureDiagnosticText(detail: String) -> (explanation: String, nextAction: String) {
        let lower = detail.lowercased()

        if detail.contains("로그인") || lower.contains("login") || detail.contains("세션") {
            return (
                "KLMS 로그인 세션이 중간에 풀렸거나, Safari가 KLMS 페이지를 정상 대시보드로 읽지 못한 상태입니다.",
                "Safari에서 KLMS 대시보드가 바로 열리는지 확인하고, 로그인/인증을 끝낸 뒤 같은 명령을 다시 실행하세요."
            )
        }

        if detail.contains("Notes") || detail.contains("메모") || detail.contains("notice note") || lower.contains("native notice") {
            return (
                "공지 내용을 Apple Notes에 쓰거나, 기존 읽음/중요 체크 상태를 보존하는 과정에서 실패했습니다. 권한 문제, Notes 창 상태, 메모 양식 불일치가 흔한 원인입니다.",
                "Notes 앱을 열어 KLMS 공지/확인한 공지 메모가 존재하는지 확인하고, 권한/환경 진단을 실행한 뒤 공지 동기화만 다시 실행하세요."
            )
        }

        if detail.contains("capture-failed") || detail.contains("suspicious bulk") {
            return (
                "읽음/중요 체크 상태를 캡처하는 과정에서 이전 상태와 너무 크게 달라져 앱이 안전장치로 중단했습니다. 기존 체크가 대량으로 사라지는 것을 막기 위한 보호 로직입니다.",
                "Notes의 KLMS 공지와 KLMS 확인한 공지에서 체크 상태가 정상인지 본 뒤, 공지 동기화를 다시 실행하세요."
            )
        }

        if detail.contains("Expected one page") || detail.contains("found 0") {
            return (
                "Safari가 KLMS 대시보드 HTML을 비어 있는 결과로 저장했습니다. 보통 로그인 미완료, 페이지 로딩 실패, Safari 자동화 실패에서 나옵니다.",
                "Safari에서 KLMS 대시보드를 새로 열어 정상 표시되는지 확인한 뒤 전체 동기화를 다시 실행하세요."
            )
        }

        if detail.contains("file") || detail.contains("manifest") || detail.contains("download") || detail.contains("quarantine") {
            return (
                "파일 manifest 생성, 다운로드, 격리 처리 중 문제가 생긴 로그입니다. 파일명이 바뀌었거나 기존 로컬 파일이 manifest와 맞지 않을 때도 발생할 수 있습니다.",
                "파일 탭에서 누락/격리/정리 후보를 확인하고, 필요한 경우 파일 동기화만 다시 실행하세요."
            )
        }

        return (
            "명령이 정상 종료되지 않았습니다. 이 항목의 상세 내용이 실제 실패 메시지이며, 아래 원본 로그에는 실패 직전의 단계 흐름이 남아 있습니다.",
            "실패 메시지의 단계 이름을 기준으로 과제/공지/파일 중 어떤 명령을 다시 실행할지 결정하세요."
        )
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

public struct DryRunReport: Codable, Sendable, Equatable {
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
