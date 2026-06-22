import KLMSShared
import AppKit
import SwiftUI

struct MenuBarRootView: View {
    @ObservedObject var model: KLMSMacModel
    @State private var selectedSection = KLMSMacSection.dashboard
    @State private var scrollResetNonce = 0
    @State private var expandedLogSummaryKind: LogSummaryKind?

    var body: some View {
        ZStack(alignment: .topLeading) {
            MacWorkspaceSelectionAccessibilityMarker(section: selectedSection)
            MacWorkspaceRenderedAccessibilityMarker(section: selectedSection)
            MacWorkspacePanelAccessibilityMarker(section: selectedSection)
            MacWorkspaceContainerAccessibilityMarker(section: selectedSection)

            HStack(alignment: .top, spacing: 0) {
                MacWorkspaceSidebarView(
                    model: model,
                    selectedSection: $selectedSection,
                    resetCurrentSectionScroll: resetCurrentSectionScroll
                )
                    .frame(width: 264, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                Rectangle()
                    .fill(Color.klmsMacBorder.opacity(0.76))
                    .frame(width: 1)
                VStack(spacing: 0) {
                    MacAlertBannerView(
                        model: model,
                        selectedSection: $selectedSection,
                        expandedLogSummaryKind: $expandedLogSummaryKind
                    )

                    WholeScreenVerticalScrollView(resetID: MacWorkspaceScrollResetKey(section: selectedSection, nonce: scrollResetNonce)) {
                        VStack(alignment: .leading, spacing: 14) {
                            DashboardTopBarView(model: model, selectedSection: $selectedSection)
                            MacWorkstationLayoutView(
                                model: model,
                                selectedSection: selectedSection,
                                expandedLogSummaryKind: $expandedLogSummaryKind
                            )
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 16)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("workspace-scroll-\(selectedSection.rawValue)")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(.klmsMacCommandAccent)
        .background(Color.klmsMacScreenBackground)
    }

    private func resetCurrentSectionScroll() {
        scrollResetNonce &+= 1
    }
}

private struct MacWorkspaceSelectionAccessibilityMarker: View {
    var section: KLMSMacSection

    var body: some View {
        Text("\(section.title) 선택됨")
            .font(.system(size: 1))
            .foregroundStyle(Color.klmsMacPrimaryText.opacity(0.01))
            .lineLimit(1)
            .frame(width: 1, height: 1)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(section.accessibilitySummary)
            .accessibilityIdentifier("workspace-content-\(section.rawValue)")
    }
}

private struct MacWorkspaceRenderedAccessibilityMarker: View {
    var section: KLMSMacSection

    var body: some View {
        Text("\(section.title) 렌더링됨")
            .font(.system(size: 1))
            .foregroundStyle(Color.klmsMacPrimaryText.opacity(0.01))
            .lineLimit(1)
            .frame(width: 1, height: 1)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(section.title) 렌더링됨")
            .accessibilityIdentifier("workspace-rendered-section-\(section.rawValue)")
    }
}

private struct MacWorkspacePanelAccessibilityMarker: View {
    var section: KLMSMacSection

    var body: some View {
        Text("\(section.title) 패널")
            .font(.system(size: 1))
            .foregroundStyle(Color.klmsMacPrimaryText.opacity(0.01))
            .lineLimit(1)
            .frame(width: 1, height: 1)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(section.title) 패널")
            .accessibilityIdentifier("workspace-panel-workspace-\(section.rawValue)")
    }
}

private struct MacWorkspaceContainerAccessibilityMarker: View {
    var section: KLMSMacSection

    var body: some View {
        Text("\(section.title) 화면")
            .font(.system(size: 1))
            .foregroundStyle(Color.klmsMacPrimaryText.opacity(0.01))
            .lineLimit(1)
            .frame(width: 1, height: 1)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(section.accessibilitySummary)
            .accessibilityIdentifier("workspace-container-\(section.rawValue)")
    }
}

private struct MacPressFeedbackButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10
    var disabledOpacity: Double = 0.48
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.klmsMacCommandButtonPressedOverlay.opacity(configuration.isPressed ? 1.0 : 0.0))
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1.0 : disabledOpacity)
    }
}

private struct DeferredMacInteractionExpansion<Content: View>: View {
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

private enum MacWorkspacePanelTiming {
    static let deferredContentDelayNanoseconds: UInt64 = 90_000_000
}

private struct DeferredMacWorkspacePanel<Content: View>: View {
    var id: String
    var contentIdentifier: String?
    var deferContent: Bool
    private let content: () -> Content
    @State private var isContentReady = false
    @State private var contentTask: Task<Void, Never>?

    init(
        id: String,
        contentIdentifier: String? = nil,
        deferContent: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.id = id
        self.contentIdentifier = contentIdentifier
        self.deferContent = deferContent
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            workspaceContentAccessibilityMarker
            if deferContent, !isContentReady {
                MacWorkspacePanelPreparingView()
            } else {
                content()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-panel-\(id)")
        .onAppear {
            prepareContentIfNeeded()
        }
        .onDisappear {
            contentTask?.cancel()
            if deferContent {
                isContentReady = false
            }
        }
    }

    private var workspaceContentAccessibilityMarker: some View {
        Text("작업공간 내용")
            .font(.system(size: 1))
            .foregroundStyle(Color.klmsMacPrimaryText.opacity(0.01))
            .lineLimit(1)
            .frame(width: 1, height: 1)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("작업공간 내용")
            .accessibilityIdentifier("workspace-panel-\(id)")
    }

    private func prepareContentIfNeeded() {
        guard deferContent else {
            isContentReady = true
            return
        }
        guard !isContentReady else { return }
        contentTask?.cancel()
        contentTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: MacWorkspacePanelTiming.deferredContentDelayNanoseconds)
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                isContentReady = true
            }
        }
    }
}

private struct MacWorkspacePanelPreparingView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("화면을 준비하는 중입니다.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.klmsMacSecondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
        .accessibilityLabel("화면을 준비하는 중입니다.")
    }
}

private struct MacWorkstationLayoutView: View {
    let model: KLMSMacModel
    let selectedSection: KLMSMacSection
    @Binding var expandedLogSummaryKind: LogSummaryKind?

    var body: some View {
        workspace
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .layoutPriority(1)
    }

    @ViewBuilder
    private var workspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            workspaceContentMarker
            switch selectedSection {
            case .dashboard:
                DeferredMacWorkspacePanel(id: "workspace-dashboard", contentIdentifier: "workspace-content-dashboard", deferContent: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        CommandPanelView(model: model)
                        DashboardSummaryView(model: model)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            case .files:
                DeferredMacWorkspacePanel(id: "workspace-files", contentIdentifier: "workspace-content-files") {
                    cachedDashboardDetailPanel(kind: .files)
                        .equatable()
                }
            case .tasks:
                DeferredMacWorkspacePanel(id: "workspace-tasks", contentIdentifier: "workspace-content-tasks") {
                    TaskAndExamWorkspaceView(model: model)
                }
            case .notices:
                DeferredMacWorkspacePanel(id: "workspace-notices", contentIdentifier: "workspace-content-notices") {
                    cachedDashboardDetailPanel(kind: .notices)
                        .equatable()
                }
            case .calendar:
                DeferredMacWorkspacePanel(id: "workspace-calendar", contentIdentifier: "workspace-content-calendar") {
                    cachedDashboardDetailPanel(kind: .calendar)
                        .equatable()
                }
            case .activityLogs:
                DeferredMacWorkspacePanel(id: "workspace-activityLogs", contentIdentifier: "workspace-content-activityLogs") {
                    VStack(alignment: .leading, spacing: 16) {
                        LogSummaryPanelView(model: model, expandedKind: $expandedLogSummaryKind)
                        DiagnosticStageDurationPanelView(model: model)
                        RemoteActivityPanelView(model: model)
                        RunLogArchivePanelView(model: model)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            case .diagnostics:
                DeferredMacWorkspacePanel(id: "workspace-diagnostics", contentIdentifier: "workspace-content-diagnostics") {
                    VStack(alignment: .leading, spacing: 16) {
                        VerifyPanelView(snapshot: model.snapshot)
                        DiagnosticToolsPanelView(model: model)
                        DoctorPanelView(snapshot: model.snapshot)
                        AppDiagnosticsPanelView(model: model)
                        LoginPanelView(model: model)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            case .settings:
                DeferredMacWorkspacePanel(id: "workspace-settings", contentIdentifier: "workspace-content-settings") {
                    SettingsView(model: model)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("workspace-container-\(selectedSection.rawValue)")
    }

    private var workspaceContentMarker: some View {
        Text(selectedSection.title)
            .font(.system(size: 1))
            .foregroundStyle(Color.klmsMacPrimaryText.opacity(0.01))
            .lineLimit(1)
            .frame(width: 1, height: 1)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(selectedSection.title) 내용")
            .accessibilityIdentifier("workspace-rendered-content-\(selectedSection.rawValue)")
    }

    private func cachedDashboardDetailPanel(kind: DashboardDetailKind) -> DashboardDetailPanelView {
        DashboardDetailPanelView(
            kind: kind,
            model: model,
            snapshot: model.snapshot,
            renderSignature: model.dashboardRenderSignature,
            fileRenderSignature: model.dashboardFileRenderSignature,
            filterOptions: model.dashboardFilterOptions(for: kind)
        )
    }
}

private struct MacWorkspaceSidebarView: View {
    let model: KLMSMacModel
    @Binding var selectedSection: KLMSMacSection
    var resetCurrentSectionScroll: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("KLMS Sync")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.klmsMacPrimaryText)
                    Text("작업 공간")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.klmsMacSecondaryText)
                }
                .padding(.horizontal, 6)

                WorkspaceNavigationView(selection: $selectedSection, resetCurrentSectionScroll: resetCurrentSectionScroll)

                DashboardRuntimePanelView(model: model)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.klmsMacSidebarBackground)
    }
}

private struct WorkspaceNavigationView: View {
    @Binding var selection: KLMSMacSection
    var resetCurrentSectionScroll: () -> Void
    @State private var hoveredSection: KLMSMacSection?

    var body: some View {
        VStack(spacing: 7) {
            WorkspaceNavigationSelectionMarker(section: selection)
            ForEach(KLMSMacSection.allCases) { section in
                let isSelected = selection == section
                let isHovered = hoveredSection == section
                Button {
                    guard selection != section else {
                        resetCurrentSectionScroll()
                        return
                    }
                    select(section)
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(iconBackground(isSelected: isSelected, isHovered: isHovered))
                            Image(systemName: section.systemImage)
                                .font(.subheadline.weight(isSelected ? .bold : .semibold))
                                .foregroundStyle(isSelected ? Color.klmsMacSelectedForeground : Color.klmsMacSecondaryText.opacity(0.84))
                        }
                        .frame(width: 30, height: 30)
                        Text(section.title)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.klmsMacSelectedForeground : Color.klmsMacPrimaryText)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? Color.klmsMacSelectedBorder : Color.klmsMacSecondaryText.opacity(0.52))
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 10)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(
                        rowBackground(isSelected: isSelected, isHovered: isHovered),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isSelected ? Color.klmsMacSelectedBorder : Color.clear)
                            .frame(width: isSelected ? 4 : 0)
                            .padding(.vertical, 9)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(rowBorder(isSelected: isSelected, isHovered: isHovered), lineWidth: isSelected ? 1.4 : 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(MacPressFeedbackButtonStyle())
                .onHover { hovering in
                    hoveredSection = hovering ? section : (hoveredSection == section ? nil : hoveredSection)
                }
                .accessibilityLabel(section.title)
                .accessibilityIdentifier("workspace-\(section.rawValue)")
                .accessibilityValue(isSelected ? "선택됨" : "선택 안 됨")
                .accessibilityHint(isSelected ? "선택된 섹션입니다." : "이 섹션으로 이동합니다.")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private func select(_ section: KLMSMacSection) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            selection = section
        }
    }

    private func rowBackground(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return Color.klmsMacSelectedBackground
        }
        return isHovered ? Color.klmsMacSubtleCardBackground.opacity(0.62) : Color.klmsMacSubtleCardBackground.opacity(0.28)
    }

    private func rowBorder(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return Color.klmsMacSelectedBorder
        }
        return isHovered ? Color.klmsMacCommandBorder.opacity(0.74) : Color.klmsMacCommandBorder.opacity(0.36)
    }

    private func iconBackground(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return Color.klmsMacSelectedBorder.opacity(0.24)
        }
        return isHovered ? Color.klmsMacCommandButtonPressedOverlay.opacity(0.46) : Color.klmsMacSubtleCardBackground.opacity(0.72)
    }
}

private struct WorkspaceNavigationSelectionMarker: View {
    var section: KLMSMacSection

    var body: some View {
        Text("\(section.title) 내용")
            .font(.system(size: 1))
            .foregroundStyle(Color.klmsMacPrimaryText.opacity(0.01))
            .lineLimit(1)
            .frame(width: 1, height: 1)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(section.title) 내용")
            .accessibilityIdentifier("workspace-navigation-selection-\(section.rawValue)")
    }
}

private struct DashboardTopBarView: View {
    let model: KLMSMacModel
    @Binding var selectedSection: KLMSMacSection

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DashboardTopBarStatusContent(snapshot: snapshot)
                .equatable()

