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
    @StateObject private var model = KLMSMacModel()
    @AppStorage("KLMSAppearanceMode") private var appearanceMode = KLMSAppearanceMode.system.rawValue

    var body: some Scene {
        WindowGroup("KLMS Sync") {
            MenuBarRootView(model: model)
                .frame(
                    minWidth: 540,
                    idealWidth: 1080,
                    maxWidth: .infinity,
                    minHeight: 520,
                    idealHeight: 760,
                    maxHeight: .infinity
                )
                .task {
                    appDelegate.model = model
                    await model.bootstrap()
                }
                .preferredColorScheme(KLMSAppearanceMode(rawValue: appearanceMode)?.colorScheme)
        }
        .defaultSize(width: 1080, height: 760)

        Window("KLMS Sync 진단", id: KLMSMacWindowID.diagnostics) {
            DiagnosticWindowView(model: model)
                .frame(
                    minWidth: 620,
                    idealWidth: 920,
                    maxWidth: .infinity,
                    minHeight: 480,
                    idealHeight: 760,
                    maxHeight: .infinity
                )
                .task {
                    appDelegate.model = model
                    await model.bootstrap()
                }
                .preferredColorScheme(KLMSAppearanceMode(rawValue: appearanceMode)?.colorScheme)
        }
        .defaultSize(width: 920, height: 760)

        MenuBarExtra {
            MenuBarRootView(model: model)
                .frame(width: KLMSWindowMetrics.menuBarWidth, height: KLMSWindowMetrics.menuBarHeight)
                .task {
                    appDelegate.model = model
                    await model.bootstrap()
                }
                .preferredColorScheme(KLMSAppearanceMode(rawValue: appearanceMode)?.colorScheme)
        } label: {
            Label("KLMS Sync", systemImage: model.menuBarSystemImage)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(width: KLMSWindowMetrics.settingsWidth, height: KLMSWindowMetrics.settingsHeight)
                .preferredColorScheme(KLMSAppearanceMode(rawValue: appearanceMode)?.colorScheme)
        }
    }
}

enum KLMSMacWindowID {
    static let diagnostics = "klms-diagnostics"
}

@MainActor
private final class KLMSAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: KLMSMacModel?
    private var terminationCleanupStarted = false

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

private enum KLMSWindowMetrics {
    private static var visibleFrame: CGRect {
        NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
    }

    static var menuBarWidth: CGFloat {
        min(1080, max(440, visibleFrame.width - 48))
    }

    static var menuBarHeight: CGFloat {
        min(780, max(360, visibleFrame.height - 80))
    }

    static var settingsWidth: CGFloat {
        min(760, max(620, visibleFrame.width - 64))
    }

    static var settingsHeight: CGFloat {
        min(700, max(520, visibleFrame.height - 96))
    }
}
