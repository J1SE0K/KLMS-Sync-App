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

private enum KLMSAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            "시스템"
        case .light:
            "라이트"
        case .dark:
            "다크"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

@main
struct KLMSiOSApp: App {
    @AppStorage("KLMSAppearanceMode") private var appearanceMode = KLMSAppearanceMode.system.rawValue

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .background(Color.klmsScreenBackground.ignoresSafeArea())
                .preferredColorScheme(KLMSAppearanceMode(rawValue: appearanceMode)?.colorScheme)
                .onAppear {
                    Self.schedulePlatformAppearance(appearanceMode)
                }
                .onChange(of: appearanceMode) { _, newValue in
                    Self.schedulePlatformAppearance(newValue)
                }
        }
    }

    private static func schedulePlatformAppearance(_ rawValue: String) {
        Task { @MainActor in
            applyPlatformAppearance(rawValue)
        }
    }

    @MainActor
    private static func applyPlatformAppearance(_ rawValue: String) {
        #if canImport(UIKit)
        let mode = KLMSAppearanceMode(rawValue: rawValue) ?? .system
        let style: UIUserInterfaceStyle
        switch mode {
        case .system:
            style = .unspecified
        case .light:
            style = .light
        case .dark:
            style = .dark
        }

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
        #endif
    }
}

@MainActor
final class CompanionModel: ObservableObject {
    @Published var recentCommands: [RemoteRunCommand] = [] {
        didSet { rebuildRemoteLogDerivedState() }
    }
    @Published var recentRequestLog: [ServerRelayRequestLogEntry] = [] {
        didSet { rebuildRemoteLogDerivedState() }
    }
    @Published var recentFileAccessRequests: [ServerRelayFileAccessRequest] = [] {
        didSet {
            rebuildFileAccessLookup()
            rebuildRemoteLogDerivedState()
        }
    }
    @Published var recentItemActions: [ServerRelayItemAction] = [] {
        didSet {
            rebuildItemActionLookups()
            rebuildVisibleCalendarChanges()
            rebuildRemoteLogDerivedState()
        }
    }
    @Published var recentSettingActions: [ServerRelaySettingAction] = [] {
        didSet { rebuildRemoteLogDerivedState() }
    }
    @Published var syncItems: [ServerRelaySyncItem] = [] {
        didSet { rebuildDashboardDerivedState(); rebuildChangeSummaryItemLookup(); rebuildVisibleCalendarChanges() }
    }
    @Published var dryRunReports: [DryRunReport] = [] {
        didSet { rebuildDashboardFileCleanupDetails(); rebuildFileCleanupReportCache() }
    }
    @Published var calendarChanges: [CalendarChange] = [] {
        didSet { rebuildVisibleCalendarChanges() }
    }
    @Published var remoteSettings: [ServerRelaySetting] = []
    @Published var sharedRunLogs: [ServerRelayRunLog] = [] {
        didSet {
            rebuildSharedRunLogStageDurationCache()
            rebuildRemoteLogDerivedState()
        }
    }
    @Published var verifySummary: ServerRelayVerifySummary?
    @Published var sharedSettings: [ServerRelaySetting] = []
    @Published var mailDashboardItems: [ServerRelaySyncItem] = [] {
        didSet { rebuildDashboardDerivedState(); rebuildVisibleCalendarChanges() }
    }
    @Published private(set) var dashboardSyncItems: [ServerRelaySyncItem] = []
    @Published private(set) var dashboardSyncItemsRevision = 0
    @Published private(set) var dashboardHasFileCleanupDetails = false
    @Published private(set) var visibleCalendarChangesCache: [CalendarChange] = []
    @Published private(set) var changeSummaryItemsByKindID: [String: [ServerRelaySyncItem]] = [:]
    @Published private(set) var changeSummaryCalendarChangesByKindID: [String: [CalendarChange]] = [:]
    @Published private(set) var fileCleanupReportsForDashboard: [DryRunReport] = []
    @Published private(set) var dashboardStatus = SanitizedRemoteStatus()
    @Published private(set) var currentRemoteLogCommand: RemoteRunCommand?
    @Published private(set) var latestRemoteLogFileRequest: ServerRelayFileAccessRequest?
    @Published private(set) var activeRemoteLogCommand: RemoteRunCommand?
    @Published private(set) var activeRemoteLogFileRequest: ServerRelayFileAccessRequest?
    @Published private(set) var hasClearableRemoteLogsCache = false
    @Published private(set) var hasClearableCommandLogs = false
    @Published private(set) var hasClearableRequestLogs = false
    @Published private(set) var hasClearableFileAccessLogs = false
    @Published private(set) var sharedRunLogStageDurationsByID: [String: [KLMSStageDuration]] = [:]
    @Published private(set) var latestSharedRunLogStageDurations: [KLMSStageDuration] = []
    @Published var status = SanitizedRemoteStatus() {
        didSet { rebuildDashboardStatus() }
    }
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
    private var resolvedCalendarChangeIDs = Set<String>()
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
    private var sharedSettingsSignature: Int?
    private var sharedRunLogsSignature: Int?
    private var verifySummarySignature: Int?
    private var lastTerminalCommandID: UUID?
    private let syncDataStaleInterval: TimeInterval = 45
    private var latestFileAccessRequestByItemID: [String: ServerRelayFileAccessRequest] = [:]
    private var activeItemActionByItemID: [String: ServerRelayItemAction] = [:]
    private var activeCalendarActionByID: [String: ServerRelayItemAction] = [:]
    private var dashboardItemsByCategoryID: [String: [ServerRelaySyncItem]] = [:]
    private var visibleDashboardItemsByCategoryID: [String: [ServerRelaySyncItem]] = [:]
    private var dashboardFilterOptionsByCategoryID: [String: CompanionItemFilterOptions] = [:]
    private var visibleDashboardTaskItems: [ServerRelaySyncItem] = []

    private static let terminalLogSummaryDisplayInterval: TimeInterval = 5 * 60

    private static let deprecatedLocalHostKey = "KLMSLocalRemoteHost"
    private static let deprecatedLocalPortKey = "KLMSLocalRemotePort"
    private static let deprecatedLocalTokenKey = "KLMSLocalRemoteToken"
    private static let serverURLKey = "KLMSServerRelayURL"
    private static let serverTokenKey = "KLMSServerRelayToken"
    private static let shouldUpdateNoticeNotesKey = "KLMSShouldUpdateNoticeNotes"
    private static let sharedAppearanceModeKey = "KLMS_APPEARANCE_MODE"
    private static let sharedNoticeUpdateNotesKey = "KLMS_UPDATE_NOTICE_NOTES"
    private static let trackedReportNotificationCommandIDsKey = "KLMSTrackedReportNotificationCommandIDs"
    private static let mailDashboardItemsKey = "KLMSCompanionMailDashboardItems"
    private static let resolvedCalendarChangeIDsKey = "KLMSResolvedCalendarChangeIDs"

    private struct PendingRefreshRequest {
        var silentErrors: Bool
        var includeSyncData: Bool?
        var showsActivity: Bool
        var scope: RelayRefreshScope

        mutating func merge(
            silentErrors newSilentErrors: Bool,
            includeSyncData newIncludeSyncData: Bool?,
            showsActivity newShowsActivity: Bool,
            scope newScope: RelayRefreshScope
        ) {
            silentErrors = silentErrors && newSilentErrors
            showsActivity = showsActivity || newShowsActivity
            if includeSyncData != true {
                includeSyncData = newIncludeSyncData
            }
            scope.formUnion(newScope)
        }
    }

    struct RelayRefreshScope: Equatable {
        var fetchesCommands: Bool
        var fetchesSyncData: Bool
        var fetchesFileRequests: Bool
        var fetchesItemActions: Bool
        var fetchesRequestLog: Bool
        var fetchesSettingActions: Bool

        var hasClientFetchWork: Bool {
            fetchesCommands
                || fetchesSyncData
                || fetchesFileRequests
                || fetchesItemActions
                || fetchesRequestLog
                || fetchesSettingActions
        }

        mutating func formUnion(_ other: RelayRefreshScope) {
            fetchesCommands = fetchesCommands || other.fetchesCommands
            fetchesSyncData = fetchesSyncData || other.fetchesSyncData
            fetchesFileRequests = fetchesFileRequests || other.fetchesFileRequests
            fetchesItemActions = fetchesItemActions || other.fetchesItemActions
            fetchesRequestLog = fetchesRequestLog || other.fetchesRequestLog
            fetchesSettingActions = fetchesSettingActions || other.fetchesSettingActions
        }

        static let full = RelayRefreshScope(
            fetchesCommands: true,
            fetchesSyncData: true,
            fetchesFileRequests: true,
            fetchesItemActions: true,
            fetchesRequestLog: true,
            fetchesSettingActions: true
        )

        static let state = RelayRefreshScope(
            fetchesCommands: true,
            fetchesSyncData: false,
            fetchesFileRequests: false,
            fetchesItemActions: false,
            fetchesRequestLog: false,
            fetchesSettingActions: false
        )

        static let commandRequest = RelayRefreshScope(
            fetchesCommands: true,
            fetchesSyncData: false,
            fetchesFileRequests: false,
            fetchesItemActions: false,
            fetchesRequestLog: true,
            fetchesSettingActions: false
        )

        static let syncData = RelayRefreshScope(
            fetchesCommands: false,
            fetchesSyncData: true,
            fetchesFileRequests: false,
            fetchesItemActions: false,
            fetchesRequestLog: false,
            fetchesSettingActions: false
        )

        static let fileAccess = RelayRefreshScope(
            fetchesCommands: false,
            fetchesSyncData: false,
            fetchesFileRequests: true,
            fetchesItemActions: false,
            fetchesRequestLog: true,
            fetchesSettingActions: false
        )

        static let itemActions = RelayRefreshScope(
            fetchesCommands: false,
            fetchesSyncData: true,
            fetchesFileRequests: false,
            fetchesItemActions: true,
            fetchesRequestLog: true,
            fetchesSettingActions: false
        )

        static let settings = RelayRefreshScope(
            fetchesCommands: false,
            fetchesSyncData: true,
            fetchesFileRequests: false,
            fetchesItemActions: false,
            fetchesRequestLog: true,
            fetchesSettingActions: true
        )

        static let settingActions = RelayRefreshScope(
            fetchesCommands: false,
            fetchesSyncData: true,
            fetchesFileRequests: false,
            fetchesItemActions: false,
            fetchesRequestLog: true,
            fetchesSettingActions: true
        )

        static let requestLog = RelayRefreshScope(
            fetchesCommands: false,
            fetchesSyncData: false,
            fetchesFileRequests: false,
            fetchesItemActions: false,
            fetchesRequestLog: true,
            fetchesSettingActions: false
        )

        static let displayLogs = RelayRefreshScope(
            fetchesCommands: true,
            fetchesSyncData: false,
            fetchesFileRequests: true,
            fetchesItemActions: true,
            fetchesRequestLog: true,
            fetchesSettingActions: true
        )
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
        resolvedCalendarChangeIDs = Self.loadResolvedCalendarChangeIDs()
        mailDashboardItems = Self.loadMailDashboardItems()
        trackedReportNotificationCommandIDs = Self.loadTrackedReportNotificationCommandIDs()
        Self.persistServerToken(storedServerToken)
        Self.clearDeprecatedLocalConnectionInfo()
        rebuildDashboardDerivedState()
        rebuildVisibleCalendarChanges()
    }

    var sharedAppearanceModeValue: String {
        let remoteValue = sharedSettings
            .first { $0.key == Self.sharedAppearanceModeKey }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let remoteValue, KLMSAppearanceMode(rawValue: remoteValue) != nil {
            return remoteValue
        }
        let localValue = UserDefaults.standard.string(forKey: "KLMSAppearanceMode") ?? KLMSAppearanceMode.system.rawValue
        return KLMSAppearanceMode(rawValue: localValue)?.rawValue ?? KLMSAppearanceMode.system.rawValue
    }

    var sharedNoticeUpdateNotesEnabled: Bool {
        guard let setting = sharedSettings.first(where: { $0.key == Self.sharedNoticeUpdateNotesKey }) else {
            return shouldUpdateNoticeNotes
        }
        return setting.boolValue
    }

    private func rebuildDashboardDerivedState() {
        let nextItems = (syncItems + mailDashboardItems).dedupedForServerRelay()
        if dashboardSyncItems != nextItems {
            dashboardSyncItems = nextItems
            dashboardSyncItemsRevision &+= 1
            rebuildDashboardItemLookup()
        }
        rebuildDashboardStatus()
    }

    private func rebuildDashboardItemLookup() {
        var next: [String: [ServerRelaySyncItem]] = [:]
        var nextVisible: [String: [ServerRelaySyncItem]] = [:]
        var nextFilterOptions: [String: CompanionItemFilterOptions] = [:]
        for category in DashboardMetricCategory.allCases {
            let categoryItems = dashboardSyncItems
                .filter { category.includes($0) }
                .companionSorted(by: .recent)
            next[category.rawValue] = categoryItems
            nextVisible[category.rawValue] = categoryItems.filter { !$0.isHidden }
            nextFilterOptions[category.rawValue] = CompanionItemFilterOptions(items: categoryItems, category: category)
        }
        dashboardItemsByCategoryID = next
        visibleDashboardItemsByCategoryID = nextVisible
        dashboardFilterOptionsByCategoryID = nextFilterOptions
        visibleDashboardTaskItems = [
            nextVisible[DashboardMetricCategory.assignments.rawValue] ?? [],
            nextVisible[DashboardMetricCategory.exams.rawValue] ?? [],
            nextVisible[DashboardMetricCategory.helpDesk.rawValue] ?? [],
        ]
        .flatMap { $0 }
        .companionSorted(by: .recent)
    }

    private func rebuildDashboardStatus() {
        var next = status
        next.applyMailDashboardItems(mailDashboardItems, baseItems: syncItems)
        if dashboardStatus != next {
            dashboardStatus = next
        }
    }

    private func rebuildDashboardFileCleanupDetails() {
        let next = dryRunReports.contains { report in
            report.scope == "files"
                && (report.wouldPrune > 0 || report.wouldPruneCourseFiles > 0 || report.wouldPruneArchive > 0 || report.wouldDelete > 0)
        }
        if dashboardHasFileCleanupDetails != next {
            dashboardHasFileCleanupDetails = next
        }
    }

    private func rebuildChangeSummaryItemLookup() {
        var next: [String: [ServerRelaySyncItem]] = [:]
        for kind in RemoteChangeSummaryKind.allCases where !kind.isCalendarChange && kind != .fileCleanup {
            next[kind.rawValue] = syncItems
                .filter { kind.includes($0) }
                .companionSorted(by: .recent)
        }
        if changeSummaryItemsByKindID != next {
            changeSummaryItemsByKindID = next
        }
    }

    private func rebuildChangeSummaryCalendarLookup(using changes: [CalendarChange]? = nil) {
        let source = changes ?? visibleCalendarChangesCache
        var next: [String: [CalendarChange]] = [:]
        for kind in RemoteChangeSummaryKind.allCases where kind.isCalendarChange {
            next[kind.rawValue] = source.filter { kind.includes($0) }
        }
        if changeSummaryCalendarChangesByKindID != next {
            changeSummaryCalendarChangesByKindID = next
        }
    }

    private func rebuildFileCleanupReportCache() {
        let next = dryRunReports.filter { report in
            report.scope == "files"
                && (report.wouldPrune > 0 || report.wouldPruneCourseFiles > 0 || report.wouldPruneArchive > 0 || report.wouldDelete > 0)
        }
        if fileCleanupReportsForDashboard != next {
            fileCleanupReportsForDashboard = next
        }
    }

    func addMailDashboardItem(_ item: ServerRelaySyncItem) {
        let normalizedItem = item.normalizedDashboardItem
        mailDashboardItems = ([normalizedItem] + mailDashboardItems.filter { $0.id != normalizedItem.id })
            .dedupedForServerRelay()
            .prefix(80)
            .map { $0 }
        persistMailDashboardItems()
        connectionSucceeded = true
        connectionMessage = "\(normalizedItem.kind.klmsMailDashboardKindName) 대시보드에 반영했습니다."
    }

