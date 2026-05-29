import Foundation

public struct EngineSnapshot: Sendable, Equatable {
    public var syncReport: SyncReport?
    public var calendarSyncResult: CalendarSyncResult?
    public var doctorResult: DoctorResult?
    public var verifyResult: VerifyResult?
    public var loginStatus: LoginStatus?
    public var noticeRenderStatus: NoticeRenderStatus?
    public var noticeStageTiming: StageTimingReport?
    public var noticeRenderState: NoticeNoteRenderState?
    public var noticeArchiveRenderState: NoticeNoteRenderState?
    public var rawLegacyState: LegacySyncState?
    public var legacyState: LegacySyncState?
    public var manualOverrides: ManualOverridesSnapshot?
    public var noticeDigest: NoticeDigest?
    public var noticeUserState: NoticeUserStateFile?
    public var appUserState: AppUserStateFile?
    public var filePreview: FileSyncPreview?
    public var downloadResult: CourseFileDownloadResult?
    public var courseFileManifest: [CourseFileManifestEntry]
    public var quarantineReport: QuarantineReport?
    public var cleanupResult: CleanupResult?
    public var dryRunReports: [KLMSSyncScope: DryRunReport]
    public var launchAgentLogTail: String

    public init(
        syncReport: SyncReport? = nil,
        calendarSyncResult: CalendarSyncResult? = nil,
        doctorResult: DoctorResult? = nil,
        verifyResult: VerifyResult? = nil,
        loginStatus: LoginStatus? = nil,
        noticeRenderStatus: NoticeRenderStatus? = nil,
        noticeStageTiming: StageTimingReport? = nil,
        noticeRenderState: NoticeNoteRenderState? = nil,
        noticeArchiveRenderState: NoticeNoteRenderState? = nil,
        rawLegacyState: LegacySyncState? = nil,
        legacyState: LegacySyncState? = nil,
        manualOverrides: ManualOverridesSnapshot? = nil,
        noticeDigest: NoticeDigest? = nil,
        noticeUserState: NoticeUserStateFile? = nil,
        appUserState: AppUserStateFile? = nil,
        filePreview: FileSyncPreview? = nil,
        downloadResult: CourseFileDownloadResult? = nil,
        courseFileManifest: [CourseFileManifestEntry] = [],
        quarantineReport: QuarantineReport? = nil,
        cleanupResult: CleanupResult? = nil,
        dryRunReports: [KLMSSyncScope: DryRunReport] = [:],
        launchAgentLogTail: String = ""
    ) {
        self.syncReport = syncReport
        self.calendarSyncResult = calendarSyncResult
        self.doctorResult = doctorResult
        self.verifyResult = verifyResult
        self.loginStatus = loginStatus
        self.noticeRenderStatus = noticeRenderStatus
        self.noticeStageTiming = noticeStageTiming
        self.noticeRenderState = noticeRenderState
        self.noticeArchiveRenderState = noticeArchiveRenderState
        self.rawLegacyState = rawLegacyState
        self.legacyState = legacyState
        self.manualOverrides = manualOverrides
        self.noticeDigest = noticeDigest
        self.noticeUserState = noticeUserState
        self.appUserState = appUserState
        self.filePreview = filePreview
        self.downloadResult = downloadResult
        self.courseFileManifest = courseFileManifest
        self.quarantineReport = quarantineReport
        self.cleanupResult = cleanupResult
        self.dryRunReports = dryRunReports
        self.launchAgentLogTail = launchAgentLogTail
    }

    public var needsAttention: Bool {
        !issues.isEmpty
    }

    public var visibleCounts: EngineVisibleCounts {
        EngineVisibleCounts(snapshot: self)
    }

    public var hiddenSummary: EngineHiddenSummary {
        EngineHiddenSummary(snapshot: self)
    }

    public var authDigits: String? {
        nil
    }

    public var loginPromptDetected: Bool {
        guard loginStatus?.loggedIn != true else {
            return false
        }
        return Self.hasRecentLaunchAgentLoginPrompt(from: launchAgentLogTail)
    }

    public static func extractRecentLaunchAgentAuthDigits(
        from text: String,
        now: Date = Date(),
        recentInterval: TimeInterval = 15 * 60
    ) -> String? {
        let pattern = #"\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}) KST\].*KAIST 인증 번호:\s*([0-9][0-9])"#
        let matches = timestampedMatches(pattern: pattern, in: text)
        return matches
            .filter { isRecent($0.date, now: now, recentInterval: recentInterval) }
            .filter { !hasLaterLaunchAgentSuccess(after: $0.date, in: text) }
            .max(by: { $0.date < $1.date })?
            .value
    }

