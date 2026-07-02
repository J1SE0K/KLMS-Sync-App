import Darwin
import Foundation

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

public struct SyncLockReader {
    public var paths: KLMSPaths
    public var fileManager: FileManager

    public init(paths: KLMSPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func sharedLockInfo(scope: String) -> SyncLockInfo? {
        for lockURL in lockURLs(scope: scope) {
            guard fileManager.fileExists(atPath: lockURL.path) else {
                continue
            }
            let info = SyncLockInfo(
                pid: readTrimmed(lockURL.appendingPathComponent("pid")),
                command: readTrimmed(lockURL.appendingPathComponent("command")),
                acquiredAt: readTrimmed(lockURL.appendingPathComponent("acquired_at"))
            )
            if !info.pid.isEmpty, !isProcessRunning(pidString: info.pid) {
                try? fileManager.removeItem(at: lockURL)
                continue
            }
            return info
        }
        return nil
    }

    private func lockURLs(scope: String) -> [URL] {
        [
            paths.automationURL
                .appendingPathComponent("\(scope).lock", isDirectory: true),
            paths.automationURL
                .appendingPathComponent("shared-locks", isDirectory: true)
                .appendingPathComponent("\(scope).lock", isDirectory: true)
        ]
    }

    private func readTrimmed(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }

    private func isProcessRunning(pidString: String) -> Bool {
        guard let pid = Int32(pidString) else {
            return false
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