    func submitMailDashboardItem(_ item: ServerRelaySyncItem) async {
        let normalizedItem = item.normalizedDashboardItem
        addMailDashboardItem(normalizedItem)
        guard let serverRelayStore else {
            return
        }
        do {
            let payload = try JSONEncoder().encode(normalizedItem)
            let message = String(data: payload, encoding: .utf8) ?? ""
            try await serverRelayStore.createItemAction(ServerRelayItemAction(
                action: .mailDashboardAdd,
                itemID: normalizedItem.id,
                itemKind: normalizedItem.kind,
                itemTitle: normalizedItem.title,
                message: message
            ))
            await refreshRecent(includeSyncData: true, showsActivity: false)
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func removeMailDashboardItem(_ item: ServerRelaySyncItem) {
        mailDashboardItems.removeAll { $0.id == item.id }
        persistMailDashboardItems()
        connectionSucceeded = true
        connectionMessage = "\(item.kind.klmsMailDashboardKindName) 항목을 대시보드에서 제거했습니다."
    }

    func submitRemoveMailDashboardItem(_ item: ServerRelaySyncItem) async {
        removeMailDashboardItem(item)
        guard let serverRelayStore else {
            return
        }
        do {
            let payload = try JSONEncoder().encode(item)
            let message = String(data: payload, encoding: .utf8) ?? ""
            try await serverRelayStore.createItemAction(ServerRelayItemAction(
                action: .mailDashboardRemove,
                itemID: item.id,
                itemKind: item.kind,
                itemTitle: item.title,
                message: message
            ))
            await refreshRecent(includeSyncData: true, showsActivity: false)
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    private static func loadMailDashboardItems() -> [ServerRelaySyncItem] {
        guard let data = UserDefaults.standard.data(forKey: mailDashboardItemsKey),
              let decoded = try? JSONDecoder().decode([ServerRelaySyncItem].self, from: data) else {
            return []
        }
        return decoded
            .filter { $0.id.hasPrefix("mail-") || $0.status.localizedCaseInsensitiveContains("메일") }
            .map(\.normalizedDashboardItem)
            .dedupedForServerRelay()
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

    private static func loadResolvedCalendarChangeIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: resolvedCalendarChangeIDsKey) ?? [])
    }

    private func persistResolvedCalendarChangeIDs() {
        let sortedIDs = resolvedCalendarChangeIDs
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted()
        let cappedIDs = sortedIDs.count > 500 ? Array(sortedIDs.suffix(500)) : sortedIDs
        UserDefaults.standard.set(cappedIDs, forKey: Self.resolvedCalendarChangeIDsKey)
    }

    var isRemoteAvailable: Bool {
        serverRelayStore != nil
    }

    var serverRelayConfigured: Bool {
        serverRelayStore != nil
    }

    var hasClearableRemoteLogs: Bool {
        hasClearableRemoteLogsCache
    }

    var remoteAvailabilityMessage: String {
        if serverRelayStore == nil {
            return "HTTPS 서버 릴레이 URL과 iPhone/iPad/Windows용 클라이언트 토큰을 입력해 주세요."
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
            || activeRemoteLogFileRequest != nil
    }

    var hasActiveServerWork: Bool {
        hasInFlightRequest
            || recentItemActions.contains { $0.status == .pending || $0.status == .running }
            || recentSettingActions.contains { $0.status == .pending || $0.status == .running }
    }

    private func rebuildRemoteLogDerivedState() {
        let now = Date()
        let nextCurrentCommand = recentCommands.first.flatMap { command -> RemoteRunCommand? in
            let displayStatus = command.displayStatus()
            if displayStatus.isInFlight {
                return command
            }
            if now.timeIntervalSince(command.updatedAt) <= Self.terminalLogSummaryDisplayInterval {
                return command
            }
            return nil
        }
        let nextLatestFileRequest = recentFileAccessRequests.first(where: { $0.status.isInFlight })
            ?? recentFileAccessRequests.first {
                now.timeIntervalSince($0.updatedAt) <= Self.terminalLogSummaryDisplayInterval
            }
        let nextActiveCommand = recentCommands.first { $0.displayStatus().isInFlight }
        let nextActiveFileRequest = recentFileAccessRequests.first { $0.status.isInFlight }
        let nextHasClearableCommandLogs = recentCommands.contains { !$0.status.isInFlight }
        let nextHasClearableRequestLogs = !recentRequestLog.isEmpty
        let nextHasClearableFileAccessLogs = recentFileAccessRequests.contains { !$0.status.isInFlight }
        let nextHasClearableRemoteLogs = nextHasClearableCommandLogs
            || nextHasClearableRequestLogs
            || nextHasClearableFileAccessLogs
            || recentItemActions.contains { $0.status != .pending && $0.status != .running }
            || recentSettingActions.contains { $0.status != .pending && $0.status != .running }
            || !sharedRunLogs.isEmpty

        if currentRemoteLogCommand != nextCurrentCommand {
            currentRemoteLogCommand = nextCurrentCommand
        }
        if latestRemoteLogFileRequest != nextLatestFileRequest {
            latestRemoteLogFileRequest = nextLatestFileRequest
        }
        if activeRemoteLogCommand != nextActiveCommand {
            activeRemoteLogCommand = nextActiveCommand
        }
        if activeRemoteLogFileRequest != nextActiveFileRequest {
            activeRemoteLogFileRequest = nextActiveFileRequest
        }
        if hasClearableCommandLogs != nextHasClearableCommandLogs {
            hasClearableCommandLogs = nextHasClearableCommandLogs
        }
        if hasClearableRequestLogs != nextHasClearableRequestLogs {
            hasClearableRequestLogs = nextHasClearableRequestLogs
        }
        if hasClearableFileAccessLogs != nextHasClearableFileAccessLogs {
            hasClearableFileAccessLogs = nextHasClearableFileAccessLogs
        }
        if hasClearableRemoteLogsCache != nextHasClearableRemoteLogs {
            hasClearableRemoteLogsCache = nextHasClearableRemoteLogs
        }
    }

    private func rebuildSharedRunLogStageDurationCache() {
        var nextByID: [String: [KLMSStageDuration]] = [:]
        var nextLatest: [KLMSStageDuration] = []
        var hasLatest = false

        for log in sharedRunLogs where !log.outputTail.isEmpty {
            let durations = KLMSStageDurationParser.parse(from: log.outputTail)
            nextByID[log.id] = durations
            if !hasLatest {
                nextLatest = durations
                hasLatest = true
            }
        }

        if sharedRunLogStageDurationsByID != nextByID {
            sharedRunLogStageDurationsByID = nextByID
        }
        if latestSharedRunLogStageDurations != nextLatest {
            latestSharedRunLogStageDurations = nextLatest
        }
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

    var authStatusDisplayTitle: String {
        guard let message = status.authStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return "인증 완료"
        }
        return Self.isAlreadyLoggedInMessage(message) ? "이미 로그인됨" : "인증 완료"
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
            return "아직 Mac에서 받은 상태가 없습니다."
        }
        if isCancelRequestedForLatestCommand {
            return "Mac에서 \(latestCommand.kind.displayName) 실행을 중단하는 중"
        }
        switch latestDisplayStatus {
        case .pending:
            return "Mac 앱이 \(latestCommand.kind.displayName) 요청을 확인하고 있습니다."
        case .running:
            if let detail = runningPhaseDetail {
                return "Mac에서 \(latestCommand.kind.displayName) · \(detail) 진행 중"
            }
            return "Mac에서 \(latestCommand.kind.displayName) 처리 중"
        case .completed:
            return "\(latestCommand.kind.displayName) 요청이 끝났습니다."
        case .failed:
            return "\(latestCommand.kind.displayName) 요청이 실패했습니다."
        case .cancelled:
            return "\(latestCommand.kind.displayName) 요청을 취소했습니다."
        case .macUnavailable:
            return "Mac 앱이 아직 요청을 확인하지 않았습니다. 켜져 있으면 곧 시작됩니다."
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
            return "KLMS 로그인이 풀린 것 같습니다. Mac에서 Safari 로그인을 마친 뒤 다시 확인해 주세요."
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
                connectionMessage = cancelResponse.message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Mac 앱이 확인하기 전에 요청을 취소했습니다."
                pendingCancelCommandID = nil
                pendingCancelRequestedAt = nil
                cancelFollowUpTask?.cancel()
                cancelFollowUpTask = nil
                userAlert = UserAlert(title: "요청 취소됨", message: connectionMessage)
            }
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
            errorMessage = "서버 연결이 필요합니다. 연결 정보를 먼저 확인해 주세요."
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
            userAlert = UserAlert(title: "설정 요청 완료", message: "Mac 앱이 요청을 확인하면 설정에 반영합니다.")
            await refreshRecent(includeSyncData: true, showsActivity: false)
        } catch {
            guard !isCancellationError(error) else { return }
            let message = userFacingMessage(for: error)
            errorMessage = message
            userAlert = UserAlert(title: "설정 요청 실패", message: message)
        }
    }

    func updateSharedAppearanceMode(_ rawValue: String) async {
        let normalized = KLMSAppearanceMode(rawValue: rawValue)?.rawValue ?? KLMSAppearanceMode.system.rawValue
        await updateSharedSetting(
            key: Self.sharedAppearanceModeKey,
            title: "화면 모드",
            value: normalized,
            valueKind: .choice,
            options: KLMSAppearanceMode.allCases.map(\.rawValue),
            successMessage: "화면 모드를 저장했습니다."
        )
    }

    func updateSharedNoticeNotes(_ enabled: Bool) async {
        await updateSharedSetting(
            key: Self.sharedNoticeUpdateNotesKey,
            title: "공지 메모 업데이트",
            value: enabled ? "1" : "0",
            valueKind: .bool,
            options: [],
            successMessage: enabled ? "공지 메모도 함께 업데이트합니다." : "원격 실행에서 공지 메모 업데이트를 건너뜁니다."
        )
    }

    private func updateSharedSetting(
        key: String,
        title: String,
        value: String,
        valueKind: ServerRelaySettingValueKind,
        options: [String],
        successMessage: String
    ) async {
        let updatedAt = ServerRelaySyncItem.isoTimestamp()
        let setting = ServerRelaySetting(
            key: key,
            title: title,
            value: value,
            valueKind: valueKind,
            options: options,
            editable: true,
            updatedAt: updatedAt
        )
        _ = applySharedSettings([setting])
        guard let serverRelayStore else {
            connectionMessage = "서버 연결 정보가 없어 이 기기에만 적용했습니다."
            connectionSucceeded = false
            return
        }
        isSubmitting = true
        defer {
            isSubmitting = false
        }
        do {
            let saved = try await serverRelayStore.updateSharedSetting(setting)
            _ = applySharedSettings([saved])
            connectionMessage = successMessage
            connectionSucceeded = true
            errorMessage = ""
            await refreshRecent(silentErrors: true, includeSyncData: true, showsActivity: false)
        } catch {
            guard !isCancellationError(error) else { return }
            let message = userFacingMessage(for: error)
            errorMessage = message
            connectionMessage = "설정 저장 실패"
            connectionSucceeded = false
            userAlert = UserAlert(title: "설정 저장 실패", message: message)
        }
    }

    func createItemAction(_ actionKind: ServerRelayItemActionKind, item: ServerRelaySyncItem) async {
        guard let serverRelayStore else {
            errorMessage = "서버 연결이 필요합니다. 연결 정보를 먼저 확인해 주세요."
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
            await refreshRecent(includeSyncData: true, showsActivity: false)
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
            errorMessage = "서버 연결이 필요합니다. 연결 정보를 먼저 확인해 주세요."
            userAlert = UserAlert(title: "요청 실패", message: errorMessage)
            return
        }
        isSubmitting = true
        defer {
            isSubmitting = false
        }
        let actionItemID = serverRelayCalendarChange(change).id
        let candidateIDs = calendarChangeResolvedIDs(for: change)
        do {
            let action = ServerRelayItemAction(
                action: actionKind,
                itemID: actionItemID,
                itemKind: "calendar",
                itemTitle: change.title.nilIfEmpty ?? change.course.nilIfEmpty ?? "캘린더 변경",
                message: try edit?.encodedMessage() ?? ""
            )
            recentItemActions.removeAll { candidateIDs.contains($0.itemID) }
            recentItemActions.insert(action, at: 0)
            try await serverRelayStore.createItemAction(action)
            connectionMessage = "\(actionKind.displayName) 요청을 보냈습니다."
            connectionSucceeded = true
            errorMessage = ""
            userAlert = UserAlert(title: "요청 완료", message: calendarActionRequestMessage(for: actionKind))
            await refreshRecent(includeSyncData: true, showsActivity: false)
        } catch {
            guard !isCancellationError(error) else { return }
            recentItemActions.removeAll { candidateIDs.contains($0.itemID) && $0.action == actionKind && $0.status == .pending }
            let message = userFacingMessage(for: error)
            errorMessage = message
            userAlert = UserAlert(title: "요청 실패", message: message)
        }
    }

    func createManualCalendarAction(title: String, edit: CalendarEventEdit) async {
        guard let serverRelayStore else {
            errorMessage = "서버 연결이 필요합니다. 연결 정보를 먼저 확인해 주세요."
            userAlert = UserAlert(title: "요청 실패", message: errorMessage)
            return
        }
        isSubmitting = true
        defer {
            isSubmitting = false
        }
        do {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let action = ServerRelayItemAction(
                action: .calendarCreate,
                itemID: "mail-calendar-\(UUID().uuidString)",
                itemKind: "calendar",
                itemTitle: title.isEmpty ? "메일 일정" : title,
                message: try edit.encodedMessage()
            )
            recentItemActions.insert(action, at: 0)
            try await serverRelayStore.createItemAction(action)
            connectionMessage = "\(ServerRelayItemActionKind.calendarCreate.displayName) 요청을 보냈습니다."
            connectionSucceeded = true
            errorMessage = ""
            userAlert = UserAlert(title: "요청 완료", message: "Mac 앱이 Apple Calendar에 새 일정을 등록합니다.")
            await refreshRecent(includeSyncData: false, showsActivity: false)
        } catch {
            guard !isCancellationError(error) else { return }
            let message = userFacingMessage(for: error)
            errorMessage = message
            userAlert = UserAlert(title: "요청 실패", message: message)
        }
    }

    private func calendarActionRequestMessage(for actionKind: ServerRelayItemActionKind) -> String {
        switch actionKind {
        case .calendarCreate:
            return "Mac 앱이 Apple Calendar에 새 일정을 등록합니다."
        case .calendarEdit:
            return "Mac 앱이 Apple Calendar 일정을 직접 수정합니다."
        case .calendarApply, .calendarDelete:
            return actionKind == .calendarDelete
                ? "Mac 앱이 Apple Calendar 일정을 직접 삭제합니다."
                : "Mac 앱이 과제/시험 동기화를 다시 실행합니다."
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
            errorMessage = "서버 연결이 필요합니다. 연결 정보를 먼저 확인해 주세요."
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
            connectionMessage = "Mac에 파일 링크를 요청했습니다."
            connectionSucceeded = true
            errorMessage = ""
            userAlert = UserAlert(title: "파일 요청 완료", message: "Mac 앱이 파일 링크를 준비하면 열기 버튼이 표시됩니다.")
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
        latestFileAccessRequestByItemID[item.id]
    }

    func activeItemAction(for item: ServerRelaySyncItem) -> ServerRelayItemAction? {
        activeItemActionByItemID[item.id]
    }

    func activeCalendarAction(for change: CalendarChange) -> ServerRelayItemAction? {
        activeCalendarActionByID[change.id]
    }

    func visibleCalendarChanges() -> [CalendarChange] {
        visibleCalendarChangesCache
    }

    func cachedDashboardItems(for categoryID: String) -> [ServerRelaySyncItem] {
        dashboardItemsByCategoryID[categoryID] ?? []
    }

    func cachedVisibleDashboardItems(for categoryID: String) -> [ServerRelaySyncItem] {
        visibleDashboardItemsByCategoryID[categoryID] ?? []
    }

    fileprivate func cachedDashboardFilterOptions(for categoryID: String) -> CompanionItemFilterOptions? {
        dashboardFilterOptionsByCategoryID[categoryID]
    }

    func cachedVisibleDashboardTaskItems() -> [ServerRelaySyncItem] {
        visibleDashboardTaskItems
    }

    func cachedChangeSummaryItems(for kindID: String) -> [ServerRelaySyncItem] {
        changeSummaryItemsByKindID[kindID] ?? []
    }

    func cachedChangeSummaryCalendarChanges(for kindID: String) -> [CalendarChange] {
        changeSummaryCalendarChangesByKindID[kindID] ?? []
    }

    func cachedFileCleanupReportsForDashboard() -> [DryRunReport] {
        fileCleanupReportsForDashboard
    }

    private func isCalendarChangeResolved(_ change: CalendarChange) -> Bool {
        let ids = calendarChangeResolvedIDs(for: change)
        if ids.contains(where: { resolvedCalendarChangeIDs.contains($0) }) {
            return true
        }
        return recentItemActions.contains { action in
            action.itemKind == "calendar"
                && ids.contains(action.itemID)
                && action.status != .failed
                && action.status != .macUnavailable
                && action.action.resolvesCalendarChange
        }
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

    private func serverRelayCalendarChange(_ change: CalendarChange) -> CalendarChange {
        CalendarChange(
            action: Self.serverRelayPublicText(change.action),
            calendar: Self.serverRelayPublicText(change.calendar),
            bucket: Self.serverRelayPublicText(change.bucket),
            identifier: Self.serverRelayPublicText(change.identifier),
            title: Self.serverRelayPublicText(change.title),
            course: Self.serverRelayPublicText(change.course),
            url: "",
            startAt: Self.serverRelayPublicText(change.startAt),
            dueAt: Self.serverRelayPublicText(change.dueAt),
            location: Self.serverRelayPublicText(change.location),
            changes: change.changes.compactMap { Self.serverRelayPublicText($0).nilIfBlank },
            raw: "",
            parseError: Self.serverRelayPublicText(change.parseError)
        )
    }

    private static func serverRelayPublicText(_ text: String?) -> String {
        let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return ""
        }
        return serverRelayLooksPrivate(value) ? "" : value
    }

    private static func serverRelayLooksPrivate(_ text: String) -> Bool {
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

    private func recordResolvedCalendarChanges(_ actions: [ServerRelayItemAction]) {
        let resolvedIDs = actions.compactMap { action -> String? in
            guard action.itemKind == "calendar",
                  action.status == .completed,
                  action.action.resolvesCalendarChange else {
                return nil
            }
            return action.itemID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        guard !resolvedIDs.isEmpty else { return }
        resolvedCalendarChangeIDs.formUnion(resolvedIDs)
        persistResolvedCalendarChangeIDs()
        rebuildVisibleCalendarChanges()
    }

    private func rebuildFileAccessLookup() {
        var next: [String: ServerRelayFileAccessRequest] = [:]
        for request in recentFileAccessRequests {
            guard !request.itemID.isEmpty else { continue }
            if let existing = next[request.itemID], existing.updatedAt >= request.updatedAt {
                continue
            }
            next[request.itemID] = request
        }
        latestFileAccessRequestByItemID = next
    }

    private func rebuildItemActionLookups() {
        var itemActions: [String: ServerRelayItemAction] = [:]
        var calendarActions: [String: ServerRelayItemAction] = [:]
        for action in recentItemActions {
            if !action.itemID.isEmpty, !action.status.isFailedLike {
                if itemActions[action.itemID]?.updatedAt ?? .distantPast < action.updatedAt {
                    itemActions[action.itemID] = action
                }
            }
            if action.itemKind == "calendar", action.status.isInFlight {
                if calendarActions[action.itemID]?.updatedAt ?? .distantPast < action.updatedAt {
                    calendarActions[action.itemID] = action
                }
            }
        }
        activeItemActionByItemID = itemActions
        activeCalendarActionByID = calendarActions
    }

    private func rebuildVisibleCalendarChanges() {
        let next = (
            calendarChanges
                + mailDashboardItems
                .unmatchedMailDashboardItems(comparedTo: syncItems)
                .compactMap(\.mailCalendarChange)
        )
            .dedupedForCalendarDisplay()
            .filter { change in
                guard change.isUserVisibleCalendarChange else {
                    return false
                }
                return !isCalendarChangeResolved(change)
            }
        if visibleCalendarChangesCache != next {
            visibleCalendarChangesCache = next
        }
        rebuildChangeSummaryCalendarLookup(using: next)
    }

    func refreshRecent(
        silentErrors: Bool = false,
        includeSyncData: Bool? = nil,
        showsActivity: Bool = true,
        scope: RelayRefreshScope = .full
    ) async {
        guard !refreshInProgress else {
            queueRefreshIfNeeded(
                silentErrors: silentErrors,
                includeSyncData: includeSyncData,
                showsActivity: showsActivity,
                scope: scope
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
                let shouldLoadSyncData = includeSyncData == true
                    || (scope.fetchesSyncData && shouldFetchSyncData(includeSyncData: includeSyncData))
                async let responseTask = serverRelayStore.fetchStatusResponse()
                async let commandsTask = Self.fetchRecentCommandsIfNeeded(scope.fetchesCommands, store: serverRelayStore, limit: 8)
                async let syncDataTask = Self.fetchSyncDataIfNeeded(shouldLoadSyncData, store: serverRelayStore)
                async let fileRequestsTask = Self.fetchRecentFileAccessRequestsIfNeeded(scope.fetchesFileRequests, store: serverRelayStore, limit: 20)
                async let itemActionsTask = Self.fetchRecentItemActionsIfNeeded(scope.fetchesItemActions, store: serverRelayStore, limit: 40)
                async let requestLogTask = Self.fetchRecentRequestLogIfNeeded(scope.fetchesRequestLog, store: serverRelayStore, limit: 30)
                async let settingActionsTask = Self.fetchRecentSettingActionsIfNeeded(scope.fetchesSettingActions, store: serverRelayStore, limit: 20)

                let response = try await responseTask
                var didChange = apply(response)
                if let commands = await commandsTask, !commands.isEmpty {
                    let visibleCommands = visibleCommands(commands)
                    if recentCommands != visibleCommands {
                        recentCommands = visibleCommands
                        didChange = true
                    }
                    clearFinishedCancelRequestIfNeeded(commands)
                    handleReportNotificationUpdates(commands)
                }
                if let syncData = await syncDataTask {
                    didChange = apply(syncData) || didChange
                }
                if let fileRequests = await fileRequestsTask {
                    let visibleFileRequests = visibleFileAccessRequests(fileRequests)
                    if recentFileAccessRequests != visibleFileRequests {
                        recentFileAccessRequests = visibleFileRequests
                        didChange = true
                    }
                }
                if let itemActions = await itemActionsTask {
                    recordResolvedCalendarChanges(itemActions)
                    let visibleItemActions = visibleItemActions(itemActions)
                    if recentItemActions != visibleItemActions {
                        recentItemActions = visibleItemActions
                        didChange = true
                    }
                }
                if let requestLog = await requestLogTask {
                    let visibleRequestLog = visibleRequestLog(requestLog)
                    if recentRequestLog != visibleRequestLog {
                        recentRequestLog = visibleRequestLog
                        didChange = true
                    }
                }
                if let settingActions = await settingActionsTask {
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
                    connectionMessage = "새로고침 완료"
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
                    connectionMessage = "새로고침 실패"
                    connectionSucceeded = false
                }
            }
        }
    }

    private static func fetchSyncDataIfNeeded(
        _ shouldFetch: Bool,
        store: ServerRelayCommandStore
    ) async -> ServerRelaySyncData? {
        guard shouldFetch else {
            return nil
        }
        return try? await store.fetchSyncData(limit: 2000)
    }

    private static func fetchRecentCommandsIfNeeded(
        _ shouldFetch: Bool,
        store: ServerRelayCommandStore,
        limit: Int
    ) async -> [RemoteRunCommand]? {
        guard shouldFetch else {
            return nil
        }
        return try? await store.fetchRecent(limit: limit)
    }

    private static func fetchRecentFileAccessRequestsIfNeeded(
        _ shouldFetch: Bool,
        store: ServerRelayCommandStore,
        limit: Int
    ) async -> [ServerRelayFileAccessRequest]? {
        guard shouldFetch else {
            return nil
        }
        return try? await store.fetchRecentFileAccessRequests(limit: limit)
    }

    private static func fetchRecentItemActionsIfNeeded(
        _ shouldFetch: Bool,
        store: ServerRelayCommandStore,
        limit: Int
    ) async -> [ServerRelayItemAction]? {
        guard shouldFetch else {
            return nil
        }
        return try? await store.fetchRecentItemActions(limit: limit)
    }

    private static func fetchRecentRequestLogIfNeeded(
        _ shouldFetch: Bool,
        store: ServerRelayCommandStore,
        limit: Int
    ) async -> [ServerRelayRequestLogEntry]? {
        guard shouldFetch else {
            return nil
        }
        return try? await store.fetchRecentRequestLog(limit: limit)
    }

    private static func fetchRecentSettingActionsIfNeeded(
        _ shouldFetch: Bool,
        store: ServerRelayCommandStore,
        limit: Int
    ) async -> [ServerRelaySettingAction]? {
        guard shouldFetch else {
            return nil
        }
        return try? await store.fetchRecentSettingActions(limit: limit)
    }

    private func queueRefreshIfNeeded(
        silentErrors: Bool,
        includeSyncData: Bool?,
        showsActivity: Bool,
        scope: RelayRefreshScope
    ) {
        guard showsActivity || includeSyncData == true || !silentErrors || scope.hasClientFetchWork else {
            return
        }
        if pendingRefreshRequest == nil {
            pendingRefreshRequest = PendingRefreshRequest(
                silentErrors: silentErrors,
                includeSyncData: includeSyncData,
                showsActivity: showsActivity,
                scope: scope
            )
        } else {
            pendingRefreshRequest?.merge(
                silentErrors: silentErrors,
                includeSyncData: includeSyncData,
                showsActivity: showsActivity,
                scope: scope
            )
        }
        if showsActivity {
            isRefreshing = true
            connectionMessage = "새로고침 중입니다. 끝나는 대로 바로 반영합니다."
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
                showsActivity: request.showsActivity,
                scope: request.scope
            )
        }
    }

    func clearRemoteLogs(scope: ServerRelayLogClearScope = .all) async {
        if scope == .fileAccess, recentFileAccessRequests.contains(where: { $0.status.isInFlight }) {
            let message = "파일 요청이 끝난 뒤 파일 요청 기록을 지울 수 있습니다."
            errorMessage = message
            userAlert = UserAlert(title: "로그 지우기 보류", message: message)
            return
        }
        var remoteClearError: String?
        if let serverRelayStore {
            do {
                _ = try await serverRelayStore.clearDisplayLogs(scope: scope)
                if scope == .all {
                    _ = try await serverRelayStore.clearSharedRunLogs()
                    sharedRunLogs = []
                    sharedRunLogsSignature = nil
                    syncDataNeedsRefresh = true
                }
            } catch {
                remoteClearError = "서버 표시 기록 지우기 실패: \(error.localizedDescription)"
            }
        }
        applyLogClear(scope: scope)
        connectionMessage = remoteClearError ?? (scope == .all ? "화면 기록과 공유 실행 로그를 지웠습니다." : "화면 기록을 지웠습니다.")
        connectionSucceeded = true
        errorMessage = remoteClearError ?? ""
        userAlert = UserAlert(
            title: remoteClearError == nil ? "\(scope.clearTitle) 완료" : "일부 로그 지우기 실패",
            message: remoteClearError ?? (scope == .all ? "실행, 서버 요청, 파일 요청, 항목 변경, 설정 변경, 공유 실행 로그를 정리했습니다. 진행 중인 요청은 유지됩니다." : "이 기록은 다른 기기 화면에서도 함께 숨겨집니다.")
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

    func startServerRelayRealtime() async {
        configureServerRelayEventStream()
        await refreshRecent(silentErrors: true, includeSyncData: true, showsActivity: false)
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
                    let scope = Self.relayRefreshScope(for: message)
                    await refreshRecent(
                        silentErrors: true,
                        includeSyncData: scope.fetchesSyncData ? true : false,
                        showsActivity: false,
                        scope: scope
                    )
                }
            } catch {
                if !Task.isCancelled, serverRelayEventStreamKey == key {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    private static func relayRefreshScope(for message: URLSessionWebSocketTask.Message) -> RelayRefreshScope {
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
            return .full
        }
        let reason = event.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if reason == "state" || reason == "updated" {
            return .state
        }
        if reason == "cancel:requested" {
            return .state
        }
        if reason.hasPrefix("commands:") {
            return reason == "commands:pending" ? .commandRequest : .state
        }
        if reason.hasPrefix("item-actions:") {
            return .itemActions
        }
        if reason.hasPrefix("setting-actions:") {
            return .settingActions
        }
        if reason == "sync-data" || reason.hasPrefix("sync-data:") {
            return .syncData
        }
        if reason == "shared-settings" {
            return .settings
        }
        if reason.hasPrefix("file-access:") {
            return .fileAccess
        }
        if reason.hasPrefix("logs-display:") || reason.hasPrefix("logs:") {
            if reason.contains("fileAccess") || reason.contains("file-access") {
                return .fileAccess
            }
            if reason.contains("requestLog") || reason.contains("request-log") {
                return .requestLog
            }
            if reason.contains("command") {
                return .state
            }
            return .displayLogs
        }
        return .full
    }

    @discardableResult
    private func apply(_ response: LocalRemoteResponse) -> Bool {
        var didChange = false
        if status != response.status {
            status = response.status
            didChange = true
        }
        if shouldNotifyAuthSuccess(for: response.status),
           let authStatusMessage = response.status.authStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines) {
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
        return !Self.isAlreadyLoggedInMessage(message)
    }

    private static func isAlreadyLoggedInMessage(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("이미 로그인") || normalized.contains("already")
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
        didChange = applySharedSettings(syncData.sharedSettings) || didChange
        let nextSharedRunLogsSignature = Self.signature(for: syncData.runLogs)
        if sharedRunLogsSignature != nextSharedRunLogsSignature {
            sharedRunLogs = syncData.runLogs
            sharedRunLogsSignature = nextSharedRunLogsSignature
            didChange = true
        }
        let nextVerifySummarySignature = Self.signature(for: syncData.verifySummary)
        if verifySummarySignature != nextVerifySummarySignature {
            verifySummary = syncData.verifySummary
            verifySummarySignature = nextVerifySummarySignature
            didChange = true
        }
        lastSyncDataRefreshAt = Date()
        syncDataNeedsRefresh = false
        return didChange
    }

    @discardableResult
    private func applySharedSettings(_ incomingSettings: [ServerRelaySetting]) -> Bool {
        guard !incomingSettings.isEmpty else {
            return false
        }
        var mergedByKey = Dictionary(uniqueKeysWithValues: sharedSettings.map { ($0.key, $0) })
        for setting in incomingSettings {
            mergedByKey[setting.key] = setting
        }
        let next = mergedByKey.values.sorted { $0.key < $1.key }
        let nextSignature = Self.signature(for: next)
        guard sharedSettingsSignature != nextSignature else {
            return false
        }
        sharedSettings = next
        sharedSettingsSignature = nextSignature
        for setting in next {
            applySharedSettingLocally(setting)
        }
        return true
    }

    private func applySharedSettingLocally(_ setting: ServerRelaySetting) {
        switch setting.key {
        case Self.sharedAppearanceModeKey:
            let rawValue = KLMSAppearanceMode(rawValue: setting.value)?.rawValue ?? KLMSAppearanceMode.system.rawValue
            UserDefaults.standard.set(rawValue, forKey: "KLMSAppearanceMode")
        case Self.sharedNoticeUpdateNotesKey:
            shouldUpdateNoticeNotes = setting.boolValue
        default:
            break
        }
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
        }
        return hasher.finalize()
    }

    private static func signature(for summary: ServerRelayVerifySummary?) -> Int {
        var hasher = Hasher()
        hasher.combine(summary?.status ?? "")
        hasher.combine(summary?.updatedAt ?? "")
        hasher.combine(summary?.checks.count ?? 0)
        for check in summary?.checks ?? [] {
            hasher.combine(check.name)
            hasher.combine(check.status)
            hasher.combine(check.detail)
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
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self,
                  !Task.isCancelled,
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
                body = "Mac 앱에서 요약 갱신이 실패했습니다. 종료 코드 \(lastExitCode). 로그 탭에서 오류를 확인해 주세요."
            } else {
                body = "Mac 앱에서 요약 갱신이 실패했습니다. 로그 탭에서 오류를 확인해 주세요."
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

private enum CompanionAppSection: String, CaseIterable, Identifiable, Hashable {
    case status
    case files
    case notices
    case tasks
    case calendar
    case history
    case settings

    var id: String { rawValue }

    static var compactTabs: [CompanionAppSection] {
        [.status, .history, .settings]
    }

    static var workstationSections: [CompanionAppSection] {
        [.status, .files, .notices, .tasks, .calendar, .history, .settings]
    }

    var title: String {
        switch self {
        case .status:
            return "대시보드"
        case .files:
            return "파일"
        case .notices:
            return "공지"
        case .tasks:
            return "과제/시험"
        case .calendar:
            return "캘린더"
        case .history:
            return "로그"
        case .settings:
            return "설정"
        }
    }

    var compactTitle: String {
        switch self {
        case .status:
            return "상태"
        case .history:
            return "로그"
        case .settings:
            return "설정"
        case .files:
            return "파일"
        case .notices:
            return "공지"
        case .tasks:
            return "과제"
        case .calendar:
            return "일정"
        }
    }

    var systemImage: String {
        switch self {
        case .status:
            return "gauge"
        case .files:
            return "folder"
        case .notices:
            return "note.text"
        case .tasks:
            return "checklist"
        case .calendar:
            return "calendar"
        case .history:
            return "clock.arrow.circlepath"
        case .settings:
            return "gearshape"
        }
    }
}

private enum CompanionWorkstationMetrics {
    static let sidebarWidth: CGFloat = 224
    static let horizontalPadding: CGFloat = 22
    static let topPadding: CGFloat = 14
    static let bottomPadding: CGFloat = 24
    static let columnSpacing: CGFloat = 18

    static let commandColumnMinWidth: CGFloat = 312
    static let commandColumnIdealWidth: CGFloat = 352
    static let commandColumnMaxWidth: CGFloat = 392

    static let metricColumnMinWidth: CGFloat = 332
    static let metricColumnIdealWidth: CGFloat = 448
    static let metricColumnMaxWidth: CGFloat = 520

    static let detailColumnMinWidth: CGFloat = 380
    static let detailColumnIdealWidth: CGFloat = 700

    static let listColumnMinWidth: CGFloat = 380
    static let listColumnIdealWidth: CGFloat = 560
    static let listColumnMaxWidth: CGFloat = 700
}

struct CompanionRootView: View {
    @StateObject private var model = CompanionModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedSection: CompanionAppSection? = .status

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                CompanionSplitRootView(model: model, selectedSection: $selectedSection)
            } else {
                CompanionTabRootView(model: model)
            }
        }
        .background(Color.klmsScreenBackground.ignoresSafeArea())
        .tint(.klmsCommandAccent)
        .task {
            await model.startServerRelayRealtime()
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

private struct CompanionTabRootView: View {
    let model: CompanionModel
    @State private var selectedSection: CompanionAppSection = .status

    var body: some View {
        VStack(spacing: 0) {
            CompanionDeferredSectionContent(section: selectedSection, model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            CompanionCompactTabBar(selectedSection: $selectedSection)
                .padding(.horizontal, 16)
                .padding(.top, 7)
                .padding(.bottom, 10)
                .background(Color.klmsScreenBackground)
        }
        .background(Color.klmsScreenBackground.ignoresSafeArea())
    }
}

private struct CompanionCompactTabBar: View {
    @Binding var selectedSection: CompanionAppSection

    var body: some View {
        VStack(spacing: 6) {
            ForEach(compactRows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row) { section in
                        compactTabButton(section)
                    }
                }
            }
        }
        .padding(6)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private var compactRows: [[CompanionAppSection]] {
        [
            CompanionAppSection.compactTabs,
        ]
    }

    private func compactTabButton(_ section: CompanionAppSection) -> some View {
        Button {
            guard selectedSection != section else { return }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                selectedSection = section
            }
        } label: {
            let isSelected = selectedSection == section
            VStack(spacing: 4) {
                Image(systemName: section.systemImage)
                    .font(.caption.weight(.bold))
                Text(section.compactTitle)
                    .font(.system(size: 11, weight: isSelected ? .bold : .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }
            .foregroundStyle(isSelected ? Color.klmsSelectedForeground : Color.klmsPrimaryText)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                isSelected
                    ? Color.klmsSelectedBackground
                    : Color.klmsSubtleCardBackground.opacity(0.54),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.klmsSelectedBorder : Color.klmsBorder.opacity(0.38), lineWidth: isSelected ? 1.35 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(KLMSCardButtonStyle())
        .accessibilityLabel(section.compactTitle)
        .accessibilityValue(selectedSection == section ? "선택됨" : "")
    }
}

private struct CompanionSplitRootView: View {
    let model: CompanionModel
    @Binding var selectedSection: CompanionAppSection?

    var body: some View {
        HStack(spacing: 0) {
            WorkstationSidebar(model: model, selectedSection: $selectedSection)
                .frame(width: CompanionWorkstationMetrics.sidebarWidth)
            Rectangle()
                .fill(Color.klmsBorder)
                .frame(width: 1)
            CompanionDeferredSectionContent(section: currentSection, model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.klmsScreenBackground.ignoresSafeArea())
    }

    private var currentSection: CompanionAppSection {
        selectedSection ?? .status
    }
}

private struct WorkstationSidebar: View {
    @ObservedObject var model: CompanionModel
    @Binding var selectedSection: CompanionAppSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("KLMS Sync")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.klmsPrimaryText)
                Text("작업 공간")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsSecondaryText)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(CompanionAppSection.workstationSections) { section in
                    CompanionSidebarButton(
                        section: section,
                        isSelected: selectedSection == section,
                        showsIcon: true,
                        showsArrow: true,
                        isCompact: false,
                        badgeText: badgeText(for: section)
                    ) {
                        guard selectedSection != section else { return }
                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) {
                            selectedSection = section
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.klmsCardBackground.opacity(0.72))
    }

    private func badgeText(for section: CompanionAppSection) -> String? {
        let status = model.dashboardStatus
        let value: Int
        switch section {
        case .files:
            value = status.fileTotal
        case .notices:
            value = status.notices
        case .tasks:
            value = status.assignments + status.exams
        case .calendar:
            value = status.calendarChangeTotal
        case .status, .history, .settings:
            return nil
        }
        return value > 0 ? "\(value)" : nil
    }
}

private struct CompanionSidebarButton: View {
    var section: CompanionAppSection
    var isSelected: Bool
    var showsIcon = true
    var showsArrow = true
    var isCompact = false
    var badgeText: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: isCompact ? 7 : 10) {
                if showsIcon {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                isSelected
                                    ? Color.klmsSelectedBorder.opacity(0.24)
                                    : Color.klmsSubtleCardBackground.opacity(0.72)
                            )
                        Image(systemName: section.systemImage)
                            .font((isCompact ? Font.subheadline : Font.body).weight(isSelected ? .bold : .semibold))
                            .foregroundStyle(isSelected ? Color.klmsSelectedForeground : Color.klmsSecondaryText.opacity(0.84))
                    }
                    .frame(width: isCompact ? 28 : 30, height: isCompact ? 28 : 30)
                }
                Text(section.title)
                    .font(.system(size: isCompact ? 12 : 13, weight: isSelected ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? Color.klmsSelectedForeground : Color.klmsPrimaryText)
                Spacer(minLength: 0)
                if let badgeText {
                    Text(badgeText)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(isSelected ? Color.klmsSelectedForeground : Color.klmsSecondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(isSelected ? Color.klmsSelectedForeground.opacity(0.14) : Color.klmsSubtleCardBackground, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(isSelected ? Color.klmsSelectedBorder.opacity(0.36) : Color.klmsBorder.opacity(0.72), lineWidth: 1)
                        )
                        .accessibilityHidden(true)
                }
                if showsArrow {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.klmsSelectedBorder : Color.klmsSecondaryText.opacity(0.52))
                }
            }
            .padding(.leading, isCompact ? 7 : 8)
            .padding(.trailing, isCompact ? 8 : 9)
            .padding(.vertical, isCompact ? 8 : 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                isSelected
                    ? Color.klmsSelectedBackground
                    : Color.klmsSubtleCardBackground.opacity(0.30),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isSelected ? Color.klmsSelectedBorder : Color.clear)
                    .frame(width: isSelected ? 4 : 0)
                    .padding(.vertical, 9)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.klmsSelectedBorder : Color.klmsBorder.opacity(0.40), lineWidth: isSelected ? 1.35 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(KLMSCardButtonStyle())
        .accessibilityLabel(section.title)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        [isSelected ? "선택됨" : nil, badgeText.map { "\($0)개" }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

private struct CompanionDeferredSectionContent: View {
    var section: CompanionAppSection
    let model: CompanionModel
    @State private var renderedSection: CompanionAppSection
    @State private var renderTask: Task<Void, Never>?
    private let sectionRenderDelayNanoseconds: UInt64 = 35_000_000

    init(section: CompanionAppSection, model: CompanionModel) {
        self.section = section
        self.model = model
        _renderedSection = State(initialValue: section)
    }

    var body: some View {
        CompanionSectionContent(section: renderedSection, model: model)
            .onChange(of: section) { _, nextSection in
                scheduleRenderedSection(nextSection)
            }
            .onDisappear {
                renderTask?.cancel()
            }
    }

    private func scheduleRenderedSection(_ nextSection: CompanionAppSection) {
        renderTask?.cancel()
        renderTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: sectionRenderDelayNanoseconds)
            guard !Task.isCancelled else { return }
            companionPerformWithoutAnimation {
                renderedSection = nextSection
            }
        }
    }
}

private struct CompanionSectionContent: View {
    var section: CompanionAppSection
    let model: CompanionModel

    var body: some View {
        Group {
            switch section {
            case .status:
                CompanionStatusScreen(model: model)
            case .files:
                CompanionDashboardCategoryScreen(title: "파일", category: .files, model: model)
            case .notices:
                CompanionDashboardCategoryScreen(title: "공지", category: .notices, model: model)
            case .tasks:
                CompanionTasksScreen(model: model)
            case .calendar:
                CompanionDashboardCategoryScreen(title: "캘린더", category: .calendar, model: model)
            case .history:
                CompanionHistoryScreen(model: model)
            case .settings:
                CompanionSettingsScreen(model: model)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private struct CompanionStatusScreen: View {
    let model: CompanionModel
    @State private var selectedDashboardPreview: DashboardMetricCategory?
    @State private var selectedChangeSummary: RemoteChangeSummaryKind?
    @State private var displayedDashboardPreview: DashboardMetricCategory?
    @State private var displayedChangeSummary: RemoteChangeSummaryKind?
    @State private var deferredStatusDetailTask: Task<Void, Never>?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        CompanionScreenContainer(
            title: horizontalSizeClass == .regular ? "대시보드" : "상태",
            model: model
        ) {
            if horizontalSizeClass == .regular {
                statusRegularWorkspace
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    statusSummaryColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .onDisappear {
            deferredStatusDetailTask?.cancel()
        }
    }

    private var statusRegularWorkspace: some View {
        HStack(alignment: .top, spacing: CompanionWorkstationMetrics.columnSpacing) {
            statusMainColumn
                .frame(
                    minWidth: CompanionWorkstationMetrics.listColumnMinWidth,
                    idealWidth: CompanionWorkstationMetrics.listColumnIdealWidth,
                    maxWidth: CompanionWorkstationMetrics.listColumnMaxWidth,
                    alignment: .topLeading
                )
            statusDetailColumn
                .frame(
                    minWidth: CompanionWorkstationMetrics.detailColumnMinWidth,
                    idealWidth: CompanionWorkstationMetrics.detailColumnIdealWidth,
                    maxWidth: .infinity,
                    alignment: .topLeading
                )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var statusMainColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusCommandColumn
            statusMetricColumn
        }
    }

    private var statusSummaryColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            RemoteDashboardSyncCard(model: model, compact: horizontalSizeClass != .regular)
            RemoteDashboardMetricOverview(
                model: model,
                status: model.dashboardStatus,
                hasFileCleanupDetails: model.dashboardHasFileCleanupDetails,
                selectedCategory: $selectedDashboardPreview,
                effectiveSelectedCategory: effectiveDashboardSelection,
                onCategoryTap: { category in
                    selectDashboardCategory(category)
                },
                selectedChangeSummary: selectedChangeSummary,
                showsCompactChangeDetail: false,
                onChangeSummaryTap: { kind in
                    selectChangeSummary(kind)
                }
            )
            CompanionItemListPrewarmView(model: model, categories: dashboardPrewarmCategories)
            compactDashboardDetail
        }
    }

    @ViewBuilder
    private var compactDashboardDetail: some View {
        if horizontalSizeClass != .regular {
            if let kind = displayedChangeSummary {
                RemoteChangeSummaryDetailPanel(
                    kind: kind,
                    status: model.dashboardStatus,
                    changedItems: model.cachedChangeSummaryItems(for: kind.rawValue),
                    changedCalendarItems: model.cachedChangeSummaryCalendarChanges(for: kind.rawValue),
                    fileCleanupReports: model.cachedFileCleanupReportsForDashboard(),
                    model: model
                )
                .id(kind)
            } else if let category = displayedDashboardPreview {
                DashboardCategoryInlineDetailPanel(category: category, model: model)
                    .id(category)
            } else if selectedDashboardPreview != nil || selectedChangeSummary != nil {
                CompanionEmptyDetailPanel(
                    title: "상세 준비 중",
                    detail: "선택한 항목을 불러오고 있습니다.",
                    systemImage: "sidebar.right"
                )
            }
        }
    }

    private var statusCommandColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            RemoteDashboardSyncCard(model: model, compact: false)
            WorkstationDashboardRunSummaryCard(status: model.dashboardStatus)
        }
    }

    private var statusMetricColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            RemoteDashboardMetricOverview(
                model: model,
                status: model.dashboardStatus,
                hasFileCleanupDetails: model.dashboardHasFileCleanupDetails,
                selectedCategory: $selectedDashboardPreview,
                effectiveSelectedCategory: effectiveDashboardSelection,
                onCategoryTap: { category in
                    selectDashboardCategory(category)
                },
                selectedChangeSummary: selectedChangeSummary,
                showsCompactChangeDetail: false,
                onChangeSummaryTap: { kind in
                    selectChangeSummary(kind)
                }
            )
            CompanionItemListPrewarmView(model: model, categories: dashboardPrewarmCategories)
        }
    }

    @ViewBuilder
    private var statusDetailColumn: some View {
        if let kind = displayedChangeSummary {
            RemoteChangeSummaryDetailPanel(
                kind: kind,
                status: model.dashboardStatus,
                changedItems: model.cachedChangeSummaryItems(for: kind.rawValue),
                changedCalendarItems: model.cachedChangeSummaryCalendarChanges(for: kind.rawValue),
                fileCleanupReports: model.cachedFileCleanupReportsForDashboard(),
                model: model
            )
                .id(kind)
        } else if let category = displayedDashboardPreview {
            DashboardCategoryInlineDetailPanel(category: category, model: model)
                .id(category)
        } else if selectedDashboardPreview != nil || selectedChangeSummary != nil {
            CompanionEmptyDetailPanel(
                title: "상세 준비 중",
                detail: "선택한 항목을 불러오고 있습니다.",
                systemImage: "sidebar.right"
            )
        } else if horizontalSizeClass == .regular {
            CompanionEmptyDetailPanel(
                title: "항목 선택",
                detail: "왼쪽 대시보드에서 파일, 과제, 공지, 시험, 캘린더 중 하나를 선택하면 상세와 처리 버튼이 여기에 표시됩니다.",
                systemImage: "rectangle.stack.badge.cursorarrow"
            )
        }
    }

    private func selectDashboardCategory(_ category: DashboardMetricCategory) {
        companionPerformWithoutAnimation {
            selectedChangeSummary = nil
            selectedDashboardPreview = category
            displayedChangeSummary = nil
            displayedDashboardPreview = nil
        }
        deferStatusDetailUpdate(category: category, changeSummary: nil)
    }

    private func selectChangeSummary(_ kind: RemoteChangeSummaryKind) {
        companionPerformWithoutAnimation {
            selectedDashboardPreview = nil
            selectedChangeSummary = kind
            displayedDashboardPreview = nil
            displayedChangeSummary = nil
        }
        deferStatusDetailUpdate(category: nil, changeSummary: kind)
    }

    private func deferStatusDetailUpdate(category: DashboardMetricCategory?, changeSummary: RemoteChangeSummaryKind?) {
        deferredStatusDetailTask?.cancel()
        deferredStatusDetailTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: CompanionLargeList.detailRenderDelayNanoseconds)
            guard !Task.isCancelled,
                  selectedDashboardPreview == category,
                  selectedChangeSummary == changeSummary else {
                return
            }
            companionPerformWithoutAnimation {
                displayedDashboardPreview = category
                displayedChangeSummary = changeSummary
            }
        }
    }

    private var effectiveDashboardSelection: DashboardMetricCategory? {
        if selectedChangeSummary != nil {
            return selectedDashboardPreview
        }
        if let selectedDashboardPreview {
            return selectedDashboardPreview
        }
        return nil
    }

    private var dashboardPrewarmCategories: [DashboardMetricCategory] {
        [.files, .assignments, .notices, .exams, .helpDesk]
            .filter { $0.value(from: model.dashboardStatus) > 0 }
    }

}
private struct CompanionDashboardCategoryScreen: View {
    var title: String
    var category: DashboardMetricCategory
    let model: CompanionModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        CompanionScreenContainer(title: title, model: model) {
            if horizontalSizeClass == .regular && category == .calendar {
                WorkstationCalendarWorkspace(model: model)
            } else if horizontalSizeClass == .regular && category.supportsWorkstationSelectionWorkspace {
                WorkstationDashboardCategoryWorkspace(category: category, model: model)
            } else {
                DashboardCategoryInlineDetailPanel(category: category, model: model)
            }
        }
    }
}

private struct CompanionTasksScreen: View {
    let model: CompanionModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        CompanionScreenContainer(title: "과제/시험", model: model) {
            if horizontalSizeClass == .regular {
                WorkstationTasksWorkspace(model: model)
            } else {
                DashboardCategoryInlineDetailPanel(category: .assignments, model: model)
                DashboardCategoryInlineDetailPanel(category: .exams, model: model)
                if DashboardMetricCategory.helpDesk.value(from: model.dashboardStatus) > 0 {
                    DashboardCategoryInlineDetailPanel(category: .helpDesk, model: model)
                }
            }
        }
    }
}

private struct CompanionSettingsScreen: View {
    let model: CompanionModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        CompanionScreenContainer(title: "설정", model: model) {
            if horizontalSizeClass == .regular {
                settingsRegularWorkspace
            } else {
                settingsPrimaryColumn
                settingsSupportColumn
            }
        }
    }

    private var settingsRegularWorkspace: some View {
        HStack(alignment: .top, spacing: CompanionWorkstationMetrics.columnSpacing) {
            settingsPrimaryColumn
                .frame(
                    minWidth: CompanionWorkstationMetrics.listColumnMinWidth,
                    idealWidth: CompanionWorkstationMetrics.listColumnIdealWidth,
                    maxWidth: CompanionWorkstationMetrics.listColumnMaxWidth,
                    alignment: .topLeading
                )
            settingsSupportColumn
                .frame(
                    minWidth: CompanionWorkstationMetrics.detailColumnMinWidth,
                    idealWidth: CompanionWorkstationMetrics.detailColumnIdealWidth,
                    maxWidth: .infinity,
                    alignment: .topLeading
                )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var settingsPrimaryColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            CompanionImmediateSettingsPanel(model: model)
            RemoteSettingsPanel(model: model, usesWideGrid: horizontalSizeClass == .regular)
        }
    }

    private var settingsSupportColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            ServerRelayConnectionPanel(model: model)
            RemoteDiagnosticPanel(model: model)
            RemotePrivacyNote()
        }
    }
}

private struct CompanionImmediateSettingsPanel: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.klmsCommandAccent)
                    .frame(width: 32, height: 32)
                    .background(Color.klmsCommandAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("바로 반영되는 설정")
                        .font(.headline)
                    Text("저장하면 모든 기기에 바로 적용됩니다.")
                        .font(.caption)
                        .foregroundStyle(Color.klmsSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                CompanionImmediateSettingRow(
                    title: "화면 모드",
                    statusText: KLMSAppearanceMode(rawValue: model.sharedAppearanceModeValue)?.title ?? "시스템",
                    detail: "기기 설정을 따르거나, KLMS Sync에서만 라이트/다크 모드를 고정합니다."
                ) {
                    Picker("화면 모드", selection: Binding(
                        get: { model.sharedAppearanceModeValue },
                        set: { newValue in
                            Task {
                                await model.updateSharedAppearanceMode(newValue)
                            }
                        }
                    )) {
                        ForEach(KLMSAppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                CompanionImmediateSettingRow(
                    title: "공지 메모",
                    statusText: model.sharedNoticeUpdateNotesEnabled ? "켜짐" : "꺼짐",
                    detail: "끄면 원격 동기화에서 Notes 공지 메모만 건너뜁니다."
                ) {
                    Button {
                        let enabled = !model.sharedNoticeUpdateNotesEnabled
                        Task {
                            await model.updateSharedNoticeNotes(enabled)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Label(
                                "원격 실행에서 공지 메모도 갱신",
                                systemImage: model.sharedNoticeUpdateNotesEnabled ? "checkmark.circle.fill" : "circle"
                            )
                            Spacer(minLength: 8)
                            Text(model.sharedNoticeUpdateNotesEnabled ? "켜짐" : "꺼짐")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.klmsSecondaryText)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(KLMSActionButtonStyle(tone: model.sharedNoticeUpdateNotesEnabled ? .success : .soft))
                    .disabled(model.isSubmitting)
                    .accessibilityLabel("공지 메모 갱신")
                    .accessibilityValue(model.sharedNoticeUpdateNotesEnabled ? "켜짐" : "꺼짐")
                    .accessibilityHint("원격 동기화에서 Notes 공지 메모를 쓸지 정합니다.")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.klmsBorder, lineWidth: 1)
        )
    }
}

private struct CompanionImmediateSettingRow<Content: View>: View {
    var title: String
    var statusText: String
    var detail: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.klmsPrimaryText)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Color.klmsSecondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.klmsSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.klmsCardBackground, in: Capsule())
            }

            CompanionSettingsControlContainer {
                content()
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsSubtleCardBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.klmsBorder.opacity(0.82), lineWidth: 1)
        }
    }
}

private struct CompanionSettingsControlContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsCardBackground.opacity(0.78), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.klmsBorder.opacity(0.64), lineWidth: 1)
        }
    }
}

private struct CompanionSettingsSubsectionCard<Content: View>: View {
    var title: String
    var detail: String
    var systemImage: String
    var statusText: String?
    var statusTint: Color = .klmsSecondaryText
    var collapsible = false
    @State private var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        detail: String,
        systemImage: String,
        statusText: String? = nil,
        statusTint: Color = .klmsSecondaryText,
        collapsible: Bool = false,
        defaultExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.statusText = statusText
        self.statusTint = statusTint
        self.collapsible = collapsible
        _isExpanded = State(initialValue: defaultExpanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if collapsible {
                Button {
                    companionPerformWithoutAnimation {
                        isExpanded.toggle()
                    }
                } label: {
                    subsectionHeader
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(KLMSCardButtonStyle(cornerRadius: 10))
                .accessibilityHint(isExpanded ? "\(title) 접기" : "\(title) 펼치기")
            } else {
                subsectionHeader
            }

            if !collapsible || isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (!collapsible || isExpanded) ? Color.klmsSubtleCardBackground.opacity(0.86) : Color.klmsSubtleCardBackground.opacity(0.58),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke((!collapsible || isExpanded) ? Color.klmsSelectedBorder.opacity(0.48) : Color.klmsBorder.opacity(0.86), lineWidth: 1)
        }
    }

    private var subsectionHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.klmsCommandAccent)
                .frame(width: 28, height: 28)
                .background(Color.klmsCommandAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.klmsPrimaryText)
                CompanionSettingHelpText(detail)
            }
            Spacer(minLength: 8)
            if let statusText {
                Text(statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusTint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.klmsCardBackground, in: Capsule())
            }
            if collapsible {
                CompanionExpansionBadge(isExpanded: isExpanded, compact: true)
            }
        }
    }
}

