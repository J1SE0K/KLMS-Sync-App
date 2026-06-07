import SwiftUI

#if canImport(AppKit)
import AppKit
#endif
#if canImport(KLMSShared)
import KLMSShared
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UserNotifications)
private final class KLMSCompanionNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = KLMSCompanionNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
#endif

@main
struct KLMSiOSApp: App {
    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .background(Color.klmsScreenBackground.ignoresSafeArea())
        }
    }
}

@MainActor
final class CompanionModel: ObservableObject {
    @Published var recentCommands: [RemoteRunCommand] = []
    @Published var recentRequestLog: [ServerRelayRequestLogEntry] = []
    @Published var recentFileAccessRequests: [ServerRelayFileAccessRequest] = []
    @Published var recentItemActions: [ServerRelayItemAction] = []
    @Published var recentSettingActions: [ServerRelaySettingAction] = []
    @Published var syncItems: [ServerRelaySyncItem] = []
    @Published var dryRunReports: [DryRunReport] = []
    @Published var calendarChanges: [CalendarChange] = []
    @Published var remoteSettings: [ServerRelaySetting] = []
    @Published var sharedRunLogs: [ServerRelayRunLog] = []
    @Published var status = SanitizedRemoteStatus()
    @Published var errorMessage = ""
    @Published var connectionMessage = ""
    @Published var connectionSucceeded: Bool?
    @Published var userAlert: UserAlert?
    @Published var isRefreshing = false
    @Published var isSubmitting = false
    @Published private(set) var pendingCancelCommandID: UUID?
    @Published private(set) var pendingCancelRequestedAt: Date?
    @Published var lastRefreshAt: Date?
    private var locallyHiddenCommandIDs = Set<UUID>()
    private var locallyHiddenRequestLogIDs = Set<UUID>()
    private var locallyHiddenFileAccessRequestIDs = Set<UUID>()
    private var locallyHiddenItemActionIDs = Set<UUID>()
    private var locallyHiddenSettingActionIDs = Set<UUID>()
    @Published var shouldUpdateNoticeNotes: Bool {
        didSet { UserDefaults.standard.set(shouldUpdateNoticeNotes, forKey: Self.shouldUpdateNoticeNotesKey) }
    }
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.serverURLKey) }
    }
    @Published var serverToken: String {
        didSet { Self.persistServerToken(serverToken) }
    }

    private var lastAuthSuccessAlertMessage = ""
    private var lastAuthSuccessAlertAt: Date?
    private var trackedReportNotificationCommandIDs = Set<UUID>()
    private var notifiedCancelCompletionCommandIDs = Set<UUID>()
    private var pasteboardClearTask: Task<Void, Never>?
    private var cancelFollowUpTask: Task<Void, Never>?
    private var serverRelayEventStreamTask: Task<Void, Never>?
    private var serverRelayEventWebSocketTask: URLSessionWebSocketTask?
    private var serverRelayEventStreamKey = ""
    private var refreshInProgress = false
    private var pendingRefreshRequest: PendingRefreshRequest?
    private var lastSyncDataRefreshAt: Date?
    private var syncDataNeedsRefresh = true
    private var syncItemsSignature: Int?
    private var calendarChangesSignature: Int?
    private var remoteSettingsSignature: Int?
    private var sharedRunLogsSignature: Int?
    private var lastTerminalCommandID: UUID?
    private let syncDataStaleInterval: TimeInterval = 45

    private static let deprecatedLocalHostKey = "KLMSLocalRemoteHost"
    private static let deprecatedLocalPortKey = "KLMSLocalRemotePort"
    private static let deprecatedLocalTokenKey = "KLMSLocalRemoteToken"
    private static let serverURLKey = "KLMSServerRelayURL"
    private static let serverTokenKey = "KLMSServerRelayToken"
    private static let shouldUpdateNoticeNotesKey = "KLMSShouldUpdateNoticeNotes"
    private static let trackedReportNotificationCommandIDsKey = "KLMSTrackedReportNotificationCommandIDs"

    private struct PendingRefreshRequest {
        var silentErrors: Bool
        var includeSyncData: Bool?
        var showsActivity: Bool

        mutating func merge(
            silentErrors newSilentErrors: Bool,
            includeSyncData newIncludeSyncData: Bool?,
            showsActivity newShowsActivity: Bool
        ) {
            silentErrors = silentErrors && newSilentErrors
            showsActivity = showsActivity || newShowsActivity
            if includeSyncData != true {
                includeSyncData = newIncludeSyncData
            }
        }
    }

    private struct RelayEventEnvelope: Decodable {
        var type: String?
        var reason: String?
        var updatedAt: String?
    }

    init() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().delegate = KLMSCompanionNotificationDelegate.shared
        #endif
        let storedServerToken = LocalRemoteTokenStore.load(account: "server-relay-ios")
            ?? UserDefaults.standard.string(forKey: Self.serverTokenKey)
            ?? ""
        let storedServerURL = UserDefaults.standard.string(forKey: Self.serverURLKey) ?? ""
        if storedServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            serverURL = ""
        } else if let publicURL = ServerRelayConnectionInfo.normalizedPublicRelayURL(storedServerURL) {
            serverURL = publicURL.absoluteString
            UserDefaults.standard.set(publicURL.absoluteString, forKey: Self.serverURLKey)
        } else {
            serverURL = ""
            UserDefaults.standard.removeObject(forKey: Self.serverURLKey)
        }
        serverToken = storedServerToken
        shouldUpdateNoticeNotes = UserDefaults.standard.object(forKey: Self.shouldUpdateNoticeNotesKey) as? Bool ?? true
        trackedReportNotificationCommandIDs = Self.loadTrackedReportNotificationCommandIDs()
        Self.persistServerToken(storedServerToken)
        Self.clearDeprecatedLocalConnectionInfo()
    }

    var isRemoteAvailable: Bool {
        serverRelayStore != nil
    }

    var serverRelayConfigured: Bool {
        serverRelayStore != nil
    }

    var remoteAvailabilityMessage: String {
        if serverRelayStore == nil {
            return "HTTPS 서버 릴레이 URL과 iPhone/Windows용 클라이언트 토큰을 입력해 주세요."
        }
        return ""
    }

    private var serverRelayStore: ServerRelayCommandStore? {
        try? ServerRelayCommandStore(urlText: serverURL, token: serverToken)
    }

    var latestCommand: RemoteRunCommand? {
        recentCommands.first
    }

    var latestDisplayStatus: RemoteCommandStatus? {
        latestCommand?.displayStatus()
    }

    var hasInFlightRequest: Bool {
        latestDisplayStatus?.isInFlight == true
            || recentFileAccessRequests.contains { $0.status.isInFlight }
    }

    var hasActiveServerWork: Bool {
        hasInFlightRequest
            || recentItemActions.contains { $0.status == .pending || $0.status == .running }
            || recentSettingActions.contains { $0.status == .pending || $0.status == .running }
    }

    var shouldShowCancelControl: Bool {
        serverRelayConfigured && latestDisplayStatus?.isInFlight == true
    }

    var isCancelRequestedForLatestCommand: Bool {
        guard let latestID = latestCommand?.id else {
            return false
        }
        return pendingCancelCommandID == latestID
    }

    var canCancelRunningCommand: Bool {
        shouldShowCancelControl && !isCancelRequestedForLatestCommand
    }

    var shouldShowAuthCompletion: Bool {
        hasAuthCompletionStatus
            && latestDisplayStatus?.isTerminal != true
    }

    var hasAuthCompletionStatus: Bool {
        status.authStatusMessage != nil
            && status.authDigits == nil
            && !status.loginRequired
    }

    var statusLine: String {
        if let authDigits = status.authDigits {
            return "KAIST 인증 화면에서 \(authDigits)를 선택해야 합니다."
        }
        if status.loginRequired {
            return "Mac에서 KLMS 로그인을 다시 확인해야 합니다."
        }
        if shouldShowAuthCompletion, let authStatusMessage = status.authStatusMessage {
            return authStatusMessage
        }
        guard let latestCommand, let latestDisplayStatus else {
            return "Mac 앱이 아직 상태를 올린 적 없습니다."
        }
        if isCancelRequestedForLatestCommand {
            return "Mac에서 \(latestCommand.kind.displayName) 실행을 중단하는 중"
        }
        switch latestDisplayStatus {
        case .pending:
            return "\(latestCommand.kind.displayName) 요청을 Mac이 확인하기를 기다리는 중"
        case .running:
            if let detail = runningPhaseDetail {
                return "Mac에서 \(latestCommand.kind.displayName) · \(detail) 진행 중"
            }
            return "Mac에서 \(latestCommand.kind.displayName) 처리 중"
        case .completed:
            return "최근 요청 완료: \(latestCommand.kind.displayName)"
        case .failed:
            return "최근 요청 실패: \(latestCommand.kind.displayName)"
        case .cancelled:
            return "최근 요청 취소됨: \(latestCommand.kind.displayName)"
        case .macUnavailable:
            return "Mac이 아직 요청을 확인하지 못했습니다. Mac 앱이 켜져 있으면 곧 처리됩니다."
        }
    }

    var activeRequestLabel: String {
        if isCancelRequestedForLatestCommand, let latestCommand {
            return "\(latestCommand.kind.displayName) 중단 처리 중"
        }
        if let latestCommand, latestDisplayStatus?.isInFlight == true {
            if let detail = runningPhaseDetail {
                return "\(latestCommand.kind.displayName) · \(detail)"
            }
            return "\(latestCommand.kind.displayName) 처리 중"
        }
        if status.phase == "running" {
            if let detail = runningPhaseDetail {
                return detail
            }
            return "요청 처리 중"
        }
        return "요청 처리 중"
    }

    var runningPhaseDetail: String? {
        let detail = status.phaseDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail?.isEmpty == false ? detail : nil
    }

    var loginAttentionMessage: String? {
        if status.loginRequired {
            return "KLMS 로그인이 풀렸을 수 있습니다. Mac에서 Safari KLMS 로그인을 완료한 뒤 다시 확인해 주세요."
        }
        return nil
    }

    var authSuccessMessage: String? {
        guard shouldShowAuthCompletion else {
            return nil
        }
        return status.authStatusMessage
    }

    func createCommand(_ kind: RemoteCommandKind, dryRun: Bool = false) async {
        guard !hasInFlightRequest else {
            errorMessage = "이미 대기 중이거나 실행 중인 요청이 있습니다."
            return
        }
        isSubmitting = true
        defer {
            isSubmitting = false
        }
        do {
            if let serverRelayStore {
                var command = RemoteRunCommand(
                    kind: kind,
                    options: RemoteRunOptions(updateNoticeNotes: shouldUpdateNoticeNotes, dryRun: dryRun)
                )
                command.summary = status
                try await serverRelayStore.create(command)
                trackReportNotificationIfNeeded(for: command)
                recentCommands.insert(command, at: 0)
                status = command.summary
                lastRefreshAt = Date()
                errorMessage = ""
                await refreshRecent(includeSyncData: false, showsActivity: false)
            } else {
                errorMessage = remoteAvailabilityMessage
            }
        } catch {
            guard !isCancellationError(error) else { return }
            errorMessage = userFacingMessage(for: error)
        }
    }

    func cancelRunningCommand() async {
        guard let serverRelayStore else {
            errorMessage = remoteAvailabilityMessage
            return
        }
        guard let commandID = latestCommand?.id,
              latestDisplayStatus?.isInFlight == true else {
            errorMessage = "중단할 원격 실행 요청을 찾지 못했습니다."
            userAlert = UserAlert(title: "중단 요청 실패", message: errorMessage)
            return
        }
        guard pendingCancelCommandID != commandID else {
            connectionMessage = "이미 이 실행에 중단 요청을 보냈습니다."
            connectionSucceeded = true
            errorMessage = ""
            return
        }
        pendingCancelCommandID = commandID
        pendingCancelRequestedAt = Date()
        markCancelRequestedLocally(commandID: commandID)
        isSubmitting = true
        defer {
            isSubmitting = false
        }
        do {
            let cancelResponse = try await serverRelayStore.requestCancel(commandID: commandID)
            connectionSucceeded = true
            errorMessage = ""
            if cancelResponse.requested {
                connectionMessage = "Mac에 실행 중단 요청을 보냈습니다."
                userAlert = UserAlert(title: "중단 요청 전송", message: "Mac 앱에 현재 실행 중단을 요청했습니다.")
                startCancelFollowUp(commandID: commandID)
            } else {
                connectionMessage = cancelResponse.message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Mac이 처리하기 전에 원격 요청을 취소했습니다."
                pendingCancelCommandID = nil
                pendingCancelRequestedAt = nil
                cancelFollowUpTask?.cancel()
                cancelFollowUpTask = nil
                userAlert = UserAlert(title: "요청 취소됨", message: connectionMessage)
            }
            await refreshRecent(includeSyncData: false, showsActivity: false)
            try? await Task.sleep(nanoseconds: 250_000_000)
            await refreshRecent(includeSyncData: false, showsActivity: false)
        } catch {
            guard !isCancellationError(error) else { return }
            if pendingCancelCommandID == commandID {
                pendingCancelCommandID = nil
                pendingCancelRequestedAt = nil
                cancelFollowUpTask?.cancel()
                cancelFollowUpTask = nil
            }
            let message = userFacingMessage(for: error)
            errorMessage = message
            userAlert = UserAlert(title: "중단 요청 실패", message: message)
        }
    }

    func createSettingAction(setting: ServerRelaySetting, value: String) async {
        guard let serverRelayStore else {
            errorMessage = "설정 변경은 서버 릴레이 연결에서만 사용할 수 있습니다."
            userAlert = UserAlert(title: "요청 실패", message: errorMessage)
            return
        }
        isSubmitting = true
        defer {
            isSubmitting = false
        }
        do {
            let action = ServerRelaySettingAction(
                key: setting.key,
                value: value,
                title: setting.title
            )
            try await serverRelayStore.createSettingAction(action)
            recentSettingActions.insert(action, at: 0)
            connectionMessage = "\(setting.title) 설정 변경 요청을 보냈습니다."
            connectionSucceeded = true
            errorMessage = ""
            userAlert = UserAlert(title: "설정 요청 완료", message: "Mac 앱이 요청을 확인하면 설정 파일(config.env)에 반영합니다.")
            await refreshRecent(includeSyncData: false, showsActivity: false)
        } catch {
            guard !isCancellationError(error) else { return }
            let message = userFacingMessage(for: error)
            errorMessage = message
            userAlert = UserAlert(title: "설정 요청 실패", message: message)
        }
    }

    func createItemAction(_ actionKind: ServerRelayItemActionKind, item: ServerRelaySyncItem) async {
        guard let serverRelayStore else {
            errorMessage = "항목 상태 변경은 서버 릴레이 연결에서만 사용할 수 있습니다."
            userAlert = UserAlert(title: "요청 실패", message: errorMessage)
            return
        }
        isSubmitting = true
        defer {
            isSubmitting = false
        }
        do {
            let action = ServerRelayItemAction(
                action: actionKind,
                itemID: item.id,
                itemKind: item.kind,
                itemTitle: item.title
            )
            recentItemActions.removeAll { $0.itemID == item.id }
            recentItemActions.insert(action, at: 0)
            try await serverRelayStore.createItemAction(action)
            connectionMessage = "\(actionKind.displayName) 요청을 보냈습니다."
            connectionSucceeded = true
            errorMessage = ""
            userAlert = UserAlert(title: "요청 완료", message: connectionMessage)
            await refreshRecent(includeSyncData: false, showsActivity: false)
        } catch {
            guard !isCancellationError(error) else { return }
            recentItemActions.removeAll { $0.itemID == item.id && $0.action == actionKind && $0.status == .pending }
            let message = userFacingMessage(for: error)
            errorMessage = message
            userAlert = UserAlert(title: "요청 실패", message: message)
        }
    }

    func createCalendarAction(
        _ actionKind: ServerRelayItemActionKind,
        change: CalendarChange,
        edit: CalendarEventEdit? = nil
    ) async {
        guard let serverRelayStore else {
            errorMessage = "캘린더 요청은 서버 릴레이 연결에서만 사용할 수 있습니다."
            userAlert = UserAlert(title: "요청 실패", message: errorMessage)
            return
        }
        isSubmitting = true
        defer {
            isSubmitting = false
        }
        do {
            let action = ServerRelayItemAction(
                action: actionKind,
                itemID: change.id,
                itemKind: "calendar",
                itemTitle: change.title.nilIfEmpty ?? change.course.nilIfEmpty ?? "캘린더 변경",
                message: try edit?.encodedMessage() ?? ""
            )
            recentItemActions.removeAll { $0.itemID == action.itemID }
            recentItemActions.insert(action, at: 0)
            try await serverRelayStore.createItemAction(action)
            connectionMessage = "\(actionKind.displayName) 요청을 보냈습니다."
            connectionSucceeded = true
            errorMessage = ""
            userAlert = UserAlert(title: "요청 완료", message: calendarActionRequestMessage(for: actionKind))
            await refreshRecent(includeSyncData: false, showsActivity: false)
        } catch {
            guard !isCancellationError(error) else { return }
            recentItemActions.removeAll { $0.itemID == change.id && $0.action == actionKind && $0.status == .pending }
            let message = userFacingMessage(for: error)
            errorMessage = message
            userAlert = UserAlert(title: "요청 실패", message: message)
        }
    }

    private func calendarActionRequestMessage(for actionKind: ServerRelayItemActionKind) -> String {
        switch actionKind {
        case .calendarEdit:
            return "Mac 앱이 Apple Calendar 일정을 직접 수정합니다."
        case .calendarApply, .calendarDelete:
            return "Mac 앱이 과제/시험 동기화를 다시 실행합니다."
        case .calendarVerify:
            return "Mac 앱이 캘린더 상태를 다시 확인합니다."
        default:
            return "Mac 앱이 캘린더 요청을 처리합니다."
        }
    }

    func createFileAccessRequest(item: ServerRelaySyncItem) async {
        guard item.kind == "file" else {
            errorMessage = "파일 항목만 열기 링크를 요청할 수 있습니다."
            return
        }
        guard let serverRelayStore else {
            errorMessage = "파일 열기는 서버 릴레이 연결에서만 사용할 수 있습니다."
            userAlert = UserAlert(title: "요청 실패", message: errorMessage)
            return
        }
        isSubmitting = true
        defer {
            isSubmitting = false
        }
        do {
            let request = ServerRelayFileAccessRequest(
                itemID: item.id,
                itemKind: item.kind,
                itemTitle: item.title
            )
            let created = try await serverRelayStore.createFileAccessRequest(request)
            recentFileAccessRequests.insert(created, at: 0)
            connectionMessage = "Mac에 파일 열기 링크를 요청했습니다."
            connectionSucceeded = true
            errorMessage = ""
            userAlert = UserAlert(title: "파일 요청 완료", message: "Mac이 임시 파일 링크를 준비하면 열기 버튼이 표시됩니다.")
            await refreshRecent(includeSyncData: false, showsActivity: false)
        } catch {
            guard !isCancellationError(error) else { return }
            let message = userFacingMessage(for: error)
            errorMessage = message
            userAlert = UserAlert(title: "파일 요청 실패", message: message)
        }
    }

    func openFileAccessRequest(_ request: ServerRelayFileAccessRequest) {
        guard let urlText = request.downloadURL,
              let url = URL(string: urlText),
              request.isDownloadAvailable else {
            errorMessage = "파일 링크가 아직 준비되지 않았거나 만료되었습니다."
            userAlert = UserAlert(title: "파일 열기 실패", message: errorMessage)
            return
        }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #else
        errorMessage = "이 빌드는 외부 URL 열기를 사용할 수 없습니다."
        #endif
    }

    deinit {
        serverRelayEventWebSocketTask?.cancel(with: .goingAway, reason: nil)
        serverRelayEventStreamTask?.cancel()
        pasteboardClearTask?.cancel()
        cancelFollowUpTask?.cancel()
    }

    func latestFileAccessRequest(for item: ServerRelaySyncItem) -> ServerRelayFileAccessRequest? {
        recentFileAccessRequests
            .filter { $0.itemID == item.id }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    func activeItemAction(for item: ServerRelaySyncItem) -> ServerRelayItemAction? {
        recentItemActions
            .filter { $0.itemID == item.id && !$0.status.isFailedLike }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    func refreshRecent(
        silentErrors: Bool = false,
        includeSyncData: Bool? = nil,
        showsActivity: Bool = true
    ) async {
        guard !refreshInProgress else {
            queueRefreshIfNeeded(
                silentErrors: silentErrors,
                includeSyncData: includeSyncData,
                showsActivity: showsActivity
            )
            return
        }
        refreshInProgress = true
        if showsActivity {
            isRefreshing = true
        }
        defer {
            refreshInProgress = false
            if showsActivity {
                isRefreshing = false
            }
            runPendingRefreshIfNeeded()
        }
        do {
            if let serverRelayStore {
                let response = try await serverRelayStore.fetchStatusResponse()
                var didChange = apply(response)
                if let commands = try? await serverRelayStore.fetchRecent(limit: 8), !commands.isEmpty {
                    let visibleCommands = visibleCommands(commands)
                    if recentCommands != visibleCommands {
                        recentCommands = visibleCommands
                        didChange = true
                    }
                    clearFinishedCancelRequestIfNeeded(commands)
                    handleReportNotificationUpdates(commands)
                }
                if shouldFetchSyncData(includeSyncData: includeSyncData),
                   let syncData = try? await serverRelayStore.fetchSyncData(limit: 2000) {
                    didChange = apply(syncData) || didChange
                }
                if let fileRequests = try? await serverRelayStore.fetchRecentFileAccessRequests(limit: 20) {
                    let visibleFileRequests = visibleFileAccessRequests(fileRequests)
                    if recentFileAccessRequests != visibleFileRequests {
                        recentFileAccessRequests = visibleFileRequests
                        didChange = true
                    }
                }
                if let itemActions = try? await serverRelayStore.fetchRecentItemActions(limit: 40) {
                    let visibleItemActions = visibleItemActions(itemActions)
                    if recentItemActions != visibleItemActions {
                        recentItemActions = visibleItemActions
                        didChange = true
                    }
                }
                if let requestLog = try? await serverRelayStore.fetchRecentRequestLog(limit: 30) {
                    let visibleRequestLog = visibleRequestLog(requestLog)
                    if recentRequestLog != visibleRequestLog {
                        recentRequestLog = visibleRequestLog
                        didChange = true
                    }
                }
                if let settingActions = try? await serverRelayStore.fetchRecentSettingActions(limit: 20) {
                    let visibleSettingActions = visibleSettingActions(settingActions)
                    if recentSettingActions != visibleSettingActions {
                        recentSettingActions = visibleSettingActions
                        didChange = true
                    }
                }
                if showsActivity || didChange {
                    lastRefreshAt = Date()
                }
                if showsActivity {
                    connectionMessage = "새로 고침 완료"
                    connectionSucceeded = true
                }
                errorMessage = ""
            } else {
                if showsActivity {
                    connectionMessage = "서버 연결 정보가 없어 새로 고칠 수 없습니다."
                    connectionSucceeded = false
                }
                errorMessage = ""
            }
        } catch {
            guard !isCancellationError(error) else { return }
            if !silentErrors {
                errorMessage = userFacingMessage(for: error)
                if showsActivity {
                    connectionMessage = "새로 고침 실패"
                    connectionSucceeded = false
                }
            }
        }
    }

    private func queueRefreshIfNeeded(
        silentErrors: Bool,
        includeSyncData: Bool?,
        showsActivity: Bool
    ) {
        guard showsActivity || includeSyncData == true || !silentErrors else {
            return
        }
        if pendingRefreshRequest == nil {
            pendingRefreshRequest = PendingRefreshRequest(
                silentErrors: silentErrors,
                includeSyncData: includeSyncData,
                showsActivity: showsActivity
            )
        } else {
            pendingRefreshRequest?.merge(
                silentErrors: silentErrors,
                includeSyncData: includeSyncData,
                showsActivity: showsActivity
            )
        }
        if showsActivity {
            isRefreshing = true
            connectionMessage = "진행 중인 갱신이 끝나면 바로 새로 고침합니다."
            connectionSucceeded = nil
        }
    }

    private func runPendingRefreshIfNeeded() {
        guard let request = pendingRefreshRequest else {
            return
        }
        pendingRefreshRequest = nil
        Task { @MainActor [weak self] in
            await self?.refreshRecent(
                silentErrors: request.silentErrors,
                includeSyncData: request.includeSyncData,
                showsActivity: request.showsActivity
            )
        }
    }

    func resetDisplayState(showConfirmation: Bool = true) {
        errorMessage = ""
        connectionMessage = ""
        connectionSucceeded = nil
        userAlert = nil
        dryRunReports = []
        if showConfirmation {
            connectionMessage = "화면 표시를 정리했습니다."
            connectionSucceeded = true
        }
    }

    func clearRemoteLogs(scope: ServerRelayLogClearScope = .all) async {
        if scope == .fileAccess, recentFileAccessRequests.contains(where: { $0.status.isInFlight }) {
            let message = "파일 요청이 끝난 뒤 파일 요청 기록을 지울 수 있습니다."
            errorMessage = message
            userAlert = UserAlert(title: "로그 지우기 보류", message: message)
            return
        }
        var sharedClearError: String?
        if scope == .all, let serverRelayStore {
            do {
                _ = try await serverRelayStore.clearSharedRunLogs()
                sharedRunLogs = []
                sharedRunLogsSignature = nil
                syncDataNeedsRefresh = true
            } catch {
                sharedClearError = "공유 실행 로그 지우기 실패: \(error.localizedDescription)"
            }
        }
        applyLogClear(scope: scope)
        connectionMessage = sharedClearError ?? (scope == .all ? "화면 기록과 공유 실행 로그를 지웠습니다." : "화면 기록을 지웠습니다.")
        connectionSucceeded = true
        errorMessage = sharedClearError ?? ""
        userAlert = UserAlert(
            title: sharedClearError == nil ? "\(scope.clearTitle) 완료" : "일부 로그 지우기 실패",
            message: sharedClearError ?? (scope == .all ? "이 기기의 화면 기록을 정리했고, 공유 실행 로그는 모든 기기에서 비워집니다." : scope.localClearMessage)
        )
    }

    func clearSharedRunLogs() async {
        guard let serverRelayStore else {
            let message = "서버 연결 정보가 없어 공유 실행 로그를 지울 수 없습니다."
            errorMessage = message
            userAlert = UserAlert(title: "공유 실행 로그 지우기 실패", message: message)
            return
        }
        do {
            let result = try await serverRelayStore.clearSharedRunLogs()
            sharedRunLogs = []
            sharedRunLogsSignature = nil
            syncDataNeedsRefresh = true
            connectionMessage = "공유 실행 로그 \(result.runLogs)개를 지웠습니다."
            connectionSucceeded = true
            errorMessage = ""
            userAlert = UserAlert(title: "공유 실행 로그 지움", message: "모든 기기에서 공유 실행 로그가 비워집니다.")
        } catch {
            let message = "공유 실행 로그 지우기 실패: \(error.localizedDescription)"
            errorMessage = message
            userAlert = UserAlert(title: "공유 실행 로그 지우기 실패", message: message)
        }
    }

    private func applyLogClear(scope: ServerRelayLogClearScope) {
        switch scope {
        case .all:
            locallyHiddenCommandIDs.formUnion(recentCommands.filter { !$0.status.isInFlight }.map(\.id))
            locallyHiddenRequestLogIDs.formUnion(recentRequestLog.map(\.id))
            locallyHiddenFileAccessRequestIDs.formUnion(recentFileAccessRequests.filter { !$0.status.isInFlight }.map(\.id))
            locallyHiddenItemActionIDs.formUnion(recentItemActions.filter { $0.status != .pending && $0.status != .running }.map(\.id))
            locallyHiddenSettingActionIDs.formUnion(recentSettingActions.filter { $0.status != .pending && $0.status != .running }.map(\.id))
            recentCommands = recentCommands.filter { $0.status.isInFlight }
            recentRequestLog = []
            recentFileAccessRequests = recentFileAccessRequests.filter { $0.status.isInFlight }
            recentItemActions = recentItemActions.filter { $0.status == .pending || $0.status == .running }
            recentSettingActions = recentSettingActions.filter { $0.status == .pending || $0.status == .running }
            lastTerminalCommandID = nil
        case .command:
            locallyHiddenCommandIDs.formUnion(recentCommands.filter { !$0.status.isInFlight }.map(\.id))
            recentCommands = recentCommands.filter { $0.status.isInFlight }
            if recentCommands.isEmpty {
                lastTerminalCommandID = nil
            }
        case .requestLog:
            locallyHiddenRequestLogIDs.formUnion(recentRequestLog.map(\.id))
            recentRequestLog = []
        case .fileAccess:
            locallyHiddenFileAccessRequestIDs.formUnion(recentFileAccessRequests.filter { !$0.status.isInFlight }.map(\.id))
            recentFileAccessRequests = recentFileAccessRequests.filter { $0.status.isInFlight }
        }
    }

    private func visibleCommands(_ commands: [RemoteRunCommand]) -> [RemoteRunCommand] {
        commands.filter { $0.status.isInFlight || !locallyHiddenCommandIDs.contains($0.id) }
    }

    private func visibleRequestLog(_ entries: [ServerRelayRequestLogEntry]) -> [ServerRelayRequestLogEntry] {
        entries.filter { !locallyHiddenRequestLogIDs.contains($0.id) }
    }

    private func visibleFileAccessRequests(_ requests: [ServerRelayFileAccessRequest]) -> [ServerRelayFileAccessRequest] {
        requests.filter { $0.status.isInFlight || !locallyHiddenFileAccessRequestIDs.contains($0.id) }
    }

    private func visibleItemActions(_ actions: [ServerRelayItemAction]) -> [ServerRelayItemAction] {
        actions.filter { $0.status == .pending || $0.status == .running || !locallyHiddenItemActionIDs.contains($0.id) }
    }

    private func visibleSettingActions(_ actions: [ServerRelaySettingAction]) -> [ServerRelaySettingAction] {
        actions.filter { $0.status == .pending || $0.status == .running || !locallyHiddenSettingActionIDs.contains($0.id) }
    }

    func checkServerRelayConnection() async {
        connectionMessage = "서버 연결을 확인하는 중..."
        connectionSucceeded = nil
        errorMessage = ""
        isRefreshing = true
        defer {
            isRefreshing = false
        }

        guard let serverRelayStore else {
            let message = "서버 URL과 클라이언트 토큰을 입력해 주세요."
            connectionMessage = message
            connectionSucceeded = false
            errorMessage = message
            userAlert = UserAlert(title: "서버 연결 실패", message: message)
            return
        }

        do {
            let response = try await serverRelayStore.fetchStatusResponse()
            apply(response)
            configureServerRelayEventStream()
            let message = "서버 릴레이와 연결됐습니다."
            connectionMessage = message
            connectionSucceeded = true
            errorMessage = ""
            userAlert = UserAlert(title: "서버 연결 완료", message: message)
            Task { @MainActor in
                await refreshRecent(silentErrors: true, includeSyncData: true, showsActivity: false)
            }
        } catch {
            guard !isCancellationError(error) else { return }
            let message = userFacingMessage(for: error)
            connectionMessage = message
            connectionSucceeded = false
            errorMessage = message
            userAlert = UserAlert(title: "서버 연결 실패", message: message)
        }
    }

    func pasteServerRelayConnectionInfo() {
        #if canImport(UIKit)
        guard let text = UIPasteboard.general.string,
              let connectionInfo = ServerRelayConnectionInfo.parse(urlText: text) else {
            errorMessage = "붙여넣은 텍스트에서 서버 URL과 클라이언트 토큰을 찾지 못했습니다."
            return
        }
        serverURL = connectionInfo.baseURL.absoluteString
        serverToken = ServerRelayConnectionInfo.labeledToken(
            in: text,
            labels: ServerRelayConnectionInfo.clientTokenLabels + ServerRelayConnectionInfo.legacyTokenLabels
        ) ?? connectionInfo.token
        if UIPasteboard.general.string == text {
            UIPasteboard.general.string = ""
        }
        connectionMessage = "서버 연결 정보를 붙여넣었습니다. 이제 서버 연결 확인을 눌러 주세요."
        connectionSucceeded = nil
        errorMessage = ""
        #else
        errorMessage = "이 빌드는 클립보드 붙여넣기를 사용할 수 없습니다."
        #endif
    }

    func copyServerRelayURL() {
        guard let publicURL = publicServerRelayURLForSharing() else {
            errorMessage = "공개 HTTPS 서버 URL만 복사할 수 있습니다. 로컬/사설 주소는 제외했습니다."
            return
        }
        copyToPasteboard(publicURL, clearAfterSeconds: nil)
        connectionMessage = "서버 URL을 복사했습니다."
        connectionSucceeded = true
        errorMessage = ""
    }

    func copyServerRelayClientToken() {
        guard !serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "복사할 클라이언트 토큰이 없습니다."
            return
        }
        copyToPasteboard(serverToken, clearAfterSeconds: 60)
        connectionMessage = "클라이언트 토큰을 복사했습니다. 60초 뒤 클립보드에서 지웁니다."
        connectionSucceeded = true
        errorMessage = ""
    }

    func copyServerRelayConnectionInfo() {
        guard let publicURL = publicServerRelayURLForSharing(),
              !serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "복사할 공개 HTTPS 서버 URL과 클라이언트 토큰이 없습니다."
            return
        }
        let text = """
        KLMS Sync 서버 연결 정보
        서버 URL: \(publicURL)
        클라이언트 토큰: \(serverToken)
        """
        copyToPasteboard(text, clearAfterSeconds: 60)
        connectionMessage = "서버 URL과 클라이언트 토큰을 복사했습니다. 60초 뒤 클립보드에서 지웁니다."
        connectionSucceeded = true
        errorMessage = ""
    }

    private func publicServerRelayURLForSharing() -> String? {
        ServerRelayConnectionInfo.normalizedPublicRelayURL(serverURL)?.absoluteString
    }

    func clearServerRelayConnectionInfo() {
        serverURL = ""
        serverToken = ""
        connectionMessage = "서버 연결 정보를 지웠습니다."
        connectionSucceeded = nil
        errorMessage = ""
    }

    private func copyToPasteboard(_ value: String, clearAfterSeconds: UInt64?) {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        pasteboardClearTask?.cancel()
        guard let clearAfterSeconds else { return }
        pasteboardClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: clearAfterSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            if UIPasteboard.general.string == value {
                UIPasteboard.general.string = ""
            }
            self?.pasteboardClearTask = nil
        }
        #else
        errorMessage = "이 빌드는 클립보드 복사를 사용할 수 없습니다."
        #endif
    }

    func pollRecentCommands() async {
        configureServerRelayEventStream()
        while !Task.isCancelled {
            configureServerRelayEventStream()
            let heavyRefreshAllowed = !hasInFlightRequest
                && status.phase != "running"
                && status.authDigits == nil
            await refreshRecent(
                silentErrors: true,
                includeSyncData: heavyRefreshAllowed ? nil : false,
                showsActivity: false
            )
            let interval: UInt64 = hasInFlightRequest
                || status.phase == "running"
                || status.authDigits != nil
                ? (pendingCancelCommandID == nil ? 350_000_000 : 250_000_000)
                : 4_000_000_000
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    private func configureServerRelayEventStream() {
        guard let serverRelayStore else {
            stopServerRelayEventStream()
            return
        }
        let key = "\(serverURL)|\(serverToken)"
        guard key != serverRelayEventStreamKey || serverRelayEventStreamTask == nil else {
            return
        }
        stopServerRelayEventStream()
        serverRelayEventStreamKey = key
        serverRelayEventStreamTask = Task { [weak self] in
            await self?.runServerRelayEventStream(key: key, store: serverRelayStore)
        }
    }

    private func stopServerRelayEventStream() {
        serverRelayEventWebSocketTask?.cancel(with: .goingAway, reason: nil)
        serverRelayEventWebSocketTask = nil
        serverRelayEventStreamTask?.cancel()
        serverRelayEventStreamTask = nil
        serverRelayEventStreamKey = ""
    }

    private func runServerRelayEventStream(key: String, store: ServerRelayCommandStore) async {
        while !Task.isCancelled, serverRelayEventStreamKey == key {
            do {
                let task = URLSession.shared.webSocketTask(with: store.eventStreamRequest(role: "client"))
                serverRelayEventWebSocketTask = task
                task.resume()
                await refreshRecent(silentErrors: true, includeSyncData: false, showsActivity: false)
                while !Task.isCancelled, serverRelayEventStreamKey == key {
                    let message = try await task.receive()
                    let includeSyncData = Self.relayEventRequiresSyncDataRefresh(message) ? true : nil
                    await refreshRecent(silentErrors: true, includeSyncData: includeSyncData, showsActivity: false)
                }
            } catch {
                if !Task.isCancelled, serverRelayEventStreamKey == key {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    private static func relayEventRequiresSyncDataRefresh(_ message: URLSessionWebSocketTask.Message) -> Bool {
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
            return false
        }
        return event.reason == "sync-data" || event.reason?.hasPrefix("sync-data:") == true
    }

    @discardableResult
    private func apply(_ response: LocalRemoteResponse) -> Bool {
        var didChange = false
        if status != response.status {
            status = response.status
            didChange = true
        }
        if shouldNotifyAuthSuccess(for: response.status) {
            let authStatusMessage = response.status.authStatusMessage ?? "인증 완료됨"
            if shouldPresentAuthSuccessAlert(message: authStatusMessage) {
                userAlert = UserAlert(title: "인증 완료", message: authStatusMessage)
                didChange = true
            }
        }
        if let latestCommand = response.latestCommand {
            let shouldShowLatestCommand = latestCommand.status.isInFlight
                || !locallyHiddenCommandIDs.contains(latestCommand.id)
            if shouldShowLatestCommand {
                if recentCommands.first != latestCommand {
                    recentCommands = [latestCommand]
                    didChange = true
                }
            } else if recentCommands.first?.id == latestCommand.id {
                recentCommands = recentCommands.filter { $0.id != latestCommand.id }
                didChange = true
            }
            clearFinishedCancelRequestIfNeeded([latestCommand])
            if latestCommand.displayStatus().isTerminal,
               latestCommand.id != lastTerminalCommandID {
                lastTerminalCommandID = latestCommand.id
                syncDataNeedsRefresh = true
            }
            handleReportNotificationUpdates([latestCommand])
        }
        return didChange
    }

    private func shouldNotifyAuthSuccess(for status: SanitizedRemoteStatus) -> Bool {
        guard let message = status.authStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty,
              status.authDigits == nil,
              !status.loginRequired,
              status.phase == "running" else {
            return false
        }
        return true
    }

    private func shouldPresentAuthSuccessAlert(message: String, now: Date = Date()) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            lastAuthSuccessAlertMessage = normalized
            lastAuthSuccessAlertAt = now
        }
        guard normalized != lastAuthSuccessAlertMessage else {
            guard let lastAuthSuccessAlertAt else {
                return true
            }
            return now.timeIntervalSince(lastAuthSuccessAlertAt) > 90
        }
        return true
    }

    private func shouldFetchSyncData(includeSyncData: Bool?) -> Bool {
        if includeSyncData == true {
            return true
        }
        if includeSyncData == false {
            return false
        }
        if syncDataNeedsRefresh {
            return true
        }
        guard let lastSyncDataRefreshAt else {
            return true
        }
        return Date().timeIntervalSince(lastSyncDataRefreshAt) >= syncDataStaleInterval
    }

    @discardableResult
    private func apply(_ syncData: ServerRelaySyncData) -> Bool {
        var didChange = false
        let nextSyncItemsSignature = Self.signature(for: syncData.items)
        if syncItemsSignature != nextSyncItemsSignature {
            syncItems = syncData.items
            syncItemsSignature = nextSyncItemsSignature
            didChange = true
        }
        if dryRunReports != syncData.dryRunReports {
            dryRunReports = syncData.dryRunReports
            didChange = true
        }
        let nextCalendarChangesSignature = Self.signature(for: syncData.calendarChanges)
        if calendarChangesSignature != nextCalendarChangesSignature {
            calendarChanges = syncData.calendarChanges
            calendarChangesSignature = nextCalendarChangesSignature
            didChange = true
        }
        let nextRemoteSettingsSignature = Self.signature(for: syncData.settings)
        if remoteSettingsSignature != nextRemoteSettingsSignature {
            remoteSettings = syncData.settings
            remoteSettingsSignature = nextRemoteSettingsSignature
            didChange = true
        }
        let nextSharedRunLogsSignature = Self.signature(for: syncData.runLogs)
        if sharedRunLogsSignature != nextSharedRunLogsSignature {
            sharedRunLogs = syncData.runLogs
            sharedRunLogsSignature = nextSharedRunLogsSignature
            didChange = true
        }
        lastSyncDataRefreshAt = Date()
        syncDataNeedsRefresh = false
        return didChange
    }

    private static func signature(for items: [ServerRelaySyncItem]) -> Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.kind)
            hasher.combine(item.status)
            hasher.combine(item.updatedAt)
            hasher.combine(item.isRead)
            hasher.combine(item.isImportant)
            hasher.combine(item.isHidden)
        }
        return hasher.finalize()
    }

    private static func signature(for changes: [CalendarChange]) -> Int {
        var hasher = Hasher()
        hasher.combine(changes.count)
        for change in changes {
            hasher.combine(change.id)
            hasher.combine(change.action)
            hasher.combine(change.changes.joined(separator: "|"))
        }
        return hasher.finalize()
    }

    private static func signature(for settings: [ServerRelaySetting]) -> Int {
        var hasher = Hasher()
        hasher.combine(settings.count)
        for setting in settings {
            hasher.combine(setting.key)
            hasher.combine(setting.value)
            hasher.combine(setting.updatedAt)
            hasher.combine(setting.editable)
        }
        return hasher.finalize()
    }

    private static func signature(for logs: [ServerRelayRunLog]) -> Int {
        var hasher = Hasher()
        hasher.combine(logs.count)
        for log in logs {
            hasher.combine(log.id)
            hasher.combine(log.status)
            hasher.combine(log.updatedAt)
            hasher.combine(log.outputTail)
        }
        return hasher.finalize()
    }

    private func trackReportNotificationIfNeeded(for command: RemoteRunCommand) {
        guard command.kind == .report else {
            return
        }
        trackedReportNotificationCommandIDs.insert(command.id)
        persistTrackedReportNotificationCommandIDs()
    }

    private func handleReportNotificationUpdates(_ commands: [RemoteRunCommand]) {
        for command in commands {
            notifyReportRefreshResultIfNeeded(command)
        }
    }

    private func markCancelRequestedLocally(commandID: UUID) {
        guard let index = recentCommands.firstIndex(where: { $0.id == commandID }) else {
            return
        }
        var command = recentCommands[index]
        command.summary.phase = "running"
        command.summary.phaseDetail = "중단 요청됨"
        command.updatedAt = Date()
        recentCommands[index] = command
        status = command.summary
        lastRefreshAt = Date()
    }

    private func startCancelFollowUp(commandID: UUID) {
        cancelFollowUpTask?.cancel()
        cancelFollowUpTask = Task { @MainActor [weak self] in
            var attempts = 0
            while !Task.isCancelled, attempts < 60 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self,
                      self.pendingCancelCommandID == commandID else {
                    return
                }
                await self.refreshRecent(
                    silentErrors: true,
                    includeSyncData: false,
                    showsActivity: false
                )
                if self.pendingCancelCommandID != commandID {
                    return
                }
                attempts += 1
            }
            guard let self,
                  self.pendingCancelCommandID == commandID else {
                return
            }
            self.connectionMessage = "Mac의 중단 완료 응답을 기다리는 중입니다."
            self.connectionSucceeded = nil
        }
    }

    private func clearFinishedCancelRequestIfNeeded(_ commands: [RemoteRunCommand]) {
        guard let pendingCancelCommandID else {
            return
        }
        guard let command = commands.first(where: { $0.id == pendingCancelCommandID }) else {
            if latestCommand?.id != pendingCancelCommandID {
                self.pendingCancelCommandID = nil
                pendingCancelRequestedAt = nil
                cancelFollowUpTask?.cancel()
                cancelFollowUpTask = nil
            }
            return
        }
        if command.displayStatus().isTerminal {
            self.pendingCancelCommandID = nil
            pendingCancelRequestedAt = nil
            cancelFollowUpTask?.cancel()
            cancelFollowUpTask = nil
            syncDataNeedsRefresh = true
            connectionMessage = "\(command.kind.displayName) 실행이 중단됐습니다."
            connectionSucceeded = true
            if !notifiedCancelCompletionCommandIDs.contains(command.id) {
                notifiedCancelCompletionCommandIDs.insert(command.id)
                userAlert = UserAlert(
                    title: "동기화 중단됨",
                    message: "\(command.kind.displayName) 실행이 Mac에서 중단됐습니다."
                )
            }
        }
    }

    private func notifyReportRefreshResultIfNeeded(_ command: RemoteRunCommand) {
        guard command.kind == .report,
              trackedReportNotificationCommandIDs.contains(command.id) else {
            return
        }
        let displayStatus = command.displayStatus()
        guard displayStatus.isTerminal else {
            return
        }
        trackedReportNotificationCommandIDs.remove(command.id)
        persistTrackedReportNotificationCommandIDs()
        postReportRefreshNotification(command: command, displayStatus: displayStatus)
    }

    private func postReportRefreshNotification(
        command: RemoteRunCommand,
        displayStatus: RemoteCommandStatus
    ) {
        #if canImport(UserNotifications)
        let title: String
        let body: String
        switch displayStatus {
        case .completed:
            title = "요약 갱신 완료"
            body = "대시보드 요약이 갱신됐습니다. 과제 \(command.summary.assignments)개 · 시험 \(command.summary.exams)개 · 새 파일 \(command.summary.newFiles)개"
        case .failed:
            title = "요약 갱신 실패"
            if let lastExitCode = command.lastExitCode {
                body = "Mac 앱에서 요약 갱신이 실패했습니다. 종료 코드 \(lastExitCode). 기록 탭에서 오류를 확인해 주세요."
            } else {
                body = "Mac 앱에서 요약 갱신이 실패했습니다. 기록 탭에서 오류를 확인해 주세요."
            }
        case .cancelled:
            title = "요약 갱신 취소됨"
            body = "Mac 앱이 처리하기 전에 요약 갱신 요청이 취소됐습니다."
        case .macUnavailable:
            title = "요약 갱신 확인 지연"
            body = "Mac 앱이 아직 요약 갱신 요청을 확인하지 못했습니다. Mac 앱이 켜져 있는지 확인해 주세요."
        case .pending, .running:
            return
        }

        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "klms-report-refresh-\(command.id.uuidString)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
        #endif
    }

    private func persistTrackedReportNotificationCommandIDs() {
        UserDefaults.standard.set(
            trackedReportNotificationCommandIDs.map(\.uuidString).sorted(),
            forKey: Self.trackedReportNotificationCommandIDsKey
        )
    }

    private static func loadTrackedReportNotificationCommandIDs() -> Set<UUID> {
        let values = UserDefaults.standard.stringArray(forKey: trackedReportNotificationCommandIDsKey) ?? []
        return Set(values.compactMap(UUID.init(uuidString:)))
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func userFacingMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "인터넷 연결을 확인해 주세요."
            case .timedOut:
                return "서버 응답 시간이 초과됐습니다. 잠시 뒤 다시 시도해 주세요."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "서버 URL을 찾지 못했습니다. 연결 설정의 서버 URL을 확인해 주세요."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return "서버 보안 연결을 확인하지 못했습니다. HTTPS 주소와 인증서를 확인해 주세요."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private static func persistServerToken(_ token: String) {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            LocalRemoteTokenStore.delete(account: "server-relay-ios")
            UserDefaults.standard.removeObject(forKey: Self.serverTokenKey)
            return
        }
        if LocalRemoteTokenStore.save(trimmedToken, account: "server-relay-ios") {
            UserDefaults.standard.removeObject(forKey: Self.serverTokenKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.serverTokenKey)
        }
    }

    private static func clearDeprecatedLocalConnectionInfo() {
        UserDefaults.standard.removeObject(forKey: Self.deprecatedLocalHostKey)
        UserDefaults.standard.removeObject(forKey: Self.deprecatedLocalPortKey)
        UserDefaults.standard.removeObject(forKey: Self.deprecatedLocalTokenKey)
        LocalRemoteTokenStore.delete(account: "ios")
    }
}