            TopUtilityActionsView(model: model)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("workspace-title-\(selectedSection.rawValue)")
        .accessibilityLabel("\(selectedSection.title) 화면")
    }

    private var snapshot: DashboardTopBarSnapshot {
        if let command = model.runningCommand {
            if let phase = model.currentPhaseText {
                return DashboardTopBarSnapshot(
                    title: selectedSection.title,
                    statusText: "\(command.displayName) 실행 중 · \(phase)",
                    runningPhaseLabel: phase,
                    statusBadgeText: "진행 중",
                    tone: .running
                )
            }
            return DashboardTopBarSnapshot(
                title: selectedSection.title,
                statusText: "\(command.displayName) 실행 중",
                runningPhaseLabel: "진행 중",
                statusBadgeText: "진행 중",
                tone: .running
            )
        }
        if model.needsAttention {
            return DashboardTopBarSnapshot(
                title: selectedSection.title,
                statusText: "확인이 필요합니다 · 진단 보기에서 원인을 확인하세요.",
                runningPhaseLabel: nil,
                statusBadgeText: "확인 필요",
                tone: .attention
            )
        }
        if let report = model.snapshot.syncReport {
            return DashboardTopBarSnapshot(
                title: selectedSection.title,
                statusText: "준비됨 · 최근 상태 \(report.status.klmsLocalizedStatus)",
                runningPhaseLabel: nil,
                statusBadgeText: "준비됨",
                tone: .ready
            )
        }
        return DashboardTopBarSnapshot(
            title: selectedSection.title,
            statusText: "첫 실행 전 · 전체 동기화나 진단을 실행하세요.",
            runningPhaseLabel: nil,
            statusBadgeText: "준비 필요",
            tone: .ready
        )
    }
}

private struct DashboardTopBarSnapshot: Equatable {
    var title: String
    var statusText: String
    var runningPhaseLabel: String?
    var statusBadgeText: String
    var tone: DashboardTopBarTone
}

private enum DashboardTopBarTone: Equatable {
    case running
    case attention
    case ready

    var color: Color {
        switch self {
        case .running:
            return .klmsMacCommandAccent
        case .attention:
            return .klmsMacWarningBorder
        case .ready:
            return .klmsMacSecondaryText
        }
    }
}

private struct DashboardTopBarStatusContent: View, Equatable {
    var snapshot: DashboardTopBarSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(snapshot.title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Color.klmsMacPrimaryText)
            Text(snapshot.statusText)
                .font(.caption)
                .foregroundStyle(Color.klmsMacSecondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.84)
                .truncationMode(.tail)
        }
        Spacer(minLength: 12)

        if let runningPhaseLabel = snapshot.runningPhaseLabel {
            Label(runningPhaseLabel, systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.klmsMacCommandAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.klmsMacCommandAccent.opacity(0.12), in: Capsule())
        }

        Text(snapshot.statusBadgeText)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .foregroundStyle(snapshot.tone.color)
            .background(snapshot.tone.color.opacity(0.12), in: Capsule())
    }
}

private struct MacAlertBannerView: View {
    let model: KLMSMacModel
    @Binding var selectedSection: KLMSMacSection
    @Binding var expandedLogSummaryKind: LogSummaryKind?

    var body: some View {
        MacAlertBannerContent(snapshot: snapshot) {
            performAction()
        }
        .equatable()
    }

    private var snapshot: MacAlertBannerSnapshot {
        MacAlertBannerSnapshot(
            selectedSection: selectedSection,
            authDigits: model.currentAuthDigits,
            authStatusMessage: model.authStatusMessage?.nilIfBlank,
            runningCommandDisplayName: model.runningCommand?.displayName,
            currentPhaseText: model.currentPhaseText,
            liveProgressLine: model.liveProgressLine,
            needsAttention: model.needsAttention,
            hasSyncReport: model.snapshot.syncReport != nil,
            loggedIn: model.snapshot.loginStatus?.loggedIn == true
        )
    }

    private func performAction() {
        if let digits = model.currentAuthDigits {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(digits, forType: .string)
            return
        }
        if model.runningCommand != nil {
            expandedLogSummaryKind = .run
            selectedSection = .activityLogs
            return
        }
        if model.needsAttention {
            selectedSection = .diagnostics
            return
        }
        if model.snapshot.syncReport == nil {
            Task {
                await model.run(.doctor)
            }
            return
        }
    }
}

private struct MacAlertBannerSnapshot: Equatable {
    var selectedSection: KLMSMacSection
    var authDigits: String?
    var authStatusMessage: String?
    var runningCommandDisplayName: String?
    var currentPhaseText: String?
    var liveProgressLine: String?
    var needsAttention: Bool
    var hasSyncReport: Bool
    var loggedIn: Bool

    var shouldShow: Bool {
        authDigits != nil
            || authStatusMessage != nil
            || runningCommandDisplayName != nil
            || needsAttention
            || selectedSection == .dashboard
    }

    var title: String {
        if authDigits != nil {
            return "KAIST 인증 번호"
        }
        if let authStatusMessage {
            return authStatusMessage
        }
        if let runningCommandDisplayName {
            if let currentPhaseText {
                return "\(runningCommandDisplayName) · \(currentPhaseText)"
            }
            return "\(runningCommandDisplayName) 실행 중"
        }
        if needsAttention {
            return "상태 검사 실패"
        }
        if !hasSyncReport {
            return "처음 실행 준비"
        }
        return loggedIn ? "이미 로그인됨" : "준비됨"
    }

    var detail: String {
        if authDigits != nil {
            return "휴대폰 인증 화면에서 같은 번호를 선택하면 동기화를 계속 진행합니다."
        }
        if authStatusMessage != nil {
            return "인증 상태가 확인됐습니다. 필요한 경우 다음 단계가 바로 이어집니다."
        }
        if runningCommandDisplayName != nil {
            return currentPhaseText.map { "현재 단계: \($0)" }
                ?? liveProgressLine
                ?? "실시간 로그에서 진행 상황을 확인할 수 있습니다."
        }
        if needsAttention {
            return "진단 보기에서 실패 원인과 다음 조치를 확인할 수 있습니다."
        }
        if !hasSyncReport {
            return "환경 진단을 실행하면 권한, 엔진, 메모/캘린더/미리 알림 상태를 확인합니다."
        }
        return "동기화를 바로 실행할 수 있습니다. 인증번호가 필요하면 여기에 크게 고정됩니다."
    }

    var chipText: String {
        if let authDigits {
            return authDigits
        }
        if runningCommandDisplayName != nil {
            return currentPhaseText ?? "LOG"
        }
        if needsAttention {
            return "진단"
        }
        if !hasSyncReport {
            return "검사"
        }
        return "확인"
    }

    var chipHorizontalPadding: CGFloat {
        if authDigits != nil {
            return 16
        }
        if runningCommandDisplayName != nil, currentPhaseText != nil {
            return 10
        }
        return 12
    }

    var tone: MacAlertBannerTone {
        if authDigits != nil {
            return .authDigits
        }
        if authStatusMessage != nil {
            return .success
        }
        if runningCommandDisplayName != nil {
            return .running
        }
        if needsAttention || !hasSyncReport {
            return .warning
        }
        return .ready
    }
}

private enum MacAlertBannerTone: Equatable {
    case authDigits
    case success
    case running
    case warning
    case ready

    var tint: Color {
        switch self {
        case .authDigits, .warning:
            return .klmsMacWarningBorder
        case .success:
            return .klmsMacSuccessBorder
        case .running, .ready:
            return .klmsMacCommandAccent
        }
    }

    var chipForeground: Color {
        switch self {
        case .authDigits, .ready:
            return Color.klmsMacPrimaryText
        case .running:
            return Color.klmsMacSecondaryCommandButtonForeground
        case .warning:
            return Color.klmsMacWarningBorder
        case .success:
            return Color.klmsMacPrimaryText
        }
    }

    var chipBackground: Color {
        switch self {
        case .authDigits, .warning:
            return Color.klmsMacWarningBackground
        case .running:
            return Color.klmsMacCommandButtonPressedBackground
        case .success, .ready:
            return Color.klmsMacSubtleCardBackground
        }
    }
}

private struct MacAlertBannerContent: View, Equatable {
    var snapshot: MacAlertBannerSnapshot
    var performAction: () -> Void

    nonisolated static func == (lhs: MacAlertBannerContent, rhs: MacAlertBannerContent) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        if snapshot.shouldShow {
            Button {
                performAction()
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.klmsMacPrimaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.86)
                        Text(snapshot.detail)
                            .font(.caption)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 10)
                    Text(snapshot.chipText)
                        .font(chipFont)
                        .monospacedDigit()
                        .foregroundStyle(chipForeground)
                        .padding(.horizontal, snapshot.chipHorizontalPadding)
                        .padding(.vertical, 8)
                        .background(chipBackground, in: Capsule())
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(bannerBackground, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(bannerBorder, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 14))
            .accessibilityLabel(snapshot.title)
            .accessibilityHint(snapshot.detail)
            .accessibilitySortPriority(100)
            .zIndex(1)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)
        }
    }

    private var chipFont: Font {
        snapshot.authDigits == nil ? .caption.weight(.bold) : .title3.weight(.heavy)
    }

    private var bannerBackground: Color {
        Color.klmsMacAdaptiveColor(
            light: NSColor(red: 0.914, green: 0.902, blue: 0.858, alpha: 1.0),
            dark: NSColor(red: 0.176, green: 0.169, blue: 0.153, alpha: 1.0)
        )
    }

    private var bannerBorder: Color {
        snapshot.tone.tint.opacity(0.28)
    }

    private var chipForeground: Color {
        snapshot.tone.chipForeground
    }

    private var chipBackground: Color {
        snapshot.tone.chipBackground
    }
}

private enum KLMSMacScrollAnchor: Hashable {
    case top
}

private struct MacWorkspaceScrollResetKey: Equatable {
    var section: KLMSMacSection
    var nonce: Int
}

private func macPerformWithoutAnimation(_ updates: () -> Void) {
    var transaction = Transaction()
    transaction.animation = nil
    withTransaction(transaction) {
        updates()
    }
}

private struct WholeScreenVerticalScrollView<ResetID: Equatable, Content: View>: View {
    var resetID: ResetID
    @ViewBuilder var content: Content
    @State private var scrollResetTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                Color.clear
                    .frame(height: 0)
                    .id(KLMSMacScrollAnchor.top)
                content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
            }
            .scrollIndicators(.visible)
            .clipped()
            .onChange(of: resetID) { _, _ in
                scheduleScrollReset(proxy: proxy)
            }
            .onDisappear {
                scrollResetTask?.cancel()
            }
        }
    }

    private func scheduleScrollReset(proxy: ScrollViewProxy) {
        scrollResetTask?.cancel()
        scrollResetTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(KLMSMacScrollAnchor.top, anchor: .top)
            }
        }
    }
}

private enum KLMSMacSection: String, CaseIterable, Identifiable {
    case dashboard
    case files
    case tasks
    case notices
    case calendar
    case activityLogs
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:
            "대시보드"
        case .files:
            "파일"
        case .notices:
            "공지"
        case .tasks:
            "과제/시험"
        case .calendar:
            "캘린더"
        case .activityLogs:
            "로그"
        case .diagnostics:
            "진단"
        case .settings:
            "설정"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard:
            "gauge.with.dots.needle.67percent"
        case .files:
            "folder"
        case .notices:
            "megaphone"
        case .tasks:
            "checklist"
        case .calendar:
            "calendar"
        case .activityLogs:
            "list.bullet.rectangle.portrait"
        case .diagnostics:
            "wrench.and.screwdriver"
        case .settings:
            "gearshape"
        }
    }

    var accessibilitySummary: String {
        switch self {
        case .dashboard:
            "대시보드 화면 · 전체 동기화 · 변경 요약"
        case .files:
            "파일 화면 · 파일 목록 · 필터와 검색"
        case .tasks:
            "과제/시험 화면 · 과제 · 시험 · 필터와 검색"
        case .notices:
            "공지 화면 · 공지 분류 · 필터와 검색"
        case .calendar:
            "캘린더 화면 · 캘린더 일정 · KLMS 기준 반영"
        case .activityLogs:
            "로그 화면 · 실행 로그 지우기 · 서버 로그 지우기"
        case .diagnostics:
            "진단 화면 · 상태 검사 · 권한/환경 진단"
        case .settings:
            "설정 화면 · 바로 반영되는 설정"
        }
    }
}

private struct TaskAndExamWorkspaceView: View {
    let model: KLMSMacModel
    @State private var selectedKind: DashboardDetailKind = .assignments

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            taskKindSelector
            cachedDashboardDetailPanel(kind: activeKind)
                .equatable()
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            normalizeSelection()
        }
        .onChange(of: availableKinds.map(\.rawValue).joined(separator: ":")) { _, _ in
            normalizeSelection()
        }
    }

    private var taskKindSelector: some View {
        HStack(spacing: 8) {
            ForEach(availableKinds) { kind in
                taskKindButton(kind)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
    }

    private func taskKindButton(_ kind: DashboardDetailKind) -> some View {
        let isSelected = activeKind == kind
        return Button {
            guard selectedKind != kind else { return }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                selectedKind = kind
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: taskKindIcon(kind))
                    .font(.caption.weight(.bold))
                Text(kind.title)
                    .font(.caption.weight(.bold))
                Text("\(taskKindCount(kind))")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(isSelected ? Color.klmsMacSelectedForeground.opacity(0.16) : Color.klmsMacSubtleCardBackground, in: Capsule())
            }
            .foregroundStyle(isSelected ? Color.klmsMacSelectedForeground : Color.klmsMacPrimaryText)
            .padding(.horizontal, 11)
            .frame(minHeight: 44)
            .background(isSelected ? Color.klmsMacSelectedBackground : Color.klmsMacSubtleCardBackground.opacity(0.70), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.klmsMacSelectedBorder : Color.klmsMacBorder.opacity(0.70), lineWidth: isSelected ? 1.25 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 10))
        .accessibilityLabel("\(kind.title) 목록")
        .accessibilityValue(isSelected ? "선택됨, \(taskKindCount(kind))개" : "\(taskKindCount(kind))개")
    }

    private var availableKinds: [DashboardDetailKind] {
        var kinds: [DashboardDetailKind] = [.assignments, .exams]
        if model.snapshot.visibleCounts.helpDesk > 0 {
            kinds.append(.helpDesk)
        }
        return kinds
    }

    private var activeKind: DashboardDetailKind {
        availableKinds.contains(selectedKind) ? selectedKind : .assignments
    }

    private func normalizeSelection() {
        guard !availableKinds.contains(selectedKind) else { return }
        selectedKind = availableKinds.first ?? .assignments
    }

    private func taskKindCount(_ kind: DashboardDetailKind) -> Int {
        switch kind {
        case .assignments:
            model.snapshot.visibleCounts.assignments
        case .exams:
            model.snapshot.visibleCounts.exams
        case .helpDesk:
            model.snapshot.visibleCounts.helpDesk
        default:
            0
        }
    }

    private func taskKindIcon(_ kind: DashboardDetailKind) -> String {
        switch kind {
        case .assignments:
            "checklist"
        case .exams:
            "calendar.badge.clock"
        case .helpDesk:
            "questionmark.circle"
        default:
            "circle"
        }
    }

    private func cachedDashboardDetailPanel(kind: DashboardDetailKind) -> DashboardDetailPanelView {
        DashboardDetailPanelView(
            kind: kind,
            model: model,
            snapshot: model.snapshot,
            renderSignature: model.dashboardRenderSignature,
            fileRenderSignature: model.dashboardFileRenderSignature,
            filterOptions: model.dashboardFilterOptions(for: kind)
        )
    }
}