private struct CompanionHistoryScreen: View {
    let model: CompanionModel
    @State private var selectedLogSummaryKind: RemoteLogSummaryKind? = .status
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        CompanionScreenContainer(title: "로그", model: model) {
            if horizontalSizeClass == .regular {
                historyRegularWorkspace
            } else {
                historySummaryColumn
                historyStageColumn
                historyRequestColumn
            }
        }
    }

    private var historyRegularWorkspace: some View {
        HStack(alignment: .top, spacing: CompanionWorkstationMetrics.columnSpacing) {
            historySummaryColumn
                .frame(
                    minWidth: CompanionWorkstationMetrics.commandColumnMinWidth,
                    idealWidth: CompanionWorkstationMetrics.commandColumnIdealWidth,
                    maxWidth: CompanionWorkstationMetrics.commandColumnMaxWidth,
                    alignment: .topLeading
                )
            historyDetailColumn
                .frame(
                    minWidth: CompanionWorkstationMetrics.metricColumnMinWidth,
                    idealWidth: CompanionWorkstationMetrics.metricColumnIdealWidth,
                    maxWidth: CompanionWorkstationMetrics.metricColumnMaxWidth,
                    alignment: .topLeading
                )
            historyRequestColumn
                .frame(
                    minWidth: CompanionWorkstationMetrics.detailColumnMinWidth,
                    idealWidth: CompanionWorkstationMetrics.detailColumnIdealWidth,
                    maxWidth: .infinity,
                    alignment: .topLeading
                )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var historySummaryColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            RemoteLogSummaryPanel(
                model: model,
                compact: false,
                showsInlineDetail: horizontalSizeClass != .regular,
                selectedKind: horizontalSizeClass == .regular ? $selectedLogSummaryKind : nil
            )
        }
    }

    private var historyStageColumn: some View {
        SharedRunLogsView(
            logs: model.sharedRunLogs,
            stageDurationsByID: model.sharedRunLogStageDurationsByID,
            clearAction: {
                Task {
                    await model.clearSharedRunLogs()
                }
            },
            clearDisabled: !model.serverRelayConfigured || model.isSubmitting || model.sharedRunLogs.isEmpty
        )
    }

    @ViewBuilder
    private var historyDetailColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            selectedHistoryDetailPanel
            historyStageColumn
        }
    }

    @ViewBuilder
    private var selectedHistoryDetailPanel: some View {
        if let selectedLogSummaryKind {
            RemoteLogDetailPanel(kind: selectedLogSummaryKind, model: model)
                .id(selectedLogSummaryKind)
        } else {
            CompanionEmptyDetailPanel(
                title: "기록 선택",
                detail: "로그 요약에서 상태, 실행 요청, 파일 요청 중 하나를 선택하면 상세가 여기에 표시됩니다.",
                systemImage: "sidebar.right"
            )
        }
    }

    private var historyRequestColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecentServerRequestLogView(
                entries: model.recentRequestLog,
                clearAction: {
                    Task {
                        await model.clearRemoteLogs(scope: .requestLog)
                    }
                },
                clearDisabled: !model.serverRelayConfigured || model.isSubmitting || !model.hasClearableRequestLogs
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
                    || !model.hasClearableFileAccessLogs
                    || model.activeRemoteLogFileRequest != nil
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
                    || !model.hasClearableCommandLogs
            )
        }
    }
}

private struct CompanionEmptyDetailPanel: View {
    var title: String
    var detail: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.klmsSecondaryText)
                .frame(width: 44, height: 44)
                .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.klmsPrimaryText)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }
}

private struct CompanionScreenContainer<Content: View>: View {
    var title: String
    let model: CompanionModel
    var showsAttentionStack = true
    @ViewBuilder var content: () -> Content
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                screenContent
            } else {
                NavigationStack {
                    screenContent
                }
            }
        }
    }

    private var screenContent: some View {
        ZStack {
            Color.klmsScreenBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                if showsAttentionStack {
                    RemoteAttentionStack(model: model)
                        .padding(.horizontal, horizontalSizeClass == .regular ? CompanionWorkstationMetrics.horizontalPadding : 16)
                        .padding(.top, horizontalSizeClass == .regular ? CompanionWorkstationMetrics.topPadding : 2)
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                WholeScreenVerticalScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        CompanionScreenHeader(title: title, model: model)
                        content()
                    }
                    .padding(
                        .horizontal,
                        horizontalSizeClass == .regular ? CompanionWorkstationMetrics.horizontalPadding : 16
                    )
                    .padding(.top, horizontalSizeClass == .regular ? CompanionWorkstationMetrics.topPadding : 2)
                    .padding(.bottom, horizontalSizeClass == .regular ? CompanionWorkstationMetrics.bottomPadding : 20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .navigationTitle(title)
        .klmsNavigationTitleMode()
        .klmsNavigationChrome()
        .klmsContentNavigationChrome()
    }
}

private struct CompanionScreenHeader: View {
    var title: String
    let model: CompanionModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularHeader
            } else {
                compactHeader
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.klmsPrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text("KLMS Sync")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.klmsSecondaryText)
                    .lineLimit(1)
                CompanionHeaderStatusPill(model: model)
            }
        }
    }

    private var regularHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.klmsPrimaryText)
            Spacer(minLength: 8)
            CompanionHeaderStatusPill(model: model)
        }
    }
}

private struct CompanionHeaderStatusPill: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        Text(headerStatusText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.klmsSecondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.klmsSubtleCardBackground, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private var headerStatusText: String {
        if model.isRefreshing {
            return "갱신 중"
        }
        if let lastRefreshAt = model.lastRefreshAt {
            return lastRefreshAt.formatted(date: .omitted, time: .shortened)
        }
        return "방금 갱신"
    }
}

private struct WholeScreenVerticalScrollView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
        }
        .scrollIndicators(.visible)
        .background(Color.klmsScreenBackground)
        .clipped()
    }
}

private struct RemoteAttentionStack: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        if hasAttention {
            VStack(alignment: .leading, spacing: 10) {
                if let authDigits = model.status.authDigits {
                    AuthCodeHero(digits: authDigits)
                }
                if shouldShowRunningStatus {
                    RemoteRunningStatusBanner(model: model)
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

    private var hasAttention: Bool {
        model.status.authDigits != nil
            || shouldShowRunningStatus
            || model.loginAttentionMessage != nil
            || model.authSuccessMessage != nil
            || !model.errorMessage.isEmpty
    }

    private var shouldShowRunningStatus: Bool {
        model.hasInFlightRequest || model.status.phase == "running"
    }
}

private struct RemoteRunningStatusBanner: View {
    @ObservedObject var model: CompanionModel
    @State private var localCancelSubmitting = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.klmsCommandAccent)
                .frame(width: 28, height: 28)
                .background(Color.klmsCommandAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text("동기화 진행 중")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.klmsPrimaryText)
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if model.shouldShowCancelControl {
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
                    Label(cancelButtonTitle, systemImage: cancelAlreadyRequested ? "checkmark.circle" : "stop.fill")
                        .labelStyle(.titleAndIcon)
                        .frame(minHeight: 44)
                }
                .buttonStyle(KLMSActionButtonStyle(tone: .destructive))
                .disabled(!model.canCancelRunningCommand || localCancelSubmitting)
                .accessibilityLabel(cancelButtonTitle)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.klmsCommandAccent.opacity(0.42), lineWidth: 1)
        }
    }

    private var statusMessage: String {
        model.statusLine
    }

    private var cancelAlreadyRequested: Bool {
        model.isCancelRequestedForLatestCommand
    }

    private var cancelButtonTitle: String {
        if cancelAlreadyRequested {
            return "중단 요청됨"
        }
        if localCancelSubmitting || model.isSubmitting {
            return "요청 중"
        }
        return "중단"
    }
}

private struct ServerRelayConnectionPanel: View {
    @ObservedObject var model: CompanionModel
    @State private var isExpanded = false
    private let actionColumns = [
        GridItem(.adaptive(minimum: 145), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                companionPerformWithoutAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: model.serverRelayConfigured ? "checkmark.circle.fill" : "server.rack")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(model.serverRelayConfigured ? Color.klmsSuccessBorder : Color.klmsSecondaryText)
                        .frame(width: 32, height: 32)
                        .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("서버 릴레이")
                            .font(.headline)
                        Text(model.serverRelayConfigured ? "연결 정보가 저장되어 있습니다." : "연결 정보를 붙여넣어 주세요.")
                            .font(.caption)
                            .foregroundStyle(Color.klmsSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(model.serverRelayConfigured ? "저장됨" : "미설정")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.klmsSecondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.klmsSubtleCardBackground, in: Capsule())
                        CompanionExpansionBadge(isExpanded: isExpanded)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(KLMSCardButtonStyle(cornerRadius: 12))
            .accessibilityHint(isExpanded ? "서버 릴레이 설정 접기" : "서버 릴레이 설정 펼치기")

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.connectionMessage.isEmpty {
                        ConnectionNoticeBanner(
                            message: model.connectionMessage,
                            succeeded: model.connectionSucceeded
                        )
                    }

                    CompanionSettingsSubsectionCard(
                        title: "서버 연결 정보",
                        detail: "서버 URL과 클라이언트 토큰을 관리합니다.",
                        systemImage: "link",
                        statusText: model.serverRelayConfigured ? "저장됨" : "미설정",
                        statusTint: model.serverRelayConfigured ? Color.klmsSuccessBorder : Color.klmsSecondaryText,
                        defaultExpanded: !model.serverRelayConfigured
                    ) {
                        CompanionConnectionInput(
                            title: "서버 URL",
                            detail: "공개 HTTPS 주소만 넣습니다. 로컬 주소는 저장하지 않습니다.",
                            text: $model.serverURL
                        )
                        CompanionConnectionInput(
                            title: "클라이언트 토큰",
                            detail: "이 기기용 토큰입니다. Mac 전용 토큰은 넣지 않습니다.",
                            text: $model.serverToken,
                            secure: true
                        )
                        CompanionSettingHelpText("실제 KLMS 수집은 Mac 앱이 처리합니다.")
                    }

                    CompanionSettingsSubsectionCard(
                        title: "연결 확인",
                        detail: "붙여넣기, 응답 검사, 요약 갱신을 처리합니다.",
                        systemImage: "checkmark.shield",
                        defaultExpanded: true
                    ) {
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
                        CompanionSettingHelpText("연결 확인은 동기화 없이 서버 응답만 검사합니다.")
                    }

                    CompanionSettingsSubsectionCard(
                        title: "복사",
                        detail: "다른 기기에 넣을 서버 주소와 토큰을 복사합니다.",
                        systemImage: "doc.on.doc"
                    ) {
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

                    CompanionSettingsSubsectionCard(
                        title: "연결 초기화",
                        detail: "이 기기에 저장된 서버 URL과 토큰을 지웁니다.",
                        systemImage: "trash"
                    ) {
                        Button(role: .destructive) {
                            model.clearServerRelayConnectionInfo()
                        } label: {
                            Label("연결 정보 지우기", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(KLMSActionButtonStyle(tone: .destructive))
                        .disabled(!model.serverRelayConfigured && model.serverURL.isEmpty && model.serverToken.isEmpty)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
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
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(KLMSActionButtonStyle())
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
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(KLMSActionButtonStyle())
    }
}

private struct CompanionConnectionInput: View {
    var title: String
    var detail: String
    @Binding var text: String
    var secure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsPrimaryText)
                CompanionSettingHelpText(detail)
            }
            if secure {
                SecureField("입력", text: $text)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            } else {
                TextField("입력", text: $text)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsSubtleCardBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.klmsBorder.opacity(0.82), lineWidth: 1)
        }
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
                .foregroundStyle(Color.klmsPrimaryText)
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
            return .klmsSuccessBorder
        case .some(false):
            return .klmsWarningBorder
        case nil:
            return .klmsCommandAccent
        }
    }
}

private enum DashboardMetricCategory: String, CaseIterable, Identifiable, Sendable {
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
            Color.klmsWarningBorder
        case .exams, .calendar:
            Color.klmsSuccessBorder
        case .notices:
            Color.klmsCommandAccent
        case .files:
            Color.klmsSecondaryText
        case .quarantine:
            Color.klmsDangerBorder
        case .helpDesk:
            Color.klmsCommandAccent
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
            "아직 동기화된 진행 중 과제가 없습니다."
        case .exams:
            "아직 동기화된 예정 시험이 없습니다."
        case .notices:
            "아직 동기화된 공지 목록이 없습니다."
        case .files:
            "아직 동기화된 파일 목록이 없습니다."
        case .quarantine:
            "격리 파일 상세는 아직 Mac 앱 파일 화면에서 확인해야 합니다."
        case .calendar:
            "캘린더 변경 상세는 Mac 앱의 캘린더 변경 화면에서 확인해야 합니다."
        case .helpDesk:
            "아직 동기화된 헬프데스크 일정이 없습니다."
        }
    }

    var workstationDescription: String {
        switch self {
        case .assignments:
            "미리알림 완료 상태 반영"
        case .exams:
            "KLMS + 메일 시험 통합"
        case .notices:
            "읽음/중요 상태 유지"
        case .files:
            "강의자료와 첨부 파일 구분"
        case .quarantine:
            "주의 파일만 표시"
        case .calendar:
            "등록/수정/삭제 확인"
        case .helpDesk:
            "헬프데스크 일정"
        }
    }

    var supportsWorkstationSelectionWorkspace: Bool {
        switch self {
        case .assignments, .exams, .notices, .files, .helpDesk:
            return true
        case .quarantine, .calendar:
            return false
        }
    }
}

private func companionItemKindTint(_ kind: String) -> Color {
    switch kind {
    case "assignment", "completedAssignment", "assignmentCandidate":
        return Color.klmsWarningBorder
    case "exam", "examCandidate":
        return Color.klmsSuccessBorder
    case "notice", "helpDesk":
        return Color.klmsCommandAccent
    case "file":
        return Color.klmsSecondaryText
    default:
        return Color.klmsSecondaryText
    }
}

private enum CompanionItemSortOption: String, CaseIterable, Identifiable, Sendable {
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

    static func defaultSort(for _: DashboardMetricCategory?) -> CompanionItemSortOption {
        .recent
    }
}

private enum CompanionItemVisibilityFilter: String, CaseIterable, Identifiable, Sendable {
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

private enum CompanionItemStatusFilter: String, CaseIterable, Identifiable, Sendable {
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
    static let allYears = "전체 연도"
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

private struct CompanionItemListInputKey: Hashable {
    var itemsRevision: Int
    var category: String
    var query: String
    var sortOption: String
    var visibilityFilter: String
    var statusFilter: String
    var selectedCourse: String
    var selectedYear: String
    var selectedSemester: String
    var newOnly: Bool
    var recentOnly: Bool

    func shouldDebounceComparedTo(_ previous: CompanionItemListInputKey?) -> Bool {
        guard var previous else { return false }
        previous.query = query
        return previous == self
    }
}

private extension CompanionItemListInputKey {
    static func defaultCategoryKey(itemsRevision: Int, category: DashboardMetricCategory) -> CompanionItemListInputKey {
        CompanionItemListInputKey(
            itemsRevision: itemsRevision,
            category: category.rawValue,
            query: "",
            sortOption: CompanionItemSortOption.defaultSort(for: category).rawValue,
            visibilityFilter: CompanionItemVisibilityFilter.visible.rawValue,
            statusFilter: CompanionItemStatusFilter.defaultFilter(for: category).rawValue,
            selectedCourse: CompanionItemListFilter.allCourses,
            selectedYear: CompanionItemListFilter.allYears,
            selectedSemester: CompanionItemListFilter.allSemesters,
            newOnly: false,
            recentOnly: false
        )
    }
}

private enum CompanionLargeList {
    static let initialVisibleLimit = 4
    static let regularInitialVisibleLimit = 12
    static let previewVisibleLimit = 5
    static let regularPreviewVisibleLimit = 8
    static let calendarVisibleLimit = 6
    static let regularCalendarVisibleLimit = 10
    static let increment = 10
    static let filterRebuildDelayNanoseconds: UInt64 = 16_000_000
    static let detailRenderDelayNanoseconds: UInt64 = 35_000_000
    static let prewarmDelayNanoseconds: UInt64 = 120_000_000

    static func initialVisibleLimit(horizontalSizeClass: UserInterfaceSizeClass?) -> Int {
        horizontalSizeClass == .regular ? regularInitialVisibleLimit : initialVisibleLimit
    }

    static func previewVisibleLimit(horizontalSizeClass: UserInterfaceSizeClass?) -> Int {
        horizontalSizeClass == .regular ? regularPreviewVisibleLimit : previewVisibleLimit
    }

    static func calendarVisibleLimit(horizontalSizeClass: UserInterfaceSizeClass?) -> Int {
        horizontalSizeClass == .regular ? regularCalendarVisibleLimit : calendarVisibleLimit
    }
}

private struct CompanionItemFilterOptions: Equatable, Sendable {
    var courseOptions: [String]
    var yearOptions: [String]
    var semesterOptions: [String]
    var availableStatusFilters: [CompanionItemStatusFilter]

    init(items: [ServerRelaySyncItem], category: DashboardMetricCategory?) {
        courseOptions = CompanionItemListFilter.courseOptions(for: items)
        yearOptions = CompanionItemListFilter.yearOptions(for: items)
        semesterOptions = CompanionItemListFilter.semesterOptions(for: items)
        availableStatusFilters = CompanionItemStatusFilter.options(for: category, items: items)
    }
}

private struct CompanionItemListData: Sendable {
    var baseItems: [ServerRelaySyncItem]
    var courseOptions: [String]
    var yearOptions: [String]
    var semesterOptions: [String]
    var availableStatusFilters: [CompanionItemStatusFilter]
    var effectiveStatusFilter: CompanionItemStatusFilter
    var filteredItems: [ServerRelaySyncItem]

    init(
        items: [ServerRelaySyncItem],
        category: DashboardMetricCategory?,
        isCategoryPrefiltered: Bool = false,
        query: String,
        sortOption: CompanionItemSortOption,
        visibilityFilter: CompanionItemVisibilityFilter,
        statusFilter: CompanionItemStatusFilter,
        selectedCourse: String,
        selectedYear: String,
        selectedSemester: String,
        newOnly: Bool,
        recentOnly: Bool,
        filterOptions: CompanionItemFilterOptions? = nil
    ) {
        let base = category.map { metric in
            isCategoryPrefiltered ? items : items.filter { metric.includes($0) }
        } ?? items
        let resolvedFilterOptions = filterOptions ?? CompanionItemFilterOptions(items: base, category: category)
        let courses = resolvedFilterOptions.courseOptions
        let years = resolvedFilterOptions.yearOptions
        let semesters = resolvedFilterOptions.semesterOptions
        let statusFilters = resolvedFilterOptions.availableStatusFilters
        let effectiveStatus = statusFilters.contains(statusFilter)
            ? statusFilter
            : CompanionItemStatusFilter.defaultFilter(for: category)
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCourse = courses.contains(selectedCourse) ? selectedCourse : CompanionItemListFilter.allCourses
        let normalizedYear = years.contains(selectedYear) ? selectedYear : CompanionItemListFilter.allYears
        let normalizedSemester = semesters.contains(selectedSemester) ? selectedSemester : CompanionItemListFilter.allSemesters
        var filtered: [ServerRelaySyncItem] = []
        filtered.reserveCapacity(base.count)
        for item in base {
            guard visibilityFilter.includes(item),
                  effectiveStatus.includes(item),
                  normalizedCourse == CompanionItemListFilter.allCourses || item.course == normalizedCourse,
                  normalizedYear == CompanionItemListFilter.allYears || (item.academicYear.map(String.init) ?? "") == normalizedYear,
                  normalizedSemester == CompanionItemListFilter.allSemesters || item.academicSemester == normalizedSemester,
                  !newOnly || item.isCompanionChangedLike,
                  !recentOnly || item.isCompanionChangedLike else {
                continue
            }
            if !normalizedQuery.isEmpty,
               !item.searchText.localizedCaseInsensitiveContains(normalizedQuery) {
                continue
            }
            filtered.append(item)
        }
        let sortedFiltered = filtered.companionSorted(by: sortOption)

        self.baseItems = base
        self.courseOptions = courses
        self.yearOptions = years
        self.semesterOptions = semesters
        self.availableStatusFilters = statusFilters
        self.effectiveStatusFilter = effectiveStatus
        self.filteredItems = sortedFiltered
    }
}

private struct CompanionItemListPrewarmView: View {
    let model: CompanionModel
    var categories: [DashboardMetricCategory]

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: prewarmKey) {
                try? await Task.sleep(nanoseconds: CompanionLargeList.prewarmDelayNanoseconds)
                guard !Task.isCancelled else { return }
                await CompanionItemListPreloadStore.prewarm(model: model, categories: categories)
            }
    }

    private var prewarmKey: String {
        "\(model.dashboardSyncItemsRevision):\(categories.map(\.rawValue).joined(separator: ","))"
    }
}

@MainActor
private enum CompanionItemListPreloadStore {
    private static var cachedDataByKey: [CompanionItemListInputKey: CompanionItemListData] = [:]
    private static var inFlightKeys = Set<CompanionItemListInputKey>()
    private static let maxCachedLists = 8

    static func cachedData(for key: CompanionItemListInputKey) -> CompanionItemListData? {
        cachedDataByKey[key]
    }

    static func store(_ data: CompanionItemListData, for key: CompanionItemListInputKey) {
        cachedDataByKey[key] = data
        inFlightKeys.remove(key)
        trimCache(keeping: key)
    }

    static func prewarm(model: CompanionModel, categories: [DashboardMetricCategory]) async {
        let revision = model.dashboardSyncItemsRevision
        for category in categories where category.supportsWorkstationSelectionWorkspace {
            let key = CompanionItemListInputKey.defaultCategoryKey(itemsRevision: revision, category: category)
            guard cachedDataByKey[key] == nil, !inFlightKeys.contains(key) else {
                continue
            }
            let items = model.cachedDashboardItems(for: category.rawValue)
            guard !items.isEmpty else { continue }
            let filterOptions = model.cachedDashboardFilterOptions(for: category.rawValue)
            inFlightKeys.insert(key)
            Task { @MainActor in
                let data = await Task.detached(priority: .utility) {
                    CompanionItemListData(
                        items: items,
                        category: category,
                        isCategoryPrefiltered: true,
                        query: "",
                        sortOption: CompanionItemSortOption.defaultSort(for: category),
                        visibilityFilter: .visible,
                        statusFilter: CompanionItemStatusFilter.defaultFilter(for: category),
                        selectedCourse: CompanionItemListFilter.allCourses,
                        selectedYear: CompanionItemListFilter.allYears,
                        selectedSemester: CompanionItemListFilter.allSemesters,
                        newOnly: false,
                        recentOnly: false,
                        filterOptions: filterOptions
                    )
                }.value
                guard inFlightKeys.contains(key) else { return }
                store(data, for: key)
            }
        }
    }

    private static func trimCache(keeping protectedKey: CompanionItemListInputKey) {
        guard cachedDataByKey.count > maxCachedLists else { return }
        let keysToRemove = cachedDataByKey.keys
            .filter { $0 != protectedKey }
            .prefix(cachedDataByKey.count - maxCachedLists)
        for key in keysToRemove {
            cachedDataByKey.removeValue(forKey: key)
        }
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
                    .foregroundStyle(Color.klmsSecondaryText)
                Spacer(minLength: 0)
                if hasActiveFilter {
                    Button {
                        resetFilters()
                    } label: {
                        Label("필터 지우기", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(KLMSActionButtonStyle())
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
                    HStack(spacing: 8) {
                        if yearOptions.count > 1 {
                            companionPickerField(title: "연도", systemImage: "calendar") {
                                Picker("연도", selection: $selectedYear) {
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

                    if courseOptions.count <= 1 && yearOptions.count <= 1 && semesterOptions.count <= 1 {
                        Text("전체 범위")
                            .font(.caption)
                            .foregroundStyle(Color.klmsSecondaryText)
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
                .frame(minHeight: 44)
                .background(isSelected ? Color.klmsSelectedBackground.opacity(0.96) : Color.klmsSubtleCardBackground, in: Capsule())
                .foregroundStyle(isSelected ? Color.klmsSelectedForeground : Color.klmsPrimaryText)
                .overlay {
                    Capsule()
                        .stroke(isSelected ? Color.klmsSelectedBorder.opacity(0.92) : Color.klmsBorder, lineWidth: isSelected ? 1.2 : 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(KLMSCardButtonStyle(cornerRadius: 999))
        .accessibilityLabel("\(title) \(isSelected ? "선택됨" : "해제됨")")
    }

    private func companionPickerField<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.klmsSecondaryText)
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

private struct CompanionItemListControlsPlaceholder: View {
    private let controls = [
        ("정렬", "arrow.up.arrow.down", "최신순으로 준비 중"),
        ("범위", "line.3.horizontal.decrease.circle", "연도 · 학기 · 과목"),
        ("상태", "checklist", "전체 상태"),
        ("표시", "slider.horizontal.3", "새 항목 · 최근 변경"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("목록 기준을 준비하고 있습니다", systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.klmsSecondaryText)

            ForEach(controls, id: \.0) { title, systemImage, detail in
                CompanionControlBox(title: title, systemImage: systemImage) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Color.klmsSecondaryText)
                }
            }
        }
        .padding(.vertical, 4)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
    }
}

private struct DeferredCompanionItemListControls: View {
    var listData: CompanionItemListData
    @Binding var sortOption: CompanionItemSortOption
    @Binding var visibilityFilter: CompanionItemVisibilityFilter
    @Binding var statusFilter: CompanionItemStatusFilter
    @Binding var selectedCourse: String
    @Binding var selectedYear: String
    @Binding var selectedSemester: String
    @Binding var newOnly: Bool
    @Binding var recentOnly: Bool
    var supportsNewOnly: Bool
    var supportsRecentOnly: Bool
    var defaultStatusFilter: CompanionItemStatusFilter
    @State private var displayedOptionsKey: String?

    var body: some View {
        Group {
            if displayedOptionsKey == optionsKey {
                CompanionItemListControls(
                    sortOption: $sortOption,
                    visibilityFilter: $visibilityFilter,
                    statusFilter: $statusFilter,
                    selectedCourse: $selectedCourse,
                    selectedYear: $selectedYear,
                    selectedSemester: $selectedSemester,
                    newOnly: $newOnly,
                    recentOnly: $recentOnly,
                    availableStatusFilters: listData.availableStatusFilters,
                    courseOptions: listData.courseOptions,
                    yearOptions: listData.yearOptions,
                    semesterOptions: listData.semesterOptions,
                    supportsNewOnly: supportsNewOnly,
                    supportsRecentOnly: supportsRecentOnly,
                    defaultStatusFilter: defaultStatusFilter,
                    totalCount: listData.baseItems.count,
                    filteredCount: listData.filteredItems.count
                )
            } else {
                CompanionItemListControlsPlaceholder()
            }
        }
        .task(id: optionsKey) {
            displayedOptionsKey = nil
            await Task.yield()
            guard !Task.isCancelled else { return }
            displayedOptionsKey = optionsKey
        }
    }

    private var optionsKey: String {
        [
            "\(listData.baseItems.count)",
            "\(listData.courseOptions.count)",
            listData.courseOptions.first ?? "",
            listData.courseOptions.last ?? "",
            listData.yearOptions.joined(separator: "|"),
            listData.semesterOptions.joined(separator: "|"),
            listData.availableStatusFilters.map(\.rawValue).joined(separator: "|"),
        ].joined(separator: "::")
    }
}

private struct CompanionSearchFilterPanel<Controls: View>: View {
    var title: String
    var fieldPrompt: String
    @Binding var query: String
    @ViewBuilder var controls: Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "magnifyingglass")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.klmsSecondaryText)

            TextField(fieldPrompt, text: $query)
                .textFieldStyle(.roundedBorder)

            controls
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

private struct CompanionControlBox<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.klmsSecondaryText)
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

private struct RemoteDashboardSyncCard: View {
    @ObservedObject var model: CompanionModel
    var compact: Bool

    private let secondaryCommands: [RemoteCommandKind] = [.filesSync, .coreSync, .noticeSync]
    private let secondaryColumns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 7), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text("동기화")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.klmsSecondaryText)
                Spacer(minLength: 8)
                syncStateChip
            }

            MailPasteAnalyzerPanel(model: model)

            dashboardPrimaryButton

            LazyVGrid(columns: secondaryColumns, spacing: 7) {
                ForEach(secondaryCommands, id: \.self) { command in
                    dashboardSecondaryButton(command)
                }
            }
        }
        .padding(11)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private var syncStateChip: some View {
        Text(syncStateTitle)
            .font(.caption2.weight(.bold))
            .foregroundStyle(syncStateColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(syncStateColor.opacity(0.13), in: Capsule())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var dashboardPrimaryButton: some View {
        let isRunning = isCommandActive(.fullSync)
        let isDisabled = commandDisabled(for: .fullSync)
        return Button {
            runOrCancel(.fullSync)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Text(primaryCommandTitle(isRunning: isRunning, isDisabled: isDisabled))
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                Spacer(minLength: 0)
                Image(systemName: primaryCommandSystemImage(isRunning: isRunning, isDisabled: isDisabled))
                    .font(.headline.weight(.black))
            }
            .foregroundStyle(primaryCommandForeground(isDisabled: isDisabled))
            .frame(maxWidth: .infinity, minHeight: compact ? 56 : 60, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 14)
            .background(
                primaryCommandBackground(isRunning: isRunning, isDisabled: isDisabled),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(primaryCommandBorder(isRunning: isRunning, isDisabled: isDisabled), lineWidth: 1)
            }
        }
        .buttonStyle(KLMSCardButtonStyle(cornerRadius: 12, disabledOpacity: 0.78))
        .disabled(isDisabled)
        .accessibilityLabel(isRunning ? "전체 동기화 중단" : "전체 동기화 실행")
        .accessibilityHint(isRunning ? "Mac 앱에서 진행 중인 전체 동기화를 중단합니다." : "Mac 앱에 전체 동기화 실행 요청을 보냅니다.")
    }

    private func dashboardSecondaryButton(_ kind: RemoteCommandKind) -> some View {
        let isRunning = isCommandActive(kind)
        let isDisabled = commandDisabled(for: kind)
        return Button {
            runOrCancel(kind)
        } label: {
            HStack(spacing: 5) {
                if let systemImage = secondaryCommandSystemImage(isRunning: isRunning, isDisabled: isDisabled) {
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: .black, design: .rounded))
                }
                Text(shortTitle(for: kind))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(secondaryCommandForeground(isDisabled: isDisabled))
            .frame(maxWidth: .infinity, minHeight: compact ? 44 : 46, alignment: .center)
            .padding(.horizontal, 5)
            .padding(.vertical, 9)
            .background(
                secondaryCommandBackground(isRunning: isRunning, isDisabled: isDisabled),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        secondaryCommandBorder(isRunning: isRunning, isDisabled: isDisabled),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(KLMSCardButtonStyle(disabledOpacity: 1.0))
        .disabled(isDisabled)
        .accessibilityLabel(isRunning ? "\(kind.displayName) 중단" : "\(kind.displayName) 실행")
        .accessibilityHint(isRunning ? "Mac 앱에서 진행 중인 \(kind.displayName)을 중단합니다." : "Mac 앱에 \(kind.displayName) 실행 요청을 보냅니다.")
    }

    private func commandDisabled(for kind: RemoteCommandKind) -> Bool {
        !model.isRemoteAvailable || model.isSubmitting || (model.hasInFlightRequest && !isCommandActive(kind))
    }

    private func isCommandActive(_ kind: RemoteCommandKind) -> Bool {
        model.latestDisplayStatus?.isInFlight == true && model.latestCommand?.kind == kind
    }

    private func runOrCancel(_ kind: RemoteCommandKind) {
        Task {
            if isCommandActive(kind) {
                await model.cancelRunningCommand()
            } else {
                await model.createCommand(kind)
            }
        }
    }

    private func primaryCommandTitle(isRunning: Bool, isDisabled _: Bool) -> String {
        if isRunning { return "전체 동기화 중단" }
        return "전체 동기화"
    }

    private func primaryCommandSystemImage(isRunning: Bool, isDisabled: Bool) -> String {
        if isRunning { return "stop.fill" }
        if isDisabled { return "lock.fill" }
        return "play.fill"
    }

    private func primaryCommandForeground(isDisabled: Bool) -> Color {
        isDisabled ? Color.klmsSecondaryText.opacity(0.76) : Color.klmsPrimaryCommandButtonForeground
    }

    private func primaryCommandBackground(isRunning: Bool, isDisabled: Bool) -> Color {
        if isDisabled { return Color.klmsSubtleCardBackground.opacity(0.86) }
        return isRunning ? Color.klmsPrimaryCommandButtonPressedBackground : Color.klmsPrimaryCommandButtonBackground
    }

    private func primaryCommandBorder(isRunning: Bool, isDisabled: Bool) -> Color {
        if isDisabled { return Color.klmsCommandButtonBorder.opacity(0.64) }
        return isRunning ? Color.klmsPrimaryCommandButtonBorder.opacity(0.78) : Color.klmsPrimaryCommandButtonBorder
    }

    private func secondaryCommandSystemImage(isRunning: Bool, isDisabled: Bool) -> String? {
        if isRunning { return "stop.fill" }
        if isDisabled { return "lock.fill" }
        return nil
    }

    private func secondaryCommandForeground(isDisabled: Bool) -> Color {
        isDisabled ? Color.klmsSecondaryText.opacity(0.64) : Color.klmsSecondaryCommandButtonForeground
    }

    private func secondaryCommandBackground(isRunning: Bool, isDisabled: Bool) -> Color {
        if isDisabled { return Color.klmsSubtleCardBackground.opacity(0.70) }
        return isRunning ? Color.klmsCommandButtonPressedBackground : Color.klmsCommandButtonBackground
    }

    private func secondaryCommandBorder(isRunning: Bool, isDisabled: Bool) -> Color {
        if isDisabled { return Color.klmsCommandButtonBorder.opacity(0.54) }
        return Color.klmsCommandButtonBorder.opacity(isRunning ? 1.0 : 0.92)
    }

    private var syncStateTitle: String {
        if model.hasInFlightRequest || model.status.phase == "running" {
            return model.activeRequestLabel
        }
        return model.isRemoteAvailable ? "준비됨" : "연결 필요"
    }

    private var syncStateColor: Color {
        if model.hasInFlightRequest || model.status.phase == "running" {
            return Color.klmsCommandAccent
        }
        return model.isRemoteAvailable ? Color.klmsSecondaryText : Color.klmsWarningBorder
    }

    private func shortTitle(for kind: RemoteCommandKind) -> String {
        switch kind {
        case .filesSync:
            return "파일"
        case .coreSync:
            return "과제/시험"
        case .noticeSync:
            return "공지"
        default:
            return kind.displayName
        }
    }
}

private struct RemoteDashboardMetricOverview: View {
    let model: CompanionModel
    var status: SanitizedRemoteStatus
    var hasFileCleanupDetails: Bool
    @Binding var selectedCategory: DashboardMetricCategory?
    var effectiveSelectedCategory: DashboardMetricCategory? = nil
    var onCategoryTap: (DashboardMetricCategory) -> Void
    var selectedChangeSummary: RemoteChangeSummaryKind?
    var showsCompactChangeDetail = true
    var onChangeSummaryTap: (RemoteChangeSummaryKind) -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let compactColumns = [
        GridItem(.adaptive(minimum: 132), spacing: 8),
    ]
    private let workstationColumns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 2)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if shouldShowPrimaryMetricSection {
                metricSection("주요 항목", categories: primaryMetricCategories)
            }
            if shouldShowAttentionMetricSection {
                metricSection("확인 필요", categories: attentionMetricCategories)
            } else if shouldShowInlineEmptyDashboardMessage {
                Text("표시할 대시보드 항목이 없습니다.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.klmsSecondaryText)
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(Color.klmsSubtleCardBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 13))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(Color.klmsBorder.opacity(0.78), lineWidth: 1)
                    }
            }

            if hasVisibleChangeSummary {
                RemoteDashboardChangeSummary(
                    status: displayStatus,
                    hasFileCleanupDetails: hasFileCleanupDetails,
                    selectedKind: selectedChangeSummary,
                    model: model,
                    showsCompactDetail: showsCompactChangeDetail,
                    onSelect: onChangeSummaryTap
                )
            }
        }
    }

    @ViewBuilder
    private func metricSection(_ title: String, categories: [DashboardMetricCategory]) -> some View {
        if !categories.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                if horizontalSizeClass == .regular {
                    LazyVGrid(columns: workstationColumns, alignment: .leading, spacing: 8) {
                        ForEach(categories) { category in
                            WorkstationMetricCard(
                                category: category,
                                value: category.value(from: displayStatus),
                                isSelected: isSelected(category)
                            ) {
                                selectCategory(category)
                            }
                        }
                    }
                } else {
                    LazyVGrid(columns: compactColumns, alignment: .leading, spacing: 8) {
                        ForEach(categories) { category in
                            RemoteMetricTile(
                                category.title,
                                category.value(from: displayStatus),
                                systemImage: category.systemImage,
                                isSelected: isSelected(category)
                            ) {
                                selectCategory(category)
                            }
                        }
                    }
                }
            }
        }
    }

    private var displayStatus: SanitizedRemoteStatus {
        status
    }

    private var primaryMetricCategories: [DashboardMetricCategory] {
        let required: [DashboardMetricCategory] = [.files, .assignments, .notices, .exams]
            .filter { $0.value(from: displayStatus) > 0 }
        let optional: [DashboardMetricCategory] = [.helpDesk].filter { $0.value(from: displayStatus) > 0 }
        return required + optional
    }

    private var attentionMetricCategories: [DashboardMetricCategory] {
        let categories: [DashboardMetricCategory] = [.quarantine, .calendar]
        return categories.filter { $0.value(from: displayStatus) > 0 }
    }

    private var shouldShowPrimaryMetricSection: Bool {
        !primaryMetricCategories.isEmpty
    }

    private var shouldShowAttentionMetricSection: Bool {
        !attentionMetricCategories.isEmpty
    }

    private var shouldShowInlineEmptyDashboardMessage: Bool {
        horizontalSizeClass != .regular
            && primaryMetricCategories.isEmpty
            && attentionMetricCategories.isEmpty
            && !hasVisibleChangeSummary
    }

    private var hasVisibleChangeSummary: Bool {
        RemoteChangeSummaryKind.allCases.contains { kind in
            guard kind.value(from: displayStatus) > 0 else { return false }
            return kind != .fileCleanup || hasFileCleanupDetails
        }
    }

    private func selectCategory(_ category: DashboardMetricCategory) {
        companionPerformWithoutAnimation {
            selectedCategory = category
            onCategoryTap(category)
        }
    }

    private func isSelected(_ category: DashboardMetricCategory) -> Bool {
        (effectiveSelectedCategory ?? selectedCategory) == category
    }
}

