import Foundation

public struct EngineSnapshot: Sendable, Equatable {
    public var syncReport: SyncReport?
    public var doctorResult: DoctorResult?
    public var verifyResult: VerifyResult?
    public var loginStatus: LoginStatus?
    public var legacyState: LegacySyncState?
    public var filePreview: FileSyncPreview?
    public var downloadResult: CourseFileDownloadResult?
    public var quarantineReport: QuarantineReport?
    public var cleanupResult: CleanupResult?
    public var dryRunReports: [KLMSSyncScope: DryRunReport]
    public var launchAgentLogTail: String

    public init(
        syncReport: SyncReport? = nil,
        doctorResult: DoctorResult? = nil,
        verifyResult: VerifyResult? = nil,
        loginStatus: LoginStatus? = nil,
        legacyState: LegacySyncState? = nil,
        filePreview: FileSyncPreview? = nil,
        downloadResult: CourseFileDownloadResult? = nil,
        quarantineReport: QuarantineReport? = nil,
        cleanupResult: CleanupResult? = nil,
        dryRunReports: [KLMSSyncScope: DryRunReport] = [:],
        launchAgentLogTail: String = ""
    ) {
        self.syncReport = syncReport
        self.doctorResult = doctorResult
        self.verifyResult = verifyResult
        self.loginStatus = loginStatus
        self.legacyState = legacyState
        self.filePreview = filePreview
        self.downloadResult = downloadResult
        self.quarantineReport = quarantineReport
        self.cleanupResult = cleanupResult
        self.dryRunReports = dryRunReports
        self.launchAgentLogTail = launchAgentLogTail
    }

    public var needsAttention: Bool {
        (syncReport?.needsAttention ?? false)
            || (quarantineReport?.quarantineCount ?? 0) > 0
            || doctorResult?.status == "error"
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

        return EngineSnapshot(
            syncReport: JSONFileLoader.loadIfExists(SyncReport.self, from: paths.syncReportURL),
            doctorResult: JSONFileLoader.loadIfExists(DoctorResult.self, from: paths.doctorResultURL),
            verifyResult: JSONFileLoader.loadIfExists(VerifyResult.self, from: paths.verifyResultURL),
            loginStatus: JSONFileLoader.loadIfExists(LoginStatus.self, from: paths.loginStatusURL),
            legacyState: JSONFileLoader.loadIfExists(LegacySyncState.self, from: paths.stateJSONURL),
            filePreview: JSONFileLoader.loadIfExists(FileSyncPreview.self, from: paths.filePreviewURL),
            downloadResult: JSONFileLoader.loadIfExists(CourseFileDownloadResult.self, from: paths.downloadResultURL),
            quarantineReport: JSONFileLoader.loadIfExists(QuarantineReport.self, from: paths.quarantineReportURL),
            cleanupResult: JSONFileLoader.loadIfExists(CleanupResult.self, from: paths.cleanupResultURL),
            dryRunReports: dryRuns,
            launchAgentLogTail: tailText(paths.launchAgentLogURL, maxBytes: 16_384)
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
        return String(data: data, encoding: .utf8) ?? ""
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