private struct QuickStatusStripView: View {
    let model: KLMSMacModel

    var body: some View {
        HStack(spacing: 6) {
            StatusChipView(
                title: "공지 체크리스트",
                systemImage: "checklist.checked",
                color: .klmsMacCommandAccent
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
            return .klmsMacCommandAccent
        }
        if let result = model.lastCommandResult {
            if result.wasCancelled {
                return .klmsMacSecondaryText
            }
            return result.succeeded ? .klmsMacSuccessBorder : .klmsMacWarningBorder
        }
        return model.snapshot.syncReport == nil ? .klmsMacSecondaryText : .klmsMacCommandAccent
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
    let model: KLMSMacModel
    @AppStorage("KLMSMacIntegrationStatusExpanded") private var isExpanded = false
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    var body: some View {
        let verify = model.snapshot.verifyResult
        let statuses = integrationStatuses(for: verify)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    isExpanded.toggle()
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
                            .foregroundStyle(Color.klmsMacSecondaryText)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 8))
                .help(isExpanded ? "연동 상태 접기" : "연동 상태 펼치기")

                Button {
                    Task { await model.run(.verify) }
                } label: {
                    Label("상태 검사", systemImage: "checkmark.seal")
                }
                .disabled(model.runningCommand != nil)
                .buttonStyle(KLMSMacRootActionButtonStyle())
            }

            if isExpanded {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(statuses) { status in
                        IntegrationStatusTile(status: status)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isExpanded ? 10 : 8)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
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
            return .klmsMacCommandAccent
        }
        guard let verify else {
            return .klmsMacSecondaryText
        }
        switch verify.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ok":
            return .klmsMacSuccessBorder
        case "warn", "warning":
            return .klmsMacWarningBorder
        case "fail", "failed", "error":
            return .klmsMacDangerBorder
        default:
            return .klmsMacSecondaryText
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
        if calendar.manualExamCount > 0 {
            return "시험 \(calendar.displayExamCount) · 헬프 \(calendar.helpdeskCount)"
        }
        return "시험 \(calendar.examCount) · 헬프 \(calendar.helpdeskCount)"
    }

    private func calendarDetail(for verify: VerifyResult?) -> String {
        guard let calendar = verify?.calendar else {
            return "시험과 헬프데스크 일정이 캘린더와 맞는지 확인합니다."
        }
        if let totals = calendar.resultTotals {
            let manualText = calendar.manualExamCount > 0 ? " · 메일 등록 시험 \(calendar.manualExamCount)" : ""
            return "최근 반영 결과: KLMS 시험 \(totals.exam)\(manualText) · 헬프 \(totals.helpdesk)"
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

private enum KLMSMacRootButtonTone {
    case soft
    case primary
    case destructive
    case success
    case accent(Color)
}

private struct KLMSMacRootActionButtonStyle: ButtonStyle {
    var tone: KLMSMacRootButtonTone = .soft
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(minWidth: 40, minHeight: 40)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(background(isPressed: configuration.isPressed))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(border(isPressed: configuration.isPressed), lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.96 : 1.0) : 0.54)
    }

    private var foreground: Color {
        switch tone {
        case .soft:
            Color.klmsMacSecondaryCommandButtonForeground
        case .primary:
            Color.klmsMacPrimaryCommandButtonForeground
        case .destructive:
            isEnabled ? Color.klmsMacDangerCommandButtonForeground : Color.klmsMacSecondaryText.opacity(0.68)
        case .success:
            Color.klmsMacSecondaryCommandButtonForeground
        case .accent(let color):
            color
        }
    }

    private func background(isPressed: Bool) -> AnyShapeStyle {
        switch tone {
        case .soft:
            return AnyShapeStyle(isPressed ? Color.klmsMacCommandButtonPressedBackground : Color.klmsMacCommandButtonBackground.opacity(0.90))
        case .primary:
            return AnyShapeStyle(isPressed ? Color.klmsMacPrimaryCommandButtonPressedBackground : Color.klmsMacPrimaryCommandButtonBackground)
        case .destructive:
            if !isEnabled {
                return AnyShapeStyle(Color.klmsMacCommandButtonBackground.opacity(0.42))
            }
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.klmsMacDangerBorder.opacity(isPressed ? 0.82 : 0.98),
                        Color.klmsMacDangerBorder.opacity(isPressed ? 0.62 : 0.74),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .success:
            return AnyShapeStyle(isPressed ? Color.klmsMacSuccessBorder.opacity(0.20) : Color.klmsMacSuccessBackground)
        case .accent(let color):
            return AnyShapeStyle(color.opacity(isPressed ? 0.18 : 0.10))
        }
    }

    private func border(isPressed: Bool) -> Color {
        switch tone {
        case .soft:
            Color.klmsMacCommandButtonBorder.opacity(0.92)
        case .primary:
            Color.klmsMacPrimaryCommandButtonBorder.opacity(isPressed ? 0.72 : 1.0)
        case .destructive:
            isEnabled ? Color.klmsMacDangerBorder.opacity(isPressed ? 0.92 : 0.84) : Color.klmsMacCommandButtonBorder.opacity(0.42)
        case .success:
            Color.klmsMacSuccessBorder
        case .accent(let color):
            color.opacity(0.28)
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
            .klmsMacSuccessBorder
        case .warning:
            .klmsMacWarningBorder
        case .unknown:
            .klmsMacSecondaryText
        case .running:
            .klmsMacCommandAccent
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
                .foregroundStyle(Color.klmsMacSecondaryText)
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

private struct ImportantLogPanelView: View {
    let model: KLMSMacModel
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
    let model: KLMSMacModel
    @Binding var expandedKind: LogSummaryKind?
    private static let terminalSummaryDisplayInterval: TimeInterval = 5 * 60
    private let tileColumns = [GridItem(.adaptive(minimum: 176), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("로그 요약", systemImage: "list.bullet.rectangle")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                if let updatedAt = latestUpdatedAtText {
                    Text(updatedAt)
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                }
                Button {
                    Task {
                        await model.clearVisibleLogsAndServerRelayLogs()
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(KLMSMacRootActionButtonStyle(tone: .destructive))
                .help("화면의 실행 로그, 서버 요청, 파일 요청, 항목 변경, 설정 변경, 공유 실행 로그를 지웁니다. 진행 중인 요청은 유지됩니다.")
                .accessibilityLabel("전체 기록 지우기")
                .disabled(model.runningCommand != nil || !model.hasClearableVisibleLogs)
            }

            LazyVGrid(columns: tileColumns, alignment: .leading, spacing: 8) {
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
            .frame(maxWidth: .infinity, alignment: .leading)

            if let expandedKind {
                LogSummaryDetailView(kind: expandedKind, model: model)
            } else {
                Text("요약 타일을 누르면 관련 로그와 요청 기록을 바로 펼칩니다.")
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.klmsMacBorder.opacity(0.72), lineWidth: 1)
        }
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
            return .klmsMacCommandAccent
        }
        guard let result = model.lastCommandResult else {
            return .klmsMacSecondaryText
        }
        if result.wasCancelled {
            return .klmsMacSecondaryText
        }
        return result.succeeded ? Color.klmsMacSuccessBorder : Color.klmsMacWarningBorder
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
        return model.serverRelayEnabled ? "iPhone/iPad/Windows 요청을 기다리고 있습니다." : "설정에서 서버 릴레이를 켜면 원격 요청을 처리합니다."
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
            return .klmsMacSecondaryText
        }
        if currentRemoteCommand?.displayStatus() == .failed || currentRemoteCommand?.displayStatus() == .macUnavailable {
            return .klmsMacWarningBorder
        }
        if currentRemoteCommand?.displayStatus().isInFlight == true {
            return .klmsMacCommandAccent
        }
        return model.serverRelayEnabled ? .klmsMacSuccessBorder : .klmsMacSecondaryText
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
                ? "iPhone/iPad/Windows에서 파일 열기를 요청하면 진행 상태가 표시됩니다."
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
            return .klmsMacCommandAccent
        case .completed:
            return .klmsMacSuccessBorder
        case .failed, .macUnavailable:
            return .klmsMacWarningBorder
        case nil:
            return .klmsMacSecondaryText
        }
    }

    private func toggle(_ kind: LogSummaryKind) {
        expandedKind = expandedKind == kind ? nil : kind
    }
}

private struct LogSummaryDetailView: View {
    var kind: LogSummaryKind
    let model: KLMSMacModel

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
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var runDetail: some View {
        let text = bounded(runLogText.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.isEmpty {
            Text("아직 표시할 실행 로그가 없습니다.")
                .font(.caption)
                .foregroundStyle(Color.klmsMacSecondaryText)
        } else {
            HStack {
                Text(model.runningCommand == nil ? "마지막 실행 로그" : "실시간 로그")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(text.split(whereSeparator: \.isNewline).count)줄")
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
            }
            LogTextBlock(text: text)
        }
    }

    private var remoteDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.remoteProcessingStatusMessage?.nilIfBlank ?? model.serverRelayStatusMessage?.nilIfBlank {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .textSelection(.enabled)
            }
            if let command = activeRemoteCommand {
                RemoteCommandActivityRow(command: command)
            } else {
                Text("현재 진행 중인 원격 요청이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(Color.klmsMacSecondaryText)
            }
        }
    }

    private var activeRemoteCommand: RemoteRunCommand? {
        guard let command = model.lastRemoteCommand,
              command.displayStatus().isInFlight else {
            return nil
        }
        return command
    }

    private var fileRequestDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("파일 요청 기록")
                .font(.caption.weight(.semibold))
            if model.serverRelayRecentFileAccessRequests.isEmpty {
                Text("최근 파일 요청이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(Color.klmsMacSecondaryText)
            } else {
                ForEach(model.serverRelayRecentFileAccessRequests.prefix(8)) { request in
                    FileAccessActivityRow(request: request)
                }
            }
        }
    }

    private var runLogText: String {
        if !model.liveCommandOutput.isEmpty {
            return model.liveCommandOutput
        }
        return model.lastCommandDisplayOutput
    }

    private func bounded(_ text: String) -> String {
        let maxCharacters = 24_000
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
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    Text(value)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.klmsMacSecondaryText)
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
        .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 14))
        .help(isExpanded ? "관련 로그 접기" : "관련 로그 펼치기")
        .accessibilityLabel("\(title) 로그 요약 \(isExpanded ? "펼쳐짐" : "접힘")")
        .accessibilityHint(isExpanded ? "관련 로그 접기" : "관련 로그 펼치기")
    }
}

private struct NextActionPanelView: View {
    let model: KLMSMacModel
    @Binding var selectedSection: KLMSMacSection
    @Binding var expandedLogSummaryKind: LogSummaryKind?

    var body: some View {
        if let action = nextAction {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: action.systemImage)
                    .foregroundStyle(action.color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(action.detail)
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    perform(action)
                } label: {
                    Label(action.buttonTitle, systemImage: action.buttonImage)
                }
                .buttonStyle(KLMSMacRootActionButtonStyle(tone: action.kind == .openDiagnostics ? .accent(.klmsMacWarningBorder) : .soft))
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
                color: .klmsMacCommandAccent
            )
        }
        if model.currentAuthDigits != nil {
            return nil
        }
        if model.needsAttention {
            return NextAction(
                kind: .openDiagnostics,
                title: "상태 확인이 필요합니다",
                detail: "진단 탭에서 실패 원인과 다음 조치를 확인하세요.",
                buttonTitle: "진단 보기",
                buttonImage: "wrench.and.screwdriver",
                systemImage: "exclamationmark.triangle.fill",
                color: .klmsMacWarningBorder
            )
        }
        if model.snapshot.syncReport == nil {
            return NextAction(
                kind: .runDoctor,
                title: "처음 실행 준비",
                detail: "환경 진단으로 권한과 엔진 상태를 먼저 확인합니다.",
                buttonTitle: "환경 진단",
                buttonImage: "stethoscope",
                systemImage: "sparkles",
                color: .klmsMacCommandAccent
            )
        }
        if model.appDiagnostics.codeSigning.isAdHoc {
            return NextAction(
                kind: .showSettings,
                title: "앱 권한이 빌드마다 흔들릴 수 있습니다",
                detail: "현재 앱은 임시 서명 상태입니다. 설정에서 서명/권한 상태를 확인하세요.",
                buttonTitle: "설정 보기",
                buttonImage: "gearshape",
                systemImage: "signature",
                color: .klmsMacWarningBorder
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
        case .copyAuthDigits:
            if let digits = model.currentAuthDigits {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(digits, forType: .string)
            }
        case .runDoctor:
            Task {
                await model.run(.doctor)
            }
        case .showSettings:
            selectedSection = .settings
        }
    }
}

