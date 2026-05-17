import KLMSShared
import SwiftUI

@main
struct KLMSMacApp: App {
    @StateObject private var model = KLMSMacModel()

    var body: some Scene {
        WindowGroup("KLMS Sync") {
            MenuBarRootView(model: model)
                .frame(minWidth: 640, idealWidth: 820, minHeight: 700, idealHeight: 820)
                .task {
                    await model.bootstrap()
                }
        }

        MenuBarExtra {
            MenuBarRootView(model: model)
                .frame(width: 520, height: 700)
                .task {
                    await model.bootstrap()
                }
        } label: {
            Label("KLMS Sync", systemImage: model.menuBarSystemImage)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(width: 540, height: 620)
        }
    }
}
