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

    public var authDigits: String? {
        Self.extractRecentLaunchAgentAuthDigits(from: launchAgentLogTail)
    }

    public var loginPromptDetected: Bool {
        authDigits != nil || Self.hasRecentLaunchAgentLoginPrompt(from: launchAgentLogTail)
    }

    public static func extractRecentLaunchAgentAuthDigits(
        from text: String,
        now: Date = Date(),
        recentInterval: TimeInterval = 15 * 60
    ) -> String? {
        let pattern = #"\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}) KST\].*login-prompt notified.*digits=([0-9][0-9])"#
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

        let quarantineCount = max(syncReport?.files.quarantine ?? 0, quarantineReport?.quarantineCount ?? 0)
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
                        title: "검사 실패 · \(check.name)",
                        detail: check.detail,
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
        let legacyState = JSONFileLoader.loadIfExists(LegacySyncState.self, from: paths.stateJSONURL)?
            .applyingManualOverrides(manualOverrides)

        return EngineSnapshot(
            syncReport: JSONFileLoader.loadIfExists(SyncReport.self, from: paths.syncReportURL),
            calendarSyncResult: JSONFileLoader.loadIfExists(CalendarSyncResult.self, from: paths.calendarSyncResultURL),
            doctorResult: JSONFileLoader.loadIfExists(DoctorResult.self, from: paths.doctorResultURL),
            verifyResult: JSONFileLoader.loadIfExists(VerifyResult.self, from: paths.verifyResultURL),
            loginStatus: JSONFileLoader.loadIfExists(LoginStatus.self, from: paths.loginStatusURL),
            noticeRenderStatus: JSONFileLoader.loadIfExists(NoticeRenderStatus.self, from: paths.noticeRenderErrorSummaryURL),
            noticeStageTiming: JSONFileLoader.loadIfExists(StageTimingReport.self, from: paths.noticeStageTimingURL),
            noticeRenderState: JSONFileLoader.loadIfExists(NoticeNoteRenderState.self, from: paths.noticeRenderStateURL),
            noticeArchiveRenderState: JSONFileLoader.loadIfExists(NoticeNoteRenderState.self, from: paths.noticeArchiveRenderStateURL),
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
    public var checks: [VerifyCheck]

    enum CodingKeys: String, CodingKey {
        case status
        case checks
    }

    public init(status: String = "missing", checks: [VerifyCheck] = []) {
        self.status = status
        self.checks = checks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.decodeIfPresentDefault(String.self, forKey: .status, default: "missing")
        checks = container.decodeIfPresentDefault([VerifyCheck].self, forKey: .checks, default: [])
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
