import KLMSShared
import AppKit
import Combine
import SwiftUI

@main
enum KLMSMacMain {
    @MainActor
    static func main() {
        KLMSLaunchState.clearSavedApplicationState()
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        let app = NSApplication.shared
        let delegate = KLMSAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

enum KLMSAppearanceMode: String, CaseIterable, Identifiable {
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

enum KLMSMacWindowID {
    static let dashboard = "klms-dashboard"
}

private enum KLMSLaunchState {
    static func clearSavedApplicationState() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let savedStateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State")
            .appendingPathComponent("\(identifier).savedState")
        try? FileManager.default.removeItem(at: savedStateURL)
    }
}

private struct KLMSMacWorkspaceRootContainerView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        MenuBarRootView(model: model)
            .klmsPreferredAppearance()
    }
}

private struct KLMSMacDeferredWorkspaceRootContainerView: View {
    @ObservedObject var model: KLMSMacModel
    @State private var isReady = false

    var body: some View {
        Group {
            if isReady {
                KLMSMacWorkspaceRootContainerView(model: model)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("KLMS Sync")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("화면을 준비하고 있습니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ProgressView()
                        .controlSize(.small)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.klmsMacScreenBackground)
                .klmsPreferredAppearance()
            }
        }
        .onAppear {
            guard !isReady else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isReady = true
            }
        }
    }
}

private struct KLMSPreferredAppearanceModifier: ViewModifier {
    @AppStorage("KLMSAppearanceMode") private var appearanceMode = KLMSAppearanceMode.system.rawValue

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(KLMSAppearanceMode(rawValue: appearanceMode)?.colorScheme)
            .onAppear {
                Self.schedulePlatformAppearance(appearanceMode)
            }
            .onChange(of: appearanceMode) { _, newValue in
                Self.schedulePlatformAppearance(newValue)
            }
    }

    private static func schedulePlatformAppearance(_ rawValue: String) {
        Task { @MainActor in
            applyPlatformAppearance(rawValue)
        }
    }

    @MainActor
    private static func applyPlatformAppearance(_ rawValue: String) {
        let mode = KLMSAppearanceMode(rawValue: rawValue) ?? .system
        let appearance: NSAppearance?
        switch mode {
        case .system:
            appearance = nil
        case .light:
            appearance = NSAppearance(named: .aqua)
        case .dark:
            appearance = NSAppearance(named: .darkAqua)
        }

        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }
}

private extension View {
    func klmsPreferredAppearance() -> some View {
        modifier(KLMSPreferredAppearanceModifier())
    }
}

private enum KLMSMenuBarStatusIconState {
    case authDigits(String)
    case ready
    case running
    case attention

    @MainActor
    init(model: KLMSMacModel) {
        if let digits = model.currentAuthDigits {
            self = .authDigits(digits)
        } else if model.runningCommand != nil {
            self = .running
        } else if model.needsAttention {
            self = .attention
        } else {
            self = .ready
        }
    }

    var tooltip: String {
        switch self {
        case let .authDigits(digits):
            "KLMS Sync 인증 번호 \(digits)"
        case .ready:
            "KLMS Sync 준비됨"
        case .running:
            "KLMS Sync 실행 중"
        case .attention:
            "KLMS Sync 확인 필요"
        }
    }

    var menuBarTitle: String {
        switch self {
        case let .authDigits(digits):
            "인증 \(digits)"
        case .ready, .running, .attention:
            ""
        }
    }
}

private enum KLMSMenuBarStatusIcon {
    static func image(for state: KLMSMenuBarStatusIconState) -> NSImage {
        let size = NSSize(width: 19, height: 19)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let ink = NSColor.black.withAlphaComponent(0.94)
        ink.setStroke()
        ink.setFill()

        drawSyncArc()
        drawDocument()
        drawStateBadge(state)
        image.unlockFocus()
        image.isTemplate = true
        image.accessibilityDescription = state.tooltip
        return image
    }

    private static func drawDocument() {
        let page = NSBezierPath(
            roundedRect: NSRect(x: 4.6, y: 3.4, width: 9.9, height: 12.2),
            xRadius: 2.2,
            yRadius: 2.2
        )
        page.lineWidth = 1.35
        page.stroke()

        let title = NSBezierPath(roundedRect: NSRect(x: 6.8, y: 12.2, width: 5.5, height: 1.25), xRadius: 0.62, yRadius: 0.62)
        title.fill()

        for y in [9.2, 7.0] {
            let box = NSBezierPath(roundedRect: NSRect(x: 6.2, y: y - 0.35, width: 1.05, height: 1.05), xRadius: 0.25, yRadius: 0.25)
            box.lineWidth = 0.85
            box.stroke()
            let line = NSBezierPath()
            line.lineWidth = 1.15
            line.lineCapStyle = .round
            line.move(to: NSPoint(x: 8.25, y: y + 0.15))
            line.line(to: NSPoint(x: 12.3, y: y + 0.15))
            line.stroke()
        }
    }

