import KLMSShared
import AppKit
import SwiftUI

struct MenuBarRootView: View {
    @ObservedObject var model: KLMSMacModel
    @State private var selectedSection = KLMSMacSection.dashboard
    @State private var expandedLogSummaryKind: LogSummaryKind?

    var body: some View {
        WholeScreenVerticalScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HeaderView(model: model)
                ImportantLogPanelView(
                    model: model,
                    selectedSection: $selectedSection,
                    expandedLogSummaryKind: $expandedLogSummaryKind
                )
                CommandPanelView(model: model)
                QuickStatusStripView(model: model)
                ExternalIntegrationStatusView(model: model)

                SectionPickerView(selection: $selectedSection)

                VStack(alignment: .leading, spacing: 16) {
                    switch selectedSection {
                    case .dashboard:
                        DashboardSummaryView(model: model)
                        CommandOutputPanelView(model: model)
                    case .activityLogs:
                        LogSummaryPanelView(model: model, expandedKind: $expandedLogSummaryKind)
                        RemoteActivityPanelView(model: model)
                        RunLogArchivePanelView(model: model)
                    case .diagnostics:
                        DiagnosticToolsPanelView(model: model)
                        DiagnosticCommandLogPanelView(model: model)
                        VerifyPanelView(snapshot: model.snapshot)
                        DoctorPanelView(snapshot: model.snapshot)
                        AppDiagnosticsPanelView(model: model)
                        LoginPanelView(model: model)
                        LogPanelView(snapshot: model.snapshot, history: model.commandHistory)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .topLeading)

                Divider()

                FooterActionsView(model: model)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.klmsMacScreenBackground)
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
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
        }
    }
}

struct DiagnosticWindowView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        WholeScreenVerticalScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.klmsMacCommandAccent)
                        .frame(width: 30, height: 30)
                        .background(Color.klmsMacCommandAccent.opacity(0.10), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("진단 로그")
                            .font(.headline.weight(.semibold))
                        Text("상단 경고에서 진단 보기를 눌렀을 때 필요한 실패 로그와 검사 결과를 바로 보여줍니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if model.runningCommand != nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                DiagnosticCommandLogPanelView(model: model)
                VerifyPanelView(snapshot: model.snapshot)
                DoctorPanelView(snapshot: model.snapshot)
                AppDiagnosticsPanelView(model: model)
                LoginPanelView(model: model)
                LogPanelView(snapshot: model.snapshot, history: model.commandHistory)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.klmsMacScreenBackground)
    }
}

private enum KLMSMacSection: String, CaseIterable, Identifiable {
    case dashboard
    case activityLogs
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:
            "대시보드"
        case .activityLogs:
            "로그"
        case .diagnostics:
            "진단"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard:
            "gauge.with.dots.needle.67percent"
        case .activityLogs:
            "list.bullet.rectangle.portrait"
        case .diagnostics:
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
            if result.wasCancelled {
                return "최근 실행 중단됨"
            }
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
            if result.wasCancelled {
                return "stop.circle.fill"
            }
            return result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        }
        return model.snapshot.syncReport == nil ? "circle.dashed" : "doc.text.magnifyingglass"
    }

    private var lastRunColor: Color {
        if model.runningCommand != nil {
            return .blue
        }
        if let result = model.lastCommandResult {
            if result.wasCancelled {
                return .secondary
            }
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

private struct ExternalIntegrationStatusView: View {
    @ObservedObject var model: KLMSMacModel
    @AppStorage("KLMSMacIntegrationStatusExpanded") private var isExpanded = false
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    var body: some View {
        let verify = model.snapshot.verifyResult
        let statuses = integrationStatuses(for: verify)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Label("연동 상태", systemImage: "link")
                            .font(.caption.weight(.semibold))

                        IntegrationSummaryBadge(
                            text: summaryText(for: verify),
                            color: summaryColor(for: verify)
                        )

                        Spacer(minLength: 8)

                        if !isExpanded {
                            IntegrationStatusCompactStrip(statuses: statuses)
                        }

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "연동 상태 접기" : "연동 상태 펼치기")

                Button {
                    Task { await model.run(.verify) }
                } label: {
                    Label("상태 검사", systemImage: "checkmark.seal")
                }
                .disabled(model.runningCommand != nil)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isExpanded {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(statuses) { status in
                        IntegrationStatusTile(status: status)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isExpanded ? 10 : 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func integrationStatuses(for verify: VerifyResult?) -> [IntegrationStatusSummary] {
        [
            IntegrationStatusSummary(
                title: "앱 권한",
                systemImage: "key",
                value: appPermissionValue,
                detail: appPermissionDetail,
                health: appPermissionHealth
            ),
            IntegrationStatusSummary(
                title: "메모",
                systemImage: "note.text",
                value: notesValue(for: verify),
                detail: notesDetail(for: verify),
                health: notesHealth(for: verify)
            ),
            IntegrationStatusSummary(
                title: "캘린더",
                systemImage: "calendar",
                value: calendarValue(for: verify),
                detail: calendarDetail(for: verify),
                health: calendarHealth(for: verify)
            ),
            IntegrationStatusSummary(
                title: "미리 알림",
                systemImage: "checklist",
                value: remindersValue(for: verify),
                detail: remindersDetail(for: verify),
                health: remindersHealth(for: verify)
            ),
        ]
    }

    private var appPermissionHealth: IntegrationHealth {
        if model.runningCommand == .doctor {
            return .running
        }
        if model.permissionProbeRows.isEmpty {
            return model.appDiagnostics.codeSigning.needsAttention ? .warning : .unknown
        }
        return model.permissionProbeRows.contains(where: \.isWarning) ? .warning : .ok
    }

    private var appPermissionValue: String {
        if model.permissionProbeRows.isEmpty {
            return model.appDiagnostics.codeSigning.needsAttention ? "권한 확인 필요" : "검사 전"
        }
        let warnings = model.permissionProbeRows.filter(\.isWarning).count
        return warnings == 0 ? "권한 OK" : "\(warnings)개 확인 필요"
    }

    private var appPermissionDetail: String {
        if let message = model.permissionStatusMessage, !message.isEmpty {
            return message
        }
        return model.appDiagnostics.codeSigning.statusTitle
    }

    private func summaryText(for verify: VerifyResult?) -> String {
        if model.runningCommand == .verify {
            return "검사 중"
        }
        guard let verify else {
            return "상태 검사 필요"
        }
        return verify.status.klmsLocalizedStatus
    }

    private func summaryColor(for verify: VerifyResult?) -> Color {
        if model.runningCommand == .verify {
            return .blue
        }
        guard let verify else {
            return .secondary
        }
        switch verify.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ok":
            return .green
        case "warn", "warning":
            return .orange
        case "fail", "failed", "error":
            return .red
        default:
            return .secondary
        }
    }

    private func notesHealth(for verify: VerifyResult?) -> IntegrationHealth {
        if model.runningCommand == .verify || model.runningCommand == .noticeSync || model.runningCommand == .fullSync {
            return .running
        }
        guard let verify else {
            return .unknown
        }
        if hasIssue(namedWithPrefix: "notice", in: verify.checks) {
            return .warning
        }
        guard let notices = verify.notices else {
            return .unknown
        }
        return notices.missingCount == 0 ? .ok : .warning
    }

    private func notesValue(for verify: VerifyResult?) -> String {
        guard let verify else {
            return "검사 전"
        }
        guard let notices = verify.notices else {
            return "요약 없음"
        }
        if notices.missingCount > 0 {
            return "\(notices.missingCount)개 누락"
        }
        return "\(notices.renderedCount)/\(notices.digestCount)개 반영"
    }

    private func notesDetail(for verify: VerifyResult?) -> String {
        guard let notices = verify?.notices else {
            return "상태 검사를 누르면 KLMS 공지와 확인한 공지 반영 상태를 확인합니다."
        }
        let candidates = "시험 후보 \(notices.examCandidateCount) · 과제 후보 \(notices.assignmentCandidateCount)"
        if notices.missingExamCandidateCount > 0 || notices.missingAssignmentCandidateCount > 0 {
            return "\(candidates) · 후보 누락 \(notices.missingExamCandidateCount + notices.missingAssignmentCandidateCount)"
        }
        return candidates
    }

    private func calendarHealth(for verify: VerifyResult?) -> IntegrationHealth {
        if model.runningCommand == .verify || model.runningCommand == .coreSync || model.runningCommand == .fullSync {
            return .running
        }
        guard let verify else {
            return .unknown
        }
        if hasIssue(namedWithPrefix: "calendar", in: verify.checks) {
            return .warning
        }
        guard let calendar = verify.calendar else {
            return .unknown
        }
        return calendar.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .ok : .warning
    }

    private func calendarValue(for verify: VerifyResult?) -> String {
        guard let calendar = verify?.calendar else {
            return "검사 전"
        }
        if !calendar.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "오류"
        }
        return "시험 \(calendar.examCount) · 헬프 \(calendar.helpdeskCount)"
    }

    private func calendarDetail(for verify: VerifyResult?) -> String {
        guard let calendar = verify?.calendar else {
            return "시험과 헬프데스크 일정이 캘린더와 맞는지 확인합니다."
        }
        if let totals = calendar.resultTotals {
            return "최근 반영 결과: 시험 \(totals.exam) · 헬프 \(totals.helpdesk)"
        }
        return "이전 캘린더 잔재: \(calendar.legacyAssignmentExists || calendar.legacyAlertExists ? "있음" : "없음")"
    }

    private func remindersHealth(for verify: VerifyResult?) -> IntegrationHealth {
        if model.runningCommand == .verify || model.runningCommand == .coreSync || model.runningCommand == .fullSync {
            return .running
        }
        guard let verify else {
            return .unknown
        }
        if hasIssue(namedWithPrefix: "reminders", in: verify.checks) {
            return .warning
        }
        guard let reminders = verify.reminders else {
            return .unknown
        }
        if !reminders.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .warning
        }
        return reminders.assignmentListExists ? .ok : .warning
    }

    private func remindersValue(for verify: VerifyResult?) -> String {
        guard let reminders = verify?.reminders else {
            return "검사 전"
        }
        if !reminders.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "오류"
        }
        return "과제 \(reminders.assignmentActiveCount)개"
    }

    private func remindersDetail(for verify: VerifyResult?) -> String {
        guard let reminders = verify?.reminders else {
            return "과제가 미리 알림 목록과 맞는지 확인합니다."
        }
        return "확인 필요 \(reminders.issueActiveCount) · 추가 알림 \(reminders.alertActiveCount) · 전체 \(reminders.totalActiveCount)"
    }

    private func hasIssue(namedWithPrefix prefix: String, in checks: [VerifyCheck]) -> Bool {
        checks.contains { check in
            check.name.hasPrefix(prefix)
                && ["fail", "failed", "error", "warn", "warning"].contains(
                    check.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
        }
    }
}

private enum IntegrationHealth {
    case ok
    case warning
    case unknown
    case running

    var label: String {
        switch self {
        case .ok:
            "정상"
        case .warning:
            "확인 필요"
        case .unknown:
            "미확인"
        case .running:
            "검사 중"
        }
    }

    var color: Color {
        switch self {
        case .ok:
            .green
        case .warning:
            .orange
        case .unknown:
            .secondary
        case .running:
            .blue
        }
    }
}

private struct IntegrationStatusSummary: Identifiable {
    var title: String
    var systemImage: String
    var value: String
    var detail: String
    var health: IntegrationHealth

    var id: String { title }
}

private struct IntegrationSummaryBadge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.10), in: Capsule())
    }
}

