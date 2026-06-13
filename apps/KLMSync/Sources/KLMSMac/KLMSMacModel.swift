import Foundation
import ApplicationServices
import AppKit
import EventKit
import KLMSShared
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct KLMSPermissionProbeRow: Identifiable, Equatable {
    var id: String
    var title: String
    var value: String
    var detail: String
    var isWarning: Bool
}

private struct PermissionProbeResult: Sendable {
    var name: String
    var ok: Bool
    var detail: String
}

@MainActor
final class KLMSMacModel: ObservableObject {
    private struct RelayEventEnvelope: Decodable {
        var type: String?
        var reason: String?
        var updatedAt: String?
    }

    private struct ServerRelaySettingDefinition {
        var key: EnvKnownKey
        var title: String
        var valueKind: ServerRelaySettingValueKind
        var defaultValue: String
        var options: [String]

        init(
            _ key: EnvKnownKey,
            title: String,
            valueKind: ServerRelaySettingValueKind,
            defaultValue: String = "",
            options: [String] = []
        ) {
            self.key = key
            self.title = title
            self.valueKind = valueKind
            self.defaultValue = defaultValue
            self.options = options
        }
    }

    private static let serverRelayEditableSettings: [ServerRelaySettingDefinition] = [
        ServerRelaySettingDefinition(.loginAssistEnabled, title: "로그인 보조", valueKind: .bool, defaultValue: "1"),
        ServerRelaySettingDefinition(.loginAssistAllowNoninteractive, title: "앱이 앞에 없어도 로그인 보조", valueKind: .bool, defaultValue: "1"),
        ServerRelaySettingDefinition(.safariBackgroundWindowEnabled, title: "Safari 백그라운드 창", valueKind: .bool, defaultValue: "1"),
        ServerRelaySettingDefinition(.safariBackgroundWindowMode, title: "Safari 백그라운드 방식", valueKind: .choice, defaultValue: "minimize", options: ["minimize", "none"]),
        ServerRelaySettingDefinition(.safariReuseExistingWindowEnabled, title: "KLMS Sync Safari 창 재사용", valueKind: .bool, defaultValue: "1"),
        ServerRelaySettingDefinition(.calendarSkipUnchangedDesired, title: "캘린더 내용 같으면 건너뛰기", valueKind: .bool, defaultValue: "1"),
        ServerRelaySettingDefinition(.syncMode, title: "동기화 모드", valueKind: .choice, defaultValue: "auto", options: ["auto", "quick", "full"]),
        ServerRelaySettingDefinition(.fileRefreshMode, title: "파일 탐색 모드", valueKind: .choice, defaultValue: "auto", options: ["auto", "quick"]),
        ServerRelaySettingDefinition(.fileSkipDownloadWhenPreviewEmpty, title: "파일 변경 없으면 다운로드 확인 건너뛰기", valueKind: .bool, defaultValue: "1"),
        ServerRelaySettingDefinition(.fileKeepFreshDownloads, title: "새 다운로드 임시 폴더 유지", valueKind: .bool, defaultValue: "0"),
        ServerRelaySettingDefinition(.fileWeeklyFoldersEnabled, title: "주차/출처 폴더 사용", valueKind: .bool, defaultValue: "1"),
        ServerRelaySettingDefinition(.filePreserveDownloadArchive, title: "임시 다운로드 보관", valueKind: .bool, defaultValue: "0"),
        ServerRelaySettingDefinition(.noticeHideHiddenItems, title: "숨긴 공지는 메모에서 제외", valueKind: .bool, defaultValue: "1"),
        ServerRelaySettingDefinition(.noticeStableNoopSkip, title: "공지 내용이 같으면 메모 다시 쓰지 않기", valueKind: .bool, defaultValue: "1"),
    ]

    @Published var paths = KLMSPaths()
    @Published var snapshot = EngineSnapshot()
    @Published var envDocument: EnvDocument?
    @Published var appDiagnostics = KLMSAppDiagnostics()
    @Published var commandHistory = CommandRunHistory()
    @Published var latestBackup: AppDataBackupRecord?
    @Published var installResult: EngineInstallResult?
    @Published var lastCommandResult: KLMSCommandResult?
    @Published var lastRemoteCommand: RemoteRunCommand?
    @Published var serverRelayRecentRequestLog: [ServerRelayRequestLogEntry] = []
    @Published var serverRelayRecentFileAccessRequests: [ServerRelayFileAccessRequest] = []
    @Published var serverRelaySharedRunLogs: [ServerRelayRunLog] = []
    @Published var mailDashboardItems: [ServerRelaySyncItem] = []
    @Published var remoteProcessingStatusMessage: String?
    @Published var isCheckingRemoteCommands = false
    @Published var serverRelayEnabled: Bool
    @Published var serverRelayURL: String
    @Published var serverRelayClientToken: String
    @Published var serverRelayWorkerToken: String
    @Published var serverRelayStatusMessage: String?
    @Published var permissionStatusMessage: String?
    @Published var permissionProbeRows: [KLMSPermissionProbeRow] = []
    @Published var resolvedCalendarChangeIDs = Set<String>()
    @Published var runningCommand: KLMSEngineCommand?
    @Published var isCancellingCommand = false
    @Published var liveCommandOutput = ""
    @Published var liveAuthDigits: String?
    @Published var authStatusMessage: String?
    @Published private var authDigitsSuppressed = false
    @Published var errorMessage: String?
    @Published var payload: EnginePayload?

    private let runner = KLMSCommandRunner()
    private let installer = EngineInstaller()
    private let locator = EnginePayloadLocator()
    private var isBootstrapping = false
    private var serverRelayEventStreamTask: Task<Void, Never>?
    private var serverRelayEventWebSocketTask: URLSessionWebSocketTask?
    private var serverRelayEventStreamKey: String?
    private var passiveSnapshotRefreshTask: Task<Void, Never>?
    private var notifiedAuthDigits = Set<String>()
    private var notifiedAuthCompletionForCurrentRun = false
    private var notifiedAlreadyLoggedInForCurrentRun = false
    private var authDigitsSeenForCurrentRun = false
    private var lastAuthCompletionAt: Date?
    private var lastAuthStatusMessageForRemote: String?
    private var authStatusClearTask: Task<Void, Never>?
    private var runningCommandStatusPollTask: Task<Void, Never>?
    private var pasteboardClearTask: Task<Void, Never>?
    private var activeRemoteCommandID: UUID?
    private var pendingRunCancellationRequested = false
    private var serverRelayLastStatusPublishAt: Date?
    private var serverRelayLastInboxUpdatedAt: String?
    private static let automaticPermissionRequestVersionKey = "KLMSAutomaticPermissionRequestVersion"
    private static let deprecatedRemoteProcessingEnabledKey = "KLMSRemoteProcessingEnabled"
    private static let deprecatedLocalRemoteEnabledKey = "KLMSLocalRemoteEnabled"
    private static let deprecatedLocalRemoteTokenKey = "KLMSLocalRemoteToken"
    private static let serverRelayEnabledKey = "KLMSServerRelayEnabled"
    private static let serverRelayURLKey = "KLMSServerRelayURL"
    private static let serverRelayClientTokenKey = "KLMSServerRelayClientToken"
    private static let serverRelayWorkerTokenKey = "KLMSServerRelayWorkerToken"
    private static let deprecatedServerRelayTokenKey = "KLMSServerRelayToken"
    private static let mailDashboardItemsKey = "KLMSMailDashboardItems"
    private static let serverRelayIdleStatusPublishMinimumInterval: TimeInterval = 30
    private static let serverRelayActiveStatusPublishMinimumInterval: TimeInterval = 0.5
    private static let passiveSnapshotRefreshIntervalNanoseconds: UInt64 = 2_000_000_000
    private static let liveCommandOutputMaxCharacters = 80_000
    private static let trimmedLiveCommandOutputPrefix = "... 이전 로그 일부 생략됨 ...\n"

