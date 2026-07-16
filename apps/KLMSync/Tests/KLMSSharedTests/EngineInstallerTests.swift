import KLMSShared
import CryptoKit
import Darwin
import XCTest

final class EngineInstallerTests: XCTestCase {
    func testLocatorRejectsUnmanifestedSourceAndAcceptsManifestPayload() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-payload-locator-test-\(UUID().uuidString)", isDirectory: true)
        let source = temp.appendingPathComponent("source", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temp)
        }

        try FileManager.default.createDirectory(at: source.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("src/js", isDirectory: true), withIntermediateDirectories: true)
        try "#!/bin/zsh\n".write(to: source.appendingPathComponent("run_all_full.sh"), atomically: true, encoding: .utf8)

        let locator = EnginePayloadLocator()
        XCTAssertNil(
            locator.resolve(
                bundledResourceURL: nil,
                environment: ["KLMS_SYNC_ENGINE_SOURCE": source.path]
            )
        )
        let version = try writePayloadManifest(at: source, revisionCharacter: "0")
        let located = try XCTUnwrap(
            locator.resolve(
                bundledResourceURL: nil,
                environment: ["KLMS_SYNC_ENGINE_SOURCE": source.path]
            )
        )
        XCTAssertEqual(located.version, version)
    }

    func testInstallCopiesCodeButPreservesPrivateFilesAndRemovesRetiredLoginAssistFiles() throws {
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
        let payloadVersion = try writePayloadManifest(at: source, revisionCharacter: "a")

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "SYNC_MODE=\"quick\"\n".write(to: destination.appendingPathComponent("config.env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("runtime", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("runtime/python-packages/private", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("legacy", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("docs", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("src/js", isDirectory: true), withIntermediateDirectories: true)
        try "keep".write(to: destination.appendingPathComponent("runtime/python-packages/private/state.txt"), atomically: true, encoding: .utf8)
        let retiredLoginStateName = "kai" + "key_state.json"
        try "secret".write(to: destination.appendingPathComponent(retiredLoginStateName), atomically: true, encoding: .utf8)
        try "old".write(to: destination.appendingPathComponent("run_all_parallel.sh"), atomically: true, encoding: .utf8)
        try "old".write(to: destination.appendingPathComponent("docs/obsolete.md"), atomically: true, encoding: .utf8)
        try "old".write(to: destination.appendingPathComponent("src/js/sync_klms_calendar_jxa.js"), atomically: true, encoding: .utf8)

        let result = try EngineInstaller().installIfNeeded(
            payload: EnginePayload(rootURL: source, version: payloadVersion),
            destination: destination,
            force: true
        )

        XCTAssertTrue(result.installed)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("config.env"), encoding: .utf8),
            "SYNC_MODE=\"quick\"\n"
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("docs").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("run_all_parallel.sh").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("src/js/sync_klms_calendar_jxa.js").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(retiredLoginStateName).path))
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
        let firstVersion = try writePayloadManifest(at: source, revisionCharacter: "b")

        _ = try EngineInstaller().installIfNeeded(
            payload: EnginePayload(rootURL: source, version: firstVersion),
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
        let secondVersion = try writePayloadManifest(at: source, revisionCharacter: "c")
        _ = try EngineInstaller().installIfNeeded(
            payload: EnginePayload(rootURL: source, version: secondVersion),
            destination: destination,
            force: true
        )

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("manual_assignment_overrides.json"), encoding: .utf8),
            "{\"assignments\":{\"local\":{}}}\n"
        )
    }

    func testTamperedPayloadIsRejectedBeforeDestinationChanges() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-installer-tamper-test-\(UUID().uuidString)", isDirectory: true)
        let source = temp.appendingPathComponent("source", isDirectory: true)
        let destination = temp.appendingPathComponent("destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try prepareRequiredPayloadLayout(at: source)
        let protectedFile = source.appendingPathComponent("src/js/protected.js")
        try FileManager.default.createDirectory(at: protectedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "trusted\n".write(to: protectedFile, atomically: true, encoding: .utf8)
        let version = try writePayloadManifest(at: source, revisionCharacter: "d")
        try "tampered\n".write(to: protectedFile, atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let privateConfig = destination.appendingPathComponent("config.env")
        try "PRIVATE=1\n".write(to: privateConfig, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try EngineInstaller().installIfNeeded(
                payload: EnginePayload(rootURL: source, version: version),
                destination: destination,
                force: true
            )
        ) { error in
            guard case EngineInstallerError.invalidPayload = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: privateConfig, encoding: .utf8), "PRIVATE=1\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("src").path))
    }

    func testInjectedCommitFailureRollsBackEveryManagedPath() throws {
        enum InjectedFailure: Error { case afterSourceSwap }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-installer-rollback-test-\(UUID().uuidString)", isDirectory: true)
        let oldSource = temp.appendingPathComponent("old-source", isDirectory: true)
        let newSource = temp.appendingPathComponent("new-source", isDirectory: true)
        let destination = temp.appendingPathComponent("destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try prepareRequiredPayloadLayout(at: oldSource)
        try "old\n".write(
            to: oldSource.appendingPathComponent("src/js/version.js"),
            atomically: true,
            encoding: .utf8
        )
        let oldVersion = try writePayloadManifest(at: oldSource, revisionCharacter: "e")
        _ = try EngineInstaller().installIfNeeded(
            payload: EnginePayload(rootURL: oldSource, version: oldVersion),
            destination: destination,
            force: true
        )
        try "PRIVATE=keep\n".write(
            to: destination.appendingPathComponent("config.env"),
            atomically: true,
            encoding: .utf8
        )

        try prepareRequiredPayloadLayout(at: newSource)
        try "new\n".write(
            to: newSource.appendingPathComponent("src/js/version.js"),
            atomically: true,
            encoding: .utf8
        )
        let newVersion = try writePayloadManifest(at: newSource, revisionCharacter: "f")
        let failingInstaller = EngineInstaller { checkpoint in
            if checkpoint == .didReplaceManagedPath("src") {
                throw InjectedFailure.afterSourceSwap
            }
        }

        XCTAssertThrowsError(
            try failingInstaller.installIfNeeded(
                payload: EnginePayload(rootURL: newSource, version: newVersion),
                destination: destination,
                force: true
            )
        ) { error in
            XCTAssertTrue(error is InjectedFailure)
        }
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("src/js/version.js"), encoding: .utf8),
            "old\n"
        )
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("runtime/automation/app_engine_payload_version"),
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines),
            oldVersion
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("config.env"), encoding: .utf8),
            "PRIVATE=keep\n"
        )
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            .filter { $0.hasPrefix(".klms-engine-install-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testMatchingVersionIsReinstalledWhenManagedFileWasModified() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-installer-repair-test-\(UUID().uuidString)", isDirectory: true)
        let source = temp.appendingPathComponent("source", isDirectory: true)
        let destination = temp.appendingPathComponent("destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try prepareRequiredPayloadLayout(at: source)
        let sourceFile = source.appendingPathComponent("src/js/version.js")
        try "trusted\n".write(to: sourceFile, atomically: true, encoding: .utf8)
        let version = try writePayloadManifest(at: source, revisionCharacter: "1")
        _ = try EngineInstaller().installIfNeeded(
            payload: EnginePayload(rootURL: source, version: version),
            destination: destination,
            force: true
        )
        let installedFile = destination.appendingPathComponent("src/js/version.js")
        try "modified\n".write(to: installedFile, atomically: true, encoding: .utf8)

        let repaired = try EngineInstaller().installIfNeeded(
            payload: EnginePayload(rootURL: source, version: version),
            destination: destination,
            force: false
        )
        XCTAssertTrue(repaired.installed)
        XCTAssertEqual(try String(contentsOf: installedFile, encoding: .utf8), "trusted\n")
    }

    func testNextLaunchRecoversInterruptedManagedPathSwap() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-installer-crash-recovery-test-\(UUID().uuidString)", isDirectory: true)
        let source = temp.appendingPathComponent("source", isDirectory: true)
        let destination = temp.appendingPathComponent("destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try prepareRequiredPayloadLayout(at: source)
        try "old\n".write(
            to: source.appendingPathComponent("src/js/version.js"),
            atomically: true,
            encoding: .utf8
        )
        let version = try writePayloadManifest(at: source, revisionCharacter: "2")
        _ = try EngineInstaller().installIfNeeded(
            payload: EnginePayload(rootURL: source, version: version),
            destination: destination,
            force: true
        )

        let transaction = destination.appendingPathComponent(
            ".klms-engine-install-interrupted",
            isDirectory: true
        )
        let backup = transaction.appendingPathComponent("backup/src", isDirectory: true)
        try FileManager.default.createDirectory(
            at: backup.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: destination.appendingPathComponent("src"), to: backup)
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("src/js", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "partial-new\n".write(
            to: destination.appendingPathComponent("src/js/version.js"),
            atomically: true,
            encoding: .utf8
        )
        let journal: [String: Any] = [
            "schemaVersion": 1,
            "phase": "committing",
            "entries": [[
                "relativePath": "src",
                "hadExistingItem": true,
                "sourceRelativePath": "staged-payload/src",
            ]],
        ]
        let journalData = try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys])
        try journalData.write(to: transaction.appendingPathComponent("journal.json"), options: .atomic)

        let result = try EngineInstaller().installIfNeeded(
            payload: EnginePayload(rootURL: source, version: version),
            destination: destination,
            force: false
        )

        XCTAssertFalse(result.installed)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("src/js/version.js"), encoding: .utf8),
            "old\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.path))
    }

    func testConcurrentInstallerIsRejectedByProcessLock() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("klms-installer-lock-test-\(UUID().uuidString)", isDirectory: true)
        let source = temp.appendingPathComponent("source", isDirectory: true)
        let destination = temp.appendingPathComponent("destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try prepareRequiredPayloadLayout(at: source)
        let version = try writePayloadManifest(at: source, revisionCharacter: "3")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let lock = destination.appendingPathComponent(".klms-engine-install.lock")
        let descriptor = Darwin.open(
            lock.path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }

        XCTAssertThrowsError(
            try EngineInstaller().installIfNeeded(
                payload: EnginePayload(rootURL: source, version: version),
                destination: destination,
                force: true
            )
        ) { error in
            guard case let EngineInstallerError.unsafeDestination(reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "install-in-progress")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("src").path))
    }

    private func prepareRequiredPayloadLayout(at root: URL) throws {
        for directory in EngineInstaller.installedCodeDirectories {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/js", isDirectory: true),
            withIntermediateDirectories: true
        )
        for file in EngineInstaller.rootCodeFiles {
            let url = root.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: url.path) {
                try "#!/bin/zsh\n".write(to: url, atomically: true, encoding: .utf8)
            }
        }
        let configExample = root.appendingPathComponent("examples/config.env.example")
        if !FileManager.default.fileExists(atPath: configExample.path) {
            try "SYNC_MODE=auto\n".write(to: configExample, atomically: true, encoding: .utf8)
        }
        for file in [
            "python-packages/bs4/__init__.py",
            "python-packages/soupsieve/__init__.py",
            "python-packages/typing_extensions.py",
        ] {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try "# package\n".write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    @discardableResult
    private func writePayloadManifest(at root: URL, revisionCharacter: Character) throws -> String {
        try prepareRequiredPayloadLayout(at: root)
        let revision = String(repeating: String(revisionCharacter), count: 40)
        let versionURL = root.appendingPathComponent("EnginePayloadVersion.txt")
        try "\(revision)\n".write(to: versionURL, atomically: true, encoding: .utf8)
        let manifestURL = root.appendingPathComponent("EnginePayloadManifest.json")

        var files: [[String: Any]] = []
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ))
        for case let fileURL as URL in enumerator {
            if fileURL.standardizedFileURL == manifestURL.standardizedFileURL { continue }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relativePath = String(fileURL.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            let data = try Data(contentsOf: fileURL)
            files.append([
                "path": relativePath,
                "bytes": data.count,
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            ])
        }
        files.sort { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
        let totalBytes = files.reduce(0) { $0 + ($1["bytes"] as? Int ?? 0) }
        let manifest: [String: Any] = [
            "schemaVersion": 2,
            "payloadVersion": revision,
            "sourceRevision": revision,
            "dirty": false,
            "allowlistSHA256": String(repeating: "a", count: 64),
            "pythonAllowlistSHA256": String(repeating: "b", count: 64),
            "fileCount": files.count,
            "totalBytes": totalBytes,
            "files": files,
        ]
        var data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        try data.write(to: manifestURL, options: .atomic)
        return revision
    }
}
