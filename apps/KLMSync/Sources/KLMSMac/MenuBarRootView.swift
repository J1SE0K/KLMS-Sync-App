import KLMSShared
import AppKit
import SwiftUI

struct MenuBarRootView: View {
    @ObservedObject var model: KLMSMacModel
    @State private var selectedSection = KLMSMacSection.dashboard
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(model: model)
            QuickStatusStripView(model: model)
            ImportantLogPanelView(
                model: model,
                selectedSection: $selectedSection,
                showingSettings: $showingSettings
            )
            CommandPanelView(model: model)

            SectionPickerView(selection: $selectedSection)
                .onChange(of: selectedSection) { _, _ in
                    showingSettings = false
                }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showingSettings {
                        SettingsView(model: model)
                    } else {
                        switch selectedSection {
                        case .dashboard:
                            DashboardSummaryView(model: model)
                            CommandOutputPanelView(model: model)
                        case .preview:
                            PreviewPanelView(model: model)
                            CommandOutputPanelView(model: model)
                        case .files:
                            FilesPanelView(model: model)
                        case .logs:
                            DiagnosticCommandLogPanelView(model: model)
                            DoctorPanelView(snapshot: model.snapshot)
                            AppDiagnosticsPanelView(model: model)
                            LoginPanelView(model: model)
                            LogPanelView(snapshot: model.snapshot, history: model.commandHistory)
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            FooterActionsView(model: model, showingSettings: $showingSettings)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            "대시보드"
        case .preview:
            "미리보기"
        case .files:
            "파일"
        case .logs:
            "진단"
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
            "wrench.and.screwdriver"
        }
    }
}

private struct QuickStatusStripView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        HStack(spacing: 6) {
            StatusChipView(
                title: model.launchAgentState?.isInstalled == true ? "자동실행 켜짐" : "자동실행 꺼짐",
                systemImage: model.launchAgentState?.isInstalled == true ? "bell.fill" : "bell.slash",
                color: model.launchAgentState?.isInstalled == true ? .green : .secondary
            )
            StatusChipView(
                title: "공지 체크리스트",
                systemImage: "checklist.checked",
                color: .blue
            )
            StatusChipView(
                title: lastRunText,
                systemImage: lastRunIcon,
                color: lastRunColor
            )
            Spacer(minLength: 0)
        }
    }

    private var lastRunText: String {
        if model.runningCommand != nil {
            return model.currentPhaseText ?? "실행 중"
        }
        if let result = model.lastCommandResult {
            return result.succeeded ? "최근 실행 성공" : "최근 실행 실패"
        }
        if let report = model.snapshot.syncReport {
            return "요약 \(report.status.klmsLocalizedStatus)"
        }
        return "첫 실행 전"
    }

    private var lastRunIcon: String {
        if model.runningCommand != nil {
            return "arrow.triangle.2.circlepath"
        }
        if let result = model.lastCommandResult {
            return result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        }
        return model.snapshot.syncReport == nil ? "circle.dashed" : "doc.text.magnifyingglass"
    }

    private var lastRunColor: Color {
        if model.runningCommand != nil {
            return .blue
        }
        if let result = model.lastCommandResult {
            return result.succeeded ? .green : .orange
        }
        return model.snapshot.syncReport == nil ? .secondary : .blue
    }
}

private struct StatusChipView: View {
    var title: String
    var systemImage: String
    var color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(color)
            .background(color.opacity(0.11), in: Capsule())
    }
}