    public static func hasRecentLaunchAgentLoginPrompt(
        from text: String,
        now: Date = Date(),
        recentInterval: TimeInterval = 15 * 60
    ) -> Bool {
        let pattern = #"\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}) KST\].*login-prompt notified"#
        return timestampedMatches(pattern: pattern, in: text)
            .contains {
                isRecent($0.date, now: now, recentInterval: recentInterval)
                    && !hasLaterLaunchAgentSuccess(after: $0.date, in: text)
            }
    }

    public var attentionSummary: String {
        issues.first?.title ?? "준비됨"
    }

    public var issues: [EngineIssue] {
        var items: [EngineIssue] = []

        if let authDigits {
            items.append(EngineIssue(
                severity: .warning,
                title: "인증 번호 \(authDigits) 선택 필요",
                detail: "휴대폰 KAIST 인증 화면에서 \(authDigits)를 선택하면 동기화를 계속 진행할 수 있습니다.",
                sourceName: "auth-digits"
            ))
        } else if loginPromptDetected {
            items.append(EngineIssue(
                severity: .warning,
                title: "KLMS 로그인 필요",
                detail: "KLMS 로그인 보조가 실패했거나 로그인 세션이 만료되었습니다.",
                sourceName: "login-required"
            ))
        }

        let quarantineCount = visibleCounts.quarantine
        if quarantineCount > 0 {
            items.append(EngineIssue(
                severity: .warning,
                title: "격리 파일 \(quarantineCount)개",
                detail: quarantineReport?.quarantineRoot ?? "파일 동기화 결과에 격리 항목이 있습니다.",
                sourceName: "quarantine"
            ))
        }

        if let report = syncReport, report.status.normalizedStatus != "ok" {
            items.append(EngineIssue(
                severity: report.status.issueSeverity,
                title: "동기화 요약 \(report.status.klmsLocalizedStatus)",
                detail: "최근 동기화 요약 상태가 \(report.status.klmsLocalizedStatus)입니다.",
                sourceName: "sync-report"
            ))
        }

        if let noticeRenderStatus,
           noticeRenderStatus.status.normalizedStatus != "ok",
           noticeRenderStatus.status.normalizedStatus != "missing" {
            let title = noticeRenderStatus.userMessage.isEmpty
                ? "공지 메모 작성 경고"
                : noticeRenderStatus.userMessage
            items.append(EngineIssue(
                severity: noticeRenderStatus.nonfatal ? .warning : noticeRenderStatus.status.issueSeverity,
                title: title,
                detail: noticeRenderStatus.rawFirstLine,
                sourceName: "notice-render-\(noticeRenderStatus.code)"
            ))
        }

        if let doctor = doctorResult {
            let doctorIssues = doctor.checks.filter { $0.status.isIssueStatus }
            if doctorIssues.isEmpty, doctor.status.isIssueStatus {
                items.append(EngineIssue(
                    severity: doctor.status.issueSeverity,
                    title: "진단 \(doctor.status.klmsLocalizedStatus)",
                    detail: "환경 진단 전체 상태가 \(doctor.status.klmsLocalizedStatus)입니다.",
                    sourceName: "doctor"
                ))
            } else {
                for check in doctorIssues {
                    if check.name == "klms-login-cache", loginPromptDetected {
                        continue
                    }
                    items.append(EngineIssue(
                        severity: check.status.issueSeverity,
                        title: doctorIssueTitle(for: check),
                        detail: doctorIssueDetail(for: check),
                        sourceName: check.name
                    ))
                }
            }
        }

        if let verify = verifyResult {
            let verifyIssues = verify.checks.filter { $0.status.isIssueStatus }
            if verifyIssues.isEmpty, verify.status.isIssueStatus {
                items.append(EngineIssue(
                    severity: verify.status.issueSeverity,
                    title: "상태 검사 \(verify.status.klmsLocalizedStatus)",
                    detail: "상태 검사 전체 결과가 \(verify.status.klmsLocalizedStatus)입니다.",
                    sourceName: "verify"
                ))
            } else {
                for check in verifyIssues {
                    items.append(EngineIssue(
                        severity: check.status.issueSeverity,
                        title: verifyIssueTitle(for: check),
                        detail: verifyIssueDetail(for: check),
                        sourceName: check.name
                    ))
                }
            }
        }

        return items
    }

