import KLMSShared
import SwiftUI

@main
struct KLMSiOSApp: App {
    var body: some Scene {
        WindowGroup {
            CompanionRootView()
        }
    }
}

struct CompanionRootView: View {
    @State private var pendingCommand: RemoteRunCommand?
    @State private var status = SanitizedRemoteStatus()
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            List {
                Section("상태") {
                    LabeledContent("과제", value: "\(status.assignments)")
                    LabeledContent("시험", value: "\(status.exams)")
                    LabeledContent("헬프데스크", value: "\(status.helpDesk)")
                    LabeledContent("공지", value: "\(status.notices)")
                    LabeledContent("새 파일", value: "\(status.newFiles)")
                    LabeledContent("격리", value: "\(status.quarantine)")
                    if !status.phase.isEmpty {
                        LabeledContent("진행 상태", value: status.phase.klmsLocalizedStatus)
                    }
                }

                Section("Mac에 요청") {
                    commandButton(.fullSync)
                    commandButton(.coreSync)
                    commandButton(.noticeSync)
                    commandButton(.filesSync)
                }

                if let pendingCommand {
                    Section("최근 요청") {
                        LabeledContent("명령", value: pendingCommand.kind.displayName)
                        LabeledContent("상태", value: pendingCommand.status.displayName)
                        LabeledContent("생성 시각", value: pendingCommand.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                if !errorMessage.isEmpty {
                    Section("오류") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("KLMS Sync")
            .toolbar {
                Button("새로고침") {
                    Task {
                        await refreshRecent()
                    }
                }
            }
            .task {
                await refreshRecent()
            }
        }
    }

    private func commandButton(_ kind: RemoteCommandKind) -> some View {
        Button(kind.engineCommand.displayName) {
            Task {
                await createCommand(kind)
            }
        }
    }

    private func createCommand(_ kind: RemoteCommandKind) async {
        let command = RemoteRunCommand(kind: kind)
        do {
            #if canImport(CloudKit)
            try await CloudKitCommandStore().create(command)
            #endif
            pendingCommand = command
            errorMessage = ""
            await refreshRecent()
        } catch {
            pendingCommand = command
            errorMessage = error.localizedDescription
        }
    }

    private func refreshRecent() async {
        do {
            #if canImport(CloudKit)
            if let recent = try await CloudKitCommandStore().fetchRecent(limit: 1).first {
                pendingCommand = recent
                status = recent.summary
            }
            #endif
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
