import SwiftUI

#if canImport(KLMSShared)
import KLMSShared
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
    @Published var isRefreshing = false
    @Published var isSubmitting = false

    private let store: (any RemoteCommandStore)?
    let remoteAvailabilityMessage: String

    init(store: (any RemoteCommandStore)? = nil) {
        if let store {
            self.store = store
            self.remoteAvailabilityMessage = ""
            return
        }
        #if canImport(CloudKit) && KLMS_ENABLE_CLOUDKIT
        self.store = CloudKitCommandStore()
        self.remoteAvailabilityMessage = ""
        #else
        self.store = nil
        self.remoteAvailabilityMessage = "현재 iPhone 앱은 CloudKit 원격 기능을 끈 상태로 빌드되었습니다. 무료 Apple ID에서는 앱 화면 확인만 가능하고, 원격 실행 요청은 비활성화됩니다."
        #endif
    }

    var isRemoteAvailable: Bool {
        store != nil
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

    var statusLine: String {
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
            return "Mac 앱 응답 없음. Mac에서 iPhone 요청 자동 처리를 켜야 합니다."
        }
    }

    func createCommand(_ kind: RemoteCommandKind) async {
        guard !hasInFlightRequest else {
            errorMessage = "이미 대기 중이거나 실행 중인 요청이 있습니다."
            return
        }
        guard let store else {
            errorMessage = remoteAvailabilityMessage
            return
        }
        isSubmitting = true
        defer {
            isSubmitting = false
        }
        let command = RemoteRunCommand(kind: kind)
        do {
            try await store.create(command)
            recentCommands.insert(command, at: 0)
            status = command.summary
            errorMessage = ""
            await refreshRecent()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshRecent() async {
        guard let store else {
            errorMessage = ""
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
        }
        do {
            let commands = try await store.fetchRecent(limit: 8)
            recentCommands = commands
            if let latest = commands.first {
                status = latest.summary
            }
            errorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pollRecentCommands() async {
        guard store != nil else {
            return
        }
        while !Task.isCancelled {
            await refreshRecent()
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }
}

struct CompanionRootView: View {
    @StateObject private var model = CompanionModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RemoteStatusHeader(model: model)
                    if !model.isRemoteAvailable {
                        InfoBanner(message: model.remoteAvailabilityMessage)
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
        guard let latest = model.latestCommand,
              let status = model.latestDisplayStatus else {
            return "대기 중"
        }
        return "\(latest.kind.displayName) · \(status.displayName)"
    }

    private var statusImage: String {
        switch model.latestDisplayStatus {
        case .pending:
            "clock"
        case .running:
            "arrow.triangle.2.circlepath"
        case .completed:
            "checkmark.circle"
        case .failed:
            "xmark.octagon"
        case .macUnavailable:
            "macbook.and.iphone"
        case nil:
            "iphone"
        }
    }

    private var statusColor: Color {
        switch model.latestDisplayStatus {
        case .pending, .running:
            .blue
        case .completed:
            .green
        case .failed, .macUnavailable:
            .orange
        case nil:
            .secondary
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
                if command.loginRequired {
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
            Label("원격 요청은 CloudKit private database만 사용", systemImage: "lock.icloud")
                .font(.subheadline.weight(.semibold))
            Text("CloudKit 권한을 켠 빌드에서만 실행 요청과 요약 숫자를 저장합니다. KLMS URL, 로그, config.env, 파일 경로는 올리지 않습니다.")
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