    private func doctorIssueTitle(for check: DoctorCheck) -> String {
        switch check.name {
        case "file-manifest":
            if let missing = numericValue(named: "missing", in: check.detail) {
                return "파일 \(missing)개 누락"
            }
            return "파일 목록 불일치"
        case "klms-login-cache":
            return "KLMS 로그인 필요"
        default:
            return "진단 문제 · \(check.name)"
        }
    }

    private func doctorIssueDetail(for check: DoctorCheck) -> String {
        switch check.name {
        case "file-manifest":
            if let tracked = numericValue(named: "tracked", in: check.detail),
               let missing = numericValue(named: "missing", in: check.detail) {
                return "파일 목록 \(tracked)개 중 로컬 파일 \(missing)개가 없습니다. KLMS 로그인 후 파일 동기화를 다시 실행하면 복구할 수 있습니다."
            }
            return check.detail
        case "klms-login-cache":
            return check.detail.isEmpty ? "KLMS 로그인이 풀렸을 수 있습니다." : check.detail
        default:
            return check.detail
        }
    }

    private func verifyIssueTitle(for check: VerifyCheck) -> String {
        switch check.name {
        case "manifest_files_exist":
            if let missing = numericValue(named: "missing", in: check.detail) {
                return "상태 검사 실패 · 파일 \(missing)개 누락"
            }
            return "상태 검사 실패 · 파일 누락"
        case "notice_render_complete":
            if let missing = numericValue(named: "missing", in: check.detail) {
                return "상태 검사 실패 · 공지 \(missing)개 누락"
            }
            return "상태 검사 실패 · 공지 메모 불일치"
        default:
            return "상태 검사 실패 · \(check.name)"
        }
    }

    private func verifyIssueDetail(for check: VerifyCheck) -> String {
        switch check.name {
        case "manifest_files_exist":
            if let missing = numericValue(named: "missing", in: check.detail) {
                return "파일 manifest에는 있지만 로컬에 없는 파일이 \(missing)개 있습니다. 파일 동기화를 다시 실행하면 누락 파일을 다시 받거나 manifest를 최신 상태로 맞출 수 있습니다."
            }
            return check.detail
        case "notice_render_complete":
            if let missing = numericValue(named: "missing", in: check.detail) {
                return "공지 digest에는 있지만 메모 렌더 상태에 반영되지 않은 공지가 \(missing)개 있습니다. 공지 동기화를 다시 실행해 주세요."
            }
            return check.detail
        default:
            return check.detail
        }
    }

    private func numericValue(named key: String, in detail: String) -> Int? {
        for part in detail.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }) {
            let prefix = "\(key)="
            guard part.hasPrefix(prefix) else { continue }
            return Int(part.dropFirst(prefix.count))
        }
        return nil
    }

    private static func timestampedMatches(pattern: String, in text: String) -> [(date: Date, value: String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let dateRange = Range(match.range(at: 1), in: text),
                  let date = launchAgentDateFormatter.date(from: String(text[dateRange])) else {
                return nil
            }
            if match.numberOfRanges >= 3, let valueRange = Range(match.range(at: 2), in: text) {
                return (date, String(text[valueRange]))
            }
            return (date, "")
        }
    }

    private static func isRecent(_ date: Date, now: Date, recentInterval: TimeInterval) -> Bool {
        date <= now.addingTimeInterval(60) && now.timeIntervalSince(date) <= recentInterval
    }

    private static func hasLaterLaunchAgentSuccess(after date: Date, in text: String) -> Bool {
        let successPatterns = [
            #"\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}) KST\].*idle=.*exit=0"#,
            #"\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}) KST\].*login-watch detected authenticated"#,
        ]
        return successPatterns.contains { pattern in
            timestampedMatches(pattern: pattern, in: text)
                .contains { $0.date >= date }
        }
    }

    public static func recentLaunchAgentLogTail(
        from text: String,
        now: Date = Date(),
        recentInterval: TimeInterval = 24 * 60 * 60
    ) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var firstRecentLineIndex: Int?
        var latestTimestampedLineIsRecent = false

        for (index, line) in lines.enumerated() {
            guard let date = launchAgentLineDate(line) else {
                continue
            }
            let recent = isRecent(date, now: now, recentInterval: recentInterval)
            latestTimestampedLineIsRecent = recent
            if recent, firstRecentLineIndex == nil {
                firstRecentLineIndex = index
            }
        }

        guard latestTimestampedLineIsRecent, let firstRecentLineIndex else {
            return ""
        }
        return lines[firstRecentLineIndex...].joined(separator: "\n")
    }

    private static func launchAgentLineDate(_ line: String) -> Date? {
        guard line.hasPrefix("[") else {
            return nil
        }
        let timestampEnd = line.index(line.startIndex, offsetBy: 21, limitedBy: line.endIndex)
        guard let timestampEnd else {
            return nil
        }
        let timestamp = String(line[line.index(after: line.startIndex)..<timestampEnd])
        return launchAgentDateFormatter.date(from: timestamp)
    }

    private static let launchAgentDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