struct UserAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct CompanionRootView: View {
    @StateObject private var model = CompanionModel()

    var body: some View {
        TabView {
            CompanionStatusScreen(model: model)
                .tabItem {
                    Label("상태", systemImage: "gauge")
                }
            CompanionRunScreen(model: model)
                .tabItem {
                    Label("실행", systemImage: "play.circle")
                }
            CompanionConnectionScreen(model: model)
                .tabItem {
                    Label("연결", systemImage: "macbook.and.iphone")
                }
            CompanionHistoryScreen(model: model)
                .tabItem {
                    Label("기록", systemImage: "clock.arrow.circlepath")
            }
        }
        .background(Color.klmsScreenBackground.ignoresSafeArea())
        .tint(.klmsCommandAccent)
        .klmsTabChrome()
        .task {
            await model.pollRecentCommands()
        }
        .alert(item: $model.userAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("확인"))
            )
        }
    }
}

private struct CompanionStatusScreen: View {
    @ObservedObject var model: CompanionModel
    @State private var selectedDashboardPreview: DashboardMetricCategory?

    var body: some View {
        CompanionScreenContainer(title: "상태", model: model) {
            Group {
                RemoteAttentionStack(model: model)
                RemoteLogSummaryPanel(model: model, compact: true)
                RemoteStatusHeader(
                    model: model,
                    selectedCategory: $selectedDashboardPreview,
                    onCategoryTap: { category in
                        selectedDashboardPreview = category
                    }
                )
                if let category = selectedDashboardPreview {
                    DashboardCategoryInlineDetailPanel(
                        category: category,
                        model: model
                    )
                    .id(category)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

private struct CompanionRunScreen: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        CompanionScreenContainer(title: "실행", model: model) {
            RemoteAttentionStack(model: model)
            RemoteLogSummaryPanel(model: model, compact: true)
            RemoteCommandPanel(model: model, compact: false)
            RemoteCancelControl(model: model, compact: false)
            RemoteRunRequestHistoryPanel(model: model)
            RemoteSettingsPanel(model: model)
            RemoteDiagnosticPanel(model: model)
            InfoBanner(message: "iPhone은 KLMS를 직접 읽지 않고 Mac 앱에 실행 요청만 보냅니다. Cloudflare 서버 릴레이를 사용하면 같은 Wi‑Fi에 있지 않아도 요청할 수 있지만, 실제 동기화는 Mac 앱이 켜져 있을 때만 실행됩니다.")
        }
    }
}

private struct CompanionConnectionScreen: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        CompanionScreenContainer(title: "서버 연결", model: model) {
            ServerRelayConnectionPanel(model: model)
            if !model.serverRelayConfigured {
                InfoBanner(message: model.remoteAvailabilityMessage)
            }
            RemotePrivacyNote()
        }
    }
}

private struct CompanionHistoryScreen: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        CompanionScreenContainer(title: "요청 기록", model: model) {
            RemoteAttentionStack(model: model)
            RemoteLogSummaryPanel(model: model, compact: false)
            SharedRunLogsView(
                logs: model.sharedRunLogs,
                clearAction: {
                    Task {
                        await model.clearSharedRunLogs()
                    }
                },
                clearDisabled: !model.serverRelayConfigured || model.isSubmitting || model.sharedRunLogs.isEmpty
            )
            RecentServerRequestLogView(
                entries: model.recentRequestLog,
                clearAction: {
                    Task {
                        await model.clearRemoteLogs(scope: .requestLog)
                    }
                },
                clearDisabled: !model.serverRelayConfigured || model.isSubmitting || model.recentRequestLog.isEmpty
            )
            RecentFileAccessRequestsView(
                requests: model.recentFileAccessRequests,
                clearAction: {
                    Task {
                        await model.clearRemoteLogs(scope: .fileAccess)
                    }
                },
                clearDisabled: !model.serverRelayConfigured
                    || model.isSubmitting
                    || model.recentFileAccessRequests.isEmpty
                    || model.recentFileAccessRequests.contains { $0.status.isInFlight }
            )
            RecentRemoteCommandsView(
                commands: model.recentCommands,
                compact: false,
                clearAction: {
                    Task {
                        await model.clearRemoteLogs(scope: .command)
                    }
                },
                clearDisabled: !model.serverRelayConfigured
                    || model.isSubmitting
                    || !model.recentCommands.contains { !$0.status.isInFlight }
            )
        }
    }
}