private enum RemoteChangeSummaryKind: String, CaseIterable, Identifiable {
    case noticeNew
    case noticeUpdated
    case newFiles
    case fileCleanup
    case calendarCreated
    case calendarUpdated
    case calendarDeleted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noticeNew:
            "새 공지"
        case .noticeUpdated:
            "수정 공지"
        case .newFiles:
            "새 파일"
        case .fileCleanup:
            "파일 정리"
        case .calendarCreated:
            "캘린더 생성"
        case .calendarUpdated:
            "캘린더 수정"
        case .calendarDeleted:
            "캘린더 삭제"
        }
    }

    var detailTitle: String {
        switch self {
        case .noticeNew:
            "새로 들어온 공지"
        case .noticeUpdated:
            "내용이 바뀐 공지"
        case .newFiles:
            "새로 확인된 파일"
        case .fileCleanup:
            "파일 정리 결과"
        case .calendarCreated:
            "새로 만든 캘린더 일정"
        case .calendarUpdated:
            "수정한 캘린더 일정"
        case .calendarDeleted:
            "삭제한 캘린더 일정"
        }
    }

    var systemImage: String {
        switch self {
        case .noticeNew, .noticeUpdated:
            "note.text"
        case .newFiles, .fileCleanup:
            "folder"
        case .calendarCreated, .calendarUpdated, .calendarDeleted:
            "calendar"
        }
    }

    var tint: Color {
        switch self {
        case .noticeNew, .noticeUpdated:
            Color.klmsCommandAccent
        case .newFiles:
            Color.klmsSecondaryText
        case .fileCleanup:
            Color.klmsDangerBorder
        case .calendarCreated:
            Color.klmsSuccessBorder
        case .calendarUpdated:
            Color.klmsCommandAccent
        case .calendarDeleted:
            Color.klmsDangerBorder
        }
    }

    var chipBackground: Color {
        switch self {
        case .noticeNew, .noticeUpdated, .calendarUpdated:
            Color.klmsCommandButtonBackground
        case .newFiles:
            Color.klmsCardBackground
        case .fileCleanup, .calendarDeleted:
            Color.klmsDangerBackground
        case .calendarCreated:
            Color.klmsSuccessBackground
        }
    }

    var chipBorder: Color {
        switch self {
        case .fileCleanup, .calendarDeleted:
            Color.klmsDangerBorder
        case .calendarCreated:
            Color.klmsSuccessBorder
        case .noticeNew, .noticeUpdated, .calendarUpdated:
            Color.klmsCommandButtonBorder
        case .newFiles:
            Color.klmsBorder
        }
    }

    var emptyMessage: String {
        switch self {
        case .noticeNew, .noticeUpdated:
            "공지 상세가 아직 도착하지 않았습니다. Mac에서 요약을 다시 받으면 채워질 수 있습니다."
        case .newFiles:
            "새 파일 상세가 아직 도착하지 않았습니다. 파일 동기화가 끝난 뒤 요약을 다시 받아 주세요."
        case .fileCleanup:
            "파일 정리 숫자는 확인됐지만 상세 정리 로그가 아직 올라오지 않았습니다."
        case .calendarCreated, .calendarUpdated, .calendarDeleted:
            "캘린더 변경 상세가 아직 도착하지 않았습니다. Mac에서 요약을 다시 받아 주세요."
        }
    }

    var isCalendarChange: Bool {
        switch self {
        case .calendarCreated, .calendarUpdated, .calendarDeleted:
            true
        default:
            false
        }
    }

    func value(from status: SanitizedRemoteStatus) -> Int {
        switch self {
        case .noticeNew:
            status.noticeNew
        case .noticeUpdated:
            status.noticeUpdated
        case .newFiles:
            status.newFiles
        case .fileCleanup:
            status.fileCleanupTotal
        case .calendarCreated:
            status.calendarCreated
        case .calendarUpdated:
            status.calendarUpdated
        case .calendarDeleted:
            status.calendarDeleted
        }
    }

    func includes(_ item: ServerRelaySyncItem) -> Bool {
        switch self {
        case .noticeNew:
            item.kind == "notice" && item.isCompanionNewLike
        case .noticeUpdated:
            item.kind == "notice" && item.isCompanionUpdatedLike
        case .newFiles:
            item.kind == "file" && item.isCompanionChangedLike
        case .fileCleanup, .calendarCreated, .calendarUpdated, .calendarDeleted:
            false
        }
    }

    func includes(_ change: CalendarChange) -> Bool {
        switch self {
        case .calendarCreated:
            change.action == "created"
        case .calendarUpdated:
            change.action == "updated"
        case .calendarDeleted:
            change.action == "deleted"
        default:
            false
        }
    }
}

private struct RemoteChangeSummaryEntry: Identifiable {
    var kind: RemoteChangeSummaryKind
    var value: Int

    var id: String { kind.id }
}

private struct RemoteDashboardChangeSummary: View {
    var status: SanitizedRemoteStatus
    var hasFileCleanupDetails: Bool
    var selectedKind: RemoteChangeSummaryKind?
    let model: CompanionModel
    var showsCompactDetail = true
    var onSelect: (RemoteChangeSummaryKind) -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var entries: [RemoteChangeSummaryEntry] {
        RemoteChangeSummaryKind.allCases.compactMap { kind in
            let value = kind.value(from: status)
            guard value > 0 else { return nil }
            guard kind != .fileCleanup || hasFileCleanupDetails else { return nil }
            return RemoteChangeSummaryEntry(kind: kind, value: value)
        }
    }

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("변경 요약", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsSecondaryText)
                FlowChipLayout(entries: entries, selectedKind: selectedKind, onSelect: onSelect)
                if showsCompactDetail,
                   let selectedKind,
                   entries.contains(where: { $0.kind == selectedKind }) {
                    compactChangeDetail(for: selectedKind)
                }
            }
        }
    }

    @ViewBuilder
    private func compactChangeDetail(for kind: RemoteChangeSummaryKind) -> some View {
        if horizontalSizeClass != .regular {
            RemoteChangeSummaryDetailPanel(
                kind: kind,
                status: status,
                changedItems: model.cachedChangeSummaryItems(for: kind.rawValue),
                changedCalendarItems: model.cachedChangeSummaryCalendarChanges(for: kind.rawValue),
                fileCleanupReports: model.cachedFileCleanupReportsForDashboard(),
                model: model
            )
                .id(kind)
        }
    }
}

private struct FlowChipLayout: View {
    var entries: [RemoteChangeSummaryEntry]
    var selectedKind: RemoteChangeSummaryKind?
    var onSelect: (RemoteChangeSummaryKind) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 7)], alignment: .leading, spacing: 7) {
            ForEach(entries) { entry in
                Button {
                    onSelect(entry.kind)
                } label: {
                    let isSelected = selectedKind == entry.kind
                    HStack(spacing: 5) {
                        Image(systemName: entry.kind.systemImage)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isSelected ? Color.klmsSelectedForeground : entry.kind.tint)
                        Text("\(entry.value)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(isSelected ? Color.klmsSelectedForeground : Color.klmsPrimaryText)
                        Text(entry.kind.title)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .foregroundStyle(isSelected ? Color.klmsSelectedForeground : Color.klmsPrimaryText)
                        Spacer(minLength: 0)
                        Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isSelected ? Color.klmsSelectedForeground.opacity(0.86) : Color.klmsSecondaryText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(
                        isSelected
                            ? Color.klmsSelectedBackground.opacity(0.96)
                            : entry.kind.chipBackground,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.klmsSelectedBorder.opacity(0.92) : entry.kind.chipBorder, lineWidth: isSelected ? 1.2 : 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(KLMSCardButtonStyle())
                .accessibilityLabel("\(entry.kind.title) \(entry.value)개 \(selectedKind == entry.kind ? "펼쳐짐" : "접힘")")
                .accessibilityHint("변경된 항목 목록을 펼칩니다.")
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
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 7) {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.klmsSelectedForeground.opacity(0.9) : Color.klmsCommandAccent)
                        .frame(width: 26, height: 26)
                        .background(
                            isSelected
                                ? Color.klmsSelectedForeground.opacity(0.12)
                                : Color.klmsCommandAccent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    Spacer(minLength: 0)
                    Text("\(value)")
                        .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(isSelected ? Color.klmsSelectedForeground : Color.klmsPrimaryText)
                }
                Text(label)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? Color.klmsSelectedForeground.opacity(0.82) : Color.klmsSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(11)
            .background(isSelected ? Color.klmsSelectedBackground.opacity(0.96) : Color.klmsCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.klmsSelectedBorder.opacity(0.92) : Color.klmsBorder, lineWidth: isSelected ? 1.2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(KLMSCardButtonStyle(cornerRadius: 14))
        .accessibilityLabel("\(label) \(value)개")
        .accessibilityValue(isSelected ? "선택됨" : "")
        .accessibilityHint("\(label) 상세를 아래에 엽니다.")
    }
}

private struct KLMSCardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10
    var disabledOpacity: Double = 0.48
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minHeight: 44)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.klmsCommandButtonPressedOverlay.opacity(configuration.isPressed ? 1.0 : 0.0))
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1.0 : disabledOpacity)
    }
}

private func companionPerformWithoutAnimation(_ updates: () -> Void) {
    var transaction = Transaction()
    transaction.animation = nil
    withTransaction(transaction) {
        updates()
    }
}

private struct DeferredInteractionExpansion<Content: View>: View {
    var isExpanded: Bool
    private let content: () -> Content

    init(
        isExpanded: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        if isExpanded {
            content()
        }
    }
}

private struct WorkstationMetricCard: View {
    var category: DashboardMetricCategory
    var value: Int
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: category.systemImage)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.klmsSelectedForeground.opacity(0.9) : Color.klmsCommandAccent)
                        .frame(width: 26, height: 26)
                        .background(
                            isSelected
                                ? Color.klmsSelectedForeground.opacity(0.12)
                                : Color.klmsCommandAccent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    Text("\(category.title) \(value)개")
                        .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(isSelected ? Color.klmsSelectedForeground : Color.klmsPrimaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Text(category.workstationDescription)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(isSelected ? Color.klmsSelectedForeground.opacity(0.78) : Color.klmsSecondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .background(isSelected ? Color.klmsSelectedBackground.opacity(0.96) : Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 13))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(isSelected ? Color.klmsSelectedBorder.opacity(0.92) : Color.klmsBorder, lineWidth: isSelected ? 1.2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(KLMSCardButtonStyle(cornerRadius: 13))
        .accessibilityLabel("\(category.title) \(value)개")
        .accessibilityValue(isSelected ? "선택됨" : "")
        .accessibilityHint("\(category.title) 상세와 처리 버튼을 오른쪽 패널에 표시합니다.")
    }
}

private struct WorkstationDashboardOverviewData: Equatable {
    var status: SanitizedRemoteStatus
    var filePreviewItems: [ServerRelaySyncItem]
    var noticePreviewItems: [ServerRelaySyncItem]
    var previewTaskItems: [ServerRelaySyncItem]

    @MainActor
    init(model: CompanionModel) {
        status = model.dashboardStatus
        filePreviewItems = Array(model.cachedVisibleDashboardItems(for: DashboardMetricCategory.files.rawValue).prefix(2))
        noticePreviewItems = Array(model.cachedVisibleDashboardItems(for: DashboardMetricCategory.notices.rawValue).prefix(2))
        previewTaskItems = Array(
            model.cachedVisibleDashboardTaskItems().prefix(2)
        )
    }
}

private struct WorkstationDashboardOverviewPanel: View, Equatable {
    var data: WorkstationDashboardOverviewData
    var showsMetrics = true
    var onOpenCategory: (DashboardMetricCategory) -> Void = { _ in }

    private var status: SanitizedRemoteStatus {
        data.status
    }

    nonisolated static func == (lhs: WorkstationDashboardOverviewPanel, rhs: WorkstationDashboardOverviewPanel) -> Bool {
        lhs.data == rhs.data
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("대시보드")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.klmsPrimaryText)
                    Text("최신 항목을 먼저 보고, 목록 카드에서 바로 처리합니다.")
                        .font(.caption)
                        .foregroundStyle(Color.klmsSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text("최신순")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsPrimaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.klmsSubtleCardBackground, in: Capsule())
                    .overlay(
                        Capsule().stroke(Color.klmsBorder, lineWidth: 1)
                    )
            }

            if showsMetrics {
                if overviewMetrics.isEmpty {
                    Text("표시할 대시보드 항목이 없습니다.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.klmsSecondaryText)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.klmsSubtleCardBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 13))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13)
                                .stroke(Color.klmsBorder.opacity(0.78), lineWidth: 1)
                        )
                } else {
                    LazyVGrid(columns: overviewColumns, alignment: .leading, spacing: 8) {
                        ForEach(overviewMetrics) { metric in
                            Button {
                                onOpenCategory(metric.category)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .center, spacing: 8) {
                                        Image(systemName: metric.systemImage)
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundStyle(metric.tint)
                                            .frame(width: 26, height: 26)
                                            .background(metric.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                        Spacer(minLength: 0)
                                        Text("\(metric.value)")
                                            .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                                            .foregroundStyle(Color.klmsPrimaryText)
                                    }
                                    Text(metric.title)
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color.klmsSecondaryText)
                                        .lineLimit(1)
                                }
                                .padding(11)
                                .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                                .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 13))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 13)
                                        .stroke(Color.klmsBorder, lineWidth: 1)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 13))
                            }
                            .buttonStyle(KLMSCardButtonStyle(cornerRadius: 13))
                            .accessibilityLabel("\(metric.title) \(metric.value)개")
                            .accessibilityHint("\(metric.title) 상세를 엽니다.")
                        }
                    }
                }
            }

            if !filePreviewItems.isEmpty {
                WorkstationDashboardPreviewSection(
                    title: "파일",
                    systemImage: "folder",
                    tint: Color.klmsCommandAccent,
                    category: .files,
                    items: filePreviewItems,
                    emptyMessage: "새로 확인할 파일이 없습니다.",
                    onOpenCategory: onOpenCategory
                )
            }

            if !previewTaskItems.isEmpty {
                WorkstationDashboardPreviewSection(
                    title: "과제/시험",
                    systemImage: "checklist",
                    tint: Color.klmsWarningBorder,
                    category: .assignments,
                    items: previewTaskItems,
                    emptyMessage: "진행 중인 과제나 예정 시험이 없습니다.",
                    onOpenCategory: onOpenCategory
                )
            }

            if !noticePreviewItems.isEmpty {
                WorkstationDashboardPreviewSection(
                    title: "공지",
                    systemImage: "note.text",
                    tint: Color.klmsCommandAccent,
                    category: .notices,
                    items: noticePreviewItems,
                    emptyMessage: "새로 볼 공지가 없습니다.",
                    onOpenCategory: onOpenCategory
                )
            }

            WorkstationChangeSummaryCard(status: data.status)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private var overviewColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 2)
    }

    private var overviewMetrics: [MetricSummary] {
        [
            MetricSummary(category: .files, title: "파일", value: status.fileTotal, systemImage: "folder", tint: Color.klmsCommandAccent),
            MetricSummary(category: .assignments, title: "과제", value: status.assignments, systemImage: "checklist", tint: Color.klmsCommandAccent),
            MetricSummary(category: .notices, title: "공지", value: status.notices, systemImage: "note.text", tint: Color.klmsCommandAccent),
            MetricSummary(category: .exams, title: "시험", value: status.exams, systemImage: "calendar.badge.clock", tint: Color.klmsWarningBorder),
        ].filter { $0.value > 0 }
    }

    private var filePreviewItems: [ServerRelaySyncItem] {
        data.filePreviewItems
    }

    private var noticePreviewItems: [ServerRelaySyncItem] {
        data.noticePreviewItems
    }

    private var previewTaskItems: [ServerRelaySyncItem] {
        data.previewTaskItems
    }

    private struct MetricSummary: Identifiable {
        var category: DashboardMetricCategory
        var title: String
        var value: Int
        var systemImage: String
        var tint: Color

        var id: String {
            title
        }
    }
}

private struct WorkstationDashboardRunSummaryCard: View {
    var status: SanitizedRemoteStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.klmsCommandAccent)
                    .frame(width: 24, height: 24)
                    .background(Color.klmsCommandAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                Text("현재 흐름")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.klmsPrimaryText)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                runSummaryLine("상태", status.phase.klmsRemotePhaseName)
                runSummaryLine("파일", "\(status.fileTotal)개 · 새 파일 \(status.newFiles)개")
                runSummaryLine("일정", "시험 \(status.exams)개 · 과제 \(status.assignments)개")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsSubtleCardBackground.opacity(0.70), in: RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(Color.klmsBorder.opacity(0.78), lineWidth: 1)
        )
    }

    private func runSummaryLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.klmsSecondaryText)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.klmsPrimaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WorkstationDashboardPreviewSection: View {
    var title: String
    var systemImage: String
    var tint: Color
    var category: DashboardMetricCategory
    var items: [ServerRelaySyncItem]
    var emptyMessage: String
    var onOpenCategory: (DashboardMetricCategory) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.klmsPrimaryText)
                Spacer(minLength: 0)
                if !items.isEmpty {
                    Text("\(items.count)개 미리보기")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.klmsSecondaryText)
                }
            }

            if items.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.klmsSubtleCardBackground.opacity(0.74), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.klmsBorder.opacity(0.78), lineWidth: 1)
                    }
            } else {
                ForEach(items) { item in
                    Button {
                        onOpenCategory(category)
                    } label: {
                        ServerSyncDataRow(item: item, isSelected: false)
                            .equatable()
                    }
                    .buttonStyle(KLMSCardButtonStyle())
                    .accessibilityLabel("\(title) \(item.title.nilIfEmpty ?? "항목") 상세 열기")
                    .accessibilityHint("\(title) 상세를 엽니다.")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsSubtleCardBackground.opacity(0.52), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.klmsBorder.opacity(0.78), lineWidth: 1)
        }
    }
}

private struct WorkstationChangeSummaryCard: View {
    var status: SanitizedRemoteStatus

    private var lines: [String] {
        [
            status.noticeNew > 0 ? "새 공지 \(status.noticeNew)개" : nil,
            status.noticeUpdated > 0 ? "수정 공지 \(status.noticeUpdated)개" : nil,
            status.newFiles > 0 ? "새 파일 \(status.newFiles)개" : nil,
            status.calendarChangeTotal > 0 ? "캘린더 변경 \(status.calendarChangeTotal)개" : nil,
        ].compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("변경 요약")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.klmsPrimaryText)
            Text(lines.isEmpty ? "최근 동기화에서 새 변경 사항이 없습니다." : lines.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(Color.klmsSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.klmsBorder, lineWidth: 1)
        )
    }
}

private struct CompactDashboardSelectedRow: View {
    var item: ServerRelaySyncItem
    let model: CompanionModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                companionPerformWithoutAnimation {
                    expanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title.isEmpty ? "제목 없음" : item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.klmsPrimaryText)
                            .lineLimit(2)
                        Text(rowSubtitle)
                            .font(.caption)
                            .foregroundStyle(Color.klmsSecondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(rowBadge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.klmsPrimaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.klmsCardBackground, in: Capsule())
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.klmsSecondaryText)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(KLMSCardButtonStyle())
            .accessibilityLabel("\(rowBadge) \(item.title.nilIfEmpty ?? "제목 없음")")
            .accessibilityValue(expanded ? "펼쳐짐" : "접힘")
            .accessibilityHint("항목 상세와 처리 버튼을 \(expanded ? "접습니다" : "펼칩니다").")

            if expanded {
                DeferredServerSyncItemDetailPanel(item: item, model: model)
            }
        }
    }

    private var rowSubtitle: String {
        [item.course, item.timestamp]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(2)
            .joined(separator: " · ")
    }

    private var rowBadge: String {
        switch item.kind {
        case "file":
            return "파일"
        case "notice":
            return item.isImportant ? "중요" : "공지"
        case "assignment", "completedAssignment", "assignmentCandidate":
            return "과제"
        case "exam", "examCandidate":
            return "시험"
        default:
            return item.kindDisplayName
        }
    }
}

private enum KLMSButtonTone {
    case soft
    case primary
    case destructive
    case success
    case accent(Color)
}

private struct KLMSActionButtonStyle: ButtonStyle {
    var tone: KLMSButtonTone = .soft
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(background(isPressed: configuration.isPressed))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(border(isPressed: configuration.isPressed), lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.96 : 1.0) : 0.54)
    }

    private var foreground: Color {
        switch tone {
        case .soft:
            return Color.klmsSecondaryCommandButtonForeground
        case .primary:
            return Color.klmsPrimaryCommandButtonForeground
        case .destructive:
            return isEnabled ? Color.klmsDangerCommandButtonForeground : Color.klmsSecondaryText.opacity(0.68)
        case .success:
            return Color.klmsSecondaryCommandButtonForeground
        case .accent(let color):
            return color
        }
    }

    private func background(isPressed: Bool) -> AnyShapeStyle {
        switch tone {
        case .soft:
            return AnyShapeStyle(isPressed ? Color.klmsCommandButtonPressedBackground : Color.klmsCommandButtonBackground.opacity(0.90))
        case .primary:
            return AnyShapeStyle(isPressed ? Color.klmsPrimaryCommandButtonPressedBackground : Color.klmsPrimaryCommandButtonBackground)
        case .destructive:
            if !isEnabled {
                return AnyShapeStyle(Color.klmsCommandButtonBackground.opacity(0.42))
            }
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.klmsDangerBorder.opacity(isPressed ? 0.82 : 0.98),
                        Color.klmsDangerBorder.opacity(isPressed ? 0.62 : 0.74),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .success:
            return AnyShapeStyle(isPressed ? Color.klmsSuccessBorder.opacity(0.20) : Color.klmsSuccessBackground)
        case .accent(let color):
            return AnyShapeStyle(color.opacity(isPressed ? 0.18 : 0.10))
        }
    }

    private func border(isPressed: Bool) -> Color {
        switch tone {
        case .soft:
            return Color.klmsCommandButtonBorder.opacity(0.92)
        case .primary:
            return Color.klmsPrimaryCommandButtonBorder.opacity(isPressed ? 0.72 : 1.0)
        case .destructive:
            return isEnabled ? Color.klmsDangerBorder.opacity(isPressed ? 0.92 : 0.84) : Color.klmsCommandButtonBorder.opacity(0.42)
        case .success:
            return Color.klmsSuccessBorder
        case .accent(let color):
            return color.opacity(0.28)
        }
    }
}

private struct KLMSToolbarButtonStyle: ButtonStyle {
    var tone: KLMSButtonTone = .soft
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(background(isPressed: configuration.isPressed))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(border(isPressed: configuration.isPressed), lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.96 : 1.0) : 0.54)
    }

    private var foreground: Color {
        switch tone {
        case .soft:
            return Color.klmsSecondaryCommandButtonForeground
        case .primary, .success:
            return Color.klmsPrimaryCommandButtonForeground
        case .destructive:
            return isEnabled ? Color.klmsDangerCommandButtonForeground : Color.klmsSecondaryText.opacity(0.68)
        case .accent(let color):
            return color
        }
    }

    private func background(isPressed: Bool) -> AnyShapeStyle {
        switch tone {
        case .soft:
            return AnyShapeStyle(isPressed ? Color.klmsCommandButtonPressedBackground : Color.klmsCommandButtonBackground.opacity(0.90))
        case .primary:
            return AnyShapeStyle(isPressed ? Color.klmsPrimaryCommandButtonPressedBackground : Color.klmsPrimaryCommandButtonBackground)
        case .destructive:
            if !isEnabled {
                return AnyShapeStyle(Color.klmsCommandButtonBackground.opacity(0.42))
            }
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.klmsDangerBorder.opacity(isPressed ? 0.82 : 0.98),
                        Color.klmsDangerBorder.opacity(isPressed ? 0.62 : 0.74),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .success:
            return AnyShapeStyle(isPressed ? Color.klmsSuccessBorder.opacity(0.44) : Color.klmsSuccessBackground)
        case .accent(let color):
            return AnyShapeStyle(color.opacity(isPressed ? 0.18 : 0.10))
        }
    }

    private func border(isPressed: Bool) -> Color {
        switch tone {
        case .soft:
            return Color.klmsCommandButtonBorder.opacity(isPressed ? 1.0 : 0.92)
        case .primary:
            return Color.klmsPrimaryCommandButtonBorder.opacity(isPressed ? 0.72 : 1.0)
        case .destructive:
            return isEnabled ? Color.klmsDangerBorder.opacity(isPressed ? 0.92 : 0.84) : Color.klmsCommandButtonBorder.opacity(0.42)
        case .success:
            return Color.klmsSuccessBorder
        case .accent(let color):
            return color.opacity(0.28)
        }
    }
}

private struct DashboardCategoryInlineDetailPanel: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var category: DashboardMetricCategory
    let model: CompanionModel
    var itemPresentation: CompanionInlineItemRowsPresentation
    var externallySelectedItemID: String?
    var onSelectItem: (ServerRelaySyncItem) -> Void
    @State private var query = ""
    @State private var sortOption = CompanionItemSortOption.recent
    @State private var visibilityFilter = CompanionItemVisibilityFilter.visible
    @State private var statusFilter: CompanionItemStatusFilter
    @State private var selectedCourse = CompanionItemListFilter.allCourses
    @State private var selectedYear = CompanionItemListFilter.allYears
    @State private var selectedSemester = CompanionItemListFilter.allSemesters
    @State private var newOnly = false
    @State private var recentOnly = false
    @State private var cachedListData: CompanionItemListData?
    @State private var cachedListInputKey: CompanionItemListInputKey?
    @State private var calendarVisibleLimit = CompanionLargeList.calendarVisibleLimit

    init(
        category: DashboardMetricCategory,
        model: CompanionModel,
        itemPresentation: CompanionInlineItemRowsPresentation = .inlineDetail,
        externallySelectedItemID: String? = nil,
        onSelectItem: @escaping (ServerRelaySyncItem) -> Void = { _ in }
    ) {
        self.category = category
        self.model = model
        self.itemPresentation = itemPresentation
        self.externallySelectedItemID = externallySelectedItemID
        self.onSelectItem = onSelectItem
        _sortOption = State(initialValue: CompanionItemSortOption.defaultSort(for: category))
        _statusFilter = State(initialValue: CompanionItemStatusFilter.defaultFilter(for: category))
    }

    private var status: SanitizedRemoteStatus {
        model.dashboardStatus
    }

    private var calendarChanges: [CalendarChange] {
        model.visibleCalendarChanges()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summaryHeader
            detailContent
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.klmsCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        )
        .task(id: listInputKey) {
            await rebuildCachedListDataAfterInputSettles()
        }
        .onChange(of: calendarChangesResetKey) { _, _ in
            calendarVisibleLimit = currentCalendarVisibleLimit
        }
        .onChange(of: horizontalSizeClass) { _, _ in
            calendarVisibleLimit = currentCalendarVisibleLimit
        }
        .onAppear {
            calendarVisibleLimit = max(calendarVisibleLimit, currentCalendarVisibleLimit)
        }
    }

    private var currentCalendarVisibleLimit: Int {
        CompanionLargeList.calendarVisibleLimit(horizontalSizeClass: horizontalSizeClass)
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
                    .foregroundStyle(Color.klmsPrimaryText)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(Color.klmsSecondaryText)
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

    @ViewBuilder
    private var detailContent: some View {
        if category == .calendar {
            let visibleChanges = calendarChanges.prefix(calendarVisibleLimit)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    DashboardCountPill(title: "생성", value: status.calendarCreated, tint: category.tint)
                    DashboardCountPill(title: "수정", value: status.calendarUpdated, tint: category.tint)
                    DashboardCountPill(title: "삭제", value: status.calendarDeleted, tint: category.tint)
                }
                RemoteCalendarActionPanel()
                if calendarChanges.isEmpty {
                    panelEmptyText("최근 캘린더 변경 상세가 아직 서버에 올라오지 않았습니다.")
                } else {
                    ForEach(visibleChanges) { change in
                        DashboardCalendarChangeDetailRow(
                            change: change,
                            activeAction: model.activeCalendarAction(for: change)
                        ) { action, edit in
                            await model.createCalendarAction(action, change: change, edit: edit)
                        }
                    }
                    if calendarChanges.count > visibleChanges.count {
                        CompanionShowMoreRowsButton(remainingCount: calendarChanges.count - visibleChanges.count) {
                            calendarVisibleLimit += CompanionLargeList.increment
                        }
                    }
                }
            }
        } else if category == .quarantine {
            panelEmptyText(category.emptyMessage)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                CompanionSearchFilterPanel(title: "검색과 필터", fieldPrompt: "\(category.title) 검색", query: $query) {
                    if let listData = cachedListData {
                        DeferredCompanionItemListControls(
                            listData: listData,
                            sortOption: $sortOption,
                            visibilityFilter: $visibilityFilter,
                            statusFilter: $statusFilter,
                            selectedCourse: $selectedCourse,
                            selectedYear: $selectedYear,
                            selectedSemester: $selectedSemester,
                            newOnly: $newOnly,
                            recentOnly: $recentOnly,
                            supportsNewOnly: category.supportsNewOnly,
                            supportsRecentOnly: category.supportsRecentOnly,
                            defaultStatusFilter: CompanionItemStatusFilter.defaultFilter(for: category)
                        )
                    } else {
                        CompanionItemListControlsPlaceholder()
                    }
                }

                if let listData = cachedListData {
                    let filtered = listData.filteredItems
                    if filtered.isEmpty {
                        panelEmptyText(category.emptyMessage)
                    } else {
                        CompanionInlineItemRowsView(
                            category: category,
                            items: filtered,
                            model: model,
                            presentation: itemPresentation,
                            externalSelectedItemID: externallySelectedItemID,
                            onSelectItem: onSelectItem
                        )
                    }
                } else {
                    panelEmptyText("목록을 준비하고 있습니다.")
                }
            }
        }
    }

    private var listInputKey: CompanionItemListInputKey {
        CompanionItemListInputKey(
            itemsRevision: model.dashboardSyncItemsRevision,
            category: category.rawValue,
            query: query,
            sortOption: sortOption.rawValue,
            visibilityFilter: visibilityFilter.rawValue,
            statusFilter: statusFilter.rawValue,
            selectedCourse: selectedCourse,
            selectedYear: selectedYear,
            selectedSemester: selectedSemester,
            newOnly: newOnly,
            recentOnly: recentOnly
        )
    }

    private var calendarChangesResetKey: String {
        "\(calendarChanges.count):\(calendarChanges.first?.id ?? ""):\(calendarChanges.last?.id ?? "")"
    }

    private func rebuildCachedListDataAfterInputSettles() async {
        let currentKey = listInputKey
        if cachedListInputKey == currentKey, cachedListData != nil {
            return
        }
        if let preloadedData = CompanionItemListPreloadStore.cachedData(for: currentKey) {
            cachedListData = preloadedData
            cachedListInputKey = currentKey
            return
        }
        if cachedListData != nil, currentKey.shouldDebounceComparedTo(cachedListInputKey) {
            try? await Task.sleep(nanoseconds: CompanionLargeList.filterRebuildDelayNanoseconds)
            guard !Task.isCancelled, currentKey == listInputKey else { return }
        }
        await rebuildCachedListData(for: currentKey)
    }

    private func rebuildCachedListData(for inputKey: CompanionItemListInputKey) async {
        guard category != .calendar, category != .quarantine else {
            cachedListData = nil
            cachedListInputKey = inputKey
            return
        }
        await Task.yield()
        guard !Task.isCancelled else { return }
        let items = model.cachedDashboardItems(for: category.rawValue)
        let category = category
        let query = query
        let sortOption = sortOption
        let visibilityFilter = visibilityFilter
        let statusFilter = statusFilter
        let selectedCourse = selectedCourse
        let selectedYear = selectedYear
        let selectedSemester = selectedSemester
        let newOnly = newOnly
        let recentOnly = recentOnly
        let filterOptions = model.cachedDashboardFilterOptions(for: category.rawValue)
        let listData = await Task.detached(priority: .userInitiated) {
            CompanionItemListData(
                items: items,
                category: category,
                isCategoryPrefiltered: true,
                query: query,
                sortOption: sortOption,
                visibilityFilter: visibilityFilter,
                statusFilter: statusFilter,
                selectedCourse: selectedCourse,
                selectedYear: selectedYear,
                selectedSemester: selectedSemester,
                newOnly: newOnly,
                recentOnly: recentOnly,
                filterOptions: filterOptions
            )
        }.value
        guard !Task.isCancelled, inputKey == listInputKey else { return }
        CompanionItemListPreloadStore.store(listData, for: inputKey)
        cachedListData = listData
        cachedListInputKey = inputKey
    }

    private var summaryText: String {
        if category == .calendar {
            return "생성 \(status.calendarCreated)개 · 수정 \(status.calendarUpdated)개 · 삭제 \(status.calendarDeleted)개"
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
            .foregroundStyle(Color.klmsSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsSubtleCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func extraCountText(_ count: Int) -> some View {
        Text("외 \(count)개")
            .font(.caption)
            .foregroundStyle(Color.klmsSecondaryText)
            .padding(.horizontal, 2)
    }

}

private struct WorkstationDashboardCategoryWorkspace: View {
    var category: DashboardMetricCategory
    let model: CompanionModel
    @State private var selectedItemID: String?
    @State private var displayedSelectedItem: ServerRelaySyncItem?
    @State private var deferredDetailSelectionTask: Task<Void, Never>?

    private var items: [ServerRelaySyncItem] {
        model.cachedVisibleDashboardItems(for: category.rawValue)
    }

    private var activeSelectedItemID: String? {
        selectedItemID
    }

    private var selectedItem: ServerRelaySyncItem? {
        guard selectedItemID != nil,
              let displayedSelectedItem,
              displayedSelectedItem.id == selectedItemID else {
            return nil
        }
        return displayedSelectedItem
    }

    private var itemsResetKey: String {
        "\(items.count):\(items.first?.id ?? ""):\(items.last?.id ?? "")"
    }

    var body: some View {
        categoryRegularWorkspace
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onAppear {
                refreshExternalSelection()
            }
            .onChange(of: itemsResetKey) { _, _ in
                refreshExternalSelection()
            }
            .onDisappear {
                deferredDetailSelectionTask?.cancel()
            }
    }

    private var categoryRegularWorkspace: some View {
        HStack(alignment: .top, spacing: CompanionWorkstationMetrics.columnSpacing) {
            categoryListPanel
                .frame(
                    minWidth: CompanionWorkstationMetrics.listColumnMinWidth,
                    idealWidth: CompanionWorkstationMetrics.listColumnIdealWidth,
                    maxWidth: CompanionWorkstationMetrics.listColumnMaxWidth,
                    alignment: .topLeading
                )

            categoryDetailPanel
                .frame(
                    minWidth: CompanionWorkstationMetrics.detailColumnMinWidth,
                    idealWidth: CompanionWorkstationMetrics.detailColumnIdealWidth,
                    maxWidth: .infinity,
                    alignment: .topLeading
                )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var categoryListPanel: some View {
        DashboardCategoryInlineDetailPanel(
            category: category,
            model: model,
            itemPresentation: .externalDetail,
            externallySelectedItemID: activeSelectedItemID,
            onSelectItem: selectItem
        )
    }

    private var categoryDetailPanel: some View {
        WorkstationExternalDetailPanel(
            title: "\(category.title) 상세",
            subtitle: "\(items.count)개 항목 · 항목을 선택하면 바로 처리할 수 있습니다.",
            item: selectedItem,
            emptyMessage: "목록에서 항목을 선택해 주세요.",
            model: model
        )
    }

    private func selectItem(_ item: ServerRelaySyncItem) {
        if activeSelectedItemID == item.id {
            return
        }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            selectedItemID = item.id
        }
        deferredDetailSelectionTask?.cancel()
        deferredDetailSelectionTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: CompanionLargeList.detailRenderDelayNanoseconds)
            guard !Task.isCancelled, selectedItemID == item.id else { return }
            displayedSelectedItem = item
        }
    }

    private func refreshExternalSelection() {
        deferredDetailSelectionTask?.cancel()
        if let selectedItemID,
           let refreshed = items.first(where: { $0.id == selectedItemID }) {
            companionPerformWithoutAnimation {
                displayedSelectedItem = refreshed
            }
            return
        }

        guard let first = items.first else {
            companionPerformWithoutAnimation {
                selectedItemID = nil
                displayedSelectedItem = nil
            }
            return
        }

        companionPerformWithoutAnimation {
            selectedItemID = first.id
            displayedSelectedItem = first
        }
    }
}

private struct WorkstationTasksWorkspace: View {
    let model: CompanionModel
    @State private var selectedTaskCategory = DashboardMetricCategory.assignments
    @State private var selectedItemID: String?
    @State private var displayedSelectedItem: ServerRelaySyncItem?
    @State private var deferredDetailSelectionTask: Task<Void, Never>?

    private var taskCategories: [DashboardMetricCategory] {
        var categories: [DashboardMetricCategory] = [.assignments, .exams]
        if DashboardMetricCategory.helpDesk.value(from: model.dashboardStatus) > 0 {
            categories.append(.helpDesk)
        }
        return categories
    }

    private var selectedCategoryItems: [ServerRelaySyncItem] {
        model.cachedVisibleDashboardItems(for: selectedTaskCategory.rawValue)
    }

    private var activeSelectedItemID: String? {
        selectedItemID
    }

    private var selectedItem: ServerRelaySyncItem? {
        guard selectedItemID != nil,
              let displayedSelectedItem,
              displayedSelectedItem.id == selectedItemID else {
            return nil
        }
        return displayedSelectedItem
    }

    private var itemsResetKey: String {
        [
            selectedTaskCategory.rawValue,
            "\(selectedCategoryItems.count)",
            selectedCategoryItems.first?.id ?? "",
            selectedCategoryItems.last?.id ?? "",
        ].joined(separator: ":")
    }

    private var categoryAvailabilityKey: String {
        taskCategories.map(\.rawValue).joined(separator: ":")
    }

    var body: some View {
        tasksRegularWorkspace
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onAppear {
                normalizeSelectedTaskCategory()
                refreshExternalSelection()
            }
            .onChange(of: categoryAvailabilityKey) { _, _ in
                normalizeSelectedTaskCategory()
                refreshExternalSelection()
            }
            .onChange(of: selectedTaskCategory) { _, _ in
                refreshExternalSelection()
            }
            .onChange(of: itemsResetKey) { _, _ in
                refreshExternalSelection()
            }
            .onDisappear {
                deferredDetailSelectionTask?.cancel()
            }
    }

    private var tasksRegularWorkspace: some View {
        HStack(alignment: .top, spacing: CompanionWorkstationMetrics.columnSpacing) {
            tasksListPanel
                .frame(
                    minWidth: CompanionWorkstationMetrics.listColumnMinWidth,
                    idealWidth: CompanionWorkstationMetrics.listColumnIdealWidth,
                    maxWidth: CompanionWorkstationMetrics.listColumnMaxWidth,
                    alignment: .topLeading
                )

            tasksDetailPanel
                .frame(
                    minWidth: CompanionWorkstationMetrics.detailColumnMinWidth,
                    idealWidth: CompanionWorkstationMetrics.detailColumnIdealWidth,
                    maxWidth: .infinity,
                    alignment: .topLeading
                )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var tasksListPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkstationTaskCategorySelector(
                categories: taskCategories,
                status: model.dashboardStatus,
                selectedCategory: $selectedTaskCategory
            )
            taskPanel(selectedTaskCategory)
                .id(selectedTaskCategory.rawValue)
        }
    }

    private var tasksDetailPanel: some View {
        WorkstationExternalDetailPanel(
            title: "선택한 일정",
            subtitle: "과제, 시험, 헬프데스크를 선택한 뒤 바로 처리합니다.",
            item: selectedItem,
            emptyMessage: "목록에서 과제나 시험을 선택해 주세요.",
            model: model
        )
    }

    private func taskPanel(_ category: DashboardMetricCategory) -> some View {
        DashboardCategoryInlineDetailPanel(
            category: category,
            model: model,
            itemPresentation: .externalDetail,
            externallySelectedItemID: activeSelectedItemID,
            onSelectItem: selectItem
        )
    }

    private func selectItem(_ item: ServerRelaySyncItem) {
        if activeSelectedItemID == item.id {
            return
        }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            selectedItemID = item.id
        }
        deferredDetailSelectionTask?.cancel()
        deferredDetailSelectionTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: CompanionLargeList.detailRenderDelayNanoseconds)
            guard !Task.isCancelled, selectedItemID == item.id else { return }
            displayedSelectedItem = item
        }
    }

    private func refreshExternalSelection() {
        deferredDetailSelectionTask?.cancel()
        if let selectedItemID,
           let refreshed = selectedCategoryItems.first(where: { $0.id == selectedItemID }) {
            companionPerformWithoutAnimation {
                displayedSelectedItem = refreshed
            }
            return
        }

        guard let first = selectedCategoryItems.first else {
            companionPerformWithoutAnimation {
                selectedItemID = nil
                displayedSelectedItem = nil
            }
            return
        }

        companionPerformWithoutAnimation {
            selectedItemID = first.id
            displayedSelectedItem = first
        }
    }

    private func normalizeSelectedTaskCategory() {
        guard !taskCategories.contains(selectedTaskCategory),
              let first = taskCategories.first else {
            return
        }
        companionPerformWithoutAnimation {
            selectedTaskCategory = first
        }
    }
}