public struct EngineVisibleCounts: Sendable, Equatable {
    public var assignments: Int
    public var exams: Int
    public var helpDesk: Int
    public var notices: Int
    public var newFiles: Int
    public var quarantine: Int

    public init(
        assignments: Int = 0,
        exams: Int = 0,
        helpDesk: Int = 0,
        notices: Int = 0,
        newFiles: Int = 0,
        quarantine: Int = 0
    ) {
        self.assignments = assignments
        self.exams = exams
        self.helpDesk = helpDesk
        self.notices = notices
        self.newFiles = newFiles
        self.quarantine = quarantine
    }

    public init(snapshot: EngineSnapshot) {
        let content = snapshot.legacyState?.content
        assignments = content?.assignments.count ?? snapshot.syncReport?.state.assignments ?? 0
        exams = content?.examItems.count ?? snapshot.syncReport?.state.exams ?? 0
        helpDesk = content?.helpDeskItems.count ?? snapshot.syncReport?.state.helpdesk ?? 0
        notices = Self.visibleNoticeCount(snapshot: snapshot)
        newFiles = Self.visibleNewFileCount(snapshot: snapshot)
        quarantine = Self.visibleQuarantineCount(snapshot: snapshot)
    }

    private static func visibleNoticeCount(snapshot: EngineSnapshot) -> Int {
        if let digest = snapshot.noticeDigest {
            let state = snapshot.noticeUserState?.notices ?? [:]
            return digest.notices.filter { state[$0.noticeIdentifier]?.hidden != true }.count
        }
        if let report = snapshot.syncReport {
            return max(0, report.notices.total - report.notices.ignored)
        }
        return 0
    }

    private static func visibleNewFileCount(snapshot: EngineSnapshot) -> Int {
        guard let downloadResult = snapshot.downloadResult else {
            return snapshot.syncReport?.files.newFiles ?? 0
        }
        return downloadResult.results.filter(\.copiedToNewFilesInbox).filter { item in
            let manifest = snapshot.courseFileManifest.first { entry in
                (!item.url.isEmpty && entry.url == item.url) || entry.relativePath == item.relativePath
            }
            let key = EngineFileInteractionKey.key(
                url: item.url,
                path: manifest?.absolutePath ?? "",
                fallback: item.relativePath
            )
            return snapshot.appUserState?.files[key]?.isHiddenLike != true
        }.count
    }

    private static func visibleQuarantineCount(snapshot: EngineSnapshot) -> Int {
        guard let quarantineReport = snapshot.quarantineReport else {
            let hidden = snapshot.appUserState?.quarantine.values.filter(\.isHiddenLike).count ?? 0
            return max(0, (snapshot.syncReport?.files.quarantine ?? 0) - hidden)
        }
        return quarantineReport.records.filter { record in
            let key = EngineFileInteractionKey.key(
                url: record.url,
                path: record.quarantinePath,
                fallback: record.quarantineRelativePath
            )
            return snapshot.appUserState?.quarantine[key]?.isHiddenLike != true
        }.count
    }
}

public struct EngineHiddenSummary: Sendable, Equatable {
    public var assignments: Int
    public var exams: Int
    public var notices: Int
    public var files: Int
    public var quarantine: Int

    public init(
        assignments: Int = 0,
        exams: Int = 0,
        notices: Int = 0,
        files: Int = 0,
        quarantine: Int = 0
    ) {
        self.assignments = assignments
        self.exams = exams
        self.notices = notices
        self.files = files
        self.quarantine = quarantine
    }

    public init(snapshot: EngineSnapshot) {
        let content = snapshot.rawLegacyState?.content ?? snapshot.legacyState?.content
        let overrides = snapshot.manualOverrides
        assignments = (
            (content?.assignments ?? [])
                + (content?.assignmentCandidates ?? [])
                + (content?.completedAssignments ?? [])
                + (content?.assignmentRecords ?? [])
                + (content?.helpDeskItems ?? [])
        )
            .filter { overrides?.isAssignmentHidden($0) == true }
            .reduce(into: Set<String>()) { keys, item in
                keys.insert(item.id)
            }
            .count
        exams = ((content?.examItems ?? []) + (content?.examCandidates ?? []))
            .filter { overrides?.isExamHidden($0) == true }
            .filter { !Self.isPastExam($0) }
            .reduce(into: Set<String>()) { keys, item in
                keys.insert(item.id)
            }
            .count
        notices = (snapshot.noticeDigest?.notices ?? [])
            .filter { snapshot.noticeUserState?.notices[$0.noticeIdentifier]?.hidden == true }
            .count
        files = snapshot.appUserState?.files.values.filter(\.isHiddenLike).count ?? 0
        quarantine = snapshot.appUserState?.quarantine.values.filter(\.isHiddenLike).count ?? 0
    }

