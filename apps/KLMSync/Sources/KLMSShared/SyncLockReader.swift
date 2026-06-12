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
}