private struct CompanionScreenContainer<Content: View>: View {
    var title: String
    @ObservedObject var model: CompanionModel
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            ZStack {
                Color.klmsScreenBackground.ignoresSafeArea()
                WholeScreenVerticalScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        CompanionScreenHeader(title: title, model: model)
                        content()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .navigationTitle(title)
            .klmsNavigationTitleMode()
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        Task {
                            await model.refreshRecent(includeSyncData: true)
                        }
                    } label: {
                        Label("새로 고침", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshing)

                    Button {
                        model.resetDisplayState()
                    } label: {
                        Label("화면 정리", systemImage: "eraser")
                    }
                    .disabled(model.isRefreshing || model.isSubmitting)
                }
            }
            .refreshable {
                await model.refreshRecent(includeSyncData: true)
            }
            .klmsNavigationChrome()
        }
    }
}

private struct CompanionScreenHeader: View {
    var title: String
    @ObservedObject var model: CompanionModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(model.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else if let lastRefreshAt = model.lastRefreshAt {
                Text(lastRefreshAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private var iconName: String {
        if model.status.authDigits != nil {
            return "key.fill"
        }
        if model.hasInFlightRequest || model.status.phase == "running" {
            return "arrow.triangle.2.circlepath"
        }
        if model.status.loginRequired {
            return "person.crop.circle.badge.exclamationmark"
        }
        switch title {
        case "실행":
            return "play.circle.fill"
        case "서버 연결":
            return "network"
        case "요청 기록":
            return "clock.arrow.circlepath"
        default:
            return "gauge.with.dots.needle.67percent"
        }
    }

    private var tint: Color {
        if model.status.authDigits != nil || model.status.loginRequired {
            return .orange
        }
        if model.hasInFlightRequest || model.status.phase == "running" {
            return .klmsCommandAccent
        }
        if model.latestDisplayStatus == .failed || model.latestDisplayStatus == .macUnavailable {
            return .orange
        }
        if model.shouldShowAuthCompletion {
            return .green
        }
        if title == "실행" {
            return .klmsCommandAccent
        }
        return .klmsCommandAccent
    }
}

private struct WholeScreenVerticalScrollView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                content
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
            }
            .scrollIndicators(.visible)
            .background(Color.klmsScreenBackground)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
        }
    }
}

private struct RemoteAttentionStack: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let authDigits = model.status.authDigits {
                AuthCodeHero(digits: authDigits)
            }
            if let message = model.loginAttentionMessage {
                LoginAttentionBanner(message: message)
            }
            if let message = model.authSuccessMessage {
                AuthSuccessBanner(message: message)
            }
            if !model.errorMessage.isEmpty {
                ErrorBanner(message: model.errorMessage)
            }
        }
    }
}

private struct ServerRelayConnectionPanel: View {
    @ObservedObject var model: CompanionModel
    @State private var showConnectionFields = false
    private let actionColumns = [
        GridItem(.adaptive(minimum: 145), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: model.serverRelayConfigured ? "checkmark.circle.fill" : "server.rack")
                    .foregroundStyle(model.serverRelayConfigured ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("서버 릴레이")
                        .font(.headline)
                    Text(model.serverRelayConfigured ? "서버 연결 정보가 저장되어 있습니다." : "Cloudflare 릴레이 연결 정보를 붙여넣어 주세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if !model.connectionMessage.isEmpty {
                ConnectionNoticeBanner(
                    message: model.connectionMessage,
                    succeeded: model.connectionSucceeded
                )
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showConnectionFields.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Label("서버 릴레이 정보", systemImage: "link")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(model.serverRelayConfigured ? "저장됨" : "미설정")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.serverRelayConfigured ? .green : .secondary)
                    Image(systemName: showConnectionFields ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityHint(showConnectionFields ? "서버 정보 접기" : "서버 정보 펼치기")

            if showConnectionFields {
                VStack(alignment: .leading, spacing: 8) {
                    CompanionSettingHelpText("서버 URL에는 Cloudflare Worker 같은 공개 HTTPS 주소만 넣습니다. 집 주소, 로컬 IP, Mac의 사설 주소는 저장하지 않습니다.")
                    TextField("서버 URL", text: $model.serverURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    CompanionSettingHelpText("클라이언트 토큰은 iPhone/Windows용 토큰입니다. 상태 조회와 실행 요청만 할 수 있으며, Mac 전용 토큰은 여기에 넣지 않습니다.")
                    SecureField("클라이언트 토큰", text: $model.serverToken)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    CompanionSettingHelpText("Mac 앱에는 같은 서버 URL과 별도의 Mac 전용 토큰이 저장되어 있어야 합니다. 실제 KLMS 동기화는 Mac 앱이 처리합니다.")
                }
                .padding(.top, 8)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("연결")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: actionColumns, spacing: 8) {
                    connectionButton("붙여넣기", systemImage: "doc.on.clipboard") {
                        model.pasteServerRelayConnectionInfo()
                    }
                    connectionAsyncButton("연결 확인", systemImage: "checkmark.seal") {
                        await model.checkServerRelayConnection()
                    }
                    .disabled(!model.serverRelayConfigured || model.isRefreshing)
                    connectionAsyncButton("요약 갱신", systemImage: "arrow.triangle.2.circlepath") {
                        await model.createCommand(.report)
                    }
                    .disabled(!model.serverRelayConfigured || model.isSubmitting || model.hasInFlightRequest)
                }
                CompanionSettingHelpText("붙여넣기는 복사한 서버 연결 정보를 한 번에 입력합니다. 연결 확인은 저장된 URL과 토큰으로 서버 응답만 검사합니다. 요약 갱신은 Mac 앱에 최신 상태를 다시 올려 달라고 요청합니다.")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("복사")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: actionColumns, spacing: 8) {
                    connectionButton("URL 복사", systemImage: "link") {
                        model.copyServerRelayURL()
                    }
                    .disabled(model.serverURL.isEmpty)
                    connectionButton("연결 정보 복사", systemImage: "doc.on.doc") {
                        model.copyServerRelayConnectionInfo()
                    }
                    .disabled(model.serverURL.isEmpty || model.serverToken.isEmpty)
                    connectionButton("클라이언트 토큰 복사", systemImage: "key") {
                        model.copyServerRelayClientToken()
                    }
                    .disabled(model.serverToken.isEmpty)
                }
                CompanionSettingHelpText("복사된 토큰은 보안을 위해 60초 뒤 클립보드에서 자동으로 지워집니다.")
            }

            Button(role: .destructive) {
                model.clearServerRelayConnectionInfo()
            } label: {
                Label("연결 정보 지우기", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!model.serverRelayConfigured && model.serverURL.isEmpty && model.serverToken.isEmpty)
        }
        .padding(12)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private func connectionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.bordered)
    }

    private func connectionAsyncButton(
        _ title: String,
        systemImage: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task {
                await action()
            }
        } label: {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.bordered)
    }
}

private struct ConnectionNoticeBanner: View {
    var message: String
    var succeeded: Bool?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var systemImage: String {
        switch succeeded {
        case .some(true):
            return "checkmark.circle.fill"
        case .some(false):
            return "exclamationmark.triangle.fill"
        case nil:
            return "hourglass"
        }
    }

    private var tint: Color {
        switch succeeded {
        case .some(true):
            return .green
        case .some(false):
            return .orange
        case nil:
            return .blue
        }
    }
}