    public var total: Int {
        assignments + exams + notices + files + quarantine
    }

    private static func isPastExam(_ item: StateItem) -> Bool {
        let normalizedCategory = item.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedCategory == "exam" || normalizedCategory == "exam_candidate" else {
            return false
        }
        let rawDue = item.syncDue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawDue.isEmpty, let due = ISO8601DateFormatter().date(from: rawDue) else {
            return false
        }
        return due < Date()
    }
}

private enum EngineFileInteractionKey {
    static func key(url: String, path: String, fallback: String) -> String {
        if !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return url
        }
        if !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return path
        }
        return fallback
    }
}

public struct EngineIssue: Sendable, Equatable, Identifiable {
    public enum Severity: String, Sendable, Equatable {
        case warning
        case error
    }

    public var severity: Severity
    public var title: String
    public var detail: String
    public var sourceName: String

    public var id: String {
        "\(severity.rawValue)-\(sourceName)-\(title)-\(detail)"
    }

    public init(severity: Severity, title: String, detail: String, sourceName: String) {
        self.severity = severity
        self.title = title
        self.detail = detail
        self.sourceName = sourceName
    }
}

public struct EngineSnapshotStore: Sendable {
    public var paths: KLMSPaths

    public init(paths: KLMSPaths) {
        self.paths = paths
    }

    public func load() -> EngineSnapshot {
        var dryRuns: [KLMSSyncScope: DryRunReport] = [:]
        for scope in [KLMSSyncScope.all, .core, .notice, .files] {
            if let report = JSONFileLoader.loadIfExists(DryRunReport.self, from: paths.dryRunReportURL(scope: scope)) {
                dryRuns[scope] = report
            }
        }
        let manualOverrides = (try? ManualOverrideStore(url: paths.overridesURL).load()) ?? ManualOverridesSnapshot()
        let rawLegacyState = JSONFileLoader.loadIfExists(LegacySyncState.self, from: paths.stateJSONURL)
        let legacyState = rawLegacyState?.applyingManualOverrides(manualOverrides)
        let noticeStageTiming = JSONFileLoader
            .loadIfExists(StageTimingReport.self, from: paths.noticeStageTimingURL)?
            .markingStaleRunningIfNeeded()

        return EngineSnapshot(
            syncReport: JSONFileLoader.loadIfExists(SyncReport.self, from: paths.syncReportURL),
            calendarSyncResult: JSONFileLoader.loadIfExists(CalendarSyncResult.self, from: paths.calendarSyncResultURL),
            doctorResult: JSONFileLoader.loadIfExists(DoctorResult.self, from: paths.doctorResultURL),
            verifyResult: JSONFileLoader.loadIfExists(VerifyResult.self, from: paths.verifyResultURL),
            loginStatus: JSONFileLoader.loadIfExists(LoginStatus.self, from: paths.loginStatusURL),
            noticeRenderStatus: JSONFileLoader.loadIfExists(NoticeRenderStatus.self, from: paths.noticeRenderErrorSummaryURL),
            noticeStageTiming: noticeStageTiming,
            noticeRenderState: JSONFileLoader.loadIfExists(NoticeNoteRenderState.self, from: paths.noticeRenderStateURL),
            noticeArchiveRenderState: JSONFileLoader.loadIfExists(NoticeNoteRenderState.self, from: paths.noticeArchiveRenderStateURL),
            rawLegacyState: rawLegacyState,
            legacyState: legacyState,
            manualOverrides: manualOverrides,
            noticeDigest: JSONFileLoader.loadIfExists(NoticeDigest.self, from: paths.noticeDigestURL),
            noticeUserState: try? NoticeUserStateStore(url: paths.noticeUserStateURL).load(),
            appUserState: try? AppUserStateStore(url: paths.appUserStateURL).load(),
            filePreview: JSONFileLoader.loadIfExists(FileSyncPreview.self, from: paths.filePreviewURL),
            downloadResult: JSONFileLoader.loadIfExists(CourseFileDownloadResult.self, from: paths.downloadResultURL),
            courseFileManifest: JSONFileLoader.loadIfExists([CourseFileManifestEntry].self, from: paths.courseFileManifestURL) ?? [],
            quarantineReport: JSONFileLoader.loadIfExists(QuarantineReport.self, from: paths.quarantineReportURL),
            cleanupResult: JSONFileLoader.loadIfExists(CleanupResult.self, from: paths.cleanupResultURL),
            dryRunReports: dryRuns,
            launchAgentLogTail: EngineSnapshot.recentLaunchAgentLogTail(
                from: tailText(paths.launchAgentLogURL, maxBytes: 16_384)
            )
        )
    }

