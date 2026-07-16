import Foundation
import XCTest
@testable import KLMSMac

private final class FileSystemEventCallbackProbe: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didSignal = false

    func signalOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !didSignal else { return }
        didSignal = true
        semaphore.signal()
    }
}

final class FileSystemEventWatcherTests: XCTestCase {
    func testWatcherStartsAndDeliversFileChangeWithoutPolling() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KLMSFileSystemEventWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let changedURL = root.appendingPathComponent("state.json")
        let probe = FileSystemEventCallbackProbe()
        let watcher = KLMSFileSystemEventWatcher(paths: [root]) {
            probe.signalOnce()
        }
        defer {
            watcher.stop()
        }

        XCTAssertTrue(watcher.start())
        try Data("changed".utf8).write(to: changedURL)

        XCTAssertEqual(
            probe.semaphore.wait(timeout: .now() + 3),
            .success,
            "FSEvents should deliver a local state change without periodic polling."
        )
    }

    func testNestedCourseFileChangeForcesSnapshotReload() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("let paths = unsafeBitCast(eventPaths, to: NSArray.self)"))
        XCTAssertTrue(source.contains("flags: eventFlags[index]"))
        XCTAssertTrue(source.contains("path == courseFilesPath || path.hasPrefix(courseFilesPrefix)"))
        XCTAssertTrue(source.contains("kFSEventStreamEventFlagMustScanSubDirs"))
        XCTAssertTrue(source.contains("await self.loadEngineSnapshotOffMain(force: forceSnapshotReload)"))
    }

    func testLiveRefreshReloadsSettingsAndCanonicalOverridesBeforeSnapshot() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func scheduleFileSystemEventRefresh(_ events: [KLMSFileSystemEvent])"))
        let end = try XCTUnwrap(
            source.range(of: "func reloadEngineState()", range: start.upperBound..<source.endIndex)
        )
        let refresh = String(source[start.lowerBound..<end.lowerBound])

        let config = try XCTUnwrap(refresh.range(of: "try self.loadConfig()"))
        let overrides = try XCTUnwrap(refresh.range(of: "try self.mergeConfiguredOverridesIntoCanonicalStore()"))
        let snapshot = try XCTUnwrap(refresh.range(of: "await self.loadEngineSnapshotOffMain(force: forceSnapshotReload)"))
        XCTAssertLessThan(config.lowerBound, overrides.lowerBound)
        XCTAssertLessThan(overrides.lowerBound, snapshot.lowerBound)
        XCTAssertTrue(source.contains("paths.overridesURL"))
        XCTAssertTrue(source.contains("Task.detached(priority: .utility)"))
    }
}
