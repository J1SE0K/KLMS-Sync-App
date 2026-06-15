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
    public var relayLogTail: String

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
        relayLogTail: String = ""
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
        self.relayLogTail = relayLogTail
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
        "상태 검사 실패 · \(check.diagnosticTitle)"
    }

    private func verifyIssueDetail(for check: VerifyCheck) -> String {
        "\(check.diagnosticExplanation) \(check.diagnosticNextAction)"
    }

    private func numericValue(named key: String, in detail: String) -> Int? {
        for part in detail.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }) {
            let prefix = "\(key)="
            guard part.hasPrefix(prefix) else { continue }
            return Int(part.dropFirst(prefix.count))
        }
        return nil
    }

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
        let manifestLookup = courseFileManifestLookup(snapshot.courseFileManifest)
        return downloadResult.results.filter(\.copiedToNewFilesInbox).filter { item in
            let manifest = (!item.url.isEmpty ? manifestLookup.byURL[item.url] : nil)
                ?? manifestLookup.byRelativePath[item.relativePath]
            let key = EngineFileInteractionKey.key(
                url: item.url,
                path: manifest?.absolutePath ?? "",
                fallback: item.relativePath
            )
            return snapshot.appUserState?.files[key]?.isHiddenLike != true
        }.count
    }

    private static func courseFileManifestLookup(_ manifest: [CourseFileManifestEntry]) -> (
        byURL: [String: CourseFileManifestEntry],
        byRelativePath: [String: CourseFileManifestEntry]
    ) {
        var byURL: [String: CourseFileManifestEntry] = [:]
        var byRelativePath: [String: CourseFileManifestEntry] = [:]
        byURL.reserveCapacity(manifest.count)
        byRelativePath.reserveCapacity(manifest.count)
        for entry in manifest {
            if !entry.url.isEmpty {
                byURL[entry.url] = entry
            }
            if !entry.relativePath.isEmpty {
                byRelativePath[entry.relativePath] = entry
            }
        }
        return (byURL, byRelativePath)
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

        let courseFileManifest = Self.mergingLocalCourseFiles(
            into: JSONFileLoader.loadIfExists([CourseFileManifestEntry].self, from: paths.courseFileManifestURL) ?? [],
            courseFilesRoot: paths.courseFilesURL
        )
        let noticeDigest = JSONFileLoader.loadIfExists(NoticeDigest.self, from: paths.noticeDigestURL)
        let noticeUserState = (try? NoticeUserStateStore(url: paths.noticeUserStateURL).load())?
            .migratingLegacyNoticeKeys(for: noticeDigest)

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
            noticeDigest: noticeDigest,
            noticeUserState: noticeUserState,
            appUserState: try? AppUserStateStore(url: paths.appUserStateURL).load(),
            filePreview: JSONFileLoader.loadIfExists(FileSyncPreview.self, from: paths.filePreviewURL),
            downloadResult: JSONFileLoader.loadIfExists(CourseFileDownloadResult.self, from: paths.downloadResultURL),
            courseFileManifest: courseFileManifest,
            quarantineReport: JSONFileLoader.loadIfExists(QuarantineReport.self, from: paths.quarantineReportURL),
            cleanupResult: JSONFileLoader.loadIfExists(CleanupResult.self, from: paths.cleanupResultURL),
            dryRunReports: dryRuns,
            relayLogTail: recentRelayLogTail(paths: paths)
        )
    }

    private func recentRelayLogTail(paths: KLMSPaths) -> String {
        let stderr = tailText(paths.relayStderrLogURL, maxBytes: 16_384)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = tailText(paths.relayStdoutLogURL, maxBytes: 8_192)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !stderr.isEmpty {
            parts.append("[relay stderr]\n\(stderr)")
        }
        if !stdout.isEmpty {
            parts.append("[relay stdout]\n\(stdout)")
        }
        return parts.joined(separator: "\n\n")
    }

    static func mergingLocalCourseFiles(
        into manifest: [CourseFileManifestEntry],
        courseFilesRoot: URL,
        fileManager: FileManager = .default
    ) -> [CourseFileManifestEntry] {
        guard let enumerator = fileManager.enumerator(
            at: courseFilesRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return manifest
        }

        var knownRelativePaths = Set(manifest.map { normalizedPathKey($0.relativePath) })
        var courseByFolder: [String: String] = [:]
        for entry in manifest {
            guard let folder = firstPathComponent(entry.relativePath), !entry.course.isEmpty else {
                continue
            }
            courseByFolder[normalizedPathKey(folder)] = entry.course
        }

        var localOnly: [CourseFileManifestEntry] = []
        for case let fileURL as URL in enumerator {
            guard !fileURL.lastPathComponent.hasPrefix("."),
                  (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let relativePath = relativePath(from: courseFilesRoot, to: fileURL) else {
                continue
            }
            let normalizedRelativePath = normalizedPathKey(relativePath)
            guard !knownRelativePaths.contains(normalizedRelativePath) else {
                continue
            }
            knownRelativePaths.insert(normalizedRelativePath)

            let components = relativePath
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            let folderCourse = components.first ?? ""
            let bucket = components.dropFirst().first ?? ""
            let course = courseByFolder[normalizedPathKey(folderCourse)] ?? folderCourse
            let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map(formatLocalCourseFileDate) ?? ""

            localOnly.append(CourseFileManifestEntry(
                filename: fileURL.lastPathComponent,
                relativePath: relativePath,
                course: course,
                absolutePath: fileURL.path,
                localDownloadedAt: modifiedAt,
                bucket: bucket
            ))
        }

        return manifest + localOnly.sorted { lhs, rhs in
            lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
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

    private static func relativePath(from root: URL, to fileURL: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else {
            return nil
        }
        return String(filePath.dropFirst(prefix.count))
    }

    private static func firstPathComponent(_ path: String) -> String? {
        path.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init)
    }

    private static func normalizedPathKey(_ value: String) -> String {
        (value as NSString).precomposedStringWithCanonicalMapping
    }

    private static func formatLocalCourseFileDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy-MM-dd HH:mm KST"
        return formatter.string(from: date)
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
    public var missingFiles: [String]
    public var derivedAssignmentCount: Int
    public var missingDerivedAssignmentCount: Int
    public var derivedExamCount: Int
    public var missingDerivedExamCount: Int
    public var classificationError: String

    enum CodingKeys: String, CodingKey {
        case manifestFileCount = "manifest_file_count"
        case missingFileCount = "missing_file_count"
        case missingFiles = "missing_files"
        case derivedAssignmentCount = "derived_assignment_count"
        case missingDerivedAssignmentCount = "missing_derived_assignment_count"
        case derivedExamCount = "derived_exam_count"
        case missingDerivedExamCount = "missing_derived_exam_count"
        case classificationError = "classification_error"
    }

    public init(
        manifestFileCount: Int = 0,
        missingFileCount: Int = 0,
        missingFiles: [String] = [],
        derivedAssignmentCount: Int = 0,
        missingDerivedAssignmentCount: Int = 0,
        derivedExamCount: Int = 0,
        missingDerivedExamCount: Int = 0,
        classificationError: String = ""
    ) {
        self.manifestFileCount = manifestFileCount
        self.missingFileCount = missingFileCount
        self.missingFiles = missingFiles
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
        missingFiles = container.decodeIfPresentDefault([String].self, forKey: .missingFiles, default: [])
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
    public var examRecordCount: Int
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
        case examRecordCount = "exam_record_count"
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
        examRecordCount: Int = 0,
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
        self.examRecordCount = examRecordCount
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
        examRecordCount = container.decodeIfPresentDefault(Int.self, forKey: .examRecordCount, default: 0)
        missingExamInfoCount = container.decodeIfPresentDefault(Int.self, forKey: .missingExamInfoCount, default: 0)
        helpdeskCount = container.decodeIfPresentDefault(Int.self, forKey: .helpdeskCount, default: 0)
    }
}

public struct VerifyCalendarSummary: Decodable, Sendable, Equatable {
    public var examCount: Int
    public var manualExamCount: Int
    public var displayExamCount: Int
    public var helpdeskCount: Int
    public var legacyAssignmentExists: Bool
    public var legacyAlertExists: Bool
    public var error: String
    public var resultTotals: VerifyCalendarResultTotals?

    enum CodingKeys: String, CodingKey {
        case examCount = "exam_count"
        case manualExamCount = "manual_exam_count"
        case displayExamCount = "display_exam_count"
        case helpdeskCount = "helpdesk_count"
        case legacyAssignmentExists = "legacy_assignment_exists"
        case legacyAlertExists = "legacy_alert_exists"
        case error
        case resultTotals = "result_totals"
    }

    public init(
        examCount: Int = 0,
        manualExamCount: Int = 0,
        displayExamCount: Int? = nil,
        helpdeskCount: Int = 0,
        legacyAssignmentExists: Bool = false,
        legacyAlertExists: Bool = false,
        error: String = "",
        resultTotals: VerifyCalendarResultTotals? = nil
    ) {
        self.examCount = examCount
        self.manualExamCount = manualExamCount
        self.displayExamCount = displayExamCount ?? examCount + manualExamCount
        self.helpdeskCount = helpdeskCount
        self.legacyAssignmentExists = legacyAssignmentExists
        self.legacyAlertExists = legacyAlertExists
        self.error = error
        self.resultTotals = resultTotals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        examCount = container.decodeIfPresentDefault(Int.self, forKey: .examCount, default: 0)
        manualExamCount = container.decodeIfPresentDefault(Int.self, forKey: .manualExamCount, default: 0)
        displayExamCount = container.decodeIfPresentDefault(
            Int.self,
            forKey: .displayExamCount,
            default: examCount + manualExamCount
        )
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
    public var issueActiveCount: Int
    public var issueMarkerCount: Int
    public var issueListExists: Bool
    public var alertActiveCount: Int
    public var alertMarkerCount: Int
    public var alertListExists: Bool
    public var totalActiveCount: Int
    public var totalMarkerCount: Int
    public var error: String

    enum CodingKeys: String, CodingKey {
        case assignmentActiveCount = "assignment_active_count"
        case assignmentMarkerCount = "assignment_marker_count"
        case assignmentListExists = "assignment_list_exists"
        case issueActiveCount = "issue_active_count"
        case issueMarkerCount = "issue_marker_count"
        case issueListExists = "issue_list_exists"
        case alertActiveCount = "alert_active_count"
        case alertMarkerCount = "alert_marker_count"
        case alertListExists = "alert_list_exists"
        case totalActiveCount = "total_active_count"
        case totalMarkerCount = "total_marker_count"
        case error
    }

    public init(
        assignmentActiveCount: Int = 0,
        assignmentMarkerCount: Int = 0,
        assignmentListExists: Bool = false,
        issueActiveCount: Int = 0,
        issueMarkerCount: Int = 0,
        issueListExists: Bool = false,
        alertActiveCount: Int = 0,
        alertMarkerCount: Int = 0,
        alertListExists: Bool = false,
        totalActiveCount: Int = 0,
        totalMarkerCount: Int = 0,
        error: String = ""
    ) {
        self.assignmentActiveCount = assignmentActiveCount
        self.assignmentMarkerCount = assignmentMarkerCount
        self.assignmentListExists = assignmentListExists
        self.issueActiveCount = issueActiveCount
        self.issueMarkerCount = issueMarkerCount
        self.issueListExists = issueListExists
        self.alertActiveCount = alertActiveCount
        self.alertMarkerCount = alertMarkerCount
        self.alertListExists = alertListExists
        self.totalActiveCount = totalActiveCount
        self.totalMarkerCount = totalMarkerCount
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assignmentActiveCount = container.decodeIfPresentDefault(Int.self, forKey: .assignmentActiveCount, default: 0)
        assignmentMarkerCount = container.decodeIfPresentDefault(Int.self, forKey: .assignmentMarkerCount, default: 0)
        assignmentListExists = container.decodeIfPresentDefault(Bool.self, forKey: .assignmentListExists, default: false)
        issueActiveCount = container.decodeIfPresentDefault(Int.self, forKey: .issueActiveCount, default: 0)
        issueMarkerCount = container.decodeIfPresentDefault(Int.self, forKey: .issueMarkerCount, default: 0)
        issueListExists = container.decodeIfPresentDefault(Bool.self, forKey: .issueListExists, default: false)
        alertActiveCount = container.decodeIfPresentDefault(Int.self, forKey: .alertActiveCount, default: 0)
        alertMarkerCount = container.decodeIfPresentDefault(Int.self, forKey: .alertMarkerCount, default: 0)
        alertListExists = container.decodeIfPresentDefault(Bool.self, forKey: .alertListExists, default: false)
        totalActiveCount = container.decodeIfPresentDefault(
            Int.self,
            forKey: .totalActiveCount,
            default: assignmentActiveCount + issueActiveCount + alertActiveCount
        )
        totalMarkerCount = container.decodeIfPresentDefault(
            Int.self,
            forKey: .totalMarkerCount,
            default: assignmentMarkerCount + issueMarkerCount + alertMarkerCount
        )
        error = container.decodeIfPresentDefault(String.self, forKey: .error, default: "")
    }
}

public struct VerifyCheck: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var status: String
    public var detail: String

    public var message: String { detail }

    public var id: String { name }

    public var diagnosticTitle: String {
        switch name {
        case "manifest_files_exist":
            if let missing = numericValue(named: "missing") {
                return "파일 \(missing)개 누락"
            }
            return "파일 목록 불일치"
        case "notice_render_complete":
            if let missing = numericValue(named: "missing") {
                return "공지 메모 \(missing)개 누락"
            }
            return "공지 메모 반영 불일치"
        case "notice_exam_detection_covered_by_state":
            return "공지 속 시험 감지 상태 확인"
        case "notice_assignment_detection_covered_by_state":
            return "공지 속 과제 감지 상태 확인"
        case "manifest_assignment_detection_covered_by_state":
            return "파일 속 과제 감지 상태 확인"
        case "manifest_exam_detection_covered_by_state":
            return "파일 속 시험 감지 상태 확인"
        case "calendar_exam_count_matches_state":
            if let calendar = numericValue(named: "calendar"),
               let state = numericValue(named: "state"),
               state > calendar {
                return "캘린더 시험 \(state - calendar)개 누락"
            }
            return "캘린더 시험 수 불일치"
        case "calendar_helpdesk_count_matches_state":
            if let calendar = numericValue(named: "calendar"),
               let state = numericValue(named: "state"),
               state > calendar {
                return "캘린더 헬프데스크 \(state - calendar)개 누락"
            }
            return "캘린더 헬프데스크 수 불일치"
        case "calendar_result_exam_matches_state":
            if let result = numericValue(named: "result"),
               let state = numericValue(named: "state"),
               state > result {
                return "마지막 캘린더 반영에서 시험 \(state - result)개 누락"
            }
            return "마지막 캘린더 시험 반영 불일치"
        case "calendar_result_helpdesk_matches_state":
            if let result = numericValue(named: "result"),
               let state = numericValue(named: "state"),
               state > result {
                return "마지막 캘린더 반영에서 헬프데스크 \(state - result)개 누락"
            }
            return "마지막 캘린더 헬프데스크 반영 불일치"
        case "reminders_assignment_count_matches_state":
            return "미리 알림 과제 수 불일치"
        case "reminders_total_count_consistent":
            return "미리 알림 전체 수 불일치"
        case "past_exam_items_absent":
            return "지난 시험 정리 상태 확인"
        case "exam_information_present":
            return "시험 세부 정보 확인"
        default:
            return "상태 검사 · \(name)"
        }
    }

    public var diagnosticExplanation: String {
        switch name {
        case "manifest_files_exist":
            if let missing = numericValue(named: "missing") {
                return "파일 목록에는 있는데 Mac 로컬 저장소에서 찾지 못한 파일이 \(missing)개 있다는 뜻입니다."
            }
            return "파일 목록과 실제 저장된 파일 목록이 서로 맞지 않습니다."
        case "notice_render_complete":
            if let missing = numericValue(named: "missing") {
                return "KLMS에서 읽은 공지 중 Notes 메모에 반영되지 않은 공지가 \(missing)개 있다는 뜻입니다."
            }
            return "공지 수집 결과와 Notes 메모 렌더 결과가 서로 맞지 않습니다."
        case "notice_exam_detection_covered_by_state":
            return "공지 본문에서 시험처럼 보이는 항목을 찾았고, 그 항목이 앱 상태와 캘린더 후보에 반영됐는지 검사합니다."
        case "notice_assignment_detection_covered_by_state":
            return "공지 본문에서 과제처럼 보이는 항목을 찾았고, 그 항목이 앱 상태와 미리 알림 후보에 반영됐는지 검사합니다."
        case "manifest_assignment_detection_covered_by_state":
            return "파일명이나 파일 목록에서 과제처럼 보이는 항목을 찾았을 때 앱 상태에 반영됐는지 검사합니다."
        case "manifest_exam_detection_covered_by_state":
            return "파일명이나 파일 목록에서 시험처럼 보이는 항목을 찾았을 때 앱 상태에 반영됐는지 검사합니다."
        case "calendar_exam_count_matches_state":
            let calendar = numericValue(named: "calendar")
            let state = numericValue(named: "state")
            if let calendar, let state {
                return "앱 상태 파일에는 시험 \(state)개가 있는데 Apple Calendar에는 시험 \(calendar)개만 있습니다. 캘린더 이벤트가 삭제됐거나 반영 단계가 일부 실패했을 수 있습니다."
            }
            return "앱이 알고 있는 시험 수와 Apple Calendar에 등록된 시험 수가 다릅니다."
        case "calendar_helpdesk_count_matches_state":
            let calendar = numericValue(named: "calendar")
            let state = numericValue(named: "state")
            if let calendar, let state {
                return "앱 상태 파일에는 헬프데스크 \(state)개가 있는데 Apple Calendar에는 \(calendar)개만 있습니다."
            }
            return "앱이 알고 있는 헬프데스크 수와 Apple Calendar 등록 수가 다릅니다."
        case "calendar_result_exam_matches_state":
            let result = numericValue(named: "result")
            let state = numericValue(named: "state")
            if let result, let state {
                return "마지막 캘린더 반영 결과가 시험 \(result)개로 기록됐지만, 앱 상태에는 시험 \(state)개가 있습니다. 방금 실행한 동기화가 모든 시험 일정을 Calendar에 쓰지 못했다는 신호입니다."
            }
            return "마지막 캘린더 반영 결과와 앱 상태의 시험 수가 다릅니다."
        case "calendar_result_helpdesk_matches_state":
            let result = numericValue(named: "result")
            let state = numericValue(named: "state")
            if let result, let state {
                return "마지막 캘린더 반영 결과가 헬프데스크 \(result)개로 기록됐지만, 앱 상태에는 \(state)개가 있습니다."
            }
            return "마지막 캘린더 반영 결과와 앱 상태의 헬프데스크 수가 다릅니다."
        case "reminders_assignment_count_matches_state":
            return "앱 상태의 과제 수와 Apple Reminders의 과제 미리 알림 수가 다릅니다."
        case "reminders_total_count_consistent":
            return "과제, 이슈, 알림 목록을 합친 전체 미리 알림 수가 예상 합계와 다릅니다."
        case "past_exam_items_absent":
            return "지난 시험이 앱 상태나 캘린더에 남아 있는지 확인하는 검사입니다."
        case "exam_information_present":
            return "시험 일정에 시간, 범위, 장소 같은 세부 정보가 충분히 들어 있는지 확인하는 검사입니다."
        default:
            return detail.isEmpty ? "상태 검사 항목입니다." : detail
        }
    }

    public var diagnosticNextAction: String {
        switch name {
        case "manifest_files_exist":
            return "파일 동기화를 다시 실행하세요. 그래도 계속 실패하면 파일 탭에서 누락 파일을 확인하고 새 파일/수정 파일만 다시 받으면 됩니다."
        case "notice_render_complete":
            return "공지 동기화를 다시 실행하세요. Notes 메모가 열려 있거나 권한이 흔들렸다면 권한/환경 진단도 같이 실행하세요."
        case "notice_exam_detection_covered_by_state",
             "notice_assignment_detection_covered_by_state":
            return "대시보드의 후보 항목을 확인하고, 빠진 항목이 있으면 시험/과제로 반영한 뒤 과제/시험 동기화를 다시 실행하세요."
        case "manifest_assignment_detection_covered_by_state",
             "manifest_exam_detection_covered_by_state":
            return "파일 탭에서 해당 파일을 확인하고, 실제 과제/시험 자료라면 후보를 과제/시험으로 반영하세요."
        case "calendar_exam_count_matches_state",
             "calendar_helpdesk_count_matches_state",
             "calendar_result_exam_matches_state",
             "calendar_result_helpdesk_matches_state":
            return "과제/시험 동기화를 다시 실행한 뒤 상태 검사를 한 번 더 누르세요. 계속 남으면 Calendar 앱의 KLMS 캘린더에서 누락된 일정을 확인하세요."
        case "reminders_assignment_count_matches_state",
             "reminders_total_count_consistent":
            return "과제/시험 동기화를 다시 실행하세요. 직접 체크한 완료 상태는 보존되어야 하므로, 중복 항목이 보이면 미리 알림 목록에서 같은 제목을 확인하세요."
        case "past_exam_items_absent":
            return "지난 시험이 남아 있으면 과제/시험 동기화를 다시 실행해서 오래된 시험을 정리하세요."
        case "exam_information_present":
            return "시험 상세가 부족하면 해당 시험 항목을 열어 범위/장소를 직접 보강하거나 공지 후보를 다시 확인하세요."
        default:
            return status.isIssueStatus ? "원본 로그에서 같은 항목명을 검색하고, 관련 동기화를 다시 실행하세요." : "문제가 없으면 별도 조치가 필요 없습니다."
        }
    }

    private func numericValue(named key: String) -> Int? {
        for part in detail.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }) {
            let prefix = "\(key)="
            guard part.hasPrefix(prefix) else { continue }
            return Int(part.dropFirst(prefix.count))
        }
        return nil
    }

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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(status, forKey: .status)
        try container.encode(detail, forKey: .detail)
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