    private func tailText(_ url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ""
        }
        defer {
            try? handle.close()
        }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return data.klmsDecodedDisplayText
    }
}

public struct VerifyResult: Decodable, Sendable, Equatable {
    public var status: String
    public var notices: VerifyNoticeSummary?
    public var files: VerifyFileSummary?
    public var state: VerifyStateSummary?
    public var calendar: VerifyCalendarSummary?
    public var reminders: VerifyRemindersSummary?
    public var checks: [VerifyCheck]

    enum CodingKeys: String, CodingKey {
        case status
        case notices
        case files
        case state
        case calendar
        case reminders
        case checks
    }

    public init(
        status: String = "missing",
        notices: VerifyNoticeSummary? = nil,
        files: VerifyFileSummary? = nil,
        state: VerifyStateSummary? = nil,
        calendar: VerifyCalendarSummary? = nil,
        reminders: VerifyRemindersSummary? = nil,
        checks: [VerifyCheck] = []
    ) {
        self.status = status
        self.notices = notices
        self.files = files
        self.state = state
        self.calendar = calendar
        self.reminders = reminders
        self.checks = checks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.decodeIfPresentDefault(String.self, forKey: .status, default: "missing")
        notices = try? container.decodeIfPresent(VerifyNoticeSummary.self, forKey: .notices)
        files = try? container.decodeIfPresent(VerifyFileSummary.self, forKey: .files)
        state = try? container.decodeIfPresent(VerifyStateSummary.self, forKey: .state)
        calendar = try? container.decodeIfPresent(VerifyCalendarSummary.self, forKey: .calendar)
        reminders = try? container.decodeIfPresent(VerifyRemindersSummary.self, forKey: .reminders)
        checks = container.decodeIfPresentDefault([VerifyCheck].self, forKey: .checks, default: [])
    }
}

public struct VerifyNoticeSummary: Decodable, Sendable, Equatable {
    public var digestCount: Int
    public var renderedCount: Int
    public var missingCount: Int
    public var examCandidateCount: Int
    public var missingExamCandidateCount: Int
    public var assignmentCandidateCount: Int
    public var missingAssignmentCandidateCount: Int

    enum CodingKeys: String, CodingKey {
        case digestCount = "digest_count"
        case renderedCount = "rendered_count"
        case missingCount = "missing_count"
        case examCandidateCount = "exam_candidate_count"
        case missingExamCandidateCount = "missing_exam_candidate_count"
        case assignmentCandidateCount = "assignment_candidate_count"
        case missingAssignmentCandidateCount = "missing_assignment_candidate_count"
    }

    public init(
        digestCount: Int = 0,
        renderedCount: Int = 0,
        missingCount: Int = 0,
        examCandidateCount: Int = 0,
        missingExamCandidateCount: Int = 0,
        assignmentCandidateCount: Int = 0,
        missingAssignmentCandidateCount: Int = 0
    ) {
        self.digestCount = digestCount
        self.renderedCount = renderedCount
        self.missingCount = missingCount
        self.examCandidateCount = examCandidateCount
        self.missingExamCandidateCount = missingExamCandidateCount
        self.assignmentCandidateCount = assignmentCandidateCount
        self.missingAssignmentCandidateCount = missingAssignmentCandidateCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        digestCount = container.decodeIfPresentDefault(Int.self, forKey: .digestCount, default: 0)
        renderedCount = container.decodeIfPresentDefault(Int.self, forKey: .renderedCount, default: 0)
        missingCount = container.decodeIfPresentDefault(Int.self, forKey: .missingCount, default: 0)
        examCandidateCount = container.decodeIfPresentDefault(Int.self, forKey: .examCandidateCount, default: 0)
        missingExamCandidateCount = container.decodeIfPresentDefault(Int.self, forKey: .missingExamCandidateCount, default: 0)
        assignmentCandidateCount = container.decodeIfPresentDefault(Int.self, forKey: .assignmentCandidateCount, default: 0)
        missingAssignmentCandidateCount = container.decodeIfPresentDefault(Int.self, forKey: .missingAssignmentCandidateCount, default: 0)
    }
}