    private static func drawSyncArc() {
        let arc = NSBezierPath()
        arc.lineWidth = 1.25
        arc.lineCapStyle = .round
        arc.appendArc(
            withCenter: NSPoint(x: 9.5, y: 9.4),
            radius: 6.65,
            startAngle: 128,
            endAngle: -42,
            clockwise: true
        )
        arc.stroke()

        let arrow = NSBezierPath()
        arrow.lineWidth = 1.25
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: 15.5, y: 7.8))
        arrow.line(to: NSPoint(x: 16.8, y: 7.4))
        arrow.line(to: NSPoint(x: 16.0, y: 6.3))
        arrow.stroke()
    }

    private static func drawStateBadge(_ state: KLMSMenuBarStatusIconState) {
        let ink = NSColor.black.withAlphaComponent(0.98)
        ink.setStroke()
        ink.setFill()
        switch state {
        case .authDigits:
            let badge = NSBezierPath(roundedRect: NSRect(x: 10.6, y: 3.9, width: 5.9, height: 5.9), xRadius: 2.95, yRadius: 2.95)
            badge.fill()
        case .ready:
            let check = NSBezierPath()
            check.lineWidth = 1.75
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.move(to: NSPoint(x: 8.3, y: 5.4))
            check.line(to: NSPoint(x: 10.4, y: 3.6))
            check.line(to: NSPoint(x: 15.4, y: 8.8))
            check.stroke()
        case .running:
            let ring = NSBezierPath()
            ring.lineWidth = 1.45
            ring.lineCapStyle = .round
            ring.appendArc(
                withCenter: NSPoint(x: 12.3, y: 6.3),
                radius: 2.9,
                startAngle: 210,
                endAngle: 515
            )
            ring.stroke()
            let arrow = NSBezierPath()
            arrow.lineWidth = 1.25
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.move(to: NSPoint(x: 14.7, y: 8.2))
            arrow.line(to: NSPoint(x: 15.7, y: 8.2))
            arrow.line(to: NSPoint(x: 15.3, y: 7.2))
            arrow.stroke()
        case .attention:
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: 13.1, y: 9.4))
            triangle.line(to: NSPoint(x: 16.2, y: 3.9))
            triangle.line(to: NSPoint(x: 10.0, y: 3.9))
            triangle.close()
            triangle.fill()
        }
    }
}

private struct KLMSAuthDigitsOverlayView: View {
    var digits: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.klmsMacWarningBorder)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("KAIST 인증 번호")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.klmsMacSecondaryText)
                Text(digits)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.klmsMacPrimaryText)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(digits, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.headline.weight(.semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.klmsMacWarningBorder)
            .help("인증 번호 복사")
            .accessibilityLabel("KAIST 인증 번호 복사")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 348, height: 74)
        .background(Color.klmsMacWarningBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.klmsMacWarningBorder.opacity(0.8), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("KAIST 인증 번호 \(digits)")
    }
}