private struct NextAction {
    enum Kind {
        case showRunningLog
        case copyAuthDigits
        case openDiagnostics
        case runDoctor
        case showSettings
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
    let model: KLMSMacModel

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
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.86)
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
                        .buttonStyle(KLMSMacRootActionButtonStyle(tone: .destructive))
                        .disabled(model.isCancellingCommand)
                        .help("\(command.displayName) 실행을 중단합니다.")
                        .accessibilityLabel("\(command.displayName) 중단")
                    }
                }
            }

            if let error = model.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.klmsMacDangerBorder)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let lock = model.sharedLockInfo {
                Label("실행 잠금: 프로세스 \(lock.pid) · 명령 \(lock.command) · \(lock.acquiredAt)", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(Color.klmsMacWarningBorder)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.runningCommand != nil, let progress = model.liveProgressLine {
                VStack(alignment: .leading, spacing: 2) {
                    if let phase = model.currentPhaseText {
                        Text("현재 단계: \(phase)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.klmsMacCommandAccent)
                    }
                    Text(progress)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.klmsMacSecondaryText)
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
        if model.needsAttention {
            return "주의 필요 · \(model.attentionSummary)"
        }
        if let report = model.snapshot.syncReport {
            return "준비됨 · \(report.status.klmsLocalizedStatus)"
        }
        return "설치 또는 첫 실행 필요"
    }

    private var statusColor: Color {
        if model.runningCommand != nil {
            return .klmsMacCommandAccent
        }
        if model.needsAttention {
            return .klmsMacWarningBorder
        }
        return .klmsMacSecondaryText
    }

    private var statusBadgeText: String {
        if model.runningCommand != nil {
            return "실행 중"
        }
        if model.needsAttention {
            return "주의"
        }
        if model.snapshot.syncReport != nil {
            return "준비됨"
        }
        return "준비 필요"
    }
}

private struct DiagnosticToolsPanelView: View {
    let model: KLMSMacModel
    @State private var isAdvancedExpanded = false
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 8)]
    private let dryRunCommands: [KLMSEngineCommand] = [.fullSync, .filesSync, .coreSync, .noticeSync]

    var body: some View {
        SectionBox(title: "빠른 점검") {
            VStack(alignment: .leading, spacing: 12) {
                Text("권장 순서: 상태 검사 → 권한/환경 진단 → 리포트")
                    .font(.caption)
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    diagnosticButton(.verify)
                    diagnosticButton(.doctor)
                    diagnosticButton(.report)
                }

                DiagnosticChecksDisclosure(
                    title: "고급 도구",
                    isExpanded: $isAdvancedExpanded
                ) {
                    Text("변경 예정량만 보거나 내부 상태 파일을 다시 만들 때 사용합니다.")
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    diagnosticButton(.v2BuildState)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(dryRunCommands, id: \.self) { command in
                            dryRunButton(command)
                        }
                    }
                    dryRunReportSummary
                }

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
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .padding(.vertical, 4)
        }
        .buttonStyle(KLMSMacRootActionButtonStyle())
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
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(KLMSMacRootActionButtonStyle())
        .disabled(model.runningCommand != nil || !command.supportsDryRun)
        .help("실제 반영 없이 변경 예정량만 계산합니다.")
        .accessibilityLabel("\(command.displayName) 변경량 계산")
        .accessibilityHint("실제 반영 없이 변경 예정량만 계산합니다.")
    }

    @ViewBuilder
    private var dryRunReportSummary: some View {
        if !model.snapshot.dryRunReports.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.snapshot.dryRunReports.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { scope in
                    if let report = model.snapshot.dryRunReports[scope] {
                        Text("\(scope.displayName): 생성 \(report.wouldCreate) · 수정 \(report.wouldUpdate) · 삭제 \(report.wouldDelete) · 다운로드 \(report.wouldDownload) · 정리 예정 \(report.wouldPrune)")
                            .font(.caption)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                    }
                }
            }
        }
    }
}

private struct DiagnosticStageDurationPanelView: View {
    let model: KLMSMacModel
    @State private var isDetailExpanded = false

    var body: some View {
        if !stageDurations.isEmpty {
            SectionBox(title: "단계별 소요 시간") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("최근 실행에서 어느 단계가 오래 걸렸는지 확인합니다.")
                        .font(.caption)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    CompactStageDurationRowsView(durations: stageDurations)
                    DiagnosticChecksDisclosure(
                        title: "자세히 보기",
                        isExpanded: $isDetailExpanded
                    ) {
                        CommandStageDurationSummaryView(durations: stageDurations)
                    }
                }
            }
        }
    }

    private var stageDurations: [KLMSStageDuration] {
        if !model.liveStageDurations.isEmpty {
            return model.liveStageDurations
        }
        return model.latestCommandHistoryStageDurations
    }
}

private struct LogTextBlock: View {
    var text: String
    var detailed = false
    private let displayText: String
    private let highlightSourceText: String
    @State private var highlights: [KLMSLogHighlight]
    @State private var isRawExpanded: Bool

    init(text: String, detailed: Bool = false, rawExpandedByDefault: Bool = false) {
        self.text = text
        self.detailed = detailed
        let boundedText = Self.boundedText(text, detailed: detailed)
        self.displayText = boundedText
        self.highlightSourceText = Self.boundedHighlightSourceText(boundedText, detailed: detailed)
        self._highlights = State(initialValue: [])
        self._isRawExpanded = State(initialValue: rawExpandedByDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ReadableLogHighlightsView(highlights: highlights, detailed: detailed)
            DiagnosticChecksDisclosure(
                title: "원본 로그 보기",
                isExpanded: $isRawExpanded,
                compact: true
            ) {
                rawLogText
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: highlightSourceText) {
            await rebuildHighlights()
        }
    }

    private var rawLogText: some View {
        Text(displayText)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(Color.klmsMacSecondaryText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(8)
            .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.klmsMacBorder, lineWidth: 1)
            )
    }

    private static func boundedText(_ text: String, detailed: Bool) -> String {
        let maxCharacters = detailed ? 18_000 : 8_000
        guard text.count > maxCharacters else {
            return text
        }
        let prefix = "... 화면 표시용으로 이전 로그 일부를 접었습니다 ...\n"
        return prefix + String(text.suffix(maxCharacters - prefix.count))
    }

    private static func boundedHighlightSourceText(_ text: String, detailed: Bool) -> String {
        let maxCharacters = detailed ? 6_000 : 3_000
        guard text.count > maxCharacters else {
            return text
        }
        return String(text.suffix(maxCharacters))
    }

    @MainActor
    private func rebuildHighlights() async {
        if !highlights.isEmpty {
            highlights = []
        }
        let text = highlightSourceText
        let nextHighlights = await Task.detached(priority: .utility) {
            KLMSReadableLogParser.highlights(from: text)
        }.value
        if highlights != nextHighlights {
            highlights = nextHighlights
        }
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
                    .foregroundStyle(Color.klmsMacSecondaryText)
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
                                    .foregroundStyle(Color.klmsMacSecondaryText)
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
                    .foregroundStyle(Color.klmsMacSecondaryText)
                Text(highlight.explanation.klmsDisplayText)
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
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
                    .foregroundStyle(Color.klmsMacPrimaryText.opacity(0.78))
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
            return .klmsMacWarningBorder
        case "success":
            return .klmsMacSuccessBorder
        case "summary":
            return .klmsMacCommandAccent
        default:
            return .klmsMacSecondaryText
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
                    .foregroundStyle(Color.klmsMacWarningBorder)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("KAIST 인증 번호")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.klmsMacSecondaryText)
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
                .buttonStyle(KLMSMacRootActionButtonStyle(tone: .accent(Color.klmsMacWarningBorder)))
                .accessibilityLabel("KAIST 인증 번호 복사")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsMacWarningBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.klmsMacWarningBorder, lineWidth: 1)
            }
        } else if let statusMessage {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.klmsMacSuccessBorder)
                Text(statusMessage)
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsMacSuccessBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.klmsMacSuccessBorder, lineWidth: 1)
            }
        }
    }
}

private struct DashboardSummaryView: View {
    let model: KLMSMacModel

    var body: some View {
        DashboardSummaryContentView(
            model: model,
            snapshot: model.snapshot,
            presentation: model.dashboardSummaryPresentation,
            renderSignature: model.dashboardRenderSignature
        )
        .equatable()
    }
}

private struct DashboardSummaryContentView: View, @preconcurrency Equatable {
    var model: KLMSMacModel
    var snapshot: EngineSnapshot
    var presentation: DashboardSummaryPresentation
    var renderSignature: DashboardRenderSignature
    @State private var selectedDetail: DashboardDetailKind?
    @State private var renderedDetail: DashboardDetailKind?
    @State private var isArchiveMetricsExpanded = false

    init(
        model: KLMSMacModel,
        snapshot: EngineSnapshot,
        presentation: DashboardSummaryPresentation,
        renderSignature: DashboardRenderSignature
    ) {
        self.model = model
        self.snapshot = snapshot
        self.presentation = presentation
        self.renderSignature = renderSignature
    }

    static func == (lhs: DashboardSummaryContentView, rhs: DashboardSummaryContentView) -> Bool {
        lhs.renderSignature == rhs.renderSignature
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            IssueSummaryView(issues: model.cachedIssues)
            if !presentation.hasAnyMetrics {
                Text("표시할 대시보드 항목이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(Color.klmsMacSecondaryText)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    metricColumn(
                        primaryMetrics: presentation.primaryMetrics,
                        attentionMetrics: presentation.attentionMetrics,
                        archiveMetrics: presentation.archiveMetrics,
                        isArchiveExpanded: isArchiveMetricsExpanded,
                        activeDetail: currentActiveDetail
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    dashboardDetailContent(renderedDetail: currentRenderedDetail)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var currentActiveDetail: DashboardDetailKind? {
        presentation.activeDetail(
            selectedDetail,
            archiveExpanded: isArchiveMetricsExpanded
        )
    }

    private var currentRenderedDetail: DashboardDetailKind? {
        presentation.renderedDetail(
            renderedDetail,
            archiveExpanded: isArchiveMetricsExpanded
        )
    }

    private func selectMetric(_ metric: Metric) {
        if let detail = metric.detail {
            guard selectedDetail != detail || renderedDetail != detail else {
                return
            }
            selectDashboardDetail(detail)
        }
    }

    private func selectDashboardDetail(_ detail: DashboardDetailKind) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            selectedDetail = detail
            renderedDetail = detail
        }
    }

    private func metricColumn(
        primaryMetrics: [Metric],
        attentionMetrics: [Metric],
        archiveMetrics: [Metric],
        isArchiveExpanded: Bool,
        activeDetail: DashboardDetailKind?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MetricSectionGrid(
                title: nil,
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
            if !archiveMetrics.isEmpty {
                DashboardArchiveMetricSection(
                    metrics: archiveMetrics,
                    isExpanded: $isArchiveMetricsExpanded,
                    selectedMetricID: activeDetail?.rawValue,
                    onSelect: selectMetric
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: isArchiveExpanded) { _, expanded in
            guard !expanded,
                  let selectedDetail,
                  archiveMetrics.contains(where: { $0.detail == selectedDetail }) else {
                return
            }
            self.selectedDetail = nil
            self.renderedDetail = nil
        }
    }

    private func dashboardDetailColumn(kind: DashboardDetailKind) -> some View {
        DashboardDetailPanelView(
            kind: kind,
            model: model,
            snapshot: snapshot,
            renderSignature: renderSignature,
            fileRenderSignature: model.dashboardFileRenderSignature,
            filterOptions: model.dashboardFilterOptions(for: kind)
        )
            .equatable()
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func dashboardDetailContent(renderedDetail: DashboardDetailKind?) -> some View {
        if let renderedDetail {
            dashboardDetailColumn(kind: renderedDetail)
        } else {
            DashboardDetailHint()
        }
    }
}

private struct DashboardDetailHint: View {
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "rectangle.stack.badge.cursorarrow")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.klmsMacSecondaryText)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text("대시보드 항목을 선택해 주세요.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsMacPrimaryText)
                Text("카드를 누르면 바로 아래에서 목록과 처리 버튼을 확인할 수 있습니다.")
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
    }
}

struct DashboardSummaryPresentation {
    var primaryMetrics: [Metric]
    var attentionMetrics: [Metric]
    var archiveMetrics: [Metric]

    init(snapshot: EngineSnapshot, summary: KLMSMacDashboardSummaryCache) {
        let counts = summary.visibleCounts
        primaryMetrics = [
            Metric("파일", snapshot.courseFileManifest.count, detail: .files),
            Metric("과제", counts.assignments + summary.mailAssignmentCount, detail: .assignments),
            Metric("공지", counts.notices, detail: .notices),
            Metric("시험", counts.exams + summary.mailExamCount, detail: .exams),
        ].filter { $0.value > 0 }
        attentionMetrics = [
            Metric("헬프데스크", counts.helpDesk, detail: .helpDesk),
            Metric("새 파일", counts.newFiles, detail: .newFiles),
            Metric("캘린더", summary.calendarAttentionCount, detail: .calendar),
            Metric("격리", counts.quarantine, detail: .quarantine),
            Metric("과제 후보", summary.assignmentCandidateCount, detail: .assignmentCandidates),
            Metric("시험 후보", summary.examCandidateCount, detail: .examCandidates),
            Metric("누락 파일", summary.localMissingFileCount, detail: .missingFiles),
            Metric("정리된 파일", summary.prunedFileCount, detail: .pruned),
        ].filter { $0.value > 0 }
        archiveMetrics = [
            Metric("보관함", summary.hiddenSummary.total, detail: .hidden),
        ].filter { $0.value > 0 }
    }

    var hasAnyMetrics: Bool {
        !primaryMetrics.isEmpty || !attentionMetrics.isEmpty || !archiveMetrics.isEmpty
    }

    func visibleMetrics(archiveExpanded: Bool) -> [Metric] {
        primaryMetrics + attentionMetrics + (archiveExpanded ? archiveMetrics : [])
    }

    func activeDetail(_ selected: DashboardDetailKind?, archiveExpanded: Bool) -> DashboardDetailKind? {
        let metrics = visibleMetrics(archiveExpanded: archiveExpanded)
        if let selected,
           let detail = metrics.first(where: { $0.detail == selected })?.detail {
            return detail
        }
        return nil
    }

    func renderedDetail(_ selected: DashboardDetailKind?, archiveExpanded: Bool) -> DashboardDetailKind? {
        let metrics = visibleMetrics(archiveExpanded: archiveExpanded)
        if let displayed = selected,
           let detail = metrics.first(where: { $0.detail == displayed })?.detail {
            return detail
        }
        return nil
    }
}

private struct DashboardRuntimePanelView: View {
    let model: KLMSMacModel
    @AppStorage("KLMSMacRuntimePanelExpanded") private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                macPerformWithoutAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Label("연동 상태", systemImage: "link")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.klmsMacPrimaryText)
                    Spacer(minLength: 6)
                    Text(runtimeSummaryBadgeText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(runtimeSummaryBadgeColor)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(runtimeSummaryBadgeColor.opacity(0.11), in: Capsule())
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.klmsMacSecondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 12))
            .help(isExpanded ? "연동 상태 접기" : "연동 상태 펼치기")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    MacRailStatusLine(text: integrationSummaryText)
                    MacRailStatusLine(text: noticeMemoSummaryText)
                    if let slowestSummaryText {
                        MacRailStatusLine(text: slowestSummaryText)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
    }

