import KLMSShared
import XCTest

final class EngineInstallerTests: XCTestCase {
    func testSourcePayloadVersionChangesWhenSourceChanges() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-payload-version-test-\(UUID().uuidString)", isDirectory: true)
        let source = temp.appendingPathComponent("repo", isDirectory: true)
        let nestedFile = source
            .appendingPathComponent("apps/KLMSync/Sources/KLMSShared/EngineInstaller.swift")
        defer {
            try? FileManager.default.removeItem(at: temp)
        }

        try FileManager.default.createDirectory(at: nestedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("src/js", isDirectory: true), withIntermediateDirectories: true)
        try "#!/bin/zsh\n".write(to: source.appendingPathComponent("sync_klms_core.sh"), atomically: true, encoding: .utf8)
        try "#!/bin/zsh\n".write(to: source.appendingPathComponent("run_all_full.sh"), atomically: true, encoding: .utf8)
        try "one\n".write(to: source.appendingPathComponent("src/js/sync_klms_notes.js"), atomically: true, encoding: .utf8)
        try "test\n".write(to: nestedFile, atomically: true, encoding: .utf8)

        let locator = EnginePayloadLocator()
        let first = try XCTUnwrap(locator.resolve(bundledResourceURL: nil, environment: [:], filePath: nestedFile.path))
        try "one plus new behavior\n".write(to: source.appendingPathComponent("src/js/sync_klms_notes.js"), atomically: true, encoding: .utf8)
        let second = try XCTUnwrap(locator.resolve(bundledResourceURL: nil, environment: [:], filePath: nestedFile.path))

        XCTAssertNotEqual(first.version, second.version)
    }

    func testInstallCopiesCodeButPreservesPrivateFiles() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-installer-test-\(UUID().uuidString)", isDirectory: true)
        let source = temp.appendingPathComponent("source", isDirectory: true)
        let destination = temp.appendingPathComponent("destination", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temp)
        }

        try FileManager.default.createDirectory(at: source.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("src/sh", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("examples", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("python-packages/bs4", isDirectory: true), withIntermediateDirectories: true)
        try "#!/bin/zsh\n".write(to: source.appendingPathComponent("run_all_full.sh"), atomically: true, encoding: .utf8)
        try "x".write(to: source.appendingPathComponent("bin/run_all_full.sh"), atomically: true, encoding: .utf8)
        try "package".write(to: source.appendingPathComponent("python-packages/bs4/__init__.py"), atomically: true, encoding: .utf8)
        try "SYNC_MODE=\"auto\"\n".write(to: source.appendingPathComponent("examples/config.env.example"), atomically: true, encoding: .utf8)
        try "{\"assignments\":{}}\n".write(
            to: source.appendingPathComponent("manual_assignment_overrides.json"),
            atomically: true,
            encoding: .utf8
        )

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "SYNC_MODE=\"quick\"\n".write(to: destination.appendingPathComponent("config.env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("runtime", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("runtime/python-packages/private", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("legacy", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("src/js", isDirectory: true), withIntermediateDirectories: true)
        try "keep".write(to: destination.appendingPathComponent("runtime/python-packages/private/state.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: destination.appendingPathComponent("kaikey_state.json"), atomically: true, encoding: .utf8)
        try "old".write(to: destination.appendingPathComponent("run_all_parallel.sh"), atomically: true, encoding: .utf8)
        try "old".write(to: destination.appendingPathComponent("src/js/sync_klms_calendar_jxa.js"), atomically: true, encoding: .utf8)

        let result = try EngineInstaller().installIfNeeded(
            payload: EnginePayload(rootURL: source, version: "test"),
            destination: destination,
            force: true
        )

        XCTAssertTrue(result.installed)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("config.env"), encoding: .utf8),
            "SYNC_MODE=\"quick\"\n"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("kaikey_state.json"), encoding: .utf8),
            "secret"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("runtime/python-packages/private/state.txt"), encoding: .utf8),
            "keep"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("runtime/app-python-packages/bs4/__init__.py"), encoding: .utf8),
            "package"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("manual_assignment_overrides.json"), encoding: .utf8),
            "{\"assignments\":{}}\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("legacy").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("run_all_parallel.sh").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("src/js/sync_klms_calendar_jxa.js").path))
    }

    func testInstallCreatesOverridesOnlyWhenMissing() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-installer-overrides-test-\(UUID().uuidString)", isDirectory: true)
        let source = temp.appendingPathComponent("source", isDirectory: true)
        let destination = temp.appendingPathComponent("destination", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temp)
        }

        try FileManager.default.createDirectory(at: source.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("src", isDirectory: true), withIntermediateDirectories: true)
        try "#!/bin/zsh\n".write(to: source.appendingPathComponent("run_all_full.sh"), atomically: true, encoding: .utf8)
        try "{\"assignments\":{\"repo\":{}}}\n".write(
            to: source.appendingPathComponent("manual_assignment_overrides.json"),
            atomically: true,
            encoding: .utf8
        )

        _ = try EngineInstaller().installIfNeeded(
            payload: EnginePayload(rootURL: source, version: "test"),
            destination: destination,
            force: true
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("manual_assignment_overrides.json"), encoding: .utf8),
            "{\"assignments\":{\"repo\":{}}}\n"
        )

        try "{\"assignments\":{\"local\":{}}}\n".write(
            to: destination.appendingPathComponent("manual_assignment_overrides.json"),
            atomically: true,
            encoding: .utf8
        )
        _ = try EngineInstaller().installIfNeeded(
            payload: EnginePayload(rootURL: source, version: "test-2"),
            destination: destination,
            force: true
        )

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("manual_assignment_overrides.json"), encoding: .utf8),
            "{\"assignments\":{\"local\":{}}}\n"
        )
    }
}