private struct IntegrationStatusCompactStrip: View {
    var statuses: [IntegrationStatusSummary]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(statuses) { status in
                Label(status.title, systemImage: status.systemImage)
                    .font(.caption2.weight(.semibold))
                    .labelStyle(.iconOnly)
                    .foregroundStyle(status.health.color)
                    .frame(width: 22, height: 22)
                    .background(status.health.color.opacity(0.10), in: Circle())
                    .help("\(status.title): \(status.value) · \(status.health.label)")
            }
        }
    }
}

private struct IntegrationStatusTile: View {
    var status: IntegrationStatusSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Label(status.title, systemImage: status.systemImage)
                    .font(.caption2.weight(.semibold))
                Spacer(minLength: 4)
                Text(status.health.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(status.health.color)
            }
            Text(status.value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(status.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .padding(8)
        .background(status.health.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(status.health.color.opacity(0.18), lineWidth: 1)
        }
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
    @Binding var expandedLogSummaryKind: LogSummaryKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AuthCodeBannerView(digits: model.currentAuthDigits, statusMessage: model.authStatusMessage)
            NextActionPanelView(
                model: model,
                selectedSection: $selectedSection,
                expandedLogSummaryKind: $expandedLogSummaryKind
            )
        }
    }
}

private enum LogSummaryKind: String {
    case run
    case remote
    case fileRequest
}

