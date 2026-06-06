import KLMSShared
import AppKit
import SwiftUI

@main
struct KLMSMacApp: App {
    @NSApplicationDelegateAdaptor(KLMSAppDelegate.self) private var appDelegate
    @StateObject private var model = KLMSMacModel()

    var body: some Scene {
        WindowGroup("KLMS Sync") {
            MenuBarRootView(model: model)
                .frame(
                    minWidth: 540,
                    idealWidth: 900,
                    maxWidth: .infinity,
                    minHeight: 520,
                    idealHeight: 820,
                    maxHeight: .infinity
                )
                .task {
                    appDelegate.model = model
                    await model.bootstrap()
                }
        }

        MenuBarExtra {
            MenuBarRootView(model: model)
                .frame(width: KLMSWindowMetrics.menuBarWidth, height: KLMSWindowMetrics.menuBarHeight)
                .task {
                    appDelegate.model = model
                    await model.bootstrap()
                }
        } label: {
            Label("KLMS Sync", systemImage: model.menuBarSystemImage)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(width: KLMSWindowMetrics.settingsWidth, height: KLMSWindowMetrics.settingsHeight)
        }
    }
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
        min(760, max(440, visibleFrame.width - 48))
    }

    static var menuBarHeight: CGFloat {
        min(760, max(360, visibleFrame.height - 80))
    }

    static var settingsWidth: CGFloat {
        min(760, max(620, visibleFrame.width - 64))
    }

    static var settingsHeight: CGFloat {
        min(700, max(520, visibleFrame.height - 96))
    }
}
