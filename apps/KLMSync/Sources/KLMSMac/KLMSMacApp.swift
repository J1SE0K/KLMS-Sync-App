import KLMSShared
import AppKit
import SwiftUI

@objc(KLMSApplication)
final class KLMSApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if Self.isQuitShortcut(event) {
            terminate(nil)
            return
        }
        super.sendEvent(event)
    }

    private static func isQuitShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isQKey = event.charactersIgnoringModifiers?.lowercased() == "q"
            || event.keyCode == 12
        return modifierFlags.contains(.command)
            && isQKey
    }
}

@main
enum KLMSMacMain {
    static func main() {
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

@MainActor
final class KLMSAppDelegate: NSObject, NSApplicationDelegate {
    private var model: KLMSMacModel?
    private var statusItem: NSStatusItem?
    private var quitKeyMonitor: Any?
    private var terminationCleanupStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.clearSavedApplicationState()
        let model = KLMSMacModel()
        self.model = model
        KLMSDashboardWindowCoordinator.shared.setModel(model)
        NSApp.setActivationPolicy(.regular)
        configureApplicationMenu()
        configureQuitKeyMonitor()
        configureStatusItem(for: model)
        DispatchQueue.main.async {
            KLMSDashboardWindowCoordinator.shared.showIfNoVisibleDashboardWindow()
        }
    }

    private static func clearSavedApplicationState() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let savedStateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State")
            .appendingPathComponent("\(identifier).savedState")
        try? FileManager.default.removeItem(at: savedStateURL)
    }

    private func configureStatusItem(for model: KLMSMacModel) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: model.menuBarSystemImage, accessibilityDescription: "KLMS Sync")
        item.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "KLMS Sync 열기", action: #selector(openDashboardFromMenu), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "상태 갱신", action: #selector(refreshStatusFromMenu), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quitFromMenu), keyEquivalent: "q"))
        for item in menu.items {
            item.target = self
        }
        item.menu = menu
        statusItem = item
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu(title: "KLMS Sync")
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "KLMS Sync")

        let openItem = NSMenuItem(title: "KLMS Sync 열기", action: #selector(openDashboardFromMenu), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = [.command]
        openItem.target = self
        appMenu.addItem(openItem)

        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "KLMS Sync 종료", action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func configureQuitKeyMonitor() {
        guard quitKeyMonitor == nil else { return }
        quitKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isQKey = event.charactersIgnoringModifiers?.lowercased() == "q"
                || event.keyCode == 12
            guard modifierFlags.contains(.command),
                  isQKey else {
                return event
            }
            NSApp.terminate(nil)
            return nil
        }
    }

    @objc private func openDashboardFromMenu(_ sender: Any?) {
        KLMSDashboardWindowCoordinator.shared.showDashboardWindow()
    }

    @objc private func refreshStatusFromMenu(_ sender: Any?) {
        guard let model else { return }
        Task { @MainActor in
            await model.bootstrap()
        }
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !KLMSDashboardWindowCoordinator.shared.hasVisibleDashboardWindow {
            KLMSDashboardWindowCoordinator.shared.showDashboardWindow()
            return false
        }
        return true
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
    static let minWidth: CGFloat = 540
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
