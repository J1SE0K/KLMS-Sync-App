import KLMSShared
import SwiftUI

struct MenuBarRootView: View {
    @ObservedObject var model: KLMSMacModel
    @State private var selectedSection = KLMSMacSection.dashboard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(model: model)

            Picker("보기", selection: $selectedSection) {
                ForEach(KLMSMacSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedSection {
                    case .dashboard:
                        DashboardSummaryView(snapshot: model.snapshot)
                        CommandPanelView(model: model)
                    case .preview:
                        PreviewPanelView(model: model)
                        CommandOutputPanelView(model: model)
                    case .files:
                        FilesPanelView(snapshot: model.snapshot)
                    case .logs:
                        LoginPanelView(model: model)
                        CommandOutputPanelView(model: model)
                        LogPanelView(snapshot: model.snapshot)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            FooterActionsView(model: model)
        }
        .padding(16)
    }
}

private enum KLMSMacSection: String, CaseIterable, Identifiable {
    case dashboard
    case preview
    case files
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:
            "상태"
        case .preview:
            "미리보기"
        case .files:
            "파일"
        case .logs:
            "로그"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard:
            "gauge.with.dots.needle.67percent"
        case .preview:
            "eye"
        case .files:
            "folder"
        case .logs:
            "doc.text"
        }
    }
}

private struct HeaderView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("KLMS Sync")
                    .font(.headline)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
            }
            Spacer()
            if model.runningCommand != nil {
                ProgressView()
                    .controlSize(.small)
            }
        }
        if let error = model.errorMessage, !error.isEmpty {
            Text(error)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let lock = model.launchAgentState?.lock {
            Text("실행 lock: pid \(lock.pid) · \(lock.command) · \(lock.acquiredAt)")
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        if let command = model.runningCommand {
            return "\(command.displayName) 실행 중"
        }
        if model.snapshot.needsAttention {
            return "주의 필요"
        }
        if let report = model.snapshot.syncReport {
            return "준비됨 · \(report.status)"
        }
        return "설치 또는 첫 실행 필요"
    }

    private var statusColor: Color {
        if model.runningCommand != nil {
            return .blue
        }
        if model.snapshot.needsAttention {
            return .orange
        }
        return .secondary
    }
}

