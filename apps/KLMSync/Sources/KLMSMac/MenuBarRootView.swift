import KLMSShared
import AppKit
import SwiftUI

struct MenuBarRootView: View {
    @ObservedObject var model: KLMSMacModel
    @AppStorage(MacFirstRunReadiness.storageKey) private var firstRunReadinessCompleted = false
    @State private var selectedSection = KLMSMacSection.dashboard
    @State private var scrollResetNonce = 0
    @State private var expandedLogSummaryKind: LogSummaryKind?
    @State private var didRequestInitialServerRefresh = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            DashboardFileDataPrewarmView(
                snapshot: model.snapshot,
                signature: model.dashboardFileRenderSignature,
                serverItems: model.dashboardServerRelayItems(for: .files)
            )

            GeometryReader { proxy in
                let metrics = MacWorkspaceLayoutPolicy.metrics(for: proxy.size.width)
                HStack(alignment: .top, spacing: 0) {
                    navigationColumn(metrics: metrics)
                    mainWorkspace(metrics: metrics)
                        .frame(width: metrics.workspaceWidth, alignment: .topLeading)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .accessibilityIdentifier("workspace-layout-mode-\(metrics.contentMode.rawValue)")
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(.klmsMacCommandAccent)
        .background(Color.klmsMacScreenBackground)
        .onChange(of: selectedSection) { _, section in
            if model.snapshot.syncReport == nil, (section == .diagnostics || section == .settings) {
                firstRunReadinessCompleted = true
            }
        }
        .onChange(of: model.snapshot.syncReport != nil) { _, hasSyncReport in
            if hasSyncReport {
                firstRunReadinessCompleted = true
            }
        }
        .task {
            guard !didRequestInitialServerRefresh else { return }
            didRequestInitialServerRefresh = true
            await model.refreshServerRelayDashboardNow(silent: true)
        }
    }

    @ViewBuilder
    private func navigationColumn(metrics: MacWorkspaceLayoutMetrics) -> some View {
        if metrics.navigationMode == .compact {
            MacWorkspaceNavigationTransitionView(
                width: metrics.navigationColumnWidth,
                selectedSection: selectedSection
            )
        } else {
            let navigationContentWidth = max(0, metrics.navigationColumnWidth - 1)
            HStack(alignment: .top, spacing: 0) {
                if metrics.navigationMode == .rail {
                    MacWorkspaceSidebarView(
                        model: model,
                        selectedSection: $selectedSection,
                        resetCurrentSectionScroll: resetCurrentSectionScroll,
                        iconOnly: true,
                        showsRuntimePanel: false,
                        showsNavigationChevron: false
                    )
                    .frame(width: navigationContentWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    MacWorkspaceSidebarView(
                        model: model,
                        selectedSection: $selectedSection,
                        resetCurrentSectionScroll: resetCurrentSectionScroll,
                        iconOnly: false,
                        showsRuntimePanel: navigationContentWidth >= 220,
                        showsNavigationChevron: navigationContentWidth >= 180
                    )
                    .frame(width: navigationContentWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                Rectangle()
                    .fill(Color.klmsMacBorder.opacity(0.76))
                    .frame(width: 1)
            }
            .frame(width: metrics.navigationColumnWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityIdentifier("workspace-navigation-mode-\(metrics.navigationMode.rawValue)")
        }
    }

    private func mainWorkspace(metrics: MacWorkspaceLayoutMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            Color.klmsMacScreenBackground
            VStack(spacing: 0) {
                if metrics.navigationMode == .compact {
                    MacCompactWorkspaceMenu(
                        selectedSection: $selectedSection,
                        resetCurrentSectionScroll: resetCurrentSectionScroll
                    )
                }
                MacAlertBannerView(
                    model: model,
                    selectedSection: $selectedSection,
                    expandedLogSummaryKind: $expandedLogSummaryKind,
                    firstRunReadinessCompleted: $firstRunReadinessCompleted
                )

                DashboardTopBarView(
                    model: model,
                    selectedSection: $selectedSection,
                    layoutMode: metrics.contentMode
                )
                .padding(.horizontal, metrics.horizontalContentPadding)
                .padding(.top, KLMSSpacing.compact)
                .padding(.bottom, KLMSSpacing.comfortable)
                .frame(width: metrics.documentWidth, alignment: .leading)
                .background(Color.klmsMacScreenBackground)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.klmsMacBorder.opacity(0.58))
                        .frame(height: 1)
                }

                MacStableWorkspacePane(section: selectedSection) {
                    WholeScreenVerticalScrollView(
                        resetID: MacWorkspaceScrollResetKey(section: selectedSection, nonce: scrollResetNonce),
                        viewportWidth: metrics.documentWidth,
                        accessibilityIdentifier: "workspace-scroll-\(selectedSection.rawValue)"
                    ) {
                        VStack(alignment: .leading, spacing: 0) {
                            MacWorkstationLayoutView(
                                model: model,
                                selectedSection: selectedSection,
                                layoutMode: metrics.contentMode,
                                expandedLogSummaryKind: $expandedLogSummaryKind,
                                openRunLog: openRunLog
                            )
                        }
                        .padding(.horizontal, metrics.horizontalContentPadding)
                        .padding(.top, KLMSSpacing.comfortable)
                        .padding(.bottom, KLMSSpacing.spacious)
                        .frame(width: metrics.documentWidth, alignment: .topLeading)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("workspace-content-root-\(selectedSection.rawValue)")
                    }
                    .frame(width: metrics.documentWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(width: metrics.documentWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .frame(width: metrics.workspaceWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private func openRunLog() {
        macPerformWithoutAnimation {
            expandedLogSummaryKind = .run
            selectedSection = .activityLogs
        }
    }

    private func resetCurrentSectionScroll() {
        scrollResetNonce &+= 1
    }
}

private enum MacFirstRunReadiness {
    static let storageKey = "KLMSMacFirstRunReadinessCompleted"
}

private struct MacWorkspaceNavigationTransitionView: View {
    var width: CGFloat
    var selectedSection: KLMSMacSection

    var body: some View {
        ZStack(alignment: .top) {
            Color.klmsMacSidebarBackground
            if width >= 28 {
                Image(systemName: selectedSection.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .frame(width: min(30, width), height: 30)
                    .background(
                        Color.klmsMacSelectedBackground.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: min(8, max(2, width / 5)))
                    )
                    .padding(.top, KLMSSpacing.spacious)
                    .transition(.identity)
            } else if width > 0 {
                Capsule()
                    .fill(Color.klmsMacSelectedBorder.opacity(0.72))
                    .frame(width: min(3, width), height: 42)
                    .padding(.top, KLMSSpacing.spacious)
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct MacStableWorkspacePane<Content: View>: View {
    var section: KLMSMacSection
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.klmsMacScreenBackground
                .ignoresSafeArea()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}


private struct MacPressFeedbackButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10
    var disabledOpacity: Double = 0.48
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minHeight: KLMSControlSize.minimumInteractive)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1.0)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.klmsMacCommandButtonPressedOverlay.opacity(configuration.isPressed && isEnabled ? 0.18 : 0.0))
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1.0 : disabledOpacity)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct DeferredMacInteractionExpansion<Content: View>: View {
    var isExpanded: Bool
    private let content: () -> Content
    @State private var shouldRender: Bool

    init(
        isExpanded: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isExpanded = isExpanded
        self.content = content
        _shouldRender = State(initialValue: isExpanded)
    }

    var body: some View {
        Group {
            if isExpanded, shouldRender {
                content()
            }
        }
        .onAppear {
            shouldRender = isExpanded
        }
        .onChange(of: isExpanded) { _, expanded in
            shouldRender = expanded
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private enum MacWorkspacePanelTiming {
    static let deferredContentDelayNanoseconds: UInt64 = 90_000_000
    static let heavyListContentDelayNanoseconds: UInt64 = 260_000_000
}

private struct DeferredMacWorkspacePanel<Content: View>: View {
    var id: String
    var deferContent: Bool
    var contentDelayNanoseconds: UInt64
    private let content: () -> Content
    @State private var isContentReady = false
    @State private var contentTask: Task<Void, Never>?

    init(
        id: String,
        deferContent: Bool = true,
        contentDelayNanoseconds: UInt64 = MacWorkspacePanelTiming.deferredContentDelayNanoseconds,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.id = id
        self.deferContent = deferContent
        self.contentDelayNanoseconds = contentDelayNanoseconds
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
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

    private func prepareContentIfNeeded() {
        guard deferContent else {
            isContentReady = true
            return
        }
        guard !isContentReady else { return }
        contentTask?.cancel()
        contentTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: contentDelayNanoseconds)
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
        HStack(spacing: KLMSSpacing.comfortable) {
            ProgressView()
                .controlSize(.small)
            Text("화면을 준비하는 중입니다.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.klmsMacSecondaryText)
        }
        .padding(KLMSSpacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.control))
        .overlay {
            RoundedRectangle(cornerRadius: KLMSRadius.control)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
        .accessibilityLabel("화면을 준비하는 중입니다.")
    }
}

private struct MacWorkstationLayoutView: View {
    let model: KLMSMacModel
    let selectedSection: KLMSMacSection
    let layoutMode: AdaptiveLayoutMode
    @Binding var expandedLogSummaryKind: LogSummaryKind?
    var openRunLog: () -> Void

    var body: some View {
        workspace
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .layoutPriority(1)
    }

    @ViewBuilder
    private var workspace: some View {
        VStack(alignment: .leading, spacing: KLMSSpacing.spacious) {
            switch selectedSection {
            case .dashboard:
                DeferredMacWorkspacePanel(id: "workspace-dashboard", deferContent: false) {
                    MacDashboardCommandCenterView(
                        model: model,
                        layoutMode: layoutMode,
                        openRunLog: openRunLog
                    )
                }
            case .files:
                DeferredMacWorkspacePanel(
                    id: "workspace-files",
                    contentDelayNanoseconds: MacWorkspacePanelTiming.heavyListContentDelayNanoseconds
                ) {
                    cachedDashboardDetailPanel(kind: .files)
                        .equatable()
                }
            case .tasks:
                DeferredMacWorkspacePanel(
                    id: "workspace-tasks",
                    contentDelayNanoseconds: MacWorkspacePanelTiming.heavyListContentDelayNanoseconds
                ) {
                    TaskAndExamWorkspaceView(model: model)
                }
            case .notices:
                DeferredMacWorkspacePanel(id: "workspace-notices") {
                    cachedDashboardDetailPanel(kind: .notices)
                        .equatable()
                }
            case .calendar:
                DeferredMacWorkspacePanel(id: "workspace-calendar") {
                    cachedDashboardDetailPanel(kind: .calendar)
                        .equatable()
                }
            case .activityLogs:
                DeferredMacWorkspacePanel(
                    id: "workspace-activityLogs",
                    contentDelayNanoseconds: MacWorkspacePanelTiming.heavyListContentDelayNanoseconds
                ) {
                    VStack(alignment: .leading, spacing: KLMSSpacing.spacious) {
                        LogSummaryPanelView(
                            model: model,
                            expandedKind: $expandedLogSummaryKind,
                            layoutMode: layoutMode
                        )
                        DiagnosticStageDurationPanelView(model: model)
                        RemoteActivityPanelView(model: model)
                        RunLogArchivePanelView(model: model)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            case .diagnostics:
                DeferredMacWorkspacePanel(
                    id: "workspace-diagnostics",
                    contentDelayNanoseconds: MacWorkspacePanelTiming.heavyListContentDelayNanoseconds
                ) {
                    VStack(alignment: .leading, spacing: KLMSSpacing.spacious) {
                        VerifyPanelView(snapshot: model.snapshot)
                        DiagnosticToolsPanelView(model: model)
                        DoctorPanelView(snapshot: model.snapshot)
                        AppDiagnosticsPanelView(model: model)
                        LoginPanelView(model: model)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            case .settings:
                DeferredMacWorkspacePanel(
                    id: "workspace-settings",
                    contentDelayNanoseconds: MacWorkspacePanelTiming.heavyListContentDelayNanoseconds
                ) {
                    SettingsView(model: model)
                }
            }
        }
        .padding(.vertical, KLMSSpacing.tight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-container-\(selectedSection.rawValue)")
    }

    private func cachedDashboardDetailPanel(kind: DashboardDetailKind) -> DashboardDetailPanelView {
        DashboardDetailPanelView(
            kind: kind,
            model: model,
            snapshot: model.snapshot,
            renderSignature: model.dashboardRenderSignature,
            fileRenderSignature: model.dashboardFileRenderSignature,
            filterOptions: model.dashboardFilterOptions(for: kind),
            viewRevision: model.dashboardViewRevision
        )
    }
}

private struct MacDashboardCommandCenterLayout: Layout {
    var isWide: Bool
    var spacing: CGFloat = KLMSSpacing.spacious

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count >= 2 else {
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        if isWide {
            let commandSize = subviews[0].sizeThatFits(
                ProposedViewSize(width: 320, height: proposal.height)
            )
            let dashboardProposalWidth = proposal.width.map { max(0, $0 - 320 - spacing) }
            let dashboardSize = subviews[1].sizeThatFits(
                ProposedViewSize(width: dashboardProposalWidth, height: proposal.height)
            )
            return CGSize(
                width: proposal.width ?? (commandSize.width + spacing + dashboardSize.width),
                height: max(commandSize.height, dashboardSize.height)
            )
        }

        let commandSize = subviews[0].sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil)
        )
        let dashboardSize = subviews[1].sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil)
        )
        return CGSize(
            width: proposal.width ?? max(commandSize.width, dashboardSize.width),
            height: commandSize.height + spacing + dashboardSize.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count >= 2 else { return }
        if isWide {
            let dashboardWidth = max(0, bounds.width - 320 - spacing)
            subviews[0].place(
                at: bounds.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: 320, height: nil)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX + 320 + spacing, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: dashboardWidth, height: nil)
            )
            return
        }

        let commandSize = subviews[0].sizeThatFits(
            ProposedViewSize(width: bounds.width, height: nil)
        )
        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + commandSize.height + spacing),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}

private struct MacDashboardCommandCenterView: View {
    @ObservedObject var model: KLMSMacModel
    var layoutMode: AdaptiveLayoutMode
    var openRunLog: () -> Void

    var body: some View {
        MacDashboardCommandCenterLayout(isWide: layoutMode == .wide) {
            commandColumn
                .frame(width: layoutMode == .wide ? 320 : nil, alignment: .topLeading)
                .layoutPriority(1)
            dashboardColumn
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .layoutPriority(2)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var commandColumn: some View {
        VStack(alignment: .leading, spacing: KLMSSpacing.spacious) {
            CommandPanelView(model: model, openRunLog: openRunLog)
            DashboardCommandCenterStatusCard(model: model, openRunLog: openRunLog)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard-command-column")
    }

    private var dashboardColumn: some View {
        DashboardSummaryView(model: model)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("dashboard-summary-column")
    }
}

private struct DashboardCommandCenterStatusCard: View {
    @ObservedObject var model: KLMSMacModel
    var openRunLog: () -> Void

    var body: some View {
        SectionBox(title: "현재 작업") {
            VStack(alignment: .leading, spacing: KLMSSpacing.comfortable) {
                HStack(alignment: .top, spacing: KLMSSpacing.comfortable) {
                    Image(systemName: statusImage)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(statusColor)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: KLMSSpacing.micro) {
                        Text(statusTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.klmsMacPrimaryText)
                        Text(statusDetail)
                            .font(.caption)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                Button(action: openRunLog) {
                    Label("실행 로그 보기", systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KLMSMacRootActionButtonStyle())
                .disabled(!canOpenRunLog)
                .accessibilityLabel("실행 로그 보기")
                .accessibilityHint("최근 실행 로그 탭으로 이동합니다.")
            }
        }
    }

    private var canOpenRunLog: Bool {
        model.runningCommand != nil || model.lastCommandResult != nil || !model.commandHistory.records.isEmpty
    }

    private var statusTitle: String {
        if let command = model.runningCommand {
            return "\(command.displayName) 진행 중"
        }
        if let result = model.lastCommandResult {
            if result.wasCancelled {
                return "마지막 실행이 중단됨"
            }
            return result.succeeded ? "마지막 실행 완료" : "마지막 실행 실패"
        }
        return "실행 대기 중"
    }

    private var statusDetail: String {
        if model.runningCommand != nil {
            let phase = (model.currentPhaseText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return phase.isEmpty ? "현재 단계를 확인하는 중입니다." : phase
        }
        if let result = model.lastCommandResult {
            let duration = max(0, Int(result.finishedAt.timeIntervalSince(result.startedAt).rounded()))
            let suffix = duration > 0 ? " · \(duration)초" : ""
            return "\(result.finishedAt.formatted(date: .omitted, time: .shortened))\(suffix)"
        }
        return "전체 동기화를 시작하면 진행 상황과 단계별 로그가 여기에 표시됩니다."
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
            return result.succeeded ? Color.klmsMacSuccessForeground : Color.klmsMacWarningForeground
        }
        return .klmsMacSecondaryText
    }
}

private struct MacWorkspaceSidebarView: View {
    let model: KLMSMacModel
    @Binding var selectedSection: KLMSMacSection
    var resetCurrentSectionScroll: () -> Void
    var iconOnly = false
    var showsRuntimePanel = true
    var showsNavigationChevron = true

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: iconOnly ? .center : .leading, spacing: KLMSSpacing.roomy) {
                if !iconOnly {
                    VStack(alignment: .leading, spacing: KLMSSpacing.snug) {
                        Text("KLMS Sync")
                            .font(.system(size: KLMSTypeSize.sectionIcon, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.klmsMacPrimaryText)
                        Text("작업 공간")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.klmsMacSecondaryText)
                    }
                    .padding(.horizontal, KLMSSpacing.compact)
                }

                WorkspaceNavigationView(
                    selection: $selectedSection,
                    resetCurrentSectionScroll: resetCurrentSectionScroll,
                    iconOnly: iconOnly,
                    showsChevron: showsNavigationChevron
                )
                .frame(width: iconOnly ? 48 : nil)

                if !iconOnly, showsRuntimePanel {
                    DashboardRuntimePanelView(model: model)
                }
            }
            .padding(.horizontal, iconOnly ? KLMSSpacing.standard : KLMSSpacing.roomy)
            .padding(.vertical, KLMSSpacing.spacious)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.klmsMacSidebarBackground)
    }
}

private struct WorkspaceNavigationView: View {
    @Binding var selection: KLMSMacSection
    var resetCurrentSectionScroll: () -> Void
    var iconOnly = false
    var showsChevron = true
    @State private var hoveredSection: KLMSMacSection?

    var body: some View {
        VStack(spacing: KLMSSpacing.compactControl) {
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
                    HStack(spacing: iconOnly ? 0 : KLMSSpacing.comfortable) {
                        ZStack {
                            RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                                .fill(iconBackground(isSelected: isSelected, isHovered: isHovered))
                            Image(systemName: section.systemImage)
                                .font(.subheadline.weight(isSelected ? .bold : .semibold))
                                .foregroundStyle(isSelected ? Color.klmsMacSelectedForeground : Color.klmsMacSecondaryText.opacity(0.84))
                        }
                        .frame(width: 30, height: 30)
                        if !iconOnly {
                            Text(section.title)
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Color.klmsMacSelectedForeground : Color.klmsMacPrimaryText)
                            Spacer(minLength: 0)
                            if showsChevron {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(isSelected ? Color.klmsMacSelectedBorder : Color.klmsMacSecondaryText.opacity(0.52))
                            }
                        }
                    }
                    .padding(.horizontal, iconOnly ? KLMSSpacing.standard : KLMSSpacing.comfortable)
                    .padding(.vertical, KLMSSpacing.standardControl)
                    .frame(maxWidth: .infinity, minHeight: KLMSControlSize.minimumInteractive, alignment: .leading)
                    .background(
                        rowBackground(isSelected: isSelected, isHovered: isHovered),
                        in: RoundedRectangle(cornerRadius: KLMSRadius.card)
                    )
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: KLMSRadius.indicator)
                            .fill(isSelected ? Color.klmsMacSelectedBorder : Color.clear)
                            .frame(width: isSelected ? 4 : 0)
                            .padding(.vertical, KLMSSpacing.standardControl)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: KLMSRadius.card)
                            .stroke(rowBorder(isSelected: isSelected, isHovered: isHovered), lineWidth: isSelected ? 1.4 : 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.card))
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
                .help(section.title)
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

private struct MacCompactWorkspaceMenu: View {
    @Binding var selectedSection: KLMSMacSection
    var resetCurrentSectionScroll: () -> Void

    var body: some View {
        HStack(spacing: KLMSSpacing.comfortable) {
            Menu {
                ForEach(KLMSMacSection.allCases) { section in
                    Button {
                        if selectedSection == section {
                            resetCurrentSectionScroll()
                        } else {
                            selectedSection = section
                        }
                    } label: {
                        Label(section.title, systemImage: section.systemImage)
                    }
                    .accessibilityLabel(section.title)
                    .accessibilityValue(selectedSection == section ? "선택됨" : "선택 안 됨")
                    .accessibilityIdentifier("workspace-compact-\(section.rawValue)")
                }
            } label: {
                Label(selectedSection.title, systemImage: "line.3.horizontal")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("작업 공간 메뉴")
            .accessibilityValue(selectedSection.title)
            .accessibilityIdentifier("workspace-compact-menu")
        }
        .padding(.horizontal, KLMSSpacing.section)
        .padding(.vertical, KLMSSpacing.standard)
        .background(Color.klmsMacSidebarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.klmsMacBorder.opacity(0.76))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-navigation-mode-compact")
    }
}

private struct DashboardTopBarView: View {
    @ObservedObject var model: KLMSMacModel
    @Binding var selectedSection: KLMSMacSection
    var layoutMode: AdaptiveLayoutMode = .wide

    var body: some View {
        Group {
            if layoutMode == .wide {
                HStack(alignment: .center, spacing: KLMSSpacing.section) {
                    statusContent
                    TopUtilityActionsView(model: model)
                }
            } else {
                VStack(alignment: .leading, spacing: KLMSSpacing.comfortable) {
                    statusContent
                    TopUtilityActionsView(model: model)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, KLMSSpacing.hairline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-title-\(selectedSection.rawValue)")
        .accessibilityLabel("\(selectedSection.title) 화면")
    }

    private var statusContent: some View {
        DashboardTopBarStatusContent(snapshot: snapshot)
            .equatable()
    }

    private var snapshot: DashboardTopBarSnapshot {
        if let command = model.runningCommand {
            if let phase = model.currentPhaseText {
                return DashboardTopBarSnapshot(
                    title: selectedSection.title,
                    statusText: "\(command.displayName) 실행 중 · \(phase)",
                    runningPhaseLabel: phase,
                    runningProgress: MacRunningProgressSnapshot(command: command, phaseText: phase),
                    statusBadgeText: "진행 중",
                    tone: .running
                )
            }
            return DashboardTopBarSnapshot(
                title: selectedSection.title,
                statusText: "\(command.displayName) 실행 중",
                runningPhaseLabel: "진행 중",
                runningProgress: MacRunningProgressSnapshot(command: command, phaseText: nil),
                statusBadgeText: "진행 중",
                tone: .running
            )
        }
        if model.fileSystemRealtimeNeedsAttention {
            return DashboardTopBarSnapshot(
                title: selectedSection.title,
                statusText: "로컬 실시간 반영을 시작하지 못했습니다 · 진단 화면에서 다시 연결하세요.",
                runningPhaseLabel: nil,
                runningProgress: nil,
                statusBadgeText: "실시간 확인 필요",
                tone: .attention
            )
        }
        if model.needsAttention {
            return DashboardTopBarSnapshot(
                title: selectedSection.title,
                statusText: "확인이 필요합니다 · 로그 탭에서 실패 흐름을 확인하세요.",
                runningPhaseLabel: nil,
                runningProgress: nil,
                statusBadgeText: "확인 필요",
                tone: .attention
            )
        }
        if let report = model.snapshot.syncReport {
            return DashboardTopBarSnapshot(
                title: selectedSection.title,
                statusText: "준비됨 · 최근 상태 \(report.status.klmsLocalizedStatus)",
                runningPhaseLabel: nil,
                runningProgress: nil,
                statusBadgeText: "준비됨",
                tone: .ready
            )
        }
        return DashboardTopBarSnapshot(
            title: selectedSection.title,
            statusText: "첫 실행 전 · 전체 동기화나 진단을 실행하세요.",
            runningPhaseLabel: nil,
            runningProgress: nil,
            statusBadgeText: "준비 필요",
            tone: .ready
        )
    }
}

enum MacCommandActionIntent: Equatable {
    case run(KLMSEngineCommand)
    case cancel(KLMSMacRunningCommandIdentity)

    static func capture(
        command: KLMSEngineCommand,
        runningIdentity: KLMSMacRunningCommandIdentity?
    ) -> MacCommandActionIntent {
        guard let runningIdentity, runningIdentity.command == command else {
            return .run(command)
        }
        return .cancel(runningIdentity)
    }
}

private struct MacPrimarySyncActionView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        Button {
            let intent = MacCommandActionIntent.capture(
                command: .fullSync,
                runningIdentity: model.runningCommandIdentity
            )
            Task {
                switch intent {
                case let .run(command):
                    await model.run(command)
                case let .cancel(expectedIdentity):
                    await model.cancelRunningCommand(expectedIdentity: expectedIdentity)
                }
            }
        } label: {
            HStack(alignment: .center, spacing: KLMSSpacing.section) {
                VStack(alignment: .leading, spacing: KLMSSpacing.micro) {
                    Text(title)
                        .font(.title3.weight(.black))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if isRunning {
                        Text(model.currentPhaseText ?? "진행 상황을 확인 중입니다.")
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .opacity(0.86)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: systemImage)
                    .font(.headline.weight(.black))
            }
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .padding(.horizontal, KLMSSpacing.roomy)
            .padding(.vertical, KLMSSpacing.roomyControl)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: KLMSRadius.card))
            .overlay {
                RoundedRectangle(cornerRadius: KLMSRadius.card)
                    .stroke(borderColor, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.card))
        }
        .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: KLMSRadius.card, disabledOpacity: 1.0))
        .controlSize(.regular)
        .help(helpText)
        .accessibilityLabel(isRunning ? "전체 동기화 중단" : "전체 동기화 실행")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(helpText)
        .accessibilityIdentifier("command-fullSync-primary")
        .disabled(isDisabled)
    }

    private var isRunning: Bool {
        model.runningCommand == .fullSync
    }

    private var isBlockedByAnotherCommand: Bool {
        model.runningCommand != nil && !isRunning
    }

    private var isDisabled: Bool {
        isBlockedByAnotherCommand || (isRunning && model.isCancellingCommand)
    }

    private var title: String {
        if isRunning {
            return model.isCancellingCommand ? "중단 요청 중" : "전체 동기화 중단"
        }
        return "전체 동기화"
    }

    private var systemImage: String {
        if isRunning {
            return model.isCancellingCommand ? "hourglass" : "stop.fill"
        }
        return isBlockedByAnotherCommand ? "lock.fill" : "arrow.triangle.2.circlepath"
    }

    private var helpText: String {
        if isRunning {
            return model.isCancellingCommand
                ? "전체 동기화 중단 요청을 처리하고 있습니다."
                : "현재 전체 동기화를 중단합니다."
        }
        if let runningCommand = model.runningCommand {
            return "\(runningCommand.displayName) 실행이 끝나면 전체 동기화를 시작할 수 있습니다."
        }
        return KLMSEngineCommand.fullSync.shortDescription
    }

    private var accessibilityValue: String {
        if model.isCancellingCommand, isRunning {
            return "중단 요청 중"
        }
        if isRunning {
            return "실행 중, 누르면 중단"
        }
        if let runningCommand = model.runningCommand {
            return "\(runningCommand.displayName) 실행 중, 사용 불가"
        }
        return "실행 가능"
    }

    private var foregroundColor: Color {
        isBlockedByAnotherCommand
            ? Color.klmsMacSecondaryText.opacity(0.76)
            : Color.klmsMacPrimaryCommandButtonForeground
    }

    private var backgroundColor: Color {
        if isBlockedByAnotherCommand {
            return Color.klmsMacSubtleCardBackground.opacity(0.86)
        }
        return isRunning
            ? Color.klmsMacPrimaryCommandButtonPressedBackground
            : Color.klmsMacPrimaryCommandButtonBackground
    }

    private var borderColor: Color {
        if isBlockedByAnotherCommand {
            return Color.klmsMacCommandButtonBorder.opacity(0.64)
        }
        return isRunning
            ? Color.klmsMacPrimaryCommandButtonBorder.opacity(0.78)
            : Color.klmsMacPrimaryCommandButtonBorder
    }
}

private struct DashboardTopBarSnapshot: Equatable {
    var title: String
    var statusText: String
    var runningPhaseLabel: String?
    var runningProgress: MacRunningProgressSnapshot?
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
            return .klmsMacWarningForeground
        case .ready:
            return .klmsMacSecondaryText
        }
    }
}

private struct MacRunningProgressSnapshot: Equatable {
    var command: KLMSEngineCommand
    var phaseText: String?
    var stages: [String]
    var currentIndex: Int

    init(command: KLMSEngineCommand, phaseText: String?) {
        self.command = command
        self.phaseText = phaseText?.nilIfBlank
        stages = Self.stages(for: command)
        currentIndex = Self.currentIndex(phaseText: phaseText, stages: stages)
    }

    var fraction: Double {
        guard !stages.isEmpty else { return 0.08 }
        let raw = (Double(currentIndex) + 0.55) / Double(stages.count)
        return min(max(raw, 0.08), 0.96)
    }

    var currentStageText: String {
        guard stages.indices.contains(currentIndex) else {
            return phaseText ?? "진행 중"
        }
        return stages[currentIndex]
    }

    var progressLabel: String {
        "\(currentIndex + 1)/\(max(stages.count, 1)) · \(currentStageText)"
    }

    static func stages(for command: KLMSEngineCommand) -> [String] {
        switch command {
        case .fullSync:
            return ["로그인", "파일", "과제/시험", "공지", "상태 검사", "정리"]
        case .filesSync:
            return ["로그인", "파일", "정리"]
        case .coreSync:
            return ["로그인", "과제/시험", "상태 검사"]
        case .noticeSync:
            return ["로그인", "공지", "상태 검사"]
        case .verify:
            return ["상태 검사"]
        case .doctor:
            return ["환경 진단"]
        case .report:
            return ["요약 갱신"]
        case .v2BuildState:
            return ["상태 파일"]
        }
    }

    private static func currentIndex(phaseText: String?, stages: [String]) -> Int {
        let normalized = (phaseText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stages.isEmpty else { return 0 }
        if normalized.contains("파일") {
            return stages.firstIndex(of: "파일") ?? min(1, stages.count - 1)
        }
        if normalized.contains("과제") || normalized.contains("시험") {
            return stages.firstIndex(of: "과제/시험") ?? min(1, stages.count - 1)
        }
        if normalized.contains("공지") {
            return stages.firstIndex(of: "공지") ?? min(1, stages.count - 1)
        }
        if normalized.contains("상태") || normalized.contains("검사") {
            return stages.firstIndex(of: "상태 검사") ?? min(stages.count - 1, 1)
        }
        if normalized.contains("정리") {
            return stages.firstIndex(of: "정리") ?? stages.count - 1
        }
        if normalized.contains("로그인") || normalized.contains("준비") {
            return 0
        }
        return 0
    }
}

private struct MacRunningProgressBarView: View, Equatable {
    var progress: MacRunningProgressSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: KLMSSpacing.compact) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .tint(Color.klmsMacCommandAccent)
                .accessibilityLabel("동기화 진행률")
                .accessibilityValue(progress.progressLabel)
            HStack(spacing: KLMSSpacing.snug) {
                ForEach(progress.stages.indices, id: \.self) { index in
                    let stage = progress.stages[index]
                    HStack(spacing: KLMSSpacing.tight) {
                        Circle()
                            .fill(stageColor(index: index))
                            .frame(width: 5, height: 5)
                        Text(stage)
                            .font(.system(size: KLMSTypeSize.badge, weight: index == progress.currentIndex ? .bold : .semibold, design: .rounded))
                            .foregroundStyle(index == progress.currentIndex ? Color.klmsMacPrimaryText : Color.klmsMacSecondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                    if index < progress.stages.count - 1 {
                        Rectangle()
                            .fill(index < progress.currentIndex ? Color.klmsMacCommandAccent.opacity(0.52) : Color.klmsMacBorder.opacity(0.52))
                            .frame(width: 10, height: 1)
                    }
                }
                Spacer(minLength: 0)
                Text(progress.progressLabel)
                    .font(.system(size: KLMSTypeSize.badge, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .lineLimit(1)
                    .accessibilityIdentifier("running-progress")
                    .accessibilityLabel("동기화 진행률")
                    .accessibilityValue(progress.progressLabel)
            }
        }
    }

    private func stageColor(index: Int) -> Color {
        if index < progress.currentIndex {
            return .klmsMacSuccessForeground
        }
        if index == progress.currentIndex {
            return .klmsMacCommandAccent
        }
        return .klmsMacBorder
    }
}

private struct DashboardTopBarStatusContent: View, Equatable {
    var snapshot: DashboardTopBarSnapshot

    var body: some View {
        HStack(alignment: snapshot.runningProgress == nil ? .center : .top, spacing: KLMSSpacing.section) {
            VStack(alignment: .leading, spacing: KLMSSpacing.snug) {
                Text(snapshot.title)
                    .font(.system(size: KLMSTypeSize.metric, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.klmsMacPrimaryText)
                Text(snapshot.statusText)
                    .font(.caption)
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
                    .truncationMode(.tail)
                if let runningProgress = snapshot.runningProgress {
                    MacRunningProgressBarView(progress: runningProgress)
                        .frame(maxWidth: 520)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: KLMSSpacing.standard) {
                if let runningPhaseLabel = snapshot.runningPhaseLabel {
                    Label(runningPhaseLabel, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.klmsMacCommandAccent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                        .padding(.horizontal, KLMSSpacing.standard)
                        .padding(.vertical, KLMSSpacing.snug)
                        .background(Color.klmsMacCommandAccent.opacity(0.12), in: Capsule())
                }

                if shouldShowStatusBadge {
                    Text(snapshot.statusBadgeText)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, KLMSSpacing.standardControl)
                        .padding(.vertical, KLMSSpacing.compact)
                        .foregroundStyle(snapshot.tone.color)
                        .background(snapshot.tone.color.opacity(0.12), in: Capsule())
                }
            }
            .frame(minHeight: 28, alignment: .center)
            .padding(.top, snapshot.runningProgress == nil ? 0 : KLMSSpacing.hairline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shouldShowStatusBadge: Bool {
        snapshot.tone != .ready || snapshot.statusBadgeText != "준비됨"
    }
}

private struct MacAlertBannerView: View {
    let model: KLMSMacModel
    @Binding var selectedSection: KLMSMacSection
    @Binding var expandedLogSummaryKind: LogSummaryKind?
    @Binding var firstRunReadinessCompleted: Bool

    var body: some View {
        MacAlertBannerContent(snapshot: snapshot) {
            performAction()
        }
        .equatable()
    }

    private var snapshot: MacAlertBannerSnapshot {
        MacAlertBannerSnapshot(
            authDigits: model.currentAuthDigits,
            authStatusMessage: model.authStatusMessage?.nilIfBlank,
            runningCommandDisplayName: model.runningCommand?.displayName,
            currentPhaseText: model.currentPhaseText,
            liveProgressLine: model.liveProgressLine,
            runningProgress: model.runningCommand.map {
                MacRunningProgressSnapshot(command: $0, phaseText: model.currentPhaseText)
            },
            hasRecentRunFailure: model.hasRecentRunFailure,
            recentRunFailureTitle: model.recentRunFailureTitle,
            recentRunFailureDetail: model.recentRunFailureDetail,
            needsAttention: model.needsAttention,
            hasSyncReport: model.snapshot.syncReport != nil,
            firstRunReadinessCompleted: firstRunReadinessCompleted,
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
        if model.hasRecentRunFailure {
            expandedLogSummaryKind = .run
            selectedSection = .activityLogs
            return
        }
        if model.needsAttention {
            expandedLogSummaryKind = .run
            selectedSection = .activityLogs
            return
        }
        if model.snapshot.syncReport == nil {
            firstRunReadinessCompleted = true
            Task {
                await model.run(.doctor)
            }
            return
        }
    }
}

private struct MacAlertBannerSnapshot: Equatable {
    var authDigits: String?
    var authStatusMessage: String?
    var runningCommandDisplayName: String?
    var currentPhaseText: String?
    var liveProgressLine: String?
    var runningProgress: MacRunningProgressSnapshot?
    var hasRecentRunFailure: Bool
    var recentRunFailureTitle: String
    var recentRunFailureDetail: String
    var needsAttention: Bool
    var hasSyncReport: Bool
    var firstRunReadinessCompleted: Bool
    var loggedIn: Bool

    private var shouldShowFirstRunReadiness: Bool {
        !hasSyncReport && !firstRunReadinessCompleted
    }

    var shouldShow: Bool {
        authDigits != nil
            || authStatusMessage != nil
            || runningCommandDisplayName != nil
            || hasRecentRunFailure
            || needsAttention
            || shouldShowFirstRunReadiness
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
        if hasRecentRunFailure {
            return recentRunFailureTitle
        }
        if needsAttention {
            return "상태 검사 실패"
        }
        if shouldShowFirstRunReadiness {
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
        if hasRecentRunFailure {
            return "\(recentRunFailureDetail) · 실행 로그에서 원인을 바로 확인할 수 있습니다."
        }
        if needsAttention {
            return "로그 탭에서 실패 흐름과 마지막 메시지를 확인할 수 있습니다."
        }
        if shouldShowFirstRunReadiness {
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
        if hasRecentRunFailure {
            return "로그"
        }
        if needsAttention {
            return "로그"
        }
        if shouldShowFirstRunReadiness {
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
        if hasRecentRunFailure {
            return .warning
        }
        if needsAttention || shouldShowFirstRunReadiness {
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
            return .klmsMacWarningForeground
        case .success:
            return .klmsMacSuccessForeground
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
            return Color.klmsMacWarningForeground
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
                VStack(alignment: .leading, spacing: KLMSSpacing.comfortable) {
                    HStack(alignment: .center, spacing: KLMSSpacing.section) {
                        VStack(alignment: .leading, spacing: KLMSSpacing.tight) {
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
                            .lineLimit(1)
                            .minimumScaleFactor(snapshot.authDigits == nil ? 0.72 : 0.86)
                            .truncationMode(.tail)
                            .frame(maxWidth: snapshot.authDigits == nil ? 92 : nil)
                            .padding(.horizontal, snapshot.chipHorizontalPadding)
                            .padding(.vertical, KLMSSpacing.standard)
                            .background(chipBackground, in: Capsule())
                    }
                    if let runningProgress = snapshot.runningProgress {
                        MacRunningProgressBarView(progress: runningProgress)
                    }
                }
                .padding(KLMSSpacing.section)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(bannerBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.panel))
                .overlay {
                    RoundedRectangle(cornerRadius: KLMSRadius.panel)
                        .stroke(bannerBorder, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.panel))
            }
            .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: KLMSRadius.panel))
            .accessibilityLabel(snapshot.title)
            .accessibilityHint(snapshot.detail)
            .accessibilitySortPriority(100)
            .zIndex(1)
            .padding(.horizontal, KLMSSpacing.spacious)
            .padding(.top, KLMSSpacing.spacious)
            .padding(.bottom, KLMSSpacing.comfortable)
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
    var viewportWidth: CGFloat
    var accessibilityIdentifier: String
    @ViewBuilder var content: Content
    @State private var scrollResetTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                Color.clear
                    .frame(height: 0)
                    .id(KLMSMacScrollAnchor.top)
                content
                    .frame(width: viewportWidth, alignment: .topLeading)
                    .contentShape(Rectangle())
            }
            .frame(width: viewportWidth, alignment: .topLeading)
            .scrollIndicators(.visible)
            .clipped()
            .accessibilityIdentifier(accessibilityIdentifier)
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
            "설정 화면 · 이 기기에 바로 적용"
        }
    }
}

private struct TaskAndExamWorkspaceView: View {
    @ObservedObject var model: KLMSMacModel
    @State private var selectedKind: DashboardDetailKind = .assignments

    var body: some View {
        VStack(alignment: .leading, spacing: KLMSSpacing.section) {
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
        LazyVGrid(columns: taskKindColumns, spacing: KLMSSpacing.standard) {
            ForEach(availableKinds) { kind in
                taskKindButton(kind)
            }
        }
        .padding(KLMSSpacing.standard)
        .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: KLMSRadius.card)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
    }

    private var taskKindColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 140), spacing: KLMSSpacing.standard),
            count: max(1, availableKinds.count)
        )
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
            HStack(spacing: KLMSSpacing.compactControl) {
                Image(systemName: taskKindIcon(kind))
                    .font(.caption.weight(.bold))
                Text(kind.title)
                    .font(.caption.weight(.bold))
                Text("\(taskKindCount(kind))")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .padding(.horizontal, KLMSSpacing.compact)
                    .padding(.vertical, KLMSSpacing.micro)
                    .background(isSelected ? Color.klmsMacSelectedForeground.opacity(0.16) : Color.klmsMacSubtleCardBackground, in: Capsule())
            }
            .foregroundStyle(isSelected ? Color.klmsMacSelectedForeground : Color.klmsMacPrimaryText)
            .padding(.horizontal, KLMSSpacing.comfortableControl)
            .frame(maxWidth: .infinity, minHeight: KLMSControlSize.minimumInteractive)
            .background(isSelected ? Color.klmsMacSelectedBackground : Color.klmsMacSubtleCardBackground.opacity(0.70), in: RoundedRectangle(cornerRadius: KLMSRadius.control))
            .overlay {
                RoundedRectangle(cornerRadius: KLMSRadius.control)
                    .stroke(isSelected ? Color.klmsMacSelectedBorder : Color.klmsMacBorder.opacity(0.70), lineWidth: isSelected ? 1.25 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.control))
        }
        .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: KLMSRadius.control))
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
            filterOptions: model.dashboardFilterOptions(for: kind),
            viewRevision: model.dashboardViewRevision
        )
    }
}

private struct QuickStatusStripView: View {
    let model: KLMSMacModel

    var body: some View {
        HStack(spacing: KLMSSpacing.compact) {
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
            return result.succeeded ? .klmsMacSuccessForeground : .klmsMacWarningForeground
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
            .padding(.horizontal, KLMSSpacing.standard)
            .padding(.vertical, KLMSSpacing.snug)
            .foregroundStyle(color)
            .background(color.opacity(0.11), in: Capsule())
    }
}

private struct ExternalIntegrationStatusView: View {
    let model: KLMSMacModel
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: KLMSSpacing.standard)]

    var body: some View {
        let verify = model.snapshot.verifyResult
        let statuses = integrationStatuses(for: verify)
        VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
            HStack(spacing: KLMSSpacing.standard) {
                HStack(spacing: KLMSSpacing.standard) {
                    Label("연동 상태", systemImage: "link")
                        .font(.caption.weight(.semibold))

                    IntegrationSummaryBadge(
                        text: summaryText(for: verify),
                        color: summaryColor(for: verify)
                    )

                    Spacer(minLength: 8)
                }
                .padding(KLMSSpacing.comfortable)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))

                Button {
                    Task { await model.run(.verify) }
                } label: {
                    Label("상태 검사", systemImage: "checkmark.seal")
                }
                .disabled(model.runningCommand != nil)
                .buttonStyle(KLMSMacRootActionButtonStyle())
            }

            LazyVGrid(columns: columns, spacing: KLMSSpacing.standard) {
                ForEach(statuses) { status in
                    IntegrationStatusTile(status: status)
                }
            }
        }
        .padding(.horizontal, KLMSSpacing.comfortable)
        .padding(.vertical, KLMSSpacing.comfortable)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
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
            return .klmsMacSuccessForeground
        case "warn", "warning":
            return .klmsMacWarningForeground
        case "fail", "failed", "error":
            return .klmsMacDangerForeground
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
            .padding(.horizontal, KLMSSpacing.comfortable)
            .padding(.vertical, KLMSSpacing.compactControl)
            .background {
                RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                    .fill(background)
            }
            .overlay {
                RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                    .stroke(border, lineWidth: isEnabled ? 1.15 : 1)
            }
            .opacity(isEnabled ? 1.0 : 0.42)
            .saturation(isEnabled ? 1.0 : 0.30)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1.0)
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

    private var background: AnyShapeStyle {
        switch tone {
        case .soft:
            return AnyShapeStyle(Color.klmsMacCommandButtonBackground.opacity(isEnabled ? 0.94 : 0.22))
        case .primary:
            return AnyShapeStyle(isEnabled ? Color.klmsMacPrimaryCommandButtonBackground : Color.klmsMacCommandButtonBackground.opacity(0.24))
        case .destructive:
            if !isEnabled {
                return AnyShapeStyle(Color.klmsMacCommandButtonBackground.opacity(0.20))
            }
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.klmsMacDangerBorder.opacity(0.98),
                        Color.klmsMacDangerBorder.opacity(0.74),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .success:
            return AnyShapeStyle(Color.klmsMacSuccessBackground.opacity(isEnabled ? 1.0 : 0.22))
        case .accent(let color):
            return AnyShapeStyle(color.opacity(isEnabled ? 0.12 : 0.04))
        }
    }

    private var border: Color {
        switch tone {
        case .soft:
            Color.klmsMacCommandButtonBorder.opacity(isEnabled ? 0.96 : 0.24)
        case .primary:
            Color.klmsMacPrimaryCommandButtonBorder.opacity(isEnabled ? 1.0 : 0.26)
        case .destructive:
            isEnabled ? Color.klmsMacDangerBorder.opacity(0.84) : Color.klmsMacCommandButtonBorder.opacity(0.24)
        case .success:
            Color.klmsMacSuccessBorder.opacity(isEnabled ? 1.0 : 0.26)
        case .accent(let color):
            color.opacity(isEnabled ? 0.32 : 0.12)
        }
    }

}

private struct KLMSMacCompactDangerIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: KLMSTypeSize.control, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.klmsMacDangerForeground : Color.klmsMacSecondaryText.opacity(0.42))
            .frame(width: 32, height: 32)
            .background {
                RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                    .fill(background)
            }
            .overlay {
                RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                    .stroke(border, lineWidth: isEnabled ? 1.15 : 1)
            }
            .opacity(isEnabled ? 1.0 : 0.40)
            .saturation(isEnabled ? 1.0 : 0.22)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1.0)
            .frame(width: KLMSControlSize.minimumInteractive, height: KLMSControlSize.minimumInteractive)
            .contentShape(Rectangle())
    }

    private var background: Color {
        guard isEnabled else {
            return Color.klmsMacCommandButtonBackground.opacity(0.18)
        }
        return Color.klmsMacDangerBorder.opacity(0.13)
    }

    private var border: Color {
        guard isEnabled else {
            return Color.klmsMacCommandButtonBorder.opacity(0.22)
        }
        return Color.klmsMacDangerBorder.opacity(0.54)
    }
}

private struct KLMSMacCompactDangerActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.klmsMacDangerForeground : Color.klmsMacSecondaryText.opacity(0.42))
            .lineLimit(1)
            .padding(.horizontal, KLMSSpacing.standard)
            .frame(minHeight: 30)
            .background(background, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
            .overlay {
                RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                    .stroke(border, lineWidth: isEnabled ? 1.1 : 1)
            }
            .opacity(isEnabled ? 1.0 : 0.40)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1.0)
            .frame(minWidth: KLMSControlSize.minimumInteractive, minHeight: KLMSControlSize.minimumInteractive)
            .contentShape(Rectangle())
    }

    private var background: Color {
        isEnabled
            ? Color.klmsMacDangerBorder.opacity(0.10)
            : Color.klmsMacCommandButtonBackground.opacity(0.16)
    }

    private var border: Color {
        isEnabled
            ? Color.klmsMacDangerBorder.opacity(0.48)
            : Color.klmsMacCommandButtonBorder.opacity(0.20)
    }
}