private enum DashboardMetricCategory: String, CaseIterable, Identifiable {
    case assignments
    case exams
    case notices
    case files
    case quarantine
    case calendar
    case helpDesk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assignments:
            "과제"
        case .exams:
            "시험"
        case .notices:
            "공지"
        case .files:
            "파일"
        case .quarantine:
            "격리"
        case .calendar:
            "캘린더"
        case .helpDesk:
            "헬프데스크"
        }
    }

    var systemImage: String {
        switch self {
        case .assignments:
            "checklist"
        case .exams:
            "calendar"
        case .notices:
            "note.text"
        case .files:
            "folder.badge.plus"
        case .quarantine:
            "exclamationmark.triangle"
        case .calendar:
            "calendar.badge.clock"
        case .helpDesk:
            "person.2"
        }
    }

    var tint: Color {
        switch self {
        case .assignments:
            .orange
        case .exams, .calendar:
            .green
        case .notices:
            .brown
        case .files:
            .blue
        case .quarantine:
            .red
        case .helpDesk:
            .teal
        }
    }

    var supportsNewOnly: Bool {
        switch self {
        case .notices, .files:
            true
        default:
            false
        }
    }

    var supportsRecentOnly: Bool {
        switch self {
        case .notices, .files:
            true
        default:
            false
        }
    }

    func value(from status: SanitizedRemoteStatus) -> Int {
        switch self {
        case .assignments:
            status.assignments
        case .exams:
            status.exams
        case .notices:
            status.notices
        case .files:
            status.fileTotal
        case .quarantine:
            status.quarantine
        case .calendar:
            status.calendarChangeTotal
        case .helpDesk:
            status.helpDesk
        }
    }

    func includes(_ item: ServerRelaySyncItem) -> Bool {
        switch self {
        case .assignments:
            item.kind == "assignment" || item.kind == "completedAssignment" || item.kind == "assignmentCandidate"
        case .exams:
            item.kind == "exam" || item.kind == "examCandidate"
        case .notices:
            item.kind == "notice"
        case .files:
            item.kind == "file"
        case .helpDesk:
            item.kind == "helpDesk"
        case .quarantine, .calendar:
            false
        }
    }

    var emptyMessage: String {
        switch self {
        case .assignments:
            "서버 DB에 올라온 진행 중 과제가 없습니다."
        case .exams:
            "서버 DB에 올라온 예정 시험이 없습니다."
        case .notices:
            "서버 DB에 올라온 공지 목록이 없습니다."
        case .files:
            "서버 DB에 올라온 파일 목록이 없습니다."
        case .quarantine:
            "격리 파일 상세는 아직 Mac 앱 파일 화면에서 확인해야 합니다."
        case .calendar:
            "캘린더 변경 상세는 Mac 앱의 캘린더 변경 화면에서 확인해야 합니다."
        case .helpDesk:
            "서버 DB에 올라온 헬프데스크 일정이 없습니다."
        }
    }
}

private enum CompanionItemSortOption: String, CaseIterable, Identifiable {
    case recent
    case updated
    case course
    case title
    case kind
    case status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent:
            "최신"
        case .updated:
            "갱신"
        case .course:
            "과목"
        case .title:
            "제목"
        case .kind:
            "종류"
        case .status:
            "상태"
        }
    }
}

private enum CompanionItemVisibilityFilter: String, CaseIterable, Identifiable {
    case visible
    case all
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visible:
            "보이는 항목"
        case .all:
            "전체"
        case .hidden:
            "숨김만"
        }
    }

    func includes(_ item: ServerRelaySyncItem) -> Bool {
        switch self {
        case .visible:
            !item.isHidden
        case .all:
            true
        case .hidden:
            item.isHidden
        }
    }
}

private enum CompanionItemStatusFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case completed
    case candidates
    case unread
    case read
    case important
    case changed
    case withAttachments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "전체"
        case .active:
            "진행 중"
        case .completed:
            "완료"
        case .candidates:
            "후보"
        case .unread:
            "안 읽음"
        case .read:
            "읽음"
        case .important:
            "중요"
        case .changed:
            "새/수정"
        case .withAttachments:
            "첨부 있음"
        }
    }

    static func defaultFilter(for category: DashboardMetricCategory?) -> CompanionItemStatusFilter {
        switch category {
        case .assignments, .exams:
            .active
        default:
            .all
        }
    }

    static func options(for category: DashboardMetricCategory?, items: [ServerRelaySyncItem]) -> [CompanionItemStatusFilter] {
        let candidates: [CompanionItemStatusFilter]
        switch category {
        case .assignments:
            candidates = [.active, .all, .completed, .candidates, .changed]
        case .exams:
            candidates = [.active, .all, .candidates, .changed]
        case .notices:
            candidates = [.all, .unread, .important, .read, .changed, .withAttachments]
        case .files:
            candidates = [.all, .changed, .withAttachments]
        case .helpDesk:
            candidates = [.all, .changed]
        case .calendar, .quarantine:
            candidates = [.all]
        case nil:
            candidates = [.all, .active, .unread, .important, .completed, .candidates, .changed, .withAttachments]
        }
        return candidates.filter { filter in
            switch filter {
            case .all:
                true
            case .active:
                items.contains { filter.includes($0) }
            case .completed, .candidates, .unread, .read, .important, .changed, .withAttachments:
                items.contains { filter.includes($0) }
            }
        }
    }

    func includes(_ item: ServerRelaySyncItem) -> Bool {
        switch self {
        case .all:
            true
        case .active:
            item.kind == "assignment" || item.kind == "exam" || item.kind == "helpDesk"
        case .completed:
            item.kind == "completedAssignment" || item.searchText.localizedCaseInsensitiveContains("완료") || item.searchText.localizedCaseInsensitiveContains("completed")
        case .candidates:
            item.kind == "assignmentCandidate" || item.kind == "examCandidate"
        case .unread:
            item.kind == "notice" && !item.isRead
        case .read:
            item.kind == "notice" && item.isRead
        case .important:
            item.kind == "notice" && item.isImportant
        case .changed:
            item.isCompanionChangedLike
        case .withAttachments:
            item.attachmentCount > 0
        }
    }
}

private enum CompanionItemListFilter {
    static let allCourses = "전체 과목"
    static let allYears = "전체 년도"
    static let allSemesters = "전체 학기"