    private var runtimeSummaryBadgeText: String {
        if model.runningCommand != nil {
            return model.currentPhaseText ?? "실행 중"
        }
        if let verify = model.snapshot.verifyResult {
            return verify.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok" ? "정상" : "확인 필요"
        }
        return "접힘"
    }

    private var runtimeSummaryBadgeColor: Color {
        if model.runningCommand != nil {
            return .klmsMacCommandAccent
        }
        if let verify = model.snapshot.verifyResult {
            return verify.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok" ? .klmsMacSuccessBorder : .klmsMacWarningBorder
        }
        return .klmsMacSecondaryText
    }

    private var integrationSummaryText: String {
        guard let verify = model.snapshot.verifyResult else {
            return "Notes · Calendar · Reminders 상태 검사 전"
        }
        return verify.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok"
            ? "Notes · Calendar · Reminders 모두 사용 가능"
            : "Notes · Calendar · Reminders 확인 필요"
    }

    private var noticeMemoSummaryText: String {
        let render = model.snapshot.noticeRenderState
        let archive = model.snapshot.noticeArchiveRenderState
        if render != nil || archive != nil {
            let primary = render?.renderedNoticeCount ?? 0
            let checked = archive?.renderedNoticeCount ?? 0
            return "공지 메모: KLMS 공지 \(primary)개 · 확인한 공지 \(checked)개"
        }
        return "공지 메모: KLMS 공지 먼저 표시"
    }

    private var slowestSummaryText: String? {
        guard let stage = model.snapshot.syncReport?.slowest.first else {
            return nil
        }
        return "오래 걸린 작업: \(stage.name.klmsDisplayStageName) · \(stage.durationSecondsText)"
    }
}

private struct MacRailStatusLine: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.klmsMacSecondaryText)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsMacSubtleCardBackground.opacity(0.76), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.klmsMacBorder.opacity(0.72), lineWidth: 1)
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
                    .foregroundStyle(Color.klmsMacSecondaryText)
                ForEach(report.slowest.prefix(3)) { stage in
                    Text("\(stage.name.klmsDisplayStageName) · \(stage.durationSecondsText) · \(stage.status.klmsLocalizedStatus)")
                        .font(.caption)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                }
            }
            .padding(.top, 2)
        }
    }
}

private struct NoticeMemoStatusView: View {
    let model: KLMSMacModel

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
                            .foregroundStyle(Color.klmsMacSecondaryText)
                    }
                }
                NoticeMemoRowView(label: "KLMS 공지", state: snapshot.noticeRenderState, model: model)
                NoticeMemoRowView(label: "KLMS 확인한 공지", state: snapshot.noticeArchiveRenderState, model: model)
                if let timing = snapshot.noticeStageTiming {
                    Text("최근 공지 메모 작성: \(timing.status.klmsLocalizedStatus) · \(timing.elapsedSecondsText) · 체크리스트/문단 서식")
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    ForEach(timing.noticeRenderResultsForDisplay.prefix(3)) { result in
                        Text("\(result.displayTargetTitle): \(result.status.klmsLocalizedStatus)")
                            .font(.caption2)
                            .foregroundStyle(noticeResultIsOK(result.status) ? Color.klmsMacSecondaryText : Color.klmsMacWarningBorder)
                    }
                }
            }
            .padding(10)
            .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var renderModeText: String {
        "체크리스트/문단"
    }

    private var renderModeColor: Color {
        Color.klmsMacCommandAccent
    }

    private func noticeResultIsOK(_ status: String) -> Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "ok" || normalized == "skipped"
    }
}

private struct NoticeMemoRowView: View {
    var label: String
    var state: NoticeNoteRenderState?
    let model: KLMSMacModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
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
            .buttonStyle(KLMSMacRootActionButtonStyle())
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
    let model: KLMSMacModel

    var body: some View {
        let fileRequests = model.serverRelayRecentFileAccessRequests
        let requestLog = model.serverRelayRecentRequestLog
        let sharedRunLogs = model.serverRelaySharedRunLogs
        if model.lastRemoteCommand != nil || !fileRequests.isEmpty || !requestLog.isEmpty || !sharedRunLogs.isEmpty || model.remoteProcessingStatusMessage?.nilIfBlank != nil {
            SectionBox(title: "서버·파일 요청 기록") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Spacer()
                        Button {
                            Task {
                                await model.clearServerRelayActivityLogs()
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(KLMSMacRootActionButtonStyle(tone: .destructive))
                        .help("서버·파일 요청 기록 지우기")
                        .accessibilityLabel("서버·파일 요청 기록 지우기")
                        .disabled(!model.serverRelayConfigured || !model.hasClearableServerActivityLogs)
                    }

                    if let message = model.remoteProcessingStatusMessage?.nilIfBlank ?? model.serverRelayStatusMessage?.nilIfBlank {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "network")
                                .foregroundStyle(Color.klmsMacCommandAccent)
                                .frame(width: 18)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(Color.klmsMacSecondaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let command = model.lastRemoteCommand {
                        RemoteCommandActivityRow(command: command)
                    }

                    if !sharedRunLogs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("동기화 단계")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.klmsMacSecondaryText)
                            Text("Mac 앱에서 실행한 단계별 소요 시간과 마지막 로그입니다.")
                                .font(.caption2)
                                .foregroundStyle(Color.klmsMacSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(sharedRunLogs.prefix(8)) { log in
                                SharedRunLogActivityRow(
                                    log: log,
                                    stageDurations: model.sharedRunLogStageDurationsByID[log.id] ?? []
                                )
                            }
                        }
                    }

                    if !requestLog.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("서버 요청")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.klmsMacSecondaryText)
                            ForEach(requestLog.prefix(10)) { entry in
                                ServerRequestLogActivityRow(entry: entry)
                            }
                        }
                    }

                    if !fileRequests.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("파일 요청")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.klmsMacSecondaryText)
                            ForEach(fileRequests.prefix(8)) { request in
                                FileAccessActivityRow(request: request)
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct SharedRunLogActivityRow: View {
    var log: ServerRelayRunLog
    var stageDurations: [KLMSStageDuration]
    @State private var isExpanded = false

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
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
                            .foregroundStyle(Color.klmsMacSecondaryText)
                        CompactStageDurationRowsView(durations: stageDurations)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.klmsMacSecondaryText)
                }
                DeferredMacInteractionExpansion(isExpanded: isExpanded) {
                    LogTextBlock(text: log.outputTail)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 8))
        .accessibilityLabel("\(log.commandTitle.nilIfBlank ?? "동기화") 실행 로그 \(isExpanded ? "펼쳐짐" : "접힘")")
        .accessibilityHint(isExpanded ? "실행 로그 접기" : "실행 로그 펼치기")
    }

    private var systemImage: String {
        if log.wasCancelled {
            return "stop.circle"
        }
        return log.needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var tint: Color {
        if log.wasCancelled {
            return .klmsMacSecondaryText
        }
        return log.needsAttention ? Color.klmsMacWarningBorder : Color.klmsMacSuccessBorder
    }
}

private struct ServerRequestLogActivityRow: View {
    var entry: ServerRelayRequestLogEntry
    @State private var isExpanded = false

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
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
                                .foregroundStyle(Color.klmsMacSecondaryText)
                            Spacer(minLength: 8)
                            Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(Color.klmsMacSecondaryText)
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.klmsMacSecondaryText.opacity(0.58))
                        }
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                DeferredMacInteractionExpansion(isExpanded: isExpanded) {
                    LogTextBlock(text: expandedLog)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(statusColor.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 8))
        .accessibilityLabel("\(entry.action.nilIfBlank ?? entry.path.nilIfBlank ?? "서버 요청") 기록 \(isExpanded ? "펼쳐짐" : "접힘")")
        .accessibilityHint(isExpanded ? "서버 요청 기록 접기" : "서버 요청 기록 펼치기")
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
            return .klmsMacWarningBorder
        case "running":
            return .klmsMacCommandAccent
        default:
            return .klmsMacSuccessBorder
        }
    }
}

private struct RemoteCommandActivityRow: View {
    var command: RemoteRunCommand
    @State private var isExpanded = false

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
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
                                .foregroundStyle(Color.klmsMacSecondaryText)
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.klmsMacSecondaryText.opacity(0.58))
                        }
                        Text(remoteCommandDetail)
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                DeferredMacInteractionExpansion(isExpanded: isExpanded) {
                    LogTextBlock(text: expandedLog)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(statusColor.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 8))
        .accessibilityLabel("\(command.kind.displayName) 원격 실행 기록 \(isExpanded ? "펼쳐짐" : "접힘")")
        .accessibilityHint(isExpanded ? "원격 실행 기록 접기" : "원격 실행 기록 펼치기")
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
            Color.klmsMacCommandAccent
        case .completed:
            Color.klmsMacSuccessBorder
        case .cancelled:
            Color.klmsMacSecondaryText
        case .failed, .macUnavailable:
            Color.klmsMacWarningBorder
        }
    }
}

private struct FileAccessActivityRow: View {
    var request: ServerRelayFileAccessRequest
    @State private var isExpanded = false

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
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
                                .foregroundStyle(Color.klmsMacSecondaryText)
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.klmsMacSecondaryText.opacity(0.58))
                        }
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                DeferredMacInteractionExpansion(isExpanded: isExpanded) {
                    LogTextBlock(text: expandedLog)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(statusColor.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 8))
        .accessibilityLabel("\(request.itemTitle.nilIfBlank ?? "파일") 파일 요청 기록 \(isExpanded ? "펼쳐짐" : "접힘")")
        .accessibilityHint(isExpanded ? "파일 요청 기록 접기" : "파일 요청 기록 펼치기")
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
            Color.klmsMacCommandAccent
        case .completed:
            Color.klmsMacSuccessBorder
        case .failed, .macUnavailable:
            Color.klmsMacWarningBorder
        }
    }
}