    init() {
        UserDefaults.standard.removeObject(forKey: Self.deprecatedRemoteProcessingEnabledKey)
        UserDefaults.standard.removeObject(forKey: Self.deprecatedLocalRemoteEnabledKey)
        serverRelayEnabled = UserDefaults.standard.bool(forKey: Self.serverRelayEnabledKey)
        let storedRelayURL = UserDefaults.standard.string(forKey: Self.serverRelayURLKey) ?? ""
        if storedRelayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            serverRelayURL = ""
        } else if let publicURL = ServerRelayConnectionInfo.normalizedPublicRelayURL(storedRelayURL) {
            serverRelayURL = publicURL.absoluteString
            UserDefaults.standard.set(publicURL.absoluteString, forKey: Self.serverRelayURLKey)
        } else {
            serverRelayURL = ""
            UserDefaults.standard.removeObject(forKey: Self.serverRelayURLKey)
        }
        LocalRemoteTokenStore.delete(account: "mac")
        UserDefaults.standard.removeObject(forKey: Self.deprecatedLocalRemoteTokenKey)
        let legacyToken = LocalRemoteTokenStore.load(account: "server-relay-mac")
            ?? UserDefaults.standard.string(forKey: Self.deprecatedServerRelayTokenKey)
        let clientToken = LocalRemoteTokenStore.load(account: "server-relay-client-mac")
            ?? UserDefaults.standard.string(forKey: Self.serverRelayClientTokenKey)
        let workerToken = LocalRemoteTokenStore.load(account: "server-relay-worker-mac")
            ?? UserDefaults.standard.string(forKey: Self.serverRelayWorkerTokenKey)
            ?? legacyToken
        serverRelayClientToken = clientToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        serverRelayWorkerToken = workerToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        mailDashboardItems = Self.loadMailDashboardItems()
        let clientTokenSaved = Self.persistRelayToken(
            serverRelayClientToken,
            account: "server-relay-client-mac",
            defaultsKey: Self.serverRelayClientTokenKey
        )
        let workerTokenSaved = Self.persistRelayToken(
            serverRelayWorkerToken,
            account: "server-relay-worker-mac",
            defaultsKey: Self.serverRelayWorkerTokenKey
        )
        if serverRelayClientToken.isEmpty || clientTokenSaved {
            UserDefaults.standard.removeObject(forKey: Self.serverRelayClientTokenKey)
        }
        if serverRelayWorkerToken.isEmpty || workerTokenSaved {
            LocalRemoteTokenStore.delete(account: "server-relay-mac")
            UserDefaults.standard.removeObject(forKey: Self.serverRelayWorkerTokenKey)
            UserDefaults.standard.removeObject(forKey: Self.deprecatedServerRelayTokenKey)
        }
    }

    @discardableResult
    private static func persistRelayToken(_ token: String, account: String, defaultsKey: String) -> Bool {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            LocalRemoteTokenStore.delete(account: account)
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return true
        }
        let saved = LocalRemoteTokenStore.save(trimmedToken, account: account)
        if saved {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        return saved
    }

    deinit {
        serverRelayEventWebSocketTask?.cancel(with: .goingAway, reason: nil)
        serverRelayEventStreamTask?.cancel()
        passiveSnapshotRefreshTask?.cancel()
        pasteboardClearTask?.cancel()
        runningCommandStatusPollTask?.cancel()
    }

    var menuBarSystemImage: String {
        if runningCommand != nil {
            return "arrow.triangle.2.circlepath"
        }
        if snapshot.needsAttention {
            return "exclamationmark.triangle"
        }
        return "checkmark.circle"
    }

    var currentAuthDigits: String? {
        guard runningCommand != nil, !authDigitsSuppressed else {
            return nil
        }
        return liveAuthDigits
    }

    var sharedLockInfo: SyncLockInfo? {
        SyncLockReader(paths: paths).sharedLockInfo(scope: "all")
    }

    var liveProgressLine: String? {
        liveCommandOutput
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
    }

    var currentPhaseText: String? {
        guard runningCommand != nil else {
            return nil
        }
        return KLMSLiveCommandPhase.currentPhase(in: liveCommandOutput).displayName
    }

    var appRunEnvironment: [String: String] {
        var environment = [
            "KLMS_APP_RUN": "1",
            "KLMS_APP_NON_INTRUSIVE_SAFARI": "1",
            "KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED": runtimeBoolConfigValue(.safariBackgroundWindowEnabled, default: true),
            "KLMS_SAFARI_BACKGROUND_WINDOW_MODE": runtimeConfigValue(.safariBackgroundWindowMode, default: "minimize"),
            "KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED": runtimeBoolConfigValue(.safariReuseExistingWindowEnabled, default: true),
            "KLMS_SAFARI_RESTORE_FRONTMOST_ENABLED": "0",
            "NOTICE_NATIVE_NOTE_BIN_PATH": nativeNoticeHelperPath,
            "KLMS_PYTHONPATH_DIR": paths.appPythonPackagesURL.path,
            "OVERRIDES_JSON_PATH": paths.overridesURL.path,
            "KLMS_SCRIPT_NOTIFICATIONS_ENABLED": "0",
            "KLMS_LOGIN_OPEN_SAFARI_ON_FAILURE": "0",
            "LOGIN_PROMPT_OPEN_SAFARI": "0",
            "KLMS_LOGIN_ASSIST_ENABLED": runtimeBoolConfigValue(.loginAssistEnabled, default: true),
            "KLMS_LOGIN_ASSIST_MODE": runtimeConfigValue(.loginAssistMode, default: "manual-digits"),
            "KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE": runtimeBoolConfigValue(.loginAssistAllowNoninteractive, default: true),
            "KLMS_FORCE_LOGIN_PREFLIGHT": "1",
            "KLMS_LOGIN_STATUS_REUSE_SECONDS": "21600",
            "KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS": "0",
            "KAIKEY_REFRESH_PREEXISTING_TWOFACTOR_ENABLED": "1",
            "KAIKEY_AUTHENTICATED_RECHECK_SECONDS": "1",
            "KAIKEY_AUTH_CHECK_SECONDS": "1.2",
            "KAIKEY_MANUAL_APPROVAL_TIMEOUT_SECONDS": "60",
            "NOTICE_NATIVE_ALWAYS_CAPTURE_STATE": runtimeBoolConfigValue(.noticeAlwaysCaptureState, default: true),
            "NOTICE_NATIVE_STABLE_NOOP_SKIP": runtimeBoolConfigValue(.noticeStableNoopSkip, default: true),
            "NOTICE_NATIVE_DEFER_STATE_ONLY_RENDER": "0",
            "NOTICE_NATIVE_FORCE_ARCHIVE_POST_CAPTURE_RENDER": "1",
            "NOTICE_NATIVE_VERIFY_STABLE_SKIP_FORMAT": runtimeBoolConfigValue(.noticeVerifyStableSkipFormat, default: false),
            "NOTICE_NATIVE_POST_RENDER_VERIFY": "0",
            "NOTICE_NATIVE_INITIAL_COLLAPSE_ENABLED": "1",
            "NOTICE_NATIVE_CONSERVATIVE_RENDER_FALLBACK": "0",
            "NOTICE_NATIVE_ENABLE_BATCH_CHECKLIST_FORMAT": "1",
            "NOTICE_NATIVE_ENABLE_UI_STYLE_FORMAT": "1",
            "NOTICE_COLLAPSE_SECTIONS": runtimeBoolConfigValue(.noticeCollapseSections, default: false),
            "NOTICE_COLLAPSE_COURSES": runtimeBoolConfigValue(.noticeCollapseCourses, default: true),
            "NOTICE_COLLAPSE_NOTICE_ITEMS": runtimeBoolConfigValue(.noticeCollapseItems, default: false),
            "NOTICE_STYLE_NOTICE_ITEMS_AS_HEADINGS": runtimeBoolConfigValue(.noticeStyleItemsAsHeadings, default: false),
            "NOTICE_HIDE_HIDDEN_ITEMS": runtimeBoolConfigValue(.noticeHideHiddenItems, default: true),
            "NOTICE_NATIVE_BOLD_REINFORCE_LIMIT": "0",
            "NOTICE_NATIVE_VALIDATE_STYLE": "0",
            "NOTICE_NATIVE_SELECTION_SETTLE_SECONDS": "0.012",
            "NOTICE_NATIVE_CHECKLIST_PRESS_SETTLE_US": "15000",
            "NOTICE_NATIVE_PREFORMATTED_PASTE_ONLY": "0",
            "NOTICE_NATIVE_PLAIN_TEXT_PASTE": runtimeBoolConfigValue(.noticePlainTextPaste, default: false),
            "NOTICE_NATIVE_STYLE_BUDGET_SECONDS": "60",
            "SYNC_MODE": runtimeConfigValue(.syncMode, default: "auto"),
            "FILE_REFRESH_MODE": runtimeConfigValue(.fileRefreshMode, default: "auto"),
            "FILE_FORCE_DOWNLOAD": "0",
            "FILE_SKIP_DOWNLOAD_WHEN_PREVIEW_EMPTY": runtimeBoolConfigValue(.fileSkipDownloadWhenPreviewEmpty, default: true),
            "FILE_KEEP_FRESH_DOWNLOADS": runtimeBoolConfigValue(.fileKeepFreshDownloads, default: false),
            "FILE_WEEKLY_FOLDERS_ENABLED": runtimeBoolConfigValue(.fileWeeklyFoldersEnabled, default: true),
            "FILE_PRESERVE_DOWNLOAD_ARCHIVE": runtimeBoolConfigValue(.filePreserveDownloadArchive, default: false),
            "FILE_ALWAYS_FETCH_MIN_INTERVAL_SECONDS": "21600",
            "FILE_DOWNLOAD_PARALLELISM": "3",
            "FILE_DIRECT_FETCH_MAX_BYTES": "26214400",
            "FILE_DIRECT_FETCH_BATCH_TIMEOUT_SECONDS": "180",
            "REMINDER_RECREATE_STAGE_ALERT_LIST": "0",
        ]
        if let newFilesRoot = runtimeOptionalConfigValue(.fileNewFilesRoot) {
            environment["FILE_NEW_FILES_ROOT"] = newFilesRoot
        }
        if let quarantineRoot = runtimeOptionalConfigValue(.fileQuarantineRoot) {
            environment["FILE_QUARANTINE_ROOT"] = quarantineRoot
        }
        return environment
    }

    var serverRelayConfigured: Bool {
        (try? makeServerRelayStore()) != nil
    }

    var serverRelayConnectionInfoText: String {
        let publicURL = publicServerRelayURLForSharing() ?? ""
        return """
        KLMS Sync 서버 연결 정보
        서버 URL: \(publicURL)
        클라이언트 토큰: \(serverRelayClientToken)
        """
    }

    var nativeNoticeHelperPath: String {
        let nestedHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/KLMSNoticeNativeNote.app/Contents/MacOS/KLMSNoticeNativeNote")
        if FileManager.default.isExecutableFile(atPath: nestedHelper.path) {
            return nestedHelper.path
        }
        return Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/KLMSNoticeNativeNote")
            .path
    }

    func bootstrap() async {
        guard payload == nil else { return }
        guard !isBootstrapping else { return }
        isBootstrapping = true
        defer {
            isBootstrapping = false
        }
        await installEngine(force: false, runDoctorAfterInstall: false)
        if shouldRequestPermissionsAfterInstall {
            await requestAppPermissions(markAutomatic: true)
        }
        await reloadEngineState()
        configurePassiveSnapshotRefresh()
        configureServerRelayRealtime()
    }

    var shouldRequestPermissionsAfterInstall: Bool {
        guard let version = payload?.version, !version.isEmpty else {
            return false
        }
        return UserDefaults.standard.string(forKey: Self.automaticPermissionRequestVersionKey) != version
    }

    func installEngine(force: Bool, runDoctorAfterInstall: Bool = true) async {
        payload = locator.resolve(bundledResourceURL: Bundle.main.resourceURL)
            ?? locator.resolve(bundledResourceURL: Bundle.module.resourceURL)
        guard let payload else {
            errorMessage = "KLMS 엔진 payload를 찾지 못했습니다."
            return
        }
        do {
            installResult = try installer.installIfNeeded(
                payload: payload,
                destination: paths.engineRoot,
                force: force
            )
            try loadConfig()
            refreshAppDiagnostics()
            if runDoctorAfterInstall, installResult?.installed == true {
                _ = try? await runner.run(.doctor, paths: paths)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearTransientRunState() {
        errorMessage = nil
        lastCommandResult = nil
        if !serverRelayEnabled {
            lastRemoteCommand = nil
        }
        liveCommandOutput = ""
        liveAuthDigits = nil
        authStatusMessage = nil
        lastAuthStatusMessageForRemote = nil
        authStatusClearTask?.cancel()
        authStatusClearTask = nil
        runningCommandStatusPollTask?.cancel()
        runningCommandStatusPollTask = nil
        isCancellingCommand = false
        authDigitsSuppressed = false
        notifiedAuthDigits.removeAll()
        notifiedAuthCompletionForCurrentRun = false
        notifiedAlreadyLoggedInForCurrentRun = false
        authDigitsSeenForCurrentRun = false
        lastAuthCompletionAt = nil
    }

    func setServerRelayEnabled(_ enabled: Bool) {
        serverRelayEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.serverRelayEnabledKey)
        configureServerRelayRealtime()
        if enabled {
            guard serverRelayConfigured else {
                serverRelayStatusMessage = "서버 URL과 Mac 전용 토큰을 먼저 입력해 주세요."
                return
            }
            serverRelayStatusMessage = "서버 릴레이 자동 처리가 켜졌습니다."
            Task {
                await publishServerRelayStatusIfNeeded(force: true)
                await processServerRelayCommands(silent: true)
            }
        } else {
            serverRelayStatusMessage = "서버 릴레이 자동 처리가 꺼졌습니다."
        }
    }

    func setServerRelayURL(_ value: String) {
        serverRelayURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(serverRelayURL, forKey: Self.serverRelayURLKey)
        if serverRelayEnabled {
            configureServerRelayRealtime()
        }
    }

    func setServerRelayClientToken(_ value: String) {
        serverRelayClientToken = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.persistRelayToken(
            serverRelayClientToken,
            account: "server-relay-client-mac",
            defaultsKey: Self.serverRelayClientTokenKey
        )
        if serverRelayEnabled {
            configureServerRelayRealtime()
        }
    }

    func setServerRelayWorkerToken(_ value: String) {
        serverRelayWorkerToken = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.persistRelayToken(
            serverRelayWorkerToken,
            account: "server-relay-worker-mac",
            defaultsKey: Self.serverRelayWorkerTokenKey
        )
        if serverRelayEnabled {
            configureServerRelayRealtime()
        }
    }

    func copyServerRelayConnectionInfo() {
        guard publicServerRelayURLForSharing() != nil else {
            serverRelayStatusMessage = "서버 연결 정보에는 공개 HTTPS 서버 URL만 넣을 수 있습니다. 로컬/사설 주소는 복사하지 않았습니다."
            errorMessage = serverRelayStatusMessage
            return
        }
        copyToPasteboard(serverRelayConnectionInfoText)
        serverRelayStatusMessage = "서버 연결 정보를 복사했습니다."
    }

    func copyServerRelayURL() {
        guard let publicURL = publicServerRelayURLForSharing() else {
            serverRelayStatusMessage = "공개 HTTPS 서버 URL만 복사할 수 있습니다. 로컬/사설 주소는 제외했습니다."
            errorMessage = serverRelayStatusMessage
            return
        }
        copyToPasteboard(publicURL)
        serverRelayStatusMessage = "서버 URL을 복사했습니다."
    }

    func copyServerRelayClientToken() {
        copyToPasteboard(serverRelayClientToken)
        serverRelayStatusMessage = "클라이언트 토큰을 복사했습니다."
    }

    func pasteServerRelayConnectionInfo() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let connectionInfo = ServerRelayConnectionInfo.parse(urlText: text) else {
            serverRelayStatusMessage = "클립보드에서 서버 URL과 클라이언트 토큰을 찾지 못했습니다."
            errorMessage = serverRelayStatusMessage
            return
        }
        setServerRelayURL(connectionInfo.baseURL.absoluteString)
        let clientToken = ServerRelayConnectionInfo.labeledToken(
            in: text,
            labels: ServerRelayConnectionInfo.clientTokenLabels + ServerRelayConnectionInfo.legacyTokenLabels
        ) ?? connectionInfo.token
        let workerToken = ServerRelayConnectionInfo.labeledToken(
            in: text,
            labels: ServerRelayConnectionInfo.workerTokenLabels
        )
        setServerRelayClientToken(clientToken)
        if let workerToken {
            setServerRelayWorkerToken(workerToken)
        }
        if NSPasteboard.general.string(forType: .string) == text {
            NSPasteboard.general.clearContents()
        }
        serverRelayStatusMessage = workerToken == nil && serverRelayWorkerToken.isEmpty
            ? "클라이언트 토큰은 붙여넣었습니다. Mac 전용 토큰도 입력해 주세요."
            : "서버 연결 정보를 붙여넣었습니다. 연결 확인을 눌러 주세요."
        errorMessage = nil
    }

    func checkServerRelayConnection(enableOnSuccess: Bool = false) async {
        serverRelayStatusMessage = "서버 연결 확인 중..."
        do {
            let store = try makeServerRelayStore()
            _ = try await store.fetchStatusResponse()
            let status = sanitizedRemoteStatus(
                snapshot: snapshot,
                phase: runningCommand == nil ? "idle" : "running"
            )
            try await store.publishStatus(
                status,
                latestCommand: lastRemoteCommand,
                running: runningCommand != nil,
                message: "Mac 앱 연결 확인 완료"
            )
            try await store.publishSyncData(serverRelaySyncData(from: snapshot))
            if let recentFileRequests = try? await store.fetchRecentFileAccessRequests(limit: 8) {
                serverRelayRecentFileAccessRequests = recentFileRequests
            }
            if let requestLog = try? await store.fetchRecentRequestLog(limit: 20) {
                serverRelayRecentRequestLog = requestLog
            }
            if let syncData = try? await store.fetchSyncData(limit: 1) {
                serverRelaySharedRunLogs = syncData.runLogs
            }
            serverRelayLastStatusPublishAt = Date()
            if enableOnSuccess && !serverRelayEnabled {
                setServerRelayEnabled(true)
            }
            serverRelayStatusMessage = enableOnSuccess || serverRelayEnabled
                ? "서버 릴레이 연결 완료 · 요청 처리 켜짐"
                : "서버 릴레이 연결 완료 · 사용을 켜면 iPhone/Windows 요청을 처리합니다."
            errorMessage = nil
        } catch {
            serverRelayStatusMessage = "서버 연결 실패: \(error.localizedDescription)"
            errorMessage = serverRelayStatusMessage
        }
    }

    func clearServerRelayLogs(scope: ServerRelayLogClearScope = .all) async {
        if scope == .fileAccess,
           serverRelayRecentFileAccessRequests.contains(where: { $0.status.isInFlight }) {
            serverRelayStatusMessage = "파일 요청이 끝난 뒤 파일 요청 기록을 지울 수 있습니다."
            return
        }
        do {
            let store = try makeServerRelayStore()
            let result = try await store.clearDisplayLogs(scope: scope)
            applyServerRelayLogClear(scope: scope)
            serverRelayStatusMessage = serverRelayLogClearMessage(scope: scope, result: result)
            remoteProcessingStatusMessage = nil
            errorMessage = nil
            if let recentFileRequests = try? await store.fetchRecentFileAccessRequests(limit: 8) {
                serverRelayRecentFileAccessRequests = recentFileRequests
            }
            if let requestLog = try? await store.fetchRecentRequestLog(limit: 20) {
                serverRelayRecentRequestLog = requestLog
            }
            if let syncData = try? await store.fetchSyncData(limit: 1) {
                serverRelaySharedRunLogs = syncData.runLogs
            }
        } catch {
            serverRelayStatusMessage = "로그 지우기 실패: \(error.localizedDescription)"
            errorMessage = serverRelayStatusMessage
        }
    }

    func clearServerRelaySharedRunLogs() async {
        do {
            let store = try makeServerRelayStore()
            let result = try await store.clearSharedRunLogs()
            serverRelaySharedRunLogs = []
            serverRelayStatusMessage = "공유 실행 로그 \(result.runLogs)개를 지웠습니다."
            remoteProcessingStatusMessage = nil
            errorMessage = nil
        } catch {
            serverRelayStatusMessage = "공유 실행 로그 지우기 실패: \(error.localizedDescription)"
            errorMessage = serverRelayStatusMessage
        }
    }

    func clearVisibleLogsAndServerRelayLogs() async {
        guard runningCommand == nil else {
            serverRelayStatusMessage = "동기화가 끝난 뒤 로그를 지울 수 있습니다."
            return
        }
        clearTransientRunState()
        clearLocalStoredLogs()
        guard serverRelayConfigured else {
            serverRelayStatusMessage = "로그를 지웠습니다."
            remoteProcessingStatusMessage = nil
            errorMessage = nil
            return
        }
        await clearServerRelayLogs(scope: .all)
        await clearServerRelaySharedRunLogs()
    }

    private func clearLocalStoredLogs() {
        commandHistory = (try? CommandRunHistoryStore(url: paths.appHistoryURL).clear()) ?? CommandRunHistory()
        snapshot.relayLogTail = ""
        for url in [paths.relayStdoutLogURL, paths.relayStderrLogURL] {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.truncate(atOffset: 0)
                    try handle.close()
                } else {
                    try Data().write(to: url)
                }
            } catch {
                errorMessage = "로컬 로그 파일 지우기 실패: \(error.localizedDescription)"
            }
        }
    }

    private func applyServerRelayLogClear(scope: ServerRelayLogClearScope) {
        switch scope {
        case .all:
            if lastRemoteCommand?.status.isInFlight != true {
                lastRemoteCommand = nil
            }
            serverRelayRecentRequestLog = []
            serverRelayRecentFileAccessRequests = serverRelayRecentFileAccessRequests.filter { $0.status.isInFlight }
            serverRelaySharedRunLogs = []
        case .command:
            if lastRemoteCommand?.status.isInFlight != true {
                lastRemoteCommand = nil
            }
        case .requestLog:
            serverRelayRecentRequestLog = []
        case .fileAccess:
            serverRelayRecentFileAccessRequests = []
        }
    }

    private func serverRelayLogClearMessage(
        scope: ServerRelayLogClearScope,
        result: ServerRelayLogClearResponse
    ) -> String {
        switch scope {
        case .all:
            return "로그를 지웠습니다. 실행 \(result.commands)개, 서버 요청 \(result.requestLogEntries)개, 파일 요청 \(result.fileAccessRequests)개"
        case .command:
            return "최근 실행 요청 \(result.commands)개를 지웠습니다."
        case .requestLog:
            return "서버 요청 기록 \(result.requestLogEntries)개를 지웠습니다."
        case .fileAccess:
            return "파일 요청 기록 \(result.fileAccessRequests)개를 지웠습니다."
        }
    }

    private func sanitizedRemoteStatus(snapshot: EngineSnapshot, phase: String) -> SanitizedRemoteStatus {
        var status = SanitizedRemoteStatus(snapshot: snapshot, phase: phase)
        let baseItems = serverRelayBaseSyncItems(
            from: snapshot,
            generatedAt: serverRelayGeneratedAt(from: snapshot),
            updatedAt: ServerRelaySyncItem.isoTimestamp()
        )
        status.applyMailDashboardItems(mailDashboardItems, baseItems: baseItems)
        let calendarCounts = visibleCalendarChangeCounts(from: visibleCalendarChanges(from: snapshot))
        status.calendarCreated = calendarCounts.created
        status.calendarUpdated = calendarCounts.updated
        status.calendarDeleted = calendarCounts.deleted
        if phase == "running" {
            status.phaseDetail = currentPhaseText ?? runningCommand?.displayName ?? "실행 중"
        }
        if phase == "running", let liveAuthDigits {
            status.loginRequired = true
            status.authDigits = liveAuthDigits
            status.authStatusMessage = nil
        } else if phase == "running",
                  let authStatusMessage = currentAuthStatusMessageForRemote() {
            status.loginRequired = false
            status.authDigits = nil
            status.authStatusMessage = authStatusMessage
        }
        return status
    }

    private func currentAuthStatusMessageForRemote(now: Date = Date()) -> String? {
        guard let lastAuthCompletionAt,
              now.timeIntervalSince(lastAuthCompletionAt) <= 120 else {
            return nil
        }
        return authStatusMessage ?? lastAuthStatusMessageForRemote
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        pasteboardClearTask?.cancel()
        pasteboardClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else {
                return
            }
            if NSPasteboard.general.string(forType: .string) == value {
                NSPasteboard.general.clearContents()
            }
            self?.pasteboardClearTask = nil
        }
    }

    private func publicServerRelayURLForSharing() -> String? {
        ServerRelayConnectionInfo.normalizedPublicRelayURL(serverRelayURL)?.absoluteString
    }

    private func configureServerRelayRealtime() {
        configureServerRelayEventStream()
        guard serverRelayEnabled else {
            return
        }
        guard serverRelayConfigured else {
            serverRelayStatusMessage = "서버 URL과 Mac 전용 토큰을 먼저 입력해 주세요."
            return
        }
    }

    private func configureServerRelayEventStream() {
        serverRelayEventWebSocketTask?.cancel(with: .goingAway, reason: nil)
        serverRelayEventWebSocketTask = nil
        serverRelayEventStreamTask?.cancel()
        serverRelayEventStreamTask = nil
        serverRelayEventStreamKey = nil
        guard serverRelayEnabled, serverRelayConfigured else {
            return
        }
        let key = "\(serverRelayURL)|\(serverRelayWorkerToken)"
        serverRelayEventStreamKey = key
        serverRelayEventStreamTask = Task { [weak self] in
            await self?.runServerRelayEventStream(key: key)
        }
    }

    private func runServerRelayEventStream(key: String) async {
        while !Task.isCancelled, serverRelayEventStreamKey == key {
            do {
                let store = try makeServerRelayStore()
                let task = URLSession.shared.webSocketTask(with: store.eventStreamRequest(role: "worker"))
                serverRelayEventWebSocketTask = task
                task.resume()
                await processServerRelayCommands(silent: true)
                let fallbackPoller = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard !Task.isCancelled else { return }
                        await self?.processServerRelayCommands(silent: true)
                    }
                }
                defer {
                    fallbackPoller.cancel()
                }
                while !Task.isCancelled, serverRelayEventStreamKey == key {
                    let message = try await task.receive()
                    handleServerRelayEvent(message)
                    await processServerRelayCommands(silent: true)
                }
            } catch {
                if !Task.isCancelled, serverRelayEventStreamKey == key {
                    serverRelayStatusMessage = "실시간 연결 재시도 중: \(error.localizedDescription)"
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    private func handleServerRelayEvent(_ message: URLSessionWebSocketTask.Message) {
        guard let reason = Self.serverRelayEventReason(message) else {
            return
        }
        if reason == "sync-data:run-logs-clear" {
            clearLocalStoredLogs()
        }
        if reason == "logs-display:all" {
            applyServerRelayLogClear(scope: .all)
            clearLocalStoredLogs()
        } else if reason == "logs-display:requestLog" {
            applyServerRelayLogClear(scope: .requestLog)
        } else if reason == "logs-display:fileAccess" {
            applyServerRelayLogClear(scope: .fileAccess)
        } else if reason == "logs-display:command" {
            applyServerRelayLogClear(scope: .command)
        }
    }

    private static func serverRelayEventReason(_ message: URLSessionWebSocketTask.Message) -> String? {
        let data: Data?
        switch message {
        case .data(let payload):
            data = payload
        case .string(let text):
            data = text.data(using: .utf8)
        @unknown default:
            data = nil
        }
        guard let data,
              let event = try? JSONDecoder().decode(RelayEventEnvelope.self, from: data) else {
            return nil
        }
        return event.reason
    }

    private func makeServerRelayStore() throws -> ServerRelayCommandStore {
        try ServerRelayCommandStore(urlText: serverRelayURL, token: serverRelayWorkerToken)
    }

    private func publishServerRelayStatusIfNeeded(force: Bool = false) async {
        guard serverRelayEnabled else {
            return
        }
        let now = Date()
        let minimumInterval = runningCommand == nil
            ? Self.serverRelayIdleStatusPublishMinimumInterval
            : Self.serverRelayActiveStatusPublishMinimumInterval
        if !force,
           let serverRelayLastStatusPublishAt,
           now.timeIntervalSince(serverRelayLastStatusPublishAt) < minimumInterval {
            return
        }
        let store: ServerRelayCommandStore
        let status: SanitizedRemoteStatus
        var latestCommand = lastRemoteCommand
        let message: String
        do {
            store = try makeServerRelayStore()
            status = sanitizedRemoteStatus(
                snapshot: snapshot,
                phase: runningCommand == nil ? "idle" : "running"
            )
            if var command = lastRemoteCommand, command.status.isInFlight {
                command.summary = status
                command.updatedAt = now
                command.loginRequired = status.loginRequired
                lastRemoteCommand = command
                latestCommand = command
                try await store.update(command)
            }
            message = serverRelayPublicStatusMessage(status: status, latestCommand: latestCommand)
            try await store.publishStatus(
                status,
                latestCommand: latestCommand,
                running: runningCommand != nil,
                message: message
            )
            serverRelayLastStatusPublishAt = now
            serverRelayStatusMessage = message.isEmpty ? "서버 상태 갱신 완료" : message
        } catch {
            serverRelayStatusMessage = "서버 상태 갱신 실패: \(error.localizedDescription)"
            return
        }

        do {
            try await store.publishSyncData(serverRelaySyncData(from: snapshot))
        } catch {
            serverRelayStatusMessage = "서버 상태는 갱신됐지만 대시보드 요약 업로드 실패: \(error.localizedDescription)"
        }
    }

    private func serverRelayPublicStatusMessage(
        status: SanitizedRemoteStatus,
        latestCommand: RemoteRunCommand?
    ) -> String {
        if runningCommand != nil {
            let commandName = runningCommand?.displayName ?? latestCommand?.kind.displayName ?? "동기화"
            let detail = status.phaseDetail ?? "실행"
            return "\(commandName) · \(detail) 진행 중"
        }
        if let latestCommand {
            return "최근 서버 요청: \(latestCommand.kind.displayName) · \(latestCommand.status.displayName)"
        }
        return serverRelayStatusMessage ?? ""
    }

    private func serverRelayGeneratedAt(from snapshot: EngineSnapshot) -> String {
        snapshot.legacyState?.generatedAt
            ?? snapshot.rawLegacyState?.generatedAt
            ?? snapshot.noticeDigest?.generatedAt
            ?? snapshot.calendarSyncResult?.generatedAt
            ?? ServerRelaySyncItem.isoTimestamp()
    }

    private func serverRelayBaseSyncItems(
        from snapshot: EngineSnapshot,
        generatedAt: String,
        updatedAt: String
    ) -> [ServerRelaySyncItem] {
        var items: [ServerRelaySyncItem] = []

        if let content = snapshot.legacyState?.content ?? snapshot.rawLegacyState?.content {
            items += content.assignments.map {
                serverRelaySyncItem(kind: "assignment", item: $0, status: $0.recordStatus.nilIfBlank ?? "진행 중", updatedAt: updatedAt)
            }
            items += content.completedAssignments.map {
                serverRelaySyncItem(kind: "completedAssignment", item: $0, status: "완료", updatedAt: updatedAt)
            }
            items += content.assignmentCandidates.map {
                serverRelaySyncItem(kind: "assignmentCandidate", item: $0, status: "과제 후보", updatedAt: updatedAt)
            }
            items += content.examItems.filter { !isPastExam($0) }.map {
                serverRelaySyncItem(kind: "exam", item: $0, status: "시험", updatedAt: updatedAt)
            }
            items += content.examCandidates.filter { !isPastExam($0) }.map {
                serverRelaySyncItem(kind: "examCandidate", item: $0, status: "시험 후보", updatedAt: updatedAt)
            }
            items += content.helpDeskItems.map {
                serverRelaySyncItem(kind: "helpDesk", item: $0, status: "헬프데스크", updatedAt: updatedAt)
            }
        }

        let noticeUserState = snapshot.noticeUserState?.notices ?? [:]
        items += snapshot.noticeDigest?.notices.map {
            let interaction = noticeUserState[$0.noticeIdentifier]
            let term = $0.academicTerm(generatedAt: snapshot.noticeDigest?.generatedAt ?? generatedAt)
            return ServerRelaySyncItem(
                id: serverRelayNoticeSyncItemID($0),
                kind: "notice",
                course: $0.course,
                academicTerm: term?.displayName ?? "",
                academicYear: term?.year,
                academicSemester: term?.semester.displayName ?? "",
                title: $0.title,
                timestamp: $0.postedAt,
                status: $0.changeState,
                detail: serverRelayPublicText($0.summary.nilIfBlank ?? $0.excerpt),
                attachmentCount: max($0.attachmentItems.count, $0.attachments.count),
                updatedAt: updatedAt,
                isRead: serverRelayNoticeIsRead(interaction, fingerprint: $0.fingerprint),
                isImportant: interaction?.important == true,
                isHidden: interaction?.hidden == true
            )
        } ?? []

        items += snapshot.courseFileManifest.map {
            let term = $0.academicTerm
            return ServerRelaySyncItem(
                id: serverRelayFileSyncItemID($0),
                kind: "file",
                course: $0.course,
                academicTerm: term?.displayName ?? "",
                academicYear: term?.year,
                academicSemester: term?.semester.displayName ?? "",
                title: $0.filename,
                timestamp: $0.klmsTimestamp.nilIfBlank ?? $0.klmsTimestampText.nilIfBlank ?? $0.localDownloadedAt,
                status: $0.bucket,
                detail: $0.klmsTimestampText,
                updatedAt: updatedAt,
                isHidden: snapshot.appUserState?.files[serverRelayFileUserStateKey($0)]?.isHiddenLike == true
            )
        }
        return items
    }

    private func serverRelaySyncData(from snapshot: EngineSnapshot) -> ServerRelaySyncData {
        let generatedAt = serverRelayGeneratedAt(from: snapshot)
        let updatedAt = ServerRelaySyncItem.isoTimestamp()
        let baseItems = serverRelayBaseSyncItems(
            from: snapshot,
            generatedAt: generatedAt,
            updatedAt: updatedAt
        )
        let items = (baseItems + mailDashboardItems).dedupedForServerRelay()

        let calendarChanges = visibleCalendarChanges(from: snapshot).map(serverRelayCalendarChange)

        return ServerRelaySyncData(
            generatedAt: generatedAt,
            items: items,
            dryRunReports: serverRelayDryRunReports(from: snapshot),
            calendarChanges: calendarChanges.dedupedForCalendarDisplay(),
            settings: serverRelaySettings(updatedAt: updatedAt),
            runLogs: serverRelayRunLogs(),
            verifySummary: snapshot.verifyResult.map { ServerRelayVerifySummary(result: $0, updatedAt: updatedAt) }
        )
    }

    private func serverRelayDryRunReports(from snapshot: EngineSnapshot) -> [DryRunReport] {
        snapshot.dryRunReports
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map(\.value)
    }

    private func visibleCalendarChanges(from snapshot: EngineSnapshot) -> [CalendarChange] {
        let changes = (
            snapshot.calendarSyncResult?.changes.filter { !isCalendarChangeResolved($0) } ?? []
        ) + mailCalendarChanges()
        return changes
            .dedupedForCalendarDisplay()
            .filter(\.isUserVisibleCalendarChange)
    }

    private func visibleCalendarChangeCounts(from changes: [CalendarChange]) -> (created: Int, updated: Int, deleted: Int) {
        var created = 0
        var updated = 0
        var deleted = 0
        for change in changes {
            switch change.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "created", "mail":
                created += 1
            case "updated":
                updated += 1
            case "deleted":
                deleted += 1
            default:
                break
            }
        }
        return (created, updated, deleted)
    }

    private func serverRelayCalendarChange(_ change: CalendarChange) -> CalendarChange {
        CalendarChange(
            action: serverRelayPublicText(change.action),
            calendar: serverRelayPublicText(change.calendar),
            bucket: serverRelayPublicText(change.bucket),
            identifier: serverRelayPublicText(change.identifier),
            title: serverRelayPublicText(change.title),
            course: serverRelayPublicText(change.course),
            url: "",
            startAt: serverRelayPublicText(change.startAt),
            dueAt: serverRelayPublicText(change.dueAt),
            location: serverRelayPublicText(change.location),
            changes: change.changes.compactMap { serverRelayPublicText($0).nilIfBlank },
            raw: "",
            parseError: serverRelayPublicText(change.parseError)
        )
    }

    func isCalendarChangeResolved(_ change: CalendarChange) -> Bool {
        calendarChangeResolvedIDs(for: change).contains { resolvedCalendarChangeIDs.contains($0) }
    }

    private func markCalendarChangeResolved(_ change: CalendarChange) {
        resolvedCalendarChangeIDs.formUnion(calendarChangeResolvedIDs(for: change))
    }

    private func calendarChangeResolvedIDs(for change: CalendarChange) -> [String] {
        var ids = [change.id]
        let publicChangeID = serverRelayCalendarChange(change).id
        if publicChangeID != change.id {
            ids.append(publicChangeID)
        }
        if let identifier = change.identifier.nilIfBlank {
            ids.append(identifier)
        }
        return ids
    }

    private func serverRelaySettings(updatedAt: String) -> [ServerRelaySetting] {
        let document = envDocument ?? (try? EnvStore(url: paths.configURL).load()) ?? EnvDocument(text: "")
        return Self.serverRelayEditableSettings.map { definition in
            ServerRelaySetting(
                key: definition.key.rawValue,
                title: definition.title,
                value: document.value(for: definition.key)?.nilIfBlank ?? definition.defaultValue,
                valueKind: definition.valueKind,
                options: definition.options,
                editable: true,
                updatedAt: updatedAt
            )
        }
    }

    private func serverRelayRunLogs() -> [ServerRelayRunLog] {
        return commandHistory.records.prefix(40).map { record in
            ServerRelayRunLog(
                id: record.id,
                command: record.command.rawValue,
                commandTitle: record.command.displayName,
                status: record.statusText,
                startedAt: record.startedAt,
                finishedAt: record.finishedAt,
                updatedAt: record.finishedAt,
                duration: record.elapsedSecondsText,
                exitCode: Int(record.exitCode),
                dryRun: record.dryRun,
                wasCancelled: record.wasCancelled,
                needsAttention: record.needsAttention,
                outputTail: serverRelayPublicLogText(record.outputTail)
            )
        }
    }

    private func serverRelaySyncItem(
        kind: String,
        item: StateItem,
        status: String,
        updatedAt: String
    ) -> ServerRelaySyncItem {
        let term = item.academicTerm
        return ServerRelaySyncItem(
            id: serverRelayStateSyncItemID(kind: kind, item: item),
            kind: kind,
            course: item.course,
            academicTerm: term?.displayName ?? "",
            academicYear: term?.year,
            academicSemester: term?.semester.displayName ?? "",
            title: item.title,
            timestamp: item.syncDue.nilIfBlank ?? item.due.nilIfBlank ?? item.syncStart,
            status: status,
            detail: serverRelayPublicText(item.coverageSummary.nilIfBlank),
            updatedAt: updatedAt
        )
    }

    func addMailDashboardItem(_ item: ServerRelaySyncItem) {
        guard Self.isMailDashboardItem(item) else {
            return
        }
        let normalizedItem = item.normalizedDashboardItem
        mailDashboardItems = ([normalizedItem] + mailDashboardItems.filter { $0.id != normalizedItem.id })
            .dedupedForServerRelay()
            .prefix(80)
            .map { $0 }
        persistMailDashboardItems()
        serverRelayStatusMessage = "\(normalizedItem.kind.klmsMailDashboardKindName) 대시보드에 반영됨"
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.publishServerRelayStatusIfNeeded(force: true)
        }
    }

    private func applyServerRelayMailDashboardAddAction(_ action: ServerRelayItemAction) throws {
        let item: ServerRelaySyncItem
        if let data = action.message.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ServerRelaySyncItem.self, from: data) {
            item = decoded
        } else {
            item = ServerRelaySyncItem(
                id: action.itemID,
                kind: action.itemKind,
                title: action.itemTitle,
                status: "추가됨",
                detail: "추가로 반영한 항목입니다."
            )
        }
        addMailDashboardItem(item)
    }

    private func applyServerRelayMailDashboardRemoveAction(_ action: ServerRelayItemAction) {
        let removed = removeMailDashboardItem(id: action.itemID, kind: action.itemKind)
        if !removed {
            serverRelayStatusMessage = "\(action.itemKind.klmsMailDashboardKindName) 항목은 이미 제거되어 있습니다."
        }
    }

    func removeMailDashboardItem(_ item: ServerRelaySyncItem) {
        _ = removeMailDashboardItem(id: item.id, kind: item.kind)
    }

    @discardableResult
    private func removeMailDashboardItem(id: String, kind: String = "") -> Bool {
        let previousCount = mailDashboardItems.count
        mailDashboardItems.removeAll { $0.id == id }
        let removed = mailDashboardItems.count != previousCount
        persistMailDashboardItems()
        let label = kind.nilIfBlank?.klmsMailDashboardKindName ?? "항목"
        serverRelayStatusMessage = removed
            ? "\(label) 항목을 대시보드에서 제거했습니다."
            : "\(label) 항목은 이미 대시보드에 없습니다."
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.publishServerRelayStatusIfNeeded(force: true)
        }
        return removed
    }

    func mailDashboardItems(kind: String) -> [ServerRelaySyncItem] {
        mailDashboardItems
            .unmatchedMailDashboardItems(comparedTo: currentServerRelayBaseSyncItems())
            .filter { $0.kind == kind }
            .map(\.normalizedDashboardItem)
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp > rhs.timestamp
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    func mailDashboardStateItems(kind: String) -> [StateItem] {
        mailDashboardItems(kind: kind).compactMap(\.mailStateItem)
    }

    func mailCalendarChanges() -> [CalendarChange] {
        mailDashboardItems
            .unmatchedMailDashboardItems(comparedTo: currentServerRelayBaseSyncItems())
            .compactMap(\.mailCalendarChange)
            .filter { !isCalendarChangeResolved($0) }
            .dedupedForCalendarDisplay()
    }

    private func currentServerRelayBaseSyncItems() -> [ServerRelaySyncItem] {
        let generatedAt = serverRelayGeneratedAt(from: snapshot)
        return serverRelayBaseSyncItems(
            from: snapshot,
            generatedAt: generatedAt,
            updatedAt: ServerRelaySyncItem.isoTimestamp()
        )
    }

    private static func isMailDashboardItem(_ item: ServerRelaySyncItem) -> Bool {
        item.status.localizedCaseInsensitiveContains("메일")
            || item.id.hasPrefix("mail-")
            || item.detail.localizedCaseInsensitiveContains("메일")
    }

    private static func loadMailDashboardItems() -> [ServerRelaySyncItem] {
        guard let data = UserDefaults.standard.data(forKey: mailDashboardItemsKey),
              let decoded = try? JSONDecoder().decode([ServerRelaySyncItem].self, from: data) else {
            return []
        }
        return decoded.filter(Self.isMailDashboardItem).map(\.normalizedDashboardItem).dedupedForServerRelay()
    }

    private func persistMailDashboardItems() {
        if mailDashboardItems.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.mailDashboardItemsKey)
            return
        }
        if let data = try? JSONEncoder().encode(mailDashboardItems) {
            UserDefaults.standard.set(data, forKey: Self.mailDashboardItemsKey)
        }
    }

    private func serverRelayPublicText(_ text: String?) -> String {
        let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return ""
        }
        if serverRelayLooksPrivate(value) {
            return ""
        }
        return value
    }

    private func serverRelayPublicLogText(_ text: String?) -> String {
        let value = (text ?? "").klmsDisplayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return ""
        }
        let patterns: [(String, String)] = [
            (#"KAIST 인증 번호:\s*[0-9]{1,3}"#, "KAIST 인증 번호: --"),
            (#"digits=[0-9]{1,3}"#, "digits=--"),
            (#"https?:\/\/klms\.kaist\.ac\.kr\/[^\s"'<>]+"#, "[KLMS URL]"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email]")
        ]
        var redacted = value
        for (pattern, replacement) in patterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        let safeLines = redacted
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !serverRelayLooksPrivateLogLine($0) }
        let tailLines = safeLines.suffix(80)
        let joined = tailLines.joined(separator: "\n")
        guard joined.count > 12_000 else {
            return joined
        }
        return "...\n" + String(joined.suffix(12_000))
    }

    private func serverRelayLooksPrivateLogLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        if lowercased.contains("/users/") || lowercased.contains("/var/folders/") {
            return true
        }
        return line.range(
            of: #"[가-힣A-Za-z0-9_.-]+(로|길)\s*\d{1,4}(\s*-\s*\d{1,4})?"#,
            options: .regularExpression
        ) != nil
    }

    private func serverRelayLooksPrivate(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        if lowercased.contains("/users/") || lowercased.contains("address") || text.contains("주소") {
            return true
        }
        if text.range(of: #"(?<!\d)\d{5}(?!\d)"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"[가-힣A-Za-z0-9_.-]+(로|길)\s*\d{1,4}(\s*-\s*\d{1,4})?"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private func applyServerRelayItemAction(_ action: ServerRelayItemAction) throws -> String {
        switch action.action {
        case .assignmentComplete:
            let item = try serverRelayStateItem(for: action)
            try ManualOverrideStore(url: paths.overridesURL).saveAssignmentStatus(
                "completed",
                for: item,
                currentKey: snapshot.manualOverrides?.assignmentOverrideKey(for: item)
            )
        case .assignmentRestore, .assignmentUnhide:
            let item = try serverRelayStateItem(for: action)
            try ManualOverrideStore(url: paths.overridesURL).saveAssignmentStatus(
                "",
                for: item,
                currentKey: snapshot.manualOverrides?.assignmentOverrideKey(for: item)
            )
        case .assignmentHide:
            let item = try serverRelayStateItem(for: action)
            try ManualOverrideStore(url: paths.overridesURL).saveAssignmentStatus(
                "ignored",
                for: item,
                currentKey: snapshot.manualOverrides?.assignmentOverrideKey(for: item)
            )
        case .examPromote:
            let item = try serverRelayStateItem(for: action)
            var override = snapshot.manualOverrides?.examOverride(for: item) ?? ExamOverride()
            override.status = "approved"
            try ManualOverrideStore(url: paths.overridesURL).saveExamOverride(
                override,
                for: item,
                currentKey: snapshot.manualOverrides?.examOverrideKey(for: item)
            )
        case .examIgnore:
            let item = try serverRelayStateItem(for: action)
            var override = snapshot.manualOverrides?.examOverride(for: item) ?? ExamOverride()
            override.status = "ignored"
            try ManualOverrideStore(url: paths.overridesURL).saveExamOverride(
                override,
                for: item,
                currentKey: snapshot.manualOverrides?.examOverrideKey(for: item)
            )
        case .examRestore:
            let item = try serverRelayStateItem(for: action)
            try ManualOverrideStore(url: paths.overridesURL).saveExamOverride(
                ExamOverride(),
                for: item,
                currentKey: snapshot.manualOverrides?.examOverrideKey(for: item)
            )
        case .noticeRead:
            try NoticeUserStateStore(url: paths.noticeUserStateURL).setRead(true, notice: try serverRelayNotice(for: action))
        case .noticeUnread:
            try NoticeUserStateStore(url: paths.noticeUserStateURL).setRead(false, notice: try serverRelayNotice(for: action))
        case .noticeImportant:
            try NoticeUserStateStore(url: paths.noticeUserStateURL).setImportant(true, notice: try serverRelayNotice(for: action))
        case .noticeUnimportant:
            try NoticeUserStateStore(url: paths.noticeUserStateURL).setImportant(false, notice: try serverRelayNotice(for: action))
        case .noticeHide:
            try NoticeUserStateStore(url: paths.noticeUserStateURL).setHidden(true, notice: try serverRelayNotice(for: action))
        case .noticeUnhide:
            try NoticeUserStateStore(url: paths.noticeUserStateURL).setHidden(false, notice: try serverRelayNotice(for: action))
        case .fileHide:
            try setServerRelayFileHidden(true, for: try serverRelayFile(for: action))
        case .fileUnhide:
            try setServerRelayFileHidden(false, for: try serverRelayFile(for: action))
        case .fileTrash:
            try trashServerRelayFile(try serverRelayFile(for: action))
        case .mailDashboardAdd:
            try applyServerRelayMailDashboardAddAction(action)
        case .mailDashboardRemove:
            applyServerRelayMailDashboardRemoveAction(action)
        case .calendarVerify, .calendarApply, .calendarCreate, .calendarEdit, .calendarDelete:
            throw serverRelayItemActionError("캘린더 요청은 실행 큐에서 처리해야 합니다.")
        }
        reloadSnapshot()
        return "\(action.action.displayName) 반영 완료"
    }

    private func serverRelayCalendarCommand(for action: ServerRelayItemActionKind) -> RemoteCommandKind? {
        switch action {
        case .calendarVerify:
            .verify
        case .calendarApply:
            .coreSync
        case .calendarCreate, .calendarEdit, .calendarDelete:
            nil
        case .mailDashboardAdd, .mailDashboardRemove:
            nil
        default:
            nil
        }
    }

    @discardableResult
    func editCalendarEvent(change: CalendarChange, edit: CalendarEventEdit) async -> Bool {
        do {
            try await updateCalendarEvent(change: change, edit: edit)
            markCalendarChangeResolved(change)
            reloadSnapshot()
            errorMessage = nil
            serverRelayStatusMessage = "캘린더 내용 수정 완료"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func createManualCalendarEvent(title: String, startAt: String, dueAt: String, location: String, notes: String) async {
        do {
            try await createCalendarEvent(title: title, startAt: startAt, dueAt: dueAt, location: location, notes: notes)
            errorMessage = nil
            serverRelayStatusMessage = "메일 일정 등록 완료"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createCalendarEvent(change: CalendarChange, edit: CalendarEventEdit) async -> Bool {
        do {
            try await createCalendarEvent(
                title: edit.title.nilIfBlank ?? change.title,
                startAt: edit.startAt.nilIfBlank ?? change.startAt,
                dueAt: edit.dueAt.nilIfBlank ?? change.dueAt,
                location: edit.location.nilIfBlank ?? change.location,
                notes: "KLMS Sync 캘린더 변경 항목에서 수동 등록"
            )
            markCalendarChangeResolved(change)
            reloadSnapshot()
            errorMessage = nil
            serverRelayStatusMessage = "캘린더 일정 등록 완료"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteCalendarEvent(change: CalendarChange) async -> Bool {
        do {
            try await performCalendarEventDeletion(change: change)
            markCalendarChangeResolved(change)
            reloadSnapshot()
            errorMessage = nil
            serverRelayStatusMessage = "캘린더 일정 삭제 완료"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func openCalendarEvent(change: CalendarChange) async -> Bool {
        do {
            try await openCalendarEventInCalendar(change: change)
            errorMessage = nil
            serverRelayStatusMessage = "캘린더 일정 열기 완료"
            return true
        } catch {
            errorMessage = error.localizedDescription
            openSystemCalendarApp()
            return false
        }
    }

    private func applyServerRelayCalendarEditAction(_ action: ServerRelayItemAction) async throws -> String {
        let edit = try CalendarEventEdit.decodeMessage(action.message)
        let change = try serverRelayCalendarChange(for: action)
        try await updateCalendarEvent(change: change, edit: edit)
        markCalendarChangeResolved(change)
        reloadSnapshot()
        return "캘린더 내용 수정 완료"
    }

    private func applyServerRelayCalendarDeleteAction(_ action: ServerRelayItemAction) async throws -> String {
        let change = try serverRelayCalendarChange(for: action)
        try await performCalendarEventDeletion(change: change)
        markCalendarChangeResolved(change)
        reloadSnapshot()
        return "캘린더 일정 삭제 완료"
    }

    private func applyServerRelayCalendarCreateAction(_ action: ServerRelayItemAction) async throws -> String {
        let edit = try CalendarEventEdit.decodeMessage(action.message)
        try await createCalendarEvent(
            title: edit.title.nilIfBlank ?? action.itemTitle,
            startAt: edit.startAt,
            dueAt: edit.dueAt,
            location: edit.location,
            notes: "iPhone/iPad 메일 내용 자동 판독에서 요청한 수동 일정입니다."
        )
        reloadSnapshot()
        return "캘린더 일정 등록 완료"
    }

    private func serverRelayCalendarChange(for action: ServerRelayItemAction) throws -> CalendarChange {
        for change in snapshot.calendarSyncResult?.changes ?? [] {
            let publicChange = serverRelayCalendarChange(change)
            if publicChange.id == action.itemID || change.id == action.itemID || change.identifier == action.itemID {
                return change
            }
        }
        throw serverRelayItemActionError("대상 캘린더 일정을 현재 결과에서 찾지 못했습니다: \(action.itemTitle)")
    }

    private func applyServerRelaySettingAction(_ action: ServerRelaySettingAction) throws -> String {
        guard let key = EnvKnownKey(rawValue: action.key),
              let definition = Self.serverRelayEditableSettings.first(where: { $0.key == key }) else {
            throw serverRelayItemActionError("원격에서 바꿀 수 없는 설정입니다: \(action.key)")
        }
        let normalizedValue = try normalizedServerRelaySettingValue(action.value, definition: definition)
        var document = try EnvStore(url: paths.configURL).load()
        document.setValue(normalizedValue, for: definition.key)
        try EnvStore(url: paths.configURL).save(document)
        envDocument = document
        return "\(definition.title) 저장 완료"
    }

    private func normalizedServerRelaySettingValue(
        _ value: String,
        definition: ServerRelaySettingDefinition
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch definition.valueKind {
        case .bool:
            let lowercased = trimmed.lowercased()
            if ["1", "true", "yes", "on"].contains(lowercased) {
                return "1"
            }
            if ["0", "false", "no", "off"].contains(lowercased) {
                return "0"
            }
            throw serverRelayItemActionError("\(definition.title)은 켜기/끄기 값만 받을 수 있습니다.")
        case .number:
            guard trimmed.range(of: #"^\d{1,7}$"#, options: .regularExpression) != nil else {
                throw serverRelayItemActionError("\(definition.title)은 초 단위 숫자만 받을 수 있습니다.")
            }
            return trimmed
        case .choice:
            guard definition.options.contains(trimmed) else {
                throw serverRelayItemActionError("\(definition.title)의 허용 값: \(definition.options.joined(separator: ", "))")
            }
            return trimmed
        case .text:
            guard !serverRelayLooksPrivate(trimmed) else {
                throw serverRelayItemActionError("개인정보처럼 보이는 값은 원격 설정으로 저장하지 않습니다.")
            }
            return trimmed
        }
    }

    private func serverRelayStateItem(for action: ServerRelayItemAction) throws -> StateItem {
        guard let content = snapshot.rawLegacyState?.content ?? snapshot.legacyState?.content else {
            throw serverRelayItemActionError("현재 상태 파일에서 과제/시험 데이터를 찾지 못했습니다.")
        }
        let groups: [(String, [StateItem])] = [
            ("assignment", content.assignments),
            ("completedAssignment", content.completedAssignments),
            ("assignmentCandidate", content.assignmentCandidates),
            ("exam", content.examItems),
            ("examCandidate", content.examCandidates),
            ("helpDesk", content.helpDeskItems),
        ]
        for (kind, items) in groups {
            for item in items where serverRelayStateSyncItemID(kind: kind, item: item) == action.itemID {
                return item
            }
        }
        throw serverRelayItemActionError("대상 항목을 현재 상태에서 찾지 못했습니다: \(action.itemTitle)")
    }

    private func serverRelayNotice(for action: ServerRelayItemAction) throws -> NoticeDigestEntry {
        for notice in snapshot.noticeDigest?.notices ?? [] where serverRelayNoticeSyncItemID(notice) == action.itemID {
            return notice
        }
        throw serverRelayItemActionError("대상 공지를 현재 공지 목록에서 찾지 못했습니다: \(action.itemTitle)")
    }

    private func serverRelayFile(for action: ServerRelayItemAction) throws -> CourseFileManifestEntry {
        for file in snapshot.courseFileManifest where serverRelayFileSyncItemID(file) == action.itemID {
            return file
        }
        throw serverRelayItemActionError("대상 파일을 현재 파일 목록에서 찾지 못했습니다: \(action.itemTitle)")
    }

    private func serverRelayFile(forFileAccess request: ServerRelayFileAccessRequest) throws -> CourseFileManifestEntry {
        for file in snapshot.courseFileManifest where serverRelayFileSyncItemID(file) == request.itemID {
            return file
        }
        throw serverRelayItemActionError("대상 파일을 현재 파일 목록에서 찾지 못했습니다: \(request.itemTitle)")
    }

    private func serverRelayLocalFileURL(for entry: CourseFileManifestEntry) throws -> URL {
        var candidates: [URL] = []
        if let absolutePath = entry.absolutePath.nilIfBlank {
            candidates.append(URL(fileURLWithPath: absolutePath))
        }
        if let relativePath = entry.relativePath.nilIfBlank {
            candidates.append(paths.courseFilesURL.appendingPathComponent(relativePath))
        }
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return candidate
            }
        }
        throw serverRelayItemActionError("Mac의 course_files 폴더에서 파일을 찾지 못했습니다: \(entry.filename.nilIfBlank ?? entry.relativePath)")
    }

    private static func serverRelayContentType(for fileURL: URL) -> String {
        let fileExtension = fileURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileExtension.isEmpty,
              let type = UTType(filenameExtension: fileExtension),
              let mimeType = type.preferredMIMEType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mimeType.isEmpty
        else {
            return "application/octet-stream"
        }
        return mimeType
    }

    private func setServerRelayFileHidden(_ hidden: Bool, for entry: CourseFileManifestEntry) throws {
        try AppUserStateStore(url: paths.appUserStateURL).setHidden(
            hidden,
            key: serverRelayFileUserStateKey(entry),
            title: entry.filename.nilIfBlank ?? entry.relativePath,
            course: entry.course,
            path: entry.absolutePath,
            url: entry.url.nilIfBlank ?? entry.sourceURL,
            bucket: .files
        )
    }

    private func trashServerRelayFile(_ entry: CourseFileManifestEntry) throws {
        let fileURL = try serverRelayLocalFileURL(for: entry)
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: &trashedURL)
        try AppUserStateStore(url: paths.appUserStateURL).markTrashed(
            key: serverRelayFileUserStateKey(entry),
            title: entry.filename.nilIfBlank ?? entry.relativePath,
            course: entry.course,
            path: fileURL.path,
            url: entry.url.nilIfBlank ?? entry.sourceURL,
            bucket: .files
        )
    }

    private func serverRelayStateSyncItemID(kind: String, item: StateItem) -> String {
        ServerRelaySyncItem.stableID(
            kind: kind,
            parts: [item.url, item.course, item.title, item.syncDue, item.due]
        )
    }

    private func serverRelayNoticeSyncItemID(_ notice: NoticeDigestEntry) -> String {
        ServerRelaySyncItem.stableID(
            kind: "notice",
            parts: [notice.noticeIdentifier, notice.fingerprint, notice.course, notice.title, notice.postedAt]
        )
    }

    private func serverRelayNoticeIsRead(_ state: NoticeInteractionState?, fingerprint: String) -> Bool {
        guard let state else {
            return false
        }
        if state.readAt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        return !fingerprint.isEmpty && state.readFingerprint == fingerprint
    }

    private func serverRelayFileSyncItemID(_ entry: CourseFileManifestEntry) -> String {
        ServerRelaySyncItem.stableID(
            kind: "file",
            parts: [entry.url, entry.sourceURL, entry.relativePath, entry.filename, entry.course]
        )
    }

    private func serverRelayFileUserStateKey(_ entry: CourseFileManifestEntry) -> String {
        entry.url.nilIfBlank ?? entry.absolutePath.nilIfBlank ?? entry.relativePath
    }

    private func serverRelayItemActionError(_ message: String) -> NSError {
        NSError(
            domain: "KLMSync.ServerRelayItemAction",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func isPastExam(_ item: StateItem) -> Bool {
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

    private func configurePassiveSnapshotRefresh() {
        passiveSnapshotRefreshTask?.cancel()
        passiveSnapshotRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.passiveSnapshotRefreshIntervalNanoseconds)
                guard !Task.isCancelled, let self else {
                    return
                }
                guard self.runningCommand == nil else {
                    continue
                }
                self.reloadSnapshot(showLoginTransition: true)
                self.commandHistory = CommandRunHistoryStore(url: self.paths.appHistoryURL).load()
                self.latestBackup = AppDataBackupManager(paths: self.paths).latestBackup()
            }
        }
    }

    func reloadEngineState() async {
        var refreshError: Error?
        do {
            try loadConfig()
            try mergeConfiguredOverridesIntoCanonicalStore()
        } catch {
            refreshError = error
            if FileManager.default.fileExists(atPath: paths.configURL.path) {
                errorMessage = error.localizedDescription
            }
        }
        let nextSnapshot = EngineSnapshotStore(paths: paths).load()
        applySnapshot(nextSnapshot, showLoginTransition: true)
        commandHistory = CommandRunHistoryStore(url: paths.appHistoryURL).load()
        latestBackup = AppDataBackupManager(paths: paths).latestBackup()
        refreshAppDiagnostics()
        if refreshError == nil {
            errorMessage = nil
        }
    }

    private func mergeConfiguredOverridesIntoCanonicalStore() throws {
        guard let configuredPath = envDocument?.value(for: "OVERRIDES_JSON_PATH"),
              !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let expandedPath = NSString(string: configuredPath).expandingTildeInPath
        let configuredURL = URL(fileURLWithPath: expandedPath)
        guard configuredURL.standardizedFileURL.path != paths.overridesURL.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: configuredURL.path) else {
            return
        }
        _ = try ManualOverrideStore(url: paths.overridesURL).mergeMissingOverrides(from: configuredURL)
    }

    func run(
        _ command: KLMSEngineCommand,
        dryRun: Bool = false,
        environmentOverrides: [String: String] = [:]
    ) async {
        guard runningCommand == nil else { return }
        runningCommand = command
        isCancellingCommand = false
        pendingRunCancellationRequested = false
        errorMessage = nil
        lastCommandResult = nil
        liveCommandOutput = ""
        liveAuthDigits = nil
        authStatusMessage = nil
        lastAuthStatusMessageForRemote = nil
        authStatusClearTask?.cancel()
        authStatusClearTask = nil
        authDigitsSuppressed = false
        notifiedAuthDigits.removeAll()
        notifiedAuthCompletionForCurrentRun = false
        notifiedAlreadyLoggedInForCurrentRun = false
        authDigitsSeenForCurrentRun = false
        lastAuthCompletionAt = nil
        let runStartedAt = Date()
        do {
            try loadConfig()
        } catch {
            errorMessage = error.localizedDescription
        }
        let effectiveEnvironment = appRunEnvironment.merging(environmentOverrides) { _, new in new }
        let skipsNoticeNativeRender = effectiveEnvironment["NOTICE_NATIVE_RENDER_ENABLED"] == "0"
        startRunningCommandStatusPoll(startedAt: runStartedAt)
        await publishServerRelayStatusIfNeeded(force: true)
        defer {
            runningCommandStatusPollTask?.cancel()
            runningCommandStatusPollTask = nil
            runningCommand = nil
            isCancellingCommand = false
            pendingRunCancellationRequested = false
            activeRemoteCommandID = nil
            Task { @MainActor [weak self] in
                await self?.publishServerRelayStatusIfNeeded(force: true)
            }
        }

        do {
            await installEngine(force: false, runDoctorAfterInstall: false)
            try mergeConfiguredOverridesIntoCanonicalStore()
            if pendingRunCancellationRequested {
                appendLiveCommandOutput("\n== 실행 시작 전 중단됨 ==\n")
                let result = KLMSCommandResult(
                    invocation: command.invocation(dryRun: dryRun),
                    startedAt: runStartedAt,
                    finishedAt: Date(),
                    exitCode: 143,
                    standardOutput: liveCommandOutput,
                    standardError: "사용자가 실행 시작 전 중단했습니다.",
                    authDigits: nil,
                    wasCancelled: true
                )
                lastCommandResult = result
                commandHistory = (try? CommandRunHistoryStore(url: paths.appHistoryURL).append(result)) ?? commandHistory
                await clearAuthDigitsState(showAuthenticatedMessage: false)
                errorMessage = nil
                return
            }
            let result = try await runner.run(
                command,
                paths: paths,
                dryRun: dryRun,
                environment: effectiveEnvironment
            ) { [weak self] chunk in
                Task { @MainActor [weak self] in
                    await self?.handleLiveCommandOutput(chunk)
                }
            }
            lastCommandResult = result
            commandHistory = (try? CommandRunHistoryStore(url: paths.appHistoryURL).append(result)) ?? commandHistory
            if result.authChallengeCompleted {
                await clearAuthDigitsState(showAuthenticatedMessage: true, confirmedAuthChallenge: true)
            }
            if result.wasCancelled {
                await clearAuthDigitsState(showAuthenticatedMessage: false)
                errorMessage = nil
            } else if !result.succeeded {
                errorMessage = "\(command.displayName) 실패: 종료 코드 \(result.exitCode)"
            }
            if !dryRun, result.succeeded, command.refreshesSyncReportAfterRun {
                _ = try? await runner.run(.report, paths: paths, environment: effectiveEnvironment)
            }
            if !dryRun, result.succeeded, command.refreshesVerificationAfterRun, skipsNoticeNativeRender {
                appendLiveCommandOutput("\n== 연동 상태 검사 skipped: 공지 메모 업데이트 꺼짐 ==\n")
            } else if !dryRun, result.succeeded, command.refreshesVerificationAfterRun {
                appendLiveCommandOutput("\n== 연동 상태 검사 start ==\n")
                let verifyResult = try await runner.run(
                    .verify,
                    paths: paths,
                    environment: effectiveEnvironment
                ) { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        await self?.handleLiveCommandOutput(chunk)
                    }
                }
                commandHistory = (try? CommandRunHistoryStore(url: paths.appHistoryURL).append(verifyResult)) ?? commandHistory
                appendLiveCommandOutput("== 연동 상태 검사 finish status=\(verifyResult.exitCode) ==\n")
                if !verifyResult.succeeded {
                    errorMessage = "동기화는 끝났지만 메모/캘린더/미리 알림 상태 검사에 실패했습니다."
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        await reloadEngineState()
    }

    func cancelRunningCommand() async {
        guard runningCommand != nil else { return }
        guard !isCancellingCommand else { return }
        isCancellingCommand = true
        pendingRunCancellationRequested = true
        let requested = await runner.cancelCurrentCommand()
        if requested {
            appendLiveCommandOutput("\n== 사용자가 동기화 중단을 요청했습니다 ==\n")
        } else {
            appendLiveCommandOutput("\n== 동기화 중단 요청을 기록했습니다 ==\n")
        }
    }

    func cancelCommandBeforeTermination() async {
        passiveSnapshotRefreshTask?.cancel()
        runningCommandStatusPollTask?.cancel()
        authStatusClearTask?.cancel()
        pasteboardClearTask?.cancel()
        guard runningCommand != nil else { return }
        isCancellingCommand = true
        _ = await runner.cancelCurrentCommand()
        try? await Task.sleep(nanoseconds: 2_300_000_000)
    }

    func runReportRefresh() async {
        await run(.report)
    }

    func configValue(_ key: EnvKnownKey) -> String {
        envDocument?.value(for: key) ?? ""
    }

    func boolConfigValue(_ key: EnvKnownKey, default defaultValue: Bool = false) -> Bool {
        envDocument?.boolValue(for: key, default: defaultValue) ?? defaultValue
    }

    private func runtimeConfigValue(_ key: EnvKnownKey, default defaultValue: String) -> String {
        let value = envDocument?.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultValue : value
    }

    private func runtimeOptionalConfigValue(_ key: EnvKnownKey) -> String? {
        let value = envDocument?.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func runtimeBoolConfigValue(_ key: EnvKnownKey, default defaultValue: Bool) -> String {
        let value = envDocument?.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if ["1", "true", "yes", "on"].contains(value) {
            return "1"
        }
        if ["0", "false", "no", "off"].contains(value) {
            return "0"
        }
        return defaultValue ? "1" : "0"
    }

    func setConfigValue(_ value: String, for key: EnvKnownKey) {
        do {
            var document = envDocument ?? EnvDocument(text: "")
            document.setValue(value, for: key)
            try EnvStore(url: paths.configURL).save(document)
            envDocument = document
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setBoolConfigValue(_ value: Bool, for key: EnvKnownKey) {
        setConfigValue(value ? "1" : "0", for: key)
    }

    func setAssignmentOverride(_ status: String, for item: StateItem) {
        do {
            try ManualOverrideStore(url: paths.overridesURL).saveAssignmentStatus(
                status,
                for: item,
                currentKey: snapshot.manualOverrides?.assignmentOverrideKey(for: item)
            )
            reloadSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setAssignmentHidden(_ isHidden: Bool, for item: StateItem) {
        let current = snapshot.manualOverrides?.assignmentStatus(for: item) ?? ""
        let next = isHidden ? "ignored" : (current == "ignored" ? "" : current)
        setAssignmentOverride(next, for: item)
    }

    func setExamOverride(_ override: ExamOverride, for item: StateItem) {
        do {
            let currentKey = snapshot.manualOverrides?.examOverrideKey(for: item)
            try ManualOverrideStore(url: paths.overridesURL).saveExamOverride(
                override,
                for: item,
                currentKey: currentKey
            )
            reloadSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setExamHidden(_ isHidden: Bool, for item: StateItem) {
        var override = snapshot.manualOverrides?.examOverride(for: item) ?? ExamOverride()
        if isHidden {
            override.status = "ignored"
        } else if override.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ignored" {
            override.status = ""
        }
        setExamOverride(override, for: item)
    }

    func setNoticeRead(_ isRead: Bool, for notice: NoticeDigestEntry) {
        do {
            try NoticeUserStateStore(url: paths.noticeUserStateURL).setRead(isRead, notice: notice)
            reloadSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setNoticeHidden(_ isHidden: Bool, for notice: NoticeDigestEntry) {
        do {
            try NoticeUserStateStore(url: paths.noticeUserStateURL).setHidden(isHidden, notice: notice)
            reloadSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setNoticeImportant(_ isImportant: Bool, for notice: NoticeDigestEntry) {
        do {
            try NoticeUserStateStore(url: paths.noticeUserStateURL).setImportant(isImportant, notice: notice)
            reloadSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setFileHidden(_ isHidden: Bool, key: String, title: String, course: String, path: String, url sourceURL: String) {
        do {
            try AppUserStateStore(url: paths.appUserStateURL).setHidden(
                isHidden,
                key: key,
                title: title,
                course: course,
                path: path,
                url: sourceURL,
                bucket: .files
            )
            reloadSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setQuarantineIgnored(_ isIgnored: Bool, key: String, title: String, path: String, url sourceURL: String) {
        do {
            try AppUserStateStore(url: paths.appUserStateURL).setIgnored(
                isIgnored,
                key: key,
                title: title,
                course: "격리",
                path: path,
                url: sourceURL,
                bucket: .quarantine
            )
            reloadSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveFileToTrash(
        key: String,
        title: String,
        course: String,
        path: String,
        url sourceURL: String,
        bucket: AppUserStateStore.Bucket
    ) {
        do {
            let fileURL = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: fileURL, resultingItemURL: &trashedURL)
            }
            try AppUserStateStore(url: paths.appUserStateURL).markTrashed(
                key: key,
                title: title,
                course: course,
                path: path,
                url: sourceURL,
                bucket: bucket
            )
            reloadSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openEngineFolder() {
        NSWorkspace.shared.open(paths.engineRoot)
    }

    func openLogsFolder() {
        NSWorkspace.shared.open(paths.logsURL)
    }

    func openAutomationSettings() {
        openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    func openAccessibilitySettings() {
        openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func requestAppPermissions() async {
        await requestAppPermissions(markAutomatic: false)
    }

    private func requestAppPermissions(markAutomatic: Bool) async {
        permissionStatusMessage = "권한 요청 중..."
        permissionProbeRows = [
            KLMSPermissionProbeRow(
                id: "permission-running",
                title: "권한 점검",
                value: "진행 중",
                detail: "앱 본체, 엔진 실행 경로, 공지 메모 렌더러 권한을 차례대로 확인합니다.",
                isWarning: false
            )
        ]
        NSApp.activate(ignoringOtherApps: true)
        await Task.yield()

        let helperPath = nativeNoticeHelperPath
        let permissionEnvironment = appRunEnvironment
        let engineRoot = paths.engineRoot
        let accessibilityTrusted = Self.requestAccessibilityPermissionPrompt()
        async let nativeNoticeHelperProbeTask: PermissionProbeResult = Task.detached {
            Self.runNativeNoticeHelperPermissionProbe(
                helperPath: helperPath,
                environment: permissionEnvironment
            )
        }.value
        async let notificationGranted = requestNotificationPermission()
        async let calendarGranted = requestCalendarPermission()
        async let remindersGranted = requestRemindersPermission()
        async let engineAutomationStatusTask: [PermissionProbeResult] = Task.detached {
            Self.runEngineAutomationPermissionProbes(
                engineRoot: engineRoot,
                environment: permissionEnvironment
            )
        }.value

        let notificationStatus = await notificationGranted
        let calendarStatus = await calendarGranted
        let remindersStatus = await remindersGranted
        let appAutomationStatus = Self.runAutomationPermissionProbes()
        let nativeNoticeHelperProbe = await nativeNoticeHelperProbeTask
        let engineAutomationStatus = await engineAutomationStatusTask

        let appAutomationAllowed = appAutomationStatus.filter(\.ok).count
        let engineAutomationAllowed = engineAutomationStatus.filter(\.ok).count
        let missingRequiredPermissions = Self.requiredPermissionFailures(
            accessibilityTrusted: accessibilityTrusted,
            nativeNoticeHelperProbe: nativeNoticeHelperProbe,
            calendarStatus: calendarStatus,
            remindersStatus: remindersStatus,
            appAutomationStatus: appAutomationStatus,
            engineAutomationStatus: engineAutomationStatus
        )
        let requiredPermissionsGranted = missingRequiredPermissions.isEmpty
        if markAutomatic, let version = payload?.version, !version.isEmpty {
            UserDefaults.standard.set(version, forKey: Self.automaticPermissionRequestVersionKey)
        }
        let summary = [
            "손쉬운 사용 \(accessibilityTrusted ? "허용됨" : "설정 필요")",
            "공지 렌더러 \(nativeNoticeHelperProbe.ok ? "허용됨" : "설정 필요")",
            "알림 \(notificationStatus ? "허용됨" : "설정 필요")",
            "캘린더 \(calendarStatus ? "허용됨" : "설정 필요")",
            "미리 알림 \(remindersStatus ? "허용됨" : "설정 필요")",
            "앱 자동화 \(appAutomationAllowed)/\(appAutomationStatus.count)",
            "엔진 자동화 \(engineAutomationAllowed)/\(engineAutomationStatus.count)",
        ].joined(separator: " · ")
        permissionProbeRows = Self.permissionRows(
            accessibilityTrusted: accessibilityTrusted,
            nativeNoticeHelperProbe: nativeNoticeHelperProbe,
            notificationStatus: notificationStatus,
            calendarStatus: calendarStatus,
            remindersStatus: remindersStatus,
            appAutomationStatus: appAutomationStatus,
            engineAutomationStatus: engineAutomationStatus
        )
        let prefix = requiredPermissionsGranted
            ? (markAutomatic ? "초기 권한 요청 완료" : "권한 요청 완료")
            : "권한 설정 필요"
        let missingText = requiredPermissionsGranted ? "" : " · 누락: \(missingRequiredPermissions.joined(separator: ", "))"
        permissionStatusMessage = "\(prefix): \(summary)\(missingText)"
    }

    func createBackup() {
        do {
            latestBackup = try AppDataBackupManager(paths: paths).createBackup()
            errorMessage = "백업 생성 완료: \(latestBackup?.id ?? "")"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreLatestBackup() async {
        do {
            guard let restored = try AppDataBackupManager(paths: paths).restoreLatestBackup() else {
                errorMessage = "복구할 백업이 없습니다."
                return
            }
            latestBackup = restored
            errorMessage = "백업 복구 완료: \(restored.id)"
            await reloadEngineState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openNoticeNote(_ state: NoticeNoteRenderState?, fallbackTitle: String) {
        guard let state else {
            errorMessage = "\(fallbackTitle) 작성 기록이 아직 없습니다."
            return
        }
        let noteID = state.noteID.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteTitle = (state.noteTitle.isEmpty ? fallbackTitle : state.noteTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !noteID.isEmpty || !noteTitle.isEmpty else {
            errorMessage = "\(fallbackTitle) 메모 ID를 찾지 못했습니다."
            return
        }

        let script = Self.openNotesScript(noteID: noteID, noteTitle: noteTitle)
        var errorInfo: NSDictionary?
        if NSAppleScript(source: script)?.executeAndReturnError(&errorInfo) == nil {
            errorMessage = appleScriptErrorMessage(errorInfo) ?? "\(fallbackTitle) 메모 열기 실패"
        }
    }

    func processServerRelayCommands(silent: Bool = false) async {
        guard serverRelayEnabled else {
            return
        }
        if runningCommand != nil {
            if let store = try? makeServerRelayStore() {
                await processServerRelayCancelRequest(store: store, silent: silent)
            }
            await publishServerRelayStatusIfNeeded()
            return
        }
        guard !isCheckingRemoteCommands else {
            return
        }
        isCheckingRemoteCommands = true
        defer {
            isCheckingRemoteCommands = false
        }
        do {
            let store = try makeServerRelayStore()
            await publishServerRelayStatusIfNeeded()
            let inbox = try await store.fetchWorkerInbox(
                since: runningCommand == nil ? serverRelayLastInboxUpdatedAt : nil,
                waitSeconds: 0
            )
            serverRelayLastInboxUpdatedAt = inbox.statusResponse.updatedAt
            serverRelayRecentRequestLog = inbox.recentRequestLog
            serverRelayRecentFileAccessRequests = inbox.recentFileAccessRequests
            if let syncData = try? await store.fetchSyncData(limit: 1) {
                serverRelaySharedRunLogs = syncData.runLogs
            }
            let pendingFileRequests = inbox.pendingFileAccessRequests
            if let fileRequest = pendingFileRequests.first {
                var runningRequest = fileRequest
                runningRequest.status = .running
                runningRequest.updatedAt = Date()
                runningRequest.message = "Mac에서 파일을 준비하는 중"
                try await store.updateFileAccessRequest(runningRequest)
                recordServerRelayFileAccessRequest(runningRequest)
                serverRelayStatusMessage = "파일 요청 처리 중: \(runningRequest.itemTitle.nilIfBlank ?? "파일")"
                remoteProcessingStatusMessage = serverRelayStatusMessage
                await notifyServerRelayFileAccess(
                    runningRequest,
                    title: "파일 요청 처리 중",
                    body: "\(runningRequest.itemTitle.nilIfBlank ?? "요청한 파일") 링크를 준비하고 있습니다.",
                    sound: false
                )

                do {
                    let entry = try serverRelayFile(forFileAccess: runningRequest)
                    let fileURL = try serverRelayLocalFileURL(for: entry)
                    let uploaded = try await store.uploadFileAccessRequest(
                        runningRequest,
                        fileURL: fileURL,
                        filename: entry.filename.nilIfBlank ?? fileURL.lastPathComponent,
                        contentType: Self.serverRelayContentType(for: fileURL)
                    )
                    recordServerRelayFileAccessRequest(uploaded)
                    serverRelayStatusMessage = "파일 링크 준비 완료: \(uploaded.itemTitle)"
                    remoteProcessingStatusMessage = serverRelayStatusMessage
                    await notifyServerRelayFileAccess(
                        uploaded,
                        title: "파일 링크 준비 완료",
                        body: "\(uploaded.itemTitle.nilIfBlank ?? "요청한 파일")을 iPhone/Windows에서 열 수 있습니다.",
                        sound: true
                    )
                    try await store.publishStatus(
                        sanitizedRemoteStatus(snapshot: snapshot, phase: "idle"),
                        latestCommand: lastRemoteCommand,
                        running: false,
                        message: serverRelayStatusMessage ?? ""
                    )
                } catch {
                    var failedRequest = runningRequest
                    failedRequest.status = .failed
                    failedRequest.updatedAt = Date()
                    failedRequest.message = error.localizedDescription
                    try await store.updateFileAccessRequest(failedRequest)
                    recordServerRelayFileAccessRequest(failedRequest)
                    serverRelayStatusMessage = "파일 링크 준비 실패: \(error.localizedDescription)"
                    remoteProcessingStatusMessage = serverRelayStatusMessage
                    await notifyServerRelayFileAccess(
                        failedRequest,
                        title: "파일 링크 준비 실패",
                        body: failedRequest.message.nilIfBlank ?? "Mac에서 요청한 파일을 준비하지 못했습니다.",
                        sound: true
                    )
                    if !silent {
                        errorMessage = failedRequest.message
                    }
                }
                return
            }
            let pendingSettingActions = inbox.pendingSettingActions
            if let settingAction = pendingSettingActions.first {
                var runningAction = settingAction
                runningAction.status = .running
                runningAction.updatedAt = Date()
                runningAction.message = "\(settingAction.title.nilIfBlank ?? settingAction.key) 설정 저장 중"
                try await store.updateSettingAction(runningAction)

                var completedAction = runningAction
                do {
                    completedAction.message = try applyServerRelaySettingAction(runningAction)
                    completedAction.status = .completed
                } catch {
                    completedAction.message = error.localizedDescription
                    completedAction.status = .failed
                }
                completedAction.updatedAt = Date()
                try await store.updateSettingAction(completedAction)

                let refreshedSnapshot = EngineSnapshotStore(paths: paths).load()
                snapshot = refreshedSnapshot
                try await store.publishStatus(
                    sanitizedRemoteStatus(snapshot: refreshedSnapshot, phase: "idle"),
                    latestCommand: lastRemoteCommand,
                    running: false,
                    message: completedAction.message
                )
                try await store.publishSyncData(serverRelaySyncData(from: refreshedSnapshot))
                serverRelayStatusMessage = "\(completedAction.title.nilIfBlank ?? completedAction.key) · \(completedAction.status.displayName)"
                remoteProcessingStatusMessage = serverRelayStatusMessage
                if !silent, completedAction.status == .failed {
                    errorMessage = completedAction.message
                }
                return
            }
            let pendingActions = inbox.pendingItemActions
            if let action = pendingActions.first {
                var runningAction = action
                runningAction.status = .running
                runningAction.updatedAt = Date()
                if action.action != .mailDashboardAdd {
                    runningAction.message = "\(action.action.displayName) 처리 중"
                }
                try await store.updateItemAction(runningAction)

                var completedAction = runningAction
                do {
                    if runningAction.action == .calendarCreate {
                        serverRelayStatusMessage = "서버 요청 처리 중: \(runningAction.action.displayName)"
                        remoteProcessingStatusMessage = serverRelayStatusMessage
                        completedAction.message = try await applyServerRelayCalendarCreateAction(runningAction)
                        completedAction.status = .completed
                    } else if runningAction.action == .calendarEdit {
                        serverRelayStatusMessage = "서버 요청 처리 중: \(runningAction.action.displayName)"
                        remoteProcessingStatusMessage = serverRelayStatusMessage
                        completedAction.message = try await applyServerRelayCalendarEditAction(runningAction)
                        completedAction.status = .completed
                    } else if runningAction.action == .calendarDelete {
                        serverRelayStatusMessage = "서버 요청 처리 중: \(runningAction.action.displayName)"
                        remoteProcessingStatusMessage = serverRelayStatusMessage
                        completedAction.message = try await applyServerRelayCalendarDeleteAction(runningAction)
                        completedAction.status = .completed
                    } else if let commandKind = serverRelayCalendarCommand(for: runningAction.action) {
                        serverRelayStatusMessage = "서버 요청 처리 중: \(runningAction.action.displayName)"
                        remoteProcessingStatusMessage = serverRelayStatusMessage
                        await run(commandKind.engineCommand)
                        completedAction.status = lastCommandResult?.succeeded == true ? .completed : .failed
                        completedAction.message = completedAction.status == .completed
                            ? "\(runningAction.action.displayName) 완료"
                            : (lastCommandResult?.combinedOutput.nilIfBlank ?? "\(runningAction.action.displayName) 실패")
                    } else {
                        completedAction.message = try applyServerRelayItemAction(runningAction)
                        completedAction.status = .completed
                    }
                } catch {
                    completedAction.message = error.localizedDescription
                    completedAction.status = .failed
                }
                completedAction.updatedAt = Date()
                try await store.updateItemAction(completedAction)

                let refreshedSnapshot = EngineSnapshotStore(paths: paths).load()
                snapshot = refreshedSnapshot
                try await store.publishStatus(
                    sanitizedRemoteStatus(snapshot: refreshedSnapshot, phase: "idle"),
                    latestCommand: lastRemoteCommand,
                    running: false,
                    message: completedAction.message
                )
                try await store.publishSyncData(serverRelaySyncData(from: refreshedSnapshot))
                serverRelayStatusMessage = "\(completedAction.action.displayName) · \(completedAction.status.displayName)"
                remoteProcessingStatusMessage = serverRelayStatusMessage
                if !silent, completedAction.status == .failed {
                    errorMessage = completedAction.message
                }
                return
            }
            let pending = inbox.pendingCommands
            let now = Date()
            let cancelRequest = inbox.cancelRequest
            if try await processServerRelayPendingCancelRequest(
                store: store,
                cancelRequest: cancelRequest,
                pending: pending,
                now: now
            ) {
                return
            }
            var commandToRun: RemoteRunCommand?
            for command in pending {
                if command.isStaleForExecution(now: now) {
                    var stale = command
                    stale.status = .macUnavailable
                    stale.updatedAt = now
                    stale.summary = sanitizedRemoteStatus(
                        snapshot: snapshot,
                        phase: stale.status.rawValue
                    )
                    try? await store.update(stale)
                    lastRemoteCommand = stale
                    continue
                }
                commandToRun = command
                break
            }
            guard let command = commandToRun else {
                serverRelayStatusMessage = "대기 중인 서버 요청이 없습니다."
                if !silent {
                    errorMessage = serverRelayStatusMessage
                }
                return
            }

            var running = command
            running.status = .running
            running.updatedAt = Date()
            running.summary = sanitizedRemoteStatus(snapshot: snapshot, phase: "running")
            try await store.update(running)
            lastRemoteCommand = running
            activeRemoteCommandID = running.id
            serverRelayStatusMessage = "서버 요청 처리 중: \(running.kind.displayName)"
            remoteProcessingStatusMessage = serverRelayStatusMessage

            await run(
                command.kind.engineCommand,
                dryRun: command.options.dryRun,
                environmentOverrides: remoteRunEnvironmentOverrides(for: command)
            )
            if activeRemoteCommandID == running.id {
                activeRemoteCommandID = nil
            }
            let refreshedSnapshot = EngineSnapshotStore(paths: paths).load()
            var completed = running
            completed.status = lastCommandResult?.succeeded == true ? .completed : .failed
            completed.updatedAt = Date()
            completed.lastExitCode = lastCommandResult.map { Int($0.exitCode) }
            completed.summary = sanitizedRemoteStatus(snapshot: refreshedSnapshot, phase: completed.status.rawValue)
            if lastCommandResult?.wasCancelled == true {
                completed.summary.phaseDetail = "사용자가 실행을 중단"
            }
            completed.loginRequired = lastCommandResult?.requiresLoginApproval == true || completed.summary.loginRequired
            try await store.update(completed)
            try await store.publishSyncData(serverRelaySyncData(from: refreshedSnapshot))
            lastRemoteCommand = completed
            serverRelayStatusMessage = "최근 서버 요청: \(completed.kind.displayName) · \(completed.status.displayName)"
            remoteProcessingStatusMessage = serverRelayStatusMessage
            try await store.publishStatus(
                completed.summary,
                latestCommand: completed,
                running: false,
                message: serverRelayStatusMessage ?? ""
            )
        } catch {
            serverRelayStatusMessage = "서버 요청 확인 실패: \(error.localizedDescription)"
            if !silent {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func processServerRelayCancelRequest(store: ServerRelayCommandStore, silent: Bool) async {
        do {
            let cancelRequest = try await store.fetchCancelRequest()
            guard cancelRequest.requested else {
                return
            }
            guard let commandID = cancelRequest.commandID else {
                _ = try await store.clearCancelRequest()
                serverRelayStatusMessage = "명령 ID가 없는 중단 요청을 무시했습니다."
                remoteProcessingStatusMessage = serverRelayStatusMessage
                return
            }
            let currentRemoteCommandID = activeRemoteCommandID ?? lastRemoteCommand?.id
            guard commandID == currentRemoteCommandID else {
                serverRelayStatusMessage = "현재 실행과 다른 중단 요청을 무시했습니다."
                remoteProcessingStatusMessage = serverRelayStatusMessage
                return
            }
            serverRelayStatusMessage = cancelRequest.message.nilIfBlank ?? "원격 실행 중단 요청을 받았습니다."
            remoteProcessingStatusMessage = serverRelayStatusMessage
            await cancelRunningCommand()
            _ = try await store.clearCancelRequest()
            try await store.publishStatus(
                sanitizedRemoteStatus(snapshot: snapshot, phase: "running"),
                latestCommand: lastRemoteCommand,
                running: true,
                message: serverRelayStatusMessage ?? ""
            )
        } catch {
            if !silent {
                errorMessage = "원격 실행 중단 확인 실패: \(error.localizedDescription)"
            }
        }
    }

    private func processServerRelayPendingCancelRequest(
        store: ServerRelayCommandStore,
        cancelRequest: ServerRelayCancelRequest,
        pending: [RemoteRunCommand],
        now: Date
    ) async throws -> Bool {
        guard cancelRequest.requested else {
            return false
        }
        guard let commandID = cancelRequest.commandID else {
            _ = try await store.clearCancelRequest()
            serverRelayStatusMessage = "명령 ID가 없는 중단 요청을 무시했습니다."
            remoteProcessingStatusMessage = serverRelayStatusMessage
            return false
        }
        guard let command = pending.first(where: { $0.id == commandID }) else {
            _ = try await store.clearCancelRequest()
            serverRelayStatusMessage = "이미 끝났거나 찾을 수 없는 중단 요청을 정리했습니다."
            remoteProcessingStatusMessage = serverRelayStatusMessage
            return false
        }

        var cancelled = command
        cancelled.status = .cancelled
        cancelled.updatedAt = now
        cancelled.lastExitCode = nil
        cancelled.loginRequired = false
        cancelled.summary = sanitizedRemoteStatus(snapshot: snapshot, phase: cancelled.status.rawValue)
        cancelled.summary.phaseDetail = "사용자가 실행 전 중단"
        try await store.update(cancelled)
        _ = try await store.clearCancelRequest()
        lastRemoteCommand = cancelled
        serverRelayStatusMessage = "\(cancelled.kind.displayName) 요청을 실행 전에 중단했습니다."
        remoteProcessingStatusMessage = serverRelayStatusMessage
        try await store.publishStatus(
            cancelled.summary,
            latestCommand: cancelled,
            running: false,
            message: serverRelayStatusMessage ?? ""
        )
        return true
    }

    private func remoteRunEnvironmentOverrides(for command: RemoteRunCommand) -> [String: String] {
        guard !command.options.updateNoticeNotes else {
            return [:]
        }
        switch command.kind {
        case .fullSync, .noticeSync:
            return ["NOTICE_NATIVE_RENDER_ENABLED": "0"]
        case .coreSync, .filesSync, .verify, .doctor, .report, .v2BuildState:
            return [:]
        }
    }

    private func loadConfig() throws {
        envDocument = try EnvStore(url: paths.configURL).load()
    }

    private func refreshAppDiagnostics() {
        let diagnostics = KLMSAppDiagnostics.collect(
            bundleURL: Bundle.main.bundleURL,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            paths: paths,
            payloadVersion: payload?.version
        )
        appDiagnostics = diagnostics
    }

    private func openSystemSettingsPane(_ text: String) {
        guard let url = URL(string: text) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func requestAccessibilityPermissionPrompt() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    nonisolated private static func runNativeNoticeHelperPermissionProbe(
        helperPath: String,
        environment: [String: String]
    ) -> PermissionProbeResult {
        let helperURL = URL(fileURLWithPath: helperPath)
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return PermissionProbeResult(
                name: "공지 렌더러",
                ok: false,
                detail: "헬퍼 실행 파일을 찾지 못했습니다: \(helperURL.path)"
            )
        }
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--permission-probe"]
        process.environment = KLMSCommandRunner.processEnvironmentForLaunch(
            base: ProcessInfo.processInfo.environment,
            overrides: environment
        )
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return PermissionProbeResult(
                name: "공지 렌더러",
                ok: process.terminationStatus == 0,
                detail: text.isEmpty ? "헬퍼 권한 probe 종료 코드 \(process.terminationStatus)" : text
            )
        } catch {
            return PermissionProbeResult(
                name: "공지 렌더러",
                ok: false,
                detail: "헬퍼 권한 probe 실행 실패: \(error.localizedDescription)"
            )
        }
    }

    private func requestNotificationPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    private func requestCalendarPermission() async -> Bool {
        let store = EKEventStore()
        if #available(macOS 14.0, *) {
            return await withCheckedContinuation { continuation in
                store.requestFullAccessToEvents { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            return await withCheckedContinuation { continuation in
                store.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func updateCalendarEvent(change: CalendarChange, edit: CalendarEventEdit) async throws {
        guard !edit.isEmpty else {
            throw serverRelayItemActionError("수정할 캘린더 내용이 없습니다.")
        }
        guard await requestCalendarPermission() else {
            throw serverRelayItemActionError("Calendar 수정 권한이 필요합니다. 시스템 설정에서 KLMS Sync의 Calendar 권한을 허용해 주세요.")
        }

        let store = EKEventStore()
        let event = try findCalendarEvent(change: change, store: store)
        let trimmedTitle = edit.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStart = edit.startAt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDue = edit.dueAt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocation = edit.location.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedTitle.isEmpty {
            event.title = trimmedTitle
        }
        if !trimmedStart.isEmpty {
            guard let startDate = parseCalendarEditDate(trimmedStart) else {
                throw serverRelayItemActionError("시작 시간을 해석할 수 없습니다: \(trimmedStart)")
            }
            event.startDate = startDate
        }
        if !trimmedDue.isEmpty {
            guard let endDate = parseCalendarEditDate(trimmedDue) else {
                throw serverRelayItemActionError("종료 시간을 해석할 수 없습니다: \(trimmedDue)")
            }
            event.endDate = endDate
        }
        if let startDate = event.startDate, let endDate = event.endDate, endDate < startDate {
            throw serverRelayItemActionError("종료 시간이 시작 시간보다 빠릅니다.")
        }
        if !trimmedLocation.isEmpty {
            event.location = trimmedLocation
        }

        try store.save(event, span: .thisEvent, commit: true)
    }

    private func performCalendarEventDeletion(change: CalendarChange) async throws {
        guard await requestCalendarPermission() else {
            throw serverRelayItemActionError("Calendar 삭제 권한이 필요합니다. 시스템 설정에서 KLMS Sync의 Calendar 권한을 허용해 주세요.")
        }
        let store = EKEventStore()
        let event = try findCalendarEvent(change: change, store: store)
        try store.remove(event, span: .thisEvent, commit: true)
    }

    private func openCalendarEventInCalendar(change: CalendarChange) async throws {
        guard await requestCalendarPermission() else {
            throw serverRelayItemActionError("Calendar 열기 권한이 필요합니다. 시스템 설정에서 KLMS Sync의 Calendar 권한을 허용해 주세요.")
        }
        let store = EKEventStore()
        let event = try findCalendarEvent(change: change, store: store)
        let calendarName = event.calendar.title
        let eventID = event.calendarItemIdentifier
        let script = """
        tell application id "com.apple.iCal"
          activate
          show event id "\(appleScriptString(eventID))" of calendar "\(appleScriptString(calendarName))"
        end tell
        """
        var errorInfo: NSDictionary?
        guard NSAppleScript(source: script)?.executeAndReturnError(&errorInfo) != nil else {
            let message = (errorInfo?[NSAppleScript.errorMessage] as? String)
                ?? "Calendar 앱에서 해당 일정을 선택하지 못했습니다."
            throw serverRelayItemActionError(message)
        }
    }

    private func createCalendarEvent(title: String, startAt: String, dueAt: String, location: String, notes: String) async throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStart = startAt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDue = dueAt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty else {
            throw serverRelayItemActionError("일정 제목이 필요합니다.")
        }
        guard let startDate = parseCalendarEditDate(trimmedStart) else {
            throw serverRelayItemActionError("시작 시간을 해석할 수 없습니다. 예: 2026-06-17 13:00")
        }
        let endDate: Date
        if trimmedDue.isEmpty {
            endDate = startDate.addingTimeInterval(60 * 60)
        } else {
            guard let parsedEndDate = parseCalendarEditDate(trimmedDue) else {
                throw serverRelayItemActionError("종료 시간을 해석할 수 없습니다. 예: 2026-06-17 14:00")
            }
            endDate = parsedEndDate
        }
        guard endDate >= startDate else {
            throw serverRelayItemActionError("종료 시간이 시작 시간보다 빠릅니다.")
        }
        guard await requestCalendarPermission() else {
            throw serverRelayItemActionError("Calendar 등록 권한이 필요합니다. 시스템 설정에서 KLMS Sync의 Calendar 권한을 허용해 주세요.")
        }

        let store = EKEventStore()
        guard let calendar = store.defaultCalendarForNewEvents ?? store.calendars(for: .event).first(where: { $0.allowsContentModifications }) else {
            throw serverRelayItemActionError("일정을 추가할 수 있는 Calendar를 찾지 못했습니다.")
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = trimmedTitle
        event.startDate = startDate
        event.endDate = endDate
        if !trimmedLocation.isEmpty {
            event.location = trimmedLocation
        }
        event.notes = [
            "KLMS Sync 메일 붙여넣기에서 수동 등록",
            trimmedNotes,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
        try store.save(event, span: .thisEvent, commit: true)
    }

    private func findCalendarEvent(change: CalendarChange, store: EKEventStore) throws -> EKEvent {
        let calendars = store.calendars(for: .event)
        let matchingCalendars = calendars.filter { calendar in
            change.calendar.nilIfBlank.map { calendar.title == $0 } ?? true
        }
        let scopedCalendars = matchingCalendars.isEmpty ? nil : matchingCalendars
        let parsedDates = [change.startAt, change.dueAt].compactMap(parseCalendarEditDate)
        let startWindow = (parsedDates.min() ?? Date()).addingTimeInterval(-60 * 60 * 24 * 45)
        let endWindow = (parsedDates.max() ?? Date()).addingTimeInterval(60 * 60 * 24 * 365 * 3)
        let predicate = store.predicateForEvents(withStart: startWindow, end: endWindow, calendars: scopedCalendars)
        let events = store.events(matching: predicate)

        if let identifier = change.identifier.nilIfBlank {
            let markerNeedles = [
                "KLMS_SYNC_ITEM_ID:\(identifier)",
                "KLMS_ASSIGN_ID:\(identifier)",
            ]
            if let event = events.first(where: { event in
                let notes = event.notes ?? ""
                return markerNeedles.contains(where: { notes.contains($0) })
            }) {
                return event
            }
        }

        let normalizedTitle = normalizeCalendarLookupText(change.title)
        let targetStart = parseCalendarEditDate(change.startAt)
        if !normalizedTitle.isEmpty,
           let event = events.first(where: { event in
               normalizeCalendarLookupText(event.title) == normalizedTitle
                   && calendarDate(event.startDate, isCloseTo: targetStart)
           }) {
            return event
        }

        throw serverRelayItemActionError("Calendar에서 수정할 일정을 찾지 못했습니다. 먼저 과제/시험 동기화로 캘린더 상태를 다시 맞춰 주세요.")
    }

    private func calendarDate(_ lhs: Date?, isCloseTo rhs: Date?) -> Bool {
        guard let lhs, let rhs else {
            return true
        }
        return abs(lhs.timeIntervalSince(rhs)) <= 60 * 10
    }

    private func normalizeCalendarLookupText(_ text: String?) -> String {
        (text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    private func appleScriptString(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func openSystemCalendarApp() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.open(appURL)
        }
    }

    private func parseCalendarEditDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: trimmed) {
            return date
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    private func requestRemindersPermission() async -> Bool {
        let store = EKEventStore()
        if #available(macOS 14.0, *) {
            return await withCheckedContinuation { continuation in
                store.requestFullAccessToReminders { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            return await withCheckedContinuation { continuation in
                store.requestAccess(to: .reminder) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private static func runAutomationPermissionProbes() -> [PermissionProbeResult] {
        let probes: [(name: String, script: String)] = [
            ("Safari", #"tell application id "com.apple.Safari" to get name"#),
            ("Notes", #"tell application id "com.apple.Notes" to get name"#),
            ("System Events", #"tell application id "com.apple.systemevents" to get name"#),
            ("Calendar", #"tell application id "com.apple.iCal" to get name"#),
            ("Reminders", #"tell application id "com.apple.reminders" to get name"#),
        ]

        return probes.map { probe in
            var errorInfo: NSDictionary?
            let result = NSAppleScript(source: probe.script)?.executeAndReturnError(&errorInfo)
            if result != nil {
                return PermissionProbeResult(name: probe.name, ok: true, detail: "앱 본체에서 Apple Event 전송 확인됨")
            }
            return PermissionProbeResult(
                name: probe.name,
                ok: false,
                detail: appleScriptProbeError(errorInfo) ?? "자동화 권한이 없거나 대상 앱에 접근할 수 없습니다."
            )
        }
    }

    nonisolated private static func runEngineAutomationPermissionProbes(
        engineRoot: URL,
        environment: [String: String]
    ) -> [PermissionProbeResult] {
        let probes: [(name: String, script: String)] = [
            ("Safari", #"Application("/Applications/Safari.app").name();"#),
            ("Notes", #"Application("/System/Applications/Notes.app").name();"#),
            ("System Events", #"Application("/System/Library/CoreServices/System Events.app").name();"#),
            ("Calendar", #"Application("/System/Applications/Calendar.app").name();"#),
            ("Reminders", #"Application("/System/Applications/Reminders.app").name();"#),
        ]
        let launchEnvironment = KLMSCommandRunner.processEnvironmentForLaunch(
            base: ProcessInfo.processInfo.environment,
            overrides: environment
        )
        return probes.map { probe in
            runOSAJavaScriptPermissionProbe(
                name: probe.name,
                script: probe.script,
                engineRoot: engineRoot,
                environment: launchEnvironment
            )
        }
    }

    nonisolated private static func runOSAJavaScriptPermissionProbe(
        name: String,
        script: String,
        engineRoot: URL,
        environment: [String: String]
    ) -> PermissionProbeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]
        process.currentDirectoryURL = engineRoot
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus == 0 {
                return PermissionProbeResult(
                    name: name,
                    ok: true,
                    detail: text.isEmpty ? "엔진 child process에서 JXA 접근 확인됨" : text
                )
            }
            return PermissionProbeResult(
                name: name,
                ok: false,
                detail: text.isEmpty ? "osascript 종료 코드 \(process.terminationStatus)" : text
            )
        } catch {
            return PermissionProbeResult(
                name: name,
                ok: false,
                detail: "osascript 권한 probe 실행 실패: \(error.localizedDescription)"
            )
        }
    }

    private static func permissionRows(
        accessibilityTrusted: Bool,
        nativeNoticeHelperProbe: PermissionProbeResult,
        notificationStatus: Bool,
        calendarStatus: Bool,
        remindersStatus: Bool,
        appAutomationStatus: [PermissionProbeResult],
        engineAutomationStatus: [PermissionProbeResult]
    ) -> [KLMSPermissionProbeRow] {
        var rows: [KLMSPermissionProbeRow] = [
            permissionRow(
                id: "accessibility",
                title: "손쉬운 사용",
                ok: accessibilityTrusted,
                detail: "공지 메모의 체크리스트, 문단 형식, 선택 영역 확인에 필요합니다."
            ),
            permissionRow(
                id: "native-notice-helper",
                title: nativeNoticeHelperProbe.name,
                ok: nativeNoticeHelperProbe.ok,
                detail: nativeNoticeHelperProbe.detail
            ),
            permissionRow(
                id: "notifications",
                title: "알림",
                ok: notificationStatus,
                detail: "KAIST 인증번호와 실패 알림을 앱에서 즉시 보여줄 때 필요합니다."
            ),
            permissionRow(
                id: "calendar-eventkit",
                title: "캘린더 전체 접근",
                ok: calendarStatus,
                detail: "시험/헬프데스크 일정을 Calendar에 생성, 수정, 삭제할 때 필요합니다."
            ),
            permissionRow(
                id: "reminders-eventkit",
                title: "미리 알림 전체 접근",
                ok: remindersStatus,
                detail: "과제 알림과 완료 상태를 Reminders에 반영할 때 필요합니다."
            ),
        ]
        rows.append(contentsOf: appAutomationStatus.map { result in
            permissionRow(
                id: "app-automation-\(result.name)",
                title: "앱 자동화 · \(result.name)",
                ok: result.ok,
                detail: result.detail
            )
        })
        rows.append(contentsOf: engineAutomationStatus.map { result in
            permissionRow(
                id: "engine-automation-\(result.name)",
                title: "엔진 자동화 · \(result.name)",
                ok: result.ok,
                detail: result.detail
            )
        })
        return rows
    }

    private static func requiredPermissionFailures(
        accessibilityTrusted: Bool,
        nativeNoticeHelperProbe: PermissionProbeResult,
        calendarStatus: Bool,
        remindersStatus: Bool,
        appAutomationStatus: [PermissionProbeResult],
        engineAutomationStatus: [PermissionProbeResult]
    ) -> [String] {
        var missing = [String]()
        if !accessibilityTrusted {
            missing.append("손쉬운 사용")
        }
        if !nativeNoticeHelperProbe.ok {
            missing.append("공지 렌더러")
        }
        if !calendarStatus {
            missing.append("캘린더")
        }
        if !remindersStatus {
            missing.append("미리 알림")
        }
        missing.append(contentsOf: appAutomationStatus.filter { !$0.ok }.map { "앱 자동화 \($0.name)" })
        missing.append(contentsOf: engineAutomationStatus.filter { !$0.ok }.map { "엔진 자동화 \($0.name)" })
        return missing
    }

    private static func permissionRow(
        id: String,
        title: String,
        ok: Bool,
        detail: String
    ) -> KLMSPermissionProbeRow {
        KLMSPermissionProbeRow(
            id: id,
            title: title,
            value: ok ? "허용됨" : "설정 필요",
            detail: detail,
            isWarning: !ok
        )
    }

    private static func appleScriptProbeError(_ errorInfo: NSDictionary?) -> String? {
        guard let errorInfo else {
            return nil
        }
        if let message = errorInfo[NSAppleScript.errorMessage] as? String {
            return message
        }
        return errorInfo.description
    }

    private static func openNotesScript(noteID: String, noteTitle: String) -> String {
        """
        tell application "Notes"
          activate
          if "\(appleScriptStringLiteralContent(noteID))" is not "" then
            try
              show note id "\(appleScriptStringLiteralContent(noteID))"
              return
            end try
          end if
          repeat with currentAccount in accounts
            repeat with currentFolder in folders of currentAccount
              repeat with currentNote in notes of currentFolder
                if name of currentNote is "\(appleScriptStringLiteralContent(noteTitle))" then
                  show currentNote
                  return
                end if
              end repeat
            end repeat
          end repeat
          error "Notes 메모를 찾지 못했습니다: \(appleScriptStringLiteralContent(noteTitle))"
        end tell
        """
    }

    private static func appleScriptStringLiteralContent(_ text: String) -> String {
        text.klmsDisplayText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func appleScriptErrorMessage(_ errorInfo: NSDictionary?) -> String? {
        guard let errorInfo else {
            return nil
        }
        if let message = errorInfo[NSAppleScript.errorMessage] as? String {
            return message
        }
        return errorInfo.description
    }

    private func reloadSnapshot(showLoginTransition: Bool = false) {
        applySnapshot(
            EngineSnapshotStore(paths: paths).load(),
            showLoginTransition: showLoginTransition
        )
    }

    private func applySnapshot(_ nextSnapshot: EngineSnapshot, showLoginTransition: Bool) {
        _ = showLoginTransition
        snapshot = nextSnapshot
        if nextSnapshot.loginStatus?.loggedIn == true || liveAuthDigits == nil {
            liveAuthDigits = nil
            authDigitsSuppressed = true
            clearAuthNotifications()
        }
    }

    private func notifyAuthDigits(_ digits: String) async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent()
        content.title = "KLMS 인증 번호"
        content.body = "휴대폰 KAIST 인증 화면에서 \(digits)를 선택해 주세요."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "klms-auth-\(digits)", content: content, trigger: nil)
        try? await center.add(request)
    }

    private func notifyAuthCompletion() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent()
        content.title = "KLMS 인증 완료"
        content.body = "로그인 인증이 완료됐습니다. 동기화를 계속 진행합니다."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "klms-auth-completed-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    private func notifyServerRelayFileAccess(
        _ request: ServerRelayFileAccessRequest,
        title: String,
        body: String,
        sound: Bool
    ) async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound {
            content.sound = .default
        }
        let identifier = "klms-file-access-\(request.id.uuidString)-\(request.status.rawValue)"
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private func recordServerRelayFileAccessRequest(_ request: ServerRelayFileAccessRequest) {
        var requests = serverRelayRecentFileAccessRequests.filter { $0.id != request.id }
        requests.insert(request, at: 0)
        serverRelayRecentFileAccessRequests = Array(requests.prefix(8))
    }

    private func handleLiveCommandOutput(_ chunk: String) async {
        appendLiveCommandOutput(chunk.klmsDisplayText)
        if let digits = KLMSCommandRunner.extractAuthDigits(from: liveCommandOutput) {
            liveAuthDigits = digits
            authStatusMessage = nil
            authStatusClearTask?.cancel()
            authStatusClearTask = nil
            authDigitsSuppressed = false
            authDigitsSeenForCurrentRun = true
            await notifyAuthDigitsIfNeeded(digits)
            await publishServerRelayStatusIfNeeded(force: true)
        }
        if authDigitsSeenForCurrentRun,
           KLMSCommandRunner.outputConfirmsAuthChallengeCompletion(liveCommandOutput) {
            await clearAuthDigitsState(showAuthenticatedMessage: true)
            await publishServerRelayStatusIfNeeded(force: true)
            return
        }
        if !authDigitsSeenForCurrentRun,
           KLMSCommandRunner.outputIndicatesAlreadyAuthenticated(liveCommandOutput) {
            showAlreadyLoggedInStatusIfNeeded()
            await publishServerRelayStatusIfNeeded(force: true)
        }
    }

    private func appendLiveCommandOutput(_ text: String) {
        liveCommandOutput = Self.trimLiveCommandOutput(liveCommandOutput + text)
    }

    private static func trimLiveCommandOutput(_ text: String) -> String {
        guard text.count > liveCommandOutputMaxCharacters else {
            return text
        }
        let suffixLength = max(0, liveCommandOutputMaxCharacters - trimmedLiveCommandOutputPrefix.count)
        return trimmedLiveCommandOutputPrefix + String(text.suffix(suffixLength))
    }

    private func notifyAuthDigitsIfNeeded(_ digits: String) async {
        guard !notifiedAuthDigits.contains(digits) else {
            return
        }
        notifiedAuthDigits.insert(digits)
        await notifyAuthDigits(digits)
    }

    private func notifyAuthCompletionIfNeeded() async {
        guard !notifiedAuthCompletionForCurrentRun else {
            return
        }
        notifiedAuthCompletionForCurrentRun = true
        await notifyAuthCompletion()
    }

    private func showAlreadyLoggedInStatusIfNeeded() {
        guard !notifiedAlreadyLoggedInForCurrentRun else {
            return
        }
        notifiedAlreadyLoggedInForCurrentRun = true
        lastAuthCompletionAt = Date()
        showTransientAuthStatus("이미 로그인됨")
    }

    private func startRunningCommandStatusPoll(startedAt: Date) {
        runningCommandStatusPollTask?.cancel()
        runningCommandStatusPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, self.runningCommand != nil else {
                    return
                }
                let nextSnapshot = EngineSnapshotStore(paths: self.paths).load()
                self.snapshot = nextSnapshot
                if self.authDigitsSeenForCurrentRun,
                   self.loginStatusWasConfirmed(nextSnapshot.loginStatus, since: startedAt) {
                    await self.clearAuthDigitsState(showAuthenticatedMessage: true)
                }
                await self.processServerRelayCancelRequestWhileRunning()
                await self.publishServerRelayStatusIfNeeded()
            }
        }
    }

    private func processServerRelayCancelRequestWhileRunning() async {
        guard runningCommand != nil,
              serverRelayEnabled,
              serverRelayConfigured,
              activeRemoteCommandID != nil || lastRemoteCommand?.status.isInFlight == true else {
            return
        }
        do {
            let store = try makeServerRelayStore()
            await processServerRelayCancelRequest(store: store, silent: true)
        } catch {
            serverRelayStatusMessage = "원격 실행 중단 확인 실패: \(error.localizedDescription)"
        }
    }

    private func loginStatusWasConfirmed(_ loginStatus: LoginStatus?, since startedAt: Date) -> Bool {
        guard loginStatus?.loggedIn == true,
              let checkedAt = loginStatus?.checkedAt else {
            return false
        }
        return checkedAt >= startedAt.addingTimeInterval(-2)
    }

    private func clearAuthDigitsState(
        showAuthenticatedMessage: Bool,
        confirmedAuthChallenge: Bool = false
    ) async {
        liveAuthDigits = nil
        authDigitsSuppressed = true
        clearAuthNotifications()
        notifiedAuthDigits.removeAll()
        let shouldShowAuthenticatedMessage = showAuthenticatedMessage
            && (authDigitsSeenForCurrentRun || confirmedAuthChallenge)
        if shouldShowAuthenticatedMessage {
            lastAuthCompletionAt = Date()
            showTransientAuthStatus("인증 완료됨")
            await notifyAuthCompletionIfNeeded()
        }
    }

    private func showTransientAuthStatus(_ message: String) {
        authStatusClearTask?.cancel()
        authStatusMessage = message
        lastAuthStatusMessageForRemote = message
        authStatusClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else {
                return
            }
            self?.authStatusMessage = nil
            self?.authStatusClearTask = nil
        }
    }

    private func clearAuthNotifications() {
        let center = UNUserNotificationCenter.current()
        let identifiers = notifiedAuthDigits.map { "klms-auth-\($0)" }
        if !identifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
        center.getPendingNotificationRequests { requests in
            let staleIdentifiers = requests
                .map(\.identifier)
                .filter(Self.isAuthDigitsNotificationIdentifier)
            guard !staleIdentifiers.isEmpty else {
                return
            }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: staleIdentifiers)
        }
        center.getDeliveredNotifications { notifications in
            let staleIdentifiers = notifications
                .map(\.request.identifier)
                .filter(Self.isAuthDigitsNotificationIdentifier)
            guard !staleIdentifiers.isEmpty else {
                return
            }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: staleIdentifiers)
        }
    }

    nonisolated private static func isAuthDigitsNotificationIdentifier(_ identifier: String) -> Bool {
        let prefix = "klms-auth-"
        guard identifier.hasPrefix(prefix) else {
            return false
        }
        let suffix = identifier.dropFirst(prefix.count)
        return suffix.count == 2 && suffix.allSatisfy(\.isNumber)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