@MainActor
final class KLMSAppDelegate: NSObject, NSApplicationDelegate {
    private var model: KLMSMacModel?
    private var statusItem: NSStatusItem?
    private var statusIconCancellable: AnyCancellable?
    private var authDigitsOverlayWindow: NSPanel?
    private var shortcutKeyMonitor: Any?
    private var terminationCleanupStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = KLMSMacModel()
        self.model = model
        KLMSDashboardWindowCoordinator.shared.setModel(model)
        NSApp.setActivationPolicy(.regular)
        configureApplicationMenu()
        configureShortcutKeyMonitor()
        configureStatusItem(for: model)
        KLMSLaunchState.clearSavedApplicationState()
        KLMSDashboardWindowCoordinator.shared.showDashboardWindow()
    }

    private func configureStatusItem(for model: KLMSMacModel) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyDown

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "KLMS Sync 열기", action: #selector(openDashboardFromMenu), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = [.command]
        menu.addItem(openItem)

        let refreshItem = NSMenuItem(title: "새로고침", action: #selector(refreshStatusFromMenu), keyEquivalent: "r")
        refreshItem.keyEquivalentModifierMask = [.command]
        menu.addItem(refreshItem)

        let verifyItem = NSMenuItem(title: "상태 검사", action: #selector(runVerifyFromMenu), keyEquivalent: "v")
        verifyItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(verifyItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "종료", action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)
        for item in menu.items {
            item.target = self
        }
        item.menu = menu
        statusItem = item
        updateStatusItemIcon(for: model)
        statusIconCancellable = model.objectWillChange.sink { [weak self, weak model] _ in
            DispatchQueue.main.async {
                guard let model else { return }
                self?.updateStatusItemIcon(for: model)
            }
        }
    }

    private func updateStatusItemIcon(for model: KLMSMacModel) {
        let state = KLMSMenuBarStatusIconState(model: model)
        guard let button = statusItem?.button else {
            return
        }
        button.image = KLMSMenuBarStatusIcon.image(for: state)
        button.toolTip = state.tooltip
        button.title = state.menuBarTitle
        button.imagePosition = state.menuBarTitle.isEmpty ? .imageOnly : .imageLeading
        button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        button.setAccessibilityLabel(state.tooltip)
        updateAuthDigitsOverlay(for: state)
    }

    private func updateAuthDigitsOverlay(for state: KLMSMenuBarStatusIconState) {
        switch state {
        case let .authDigits(digits):
            showAuthDigitsOverlay(digits)
        case .ready, .running, .attention:
            hideAuthDigitsOverlay()
        }
    }

    private func showAuthDigitsOverlay(_ digits: String) {
        let panel = authDigitsOverlayWindow ?? makeAuthDigitsOverlayWindow()
        panel.contentView = NSHostingView(rootView: KLMSAuthDigitsOverlayView(digits: digits))
        positionAuthDigitsOverlay(panel)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        authDigitsOverlayWindow = panel
    }

    private func hideAuthDigitsOverlay() {
        authDigitsOverlayWindow?.orderOut(nil)
    }

    private func makeAuthDigitsOverlayWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 348, height: 74),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.setAccessibilityIdentifier("klms-auth-digits-overlay")
        return panel
    }

    private func positionAuthDigitsOverlay(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 600)
        let size = NSSize(width: 348, height: 74)
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 10
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu(title: "KLMS Sync")
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "KLMS Sync")

        let openItem = NSMenuItem(title: "KLMS Sync 열기", action: #selector(openDashboardFromMenu), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = [.command]
        openItem.target = self
        appMenu.addItem(openItem)

        let refreshItem = NSMenuItem(title: "새로고침", action: #selector(refreshStatusFromMenu), keyEquivalent: "r")
        refreshItem.keyEquivalentModifierMask = [.command]
        refreshItem.target = self
        appMenu.addItem(refreshItem)

        let verifyItem = NSMenuItem(title: "상태 검사", action: #selector(runVerifyFromMenu), keyEquivalent: "v")
        verifyItem.keyEquivalentModifierMask = [.command, .shift]
        verifyItem.target = self
        appMenu.addItem(verifyItem)

        let doctorItem = NSMenuItem(title: "권한/환경 진단", action: #selector(runDoctorFromMenu), keyEquivalent: "d")
        doctorItem.keyEquivalentModifierMask = [.command, .shift]
        doctorItem.target = self
        appMenu.addItem(doctorItem)

        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "KLMS Sync 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func configureShortcutKeyMonitor() {
        guard shortcutKeyMonitor == nil else { return }
        shortcutKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyboardShortcut(event)
        }
    }

    private func handleKeyboardShortcut(_ event: NSEvent) -> NSEvent? {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifierFlags.contains(.command) else {
            return event
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let hasShift = modifierFlags.contains(.shift)
        switch key {
        case "o" where !hasShift:
            openDashboardFromMenu(nil)
            return nil
        case "r" where !hasShift:
            refreshStatusFromMenu(nil)
            return nil
        case "v" where hasShift:
            runVerifyFromMenu(nil)
            return nil
        case "d" where hasShift:
            runDoctorFromMenu(nil)
            return nil
        case "q" where !hasShift:
            NSApp.terminate(nil)
            return nil
        default:
            return event
        }
    }

    @objc private func openDashboardFromMenu(_ sender: Any?) {
        KLMSDashboardWindowCoordinator.shared.showDashboardWindow()
    }

    @objc private func refreshStatusFromMenu(_ sender: Any?) {
        guard let model else { return }
        Task { @MainActor in
            await model.refreshVisibleStateFromShortcut()
        }
    }

    @objc private func runVerifyFromMenu(_ sender: Any?) {
        guard let model else { return }
        Task { @MainActor in
            KLMSDashboardWindowCoordinator.shared.showDashboardWindow()
            await model.run(.verify)
        }
    }

    @objc private func runDoctorFromMenu(_ sender: Any?) {
        guard let model else { return }
        Task { @MainActor in
            KLMSDashboardWindowCoordinator.shared.showDashboardWindow()
            await model.run(.doctor)
        }
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        KLMSDashboardWindowCoordinator.shared.showDashboardWindow()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        KLMSDashboardWindowCoordinator.shared.showIfNoVisibleDashboardWindow()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationCleanupStarted, let model, model.runningCommand != nil else {
            return .terminateNow
        }
        terminationCleanupStarted = true
        Task { @MainActor in
            await model.cancelCommandBeforeTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
private final class KLMSDashboardWindowCoordinator {
    static let shared = KLMSDashboardWindowCoordinator()

    private(set) var model: KLMSMacModel?
    private var window: NSWindow?
    private var bootstrapTask: Task<Void, Never>?
    private var pendingDashboardWindowOpen = false

    func setModel(_ model: KLMSMacModel) {
        self.model = model
        guard pendingDashboardWindowOpen else {
            return
        }
        pendingDashboardWindowOpen = false
        showDashboardWindow()
    }

    func showIfNoVisibleDashboardWindow() {
        guard !hasVisibleDashboardWindow else {
            return
        }
        showDashboardWindow()
    }

    func showDashboardWindow() {
        NSApp.setActivationPolicy(.regular)
        guard let model else {
            pendingDashboardWindowOpen = true
            activateDashboardApplication()
            return
        }

        let initialSize = NSSize(width: KLMSWindowMetrics.initialWidth, height: KLMSWindowMetrics.initialHeight)
        if let window {
            restoreDashboardFrameIfNeeded(window, size: initialSize)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            activateDashboardApplication()
            return
        }

        let rootView = KLMSMacDeferredWorkspaceRootContainerView(model: model)
            .frame(
                minWidth: KLMSWindowMetrics.minWidth,
                idealWidth: KLMSWindowMetrics.initialWidth,
                maxWidth: .infinity,
                minHeight: KLMSWindowMetrics.minHeight,
                idealHeight: KLMSWindowMetrics.initialHeight,
                alignment: .topLeading
            )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "KLMS Sync"
        window.identifier = NSUserInterfaceItemIdentifier(KLMSMacWindowID.dashboard)
        window.setAccessibilityIdentifier(KLMSMacWindowID.dashboard)
        window.minSize = NSSize(width: KLMSWindowMetrics.minWidth, height: KLMSWindowMetrics.minHeight)
        window.center()
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = []
        hostingController.view.setAccessibilityIdentifier("klms-dashboard-root")
        window.contentViewController = hostingController
        window.setContentSize(initialSize)
        restoreDashboardFrameIfNeeded(window, size: initialSize)
        self.window = window

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        activateDashboardApplication()
        scheduleBootstrapIfNeeded(delay: 2.5)
    }

    private func activateDashboardApplication() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    private func restoreDashboardFrameIfNeeded(_ window: NSWindow, size: NSSize) {
        guard window.frame.width < KLMSWindowMetrics.minWidth || window.frame.height < KLMSWindowMetrics.minHeight else {
            return
        }
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let width = min(size.width, max(KLMSWindowMetrics.minWidth, screenFrame.width - 48))
        let height = min(size.height, max(KLMSWindowMetrics.minHeight, screenFrame.height - 64))
        let origin = NSPoint(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2
        )
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    func scheduleBootstrapIfNeeded(delay: TimeInterval = 0.2) {
        guard bootstrapTask == nil else {
            return
        }
        bootstrapTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self, let model = self.model else {
                return
            }
            await model.bootstrap()
        }
    }

    var hasVisibleDashboardWindow: Bool {
        NSApp.windows.contains { window in
            window.isVisible
                && window.identifier?.rawValue == KLMSMacWindowID.dashboard
                && window.frame.width >= KLMSWindowMetrics.minWidth
                && window.frame.height >= KLMSWindowMetrics.minHeight
        }
    }
}

private enum KLMSWindowMetrics {
    static let initialWidth: CGFloat = 1080
    static let initialHeight: CGFloat = 760
    static let minWidth: CGFloat = 900
    static let minHeight: CGFloat = 520

    private static var visibleFrame: CGRect {
        NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
    }

    static var menuBarWidth: CGFloat {
        min(1080, max(440, visibleFrame.width - 48))
    }

    static var menuBarHeight: CGFloat {
        min(780, max(360, visibleFrame.height - 80))
    }
}