private struct CommandPanelView: View {
    let model: KLMSMacModel
    private let commands: [KLMSEngineCommand] = [.fullSync, .filesSync, .coreSync, .noticeSync]
    private let secondaryCommandColumns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 3)

    private var primaryCommand: KLMSEngineCommand {
        .fullSync
    }

    private var secondaryCommands: [KLMSEngineCommand] {
        commands.filter { $0 != primaryCommand }
    }

    var body: some View {
        SectionBox(title: "동기화") {
            VStack(alignment: .leading, spacing: 10) {
                MacMailPasteAnalyzerPanel(model: model, snapshot: model.snapshot)
                commandStatusStrip

                primaryCommandActionCard(primaryCommand)

                LazyVGrid(columns: secondaryCommandColumns, spacing: 8) {
                    ForEach(secondaryCommands, id: \.self) { command in
                        commandActionCard(command)
                    }
                }
            }

            if let command = model.runningCommand {
                Button(role: .destructive) {
                    Task {
                        await model.cancelRunningCommand()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                            .font(.caption.weight(.bold))
                        Text(model.isCancellingCommand ? "중단 요청 중..." : "\(command.displayName) 중단")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Color.klmsMacDangerBorder)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.klmsMacCommandButtonBackground.opacity(0.90), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.klmsMacDangerBorder.opacity(0.48), lineWidth: 1)
                    }
                }
                .buttonStyle(MacPressFeedbackButtonStyle())
                .disabled(model.isCancellingCommand)
                .accessibilityLabel("\(command.displayName) 중단")
                .accessibilityHint("현재 실행 중인 동기화를 중단합니다.")
            }
        }
    }

    private var commandStatusStrip: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: commandStatusImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(commandStatusColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(commandStatusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsMacPrimaryText)
                    .lineLimit(1)
                Text(commandStatusDetailText)
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacSubtleCardBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(commandStatusColor.opacity(model.runningCommand == nil ? 0.18 : 0.36), lineWidth: 1)
        }
    }

    private func primaryCommandActionCard(_ command: KLMSEngineCommand) -> some View {
        let isRunning = model.runningCommand == command
        let isDisabled = model.runningCommand != nil && !isRunning
        return Button {
            runOrCancel(command)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isRunning ? "전체 동기화 중단" : "전체 동기화")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                    if isRunning {
                        Text(model.currentPhaseText ?? "진행 상황을 확인 중입니다.")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .opacity(0.86)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: primaryCommandSystemImage(isRunning: isRunning, isDisabled: isDisabled))
                    .font(.headline.weight(.black))
            }
            .foregroundStyle(primaryCommandForeground(isDisabled: isDisabled))
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 15)
            .background(
                primaryCommandBackground(isRunning: isRunning, isDisabled: isDisabled),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(primaryCommandBorder(isRunning: isRunning, isDisabled: isDisabled), lineWidth: 1)
            }
        }
        .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 12, disabledOpacity: 1.0))
        .controlSize(.regular)
        .help(command.shortDescription)
        .accessibilityLabel("\(command.displayName) 실행")
        .accessibilityHint(command.shortDescription)
        .disabled(isDisabled)
    }

    private func commandActionCard(_ command: KLMSEngineCommand) -> some View {
        let isRunning = model.runningCommand == command
        let isDisabled = model.runningCommand != nil && !isRunning
        return Button {
            runOrCancel(command)
        } label: {
            HStack(spacing: 5) {
                if let systemImage = secondaryCommandSystemImage(isRunning: isRunning, isDisabled: isDisabled) {
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: .black, design: .rounded))
                }
                VStack(spacing: 2) {
                    Text(shortTitle(for: command))
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                    if isRunning {
                        Text(model.currentPhaseText ?? "진행 중")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .opacity(0.78)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            }
            .foregroundStyle(secondaryCommandForeground(isDisabled: isDisabled))
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            .padding(.horizontal, 8)
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
        .buttonStyle(MacPressFeedbackButtonStyle(disabledOpacity: 1.0))
        .controlSize(.small)
        .help(command.shortDescription)
        .accessibilityLabel("\(command.displayName) 실행")
        .accessibilityHint(command.shortDescription)
        .disabled(isDisabled)
    }

    private func runOrCancel(_ command: KLMSEngineCommand) {
        Task {
            if model.runningCommand == command {
                await model.cancelRunningCommand()
            } else {
                await model.run(command)
            }
        }
    }

    private func shortTitle(for command: KLMSEngineCommand) -> String {
        switch command {
        case .filesSync:
            return "파일"
        case .coreSync:
            return "과제/시험"
        case .noticeSync:
            return "공지"
        default:
            return command.displayName
        }
    }

    private func primaryCommandSystemImage(isRunning: Bool, isDisabled: Bool) -> String {
        if isRunning { return "stop.fill" }
        if isDisabled { return "lock.fill" }
        return "play.fill"
    }

    private func primaryCommandForeground(isDisabled: Bool) -> Color {
        isDisabled ? Color.klmsMacSecondaryText.opacity(0.76) : Color.klmsMacPrimaryCommandButtonForeground
    }

    private func primaryCommandBackground(isRunning: Bool, isDisabled: Bool) -> Color {
        if isDisabled { return Color.klmsMacSubtleCardBackground.opacity(0.86) }
        return isRunning ? Color.klmsMacPrimaryCommandButtonPressedBackground : Color.klmsMacPrimaryCommandButtonBackground
    }

    private func primaryCommandBorder(isRunning: Bool, isDisabled: Bool) -> Color {
        if isDisabled { return Color.klmsMacCommandButtonBorder.opacity(0.64) }
        return isRunning ? Color.klmsMacPrimaryCommandButtonBorder.opacity(0.78) : Color.klmsMacPrimaryCommandButtonBorder
    }

    private func secondaryCommandSystemImage(isRunning: Bool, isDisabled: Bool) -> String? {
        if isRunning { return "stop.fill" }
        if isDisabled { return "lock.fill" }
        return nil
    }

    private func secondaryCommandForeground(isDisabled: Bool) -> Color {
        isDisabled ? Color.klmsMacSecondaryText.opacity(0.64) : Color.klmsMacSecondaryCommandButtonForeground
    }

    private func secondaryCommandBackground(isRunning: Bool, isDisabled: Bool) -> Color {
        if isDisabled { return Color.klmsMacSubtleCardBackground.opacity(0.70) }
        return isRunning ? Color.klmsMacCommandButtonPressedBackground : Color.klmsMacCommandButtonBackground.opacity(0.88)
    }

    private func secondaryCommandBorder(isRunning: Bool, isDisabled: Bool) -> Color {
        if isDisabled { return Color.klmsMacCommandButtonBorder.opacity(0.54) }
        return Color.klmsMacCommandButtonBorder.opacity(isRunning ? 1.0 : 0.88)
    }

    private var commandStatusText: String {
        if let command = model.runningCommand {
            return "\(command.displayName) 진행 중"
        }
        if let result = model.lastCommandResult {
            if result.wasCancelled {
                return "최근 실행 중단됨"
            }
            return result.succeeded ? "최근 실행 완료" : "최근 실행 실패"
        }
        return model.snapshot.syncReport == nil ? "대기 중" : "준비됨"
    }

    private var commandStatusDetailText: String {
        if model.runningCommand != nil {
            return model.currentPhaseText.map { "현재 단계: \($0)" } ?? model.liveProgressLine ?? "실시간 로그를 기다리고 있습니다."
        }
        if let result = model.lastCommandResult {
            if result.wasCancelled {
                return "중단된 실행은 로그 탭에서 다시 확인할 수 있습니다."
            }
            return result.succeeded ? "필요하면 바로 다시 실행할 수 있습니다." : "진단 보기에서 마지막 오류를 확인하세요."
        }
        return "전체 동기화 또는 개별 동기화를 실행하세요."
    }

    private var commandStatusImage: String {
        if model.runningCommand != nil {
            return "arrow.triangle.2.circlepath"
        }
        if let result = model.lastCommandResult {
            if result.wasCancelled {
                return "stop.circle"
            }
            return result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        }
        return "clock"
    }

    private var commandStatusColor: Color {
        if model.runningCommand != nil {
            return .klmsMacCommandAccent
        }
        if let result = model.lastCommandResult {
            if result.wasCancelled {
                return .klmsMacSecondaryText
            }
            return result.succeeded ? Color.klmsMacSuccessBorder : Color.klmsMacWarningBorder
        }
        return .klmsMacSecondaryText
    }

}

private struct CommandStageDurationSummaryView: View {
    var durations: [KLMSStageDuration]

    var body: some View {
        if !durations.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("단계별 소요 시간")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsMacSecondaryText)
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
                                .foregroundStyle(Color.klmsMacSecondaryText)
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
            return .klmsMacWarningBorder
        case "notice":
            return .klmsMacCommandAccent
        case "files":
            return .klmsMacSecondaryText
        default:
            return .klmsMacSecondaryText
        }
    }
}

private struct MetricSectionGrid: View {
    var title: String?
    var metrics: [Metric]
    var selectedMetricID: String?
    var onSelect: (Metric) -> Void

    var body: some View {
        if !metrics.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let title {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .fontWeight(.semibold)
                }
                MetricGrid(metrics: metrics, selectedMetricID: selectedMetricID, onSelect: onSelect)
            }
        }
    }
}

private struct DashboardArchiveMetricSection: View {
    var metrics: [Metric]
    @Binding var isExpanded: Bool
    var selectedMetricID: String?
    var onSelect: (Metric) -> Void

    private var totalCount: Int {
        metrics.reduce(0) { $0 + $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .frame(width: 14)
                    Text("기록과 보관")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    Spacer(minLength: 8)
                    Text("\(totalCount)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.klmsMacSubtleCardBackground, in: Capsule())
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.klmsMacSubtleCardBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.klmsMacCommandBorder.opacity(0.62), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(MacPressFeedbackButtonStyle())
            .accessibilityLabel("기록과 보관 \(totalCount)개 \(isExpanded ? "펼쳐짐" : "접힘")")
            .accessibilityHint(isExpanded ? "기록과 보관 접기" : "기록과 보관 펼치기")

            if isExpanded {
                MetricGrid(metrics: metrics, selectedMetricID: selectedMetricID, onSelect: onSelect)
            }
        }
    }
}

private struct LoginPanelView: View {
    let model: KLMSMacModel

    var body: some View {
        SectionBox(title: "로그인") {
            let login = model.snapshot.loginStatus
            Text(login?.loggedIn == true ? "최근 로그인 확인됨" : "로그인 상태 미확인")
                .font(.caption)
                .foregroundStyle(login?.loggedIn == true ? Color.klmsMacSecondaryText : Color.klmsMacWarningBorder)
            if let checkedAt = login?.checkedAt {
                Text(checkedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(Color.klmsMacSecondaryText)
            }
            Text("인증 방식: \(loginAssistModeText)")
                .font(.caption)
                .foregroundStyle(Color.klmsMacSecondaryText)
            if let digits = model.currentAuthDigits {
                HStack(spacing: 8) {
                    Text("인증 번호")
                        .font(.caption)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    Text(digits)
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.klmsMacWarningBorder)
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
    @State private var isRemainingIssuesExpanded = false
    @State private var isAllChecksExpanded = false
    private let primaryVisibleIssueCount = 1

    var body: some View {
        if let verify = snapshot.verifyResult {
            SectionBox(title: "상태 검사") {
                let checkSummary = VerifyDiagnosticSummary(
                    checks: verify.checks,
                    primaryVisibleIssueCount: primaryVisibleIssueCount
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text(summaryText(for: verify, checkSummary: checkSummary))
                        .font(.caption)
                        .foregroundStyle(!checkSummary.hasIssues && verify.status.lowercased() == "ok" ? Color.klmsMacSecondaryText : Color.klmsMacWarningBorder)
                        .fixedSize(horizontal: false, vertical: true)

                    if !checkSummary.hasIssues {
                        Text("상태 검사에서 설명이 필요한 실패 항목이 없습니다.")
                            .font(.caption)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                    } else {
                        ForEach(checkSummary.primaryIssues) { check in
                            VerifyCheckExplanationRowView(check: check)
                        }
                        if !checkSummary.remainingIssues.isEmpty {
                            DiagnosticChecksDisclosure(
                                title: "나머지 확인 항목 \(checkSummary.remainingIssues.count)개",
                                isExpanded: $isRemainingIssuesExpanded
                            ) {
                                ForEach(checkSummary.remainingIssues) { check in
                                    VerifyCheckExplanationRowView(check: check, compact: true)
                                }
                            }
                        }
                    }

                    DiagnosticChecksDisclosure(
                        title: "전체 상태 검사 항목 \(verify.checks.count)개",
                        isExpanded: $isAllChecksExpanded
                    ) {
                        ForEach(verify.checks) { check in
                            VerifyCheckExplanationRowView(check: check, compact: true)
                        }
                    }
                }
            }
        }
    }

    private func summaryText(for verify: VerifyResult, checkSummary: VerifyDiagnosticSummary) -> String {
        if !checkSummary.hasIssues {
            return "상태: \(verify.status.klmsLocalizedStatus) · 정상 \(checkSummary.okCount)개"
        }
        return "상태: \(verify.status.klmsLocalizedStatus) · 확인 필요 \(checkSummary.issueCount)개 · 정상 \(checkSummary.okCount)개"
    }
}

private struct VerifyDiagnosticSummary {
    var primaryIssues: [VerifyCheck] = []
    var remainingIssues: [VerifyCheck] = []
    var okCount = 0

    init(checks: [VerifyCheck], primaryVisibleIssueCount: Int) {
        primaryIssues.reserveCapacity(primaryVisibleIssueCount)
        for check in checks {
            let normalizedStatus = check.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedStatus == "ok" {
                okCount += 1
            }
            guard ["fail", "failed", "error", "warn", "warning"].contains(normalizedStatus) else {
                continue
            }
            if primaryIssues.count < primaryVisibleIssueCount {
                primaryIssues.append(check)
            } else {
                remainingIssues.append(check)
            }
        }
    }

    var issueCount: Int {
        primaryIssues.count + remainingIssues.count
    }

    var hasIssues: Bool {
        issueCount > 0
    }
}

private struct VerifyCheckExplanationRowView: View {
    var check: VerifyCheck
    var compact = false
    @State private var isRawDetailExpanded = false
    @State private var isGuidanceExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !compact {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(isIssue ? 0.72 : 0.24))
                    .frame(width: 3)
            }
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Text("\(check.diagnosticTitle) · \(check.status.klmsLocalizedStatus)")
                    .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                if compact {
                    Text(rawDetail)
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(check.diagnosticExplanation)
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacPrimaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                    DiagnosticChecksDisclosure(
                        title: "원인과 조치 보기",
                        isExpanded: $isGuidanceExpanded,
                        compact: true
                    ) {
                        Text(check.diagnosticExplanation)
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacPrimaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(check.diagnosticNextAction)
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if !rawDetail.isEmpty {
                            DiagnosticChecksDisclosure(
                                title: "원본 보기",
                                isExpanded: $isRawDetailExpanded,
                                compact: true
                            ) {
                                Text(rawDetail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Color.klmsMacSecondaryText)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 1)
                }
            }
        }
        .padding(compact ? 6 : 9)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(compact ? 0.10 : (isIssue ? 0.34 : 0.18)), lineWidth: 1)
        }
    }

    private var rawDetail: String {
        check.detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isIssue: Bool {
        ["fail", "failed", "error", "warn", "warning"].contains(
            check.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
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
            return .klmsMacDangerBorder
        }
        if ["warn", "warning"].contains(check.status.lowercased()) {
            return .klmsMacWarningBorder
        }
        return .klmsMacSuccessBorder
    }
}

private struct DoctorPanelView: View {
    var snapshot: EngineSnapshot
    @State private var isRemainingIssuesExpanded = false
    @State private var isAllChecksExpanded = false
    private let primaryVisibleIssueCount = 1

    var body: some View {
        if let doctor = snapshot.doctorResult {
            SectionBox(title: "권한/환경 진단") {
                let checkSummary = DoctorDiagnosticSummary(
                    checks: doctor.checks,
                    primaryVisibleIssueCount: primaryVisibleIssueCount
                )
                Text(summaryText(for: doctor, checkSummary: checkSummary))
                    .font(.caption)
                    .foregroundStyle(!checkSummary.hasIssues && doctor.status.lowercased() == "ok" ? Color.klmsMacSecondaryText : Color.klmsMacWarningBorder)

                if !checkSummary.hasIssues {
                    Text("권한과 실행 환경에서 설명이 필요한 실패 항목이 없습니다.")
                        .font(.caption)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                } else {
                    ForEach(checkSummary.primaryIssues) { check in
                        DoctorCheckRowView(check: check)
                    }
                    if !checkSummary.remainingIssues.isEmpty {
                        DiagnosticChecksDisclosure(
                            title: "나머지 진단 항목 \(checkSummary.remainingIssues.count)개",
                            isExpanded: $isRemainingIssuesExpanded
                        ) {
                            ForEach(checkSummary.remainingIssues) { check in
                                DoctorCheckRowView(check: check, compact: true)
                            }
                        }
                    }
                }

                DiagnosticChecksDisclosure(
                    title: "전체 진단 항목 \(doctor.checks.count)개",
                    isExpanded: $isAllChecksExpanded
                ) {
                    ForEach(doctor.checks) { check in
                        DoctorCheckRowView(check: check, compact: true)
                    }
                }
            }
        }
    }