private struct SectionPickerView: View {
    @Binding var selection: KLMSMacSection

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 6)], spacing: 6) {
            ForEach(KLMSMacSection.allCases) { section in
                let isSelected = selection == section
                Button {
                    selection = section
                } label: {
                    Label(section.title, systemImage: section.systemImage)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

private struct ImportantLogPanelView: View {
    @ObservedObject var model: KLMSMacModel
    @Binding var selectedSection: KLMSMacSection
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AuthCodeBannerView(digits: model.currentAuthDigits, statusMessage: model.authStatusMessage)
            NextActionPanelView(
                model: model,
                selectedSection: $selectedSection,
                showingSettings: $showingSettings
            )
        }
    }
}

private struct NextActionPanelView: View {
    @ObservedObject var model: KLMSMacModel
    @Binding var selectedSection: KLMSMacSection
    @Binding var showingSettings: Bool

    var body: some View {
        if let action = nextAction {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: action.systemImage)
                    .foregroundStyle(action.color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.caption.weight(.semibold))
                    Text(action.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button {
                    perform(action)
                } label: {
                    Label(action.buttonTitle, systemImage: action.buttonImage)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(action.buttonTitle)
                .accessibilityHint(action.detail)
                .disabled(model.runningCommand != nil && action.kind != .showRunningLog)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(action.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var nextAction: NextAction? {
        if model.runningCommand != nil {
            return NextAction(
                kind: .showRunningLog,
                title: "동기화가 진행 중입니다",
                detail: model.currentPhaseText.map { "현재 단계: \($0)" } ?? "실시간 로그에서 진행 상황을 확인할 수 있습니다.",
                buttonTitle: "로그 보기",
                buttonImage: "text.alignleft",
                systemImage: "arrow.triangle.2.circlepath",
                color: .blue
            )
        }
        if model.currentAuthDigits != nil {
            return nil
        }
        if model.snapshot.needsAttention {
            return NextAction(
                kind: .openDiagnostics,
                title: model.snapshot.attentionSummary,
                detail: "진단 화면에서 권한, 로그인, 파일 상태를 확인하세요.",
                buttonTitle: "진단 보기",
                buttonImage: "wrench.and.screwdriver",
                systemImage: "exclamationmark.triangle.fill",
                color: .orange
            )
        }
        if model.snapshot.syncReport == nil {
            return NextAction(
                kind: .runDoctor,
                title: "첫 실행 준비",
                detail: "환경 진단을 먼저 실행하면 권한과 엔진 상태를 확인할 수 있습니다.",
                buttonTitle: "환경 진단",
                buttonImage: "stethoscope",
                systemImage: "sparkles",
                color: .blue
            )
        }
        if model.appDiagnostics.codeSigning.isAdHoc {
            return NextAction(
                kind: .openSettings,
                title: "앱 권한이 빌드마다 흔들릴 수 있습니다",
                detail: "현재 앱은 임시 서명 상태입니다. 설정에서 서명/권한 상태를 확인하세요.",
                buttonTitle: "설정 보기",
                buttonImage: "gearshape",
                systemImage: "signature",
                color: .orange
            )
        }
        return nil
    }

    private func perform(_ action: NextAction) {
        switch action.kind {
        case .showRunningLog, .openDiagnostics:
            showingSettings = false
            selectedSection = .logs
        case .copyAuthDigits:
            if let digits = model.currentAuthDigits {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(digits, forType: .string)
            }
        case .runDoctor:
            Task {
                await model.run(.doctor)
            }
        case .openSettings:
            showingSettings = true
        }
    }
}

private struct NextAction {
    enum Kind {
        case showRunningLog
        case copyAuthDigits
        case openDiagnostics
        case runDoctor
        case openSettings
    }

    var kind: Kind
    var title: String
    var detail: String
    var buttonTitle: String
    var buttonImage: String
    var systemImage: String
    var color: Color
}

private struct HeaderView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        HStack(alignment: .top) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
            Text("실행 잠금: 프로세스 \(lock.pid) · 명령 \(lock.command) · \(lock.acquiredAt)")
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if model.runningCommand != nil, let progress = model.liveProgressLine {
            VStack(alignment: .leading, spacing: 2) {
                if let phase = model.currentPhaseText {
                    Text("현재 단계: \(phase)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                Text(progress)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private var statusText: String {
        if let command = model.runningCommand {
            return "\(command.displayName) 실행 중"
        }
        if model.snapshot.needsAttention {
            return "주의 필요 · \(model.snapshot.attentionSummary)"
        }
        if let report = model.snapshot.syncReport {
            return "준비됨 · \(report.status.klmsLocalizedStatus)"
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
    @State private var showingFullOutput = false

    var body: some View {
        let output = commandOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            SectionBox(title: model.runningCommand == nil ? "실행 결과" : "실시간 로그") {
                Text(commandStatusText)
                    .font(.caption)
                    .foregroundStyle(commandStatusColor)
                Text(visibleOutput(from: output))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if outputLineCount(output) > 40 {
                    DisclosureGroup(isExpanded: $showingFullOutput) {
                        Text(output)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } label: {
                        Text("전체 원본 로그")
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var commandOutput: String {
        if !model.liveCommandOutput.isEmpty {
            return model.liveCommandOutput.klmsDisplayText
        }
        return model.lastCommandResult?.combinedOutput.klmsDisplayText ?? ""
    }

    private var commandStatusText: String {
        if let command = model.runningCommand {
            return "\(command.displayName) 실행 중"
        }
        if let result = model.lastCommandResult {
            return "\(result.invocation.command.displayName) · 종료 코드 \(result.exitCode)"
        }
        return "대기 중"
    }

    private var commandStatusColor: Color {
        if model.runningCommand != nil {
            return .blue
        }
        if let result = model.lastCommandResult {
            return result.succeeded ? Color.secondary : Color.orange
        }
        return .secondary
    }

    private func visibleOutput(from output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count > 40 else {
            return output
        }
        return lines.suffix(40).joined(separator: "\n")
    }

    private func outputLineCount(_ output: String) -> Int {
        output.split(whereSeparator: \.isNewline).count
    }
}

private struct DiagnosticCommandLogPanelView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        SectionBox(title: "진단/실행 로그") {
            VStack(alignment: .leading, spacing: 8) {
                if let source = activeLogSource {
                    HStack(spacing: 8) {
                        Label(source.title, systemImage: source.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(source.isWarning ? .orange : .primary)
                        Text("\(source.lineCount)줄")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    if !source.detail.isEmpty {
                        Text(source.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    LogTextBlock(text: source.text)
                } else {
                    Text("아직 표시할 실행 로그가 없습니다. 위의 권한/환경 진단 또는 동기화 버튼을 실행하면 이곳에 실시간 로그와 마지막 로그가 표시됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var activeLogSource: DiagnosticLogSource? {
        let liveOutput = cleaned(model.liveCommandOutput)
        if !liveOutput.isEmpty {
            return DiagnosticLogSource(
                title: "\(model.runningCommand?.displayName ?? "명령") 실시간 로그",
                detail: model.currentPhaseText.map { "현재 단계: \($0)" } ?? "실시간으로 들어오는 표준 출력/오류입니다.",
                systemImage: "dot.radiowaves.left.and.right",
                text: liveOutput,
                isWarning: false
            )
        }

        if let result = model.lastCommandResult {
            let output = cleaned(result.combinedOutput)
            if !output.isEmpty {
                return DiagnosticLogSource(
                    title: "\(result.invocation.command.displayName) 마지막 실행 로그",
                    detail: "\(result.startedAt.formatted(date: .numeric, time: .standard)) 시작 · 종료 코드 \(result.exitCode)",
                    systemImage: result.succeeded ? "doc.text" : "exclamationmark.triangle",
                    text: output,
                    isWarning: !result.succeeded
                )
            }
        }

        if let record = model.commandHistory.records.first(where: { $0.command.isDiagnostic && !cleaned($0.outputTail).isEmpty }) {
            return historySource(record, titlePrefix: "최근 진단 기록")
        }

        let doctorText = cleaned(doctorResultText)
        if !doctorText.isEmpty {
            return DiagnosticLogSource(
                title: "저장된 진단 결과",
                detail: "runtime/cache/doctor_result.json에서 읽은 최신 진단 항목입니다.",
                systemImage: model.snapshot.doctorResult?.status.lowercased() == "ok" ? "checkmark.seal" : "exclamationmark.triangle",
                text: doctorText,
                isWarning: model.snapshot.doctorResult?.status.lowercased() != "ok"
            )
        }

        if let record = model.commandHistory.records.first(where: { !cleaned($0.outputTail).isEmpty }) {
            return historySource(record, titlePrefix: "최근 일반 실행 기록")
        }

        let launchAgentLog = cleaned(model.snapshot.launchAgentLogTail)
        if !launchAgentLog.isEmpty {
            return DiagnosticLogSource(
                title: "자동실행 로그",
                detail: "runtime/logs/launch-agent.log의 최근 항목입니다.",
                systemImage: "clock.arrow.circlepath",
                text: launchAgentLog,
                isWarning: false
            )
        }

        return nil
    }

    private func historySource(_ record: CommandRunRecord, titlePrefix: String) -> DiagnosticLogSource {
        DiagnosticLogSource(
            title: "\(titlePrefix) · \(record.command.displayName) · \(record.statusText)",
            detail: "\(record.startedAt.formatted(date: .numeric, time: .standard)) 시작 · \(record.elapsedSecondsText)",
            systemImage: record.succeeded ? "doc.text" : "exclamationmark.triangle",
            text: cleaned(record.outputTail),
            isWarning: !record.succeeded
        )
    }

    private func cleaned(_ text: String) -> String {
        text.klmsDisplayText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var doctorResultText: String {
        guard let doctor = model.snapshot.doctorResult else {
            return ""
        }
        var lines = ["status=\(doctor.status)"]
        for check in doctor.checks {
            let detail = check.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                lines.append("\(check.status)\t\(check.name)")
            } else {
                lines.append("\(check.status)\t\(check.name)\t\(detail)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

private struct DiagnosticLogSource {
    var title: String
    var detail: String
    var systemImage: String
    var text: String
    var isWarning: Bool

    var lineCount: Int {
        max(1, text.split(whereSeparator: \.isNewline).count)
    }
}

private struct LogTextBlock: View {
    var text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
        }
        .frame(minHeight: 120, maxHeight: 280)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct AuthCodeBannerView: View {
    var digits: String?
    var statusMessage: String?

    var body: some View {
        if let digits {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("KAIST 인증 번호")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(digits)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(digits, forType: .string)
                } label: {
                    Label("복사", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("KAIST 인증 번호 복사")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        } else if let statusMessage {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(statusMessage)
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct DashboardSummaryView: View {
    @ObservedObject var model: KLMSMacModel
    @State private var selectedDetail = DashboardDetailKind.assignments

    var body: some View {
        SectionBox(title: "대시보드") {
            let snapshot = model.snapshot
            let report = snapshot.syncReport
            let state = snapshot.legacyState?.content
            let assignmentCandidateCount = state?.assignmentCandidates.count ?? 0
            let examCandidateCount = state?.examCandidates.count ?? 0
            let completedAssignmentCount = state?.completedAssignments.count ?? 0
            let prunedCount = report?.files.pruned ?? 0
            let hiddenCount = DashboardHiddenMetric.count(snapshot: snapshot)
            let visibleMetrics = [
                Metric("과제", state?.assignments.count ?? report?.state.assignments ?? 0, detail: .assignments),
                Metric("시험", state?.examItems.count ?? report?.state.exams ?? 0, detail: .exams),
                Metric("헬프데스크", state?.helpDeskItems.count ?? report?.state.helpdesk ?? 0, detail: .helpDesk),
                Metric("공지", report?.notices.total ?? snapshot.noticeDigest?.noticeCount ?? 0, detail: .notices),
                Metric("새 파일", report?.files.newFiles ?? snapshot.downloadResult?.newFilesCopiedCount ?? 0, detail: .newFiles),
                Metric("격리", report?.files.quarantine ?? snapshot.quarantineReport?.quarantineCount ?? 0, detail: .quarantine),
                Metric("캘린더", (report?.calendar.created ?? 0) + (report?.calendar.updated ?? 0) + (report?.calendar.deleted ?? 0), detail: .calendar),
            ] + [
                Metric("완료 기록", completedAssignmentCount, detail: .assignmentRecords),
                Metric("과제 후보", assignmentCandidateCount, detail: .assignmentCandidates),
                Metric("시험 후보", examCandidateCount, detail: .examCandidates),
                Metric("삭제된 파일", prunedCount, detail: .pruned),
                Metric("숨김", hiddenCount, detail: .hidden),
            ].filter { $0.value > 0 }
            IssueSummaryView(issues: snapshot.issues)
            MetricGrid(metrics: visibleMetrics, selectedMetricID: selectedDetail.rawValue) { metric in
                if let detail = metric.detail {
                    selectedDetail = detail
                }
            }
            DashboardDetailPanelView(kind: selectedDetail, model: model)

            NoticeMemoStatusView(model: model)
            SlowestWorkView(report: report)
        }
    }
}

private struct SlowestWorkView: View {
    var report: SyncReport?

    var body: some View {
        if let report, !report.slowest.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("오래 걸린 작업")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(report.slowest.prefix(3)) { stage in
                    Text("\(stage.name.klmsDisplayStageName) · \(stage.durationSecondsText) · \(stage.status.klmsLocalizedStatus)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        }
    }
}

private struct NoticeMemoStatusView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        let snapshot = model.snapshot
        if snapshot.noticeDigest != nil || snapshot.noticeRenderState != nil || snapshot.noticeArchiveRenderState != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("공지 메모", systemImage: "note.text")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(renderModeText)
                        .font(.caption2)
                        .foregroundStyle(renderModeColor)
                    if let generatedAt = snapshot.noticeDigest?.generatedAt, !generatedAt.isEmpty {
                        Text("기준 \(generatedAt)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                NoticeMemoRowView(label: "KLMS 공지", state: snapshot.noticeRenderState, model: model)
                NoticeMemoRowView(label: "KLMS 확인한 공지", state: snapshot.noticeArchiveRenderState, model: model)
                if let timing = snapshot.noticeStageTiming {
                    Text("최근 공지 메모 작성: \(timing.status.klmsLocalizedStatus) · \(timing.elapsedSecondsText) · 체크리스트/문단 형식")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(timing.noticeRenderResults.prefix(3)) { result in
                        Text("\(noticeTargetText(result.target)): \(result.status.klmsLocalizedStatus)")
                            .font(.caption2)
                            .foregroundStyle(noticeResultIsOK(result.status) ? Color.secondary : Color.orange)
                    }
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var renderModeText: String {
        "체크리스트/문단"
    }

    private var renderModeColor: Color {
        .blue
    }

    private func noticeTargetText(_ target: String) -> String {
        switch target {
        case "capture":
            "체크 표시 읽기"
        case "primary":
            "KLMS 공지"
        case "archive":
            "확인한 공지"
        default:
            target
        }
    }

    private func noticeResultIsOK(_ status: String) -> Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "ok" || normalized == "skipped"
    }
}

private struct NoticeMemoRowView: View {
    var label: String
    var state: NoticeNoteRenderState?
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button {
                model.openNoticeNote(state, fallbackTitle: label)
            } label: {
                Label("열기", systemImage: "arrow.up.forward.app")
            }
            .disabled(state == nil)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("\(label) 열기")
        }
    }

    private var detailText: String {
        guard let state else {
            return "아직 작성 기록 없음"
        }
        let title = (state.noteTitle.isEmpty ? label : state.noteTitle).klmsDisplayText
        let updated = (state.updatedAt.isEmpty ? "수정 시각 없음" : state.updatedAt).klmsDisplayText
        return "\(title) · \(state.renderedNoticeCount)건 · \(updated)"
    }
}

private enum DashboardHiddenMetric {
    static func count(snapshot: EngineSnapshot) -> Int {
        let content = snapshot.legacyState?.content
        let overrides = snapshot.manualOverrides
        let assignmentCount = (
            (content?.assignments ?? [])
                + (content?.assignmentCandidates ?? [])
                + (content?.completedAssignments ?? [])
                + (content?.assignmentRecords ?? [])
        )
            .filter { overrides?.isAssignmentHidden($0) == true }
            .reduce(into: Set<String>()) { keys, item in
                keys.insert(item.id)
            }
            .count
        let examCount = ((content?.examItems ?? []) + (content?.examCandidates ?? []))
            .filter { overrides?.isExamHidden($0) == true }
            .count
        let noticeCount = (snapshot.noticeDigest?.notices ?? [])
            .filter { snapshot.noticeUserState?.notices[$0.noticeIdentifier]?.hidden == true }
            .count
        let fileCount = snapshot.appUserState?.files.values.filter(\.isHiddenLike).count ?? 0
        let quarantineCount = snapshot.appUserState?.quarantine.values.filter(\.isHiddenLike).count ?? 0
        return assignmentCount + examCount + noticeCount + fileCount + quarantineCount
    }
}

private struct CommandPanelView: View {
    @ObservedObject var model: KLMSMacModel
    @State private var showingAdvancedTools = false
    private let commandColumns = [GridItem(.adaptive(minimum: 150), spacing: 8)]
    private let toolColumns = [GridItem(.adaptive(minimum: 140), spacing: 8)]

    var body: some View {
        SectionBox(title: "바로 실행") {
            VStack(alignment: .leading, spacing: 10) {
                commandButton(.fullSync, prominence: .primary)
                LazyVGrid(columns: commandColumns, spacing: 8) {
                    commandButton(.coreSync)
                    commandButton(.noticeSync)
                    commandButton(.filesSync)
                }

                DisclosureGroup(isExpanded: $showingAdvancedTools) {
                    VStack(alignment: .leading, spacing: 8) {
                        LazyVGrid(columns: toolColumns, spacing: 8) {
                            commandButton(.verify)
                            commandButton(.doctor)
                            commandButton(.report)
                            commandButton(.v2BuildState)
                        }
                        Toggle(
                            "로컬 iPhone 원격 제어",
                            isOn: Binding(
                                get: { model.localRemoteEnabled },
                                set: { model.setLocalRemoteEnabled($0) }
                            )
                        )
                        .toggleStyle(.switch)
                        .help("같은 Wi-Fi의 iPhone 앱에서 이 Mac으로 직접 실행 요청을 보낼 수 있게 합니다.")
                        .accessibilityHint("같은 Wi-Fi의 iPhone 앱에서 이 Mac으로 직접 실행 요청을 보낼 수 있게 합니다.")

                        if model.localRemoteEnabled {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.localRemoteStatusMessage ?? "로컬 원격 제어 준비 중")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    Text("주소: \(model.localRemotePrimaryEndpoint)")
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                    Spacer(minLength: 4)
                                    Button {
                                        model.copyLocalRemoteEndpoint()
                                    } label: {
                                        Label("주소 복사", systemImage: "doc.on.doc")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("이 주소를 복사합니다.")
                                }
                                HStack(spacing: 8) {
                                    Text("토큰: \(model.localRemoteToken)")
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                    Spacer(minLength: 4)
                                    Button {
                                        model.copyLocalRemoteToken()
                                    } label: {
                                        Label("토큰 복사", systemImage: "doc.on.doc")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("iPhone 앱에 입력할 토큰을 복사합니다.")
                                    Button {
                                        model.regenerateLocalRemoteToken()
                                    } label: {
                                        Label("토큰 재생성", systemImage: "arrow.triangle.2.circlepath")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("기존 iPhone 연결 토큰을 폐기하고 새 토큰을 만듭니다.")
                                }
                                Button {
                                    model.copyLocalRemoteConnectionInfo()
                                } label: {
                                    Label("주소와 토큰 복사", systemImage: "doc.on.clipboard")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quinary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        Toggle(
                            "CloudKit iPhone 요청 자동 처리",
                            isOn: Binding(
                                get: { model.remoteProcessingEnabled },
                                set: { model.setRemoteProcessingEnabled($0) }
                            )
                        )
                        .toggleStyle(.switch)
                        .disabled(!model.appDiagnostics.codeSigning.cloudKitEntitled)
                        .help("켜두면 Mac 앱이 CloudKit의 iPhone 실행 요청을 주기적으로 확인해 실행합니다.")
                        .accessibilityHint("켜두면 Mac 앱이 CloudKit의 iPhone 실행 요청을 주기적으로 확인해 실행합니다.")

                        Button {
                            Task {
                                await model.processRemoteCommands(silent: false)
                            }
                        } label: {
                            Label(
                                model.isCheckingRemoteCommands ? "iPhone 요청 확인 중" : "iPhone 요청 지금 확인",
                                systemImage: "iphone.radiowaves.left.and.right"
                            )
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            model.runningCommand != nil
                                || model.isCheckingRemoteCommands
                                || !model.appDiagnostics.codeSigning.cloudKitEntitled
                        )
                        .help("iPhone companion이 CloudKit에 올린 실행 요청을 Mac에서 바로 확인합니다.")
                        .accessibilityLabel("iPhone 요청 지금 확인")
                        .accessibilityHint("iPhone companion이 CloudKit에 올린 실행 요청을 Mac에서 바로 확인합니다.")

                        if let remote = model.lastRemoteCommand {
                            Text("최근 iPhone 요청: \(remote.kind.displayName) · \(remote.status.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let message = model.remoteProcessingStatusMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !model.appDiagnostics.codeSigning.cloudKitEntitled {
                            Text("iPhone 원격 요청은 CloudKit entitlement/provisioning 설정 후 사용할 수 있습니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label("점검 도구", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }

            if let command = model.runningCommand {
                Button(role: .destructive) {
                    Task {
                        await model.cancelRunningCommand()
                    }
                } label: {
                    Label(
                        model.isCancellingCommand ? "중단 요청 중..." : "\(command.displayName) 중단",
                        systemImage: "stop.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isCancellingCommand)
                .accessibilityLabel("\(command.displayName) 중단")
                .accessibilityHint("현재 실행 중인 동기화를 중단합니다.")
            }
        }
    }

    private enum CommandProminence {
        case standard
        case primary
    }

    @ViewBuilder
    private func commandButton(_ command: KLMSEngineCommand, prominence: CommandProminence = .standard) -> some View {
        if prominence == .primary {
            commandButtonContent(command)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .font(.callout.weight(.semibold))
        } else {
            commandButtonContent(command)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func commandButtonContent(_ command: KLMSEngineCommand) -> some View {
        Button {
            Task {
                await model.run(command)
            }
        } label: {
            Label(command.displayName, systemImage: command.systemImage)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
                .frame(minHeight: command == .fullSync ? 34 : 30)
        }
        .help(command.shortDescription)
        .accessibilityLabel(command.displayName)
        .accessibilityHint(command.shortDescription)
        .disabled(model.runningCommand != nil)
    }
}

private struct PreviewPanelView: View {
    @ObservedObject var model: KLMSMacModel
    private let previewColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        SectionBox(title: "미리보기") {
            LazyVGrid(columns: previewColumns, spacing: 8) {
                dryRunButton(.fullSync)
                dryRunButton(.coreSync)
                dryRunButton(.noticeSync)
                dryRunButton(.filesSync)
            }
            .buttonStyle(.bordered)

            if !model.snapshot.dryRunReports.isEmpty {
                ForEach(Array(model.snapshot.dryRunReports.keys).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { scope in
                    if let report = model.snapshot.dryRunReports[scope] {
                        Text("\(scope.displayName): 생성 \(report.wouldCreate) · 수정 \(report.wouldUpdate) · 삭제 \(report.wouldDelete) · 다운로드 \(report.wouldDownload) · 파일 삭제 예정 \(report.wouldPrune)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func dryRunButton(_ command: KLMSEngineCommand) -> some View {
        Button {
            Task {
                await model.run(command, dryRun: true)
            }
        } label: {
            Label(command.displayName, systemImage: command.systemImage)
        }
        .help("실제 반영 없이 변경 예정량만 확인합니다.")
        .accessibilityLabel("\(command.displayName) 미리보기")
        .accessibilityHint("실제 반영 없이 변경 예정량만 확인합니다.")
        .disabled(model.runningCommand != nil || !command.supportsDryRun)
    }
}

private struct FilesPanelView: View {
    @ObservedObject var model: KLMSMacModel
    @State private var selectedDetail = DashboardDetailKind.newFiles

    private var snapshot: EngineSnapshot {
        model.snapshot
    }

    var body: some View {
        SectionBox(title: "파일") {
            if let preview = snapshot.filePreview {
                MetricGrid(metrics: [
                    Metric("파일 목록", preview.manifestCount),
                    Metric("실제 파일", preview.actualFileCount),
                    Metric("새 URL", preview.newURLCount, detail: .newFiles),
                    Metric("이동", preview.movedCount),
                    Metric("새로 받을 파일", preview.freshDownloadCandidateCount, detail: .newFiles),
                    Metric("삭제 예정", preview.pruneCandidateCount, detail: .pruned),
                    Metric("형식 불일치", preview.typeMismatchCandidateCount),
                ], selectedMetricID: selectedDetail.rawValue) { metric in
                    if let detail = metric.detail {
                        selectedDetail = detail
                    }
                }
            } else {
                Text("파일 변경 미리보기가 아직 없습니다.")
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
                    Metric("이미 있음", download.skippedExistingCount),
                    Metric("복원", download.restoredFromArchiveCount),
                    Metric("재사용", download.reusedLoggedFileCount),
                    Metric("새 다운로드", download.freshDownloadCount, detail: .newFiles),
                    Metric("새 파일 보관함", download.newFilesCopiedCount, detail: .newFiles),
                    Metric("격리됨", download.quarantineCount, detail: .quarantine),
                ], selectedMetricID: selectedDetail.rawValue) { metric in
                    if let detail = metric.detail {
                        selectedDetail = detail
                    }
                }
            }

            if let cleanup = snapshot.cleanupResult {
                MetricGrid(metrics: [
                    Metric("삭제", cleanup.actionCount("deleted"), detail: .pruned),
                    Metric("새 파일 유지", cleanup.actionCount("kept-fresh")),
                    Metric("보존", cleanup.actionCount("preserved")),
                    Metric("복원", cleanup.actionCount("restored")),
                ], selectedMetricID: selectedDetail.rawValue) { metric in
                    if let detail = metric.detail {
                        selectedDetail = detail
                    }
                }
            }

            if let filesDryRun = snapshot.dryRunReports[.files] {
                if !filesDryRun.pruneBackupManifest.isEmpty {
                    Text("삭제 전 백업 목록: \(filesDryRun.pruneBackupManifest)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                if !filesDryRun.archivePruneBackupManifest.isEmpty {
                    Text("임시 다운로드 삭제 전 백업 목록: \(filesDryRun.archivePruneBackupManifest)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Divider()
            DashboardDetailPanelView(kind: selectedDetail, model: model)
        }
    }
}

private struct LoginPanelView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        SectionBox(title: "로그인") {
            let login = model.snapshot.loginStatus
            Text(login?.loggedIn == true ? "최근 로그인 확인됨" : "로그인 상태 미확인")
                .font(.caption)
                .foregroundStyle(login?.loggedIn == true ? Color.secondary : Color.orange)
            if let checkedAt = login?.checkedAt {
                Text(checkedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("인증 방식: \(loginAssistModeText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let digits = model.currentAuthDigits {
                HStack(spacing: 8) {
                    Text("인증 번호")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(digits)
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var loginAssistModeText: String {
        switch model.configValue(.loginAssistMode) {
        case "kaikey-auto":
            "Kaikey 자동"
        case "manual-digits", "":
            "수동 인증번호"
        case let value:
            value
        }
    }
}

private struct DoctorPanelView: View {
    var snapshot: EngineSnapshot

    var body: some View {
        if let doctor = snapshot.doctorResult {
            SectionBox(title: "진단") {
                let issueChecks = doctor.checks.filter { ["fail", "failed", "error", "warn", "warning"].contains($0.status.lowercased()) }
                Text("상태: \(doctor.status.klmsLocalizedStatus) · 정상 \(doctor.checks.filter { $0.status.lowercased() == "ok" }.count)개")
                    .font(.caption)
                    .foregroundStyle(doctor.status.lowercased() == "ok" ? Color.secondary : Color.orange)

                if issueChecks.isEmpty {
                    Text("진단에서 발견된 문제가 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(issueChecks) { check in
                        DoctorCheckRowView(check: check)
                    }
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(doctor.checks) { check in
                            DoctorCheckRowView(check: check, compact: true)
                        }
                    }
                } label: {
                    Text("전체 진단 항목 \(doctor.checks.count)개")
                        .font(.caption)
                }
            }
        }
    }
}

private struct DoctorCheckRowView: View {
    var check: DoctorCheck
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(check.name) · \(check.status.klmsLocalizedStatus)")
                    .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                if !check.detail.isEmpty {
                    Text(check.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(compact ? 6 : 8)
        .background(compact ? Color(nsColor: .controlBackgroundColor) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var systemImage: String {
        if ["fail", "failed", "error"].contains(check.status.lowercased()) {
            return "xmark.octagon.fill"
        }
        if ["warn", "warning"].contains(check.status.lowercased()) {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var color: Color {
        if ["fail", "failed", "error"].contains(check.status.lowercased()) {
            return .red
        }
        if ["warn", "warning"].contains(check.status.lowercased()) {
            return .orange
        }
        return .green
    }
}

private struct AppDiagnosticsPanelView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        SectionBox(title: "앱/권한") {
            let diagnostics = model.appDiagnostics
            VStack(alignment: .leading, spacing: 8) {
                DiagnosticRowView(
                    title: "코드 서명",
                    value: diagnostics.codeSigning.statusTitle,
                    detail: diagnostics.codeSigning.statusDetail,
                    isWarning: diagnostics.codeSigning.needsAttention
                )
                DiagnosticRowView(
                    title: "서명 인증서",
                    value: signingIdentityText,
                    detail: "고정 인증서로 서명하면 앱 재빌드 후에도 자동화 권한이 안정적으로 유지됩니다.",
                    isWarning: (diagnostics.codeSigning.validIdentityCount ?? 0) == 0
                )
                DiagnosticRowView(
                    title: "공지 메모 작성",
                    value: "체크리스트/문단 형식",
                    detail: "앱 실행은 대시보드 상태를 기준으로 Notes 메모를 다시 작성합니다. 체크리스트와 문단 형식을 적용하려면 자동화/손쉬운 사용 권한이 필요합니다.",
                    isWarning: false
                )
                DiagnosticRowView(
                    title: "엔진",
                    value: diagnostics.installedPayloadVersion.isEmpty ? "설치 필요" : diagnostics.installedPayloadVersion,
                    detail: diagnostics.engineRoot,
                    isWarning: diagnostics.installedPayloadVersion.isEmpty
                )

                HStack {
                    Button {
                        Task {
                            await model.requestAppPermissions()
                        }
                    } label: {
                        Label("권한 요청", systemImage: "key")
                    }
                    .disabled(model.runningCommand != nil)
                    Button {
                        model.openAutomationSettings()
                    } label: {
                        Label("자동화 권한 열기", systemImage: "hand.raised")
                    }
                    Button {
                        model.openAccessibilitySettings()
                    } label: {
                        Label("손쉬운 사용 열기", systemImage: "accessibility")
                    }
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let permissionStatusMessage = model.permissionStatusMessage,
                   !permissionStatusMessage.isEmpty {
                    Text(permissionStatusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !model.permissionProbeRows.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("권한 점검 결과")
                            .font(.caption.weight(.semibold))
                        ForEach(model.permissionProbeRows) { row in
                            DiagnosticRowView(
                                title: row.title,
                                value: row.value,
                                detail: row.detail,
                                isWarning: row.isWarning
                            )
                        }
                    }
                }

                DisclosureGroup("필요 권한 범위") {
                    VStack(alignment: .leading, spacing: 6) {
                        PermissionScopeText("손쉬운 사용: 시스템 설정에서 KLMS Sync를 켜야 합니다. KLMS 공지 메모 렌더러가 보이면 그것도 켜야 합니다.")
                        PermissionScopeText("손쉬운 사용 사용처: Notes 편집 영역 포커스, 체크리스트와 문단 형식 적용")
                        PermissionScopeText("자동화 · Safari: KLMS 로그인 확인, 페이지 수집, 파일 다운로드")
                        PermissionScopeText("자동화 · Notes: 공지 메모 열기, 선택, 본문 갱신")
                        PermissionScopeText("자동화 · System Events: Notes 메뉴 조작과 포커스 확인")
                        PermissionScopeText("자동화 · Calendar/Reminders: 레거시 스크립트와 상태 확인 경로")
                        PermissionScopeText("캘린더/미리 알림 전체 접근: EventKit 기반 일정과 알림 동기화")
                        PermissionScopeText("알림: KAIST 인증번호와 실패 상태를 앱에서 즉시 표시")
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
    }

    private var signingIdentityText: String {
        guard let count = model.appDiagnostics.codeSigning.validIdentityCount else {
            return "확인 불가"
        }
        return count == 0 ? "사용 가능한 인증서 없음" : "\(count)개 사용 가능"
    }
}

private struct PermissionScopeText: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DiagnosticRowView: View {
    var title: String
    var value: String
    var detail: String
    var isWarning: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isWarning ? .orange : .green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title): \(value)")
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LogPanelView: View {
    var snapshot: EngineSnapshot
    var history: CommandRunHistory

    var body: some View {
        if !history.records.isEmpty {
            SectionBox(title: "실행 기록") {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(history.records.prefix(10)) { record in
                        CommandHistoryRowView(record: record)
                    }
                }
            }
        }

        if !snapshot.launchAgentLogTail.isEmpty {
            SectionBox(title: "자동실행 로그") {
                LogTextBlock(text: snapshot.launchAgentLogTail.klmsDisplayText)
            }
        } else if history.records.isEmpty {
            SectionBox(title: "저장된 로그") {
                Text("저장된 실행 기록이나 자동실행 로그가 아직 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CommandHistoryRowView: View {
    var record: CommandRunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.command.displayName)
                    .font(.caption.weight(.semibold))
                if record.dryRun {
                    Text("미리보기")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                Spacer()
                Text(record.statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(record.succeeded ? .green : .orange)
            }
            Text("\(record.startedAt.formatted(date: .numeric, time: .standard)) · \(record.elapsedSecondsText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !record.outputTail.isEmpty {
                DisclosureGroup {
                    Text(record.outputTail)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text("마지막 로그 보기")
                        .font(.caption2)
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct IssueSummaryView: View {
    var issues: [EngineIssue]

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(issues.prefix(5)) { issue in
                    IssueRowView(issue: issue)
                }
            }
        }
    }
}

private struct IssueRowView: View {
    var issue: EngineIssue

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: issue.severity.systemImage)
                .foregroundStyle(issue.severity.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                if !issue.detail.isEmpty {
                    Text(issue.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(issue.severity.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension EngineIssue.Severity {
    var color: Color {
        switch self {
        case .warning:
            .orange
        case .error:
            .red
        }
    }

    var systemImage: String {
        switch self {
        case .warning:
            "exclamationmark.triangle.fill"
        case .error:
            "xmark.octagon.fill"
        }
    }
}

private struct FooterActionsView: View {
    @ObservedObject var model: KLMSMacModel
    @Binding var showingSettings: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await model.refresh(clearDisplayLogs: true)
                }
            } label: {
                Label("새로고침", systemImage: "arrow.clockwise")
            }
            .disabled(model.runningCommand != nil)
            Button {
                model.clearDisplayState(resetSnapshot: true)
            } label: {
                Label("초기화", systemImage: "eraser")
            }
            .disabled(model.runningCommand != nil)
            Button {
                showingSettings.toggle()
            } label: {
                Label(showingSettings ? "설정 닫기" : "설정", systemImage: showingSettings ? "xmark.circle" : "gearshape")
            }
            Spacer()
            Button {
                Task {
                    await model.toggleLaunchAgent()
                }
            } label: {
                Label(
                    model.launchAgentState?.isInstalled == true ? "자동실행 끄기" : "자동실행 켜기",
                    systemImage: model.launchAgentState?.isInstalled == true ? "bell.slash" : "bell"
                )
            }
            .disabled(model.runningCommand != nil)
            Menu {
                Button {
                    Task {
                        await model.requestAppPermissions()
                    }
                } label: {
                    Label("권한 요청", systemImage: "key")
                }
                .disabled(model.runningCommand != nil)
                Button {
                    model.openEngineFolder()
                } label: {
                    Label("엔진 폴더", systemImage: "folder")
                }
                Button {
                    model.openLogsFolder()
                } label: {
                    Label("로그 폴더", systemImage: "doc.text")
                }
                Button {
                    model.openAutomationSettings()
                } label: {
                    Label("자동화 권한", systemImage: "hand.raised")
                }
                Button {
                    model.openAccessibilitySettings()
                } label: {
                    Label("손쉬운 사용 권한", systemImage: "accessibility")
                }
            } label: {
                Label("열기", systemImage: "square.grid.2x2")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

struct Metric: Identifiable {
    var label: String
    var value: Int
    var detail: DashboardDetailKind?
    var id: String { label }

    init(_ label: String, _ value: Int, detail: DashboardDetailKind? = nil) {
        self.label = label
        self.value = value
        self.detail = detail
    }
}

struct MetricGrid: View {
    var metrics: [Metric]
    var selectedMetricID: String?
    var onSelect: ((Metric) -> Void)?

    init(
        metrics: [Metric],
        selectedMetricID: String? = nil,
        onSelect: ((Metric) -> Void)? = nil
    ) {
        self.metrics = metrics
        self.selectedMetricID = selectedMetricID
        self.onSelect = onSelect
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
            ForEach(metrics) { metric in
                if let onSelect {
                    Button {
                        onSelect(metric)
                    } label: {
                        MetricTile(metric: metric, isSelected: metric.detail?.rawValue == selectedMetricID)
                    }
                    .buttonStyle(.plain)
                    .disabled(metric.detail == nil)
                } else {
                    MetricTile(metric: metric, isSelected: false)
                }
            }
        }
    }
}

private struct MetricTile: View {
    var metric: Metric
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(metric.value)")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .quaternaryLabelColor).opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1)
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