private struct WorkstationTaskCategorySelector: View {
    var categories: [DashboardMetricCategory]
    var status: SanitizedRemoteStatus
    @Binding var selectedCategory: DashboardMetricCategory

    private let columns = [
        GridItem(.adaptive(minimum: 132), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("작업 종류", systemImage: "square.grid.2x2")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.klmsSecondaryText)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(categories) { category in
                    categoryButton(category)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsSubtleCardBackground.opacity(0.62), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.klmsBorder.opacity(0.78), lineWidth: 1)
        }
    }

    private func categoryButton(_ category: DashboardMetricCategory) -> some View {
        let isSelected = selectedCategory == category
        let value = category.value(from: status)
        return Button {
            guard selectedCategory != category else { return }
            companionPerformWithoutAnimation {
                selectedCategory = category
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: category.systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? Color.klmsSelectedForeground : category.tint)
                    .frame(width: 26, height: 26)
                    .background(
                        isSelected ? Color.klmsSelectedForeground.opacity(0.13) : category.tint.opacity(0.11),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isSelected ? Color.klmsSelectedForeground : Color.klmsPrimaryText)
                        .lineLimit(1)
                    Text("\(value)개")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(isSelected ? Color.klmsSelectedForeground.opacity(0.78) : Color.klmsSecondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                isSelected ? Color.klmsSelectedBackground.opacity(0.96) : Color.klmsCardBackground.opacity(0.82),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.klmsSelectedBorder.opacity(0.92) : Color.klmsBorder.opacity(0.62), lineWidth: isSelected ? 1.2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(KLMSCardButtonStyle(cornerRadius: 10))
        .accessibilityLabel("\(category.title) \(value)개")
        .accessibilityValue(isSelected ? "선택됨" : "")
        .accessibilityHint("\(category.title) 목록을 가운데 작업 영역에 표시합니다.")
    }
}

private struct WorkstationCalendarWorkspace: View {
    let model: CompanionModel
    @State private var selectedChangeID: String?
    @State private var displayedSelectedChange: CalendarChange?
    @State private var deferredDetailSelectionTask: Task<Void, Never>?
    @State private var calendarVisibleLimit = CompanionLargeList.regularCalendarVisibleLimit

    private var changes: [CalendarChange] {
        model.visibleCalendarChanges()
    }

    private var activeSelectedChangeID: String? {
        selectedChangeID
    }

    private var selectedChange: CalendarChange? {
        guard selectedChangeID != nil,
              let displayedSelectedChange,
              displayedSelectedChange.id == selectedChangeID else {
            return nil
        }
        return displayedSelectedChange
    }

    private var changesResetKey: String {
        "\(changes.count):\(changes.first?.id ?? ""):\(changes.last?.id ?? "")"
    }

    var body: some View {
        calendarRegularWorkspace
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onAppear {
                refreshExternalSelection()
            }
            .onChange(of: changesResetKey) { _, _ in
                calendarVisibleLimit = CompanionLargeList.regularCalendarVisibleLimit
                refreshExternalSelection()
            }
            .onDisappear {
                deferredDetailSelectionTask?.cancel()
            }
    }

    private var calendarRegularWorkspace: some View {
        HStack(alignment: .top, spacing: CompanionWorkstationMetrics.columnSpacing) {
            calendarListPanel
                .frame(
                    minWidth: CompanionWorkstationMetrics.listColumnMinWidth,
                    idealWidth: CompanionWorkstationMetrics.listColumnIdealWidth,
                    maxWidth: CompanionWorkstationMetrics.listColumnMaxWidth,
                    alignment: .topLeading
                )

            calendarDetailPanel
                .frame(
                    minWidth: CompanionWorkstationMetrics.detailColumnMinWidth,
                    idealWidth: CompanionWorkstationMetrics.detailColumnIdealWidth,
                    maxWidth: .infinity,
                    alignment: .topLeading
                )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var calendarListPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: DashboardMetricCategory.calendar.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DashboardMetricCategory.calendar.tint)
                    .frame(width: 32, height: 32)
                    .background(DashboardMetricCategory.calendar.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text("캘린더")
                        .font(.headline)
                        .foregroundStyle(Color.klmsPrimaryText)
                    Text("변경된 일정 \(changes.count)개 · 목록에서 고르고 상세 패널에서 처리합니다.")
                        .font(.caption)
                        .foregroundStyle(Color.klmsSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                DashboardCountPill(title: "생성", value: model.dashboardStatus.calendarCreated, tint: DashboardMetricCategory.calendar.tint)
                DashboardCountPill(title: "수정", value: model.dashboardStatus.calendarUpdated, tint: DashboardMetricCategory.calendar.tint)
                DashboardCountPill(title: "삭제", value: model.dashboardStatus.calendarDeleted, tint: DashboardMetricCategory.calendar.tint)
            }

            RemoteCalendarActionPanel()

            if changes.isEmpty {
                Text("최근 캘린더 변경 상세가 아직 서버에 올라오지 않았습니다.")
                    .font(.subheadline)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(changes.prefix(calendarVisibleLimit)) { change in
                        calendarChangeButton(change)
                    }
                }
                if changes.count > calendarVisibleLimit {
                    CompanionShowMoreRowsButton(remainingCount: changes.count - calendarVisibleLimit) {
                        calendarVisibleLimit += CompanionLargeList.increment
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private var calendarDetailPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("캘린더 상세")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.klmsPrimaryText)
                Text("선택한 일정 변경을 등록, 수정, 삭제하거나 Calendar에서 열 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let selectedChange {
                DashboardCalendarChangeDetailRow(
                    change: selectedChange,
                    activeAction: model.activeCalendarAction(for: selectedChange)
                ) { action, edit in
                    await model.createCalendarAction(action, change: selectedChange, edit: edit)
                }
            } else {
                Text("캘린더 변경 목록에서 항목을 선택해 주세요.")
                    .font(.subheadline)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private func calendarChangeButton(_ change: CalendarChange) -> some View {
        let isSelected = activeSelectedChangeID == change.id
        return Button {
            selectChange(change)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Text(change.actionDisplayName)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .foregroundStyle(isSelected ? Color.klmsSelectedForeground : calendarActionTint(change))
                    .background(
                        isSelected
                            ? Color.klmsSelectedForeground.opacity(0.12)
                            : calendarActionTint(change).opacity(0.13),
                        in: Capsule()
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(change.title.nilIfEmpty ?? "제목 없음")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.klmsSelectedForeground : Color.klmsPrimaryText)
                        .lineLimit(2)
                    Text(calendarChangeSubtitle(change))
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.klmsSelectedForeground.opacity(0.76) : Color.klmsSecondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.klmsSelectedForeground : Color.klmsSecondaryText.opacity(0.76))
                    .padding(.top, 2)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(isSelected ? Color.klmsSelectedBackground.opacity(0.96) : Color.klmsSubtleCardBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.klmsSelectedBorder.opacity(0.92) : Color.klmsBorder.opacity(0.74), lineWidth: isSelected ? 1.2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(KLMSCardButtonStyle(cornerRadius: 10))
        .accessibilityLabel("\(change.title.nilIfBlank ?? "캘린더 변경") \(change.actionDisplayName)")
        .accessibilityHint("상세 패널에 일정 상세와 처리 버튼을 표시합니다.")
    }

    private func calendarActionTint(_ change: CalendarChange) -> Color {
        switch change.action {
        case "created", "mail":
            Color.klmsSuccessBorder
        case "updated":
            Color.klmsCommandAccent
        case "deleted":
            Color.klmsDangerBorder
        default:
            Color.klmsSecondaryText
        }
    }

    private func calendarChangeSubtitle(_ change: CalendarChange) -> String {
        let dateText = change.startAt.nilIfBlank ?? change.dueAt.nilIfBlank
        return [change.course.nilIfBlank, change.calendar.nilIfBlank, dateText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func selectChange(_ change: CalendarChange) {
        if activeSelectedChangeID == change.id {
            return
        }
        companionPerformWithoutAnimation {
            selectedChangeID = change.id
        }
        deferredDetailSelectionTask?.cancel()
        deferredDetailSelectionTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: CompanionLargeList.detailRenderDelayNanoseconds)
            guard !Task.isCancelled, selectedChangeID == change.id else { return }
            displayedSelectedChange = change
        }
    }

    private func refreshExternalSelection() {
        deferredDetailSelectionTask?.cancel()
        if let selectedChangeID,
           let refreshed = changes.first(where: { $0.id == selectedChangeID }) {
            companionPerformWithoutAnimation {
                displayedSelectedChange = refreshed
            }
            return
        }

        guard let first = changes.first else {
            companionPerformWithoutAnimation {
                selectedChangeID = nil
                displayedSelectedChange = nil
            }
            return
        }

        companionPerformWithoutAnimation {
            selectedChangeID = first.id
            displayedSelectedChange = first
        }
    }
}

private struct WorkstationExternalDetailPanel: View {
    var title: String
    var subtitle: String
    var item: ServerRelaySyncItem?
    var emptyMessage: String
    let model: CompanionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.klmsPrimaryText)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let item {
                DeferredServerSyncItemDetailPanel(item: item, model: model)
            } else {
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        )
    }
}

private enum CompanionInlineItemRowsPresentation {
    case inlineDetail
    case externalDetail
}

private struct CompanionInlineItemRowsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var category: DashboardMetricCategory
    var items: [ServerRelaySyncItem]
    let model: CompanionModel
    var presentation: CompanionInlineItemRowsPresentation
    var externalSelectedItemID: String?
    var onSelectItem: (ServerRelaySyncItem) -> Void
    @State private var selectedItemID: String?
    @State private var optimisticExternalSelectedItemID: String?
    @State private var visibleLimit = CompanionLargeList.initialVisibleLimit
    @State private var deferredExternalSelectionTask: Task<Void, Never>?

    init(
        category: DashboardMetricCategory,
        items: [ServerRelaySyncItem],
        model: CompanionModel,
        presentation: CompanionInlineItemRowsPresentation = .inlineDetail,
        externalSelectedItemID: String? = nil,
        onSelectItem: @escaping (ServerRelaySyncItem) -> Void = { _ in }
    ) {
        self.category = category
        self.items = items
        self.model = model
        self.presentation = presentation
        self.externalSelectedItemID = externalSelectedItemID
        self.onSelectItem = onSelectItem
    }

    var body: some View {
        let visibleItems = items.prefix(visibleLimit)
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(visibleItems) { item in
                let isSelected = activeSelectedItemID == item.id
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        select(item)
                    } label: {
                        ServerSyncDataRow(
                            item: item,
                            isSelected: isSelected,
                            accessorySystemImage: accessorySystemImage(isSelected: isSelected)
                        )
                        .equatable()
                    }
                    .buttonStyle(KLMSCardButtonStyle())
                    .accessibilityValue(isSelected ? "선택됨" : "")
                    .accessibilityHint(presentation == .inlineDetail ? "항목 상세를 같은 화면에서 펼칩니다." : "상세 패널에 항목을 표시합니다.")

                    if presentation == .inlineDetail && selectedItemID == item.id {
                        DeferredServerSyncItemDetailPanel(item: item, model: model)
                    }
                }
            }
            if items.count > visibleItems.count {
                CompanionShowMoreRowsButton(
                    remainingCount: items.count - visibleItems.count
                ) {
                    visibleLimit += CompanionLargeList.increment
                }
            }
        }
        .onChange(of: visibleItemsResetKey) { _, _ in
            visibleLimit = currentInitialVisibleLimit
            clearStaleInlineSelectionIfNeeded()
            clearStaleExternalSelectionIfNeeded()
        }
        .onChange(of: horizontalSizeClass) { _, _ in
            visibleLimit = currentInitialVisibleLimit
        }
        .onChange(of: externalSelectedItemID) { _, newValue in
            guard presentation == .externalDetail else { return }
            optimisticExternalSelectedItemID = newValue
        }
        .onAppear {
            visibleLimit = max(visibleLimit, currentInitialVisibleLimit)
        }
        .onDisappear {
            deferredExternalSelectionTask?.cancel()
        }
    }

    private var activeSelectedItemID: String? {
        presentation == .externalDetail ? (optimisticExternalSelectedItemID ?? externalSelectedItemID) : selectedItemID
    }

    private var currentInitialVisibleLimit: Int {
        CompanionLargeList.initialVisibleLimit(horizontalSizeClass: horizontalSizeClass)
    }

    private var visibleItemsResetKey: String {
        "\(items.count):\(items.first?.id ?? ""):\(items.last?.id ?? "")"
    }

    private func accessorySystemImage(isSelected: Bool) -> String {
        switch presentation {
        case .inlineDetail:
            return isSelected ? "chevron.up" : "chevron.down"
        case .externalDetail:
            return isSelected ? "checkmark.circle.fill" : "chevron.right"
        }
    }

    private func select(_ item: ServerRelaySyncItem) {
        if presentation == .externalDetail {
            let itemID = item.id
            deferredExternalSelectionTask?.cancel()
            companionPerformWithoutAnimation {
                optimisticExternalSelectedItemID = itemID
            }
            deferredExternalSelectionTask = Task { @MainActor in
                await Task.yield()
                try? await Task.sleep(nanoseconds: CompanionLargeList.detailRenderDelayNanoseconds)
                guard !Task.isCancelled,
                      (optimisticExternalSelectedItemID ?? externalSelectedItemID) == itemID else {
                    return
                }
                onSelectItem(item)
            }
            return
        }

        let nextID = selectedItemID == item.id ? nil : item.id
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            selectedItemID = nextID
        }
    }

    private func clearStaleInlineSelectionIfNeeded() {
        guard let selectedItemID,
              !items.contains(where: { $0.id == selectedItemID }) else {
            return
        }
        self.selectedItemID = nil
    }

    private func clearStaleExternalSelectionIfNeeded() {
        guard presentation == .externalDetail,
              let optimisticExternalSelectedItemID,
              !items.contains(where: { $0.id == optimisticExternalSelectedItemID }) else {
            return
        }
        self.optimisticExternalSelectedItemID = externalSelectedItemID
    }

}

private struct CompanionSelectableItemListRows: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var items: [ServerRelaySyncItem]
    var onSelect: (ServerRelaySyncItem) -> Void
    @State private var selectedItemID: String?
    @State private var visibleLimit = CompanionLargeList.initialVisibleLimit
    @State private var deferredSelectionTask: Task<Void, Never>?

    init(
        items: [ServerRelaySyncItem],
        onSelect: @escaping (ServerRelaySyncItem) -> Void
    ) {
        self.items = items
        self.onSelect = onSelect
    }

    var body: some View {
        let visibleItems = items.prefix(visibleLimit)
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(visibleItems) { item in
                Button {
                    select(item)
                } label: {
                    ServerSyncDataRow(item: item, isSelected: selectedItemID == item.id)
                        .equatable()
                }
                .buttonStyle(KLMSCardButtonStyle())
                .accessibilityValue(selectedItemID == item.id ? "선택됨" : "")
                .accessibilityHint("항목 상세를 엽니다.")
            }
            if items.count > visibleItems.count {
                CompanionShowMoreRowsButton(
                    remainingCount: items.count - visibleItems.count
                ) {
                    visibleLimit += CompanionLargeList.increment
                }
            }
        }
        .onChange(of: visibleItemsResetKey) { _, _ in
            visibleLimit = currentInitialVisibleLimit
            deferredSelectionTask?.cancel()
        }
        .onChange(of: horizontalSizeClass) { _, _ in
            visibleLimit = currentInitialVisibleLimit
        }
        .onAppear {
            visibleLimit = max(visibleLimit, currentInitialVisibleLimit)
        }
        .onDisappear {
            deferredSelectionTask?.cancel()
        }
    }

    private var currentInitialVisibleLimit: Int {
        CompanionLargeList.initialVisibleLimit(horizontalSizeClass: horizontalSizeClass)
    }

    private var visibleItemsResetKey: String {
        "\(items.count):\(items.first?.id ?? ""):\(items.last?.id ?? "")"
    }

    private func select(_ item: ServerRelaySyncItem) {
        let itemID = item.id
        deferredSelectionTask?.cancel()
        companionPerformWithoutAnimation {
            selectedItemID = item.id
        }
        deferredSelectionTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: CompanionLargeList.detailRenderDelayNanoseconds)
            guard !Task.isCancelled, selectedItemID == itemID else { return }
            onSelect(item)
        }
    }

}

private struct CompanionShowMoreRowsButton: View {
    var remainingCount: Int
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down.circle")
                    .font(.subheadline.weight(.semibold))
                Text("더 보기")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(remainingCount)개 남음")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.klmsSecondaryText)
            }
            .foregroundStyle(Color.klmsPrimaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.klmsBorder, lineWidth: 1)
            }
        }
        .buttonStyle(KLMSCardButtonStyle())
        .accessibilityLabel("항목 더 보기")
        .accessibilityValue("\(remainingCount)개 남음")
    }
}

private struct RemoteChangeSummaryDetailPanel: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var kind: RemoteChangeSummaryKind
    var status: SanitizedRemoteStatus
    var changedItems: [ServerRelaySyncItem]
    var changedCalendarItems: [CalendarChange]
    var fileCleanupReports: [DryRunReport]
    let model: CompanionModel
    @State private var selectedItemID: String?
    @State private var visibleItemLimit = CompanionLargeList.initialVisibleLimit
    @State private var calendarVisibleLimit = CompanionLargeList.calendarVisibleLimit
    @State private var cleanupVisibleLimit = CompanionLargeList.previewVisibleLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            detailContent
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.klmsCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        )
        .onChange(of: visibleContentResetKey) { _, _ in
            resetVisibleLimits()
        }
        .onChange(of: horizontalSizeClass) { _, _ in
            resetVisibleLimits()
        }
        .onAppear {
            visibleItemLimit = max(visibleItemLimit, currentInitialVisibleLimit)
            calendarVisibleLimit = max(calendarVisibleLimit, currentCalendarVisibleLimit)
            cleanupVisibleLimit = max(cleanupVisibleLimit, currentPreviewVisibleLimit)
        }
    }

    private var currentInitialVisibleLimit: Int {
        CompanionLargeList.initialVisibleLimit(horizontalSizeClass: horizontalSizeClass)
    }

    private var currentCalendarVisibleLimit: Int {
        CompanionLargeList.calendarVisibleLimit(horizontalSizeClass: horizontalSizeClass)
    }

    private var currentPreviewVisibleLimit: Int {
        CompanionLargeList.previewVisibleLimit(horizontalSizeClass: horizontalSizeClass)
    }

    private func resetVisibleLimits() {
        selectedItemID = nil
        visibleItemLimit = currentInitialVisibleLimit
        calendarVisibleLimit = currentCalendarVisibleLimit
        cleanupVisibleLimit = currentPreviewVisibleLimit
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(kind.tint)
                .frame(width: 32, height: 32)
                .background(kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.detailTitle)
                    .font(.headline)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(Color.klmsSecondaryText)
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
                .stroke(Color.klmsBorder.opacity(0.95), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        if kind.isCalendarChange {
            if changedCalendarItems.isEmpty {
                emptyState
            } else {
                let visibleCalendarItems = changedCalendarItems.prefix(calendarVisibleLimit)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleCalendarItems) { change in
                        DashboardCalendarChangeDetailRow(
                            change: change,
                            activeAction: model.activeCalendarAction(for: change)
                        ) { action, edit in
                            await model.createCalendarAction(action, change: change, edit: edit)
                        }
                    }
                    if changedCalendarItems.count > visibleCalendarItems.count {
                        CompanionShowMoreRowsButton(remainingCount: changedCalendarItems.count - visibleCalendarItems.count) {
                            calendarVisibleLimit += CompanionLargeList.increment
                        }
                    }
                }
            }
        } else if kind == .fileCleanup {
            fileCleanupContent
        } else if changedItems.isEmpty {
            emptyState
        } else {
            let visibleChangedItems = changedItems.prefix(visibleItemLimit)
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(visibleChangedItems) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            companionPerformWithoutAnimation {
                                selectedItemID = selectedItemID == item.id ? nil : item.id
                            }
                        } label: {
                            ServerSyncDataRow(
                                item: item,
                                isSelected: selectedItemID == item.id,
                                accessorySystemImage: selectedItemID == item.id ? "chevron.up" : "chevron.down"
                            )
                            .equatable()
                        }
                        .buttonStyle(KLMSCardButtonStyle())

                        if selectedItemID == item.id {
                            DeferredServerSyncItemDetailPanel(item: item, model: model)
                        }
                    }
                }
                if changedItems.count > visibleChangedItems.count {
                    CompanionShowMoreRowsButton(remainingCount: changedItems.count - visibleChangedItems.count) {
                        visibleItemLimit += CompanionLargeList.increment
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var fileCleanupContent: some View {
        let cleanupTotal = status.fileCleanupTotal
        if cleanupTotal <= 0 && fileCleanupReports.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    DashboardCountPill(title: "정리", value: status.filePruned, tint: kind.tint)
                    DashboardCountPill(title: "보관 정리", value: status.fileArchivePruned, tint: kind.tint)
                }
                if fileCleanupReports.isEmpty {
                    Text("정리된 파일 수는 확인됐지만 상세 미리보기 리포트는 없습니다. 실제 삭제/정리 내역은 Mac의 파일 로그에서 확인할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(Color.klmsSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    let visibleReports = fileCleanupReports.prefix(cleanupVisibleLimit)
                    ForEach(visibleReports, id: \.scope) { report in
                        RemoteDryRunReportRow(report: report)
                    }
                    if fileCleanupReports.count > visibleReports.count {
                        CompanionShowMoreRowsButton(remainingCount: fileCleanupReports.count - visibleReports.count) {
                            cleanupVisibleLimit += CompanionLargeList.increment
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        Text(kind.emptyMessage)
            .font(.subheadline)
            .foregroundStyle(Color.klmsSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private var summaryText: String {
        let count = kind.value(from: status)
        switch kind {
        case .noticeNew, .noticeUpdated, .newFiles:
            return "\(count)개 · 항목을 누르면 세부 정보와 상태 변경 버튼이 열립니다."
        case .fileCleanup:
            return "\(count)개 · 정리된 파일과 보관 정리 결과를 확인합니다."
        case .calendarCreated, .calendarUpdated, .calendarDeleted:
            return "\(count)개 · 일정 내용을 확인하고 필요하면 바로 수정할 수 있습니다."
        }
    }

    private var visibleContentResetKey: String {
        [
            kind.rawValue,
            "\(changedItems.count)",
            changedItems.first?.id ?? "",
            changedItems.last?.id ?? "",
            "\(changedCalendarItems.count)",
            changedCalendarItems.first?.id ?? "",
            changedCalendarItems.last?.id ?? "",
            "\(fileCleanupReports.count)",
        ].joined(separator: ":")
    }
}

private struct MailPasteAnalyzerPanel: View {
    @ObservedObject var model: CompanionModel
    @State private var isExpanded = false
    @State private var mailText = ""
    @State private var analysis = MailPasteAnalysis.empty
    @State private var deferredAnalysisTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                companionPerformWithoutAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("메일·캘린더 분석")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.klmsPrimaryText)
                        Text(isExpanded ? "메일 본문에서 과제·시험·일정을 찾습니다." : "메일 본문 붙여넣기")
                            .font(.caption2)
                            .foregroundStyle(Color.klmsSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if !analysis.isEmpty {
                        Text(analysis.kind.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(analysis.kind.tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(analysis.kind.tint.opacity(0.12), in: Capsule())
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.klmsSecondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.klmsCommandButtonBackground.opacity(colorScheme == .dark ? 0.82 : 0.92), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.klmsCommandButtonBorder.opacity(colorScheme == .dark ? 0.72 : 0.92), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(KLMSCardButtonStyle())
            .accessibilityHint(isExpanded ? "메일 판독 입력 접기" : "메일 판독 입력 펼치기")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    MailPasteInputBox(mailText: $mailText)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                        Button {
                            pasteFromClipboard()
                        } label: {
                            Label("클립보드 붙여넣기", systemImage: "doc.on.clipboard")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(KLMSActionButtonStyle())

                        Button {
                            runAnalysis()
                        } label: {
                            Label("판독하기", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(KLMSActionButtonStyle())
                        .disabled(mailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button {
                            mailText = ""
                            analysis = .empty
                        } label: {
                            Label("입력 비우기", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(KLMSActionButtonStyle())
                        .disabled(mailText.isEmpty)
                    }
                    .font(.caption.weight(.semibold))

                    MailPasteAnalysisResultView(analysis: analysis, model: model)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        )
        .onChange(of: mailText) { _, _ in
            scheduleAnalysis()
        }
        .onChange(of: model.dashboardSyncItemsRevision) { _, _ in
            scheduleAnalysis()
        }
        .onDisappear {
            deferredAnalysisTask?.cancel()
        }
    }

    private func pasteFromClipboard() {
        #if canImport(UIKit)
        if let clipboardText = UIPasteboard.general.string {
            mailText = clipboardText
            isExpanded = true
            runAnalysis()
        }
        #endif
    }

    private func runAnalysis() {
        deferredAnalysisTask?.cancel()
        analysis = MailPasteAnalyzer.analyze(mailText, syncItems: model.dashboardSyncItems)
    }

    private func scheduleAnalysis() {
        deferredAnalysisTask?.cancel()
        let text = mailText
        let items = model.dashboardSyncItems
        deferredAnalysisTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            analysis = MailPasteAnalyzer.analyze(text, syncItems: items)
        }
    }
}

private struct MailPasteInputBox: View {
    @Binding var mailText: String
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        companionMailThemeAccent(for: colorScheme)
    }

    private var trimmedText: String {
        mailText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var lineCount: Int {
        let lines = trimmedText.split(whereSeparator: \.isNewline)
        return lines.isEmpty ? 0 : lines.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "text.badge.checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(accent.opacity(colorScheme == .dark ? 0.22 : 0.13), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text("메일 원문 붙여넣기")
                        .font(.subheadline.weight(.semibold))
                    Text("메일 본문, LMS 외부 공지, 캘린더 안내문을 그대로 붙여넣으면 이 기기 안에서만 판독합니다. 원문은 저장하지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(Color.klmsSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("1단계")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accent.opacity(colorScheme == .dark ? 0.18 : 0.11), in: Capsule())
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $mailText)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 144)
                    .padding(8)
                    .background(accent.opacity(colorScheme == .dark ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(accent.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 1)
                    )
                if mailText.isEmpty {
                    Text("예: 시험 일정, 과제 마감, 첨부파일 안내가 들어 있는 메일 본문")
                        .font(.callout)
                        .foregroundStyle(Color.klmsPrimaryText.opacity(0.48))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 8) {
                Label(trimmedText.isEmpty ? "입력 대기" : "\(lineCount)줄 · \(trimmedText.count)자", systemImage: trimmedText.isEmpty ? "square.and.pencil" : "doc.text.magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(trimmedText.isEmpty ? Color.klmsSecondaryText : accent)
                Spacer(minLength: 0)
                Label("원문은 서버로 보내지 않음", systemImage: "lock.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsSecondaryText)
            }
        }
        .padding(12)
        .background(accent.opacity(colorScheme == .dark ? 0.08 : 0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent.opacity(colorScheme == .dark ? 0.22 : 0.20), lineWidth: 1)
        )
    }
}

private func companionMailThemeAccent(for colorScheme: ColorScheme) -> Color {
    Color.klmsCommandAccent
}

private struct MailPasteAnalysisResultView: View {
    var analysis: MailPasteAnalysis
    @ObservedObject var model: CompanionModel
    @State private var selectedItemID: String?
    @State private var isShowingCreateSheet = false
    @State private var dashboardEditItem: ServerRelaySyncItem?

    var body: some View {
        if analysis.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("판독 결과", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                Text("메일 원문을 붙여넣고 `판독하기`를 누르면 분류, 과목, 일정, 대시보드 반영 후보를 여기에서 확인합니다.")
                    .font(.caption)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.klmsBorder, lineWidth: 1)
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("판독 결과", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Text("2단계")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(analysis.kind.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(analysis.kind.tint.opacity(0.12), in: Capsule())
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: analysis.kind.systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(analysis.kind.tint)
                        .frame(width: 30, height: 30)
                        .background(analysis.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(analysis.title.nilIfEmpty ?? "제목을 찾지 못했습니다.")
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(analysis.summary)
                            .font(.caption)
                            .foregroundStyle(Color.klmsSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 106), spacing: 8)], alignment: .leading, spacing: 8) {
                    MailAnalysisPill(title: "분류", value: analysis.kind.title, tint: analysis.kind.tint)
                    MailAnalysisPill(title: "과목", value: analysis.course.nilIfEmpty ?? "미확인", tint: Color.klmsCommandAccent)
                    MailAnalysisPill(title: "일정", value: analysis.dueText.nilIfEmpty ?? "미확인", tint: Color.klmsWarningBorder)
                    MailAnalysisPill(title: "신뢰도", value: "\(analysis.confidence)%", tint: analysis.confidence >= 70 ? Color.klmsSuccessBorder : Color.klmsWarningBorder)
                }

                MailAnalysisProcessView(steps: analysis.analysisSteps)

                if !analysis.detectedTargets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("처리 대상")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.klmsSecondaryText)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 106), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(analysis.detectedTargets, id: \.self) { target in
                                MailAnalysisPill(title: "판독", value: target, tint: analysis.kind.tint)
                            }
                        }
                    }
                }

                if !analysis.urls.isEmpty {
                    Text("본문 링크 \(analysis.urls.count)개를 감지했습니다.")
                        .font(.caption)
                        .foregroundStyle(Color.klmsSecondaryText)
                }

                if analysis.matchedItems.isEmpty {
                    MailActionPlanView(lines: analysis.actionPlan)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("관련 KLMS 항목")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.klmsSecondaryText)
                        ForEach(Array(analysis.matchedItems.prefix(5))) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    companionPerformWithoutAnimation {
                                        selectedItemID = selectedItemID == item.id ? nil : item.id
                                    }
                                } label: {
                                    ServerSyncDataRow(
                                        item: item,
                                        isSelected: selectedItemID == item.id,
                                        accessorySystemImage: selectedItemID == item.id ? "chevron.up" : "chevron.down"
                                    )
                                    .equatable()
                                }
                                .buttonStyle(KLMSCardButtonStyle())

                                if selectedItemID == item.id {
                                    DeferredServerSyncItemDetailPanel(item: item, model: model)
                                }
                            }
                        }
                    }
                }

                if !analysis.actionPlan.isEmpty, !analysis.matchedItems.isEmpty {
                    MailActionPlanView(lines: analysis.actionPlan)
                }

                if analysis.canCreateCalendarEvent {
                    Button {
                        isShowingCreateSheet = true
                    } label: {
                        Label("Mac 캘린더에 등록", systemImage: "calendar.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(KLMSActionButtonStyle(tone: .success))
                    .disabled(model.isSubmitting)
                }

                if let dashboardItem = analysis.dashboardItem {
                    let registeredItem = model.mailDashboardItems.first { $0.id == dashboardItem.id }
                    let editableItem = registeredItem ?? dashboardItem
                    if registeredItem != nil {
                        HStack(spacing: 8) {
                            Label("대시보드 등록됨", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.klmsSuccessBorder)
                            Spacer(minLength: 0)
                            Button {
                                dashboardEditItem = editableItem
                            } label: {
                                Label("수정", systemImage: "pencil")
                            }
                            .buttonStyle(KLMSActionButtonStyle())
                            .disabled(model.isSubmitting)
                            Button(role: .destructive) {
                                Task {
                                    await model.submitRemoveMailDashboardItem(editableItem)
                                }
                            } label: {
                                Label("제거", systemImage: "minus.circle")
                            }
                            .buttonStyle(KLMSActionButtonStyle(tone: .destructive))
                            .disabled(model.isSubmitting)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Button {
                                dashboardEditItem = editableItem
                            } label: {
                                Label("수정", systemImage: "pencil")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(KLMSActionButtonStyle())
                            .disabled(model.isSubmitting)
                            Button {
                                Task {
                                    await model.submitMailDashboardItem(dashboardItem)
                                }
                            } label: {
                                Label("등록", systemImage: "plus.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(KLMSActionButtonStyle(tone: .accent(analysis.kind.tint)))
                            .disabled(model.isSubmitting)
                        }
                    }
                }
            }
            .padding(12)
            .background(analysis.kind.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(analysis.kind.tint.opacity(0.22), lineWidth: 1)
            )
            .sheet(isPresented: $isShowingCreateSheet) {
                MailCalendarCreateForm(analysis: analysis) { edit in
                    Task {
                        await model.createManualCalendarAction(title: analysis.calendarTitle, edit: edit)
                    }
                }
            }
            .sheet(item: $dashboardEditItem) { item in
                MailDashboardItemEditForm(item: item) { edited in
                    Task {
                        await model.submitMailDashboardItem(edited)
                    }
                }
            }
        }
    }
}

private struct MailCalendarCreateForm: View {
    var analysis: MailPasteAnalysis
    var onSave: (CalendarEventEdit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var startAt: String
    @State private var dueAt: String
    @State private var location: String

    init(analysis: MailPasteAnalysis, onSave: @escaping (CalendarEventEdit) -> Void) {
        self.analysis = analysis
        self.onSave = onSave
        _title = State(initialValue: analysis.calendarTitle)
        _startAt = State(initialValue: analysis.calendarStartInput)
        _dueAt = State(initialValue: analysis.calendarEndInput)
        _location = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("제목", text: $title)
                    TextField("시작 시간", text: $startAt)
                    TextField("종료 시간", text: $dueAt)
                    TextField("장소", text: $location)
                } header: {
                    Text("캘린더 일정")
                } footer: {
                    Text("Mac 앱이 Apple Calendar에 새 일정을 등록합니다. 시간은 2026-06-17 13:00 형식으로 확인해 주세요.")
                }
            }
            .navigationTitle("메일 일정 등록")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        dismiss()
                    }
                    .buttonStyle(KLMSToolbarButtonStyle())
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("등록") {
                        onSave(CalendarEventEdit(title: title, startAt: startAt, dueAt: dueAt, location: location))
                        dismiss()
                    }
                    .buttonStyle(KLMSToolbarButtonStyle(tone: .success))
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || startAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct MailDashboardItemEditForm: View {
    var item: ServerRelaySyncItem
    var onSave: (ServerRelaySyncItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: String
    @State private var title: String
    @State private var course: String
    @State private var timestamp: String
    @State private var detail: String
    @State private var attachmentCount: String

    private static let kindOptions = ["assignment", "exam", "notice", "file", "assignmentCandidate", "examCandidate"]

    init(item: ServerRelaySyncItem, onSave: @escaping (ServerRelaySyncItem) -> Void) {
        self.item = item
        self.onSave = onSave
        _kind = State(initialValue: Self.kindOptions.contains(item.kind) ? item.kind : "notice")
        _title = State(initialValue: item.title)
        _course = State(initialValue: item.course)
        _timestamp = State(initialValue: item.timestamp)
        _detail = State(initialValue: item.detail)
        _attachmentCount = State(initialValue: String(item.attachmentCount))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("분류", selection: $kind) {
                        ForEach(Self.kindOptions, id: \.self) { value in
                            Text(value.klmsMailDashboardKindName).tag(value)
                        }
                    }
                    TextField("제목", text: $title)
                    TextField("과목", text: $course)
                    TextField("일시", text: $timestamp)
                    TextField("설명", text: $detail, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("첨부/링크 수", text: $attachmentCount)
                } header: {
                    Text("대시보드 항목")
                } footer: {
                    Text("붙여넣은 내용을 대시보드에 반영할 형태로 정리합니다. 원문은 저장하지 않습니다.")
                }
            }
            .navigationTitle("대시보드 항목 수정")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        dismiss()
                    }
                    .buttonStyle(KLMSToolbarButtonStyle())
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        onSave(editedItem)
                        dismiss()
                    }
                    .buttonStyle(KLMSToolbarButtonStyle(tone: .primary))
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var editedItem: ServerRelaySyncItem {
        let count = max(0, Int(attachmentCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? item.attachmentCount)
        return ServerRelaySyncItem(
            id: item.id,
            kind: kind,
            course: course.trimmingCharacters(in: .whitespacesAndNewlines),
            academicTerm: item.academicTerm,
            academicYear: item.academicYear,
            academicSemester: item.academicSemester,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            timestamp: timestamp.trimmingCharacters(in: .whitespacesAndNewlines),
            status: "추가됨",
            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "추가로 반영한 항목입니다.",
            attachmentCount: count,
            updatedAt: ServerRelaySyncItem.isoTimestamp(),
            isRead: item.isRead,
            isImportant: item.isImportant,
            isHidden: item.isHidden
        )
    }
}

private struct MailAnalysisPill: View {
    var title: String
    var value: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.klmsSecondaryText)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

private enum MailAnalysisStepTone: String, Equatable {
    case secondary
    case orange
    case green
    case teal
    case blue
    case brown
    case purple

    var color: Color {
        switch self {
        case .secondary:
            Color.klmsSecondaryText
        case .orange:
            Color.klmsWarningBorder
        case .green:
            Color.klmsSuccessBorder
        case .teal:
            Color.klmsCommandAccent
        case .blue:
            Color.klmsSecondaryText
        case .brown:
            Color.klmsCommandAccent
        case .purple:
            Color.klmsCommandAccent
        }
    }
}

private struct MailAnalysisStep: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var systemImage: String
    var tone: MailAnalysisStepTone
}

private struct MailAnalysisProcessView: View {
    var steps: [MailAnalysisStep]

    var body: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Label("분석 과정", systemImage: "list.bullet.clipboard")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Text("\(steps.count)단계")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.klmsSecondaryText)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: step.systemImage)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(step.tone.color)
                                .frame(width: 22, height: 22)
                                .background(step.tone.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title)
                                    .font(.caption.weight(.semibold))
                                Text(step.detail)
                                    .font(.caption)
                                    .foregroundStyle(Color.klmsSecondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(10)
            .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.klmsBorder, lineWidth: 1)
            )
        }
    }
}

