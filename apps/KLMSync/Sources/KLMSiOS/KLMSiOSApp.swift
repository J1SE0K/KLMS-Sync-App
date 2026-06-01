import SwiftUI

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
        }
    }
}

@MainActor
final class CompanionModel: ObservableObject {
    @Published var recentCommands: [RemoteRunCommand] = []
    @Published var syncItems: [ServerRelaySyncItem] = []
    @Published var status = SanitizedRemoteStatus()
    @Published var errorMessage = ""
    @Published var connectionMessage = ""
    @Published var connectionSucceeded: Bool?
    @Published var userAlert: UserAlert?
    @Published var isRefreshing = false
    @Published var isSubmitting = false
    @Published var lastRefreshAt: Date?
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.serverURLKey) }
    }
    @Published var serverToken: String {
        didSet { Self.persistServerToken(serverToken) }
    }

    private var lastAuthSuccessAlertMessage = ""
    private var trackedReportNotificationCommandIDs = Set<UUID>()
    private var pasteboardClearTask: Task<Void, Never>?

    private static let deprecatedLocalHostKey = "KLMSLocalRemoteHost"
    private static let deprecatedLocalPortKey = "KLMSLocalRemotePort"
    private static let deprecatedLocalTokenKey = "KLMSLocalRemoteToken"
    private static let serverURLKey = "KLMSServerRelayURL"
    private static let serverTokenKey = "KLMSServerRelayToken"
    private static let trackedReportNotificationCommandIDsKey = "KLMSTrackedReportNotificationCommandIDs"

    init() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().delegate = KLMSCompanionNotificationDelegate.shared
        #endif
        let storedServerToken = LocalRemoteTokenStore.load(account: "server-relay-ios")
            ?? UserDefaults.standard.string(forKey: Self.serverTokenKey)
            ?? ""
        serverURL = UserDefaults.standard.string(forKey: Self.serverURLKey) ?? ""
        serverToken = storedServerToken
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
            return "HTTPS 서버 릴레이 주소와 iPhone/Windows용 클라이언트 토큰을 입력해 주세요."
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
    }

    var canCancelRunningCommand: Bool {
        false
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
        switch latestDisplayStatus {
        case .pending:
            return "\(latestCommand.kind.displayName) 요청을 Mac이 확인하기를 기다리는 중"
        case .running:
            return "Mac에서 \(latestCommand.kind.displayName) 처리 중"
        case .completed:
            return "최근 요청 완료: \(latestCommand.kind.displayName)"
        case .failed:
            return "최근 요청 실패: \(latestCommand.kind.displayName)"
        case .macUnavailable:
            return "Mac 앱 응답 없음. Mac에서 서버 릴레이가 켜져 있는지 확인해 주세요."
        }
    }

    var activeRequestLabel: String {
        if let latestCommand, latestDisplayStatus?.isInFlight == true {
            return "\(latestCommand.kind.displayName) 처리 중"
        }
        if status.phase == "running" {
            return "요청 처리 중"
        }
        return "요청 처리 중"
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

    func createCommand(_ kind: RemoteCommandKind) async {
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
                var command = RemoteRunCommand(kind: kind)
                command.summary = status
                try await serverRelayStore.create(command)
                trackReportNotificationIfNeeded(for: command)
                recentCommands.insert(command, at: 0)
                status = command.summary
                lastRefreshAt = Date()
                errorMessage = ""
                await refreshRecent()
            } else {
                errorMessage = remoteAvailabilityMessage
            }
        } catch {
            guard !isCancellationError(error) else { return }
            errorMessage = userFacingMessage(for: error)
        }
    }

    func cancelRunningCommand() async {
        errorMessage = "서버 릴레이에서는 아직 실행 중단을 지원하지 않습니다."
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
            try await serverRelayStore.createItemAction(action)
            connectionMessage = "\(actionKind.displayName) 요청을 보냈습니다."
            connectionSucceeded = true
            errorMessage = ""
            userAlert = UserAlert(title: "요청 완료", message: connectionMessage)
            await refreshRecent()
        } catch {
            guard !isCancellationError(error) else { return }
            let message = userFacingMessage(for: error)
            errorMessage = message
            userAlert = UserAlert(title: "요청 실패", message: message)
        }
    }

    func refreshRecent() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
        }
        do {
            if let serverRelayStore {
                let response = try await serverRelayStore.fetchStatusResponse()
                apply(response)
                let commands = try await serverRelayStore.fetchRecent(limit: 8)
                syncItems = try await serverRelayStore.fetchSyncData(limit: 2000).items
                if !commands.isEmpty {
                    recentCommands = commands
                    handleReportNotificationUpdates(commands)
                }
                lastRefreshAt = Date()
                errorMessage = ""
            } else {
                errorMessage = ""
            }
        } catch {
            guard !isCancellationError(error) else { return }
            errorMessage = userFacingMessage(for: error)
        }
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
            let message = "서버 주소와 클라이언트 토큰을 입력해 주세요."
            connectionMessage = message
            connectionSucceeded = false
            errorMessage = message
            userAlert = UserAlert(title: "서버 연결 실패", message: message)
            return
        }

        do {
            let response = try await serverRelayStore.fetchStatusResponse()
            apply(response)
            syncItems = try await serverRelayStore.fetchSyncData(limit: 2000).items
            let message = "서버 릴레이와 연결됐습니다."
            connectionMessage = message
            connectionSucceeded = true
            errorMessage = ""
            userAlert = UserAlert(title: "서버 연결 완료", message: message)
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
            errorMessage = "붙여넣은 텍스트에서 서버 주소와 클라이언트 토큰을 찾지 못했습니다."
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
        guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "복사할 서버 주소가 없습니다."
            return
        }
        copyToPasteboard(serverURL, clearAfterSeconds: nil)
        connectionMessage = "서버 주소를 복사했습니다."
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
        guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "복사할 서버 주소와 클라이언트 토큰이 없습니다."
            return
        }
        let text = """
        KLMS Sync 서버 연결 정보
        서버 주소: \(serverURL)
        클라이언트 토큰: \(serverToken)
        """
        copyToPasteboard(text, clearAfterSeconds: 60)
        connectionMessage = "서버 주소와 클라이언트 토큰을 복사했습니다. 60초 뒤 클립보드에서 지웁니다."
        connectionSucceeded = true
        errorMessage = ""
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
        while !Task.isCancelled {
            await refreshRecent()
            let interval: UInt64 = hasInFlightRequest
                || status.authDigits != nil
                || status.authStatusMessage != nil
                ? 2_000_000_000
                : 10_000_000_000
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    private func apply(_ response: LocalRemoteResponse) {
        let previousAuthStatusMessage = status.authStatusMessage
        status = response.status
        lastRefreshAt = Date()
        if let authStatusMessage = response.status.authStatusMessage, !authStatusMessage.isEmpty {
            if authStatusMessage != lastAuthSuccessAlertMessage || previousAuthStatusMessage == nil {
                userAlert = UserAlert(title: "인증 완료", message: authStatusMessage)
            }
            lastAuthSuccessAlertMessage = authStatusMessage
        } else {
            lastAuthSuccessAlertMessage = ""
        }
        if let latestCommand = response.latestCommand {
            recentCommands = [latestCommand]
            handleReportNotificationUpdates([latestCommand])
        }
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
        case .macUnavailable:
            title = "요약 갱신 응답 없음"
            body = "Mac 앱이 요약 갱신 요청에 응답하지 않았습니다. Mac 앱의 서버 릴레이 상태를 확인해 주세요."
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
                return "서버 주소를 찾지 못했습니다. 연결 설정의 서버 주소를 확인해 주세요."
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
            UserDefaults.standard.set(trimmedToken, forKey: Self.serverTokenKey)
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
    @State private var selectedDashboardCategory: DashboardMetricCategory = .assignments
    @State private var selectedDashboardRoute: DashboardMetricCategory?
    @State private var selectedSyncItem: ServerRelaySyncItem?

    var body: some View {
        CompanionScreenContainer(title: "상태", model: model) {
            RemoteAttentionStack(model: model)
            RemoteStatusHeader(
                model: model,
                selectedCategory: $selectedDashboardCategory,
                onCategoryTap: { category in
                    selectedDashboardCategory = category
                    selectedDashboardRoute = category
                }
            )
            .navigationDestination(item: $selectedDashboardRoute) { category in
                DashboardCategoryDetailScreen(
                    category: category,
                    status: model.status,
                    items: model.syncItems,
                    onSelect: { selectedSyncItem = $0 }
                )
            }
            DashboardMetricDetailPanel(
                category: selectedDashboardCategory,
                status: model.status,
                items: model.syncItems,
                onSelect: { selectedSyncItem = $0 }
            )
            RemoteChangeSummaryPanel(status: model.status)
            ServerSyncDataPanel(items: model.syncItems, onSelect: { selectedSyncItem = $0 })
            RemoteCommandPanel(model: model, compact: true)
            RecentRemoteCommandsView(commands: Array(model.recentCommands.prefix(3)), compact: true)
        }
        .sheet(item: $selectedSyncItem) { item in
            ServerSyncItemDetailView(item: item, model: model)
        }
    }
}

private struct CompanionRunScreen: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        CompanionScreenContainer(title: "실행", model: model) {
            RemoteAttentionStack(model: model)
            RemoteCommandPanel(model: model, compact: false)
            RemoteChangeSummaryPanel(status: model.status)
            RemoteDiagnosticPanel(model: model)
            InfoBanner(message: "iPhone은 KLMS를 직접 읽지 않고 Mac 앱에 실행 요청만 보냅니다. Cloudflare 서버 릴레이를 쓰면 같은 Wi‑Fi가 아니어도 요청을 보낼 수 있지만, 실제 동기화는 Mac 앱이 켜져 있어야 실행됩니다.")
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
            RecentRemoteCommandsView(commands: model.recentCommands, compact: false)
        }
    }
}

