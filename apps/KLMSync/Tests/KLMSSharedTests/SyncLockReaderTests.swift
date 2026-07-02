import XCTest
@testable import KLMSShared

final class SyncLockReaderTests: XCTestCase {
    func testReadsCanonicalAutomationLockBeforeLegacyFallback() throws {
        let root = try makeTemporaryEngineRoot()
        let paths = KLMSPaths(engineRoot: root)
        let canonicalLock = paths.automationURL.appendingPathComponent("all.lock", isDirectory: true)
        let legacyLock = paths.automationURL
            .appendingPathComponent("shared-locks", isDirectory: true)
            .appendingPathComponent("all.lock", isDirectory: true)
        try writeLock(canonicalLock, pid: currentPID, command: "canonical", acquiredAt: "now")
        try writeLock(legacyLock, pid: currentPID, command: "legacy", acquiredAt: "old")

        let info = try XCTUnwrap(SyncLockReader(paths: paths).sharedLockInfo(scope: "all"))

        XCTAssertEqual(info.pid, currentPID)
        XCTAssertEqual(info.command, "canonical")
        XCTAssertEqual(info.acquiredAt, "now")
    }

    func testCleansStaleCanonicalLockAndFallsBackToLegacyLock() throws {
        let root = try makeTemporaryEngineRoot()
        let paths = KLMSPaths(engineRoot: root)
        let canonicalLock = paths.automationURL.appendingPathComponent("all.lock", isDirectory: true)
        let legacyLock = paths.automationURL
            .appendingPathComponent("shared-locks", isDirectory: true)
            .appendingPathComponent("all.lock", isDirectory: true)
        try writeLock(canonicalLock, pid: "99999999", command: "stale", acquiredAt: "stale-time")
        try writeLock(legacyLock, pid: currentPID, command: "legacy", acquiredAt: "legacy-time")

        let info = try XCTUnwrap(SyncLockReader(paths: paths).sharedLockInfo(scope: "all"))

        XCTAssertEqual(info.command, "legacy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalLock.path))
    }

    private var currentPID: String {
        String(ProcessInfo.processInfo.processIdentifier)
    }

    private func makeTemporaryEngineRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-sync-lock-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func writeLock(_ url: URL, pid: String, command: String, acquiredAt: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try pid.write(to: url.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        try command.write(to: url.appendingPathComponent("command"), atomically: true, encoding: .utf8)
        try acquiredAt.write(to: url.appendingPathComponent("acquired_at"), atomically: true, encoding: .utf8)
    }
}