    static func courseOptions(for items: [ServerRelaySyncItem]) -> [String] {
        let courses = Set(
            items
                .map { $0.course.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        return [allCourses] + courses.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func yearOptions(for items: [ServerRelaySyncItem]) -> [String] {
        let years = Set(items.compactMap(\.academicYear))
        return [allYears] + years.sorted(by: >).map(String.init)
    }

    static func semesterOptions(for items: [ServerRelaySyncItem]) -> [String] {
        let semesters = Set(
            items
                .map { $0.academicSemester.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let ordered = ["봄학기", "가을학기"].filter { semesters.contains($0) }
        let rest = semesters.subtracting(ordered).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [allSemesters] + ordered + rest
    }
}

private struct CompanionItemListControls: View {
    @Binding var sortOption: CompanionItemSortOption
    @Binding var visibilityFilter: CompanionItemVisibilityFilter
    @Binding var statusFilter: CompanionItemStatusFilter
    @Binding var selectedCourse: String
    @Binding var selectedYear: String
    @Binding var selectedSemester: String
    @Binding var newOnly: Bool
    @Binding var recentOnly: Bool
    var availableStatusFilters: [CompanionItemStatusFilter]
    var courseOptions: [String]
    var yearOptions: [String]
    var semesterOptions: [String]
    var supportsNewOnly: Bool
    var supportsRecentOnly: Bool
    var defaultStatusFilter: CompanionItemStatusFilter
    var totalCount: Int
    var filteredCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("\(filteredCount) / \(totalCount)개 표시", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if hasActiveFilter {
                    Button {
                        resetFilters()
                    } label: {
                        Label("초기화", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            CompanionControlBox(title: "정렬", systemImage: "arrow.up.arrow.down") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(CompanionItemSortOption.allCases) { option in
                            companionChoiceChip(
                                title: option.title,
                                isSelected: sortOption == option
                            ) {
                                sortOption = option
                            }
                        }
                    }
                }
            }

            CompanionControlBox(title: "범위", systemImage: "line.3.horizontal.decrease.circle") {
                VStack(alignment: .leading, spacing: 8) {
                    if courseOptions.count > 1 {
                        companionPickerField(title: "과목", systemImage: "book.closed") {
                            Picker("과목", selection: $selectedCourse) {
                                ForEach(courseOptions, id: \.self) { course in
                                    Text(course).tag(course)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    HStack(spacing: 8) {
                        if yearOptions.count > 1 {
                            companionPickerField(title: "년도", systemImage: "calendar") {
                                Picker("년도", selection: $selectedYear) {
                                    ForEach(yearOptions, id: \.self) { year in
                                        Text(year).tag(year)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                        }

                        if semesterOptions.count > 1 {
                            companionPickerField(title: "학기", systemImage: "calendar.badge.clock") {
                                Picker("학기", selection: $selectedSemester) {
                                    ForEach(semesterOptions, id: \.self) { semester in
                                        Text(semester).tag(semester)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                        }
                    }

                    if courseOptions.count <= 1 && yearOptions.count <= 1 && semesterOptions.count <= 1 {
                        Text("전체 범위")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if availableStatusFilters.count > 1 {
                CompanionControlBox(title: "상태", systemImage: "checklist") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(availableStatusFilters) { filter in
                                companionChoiceChip(
                                    title: filter.title,
                                    isSelected: statusFilter == filter
                                ) {
                                    statusFilter = filter
                                }
                            }
                        }
                    }
                }
            }

            CompanionControlBox(title: "표시", systemImage: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(CompanionItemVisibilityFilter.allCases) { option in
                                companionChoiceChip(
                                    title: option.title,
                                    isSelected: visibilityFilter == option
                                ) {
                                    visibilityFilter = option
                                }
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        if supportsNewOnly {
                            filterToggle("새 항목만", isOn: $newOnly)
                        }
                        if supportsRecentOnly {
                            filterToggle("최근 변경만", isOn: $recentOnly)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var hasActiveFilter: Bool {
        visibilityFilter != .visible
            || statusFilter != defaultStatusFilter
            || selectedCourse != CompanionItemListFilter.allCourses
            || selectedYear != CompanionItemListFilter.allYears
            || selectedSemester != CompanionItemListFilter.allSemesters
            || newOnly
            || recentOnly
    }

    private func filterToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        companionChoiceChip(title: title, isSelected: isOn.wrappedValue) {
            isOn.wrappedValue.toggle()
        }
    }

    private func companionChoiceChip(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.klmsSubtleCardBackground, in: Capsule())
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .overlay {
                    Capsule()
                        .stroke(isSelected ? Color.accentColor.opacity(0.42) : Color.klmsBorder, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func companionPickerField<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private func resetFilters() {
        sortOption = .recent
        visibilityFilter = .visible
        statusFilter = defaultStatusFilter
        selectedCourse = CompanionItemListFilter.allCourses
        selectedYear = CompanionItemListFilter.allYears
        selectedSemester = CompanionItemListFilter.allSemesters
        newOnly = false
        recentOnly = false
    }
}

private struct CompanionControlBox<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }
}

private struct RemoteStatusHeader: View {
    @ObservedObject var model: CompanionModel
    @Binding var selectedCategory: DashboardMetricCategory?
    var onCategoryTap: (DashboardMetricCategory) -> Void = { _ in }

    private let columns = [
        GridItem(.adaptive(minimum: 96), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 42, height: 42)
                    .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.headline.weight(.semibold))
                    Text(model.statusLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(statusMetadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.isRefreshing {
                    Label("갱신 중", systemImage: "arrow.clockwise")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(statusColor.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            metricSection("주요 항목", categories: primaryMetricCategories)
            metricSection("확인 필요", categories: attentionMetricCategories)

            if model.status.hasCompanionChangeSummary {
                Divider()
                RemoteDashboardChangeSummary(status: model.status)
            }
        }
        .padding(16)
        .background(statusBackground, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusColor.opacity(0.24), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func metricSection(_ title: String, categories: [DashboardMetricCategory]) -> some View {
        if !categories.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(categories) { category in
                        metricTile(category)
                    }
                }
            }
        }
    }

    private func metricTile(
        _ category: DashboardMetricCategory,
        label: String? = nil
    ) -> some View {
        RemoteMetricTile(
            label ?? category.title,
            category.value(from: model.status),
            systemImage: category.systemImage,
            isSelected: selectedCategory == category
        ) {
            selectedCategory = category
            onCategoryTap(category)
        }
    }

    private var primaryMetricCategories: [DashboardMetricCategory] {
        [
            .assignments,
            .exams,
            .notices,
            .files,
            .helpDesk,
        ].filter { $0.value(from: model.status) > 0 }
    }

    private var attentionMetricCategories: [DashboardMetricCategory] {
        [
            .quarantine,
            .calendar,
        ].filter { $0.value(from: model.status) > 0 }
    }

    private var statusTitle: String {
        if model.status.authDigits != nil {
            return "인증 번호 선택 필요"
        }
        if model.status.loginRequired {
            return "KLMS 로그인 필요"
        }
        if model.shouldShowAuthCompletion {
            return "인증 완료"
        }
        guard let latest = model.latestCommand,
              let status = model.latestDisplayStatus else {
            return "대기 중"
        }
        return "\(latest.kind.displayName) · \(status.displayName)"
    }

    private var statusMetadata: String {
        let phase = if model.status.phase == "running", let detail = model.runningPhaseDetail {
            "\(model.status.phase.klmsRemotePhaseName): \(detail)"
        } else {
            model.status.phase.klmsRemotePhaseName
        }
        if let lastRefreshAt = model.lastRefreshAt {
            return "\(phase) · \(lastRefreshAt.formatted(date: .omitted, time: .shortened)) 갱신"
        }
        return phase
    }

    private var statusImage: String {
        if model.status.authDigits != nil {
            return "key"
        }
        if model.status.loginRequired {
            return "person.crop.circle.badge.exclamationmark"
        }
        if model.shouldShowAuthCompletion {
            return "checkmark.circle.fill"
        }
        switch model.latestDisplayStatus {
        case .pending:
            return "clock"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "xmark.octagon"
        case .cancelled:
            return "stop.circle"
        case .macUnavailable:
            return "macbook.and.iphone"
        case nil:
            return "iphone"
        }
    }

    private var statusColor: Color {
        if model.status.authDigits != nil {
            return .orange
        }
        if model.status.loginRequired {
            return .orange
        }
        if model.shouldShowAuthCompletion {
            return .green
        }
        switch model.latestDisplayStatus {
        case .pending, .running:
            return .blue
        case .completed:
            return .green
        case .cancelled:
            return .secondary
        case .failed, .macUnavailable:
            return .orange
        case nil:
            return .secondary
        }
    }

    private var statusBackground: Color {
        if model.status.authDigits != nil {
            return Color.orange.opacity(0.10)
        }
        if model.status.loginRequired {
            return Color.orange.opacity(0.08)
        }
        if model.shouldShowAuthCompletion {
            return Color.green.opacity(0.08)
        }
        switch model.latestDisplayStatus {
        case .pending, .running:
            return Color.blue.opacity(0.08)
        case .completed:
            return Color.green.opacity(0.06)
        case .cancelled:
            return Color.secondary.opacity(0.06)
        case .failed, .macUnavailable:
            return Color.orange.opacity(0.08)
        case nil:
            return Color.secondary.opacity(0.06)
        }
    }
}

private struct RemoteDashboardChangeSummary: View {
    var status: SanitizedRemoteStatus

    private var chips: [(String, String, Color)] {
        [
            status.noticeNew > 0 ? ("새 공지", "\(status.noticeNew)", .brown) : nil,
            status.noticeUpdated > 0 ? ("수정 공지", "\(status.noticeUpdated)", .brown) : nil,
            status.newFiles > 0 ? ("새 파일", "\(status.newFiles)", .blue) : nil,
            status.fileCleanupTotal > 0 ? ("파일 정리", "\(status.fileCleanupTotal)", .blue) : nil,
            status.calendarCreated > 0 ? ("캘린더 생성", "\(status.calendarCreated)", .green) : nil,
            status.calendarUpdated > 0 ? ("캘린더 수정", "\(status.calendarUpdated)", .green) : nil,
            status.calendarDeleted > 0 ? ("캘린더 정리", "\(status.calendarDeleted)", .red) : nil,
        ].compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("변경 요약", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowChipLayout(chips: chips)
        }
    }
}

private struct FlowChipLayout: View {
    var chips: [(String, String, Color)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 106), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(chips, id: \.0) { title, value, tint in
                HStack(spacing: 5) {
                    Text(value)
                        .font(.caption.monospacedDigit().weight(.bold))
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct RemoteMetricTile: View {
    var label: String
    var value: Int
    var systemImage: String
    var isSelected: Bool
    var action: () -> Void

    init(
        _ label: String,
        _ value: Int,
        systemImage: String,
        isSelected: Bool = false,
        action: @escaping () -> Void = {}
    ) {
        self.label = label
        self.value = value
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .frame(width: 30, height: 30)
                    .background((isSelected ? Color.blue : Color.secondary).opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(value)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.primary)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .padding(.horizontal, 10)
            .background(isSelected ? Color.blue.opacity(0.12) : Color.klmsSubtleCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue.opacity(0.45) : Color.klmsBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) \(value)개")
    }
}

private struct DashboardMetricDetailPanel: View {
    var category: DashboardMetricCategory
    var status: SanitizedRemoteStatus
    var items: [ServerRelaySyncItem]
    var onSelect: (ServerRelaySyncItem) -> Void = { _ in }

    private var filteredItems: [ServerRelaySyncItem] {
        let defaultFilter = CompanionItemStatusFilter.defaultFilter(for: category)
        return items
            .filter { category.includes($0) }
            .filter { !$0.isHidden }
            .filter { defaultFilter.includes($0) }
            .companionSorted(by: .recent)
    }

    private var visibleItems: [ServerRelaySyncItem] {
        Array(filteredItems.prefix(8))
    }

    var body: some View {
        let filtered = filteredItems
        let visible = Array(filtered.prefix(8))
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(category.title, systemImage: category.systemImage)
                    .font(.headline)
                    .foregroundStyle(category.tint)
                Spacer(minLength: 0)
                Text("\(category.value(from: status))개")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if category == .calendar {
                calendarSummary
            } else if category == .quarantine {
                quarantineSummary
            } else if filtered.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(visible) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            ServerSyncDataRow(item: item)
                                .equatable()
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("항목 상세를 엽니다.")
                    }
                    if filtered.count > visible.count {
                        Text("외 \(filtered.count - visible.count)개")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.klmsCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(category.tint.opacity(0.30), lineWidth: 1)
        )
    }

    private var calendarSummary: some View {
        HStack(spacing: 8) {
            DashboardCountPill(title: "생성", value: status.calendarCreated, tint: category.tint)
            DashboardCountPill(title: "수정", value: status.calendarUpdated, tint: category.tint)
            DashboardCountPill(title: "삭제", value: status.calendarDeleted, tint: category.tint)
        }
    }

    private var quarantineSummary: some View {
        Text(category.emptyMessage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyState: some View {
        Text(category.emptyMessage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DashboardCategoryInlineDetailPanel: View {
    var category: DashboardMetricCategory
    @ObservedObject var model: CompanionModel
    @State private var query = ""
    @State private var sortOption = CompanionItemSortOption.recent
    @State private var visibilityFilter = CompanionItemVisibilityFilter.visible
    @State private var statusFilter: CompanionItemStatusFilter
    @State private var selectedCourse = CompanionItemListFilter.allCourses
    @State private var selectedYear = CompanionItemListFilter.allYears
    @State private var selectedSemester = CompanionItemListFilter.allSemesters
    @State private var newOnly = false
    @State private var recentOnly = false
    @State private var selectedItemID: String?
    @State private var visibleLimit = 18

    init(category: DashboardMetricCategory, model: CompanionModel) {
        self.category = category
        _model = ObservedObject(wrappedValue: model)
        _statusFilter = State(initialValue: CompanionItemStatusFilter.defaultFilter(for: category))
    }

    private var status: SanitizedRemoteStatus {
        model.status
    }

    private var calendarChanges: [CalendarChange] {
        model.calendarChanges
    }

    private var baseItems: [ServerRelaySyncItem] {
        model.syncItems.filter { category.includes($0) }
    }

    private var courseOptions: [String] {
        CompanionItemListFilter.courseOptions(for: baseItems)
    }

    private var yearOptions: [String] {
        CompanionItemListFilter.yearOptions(for: baseItems)
    }

    private var semesterOptions: [String] {
        CompanionItemListFilter.semesterOptions(for: baseItems)
    }

    private var availableStatusFilters: [CompanionItemStatusFilter] {
        CompanionItemStatusFilter.options(for: category, items: baseItems)
    }

    private var effectiveStatusFilter: CompanionItemStatusFilter {
        availableStatusFilters.contains(statusFilter) ? statusFilter : CompanionItemStatusFilter.defaultFilter(for: category)
    }

    private var filteredItems: [ServerRelaySyncItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedCourse = courseOptions.contains(selectedCourse) ? selectedCourse : CompanionItemListFilter.allCourses
        let selectedYear = yearOptions.contains(selectedYear) ? selectedYear : CompanionItemListFilter.allYears
        let selectedSemester = semesterOptions.contains(selectedSemester) ? selectedSemester : CompanionItemListFilter.allSemesters
        return baseItems
            .filter { visibilityFilter.includes($0) }
            .filter { effectiveStatusFilter.includes($0) }
            .filter { selectedCourse == CompanionItemListFilter.allCourses || $0.course == selectedCourse }
            .filter { selectedYear == CompanionItemListFilter.allYears || ($0.academicYear.map(String.init) ?? "") == selectedYear }
            .filter { selectedSemester == CompanionItemListFilter.allSemesters || $0.academicSemester == selectedSemester }
            .filter { !newOnly || $0.isCompanionChangedLike }
            .filter { !recentOnly || $0.isCompanionChangedLike }
            .filter { item in
                guard !query.isEmpty else { return true }
                return item.searchText.localizedCaseInsensitiveContains(query)
            }
            .companionSorted(by: sortOption)
    }

    private var visibleItems: [ServerRelaySyncItem] {
        Array(filteredItems.prefix(visibleLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summaryHeader
            detailContent
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(category.tint.opacity(0.22), lineWidth: 1)
        )
    }

    private var summaryHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: category.systemImage)
                .font(.title2)
                .foregroundStyle(category.tint)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(category.title)
                    .font(.headline)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(category.tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var detailContent: some View {
        if category == .calendar {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    DashboardCountPill(title: "생성", value: status.calendarCreated, tint: category.tint)
                    DashboardCountPill(title: "수정", value: status.calendarUpdated, tint: category.tint)
                    DashboardCountPill(title: "정리", value: status.calendarDeleted, tint: category.tint)
                }
                RemoteCalendarActionPanel(model: model)
                if calendarChanges.isEmpty {
                    panelEmptyText("최근 캘린더 변경 상세가 아직 서버에 올라오지 않았습니다.")
                } else {
                    ForEach(calendarChanges) { change in
                        DashboardCalendarChangeDetailRow(change: change) { action, edit in
                            Task { await model.createCalendarAction(action, change: change, edit: edit) }
                        }
                    }
                }
            }
        } else if category == .quarantine {
            panelEmptyText(category.emptyMessage)
        } else {
            let filtered = filteredItems
            let visible = Array(filtered.prefix(visibleLimit))
            VStack(alignment: .leading, spacing: 8) {
                TextField("\(category.title) 검색", text: $query)
                    .textFieldStyle(.roundedBorder)

                CompanionItemListControls(
                    sortOption: $sortOption,
                    visibilityFilter: $visibilityFilter,
                    statusFilter: $statusFilter,
                    selectedCourse: $selectedCourse,
                    selectedYear: $selectedYear,
                    selectedSemester: $selectedSemester,
                    newOnly: $newOnly,
                    recentOnly: $recentOnly,
                    availableStatusFilters: availableStatusFilters,
                    courseOptions: courseOptions,
                    yearOptions: yearOptions,
                    semesterOptions: semesterOptions,
                    supportsNewOnly: category.supportsNewOnly,
                    supportsRecentOnly: category.supportsRecentOnly,
                    defaultStatusFilter: CompanionItemStatusFilter.defaultFilter(for: category),
                    totalCount: baseItems.count,
                    filteredCount: filtered.count
                )

                if filtered.isEmpty {
                    panelEmptyText(category.emptyMessage)
                } else {
                    ForEach(visible) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                selectedItemID = selectedItemID == item.id ? nil : item.id
                            } label: {
                                HStack(alignment: .center, spacing: 8) {
                                    ServerSyncDataRow(item: item)
                                        .equatable()
                                    Image(systemName: selectedItemID == item.id ? "chevron.up" : "chevron.down")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("항목 상세를 같은 화면에서 펼칩니다.")

                            if selectedItemID == item.id {
                                ServerSyncItemInlineDetailPanel(item: item, model: model)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                    if filtered.count > visible.count {
                        showMoreButton(filtered.count - visible.count)
                    }
                }
            }
        }
    }

    private var summaryText: String {
        if category == .calendar {
            return "생성 \(status.calendarCreated)개 · 수정 \(status.calendarUpdated)개 · 정리 \(status.calendarDeleted)개"
        }
        if category == .quarantine {
            return "\(category.value(from: status))개 · 격리 항목은 Mac 앱 파일 화면에서 처리합니다."
        }
        let count = category.value(from: status)
        return "\(count)개 · 아래에서 필터와 정렬을 조정할 수 있습니다."
    }

    private func panelEmptyText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func extraCountText(_ count: Int) -> some View {
        Text("외 \(count)개")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
    }

    private func showMoreButton(_ remainingCount: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                visibleLimit += category == .files ? 24 : 18
            }
        } label: {
            Label("더 보기 \(remainingCount)개 남음", systemImage: "chevron.down")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
    }
}

private struct DashboardCategoryDetailScreen: View {
    var category: DashboardMetricCategory
    var status: SanitizedRemoteStatus
    var items: [ServerRelaySyncItem]
    var calendarChanges: [CalendarChange]
    var onSelect: (ServerRelaySyncItem) -> Void
    @State private var query = ""
    @State private var sortOption = CompanionItemSortOption.recent
    @State private var visibilityFilter = CompanionItemVisibilityFilter.visible
    @State private var statusFilter: CompanionItemStatusFilter
    @State private var selectedCourse = CompanionItemListFilter.allCourses
    @State private var selectedYear = CompanionItemListFilter.allYears
    @State private var selectedSemester = CompanionItemListFilter.allSemesters
    @State private var newOnly = false
    @State private var recentOnly = false

    init(
        category: DashboardMetricCategory,
        status: SanitizedRemoteStatus,
        items: [ServerRelaySyncItem],
        calendarChanges: [CalendarChange] = [],
        onSelect: @escaping (ServerRelaySyncItem) -> Void
    ) {
        self.category = category
        self.status = status
        self.items = items
        self.calendarChanges = calendarChanges
        self.onSelect = onSelect
        _statusFilter = State(initialValue: CompanionItemStatusFilter.defaultFilter(for: category))
    }

    private var baseItems: [ServerRelaySyncItem] {
        items.filter { category.includes($0) }
    }

    private var courseOptions: [String] {
        CompanionItemListFilter.courseOptions(for: baseItems)
    }

    private var yearOptions: [String] {
        CompanionItemListFilter.yearOptions(for: baseItems)
    }

    private var semesterOptions: [String] {
        CompanionItemListFilter.semesterOptions(for: baseItems)
    }

    private var availableStatusFilters: [CompanionItemStatusFilter] {
        CompanionItemStatusFilter.options(for: category, items: baseItems)
    }

    private var effectiveStatusFilter: CompanionItemStatusFilter {
        availableStatusFilters.contains(statusFilter) ? statusFilter : CompanionItemStatusFilter.defaultFilter(for: category)
    }

    private var filteredItems: [ServerRelaySyncItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedCourse = courseOptions.contains(selectedCourse) ? selectedCourse : CompanionItemListFilter.allCourses
        let selectedYear = yearOptions.contains(selectedYear) ? selectedYear : CompanionItemListFilter.allYears
        let selectedSemester = semesterOptions.contains(selectedSemester) ? selectedSemester : CompanionItemListFilter.allSemesters
        return baseItems
            .filter { visibilityFilter.includes($0) }
            .filter { effectiveStatusFilter.includes($0) }
            .filter { selectedCourse == CompanionItemListFilter.allCourses || $0.course == selectedCourse }
            .filter { selectedYear == CompanionItemListFilter.allYears || ($0.academicYear.map(String.init) ?? "") == selectedYear }
            .filter { selectedSemester == CompanionItemListFilter.allSemesters || $0.academicSemester == selectedSemester }
            .filter { !newOnly || $0.isCompanionChangedLike }
            .filter { !recentOnly || $0.isCompanionChangedLike }
            .filter { item in
                guard !query.isEmpty else { return true }
                return item.searchText.localizedCaseInsensitiveContains(query)
            }
            .companionSorted(by: sortOption)
    }

    var body: some View {
        let filtered = filteredItems
        List {
            Section {
                DashboardCategorySummaryRow(category: category, status: status, itemCount: filtered.count)
            }

            if category == .calendar {
                Section("캘린더 변경") {
                    DashboardCalendarChangeRow(title: "생성", value: status.calendarCreated)
                    DashboardCalendarChangeRow(title: "수정", value: status.calendarUpdated)
                    DashboardCalendarChangeRow(title: "정리", value: status.calendarDeleted)
                }
                if calendarChanges.isEmpty {
                    Section {
                        Text("최근 캘린더 변경 상세가 아직 서버에 올라오지 않았습니다.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("\(calendarChanges.count)개 변경") {
                        ForEach(calendarChanges) { change in
                            DashboardCalendarChangeDetailRow(change: change)
                        }
                    }
                }
            } else if category == .quarantine {
                Section {
                    Text(category.emptyMessage)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("보기") {
                    CompanionItemListControls(
                        sortOption: $sortOption,
                        visibilityFilter: $visibilityFilter,
                        statusFilter: $statusFilter,
                        selectedCourse: $selectedCourse,
                        selectedYear: $selectedYear,
                        selectedSemester: $selectedSemester,
                        newOnly: $newOnly,
                        recentOnly: $recentOnly,
                        availableStatusFilters: availableStatusFilters,
                        courseOptions: courseOptions,
                        yearOptions: yearOptions,
                        semesterOptions: semesterOptions,
                        supportsNewOnly: category.supportsNewOnly,
                        supportsRecentOnly: category.supportsRecentOnly,
                        defaultStatusFilter: CompanionItemStatusFilter.defaultFilter(for: category),
                        totalCount: baseItems.count,
                        filteredCount: filtered.count
                    )
                }
                if filtered.isEmpty {
                    Section {
                        Text(category.emptyMessage)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("\(filtered.count)개") {
                        ForEach(filtered) { item in
                            Button {
                                onSelect(item)
                            } label: {
                                ServerSyncDataRow(item: item)
                                    .equatable()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle(category.title)
        .searchable(text: $query, prompt: "\(category.title) 검색")
    }
}

private struct DashboardCategorySummaryRow: View {
    var category: DashboardMetricCategory
    var status: SanitizedRemoteStatus
    var itemCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(category.tint)
                .frame(width: 34, height: 34)
                .background(category.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(category.title)
                    .font(.headline)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(category.value(from: status))")
                .font(.title3.monospacedDigit().weight(.semibold))
        }
    }

    private var summaryText: String {
        switch category {
        case .files:
            "서버 DB 파일 \(status.fileTotal)개 · 새 파일 \(status.newFiles)개"
        case .notices:
            "새 \(status.noticeNew)개 · 수정 \(status.noticeUpdated)개"
        case .calendar:
            "생성 \(status.calendarCreated) · 수정 \(status.calendarUpdated) · 정리 \(status.calendarDeleted)"
        default:
            "상세 목록 \(itemCount)개"
        }
    }
}

private struct DashboardCalendarChangeRow: View {
    var title: String
    var value: Int

    var body: some View {
        if value > 0 {
            HStack {
                Text(title)
                Spacer()
                Text("\(value)개")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RemoteCalendarActionPanel: View {
    @ObservedObject var model: CompanionModel
    var compact = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !compact {
                Text("캘린더가 맞지 않으면 Mac에 검사나 재동기화를 요청할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.hasInFlightRequest {
                RemoteItemRequestPendingView(
                    title: "요청 전송됨",
                    message: "Mac이 캘린더 관련 요청을 처리하는 중입니다."
                )
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 118 : 140), spacing: 8)], spacing: 8) {
                    actionButton("상태 검사", systemImage: RemoteCommandKind.verify.engineCommand.systemImage, kind: .verify)
                    actionButton("과제/시험 재동기화", systemImage: RemoteCommandKind.coreSync.engineCommand.systemImage, kind: .coreSync)
                    actionButton("권한 점검", systemImage: RemoteCommandKind.doctor.engineCommand.systemImage, kind: .doctor)
                }
            }
        }
        .padding(compact ? 10 : 0)
        .background(compact ? Color.klmsSubtleCardBackground : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(compact ? Color.klmsBorder : Color.clear, lineWidth: 1)
        )
    }

    private func actionButton(_ title: String, systemImage: String, kind: RemoteCommandKind) -> some View {
        Button {
            Task { await model.createCommand(kind) }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 32)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
        .disabled(!model.isRemoteAvailable || model.isSubmitting || model.hasInFlightRequest)
        .accessibilityHint("Mac에 \(title) 요청을 보냅니다.")
    }
}

private struct DashboardCalendarChangeDetailRow: View {
    var change: CalendarChange
    var onAction: ((ServerRelayItemActionKind, CalendarEventEdit?) -> Void)?
    @State private var didSubmitCommand = false
    @State private var isShowingEditSheet = false

    init(change: CalendarChange, onAction: ((ServerRelayItemActionKind, CalendarEventEdit?) -> Void)? = nil) {
        self.change = change
        self.onAction = onAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Text(change.actionDisplayName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.14))
                    .foregroundStyle(tint)
                    .clipShape(Capsule())
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.title.nilIfEmpty ?? "제목 없음")
                        .font(.subheadline.weight(.semibold))
                    Text([change.course, change.calendar, change.startAt.nilIfEmpty ?? change.dueAt].compactMap(\.nilIfEmpty).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !change.changes.isEmpty {
                Text(change.changes.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CalendarChangeExplanationPanel(change: change, showsActionHelp: onAction != nil)
            if didSubmitCommand {
                RemoteItemRequestPendingView(
                    title: "요청 전송됨",
                    message: "Mac이 캘린더 요청을 처리하는 중입니다."
                )
            } else if onAction != nil {
                HStack(spacing: 8) {
                    Button {
                        isShowingEditSheet = true
                    } label: {
                        Label("내용 수정", systemImage: "pencil")
                    }
                    Button {
                        openSystemCalendar()
                    } label: {
                        Label("캘린더에서 열기", systemImage: "calendar")
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $isShowingEditSheet) {
            CalendarEventEditForm(change: change) { edit in
                didSubmitCommand = true
                onAction?(.calendarEdit, edit)
            }
        }
    }

    private var tint: Color {
        switch change.action {
        case "created":
            .green
        case "updated":
            .blue
        case "deleted":
            .red
        default:
            .secondary
        }
    }

    private func openSystemCalendar() {
        #if canImport(UIKit)
        let date = parseCalendarEditInputDate(change.startAt) ?? parseCalendarEditInputDate(change.dueAt)
        let url: URL?
        if let date {
            url = URL(string: "calshow:\(date.timeIntervalSinceReferenceDate)")
        } else {
            url = URL(string: "calshow:")
        }
        if let url {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

private struct CalendarEventEditForm: View {
    var change: CalendarChange
    var onSave: (CalendarEventEdit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var startAt: String
    @State private var dueAt: String
    @State private var location: String

    init(change: CalendarChange, onSave: @escaping (CalendarEventEdit) -> Void) {
        self.change = change
        self.onSave = onSave
        _title = State(initialValue: change.title)
        _startAt = State(initialValue: calendarEditInputDate(change.startAt))
        _dueAt = State(initialValue: calendarEditInputDate(change.dueAt))
        _location = State(initialValue: change.location)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("제목", text: $title)
                    TextField("시작 시간", text: $startAt)
                    TextField("종료 시간", text: $dueAt)
                    TextField("장소", text: $location)
                } footer: {
                    Text("Mac이 Apple Calendar 이벤트를 찾아 직접 수정합니다. 시간은 2026-06-17 13:00 형식으로 입력할 수 있고, 비어 있는 시간/장소는 변경하지 않습니다.")
                }
            }
            .navigationTitle("캘린더 내용 수정")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        onSave(CalendarEventEdit(title: title, startAt: startAt, dueAt: dueAt, location: location))
                        dismiss()
                    }
                }
            }
        }
    }
}

private func calendarEditInputDate(_ text: String) -> String {
    guard let date = parseCalendarEditInputDate(text) else { return text }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

private func parseCalendarEditInputDate(_ text: String) -> Date? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractionalFormatter.date(from: trimmed) {
        return date
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: trimmed)
}

private struct CalendarChangeExplanationPanel: View {
    var change: CalendarChange
    var showsActionHelp = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(change.explanationText, systemImage: "info.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(change.nextActionText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if showsActionHelp {
                Text(change.actionButtonHelpText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct DashboardCountPill: View {
    var title: String
    var value: Int
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.primary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 10)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct RemoteChangeSummaryPanel: View {
    var status: SanitizedRemoteStatus

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("변경 요약")
                    .font(.headline)
                Spacer()
                Text(status.phase.klmsRemotePhaseName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                RemoteSummaryCard(
                    title: "공지",
                    systemImage: "megaphone",
                    tint: .brown,
                    lines: [
                        "표시 \(status.notices)",
                        "새 \(status.noticeNew)",
                        "수정 \(status.noticeUpdated)",
                        status.noticeIgnored > 0 ? "보관 \(status.noticeIgnored)" : nil,
                    ]
                )
                RemoteSummaryCard(
                    title: "파일",
                    systemImage: "folder",
                    tint: .blue,
                    lines: [
                        status.fileTotal > 0 ? "전체 \(status.fileTotal)" : nil,
                        "새 \(status.newFiles)",
                        status.fileCleanupTotal > 0 ? "정리 \(status.fileCleanupTotal)" : nil,
                        status.quarantine > 0 ? "격리 \(status.quarantine)" : nil,
                    ]
                )
                RemoteSummaryCard(
                    title: "캘린더",
                    systemImage: "calendar",
                    tint: .green,
                    lines: [
                        "생성 \(status.calendarCreated)",
                        "수정 \(status.calendarUpdated)",
                        "정리 \(status.calendarDeleted)",
                    ]
                )
            }
        }
        .padding(12)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }
}

private struct RemoteSummaryCard: View {
    var title: String
    var systemImage: String
    var tint: Color
    var lines: [String?]

    private var displayLines: [String] {
        let values = lines.compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        return values.isEmpty ? ["변경 없음"] : values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(displayLines.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
        .padding(10)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ServerSyncDataPanel: View {
    var items: [ServerRelaySyncItem]
    var onSelect: (ServerRelaySyncItem) -> Void = { _ in }
    @State private var isExpanded = true
    @State private var query = ""
    @State private var sortOption = CompanionItemSortOption.recent
    @State private var visibilityFilter = CompanionItemVisibilityFilter.visible
    @State private var statusFilter = CompanionItemStatusFilter.all
    @State private var selectedCourse = CompanionItemListFilter.allCourses
    @State private var selectedYear = CompanionItemListFilter.allYears
    @State private var selectedSemester = CompanionItemListFilter.allSemesters
    @State private var newOnly = false
    @State private var recentOnly = false
    @State private var visibleLimit = 20

    private var courseOptions: [String] {
        CompanionItemListFilter.courseOptions(for: items)
    }

    private var yearOptions: [String] {
        CompanionItemListFilter.yearOptions(for: items)
    }

    private var semesterOptions: [String] {
        CompanionItemListFilter.semesterOptions(for: items)
    }

    private var availableStatusFilters: [CompanionItemStatusFilter] {
        CompanionItemStatusFilter.options(for: nil, items: items)
    }

    private var effectiveStatusFilter: CompanionItemStatusFilter {
        availableStatusFilters.contains(statusFilter) ? statusFilter : .all
    }

    private var filteredItems: [ServerRelaySyncItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedCourse = courseOptions.contains(selectedCourse) ? selectedCourse : CompanionItemListFilter.allCourses
        let selectedYear = yearOptions.contains(selectedYear) ? selectedYear : CompanionItemListFilter.allYears
        let selectedSemester = semesterOptions.contains(selectedSemester) ? selectedSemester : CompanionItemListFilter.allSemesters
        return items
            .filter { visibilityFilter.includes($0) }
            .filter { effectiveStatusFilter.includes($0) }
            .filter { selectedCourse == CompanionItemListFilter.allCourses || $0.course == selectedCourse }
            .filter { selectedYear == CompanionItemListFilter.allYears || ($0.academicYear.map(String.init) ?? "") == selectedYear }
            .filter { selectedSemester == CompanionItemListFilter.allSemesters || $0.academicSemester == selectedSemester }
            .filter { !newOnly || $0.isCompanionChangedLike }
            .filter { !recentOnly || $0.isCompanionChangedLike }
            .filter { item in
                guard !query.isEmpty else { return true }
                return item.searchText.localizedCaseInsensitiveContains(query)
            }
            .companionSorted(by: sortOption)
    }

    private var visibleItems: [ServerRelaySyncItem] {
        Array(filteredItems.prefix(visibleLimit))
    }

    var body: some View {
        if !items.isEmpty {
            let filtered = filteredItems
            let visible = Array(filtered.prefix(visibleLimit))
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("동기화 데이터 검색", text: $query)
                        .textFieldStyle(.roundedBorder)
                    CompanionItemListControls(
                        sortOption: $sortOption,
                        visibilityFilter: $visibilityFilter,
                        statusFilter: $statusFilter,
                        selectedCourse: $selectedCourse,
                        selectedYear: $selectedYear,
                        selectedSemester: $selectedSemester,
                        newOnly: $newOnly,
                        recentOnly: $recentOnly,
                        availableStatusFilters: availableStatusFilters,
                        courseOptions: courseOptions,
                        yearOptions: yearOptions,
                        semesterOptions: semesterOptions,
                        supportsNewOnly: true,
                        supportsRecentOnly: true,
                        defaultStatusFilter: .all,
                        totalCount: items.count,
                        filteredCount: filtered.count
                    )
                    ForEach(visible) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            ServerSyncDataRow(item: item)
                                .equatable()
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("항목 상세를 엽니다.")
                    }
                    if filtered.count > visible.count {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                visibleLimit += 30
                            }
                        } label: {
                            Label("더 보기 \(filtered.count - visible.count)개 남음", systemImage: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack {
                    Label("동기화 데이터", systemImage: "tray.full")
                        .font(.headline)
                    Spacer()
                    Text("\(items.count)개")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.quinary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct ServerSyncItemInlineDetailPanel: View {
    var item: ServerRelaySyncItem
    @ObservedObject var model: CompanionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            detailFields
            if item.kind == "file" {
                fileAccessPanel
            }
            if let activeAction = model.activeItemAction(for: item) {
                RemoteItemRequestPendingView(
                    title: "요청 전송됨",
                    message: "\(activeAction.action.companionActionTitle) · \(activeAction.status.displayName)"
                )
            } else if model.hasInFlightRequest {
                RemoteItemRequestPendingView(
                    title: "처리 중",
                    message: "Mac이 요청을 처리하는 중입니다. 끝나면 결과를 다시 불러옵니다."
                )
            } else {
                actionPanel
            }
            InfoBanner(message: detailHelpMessage)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(kindName, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(item.title.isEmpty ? "제목 없음" : item.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if !item.course.isEmpty {
                Text(item.course)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var detailFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailFieldRow(title: "상태", value: item.status)
            if item.kind == "notice" {
                DetailFieldRow(title: "읽음", value: item.isRead ? "읽음" : "읽지 않음")
                DetailFieldRow(title: "중요", value: item.isImportant ? "중요" : "일반")
            }
            DetailFieldRow(title: "시간", value: item.timestamp)
            DetailFieldRow(title: "학기", value: item.academicTerm)
            DetailFieldRow(title: "세부 내용", value: item.detail)
            DetailFieldRow(title: "첨부", value: item.attachmentCount > 0 ? "\(item.attachmentCount)개" : "")
            DetailFieldRow(title: "서버 갱신", value: item.updatedAt)
        }
        .padding(12)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !itemActions.isEmpty {
                Text("수정/삭제 선택")
                    .font(.subheadline.weight(.semibold))
                if item.kind == "notice" {
                    VStack(spacing: 8) {
                        RemoteItemToggleButton(
                            title: "읽음",
                            isOn: item.isRead,
                            onText: "ON · 읽음 처리됨",
                            offText: "OFF · 읽지 않음",
                            systemImage: item.isRead ? "checkmark.circle.fill" : "circle",
                            action: item.isRead ? .noticeUnread : .noticeRead,
                            item: item,
                            model: model
                        )
                        RemoteItemToggleButton(
                            title: "중요",
                            isOn: item.isImportant,
                            onText: "ON · 중요 공지",
                            offText: "OFF · 일반 공지",
                            systemImage: item.isImportant ? "star.fill" : "star",
                            action: item.isImportant ? .noticeUnimportant : .noticeImportant,
                            item: item,
                            model: model
                        )
                    }
                }
                if !regularItemActions.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], spacing: 8) {
                        ForEach(regularItemActions) { action in
                            Button {
                                Task {
                                    await model.createItemAction(action, item: item)
                            }
                        } label: {
                            Label(action.companionActionTitle, systemImage: action.companionActionImage)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                            .disabled(!model.serverRelayConfigured || model.isSubmitting)
                        }
                    }
                }
                if !model.serverRelayConfigured {
                    Text("항목 처리 요청은 서버 릴레이가 연결되어 있을 때만 사용할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("반영")
                .font(.subheadline.weight(.semibold))
            Button {
                Task {
                    await model.createCommand(relevantCommand)
                }
            } label: {
                Label("\(relevantCommand.displayName) 반영", systemImage: relevantCommand.engineCommand.systemImage)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.isRemoteAvailable || model.isSubmitting || model.hasInFlightRequest)

            Button {
                Task {
                    await model.refreshRecent(includeSyncData: true)
                }
            } label: {
                Label("결과 다시 불러오기", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
            .disabled(model.isRefreshing)
        }
    }

    private var fileAccessPanel: some View {
        let request = model.latestFileAccessRequest(for: item)
        return VStack(alignment: .leading, spacing: 10) {
            Text("파일 열기")
                .font(.subheadline.weight(.semibold))
            if let request {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(request.status.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(fileAccessDescription(request))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if request.isDownloadAvailable {
                        Button {
                            model.openFileAccessRequest(request)
                        } label: {
                            Label("웹 미리보기", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Text("Mac에 저장된 course_files 원본을 임시 서버 링크로 준비할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task {
                    await model.createFileAccessRequest(item: item)
                }
            } label: {
                Label("파일 링크 요청", systemImage: "link.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
            .disabled(!model.serverRelayConfigured || model.isSubmitting || request?.status.isInFlight == true)
        }
        .padding(12)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fileAccessDescription(_ request: ServerRelayFileAccessRequest) -> String {
        var parts: [String] = []
        if let expiresAt = request.expiresAt, request.isDownloadAvailable {
            parts.append("만료 \(expiresAt.formatted(date: .omitted, time: .shortened))")
        }
        if let sizeBytes = request.sizeBytes, sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))
        }
        if !request.message.isEmpty {
            parts.append(request.message)
        }
        return parts.isEmpty ? "Mac에서 파일을 준비하는 중입니다." : parts.joined(separator: " · ")
    }

    private var detailHelpMessage: String {
        if item.kind == "file" {
            return "파일 열기 요청을 보내면 Mac이 course_files 원본을 임시 링크로 준비합니다. 링크가 만료되면 서버 기록과 임시 파일은 자동으로 정리됩니다."
        }
        return "항목 처리 요청은 서버에 대기 상태로 올라가고, Mac 앱이 확인한 뒤 기존 상태 파일에 반영합니다."
    }

    private var itemActions: [ServerRelayItemActionKind] {
        switch item.kind {
        case "assignment", "assignmentCandidate":
            [.assignmentComplete, .assignmentHide]
        case "completedAssignment":
            [.assignmentRestore, .assignmentHide]
        case "examCandidate":
            [.examPromote, .examIgnore]
        case "exam":
            [.examRestore, .examIgnore]
        case "notice":
            [item.isHidden ? .noticeUnhide : .noticeHide]
        case "file":
            item.isHidden ? [.fileUnhide] : [.fileHide, .fileTrash]
        default:
            []
        }
    }

    private var regularItemActions: [ServerRelayItemActionKind] {
        itemActions
    }

    private var relevantCommand: RemoteCommandKind {
        switch item.kind {
        case "notice":
            .noticeSync
        case "file":
            .filesSync
        case "assignment", "completedAssignment", "assignmentCandidate", "exam", "examCandidate", "helpDesk":
            .coreSync
        default:
            .fullSync
        }
    }

    private var kindName: String {
        switch item.kind {
        case "assignment":
            "과제"
        case "completedAssignment":
            "완료 과제"
        case "assignmentCandidate":
            "과제 후보"
        case "exam":
            "시험"
        case "examCandidate":
            "시험 후보"
        case "helpDesk":
            "헬프데스크"
        case "notice":
            "공지"
        case "file":
            "파일"
        default:
            item.kind
        }
    }

    private var systemImage: String {
        switch item.kind {
        case "assignment", "completedAssignment", "assignmentCandidate":
            "checklist"
        case "exam", "examCandidate":
            "calendar"
        case "notice":
            "note.text"
        case "file":
            "doc"
        case "helpDesk":
            "person.2"
        default:
            "circle"
        }
    }

    private var tint: Color {
        switch item.kind {
        case "assignment", "completedAssignment", "assignmentCandidate":
            .orange
        case "exam", "examCandidate":
            .green
        case "notice":
            .brown
        case "file":
            .blue
        case "helpDesk":
            .teal
        default:
            .secondary
        }
    }
}

private struct ServerSyncItemDetailView: View {
    var item: ServerRelaySyncItem
    @ObservedObject var model: CompanionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    detailFields
                    if item.kind == "file" {
                        fileAccessPanel
                    }
                    if let activeAction = model.activeItemAction(for: item) {
                        RemoteItemRequestPendingView(
                            title: "요청 전송됨",
                            message: "\(activeAction.action.companionActionTitle) · \(activeAction.status.displayName)"
                        )
                    } else if model.hasInFlightRequest {
                        RemoteItemRequestPendingView(
                            title: "처리 중",
                            message: "Mac이 요청을 처리하는 중입니다. 끝나면 결과를 다시 불러옵니다."
                        )
                    } else {
                        actionPanel
                    }
                    InfoBanner(message: detailHelpMessage)
                }
                .padding()
            }
            .navigationTitle("상세")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(kindName, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(item.title.isEmpty ? "제목 없음" : item.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !item.course.isEmpty {
                Text(item.course)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var detailFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailFieldRow(title: "상태", value: item.status)
            if item.kind == "notice" {
                DetailFieldRow(title: "읽음", value: item.isRead ? "읽음" : "읽지 않음")
                DetailFieldRow(title: "중요", value: item.isImportant ? "중요" : "일반")
            }
            DetailFieldRow(title: "시간", value: item.timestamp)
            DetailFieldRow(title: "학기", value: item.academicTerm)
            DetailFieldRow(title: "세부 내용", value: item.detail)
            DetailFieldRow(title: "첨부", value: item.attachmentCount > 0 ? "\(item.attachmentCount)개" : "")
            DetailFieldRow(title: "서버 갱신", value: item.updatedAt)
        }
        .padding(12)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !itemActions.isEmpty {
                Text("수정/삭제 선택")
                    .font(.headline)
                if item.kind == "notice" {
                    VStack(spacing: 8) {
                        RemoteItemToggleButton(
                            title: "읽음",
                            isOn: item.isRead,
                            onText: "ON · 읽음 처리됨",
                            offText: "OFF · 읽지 않음",
                            systemImage: item.isRead ? "checkmark.circle.fill" : "circle",
                            action: item.isRead ? .noticeUnread : .noticeRead,
                            item: item,
                            model: model
                        )
                        RemoteItemToggleButton(
                            title: "중요",
                            isOn: item.isImportant,
                            onText: "ON · 중요 공지",
                            offText: "OFF · 일반 공지",
                            systemImage: item.isImportant ? "star.fill" : "star",
                            action: item.isImportant ? .noticeUnimportant : .noticeImportant,
                            item: item,
                            model: model
                        )
                    }
                }
                if !regularItemActions.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                        ForEach(regularItemActions) { action in
                            Button {
                                Task {
                                    await model.createItemAction(action, item: item)
                            }
                        } label: {
                            Label(action.companionActionTitle, systemImage: action.companionActionImage)
                                .frame(maxWidth: .infinity, minHeight: 38)
                        }
                        .buttonStyle(.bordered)
                            .disabled(!model.serverRelayConfigured || model.isSubmitting)
                        }
                    }
                }
                if !model.serverRelayConfigured {
                    Text("항목 처리 요청은 서버 릴레이가 연결되어 있을 때만 사용할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("반영")
                .font(.headline)
            Button {
                Task {
                    await model.createCommand(relevantCommand)
                }
            } label: {
                Label("\(relevantCommand.displayName) 반영", systemImage: relevantCommand.engineCommand.systemImage)
                    .frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.isRemoteAvailable || model.isSubmitting || model.hasInFlightRequest)

            Button {
                Task {
                    await model.refreshRecent(includeSyncData: true)
                }
            } label: {
                Label("결과 다시 불러오기", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(.bordered)
            .disabled(model.isRefreshing)
        }
    }

    private var fileAccessPanel: some View {
        let request = model.latestFileAccessRequest(for: item)
        return VStack(alignment: .leading, spacing: 10) {
            Text("파일 열기")
                .font(.headline)
            if let request {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(request.status.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(fileAccessDescription(request))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if request.isDownloadAvailable {
                        Button {
                            model.openFileAccessRequest(request)
                        } label: {
                            Label("웹 미리보기", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Text("Mac에 저장된 course_files 원본을 임시 서버 링크로 준비할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task {
                    await model.createFileAccessRequest(item: item)
                }
            } label: {
                Label("파일 링크 요청", systemImage: "link.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(.bordered)
            .disabled(!model.serverRelayConfigured || model.isSubmitting || request?.status.isInFlight == true)
        }
        .padding(12)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fileAccessDescription(_ request: ServerRelayFileAccessRequest) -> String {
        var parts: [String] = []
        if let expiresAt = request.expiresAt, request.isDownloadAvailable {
            parts.append("만료 \(expiresAt.formatted(date: .omitted, time: .shortened))")
        }
        if let sizeBytes = request.sizeBytes, sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))
        }
        if !request.message.isEmpty {
            parts.append(request.message)
        }
        return parts.isEmpty ? "Mac에서 파일을 준비하는 중입니다." : parts.joined(separator: " · ")
    }

    private var detailHelpMessage: String {
        if item.kind == "file" {
            return "iPhone은 KLMS에 직접 로그인하지 않습니다. 파일 열기 요청을 보내면 Mac이 course_files 원본을 임시 링크로 준비합니다. 링크가 만료되면 서버 기록과 임시 파일은 자동으로 정리됩니다."
        }
        return "항목 처리 요청은 서버에 대기 상태로 올라가고, Mac 앱이 확인한 뒤 기존 상태 파일에 반영합니다."
    }

    private var itemActions: [ServerRelayItemActionKind] {
        switch item.kind {
        case "assignment", "assignmentCandidate":
            [.assignmentComplete, .assignmentHide]
        case "completedAssignment":
            [.assignmentRestore, .assignmentHide]
        case "examCandidate":
            [.examPromote, .examIgnore]
        case "exam":
            [.examRestore, .examIgnore]
        case "notice":
            [item.isHidden ? .noticeUnhide : .noticeHide]
        case "file":
            item.isHidden ? [.fileUnhide] : [.fileHide, .fileTrash]
        default:
            []
        }
    }

    private var regularItemActions: [ServerRelayItemActionKind] {
        itemActions
    }

    private var relevantCommand: RemoteCommandKind {
        switch item.kind {
        case "notice":
            .noticeSync
        case "file":
            .filesSync
        case "assignment", "completedAssignment", "assignmentCandidate", "exam", "examCandidate", "helpDesk":
            .coreSync
        default:
            .fullSync
        }
    }

    private var kindName: String {
        switch item.kind {
        case "assignment":
            "과제"
        case "completedAssignment":
            "완료 과제"
        case "assignmentCandidate":
            "과제 후보"
        case "exam":
            "시험"
        case "examCandidate":
            "시험 후보"
        case "helpDesk":
            "헬프데스크"
        case "notice":
            "공지"
        case "file":
            "파일"
        default:
            item.kind
        }
    }

    private var systemImage: String {
        switch item.kind {
        case "assignment", "completedAssignment", "assignmentCandidate":
            "checklist"
        case "exam", "examCandidate":
            "calendar"
        case "notice":
            "note.text"
        case "file":
            "doc"
        case "helpDesk":
            "person.2"
        default:
            "circle"
        }
    }

    private var tint: Color {
        switch item.kind {
        case "assignment", "completedAssignment", "assignmentCandidate":
            .orange
        case "exam", "examCandidate":
            .green
        case "notice":
            .brown
        case "file":
            .blue
        case "helpDesk":
            .teal
        default:
            .secondary
        }
    }
}

private struct DetailFieldRow: View {
    var title: String
    var value: String

    var body: some View {
        if let displayValue = value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(displayValue)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RemoteItemRequestPendingView: View {
    var title: String
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsSubtleCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        )
    }
}

private struct RemoteItemToggleButton: View {
    var title: String
    var isOn: Bool
    var onText: String
    var offText: String
    var systemImage: String
    var action: ServerRelayItemActionKind
    var item: ServerRelaySyncItem
    @ObservedObject var model: CompanionModel

    var body: some View {
        Button {
            Task {
                await model.createItemAction(action, item: item)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(isOn ? onText : offText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(isOn ? "ON" : "OFF")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isOn ? Color.white : Color.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(isOn ? Color.accentColor : Color.secondary.opacity(0.14))
                    .clipShape(Capsule())
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .tint(isOn ? .accentColor : .secondary)
        .disabled(!model.serverRelayConfigured || model.isSubmitting)
        .accessibilityLabel("\(title) \(isOn ? "켜짐" : "꺼짐")")
        .accessibilityHint("누르면 \(action.displayName) 요청을 보냅니다.")
    }
}

private extension Array where Element == ServerRelaySyncItem {
    func companionSorted(by option: CompanionItemSortOption) -> [ServerRelaySyncItem] {
        sorted { lhs, rhs in
            switch option {
            case .recent:
                if let result = ServerRelaySyncItem.descendingCompare(lhs.timestamp, rhs.timestamp) {
                    return result
                }
                if let result = ServerRelaySyncItem.descendingCompare(lhs.updatedAt, rhs.updatedAt) {
                    return result
                }
            case .updated:
                if let result = ServerRelaySyncItem.descendingCompare(lhs.updatedAt, rhs.updatedAt) {
                    return result
                }
                if let result = ServerRelaySyncItem.descendingCompare(lhs.timestamp, rhs.timestamp) {
                    return result
                }
            case .course:
                if let result = ServerRelaySyncItem.ascendingCompare(lhs.course, rhs.course) {
                    return result
                }
            case .title:
                if let result = ServerRelaySyncItem.ascendingCompare(lhs.title, rhs.title) {
                    return result
                }
            case .kind:
                if let result = ServerRelaySyncItem.ascendingCompare(lhs.kindDisplayName, rhs.kindDisplayName) {
                    return result
                }
            case .status:
                if let result = ServerRelaySyncItem.ascendingCompare(lhs.status, rhs.status) {
                    return result
                }
            }

            if let result = ServerRelaySyncItem.ascendingCompare(lhs.title, rhs.title) {
                return result
            }
            if let result = ServerRelaySyncItem.ascendingCompare(lhs.course, rhs.course) {
                return result
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }
}

private extension ServerRelaySyncItem {
    var isCompanionChangedLike: Bool {
        let text = searchText
        return text.localizedCaseInsensitiveContains("new")
            || text.localizedCaseInsensitiveContains("updated")
            || text.localizedCaseInsensitiveContains("새")
            || text.localizedCaseInsensitiveContains("수정")
            || text.localizedCaseInsensitiveContains("신규")
            || status.localizedCaseInsensitiveContains("changed")
    }

    var searchText: String {
        [
            kindDisplayName,
            kind,
            course,
            academicTerm,
            academicYear.map(String.init) ?? "",
            academicSemester,
            title,
            timestamp,
            status,
            detail,
            kind == "notice" ? (isRead ? "읽음" : "안 읽음") : "",
            kind == "notice" && isImportant ? "중요" : "",
            isHidden ? "숨김" : "",
            attachmentCount > 0 ? "첨부 \(attachmentCount)" : "",
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    var kindDisplayName: String {
        switch kind {
        case "assignment":
            "과제"
        case "completedAssignment":
            "완료 과제"
        case "assignmentCandidate":
            "과제 후보"
        case "exam":
            "시험"
        case "examCandidate":
            "시험 후보"
        case "helpDesk":
            "헬프데스크"
        case "notice":
            "공지"
        case "file":
            "파일"
        default:
            kind
        }
    }

    static func descendingCompare(_ lhs: String, _ rhs: String) -> Bool? {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty && right.isEmpty {
            return nil
        }
        if left.isEmpty != right.isEmpty {
            return !left.isEmpty
        }
        let result = left.localizedStandardCompare(right)
        guard result != .orderedSame else {
            return nil
        }
        return result == .orderedDescending
    }

    static func ascendingCompare(_ lhs: String, _ rhs: String) -> Bool? {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty && right.isEmpty {
            return nil
        }
        if left.isEmpty != right.isEmpty {
            return !left.isEmpty
        }
        let result = left.localizedStandardCompare(right)
        guard result != .orderedSame else {
            return nil
        }
        return result == .orderedAscending
    }
}

private extension ServerRelayItemActionStatus {
    var isFailedLike: Bool {
        switch self {
        case .failed, .macUnavailable:
            true
        case .pending, .running, .completed:
            false
        }
    }
}

private extension ServerRelayItemActionKind {
    var companionActionTitle: String {
        switch self {
        case .assignmentComplete:
            "수정/완료"
        case .assignmentRestore, .assignmentUnhide:
            "수정/복구"
        case .assignmentHide:
            "삭제/숨김"
        case .examPromote:
            "반영/시험 확정"
        case .examIgnore:
            "삭제/시험 아님"
        case .examRestore:
            "수정/복구"
        case .noticeRead:
            "수정/읽음"
        case .noticeUnread:
            "수정/읽지 않음"
        case .noticeImportant:
            "수정/중요"
        case .noticeUnimportant:
            "수정/중요 해제"
        case .noticeHide:
            "삭제/숨김"
        case .noticeUnhide:
            "수정/복구"
        case .fileHide:
            "삭제/숨김"
        case .fileUnhide:
            "수정/복구"
        case .fileTrash:
            "삭제/휴지통"
        case .calendarVerify:
            "확인/캘린더"
        case .calendarApply:
            "KLMS 기준 반영"
        case .calendarEdit:
            "수정/캘린더"
        case .calendarDelete:
            "KLMS 기준 반영"
        }
    }

    var companionActionImage: String {
        switch self {
        case .assignmentComplete:
            "checkmark.circle"
        case .assignmentRestore, .assignmentUnhide, .examRestore, .noticeUnhide, .fileUnhide:
            "arrow.uturn.backward"
        case .assignmentHide, .examIgnore, .noticeHide, .fileHide:
            "eye.slash"
        case .fileTrash:
            "trash"
        case .calendarVerify:
            "checklist"
        case .calendarApply:
            "calendar.badge.checkmark"
        case .calendarEdit:
            "pencil"
        case .calendarDelete:
            "calendar.badge.checkmark"
        case .examPromote:
            "checkmark.seal"
        case .noticeRead:
            "checkmark.circle"
        case .noticeUnread:
            "circle"
        case .noticeImportant:
            "star"
        case .noticeUnimportant:
            "star.slash"
        }
    }
}

private struct ServerSyncDataRow: View, Equatable {
    var item: ServerRelaySyncItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kindName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    if !item.status.isEmpty {
                        Text(item.status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if item.isHidden {
                        Text("숨김")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.title.isEmpty ? "제목 없음" : item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        )
    }

    private var metadata: String {
        var parts: [String] = []
        if !item.course.isEmpty {
            parts.append(item.course)
        }
        if !item.academicTerm.isEmpty {
            parts.append(item.academicTerm)
        }
        if !item.timestamp.isEmpty {
            parts.append(item.timestamp)
        }
        if item.attachmentCount > 0 {
            parts.append("첨부 \(item.attachmentCount)")
        }
        if item.kind == "notice" {
            parts.append(item.isRead ? "읽음" : "안 읽음")
            if item.isImportant {
                parts.append("중요")
            }
        }
        if !item.detail.isEmpty {
            parts.append(item.detail)
        }
        return parts.isEmpty ? "세부 정보 없음" : parts.joined(separator: " · ")
    }

    private var kindName: String {
        switch item.kind {
        case "assignment":
            "과제"
        case "completedAssignment":
            "완료 과제"
        case "assignmentCandidate":
            "과제 후보"
        case "exam":
            "시험"
        case "examCandidate":
            "시험 후보"
        case "helpDesk":
            "헬프데스크"
        case "notice":
            "공지"
        case "file":
            "파일"
        default:
            item.kind
        }
    }

    private var systemImage: String {
        switch item.kind {
        case "assignment", "completedAssignment", "assignmentCandidate":
            "checklist"
        case "exam", "examCandidate":
            "calendar"
        case "notice":
            "note.text"
        case "file":
            "doc"
        case "helpDesk":
            "person.2"
        default:
            "circle"
        }
    }

    private var tint: Color {
        switch item.kind {
        case "assignment", "completedAssignment", "assignmentCandidate":
            .orange
        case "exam", "examCandidate":
            .green
        case "notice":
            .brown
        case "file":
            .blue
        default:
            .secondary
        }
    }
}

private struct RemoteCommandPanel: View {
    @ObservedObject var model: CompanionModel
    var compact: Bool

    private let commands: [RemoteCommandKind] = [.fullSync, .coreSync, .noticeSync, .filesSync]
    private let secondaryColumns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 3)

    private var primaryCommand: RemoteCommandKind {
        .fullSync
    }

    private var secondaryCommands: [RemoteCommandKind] {
        commands.filter { $0 != primaryCommand }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("동기화")
                    .font(.headline)
                Spacer()
                if model.hasInFlightRequest || model.status.phase == "running" {
                    Label(model.activeRequestLabel, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.klmsCommandAccent)
                }
            }
            Toggle(isOn: $model.shouldUpdateNoticeNotes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("공지 메모도 업데이트")
                        .font(.subheadline.weight(.semibold))
                    Text("끄면 전체/공지 동기화가 목록과 상태만 갱신하고 Mac의 Notes 메모는 건드리지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            primaryCommandActionCard(primaryCommand)
            LazyVGrid(columns: secondaryColumns, spacing: 8) {
                ForEach(secondaryCommands, id: \.self) { command in
                    commandActionCard(command)
                }
            }
            if compact {
                Text("점검 도구는 실행 탭에서 할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private func primaryCommandActionCard(_ kind: RemoteCommandKind) -> some View {
        Button {
            Task {
                await model.createCommand(kind)
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: kind.engineCommand.systemImage)
                    .font(.title3.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.18), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.displayName)
                        .font(.headline.weight(.semibold))
                    Text(kind.engineCommand.shortDescription)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 58 : 64, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(.klmsCommandAccent)
        .disabled(!model.isRemoteAvailable || model.isSubmitting || model.hasInFlightRequest)
        .accessibilityLabel("\(kind.displayName) 실행")
        .accessibilityHint("Mac 앱에 \(kind.displayName) 실행 요청을 보냅니다.")
    }

    private func commandActionCard(_ kind: RemoteCommandKind) -> some View {
        Button {
            Task {
                await model.createCommand(kind)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: kind.engineCommand.systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(kind.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 54 : 60, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .tint(.klmsCommandAccent)
        .disabled(!model.isRemoteAvailable || model.isSubmitting || model.hasInFlightRequest)
        .accessibilityLabel("\(kind.displayName) 실행")
        .accessibilityHint("Mac 앱에 \(kind.displayName) 실행 요청을 보냅니다.")
    }
}

private struct RemoteCancelControl: View {
    @ObservedObject var model: CompanionModel
    var compact: Bool
    @State private var localCancelSubmitting = false

    private var cancelAlreadyRequested: Bool {
        model.isCancelRequestedForLatestCommand
    }

    private var title: String {
        cancelAlreadyRequested ? "중단 요청 전송됨" : "동기화 중단 가능"
    }

    private var message: String {
        if cancelAlreadyRequested {
            return "Mac 앱이 중단 요청을 처리하는 중입니다."
        }
        return "Mac 앱에 \(model.activeRequestLabel) 실행을 중단하라고 요청합니다."
    }

    private var buttonTitle: String {
        if cancelAlreadyRequested {
            return "중단 요청됨"
        }
        return localCancelSubmitting || model.isSubmitting ? "중단 요청 중" : "지금 중단"
    }

    var body: some View {
        if model.shouldShowCancelControl {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(compact ? .subheadline.weight(.semibold) : .headline)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Button(role: .destructive) {
                    guard model.canCancelRunningCommand, !localCancelSubmitting else {
                        return
                    }
                    localCancelSubmitting = true
                    Task {
                        await model.cancelRunningCommand()
                        await MainActor.run {
                            localCancelSubmitting = false
                        }
                    }
                } label: {
                    Label(buttonTitle, systemImage: "stop.fill")
                        .frame(maxWidth: .infinity, minHeight: compact ? 38 : 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCancelRunningCommand || localCancelSubmitting || model.isSubmitting)
                .accessibilityHint("Mac 앱에 현재 실행 중인 KLMS 동기화를 중단하라고 요청합니다.")
            }
            .padding(14)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.red.opacity(0.22), lineWidth: 1)
            )
        }
    }
}

private struct RemoteRunRequestHistoryPanel: View {
    @ObservedObject var model: CompanionModel

    private var commandRows: [RemoteRunCommand] {
        Array(model.recentCommands.prefix(3))
    }

    private var fileRequestRows: [ServerRelayFileAccessRequest] {
        Array(model.recentFileAccessRequests.prefix(3))
    }

    private var serverRequestRows: [ServerRelayRequestLogEntry] {
        Array(model.recentRequestLog.prefix(5))
    }

    private var totalCount: Int {
        model.recentCommands.count + model.recentFileAccessRequests.count + model.recentRequestLog.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Label("요청 기록", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer(minLength: 8)
                Text(totalCount == 0 ? "없음" : "최근 \(totalCount)개")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if totalCount == 0 {
                Text("iPhone이나 Windows에서 실행, 파일 열기, 상태 갱신을 요청하면 여기에 최근 기록이 표시됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if !commandRows.isEmpty {
                        requestGroupTitle("원격 실행")
                        ForEach(commandRows) { command in
                            RemoteCommandRow(command: command, compact: true)
                        }
                    }
                    if !fileRequestRows.isEmpty {
                        requestGroupTitle("파일 요청")
                        ForEach(fileRequestRows) { request in
                            RemoteFileAccessRequestRow(request: request)
                        }
                    }
                    if !serverRequestRows.isEmpty {
                        requestGroupTitle("서버 요청")
                        ForEach(serverRequestRows) { entry in
                            ServerRequestLogRow(entry: entry)
                        }
                    }
                    Text("전체 내역은 아래 메뉴의 요청 기록 탭에서 볼 수 있습니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private func requestGroupTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}

private struct RemoteDiagnosticPanel: View {
    @ObservedObject var model: CompanionModel
    @State private var isPanelExpanded = false
    @State private var isAdvancedExpanded = false

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 8),
    ]
    private let dryRunCommands: [RemoteCommandKind] = [.fullSync, .coreSync, .noticeSync, .filesSync]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: $isPanelExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("동기화는 실행하지 않고 현재 상태를 확인하거나, 앱 대시보드에 필요한 보조 파일만 갱신합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: columns, spacing: 8) {
                        diagnosticButton(.verify)
                        diagnosticButton(.doctor)
                        diagnosticButton(.report)
                        diagnosticButton(.v2BuildState)
                    }

                    DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("실제 반영 없이 바뀔 항목 수만 계산합니다. 일반 실행 카드에서는 숨겨 둔 고급 기능입니다.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(dryRunCommands, id: \.self) { command in
                                    dryRunButton(command)
                                }
                            }
                            RemoteDryRunPanel(reports: model.dryRunReports)
                        }
                        .padding(.top, 6)
                    } label: {
                        Label("고급 도구", systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Label("점검 도구", systemImage: "wrench.and.screwdriver")
                        .font(.headline)
                    Spacer(minLength: 8)
                    Text(isPanelExpanded ? "접기" : "펼치기")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private func diagnosticButton(_ kind: RemoteCommandKind) -> some View {
        Button {
            Task {
                await model.createCommand(kind)
            }
        } label: {
            VStack(spacing: 4) {
                Label(kind.displayName, systemImage: kind.engineCommand.systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(kind.engineCommand.shortDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
        }
        .buttonStyle(.bordered)
        .disabled(!model.isRemoteAvailable || model.isSubmitting || model.hasInFlightRequest)
    }

    private func dryRunButton(_ kind: RemoteCommandKind) -> some View {
        Button {
            Task {
                await model.createCommand(kind, dryRun: true)
            }
        } label: {
            Label("\(kind.displayName) 변경량 계산", systemImage: "magnifyingglass")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(.bordered)
        .disabled(!model.isRemoteAvailable || model.isSubmitting || model.hasInFlightRequest || !kind.engineCommand.supportsDryRun)
        .accessibilityLabel("\(kind.displayName) 변경량 계산")
        .accessibilityHint("Mac 앱에 \(kind.displayName) 변경량 계산 요청을 보냅니다.")
    }
}

private struct RemoteDryRunPanel: View {
    var reports: [DryRunReport]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("변경량 계산 결과", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Text(reports.isEmpty ? "없음" : "\(reports.count)개")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if reports.isEmpty {
                Text("변경량 계산을 실행하면 변경 예정량이 여기에 표시됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(reports, id: \.scope) { report in
                    RemoteDryRunReportRow(report: report)
                }
            }
        }
        .padding(12)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct RemoteDryRunReportRow: View {
    var report: DryRunReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(report.scope.klmsScopeDisplayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(report.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text([
                report.wouldCreate > 0 ? "생성 \(report.wouldCreate)" : nil,
                report.wouldUpdate > 0 ? "수정 \(report.wouldUpdate)" : nil,
                report.wouldDelete > 0 ? "삭제 \(report.wouldDelete)" : nil,
                report.wouldDownload > 0 ? "다운로드 \(report.wouldDownload)" : nil,
                report.wouldPrune > 0 ? "정리 \(report.wouldPrune)" : nil,
            ].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "변경 예정 없음")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct RemoteSettingsPanel: View {
    @ObservedObject var model: CompanionModel
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                CompanionSettingHelpText("여기에서 바꾼 값은 서버 요청으로 올라가고, Mac 앱이 받아서 설정 파일(config.env)에 반영합니다. 알 수 없는 설정이나 개인정보처럼 보이는 값은 Mac 쪽에서 거부합니다.")
                if model.remoteSettings.isEmpty {
                    Text("Mac이 설정 목록을 서버에 올리면 여기에서 일부 설정을 바꿀 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.remoteSettings) { setting in
                        RemoteSettingRow(setting: setting, model: model)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Label("Mac 설정", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Text(model.remoteSettings.isEmpty ? "대기" : "\(model.remoteSettings.count)개")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private enum RemoteLogSummaryKind: String {
    case status
    case command
    case fileRequest
}

private extension ServerRelayLogClearScope {
    var clearTitle: String {
        switch self {
        case .all:
            "로그 지우기"
        case .command:
            "최근 실행 요청 지우기"
        case .requestLog:
            "서버 요청 기록 지우기"
        case .fileAccess:
            "파일 요청 기록 지우기"
        }
    }

    func clearMessage(_ result: ServerRelayLogClearResponse) -> String {
        switch self {
        case .all:
            return "실행 \(result.commands)개, 서버 요청 \(result.requestLogEntries)개, 파일 요청 \(result.fileAccessRequests)개 기록을 지웠습니다."
        case .command:
            return "최근 실행 요청 \(result.commands)개를 지웠습니다."
        case .requestLog:
            return "서버 요청 기록 \(result.requestLogEntries)개를 지웠습니다."
        case .fileAccess:
            return "파일 요청 기록 \(result.fileAccessRequests)개를 지웠습니다."
        }
    }

    var localClearMessage: String {
        switch self {
        case .all:
            "이 기기 화면의 완료된 실행, 서버 요청, 파일 요청 기록을 숨겼습니다. 진행 중인 요청은 유지됩니다."
        case .command:
            "이 기기 화면의 완료된 실행 요청 기록을 숨겼습니다. 진행 중인 요청은 유지됩니다."
        case .requestLog:
            "이 기기 화면의 서버 요청 기록을 숨겼습니다."
        case .fileAccess:
            "이 기기 화면의 완료된 파일 요청 기록을 숨겼습니다. 진행 중인 파일 요청은 유지됩니다."
        }
    }
}

private struct RemoteLogSummaryPanel: View {
    @ObservedObject var model: CompanionModel
    var compact: Bool
    @State private var expandedKind: RemoteLogSummaryKind?
    private static let terminalSummaryDisplayInterval: TimeInterval = 5 * 60

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("로그 요약", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer(minLength: 8)
                if let lastRefreshAt = model.lastRefreshAt {
                    Text(lastRefreshAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task {
                        await model.clearRemoteLogs()
                    }
                } label: {
                    Label("로그 지우기", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(!model.serverRelayConfigured || model.isSubmitting)
                .accessibilityLabel("로그 지우기")
            }

            VStack(spacing: 8) {
                RemoteLogSummaryRow(
                    title: "현재 상태",
                    value: model.statusLine,
                    detail: model.runningPhaseDetail ?? model.status.phase.klmsRemotePhaseName,
                    systemImage: statusSystemImage,
                    tint: statusTint,
                    isExpanded: expandedKind == .status
                ) {
                    toggle(.status)
                }
                RemoteLogSummaryRow(
                    title: "최근 실행 요청",
                    value: recentCommandValue,
                    detail: recentCommandDetail,
                    systemImage: recentCommandSystemImage,
                    tint: recentCommandTint,
                    isExpanded: expandedKind == .command
                ) {
                    toggle(.command)
                }
                if !compact || latestFileRequest != nil {
                    RemoteLogSummaryRow(
                        title: "파일 요청",
                        value: fileRequestValue,
                        detail: fileRequestDetail,
                        systemImage: fileRequestSystemImage,
                        tint: fileRequestTint,
                        isExpanded: expandedKind == .fileRequest
                    ) {
                        toggle(.fileRequest)
                    }
                }

                if let expandedKind {
                    RemoteLogDetailPanel(kind: expandedKind, model: model)
                        .transition(.opacity)
                } else {
                    Text("요약 행을 누르면 관련 기록을 바로 펼칩니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var latestFileRequest: ServerRelayFileAccessRequest? {
        if let active = model.recentFileAccessRequests.first(where: { $0.status.isInFlight }) {
            return active
        }
        return model.recentFileAccessRequests.first {
            Date().timeIntervalSince($0.updatedAt) <= Self.terminalSummaryDisplayInterval
        }
    }

    private var currentCommand: RemoteRunCommand? {
        guard let command = model.latestCommand else {
            return nil
        }
        let status = command.displayStatus()
        if status.isInFlight {
            return command
        }
        if Date().timeIntervalSince(command.updatedAt) <= Self.terminalSummaryDisplayInterval {
            return command
        }
        return nil
    }

    private var statusSystemImage: String {
        if model.status.authDigits != nil {
            return "key"
        }
        if model.hasInFlightRequest || model.status.phase == "running" {
            return "arrow.triangle.2.circlepath"
        }
        if model.status.loginRequired {
            return "person.crop.circle.badge.exclamationmark"
        }
        return "gauge"
    }

    private var statusTint: Color {
        if model.status.authDigits != nil || model.status.loginRequired {
            return .orange
        }
        if model.hasInFlightRequest || model.status.phase == "running" {
            return .klmsCommandAccent
        }
        if model.latestDisplayStatus == .failed || model.latestDisplayStatus == .macUnavailable {
            return .orange
        }
        if model.latestDisplayStatus == .cancelled {
            return .secondary
        }
        return .green
    }

    private var recentCommandValue: String {
        guard let command = currentCommand else {
            return model.latestCommand == nil ? "요청 기록 없음" : "현재 요청 없음"
        }
        return "\(command.kind.displayName) · \(command.displayStatus().displayName)"
    }

    private var recentCommandDetail: String {
        guard let command = currentCommand else {
            return model.latestCommand == nil
                ? "실행 버튼을 누르면 Mac 앱에 요청이 올라갑니다."
                : "지난 완료/실패 기록은 이 행을 펼쳐서 확인할 수 있습니다."
        }
        var parts = [
            "과제 \(command.summary.assignments)",
            "시험 \(command.summary.exams)",
            "공지 \(command.summary.notices)",
            "파일 \(command.summary.fileTotal)",
        ]
        if command.summary.calendarChangeTotal > 0 {
            parts.append("캘린더 \(command.summary.calendarChangeTotal)")
        }
        return parts.joined(separator: " · ")
    }

    private var recentCommandSystemImage: String {
        currentCommand?.kind.engineCommand.systemImage ?? "clock"
    }

    private var recentCommandTint: Color {
        switch currentCommand?.displayStatus() {
        case .pending, .running:
            return .klmsCommandAccent
        case .completed:
            return .green
        case .cancelled:
            return .secondary
        case .failed, .macUnavailable:
            return .orange
        case nil:
            return .secondary
        }
    }

    private var fileRequestValue: String {
        guard let latestFileRequest else {
            return "요청 없음"
        }
        return latestFileRequest.status.displayName
    }

    private var fileRequestDetail: String {
        guard let latestFileRequest else {
            return model.recentFileAccessRequests.isEmpty
                ? "파일 항목에서 링크 요청을 누르면 Mac이 임시 링크를 준비합니다."
                : "지난 완료/실패 기록은 이 행을 펼쳐서 확인할 수 있습니다."
        }
        let title = latestFileRequest.itemTitle.nilIfEmpty ?? "파일"
        let message = latestFileRequest.message.nilIfEmpty ?? latestFileRequest.updatedAt.formatted(date: .omitted, time: .shortened)
        return "\(title) · \(message)"
    }

    private var fileRequestSystemImage: String {
        switch latestFileRequest?.status {
        case .pending:
            return "clock"
        case .running:
            return "arrow.up.doc"
        case .completed:
            return "link.circle.fill"
        case .failed, .macUnavailable:
            return "exclamationmark.triangle.fill"
        case nil:
            return "doc.badge.arrow.up"
        }
    }

    private var fileRequestTint: Color {
        switch latestFileRequest?.status {
        case .pending, .running:
            return .klmsCommandAccent
        case .completed:
            return .green
        case .failed, .macUnavailable:
            return .orange
        case nil:
            return .secondary
        }
    }

    private func toggle(_ kind: RemoteLogSummaryKind) {
        withAnimation(.easeInOut(duration: 0.16)) {
            expandedKind = expandedKind == kind ? nil : kind
        }
    }
}

private struct RemoteLogDetailPanel: View {
    var kind: RemoteLogSummaryKind
    @ObservedObject var model: CompanionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch kind {
            case .status:
                statusDetails
            case .command:
                RecentRemoteCommandsView(
                    commands: model.recentCommands,
                    compact: false,
                    clearAction: {
                        Task {
                            await model.clearRemoteLogs(scope: .command)
                        }
                    },
                    clearDisabled: !model.serverRelayConfigured
                        || model.isSubmitting
                        || !model.recentCommands.contains { !$0.status.isInFlight }
                )
            case .fileRequest:
                RecentFileAccessRequestsView(
                    requests: model.recentFileAccessRequests,
                    clearAction: {
                        Task {
                            await model.clearRemoteLogs(scope: .fileAccess)
                        }
                    },
                    clearDisabled: !model.serverRelayConfigured
                        || model.isSubmitting
                        || model.recentFileAccessRequests.isEmpty
                        || model.recentFileAccessRequests.contains { $0.status.isInFlight }
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private var statusDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailFieldRow(title: "현재 표시", value: model.statusLine)
            DetailFieldRow(title: "단계", value: model.status.phase.klmsRemotePhaseName)
            DetailFieldRow(title: "세부 단계", value: model.runningPhaseDetail ?? "")
            if let latest = model.latestCommand {
                DetailFieldRow(title: "최근 요청", value: "\(latest.kind.displayName) · \(latest.displayStatus().displayName)")
            }
            if let lastRefreshAt = model.lastRefreshAt {
                DetailFieldRow(title: "최근 갱신", value: lastRefreshAt.formatted(date: .abbreviated, time: .standard))
            }
        }
    }
}

private struct RemoteLogSummaryRow: View {
    var title: String
    var value: String
    var detail: String
    var systemImage: String
    var tint: Color
    var isExpanded: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isExpanded ? tint.opacity(0.32) : Color.klmsBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint(isExpanded ? "관련 기록 접기" : "관련 기록 펼치기")
    }
}

private struct SharedRunLogsView: View {
    var logs: [ServerRelayRunLog]
    var clearAction: (() -> Void)?
    var clearDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("공유 실행 로그")
                    .font(.headline)
                Spacer()
                if !logs.isEmpty {
                    Text("최근 \(logs.count)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let clearAction {
                    Button(action: clearAction) {
                        Label("지우기", systemImage: "trash")
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(clearDisabled)
                }
            }
            Text("Mac이 실행한 동기화 결과를 모든 기기가 함께 보는 기록입니다. 지우면 다른 기기에서도 사라집니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if logs.isEmpty {
                Text("아직 공유 실행 로그가 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quinary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(logs.prefix(30)) { log in
                        SharedRunLogRow(log: log)
                    }
                }
            }
        }
    }
}

private struct SharedRunLogRow: View {
    var log: ServerRelayRunLog
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(log.commandTitle.nilIfEmpty ?? "동기화")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(log.status) · \(log.duration) · \(log.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if log.dryRun {
                        Text("미리보기 실행")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if isExpanded {
                CompanionInlineLogBlock(text: log.outputTail)
            }
        }
        .padding(12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.18)) {
                isExpanded.toggle()
            }
        }
    }

    private var systemImage: String {
        if log.wasCancelled {
            return "stop.circle"
        }
        if log.needsAttention {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var tint: Color {
        if log.wasCancelled {
            return .secondary
        }
        return log.needsAttention ? .orange : .green
    }
}

private struct RecentFileAccessRequestsView: View {
    var requests: [ServerRelayFileAccessRequest]
    var clearAction: (() -> Void)?
    var clearDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("파일 요청 기록")
                    .font(.headline)
                Spacer()
                if !requests.isEmpty {
                    Text("최근 \(requests.count)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let clearAction {
                    Button(action: clearAction) {
                        Label("지우기", systemImage: "trash")
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(clearDisabled)
                }
            }
            if requests.isEmpty {
                Text("아직 파일 요청 기록이 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quinary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 8) {
                    ForEach(requests) { request in
                        RemoteFileAccessRequestRow(request: request)
                    }
                }
            }
        }
    }
}

private struct RecentServerRequestLogView: View {
    var entries: [ServerRelayRequestLogEntry]
    var clearAction: (() -> Void)?
    var clearDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("서버 요청 기록")
                    .font(.headline)
                Spacer()
                if !entries.isEmpty {
                    Text("최근 \(entries.count)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let clearAction {
                    Button(action: clearAction) {
                        Label("지우기", systemImage: "trash")
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(clearDisabled)
                }
            }
            if entries.isEmpty {
                Text("아직 서버 요청 기록이 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quinary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(entries.prefix(30)) { entry in
                        ServerRequestLogRow(entry: entry)
                    }
                }
            }
        }
    }
}

private struct ServerRequestLogRow: View {
    var entry: ServerRelayRequestLogEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: sourceIcon)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.action.nilIfEmpty ?? entry.path.nilIfEmpty ?? "서버 요청")
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(entry.sourceDisplayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.quinary, in: Capsule())
                    }
                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(entry.statusDisplayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.10), in: Capsule())
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if isExpanded {
                CompanionInlineLogBlock(text: expandedLog)
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.quaternary, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.18)) {
                isExpanded.toggle()
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let message = entry.message.nilIfEmpty {
            parts.append(message)
        }
        let route = [entry.method.nilIfEmpty, entry.path.nilIfEmpty].compactMap { $0 }.joined(separator: " ")
        if !route.isEmpty {
            parts.append(route)
        }
        return parts.isEmpty ? "서버가 받은 요청입니다." : parts.joined(separator: " · ")
    }

    private var expandedLog: String {
        var lines = [
            "요청: \(entry.action.nilIfEmpty ?? "서버 요청")",
            "출처: \(entry.sourceDisplayName)",
            "상태: \(entry.statusDisplayName)",
            "시간: \(entry.createdAt.formatted(date: .abbreviated, time: .standard))",
        ]
        let route = [entry.method.nilIfEmpty, entry.path.nilIfEmpty].compactMap { $0 }.joined(separator: " ")
        if !route.isEmpty {
            lines.append("경로: \(route)")
        }
        if let message = entry.message.nilIfEmpty {
            lines.append("메시지: \(message)")
        }
        return lines.joined(separator: "\n")
    }

    private var sourceIcon: String {
        switch entry.sourceDisplayName.lowercased() {
        case let value where value.contains("iphone"):
            return "iphone"
        case let value where value.contains("windows"):
            return "desktopcomputer"
        case let value where value.contains("mac"):
            return "laptopcomputer"
        default:
            return "network"
        }
    }

    private var tint: Color {
        switch entry.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "failed", "rejected", "error":
            return .orange
        case "running":
            return .blue
        default:
            return .green
        }
    }
}

private struct RemoteFileAccessRequestRow: View {
    var request: ServerRelayFileAccessRequest
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.itemTitle.nilIfEmpty ?? "파일")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(request.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let message = request.message.nilIfEmpty {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(request.status.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if isExpanded {
                CompanionInlineLogBlock(text: expandedLog)
            }
        }
        .padding(12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.18)) {
                isExpanded.toggle()
            }
        }
    }

    private var expandedLog: String {
        var lines = [
            "파일: \(request.itemTitle.nilIfEmpty ?? "파일")",
            "상태: \(request.status.displayName)",
            "생성: \(request.createdAt.formatted(date: .abbreviated, time: .standard))",
            "갱신: \(request.updatedAt.formatted(date: .abbreviated, time: .standard))",
        ]
        if let message = request.message.nilIfEmpty {
            lines.append("메시지: \(message)")
        }
        if let sizeBytes = request.sizeBytes, sizeBytes > 0 {
            lines.append("크기: \(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))")
        }
        if let expiresAt = request.expiresAt {
            lines.append("만료: \(expiresAt.formatted(date: .abbreviated, time: .standard))")
        }
        lines.append("링크: \(request.isDownloadAvailable ? "열기 가능" : "준비 안 됨/만료")")
        return lines.joined(separator: "\n")
    }

    private var systemImage: String {
        switch request.status {
        case .pending:
            return "clock"
        case .running:
            return "arrow.up.doc"
        case .completed:
            return "link.circle.fill"
        case .failed, .macUnavailable:
            return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch request.status {
        case .pending, .running:
            return .blue
        case .completed:
            return .green
        case .failed, .macUnavailable:
            return .orange
        }
    }
}

private struct CompanionInlineLogBlock: View {
    var text: String

    var body: some View {
        Text(text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "표시할 로그가 없습니다.")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary, lineWidth: 1)
            )
    }
}

private struct RemoteSettingRow: View {
    var setting: ServerRelaySetting
    @ObservedObject var model: CompanionModel
    @State private var draftValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(setting.title)
                        .font(.subheadline.weight(.semibold))
                    Text(setting.key)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let detail = settingExplanation {
                        CompanionSettingHelpText(detail)
                    }
                }
                Spacer(minLength: 8)
                control
            }
        }
        .padding(10)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            if draftValue.isEmpty {
                draftValue = setting.value
            }
        }
        .onChange(of: setting.value) { _, newValue in
            draftValue = newValue
        }
    }

    @ViewBuilder
    private var control: some View {
        switch setting.valueKind {
        case .bool:
            Button {
                Task {
                    await model.createSettingAction(
                        setting: setting,
                        value: setting.boolValue ? "0" : "1"
                    )
                }
            } label: {
                Text(setting.boolValue ? "끄기" : "켜기")
                    .frame(minWidth: 58)
            }
            .buttonStyle(.bordered)
            .disabled(!setting.editable || model.isSubmitting)
        case .choice:
            Menu {
                ForEach(setting.options, id: \.self) { option in
                    Button(option) {
                        Task {
                            await model.createSettingAction(setting: setting, value: option)
                        }
                    }
                }
            } label: {
                Label(setting.value.nilIfEmpty ?? "선택", systemImage: "chevron.up.chevron.down")
            }
            .disabled(!setting.editable || model.isSubmitting)
        case .number, .text:
            HStack(spacing: 6) {
                TextField("값", text: $draftValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                Button("저장") {
                    Task {
                        await model.createSettingAction(setting: setting, value: draftValue)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!setting.editable || model.isSubmitting || draftValue == setting.value)
            }
        }
    }

    private var settingExplanation: String? {
        switch setting.key {
        case "SYNC_INTERVAL_SECONDS":
            return "자동 실행이 다음 실행 여부를 확인하는 간격입니다. iPhone에서 누르는 수동 실행에는 영향을 주지 않습니다."
        case "MIN_IDLE_SECONDS":
            return "Mac에서 키보드나 마우스를 이 시간 이상 사용하지 않았을 때만 자동 실행을 허용합니다."
        case "SYNC_MODE":
            return "자동은 캐시와 변경 여부를 보고 필요한 범위를 고릅니다. 빠르게는 기존 데이터를 우선 재사용하고, 전체는 가능한 데이터를 다시 읽습니다."
        case "FILE_REFRESH_MODE":
            return "자동은 변경 가능성이 있는 파일 페이지를 더 확인합니다. 빠르게는 기존 캐시 재사용을 우선합니다."
        case "FILE_SKIP_DOWNLOAD_WHEN_PREVIEW_EMPTY":
            return "변경량 계산에서 새 파일이나 수정된 파일이 없으면 실제 다운로드 단계를 건너뜁니다."
        case "NOTICE_HIDE_HIDDEN_ITEMS":
            return "숨긴 공지는 Notes 메모에 쓰지 않습니다. KLMS 원본 공지는 그대로 둡니다."
        case "NOTICE_NATIVE_STABLE_NOOP_SKIP":
            return "동기화할 때마다 Notes 체크리스트 상태를 다시 읽어 읽음/중요 표시를 유지합니다. 변경이 없으면 메모 다시 쓰기는 건너뜁니다."
        case "SYNC_ABORT_ON_USER_ACTIVITY":
            return "자동 동기화 중 사용자가 Mac을 다시 쓰기 시작하면 Safari와 Notes가 방해되지 않도록 실행을 멈춥니다."
        case "SYNC_ACTIVE_ABORT_IDLE_SECONDS":
            return "사용자 활동으로 판단할 유휴 기준입니다. 값이 작을수록 자동 실행을 더 빨리 멈춥니다."
        case "KLMS_SAFARI_BACKGROUND_WINDOW_MODE":
            return "Safari 자동화 창을 처리하는 방식입니다. 앱은 KLMS 전용 Safari 창을 최소화해 백그라운드에서 사용합니다."
        default:
            return nil
        }
    }
}

private struct RecentRemoteCommandsView: View {
    var commands: [RemoteRunCommand]
    var compact: Bool
    var clearAction: (() -> Void)? = nil
    var clearDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(compact ? "최근 요청" : "최근 요청 기록")
                    .font(.headline)
                Spacer()
                if compact, !commands.isEmpty {
                    Text("최근 \(commands.count)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let clearAction {
                    Button(action: clearAction) {
                        Label("지우기", systemImage: "trash")
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(clearDisabled)
                }
            }
            if commands.isEmpty {
                Text("아직 요청 기록이 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quinary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 8) {
                    ForEach(commands) { command in
                        RemoteCommandRow(command: command, compact: compact)
                    }
                }
            }
        }
    }
}

private struct RemoteCommandRow: View {
    var command: RemoteRunCommand
    var compact: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: command.kind.engineCommand.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(command.kind.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(command.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !compact {
                        Text(summaryText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 2)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(command.displayStatus().displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                    if let authDigits = command.summary.authDigits {
                        Text("인증 \(authDigits)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.orange)
                    } else if command.displayStatus().isInFlight,
                              let authStatusMessage = command.summary.authStatusMessage {
                        Text(authStatusMessage)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    } else if command.loginRequired {
                        Text("로그인 필요")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if let exitCode = command.lastExitCode {
                        Text("종료 \(exitCode)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if isExpanded {
                CompanionInlineLogBlock(text: expandedLog)
            }
        }
        .padding(12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.18)) {
                isExpanded.toggle()
            }
        }
    }

    private var statusColor: Color {
        switch command.displayStatus() {
        case .pending, .running:
            .blue
        case .completed:
            .green
        case .cancelled:
            .secondary
        case .failed, .macUnavailable:
            .orange
        }
    }

    private var summaryText: String {
        var parts = [
            "과제 \(command.summary.assignments)",
            "시험 \(command.summary.exams)",
            "공지 \(command.summary.notices)",
            "새 파일 \(command.summary.newFiles)",
        ]
        if command.summary.calendarChangeTotal > 0 {
            parts.append("캘린더 \(command.summary.calendarChangeTotal)")
        }
        if command.summary.quarantine > 0 {
            parts.append("격리 \(command.summary.quarantine)")
        }
        return parts.joined(separator: " · ")
    }

    private var expandedLog: String {
        var lines = [
            "요청: \(command.kind.displayName)",
            "상태: \(command.displayStatus().displayName)",
            "생성: \(command.createdAt.formatted(date: .abbreviated, time: .standard))",
            "갱신: \(command.updatedAt.formatted(date: .abbreviated, time: .standard))",
            "메모 업데이트: \(command.options.updateNoticeNotes ? "함" : "안 함")",
            "미리보기 실행: \(command.options.dryRun ? "예" : "아니오")",
        ]
        if let lastExitCode = command.lastExitCode {
            lines.append("종료 코드: \(lastExitCode)")
        }
        if command.loginRequired {
            lines.append("로그인: 필요")
        }
        if let authDigits = command.summary.authDigits {
            lines.append("인증 번호: \(authDigits)")
        }
        if let authMessage = command.summary.authStatusMessage?.nilIfEmpty {
            lines.append("인증 상태: \(authMessage)")
        }
        if let phaseDetail = command.summary.phaseDetail?.nilIfEmpty {
            lines.append("단계 상세: \(phaseDetail)")
        } else if !command.summary.phase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("단계: \(command.summary.phase.klmsRemotePhaseName)")
        }
        lines.append("요약: \(summaryText)")
        return lines.joined(separator: "\n")
    }
}

private struct RemotePrivacyNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("원격 요청은 클라이언트 토큰으로 보호됩니다", systemImage: "lock")
                .font(.subheadline.weight(.semibold))
            Text("Cloudflare 서버 릴레이는 실행 요청과 요약 상태만 보관합니다. 파일은 사용자가 열기를 요청할 때만 Mac이 임시로 올리고, 링크가 만료되면 서버 기록과 임시 파일을 정리합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct CompanionSettingHelpText: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InfoBanner: View {
    var message: String

    var body: some View {
        Label(message, systemImage: "info.circle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ErrorBanner: View {
    var message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct AuthSuccessBanner: View {
    var message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.green)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.green.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct AuthCodeHero: View {
    var digits: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text("KAIST 인증 번호")
                        .font(.headline)
                    Text("휴대폰 인증 화면에서 같은 번호를 선택하세요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text(digits)
                .font(.system(size: 58, weight: .black, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 88)
                .foregroundStyle(.orange)
                .background(Color.orange.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("KAIST 인증 번호 \(digits)")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }
}

private struct LoginAttentionBanner: View {
    var message: String

    var body: some View {
        Label(message, systemImage: "key")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private extension View {
    @ViewBuilder
    func klmsNavigationTitleMode() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func klmsNavigationChrome() -> some View {
        #if os(iOS)
        self
            .toolbarBackground(Color.klmsScreenBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        #else
        self
        #endif
    }

    @ViewBuilder
    func klmsTabChrome() -> some View {
        #if os(iOS)
        self
            .toolbarBackground(Color.klmsScreenBackground, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
        #else
        self
        #endif
    }
}

private extension Color {
    static var klmsScreenBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.white
        #endif
    }

    static var klmsCardBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.white
        #endif
    }

    static var klmsSubtleCardBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .tertiarySystemGroupedBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .quaternaryLabelColor).opacity(0.14)
        #else
        Color.gray.opacity(0.08)
        #endif
    }

    static var klmsBorder: Color {
        #if canImport(UIKit)
        Color(uiColor: .separator).opacity(0.28)
        #elseif canImport(AppKit)
        Color.black.opacity(0.05)
        #else
        Color.gray.opacity(0.18)
        #endif
    }

    static var klmsCommandAccent: Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.60, green: 0.53, blue: 0.65, alpha: 1.0)
                : UIColor(red: 0.31, green: 0.24, blue: 0.35, alpha: 1.0)
        })
        #elseif canImport(AppKit)
        Color(red: 0.31, green: 0.24, blue: 0.35)
        #else
        Color.gray
        #endif
    }

    static var klmsCommandBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
                : UIColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1.0)
        })
        #elseif canImport(AppKit)
        Color.klmsCommandAccent.opacity(0.10)
        #else
        Color.gray.opacity(0.08)
        #endif
    }

    static var klmsCommandBorder: Color {
        Color.klmsCommandAccent.opacity(0.30)
    }
}

private extension SanitizedRemoteStatus {
    var hasCompanionChangeSummary: Bool {
        noticeNew > 0
            || noticeUpdated > 0
            || newFiles > 0
            || fileCleanupTotal > 0
            || calendarChangeTotal > 0
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var klmsRemotePhaseName: String {
        switch trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "running":
            "요청 처리 중"
        case "completed":
            "완료"
        case "failed":
            "실패"
        case "busy":
            "Mac 실행 중"
        case "idle":
            "대기 중"
        case "":
            "상태 없음"
        default:
            self
        }
    }

    var klmsScopeDisplayName: String {
        switch trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "all", "full":
            "전체"
        case "core":
            "과제/시험"
        case "notice":
            "공지"
        case "files", "file":
            "파일"
        default:
            isEmpty ? "범위 없음" : self
        }
    }
}