private struct CompanionScreenContainer<Content: View>: View {
    var title: String
    @ObservedObject var model: CompanionModel
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content()
                }
                .padding()
            }
            .navigationTitle(title)
            .toolbar {
                Button {
                    Task {
                        await model.refreshRecent()
                    }
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
            }
            .refreshable {
                await model.refreshRecent()
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showConnectionFields.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Label("서버 정보", systemImage: "link")
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
                    TextField("서버 주소 예: https://klms-sync.example.com", text: $model.serverURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    SecureField("클라이언트 토큰", text: $model.serverToken)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Text("Mac 앱에는 같은 서버 주소와 별도 Mac worker 토큰이 저장되어 있어야 합니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }

            HStack(spacing: 8) {
                Button {
                    model.pasteServerRelayConnectionInfo()
                } label: {
                    Label("붙여넣기", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    model.clearServerRelayConnectionInfo()
                } label: {
                    Label("지우기", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!model.serverRelayConfigured && model.serverURL.isEmpty && model.serverToken.isEmpty)
            }

            HStack(spacing: 8) {
                Button {
                    model.copyServerRelayURL()
                } label: {
                    Label("주소 복사", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.serverURL.isEmpty)

                Button {
                    model.copyServerRelayClientToken()
                } label: {
                    Label("토큰 복사", systemImage: "key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.serverToken.isEmpty)
            }

            Button {
                model.copyServerRelayConnectionInfo()
            } label: {
                Label("주소+토큰 복사", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.serverURL.isEmpty || model.serverToken.isEmpty)

            HStack(spacing: 8) {
                Button {
                    Task {
                        await model.checkServerRelayConnection()
                    }
                } label: {
                    Label("서버 연결 확인", systemImage: "network")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRefreshing)

                Button {
                    Task {
                        await model.createCommand(.report)
                    }
                } label: {
                    Label("요약 갱신", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!model.serverRelayConfigured || model.isSubmitting || model.hasInFlightRequest)
            }
        }
        .padding(12)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
            .purple
        case .files:
            .blue
        case .quarantine:
            .red
        case .helpDesk:
            .teal
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
            item.kind == "assignment"
        case .exams:
            item.kind == "exam"
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

private struct RemoteStatusHeader: View {
    @ObservedObject var model: CompanionModel
    @Binding var selectedCategory: DashboardMetricCategory
    var onCategoryTap: (DashboardMetricCategory) -> Void = { _ in }

    private let columns = [
        GridItem(.adaptive(minimum: 96), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusImage)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.headline)
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

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                metricTile(.assignments)
                metricTile(.exams)
                metricTile(.notices)
                metricTile(.files)
                if model.status.quarantine > 0 {
                    metricTile(.quarantine)
                }
                if model.status.calendarChangeTotal > 0 {
                    metricTile(.calendar)
                }
                metricTile(.helpDesk)
            }
        }
        .padding(16)
        .background(statusBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusColor.opacity(0.22), lineWidth: 1)
        )
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
        let phase = model.status.phase.klmsRemotePhaseName
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
        case .failed, .macUnavailable:
            return Color.orange.opacity(0.08)
        case nil:
            return Color.secondary.opacity(0.06)
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
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .frame(width: 18)
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
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 10)
            .background(isSelected ? Color.blue.opacity(0.10) : Color.secondary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue.opacity(0.45) : Color.clear, lineWidth: 1)
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
        items.filter { category.includes($0) }
    }

    private var visibleItems: [ServerRelaySyncItem] {
        Array(filteredItems.prefix(8))
    }

    var body: some View {
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
            } else if filteredItems.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleItems) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            ServerSyncDataRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("항목 상세를 엽니다.")
                    }
                    if filteredItems.count > visibleItems.count {
                        Text("외 \(filteredItems.count - visibleItems.count)개")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                    }
                }
            }
        }
        .padding(12)
        .background(category.tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(category.tint.opacity(0.35), lineWidth: 1)
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

private struct DashboardCategoryDetailScreen: View {
    var category: DashboardMetricCategory
    var status: SanitizedRemoteStatus
    var items: [ServerRelaySyncItem]
    var onSelect: (ServerRelaySyncItem) -> Void
    @State private var query = ""

    private var filteredItems: [ServerRelaySyncItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items
            .filter { category.includes($0) }
            .filter { item in
                guard !query.isEmpty else { return true }
                return [
                    item.course,
                    item.title,
                    item.timestamp,
                    item.status,
                    item.detail,
                ]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
            }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp > rhs.timestamp
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    var body: some View {
        List {
            Section {
                DashboardCategorySummaryRow(category: category, status: status, itemCount: filteredItems.count)
            }

            if category == .calendar {
                Section("캘린더 변경") {
                    DashboardCalendarChangeRow(title: "생성", value: status.calendarCreated)
                    DashboardCalendarChangeRow(title: "수정", value: status.calendarUpdated)
                    DashboardCalendarChangeRow(title: "삭제", value: status.calendarDeleted)
                }
            } else if category == .quarantine {
                Section {
                    Text(category.emptyMessage)
                        .foregroundStyle(.secondary)
                }
            } else if filteredItems.isEmpty {
                Section {
                    Text(category.emptyMessage)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("\(filteredItems.count)개") {
                    ForEach(filteredItems) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            ServerSyncDataRow(item: item)
                        }
                        .buttonStyle(.plain)
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
                .font(.title3)
                .foregroundStyle(category.tint)
                .frame(width: 28)
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
            "생성 \(status.calendarCreated) · 수정 \(status.calendarUpdated) · 삭제 \(status.calendarDeleted)"
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
                    tint: .purple,
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
                        "삭제 \(status.calendarDeleted)",
                    ]
                )
            }
        }
        .padding(12)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    private var visibleItems: [ServerRelaySyncItem] {
        Array(items.prefix(12))
    }

    var body: some View {
        if !items.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleItems) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            ServerSyncDataRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("항목 상세를 엽니다.")
                    }
                    if items.count > visibleItems.count {
                        Text("외 \(items.count - visibleItems.count)개")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    actionPanel
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
            DetailFieldRow(title: "세부 내용", value: item.detail)
            DetailFieldRow(title: "첨부", value: item.attachmentCount > 0 ? "\(item.attachmentCount)개" : "")
            DetailFieldRow(title: "서버 갱신", value: item.updatedAt)
            DetailFieldRow(title: "식별자", value: item.id)
        }
        .padding(12)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !itemActions.isEmpty {
                Text("항목 처리")
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
                                Text(action.displayName)
                                    .frame(maxWidth: .infinity, minHeight: 38)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!model.serverRelayConfigured || model.isSubmitting)
                        }
                    }
                }
                if !model.serverRelayConfigured {
                    Text("항목 처리 요청은 서버 릴레이 연결에서만 사용할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("원격 실행")
                .font(.headline)
            Button {
                Task {
                    await model.createCommand(relevantCommand)
                }
            } label: {
                Label("\(relevantCommand.displayName) 요청", systemImage: relevantCommand.engineCommand.systemImage)
                    .frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.isRemoteAvailable || model.isSubmitting || model.hasInFlightRequest)

            Button {
                Task {
                    await model.refreshRecent()
                }
            } label: {
                Label("상태 새로고침", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(.bordered)
            .disabled(model.isRefreshing)
        }
    }

    private var detailHelpMessage: String {
        if item.kind == "file" {
            return "iPhone은 KLMS 파일 원본을 직접 내려받지 않습니다. 파일 동기화 요청을 보내면 Mac 앱이 Safari 로그인 세션으로 파일 목록과 다운로드 상태를 갱신합니다."
        }
        return "항목 처리 요청은 서버에 대기열로 올라가고, Mac 앱이 받아서 기존 override/state 파일에 반영합니다."
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
            [item.isHidden ? .fileUnhide : .fileHide]
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
            .purple
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

private struct ServerSyncDataRow: View {
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
    }

    private var metadata: String {
        var parts: [String] = []
        if !item.course.isEmpty {
            parts.append(item.course)
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
            .purple
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

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Mac에 실행 요청")
                    .font(.headline)
                Spacer()
                if model.hasInFlightRequest || model.status.phase == "running" {
                    Label(model.activeRequestLabel, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
            LazyVGrid(columns: columns, spacing: 8) {
                commandButton(.fullSync)
                commandButton(.coreSync)
                commandButton(.noticeSync)
                commandButton(.filesSync)
            }
            if model.canCancelRunningCommand {
                Button(role: .destructive) {
                    Task {
                        await model.cancelRunningCommand()
                    }
                } label: {
                    Label("현재 동기화 중단", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.bordered)
            }
            if compact {
                Text("세부 진단과 요약 갱신은 실행 탭에서 할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commandButton(_ kind: RemoteCommandKind) -> some View {
        Button {
            Task {
                await model.createCommand(kind)
            }
        } label: {
            Label(kind.displayName, systemImage: kind.engineCommand.systemImage)
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.isRemoteAvailable || model.isSubmitting || model.hasInFlightRequest)
        .accessibilityHint("Mac 앱에 \(kind.displayName) 실행 요청을 보냅니다.")
    }
}

private struct RemoteDiagnosticPanel: View {
    @ObservedObject var model: CompanionModel

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("점검")
                .font(.headline)
            LazyVGrid(columns: columns, spacing: 8) {
                diagnosticButton(.doctor)
                diagnosticButton(.report)
            }
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
}

private struct RecentRemoteCommandsView: View {
    var commands: [RemoteRunCommand]
    var compact: Bool

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

    var body: some View {
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
                        .lineLimit(2)
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
            }
        }
        .padding(12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch command.displayStatus() {
        case .pending, .running:
            .blue
        case .completed:
            .green
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
}

private struct RemotePrivacyNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("원격 요청은 클라이언트 토큰으로 보호", systemImage: "lock")
                .font(.subheadline.weight(.semibold))
            Text("Cloudflare 서버 릴레이는 실행 요청과 요약 상태만 보관합니다. KLMS URL, 원본 로그, config.env, 파일 경로는 iPhone이나 서버에 저장하지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
}