    private func summaryText(for doctor: DoctorResult, checkSummary: DoctorDiagnosticSummary) -> String {
        if !checkSummary.hasIssues {
            return "상태: \(doctor.status.klmsLocalizedStatus) · 정상 \(checkSummary.okCount)개"
        }
        return "상태: \(doctor.status.klmsLocalizedStatus) · 확인 필요 \(checkSummary.issueCount)개 · 정상 \(checkSummary.okCount)개"
    }
}

private struct DoctorDiagnosticSummary {
    var primaryIssues: [DoctorCheck] = []
    var remainingIssues: [DoctorCheck] = []
    var okCount = 0

    init(checks: [DoctorCheck], primaryVisibleIssueCount: Int) {
        primaryIssues.reserveCapacity(primaryVisibleIssueCount)
        for check in checks {
            let normalizedStatus = check.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedStatus == "ok" {
                okCount += 1
            }
            guard ["fail", "failed", "error", "warn", "warning"].contains(normalizedStatus) else {
                continue
            }
            if primaryIssues.count < primaryVisibleIssueCount {
                primaryIssues.append(check)
            } else {
                remainingIssues.append(check)
            }
        }
    }

    var issueCount: Int {
        primaryIssues.count + remainingIssues.count
    }

    var hasIssues: Bool {
        issueCount > 0
    }
}

private struct DiagnosticChecksDisclosure<Content: View>: View {
    var title: String
    @Binding var isExpanded: Bool
    var compact = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            Button {
                macPerformWithoutAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .frame(width: 12)
                    Text(title)
                        .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.klmsMacSecondaryText)
                .padding(.horizontal, compact ? 6 : 8)
                .padding(.vertical, compact ? 4 : 6)
                .frame(maxWidth: .infinity, minHeight: compact ? 36 : 44, alignment: .leading)
                .background(Color.klmsMacSubtleCardBackground.opacity(compact ? 0.18 : 0.30), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.klmsMacBorder.opacity(compact ? 0.20 : 0.34), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 7))
            .accessibilityLabel("\(title) \(isExpanded ? "펼쳐짐" : "접힘")")
            .accessibilityHint(isExpanded ? "\(title) 접기" : "\(title) 펼치기")

            if isExpanded {
                VStack(alignment: .leading, spacing: compact ? 5 : 6) {
                    content()
                }
                .padding(.top, compact ? 1 : 3)
            }
        }
        .padding(compact ? 0 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? Color.clear : Color.klmsMacSubtleCardBackground.opacity(0.34), in: RoundedRectangle(cornerRadius: 8))
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
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .textSelection(.enabled)
                        .lineLimit(compact ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(compact ? 6 : 8)
        .background(compact ? Color.klmsMacSubtleCardBackground : Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
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
            return .klmsMacDangerBorder
        }
        if ["warn", "warning"].contains(check.status.lowercased()) {
            return .klmsMacWarningBorder
        }
        return .klmsMacSuccessBorder
    }
}

private struct AppDiagnosticsPanelView: View {
    let model: KLMSMacModel
    @State private var isExpanded = false
    @State private var isPermissionScopeExpanded = false
    private let permissionActionColumns = [GridItem(.adaptive(minimum: 136), spacing: 8)]

    var body: some View {
        SectionBox(title: "앱/설치 정보") {
            let diagnostics = model.appDiagnostics
            HStack(spacing: 9) {
                Image(systemName: "app.badge.checkmark")
                    .foregroundStyle(diagnostics.codeSigning.needsAttention ? Color.klmsMacWarningBorder : Color.klmsMacSecondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(diagnostics.codeSigning.needsAttention ? "권한이나 서명 상태를 확인하세요." : "앱과 엔진 상태가 준비되어 있습니다.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.klmsMacPrimaryText)
                    Text(diagnostics.installedPayloadVersion.isEmpty ? "엔진 설치 상태 확인 필요" : "엔진 \(diagnostics.installedPayloadVersion)")
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))

            DiagnosticChecksDisclosure(
                title: "설치·권한 세부 정보",
                isExpanded: $isExpanded
            ) {
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

                    LazyVGrid(columns: permissionActionColumns, alignment: .leading, spacing: 8) {
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
                    }
                    .buttonStyle(KLMSMacRootActionButtonStyle())

                    if let permissionStatusMessage = model.permissionStatusMessage,
                       !permissionStatusMessage.isEmpty {
                        Text(permissionStatusMessage)
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacSecondaryText)
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

                    DiagnosticChecksDisclosure(
                        title: "필요 권한 범위",
                        isExpanded: $isPermissionScopeExpanded,
                        compact: true
                    ) {
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
                .padding(.top, 6)
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
                .foregroundStyle(Color.klmsMacSecondaryText)
                .padding(.top, 6)
            Text(text)
                .font(.caption2)
                .foregroundStyle(Color.klmsMacSecondaryText)
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
                .foregroundStyle(isWarning ? Color.klmsMacWarningBorder : Color.klmsMacSuccessBorder)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title): \(value)")
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
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

private enum RunLogArchiveList {
    static let initialVisibleLimit = 12
    static let increment = 18
}

private struct RunLogArchivePanelView: View {
    let model: KLMSMacModel
    @State private var filter = RunLogArchiveFilter.all
    @State private var isHistoryExpanded = false
    @State private var showingSystemLogs = false
    @State private var visibleLimit = RunLogArchiveList.initialVisibleLimit

    private var records: [CommandRunRecord] {
        model.commandHistory.records
    }

    private var filteredRecords: [CommandRunRecord] {
        records.filter { filter.includes($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        macPerformWithoutAnimation {
                            isHistoryExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(Color.klmsMacSecondaryText)
                            Text("실행 로그")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.klmsMacPrimaryText)
                            if !isHistoryExpanded {
                                Text("\(records.count)개")
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(Color.klmsMacSecondaryText)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.klmsMacSubtleCardBackground, in: Capsule())
                            }
                            Spacer(minLength: 8)
                            Image(systemName: isHistoryExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.klmsMacSecondaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MacPressFeedbackButtonStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())

                    Button(role: .destructive) {
                        model.clearExecutionRunLogs()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(KLMSMacRootActionButtonStyle(tone: .destructive))
                    .help("실행 로그 지우기")
                    .accessibilityLabel("실행 로그 지우기")
                    .disabled(model.runningCommand != nil || !model.hasClearableExecutionRunLogs)
                }

                if isHistoryExpanded {
                    let summary = RunLogArchiveSummary(records: records)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("각 실행 기록을 펼치면 마지막 로그를 볼 수 있습니다.")
                            .font(.caption)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                            RunLogStatChip(title: "전체", value: "\(summary.total)", systemImage: "tray.full", tint: .klmsMacCommandAccent)
                            RunLogStatChip(title: "성공", value: "\(summary.succeeded)", systemImage: "checkmark.circle", tint: Color.klmsMacSuccessBorder)
                            RunLogStatChip(title: "실패", value: "\(summary.needsAttention)", systemImage: "exclamationmark.triangle", tint: Color.klmsMacWarningBorder)
                            RunLogStatChip(title: "중단", value: "\(summary.cancelled)", systemImage: "stop.circle", tint: .klmsMacSecondaryText)
                        }

                        if let latest = records.first {
                            Text("최근 실행: \(latest.command.displayName) · \(latest.startedAt.formatted(date: .numeric, time: .shortened)) · \(latest.statusText)")
                                .font(.caption2)
                                .foregroundStyle(Color.klmsMacSecondaryText)
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
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.klmsMacBorder, lineWidth: 1)
            }

            CurrentRunLogCardView(model: model)

            if isHistoryExpanded {
                let filtered = filteredRecords
                let visible = filtered.prefix(visibleLimit)
                SectionBox(title: "\(filter.title) 기록") {
                    if filtered.isEmpty {
                        Text(emptyText)
                            .font(.caption)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(visible) { record in
                                RunLogArchiveRowView(record: record, model: model)
                            }
                            if filtered.count > visible.count {
                                Button {
                                    visibleLimit += RunLogArchiveList.increment
                                } label: {
                                    HStack {
                                        Text("더 보기")
                                            .font(.caption.weight(.semibold))
                                        Spacer()
                                        Text("남은 \(filtered.count - visible.count)개")
                                            .font(.caption2)
                                            .foregroundStyle(Color.klmsMacSecondaryText)
                                    }
                                    .padding(9)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(MacPressFeedbackButtonStyle())
                            }
                        }
                    }
                }
            }

            SectionBox(title: "서버 로그") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            macPerformWithoutAnimation {
                                showingSystemLogs.toggle()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Label("서버 로그 보기", systemImage: "network")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(systemLogSummary)
                                    .font(.caption2)
                                    .foregroundStyle(Color.klmsMacSecondaryText)
                                Image(systemName: showingSystemLogs ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.klmsMacSecondaryText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MacPressFeedbackButtonStyle())

                        Button(role: .destructive) {
                            model.clearLocalRelayLogs()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(KLMSMacRootActionButtonStyle(tone: .destructive))
                        .help("서버 로그 지우기")
                        .accessibilityLabel("서버 로그 지우기")
                        .disabled(!model.hasClearableLocalRelayLogs)
                    }

                    if showingSystemLogs {
                        VStack(alignment: .leading, spacing: 10) {
                            if !model.snapshot.relayLogTail.isEmpty {
                                Text("서버 릴레이 로그")
                                    .font(.caption.weight(.semibold))
                                LogTextBlock(text: model.snapshot.relayLogTail.klmsDisplayText)
                            }
                            if model.snapshot.relayLogTail.isEmpty {
                                Text("저장된 서버 로그가 아직 없습니다.")
                                    .font(.caption)
                                    .foregroundStyle(Color.klmsMacSecondaryText)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }
        }
        .onChange(of: filter) { _, _ in
            visibleLimit = RunLogArchiveList.initialVisibleLimit
        }
    }

    private var emptyText: String {
        if records.isEmpty {
            return "아직 저장된 실행 기록이 없습니다. 동기화나 진단을 실행하면 여기에 기록됩니다."
        }
        return "\(filter.title) 조건에 맞는 실행 기록이 없습니다."
    }

    private var systemLogSummary: String {
        let relayHasLog = !model.snapshot.relayLogTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return relayHasLog ? "서버" : "없음"
    }
}

private struct RunLogArchiveSummary {
    var total = 0
    var succeeded = 0
    var needsAttention = 0
    var cancelled = 0

    init(records: [CommandRunRecord]) {
        total = records.count
        for record in records {
            if record.succeeded {
                succeeded += 1
            }
            if record.needsAttention {
                needsAttention += 1
            }
            if record.wasCancelled {
                cancelled += 1
            }
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
                    .foregroundStyle(Color.klmsMacSecondaryText)
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
    let model: KLMSMacModel

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
                                .foregroundStyle(Color.klmsMacSecondaryText)
                        }
                    }
                    LogTextBlock(text: output)
                }
            }
        }
    }

    private var currentOutput: String {
        if !model.liveCommandOutput.isEmpty {
            return model.liveCommandOutput
        }
        return model.lastCommandDisplayOutput
    }

    private var statusText: String {
        if let command = model.runningCommand {
            if let phase = model.currentPhaseText {
                return "\(command.displayName) · \(phase) 진행 중"
            }
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
            return .klmsMacCommandAccent
        }
        if let result = model.lastCommandResult {
            if result.wasCancelled {
                return .klmsMacSecondaryText
            }
            return result.succeeded ? Color.klmsMacSuccessBorder : Color.klmsMacWarningBorder
        }
        return .klmsMacSecondaryText
    }

}

private struct RunLogArchiveRowView: View {
    var record: CommandRunRecord
    var model: KLMSMacModel
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                macPerformWithoutAnimation {
                    isExpanded.toggle()
                }
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
                                    .foregroundStyle(Color.klmsMacCommandAccent)
                                    .lineLimit(1)
                            }
                        }
                        Text("\(record.startedAt.formatted(date: .numeric, time: .shortened)) · \(record.elapsedSecondsText)")
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                        CompactStageDurationRowsView(durations: record.visibleStageDurations)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(record.statusText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.klmsMacSecondaryText)
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 8))
            .accessibilityLabel("\(record.command.displayName) 실행 로그 \(isExpanded ? "펼쳐짐" : "접힘")")
            .accessibilityHint(isExpanded ? "실행 로그 접기" : "실행 로그 펼치기")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label(record.command.isDiagnostic ? "진단 명령" : "동기화 명령", systemImage: record.command.isDiagnostic ? "wrench.and.screwdriver" : "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                        if record.dryRun {
                            Text("변경량 계산")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.klmsMacCommandAccent)
                        }
                        Spacer()
                        Text("종료 코드 \(record.exitCode)")
                            .font(.caption2)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                    }
                    if record.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("이 실행에는 저장된 로그가 없습니다.")
                            .font(.caption)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                    } else {
                        CommandStageDurationSummaryView(durations: record.visibleStageDurations)
                        LogTextBlock(text: record.outputTail)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 9)
            }
        }
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
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
            return .klmsMacSecondaryText
        }
        return record.succeeded ? .klmsMacSuccessBorder : .klmsMacWarningBorder
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
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }
}

private extension CommandRunRecord {
    var visibleStageDurations: [KLMSStageDuration] {
        stageDurations
    }
}

private struct IssueSummaryView: View {
    var issues: [EngineIssue]
    @State private var isExpanded = false
    @State private var isRemainingIssuesExpanded = false
    private let primaryVisibleIssueCount = 1
    private let remainingVisibleLimit = 3

