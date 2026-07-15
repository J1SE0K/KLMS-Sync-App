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

        let probe = FileSystemEventCallbackProbe()
        let watcher = KLMSFileSystemEventWatcher(paths: [root]) {
            probe.signalOnce()
        }
        defer {
            watcher.stop()
        }

        XCTAssertTrue(watcher.start())
        try Data("changed".utf8).write(
            to: root.appendingPathComponent("state.json"),
            options: .atomic
        )

        XCTAssertEqual(
            probe.semaphore.wait(timeout: .now() + 3),
            .success,
            "FSEvents should deliver a local state change without periodic polling."
        )
    }

    func testLiveRefreshReloadsSettingsAndCanonicalOverridesBeforeSnapshot() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func scheduleFileSystemEventRefresh()"))
        let end = try XCTUnwrap(
            source.range(of: "func reloadEngineState()", range: start.upperBound..<source.endIndex)
        )
        let refresh = String(source[start.lowerBound..<end.lowerBound])

        let config = try XCTUnwrap(refresh.range(of: "try self.loadConfig()"))
        let overrides = try XCTUnwrap(refresh.range(of: "try self.mergeConfiguredOverridesIntoCanonicalStore()"))
        let snapshot = try XCTUnwrap(refresh.range(of: "self.loadEngineSnapshot(force: false)"))
        XCTAssertLessThan(config.lowerBound, overrides.lowerBound)
        XCTAssertLessThan(overrides.lowerBound, snapshot.lowerBound)
        XCTAssertTrue(source.contains("paths.overridesURL"))
    }
}
