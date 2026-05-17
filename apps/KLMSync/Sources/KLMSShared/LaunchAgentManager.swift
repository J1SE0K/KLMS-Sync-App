import Darwin
import Foundation

public struct LaunchAgentState: Sendable, Equatable {
    public var label: String
    public var plistURL: URL
    public var isInstalled: Bool
    public var lock: SyncLockInfo?

    public init(label: String, plistURL: URL, isInstalled: Bool, lock: SyncLockInfo? = nil) {
        self.label = label
        self.plistURL = plistURL
        self.isInstalled = isInstalled
        self.lock = lock
    }
}

public struct SyncLockInfo: Sendable, Equatable {
    public var pid: String
    public var command: String
    public var acquiredAt: String

    public init(pid: String = "", command: String = "", acquiredAt: String = "") {
        self.pid = pid
        self.command = command
        self.acquiredAt = acquiredAt
    }
}

public struct LaunchAgentManager {
    public var paths: KLMSPaths
    public var launchAgentsDirectory: URL
    public var fileManager: FileManager

    public init(
        paths: KLMSPaths,
        launchAgentsDirectory: URL = KLMSPaths.defaultLaunchAgentsDirectory(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.launchAgentsDirectory = launchAgentsDirectory
        self.fileManager = fileManager
    }

    public func label(from document: EnvDocument?) -> String {
        document?.value(forRawKey: "KLMS_LAUNCHD_LABEL") ?? "com.local.klms-notes-sync"
    }

    public func plistURL(label: String) -> URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    public func state(label: String) -> LaunchAgentState {
        let url = plistURL(label: label)
        return LaunchAgentState(
            label: label,
            plistURL: url,
            isInstalled: fileManager.fileExists(atPath: url.path),
            lock: sharedLockInfo(scope: "all")
        )
    }

    public func renderPlist(label: String) -> String {
        let launchWorker = paths.engineRoot
            .appendingPathComponent("src", isDirectory: true)
            .appendingPathComponent("sh", isDirectory: true)
            .appendingPathComponent("launch_sync_if_idle.sh")
            .path
        let stdout = paths.logsURL.appendingPathComponent("launchd.stdout.log").path
        let stderr = paths.logsURL.appendingPathComponent("launchd.stderr.log").path
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(xmlEscape(label))</string>

          <key>ProgramArguments</key>
          <array>
            <string>/bin/zsh</string>
            <string>\(xmlEscape(launchWorker))</string>
          </array>

          <key>WorkingDirectory</key>
          <string>\(xmlEscape(paths.engineRoot.path))</string>

          <key>RunAtLoad</key>
          <true/>

          <key>StartInterval</key>
          <integer>900</integer>

          <key>StandardOutPath</key>
          <string>\(xmlEscape(stdout))</string>

          <key>StandardErrorPath</key>
          <string>\(xmlEscape(stderr))</string>
        </dict>
        </plist>
        """
    }

    public func install(label: String) throws {
        try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.logsURL, withIntermediateDirectories: true)
        let url = plistURL(label: label)
        try renderPlist(label: label).write(to: url, atomically: true, encoding: .utf8)
        _ = try? runLaunchctl(["bootout", guiDomain(), url.path])
        _ = try runLaunchctl(["bootstrap", guiDomain(), url.path])
        _ = try runLaunchctl(["enable", "\(guiDomain())/\(label)"])
    }

    public func uninstall(label: String) throws {
        let url = plistURL(label: label)
        _ = try? runLaunchctl(["bootout", guiDomain(), url.path])
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func sharedLockInfo(scope: String) -> SyncLockInfo? {
        let lockURL = paths.automationURL
            .appendingPathComponent("shared-locks", isDirectory: true)
            .appendingPathComponent("\(scope).lock", isDirectory: true)
        guard fileManager.fileExists(atPath: lockURL.path) else {
            return nil
        }
        return SyncLockInfo(
            pid: readTrimmed(lockURL.appendingPathComponent("pid")),
            command: readTrimmed(lockURL.appendingPathComponent("command")),
            acquiredAt: readTrimmed(lockURL.appendingPathComponent("acquired_at"))
        )
    }

    private func readTrimmed(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }

    private func runLaunchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func guiDomain() -> String {
        "gui/\(getuid())"
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private extension EnvDocument {
    func value(forRawKey key: String) -> String? {
        value(for: key)
    }
}
