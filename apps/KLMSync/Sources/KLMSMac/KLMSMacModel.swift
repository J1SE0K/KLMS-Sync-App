import Foundation
import ApplicationServices
import AppKit
import Darwin
import EventKit
import KLMSShared
import SwiftUI
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
    @Published var paths = KLMSPaths()
    @Published var snapshot = EngineSnapshot()
    @Published var envDocument: EnvDocument?
    @Published var launchAgentState: LaunchAgentState?
    @Published var appDiagnostics = KLMSAppDiagnostics()
    @Published var commandHistory = CommandRunHistory()
    @Published var latestBackup: AppDataBackupRecord?
    @Published var installResult: EngineInstallResult?
    @Published var lastCommandResult: KLMSCommandResult?
    @Published var lastRemoteCommand: RemoteRunCommand?
    @Published var remoteProcessingEnabled: Bool
    @Published var remoteProcessingStatusMessage: String?
    @Published var isCheckingRemoteCommands = false
    @Published var localRemoteEnabled: Bool
    @Published var localRemoteToken: String
    @Published var localRemoteStatusMessage: String?
    @Published var isLocalRemoteServerRunning = false
    @Published var permissionStatusMessage: String?
    @Published var permissionProbeRows: [KLMSPermissionProbeRow] = []
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
    private var remotePollingTask: Task<Void, Never>?
    private var localRemoteServer: LocalRemoteServer?
    private var notifiedAuthDigits = Set<String>()
    private var authStatusClearTask: Task<Void, Never>?
    private static let automaticPermissionRequestVersionKey = "KLMSAutomaticPermissionRequestVersion"
    private static let remoteProcessingEnabledKey = "KLMSRemoteProcessingEnabled"
    private static let localRemoteEnabledKey = "KLMSLocalRemoteEnabled"
    private static let localRemoteTokenKey = "KLMSLocalRemoteToken"
    private static let localRemotePort: UInt16 = 18483
    private static let remotePollingIntervalNanoseconds: UInt64 = 20_000_000_000

    init() {
        remoteProcessingEnabled = UserDefaults.standard.bool(
            forKey: Self.remoteProcessingEnabledKey
        )
        localRemoteEnabled = UserDefaults.standard.bool(forKey: Self.localRemoteEnabledKey)
        if let token = UserDefaults.standard.string(forKey: Self.localRemoteTokenKey),
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            localRemoteToken = token
        } else {
            let token = Self.makeLocalRemoteToken()
            localRemoteToken = token
            UserDefaults.standard.set(token, forKey: Self.localRemoteTokenKey)
        }
    }

    deinit {
        remotePollingTask?.cancel()
        localRemoteServer?.stop()
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

    var launchLabel: String {
        LaunchAgentManager(paths: paths).label(from: envDocument)
    }

    var currentAuthDigits: String? {
        if let liveAuthDigits {
            return liveAuthDigits
        }
        if let result = lastCommandResult,
           let digits = result.authDigits,
               Date().timeIntervalSince(result.finishedAt) <= 15 * 60 {
            return digits
        }
        if authDigitsSuppressed {
            return nil
        }
        return snapshot.authDigits
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
        [
            "KLMS_APP_RUN": "1",
            "NOTICE_NATIVE_NOTE_BIN_PATH": nativeNoticeHelperPath,
            "KLMS_PYTHONPATH_DIR": paths.appPythonPackagesURL.path,
            "KLMS_SCRIPT_NOTIFICATIONS_ENABLED": "0",
            "KLMS_LOGIN_ASSIST_ENABLED": "1",
            "KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE": "1",
            "NOTICE_NATIVE_ALWAYS_CAPTURE_STATE": "1",
            "NOTICE_NATIVE_STABLE_NOOP_SKIP": "0",
            "NOTICE_NATIVE_DEFER_STATE_ONLY_RENDER": "0",
            "NOTICE_NATIVE_FORCE_ARCHIVE_POST_CAPTURE_RENDER": "0",
            "NOTICE_NATIVE_VERIFY_STABLE_SKIP_FORMAT": "0",
            "NOTICE_NATIVE_ENABLE_BATCH_CHECKLIST_FORMAT": "1",
            "NOTICE_NATIVE_ENABLE_UI_STYLE_FORMAT": "1",
            "NOTICE_NATIVE_BOLD_REINFORCE_LIMIT": "0",
            "NOTICE_NATIVE_VALIDATE_STYLE": "0",
            "NOTICE_NATIVE_COLLAPSE_ALL_FIRST": "0",
            "NOTICE_NATIVE_SELECTION_SETTLE_SECONDS": "0.012",
            "NOTICE_NATIVE_CHECKLIST_PRESS_SETTLE_US": "15000",
            "NOTICE_NATIVE_PREFORMATTED_PASTE_ONLY": "0",
            "NOTICE_NATIVE_PLAIN_TEXT_PASTE": "0",
            "NOTICE_NATIVE_STYLE_BUDGET_SECONDS": "60",
        ]
    }

    var localRemotePort: UInt16 {
        Self.localRemotePort
    }

    var localRemoteEndpointHints: [String] {
        Self.localIPv4Addresses().map { "\($0):\(Self.localRemotePort)" }
    }

    var localRemotePrimaryEndpoint: String {
        localRemoteEndpointHints.first ?? "이 Mac의 IP:\(Self.localRemotePort)"
    }

    var localRemoteConnectionInfoText: String {
        """
        KLMS Sync iPhone 연결 정보
        Mac 주소: \(localRemotePrimaryEndpoint)
        토큰: \(localRemoteToken)
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
        await refresh()
        configureRemotePolling()
        configureLocalRemoteServer()
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
            refreshLaunchAgentState()
            refreshAppDiagnostics()
            if runDoctorAfterInstall, installResult?.installed == true {
                _ = try? await runner.run(.doctor, paths: paths)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearDisplayState(resetSnapshot: Bool) {
        errorMessage = nil
        lastCommandResult = nil
        if !remoteProcessingEnabled {
            lastRemoteCommand = nil
        }
        liveCommandOutput = ""
        liveAuthDigits = nil
        authStatusMessage = nil
        authStatusClearTask?.cancel()
        authStatusClearTask = nil
        isCancellingCommand = false
        authDigitsSuppressed = false
        notifiedAuthDigits.removeAll()
        if resetSnapshot {
            snapshot = EngineSnapshot()
            launchAgentState = nil
        }
    }

    func setRemoteProcessingEnabled(_ enabled: Bool) {
        if enabled, !appDiagnostics.codeSigning.cloudKitEntitled {
            remoteProcessingEnabled = false
            UserDefaults.standard.set(false, forKey: Self.remoteProcessingEnabledKey)
            remoteProcessingStatusMessage = "CloudKit 권한이 없어 iPhone 요청 자동 처리를 켤 수 없습니다."
            errorMessage = "iPhone 원격 요청은 Apple Developer iCloud container/provisioning 설정 후 사용할 수 있습니다."
            return
        }
        remoteProcessingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.remoteProcessingEnabledKey)
        configureRemotePolling()
        if enabled {
            remoteProcessingStatusMessage = "iPhone 요청 자동 처리가 켜졌습니다."
            Task {
                await processRemoteCommands(silent: true)
            }
        } else {
            remoteProcessingStatusMessage = "iPhone 요청 자동 처리가 꺼졌습니다."
        }
    }

    func setLocalRemoteEnabled(_ enabled: Bool) {
        localRemoteEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.localRemoteEnabledKey)
        configureLocalRemoteServer()
    }

    func regenerateLocalRemoteToken() {
        let token = Self.makeLocalRemoteToken()
        localRemoteToken = token
        UserDefaults.standard.set(token, forKey: Self.localRemoteTokenKey)
        if localRemoteEnabled {
            configureLocalRemoteServer()
        }
    }

    func copyLocalRemoteEndpoint(_ endpoint: String? = nil) {
        let value = endpoint ?? localRemotePrimaryEndpoint
        copyToPasteboard(value)
        localRemoteStatusMessage = "Mac 주소를 복사했습니다: \(value)"
    }

    func copyLocalRemoteToken() {
        copyToPasteboard(localRemoteToken)
        localRemoteStatusMessage = "토큰을 복사했습니다."
    }

    func copyLocalRemoteConnectionInfo() {
        copyToPasteboard(localRemoteConnectionInfoText)
        localRemoteStatusMessage = "iPhone 연결 정보를 복사했습니다."
    }

    private func configureLocalRemoteServer() {
        localRemoteServer?.stop()
        localRemoteServer = nil
        isLocalRemoteServerRunning = false
        guard localRemoteEnabled else {
            localRemoteStatusMessage = "로컬 원격 제어가 꺼져 있습니다."
            return
        }
        let server = LocalRemoteServer(port: Self.localRemotePort) { [weak self] request in
            await self?.handleLocalRemoteRequest(request)
                ?? LocalRemoteResponse(ok: false, message: "Mac 앱이 준비되지 않았습니다.")
        }
        do {
            try server.start()
            localRemoteServer = server
            isLocalRemoteServerRunning = true
            let endpoint = localRemoteEndpointHints.first ?? "이 Mac의 IP:\(Self.localRemotePort)"
            localRemoteStatusMessage = "로컬 원격 제어 실행 중: \(endpoint)"
        } catch {
            localRemoteStatusMessage = "로컬 원격 제어 시작 실패: \(error.localizedDescription)"
            errorMessage = localRemoteStatusMessage
        }
    }

    private func handleLocalRemoteRequest(_ request: LocalRemoteRequest) async -> LocalRemoteResponse {
        guard request.token == localRemoteToken else {
            return LocalRemoteResponse(ok: false, message: "토큰이 맞지 않습니다.")
        }
        switch request.action {
        case .status:
            return LocalRemoteResponse(
                ok: true,
                message: localRemoteStatusMessage ?? "대기 중",
                status: SanitizedRemoteStatus(snapshot: snapshot, phase: runningCommand == nil ? "idle" : "running"),
                latestCommand: lastRemoteCommand,
                running: runningCommand != nil
            )
        case .run:
            guard let kind = request.kind else {
                return LocalRemoteResponse(ok: false, message: "실행할 명령이 없습니다.")
            }
            guard runningCommand == nil,
                  lastRemoteCommand?.status.isInFlight != true else {
                return LocalRemoteResponse(
                    ok: false,
                    message: "이미 동기화가 실행 중입니다.",
                    status: SanitizedRemoteStatus(snapshot: snapshot, phase: "busy"),
                    latestCommand: lastRemoteCommand,
                    running: true
                )
            }
            let command = RemoteRunCommand(
                kind: kind,
                status: .running,
                summary: SanitizedRemoteStatus(snapshot: snapshot, phase: "running")
            )
            lastRemoteCommand = command
            remoteProcessingStatusMessage = "로컬 iPhone 요청 처리 중: \(kind.displayName)"
            localRemoteStatusMessage = "로컬 iPhone 요청 처리 중: \(kind.displayName)"
            Task { [weak self] in
                await self?.executeLocalRemoteCommand(command)
            }
            return LocalRemoteResponse(
                ok: true,
                message: "\(kind.displayName) 실행을 시작했습니다.",
                status: command.summary,
                latestCommand: command,
                running: true
            )
        }
    }

    private func executeLocalRemoteCommand(_ command: RemoteRunCommand) async {
        await run(command.kind.engineCommand)
        let refreshedSnapshot = EngineSnapshotStore(paths: paths).load()
        var completed = command
        completed.status = lastCommandResult?.succeeded == true ? .completed : .failed
        completed.updatedAt = Date()
        completed.lastExitCode = lastCommandResult.map { Int($0.exitCode) }
        completed.loginRequired = lastCommandResult?.requiresLoginApproval == true
        completed.summary = SanitizedRemoteStatus(snapshot: refreshedSnapshot, phase: completed.status.rawValue)
        lastRemoteCommand = completed
        let message = "최근 로컬 iPhone 요청: \(completed.kind.displayName) · \(completed.status.displayName)"
        localRemoteStatusMessage = message
        remoteProcessingStatusMessage = message
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func configureRemotePolling() {
        remotePollingTask?.cancel()
        remotePollingTask = nil
        guard remoteProcessingEnabled else {
            return
        }
        remotePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.processRemoteCommands(silent: true)
                try? await Task.sleep(nanoseconds: Self.remotePollingIntervalNanoseconds)
            }
        }
    }

    func refresh(clearDisplayLogs: Bool = false) async {
        if clearDisplayLogs {
            clearDisplayState(resetSnapshot: false)
        }
        do {
            try loadConfig()
        } catch {
            if FileManager.default.fileExists(atPath: paths.configURL.path) {
                errorMessage = error.localizedDescription
            }
        }
        let nextSnapshot = EngineSnapshotStore(paths: paths).load()
        snapshot = nextSnapshot
        commandHistory = CommandRunHistoryStore(url: paths.appHistoryURL).load()
        latestBackup = AppDataBackupManager(paths: paths).latestBackup()
        refreshAppDiagnostics()
        if nextSnapshot.authDigits == nil && liveAuthDigits == nil {
            clearAuthNotifications()
        }
        refreshLaunchAgentState()
    }

    func run(_ command: KLMSEngineCommand, dryRun: Bool = false) async {
        guard runningCommand == nil else { return }
        runningCommand = command
        isCancellingCommand = false
        errorMessage = nil
        lastCommandResult = nil
        liveCommandOutput = ""
        liveAuthDigits = nil
        authStatusMessage = nil
        authStatusClearTask?.cancel()
        authStatusClearTask = nil
        authDigitsSuppressed = false
        notifiedAuthDigits.removeAll()
        defer {
            runningCommand = nil
            isCancellingCommand = false
        }

        do {
            await installEngine(force: false, runDoctorAfterInstall: false)
            let result = try await runner.run(
                command,
                paths: paths,
                dryRun: dryRun,
                environment: appRunEnvironment
            ) { [weak self] chunk in
                Task { @MainActor [weak self] in
                    await self?.handleLiveCommandOutput(chunk)
                }
            }
            lastCommandResult = result
            commandHistory = (try? CommandRunHistoryStore(url: paths.appHistoryURL).append(result)) ?? commandHistory
            if result.loginAuthenticated {
                await clearAuthDigitsState(showAuthenticatedMessage: result.authDigits != nil)
            } else if let digits = result.authDigits {
                await notifyAuthDigitsIfNeeded(digits)
            }
            if result.wasCancelled {
                errorMessage = "\(command.displayName) 중단됨"
            } else if !result.succeeded {
                errorMessage = "\(command.displayName) 실패: 종료 코드 \(result.exitCode)"
            }
            if !dryRun, result.succeeded, command.refreshesSyncReportAfterRun {
                _ = try? await runner.run(.report, paths: paths, environment: appRunEnvironment)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    func cancelRunningCommand() async {
        guard runningCommand != nil else { return }
        isCancellingCommand = true
        let requested = await runner.cancelCurrentCommand()
        if requested {
            liveCommandOutput.append("\n== 사용자가 동기화 중단을 요청했습니다 ==\n")
        } else {
            isCancellingCommand = false
        }
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

    func setConfigValue(_ value: String, for key: EnvKnownKey) {
        do {
            var document = envDocument ?? EnvDocument(text: "")
            document.setValue(value, for: key)
            try EnvStore(url: paths.configURL).save(document)
            envDocument = document
            refreshLaunchAgentState()
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

    func toggleLaunchAgent() async {
        let manager = LaunchAgentManager(paths: paths)
        let label = launchLabel
        do {
            if manager.state(label: label).isInstalled {
                try manager.uninstall(label: label)
            } else {
                try manager.install(label: label)
            }
            refreshLaunchAgentState()
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
            await refresh()
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

    func processRemoteCommands(silent: Bool = false) async {
        #if canImport(CloudKit)
        guard appDiagnostics.codeSigning.cloudKitEntitled else {
            remoteProcessingStatusMessage = "CloudKit 권한이 없어 iPhone 요청을 확인할 수 없습니다."
            if !silent {
                errorMessage = "iPhone 원격 요청은 Apple Developer iCloud container/provisioning 설정 후 사용할 수 있습니다."
            }
            return
        }
        guard runningCommand == nil else {
            if !silent {
                remoteProcessingStatusMessage = "동기화 실행 중에는 iPhone 요청을 처리하지 않습니다."
            }
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
            let store = CloudKitCommandStore()
            let pending = try await store.fetchPending()
            let now = Date()
            var commandToRun: RemoteRunCommand?
            for command in pending {
                if command.isStaleForExecution(now: now) {
                    var stale = command
                    stale.status = .macUnavailable
                    stale.updatedAt = now
                    stale.summary = SanitizedRemoteStatus(
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
                remoteProcessingStatusMessage = "대기 중인 iPhone 요청이 없습니다."
                if !silent {
                    errorMessage = remoteProcessingStatusMessage
                }
                return
            }
            var running = command
            running.status = .running
            running.updatedAt = Date()
            running.summary = SanitizedRemoteStatus(snapshot: snapshot, phase: "running")
            try await store.update(running)
            lastRemoteCommand = running
            remoteProcessingStatusMessage = "\(running.kind.displayName) 요청 처리 중"

            await run(command.kind.engineCommand)
            let refreshedSnapshot = EngineSnapshotStore(paths: paths).load()
            var completed = running
            completed.status = lastCommandResult?.succeeded == true ? .completed : .failed
            completed.updatedAt = Date()
            completed.lastExitCode = lastCommandResult.map { Int($0.exitCode) }
            completed.loginRequired = lastCommandResult?.requiresLoginApproval == true
            completed.summary = SanitizedRemoteStatus(snapshot: refreshedSnapshot, phase: completed.status.rawValue)
            try await store.update(completed)
            lastRemoteCommand = completed
            remoteProcessingStatusMessage = "최근 iPhone 요청: \(completed.kind.displayName) · \(completed.status.displayName)"
        } catch {
            remoteProcessingStatusMessage = "iPhone 요청 확인 실패: \(error.localizedDescription)"
            if !silent {
                errorMessage = error.localizedDescription
            }
        }
        #else
        remoteProcessingStatusMessage = "CloudKit을 사용할 수 없는 빌드입니다."
        if !silent {
            errorMessage = remoteProcessingStatusMessage
        }
        #endif
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
        if remoteProcessingEnabled, !diagnostics.codeSigning.cloudKitEntitled {
            remoteProcessingEnabled = false
            UserDefaults.standard.set(false, forKey: Self.remoteProcessingEnabledKey)
            remotePollingTask?.cancel()
            remotePollingTask = nil
            remoteProcessingStatusMessage = "CloudKit 권한이 없어 iPhone 요청 자동 처리를 껐습니다."
        }
    }

    private func openSystemSettingsPane(_ text: String) {
        guard let url = URL(string: text) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func makeLocalRemoteToken() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<12).map { _ in alphabet.randomElement() ?? "K" })
    }

    private static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return addresses
        }
        defer { freeifaddrs(interfaces) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ipBytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let ip = String(decoding: ipBytes, as: UTF8.self)
            if !ip.isEmpty {
                addresses.append(ip)
            }
        }
        return Array(NSOrderedSet(array: addresses)) as? [String] ?? addresses
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

    private func refreshLaunchAgentState() {
        let manager = LaunchAgentManager(paths: paths)
        launchAgentState = manager.state(label: manager.label(from: envDocument))
    }

    private func reloadSnapshot() {
        snapshot = EngineSnapshotStore(paths: paths).load()
    }

    private func notifyAuthDigits(_ digits: String) async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent()
        content.title = "KLMS 인증 번호"
        content.body = "휴대폰 KAIST 인증 화면에서 \(digits)를 선택해 주세요."
        let request = UNNotificationRequest(identifier: "klms-auth-\(digits)", content: content, trigger: nil)
        try? await center.add(request)
    }

    private func handleLiveCommandOutput(_ chunk: String) async {
        liveCommandOutput.append(chunk.klmsDisplayText)
        if let digits = KLMSCommandRunner.extractAuthDigits(from: liveCommandOutput) {
            liveAuthDigits = digits
            authStatusMessage = nil
            authStatusClearTask?.cancel()
            authStatusClearTask = nil
            authDigitsSuppressed = false
            await notifyAuthDigitsIfNeeded(digits)
        }
        if KLMSCommandRunner.outputIndicatesAuthenticatedAfterLatestAuthDigits(liveCommandOutput) {
            await clearAuthDigitsState(showAuthenticatedMessage: liveAuthDigits != nil)
            return
        }
    }

    private func notifyAuthDigitsIfNeeded(_ digits: String) async {
        guard !notifiedAuthDigits.contains(digits) else {
            return
        }
        notifiedAuthDigits.insert(digits)
        await notifyAuthDigits(digits)
    }

    private func clearAuthDigitsState(showAuthenticatedMessage: Bool) async {
        liveAuthDigits = nil
        authDigitsSuppressed = true
        clearAuthNotifications()
        notifiedAuthDigits.removeAll()
        if showAuthenticatedMessage {
            showTransientAuthStatus("인증 완료됨")
        }
    }

    private func showTransientAuthStatus(_ message: String) {
        authStatusClearTask?.cancel()
        authStatusMessage = message
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
        if identifiers.isEmpty {
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
        } else {
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }
}