public struct VerifyFileSummary: Decodable, Sendable, Equatable {
    public var manifestFileCount: Int
    public var missingFileCount: Int
    public var derivedAssignmentCount: Int
    public var missingDerivedAssignmentCount: Int
    public var derivedExamCount: Int
    public var missingDerivedExamCount: Int
    public var classificationError: String

    enum CodingKeys: String, CodingKey {
        case manifestFileCount = "manifest_file_count"
        case missingFileCount = "missing_file_count"
        case derivedAssignmentCount = "derived_assignment_count"
        case missingDerivedAssignmentCount = "missing_derived_assignment_count"
        case derivedExamCount = "derived_exam_count"
        case missingDerivedExamCount = "missing_derived_exam_count"
        case classificationError = "classification_error"
    }

    public init(
        manifestFileCount: Int = 0,
        missingFileCount: Int = 0,
        derivedAssignmentCount: Int = 0,
        missingDerivedAssignmentCount: Int = 0,
        derivedExamCount: Int = 0,
        missingDerivedExamCount: Int = 0,
        classificationError: String = ""
    ) {
        self.manifestFileCount = manifestFileCount
        self.missingFileCount = missingFileCount
        self.derivedAssignmentCount = derivedAssignmentCount
        self.missingDerivedAssignmentCount = missingDerivedAssignmentCount
        self.derivedExamCount = derivedExamCount
        self.missingDerivedExamCount = missingDerivedExamCount
        self.classificationError = classificationError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifestFileCount = container.decodeIfPresentDefault(Int.self, forKey: .manifestFileCount, default: 0)
        missingFileCount = container.decodeIfPresentDefault(Int.self, forKey: .missingFileCount, default: 0)
        derivedAssignmentCount = container.decodeIfPresentDefault(Int.self, forKey: .derivedAssignmentCount, default: 0)
        missingDerivedAssignmentCount = container.decodeIfPresentDefault(Int.self, forKey: .missingDerivedAssignmentCount, default: 0)
        derivedExamCount = container.decodeIfPresentDefault(Int.self, forKey: .derivedExamCount, default: 0)
        missingDerivedExamCount = container.decodeIfPresentDefault(Int.self, forKey: .missingDerivedExamCount, default: 0)
        classificationError = container.decodeIfPresentDefault(String.self, forKey: .classificationError, default: "")
    }
}

public struct VerifyStateSummary: Decodable, Sendable, Equatable {
    public var assignmentCount: Int
    public var assignmentCandidateCount: Int
    public var completedAssignmentCount: Int
    public var assignmentRecordCount: Int
    public var examCount: Int
    public var examCandidateCount: Int
    public var pastExamCount: Int
    public var missingExamInfoCount: Int
    public var helpdeskCount: Int

    enum CodingKeys: String, CodingKey {
        case assignmentCount = "assignment_count"
        case assignmentCandidateCount = "assignment_candidate_count"
        case completedAssignmentCount = "completed_assignment_count"
        case assignmentRecordCount = "assignment_record_count"
        case examCount = "exam_count"
        case examCandidateCount = "exam_candidate_count"
        case pastExamCount = "past_exam_count"
        case missingExamInfoCount = "missing_exam_info_count"
        case helpdeskCount = "helpdesk_count"
    }

    public init(
        assignmentCount: Int = 0,
        assignmentCandidateCount: Int = 0,
        completedAssignmentCount: Int = 0,
        assignmentRecordCount: Int = 0,
        examCount: Int = 0,
        examCandidateCount: Int = 0,
        pastExamCount: Int = 0,
        missingExamInfoCount: Int = 0,
        helpdeskCount: Int = 0
    ) {
        self.assignmentCount = assignmentCount
        self.assignmentCandidateCount = assignmentCandidateCount
        self.completedAssignmentCount = completedAssignmentCount
        self.assignmentRecordCount = assignmentRecordCount
        self.examCount = examCount
        self.examCandidateCount = examCandidateCount
        self.pastExamCount = pastExamCount
        self.missingExamInfoCount = missingExamInfoCount
        self.helpdeskCount = helpdeskCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assignmentCount = container.decodeIfPresentDefault(Int.self, forKey: .assignmentCount, default: 0)
        assignmentCandidateCount = container.decodeIfPresentDefault(Int.self, forKey: .assignmentCandidateCount, default: 0)
        completedAssignmentCount = container.decodeIfPresentDefault(Int.self, forKey: .completedAssignmentCount, default: 0)
        assignmentRecordCount = container.decodeIfPresentDefault(Int.self, forKey: .assignmentRecordCount, default: 0)
        examCount = container.decodeIfPresentDefault(Int.self, forKey: .examCount, default: 0)
        examCandidateCount = container.decodeIfPresentDefault(Int.self, forKey: .examCandidateCount, default: 0)
        pastExamCount = container.decodeIfPresentDefault(Int.self, forKey: .pastExamCount, default: 0)
        missingExamInfoCount = container.decodeIfPresentDefault(Int.self, forKey: .missingExamInfoCount, default: 0)
        helpdeskCount = container.decodeIfPresentDefault(Int.self, forKey: .helpdeskCount, default: 0)
    }
}