    var body: some View {
        if !issues.isEmpty {
            let primaryIssues = Array(issues.prefix(primaryVisibleIssueCount))
            let remainingIssues = Array(issues.dropFirst(primaryVisibleIssueCount))
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.klmsMacWarningBorder)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(compactTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.klmsMacPrimaryText)
                                .lineLimit(1)
                            Text(issueSummaryText)
                                .font(.caption2)
                                .foregroundStyle(Color.klmsMacSecondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text("\(issues.count)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.klmsMacWarningBorder)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.klmsMacWarningBackground, in: Capsule())
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.klmsMacWarningBorder.opacity(0.24), lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(MacPressFeedbackButtonStyle())
                .accessibilityLabel("\(compactTitle) \(issues.count)개 \(isExpanded ? "펼쳐짐" : "접힘")")
                .accessibilityHint(isExpanded ? "확인 항목 접기" : "확인 항목 펼치기")

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(primaryIssues) { issue in
                            IssueRowView(issue: issue)
                        }
                        if !remainingIssues.isEmpty {
                            Button {
                                isRemainingIssuesExpanded.toggle()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isRemainingIssuesExpanded ? "chevron.down" : "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .frame(width: 12)
                                    Text("나머지 확인 항목 \(remainingIssues.count)개")
                                        .font(.caption2.weight(.semibold))
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(Color.klmsMacSecondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color.klmsMacSubtleCardBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(MacPressFeedbackButtonStyle())
                            .accessibilityLabel("나머지 확인 항목 \(remainingIssues.count)개 \(isRemainingIssuesExpanded ? "펼쳐짐" : "접힘")")
                            .accessibilityHint(isRemainingIssuesExpanded ? "나머지 확인 항목 접기" : "나머지 확인 항목 펼치기")

                            if isRemainingIssuesExpanded {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(remainingIssues.prefix(remainingVisibleLimit)) { issue in
                                        IssueRowView(issue: issue, compact: true)
                                    }
                                    if remainingIssues.count > remainingVisibleLimit {
                                        Text("나머지 \(remainingIssues.count - remainingVisibleLimit)개는 진단 화면에서 확인할 수 있습니다.")
                                            .font(.caption2)
                                            .foregroundStyle(Color.klmsMacSecondaryText)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var issueSummaryText: String {
        if issues.count == 1 {
            return "자세한 설명은 눌러서 펼치거나 진단 화면에서 확인하세요."
        }
        return "확인할 항목 \(issues.count)개 · 자세한 설명은 눌러서 펼치세요."
    }

    private var compactTitle: String {
        guard let first = issues.first else {
            return "확인이 필요합니다"
        }
        if first.title.hasPrefix("상태 검사") {
            return "상태 검사 실패"
        }
        if first.title.hasPrefix("권한") {
            return "권한 확인 필요"
        }
        return first.title
    }
}

private struct IssueRowView: View {
    var issue: EngineIssue
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(issue.severity.color.opacity(0.68))
                .frame(width: 3)
            Image(systemName: issue.severity.systemImage)
                .foregroundStyle(issue.severity.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsMacPrimaryText)
                    .lineLimit(compact ? 1 : 2)
                if !issue.detail.isEmpty {
                    Text(issue.detail)
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .textSelection(.enabled)
                        .lineLimit(compact ? 1 : 2)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(compact ? 7 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(issue.severity.color.opacity(0.30), lineWidth: 1)
        }
    }
}

private extension EngineIssue.Severity {
    var color: Color {
        switch self {
        case .warning:
            Color.klmsMacWarningBorder
        case .error:
            Color.klmsMacDangerBorder
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

private struct TopUtilityActionsView: View {
    let model: KLMSMacModel

    var body: some View {
        HStack(spacing: 8) {
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
                utilityLabel("바로가기", systemImage: "square.grid.2x2")
            }
        }
    }

    private func utilityLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.klmsMacPrimaryText)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.klmsMacSubtleCardBackground, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.klmsMacCommandBorder, lineWidth: 1)
            }
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
    @State private var hoveredMetricID: String?

    private var columns: [GridItem] {
        let count = min(max(metrics.count, 1), 4)
        return Array(
            repeating: GridItem(.flexible(minimum: 128), spacing: 8),
            count: count
        )
    }

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
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(metrics) { metric in
                let isInteractive = metric.detail != nil
                let isSelected = metric.detail?.rawValue == selectedMetricID
                let isHovered = hoveredMetricID == metric.id
                if let onSelect {
                    Button {
                        onSelect(metric)
                    } label: {
                        MetricTile(metric: metric, isSelected: isSelected, isHovered: isHovered && isInteractive)
                    }
                    .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 13))
                    .disabled(!isInteractive)
                    .accessibilityLabel("\(metric.label) \(metric.value)개")
                    .accessibilityValue(isSelected ? "선택됨" : "선택 안 됨")
                    .accessibilityHint(isInteractive ? "\(metric.label) 상세를 엽니다." : "현재 상태만 표시합니다.")
                    .onHover { hovering in
                        hoveredMetricID = hovering && isInteractive ? metric.id : (hoveredMetricID == metric.id ? nil : hoveredMetricID)
                    }
                } else {
                    MetricTile(metric: metric, isSelected: false, isHovered: false)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(metric.label) \(metric.value)개")
                }
            }
        }
    }
}

private struct MetricTile: View {
    var metric: Metric
    var isSelected: Bool
    var isHovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(metric.value)")
                        .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(isSelected ? Color.klmsMacSelectedForeground : Color.klmsMacPrimaryText)
                    Text(metric.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Spacer(minLength: 0)
                if metric.detail != nil {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? tint : (isHovered ? Color.klmsMacPrimaryText : Color.klmsMacSecondaryText.opacity(0.70)))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .padding(10)
        .background(metricBackground, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(metricBorder, lineWidth: isSelected ? 1.4 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 13))
    }

    private var metricBackground: Color {
        if isSelected {
            return Color.klmsMacSelectedBackground
        }
        return isHovered ? Color.klmsMacSubtleCardBackground.opacity(0.64) : Color.klmsMacCardBackground
    }

    private var metricBorder: Color {
        if isSelected {
            return tint.opacity(0.92)
        }
        return isHovered ? Color.klmsMacCommandBorder.opacity(0.78) : Color.klmsMacBorder
    }

    private var tint: Color {
        switch metric.detail {
        case .assignments, .assignmentCandidates:
            return .klmsMacWarningBorder
        case .exams, .examCandidates, .calendar:
            return .klmsMacSuccessBorder
        case .notices:
            return .klmsMacCommandAccent
        case .files, .missingFiles, .newFiles:
            return .klmsMacSecondaryText
        case .quarantine, .pruned:
            return .klmsMacDangerBorder
        case .helpDesk:
            return .klmsMacCommandAccent
        case .hidden:
            return .klmsMacSecondaryText
        case nil:
            return .klmsMacCommandAccent
        }
    }
}

struct SectionBox<Content: View>: View {
    var title: String
    var backgroundColor: Color = .klmsMacCardBackground
    var borderColor: Color = .klmsMacBorder
    var titleColor: Color = .klmsMacPrimaryText
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(titleColor)
            VStack(alignment: .leading, spacing: 9) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(borderColor.opacity(0.78), lineWidth: 1)
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
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                    }
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.klmsMacPrimaryText)
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.klmsMacSecondaryText)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Color.klmsMacSubtleCardBackground.opacity(0.52), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.klmsMacBorder.opacity(0.58), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: 10))
            .accessibilityLabel("\(title) \(isExpanded ? "펼쳐짐" : "접힘")")
            .accessibilityHint(isExpanded ? "\(title) 접기" : "\(title) 펼치기")
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10))

            if isExpanded {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Color {
    static func klmsMacAdaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            klmsMacIsDark(appearance) ? dark : light
        })
    }

    static func klmsMacIsDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static var klmsMacScreenBackground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.973, green: 0.969, blue: 0.949, alpha: 1.0),
            dark: NSColor(red: 0.063, green: 0.063, blue: 0.059, alpha: 1.0)
        )
    }

    static var klmsMacSidebarBackground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.949, green: 0.941, blue: 0.914, alpha: 1.0),
            dark: NSColor(red: 0.078, green: 0.078, blue: 0.073, alpha: 1.0)
        )
    }

    static var klmsMacCardBackground: Color {
        klmsMacAdaptiveColor(
            light: NSColor.white,
            dark: NSColor(red: 0.114, green: 0.114, blue: 0.106, alpha: 1.0)
        )
    }

    static var klmsMacSubtleCardBackground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.925, green: 0.914, blue: 0.875, alpha: 1.0),
            dark: NSColor(red: 0.176, green: 0.169, blue: 0.153, alpha: 1.0)
        )
    }

    static var klmsMacHeroBackground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.925, green: 0.914, blue: 0.875, alpha: 1.0),
            dark: NSColor(red: 0.176, green: 0.169, blue: 0.153, alpha: 1.0)
        )
    }

    static var klmsMacCommandAccent: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 1.0),
            dark: NSColor(red: 0.941, green: 0.875, blue: 0.722, alpha: 1.0)
        )
    }

    static var klmsMacPrimaryText: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.090, green: 0.086, blue: 0.075, alpha: 1.0),
            dark: NSColor(red: 0.969, green: 0.953, blue: 0.918, alpha: 1.0)
        )
    }

    static var klmsMacSecondaryText: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.427, green: 0.404, blue: 0.365, alpha: 1.0),
            dark: NSColor(red: 0.741, green: 0.710, blue: 0.655, alpha: 1.0)
        )
    }

    static var klmsMacCommandBackground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.925, green: 0.914, blue: 0.875, alpha: 1.0),
            dark: NSColor(red: 0.176, green: 0.169, blue: 0.153, alpha: 1.0)
        )
    }

    static var klmsMacCommandBorder: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.843, green: 0.820, blue: 0.769, alpha: 1.0),
            dark: NSColor(white: 1.0, alpha: 0.160)
        )
    }

    static var klmsMacCommandButtonBackground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.925, green: 0.914, blue: 0.875, alpha: 1.0),
            dark: NSColor(red: 0.176, green: 0.169, blue: 0.153, alpha: 1.0)
        )
    }

    static var klmsMacCommandButtonPressedBackground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.812, green: 0.788, blue: 0.718, alpha: 1.0),
            dark: NSColor(red: 0.318, green: 0.298, blue: 0.251, alpha: 1.0)
        )
    }

    static var klmsMacCommandButtonPressedOverlay: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 0.105),
            dark: NSColor(red: 0.941, green: 0.875, blue: 0.722, alpha: 0.140)
        )
    }

    static var klmsMacSelectedBackground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.894, green: 0.878, blue: 0.827, alpha: 1.0),
            dark: NSColor(red: 0.224, green: 0.212, blue: 0.184, alpha: 1.0)
        )
    }

    static var klmsMacSelectedBorder: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 0.56),
            dark: NSColor(red: 0.941, green: 0.875, blue: 0.722, alpha: 0.48)
        )
    }

    static var klmsMacSelectedForeground: Color {
        klmsMacPrimaryText
    }

    static var klmsMacPrimaryCommandButtonBackground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 1.0),
            dark: NSColor(red: 0.941, green: 0.875, blue: 0.722, alpha: 1.0)
        )
    }

    static var klmsMacPrimaryCommandButtonPressedBackground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.285, green: 0.282, blue: 0.258, alpha: 1.0),
            dark: NSColor(red: 0.800, green: 0.729, blue: 0.553, alpha: 1.0)
        )
    }

    static var klmsMacCommandButtonForeground: Color {
        klmsMacPrimaryCommandButtonForeground
    }

    static var klmsMacPrimaryCommandButtonForeground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 1.000, green: 0.980, blue: 0.941, alpha: 1.0),
            dark: NSColor(red: 0.082, green: 0.075, blue: 0.055, alpha: 1.0)
        )
    }

    static var klmsMacDangerCommandButtonForeground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 1.000, green: 0.980, blue: 0.941, alpha: 1.0),
            dark: NSColor(red: 1.000, green: 0.980, blue: 0.941, alpha: 1.0)
        )
    }

    static var klmsMacSecondaryCommandButtonForeground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.090, green: 0.086, blue: 0.075, alpha: 1.0),
            dark: NSColor(red: 0.969, green: 0.953, blue: 0.918, alpha: 1.0)
        )
    }

    static var klmsMacPrimaryCommandButtonBorder: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.165, green: 0.165, blue: 0.153, alpha: 1.0),
            dark: NSColor(red: 0.784, green: 0.722, blue: 0.573, alpha: 1.0)
        )
    }

    static var klmsMacCommandButtonBorder: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.843, green: 0.820, blue: 0.769, alpha: 1.0),
            dark: NSColor(white: 1.0, alpha: 0.160)
        )
    }

    static var klmsMacSubtleAccentBackground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.894, green: 0.879, blue: 0.828, alpha: 1.0),
            dark: NSColor(red: 0.220, green: 0.207, blue: 0.180, alpha: 1.0)
        )
    }

    static var klmsMacWarningBackground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.953, green: 0.932, blue: 0.875, alpha: 1.0),
            dark: NSColor(red: 0.235, green: 0.198, blue: 0.122, alpha: 1.0)
        )
    }

    static var klmsMacWarningBorder: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.784, green: 0.722, blue: 0.573, alpha: 1.0),
            dark: NSColor(red: 0.470, green: 0.376, blue: 0.192, alpha: 1.0)
        )
    }

    static var klmsMacDangerBackground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.965, green: 0.928, blue: 0.916, alpha: 1.0),
            dark: NSColor(red: 0.250, green: 0.132, blue: 0.116, alpha: 1.0)
        )
    }

    static var klmsMacDangerBorder: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.745, green: 0.395, blue: 0.340, alpha: 1.0),
            dark: NSColor(red: 0.520, green: 0.220, blue: 0.190, alpha: 1.0)
        )
    }

    static var klmsMacSuccessBackground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.920, green: 0.945, blue: 0.902, alpha: 1.0),
            dark: NSColor(red: 0.130, green: 0.205, blue: 0.138, alpha: 1.0)
        )
    }

    static var klmsMacSuccessBorder: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.492, green: 0.616, blue: 0.400, alpha: 1.0),
            dark: NSColor(red: 0.292, green: 0.445, blue: 0.270, alpha: 1.0)
        )
    }

    static var klmsMacBorder: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.843, green: 0.820, blue: 0.769, alpha: 1.0),
            dark: NSColor(white: 1.0, alpha: 0.105)
        )
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