private struct KLMSMacConfirmedClearAction: View {
    var shortLabel: String?
    var accessibilityLabel: String
    var confirmationTitle: String
    var confirmationMessage: String
    var confirmationButtonTitle: String
    var accessibilityIdentifier: String?
    var isEnabled = true
    var action: () -> Void
    @State private var showsConfirmation = false

    var body: some View {
        Button(role: .destructive) {
            showsConfirmation = true
        } label: {
            if let shortLabel {
                Label(shortLabel, systemImage: "trash")
            } else {
                Image(systemName: "trash")
            }
        }
        .buttonStyle(KLMSMacCompactDangerActionButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(shortLabel == nil ? "아이콘 전용" : "아이콘과 레이블")
        .modifier(OptionalAccessibilityIdentifier(identifier: accessibilityIdentifier))
        .confirmationDialog(
            confirmationTitle,
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button(confirmationButtonTitle, role: .destructive, action: action)
            Button("취소", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    var identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
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
            .klmsMacSuccessForeground
        case .warning:
            .klmsMacWarningForeground
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
            .padding(.horizontal, KLMSSpacing.compactControl)
            .padding(.vertical, KLMSSpacing.micro)
            .background(color.opacity(0.10), in: Capsule())
    }
}

private struct IntegrationStatusTile: View {
    var status: IntegrationStatusSummary

    var body: some View {
        VStack(alignment: .leading, spacing: KLMSSpacing.snug) {
            HStack(spacing: KLMSSpacing.snug) {
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
        .padding(KLMSSpacing.standard)
        .background(status.health.color.opacity(0.08), in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
        .overlay {
            RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                .stroke(status.health.color.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct ImportantLogPanelView: View {
    @ObservedObject var model: KLMSMacModel
    @Binding var selectedSection: KLMSMacSection
    @Binding var expandedLogSummaryKind: LogSummaryKind?
    @Binding var firstRunReadinessCompleted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
            AuthCodeBannerView(digits: model.currentAuthDigits, statusMessage: model.authStatusMessage)
            NextActionPanelView(
                model: model,
                selectedSection: $selectedSection,
                expandedLogSummaryKind: $expandedLogSummaryKind,
                firstRunReadinessCompleted: $firstRunReadinessCompleted
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
    var layoutMode: AdaptiveLayoutMode
    private static let terminalSummaryDisplayInterval: TimeInterval = 5 * 60
    private let tileColumns = [GridItem(.adaptive(minimum: 176), spacing: KLMSSpacing.standard)]
    private let renderReferenceDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
            HStack {
                Label("로그 요약", systemImage: "list.bullet.rectangle")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                if let updatedAt = latestUpdatedAtText {
                    Text(updatedAt)
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                }
                KLMSMacConfirmedClearAction(
                    shortLabel: layoutMode == .compact ? nil : "로그 지우기",
                    accessibilityLabel: "모든 로그 지우기",
                    confirmationTitle: "모든 로그를 지울까요?",
                    confirmationMessage: "실행 로그, 서버 요청, 파일 요청, 항목·설정 변경, 공유 실행 로그를 지웁니다. 진행 중인 요청은 유지됩니다.",
                    confirmationButtonTitle: "모든 로그 지우기",
                    accessibilityIdentifier: "log-clear-all-action",
                    isEnabled: model.hasClearableVisibleLogs
                ) {
                    Task {
                        await model.clearVisibleLogsAndServerRelayLogs()
                    }
                }
                .help("화면의 실행 로그, 서버 요청, 파일 요청, 항목 변경, 설정 변경, 공유 실행 로그를 지웁니다. 진행 중인 요청은 유지됩니다.")
            }

            LazyVGrid(columns: tileColumns, alignment: .leading, spacing: KLMSSpacing.standard) {
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
        .padding(KLMSSpacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: KLMSRadius.panel)
                .stroke(Color.klmsMacBorder.opacity(0.72), lineWidth: 1)
        }
    }

    private var latestFileRequest: ServerRelayFileAccessRequest? {
        if let active = model.serverRelayRecentFileAccessRequests.first(where: { $0.status.isInFlight }) {
            return active
        }
        return model.serverRelayRecentFileAccessRequests.first {
            renderReferenceDate.timeIntervalSince($0.updatedAt) <= Self.terminalSummaryDisplayInterval
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
        if renderReferenceDate.timeIntervalSince(command.updatedAt) <= Self.terminalSummaryDisplayInterval {
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
            return result.succeeded ? "종료 코드 \(result.exitCode)" : "마지막 오류는 로그 탭에서 확인하세요."
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
        return result.succeeded ? Color.klmsMacSuccessForeground : Color.klmsMacWarningForeground
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
            return .klmsMacWarningForeground
        }
        if currentRemoteCommand?.displayStatus().isInFlight == true {
            return .klmsMacCommandAccent
        }
        return model.serverRelayEnabled ? .klmsMacSuccessForeground : .klmsMacSecondaryText
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
            return .klmsMacSuccessForeground
        case .failed, .macUnavailable:
            return .klmsMacWarningForeground
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
        VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
            switch kind {
            case .run:
                runDetail
            case .remote:
                remoteDetail
            case .fileRequest:
                fileRequestDetail
            }
        }
        .padding(KLMSSpacing.comfortable)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
        .overlay {
            RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
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
        VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
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
        VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
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
            HStack(alignment: .top, spacing: KLMSSpacing.standard) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: KLMSSpacing.micro) {
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
            .padding(KLMSSpacing.standardControl)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
            .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
            .overlay {
                RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                    .stroke(isExpanded ? tint.opacity(0.42) : tint.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: KLMSRadius.panel))
        .help(isExpanded ? "관련 로그 접기" : "관련 로그 펼치기")
        .accessibilityLabel("\(title) 로그 요약 \(isExpanded ? "펼쳐짐" : "접힘")")
        .accessibilityHint(isExpanded ? "관련 로그 접기" : "관련 로그 펼치기")
    }
}

private struct NextActionPanelView: View {
    let model: KLMSMacModel
    @Binding var selectedSection: KLMSMacSection
    @Binding var expandedLogSummaryKind: LogSummaryKind?
    @Binding var firstRunReadinessCompleted: Bool

    var body: some View {
        if let action = nextAction {
            HStack(alignment: .center, spacing: KLMSSpacing.comfortable) {
                Image(systemName: action.systemImage)
                    .foregroundStyle(action.color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: KLMSSpacing.hairline) {
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
                .buttonStyle(KLMSMacRootActionButtonStyle(tone: .soft))
                .accessibilityLabel(action.buttonTitle)
                .accessibilityHint(action.detail)
                .disabled(model.runningCommand != nil && action.kind != .showRunningLog)
            }
            .padding(KLMSSpacing.comfortable)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(action.color.opacity(0.10), in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
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
        if model.hasRecentRunFailure {
            return NextAction(
                kind: .showRunningLog,
                title: model.recentRunFailureTitle,
                detail: "실행 로그에서 마지막 오류를 확인하세요.",
                buttonTitle: "로그 보기",
                buttonImage: "text.alignleft",
                systemImage: "exclamationmark.triangle.fill",
                color: .klmsMacWarningForeground
            )
        }
        if model.needsAttention {
            return NextAction(
                kind: .showRunningLog,
                title: "상태 확인이 필요합니다",
                detail: "로그 탭에서 실패 흐름과 마지막 오류를 먼저 확인하세요.",
                buttonTitle: "로그 보기",
                buttonImage: "text.alignleft",
                systemImage: "exclamationmark.triangle.fill",
                color: .klmsMacWarningForeground
            )
        }
        if model.snapshot.syncReport == nil, !firstRunReadinessCompleted {
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
                color: .klmsMacWarningForeground
            )
        }
        return nil
    }

    private func perform(_ action: NextAction) {
        switch action.kind {
        case .showRunningLog:
            expandedLogSummaryKind = .run
            selectedSection = .activityLogs
        case .copyAuthDigits:
            if let digits = model.currentAuthDigits {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(digits, forType: .string)
            }
        case .runDoctor:
            firstRunReadinessCompleted = true
            Task {
                await model.run(.doctor)
            }
        case .showSettings:
            if model.snapshot.syncReport == nil {
                firstRunReadinessCompleted = true
            }
            selectedSection = .settings
        }
    }
}

private struct NextAction {
    enum Kind {
        case showRunningLog
        case copyAuthDigits
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

private struct DiagnosticToolsPanelView: View {
    let model: KLMSMacModel
    @State private var isAdvancedExpanded = false
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: KLMSSpacing.standard)]
    private let dryRunCommands: [KLMSEngineCommand] = [.fullSync, .filesSync, .coreSync, .noticeSync]

    var body: some View {
        SectionBox(title: "빠른 점검") {
            VStack(alignment: .leading, spacing: KLMSSpacing.section) {
                Text("권장 순서: 상태 검사 → 권한/환경 진단 → 리포트")
                    .font(.caption)
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                LazyVGrid(columns: columns, alignment: .leading, spacing: KLMSSpacing.standard) {
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
                    LazyVGrid(columns: columns, alignment: .leading, spacing: KLMSSpacing.standard) {
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
            VStack(alignment: .leading, spacing: KLMSSpacing.tight) {
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
            .padding(.vertical, KLMSSpacing.tight)
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
                .frame(maxWidth: .infinity, minHeight: KLMSControlSize.minimumInteractive)
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
            VStack(alignment: .leading, spacing: KLMSSpacing.tight) {
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
                VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
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
        VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
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
            .padding(KLMSSpacing.standard)
            .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
            .overlay(
                RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
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
            VStack(alignment: .leading, spacing: KLMSSpacing.compact) {
                Text("핵심 로그")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsMacSecondaryText)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: KLMSSpacing.compact)], alignment: .leading, spacing: KLMSSpacing.compact) {
                    ForEach(highlights) { highlight in
                        HStack(alignment: .top, spacing: KLMSSpacing.compactControl) {
                            Image(systemName: systemImage(for: highlight.level))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(tint(for: highlight.level))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: KLMSSpacing.hairline) {
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
                        .padding(KLMSSpacing.standard)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(tint(for: highlight.level).opacity(0.08), in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
                        .overlay {
                            RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
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
            VStack(alignment: .leading, spacing: KLMSSpacing.hairline) {
                Label("의미", systemImage: "questionmark.circle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.klmsMacSecondaryText)
                Text(highlight.explanation.klmsDisplayText)
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, KLMSSpacing.snug)
        }
        if !highlight.nextAction.isEmpty {
            VStack(alignment: .leading, spacing: KLMSSpacing.hairline) {
                Label("다음 확인", systemImage: "arrow.turn.down.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint(for: highlight.level))
                Text(highlight.nextAction.klmsDisplayText)
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacPrimaryText.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, KLMSSpacing.micro)
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
            return .klmsMacWarningForeground
        case "success":
            return .klmsMacSuccessForeground
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
            HStack(alignment: .center, spacing: KLMSSpacing.section) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundStyle(Color.klmsMacWarningForeground)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: KLMSSpacing.hairline) {
                    Text("KAIST 인증 번호")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    Text(digits)
                        .font(.system(size: KLMSTypeSize.heroMetric, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("KAIST 인증 번호")
                .accessibilityValue(digits.map(String.init).joined(separator: " "))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(digits, forType: .string)
                } label: {
                    Label("복사", systemImage: "doc.on.doc")
                }
                .buttonStyle(KLMSMacRootActionButtonStyle(tone: .accent(Color.klmsMacWarningForeground)))
                .accessibilityLabel("KAIST 인증 번호 복사")
            }
            .padding(KLMSSpacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsMacWarningBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
            .overlay {
                RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                    .stroke(Color.klmsMacWarningBorder, lineWidth: 1)
            }
        } else if let statusMessage {
            HStack(alignment: .center, spacing: KLMSSpacing.comfortable) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.klmsMacSuccessForeground)
                Text(statusMessage)
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            .padding(KLMSSpacing.comfortable)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsMacSuccessBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
            .overlay {
                RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
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
            renderSignature: model.dashboardRenderSignature,
            viewRevision: model.dashboardViewRevision
        )
        .equatable()
    }
}

private struct DashboardSummaryContentView: View, @preconcurrency Equatable {
    var model: KLMSMacModel
    var snapshot: EngineSnapshot
    var presentation: DashboardSummaryPresentation
    var renderSignature: DashboardRenderSignature
    var viewRevision: Int
    @State private var selectedDetail: DashboardDetailKind?
    @State private var renderedDetail: DashboardDetailKind?
    @State private var detailRenderTask: Task<Void, Never>?
    @State private var isArchiveMetricsExpanded = false
    @State private var selectedYear = DashboardTermFilter.allYears
    @State private var selectedSemester = DashboardTermFilter.allSemesters

    @MainActor
    init(
        model: KLMSMacModel,
        snapshot: EngineSnapshot,
        presentation: DashboardSummaryPresentation,
        renderSignature: DashboardRenderSignature,
        viewRevision: Int
    ) {
        self.model = model
        self.snapshot = snapshot
        self.presentation = presentation
        self.renderSignature = renderSignature
        self.viewRevision = viewRevision
    }

    static func == (lhs: DashboardSummaryContentView, rhs: DashboardSummaryContentView) -> Bool {
        lhs.renderSignature == rhs.renderSignature
            && lhs.viewRevision == rhs.viewRevision
    }

    var body: some View {
        let scopedPresentation = DashboardSummaryPresentation(
            model: model,
            snapshot: snapshot,
            summary: model.dashboardSummaryCache,
            selectedYear: selectedYear,
            selectedSemester: selectedSemester
        )
        VStack(alignment: .leading, spacing: KLMSSpacing.section) {
            IssueSummaryView(issues: model.cachedIssues)
            DashboardMainScopeBarView(
                selectedYear: $selectedYear,
                selectedSemester: $selectedSemester,
                options: DashboardMainScopeOptions(model: model, snapshot: snapshot)
            )
            if !scopedPresentation.hasAnyMetrics {
                Text("표시할 대시보드 항목이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(Color.klmsMacSecondaryText)
            } else {
                VStack(alignment: .leading, spacing: KLMSSpacing.section) {
                    metricColumn(
                        primaryMetrics: scopedPresentation.primaryMetrics,
                        attentionMetrics: scopedPresentation.attentionMetrics,
                        archiveMetrics: scopedPresentation.archiveMetrics,
                        isArchiveExpanded: isArchiveMetricsExpanded,
                        activeDetail: currentActiveDetail(in: scopedPresentation)
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    dashboardDetailContent(
                        renderedDetail: currentRenderedDetail(in: scopedPresentation),
                        scopedPresentation: scopedPresentation
                    )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onDisappear {
            detailRenderTask?.cancel()
            detailRenderTask = nil
        }
    }

    private func currentActiveDetail(in scopedPresentation: DashboardSummaryPresentation) -> DashboardDetailKind? {
        scopedPresentation.activeDetail(
            selectedDetail,
            archiveExpanded: isArchiveMetricsExpanded
        )
    }

    private func currentRenderedDetail(in scopedPresentation: DashboardSummaryPresentation) -> DashboardDetailKind? {
        scopedPresentation.renderedDetail(
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
        }
        detailRenderTask?.cancel()
        detailRenderTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, selectedDetail == detail else { return }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                renderedDetail = detail
            }
            detailRenderTask = nil
        }
    }

    private func metricColumn(
        primaryMetrics: [Metric],
        attentionMetrics: [Metric],
        archiveMetrics: [Metric],
        isArchiveExpanded: Bool,
        activeDetail: DashboardDetailKind?
    ) -> some View {
        VStack(alignment: .leading, spacing: KLMSSpacing.section) {
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
            detailRenderTask?.cancel()
            detailRenderTask = nil
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
            filterOptions: model.dashboardFilterOptions(for: kind),
            viewRevision: model.dashboardViewRevision,
            initialSelectedYear: selectedYear,
            initialSelectedSemester: selectedSemester
        )
            .equatable()
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func dashboardDetailContent(
        renderedDetail: DashboardDetailKind?,
        scopedPresentation: DashboardSummaryPresentation
    ) -> some View {
        if let renderedDetail {
            dashboardDetailColumn(kind: renderedDetail)
        } else {
            DashboardDetailHint(
                items: DashboardQuickWorkItem.items(
                    model: model,
                    snapshot: snapshot,
                    presentation: scopedPresentation,
                    selectedYear: selectedYear,
                    selectedSemester: selectedSemester
                ),
                onSelect: selectDashboardDetail
            )
        }
    }
}

private struct DashboardQuickWorkItem: Identifiable {
    var id: String
    var title: String
    var detail: String
    var kind: DashboardDetailKind
    var systemImage: String
    var tint: Color

    @MainActor
    static func items(
        model: KLMSMacModel,
        snapshot: EngineSnapshot,
        presentation: DashboardSummaryPresentation,
        selectedYear: String,
        selectedSemester: String
    ) -> [DashboardQuickWorkItem] {
        var items: [DashboardQuickWorkItem] = []
        var usedKinds = Set<DashboardDetailKind>()

        func append(_ item: DashboardQuickWorkItem) {
            guard usedKinds.insert(item.kind).inserted else { return }
            items.append(item)
        }

        if let assignment = model.dashboardStateItems(for: .assignments)
            .filter({ matchesScope($0.academicTerm, selectedYear: selectedYear, selectedSemester: selectedSemester) })
            .sorted(by: StateItem.dashboardAssignmentSort)
            .first {
            append(Self.stateItem(
                assignment,
                kind: .assignments,
                prefix: "과제",
                systemImage: "checklist",
                tint: Color.klmsMacWarningForeground
            ))
        }

        if let exam = model.dashboardStateItems(for: .exams)
            .filter({ matchesScope($0.academicTerm, selectedYear: selectedYear, selectedSemester: selectedSemester) })
            .sorted(by: StateItem.dashboardScheduleSort)
            .first {
            append(Self.stateItem(
                exam,
                kind: .exams,
                prefix: "시험",
                systemImage: "calendar.badge.clock",
                tint: Color.klmsMacSuccessForeground
            ))
        }

        if let notice = dashboardNoticeCandidate(snapshot: snapshot, selectedYear: selectedYear, selectedSemester: selectedSemester) {
            append(Self(
                id: "notice-\(notice.id)",
                title: notice.title.klmsDisplayText.nilIfBlank ?? "공지",
                detail: [notice.course, notice.postedAt, notice.changeState.klmsLocalizedStatus]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                kind: .notices,
                systemImage: "megaphone",
                tint: Color.klmsMacCommandAccent
            ))
        }

        if let file = dashboardFileCandidate(snapshot: snapshot, selectedYear: selectedYear, selectedSemester: selectedSemester) {
            append(Self(
                id: "file-\(file.id)",
                title: dashboardFileTitle(filename: file.filename, relativePath: file.relativePath),
                detail: [file.resolvedAcademicTerm(catalog: snapshot.academicTermCatalog)?.displayName ?? "", file.course, "파일"]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                kind: .files,
                systemImage: "doc",
                tint: Color.klmsMacSecondaryText
            ))
        }

        if let calendarChange = dashboardCalendarCandidate(model: model, snapshot: snapshot, selectedYear: selectedYear, selectedSemester: selectedSemester) {
            append(Self(
                id: "calendar-\(calendarChange.id)",
                title: calendarChange.title.nilIfBlank ?? "캘린더 변경",
                detail: [calendarChange.actionDisplayName, calendarChange.course, calendarChange.calendar]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                kind: .calendar,
                systemImage: "calendar",
                tint: Color.klmsMacSuccessForeground
            ))
        }

        if items.count < 3 {
            for metric in presentation.attentionMetrics + presentation.primaryMetrics + presentation.archiveMetrics {
                guard let kind = metric.detail, metric.value > 0, !usedKinds.contains(kind) else {
                    continue
                }
                append(Self(
                    id: "metric-\(kind.rawValue)",
                    title: "\(metric.label) \(metric.value)개",
                    detail: "목록과 처리 버튼 열기",
                    kind: kind,
                    systemImage: fallbackSystemImage(for: kind),
                    tint: fallbackTint(for: kind)
                ))
                if items.count >= 5 {
                    break
                }
            }
        }

        return Array(items.prefix(5))
    }

    private static func dashboardFileTitle(filename: String, relativePath: String) -> String {
        let trimmedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFilename.isEmpty {
            return trimmedFilename
        }
        let trimmedRelativePath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRelativePath.isEmpty else {
            return "파일"
        }
        let basename = URL(fileURLWithPath: trimmedRelativePath).lastPathComponent
        return basename.isEmpty ? trimmedRelativePath : basename
    }

    private static func stateItem(
        _ item: StateItem,
        kind: DashboardDetailKind,
        prefix: String,
        systemImage: String,
        tint: Color
    ) -> DashboardQuickWorkItem {
        DashboardQuickWorkItem(
            id: "\(kind.rawValue)-\(item.id)",
            title: item.title.nilIfBlank ?? prefix,
            detail: [item.academicTerm?.displayName ?? "", item.course, item.due]
                .filter { !$0.isEmpty }
                .joined(separator: " · "),
            kind: kind,
            systemImage: systemImage,
            tint: tint
        )
    }

    private static func dashboardNoticeCandidate(
        snapshot: EngineSnapshot,
        selectedYear: String,
        selectedSemester: String
    ) -> NoticeDigestEntry? {
        let generatedAt = snapshot.noticeDigest?.generatedAt ?? ""
        let catalog = snapshot.academicTermCatalog
        return (snapshot.noticeDigest?.notices ?? [])
            .filter { notice in
                let hidden = snapshot.noticeUserState?.notices[notice.noticeIdentifier]?.hidden == true
                let term = notice.academicTerm(generatedAt: generatedAt, catalog: catalog)
                return !hidden && matchesScope(term, selectedYear: selectedYear, selectedSemester: selectedSemester)
            }
            .sorted { lhs, rhs in
                let leftFresh = lhs.changeState == "new" || lhs.changeState == "updated"
                let rightFresh = rhs.changeState == "new" || rhs.changeState == "updated"
                if leftFresh != rightFresh {
                    return leftFresh && !rightFresh
                }
                return lhs.postedAt.localizedStandardCompare(rhs.postedAt) == .orderedDescending
            }
            .first
    }

    private static func dashboardFileCandidate(
        snapshot: EngineSnapshot,
        selectedYear: String,
        selectedSemester: String
    ) -> CourseFileManifestEntry? {
        snapshot.courseFileManifest
            .filter {
                matchesScope(
                    $0.resolvedAcademicTerm(catalog: snapshot.academicTermCatalog),
                    selectedYear: selectedYear,
                    selectedSemester: selectedSemester
                )
            }
            .sorted {
                ($0.klmsTimestampEpoch ?? Int.min) > ($1.klmsTimestampEpoch ?? Int.min)
            }
            .first
    }

    @MainActor
    private static func dashboardCalendarCandidate(
        model: KLMSMacModel,
        snapshot: EngineSnapshot,
        selectedYear: String,
        selectedSemester: String
    ) -> CalendarChange? {
        ((snapshot.calendarSyncResult?.changes ?? []) + model.mailCalendarChanges())
            .dedupedForCalendarDisplay()
            .filter {
                $0.isUserVisibleCalendarChange
                    && !model.isCalendarChangeResolved($0)
                    && matchesScope($0.academicTerm, selectedYear: selectedYear, selectedSemester: selectedSemester)
            }
            .first
    }

    private static func matchesScope(
        _ term: AcademicTerm?,
        selectedYear: String,
        selectedSemester: String
    ) -> Bool {
        DashboardTermFilter.matches(term, selectedYear: selectedYear, selectedSemester: selectedSemester)
    }

    private static func fallbackSystemImage(for kind: DashboardDetailKind) -> String {
        switch kind {
        case .assignments, .assignmentCandidates:
            "checklist"
        case .exams, .examCandidates:
            "calendar.badge.clock"
        case .notices:
            "megaphone"
        case .files, .missingFiles, .newFiles, .pruned:
            "doc"
        case .calendar:
            "calendar"
        case .quarantine:
            "exclamationmark.triangle"
        case .helpDesk:
            "questionmark.circle"
        case .hidden:
            "archivebox"
        }
    }

    private static func fallbackTint(for kind: DashboardDetailKind) -> Color {
        switch kind {
        case .assignments, .assignmentCandidates:
            Color.klmsMacWarningForeground
        case .exams, .examCandidates, .calendar:
            Color.klmsMacSuccessForeground
        case .notices, .helpDesk:
            Color.klmsMacCommandAccent
        case .quarantine, .pruned, .missingFiles:
            Color.klmsMacDangerForeground
        case .files, .newFiles, .hidden:
            Color.klmsMacSecondaryText
        }
    }
}

private struct DashboardDetailHint: View {
    var items: [DashboardQuickWorkItem]
    var onSelect: (DashboardDetailKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
            HStack(alignment: .center, spacing: KLMSSpacing.comfortable) {
                Image(systemName: "rectangle.stack.badge.cursorarrow")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: KLMSSpacing.micro) {
                    Text("우선 처리할 항목")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.klmsMacPrimaryText)
                    Text("카드를 누르면 바로 아래에서 목록과 처리 버튼을 확인할 수 있습니다.")
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if items.isEmpty {
                Text("현재 범위에서 바로 처리할 항목이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(Color.klmsMacSecondaryText)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: KLMSSpacing.standard)], alignment: .leading, spacing: KLMSSpacing.standard) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item.kind)
                        } label: {
                            DashboardQuickWorkItemRow(item: item)
                        }
                        .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: KLMSRadius.smallSurface))
                        .help("\(item.kind.title) 상세 열기")
                        .accessibilityLabel("\(item.title) \(item.kind.title) 상세 열기")
                    }
                }
            }
        }
        .padding(KLMSSpacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
        .overlay {
            RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
    }
}

private struct DashboardQuickWorkItemRow: View {
    var item: DashboardQuickWorkItem

    var body: some View {
        HStack(alignment: .top, spacing: KLMSSpacing.standard) {
            Image(systemName: item.systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(item.tint)
                .frame(width: 22, height: 22)
                .background(item.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: KLMSRadius.compactSurface))
            VStack(alignment: .leading, spacing: KLMSSpacing.micro) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsMacPrimaryText)
                    .lineLimit(2)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.klmsMacSecondaryText.opacity(0.72))
        }
        .padding(KLMSSpacing.standardControl)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .background(Color.klmsMacCardBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
        .overlay {
            RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                .stroke(item.tint.opacity(0.16), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
    }
}

private struct DashboardMainScopeOptions: Equatable {
    var years: [String]
    var semesters: [String]

    @MainActor
    init(model: KLMSMacModel, snapshot: EngineSnapshot) {
        var terms: [AcademicTerm?] = []
        terms += model.dashboardStateItems(for: .assignments).map(\.academicTerm)
        terms += model.dashboardStateItems(for: .exams).map(\.academicTerm)
        terms += DashboardTermFilter.terms(for: .helpDesk, snapshot: snapshot)
        terms += DashboardTermFilter.terms(for: .notices, snapshot: snapshot)
        terms += DashboardTermFilter.terms(for: .files, snapshot: snapshot)
        terms += DashboardTermFilter.terms(for: .newFiles, snapshot: snapshot)
        terms += DashboardTermFilter.terms(for: .calendar, snapshot: snapshot)
        terms += model.dashboardServerRelayItems().map(\.dashboardFilterAcademicTerm)
        if let selectedTerm = snapshot.academicTermCatalog?.selectedAcademicTerm {
            terms.append(selectedTerm)
        }
        let options = DashboardTermFilter.options(from: terms)
        years = options.years
        semesters = options.semesters
    }
}

private struct DashboardMainScopeBarView: View {
    @Binding var selectedYear: String
    @Binding var selectedSemester: String
    var options: DashboardMainScopeOptions

    var body: some View {
        HStack(alignment: .center, spacing: KLMSSpacing.comfortable) {
            Label("동기화 범위", systemImage: "calendar.badge.clock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.klmsMacPrimaryText)
            Spacer(minLength: 4)
            scopePicker("연도", selection: normalizedYearBinding, values: options.years)
                .frame(width: 132)
                .frame(minHeight: KLMSControlSize.minimumInteractive)
            scopePicker("학기", selection: normalizedSemesterBinding, values: options.semesters)
                .frame(width: 150)
                .frame(minHeight: KLMSControlSize.minimumInteractive)
            if hasActiveScope {
                Button {
                    selectedYear = DashboardTermFilter.allYears
                    selectedSemester = DashboardTermFilter.allSemesters
                } label: {
                    Label("범위 초기화", systemImage: "arrow.counterclockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .frame(minWidth: KLMSControlSize.minimumInteractive, minHeight: KLMSControlSize.minimumInteractive)
                .contentShape(Rectangle())
                .help("연도와 학기 범위를 전체로 되돌립니다.")
                .accessibilityLabel("동기화 범위 초기화")
            }
        }
        .padding(KLMSSpacing.comfortable)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
        .overlay {
            RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func scopePicker(_ title: String, selection: Binding<String>, values: [String]) -> some View {
        Picker(title, selection: selection) {
            ForEach(values, id: \.self) { value in
                Text(value).tag(value)
            }
        }
        .labelsHidden()
    }

    private var normalizedYearBinding: Binding<String> {
        Binding(
            get: { options.years.contains(selectedYear) ? selectedYear : DashboardTermFilter.allYears },
            set: { selectedYear = $0 }
        )
    }

    private var normalizedSemesterBinding: Binding<String> {
        Binding(
            get: { options.semesters.contains(selectedSemester) ? selectedSemester : DashboardTermFilter.allSemesters },
            set: { selectedSemester = $0 }
        )
    }

    private var hasActiveScope: Bool {
        selectedYear != DashboardTermFilter.allYears || selectedSemester != DashboardTermFilter.allSemesters
    }

    private var accessibilityLabel: String {
        if hasActiveScope {
            return "동기화 범위 \(selectedYear), \(selectedSemester)"
        }
        return "동기화 범위 전체 연도, 전체 학기"
    }
}

struct DashboardSummaryPresentation {
    var primaryMetrics: [Metric]
    var attentionMetrics: [Metric]
    var archiveMetrics: [Metric]

    init(snapshot: EngineSnapshot, summary: KLMSMacDashboardSummaryCache) {
        let counts = summary.visibleCounts
        let fileCount = DashboardFileMetricCounter.visibleCourseFileCount(
            snapshot: snapshot,
            selectedYear: DashboardTermFilter.allYears,
            selectedSemester: DashboardTermFilter.allSemesters,
            fallback: summary.serverDashboardItemsLoaded ? summary.serverFileCount : nil
        )
        let assignmentCount = summary.serverDashboardItemsLoaded ? summary.serverAssignmentCount : counts.assignments + summary.mailAssignmentCount
        let noticeCount = summary.serverDashboardItemsLoaded ? summary.serverNoticeCount : counts.notices
        let examCount = summary.serverDashboardItemsLoaded ? summary.serverExamCount : counts.exams + summary.mailExamCount
        let helpDeskCount = summary.serverDashboardItemsLoaded ? summary.serverHelpDeskCount : counts.helpDesk
        primaryMetrics = [
            Metric("파일", fileCount, detail: .files),
            Metric("과제", assignmentCount, detail: .assignments),
            Metric("공지", noticeCount, detail: .notices),
            Metric("시험", examCount, detail: .exams),
        ].filter { $0.value > 0 }
        attentionMetrics = [
            Metric("헬프데스크", helpDeskCount, detail: .helpDesk),
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

    @MainActor
    init(
        model: KLMSMacModel,
        snapshot: EngineSnapshot,
        summary: KLMSMacDashboardSummaryCache,
        selectedYear: String,
        selectedSemester: String
    ) {
        if selectedYear == DashboardTermFilter.allYears,
           selectedSemester == DashboardTermFilter.allSemesters {
            let base = DashboardSummaryPresentation(snapshot: snapshot, summary: summary)
            primaryMetrics = base.primaryMetrics
            attentionMetrics = base.attentionMetrics
            archiveMetrics = base.archiveMetrics
            return
        }
        let counts = DashboardScopedMetricCounts(
            model: model,
            snapshot: snapshot,
            summary: summary,
            selectedYear: selectedYear,
            selectedSemester: selectedSemester
        )
        primaryMetrics = [
            Metric("파일", counts.files, detail: .files),
            Metric("과제", counts.assignments, detail: .assignments),
            Metric("공지", counts.notices, detail: .notices),
            Metric("시험", counts.exams, detail: .exams),
        ].filter { $0.value > 0 }
        attentionMetrics = [
            Metric("헬프데스크", counts.helpDesk, detail: .helpDesk),
            Metric("캘린더", counts.calendarAttention, detail: .calendar),
            Metric("격리", counts.quarantine, detail: .quarantine),
            Metric("과제 후보", counts.assignmentCandidates, detail: .assignmentCandidates),
            Metric("시험 후보", counts.examCandidates, detail: .examCandidates),
            Metric("누락 파일", counts.missingFiles, detail: .missingFiles),
            Metric("정리된 파일", counts.prunedFiles, detail: .pruned),
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

private struct DashboardScopedMetricCounts {
    var assignments = 0
    var exams = 0
    var helpDesk = 0
    var notices = 0
    var files = 0
    var newFiles = 0
    var calendarAttention = 0
    var quarantine = 0
    var assignmentCandidates = 0
    var examCandidates = 0
    var missingFiles = 0
    var prunedFiles = 0

    @MainActor
    init(
        model: KLMSMacModel,
        snapshot: EngineSnapshot,
        summary: KLMSMacDashboardSummaryCache,
        selectedYear: String,
        selectedSemester: String
    ) {
        let content = snapshot.legacyState?.content
        assignments = Self.visibleStateCount(
            model.dashboardStateItems(for: .assignments),
            editor: .assignment,
            snapshot: snapshot,
            selectedYear: selectedYear,
            selectedSemester: selectedSemester
        )
        exams = Self.visibleStateCount(
            model.dashboardStateItems(for: .exams),
            editor: .exam,
            snapshot: snapshot,
            selectedYear: selectedYear,
            selectedSemester: selectedSemester
        )
        helpDesk = Self.visibleStateCount(
            content?.helpDeskItems ?? [],
            editor: .assignment,
            snapshot: snapshot,
            selectedYear: selectedYear,
            selectedSemester: selectedSemester
        )
        assignmentCandidates = Self.visibleStateCount(
            content?.assignmentCandidates ?? [],
            editor: .assignment,
            snapshot: snapshot,
            selectedYear: selectedYear,
            selectedSemester: selectedSemester
        )
        examCandidates = Self.visibleStateCount(
            content?.examCandidates ?? [],
            editor: .exam,
            snapshot: snapshot,
            selectedYear: selectedYear,
            selectedSemester: selectedSemester
        )
        let generatedAt = snapshot.noticeDigest?.generatedAt ?? ""
        notices = (snapshot.noticeDigest?.notices ?? []).filter { notice in
            snapshot.noticeUserState?.notices[notice.noticeIdentifier]?.hidden != true
                && DashboardTermFilter.matches(
                    notice.academicTerm(generatedAt: generatedAt, catalog: snapshot.academicTermCatalog),
                    selectedYear: selectedYear,
                    selectedSemester: selectedSemester
                )
        }.count
        files = DashboardFileMetricCounter.visibleCourseFileCount(
            snapshot: snapshot,
            selectedYear: selectedYear,
            selectedSemester: selectedSemester,
            serverItems: model.dashboardServerRelayItems(for: .files)
        )
        newFiles = DashboardTermFilter.terms(for: .newFiles, snapshot: snapshot).filter {
            DashboardTermFilter.matches($0, selectedYear: selectedYear, selectedSemester: selectedSemester)
        }.count
        calendarAttention = (
            (snapshot.calendarSyncResult?.changes ?? []) + model.mailCalendarChanges()
        )
        .dedupedForCalendarDisplay()
        .filter {
            $0.isUserVisibleCalendarChange
                && DashboardTermFilter.matches($0.academicTerm, selectedYear: selectedYear, selectedSemester: selectedSemester)
        }
        .count
        quarantine = summary.visibleCounts.quarantine
        missingFiles = DashboardTermFilter.terms(for: .missingFiles, snapshot: snapshot).filter {
            DashboardTermFilter.matches($0, selectedYear: selectedYear, selectedSemester: selectedSemester)
        }.count
        prunedFiles = DashboardTermFilter.terms(for: .pruned, snapshot: snapshot).filter {
            DashboardTermFilter.matches($0, selectedYear: selectedYear, selectedSemester: selectedSemester)
        }.count
    }

    private static func visibleStateCount(
        _ items: [StateItem],
        editor: StateItemEditorKind,
        snapshot: EngineSnapshot,
        selectedYear: String,
        selectedSemester: String
    ) -> Int {
        items.filter { item in
            !isHidden(item, editor: editor, snapshot: snapshot)
                && DashboardTermFilter.matches(
                    item.academicTerm,
                    selectedYear: selectedYear,
                    selectedSemester: selectedSemester
                )
        }.count
    }

    private static func isHidden(_ item: StateItem, editor: StateItemEditorKind, snapshot: EngineSnapshot) -> Bool {
        switch editor {
        case .assignment, .assignmentRecord:
            snapshot.manualOverrides?.isAssignmentHidden(item) == true
        case .exam:
            snapshot.manualOverrides?.isExamHidden(item) == true
        }
    }
}

enum DashboardFileMetricCounter {
    static func visibleCourseFileCount(
        snapshot: EngineSnapshot,
        selectedYear: String,
        selectedSemester: String,
        serverItems: [ServerRelaySyncItem] = [],
        fallback: Int? = nil
    ) -> Int {
        guard !snapshot.courseFileManifest.isEmpty else {
            let serverCount = serverItems.filter { item in
                item.kind == "file"
                    && !item.isHidden
                    && DashboardTermFilter.matches(
                        item.dashboardFilterAcademicTerm,
                        selectedYear: selectedYear,
                        selectedSemester: selectedSemester
                    )
            }.count
            return serverCount > 0 ? serverCount : (fallback ?? 0)
        }
        let appFileState = snapshot.appUserState?.files ?? [:]
        return snapshot.courseFileManifest.filter { entry in
            let key = fileKey(url: entry.url, path: entry.absolutePath, fallback: entry.relativePath)
            guard appFileState[key]?.isHiddenLike != true else {
                return false
            }
            return DashboardTermFilter.matches(
                entry.resolvedAcademicTerm(catalog: snapshot.academicTermCatalog),
                selectedYear: selectedYear,
                selectedSemester: selectedSemester
            )
        }.count
    }

    private static func fileKey(url: String, path: String, fallback: String) -> String {
        if !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return url
        }
        if !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return path
        }
        return fallback
    }
}

private struct DashboardRuntimePanelView: View {
    let model: KLMSMacModel

    var body: some View {
        VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
            HStack(spacing: KLMSSpacing.standard) {
                Label("연동 상태", systemImage: "link")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsMacPrimaryText)
                Spacer(minLength: 6)
                if let runtimeSummaryBadgeText {
                    Text(runtimeSummaryBadgeText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(runtimeSummaryBadgeColor)
                        .lineLimit(1)
                        .padding(.horizontal, KLMSSpacing.standard)
                        .padding(.vertical, KLMSSpacing.snug)
                        .background(runtimeSummaryBadgeColor.opacity(0.11), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
                MacRailStatusLine(text: integrationSummaryText)
                MacRailStatusLine(text: noticeMemoSummaryText)
                if let slowestSummaryText {
                    MacRailStatusLine(text: slowestSummaryText)
                }
            }
        }
        .padding(KLMSSpacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: KLMSRadius.panel)
                .stroke(Color.klmsMacBorder, lineWidth: 1)
        }
    }

    private var runtimeSummaryBadgeText: String? {
        if model.runningCommand != nil {
            return model.currentPhaseText ?? "실행 중"
        }
        if let verify = model.snapshot.verifyResult {
            return verify.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok" ? "정상" : "확인 필요"
        }
        return nil
    }

    private var runtimeSummaryBadgeColor: Color {
        if model.runningCommand != nil {
            return .klmsMacCommandAccent
        }
        if let verify = model.snapshot.verifyResult {
            return verify.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok" ? .klmsMacSuccessForeground : .klmsMacWarningForeground
        }
        return .klmsMacSecondaryText
    }

    private var integrationSummaryText: String {
        guard let verify = model.snapshot.verifyResult else {
            return "메모 · 캘린더 · 미리 알림 상태 검사 전"
        }
        return verify.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ok"
            ? "메모 · 캘린더 · 미리 알림 모두 사용 가능"
            : "메모 · 캘린더 · 미리 알림 확인 필요"
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
            .padding(.horizontal, KLMSSpacing.standardControl)
            .padding(.vertical, KLMSSpacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsMacSubtleCardBackground.opacity(0.76), in: RoundedRectangle(cornerRadius: KLMSRadius.standardSurface))
            .overlay {
                RoundedRectangle(cornerRadius: KLMSRadius.standardSurface)
                    .stroke(Color.klmsMacBorder.opacity(0.72), lineWidth: 1)
            }
    }
}

private struct RemoteActivityPanelView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        let fileRequests = model.serverRelayRecentFileAccessRequests
        let requestLog = model.serverRelayRecentRequestLog
        let sharedRunLogs = model.serverRelaySharedRunLogs
        if model.lastRemoteCommand != nil || !fileRequests.isEmpty || !requestLog.isEmpty || !sharedRunLogs.isEmpty || model.remoteProcessingStatusMessage?.nilIfBlank != nil {
            SectionBox(title: "서버·파일 요청 기록") {
                VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
                    HStack(spacing: KLMSSpacing.standard) {
                        Spacer()
                        KLMSMacConfirmedClearAction(
                            shortLabel: nil,
                            accessibilityLabel: "서버·파일 요청 기록 지우기",
                            confirmationTitle: "서버·파일 요청 기록을 지울까요?",
                            confirmationMessage: "완료된 서버 요청, 파일 요청, 항목·설정 변경과 공유 실행 로그를 지웁니다. 진행 중인 요청은 유지됩니다.",
                            confirmationButtonTitle: "요청 기록 지우기"
                        ) {
                            Task {
                                await model.clearServerRelayActivityLogs()
                            }
                        }
                        .help("서버·파일 요청 기록 지우기")
                    }

                    if let message = model.remoteProcessingStatusMessage?.nilIfBlank ?? model.serverRelayStatusMessage?.nilIfBlank {
                        HStack(alignment: .top, spacing: KLMSSpacing.standard) {
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
                        VStack(alignment: .leading, spacing: KLMSSpacing.compact) {
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
                        VStack(alignment: .leading, spacing: KLMSSpacing.compact) {
                            Text("서버 요청")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.klmsMacSecondaryText)
                            ForEach(requestLog.prefix(10)) { entry in
                                ServerRequestLogActivityRow(entry: entry)
                            }
                        }
                    }

                    if !fileRequests.isEmpty {
                        VStack(alignment: .leading, spacing: KLMSSpacing.compact) {
                            Text("파일 요청")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.klmsMacSecondaryText)
                            ForEach(fileRequests.prefix(8)) { request in
                                FileAccessActivityRow(request: request)
                            }
                        }
                    }
                }
                .padding(KLMSSpacing.comfortable)
                .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
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
            macPerformWithoutAnimation {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: KLMSSpacing.compact) {
                HStack(alignment: .top, spacing: KLMSSpacing.standard) {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: KLMSSpacing.hairline) {
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
            .padding(KLMSSpacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
            .overlay(
                RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: KLMSRadius.smallSurface))
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
        return log.needsAttention ? Color.klmsMacWarningForeground : Color.klmsMacSuccessForeground
    }
}

private struct ServerRequestLogActivityRow: View {
    var entry: ServerRelayRequestLogEntry
    @State private var isExpanded = false

    var body: some View {
        Button {
            macPerformWithoutAnimation {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: KLMSSpacing.compact) {
                HStack(alignment: .top, spacing: KLMSSpacing.standard) {
                    Image(systemName: sourceIcon)
                        .foregroundStyle(statusColor)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: KLMSSpacing.micro) {
                        HStack(spacing: KLMSSpacing.compact) {
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
            .padding(KLMSSpacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
            .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
            .overlay {
                RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                    .stroke(statusColor.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: KLMSRadius.smallSurface))
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
            return .klmsMacWarningForeground
        case "running":
            return .klmsMacCommandAccent
        default:
            return .klmsMacSuccessForeground
        }
    }
}

private struct RemoteCommandActivityRow: View {
    var command: RemoteRunCommand
    @State private var isExpanded = false

    var body: some View {
        Button {
            macPerformWithoutAnimation {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: KLMSSpacing.compact) {
                HStack(alignment: .top, spacing: KLMSSpacing.standard) {
                    Image(systemName: systemImage)
                        .foregroundStyle(statusColor)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: KLMSSpacing.micro) {
                        HStack(spacing: KLMSSpacing.compact) {
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
            .padding(KLMSSpacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
            .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
            .overlay {
                RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                    .stroke(statusColor.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: KLMSRadius.smallSurface))
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
            Color.klmsMacSuccessForeground
        case .cancelled:
            Color.klmsMacSecondaryText
        case .failed, .macUnavailable:
            Color.klmsMacWarningForeground
        }
    }
}

private struct FileAccessActivityRow: View {
    var request: ServerRelayFileAccessRequest
    @State private var isExpanded = false

    var body: some View {
        Button {
            macPerformWithoutAnimation {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: KLMSSpacing.compact) {
                HStack(alignment: .top, spacing: KLMSSpacing.standard) {
                    Image(systemName: systemImage)
                        .foregroundStyle(statusColor)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: KLMSSpacing.micro) {
                        HStack(spacing: KLMSSpacing.compact) {
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
            .padding(KLMSSpacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
            .overlay {
                RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                    .stroke(statusColor.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: KLMSRadius.smallSurface))
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
            Color.klmsMacSuccessForeground
        case .failed, .macUnavailable:
            Color.klmsMacWarningForeground
        }
    }
}

private struct CommandPanelView: View {
    @ObservedObject var model: KLMSMacModel
    var openRunLog: () -> Void
    private let secondaryCommands: [KLMSEngineCommand] = [.filesSync, .coreSync, .noticeSync]
    private let secondaryCommandColumns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: KLMSSpacing.standard), count: 3)

    var body: some View {
        SectionBox(title: "동기화") {
            VStack(alignment: .leading, spacing: KLMSSpacing.comfortable) {
                commandStatusStrip

                MacPrimarySyncActionView(model: model)

                LazyVGrid(columns: secondaryCommandColumns, spacing: KLMSSpacing.standard) {
                    ForEach(secondaryCommands, id: \.self) { command in
                        commandActionCard(command)
                    }
                }

                MacMailPasteAnalyzerPanel(model: model, snapshot: model.snapshot)
            }

            if let command = model.runningCommand {
                HStack(spacing: KLMSSpacing.comfortable) {
                    Label(
                        model.isCancellingCommand ? "중단 요청 중입니다" : "\(command.displayName) 실행 중",
                        systemImage: model.isCancellingCommand ? "hourglass" : "play.circle"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    Button(role: .destructive) {
                        let expectedIdentity = model.runningCommandIdentity
                        Task {
                            await model.cancelRunningCommand(expectedIdentity: expectedIdentity)
                        }
                    } label: {
                        Image(systemName: model.isCancellingCommand ? "hourglass" : "stop.fill")
                    }
                    .buttonStyle(KLMSMacCompactDangerIconButtonStyle())
                    .disabled(model.isCancellingCommand)
                    .help("\(command.displayName) 실행을 중단합니다.")
                    .accessibilityLabel("\(command.displayName) 중단")
                    .accessibilityHint("현재 실행 중인 동기화를 중단합니다.")
                    .accessibilityIdentifier("command-cancel-current")
                }
                .padding(.horizontal, KLMSSpacing.comfortable)
                .padding(.vertical, KLMSSpacing.standard)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.klmsMacSubtleCardBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: KLMSRadius.standardSurface))
                .overlay {
                    RoundedRectangle(cornerRadius: KLMSRadius.standardSurface)
                        .stroke(Color.klmsMacDangerBorder.opacity(0.24), lineWidth: 1)
                }
            }
        }
    }

    private var commandStatusStrip: some View {
        Button {
            if canOpenRunLog {
                openRunLog()
            }
        } label: {
            VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
                HStack(alignment: .center, spacing: KLMSSpacing.standard) {
                    Image(systemName: commandStatusImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(commandStatusColor)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: KLMSSpacing.hairline) {
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
                    if canOpenRunLog {
                        Image(systemName: "text.alignleft")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.klmsMacSecondaryText)
                    }
                }
                if let command = model.runningCommand {
                    MacRunningProgressBarView(
                        progress: MacRunningProgressSnapshot(
                            command: command,
                            phaseText: model.currentPhaseText
                        )
                    )
                }
            }
            .padding(.horizontal, KLMSSpacing.comfortable)
            .padding(.vertical, KLMSSpacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsMacSubtleCardBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: KLMSRadius.standardSurface))
            .overlay {
                RoundedRectangle(cornerRadius: KLMSRadius.standardSurface)
                    .stroke(commandStatusColor.opacity(model.runningCommand == nil ? 0.18 : 0.36), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.standardSurface))
        }
        .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: KLMSRadius.standardSurface, disabledOpacity: 1.0))
        .disabled(!canOpenRunLog)
        .help(canOpenRunLog ? "최근 실행 로그 보기" : "실행 기록이 생기면 로그를 볼 수 있습니다.")
        .accessibilityLabel(commandStatusText)
        .accessibilityHint(canOpenRunLog ? "실행 로그 탭으로 이동합니다." : commandStatusDetailText)
    }

    private func commandActionCard(_ command: KLMSEngineCommand) -> some View {
        let isRunning = model.runningCommand == command
        let isDisabled = model.runningCommand != nil && !isRunning
        return Button {
            runOrCancel(command)
        } label: {
            HStack(spacing: KLMSSpacing.snug) {
                if let systemImage = secondaryCommandSystemImage(isRunning: isRunning, isDisabled: isDisabled) {
                    Image(systemName: systemImage)
                        .font(.system(size: KLMSTypeSize.compactStatus, weight: .black, design: .rounded))
                }
                VStack(spacing: KLMSSpacing.hairline) {
                    Text(shortTitle(for: command))
                        .font(.system(size: KLMSTypeSize.footnoteBadge, weight: .heavy, design: .rounded))
                    if isRunning {
                        Text(model.currentPhaseText ?? "진행 중")
                            .font(.system(size: KLMSTypeSize.compactStatus, weight: .semibold, design: .rounded))
                            .opacity(0.78)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            }
            .foregroundStyle(secondaryCommandForeground(isRunning: isRunning, isDisabled: isDisabled))
            .frame(maxWidth: .infinity, minHeight: KLMSControlSize.minimumInteractive, alignment: .center)
            .padding(.horizontal, KLMSSpacing.standard)
            .padding(.vertical, KLMSSpacing.standardControl)
            .background(
                secondaryCommandBackground(isRunning: isRunning, isDisabled: isDisabled),
                in: RoundedRectangle(cornerRadius: KLMSRadius.control)
            )
            .overlay {
                RoundedRectangle(cornerRadius: KLMSRadius.control)
                    .stroke(
                        secondaryCommandBorder(isRunning: isRunning, isDisabled: isDisabled),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.control))
        }
        .buttonStyle(MacPressFeedbackButtonStyle(disabledOpacity: 1.0))
        .controlSize(.small)
        .help(command.shortDescription)
        .accessibilityLabel(isRunning ? "\(command.displayName) 중단" : "\(command.displayName) 실행")
        .accessibilityHint(command.shortDescription)
        .accessibilityValue(isRunning ? "실행 중, 누르면 중단" : (isDisabled ? "다른 동기화 실행 중, 사용 불가" : "실행 가능"))
        .accessibilityIdentifier("command-\(command.rawValue)")
        .disabled(isDisabled)
    }

    private func runOrCancel(_ command: KLMSEngineCommand) {
        let intent = MacCommandActionIntent.capture(
            command: command,
            runningIdentity: model.runningCommandIdentity
        )
        Task {
            switch intent {
            case let .run(command):
                await model.run(command)
            case let .cancel(expectedIdentity):
                await model.cancelRunningCommand(expectedIdentity: expectedIdentity)
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

    private func secondaryCommandSystemImage(isRunning: Bool, isDisabled: Bool) -> String? {
        if isRunning { return "stop.fill" }
        if isDisabled { return "lock.fill" }
        return nil
    }

    private func secondaryCommandForeground(isRunning: Bool, isDisabled: Bool) -> Color {
        if isDisabled { return Color.klmsMacSecondaryText.opacity(0.64) }
        if isRunning { return Color.klmsMacDangerForeground }
        return Color.klmsMacSecondaryCommandButtonForeground
    }

    private func secondaryCommandBackground(isRunning: Bool, isDisabled: Bool) -> Color {
        if isDisabled { return Color.klmsMacSubtleCardBackground.opacity(0.70) }
        return isRunning ? Color.klmsMacDangerBorder.opacity(0.10) : Color.klmsMacCommandButtonBackground.opacity(0.88)
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
            return result.succeeded ? "필요하면 바로 다시 실행할 수 있습니다." : "로그 탭에서 마지막 오류를 확인하세요."
        }
        return "전체 동기화 또는 개별 동기화를 실행하세요."
    }

    private var canOpenRunLog: Bool {
        model.runningCommand != nil
            || model.lastCommandResult != nil
            || !model.commandHistory.records.isEmpty
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
            return result.succeeded ? Color.klmsMacSuccessForeground : Color.klmsMacWarningForeground
        }
        return .klmsMacSecondaryText
    }

}

private struct CommandStageDurationSummaryView: View {
    var durations: [KLMSStageDuration]

    var body: some View {
        if !durations.isEmpty {
            VStack(alignment: .leading, spacing: KLMSSpacing.compact) {
                Text("단계별 소요 시간")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsMacSecondaryText)
                VStack(spacing: KLMSSpacing.compact) {
                    ForEach(durations) { duration in
                        HStack(spacing: KLMSSpacing.compact) {
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
                        .padding(.horizontal, KLMSSpacing.standard)
                        .padding(.vertical, KLMSSpacing.compact)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
                    }
                }
            }
        }
    }

    private func tint(for stage: String) -> Color {
        switch stage {
        case "core":
            return .klmsMacWarningForeground
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
            VStack(alignment: .leading, spacing: KLMSSpacing.compact) {
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
        VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
            Button {
                macPerformWithoutAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: KLMSSpacing.standard) {
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
                        .padding(.horizontal, KLMSSpacing.standard)
                        .padding(.vertical, KLMSSpacing.tight)
                        .background(Color.klmsMacSubtleCardBackground, in: Capsule())
                }
                .padding(.horizontal, KLMSSpacing.standardControl)
                .padding(.vertical, KLMSSpacing.standard)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.klmsMacSubtleCardBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: KLMSRadius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: KLMSRadius.control)
                        .stroke(Color.klmsMacCommandBorder.opacity(0.62), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.control))
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
                .foregroundStyle(login?.loggedIn == true ? Color.klmsMacSecondaryText : Color.klmsMacWarningForeground)
            if let checkedAt = login?.checkedAt {
                Text(checkedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(Color.klmsMacSecondaryText)
            }
            if let digits = model.currentAuthDigits {
                HStack(spacing: KLMSSpacing.standard) {
                    Text("인증 번호")
                        .font(.caption)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                    Text(digits)
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.klmsMacWarningForeground)
                }
            }
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
                VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
                    Text(summaryText(for: verify, checkSummary: checkSummary))
                        .font(.caption)
                        .foregroundStyle(!checkSummary.hasIssues && verify.status.lowercased() == "ok" ? Color.klmsMacSecondaryText : Color.klmsMacWarningForeground)
                        .fixedSize(horizontal: false, vertical: true)

                    if !checkSummary.hasIssues {
                        Text("정상 항목은 필요할 때만 펼쳐서 확인합니다.")
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
                        title: checkSummary.hasIssues ? "전체 상태 검사 항목 \(verify.checks.count)개" : "정상 항목 \(checkSummary.okCount)개 보기",
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
            return "문제 없음"
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
        HStack(alignment: .top, spacing: KLMSSpacing.standard) {
            if !compact {
                RoundedRectangle(cornerRadius: KLMSRadius.indicator)
                    .fill(color.opacity(isIssue ? 0.72 : 0.24))
                    .frame(width: 3)
            }
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: compact ? KLMSSpacing.hairline : KLMSSpacing.tight) {
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
                    .padding(.top, KLMSSpacing.optical)
                }
            }
        }
        .padding(compact ? KLMSSpacing.compact : KLMSSpacing.standardControl)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
        .overlay {
            RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
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
            return .klmsMacDangerForeground
        }
        if ["warn", "warning"].contains(check.status.lowercased()) {
            return .klmsMacWarningForeground
        }
        return .klmsMacSuccessForeground
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
                    .foregroundStyle(!checkSummary.hasIssues && doctor.status.lowercased() == "ok" ? Color.klmsMacSecondaryText : Color.klmsMacWarningForeground)

                if !checkSummary.hasIssues {
                    Text("정상 항목은 필요할 때만 펼쳐서 확인합니다.")
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
                    title: checkSummary.hasIssues ? "전체 진단 항목 \(doctor.checks.count)개" : "정상 항목 \(checkSummary.okCount)개 보기",
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
            return "문제 없음"
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
        VStack(alignment: .leading, spacing: compact ? KLMSSpacing.snug : KLMSSpacing.compactControl) {
            Button {
                macPerformWithoutAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: KLMSSpacing.compactControl) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .frame(width: 12)
                    Text(title)
                        .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.klmsMacSecondaryText)
                .padding(.horizontal, compact ? KLMSSpacing.compact : KLMSSpacing.standard)
                .padding(.vertical, compact ? KLMSSpacing.tight : KLMSSpacing.compact)
                .frame(maxWidth: .infinity, minHeight: KLMSControlSize.minimumInteractive, alignment: .leading)
                .background(Color.klmsMacSubtleCardBackground.opacity(compact ? 0.18 : 0.30), in: RoundedRectangle(cornerRadius: KLMSRadius.compactControl))
                .overlay {
                    RoundedRectangle(cornerRadius: KLMSRadius.compactControl)
                        .stroke(Color.klmsMacBorder.opacity(compact ? 0.20 : 0.34), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.compactControl))
            }
            .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: KLMSRadius.compactControl))
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "펼쳐짐" : "접힘")
            .accessibilityHint(isExpanded ? "\(title) 접기" : "\(title) 펼치기")

            DeferredMacInteractionExpansion(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: compact ? KLMSSpacing.snug : KLMSSpacing.compact) {
                    content()
                }
                .padding(.top, compact ? KLMSSpacing.optical : KLMSSpacing.micro)
            }
        }
        .padding(compact ? 0 : KLMSSpacing.compactControl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? Color.clear : Color.klmsMacSubtleCardBackground.opacity(0.34), in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
    }
}

private struct DoctorCheckRowView: View {
    var check: DoctorCheck
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: KLMSSpacing.standard) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: KLMSSpacing.hairline) {
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
        .padding(compact ? KLMSSpacing.compact : KLMSSpacing.standard)
        .background(compact ? Color.klmsMacSubtleCardBackground : Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
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
            return .klmsMacDangerForeground
        }
        if ["warn", "warning"].contains(check.status.lowercased()) {
            return .klmsMacWarningForeground
        }
        return .klmsMacSuccessForeground
    }
}

private struct AppDiagnosticsPanelView: View {
    @ObservedObject var model: KLMSMacModel
    @State private var isExpanded = false
    @State private var isPermissionScopeExpanded = false
    private let permissionActionColumns = [GridItem(.adaptive(minimum: 136), spacing: KLMSSpacing.standard)]

    var body: some View {
        SectionBox(title: "앱/설치 정보") {
            let diagnostics = model.appDiagnostics
            HStack(spacing: KLMSSpacing.standardControl) {
                Image(systemName: "app.badge.checkmark")
                    .foregroundStyle(diagnostics.codeSigning.needsAttention ? Color.klmsMacWarningForeground : Color.klmsMacSecondaryText)
                VStack(alignment: .leading, spacing: KLMSSpacing.hairline) {
                    Text(diagnostics.codeSigning.needsAttention ? "권한이나 서명 상태를 확인하세요." : "앱과 엔진 상태가 준비되어 있습니다.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.klmsMacPrimaryText)
                    Text(diagnostics.installedPayloadVersion.isEmpty ? "엔진 설치 상태 확인 필요" : "엔진 \(diagnostics.installedPayloadVersion)")
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(KLMSSpacing.standard)
            .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))

            HStack(alignment: .top, spacing: KLMSSpacing.standardControl) {
                Image(systemName: localRealtimeSystemImage)
                    .foregroundStyle(localRealtimeColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: KLMSSpacing.hairline) {
                    Text("로컬 실시간 반영 · \(model.fileSystemRealtimeStatusTitle)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.klmsMacPrimaryText)
                    Text(model.fileSystemRealtimeStatusDetail)
                        .font(.caption2)
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if model.fileSystemRealtimeNeedsAttention {
                    Button {
                        Task {
                            await model.retryFileSystemEventRefresh()
                        }
                    } label: {
                        Label("다시 연결", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(KLMSMacRootActionButtonStyle())
                    .disabled(model.runningCommand != nil)
                    .accessibilityIdentifier("local-realtime-retry")
                }
            }
            .padding(KLMSSpacing.standard)
            .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
            .overlay {
                RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                    .stroke(
                        model.fileSystemRealtimeNeedsAttention
                            ? Color.klmsMacWarningBorder.opacity(0.34)
                            : Color.klmsMacBorder.opacity(0.58),
                        lineWidth: 1
                    )
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("local-realtime-status")

            DiagnosticChecksDisclosure(
                title: "설치·권한 세부 정보",
                isExpanded: $isExpanded
            ) {
                VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
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

                    LazyVGrid(columns: permissionActionColumns, alignment: .leading, spacing: KLMSSpacing.standard) {
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
                        VStack(alignment: .leading, spacing: KLMSSpacing.compact) {
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
                        VStack(alignment: .leading, spacing: KLMSSpacing.compact) {
                            PermissionScopeText("손쉬운 사용: 시스템 설정에서 KLMS Sync를 켜야 합니다. KLMS 공지 메모 렌더러가 따로 보이면 그것도 켜 주세요.")
                            PermissionScopeText("손쉬운 사용 사용처: Notes 편집 영역 포커스 확인, 체크리스트와 문단 서식 적용")
                            PermissionScopeText("자동화 · Safari: KLMS 로그인 확인, 페이지 수집, 파일 다운로드")
                            PermissionScopeText("자동화 · Notes: 공지 메모 열기, 선택, 본문 갱신")
                            PermissionScopeText("자동화 · System Events: Notes 메뉴 조작과 포커스 확인")
                            PermissionScopeText("자동화 · 캘린더/미리 알림: 기존 스크립트와 상태 확인 경로")
                            PermissionScopeText("캘린더/미리 알림 전체 접근: 일정과 미리 알림 동기화")
                            PermissionScopeText("알림: KAIST 인증번호와 실패 상태를 앱에서 바로 표시")
                        }
                        .padding(.top, KLMSSpacing.tight)
                    }
                    .font(.caption)
                }
                .padding(.top, KLMSSpacing.compact)
            }
        }
    }

    private var signingIdentityText: String {
        guard let count = model.appDiagnostics.codeSigning.validIdentityCount else {
            return "확인 불가"
        }
        return count == 0 ? "사용 가능한 인증서 없음" : "\(count)개 사용 가능"
    }

    private var localRealtimeSystemImage: String {
        if model.fileSystemRealtimeNeedsAttention {
            return "exclamationmark.arrow.triangle.2.circlepath"
        }
        return model.fileSystemRealtimeIsActive ? "bolt.horizontal.circle.fill" : "clock"
    }

    private var localRealtimeColor: Color {
        if model.fileSystemRealtimeNeedsAttention {
            return .klmsMacWarningForeground
        }
        return model.fileSystemRealtimeIsActive ? .klmsMacSuccessForeground : .klmsMacSecondaryText
    }
}

private struct PermissionScopeText: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: KLMSSpacing.compact) {
            Image(systemName: "circle.fill")
                .font(.system(size: KLMSTypeSize.microIndicator))
                .foregroundStyle(Color.klmsMacSecondaryText)
                .padding(.top, KLMSSpacing.compact)
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
        HStack(alignment: .top, spacing: KLMSSpacing.standard) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isWarning ? Color.klmsMacWarningForeground : Color.klmsMacSuccessForeground)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: KLMSSpacing.hairline) {
                Text("\(title): \(value)")
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(KLMSSpacing.standard)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
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
    @ObservedObject var model: KLMSMacModel
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
        VStack(alignment: .leading, spacing: KLMSSpacing.section) {
            VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
                HStack(spacing: KLMSSpacing.standard) {
                    Button {
                        macPerformWithoutAnimation {
                            isHistoryExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: KLMSSpacing.standard) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(Color.klmsMacSecondaryText)
                            Text("실행 로그")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.klmsMacPrimaryText)
                            if !isHistoryExpanded {
                                Text("\(records.count)개")
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(Color.klmsMacSecondaryText)
                                    .padding(.horizontal, KLMSSpacing.compactControl)
                                    .padding(.vertical, KLMSSpacing.micro)
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
                    .padding(.vertical, KLMSSpacing.tight)
                    .contentShape(Rectangle())
                    .accessibilityLabel("실행 로그")
                    .accessibilityValue(isHistoryExpanded ? "펼쳐짐" : "접힘")
                    .accessibilityHint(isHistoryExpanded ? "실행 로그 접기" : "실행 로그 펼치기")

                    KLMSMacConfirmedClearAction(
                        shortLabel: nil,
                        accessibilityLabel: "실행 로그 지우기",
                        confirmationTitle: "실행 로그를 지울까요?",
                        confirmationMessage: "저장된 실행 기록과 현재 화면의 완료 로그를 지웁니다.",
                        confirmationButtonTitle: "실행 로그 지우기"
                    ) {
                        model.clearExecutionRunLogs()
                    }
                    .help("실행 로그 지우기")
                }

                if isHistoryExpanded {
                    let summary = RunLogArchiveSummary(records: records)
                    VStack(alignment: .leading, spacing: KLMSSpacing.comfortable) {
                        Text("각 실행 기록을 펼치면 마지막 로그를 볼 수 있습니다.")
                            .font(.caption)
                            .foregroundStyle(Color.klmsMacSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: KLMSSpacing.standard)], spacing: KLMSSpacing.standard) {
                            RunLogStatChip(title: "전체", value: "\(summary.total)", systemImage: "tray.full", tint: .klmsMacCommandAccent)
                            RunLogStatChip(title: "성공", value: "\(summary.succeeded)", systemImage: "checkmark.circle", tint: Color.klmsMacSuccessForeground)
                            RunLogStatChip(title: "실패", value: "\(summary.needsAttention)", systemImage: "exclamationmark.triangle", tint: Color.klmsMacWarningForeground)
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
            .padding(KLMSSpacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.klmsMacCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: KLMSRadius.panel)
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
                        LazyVStack(alignment: .leading, spacing: KLMSSpacing.standard) {
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
                                    .padding(KLMSSpacing.standardControl)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
                                }
                                .buttonStyle(MacPressFeedbackButtonStyle())
                            }
                        }
                    }
                }
            }

            SectionBox(title: "서버 로그") {
                VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
                    HStack(spacing: KLMSSpacing.standard) {
                        Button {
                            macPerformWithoutAnimation {
                                showingSystemLogs.toggle()
                            }
                        } label: {
                            HStack(spacing: KLMSSpacing.standard) {
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
                        .accessibilityLabel("서버 로그")
                        .accessibilityValue(showingSystemLogs ? "펼쳐짐" : "접힘")
                        .accessibilityHint(showingSystemLogs ? "서버 로그 접기" : "서버 로그 펼치기")

                        KLMSMacConfirmedClearAction(
                            shortLabel: nil,
                            accessibilityLabel: "서버 로그 지우기",
                            confirmationTitle: "서버 로그를 지울까요?",
                            confirmationMessage: "이 Mac에 저장된 서버 릴레이 로그를 지웁니다.",
                            confirmationButtonTitle: "서버 로그 지우기"
                        ) {
                            model.clearLocalRelayLogs()
                        }
                        .help("서버 로그 지우기")
                    }

                    if showingSystemLogs {
                        VStack(alignment: .leading, spacing: KLMSSpacing.comfortable) {
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
                        .padding(.top, KLMSSpacing.compact)
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
        HStack(spacing: KLMSSpacing.compactControl) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: KLMSSpacing.hairline) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(Color.klmsMacSecondaryText)
                Text(value)
                    .font(.caption.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(KLMSSpacing.standard)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
        .overlay {
            RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
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
                VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
                    HStack(spacing: KLMSSpacing.standard) {
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
            return result.succeeded ? Color.klmsMacSuccessForeground : Color.klmsMacWarningForeground
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
                HStack(alignment: .top, spacing: KLMSSpacing.comfortable) {
                    Image(systemName: statusImage)
                        .foregroundStyle(statusColor)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: KLMSSpacing.micro) {
                        HStack(spacing: KLMSSpacing.compact) {
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
                    VStack(alignment: .trailing, spacing: KLMSSpacing.tight) {
                        Text(record.statusText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.klmsMacSecondaryText)
                    }
                }
                .padding(KLMSSpacing.standardControl)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
            }
            .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: KLMSRadius.smallSurface))
            .accessibilityLabel("\(record.command.displayName) 실행 로그 \(isExpanded ? "펼쳐짐" : "접힘")")
            .accessibilityHint(isExpanded ? "실행 로그 접기" : "실행 로그 펼치기")

            DeferredMacInteractionExpansion(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
                    HStack(spacing: KLMSSpacing.standard) {
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
                .padding(.horizontal, KLMSSpacing.standardControl)
                .padding(.bottom, KLMSSpacing.standardControl)
            }
        }
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
        .overlay {
            RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
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
        return record.succeeded ? .klmsMacSuccessForeground : .klmsMacWarningForeground
    }
}

private struct CompactStageDurationRowsView: View {
    var durations: [KLMSStageDuration]
    private static let visibleLimit = 4

    var body: some View {
        if !durations.isEmpty {
            VStack(alignment: .leading, spacing: KLMSSpacing.hairline) {
                ForEach(visibleDurations) { duration in
                    HStack(spacing: KLMSSpacing.tight) {
                        Text(duration.displayName)
                            .font(.caption2.weight(.semibold))
                        Text(duration.secondsText)
                            .font(.caption2)
                    }
                    .foregroundStyle(Color.klmsMacSecondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                if remainingCount > 0 {
                    Text("+\(remainingCount)단계")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.klmsMacSecondaryText)
                        .lineLimit(1)
                }
            }
        }
    }

    private var visibleDurations: [KLMSStageDuration] {
        Array(durations.prefix(Self.visibleLimit))
    }

    private var remainingCount: Int {
        max(0, durations.count - Self.visibleLimit)
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
            VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
                Button {
                    macPerformWithoutAnimation {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .center, spacing: KLMSSpacing.standard) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.klmsMacWarningForeground)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: KLMSSpacing.hairline) {
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
                            .foregroundStyle(Color.klmsMacWarningForeground)
                            .padding(.horizontal, KLMSSpacing.standard)
                            .padding(.vertical, KLMSSpacing.tight)
                            .background(Color.klmsMacWarningBackground, in: Capsule())
                    }
                    .padding(KLMSSpacing.standardControl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
                    .overlay {
                        RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                            .stroke(Color.klmsMacWarningBorder.opacity(0.24), lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
                }
                .buttonStyle(MacPressFeedbackButtonStyle())
                .accessibilityLabel("\(compactTitle) \(issues.count)개 \(isExpanded ? "펼쳐짐" : "접힘")")
                .accessibilityHint(isExpanded ? "확인 항목 접기" : "확인 항목 펼치기")

                if isExpanded {
                    VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
                        ForEach(primaryIssues) { issue in
                            IssueRowView(issue: issue)
                        }
                        if !remainingIssues.isEmpty {
                            Button {
                                macPerformWithoutAnimation {
                                    isRemainingIssuesExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: KLMSSpacing.compact) {
                                    Image(systemName: isRemainingIssuesExpanded ? "chevron.down" : "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .frame(width: 12)
                                    Text("나머지 확인 항목 \(remainingIssues.count)개")
                                        .font(.caption2.weight(.semibold))
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(Color.klmsMacSecondaryText)
                                .padding(.horizontal, KLMSSpacing.standard)
                                .padding(.vertical, KLMSSpacing.compact)
                                .background(Color.klmsMacSubtleCardBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
                                .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
                            }
                            .buttonStyle(MacPressFeedbackButtonStyle())
                            .accessibilityLabel("나머지 확인 항목 \(remainingIssues.count)개 \(isRemainingIssuesExpanded ? "펼쳐짐" : "접힘")")
                            .accessibilityHint(isRemainingIssuesExpanded ? "나머지 확인 항목 접기" : "나머지 확인 항목 펼치기")

                            if isRemainingIssuesExpanded {
                                VStack(alignment: .leading, spacing: KLMSSpacing.compact) {
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
        HStack(alignment: .top, spacing: KLMSSpacing.standard) {
            RoundedRectangle(cornerRadius: KLMSRadius.indicator)
                .fill(issue.severity.color.opacity(0.68))
                .frame(width: 3)
            Image(systemName: issue.severity.systemImage)
                .foregroundStyle(issue.severity.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: KLMSSpacing.hairline) {
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
        .padding(compact ? KLMSSpacing.compactControl : KLMSSpacing.standardControl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.klmsMacSubtleCardBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.smallSurface))
        .overlay {
            RoundedRectangle(cornerRadius: KLMSRadius.smallSurface)
                .stroke(issue.severity.color.opacity(0.30), lineWidth: 1)
        }
    }
}

private extension EngineIssue.Severity {
    var color: Color {
        switch self {
        case .warning:
            Color.klmsMacWarningForeground
        case .error:
            Color.klmsMacDangerForeground
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
        HStack(spacing: KLMSSpacing.standard) {
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
        .accessibilityIdentifier("top-utility-actions")
    }

    private func utilityLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.klmsMacPrimaryText)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, KLMSSpacing.comfortable)
            .padding(.vertical, KLMSSpacing.compactControl)
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
        [
            GridItem(.adaptive(minimum: 118, maximum: 180), spacing: KLMSSpacing.standard),
        ]
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
        LazyVGrid(columns: columns, spacing: KLMSSpacing.standard) {
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
                    .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: KLMSRadius.prominentCard))
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
        VStack(alignment: .leading, spacing: KLMSSpacing.compact) {
            HStack(alignment: .top, spacing: KLMSSpacing.standard) {
                VStack(alignment: .leading, spacing: KLMSSpacing.tight) {
                    Text("\(metric.value)")
                        .font(.system(size: KLMSTypeSize.prominentMetric, weight: .bold, design: .rounded).monospacedDigit())
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
        .padding(KLMSSpacing.comfortable)
        .background(metricBackground, in: RoundedRectangle(cornerRadius: KLMSRadius.prominentCard))
        .overlay {
            RoundedRectangle(cornerRadius: KLMSRadius.prominentCard)
                .stroke(metricBorder, lineWidth: isSelected ? 1.4 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.prominentCard))
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
            return .klmsMacWarningForeground
        case .exams, .examCandidates, .calendar:
            return .klmsMacSuccessForeground
        case .notices:
            return .klmsMacCommandAccent
        case .files, .missingFiles, .newFiles:
            return .klmsMacSecondaryText
        case .quarantine, .pruned:
            return .klmsMacDangerForeground
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
        VStack(alignment: .leading, spacing: KLMSSpacing.comfortableControl) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(titleColor)
            VStack(alignment: .leading, spacing: KLMSSpacing.standardControl) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(KLMSSpacing.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: KLMSRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: KLMSRadius.panel)
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
        VStack(alignment: .leading, spacing: KLMSSpacing.standard) {
            Button {
                macPerformWithoutAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: KLMSSpacing.standard) {
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
                .padding(.horizontal, KLMSSpacing.comfortable)
                .frame(maxWidth: .infinity, minHeight: KLMSControlSize.minimumInteractive, alignment: .leading)
                .background(Color.klmsMacSubtleCardBackground.opacity(0.52), in: RoundedRectangle(cornerRadius: KLMSRadius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: KLMSRadius.control)
                        .stroke(Color.klmsMacBorder.opacity(0.58), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.control))
            }
            .buttonStyle(MacPressFeedbackButtonStyle(cornerRadius: KLMSRadius.control))
            .accessibilityLabel("\(title) \(isExpanded ? "펼쳐짐" : "접힘")")
            .accessibilityHint(isExpanded ? "\(title) 접기" : "\(title) 펼치기")
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: KLMSRadius.control))

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

    static var klmsMacWarningForeground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.360, green: 0.270, blue: 0.080, alpha: 1.0),
            dark: NSColor(red: 0.920, green: 0.780, blue: 0.460, alpha: 1.0)
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

    static var klmsMacDangerForeground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.510, green: 0.180, blue: 0.140, alpha: 1.0),
            dark: NSColor(red: 0.960, green: 0.640, blue: 0.560, alpha: 1.0)
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

    static var klmsMacSuccessForeground: Color {
        klmsMacAdaptiveColor(
            light: NSColor(red: 0.200, green: 0.340, blue: 0.140, alpha: 1.0),
            dark: NSColor(red: 0.700, green: 0.860, blue: 0.610, alpha: 1.0)
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
        case "created":
            "생성됨"
        case "updated":
            "갱신됨"
        case "stable", "unchanged", "noop", "stable-noop":
            "변경 없음"
        case "deleted", "removed", "cleared":
            "삭제됨"
        case "pending", "queued":
            "대기 중"
        case "cancelled", "canceled":
            "취소됨"
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
