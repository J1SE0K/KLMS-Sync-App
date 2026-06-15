import KLMSShared
import AppKit
import SwiftUI

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

@main
struct KLMSMacApp: App {
    @NSApplicationDelegateAdaptor(KLMSAppDelegate.self) private var appDelegate
    @StateObject private var model: KLMSMacModel

    init() {
        Self.clearSavedApplicationState()
        let model = KLMSMacModel()
        _model = StateObject(wrappedValue: model)
        KLMSDashboardWindowCoordinator.shared.model = model
    }

    private static func clearSavedApplicationState() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let savedStateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State")
            .appendingPathComponent("\(identifier).savedState")
        try? FileManager.default.removeItem(at: savedStateURL)
    }

    var body: some Scene {
        MenuBarExtra {
            KLMSMacRootContainerView(model: model)
                .frame(width: KLMSWindowMetrics.menuBarWidth, height: KLMSWindowMetrics.menuBarHeight)
                .onAppear {
                    appDelegate.model = model
                    KLMSDashboardWindowCoordinator.shared.scheduleBootstrapIfNeeded()
                }
        } label: {
            Label("KLMS Sync", systemImage: model.menuBarSystemImage)
        }
        .menuBarExtraStyle(.window)
    }
}

enum KLMSMacWindowID {
    static let dashboard = "klms-dashboard"
}

private struct KLMSMacRootContainerView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        MenuBarRootView(model: model)
            .klmsPreferredAppearance()
    }
}

private struct KLMSMacWorkspaceRootContainerView: View {
    @ObservedObject var model: KLMSMacModel

    var body: some View {
        MenuBarRootView(model: model)
            .klmsPreferredAppearance()
    }
}

private struct KLMSPreferredAppearanceModifier: ViewModifier {
    @AppStorage("KLMSAppearanceMode") private var appearanceMode = KLMSAppearanceMode.system.rawValue

    func body(content: Content) -> some View {
        content.preferredColorScheme(KLMSAppearanceMode(rawValue: appearanceMode)?.colorScheme)
    }
}

private extension View {
    func klmsPreferredAppearance() -> some View {
        modifier(KLMSPreferredAppearanceModifier())
    }
}

@MainActor
private final class KLMSAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: KLMSMacModel?
    private var terminationCleanupStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = KLMSDashboardWindowCoordinator.shared.model
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            KLMSDashboardWindowCoordinator.shared.showDashboardWindow()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        KLMSDashboardWindowCoordinator.shared.showDashboardWindow()
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !KLMSDashboardWindowCoordinator.shared.hasVisibleDashboardWindow {
            KLMSDashboardWindowCoordinator.shared.showDashboardWindow()
            return false
        }
        return true
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

    var model: KLMSMacModel?
    private var window: NSWindow?
    private var bootstrapTask: Task<Void, Never>?

    func showIfNoVisibleDashboardWindow() {
        guard !hasVisibleDashboardWindow else {
            return
        }
        showDashboardWindow()
    }

    func showDashboardWindow() {
        NSApp.setActivationPolicy(.regular)
        guard let model else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let initialSize = NSSize(width: KLMSWindowMetrics.initialWidth, height: KLMSWindowMetrics.initialHeight)

        let rootView = KLMSMacWorkspaceRootContainerView(model: model)
            .frame(
                minWidth: KLMSWindowMetrics.minWidth,
                idealWidth: KLMSWindowMetrics.initialWidth,
                maxWidth: .infinity,
                minHeight: KLMSWindowMetrics.minHeight,
                idealHeight: KLMSWindowMetrics.initialHeight,
                maxHeight: .infinity,
                alignment: .topLeading
            )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "KLMS Sync"
        window.minSize = NSSize(width: KLMSWindowMetrics.minWidth, height: KLMSWindowMetrics.minHeight)
        window.center()
        window.isReleasedWhenClosed = false
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.setContentSize(initialSize)
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        scheduleBootstrapIfNeeded(delay: 0.4)
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
            window.isVisible && window.title == "KLMS Sync"
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