public struct VerifyCalendarSummary: Decodable, Sendable, Equatable {
    public var examCount: Int
    public var helpdeskCount: Int
    public var legacyAssignmentExists: Bool
    public var legacyAlertExists: Bool
    public var error: String
    public var resultTotals: VerifyCalendarResultTotals?

    enum CodingKeys: String, CodingKey {
        case examCount = "exam_count"
        case helpdeskCount = "helpdesk_count"
        case legacyAssignmentExists = "legacy_assignment_exists"
        case legacyAlertExists = "legacy_alert_exists"
        case error
        case resultTotals = "result_totals"
    }

    public init(
        examCount: Int = 0,
        helpdeskCount: Int = 0,
        legacyAssignmentExists: Bool = false,
        legacyAlertExists: Bool = false,
        error: String = "",
        resultTotals: VerifyCalendarResultTotals? = nil
    ) {
        self.examCount = examCount
        self.helpdeskCount = helpdeskCount
        self.legacyAssignmentExists = legacyAssignmentExists
        self.legacyAlertExists = legacyAlertExists
        self.error = error
        self.resultTotals = resultTotals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        examCount = container.decodeIfPresentDefault(Int.self, forKey: .examCount, default: 0)
        helpdeskCount = container.decodeIfPresentDefault(Int.self, forKey: .helpdeskCount, default: 0)
        legacyAssignmentExists = container.decodeIfPresentDefault(Bool.self, forKey: .legacyAssignmentExists, default: false)
        legacyAlertExists = container.decodeIfPresentDefault(Bool.self, forKey: .legacyAlertExists, default: false)
        error = container.decodeIfPresentDefault(String.self, forKey: .error, default: "")
        resultTotals = try? container.decodeIfPresent(VerifyCalendarResultTotals.self, forKey: .resultTotals)
    }
}

public struct VerifyCalendarResultTotals: Decodable, Sendable, Equatable {
    public var exam: Int
    public var helpdesk: Int

    public init(exam: Int = 0, helpdesk: Int = 0) {
        self.exam = exam
        self.helpdesk = helpdesk
    }
}

public struct VerifyRemindersSummary: Decodable, Sendable, Equatable {
    public var assignmentActiveCount: Int
    public var assignmentMarkerCount: Int
    public var assignmentListExists: Bool
    public var error: String

    enum CodingKeys: String, CodingKey {
        case assignmentActiveCount = "assignment_active_count"
        case assignmentMarkerCount = "assignment_marker_count"
        case assignmentListExists = "assignment_list_exists"
        case error
    }

    public init(
        assignmentActiveCount: Int = 0,
        assignmentMarkerCount: Int = 0,
        assignmentListExists: Bool = false,
        error: String = ""
    ) {
        self.assignmentActiveCount = assignmentActiveCount
        self.assignmentMarkerCount = assignmentMarkerCount
        self.assignmentListExists = assignmentListExists
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assignmentActiveCount = container.decodeIfPresentDefault(Int.self, forKey: .assignmentActiveCount, default: 0)
        assignmentMarkerCount = container.decodeIfPresentDefault(Int.self, forKey: .assignmentMarkerCount, default: 0)
        assignmentListExists = container.decodeIfPresentDefault(Bool.self, forKey: .assignmentListExists, default: false)
        error = container.decodeIfPresentDefault(String.self, forKey: .error, default: "")
    }
}

public struct VerifyCheck: Decodable, Sendable, Equatable, Identifiable {
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

private extension String {
    var normalizedStatus: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isIssueStatus: Bool {
        ["fail", "failed", "error", "warn", "warning"].contains(normalizedStatus)
    }

    var issueSeverity: EngineIssue.Severity {
        ["fail", "failed", "error"].contains(normalizedStatus) ? .error : .warning
    }
}
