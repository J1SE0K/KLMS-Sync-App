import KLMSShared
import AppKit
import SwiftUI

@main
struct KLMSMacApp: App {
    @StateObject private var model = KLMSMacModel()

    var body: some Scene {
        WindowGroup("KLMS Sync") {
            MenuBarRootView(model: model)
                .frame(
                    minWidth: 460,
                    idealWidth: 820,
                    maxWidth: .infinity,
                    minHeight: 520,
                    idealHeight: 820,
                    maxHeight: .infinity
                )
                .task {
                    await model.bootstrap()
                }
        }

        MenuBarExtra {
            MenuBarRootView(model: model)
                .frame(width: KLMSWindowMetrics.menuBarWidth, height: KLMSWindowMetrics.menuBarHeight)
                .task {
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

private enum KLMSWindowMetrics {
    private static var visibleFrame: CGRect {
        NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
    }

    static var menuBarWidth: CGFloat {
        min(620, max(360, visibleFrame.width - 48))
    }

    static var menuBarHeight: CGFloat {
        min(760, max(360, visibleFrame.height - 80))
    }

    static var settingsWidth: CGFloat {
        min(560, max(420, visibleFrame.width - 64))
    }

    static var settingsHeight: CGFloat {
        min(660, max(420, visibleFrame.height - 96))
    }
}