private struct LogSummaryPanelView: View {
    @ObservedObject var model: KLMSMacModel
    @Binding var expandedKind: LogSummaryKind?
    private static let terminalSummaryDisplayInterval: TimeInterval = 5 * 60

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("로그 요약", systemImage: "list.bullet.rectangle")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                if let updatedAt = latestUpdatedAtText {
                    Text(updatedAt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task {
                        await model.clearVisibleLogsAndServerRelayLogs()
                    }
                } label: {
                    Label("로그 지우기", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("화면의 실행 로그와 완료된 서버 요청, 파일 요청 기록을 지웁니다. 진행 중인 요청은 유지됩니다.")
                .disabled(model.runningCommand != nil)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 176), spacing: 8)], alignment: .leading, spacing: 8) {
                LogSummaryTile(
                    title: "실행",
                    value: runValue,
                    detail: runDetail,
                    systemImage: runSystemImage,
                    tint: runTint,
                    isExpanded: expandedKind == .run
                ) {
                    toggle(.run)
                }
                LogSummaryTile(
                    title: "원격 요청",
                    value: remoteValue,
                    detail: remoteDetail,
                    systemImage: remoteSystemImage,
                    tint: remoteTint,
                    isExpanded: expandedKind == .remote
                ) {
                    toggle(.remote)
                }
                LogSummaryTile(
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
                LogSummaryDetailView(kind: expandedKind, model: model)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text("요약 타일을 누르면 관련 로그와 요청 기록을 바로 펼칩니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var latestFileRequest: ServerRelayFileAccessRequest? {
        if let active = model.serverRelayRecentFileAccessRequests.first(where: { $0.status.isInFlight }) {
            return active
        }
        return model.serverRelayRecentFileAccessRequests.first {
            Date().timeIntervalSince($0.updatedAt) <= Self.terminalSummaryDisplayInterval
        }
    }

    private var currentRemoteCommand: RemoteRunCommand? {
        guard let command = model.lastRemoteCommand else {
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

    private var latestUpdatedAtText: String? {
        if let request = latestFileRequest {
            return request.updatedAt.formatted(date: .omitted, time: .shortened)
        }
        if let command = model.lastRemoteCommand {
            return command.updatedAt.formatted(date: .omitted, time: .shortened)
        }
        if let result = model.lastCommandResult {
            return result.startedAt.formatted(date: .omitted, time: .shortened)
        }
        return nil
    }

    private var runValue: String {
        if let command = model.runningCommand {
            return "\(command.displayName) 실행 중"
        }
        if let result = model.lastCommandResult {
            if result.wasCancelled {
                return "\(result.invocation.command.displayName) 중단됨"
            }
            return result.succeeded ? "\(result.invocation.command.displayName) 완료" : "\(result.invocation.command.displayName) 실패"
        }
        if let report = model.snapshot.syncReport {
            return "상태 \(report.status.klmsLocalizedStatus)"
        }
        return "실행 기록 없음"
    }

    private var runDetail: String {
        if model.runningCommand != nil {
            return model.currentPhaseText ?? model.liveProgressLine ?? "진행 상황을 확인 중입니다."
        }
        if let result = model.lastCommandResult {
            if result.wasCancelled {
                return "사용자가 실행을 중단했습니다."
            }
            return result.succeeded ? "종료 코드 \(result.exitCode)" : "마지막 오류는 진단 탭에서 확인하세요."
        }
        return "동기화를 실행하면 마지막 실행 요약이 여기에 표시됩니다."
    }

    private var runSystemImage: String {
        if model.runningCommand != nil {
            return "arrow.triangle.2.circlepath"
        }
        guard let result = model.lastCommandResult else {
            return "circle.dashed"
        }
        if result.wasCancelled {
            return "stop.circle"
        }
        return result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var runTint: Color {
        if model.runningCommand != nil {
            return .blue
        }
        guard let result = model.lastCommandResult else {
            return .secondary
        }
        if result.wasCancelled {
            return .secondary
        }
        return result.succeeded ? .green : .orange
    }

    private var remoteValue: String {
        if let command = currentRemoteCommand {
            return "\(command.kind.displayName) · \(command.displayStatus().displayName)"
        }
        if model.lastRemoteCommand != nil {
            return "현재 요청 없음"
        }
        return model.serverRelayEnabled ? "대기 중" : "꺼짐"
    }

    private var remoteDetail: String {
        if currentRemoteCommand != nil,
           let message = model.remoteProcessingStatusMessage?.nilIfBlank ?? model.serverRelayStatusMessage?.nilIfBlank {
            return message
        }
        if model.lastRemoteCommand != nil, currentRemoteCommand == nil {
            return "지난 완료/실패 기록은 원격 요청 타일을 펼쳐서 확인할 수 있습니다."
        }
        if let message = model.remoteProcessingStatusMessage?.nilIfBlank ?? model.serverRelayStatusMessage?.nilIfBlank {
            return message
        }
        return model.serverRelayEnabled ? "iPhone/Windows 요청을 기다리고 있습니다." : "설정에서 서버 릴레이를 켜면 원격 요청을 처리합니다."
    }

    private var remoteSystemImage: String {
        if currentRemoteCommand?.displayStatus() == .cancelled {
            return "stop.circle"
        }
        if currentRemoteCommand?.displayStatus().isInFlight == true {
            return "antenna.radiowaves.left.and.right"
        }
        return model.serverRelayEnabled ? "network" : "network.slash"
    }

    private var remoteTint: Color {
        if currentRemoteCommand?.displayStatus() == .cancelled {
            return .secondary
        }
        if currentRemoteCommand?.displayStatus() == .failed || currentRemoteCommand?.displayStatus() == .macUnavailable {
            return .orange
        }
        if currentRemoteCommand?.displayStatus().isInFlight == true {
            return .blue
        }
        return model.serverRelayEnabled ? .green : .secondary
    }

    private var fileRequestValue: String {
        guard let latestFileRequest else {
            return "요청 없음"
        }
        return latestFileRequest.status.displayName
    }

    private var fileRequestDetail: String {
        guard let latestFileRequest else {
            return model.serverRelayRecentFileAccessRequests.isEmpty
                ? "iPhone/Windows에서 파일 열기를 요청하면 진행 상태가 표시됩니다."
                : "지난 완료/실패 기록은 파일 요청 타일을 펼쳐서 확인할 수 있습니다."
        }
        let title = latestFileRequest.itemTitle.nilIfBlank ?? "파일"
        if let message = latestFileRequest.message.nilIfBlank {
            return "\(title) · \(message)"
        }
        return "\(title) · \(latestFileRequest.updatedAt.formatted(date: .omitted, time: .shortened))"
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
            return .blue
        case .completed:
            return .green
        case .failed, .macUnavailable:
            return .orange
        case nil:
            return .secondary
        }
    }

    private func toggle(_ kind: LogSummaryKind) {
        withAnimation(.easeInOut(duration: 0.16)) {
            expandedKind = expandedKind == kind ? nil : kind
        }
    }
}

private struct LogSummaryDetailView: View {
    var kind: LogSummaryKind
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch kind {
            case .run:
                runDetail
            case .remote:
                remoteDetail
            case .fileRequest:
                fileRequestDetail
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var runDetail: some View {
        let text = bounded(runLogText.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.isEmpty {
            Text("아직 표시할 실행 로그가 없습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Text(model.runningCommand == nil ? "마지막 실행 로그" : "실시간 로그")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(text.split(whereSeparator: \.isNewline).count)줄")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            LogTextBlock(text: text)
        }
    }

    private var remoteDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.remoteProcessingStatusMessage?.nilIfBlank ?? model.serverRelayStatusMessage?.nilIfBlank {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let command = model.lastRemoteCommand {
                RemoteCommandActivityRow(command: command)
            } else {
                Text("최근 원격 실행 요청이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var fileRequestDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("파일 요청 기록")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    Task {
                        await model.clearServerRelayLogs(scope: .fileAccess)
                    }
                } label: {
                    Label("지우기", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(
                    !model.serverRelayConfigured
                        || model.serverRelayRecentFileAccessRequests.isEmpty
                        || model.serverRelayRecentFileAccessRequests.contains { $0.status.isInFlight }
                )
            }
            if model.serverRelayRecentFileAccessRequests.isEmpty {
                Text("최근 파일 요청이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.serverRelayRecentFileAccessRequests.prefix(8)) { request in
                    FileAccessActivityRow(request: request)
                }
            }
        }
    }

    private var runLogText: String {
        if !model.liveCommandOutput.isEmpty {
            return model.liveCommandOutput.klmsDisplayText
        }
        guard let result = model.lastCommandResult else {
            return ""
        }
        return result.wasCancelled
            ? result.combinedOutput.klmsDisplayText.klmsRedactingAuthDigitsForDisplay
            : result.combinedOutput.klmsDisplayText
    }

    private func bounded(_ text: String) -> String {
        let maxCharacters = 60_000
        let prefix = "... 이전 로그 일부 생략됨 ...\n"
        guard text.count > maxCharacters else {
            return text
        }
        return prefix + String(text.suffix(maxCharacters - prefix.count))
    }
}

private struct LogSummaryTile: View {
    var title: String
    var value: String
    var detail: String
    var systemImage: String
    var tint: Color
    var isExpanded: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
            .padding(9)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isExpanded ? tint.opacity(0.42) : tint.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "관련 로그 접기" : "관련 로그 펼치기")
    }
}

private struct NextActionPanelView: View {
    @ObservedObject var model: KLMSMacModel
    @Binding var selectedSection: KLMSMacSection
    @Binding var expandedLogSummaryKind: LogSummaryKind?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

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
        if let command = model.runningCommand {
            return NextAction(
                kind: .showRunningLog,
                title: "\(command.displayName) 실행 중입니다",
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
        case .showRunningLog:
            expandedLogSummaryKind = .run
            selectedSection = .activityLogs
        case .openDiagnostics:
            selectedSection = .diagnostics
            openDiagnosticsWindow()
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
            openSettings()
        }
    }

    private func openDiagnosticsWindow() {
        openWindow(id: KLMSMacWindowID.diagnostics)
        NSApp.activate(ignoringOtherApps: true)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.35), lineWidth: 1)
                    }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("KLMS Sync")
                            .font(.headline.weight(.semibold))
                        Text(statusBadgeText)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .foregroundStyle(statusColor)
                            .background(statusColor.opacity(0.12), in: Capsule())
                    }
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let command = model.runningCommand {
                    VStack(alignment: .trailing, spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Button(role: .destructive) {
                            Task {
                                await model.cancelRunningCommand()
                            }
                        } label: {
                            Label(
                                model.isCancellingCommand ? "중단 중" : "중단",
                                systemImage: "stop.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.isCancellingCommand)
                        .help("\(command.displayName) 실행을 중단합니다.")
                        .accessibilityLabel("\(command.displayName) 중단")
                    }
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
                Label("실행 잠금: 프로세스 \(lock.pid) · 명령 \(lock.command) · \(lock.acquiredAt)", systemImage: "lock.fill")
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
        .padding(12)
        .background(Color.klmsMacHeroBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusColor.opacity(0.18), lineWidth: 1)
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

    private var statusBadgeText: String {
        if model.runningCommand != nil {
            return "실행 중"
        }
        if model.snapshot.needsAttention {
            return "주의"
        }
        if model.snapshot.syncReport != nil {
            return "준비됨"
        }
        return "설정 필요"
    }
}

private struct CommandOutputPanelView: View {
    @ObservedObject var model: KLMSMacModel
    @State private var showingFullOutput = false
    private static let maxRenderedOutputCharacters = 80_000
    private static let trimmedOutputPrefix = "... 이전 로그 일부 생략됨 ...\n"

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
                        Text("최근 원본 로그")
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var commandOutput: String {
        if !model.liveCommandOutput.isEmpty {
            return Self.boundedOutput(model.liveCommandOutput.klmsDisplayText)
        }
        guard let result = model.lastCommandResult else {
            return ""
        }
        let output = result.wasCancelled
            ? result.combinedOutput.klmsDisplayText.klmsRedactingAuthDigitsForDisplay
            : result.combinedOutput.klmsDisplayText
        return Self.boundedOutput(output)
    }

    private var commandStatusText: String {
        if let command = model.runningCommand {
            return "\(command.displayName) 실행 중"
        }
        if let result = model.lastCommandResult {
            if result.wasCancelled {
                return "\(result.invocation.command.displayName) · 중단됨"
            }
            return "\(result.invocation.command.displayName) · 종료 코드 \(result.exitCode)"
        }
        return "대기 중"
    }

    private var commandStatusColor: Color {
        if model.runningCommand != nil {
            return .blue
        }
        if let result = model.lastCommandResult {
            if result.wasCancelled {
                return .secondary
            }
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

    private static func boundedOutput(_ text: String) -> String {
        guard text.count > maxRenderedOutputCharacters else {
            return text
        }
        let suffixLength = max(0, maxRenderedOutputCharacters - trimmedOutputPrefix.count)
        return trimmedOutputPrefix + String(text.suffix(suffixLength))
    }
}

private struct DiagnosticToolsPanelView: View {
    @ObservedObject var model: KLMSMacModel
    @State private var isAdvancedExpanded = false
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 8)]
    private let dryRunCommands: [KLMSEngineCommand] = [.fullSync, .coreSync, .noticeSync, .filesSync]

    var body: some View {
        SectionBox(title: "점검 도구") {
            VStack(alignment: .leading, spacing: 12) {
                Text("동기화는 실행하지 않고 현재 상태를 확인하거나, 앱 대시보드에 필요한 보조 파일만 갱신합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    diagnosticButton(.verify)
                    diagnosticButton(.doctor)
                    diagnosticButton(.report)
                    diagnosticButton(.v2BuildState)
                }

                DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("실제 반영 없이 바뀔 항목 수만 계산합니다. 일반 동기화 화면에서는 숨겨 둔 고급 기능입니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            ForEach(dryRunCommands, id: \.self) { command in
                                dryRunButton(command)
                            }
                        }
                        dryRunReportSummary
                    }
                    .padding(.top, 6)
                } label: {
                    Label("고급 도구", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Label("iPhone 연결은 서버 릴레이로 처리합니다", systemImage: "iphone.and.arrow.forward")
                        .font(.caption.weight(.semibold))
                    if model.serverRelayEnabled {
                        Text(model.serverRelayStatusMessage ?? "서버 릴레이 대기 중")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("설정 > 서버에서 서버 URL과 Mac 전용 토큰을 입력한 뒤 릴레이를 켜 주세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quinary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func diagnosticButton(_ command: KLMSEngineCommand) -> some View {
        Button {
            Task {
                await model.run(command)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(command.displayName, systemImage: command.systemImage)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(command.shortDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .disabled(model.runningCommand != nil)
        .help(command.shortDescription)
        .accessibilityLabel(command.displayName)
        .accessibilityHint(command.shortDescription)
    }

    private func dryRunButton(_ command: KLMSEngineCommand) -> some View {
        Button {
            Task {
                await model.run(command, dryRun: true)
            }
        } label: {
            Label("\(command.displayName) 변경량 계산", systemImage: "magnifyingglass")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.runningCommand != nil || !command.supportsDryRun)
        .help("실제 반영 없이 변경 예정량만 계산합니다.")
        .accessibilityLabel("\(command.displayName) 변경량 계산")
        .accessibilityHint("실제 반영 없이 변경 예정량만 계산합니다.")
    }

    @ViewBuilder
    private var dryRunReportSummary: some View {
        if !model.snapshot.dryRunReports.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.snapshot.dryRunReports.keys).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { scope in
                    if let report = model.snapshot.dryRunReports[scope] {
                        Text("\(scope.displayName): 생성 \(report.wouldCreate) · 수정 \(report.wouldUpdate) · 삭제 \(report.wouldDelete) · 다운로드 \(report.wouldDownload) · 정리 예정 \(report.wouldPrune)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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
                    CommandStageDurationSummaryView(durations: KLMSStageDurationParser.parse(from: source.text))
                    LogTextBlock(text: source.text, detailed: true)
                } else {
                    Text("아직 표시할 실행 로그가 없습니다. 위의 권한/환경 진단이나 동기화 버튼을 실행하면 실시간 로그와 마지막 로그가 여기에 표시됩니다.")
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
            let rawOutput = result.wasCancelled
                ? result.combinedOutput.klmsDisplayText.klmsRedactingAuthDigitsForDisplay
                : result.combinedOutput
            let output = cleaned(rawOutput)
            if !output.isEmpty {
                return DiagnosticLogSource(
                    title: "\(result.invocation.command.displayName) 마지막 실행 로그",
                    detail: result.wasCancelled
                        ? "\(result.startedAt.formatted(date: .numeric, time: .standard)) 시작 · 사용자가 중단함"
                        : "\(result.startedAt.formatted(date: .numeric, time: .standard)) 시작 · 종료 코드 \(result.exitCode)",
                    systemImage: result.wasCancelled ? "stop.circle" : (result.succeeded ? "doc.text" : "exclamationmark.triangle"),
                    text: output,
                    isWarning: !result.succeeded && !result.wasCancelled
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

        let relayLog = cleaned(model.snapshot.relayLogTail)
        if !relayLog.isEmpty {
            return DiagnosticLogSource(
                title: "서버 릴레이 로그",
                detail: "runtime/logs/relay.stderr.log와 relay.stdout.log의 최근 항목입니다.",
                systemImage: "network",
                text: relayLog,
                isWarning: relayLog.localizedCaseInsensitiveContains("error")
                    || relayLog.localizedCaseInsensitiveContains("required")
                    || relayLog.localizedCaseInsensitiveContains("failed")
            )
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
            systemImage: record.wasCancelled ? "stop.circle" : (record.succeeded ? "doc.text" : "exclamationmark.triangle"),
            text: cleaned(record.outputTail),
            isWarning: record.needsAttention
        )
    }

    private func cleaned(_ text: String) -> String {
        Self.boundedLogText(text.klmsDisplayText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func boundedLogText(_ text: String) -> String {
        let maxCharacters = 80_000
        let prefix = "... 이전 로그 일부 생략됨 ...\n"
        guard text.count > maxCharacters else {
            return text
        }
        let suffixLength = max(0, maxCharacters - prefix.count)
        return prefix + String(text.suffix(suffixLength))
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
    var detailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ReadableLogHighlightsView(highlights: KLMSReadableLogParser.highlights(from: text), detailed: detailed)
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ReadableLogHighlightsView: View {
    var highlights: [KLMSLogHighlight]
    var detailed = false

    var body: some View {
        if !highlights.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("핵심 로그")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(highlights) { highlight in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: systemImage(for: highlight.level))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(tint(for: highlight.level))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(highlight.title)
                                    .font(.caption2.weight(.semibold))
                                Text(highlight.detail.klmsDisplayText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                if detailed {
                                    diagnosticDetailRows(for: highlight)
                                }
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(tint(for: highlight.level).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(tint(for: highlight.level).opacity(0.18), lineWidth: 1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func diagnosticDetailRows(for highlight: KLMSLogHighlight) -> some View {
        if !highlight.explanation.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Label("의미", systemImage: "questionmark.circle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(highlight.explanation.klmsDisplayText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 5)
        }
        if !highlight.nextAction.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Label("다음 확인", systemImage: "arrow.turn.down.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint(for: highlight.level))
                Text(highlight.nextAction.klmsDisplayText)
                    .font(.caption2)
                    .foregroundStyle(.primary.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 3)
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
            return .orange
        case "success":
            return .green
        case "summary":
            return .blue
        default:
            return .secondary
        }
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
            let counts = snapshot.visibleCounts
            let assignmentCandidateCount = state?.assignmentCandidates.count ?? 0
            let examCandidateCount = state?.examCandidates.count ?? 0
            let completedAssignmentCount = state?.completedAssignments.count ?? 0
            let localMissingFileCount = snapshot.verifyResult?.files?.missingFileCount ?? 0
            let prunedCount = report?.files.pruned ?? 0
            let hiddenCount = snapshot.hiddenSummary.total
            let primaryMetrics = [
                Metric("과제", counts.assignments + model.mailDashboardItems(kind: "assignment").count, detail: .assignments),
                Metric("시험", counts.exams + model.mailDashboardItems(kind: "exam").count, detail: .exams),
                Metric("공지", counts.notices + model.mailDashboardItems(kind: "notice").count, detail: .notices),
                Metric("파일", snapshot.courseFileManifest.count + model.mailDashboardItems(kind: "file").count, detail: .files),
                Metric("헬프데스크", counts.helpDesk, detail: .helpDesk),
            ].filter { $0.value > 0 }
            let attentionMetrics = [
                Metric("새 파일", counts.newFiles, detail: .newFiles),
                Metric("캘린더", (report?.calendar.created ?? 0) + (report?.calendar.updated ?? 0) + (report?.calendar.deleted ?? 0), detail: .calendar),
                Metric("격리", counts.quarantine, detail: .quarantine),
                Metric("과제 후보", assignmentCandidateCount, detail: .assignmentCandidates),
                Metric("시험 후보", examCandidateCount, detail: .examCandidates),
                Metric("누락 파일", localMissingFileCount, detail: .missingFiles),
                Metric("삭제된 파일", prunedCount, detail: .pruned),
            ].filter { $0.value > 0 }
            let archiveMetrics = [
                Metric("완료 기록", completedAssignmentCount, detail: .assignmentRecords),
                Metric("보관함", hiddenCount, detail: .hidden),
            ].filter { $0.value > 0 }
            let visibleMetrics = primaryMetrics + attentionMetrics + archiveMetrics
            let activeDetail = visibleMetrics.first { $0.detail == selectedDetail }?.detail
                ?? visibleMetrics.first?.detail
            IssueSummaryView(issues: snapshot.issues)
            if visibleMetrics.isEmpty {
                Text("표시할 대시보드 항목이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                MetricSectionGrid(
                    title: "주요 항목",
                    metrics: primaryMetrics,
                    selectedMetricID: activeDetail?.rawValue,
                    onSelect: selectMetric
                )
                MetricSectionGrid(
                    title: "확인 필요",
                    metrics: attentionMetrics,
                    selectedMetricID: activeDetail?.rawValue,
                    onSelect: selectMetric
                )
                MetricSectionGrid(
                    title: "기록과 보관",
                    metrics: archiveMetrics,
                    selectedMetricID: activeDetail?.rawValue,
                    onSelect: selectMetric
                )
            }
            if let activeDetail {
                DashboardDetailPanelView(kind: activeDetail, model: model)
            }

            NoticeMemoStatusView(model: model)
            SlowestWorkView(report: report)
        }
    }

    private func selectMetric(_ metric: Metric) {
        if let detail = metric.detail {
            selectedDetail = detail
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
                    Text("최근 공지 메모 작성: \(timing.status.klmsLocalizedStatus) · \(timing.elapsedSecondsText) · 체크리스트/문단 서식")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(timing.noticeRenderResultsForDisplay.prefix(3)) { result in
                        Text("\(result.displayTargetTitle): \(result.status.klmsLocalizedStatus)")
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

private struct RemoteActivityPanelView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        let fileRequests = model.serverRelayRecentFileAccessRequests
        let requestLog = model.serverRelayRecentRequestLog
        let sharedRunLogs = model.serverRelaySharedRunLogs
        if model.lastRemoteCommand != nil || !fileRequests.isEmpty || !requestLog.isEmpty || !sharedRunLogs.isEmpty || model.remoteProcessingStatusMessage?.nilIfBlank != nil {
            SectionBox(title: "원격/파일 요청 기록") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Spacer()
                        Button {
                            Task {
                                await model.clearServerRelaySharedRunLogs()
                            }
                        } label: {
                            Label("공유 실행 로그 지우기", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!model.serverRelayConfigured || sharedRunLogs.isEmpty)

                        Button {
                            Task {
                                await model.clearServerRelayLogs(scope: .requestLog)
                            }
                        } label: {
                            Label("서버 요청 지우기", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!model.serverRelayConfigured || requestLog.isEmpty)

                        Button {
                            Task {
                                await model.clearServerRelayLogs(scope: .fileAccess)
                            }
                        } label: {
                            Label("파일 요청 지우기", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(
                            !model.serverRelayConfigured
                                || fileRequests.isEmpty
                                || fileRequests.contains { $0.status.isInFlight }
                        )
                    }

                    if let message = model.remoteProcessingStatusMessage?.nilIfBlank ?? model.serverRelayStatusMessage?.nilIfBlank {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "network")
                                .foregroundStyle(.blue)
                                .frame(width: 18)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let command = model.lastRemoteCommand {
                        RemoteCommandActivityRow(command: command)
                    }

                    if !sharedRunLogs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("공유 실행 로그")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(sharedRunLogs.prefix(8)) { log in
                                SharedRunLogActivityRow(log: log)
                            }
                        }
                    }

                    if !requestLog.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("서버 요청")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(requestLog.prefix(10)) { entry in
                                ServerRequestLogActivityRow(entry: entry)
                            }
                        }
                    }

                    if !fileRequests.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("파일 요청")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(fileRequests.prefix(8)) { request in
                                FileAccessActivityRow(request: request)
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct SharedRunLogActivityRow: View {
    var log: ServerRelayRunLog
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(log.commandTitle.nilIfBlank ?? "동기화")
                        .font(.caption.weight(.semibold))
                    Text("\(log.status) · \(log.duration) · \(log.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if isExpanded {
                LogTextBlock(text: log.outputTail)
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.18), lineWidth: 1)
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
        return log.needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var tint: Color {
        if log.wasCancelled {
            return .secondary
        }
        return log.needsAttention ? .orange : .green
    }
}

private struct ServerRequestLogActivityRow: View {
    var entry: ServerRelayRequestLogEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: sourceIcon)
                    .foregroundStyle(statusColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.action.nilIfBlank ?? entry.path.nilIfBlank ?? "서버 요청")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(entry.sourceDisplayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if isExpanded {
                LogTextBlock(text: expandedLog)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.18)) {
                isExpanded.toggle()
            }
        }
    }

    private var detail: String {
        var parts = [entry.statusDisplayName]
        if let message = entry.message.nilIfBlank {
            parts.append(message)
        }
        let route = [entry.method.nilIfBlank, entry.path.nilIfBlank].compactMap { $0 }.joined(separator: " ")
        if !route.isEmpty {
            parts.append(route)
        }
        return parts.joined(separator: " · ")
    }

    private var expandedLog: String {
        var lines = [
            "요청: \(entry.action.nilIfBlank ?? "서버 요청")",
            "출처: \(entry.sourceDisplayName)",
            "상태: \(entry.statusDisplayName)",
            "시간: \(entry.createdAt.formatted(date: .abbreviated, time: .standard))",
        ]
        let route = [entry.method.nilIfBlank, entry.path.nilIfBlank].compactMap { $0 }.joined(separator: " ")
        if !route.isEmpty {
            lines.append("경로: \(route)")
        }
        if let message = entry.message.nilIfBlank {
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

    private var statusColor: Color {
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

private struct RemoteCommandActivityRow: View {
    var command: RemoteRunCommand
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(statusColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(command.kind.displayName)
                            .font(.caption.weight(.semibold))
                        Text(command.status.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(statusColor)
                        Spacer(minLength: 8)
                        Text(command.updatedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(remoteCommandDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if isExpanded {
                LogTextBlock(text: expandedLog)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.18)) {
                isExpanded.toggle()
            }
        }
    }

    private var remoteCommandDetail: String {
        var parts: [String] = []
        if command.loginRequired {
            parts.append("로그인 필요")
        }
        if let lastExitCode = command.lastExitCode {
            parts.append("종료 코드 \(lastExitCode)")
        }
        if !command.summary.phase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("단계 \(command.summary.phase)")
        }
        return parts.isEmpty ? "원격에서 요청한 실행 상태입니다." : parts.joined(separator: " · ")
    }

    private var expandedLog: String {
        var lines = [
            "요청: \(command.kind.displayName)",
            "상태: \(command.status.displayName)",
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
        if let authMessage = command.summary.authStatusMessage?.nilIfBlank {
            lines.append("인증 상태: \(authMessage)")
        }
        if let phaseDetail = command.summary.phaseDetail?.nilIfBlank {
            lines.append("단계 상세: \(phaseDetail)")
        } else if !command.summary.phase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("단계: \(command.summary.phase.klmsRemotePhaseName)")
        }
        lines.append("요약: \(remoteCommandSummaryText)")
        return lines.joined(separator: "\n")
    }

    private var remoteCommandSummaryText: String {
        var parts = [
            "과제 \(command.summary.assignments)",
            "시험 \(command.summary.exams)",
            "공지 \(command.summary.notices)",
            "파일 \(command.summary.fileTotal)",
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

    private var systemImage: String {
        switch command.status {
        case .pending:
            "clock"
        case .running:
            "dot.radiowaves.left.and.right"
        case .completed:
            "checkmark.circle.fill"
        case .cancelled:
            "stop.circle"
        case .failed, .macUnavailable:
            "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch command.status {
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
}

private struct FileAccessActivityRow: View {
    var request: ServerRelayFileAccessRequest
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(statusColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(request.itemTitle.nilIfBlank ?? "파일")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(request.status.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(statusColor)
                        Spacer(minLength: 8)
                        Text(request.updatedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if isExpanded {
                LogTextBlock(text: expandedLog)
            }
        }
        .padding(8)
        .background(statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusColor.opacity(0.16), lineWidth: 1)
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
        if let message = request.message.nilIfBlank {
            parts.append(message)
        }
        if let sizeBytes = request.sizeBytes, sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))
        }
        if let expiresAt = request.expiresAt, request.isDownloadAvailable {
            parts.append("만료 \(expiresAt.formatted(date: .omitted, time: .shortened))")
        }
        return parts.isEmpty ? "Mac이 파일 링크 요청을 처리한 기록입니다." : parts.joined(separator: " · ")
    }

    private var expandedLog: String {
        var lines = [
            "파일: \(request.itemTitle.nilIfBlank ?? "파일")",
            "상태: \(request.status.displayName)",
            "생성: \(request.createdAt.formatted(date: .abbreviated, time: .standard))",
            "갱신: \(request.updatedAt.formatted(date: .abbreviated, time: .standard))",
        ]
        if let message = request.message.nilIfBlank {
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
            "clock"
        case .running:
            "arrow.up.doc"
        case .completed:
            "link.circle.fill"
        case .failed, .macUnavailable:
            "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch request.status {
        case .pending, .running:
            .blue
        case .completed:
            .green
        case .failed, .macUnavailable:
            .orange
        }
    }
}

private struct CommandPanelView: View {
    @ObservedObject var model: KLMSMacModel
    private let commands: [KLMSEngineCommand] = [.fullSync, .coreSync, .noticeSync, .filesSync]
    private let secondaryCommandColumns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 3)

    private var primaryCommand: KLMSEngineCommand {
        .fullSync
    }

    private var secondaryCommands: [KLMSEngineCommand] {
        commands.filter { $0 != primaryCommand }
    }

    var body: some View {
        SectionBox(
            title: "동기화"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                MacMailPasteAnalyzerPanel(model: model, snapshot: model.snapshot)
                primaryCommandActionCard(primaryCommand)

                LazyVGrid(columns: secondaryCommandColumns, spacing: 8) {
                    ForEach(secondaryCommands, id: \.self) { command in
                        commandActionCard(command)
                    }
                }

                CommandStageDurationSummaryView(durations: stageDurations)
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

    private func primaryCommandActionCard(_ command: KLMSEngineCommand) -> some View {
        Button {
            Task {
                await model.run(command)
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: command.systemImage)
                    .font(.title3.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.18), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(command.displayName)
                        .font(.headline.weight(.semibold))
                    Text(command.shortDescription)
                        .font(.caption)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.white.opacity(0.84))
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .tint(.klmsMacCommandAccent)
        .help(command.shortDescription)
        .accessibilityLabel("\(command.displayName) 실행")
        .accessibilityHint(command.shortDescription)
        .disabled(model.runningCommand != nil)
    }

    private func commandActionCard(_ command: KLMSEngineCommand) -> some View {
        Button {
            Task {
                await model.run(command)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(command.displayName, systemImage: command.systemImage)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
                Text("실행")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .padding(9)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.klmsMacCommandAccent)
        .help(command.shortDescription)
        .accessibilityLabel("\(command.displayName) 실행")
        .accessibilityHint(command.shortDescription)
        .disabled(model.runningCommand != nil)
    }

    private var stageDurations: [KLMSStageDuration] {
        let output = model.liveCommandOutput.isEmpty
            ? (model.lastCommandResult?.combinedOutput ?? "")
            : model.liveCommandOutput
        return KLMSStageDurationParser.parse(from: output)
    }
}

private struct CommandStageDurationSummaryView: View {
    var durations: [KLMSStageDuration]

    var body: some View {
        if !durations.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("단계별 소요 시간")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func tint(for stage: String) -> Color {
        switch stage {
        case "core":
            return .orange
        case "notice":
            return .brown
        case "files":
            return .blue
        default:
            return .secondary
        }
    }
}

private struct MetricSectionGrid: View {
    var title: String
    var metrics: [Metric]
    var selectedMetricID: String?
    var onSelect: (Metric) -> Void

    var body: some View {
        if !metrics.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontWeight(.semibold)
                MetricGrid(metrics: metrics, selectedMetricID: selectedMetricID, onSelect: onSelect)
            }
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

private struct VerifyPanelView: View {
    var snapshot: EngineSnapshot

    var body: some View {
        if let verify = snapshot.verifyResult {
            SectionBox(title: "상태 검사 해설") {
                let issueChecks = verify.checks.filter { isIssueStatus($0.status) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(summaryText(for: verify, issueCount: issueChecks.count))
                        .font(.caption)
                        .foregroundStyle(issueChecks.isEmpty && verify.status.lowercased() == "ok" ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    if issueChecks.isEmpty {
                        Text("메모, 파일, 캘린더, 미리 알림 검사에서 설명이 필요한 실패 항목이 없습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(issueChecks) { check in
                            VerifyCheckExplanationRowView(check: check)
                        }
                    }

                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(verify.checks) { check in
                                VerifyCheckExplanationRowView(check: check, compact: true)
                            }
                        }
                    } label: {
                        Text("전체 상태 검사 항목 \(verify.checks.count)개")
                            .font(.caption)
                    }
                }
            }
        }
    }

    private func summaryText(for verify: VerifyResult, issueCount: Int) -> String {
        let okCount = verify.checks.filter { $0.status.lowercased() == "ok" }.count
        if issueCount == 0 {
            return "상태: \(verify.status.klmsLocalizedStatus) · 정상 \(okCount)개"
        }
        return "상태: \(verify.status.klmsLocalizedStatus) · 확인 필요 \(issueCount)개 · 정상 \(okCount)개"
    }

    private func isIssueStatus(_ status: String) -> Bool {
        ["fail", "failed", "error", "warn", "warning"].contains(status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

private struct VerifyCheckExplanationRowView: View {
    var check: VerifyCheck
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Text("\(check.diagnosticTitle) · \(check.status.klmsLocalizedStatus)")
                    .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                if compact {
                    Text(rawDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(check.diagnosticExplanation)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(check.diagnosticNextAction)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !rawDetail.isEmpty {
                        Text("원본: \(rawDetail)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(compact ? 6 : 9)
        .background(compact ? Color(nsColor: .controlBackgroundColor) : rowBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(compact ? 0.10 : 0.22), lineWidth: 1)
        }
    }

    private var rawDetail: String {
        check.detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var rowBackground: Color {
        if ["fail", "failed", "error"].contains(check.status.lowercased()) {
            return Color.red.opacity(0.08)
        }
        if ["warn", "warning"].contains(check.status.lowercased()) {
            return Color.orange.opacity(0.10)
        }
        return Color.secondary.opacity(0.10)
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
                    detail: "앱은 대시보드 상태를 기준으로 Notes 메모를 다시 작성합니다. 체크리스트와 문단 서식을 적용하려면 자동화 권한과 손쉬운 사용 권한이 필요합니다.",
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
                        PermissionScopeText("손쉬운 사용: 시스템 설정에서 KLMS Sync를 켜야 합니다. KLMS 공지 메모 렌더러가 따로 보이면 그것도 켜 주세요.")
                        PermissionScopeText("손쉬운 사용 사용처: Notes 편집 영역 포커스 확인, 체크리스트와 문단 서식 적용")
                        PermissionScopeText("자동화 · Safari: KLMS 로그인 확인, 페이지 수집, 파일 다운로드")
                        PermissionScopeText("자동화 · Notes: 공지 메모 열기, 선택, 본문 갱신")
                        PermissionScopeText("자동화 · System Events: Notes 메뉴 조작과 포커스 확인")
                        PermissionScopeText("자동화 · Calendar/Reminders: 기존 스크립트와 상태 확인 경로")
                        PermissionScopeText("캘린더/미리 알림 전체 접근: 일정과 미리 알림 동기화")
                        PermissionScopeText("알림: KAIST 인증번호와 실패 상태를 앱에서 바로 표시")
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

private enum RunLogArchiveFilter: String, CaseIterable, Identifiable {
    case all
    case sync
    case diagnostic
    case failed
    case cancelled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "전체"
        case .sync:
            "동기화"
        case .diagnostic:
            "진단"
        case .failed:
            "실패"
        case .cancelled:
            "중단"
        }
    }

    func includes(_ record: CommandRunRecord) -> Bool {
        switch self {
        case .all:
            true
        case .sync:
            !record.command.isDiagnostic
        case .diagnostic:
            record.command.isDiagnostic
        case .failed:
            record.needsAttention
        case .cancelled:
            record.wasCancelled
        }
    }
}

private struct RunLogArchivePanelView: View {
    @ObservedObject var model: KLMSMacModel
    @State private var filter = RunLogArchiveFilter.all
    @State private var showingSystemLogs = false

    private var records: [CommandRunRecord] {
        model.commandHistory.records
    }

    private var filteredRecords: [CommandRunRecord] {
        records.filter { filter.includes($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionBox(title: "실행 로그") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("앱에서 실행한 동기화, 변경량 계산, 진단 명령의 누적 기록입니다. 각 항목을 펼치면 해당 실행의 마지막 로그를 확인할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                        RunLogStatChip(title: "전체", value: "\(records.count)", systemImage: "tray.full", tint: .accentColor)
                        RunLogStatChip(title: "성공", value: "\(records.filter(\.succeeded).count)", systemImage: "checkmark.circle", tint: .green)
                        RunLogStatChip(title: "실패", value: "\(records.filter(\.needsAttention).count)", systemImage: "exclamationmark.triangle", tint: .orange)
                        RunLogStatChip(title: "중단", value: "\(records.filter(\.wasCancelled).count)", systemImage: "stop.circle", tint: .secondary)
                    }

                    if let latest = records.first {
                        Text("최근 실행: \(latest.command.displayName) · \(latest.startedAt.formatted(date: .numeric, time: .shortened)) · \(latest.statusText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Picker("보기", selection: $filter) {
                        ForEach(RunLogArchiveFilter.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                }
            }

            CurrentRunLogCardView(model: model)

            SectionBox(title: "\(filter.title) 기록") {
                if filteredRecords.isEmpty {
                    Text(emptyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredRecords) { record in
                            RunLogArchiveRowView(record: record)
                        }
                    }
                }
            }

            SectionBox(title: "자동실행/서버 로그") {
                DisclosureGroup(isExpanded: $showingSystemLogs) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !model.snapshot.launchAgentLogTail.isEmpty {
                            Text("자동실행 로그")
                                .font(.caption.weight(.semibold))
                            LogTextBlock(text: model.snapshot.launchAgentLogTail.klmsDisplayText)
                        }
                        if !model.snapshot.relayLogTail.isEmpty {
                            Text("서버 릴레이 로그")
                                .font(.caption.weight(.semibold))
                            LogTextBlock(text: model.snapshot.relayLogTail.klmsDisplayText)
                        }
                        if model.snapshot.launchAgentLogTail.isEmpty && model.snapshot.relayLogTail.isEmpty {
                            Text("저장된 자동실행/서버 로그가 아직 없습니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 8) {
                        Label("백그라운드 로그 보기", systemImage: "clock.arrow.circlepath")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(systemLogSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var emptyText: String {
        if records.isEmpty {
            return "아직 저장된 실행 기록이 없습니다. 동기화나 진단을 실행하면 여기에 기록됩니다."
        }
        return "\(filter.title) 조건에 맞는 실행 기록이 없습니다."
    }

    private var systemLogSummary: String {
        let launchHasLog = !model.snapshot.launchAgentLogTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let relayHasLog = !model.snapshot.relayLogTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch (launchHasLog, relayHasLog) {
        case (true, true):
            return "자동실행, 서버"
        case (true, false):
            return "자동실행"
        case (false, true):
            return "서버"
        case (false, false):
            return "없음"
        }
    }
}

private struct RunLogStatChip: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct CurrentRunLogCardView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        let output = currentOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            SectionBox(title: model.runningCommand == nil ? "마지막 실행 로그" : "현재 실행 로그") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label(statusText, systemImage: statusImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusColor)
                        Spacer()
                        if let phase = model.currentPhaseText, model.runningCommand != nil {
                            Text(phase)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LogTextBlock(text: output)
                }
            }
        }
    }

    private var currentOutput: String {
        if !model.liveCommandOutput.isEmpty {
            return Self.boundedOutput(model.liveCommandOutput.klmsDisplayText)
        }
        guard let result = model.lastCommandResult else {
            return ""
        }
        let output = result.wasCancelled
            ? result.combinedOutput.klmsDisplayText.klmsRedactingAuthDigitsForDisplay
            : result.combinedOutput.klmsDisplayText
        return Self.boundedOutput(output)
    }

    private var statusText: String {
        if let command = model.runningCommand {
            return "\(command.displayName) 실행 중"
        }
        if let result = model.lastCommandResult {
            if result.wasCancelled {
                return "\(result.invocation.command.displayName) 중단됨"
            }
            return result.succeeded ? "\(result.invocation.command.displayName) 완료" : "\(result.invocation.command.displayName) 실패"
        }
        return "대기 중"
    }

    private var statusImage: String {
        if model.runningCommand != nil {
            return "dot.radiowaves.left.and.right"
        }
        if let result = model.lastCommandResult {
            if result.wasCancelled {
                return "stop.circle"
            }
            return result.succeeded ? "checkmark.circle" : "exclamationmark.triangle"
        }
        return "clock"
    }

    private var statusColor: Color {
        if model.runningCommand != nil {
            return .accentColor
        }
        if let result = model.lastCommandResult {
            if result.wasCancelled {
                return .secondary
            }
            return result.succeeded ? .green : .orange
        }
        return .secondary
    }

    private static func boundedOutput(_ text: String) -> String {
        let maxCharacters = 80_000
        let prefix = "... 이전 로그 일부 생략됨 ...\n"
        guard text.count > maxCharacters else {
            return text
        }
        let suffixLength = max(0, maxCharacters - prefix.count)
        return prefix + String(text.suffix(suffixLength))
    }
}

private struct RunLogArchiveRowView: View {
    var record: CommandRunRecord
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label(record.command.isDiagnostic ? "진단 명령" : "동기화 명령", systemImage: record.command.isDiagnostic ? "wrench.and.screwdriver" : "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if record.dryRun {
                        Text("변경량 계산")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                    Text("종료 코드 \(record.exitCode)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if record.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("이 실행에는 저장된 로그가 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    CommandStageDurationSummaryView(durations: record.visibleStageDurations)
                    LogTextBlock(text: record.outputTail)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusImage)
                    .foregroundStyle(statusColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(record.command.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if record.dryRun {
                            Text("변경량 계산")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                                .lineLimit(1)
                        }
                    }
                    Text("\(record.startedAt.formatted(date: .numeric, time: .shortened)) · \(record.elapsedSecondsText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    CompactStageDurationRowsView(durations: record.visibleStageDurations)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Text(record.statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusColor.opacity(record.needsAttention ? 0.35 : 0.12), lineWidth: 1)
        }
    }

    private var statusImage: String {
        if record.wasCancelled {
            return "stop.circle"
        }
        return record.succeeded ? "checkmark.circle" : "exclamationmark.triangle"
    }

    private var statusColor: Color {
        if record.wasCancelled {
            return .secondary
        }
        return record.succeeded ? .green : .orange
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
        }

        if !snapshot.relayLogTail.isEmpty {
            SectionBox(title: "서버 릴레이 로그") {
                LogTextBlock(text: snapshot.relayLogTail.klmsDisplayText)
            }
        } else if history.records.isEmpty && snapshot.launchAgentLogTail.isEmpty {
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
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if record.dryRun {
                    Text("변경량 계산")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(record.statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            Text("\(record.startedAt.formatted(date: .numeric, time: .standard)) · \(record.elapsedSecondsText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            CompactStageDurationRowsView(durations: record.visibleStageDurations)
            if !record.outputTail.isEmpty {
                DisclosureGroup {
                    CommandStageDurationSummaryView(durations: record.visibleStageDurations)
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

    private var statusColor: Color {
        if record.wasCancelled {
            return .secondary
        }
        return record.succeeded ? .green : .orange
    }
}

private struct CompactStageDurationRowsView: View {
    var durations: [KLMSStageDuration]

    var body: some View {
        if !durations.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(durations) { duration in
                    HStack(spacing: 4) {
                        Text(duration.displayName)
                            .font(.caption2.weight(.semibold))
                        Text(duration.secondsText)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }
}

private extension CommandRunRecord {
    var visibleStageDurations: [KLMSStageDuration] {
        if !stageDurations.isEmpty {
            return stageDurations
        }
        return KLMSStageDurationParser.parse(from: outputTail)
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
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await model.refresh(clearDisplayLogs: false, showConfirmation: true)
                }
            } label: {
                Label("새로 고침", systemImage: "arrow.clockwise")
            }
            .help("저장된 동기화 상태와 설정을 다시 읽습니다. 현재 화면 로그와 마지막 실행 결과는 지우지 않습니다.")
            .disabled(model.runningCommand != nil)
            Button {
                model.clearDisplayState(resetSnapshot: false, showConfirmation: true)
            } label: {
                Label("화면 정리", systemImage: "eraser")
            }
            .help("실시간 로그, 인증번호 표시, 마지막 오류처럼 화면에 남은 임시 표시만 정리합니다. 동기화 데이터와 설정은 유지됩니다.")
            .disabled(model.runningCommand != nil)
            Button {
                openSettings()
            } label: {
                Label("설정", systemImage: "gearshape")
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], spacing: 8) {
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
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text("\(metric.value)")
                    .font(.headline.monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(8)
        .background(isSelected ? tint.opacity(0.14) : Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? tint.opacity(0.55) : Color.black.opacity(0.04), lineWidth: 1)
        }
    }

    private var icon: String {
        switch metric.detail {
        case .assignments, .assignmentRecords, .assignmentCandidates:
            return "checklist"
        case .exams, .examCandidates:
            return "calendar"
        case .helpDesk:
            return "person.2"
        case .notices:
            return "note.text"
        case .files, .missingFiles, .newFiles:
            return "folder"
        case .quarantine:
            return "exclamationmark.shield"
        case .pruned:
            return "trash"
        case .calendar:
            return "calendar.badge.clock"
        case .hidden:
            return "archivebox"
        case nil:
            return "circle.grid.2x2"
        }
    }

    private var tint: Color {
        switch metric.detail {
        case .assignments, .assignmentRecords, .assignmentCandidates:
            return .orange
        case .exams, .examCandidates, .calendar:
            return .green
        case .notices:
            return .brown
        case .files, .missingFiles, .newFiles:
            return .blue
        case .quarantine, .pruned:
            return .red
        case .helpDesk:
            return .teal
        case .hidden:
            return .secondary
        case nil:
            return .accentColor
        }
    }
}

struct SectionBox<Content: View>: View {
    var title: String
    var backgroundColor: Color = .klmsMacCardBackground
    var borderColor: Color = Color.black.opacity(0.05)
    var titleColor: Color = .primary
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(titleColor)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 1)
        }
    }
}

struct CollapsibleSectionBox<Content: View>: View {
    var title: String
    var systemImage: String? = nil
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())

            if isExpanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension Color {
    static var klmsMacScreenBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var klmsMacCardBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var klmsMacSubtleCardBackground: Color {
        Color(nsColor: .quaternaryLabelColor).opacity(0.14)
    }

    static var klmsMacHeroBackground: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.92)
    }

    static var klmsMacCommandAccent: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(calibratedRed: 0.42, green: 0.62, blue: 0.55, alpha: 1.0)
                : NSColor(calibratedRed: 0.15, green: 0.36, blue: 0.31, alpha: 1.0)
        })
    }

    static var klmsMacCommandBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.09, alpha: 1.0)
                : NSColor(calibratedRed: 0.94, green: 0.97, blue: 0.96, alpha: 1.0)
        })
    }

    static var klmsMacCommandBorder: Color {
        Color.klmsMacCommandAccent.opacity(0.28)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
