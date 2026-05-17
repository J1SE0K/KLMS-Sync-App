import Foundation
import KLMSShared
import SwiftUI
import UserNotifications

@MainActor
final class KLMSMacModel: ObservableObject {
    @Published var paths = KLMSPaths()
    @Published var snapshot = EngineSnapshot()
    @Published var envDocument: EnvDocument?
    @Published var launchAgentState: LaunchAgentState?
    @Published var installResult: EngineInstallResult?
    @Published var lastCommandResult: KLMSCommandResult?
    @Published var lastRemoteCommand: RemoteRunCommand?
    @Published var runningCommand: KLMSEngineCommand?
    @Published var errorMessage: String?
    @Published var payload: EnginePayload?

    private let runner = KLMSCommandRunner()
    private let installer = EngineInstaller()
    private let locator = EnginePayloadLocator()
    private var isBootstrapping = false

    var menuBarSystemImage: String {
        if runningCommand != nil {
            return "arrow.triangle.2.circlepath"
        }
        if snapshot.needsAttention {
            return "exclamationmark.triangle"
        }
        return "checkmark.circle"
    }

    var launchLabel: String {
        LaunchAgentManager(paths: paths).label(from: envDocument)
    }

    func bootstrap() async {
        guard payload == nil else { return }
        guard !isBootstrapping else { return }
        isBootstrapping = true
        defer {
            isBootstrapping = false
        }
        await installEngine(force: false, runDoctorAfterInstall: false)
        await refresh()
    }

    func installEngine(force: Bool, runDoctorAfterInstall: Bool = true) async {
        payload = locator.resolve(bundledResourceURL: Bundle.main.resourceURL)
            ?? locator.resolve(bundledResourceURL: Bundle.module.resourceURL)
        guard let payload else {
            errorMessage = "KLMS 엔진 payload를 찾지 못했습니다."
            return
        }
        do {
            installResult = try installer.installIfNeeded(
                payload: payload,
                destination: paths.engineRoot,
                force: force
            )
            try loadConfig()
            refreshLaunchAgentState()
            if runDoctorAfterInstall, installResult?.installed == true {
                _ = try? await runner.run(.doctor, paths: paths)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        do {
            try loadConfig()
        } catch {
            if FileManager.default.fileExists(atPath: paths.configURL.path) {
                errorMessage = error.localizedDescription
            }
        }
        snapshot = EngineSnapshotStore(paths: paths).load()
        refreshLaunchAgentState()
    }

    func run(_ command: KLMSEngineCommand, dryRun: Bool = false) async {
        guard runningCommand == nil else { return }
        runningCommand = command
        errorMessage = nil
        defer {
            runningCommand = nil
        }

        do {
            await installEngine(force: false, runDoctorAfterInstall: false)
            let result = try await runner.run(command, paths: paths, dryRun: dryRun)
            lastCommandResult = result
            if let digits = result.authDigits {
                await notifyAuthDigits(digits)
            }
            if !result.succeeded {
                errorMessage = "\(command.displayName) 실패: exit \(result.exitCode)"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    func runReportRefresh() async {
        await run(.report)
    }

    func configValue(_ key: EnvKnownKey) -> String {
        envDocument?.value(for: key) ?? ""
    }

    func boolConfigValue(_ key: EnvKnownKey, default defaultValue: Bool = false) -> Bool {
        envDocument?.boolValue(for: key, default: defaultValue) ?? defaultValue
    }

    func setConfigValue(_ value: String, for key: EnvKnownKey) {
        do {
            var document = envDocument ?? EnvDocument(text: "")
            document.setValue(value, for: key)
            try EnvStore(url: paths.configURL).save(document)
            envDocument = document
            refreshLaunchAgentState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setBoolConfigValue(_ value: Bool, for key: EnvKnownKey) {
        setConfigValue(value ? "1" : "0", for: key)
    }

    func toggleLaunchAgent() async {
        let manager = LaunchAgentManager(paths: paths)
        let label = launchLabel
        do {
            if manager.state(label: label).isInstalled {
                try manager.uninstall(label: label)
            } else {
                try manager.install(label: label)
            }
            refreshLaunchAgentState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openEngineFolder() {
        NSWorkspace.shared.open(paths.engineRoot)
    }

    func openLogsFolder() {
        NSWorkspace.shared.open(paths.logsURL)
    }

    func processRemoteCommands() async {
        #if canImport(CloudKit)
        do {
            let store = CloudKitCommandStore()
            let pending = try await store.fetchPending()
            guard let command = pending.first else {
                errorMessage = "대기 중인 원격 요청이 없습니다."
                return
            }
            var running = command
            running.status = .running
            running.updatedAt = Date()
            running.summary = SanitizedRemoteStatus(snapshot: snapshot, phase: "running")
            try await store.update(running)
            lastRemoteCommand = running

            await run(command.kind.engineCommand)
            let refreshedSnapshot = EngineSnapshotStore(paths: paths).load()
            var completed = running
            completed.status = lastCommandResult?.succeeded == true ? .completed : .failed
            completed.updatedAt = Date()
            completed.lastExitCode = lastCommandResult.map { Int($0.exitCode) }
            completed.loginRequired = lastCommandResult?.authDigits != nil
            completed.summary = SanitizedRemoteStatus(snapshot: refreshedSnapshot, phase: completed.status.rawValue)
            try await store.update(completed)
            lastRemoteCommand = completed
        } catch {
            errorMessage = error.localizedDescription
        }
        #else
        errorMessage = "CloudKit을 사용할 수 없는 빌드입니다."
        #endif
    }

    private func loadConfig() throws {
        envDocument = try EnvStore(url: paths.configURL).load()
    }

    private func refreshLaunchAgentState() {
        let manager = LaunchAgentManager(paths: paths)
        launchAgentState = manager.state(label: manager.label(from: envDocument))
    }

    private func notifyAuthDigits(_ digits: String) async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent()
        content.title = "KLMS 인증 번호"
        content.body = "휴대폰 KAIST 인증 화면에서 \(digits)를 선택해 주세요."
        let request = UNNotificationRequest(identifier: "klms-auth-\(digits)", content: content, trigger: nil)
        try? await center.add(request)
    }
}