private struct MailActionPlanView: View {
    var lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("추천 처리")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.klmsSecondaryText)
            ForEach(lines, id: \.self) { line in
                Label(line, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

private enum MailPasteDetectedKind: String {
    case none
    case assignment
    case exam
    case notice
    case file

    var title: String {
        switch self {
        case .none:
            "미분류"
        case .assignment:
            "과제 후보"
        case .exam:
            "시험 후보"
        case .notice:
            "공지 후보"
        case .file:
            "파일 후보"
        }
    }

    var systemImage: String {
        switch self {
        case .none:
            "questionmark.circle"
        case .assignment:
            "checklist"
        case .exam:
            "calendar"
        case .notice:
            "note.text"
        case .file:
            "doc"
        }
    }

    var tint: Color {
        switch self {
        case .none:
            Color.klmsSecondaryText
        case .assignment:
            Color.klmsWarningBorder
        case .exam:
            Color.klmsSuccessBorder
        case .notice:
            Color.klmsCommandAccent
        case .file:
            Color.klmsSecondaryText
        }
    }

    var dashboardKind: String? {
        switch self {
        case .assignment:
            "assignment"
        case .exam:
            "exam"
        case .notice:
            "notice"
        case .file:
            "file"
        case .none:
            nil
        }
    }
}

private struct MailPasteAnalysis: Equatable {
    var kind: MailPasteDetectedKind
    var title: String
    var course: String
    var dueText: String
    var urls: [String]
    var confidence: Int
    var matchedItems: [ServerRelaySyncItem]
    var suggestedAction: String
    var calendarStartInput: String
    var calendarEndInput: String
    var analysisSteps: [MailAnalysisStep]

    static let empty = MailPasteAnalysis(
        kind: .none,
        title: "",
        course: "",
        dueText: "",
        urls: [],
        confidence: 0,
        matchedItems: [],
        suggestedAction: "",
        calendarStartInput: "",
        calendarEndInput: "",
        analysisSteps: []
    )

    var isEmpty: Bool {
        kind == .none
            && title.isEmpty
            && course.isEmpty
            && dueText.isEmpty
            && urls.isEmpty
            && matchedItems.isEmpty
    }

    var summary: String {
        if !matchedItems.isEmpty {
            return "기존 동기화 항목 \(matchedItems.count)개와 연결될 가능성이 큽니다."
        }
        if kind == .none {
            return "과제, 시험, 공지 중 어떤 항목인지 확실하지 않습니다."
        }
        return "\(kind.title)로 보입니다. 일정 정보가 있으면 캘린더 처리까지 이어갈 수 있습니다."
    }

    var canCreateCalendarEvent: Bool {
        kind == .assignment || kind == .exam
    }

    var dashboardItem: ServerRelaySyncItem? {
        guard let dashboardKind = kind.dashboardKind else {
            return nil
        }
        let itemTitle = title.nilIfEmpty ?? kind.title
        let id = "mail-\(ServerRelaySyncItem.stableID(kind: dashboardKind, parts: [course, itemTitle, dueText]))"
        let detail = [
            "추가됨",
            confidence > 0 ? "신뢰도 \(confidence)%" : nil,
            urls.isEmpty ? nil : "링크 \(urls.count)개",
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        return ServerRelaySyncItem(
            id: id,
            kind: dashboardKind,
            course: course,
            title: itemTitle,
            timestamp: calendarStartInput.nilIfEmpty ?? dueText,
            status: "추가됨",
            detail: detail,
            attachmentCount: kind == .file ? max(1, urls.count) : urls.count,
            updatedAt: ServerRelaySyncItem.isoTimestamp()
        )
    }

    var calendarTitle: String {
        let base = title.nilIfEmpty ?? kind.title
        return course.nilIfEmpty.map { "\($0) · \(base)" } ?? base
    }

    var detectedTargets: [String] {
        var targets: [String] = []
        switch kind {
        case .assignment:
            targets.append("과제 후보")
        case .exam:
            targets.append("시험/캘린더 후보")
        case .notice:
            targets.append("공지 후보")
        case .file:
            targets.append("파일 후보")
        case .none:
            break
        }
        if !dueText.isEmpty {
            targets.append("일정/마감 감지")
        }
        if !matchedItems.isEmpty {
            targets.append("기존 KLMS 항목 연결")
        }
        if !urls.isEmpty {
            targets.append("링크 포함")
        }
        var seen = Set<String>()
        return targets.filter { seen.insert($0).inserted }
    }

    var actionPlan: [String] {
        if isEmpty { return [] }
        var lines: [String] = []
        if !matchedItems.isEmpty {
            lines.append("기존 KLMS 항목과 맞아 보입니다. 항목을 펼쳐 상태를 바로 확인하세요.")
        }
        switch kind {
        case .assignment:
            lines.append("과제로 판독했습니다. 마감이 있으면 미리알림/캘린더 등록 대상입니다.")
        case .exam:
            lines.append("시험 또는 퀴즈로 판독했습니다. 캘린더 등록 대상입니다.")
        case .notice:
            lines.append("공지로 판독했습니다. 일정 문구가 있으면 캘린더 등록 여부를 확인하세요.")
        case .file:
            lines.append("파일 또는 첨부 자료 안내로 판독했습니다. 파일 동기화 후 파일 대시보드와 대조하세요.")
        case .none:
            lines.append("분류가 애매합니다. 제목, 과목명, 날짜가 들어간 메일 본문 전체를 붙여넣어 주세요.")
        }
        if canCreateCalendarEvent {
            lines.append("필요하면 Mac 캘린더에 직접 등록하도록 요청할 수 있습니다.")
        }
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }
}

private enum MailPasteAnalyzer {
    static func analyze(_ rawText: String, syncItems: [ServerRelaySyncItem]) -> MailPasteAnalysis {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }

        let urls = regexMatches("https?://[^\\s>\\]]+", in: text)
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let knownCourses = Array(Set(syncItems.map(\.course).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
            .sorted { $0.count > $1.count }
        let course = detectCourse(in: text, lines: lines, knownCourses: knownCourses)
        let scores = kindScores(in: text)
        let kind = detectKind(in: text)
        let title = detectTitle(lines: lines, kind: kind, course: course)
        let dueText = detectDueText(in: text)
        let matchedItems = matchItems(
            syncItems: syncItems,
            text: text,
            kind: kind,
            title: title,
            course: course,
            dueText: dueText
        )
        let calendarInput = calendarInputs(from: dueText)
        let confidence = confidenceScore(kind: kind, title: title, course: course, dueText: dueText, matchedItems: matchedItems)
        let steps = analysisSteps(
            kind: kind,
            assignmentScore: scores.assignmentScore,
            examScore: scores.examScore,
            fileScore: scores.fileScore,
            course: course,
            title: title,
            dueText: dueText,
            calendarInput: calendarInput,
            matchedItems: matchedItems,
            urls: urls
        )
        return MailPasteAnalysis(
            kind: kind,
            title: title,
            course: course,
            dueText: dueText,
            urls: urls,
            confidence: confidence,
            matchedItems: matchedItems,
            suggestedAction: suggestedAction(kind: kind, matchedItems: matchedItems),
            calendarStartInput: calendarInput.start,
            calendarEndInput: calendarInput.end,
            analysisSteps: steps
        )
    }

    private static func kindScores(in text: String) -> (assignmentScore: Int, examScore: Int, fileScore: Int) {
        let lower = text.lowercased()
        let assignmentScore = keywordScore(lower, weightedKeywords: [
            ("written assignment", 7),
            ("problem set", 6),
            ("due date", 6),
            ("deadline", 6),
            ("assignment", 5),
            ("homework", 5),
            ("submission", 4),
            ("submit", 4),
            ("project", 3),
            ("essay", 3),
            ("paper", 3),
            ("과제", 6),
            ("숙제", 5),
            ("제출", 5),
            ("마감", 5),
            ("레포트", 4),
            ("보고서", 4),
        ])
        let examScore = keywordScore(lower, weightedKeywords: [
            ("final exam", 7),
            ("midterm exam", 7),
            ("기말고사", 7),
            ("중간고사", 7),
            ("quiz", 5),
            ("exam", 5),
            ("시험", 5),
            ("퀴즈", 5),
            ("midterm", 3),
            ("final", 2),
            ("중간", 2),
            ("기말", 2),
        ])
        let fileScore = keywordScore(lower, weightedKeywords: [
            ("attachment", 6),
            ("attached", 6),
            ("file", 5),
            ("pdf", 5),
            ("slides", 4),
            ("material", 4),
            ("첨부", 6),
            ("파일", 5),
            ("자료", 5),
            ("강의자료", 5),
            ("슬라이드", 4),
        ])
        return (assignmentScore, examScore, fileScore)
    }

    private static func detectKind(in text: String) -> MailPasteDetectedKind {
        let scores = kindScores(in: text)
        let assignmentScore = scores.assignmentScore
        let examScore = scores.examScore
        let fileScore = scores.fileScore
        if assignmentScore >= examScore, assignmentScore >= fileScore, assignmentScore > 0 {
            return .assignment
        }
        if examScore >= assignmentScore, examScore >= fileScore, examScore > 0 {
            return .exam
        }
        if fileScore > 0 { return .file }
        return .notice
    }

    private static func analysisSteps(
        kind: MailPasteDetectedKind,
        assignmentScore: Int,
        examScore: Int,
        fileScore: Int,
        course: String,
        title: String,
        dueText: String,
        calendarInput: (start: String, end: String),
        matchedItems: [ServerRelaySyncItem],
        urls: [String]
    ) -> [MailAnalysisStep] {
        var steps: [MailAnalysisStep] = [
            MailAnalysisStep(
                id: "kind",
                title: "분류 판단",
                detail: "과제 \(assignmentScore), 시험 \(examScore), 파일 \(fileScore) 점수를 비교해 \(kind.title)로 분류했습니다.",
                systemImage: kind.systemImage,
                tone: tone(for: kind)
            ),
        ]

        let courseDetail: String
        if course.isEmpty {
            courseDetail = "본문과 동기화된 목록에서 과목명이나 과목 코드를 찾지 못했습니다."
        } else if let code = firstCapture("\\(([A-Z]{2,}\\d{2,4}[A-Z]?)\\)$", in: course) {
            courseDetail = "메일의 \(code) 코드를 현재 KLMS 과목명/별칭표로 풀었습니다: \(course)"
        } else {
            courseDetail = "본문 또는 동기화된 목록에서 과목명을 찾았습니다: \(course)"
        }
        steps.append(MailAnalysisStep(id: "course", title: "과목 해석", detail: courseDetail, systemImage: "books.vertical", tone: .teal))

        let titleDetail: String
        if title.isEmpty {
            titleDetail = "제목, Subject, 시험/과제 핵심 문구에서 사용할 제목을 찾지 못했습니다."
        } else if ["기말고사", "중간고사", "퀴즈", "시험 안내", "과제 안내"].contains(title) {
            titleDetail = "본문의 핵심 키워드로 제목을 추론했습니다: \(title)"
        } else {
            titleDetail = "Subject 또는 본문 첫 유효 줄에서 제목을 잡았습니다: \(title)"
        }
        steps.append(MailAnalysisStep(id: "title", title: "제목 추론", detail: titleDetail, systemImage: "text.quote", tone: .blue))

        let dateDetail: String
        if dueText.isEmpty {
            dateDetail = "마감, 일정, 시험 시간 같은 날짜 문구를 찾지 못했습니다."
        } else if !calendarInput.start.isEmpty {
            dateDetail = "\(dueText)를 캘린더 입력값 \(calendarInput.start)로 변환했습니다."
        } else {
            dateDetail = "날짜 문구 \(dueText)는 찾았지만 캘린더 시간으로 변환하지 못했습니다."
        }
        steps.append(MailAnalysisStep(id: "date", title: "일정 해석", detail: dateDetail, systemImage: "calendar.badge.clock", tone: .orange))

        let matchDetail = matchedItems.isEmpty
            ? "기존 동기화 항목과 바로 이어지는 항목은 아직 없습니다."
            : "기존 동기화 항목 \(matchedItems.count)개와 제목, 과목, 일정 정보가 겹칩니다."
        steps.append(MailAnalysisStep(id: "match", title: "기존 항목 비교", detail: matchDetail, systemImage: "link", tone: matchedItems.isEmpty ? .secondary : .green))

        if !urls.isEmpty {
            steps.append(MailAnalysisStep(id: "links", title: "링크 감지", detail: "본문에서 URL \(urls.count)개를 찾았습니다. KLMS 링크가 있으면 다음 동기화와 대조할 수 있습니다.", systemImage: "link.circle", tone: .purple))
        }
        return steps
    }

    private static func tone(for kind: MailPasteDetectedKind) -> MailAnalysisStepTone {
        switch kind {
        case .none:
            .secondary
        case .assignment:
            .orange
        case .exam:
            .green
        case .notice:
            .brown
        case .file:
            .blue
        }
    }

    private static func detectCourse(in text: String, lines: [String], knownCourses: [String]) -> String {
        if let known = knownCourses.first(where: { text.localizedCaseInsensitiveContains($0) }) {
            return known
        }
        if let captured = firstCapture("(?:과목|강의|Course)[:：]\\s*([^\\n]+)", in: text) {
            return resolvedCourseDisplay(for: captured, knownCourses: knownCourses) ?? captured
        }
        if let captured = firstCapture("(?:TA|조교)\\s*(?:for|of|[:：])\\s*([A-Z]{2,}\\s*\\d{2,4}[A-Z]?)", in: text) {
            return resolvedCourseDisplay(for: captured, knownCourses: knownCourses) ?? captured.replacingOccurrences(of: " ", with: "")
        }
        if let captured = firstCapture("([A-Z]{2,}\\s*\\d{2,4}[A-Z]?)\\s*(?:TA|조교)", in: text) {
            return resolvedCourseDisplay(for: captured, knownCourses: knownCourses) ?? captured.replacingOccurrences(of: " ", with: "")
        }
        if let captured = firstCapture("\\b([A-Z]{2,}\\s*\\.?\\s*\\d{2,4}[A-Z]?)\\b", in: text),
           let resolved = resolvedCourseDisplay(for: captured, knownCourses: knownCourses) {
            return resolved
        }
        if let bracket = firstCapture("^\\s*\\[([^\\]\\n]{2,40})\\]", in: lines.first ?? "") {
            return resolvedCourseDisplay(for: bracket, knownCourses: knownCourses) ?? bracket
        }
        return ""
    }

    private static func resolvedCourseDisplay(for rawCourseOrCode: String, knownCourses: [String]) -> String? {
        let code = normalizedCourseCode(rawCourseOrCode)
        guard !code.isEmpty else { return nil }
        if let known = knownCourseName(for: code, knownCourses: knownCourses) {
            return "\(known) (\(code))"
        }
        if let fallback = fallbackCourseCodeAliases[code] {
            return "\(fallback) (\(code))"
        }
        return code == rawCourseOrCode.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : code
    }

    private static func normalizedCourseCode(_ raw: String) -> String {
        let compact = raw
            .uppercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.range(of: #"^[A-Z]{2,}\d{2,4}[A-Z]?$"#, options: .regularExpression) != nil else {
            return ""
        }
        return compact
    }

    private static func knownCourseName(for code: String, knownCourses: [String]) -> String? {
        switch code {
        case "EE488":
            return knownCourses.first {
                $0.localizedCaseInsensitiveContains("전자공학을 위한 사이버 보안 개론")
            } ?? knownCourses.first {
                $0.localizedCaseInsensitiveContains("Introduction to Cybersecurity for EE")
            }
        default:
            return nil
        }
    }

    private static let fallbackCourseCodeAliases: [String: String] = [
        "EE488": "전기 전자공학특강<전자공학을 위한 사이버 보안 개론>",
    ]

    private static func detectTitle(lines: [String], kind: MailPasteDetectedKind, course: String) -> String {
        if let subject = lines.first(where: { line in
            let lower = line.lowercased()
            return lower.hasPrefix("subject:") || line.hasPrefix("제목:") || line.hasPrefix("제목：")
        }) {
            return cleanTitle(subject)
        }
        if let inferred = inferredTitle(lines: lines, kind: kind, course: course) {
            return inferred
        }
        if let title = lines.first(where: { line in
            let lower = line.lowercased()
            return !lower.hasPrefix("from:")
                && !lower.hasPrefix("to:")
                && !lower.hasPrefix("date:")
                && !lower.hasPrefix("sent:")
                && !line.hasPrefix("보낸 사람:")
                && !line.hasPrefix("받는 사람:")
                && !line.hasPrefix("날짜:")
                && !line.hasPrefix("https://")
                && !line.hasPrefix("http://")
                && !isMailGreetingOrSignature(line)
        }) {
            return cleanTitle(title)
        }
        return ""
    }

    private static func inferredTitle(lines: [String], kind: MailPasteDetectedKind, course: String) -> String? {
        let joined = lines.joined(separator: "\n").lowercased()
        switch kind {
        case .exam:
            if joined.contains("final exam") || joined.contains("기말고사") {
                return "기말고사"
            }
            if joined.contains("midterm exam") || joined.contains("중간고사") {
                return "중간고사"
            }
            if joined.contains("quiz") || joined.contains("퀴즈") {
                return "퀴즈"
            }
            return "시험 안내"
        case .assignment:
            if let line = lines.first(where: { line in
                let lower = line.lowercased()
                return lower.contains("assignment") || lower.contains("homework") || lower.contains("과제")
            }) {
                return cleanTitle(line)
            }
            return "과제 안내"
        case .file:
            if let line = lines.first(where: { line in
                let lower = line.lowercased()
                return lower.contains("attachment") || lower.contains("file") || lower.contains("첨부") || lower.contains("파일") || lower.contains("자료")
            }) {
                return cleanTitle(line)
            }
            return "파일 안내"
        case .notice:
            return nil
        case .none:
            return nil
        }
    }

    private static func isMailGreetingOrSignature(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasPrefix("dear ")
            || lower == "hi,"
            || lower.hasPrefix("hi, ")
            || lower.hasPrefix("hello")
            || lower.hasPrefix("best regards")
            || lower.hasPrefix("regards")
            || lower.hasPrefix("thanks")
            || line.hasPrefix("학생 여러분")
            || line.hasPrefix("안녕하세요")
            || line.hasPrefix("감사합니다")
            || line.hasPrefix("질문이 있으면")
    }

    private static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Subject:", "subject:", "제목:", "제목：", "[KLMS]", "KLMS:"] {
            if title.hasPrefix(prefix) {
                title.removeFirst(prefix.count)
                title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let range = title.range(of: "^\\[[^\\]]+\\]\\s*", options: .regularExpression) {
            title.removeSubrange(range)
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func detectDueText(in text: String) -> String {
        if let captured = firstCapture("(?:due|deadline|exam schedule|schedule|마감|제출|일시|일정|시험일|시험 일정|시험일정|시험 시간|시험시간)[:：]?\\s*([^\\n]{1,160})", in: text) {
            return dateSnippet(in: captured) ?? captured
        }
        if let subjectDate = dateSnippet(in: text) {
            return subjectDate
        }
        let datePatterns = [
            "\\d{4}\\s*[년.-]\\s*\\d{1,2}\\s*[월.-]\\s*\\d{1,2}\\s*일?(?:[^\\n]{0,40})?",
            "(?:January|Jan|February|Feb|March|Mar|April|Apr|May|June|Jun|July|Jul|August|Aug|September|Sep|October|Oct|November|Nov|December|Dec)\\s+\\d{1,2}(?:st|nd|rd|th)?(?:,?\\s*\\d{4})?(?:[^\\n]{0,50})?",
            "\\d{1,2}/\\d{1,2}(?:/\\d{2,4})?(?:[^\\n]{0,30})?",
        ]
        for pattern in datePatterns {
            if let match = regexMatches(pattern, in: text).first {
                return match.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    private static func matchItems(
        syncItems: [ServerRelaySyncItem],
        text: String,
        kind: MailPasteDetectedKind,
        title: String,
        course: String,
        dueText: String
    ) -> [ServerRelaySyncItem] {
        let lowerText = text.lowercased()
        let normalizedText = normalizeMailText(text)
        let normalizedCourse = normalizeMailText(course)
        let normalizedDue = normalizeMailText(dueText)
        let detectedTitleTokens = titleTokens(title).map(normalizeMailText)
        let scored = syncItems.compactMap { item -> (ServerRelaySyncItem, Int)? in
            guard kind == .none || item.kind.matches(mailKind: kind) else {
                return nil
            }
            var score = 0
            let itemCourse = normalizeMailText(item.course)
            if !normalizedCourse.isEmpty,
               !itemCourse.isEmpty,
               (itemCourse.contains(normalizedCourse) || normalizedCourse.contains(itemCourse)) {
                score += 3
            }
            if item.kind.matches(mailKind: kind) {
                score += 2
            }
            if !item.title.isEmpty && lowerText.contains(item.title.lowercased()) {
                score += 8
            } else {
                let itemTitleText = normalizeMailText(item.title)
                var tokenHits = titleTokens(item.title)
                    .map(normalizeMailText)
                    .filter { !$0.isEmpty && normalizedText.contains($0) }
                    .count
                if !detectedTitleTokens.isEmpty, !itemTitleText.isEmpty {
                    tokenHits += detectedTitleTokens.filter { !$0.isEmpty && itemTitleText.contains($0) }.count
                }
                if tokenHits >= 2 {
                    score += min(5, tokenHits)
                }
            }
            if !normalizedDue.isEmpty && normalizeMailText(item.searchText).contains(normalizedDue) {
                score += 1
            }
            guard score >= 5 else { return nil }
            return (item, score)
        }
        return scored
            .sorted {
                if $0.1 != $1.1 {
                    return $0.1 > $1.1
                }
                return $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending
            }
            .map(\.0)
    }

    private static func confidenceScore(
        kind: MailPasteDetectedKind,
        title: String,
        course: String,
        dueText: String,
        matchedItems: [ServerRelaySyncItem]
    ) -> Int {
        if !matchedItems.isEmpty {
            return 90
        }
        var score = kind == .none ? 20 : 42
        if !title.isEmpty {
            score += 18
        }
        if !course.isEmpty {
            score += 14
        }
        if !dueText.isEmpty {
            score += 16
        }
        return min(score, 82)
    }

    private static func suggestedAction(kind: MailPasteDetectedKind, matchedItems: [ServerRelaySyncItem]) -> String {
        if !matchedItems.isEmpty {
            return "기존 KLMS 항목과 맞아 보입니다. 항목을 펼쳐 읽음, 중요, 숨김 같은 상태를 바로 확인할 수 있습니다."
        }
        switch kind {
        case .assignment:
            return "과제 후보로 보입니다. 다음 전체 동기화 후 과제 대시보드에서 반영됐는지 확인하세요. KLMS에 없는 메일 전용 과제라면 수동 등록 기능을 추가하는 쪽이 필요합니다."
        case .exam:
            return "시험 후보로 보입니다. 캘린더에 자동 반영되지 않으면 시험 대시보드에서 후보 승격 또는 캘린더 내용 수정을 사용하세요."
        case .notice:
            return "공지 후보로 보입니다. KLMS 공지가 아니라 메일 전용 공지라면 앱 안의 기록용 항목으로 따로 저장하는 기능을 추가할 수 있습니다."
        case .file:
            return "파일 후보로 보입니다. 파일 대시보드에 임시로 반영한 뒤 실제 파일 동기화와 대조하세요."
        case .none:
            return "분류가 확실하지 않습니다. 제목, 과목명, 마감일이 들어간 메일 본문 전체를 붙여넣으면 분석이 더 정확해집니다."
        }
    }

    private static func calendarInputs(from dueText: String) -> (start: String, end: String) {
        guard let date = parseMailDate(dueText) else {
            return ("", "")
        }
        let formatter = CompanionDateParsingCache.mailCalendarInputFormatter()
        return (formatter.string(from: date), formatter.string(from: date.addingTimeInterval(60 * 60)))
    }

    private static func parseMailDate(_ raw: String) -> Date? {
        var text = (dateSnippet(in: raw) ?? raw)
            .replacingOccurrences(of: #"(\d)(st|nd|rd|th)"#, with: "$1", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(?i)\bat\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "오전", with: "AM")
            .replacingOccurrences(of: "오후", with: "PM")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: #"[()]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*(월요일|화요일|수요일|목요일|금요일|토요일|일요일|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),?\s*"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"(\d{1,2})\s*시\s*(\d{1,2})\s*분"#, with: "$1:$2", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(\d{1,2})\s*시"#, with: "$1:00", options: .regularExpression)
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        let candidates = [text, "\(currentYear) \(text)"]
        let formatter = CompanionDateParsingCache.mailParseFormatter()
        let formats = [
            ("ko_KR", "yyyy년 M월 d일 a h:mm"),
            ("ko_KR", "yyyy년 M월 d일 H:mm"),
            ("ko_KR", "yyyy M월 d일 a h:mm"),
            ("ko_KR", "yyyy M월 d일 H:mm"),
            ("en_US_POSIX", "yyyy MMMM d, h:mm a"),
            ("en_US_POSIX", "yyyy MMM d, h:mm a"),
            ("en_US_POSIX", "yyyy MMMM d h:mm a"),
            ("en_US_POSIX", "yyyy MMM d h:mm a"),
            ("en_US_POSIX", "yyyy MMMM d, HH:mm"),
            ("en_US_POSIX", "yyyy MMM d, HH:mm"),
            ("en_US_POSIX", "yyyy MMMM d HH:mm"),
            ("en_US_POSIX", "yyyy MMM d HH:mm"),
            ("en_US_POSIX", "yyyy M/d HH:mm"),
            ("en_US_POSIX", "yyyy M/d/yyyy HH:mm"),
        ]
        for candidate in candidates {
            for (locale, format) in formats {
                formatter.locale = Locale(identifier: locale)
                formatter.dateFormat = format
                if let date = formatter.date(from: candidate) {
                    return date
                }
            }
        }
        return nil
    }

    private static func dateSnippet(in text: String) -> String? {
        let patterns = [
            "(?:\\d{4}\\s*년\\s*)?\\d{1,2}\\s*월\\s*\\d{1,2}\\s*일(?:\\s*(?:월요일|화요일|수요일|목요일|금요일|토요일|일요일))?(?:\\s*(?:오전|오후|AM|PM)?\\s*\\d{1,2}(?::\\d{2}|\\s*시(?:\\s*\\d{1,2}\\s*분)?))?",
            "\\d{4}\\s*[.-]\\s*\\d{1,2}\\s*[.-]\\s*\\d{1,2}(?:\\s*(?:오전|오후|AM|PM)?\\s*\\d{1,2}:\\d{2})?",
            "(?:January|Jan|February|Feb|March|Mar|April|Apr|May|June|Jun|July|Jul|August|Aug|September|Sep|October|Oct|November|Nov|December|Dec)\\s+\\d{1,2}(?:st|nd|rd|th)?(?:,?\\s*\\d{4})?(?:,?\\s*(?:at\\s*)?(?:(?:AM|PM|오전|오후)\\s*)?\\d{1,2}:\\d{2}(?:\\s*(?:AM|PM))?)?",
            "\\d{1,2}/\\d{1,2}(?:/\\d{2,4})?(?:\\s*(?:AM|PM|오전|오후)?\\s*\\d{1,2}:\\d{2})?",
        ]
        for pattern in patterns {
            if let match = regexMatches(pattern, in: text).first {
                return match
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "().,"))
            }
        }
        return nil
    }

    private static func titleTokens(_ title: String) -> [String] {
        title
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
    }

    private static func keywordScore(_ text: String, weightedKeywords: [(String, Int)]) -> Int {
        weightedKeywords.reduce(0) { partialResult, keyword in
            partialResult + (text.contains(keyword.0) ? keyword.1 : 0)
        }
    }

    private static func normalizeMailText(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func regexMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func matches(mailKind: MailPasteDetectedKind) -> Bool {
        switch mailKind {
        case .assignment:
            self == "assignment" || self == "assignmentCandidate" || self == "completedAssignment"
        case .exam:
            self == "exam" || self == "examCandidate"
        case .notice:
            self == "notice"
        case .file:
            self == "file"
        case .none:
            false
        }
    }
}

private struct RemoteCalendarActionPanel: View {
    var compact = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.klmsWarningBorder)
                    .frame(width: 28, height: 28)
                    .background(Color.klmsWarningBackground, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text("캘린더 일정")
                        .font(.caption.weight(.semibold))
                    Text("일정별 등록·수정·삭제는 아래 항목에서 처리합니다. 전체 상태 검사는 진단 화면에서 실행하세요.")
                        .font(.caption2)
                        .foregroundStyle(Color.klmsSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Button {
                openSystemCalendar()
            } label: {
                Label("캘린더에서 열기", systemImage: "calendar")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(KLMSActionButtonStyle(tone: .accent(Color.klmsWarningBorder)))
        }
        .padding(compact ? 10 : 0)
        .background(compact ? Color.klmsSubtleCardBackground : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(compact ? Color.klmsBorder : Color.clear, lineWidth: 1)
        )
    }

    private func openSystemCalendar() {
        #if canImport(UIKit)
        if let url = URL(string: "calshow:") {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

private struct DashboardCalendarChangeDetailRow: View {
    var change: CalendarChange
    var activeAction: ServerRelayItemAction?
    var onAction: ((ServerRelayItemActionKind, CalendarEventEdit?) async -> Void)?
    @State private var calendarSheetAction: ServerRelayItemActionKind?

    init(
        change: CalendarChange,
        activeAction: ServerRelayItemAction? = nil,
        onAction: ((ServerRelayItemActionKind, CalendarEventEdit?) async -> Void)? = nil
    ) {
        self.change = change
        self.activeAction = activeAction
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
                        .foregroundStyle(Color.klmsSecondaryText)
                }
            }
            if !change.changes.isEmpty {
                Text(change.changes.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CalendarChangeExplanationPanel(change: change, showsActionHelp: onAction != nil)
            if let activeAction {
                RemoteItemRequestPendingView(
                    title: activeAction.action.displayName,
                    message: "Mac 앱에서 \(activeAction.status.displayName) 중입니다."
                )
            } else if onAction != nil {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    Button {
                        calendarSheetAction = .calendarCreate
                    } label: {
                        Label("등록", systemImage: "calendar.badge.plus")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(KLMSActionButtonStyle(tone: .success))
                    Button {
                        calendarSheetAction = .calendarEdit
                    } label: {
                        Label("수정", systemImage: "pencil")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(KLMSActionButtonStyle())
                    if change.isDeletedAction {
                        Button {
                            Task {
                                if let onAction {
                                    await onAction(.calendarDelete, nil)
                                }
                            }
                        } label: {
                            Label("확인", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(KLMSActionButtonStyle())
                    } else {
                        Button(role: .destructive) {
                            Task {
                                if let onAction {
                                    await onAction(.calendarDelete, nil)
                                }
                            }
                        } label: {
                            Label("삭제", systemImage: "calendar.badge.minus")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(KLMSActionButtonStyle(tone: .destructive))
                    }
                    Button {
                        openSystemCalendar()
                    } label: {
                        Label("캘린더에서 열기", systemImage: "calendar")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(KLMSActionButtonStyle())
                }
                .font(.caption)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .sheet(
            isPresented: Binding(
                get: { calendarSheetAction != nil },
                set: { if !$0 { calendarSheetAction = nil } }
            )
        ) {
            let action = calendarSheetAction ?? .calendarEdit
            CalendarEventEditForm(change: change, action: action) { edit in
                Task {
                    if let onAction {
                        await onAction(action, edit)
                    }
                }
            }
        }
    }

    private var tint: Color {
        switch change.action {
        case "created":
            Color.klmsSuccessBorder
        case "updated":
            Color.klmsCommandAccent
        case "deleted":
            Color.klmsDangerBorder
        default:
            Color.klmsSecondaryText
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
    var action: ServerRelayItemActionKind
    var onSave: (CalendarEventEdit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var startAt: String
    @State private var dueAt: String
    @State private var location: String

    init(change: CalendarChange, action: ServerRelayItemActionKind, onSave: @escaping (CalendarEventEdit) -> Void) {
        self.change = change
        self.action = action
        self.onSave = onSave
        let defaults = change.editDefaults
        _title = State(initialValue: defaults.title)
        _startAt = State(initialValue: defaults.startAt)
        _dueAt = State(initialValue: defaults.dueAt)
        _location = State(initialValue: defaults.location)
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
                    Text(action == .calendarCreate
                        ? "Mac 앱에서 Apple Calendar에 새 일정을 등록합니다. 시간은 2026-06-17 13:00 형식으로 입력할 수 있습니다."
                        : "Mac 앱에서 Apple Calendar 일정을 찾아 직접 수정합니다. 시간은 2026-06-17 13:00 형식으로 입력할 수 있고, 비워 둔 항목은 그대로 둡니다.")
                }
            }
            .navigationTitle(action == .calendarCreate ? "캘린더 일정 등록" : "캘린더 내용 수정")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        dismiss()
                    }
                    .buttonStyle(KLMSToolbarButtonStyle())
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action == .calendarCreate ? "등록" : "저장") {
                        onSave(CalendarEventEdit(title: title, startAt: startAt, dueAt: dueAt, location: location))
                        dismiss()
                    }
                    .buttonStyle(KLMSToolbarButtonStyle(tone: action == .calendarCreate ? .success : .primary))
                }
            }
        }
    }
}

private func parseCalendarEditInputDate(_ text: String) -> Date? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let fractionalFormatter = CompanionDateParsingCache.isoFormatter(fractionalSeconds: true)
    if let date = fractionalFormatter.date(from: trimmed) {
        return date
    }
    let formatter = CompanionDateParsingCache.isoFormatter(fractionalSeconds: false)
    return formatter.date(from: trimmed)
}

private enum CompanionDateParsingCache {
    static func mailCalendarInputFormatter() -> DateFormatter {
        cachedDateFormatter(key: "KLMSSync.iOS.mailCalendarInputFormatter") { formatter in
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
        }
    }

    static func mailParseFormatter() -> DateFormatter {
        cachedDateFormatter(key: "KLMSSync.iOS.mailParseFormatter") { formatter in
            formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        }
    }

    static func isoFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let key = fractionalSeconds
            ? "KLMSSync.iOS.iso8601FractionalFormatter"
            : "KLMSSync.iOS.iso8601Formatter"
        if let formatter = Thread.current.threadDictionary[key] as? ISO8601DateFormatter {
            return formatter
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        Thread.current.threadDictionary[key] = formatter
        return formatter
    }

    private static func cachedDateFormatter(
        key: String,
        configure: (DateFormatter) -> Void
    ) -> DateFormatter {
        if let formatter = Thread.current.threadDictionary[key] as? DateFormatter {
            return formatter
        }
        let formatter = DateFormatter()
        configure(formatter)
        Thread.current.threadDictionary[key] = formatter
        return formatter
    }
}

private struct CalendarChangeExplanationPanel: View {
    var change: CalendarChange
    var showsActionHelp = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(change.explanationText, systemImage: "info.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.klmsSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(change.nextActionText)
                .font(.caption)
                .foregroundStyle(Color.klmsSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if showsActionHelp {
                Text(change.actionButtonHelpText)
                    .font(.caption2)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsWarningBackground)
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
                .foregroundStyle(Color.klmsPrimaryText)
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.klmsSecondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 10)
        .background(Color.klmsCommandButtonBackground.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder.opacity(0.95), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, 8)
        }
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
                    .foregroundStyle(Color.klmsSecondaryText)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                RemoteSummaryCard(
                    title: "공지",
                    systemImage: "megaphone",
                    tint: Color.klmsCommandAccent,
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
                    tint: Color.klmsSecondaryText,
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
                    tint: Color.klmsSuccessBorder,
                    lines: [
                        "생성 \(status.calendarCreated)",
                        "수정 \(status.calendarUpdated)",
                        "삭제 \(status.calendarDeleted)",
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
                .foregroundStyle(Color.klmsSecondaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
        .padding(10)
        .background(Color.klmsCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ServerSyncDataPanel: View {
    var items: [ServerRelaySyncItem]
    var itemsRevision: Int
    var onSelect: (ServerRelaySyncItem) -> Void = { _ in }
    @State private var query = ""
    @State private var sortOption = CompanionItemSortOption.recent
    @State private var visibilityFilter = CompanionItemVisibilityFilter.visible
    @State private var statusFilter = CompanionItemStatusFilter.all
    @State private var selectedCourse = CompanionItemListFilter.allCourses
    @State private var selectedYear = CompanionItemListFilter.allYears
    @State private var selectedSemester = CompanionItemListFilter.allSemesters
    @State private var newOnly = false
    @State private var recentOnly = false
    @State private var cachedListData: CompanionItemListData?
    @State private var cachedListInputKey: CompanionItemListInputKey?

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("동기화 데이터", systemImage: "tray.full")
                        .font(.headline)
                    Spacer()
                    Text("\(items.count)개")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.klmsSecondaryText)
                }

                CompanionSearchFilterPanel(title: "검색과 필터", fieldPrompt: "동기화 데이터 검색", query: $query) {
                    if let listData = cachedListData {
                        DeferredCompanionItemListControls(
                            listData: listData,
                            sortOption: $sortOption,
                            visibilityFilter: $visibilityFilter,
                            statusFilter: $statusFilter,
                            selectedCourse: $selectedCourse,
                            selectedYear: $selectedYear,
                            selectedSemester: $selectedSemester,
                            newOnly: $newOnly,
                            recentOnly: $recentOnly,
                            supportsNewOnly: true,
                            supportsRecentOnly: true,
                            defaultStatusFilter: .all
                        )
                    } else {
                        CompanionItemListControlsPlaceholder()
                    }
                }

                if let listData = cachedListData {
                    let filtered = listData.filteredItems
                    CompanionSelectableItemListRows(
                        items: filtered,
                        onSelect: onSelect
                    )
                } else {
                    Text("목록을 준비하고 있습니다.")
                        .font(.caption)
                        .foregroundStyle(Color.klmsSecondaryText)
                }
            }
            .padding(12)
            .background(Color.klmsSubtleCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: listInputKey) {
                await rebuildCachedListDataAfterInputSettles()
            }
        }
    }

    private var listInputKey: CompanionItemListInputKey {
        CompanionItemListInputKey(
            itemsRevision: itemsRevision,
            category: "all",
            query: query,
            sortOption: sortOption.rawValue,
            visibilityFilter: visibilityFilter.rawValue,
            statusFilter: statusFilter.rawValue,
            selectedCourse: selectedCourse,
            selectedYear: selectedYear,
            selectedSemester: selectedSemester,
            newOnly: newOnly,
            recentOnly: recentOnly
        )
    }

    private func rebuildCachedListDataAfterInputSettles() async {
        let currentKey = listInputKey
        if cachedListInputKey == currentKey, cachedListData != nil {
            return
        }
        if cachedListData != nil, currentKey.shouldDebounceComparedTo(cachedListInputKey) {
            try? await Task.sleep(nanoseconds: CompanionLargeList.filterRebuildDelayNanoseconds)
            guard !Task.isCancelled, currentKey == listInputKey else { return }
        }
        await rebuildCachedListData(for: currentKey)
    }

    private func rebuildCachedListData(for inputKey: CompanionItemListInputKey) async {
        await Task.yield()
        guard !Task.isCancelled else { return }
        let items = items
        let query = query
        let sortOption = sortOption
        let visibilityFilter = visibilityFilter
        let statusFilter = statusFilter
        let selectedCourse = selectedCourse
        let selectedYear = selectedYear
        let selectedSemester = selectedSemester
        let newOnly = newOnly
        let recentOnly = recentOnly
        let listData = await Task.detached(priority: .userInitiated) {
            CompanionItemListData(
                items: items,
                category: nil,
                query: query,
                sortOption: sortOption,
                visibilityFilter: visibilityFilter,
                statusFilter: statusFilter,
                selectedCourse: selectedCourse,
                selectedYear: selectedYear,
                selectedSemester: selectedSemester,
                newOnly: newOnly,
                recentOnly: recentOnly
            )
        }.value
        guard !Task.isCancelled, inputKey == listInputKey else { return }
        cachedListData = listData
        cachedListInputKey = inputKey
    }
}

private struct DeferredServerSyncItemDetailPanel: View {
    var item: ServerRelaySyncItem
    let model: CompanionModel
    @State private var loadedItemID: String?

    var body: some View {
        Group {
            if loadedItemID == item.id {
                ServerSyncItemInlineDetailPanel(item: item, model: model)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("상세를 여는 중")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.klmsPrimaryText)
                        Text(item.title.isEmpty ? "선택한 항목을 준비하고 있습니다." : item.title)
                            .font(.caption)
                            .foregroundStyle(Color.klmsSecondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.klmsBorder, lineWidth: 1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("상세를 여는 중")
                .accessibilityValue(item.title.isEmpty ? "선택한 항목" : item.title)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .task(id: item.id) {
            loadedItemID = nil
            await Task.yield()
            guard !Task.isCancelled else { return }
            loadedItemID = item.id
        }
    }
}

private struct ServerSyncItemInlineDetailPanel: View {
    var item: ServerRelaySyncItem
    let model: CompanionModel

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
                    message: "Mac 앱에서 요청을 처리하고 있습니다. 끝나면 결과를 다시 불러옵니다."
                )
            } else {
                actionPanel
            }
            InfoBanner(message: detailHelpMessage)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.klmsCardBackground)
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
                    .foregroundStyle(Color.klmsSecondaryText)
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
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !itemActions.isEmpty {
                Text("항목 처리")
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
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(KLMSActionButtonStyle())
                        .disabled(!model.serverRelayConfigured || model.isSubmitting)
                        }
                    }
                }
                if !model.serverRelayConfigured {
                    Text("항목 처리 요청은 서버 릴레이가 연결되어 있을 때만 사용할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(Color.klmsSecondaryText)
                }
            }

            Text("동기화")
                .font(.subheadline.weight(.semibold))
            Button {
                Task {
                    await model.createCommand(relevantCommand)
                }
            } label: {
                Label("\(relevantCommand.displayName) 다시 실행", systemImage: relevantCommand.engineCommand.systemImage)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(KLMSActionButtonStyle())
            .disabled(!model.isRemoteAvailable || model.isSubmitting || model.hasInFlightRequest)
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
                            .foregroundStyle(Color.klmsSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if request.isDownloadAvailable {
                        Button {
                            model.openFileAccessRequest(request)
                        } label: {
                            Label("웹 미리보기", systemImage: "safari")
                        }
                        .buttonStyle(KLMSActionButtonStyle())
                    }
                }
            } else {
                Text("Mac에 저장된 course_files 원본을 임시 서버 링크로 준비할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task {
                    await model.createFileAccessRequest(item: item)
                }
            } label: {
                Label("파일 링크 요청", systemImage: "link.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(KLMSActionButtonStyle())
            .disabled(!model.serverRelayConfigured || model.isSubmitting || request?.status.isInFlight == true)
        }
        .padding(12)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
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
            return "파일 링크를 요청하면 Mac 앱에서 course_files 원본을 임시 링크로 준비합니다. 링크가 만료되면 기록과 임시 파일은 자동으로 정리됩니다."
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
        companionItemKindTint(item.kind)
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
                    .foregroundStyle(Color.klmsSecondaryText)
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
                    .foregroundStyle(Color.klmsSecondaryText)
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
    let model: CompanionModel

    var body: some View {
        Button {
            Task {
                await model.createItemAction(action, item: item)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isOn ? Color.klmsCommandAccent : Color.klmsSecondaryText)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.klmsPrimaryText)
                    Text(isOn ? onText : offText)
                        .font(.caption)
                        .foregroundStyle(Color.klmsSecondaryText)
                }
                Spacer(minLength: 0)
                Text(isOn ? "ON" : "OFF")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isOn ? Color.klmsCommandAccent : Color.klmsSecondaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(isOn ? Color.klmsCommandBackground : Color.klmsSubtleCardBackground)
                    .clipShape(Capsule())
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(KLMSCardButtonStyle())
        .padding(10)
        .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isOn ? Color.klmsCommandBorder : Color.klmsBorder, lineWidth: 1)
        }
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
        isCompanionNewLike || isCompanionUpdatedLike || status.localizedCaseInsensitiveContains("changed")
    }

    var isCompanionNewLike: Bool {
        let text = searchText
        return text.localizedCaseInsensitiveContains("new")
            || text.localizedCaseInsensitiveContains("새")
            || text.localizedCaseInsensitiveContains("신규")
    }

    var isCompanionUpdatedLike: Bool {
        let text = searchText
        return text.localizedCaseInsensitiveContains("updated")
            || text.localizedCaseInsensitiveContains("수정")
            || text.localizedCaseInsensitiveContains("변경")
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
    var isInFlight: Bool {
        switch self {
        case .pending, .running:
            true
        case .completed, .failed, .macUnavailable:
            false
        }
    }

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
            "완료 처리"
        case .assignmentRestore, .assignmentUnhide:
            "복구"
        case .assignmentHide:
            "숨김"
        case .examPromote:
            "시험으로 등록"
        case .examIgnore:
            "시험 아님"
        case .examRestore:
            "복구"
        case .noticeRead:
            "읽음"
        case .noticeUnread:
            "읽지 않음"
        case .noticeImportant:
            "중요"
        case .noticeUnimportant:
            "중요 해제"
        case .noticeHide:
            "숨김"
        case .noticeUnhide:
            "복구"
        case .fileHide:
            "숨김"
        case .fileUnhide:
            "복구"
        case .fileTrash:
            "삭제"
        case .calendarVerify:
            "캘린더 상태 검사"
        case .calendarApply:
            "KLMS 기준 반영"
        case .calendarCreate:
            "캘린더 일정 등록"
        case .calendarEdit:
            "캘린더 내용 수정"
        case .calendarDelete:
            "캘린더 일정 삭제"
        case .mailDashboardAdd:
            "항목 반영"
        case .mailDashboardRemove:
            "항목 제거"
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
        case .calendarCreate:
            "calendar.badge.plus"
        case .calendarEdit:
            "pencil"
        case .calendarDelete:
            "calendar.badge.minus"
        case .mailDashboardAdd:
            "envelope.badge"
        case .mailDashboardRemove:
            "minus.circle"
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

    var companionButtonTone: KLMSButtonTone {
        switch self {
        case .assignmentComplete,
             .assignmentRestore,
             .assignmentUnhide,
             .examRestore,
             .noticeRead,
             .noticeUnread,
             .noticeImportant,
             .noticeUnimportant,
             .noticeUnhide,
             .fileUnhide,
             .calendarVerify,
             .calendarEdit:
            .soft
        case .examPromote,
             .calendarApply,
             .mailDashboardAdd:
            .primary
        case .calendarCreate:
            .success
        case .assignmentHide,
             .examIgnore,
             .noticeHide,
             .fileHide,
             .fileTrash,
             .calendarDelete,
             .mailDashboardRemove:
            .destructive
        }
    }

    var resolvesCalendarChange: Bool {
        switch self {
        case .calendarCreate, .calendarEdit, .calendarApply, .calendarDelete:
            true
        case .calendarVerify:
            false
        default:
            false
        }
    }
}

private struct ServerSyncDataRow: View, Equatable {
    var item: ServerRelaySyncItem
    var isSelected = false
    var accessorySystemImage: String?

    nonisolated static func == (lhs: ServerSyncDataRow, rhs: ServerSyncDataRow) -> Bool {
        lhs.isSelected == rhs.isSelected
            && lhs.accessorySystemImage == rhs.accessorySystemImage
            && lhs.item.id == rhs.item.id
            && lhs.item.kind == rhs.item.kind
            && lhs.item.course == rhs.item.course
            && lhs.item.academicTerm == rhs.item.academicTerm
            && lhs.item.title == rhs.item.title
            && lhs.item.timestamp == rhs.item.timestamp
            && lhs.item.status == rhs.item.status
            && lhs.item.attachmentCount == rhs.item.attachmentCount
            && lhs.item.isRead == rhs.item.isRead
            && lhs.item.isImportant == rhs.item.isImportant
            && lhs.item.isHidden == rhs.item.isHidden
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(primaryForeground)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kindName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(primaryForeground)
                    if !item.status.isEmpty {
                        Text(item.status)
                            .font(.caption2)
                            .foregroundStyle(secondaryForeground)
                    }
                    if item.isHidden {
                        Text("숨김")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(secondaryForeground)
                    }
                }
                Text(item.title.isEmpty ? "제목 없음" : item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.klmsSelectedForeground : Color.klmsPrimaryText)
                    .lineLimit(2)
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(secondaryForeground)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let accessorySystemImage {
                Image(systemName: accessorySystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(secondaryForeground)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .background(isSelected ? Color.klmsSelectedBackground.opacity(0.96) : Color.klmsSubtleCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.klmsSelectedBorder.opacity(0.92) : Color.klmsBorder, lineWidth: isSelected ? 1.2 : 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue(isSelected ? "선택됨" : "선택 안 됨")
    }

    private var primaryForeground: Color {
        isSelected ? Color.klmsSelectedForeground : tint
    }

    private var secondaryForeground: Color {
        Color.klmsSecondaryText
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
        return parts.isEmpty ? "세부 정보 없음" : parts.joined(separator: " · ")
    }

    private var accessibilityLabelText: String {
        [
            kindName,
            item.title.isEmpty ? "제목 없음" : item.title,
            metadata,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
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
        companionItemKindTint(item.kind)
    }
}

private struct RemoteStageDurationSummaryView: View {
    var durations: [KLMSStageDuration]

    var body: some View {
        if !durations.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("단계별 소요 시간")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsSecondaryText)
                VStack(spacing: 6) {
                    ForEach(durations) { duration in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(tint(for: duration.stage))
                                .frame(width: 6, height: 6)
                            Text(duration.displayName)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 4)
                            Text(duration.secondsText)
                                .font(.caption2)
                                .foregroundStyle(Color.klmsSecondaryText)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func tint(for stage: String) -> Color {
        switch stage {
        case "core":
            return Color.klmsWarningBorder
        case "notice":
            return Color.klmsCommandAccent
        case "files":
            return Color.klmsSecondaryText
        default:
            return Color.klmsSecondaryText
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
                    .foregroundStyle(Color.klmsSecondaryText)
            }

            if totalCount == 0 {
                Text("요청이 오면 최근 기록을 여기에 보여줍니다.")
                    .font(.caption)
                    .foregroundStyle(Color.klmsSecondaryText)
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
                    Text("전체 내역은 아래 메뉴의 로그 탭에서 볼 수 있습니다.")
                        .font(.caption2)
                        .foregroundStyle(Color.klmsSecondaryText)
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
            .foregroundStyle(Color.klmsSecondaryText)
            .padding(.top, 2)
    }
}

private struct RemoteVerifySummaryPanel: View {
    var summary: ServerRelayVerifySummary?
    @State private var showsAllChecks = false
    @State private var showsRemainingIssues = false
    private let primaryVisibleIssueCount = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: issueChecks.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issueChecks.isEmpty ? Color.klmsSuccessBorder : Color.klmsWarningBorder)
                VStack(alignment: .leading, spacing: 2) {
                    Text("상태 검사 해설")
                        .font(.subheadline.weight(.semibold))
                    Text(summaryText)
                        .font(.caption2)
                        .foregroundStyle(Color.klmsSecondaryText)
                }
                Spacer(minLength: 0)
            }

            if let summary {
                if issueChecks.isEmpty {
                    Text("메모, 파일, 캘린더, 미리 알림 검사에서 설명이 필요한 실패 항목이 없습니다.")
                        .font(.caption2)
                        .foregroundStyle(Color.klmsSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let primaryIssues = Array(issueChecks.prefix(primaryVisibleIssueCount))
                    let remainingIssues = Array(issueChecks.dropFirst(primaryVisibleIssueCount))
                    ForEach(primaryIssues, id: \.id) { check in
                        RemoteVerifyCheckRow(check: check)
                    }
                    if !remainingIssues.isEmpty {
                        DisclosureGroup(isExpanded: $showsRemainingIssues) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(remainingIssues, id: \.id) { check in
                                    RemoteVerifyCheckRow(check: check, compact: true)
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text("나머지 확인 항목 \(remainingIssues.count)개")
                                .font(.caption.weight(.semibold))
                        }
                    }
                }

                DisclosureGroup(isExpanded: $showsAllChecks) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(summary.checks, id: \.id) { check in
                            RemoteVerifyCheckRow(check: check, compact: true)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("전체 상태 검사 항목 \(summary.checks.count)개")
                        .font(.caption.weight(.semibold))
                }
            } else {
                Text("아직 Mac에서 상태 검사 결과를 서버에 올리지 않았습니다. 상태 검사를 실행하면 캘린더/미리 알림/메모 불일치를 한국어로 풀어 보여줍니다.")
                    .font(.caption2)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private var issueChecks: [VerifyCheck] {
        summary?.issueChecks ?? []
    }

    private var summaryText: String {
        guard let summary else {
            return "검사 전"
        }
        let okCount = summary.checks.filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok" }.count
        if issueChecks.isEmpty {
            return "상태 \(summary.status.klmsLocalizedStatus) · 정상 \(okCount)개"
        }
        return "상태 \(summary.status.klmsLocalizedStatus) · 확인 필요 \(issueChecks.count)개 · 정상 \(okCount)개"
    }
}

private struct RemoteVerifyCheckRow: View {
    var check: VerifyCheck
    var compact = false
    @State private var showsGuidance = false
    @State private var showsRawDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 5) {
            HStack(alignment: .top, spacing: 7) {
                if !compact {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint.opacity(isIssue ? 0.72 : 0.24))
                        .frame(width: 3)
                }
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(check.diagnosticTitle) · \(check.status.klmsLocalizedStatus)")
                        .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                    if compact {
                        Text(rawDetail)
                            .font(.caption2)
                            .foregroundStyle(Color.klmsSecondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !compact {
                Text(check.diagnosticExplanation)
                    .font(.caption2)
                    .foregroundStyle(Color.klmsPrimaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup(isExpanded: $showsGuidance) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(check.diagnosticExplanation)
                            .font(.caption2)
                            .foregroundStyle(Color.klmsPrimaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(check.diagnosticNextAction)
                            .font(.caption2)
                            .foregroundStyle(Color.klmsSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if !rawDetail.isEmpty {
                            DisclosureGroup(isExpanded: $showsRawDetail) {
                                Text(rawDetail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Color.klmsSecondaryText)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            } label: {
                                Text("원본 보기")
                                    .font(.caption2.weight(.semibold))
                            }
                        }
                    }
                    .padding(.top, 3)
                } label: {
                    Text("원인과 조치 보기")
                        .font(.caption2.weight(.semibold))
                }
            }
        }
        .padding(compact ? 7 : 9)
        .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(compact ? 0.10 : (isIssue ? 0.34 : 0.18)), lineWidth: 1)
        }
    }

    private var rawDetail: String {
        check.detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var status: String {
        check.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var systemImage: String {
        if ["fail", "failed", "error"].contains(status) {
            return "xmark.octagon.fill"
        }
        if ["warn", "warning"].contains(status) {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var tint: Color {
        if ["fail", "failed", "error"].contains(status) {
            return Color.klmsDangerBorder
        }
        if ["warn", "warning"].contains(status) {
            return Color.klmsWarningBorder
        }
        return Color.klmsSuccessBorder
    }

    private var isIssue: Bool {
        ["fail", "failed", "error", "warn", "warning"].contains(status)
    }
}

private struct RemoteDiagnosticPanel: View {
    @ObservedObject var model: CompanionModel
    @State private var isPanelExpanded = false

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 8),
    ]
    private let dryRunCommands: [RemoteCommandKind] = [.fullSync, .filesSync, .coreSync, .noticeSync]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isPanelExpanded.toggle()
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.klmsCommandAccent)
                        .frame(width: 32, height: 32)
                        .background(Color.klmsCommandAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("진단")
                            .font(.headline)
                        Text("상태 검사와 권한 점검은 필요할 때만 펼치세요.")
                            .font(.caption)
                            .foregroundStyle(Color.klmsSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    CompanionExpansionBadge(isExpanded: isPanelExpanded)
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(KLMSCardButtonStyle(cornerRadius: 12))
            .accessibilityHint(isPanelExpanded ? "진단 도구 접기" : "진단 도구 펼치기")

            if isPanelExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    RemoteVerifySummaryPanel(summary: model.verifySummary)
                    Text("권장 순서: 상태 검사 → 권한/환경 진단 → 리포트")
                        .font(.caption)
                        .foregroundStyle(Color.klmsSecondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    LazyVGrid(columns: columns, spacing: 8) {
                        diagnosticButton(.verify)
                        diagnosticButton(.doctor)
                        diagnosticButton(.report)
                    }
                    RemoteStageDurationSummaryView(durations: model.latestSharedRunLogStageDurations)

                    CompanionSettingsSubsectionCard(
                        title: "고급 도구",
                        detail: "변경 예정량과 내부 상태 파일을 점검합니다.",
                        systemImage: "slider.horizontal.3",
                        collapsible: true
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("실제 반영 없이 바뀔 항목 수를 보거나 내부 상태 파일만 다시 만듭니다.")
                                .font(.caption2)
                                .foregroundStyle(Color.klmsSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            diagnosticButton(.v2BuildState)
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(dryRunCommands, id: \.self) { command in
                                    dryRunButton(command)
                                }
                            }
                            RemoteDryRunPanel(reports: model.dryRunReports)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
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
                    .foregroundStyle(Color.klmsSecondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
        }
        .buttonStyle(KLMSActionButtonStyle())
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
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(KLMSActionButtonStyle())
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
                    .foregroundStyle(Color.klmsSecondaryText)
            }
            if reports.isEmpty {
                Text("변경량 계산을 실행하면 변경 예정량이 여기에 표시됩니다.")
                    .font(.caption)
                    .foregroundStyle(Color.klmsSecondaryText)
            } else {
                ForEach(reports, id: \.scope) { report in
                    RemoteDryRunReportRow(report: report)
                }
            }
        }
        .padding(12)
        .background(Color.klmsSubtleCardBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.klmsBorder.opacity(0.82), lineWidth: 1)
        }
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
                    .foregroundStyle(Color.klmsSecondaryText)
            }
            Text([
                report.wouldCreate > 0 ? "생성 \(report.wouldCreate)" : nil,
                report.wouldUpdate > 0 ? "수정 \(report.wouldUpdate)" : nil,
                report.wouldDelete > 0 ? "삭제 \(report.wouldDelete)" : nil,
                report.wouldDownload > 0 ? "다운로드 \(report.wouldDownload)" : nil,
                report.wouldPrune > 0 ? "정리 \(report.wouldPrune)" : nil,
            ].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "변경 예정 없음")
                .font(.caption)
                .foregroundStyle(Color.klmsSecondaryText)
        }
        .padding(10)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.klmsBorder.opacity(0.72), lineWidth: 1)
        }
    }
}

private struct RemoteSettingsPanel: View {
    @ObservedObject var model: CompanionModel
    var usesWideGrid = false

    private var settingGroups: [RemoteSettingGroup] {
        RemoteSettingGroup.grouped(settings: model.remoteSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "macbook.and.iphone")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.klmsCommandAccent)
                    .frame(width: 32, height: 32)
                    .background(Color.klmsCommandAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac 동기화 설정")
                        .font(.headline)
                    Text("Mac에서 실행할 동기화 방식을 정합니다.")
                        .font(.caption)
                        .foregroundStyle(Color.klmsSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(model.remoteSettings.isEmpty ? "대기" : "\(model.remoteSettings.count)개")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.klmsSecondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.klmsSubtleCardBackground, in: Capsule())
            }

            VStack(alignment: .leading, spacing: 10) {
                CompanionSettingHelpText("변경한 값은 서버에 저장되고 Mac 앱이 받아 적용합니다.")
                if model.remoteSettings.isEmpty {
                    Text("Mac 앱이 설정 목록을 올리면 여기에서 바꿀 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(Color.klmsSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 10))
                } else if usesWideGrid {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260), spacing: 10, alignment: .top)],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        ForEach(settingGroups) { group in
                            RemoteSettingGroupSection(group: group, model: model)
                        }
                    }
                } else {
                    ForEach(settingGroups) { group in
                        RemoteSettingGroupSection(group: group, model: model)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }
}

private struct RemoteSettingGroup: Identifiable {
    var title: String
    var systemImage: String
    var detail: String
    var expandedDetail: String
    var settings: [ServerRelaySetting]

    var id: String { title }
    var countText: String { "\(settings.count)개" }
    var hasExpandedDetail: Bool {
        !expandedDetail.isEmpty && expandedDetail != detail
    }
    var isDefaultExpanded: Bool {
        title != "Safari" && title != "고급"
    }
    var isCollapsible: Bool {
        title == "Safari" || title == "고급"
    }

    static func grouped(settings: [ServerRelaySetting]) -> [RemoteSettingGroup] {
        let byKey = Dictionary(settings.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var used = Set<String>()
        let specs: [(String, String, String, String, [String])] = [
            (
                "로그인",
                "person.badge.key",
                "로그인 확인과 인증번호 표시 방식을 정합니다.",
                "인증번호 감지와 로그인 보조 방식을 정합니다. 동기화 중 필요한 알림은 어떤 탭에 있어도 상단에 바로 표시됩니다.",
                ["KLMS_LOGIN_ASSIST_ENABLED", "KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE"]
            ),
            (
                "실행",
                "arrow.triangle.2.circlepath",
                "동기화 범위와 캘린더 반영 방식을 정합니다.",
                "동기화 범위, 변경 없는 캘린더 항목 처리 기준을 정합니다. 값은 서버에 저장되어 Mac, iPhone, iPad가 같은 기준을 봅니다.",
                ["SYNC_MODE", "CALENDAR_SKIP_UNCHANGED_DESIRED"]
            ),
            (
                "파일",
                "folder",
                "파일 확인과 폴더 정리 방식을 정합니다.",
                "파일 탐색 방식, 주차별 폴더 정리, 로컬 파일 보존 기준을 정합니다. 로컬 파일과 KLMS 등록 시각이 같으면 다시 받지 않습니다.",
                ["FILE_REFRESH_MODE", "FILE_SKIP_DOWNLOAD_WHEN_PREVIEW_EMPTY", "FILE_WEEKLY_FOLDERS_ENABLED", "FILE_KEEP_FRESH_DOWNLOADS", "FILE_PRESERVE_DOWNLOAD_ARCHIVE"]
            ),
            (
                "공지 메모",
                "checklist",
                "숨긴 공지와 변경 없는 메모 처리 방식을 정합니다.",
                "숨긴 공지를 Notes에 쓸지, 내용이 같은 공지를 다시 렌더링할지 정합니다. 메모 업데이트를 끄면 공지 수집은 유지하고 Notes 쓰기만 건너뜁니다.",
                ["NOTICE_HIDE_HIDDEN_ITEMS", "NOTICE_NATIVE_STABLE_NOOP_SKIP"]
            ),
            (
                "Safari",
                "safari",
                "KLMS를 읽을 때 쓰는 전용 Safari 창의 동작을 정합니다.",
                "앱이 사용자 화면을 덜 방해하도록 전용 Safari 창을 관리합니다. 기존 Safari 창 재사용 여부도 여기에서 정합니다.",
                ["KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED", "KLMS_SAFARI_BACKGROUND_WINDOW_MODE", "KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED"]
            ),
        ]

        var groups: [RemoteSettingGroup] = specs.compactMap { spec in
            let (title, systemImage, detail, expandedDetail, keys) = spec
            let groupSettings = keys.compactMap { key -> ServerRelaySetting? in
                guard let setting = byKey[key] else { return nil }
                used.insert(key)
                return setting
            }
            guard !groupSettings.isEmpty else { return nil }
            return RemoteSettingGroup(title: title, systemImage: systemImage, detail: detail, expandedDetail: expandedDetail, settings: groupSettings)
        }

        let extras = settings.filter { !used.contains($0.key) }
        if !extras.isEmpty {
            groups.append(
                RemoteSettingGroup(
                    title: "고급",
                    systemImage: "slider.horizontal.3",
                    detail: "기본 화면에 분류되지 않은 설정입니다.",
                    expandedDetail: "평소에는 바꾸지 않아도 됩니다. 정확히 의미를 아는 값만 수정하는 것이 안전합니다.",
                    settings: extras
                )
            )
        }
        return groups
    }
}

private struct RemoteSettingGroupSection: View {
    var group: RemoteSettingGroup
    @ObservedObject var model: CompanionModel
    @State private var isExpanded: Bool
    @State private var showsDetail = false

    init(group: RemoteSettingGroup, model: CompanionModel) {
        self.group = group
        self.model = model
        _isExpanded = State(initialValue: group.isDefaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if group.isCollapsible {
                Button {
                    companionPerformWithoutAnimation {
                        isExpanded.toggle()
                    }
                } label: {
                    groupHeader
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(KLMSCardButtonStyle(cornerRadius: 10))
                .accessibilityHint(isExpanded ? "\(group.title) 설정 접기" : "\(group.title) 설정 펼치기")
            } else {
                Button {
                    companionPerformWithoutAnimation {
                        showsDetail.toggle()
                    }
                } label: {
                    groupHeader
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(KLMSCardButtonStyle(cornerRadius: 10))
                .accessibilityHint(showsDetail ? "\(group.title) 설명 접기" : "\(group.title) 설명 보기")
            }

            if shouldShowExpandedDetail {
                CompanionSettingHelpText(group.expandedDetail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.klmsCardBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.klmsBorder.opacity(0.50), lineWidth: 1)
                    )
            }

            if !group.isCollapsible || isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.settings) { setting in
                        RemoteSettingRow(setting: setting, model: model)
                    }
                }
            }
        }
        .padding(11)
        .background(
            (!group.isCollapsible || isExpanded) ? Color.klmsSubtleCardBackground.opacity(0.86) : Color.klmsSubtleCardBackground.opacity(0.58),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke((!group.isCollapsible || isExpanded) ? Color.klmsSelectedBorder.opacity(0.48) : Color.klmsBorder.opacity(0.86), lineWidth: 1)
        )
    }

    private var shouldShowExpandedDetail: Bool {
        group.hasExpandedDetail && (showsDetail || (group.isCollapsible && isExpanded))
    }

    private var groupHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: group.systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.klmsCommandAccent)
                .frame(width: 28, height: 28)
                .background(Color.klmsCommandAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                Text(group.detail)
                    .font(.caption2)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(group.countText)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.klmsSecondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.klmsCardBackground, in: Capsule())
                if group.isCollapsible {
                    CompanionExpansionBadge(isExpanded: isExpanded, compact: true)
                } else if group.hasExpandedDetail {
                    CompanionInlineDetailBadge(isExpanded: showsDetail)
                }
            }
        }
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
            "전체 기록 지우기"
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
            return "실행 \(result.commands)개, 서버 요청 \(result.requestLogEntries)개, 파일 요청 \(result.fileAccessRequests)개, 항목 변경 \(result.itemActions)개, 설정 변경 \(result.settingActions)개 기록을 지웠습니다."
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
            "이 기기 화면의 완료된 실행, 서버 요청, 파일 요청, 항목 변경, 설정 변경 기록을 숨겼습니다. 진행 중인 요청은 유지됩니다."
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
    var showsInlineDetail = true
    var selectedKind: Binding<RemoteLogSummaryKind?>? = nil
    @State private var localExpandedKind: RemoteLogSummaryKind?

    private var expandedKind: RemoteLogSummaryKind? {
        selectedKind?.wrappedValue ?? localExpandedKind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("로그 요약", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer(minLength: 8)
                if let lastRefreshAt = model.lastRefreshAt {
                    Text(lastRefreshAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(Color.klmsSecondaryText)
                }
                Button {
                    Task {
                        await model.clearRemoteLogs()
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(KLMSActionButtonStyle(tone: .destructive))
                .disabled(!model.serverRelayConfigured || model.isSubmitting || !model.hasClearableRemoteLogs)
                .accessibilityLabel("전체 기록 지우기")
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
                if !compact || model.latestRemoteLogFileRequest != nil {
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
                    if showsInlineDetail {
                        RemoteLogDetailPanel(kind: expandedKind, model: model)
                    }
                } else if showsInlineDetail || compact {
                    Text("행을 누르면 펼쳐집니다.")
                        .font(.caption2)
                        .foregroundStyle(Color.klmsSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private var currentCommand: RemoteRunCommand? {
        model.currentRemoteLogCommand
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
            return Color.klmsWarningBorder
        }
        if model.hasInFlightRequest || model.status.phase == "running" {
            return .klmsCommandAccent
        }
        if model.latestDisplayStatus == .failed || model.latestDisplayStatus == .macUnavailable {
            return Color.klmsWarningBorder
        }
        if model.latestDisplayStatus == .cancelled {
            return Color.klmsSecondaryText
        }
        return Color.klmsSuccessBorder
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
                ? "실행하면 Mac에 요청이 올라갑니다."
                : "지난 기록은 펼쳐서 봅니다."
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
            return Color.klmsSuccessBorder
        case .cancelled:
            return Color.klmsSecondaryText
        case .failed, .macUnavailable:
            return Color.klmsWarningBorder
        case nil:
            return Color.klmsSecondaryText
        }
    }

    private var fileRequestValue: String {
        guard let latestFileRequest = model.latestRemoteLogFileRequest else {
            return "요청 없음"
        }
        return latestFileRequest.status.displayName
    }

    private var fileRequestDetail: String {
        guard let latestFileRequest = model.latestRemoteLogFileRequest else {
            return model.recentFileAccessRequests.isEmpty
                ? "파일에서 링크 요청을 누르면 임시 링크를 준비합니다."
                : "지난 기록은 펼쳐서 봅니다."
        }
        let title = latestFileRequest.itemTitle.nilIfEmpty ?? "파일"
        let message = latestFileRequest.message.nilIfEmpty ?? latestFileRequest.updatedAt.formatted(date: .omitted, time: .shortened)
        return "\(title) · \(message)"
    }

    private var fileRequestSystemImage: String {
        switch model.latestRemoteLogFileRequest?.status {
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
        switch model.latestRemoteLogFileRequest?.status {
        case .pending, .running:
            return .klmsCommandAccent
        case .completed:
            return Color.klmsSuccessBorder
        case .failed, .macUnavailable:
            return Color.klmsWarningBorder
        case nil:
            return Color.klmsSecondaryText
        }
    }

    private func toggle(_ kind: RemoteLogSummaryKind) {
        if let selectedKind {
            selectedKind.wrappedValue = expandedKind == kind ? nil : kind
        } else {
            localExpandedKind = expandedKind == kind ? nil : kind
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
                        || !model.hasClearableCommandLogs
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
                        || !model.hasClearableFileAccessLogs
                        || model.activeRemoteLogFileRequest != nil
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }

    private var statusDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let digits = model.status.authDigits {
                DetailFieldRow(title: "인증번호", value: digits)
            }
            if model.status.loginRequired {
                DetailFieldRow(title: "로그인", value: "KLMS 로그인이 필요합니다.")
            }
            if model.status.phase == "running" || model.hasInFlightRequest {
                DetailFieldRow(title: "단계", value: model.status.phase.klmsRemotePhaseName)
                DetailFieldRow(title: "세부 단계", value: model.runningPhaseDetail ?? "처리 중")
            }
            if let activeCommand {
                DetailFieldRow(title: "실행 중", value: "\(activeCommand.kind.displayName) · \(activeCommand.displayStatus().displayName)")
            }
            if let activeFileRequest {
                DetailFieldRow(title: "파일 요청", value: "\(activeFileRequest.itemTitle.nilIfEmpty ?? "파일") · \(activeFileRequest.status.displayName)")
            }
            if !hasCurrentDetail {
                Text("현재 진행 중인 요청이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var activeCommand: RemoteRunCommand? {
        model.activeRemoteLogCommand
    }

    private var activeFileRequest: ServerRelayFileAccessRequest? {
        model.activeRemoteLogFileRequest
    }

    private var hasCurrentDetail: Bool {
        model.status.authDigits != nil
            || model.status.loginRequired
            || model.status.phase == "running"
            || activeCommand != nil
            || activeFileRequest != nil
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
                        .foregroundStyle(Color.klmsSecondaryText)
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Color.klmsSecondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsSecondaryText)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(isExpanded ? Color.klmsSelectedBackground.opacity(0.96) : Color.klmsSubtleCardBackground.opacity(0.62), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isExpanded ? Color.klmsSelectedBorder.opacity(0.82) : Color.klmsBorder.opacity(0.88), lineWidth: isExpanded ? 1.2 : 1)
            )
        }
        .buttonStyle(KLMSCardButtonStyle(cornerRadius: 12))
        .accessibilityLabel("\(title) \(value). \(detail). \(isExpanded ? "펼쳐짐" : "접힘")")
        .accessibilityHint(isExpanded ? "관련 기록 접기" : "관련 기록 펼치기")
    }
}

private struct SharedRunLogsView: View {
    var logs: [ServerRelayRunLog]
    var stageDurationsByID: [String: [KLMSStageDuration]] = [:]
    var clearAction: (() -> Void)?
    var clearDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("동기화 단계")
                    .font(.headline)
                Spacer()
                if !logs.isEmpty {
                    Text("최근 \(logs.count)개")
                        .font(.caption)
                        .foregroundStyle(Color.klmsSecondaryText)
                }
                if let clearAction {
                    Button(action: clearAction) {
                        Image(systemName: "trash")
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(KLMSActionButtonStyle(tone: .destructive))
                    .accessibilityLabel("동기화 단계 기록 지우기")
                    .disabled(clearDisabled)
                }
            }
            Text("단계별 시간과 마지막 로그를 보여줍니다.")
                .font(.caption2)
                .foregroundStyle(Color.klmsSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if logs.isEmpty {
                Text("아직 표시할 동기화 단계 기록이 없습니다.")
                    .foregroundStyle(Color.klmsSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.klmsSubtleCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(logs.prefix(30)) { log in
                        SharedRunLogRow(
                            log: log,
                            stageDurations: stageDurationsByID[log.id] ?? []
                        )
                    }
                }
            }
        }
    }
}

private struct SharedRunLogRow: View {
    var log: ServerRelayRunLog
    var stageDurations: [KLMSStageDuration]
    @State private var isExpanded = false

    var body: some View {
        Button {
            companionPerformWithoutAnimation {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(log.commandTitle.nilIfEmpty ?? "동기화")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(log.status) · \(log.duration) · \(log.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(Color.klmsSecondaryText)
                            .lineLimit(2)
                        CompactRemoteStageDurationRowsView(durations: stageDurations)
                        if log.dryRun {
                            Text("미리보기 실행")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.klmsSecondaryText)
                        }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.klmsSecondaryText)
                }
                DeferredInteractionExpansion(isExpanded: isExpanded) {
                    RemoteStageDurationSummaryView(durations: stageDurations)
                    CompanionInlineLogBlock(text: log.outputTail)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isExpanded ? Color.klmsSelectedBackground.opacity(0.96) : Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isExpanded ? Color.klmsSelectedBorder.opacity(0.82) : tint.opacity(0.20), lineWidth: isExpanded ? 1.2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(KLMSCardButtonStyle(cornerRadius: 12))
        .accessibilityLabel("\(log.commandTitle.nilIfEmpty ?? "동기화") 로그 \(isExpanded ? "접기" : "펼치기")")
        .accessibilityHint("단계별 소요 시간과 마지막 로그를 보여줍니다.")
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
            return Color.klmsSecondaryText
        }
        return log.needsAttention ? Color.klmsWarningBorder : Color.klmsSuccessBorder
    }

}

private struct CompactRemoteStageDurationRowsView: View {
    var durations: [KLMSStageDuration]

    var body: some View {
        if !durations.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(durations) { duration in
                    HStack(spacing: 4) {
                        Text(duration.displayName)
                            .font(.caption.weight(.semibold))
                        Text(duration.secondsText)
                            .font(.caption)
                    }
                    .foregroundStyle(Color.klmsSecondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
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
                        .foregroundStyle(Color.klmsSecondaryText)
                }
                if let clearAction {
                    Button(action: clearAction) {
                        Image(systemName: "trash")
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(KLMSActionButtonStyle(tone: .destructive))
                    .accessibilityLabel("파일 요청 기록 지우기")
                    .disabled(clearDisabled)
                }
            }
            if requests.isEmpty {
                Text("아직 파일 요청 기록이 없습니다.")
                    .foregroundStyle(Color.klmsSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.klmsSubtleCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(requests.prefix(30)) { request in
                        RemoteFileAccessRequestRow(request: request)
                    }
                    if requests.count > 30 {
                        Text("최근 30개만 표시합니다.")
                            .font(.caption)
                            .foregroundStyle(Color.klmsSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)
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
                        .foregroundStyle(Color.klmsSecondaryText)
                }
                if let clearAction {
                    Button(action: clearAction) {
                        Image(systemName: "trash")
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(KLMSActionButtonStyle(tone: .destructive))
                    .accessibilityLabel("서버 요청 기록 지우기")
                    .disabled(clearDisabled)
                }
            }
            if entries.isEmpty {
                Text("아직 서버 요청 기록이 없습니다.")
                    .foregroundStyle(Color.klmsSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.klmsSubtleCardBackground)
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
        Button {
            companionPerformWithoutAnimation {
                isExpanded.toggle()
            }
        } label: {
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
                                .foregroundStyle(Color.klmsSecondaryText)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.klmsSubtleCardBackground, in: Capsule())
                        }
                        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(Color.klmsSecondaryText)
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(Color.klmsSecondaryText)
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
                            .foregroundStyle(Color.klmsSecondaryText)
                    }
                }
                DeferredInteractionExpansion(isExpanded: isExpanded) {
                    CompanionInlineLogBlock(text: expandedLog)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.klmsBorder, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(KLMSCardButtonStyle(cornerRadius: 10))
        .accessibilityLabel("\(entry.action.nilIfEmpty ?? entry.path.nilIfEmpty ?? "서버 요청") 기록 \(isExpanded ? "접기" : "펼치기")")
        .accessibilityHint("요청 출처와 상세 로그를 보여줍니다.")
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
            return Color.klmsWarningBorder
        case "running":
            return Color.klmsCommandAccent
        default:
            return Color.klmsSuccessBorder
        }
    }
}

private struct RemoteFileAccessRequestRow: View {
    var request: ServerRelayFileAccessRequest
    @State private var isExpanded = false

    var body: some View {
        Button {
            companionPerformWithoutAnimation {
                isExpanded.toggle()
            }
        } label: {
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
                            .foregroundStyle(Color.klmsSecondaryText)
                        if let message = request.message.nilIfEmpty {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(Color.klmsSecondaryText)
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
                            .foregroundStyle(Color.klmsSecondaryText)
                    }
                }
                DeferredInteractionExpansion(isExpanded: isExpanded) {
                    CompanionInlineLogBlock(text: expandedLog)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(0.16), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(KLMSCardButtonStyle(cornerRadius: 8))
        .accessibilityLabel("\(request.itemTitle.nilIfEmpty ?? "파일") 요청 기록 \(isExpanded ? "접기" : "펼치기")")
        .accessibilityHint("파일 요청 상태와 상세 로그를 보여줍니다.")
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
            return Color.klmsCommandAccent
        case .completed:
            return Color.klmsSuccessBorder
        case .failed, .macUnavailable:
            return Color.klmsWarningBorder
        }
    }
}

private struct CompanionInlineLogBlock: View {
    var text: String
    private let displayText: String
    private let highlights: [KLMSLogHighlight]

    init(text: String) {
        self.text = text
        let boundedText = Self.boundedText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "표시할 로그가 없습니다."
        self.displayText = boundedText
        self.highlights = KLMSReadableLogParser.highlights(from: boundedText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompanionReadableLogHighlightsView(highlights: highlights)
            Text(displayText)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.klmsSecondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.klmsBorder, lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func boundedText(_ text: String) -> String {
        let maxCharacters = 6_000
        guard text.count > maxCharacters else {
            return text
        }
        let prefix = "... 화면 표시용으로 이전 로그 일부를 접었습니다 ...\n"
        return prefix + String(text.suffix(maxCharacters - prefix.count))
    }
}

private struct CompanionReadableLogHighlightsView: View {
    var highlights: [KLMSLogHighlight]

    var body: some View {
        if !highlights.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("핵심 로그")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsSecondaryText)
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(highlights) { highlight in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: systemImage(for: highlight.level))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(tint(for: highlight.level))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(highlight.title)
                                    .font(.caption.weight(.semibold))
                                Text(highlight.detail.klmsDisplayText)
                                    .font(.caption2)
                                    .foregroundStyle(Color.klmsSecondaryText)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(tint(for: highlight.level).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(tint(for: highlight.level).opacity(0.18), lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    private func systemImage(for level: String) -> String {
        switch level {
        case "error", "warning":
            return "exclamationmark.triangle.fill"
        case "auth":
            return "iphone.radiowaves.left.and.right"
        case "success":
            return "checkmark.circle.fill"
        case "summary":
            return "list.bullet.rectangle"
        default:
            return "info.circle"
        }
    }

    private func tint(for level: String) -> Color {
        switch level {
        case "error", "warning", "auth":
            return Color.klmsWarningBorder
        case "success":
            return Color.klmsSuccessBorder
        case "summary":
            return Color.klmsCommandAccent
        default:
            return Color.klmsSecondaryText
        }
    }
}

private struct RemoteSettingRow: View {
    var setting: ServerRelaySetting
    @ObservedObject var model: CompanionModel
    @State private var draftValue = ""
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                companionPerformWithoutAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(setting.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.klmsPrimaryText)
                        if let detail = settingExplanation {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(Color.klmsSecondaryText)
                                .lineLimit(isExpanded ? 3 : 1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(settingValueSummary)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.klmsSecondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.klmsSubtleCardBackground, in: Capsule())
                        CompanionExpansionBadge(isExpanded: isExpanded, compact: true)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(KLMSCardButtonStyle(cornerRadius: 9))
            .accessibilityHint(isExpanded ? "\(setting.title) 설정 접기" : "\(setting.title) 설정 펼치기")

            if isExpanded {
                CompanionSettingsControlContainer {
                    control
                }
                .padding(.top, 2)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isExpanded ? Color.klmsCardBackground.opacity(0.96) : Color.klmsCardBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isExpanded ? Color.klmsSelectedBorder.opacity(0.44) : Color.klmsBorder.opacity(0.82), lineWidth: 1)
        }
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
                Label(setting.boolValue ? "켜짐" : "꺼짐", systemImage: setting.boolValue ? "checkmark.circle.fill" : "circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(KLMSActionButtonStyle(tone: setting.boolValue ? .success : .soft))
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
                HStack {
                    Text(setting.value.nilIfEmpty ?? "선택")
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(KLMSActionButtonStyle())
            .disabled(!setting.editable || model.isSubmitting)
        case .number, .text:
            HStack(spacing: 6) {
                TextField("값", text: $draftValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120)
                Button("저장") {
                    Task {
                        await model.createSettingAction(setting: setting, value: draftValue)
                    }
                }
                .frame(minHeight: 44)
                .buttonStyle(KLMSActionButtonStyle())
                .disabled(!setting.editable || model.isSubmitting || draftValue == setting.value)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var settingExplanation: String? {
        switch setting.key {
        case "SYNC_MODE":
            return "자동은 캐시와 변경 여부를 보고 필요한 범위를 고릅니다. 빠른 모드는 기존 데이터를 우선 재사용하고, 전체는 가능한 데이터를 다시 읽습니다."
        case "FILE_REFRESH_MODE":
            return "자동은 변경 가능성이 있는 파일 페이지를 더 확인합니다. 빠른 모드는 기존 캐시 재사용을 우선합니다."
        case "FILE_SKIP_DOWNLOAD_WHEN_PREVIEW_EMPTY":
            return "변경량 계산에서 새 파일이나 수정된 파일이 없으면 실제 다운로드 단계를 건너뜁니다."
        case "FILE_WEEKLY_FOLDERS_ENABLED":
            return "파일을 과목, 주차, KLMS 출처 구조에 맞춰 정리합니다. 기본값은 켜짐입니다."
        case "NOTICE_HIDE_HIDDEN_ITEMS":
            return "숨긴 공지는 Notes 메모에 쓰지 않습니다. KLMS 원본 공지는 그대로 둡니다."
        case "NOTICE_NATIVE_STABLE_NOOP_SKIP":
            return "읽음/중요 표시는 유지하되, 공지 내용이 그대로면 Notes 메모를 다시 쓰지 않습니다."
        case "KLMS_SAFARI_BACKGROUND_WINDOW_MODE":
            return "KLMS 전용 Safari 창을 처리하는 방식입니다. 기본값은 최소화입니다."
        default:
            return nil
        }
    }

    private var settingValueSummary: String {
        switch setting.valueKind {
        case .bool:
            return setting.boolValue ? "켜짐" : "꺼짐"
        case .choice:
            return setting.value.nilIfEmpty ?? "선택"
        case .number, .text:
            return compactSettingValueSummary(setting.value)
        }
    }

    private func compactSettingValueSummary(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "비어 있음"
        }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.count > 18 {
            return "저장됨"
        }
        return trimmed
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
                        .foregroundStyle(Color.klmsSecondaryText)
                }
                if let clearAction {
                    Button(action: clearAction) {
                        Image(systemName: "trash")
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(KLMSActionButtonStyle(tone: .destructive))
                    .accessibilityLabel("최근 요청 기록 지우기")
                    .disabled(clearDisabled)
                }
            }
            if commands.isEmpty {
                Text("아직 요청 기록이 없습니다.")
                    .foregroundStyle(Color.klmsSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.klmsSubtleCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(commands.prefix(30)) { command in
                        RemoteCommandRow(command: command, compact: compact)
                    }
                    if commands.count > 30 {
                        Text("최근 30개만 표시합니다.")
                            .font(.caption)
                            .foregroundStyle(Color.klmsSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)
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
        Button {
            companionPerformWithoutAnimation {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: command.kind.engineCommand.systemImage)
                        .foregroundStyle(Color.klmsSecondaryText)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(command.kind.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(command.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(Color.klmsSecondaryText)
                        if !compact {
                            Text(summaryText)
                                .font(.caption2)
                                .foregroundStyle(Color.klmsSecondaryText)
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
                                .foregroundStyle(Color.klmsWarningBorder)
                        } else if command.displayStatus().isInFlight,
                                  let authStatusMessage = command.summary.authStatusMessage {
                            Text(authStatusMessage)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.klmsSuccessBorder)
                        } else if command.loginRequired {
                            Text("로그인 필요")
                                .font(.caption2)
                                .foregroundStyle(Color.klmsWarningBorder)
                        } else if let exitCode = command.lastExitCode {
                            Text("종료 \(exitCode)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.klmsSecondaryText)
                        }
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.klmsSecondaryText)
                    }
                }
                DeferredInteractionExpansion(isExpanded: isExpanded) {
                    CompanionInlineLogBlock(text: expandedLog)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.klmsBorder, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(KLMSCardButtonStyle(cornerRadius: 8))
        .accessibilityLabel("\(command.kind.displayName) 원격 실행 기록 \(isExpanded ? "접기" : "펼치기")")
        .accessibilityHint("실행 상태와 상세 로그를 보여줍니다.")
    }

    private var statusColor: Color {
        switch command.displayStatus() {
        case .pending, .running:
            Color.klmsCommandAccent
        case .completed:
            Color.klmsSuccessBorder
        case .cancelled:
            Color.klmsSecondaryText
        case .failed, .macUnavailable:
            Color.klmsWarningBorder
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
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                companionPerformWithoutAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "lock")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.klmsCommandAccent)
                        .frame(width: 32, height: 32)
                        .background(Color.klmsCommandAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("개인정보와 서버 보관")
                            .font(.subheadline.weight(.semibold))
                        Text("서버에는 실행 요청과 요약 상태만 저장됩니다.")
                            .font(.caption)
                            .foregroundStyle(Color.klmsSecondaryText)
                    }
                    Spacer(minLength: 0)
                    CompanionExpansionBadge(isExpanded: isExpanded, compact: true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(KLMSCardButtonStyle(cornerRadius: 12))
            .accessibilityHint(isExpanded ? "개인정보 보관 설명 접기" : "개인정보 보관 설명 펼치기")

            if isExpanded {
                Text("파일 열기를 요청할 때만 Mac이 임시 링크를 만들고, 만료되면 정리합니다.")
                    .font(.caption)
                    .foregroundStyle(Color.klmsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.klmsBorder, lineWidth: 1)
        }
    }
}

private struct CompanionExpansionBadge: View {
    var isExpanded: Bool
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: compact ? 9 : 10, weight: .bold))
            Text(isExpanded ? "접기" : "펼치기")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(isExpanded ? Color.klmsSelectedForeground : Color.klmsSecondaryText)
        .padding(.horizontal, compact ? 7 : 8)
        .padding(.vertical, compact ? 4 : 5)
        .background(
            isExpanded ? Color.klmsSelectedBackground.opacity(0.92) : Color.klmsSubtleCardBackground,
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    isExpanded ? Color.klmsSelectedBorder.opacity(0.64) : Color.klmsBorder.opacity(0.72),
                    lineWidth: 1
                )
        }
    }
}

private struct CompanionDetailDisclosureBadge: View {
    var isExpanded: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
            Text(isExpanded ? "설명 접기" : "설명 보기")
                .font(.caption2.weight(.semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(isExpanded ? Color.klmsSelectedForeground : Color.klmsSecondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isExpanded ? Color.klmsSelectedBackground.opacity(0.20) : Color.klmsSubtleCardBackground.opacity(0.54),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(isExpanded ? Color.klmsSelectedBorder.opacity(0.44) : Color.klmsBorder.opacity(0.62), lineWidth: 1)
        }
    }
}

private struct CompanionInlineDetailBadge: View {
    var isExpanded: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isExpanded ? "chevron.up" : "info.circle")
                .font(.system(size: 9, weight: .bold))
            Text(isExpanded ? "접기" : "설명")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(isExpanded ? Color.klmsSelectedForeground : Color.klmsSecondaryText)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            isExpanded ? Color.klmsSelectedBackground.opacity(0.88) : Color.klmsSubtleCardBackground.opacity(0.76),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    isExpanded ? Color.klmsSelectedBorder.opacity(0.62) : Color.klmsBorder.opacity(0.62),
                    lineWidth: 1
                )
        }
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
            .foregroundStyle(Color.klmsSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InfoBanner: View {
    var message: String

    var body: some View {
        Label(message, systemImage: "info.circle")
            .font(.subheadline)
            .foregroundStyle(Color.klmsSecondaryText)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsCommandBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.klmsCommandBorder, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ErrorBanner: View {
    var message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .foregroundStyle(Color.klmsDangerBorder)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.klmsDangerBorder.opacity(0.48), lineWidth: 1)
            }
    }
}

private struct AuthSuccessBanner: View {
    var message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.klmsSuccessBorder)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsSuccessBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.klmsSuccessBorder, lineWidth: 1)
            }
    }
}

private struct AuthCodeHero: View {
    var digits: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("KAIST 인증 번호")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.klmsPrimaryText)
                Text("휴대폰 인증 화면에서 같은 번호를 선택하세요.")
                    .font(.subheadline)
                    .foregroundStyle(Color.klmsSecondaryText)
            }
            Spacer(minLength: 0)
            Text(digits)
                .font(.system(size: 38, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.klmsWarningBorder)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.klmsWarningBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.klmsWarningBorder.opacity(0.44), lineWidth: 1)
                }
                .accessibilityLabel("KAIST 인증 번호 \(digits)")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsSubtleCardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.klmsBorder, lineWidth: 1)
        )
    }
}

private struct LoginAttentionBanner: View {
    var message: String

    var body: some View {
        Label(message, systemImage: "key")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.klmsWarningBorder)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsWarningBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.klmsWarningBorder, lineWidth: 1)
            }
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
    func klmsContentNavigationChrome() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
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
    #if canImport(UIKit)
    static func klmsAdaptiveColor(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
    #endif

    #if canImport(AppKit)
    static func klmsAppKitAdaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            klmsAppKitIsDark(appearance) ? dark : light
        })
    }

    static func klmsAppKitIsDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    #endif

    static var klmsScreenBackground: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.973, green: 0.969, blue: 0.949, alpha: 1.0),
            dark: UIColor(red: 0.063, green: 0.063, blue: 0.059, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.973, green: 0.969, blue: 0.949, alpha: 1.0),
            dark: NSColor(red: 0.063, green: 0.063, blue: 0.059, alpha: 1.0)
        )
        #else
        return Color.white
        #endif
    }

    static var klmsCardBackground: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor.white,
            dark: UIColor(red: 0.114, green: 0.114, blue: 0.106, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor.white,
            dark: NSColor(red: 0.114, green: 0.114, blue: 0.106, alpha: 1.0)
        )
        #else
        return Color.white
        #endif
    }

    static var klmsSubtleCardBackground: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.925, green: 0.914, blue: 0.875, alpha: 1.0),
            dark: UIColor(red: 0.176, green: 0.169, blue: 0.153, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.925, green: 0.914, blue: 0.875, alpha: 1.0),
            dark: NSColor(red: 0.176, green: 0.169, blue: 0.153, alpha: 1.0)
        )
        #else
        return Color.gray.opacity(0.08)
        #endif
    }

    static var klmsBorder: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.843, green: 0.820, blue: 0.769, alpha: 1.0),
            dark: UIColor(white: 1.0, alpha: 0.105)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.843, green: 0.820, blue: 0.769, alpha: 1.0),
            dark: NSColor(white: 1.0, alpha: 0.105)
        )
        #else
        return Color.gray.opacity(0.18)
        #endif
    }

    static var klmsCommandAccent: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 1.0),
            dark: UIColor(red: 0.941, green: 0.875, blue: 0.722, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 1.0),
            dark: NSColor(red: 0.941, green: 0.875, blue: 0.722, alpha: 1.0)
        )
        #else
        return Color.gray
        #endif
    }

    static var klmsPrimaryText: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.090, green: 0.086, blue: 0.075, alpha: 1.0),
            dark: UIColor(red: 0.969, green: 0.953, blue: 0.918, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.090, green: 0.086, blue: 0.075, alpha: 1.0),
            dark: NSColor(red: 0.969, green: 0.953, blue: 0.918, alpha: 1.0)
        )
        #else
        return Color(red: 0.090, green: 0.086, blue: 0.075)
        #endif
    }

    static var klmsSecondaryText: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.427, green: 0.404, blue: 0.365, alpha: 1.0),
            dark: UIColor(red: 0.741, green: 0.710, blue: 0.655, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.427, green: 0.404, blue: 0.365, alpha: 1.0),
            dark: NSColor(red: 0.741, green: 0.710, blue: 0.655, alpha: 1.0)
        )
        #else
        return Color(red: 0.427, green: 0.404, blue: 0.365)
        #endif
    }

    static var klmsCommandBackground: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.925, green: 0.914, blue: 0.875, alpha: 1.0),
            dark: UIColor(red: 0.176, green: 0.169, blue: 0.153, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.925, green: 0.914, blue: 0.875, alpha: 1.0),
            dark: NSColor(red: 0.176, green: 0.169, blue: 0.153, alpha: 1.0)
        )
        #else
        return Color.gray.opacity(0.08)
        #endif
    }

    static var klmsCommandBorder: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.843, green: 0.820, blue: 0.769, alpha: 1.0),
            dark: UIColor(white: 1.0, alpha: 0.160)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.843, green: 0.820, blue: 0.769, alpha: 1.0),
            dark: NSColor(white: 1.0, alpha: 0.160)
        )
        #else
        return Color.klmsCommandAccent.opacity(0.30)
        #endif
    }

    static var klmsWarningBackground: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.953, green: 0.932, blue: 0.875, alpha: 1.0),
            dark: UIColor(red: 0.235, green: 0.198, blue: 0.122, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.953, green: 0.932, blue: 0.875, alpha: 1.0),
            dark: NSColor(red: 0.235, green: 0.198, blue: 0.122, alpha: 1.0)
        )
        #else
        return Color.orange.opacity(0.10)
        #endif
    }

    static var klmsWarningBorder: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.784, green: 0.722, blue: 0.573, alpha: 1.0),
            dark: UIColor(red: 0.470, green: 0.376, blue: 0.192, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.784, green: 0.722, blue: 0.573, alpha: 1.0),
            dark: NSColor(red: 0.470, green: 0.376, blue: 0.192, alpha: 1.0)
        )
        #else
        return Color.orange.opacity(0.45)
        #endif
    }

    static var klmsDangerBackground: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.965, green: 0.928, blue: 0.916, alpha: 1.0),
            dark: UIColor(red: 0.250, green: 0.132, blue: 0.116, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.965, green: 0.928, blue: 0.916, alpha: 1.0),
            dark: NSColor(red: 0.250, green: 0.132, blue: 0.116, alpha: 1.0)
        )
        #else
        return Color.red.opacity(0.10)
        #endif
    }

    static var klmsDangerBorder: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.745, green: 0.395, blue: 0.340, alpha: 1.0),
            dark: UIColor(red: 0.520, green: 0.220, blue: 0.190, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.745, green: 0.395, blue: 0.340, alpha: 1.0),
            dark: NSColor(red: 0.520, green: 0.220, blue: 0.190, alpha: 1.0)
        )
        #else
        return Color.red.opacity(0.42)
        #endif
    }

    static var klmsSuccessBackground: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.920, green: 0.945, blue: 0.902, alpha: 1.0),
            dark: UIColor(red: 0.130, green: 0.205, blue: 0.138, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.920, green: 0.945, blue: 0.902, alpha: 1.0),
            dark: NSColor(red: 0.130, green: 0.205, blue: 0.138, alpha: 1.0)
        )
        #else
        return Color.green.opacity(0.10)
        #endif
    }

    static var klmsSuccessBorder: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.492, green: 0.616, blue: 0.400, alpha: 1.0),
            dark: UIColor(red: 0.292, green: 0.445, blue: 0.270, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.492, green: 0.616, blue: 0.400, alpha: 1.0),
            dark: NSColor(red: 0.292, green: 0.445, blue: 0.270, alpha: 1.0)
        )
        #else
        return Color.green.opacity(0.42)
        #endif
    }

    static var klmsCommandButtonBackground: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.925, green: 0.914, blue: 0.875, alpha: 1.0),
            dark: UIColor(red: 0.176, green: 0.169, blue: 0.153, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.925, green: 0.914, blue: 0.875, alpha: 1.0),
            dark: NSColor(red: 0.176, green: 0.169, blue: 0.153, alpha: 1.0)
        )
        #else
        return Color.black.opacity(0.82)
        #endif
    }

    static var klmsCommandButtonPressedBackground: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.812, green: 0.788, blue: 0.718, alpha: 1.0),
            dark: UIColor(red: 0.318, green: 0.298, blue: 0.251, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.812, green: 0.788, blue: 0.718, alpha: 1.0),
            dark: NSColor(red: 0.318, green: 0.298, blue: 0.251, alpha: 1.0)
        )
        #else
        return Color.black.opacity(0.24)
        #endif
    }

    static var klmsCommandButtonPressedOverlay: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 0.105),
            dark: UIColor(red: 0.941, green: 0.875, blue: 0.722, alpha: 0.140)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 0.105),
            dark: NSColor(red: 0.941, green: 0.875, blue: 0.722, alpha: 0.140)
        )
        #else
        return Color.white.opacity(0.12)
        #endif
    }

    static var klmsSelectedBackground: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.894, green: 0.878, blue: 0.827, alpha: 1.0),
            dark: UIColor(red: 0.224, green: 0.212, blue: 0.184, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.894, green: 0.878, blue: 0.827, alpha: 1.0),
            dark: NSColor(red: 0.224, green: 0.212, blue: 0.184, alpha: 1.0)
        )
        #else
        return Color.gray.opacity(0.18)
        #endif
    }

    static var klmsSelectedBorder: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 0.56),
            dark: UIColor(red: 0.941, green: 0.875, blue: 0.722, alpha: 0.48)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 0.56),
            dark: NSColor(red: 0.941, green: 0.875, blue: 0.722, alpha: 0.48)
        )
        #else
        return Color.gray.opacity(0.72)
        #endif
    }

    static var klmsSelectedForeground: Color {
        klmsPrimaryText
    }

    static var klmsPrimaryCommandButtonBackground: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 1.0),
            dark: UIColor(red: 0.941, green: 0.875, blue: 0.722, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 1.0),
            dark: NSColor(red: 0.941, green: 0.875, blue: 0.722, alpha: 1.0)
        )
        #else
        return Color(red: 0.784, green: 0.722, blue: 0.573)
        #endif
    }

    static var klmsPrimaryCommandButtonPressedBackground: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.232, green: 0.232, blue: 0.214, alpha: 1.0),
            dark: UIColor(red: 0.843, green: 0.776, blue: 0.624, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.232, green: 0.232, blue: 0.214, alpha: 1.0),
            dark: NSColor(red: 0.843, green: 0.776, blue: 0.624, alpha: 1.0)
        )
        #else
        return Color(red: 0.690, green: 0.620, blue: 0.455)
        #endif
    }

    static var klmsCommandButtonForeground: Color {
        klmsPrimaryCommandButtonForeground
    }

    static var klmsPrimaryCommandButtonForeground: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 1.000, green: 0.980, blue: 0.941, alpha: 1.0),
            dark: UIColor(red: 0.082, green: 0.075, blue: 0.055, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 1.000, green: 0.980, blue: 0.941, alpha: 1.0),
            dark: NSColor(red: 0.082, green: 0.075, blue: 0.055, alpha: 1.0)
        )
        #else
        return Color.white
        #endif
    }

    static var klmsDangerCommandButtonForeground: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 1.000, green: 0.980, blue: 0.941, alpha: 1.0),
            dark: UIColor(red: 1.000, green: 0.980, blue: 0.941, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 1.000, green: 0.980, blue: 0.941, alpha: 1.0),
            dark: NSColor(red: 1.000, green: 0.980, blue: 0.941, alpha: 1.0)
        )
        #else
        return Color(red: 1.000, green: 0.980, blue: 0.941)
        #endif
    }

    static var klmsSecondaryCommandButtonForeground: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.090, green: 0.086, blue: 0.075, alpha: 1.0),
            dark: UIColor(red: 0.969, green: 0.953, blue: 0.918, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.090, green: 0.086, blue: 0.075, alpha: 1.0),
            dark: NSColor(red: 0.969, green: 0.953, blue: 0.918, alpha: 1.0)
        )
        #else
        return Color.white
        #endif
    }

    static var klmsPrimaryCommandButtonBorder: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 1.0),
            dark: UIColor(red: 0.784, green: 0.722, blue: 0.573, alpha: 1.0)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 1.0),
            dark: NSColor(red: 0.784, green: 0.722, blue: 0.573, alpha: 1.0)
        )
        #else
        return Color(red: 0.500, green: 0.430, blue: 0.270)
        #endif
    }

    static var klmsCommandButtonBorder: Color {
        #if canImport(UIKit)
        return klmsAdaptiveColor(
            light: UIColor(red: 0.843, green: 0.820, blue: 0.769, alpha: 1.0),
            dark: UIColor(white: 1.0, alpha: 0.160)
        )
        #elseif canImport(AppKit)
        return klmsAppKitAdaptiveColor(
            light: NSColor(red: 0.843, green: 0.820, blue: 0.769, alpha: 1.0),
            dark: NSColor(white: 1.0, alpha: 0.160)
        )
        #else
        return Color.black.opacity(0.92)
        #endif
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