private struct CommandOutputPanelView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        if let result = model.lastCommandResult {
            let output = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty {
                SectionBox(title: "Command Output") {
                    Text("\(result.invocation.command.displayName) · exit \(result.exitCode)")
                        .font(.caption)
                        .foregroundStyle(result.succeeded ? Color.secondary : Color.orange)
                    Text(output)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct DashboardSummaryView: View {
    var snapshot: EngineSnapshot

    var body: some View {
        SectionBox(title: "Dashboard") {
            let report = snapshot.syncReport
            let state = snapshot.legacyState?.content
            MetricGrid(metrics: [
                Metric("과제", report?.state.assignments ?? state?.assignments.count ?? 0),
                Metric("과제 후보", state?.assignmentCandidates.count ?? 0),
                Metric("시험", report?.state.exams ?? state?.examItems.count ?? 0),
                Metric("시험 후보", state?.examCandidates.count ?? 0),
                Metric("헬프데스크", report?.state.helpdesk ?? state?.helpDeskItems.count ?? 0),
                Metric("공지", report?.notices.total ?? 0),
                Metric("새 파일", report?.files.newFiles ?? snapshot.downloadResult?.newFilesCopiedCount ?? 0),
                Metric("격리", report?.files.quarantine ?? snapshot.quarantineReport?.quarantineCount ?? 0),
                Metric("Pruned", report?.files.pruned ?? 0),
                Metric("Cal", (report?.calendar.created ?? 0) + (report?.calendar.updated ?? 0) + (report?.calendar.deleted ?? 0)),
            ])

            if let report, !report.slowest.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Slowest")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(report.slowest.prefix(3)) { stage in
                        Text("\(stage.name) · \(stage.durationSecondsText) · \(stage.status)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct CommandPanelView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        SectionBox(title: "Commands") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                commandButton(.fullSync)
                commandButton(.coreSync)
                commandButton(.noticeSync)
                commandButton(.filesSync)
                commandButton(.verify)
                commandButton(.doctor)
                commandButton(.report)
                commandButton(.v2BuildState)
            }
            Button("원격 요청 처리") {
                Task {
                    await model.processRemoteCommands()
                }
            }
            .disabled(model.runningCommand != nil)
            if let remote = model.lastRemoteCommand {
                Text("Remote: \(remote.kind.rawValue) · \(remote.status.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commandButton(_ command: KLMSEngineCommand) -> some View {
        Button {
            Task {
                await model.run(command)
            }
        } label: {
            Text(command.displayName)
                .frame(maxWidth: .infinity)
        }
        .disabled(model.runningCommand != nil)
    }
}

private struct PreviewPanelView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        SectionBox(title: "Preview") {
            HStack {
                dryRunButton(.fullSync)
                dryRunButton(.coreSync)
                dryRunButton(.noticeSync)
                dryRunButton(.filesSync)
            }
            .buttonStyle(.bordered)

            if !model.snapshot.dryRunReports.isEmpty {
                ForEach(Array(model.snapshot.dryRunReports.keys).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { scope in
                    if let report = model.snapshot.dryRunReports[scope] {
                        Text("\(scope.rawValue): +\(report.wouldCreate) ~\(report.wouldUpdate) -\(report.wouldDelete) download \(report.wouldDownload) prune \(report.wouldPrune)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func dryRunButton(_ command: KLMSEngineCommand) -> some View {
        Button(command.displayName) {
            Task {
                await model.run(command, dryRun: true)
            }
        }
        .disabled(model.runningCommand != nil || !command.supportsDryRun)
    }
}

private struct FilesPanelView: View {
    var snapshot: EngineSnapshot

    var body: some View {
        SectionBox(title: "Files") {
            if let preview = snapshot.filePreview {
                MetricGrid(metrics: [
                    Metric("Manifest", preview.manifestCount),
                    Metric("Actual", preview.actualFileCount),
                    Metric("New URLs", preview.newURLCount),
                    Metric("Moved", preview.movedCount),
                    Metric("Fresh", preview.freshDownloadCandidateCount),
                    Metric("Prune", preview.pruneCandidateCount),
                    Metric("Mismatch", preview.typeMismatchCandidateCount),
                ])
            } else {
                Text("파일 preview가 아직 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let quarantine = snapshot.quarantineReport, quarantine.quarantineCount > 0 {
                Text("격리 파일 \(quarantine.quarantineCount)개 · \(quarantine.quarantineRoot)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            if let download = snapshot.downloadResult {
                MetricGrid(metrics: [
                    Metric("Skipped", download.skippedExistingCount),
                    Metric("Restored", download.restoredFromArchiveCount),
                    Metric("Reused", download.reusedLoggedFileCount),
                    Metric("Fresh", download.freshDownloadCount),
                    Metric("Inbox", download.newFilesCopiedCount),
                    Metric("Download Q", download.quarantineCount),
                ])
            }

            if let cleanup = snapshot.cleanupResult {
                MetricGrid(metrics: [
                    Metric("Deleted", cleanup.actionCount("deleted")),
                    Metric("Kept Fresh", cleanup.actionCount("kept-fresh")),
                    Metric("Preserved", cleanup.actionCount("preserved")),
                    Metric("Restored", cleanup.actionCount("restored")),
                ])
            }

            if let filesDryRun = snapshot.dryRunReports[.files] {
                if !filesDryRun.pruneBackupManifest.isEmpty {
                    Text("Prune backup: \(filesDryRun.pruneBackupManifest)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                if !filesDryRun.archivePruneBackupManifest.isEmpty {
                    Text("Archive prune backup: \(filesDryRun.archivePruneBackupManifest)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct LoginPanelView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        SectionBox(title: "Login") {
            let login = model.snapshot.loginStatus
            Text(login?.loggedIn == true ? "최근 로그인 확인됨" : "로그인 상태 미확인")
                .font(.caption)
                .foregroundStyle(login?.loggedIn == true ? Color.secondary : Color.orange)
            if let checkedAt = login?.checkedAt {
                Text(checkedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Mode: \(model.configValue(.loginAssistMode).isEmpty ? "manual-digits" : model.configValue(.loginAssistMode))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let digits = model.lastCommandResult?.authDigits {
                Text("인증 번호 감지: \(digits)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct LogPanelView: View {
    var snapshot: EngineSnapshot

    var body: some View {
        if !snapshot.launchAgentLogTail.isEmpty {
            SectionBox(title: "LaunchAgent Log") {
                Text(snapshot.launchAgentLogTail)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct FooterActionsView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        HStack {
            Button("새로고침") {
                Task {
                    await model.refresh()
                }
            }
            Button(model.launchAgentState?.isInstalled == true ? "자동실행 끄기" : "자동실행 켜기") {
                Task {
                    await model.toggleLaunchAgent()
                }
            }
            Spacer()
            Button("엔진 폴더") {
                model.openEngineFolder()
            }
            Button("로그") {
                model.openLogsFolder()
            }
        }
        .disabled(model.runningCommand != nil)
    }
}

struct Metric: Identifiable {
    var label: String
    var value: Int
    var id: String { label }

    init(_ label: String, _ value: Int) {
        self.label = label
        self.value = value
    }
}

struct MetricGrid: View {
    var metrics: [Metric]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(metric.value)")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct SectionBox<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
