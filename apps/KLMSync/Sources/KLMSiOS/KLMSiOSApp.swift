import SwiftUI

#if canImport(KLMSShared)
import KLMSShared
#endif
#if canImport(UIKit)
import UIKit
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
    @Published var status = SanitizedRemoteStatus()
    @Published var errorMessage = ""
    @Published var connectionMessage = ""
    @Published var connectionSucceeded: Bool?
    @Published var userAlert: UserAlert?
    @Published var isRefreshing = false
    @Published var isSubmitting = false
    @Published var localHost: String {
        didSet { UserDefaults.standard.set(localHost, forKey: Self.localHostKey) }
    }
    @Published var localPortText: String {
        didSet { UserDefaults.standard.set(localPortText, forKey: Self.localPortKey) }
    }
    @Published var localToken: String {
        didSet { Self.persistLocalToken(localToken) }
    }

    private let cloudStore: (any RemoteCommandStore)?

    private static let localHostKey = "KLMSLocalRemoteHost"
    private static let localPortKey = "KLMSLocalRemotePort"
    private static let localTokenKey = "KLMSLocalRemoteToken"

    init(store: (any RemoteCommandStore)? = nil) {
        let storedLocalToken = LocalRemoteTokenStore.load(account: "ios")
            ?? UserDefaults.standard.string(forKey: Self.localTokenKey)
            ?? ""
        localHost = UserDefaults.standard.string(forKey: Self.localHostKey) ?? ""
        localPortText = UserDefaults.standard.string(forKey: Self.localPortKey) ?? "18483"
        localToken = storedLocalToken
        Self.persistLocalToken(storedLocalToken)
        if let store {
            cloudStore = store
            return
        }
        #if canImport(CloudKit) && KLMS_ENABLE_CLOUDKIT
        cloudStore = CloudKitCommandStore()
        #else
        cloudStore = nil
        #endif
    }

    var isRemoteAvailable: Bool {
        localRemoteClient != nil || cloudStore != nil
    }

    var localRemoteConfigured: Bool {
        localRemoteClient != nil
    }

    var remoteAvailabilityMessage: String {
        if localRemoteClient == nil {
            return "Mac 앱에서 로컬 원격 제어를 켠 뒤, 표시되는 Mac 주소와 토큰을 입력해 주세요."
        }
        return ""
    }

    private var localRemoteClient: LocalRemoteClient? {
        #if canImport(Network)
        guard let connectionInfo = localConnectionInfo,
              let token = connectionInfo.token,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return LocalRemoteClient(host: connectionInfo.host, port: connectionInfo.port, token: token)
        #else
        return nil
        #endif
    }

    private var localConnectionInfo: LocalRemoteConnectionInfo? {
        LocalRemoteConnectionInfo.parse(
            hostText: localHost,
            portText: localPortText,
            tokenText: localToken
        )
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

    var shouldShowAuthCompletion: Bool {
        status.authStatusMessage != nil
            && latestDisplayStatus?.isTerminal != true
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
            return "Mac에서 \(latestCommand.kind.displayName) 실행 중"
        case .completed:
            return "최근 요청 완료: \(latestCommand.kind.displayName)"
        case .failed:
            return "최근 요청 실패: \(latestCommand.kind.displayName)"
        case .macUnavailable:
            return "Mac 앱 응답 없음. Mac에서 로컬 원격 제어를 켜야 합니다."
        }
    }

    var loginAttentionMessage: String? {
        if let authDigits = status.authDigits {
            return "KAIST 인증 번호 \(authDigits)를 휴대폰 인증 화면에서 선택하면 Mac 동기화가 계속됩니다."
        }
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
            if let localRemoteClient {
                let response = try await localRemoteClient.run(kind)
                apply(response)
                errorMessage = ""
            } else if let cloudStore {
                let command = RemoteRunCommand(kind: kind)
                try await cloudStore.create(command)
                recentCommands.insert(command, at: 0)
                status = command.summary
                errorMessage = ""
                await refreshRecent()
            } else {
                errorMessage = remoteAvailabilityMessage
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshRecent() async {
        isRefreshing = true
        defer {
            isRefreshing = false
        }
        do {
            if let localRemoteClient {
                let response = try await localRemoteClient.fetchStatus()
                apply(response)
                errorMessage = ""
            } else if let cloudStore {
                let commands = try await cloudStore.fetchRecent(limit: 8)
                recentCommands = commands
                if let latest = commands.first {
                    status = latest.summary
                }
                errorMessage = ""
            } else {
                errorMessage = ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkLocalConnection() async {
        connectionMessage = "Mac 연결을 확인하는 중..."
        connectionSucceeded = nil
        errorMessage = ""
        isRefreshing = true
        defer {
            isRefreshing = false
        }

        guard let localRemoteClient else {
            let message = remoteAvailabilityMessage
            connectionMessage = message
            connectionSucceeded = false
            errorMessage = message
            userAlert = UserAlert(title: "연결 확인 실패", message: message)
            return
        }

        do {
            let response = try await localRemoteClient.fetchStatus()
            apply(response)
            let message = "Mac 앱과 연결됐습니다."
            connectionMessage = message
            connectionSucceeded = true
            errorMessage = ""
            userAlert = UserAlert(title: "연결 확인 완료", message: message)
        } catch {
            let message = error.localizedDescription
            connectionMessage = message
            connectionSucceeded = false
            errorMessage = message
            userAlert = UserAlert(title: "연결 확인 실패", message: message)
        }
    }

    func pasteLocalConnectionInfo() {
        #if canImport(UIKit)
        guard let text = UIPasteboard.general.string,
              let connectionInfo = LocalRemoteConnectionInfo.parse(hostText: text) else {
            errorMessage = "붙여넣은 텍스트에서 Mac 주소와 토큰을 찾지 못했습니다."
            return
        }
        localHost = "\(connectionInfo.host):\(connectionInfo.port)"
        localPortText = "\(connectionInfo.port)"
        if let token = connectionInfo.token {
            localToken = token
        }
        if UIPasteboard.general.string == text {
            UIPasteboard.general.string = ""
        }
        connectionMessage = "연결 정보를 붙여넣었습니다. 이제 연결 확인을 눌러 주세요."
        connectionSucceeded = nil
        errorMessage = ""
        #else
        errorMessage = "이 빌드는 클립보드 붙여넣기를 사용할 수 없습니다."
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
        status = response.status
        if let latestCommand = response.latestCommand {
            recentCommands = [latestCommand]
        }
    }

    private static func persistLocalToken(_ token: String) {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            LocalRemoteTokenStore.delete(account: "ios")
        } else {
            LocalRemoteTokenStore.save(trimmedToken, account: "ios")
        }
        UserDefaults.standard.removeObject(forKey: Self.localTokenKey)
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RemoteStatusHeader(model: model)
                    LocalConnectionPanel(model: model)
                    if !model.localRemoteConfigured {
                        InfoBanner(message: model.remoteAvailabilityMessage)
                    }
                    if let message = model.loginAttentionMessage {
                        LoginAttentionBanner(message: message)
                    }
                    if let message = model.authSuccessMessage {
                        AuthSuccessBanner(message: message)
                    }
                    RemoteCommandPanel(model: model)
                    RecentRemoteCommandsView(commands: model.recentCommands)
                    RemotePrivacyNote()

                    if !model.errorMessage.isEmpty {
                        ErrorBanner(message: model.errorMessage)
                    }
                }
                .padding()
            }
            .navigationTitle("KLMS Sync")
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
}

private struct LocalConnectionPanel: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mac 연결")
                .font(.headline)
            TextField("Mac 주소 예: 192.168.0.10 또는 192.168.0.10:18483", text: $model.localHost)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            HStack(spacing: 8) {
                TextField("포트", text: $model.localPortText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(maxWidth: 90)
                TextField("토큰", text: $model.localToken)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            Button {
                model.pasteLocalConnectionInfo()
            } label: {
                Label("복사한 연결 정보 붙여넣기", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            HStack(spacing: 8) {
                Button {
                    Task {
                        await model.checkLocalConnection()
                    }
                } label: {
                    Label("연결 확인", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.isRefreshing)

                Button {
                    Task {
                        await model.createCommand(.doctor)
                    }
                } label: {
                    Label("로그인 확인", systemImage: "person.crop.circle.badge.questionmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!model.localRemoteConfigured || model.isSubmitting || model.hasInFlightRequest)
            }
            if !model.connectionMessage.isEmpty {
                ConnectionNoticeBanner(
                    message: model.connectionMessage,
                    succeeded: model.connectionSucceeded
                )
            }
            Text("처음 연결할 때 iOS의 로컬 네트워크 권한 알림이 뜨면 허용해야 합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

private struct RemoteStatusHeader: View {
    @ObservedObject var model: CompanionModel

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
                }
                Spacer(minLength: 0)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                RemoteMetricTile("과제", model.status.assignments, systemImage: "checklist")
                RemoteMetricTile("시험", model.status.exams, systemImage: "calendar")
                RemoteMetricTile("공지", model.status.notices, systemImage: "note.text")
                RemoteMetricTile("파일", model.status.newFiles, systemImage: "folder")
                RemoteMetricTile("격리", model.status.quarantine, systemImage: "exclamationmark.triangle")
                RemoteMetricTile("헬프데스크", model.status.helpDesk, systemImage: "person.2")
            }
        }
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
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
}

private struct RemoteMetricTile: View {
    var label: String
    var value: Int
    var systemImage: String

    init(_ label: String, _ value: Int, systemImage: String) {
        self.label = label
        self.value = value
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(.headline.monospacedDigit())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 10)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct RemoteCommandPanel: View {
    @ObservedObject var model: CompanionModel

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mac에 실행 요청")
                .font(.headline)
            LazyVGrid(columns: columns, spacing: 8) {
                commandButton(.fullSync)
                commandButton(.coreSync)
                commandButton(.noticeSync)
                commandButton(.filesSync)
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

private struct RecentRemoteCommandsView: View {
    var commands: [RemoteRunCommand]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("최근 요청")
                .font(.headline)
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
                        RemoteCommandRow(command: command)
                    }
                }
            }
        }
    }
}

private struct RemoteCommandRow: View {
    var command: RemoteRunCommand

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
}

private struct RemotePrivacyNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("원격 요청은 로컬 토큰으로 보호", systemImage: "lock")
                .font(.subheadline.weight(.semibold))
            Text("무료 계정 빌드는 같은 Wi-Fi의 Mac 앱에 직접 요청합니다. KLMS URL, 로그, config.env, 파일 경로는 iPhone에 저장하지 않습니다.")
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
