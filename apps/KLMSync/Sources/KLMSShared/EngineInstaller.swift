import Foundation
import CryptoKit
import Darwin

public enum EngineInstallerError: Error, LocalizedError, Equatable {
    case invalidPayload(String)
    case unsafeDestination(String)
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPayload(reason):
            "KLMS 엔진 payload 검증에 실패했습니다: \(reason)"
        case let .unsafeDestination(reason):
            "KLMS 엔진 설치 경로가 안전하지 않습니다: \(reason)"
        case let .rollbackFailed(reason):
            "KLMS 엔진 설치 복구에 실패했습니다. 기존 파일은 설치 임시 폴더에 보존했습니다: \(reason)"
        }
    }
}

public enum EngineInstallCheckpoint: Sendable, Equatable {
    case payloadValidated
    case payloadStaged
    case beforeCommit
    case didReplaceManagedPath(String)
    case installedPayloadVerified
}

private struct EnginePayloadManifest: Decodable, Equatable {
    var schemaVersion: Int
    var payloadVersion: String
    var sourceRevision: String
    var dirty: Bool
    var allowlistSHA256: String
    var pythonAllowlistSHA256: String
    var fileCount: Int
    var totalBytes: Int64
    var files: [EnginePayloadManifestFile]
}

private struct EnginePayloadManifestFile: Decodable, Equatable {
    var path: String
    var bytes: Int64
    var sha256: String
}

private struct ValidatedEnginePayload {
    var payload: EnginePayload
    var manifest: EnginePayloadManifest
    var manifestURL: URL
    var filesByPath: [String: EnginePayloadManifestFile]
}

private enum EngineInstallPhase: String, Codable {
    case committing
    case committed
}

private struct EngineInstallJournalEntry: Codable, Equatable {
    var relativePath: String
    var hadExistingItem: Bool
    var sourceRelativePath: String?
}

private struct EngineInstallJournal: Codable, Equatable {
    var schemaVersion: Int
    var phase: EngineInstallPhase
    var entries: [EngineInstallJournalEntry]
}

public struct EnginePayload: Sendable, Equatable {
    public var rootURL: URL
    public var version: String

    public init(rootURL: URL, version: String) {
        self.rootURL = rootURL
        self.version = version
    }

    public var hasEngineLayout: Bool {
        FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("bin", isDirectory: true).path)
            && FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("src", isDirectory: true).path)
            && FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("run_all_full.sh").path)
    }

    public var hasManifestEnvelope: Bool {
        let manifest = rootURL.appendingPathComponent("EnginePayloadManifest.json")
        let version = rootURL.appendingPathComponent("EnginePayloadVersion.txt")
        return !manifest.hasDirectoryPath
            && !version.hasDirectoryPath
            && FileManager.default.fileExists(atPath: manifest.path)
            && FileManager.default.fileExists(atPath: version.path)
    }
}

public struct EngineInstallResult: Sendable, Equatable {
    public var installed: Bool
    public var sourceURL: URL
    public var destinationURL: URL
    public var version: String
    public var copiedPaths: [String]
    public var createdConfig: Bool

    public init(
        installed: Bool,
        sourceURL: URL,
        destinationURL: URL,
        version: String,
        copiedPaths: [String],
        createdConfig: Bool
    ) {
        self.installed = installed
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.version = version
        self.copiedPaths = copiedPaths
        self.createdConfig = createdConfig
    }
}

public struct EnginePayloadLocator: Sendable {
    public init() {}

    public func resolve(
        bundledResourceURL: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> EnginePayload? {
        if let bundled = bundledResourceURL?.appendingPathComponent("EnginePayload", isDirectory: true) {
            let payload = EnginePayload(
                rootURL: bundled,
                version: explicitVersion(in: bundled) ?? "bundled"
            )
            if payload.hasEngineLayout, payload.hasManifestEnvelope {
                return payload
            }
        }

        if let override = environment["KLMS_SYNC_ENGINE_SOURCE"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            let payload = EnginePayload(rootURL: url, version: explicitVersion(in: url) ?? "override")
            if payload.hasEngineLayout, payload.hasManifestEnvelope {
                return payload
            }
        }

        return nil
    }

    private func explicitVersion(in rootURL: URL) -> String? {
        let explicit = rootURL.appendingPathComponent("EnginePayloadVersion.txt")
        if let text = try? String(contentsOf: explicit, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return nil
    }

}

public struct EngineInstaller {
    public var fileManager: FileManager
    private var checkpoint: (EngineInstallCheckpoint) throws -> Void

    public init(
        fileManager: FileManager = .default,
        checkpoint: @escaping (EngineInstallCheckpoint) throws -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.checkpoint = checkpoint
    }

    public func installIfNeeded(
        payload: EnginePayload,
        destination: URL,
        force: Bool = false
    ) throws -> EngineInstallResult {
        let validatedPayload = try validate(payload: payload)
        try checkpoint(.payloadValidated)
        let destination = destination.standardizedFileURL
        try validateDestination(destination, payloadRoot: payload.rootURL)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let installLock = try acquireInstallLock(at: destination)
        defer { releaseInstallLock(installLock) }
        try recoverStaleTransactions(at: destination)

        if !force, (try? installedPayloadMatches(validatedPayload, at: destination)) == true {
            return EngineInstallResult(
                installed: false,
                sourceURL: payload.rootURL,
                destinationURL: destination,
                version: payload.version,
                copiedPaths: [],
                createdConfig: false
            )
        }

        let transactionRoot = destination.appendingPathComponent(
            ".klms-engine-install-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagedPayloadRoot = transactionRoot.appendingPathComponent("staged-payload", isDirectory: true)
        let defaultsRoot = transactionRoot.appendingPathComponent("defaults", isDirectory: true)
        let backupRoot = transactionRoot.appendingPathComponent("backup", isDirectory: true)
        let journalURL = transactionRoot.appendingPathComponent("journal.json")
        var journal = EngineInstallJournal(schemaVersion: 1, phase: .committing, entries: [])
        var removeTransactionOnExit = true
        defer {
            if removeTransactionOnExit {
                try? fileManager.removeItem(at: transactionRoot)
            }
        }

        try fileManager.createDirectory(at: transactionRoot, withIntermediateDirectories: false)
        try writeInstallJournal(journal, to: journalURL)
        try fileManager.copyItem(at: payload.rootURL, to: stagedPayloadRoot)
        let stagedPayload = EnginePayload(rootURL: stagedPayloadRoot, version: payload.version)
        let stagedValidation = try validate(payload: stagedPayload)
        guard stagedValidation.manifest == validatedPayload.manifest else {
            throw EngineInstallerError.invalidPayload("staged-manifest-mismatch")
        }
        try makeScriptsExecutable(in: stagedPayloadRoot)
        try checkpoint(.payloadStaged)

        var items = try managedInstallItems(
            stagedPayloadRoot: stagedPayloadRoot,
            defaultsRoot: defaultsRoot,
            destination: destination
        )
        items.append(contentsOf: retiredInstallItems(destination: destination))
        items.append(
            InstallItem(
                relativePath: Self.installedManifestRelativePath,
                sourceURL: stagedPayloadRoot.appendingPathComponent("EnginePayloadManifest.json"),
                copiedPath: nil,
                onlyIfMissing: false
            )
        )
        items.append(
            InstallItem(
                relativePath: Self.installedVersionRelativePath,
                sourceURL: stagedPayloadRoot.appendingPathComponent("EnginePayloadVersion.txt"),
                copiedPath: nil,
                onlyIfMissing: false
            )
        )

        var committed: [CommittedInstallItem] = []
        do {
            try checkpoint(.beforeCommit)
            for item in items {
                let target = destination.appendingPathComponent(item.relativePath)
                try validateManagedTarget(target, relativePath: item.relativePath, destination: destination)
                if item.onlyIfMissing, itemExists(target) {
                    continue
                }
                let backup = backupRoot.appendingPathComponent(item.relativePath)
                let hadExistingItem = itemExists(target)
                let sourceRelativePath = item.sourceURL.map {
                    relativePath(of: $0, under: transactionRoot)
                }
                let journalEntry = EngineInstallJournalEntry(
                    relativePath: item.relativePath,
                    hadExistingItem: hadExistingItem,
                    sourceRelativePath: sourceRelativePath
                )
                try validateJournalEntry(journalEntry)
                journal.entries.append(journalEntry)
                try writeInstallJournal(journal, to: journalURL)
                var state = CommittedInstallItem(
                    relativePath: item.relativePath,
                    targetURL: target,
                    backupURL: backup,
                    hadBackup: false,
                    installedNewItem: false,
                    copiedPath: item.copiedPath
                )
                if hadExistingItem {
                    try fileManager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: target, to: backup)
                    state.hadBackup = true
                }
                committed.append(state)
                if let source = item.sourceURL {
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: source, to: target)
                    committed[committed.count - 1].installedNewItem = true
                }
                try checkpoint(.didReplaceManagedPath(item.relativePath))
            }
            guard try installedPayloadMatches(validatedPayload, at: destination) else {
                throw EngineInstallerError.invalidPayload("installed-payload-verification-failed")
            }
            try checkpoint(.installedPayloadVerified)
            journal.phase = .committed
            try writeInstallJournal(journal, to: journalURL)
        } catch {
            do {
                try rollback(committed.reversed())
            } catch let rollbackError {
                removeTransactionOnExit = false
                throw EngineInstallerError.rollbackFailed(
                    "install=\(error.localizedDescription); rollback=\(rollbackError.localizedDescription); transaction=\(transactionRoot.path)"
                )
            }
            throw error
        }

        let copiedPaths = committed.compactMap(\.copiedPath)
        return EngineInstallResult(
            installed: true,
            sourceURL: payload.rootURL,
            destinationURL: destination,
            version: payload.version,
            copiedPaths: copiedPaths,
            createdConfig: committed.contains {
                $0.relativePath == "config.env" && $0.installedNewItem
            }
        )
    }

    private func acquireInstallLock(at destination: URL) throws -> Int32 {
        let lockURL = destination.appendingPathComponent(Self.installLockName)
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw EngineInstallerError.unsafeDestination("install-lock-unavailable")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw EngineInstallerError.unsafeDestination("install-in-progress")
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw EngineInstallerError.unsafeDestination("install-lock-permissions")
        }
        return descriptor
    }

    private func releaseInstallLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private func writeInstallJournal(_ journal: EngineInstallJournal, to journalURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(journal)
        data.append(0x0A)
        let temporaryURL = journalURL.deletingLastPathComponent().appendingPathComponent(
            ".journal-\(UUID().uuidString).tmp"
        )
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw EngineInstallerError.rollbackFailed("journal-create-failed")
        }
        defer { try? fileManager.removeItem(at: temporaryURL) }
        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard Darwin.rename(temporaryURL.path, journalURL.path) == 0 else {
            throw EngineInstallerError.rollbackFailed("journal-replace-failed")
        }
        try synchronizeDirectory(journalURL.deletingLastPathComponent())
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw EngineInstallerError.rollbackFailed("journal-directory-open-failed")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw EngineInstallerError.rollbackFailed("journal-directory-sync-failed")
        }
    }

    private func recoverStaleTransactions(at destination: URL) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants]
        )
        for transactionRoot in entries where transactionRoot.lastPathComponent.hasPrefix(Self.transactionPrefix) {
            let values = try transactionRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw EngineInstallerError.rollbackFailed("unsafe-stale-transaction")
            }
            let journalURL = transactionRoot.appendingPathComponent("journal.json")
            if !itemExists(journalURL) {
                let backupRoot = transactionRoot.appendingPathComponent("backup", isDirectory: true)
                if try directoryContainsItem(backupRoot) {
                    throw EngineInstallerError.rollbackFailed(
                        "stale-transaction-missing-journal-\(transactionRoot.path)"
                    )
                }
                try fileManager.removeItem(at: transactionRoot)
                continue
            }
            guard isRegularFile(journalURL), !isSymbolicLink(journalURL) else {
                throw EngineInstallerError.rollbackFailed("unsafe-stale-journal")
            }
            guard let journalSize = try? regularFileSize(journalURL),
                  journalSize <= 1024 * 1024 else {
                throw EngineInstallerError.rollbackFailed("oversized-stale-journal")
            }
            let journalData = try Data(contentsOf: journalURL, options: [.mappedIfSafe])
            guard let journal = try? JSONDecoder().decode(EngineInstallJournal.self, from: journalData),
                  journal.schemaVersion == 1 else {
                throw EngineInstallerError.rollbackFailed(
                    "invalid-stale-journal-\(transactionRoot.path)"
                )
            }
            if journal.phase == .committed {
                try fileManager.removeItem(at: transactionRoot)
                continue
            }
            var seenPaths = Set<String>()
            for entry in journal.entries {
                try validateJournalEntry(entry)
                guard seenPaths.insert(entry.relativePath).inserted else {
                    throw EngineInstallerError.rollbackFailed("duplicate-stale-journal-path")
                }
            }
            for entry in journal.entries.reversed() {
                try recover(entry, transactionRoot: transactionRoot, destination: destination)
            }
            try fileManager.removeItem(at: transactionRoot)
        }
    }

    private func recover(
        _ entry: EngineInstallJournalEntry,
        transactionRoot: URL,
        destination: URL
    ) throws {
        let target = destination.appendingPathComponent(entry.relativePath)
        try validateManagedTarget(target, relativePath: entry.relativePath, destination: destination)
        let backupRelativePath = "backup/\(entry.relativePath)"
        try validateTransactionPath(backupRelativePath, under: transactionRoot)
        let backup = transactionRoot.appendingPathComponent(backupRelativePath)
        if itemExists(backup) {
            if itemExists(target) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: backup, to: target)
            return
        }
        if entry.hadExistingItem {
            guard itemExists(target) else {
                throw EngineInstallerError.rollbackFailed("stale-backup-missing-\(entry.relativePath)")
            }
            return
        }
        guard let sourceRelativePath = entry.sourceRelativePath else { return }
        try validateTransactionPath(sourceRelativePath, under: transactionRoot)
        let source = transactionRoot.appendingPathComponent(sourceRelativePath)
        if !itemExists(source), itemExists(target) {
            try fileManager.removeItem(at: target)
        }
    }

    private func validateJournalEntry(_ entry: EngineInstallJournalEntry) throws {
        guard Self.recoverableManagedPaths.contains(entry.relativePath),
              entry.sourceRelativePath == expectedJournalSource(for: entry.relativePath) else {
            throw EngineInstallerError.rollbackFailed("invalid-journal-entry")
        }
    }

    private func expectedJournalSource(for relativePath: String) -> String? {
        if Self.installedCodeDirectories.contains(relativePath)
            || Self.rootCodeFiles.contains(relativePath) {
            return "staged-payload/\(relativePath)"
        }
        switch relativePath {
        case "runtime/app-python-packages":
            return "staged-payload/python-packages"
        case Self.installedManifestRelativePath:
            return "staged-payload/EnginePayloadManifest.json"
        case Self.installedVersionRelativePath:
            return "staged-payload/EnginePayloadVersion.txt"
        case "config.env":
            return "defaults/config.env"
        case "manual_assignment_overrides.json":
            return "defaults/manual_assignment_overrides.json"
        default:
            return nil
        }
    }

    private func validateTransactionPath(_ relativePath: String, under transactionRoot: URL) throws {
        guard isSafeRelativePath(relativePath) else {
            throw EngineInstallerError.rollbackFailed("invalid-stale-transaction-path")
        }
        var current = transactionRoot
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component))
            if itemExists(current), isSymbolicLink(current) {
                throw EngineInstallerError.rollbackFailed("symlinked-stale-transaction-path")
            }
        }
    }

    private func directoryContainsItem(_ directory: URL) throws -> Bool {
        guard itemExists(directory) else { return false }
        guard !isSymbolicLink(directory) else {
            throw EngineInstallerError.rollbackFailed("symlinked-stale-backup")
        }
        return try !fileManager.contentsOfDirectory(atPath: directory.path).isEmpty
    }

    private func validate(payload: EnginePayload) throws -> ValidatedEnginePayload {
        let root = payload.rootURL.standardizedFileURL
        guard itemExists(root), !isSymbolicLink(root) else {
            throw EngineInstallerError.invalidPayload("missing-or-symlinked-root")
        }
        let manifestURL = root.appendingPathComponent("EnginePayloadManifest.json")
        guard isRegularFile(manifestURL), !isSymbolicLink(manifestURL) else {
            throw EngineInstallerError.invalidPayload("missing-manifest")
        }
        let manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        guard manifestData.count <= 2 * 1024 * 1024 else {
            throw EngineInstallerError.invalidPayload("manifest-too-large")
        }
        let manifest: EnginePayloadManifest
        do {
            manifest = try JSONDecoder().decode(EnginePayloadManifest.self, from: manifestData)
        } catch {
            throw EngineInstallerError.invalidPayload("invalid-manifest")
        }
        guard manifest.schemaVersion == 2 else {
            throw EngineInstallerError.invalidPayload("unsupported-manifest")
        }
        guard payload.version == manifest.payloadVersion,
              let version = try? String(
                  contentsOf: root.appendingPathComponent("EnginePayloadVersion.txt"),
                  encoding: .utf8
              ).trimmingCharacters(in: .whitespacesAndNewlines),
              version == payload.version else {
            throw EngineInstallerError.invalidPayload("version-mismatch")
        }
        guard isLowerHex(manifest.sourceRevision, length: 40) else {
            throw EngineInstallerError.invalidPayload("invalid-source-revision")
        }
        if manifest.dirty {
            let prefix = "\(manifest.sourceRevision)-dirty-"
            let suffix = manifest.payloadVersion.hasPrefix(prefix)
                ? String(manifest.payloadVersion.dropFirst(prefix.count))
                : ""
            guard suffix.utf8.count == 14, suffix.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw EngineInstallerError.invalidPayload("dirty-version-mismatch")
            }
        } else if manifest.payloadVersion != manifest.sourceRevision {
            throw EngineInstallerError.invalidPayload("clean-version-mismatch")
        }
        guard isLowerHex(manifest.allowlistSHA256, length: 64),
              isLowerHex(manifest.pythonAllowlistSHA256, length: 64) else {
            throw EngineInstallerError.invalidPayload("invalid-allowlist-digest")
        }

        var manifestFiles: [String: EnginePayloadManifestFile] = [:]
        var declaredBytes: Int64 = 0
        for file in manifest.files {
            guard isSafeRelativePath(file.path),
                  file.bytes >= 0,
                  isLowerHex(file.sha256, length: 64),
                  manifestFiles[file.path] == nil else {
                throw EngineInstallerError.invalidPayload("invalid-file-entry")
            }
            let (nextBytes, overflow) = declaredBytes.addingReportingOverflow(file.bytes)
            guard !overflow else {
                throw EngineInstallerError.invalidPayload("payload-size-overflow")
            }
            declaredBytes = nextBytes
            manifestFiles[file.path] = file
        }
        guard manifest.fileCount == manifestFiles.count,
              manifest.totalBytes == declaredBytes else {
            throw EngineInstallerError.invalidPayload("manifest-count-mismatch")
        }

        let actualFiles = try regularFiles(in: root, excluding: manifestURL)
        guard Set(actualFiles.keys) == Set(manifestFiles.keys) else {
            throw EngineInstallerError.invalidPayload("inventory-path-mismatch")
        }
        for (relativePath, file) in manifestFiles {
            guard let actualURL = actualFiles[relativePath],
                  try regularFileSize(actualURL) == file.bytes,
                  try sha256Hex(actualURL) == file.sha256 else {
                throw EngineInstallerError.invalidPayload("inventory-digest-mismatch-\(relativePath)")
            }
        }
        guard payload.hasEngineLayout,
              Self.installedCodeDirectories.allSatisfy({ itemExists(root.appendingPathComponent($0)) }),
              Self.rootCodeFiles.allSatisfy({ isRegularFile(root.appendingPathComponent($0)) }),
              Self.requiredPythonPayloadFiles.allSatisfy({
                  isRegularFile(root.appendingPathComponent("python-packages/\($0)"))
              }) else {
            throw EngineInstallerError.invalidPayload("missing-required-engine-layout")
        }
        return ValidatedEnginePayload(
            payload: payload,
            manifest: manifest,
            manifestURL: manifestURL,
            filesByPath: manifestFiles
        )
    }

    private func managedInstallItems(
        stagedPayloadRoot: URL,
        defaultsRoot: URL,
        destination: URL
    ) throws -> [InstallItem] {
        var items = Self.installedCodeDirectories.map { directory in
            InstallItem(
                relativePath: directory,
                sourceURL: stagedPayloadRoot.appendingPathComponent(directory, isDirectory: true),
                copiedPath: directory,
                onlyIfMissing: false
            )
        }
        items.append(
            InstallItem(
                relativePath: "runtime/app-python-packages",
                sourceURL: stagedPayloadRoot.appendingPathComponent("python-packages", isDirectory: true),
                copiedPath: "runtime/app-python-packages",
                onlyIfMissing: false
            )
        )
        items.append(contentsOf: Self.rootCodeFiles.map { file in
            InstallItem(
                relativePath: file,
                sourceURL: stagedPayloadRoot.appendingPathComponent(file),
                copiedPath: file,
                onlyIfMissing: false
            )
        })

        let configURL = destination.appendingPathComponent("config.env")
        if !itemExists(configURL) {
            let stagedConfig = defaultsRoot.appendingPathComponent("config.env")
            try fileManager.createDirectory(at: defaultsRoot, withIntermediateDirectories: true)
            try fileManager.copyItem(
                at: stagedPayloadRoot.appendingPathComponent("examples/config.env.example"),
                to: stagedConfig
            )
            items.append(
                InstallItem(
                    relativePath: "config.env",
                    sourceURL: stagedConfig,
                    copiedPath: nil,
                    onlyIfMissing: true
                )
            )
        }

        let overridesURL = destination.appendingPathComponent("manual_assignment_overrides.json")
        let payloadOverrides = stagedPayloadRoot.appendingPathComponent("manual_assignment_overrides.json")
        if !itemExists(overridesURL), isRegularFile(payloadOverrides) {
            let stagedOverrides = defaultsRoot.appendingPathComponent("manual_assignment_overrides.json")
            try fileManager.createDirectory(at: defaultsRoot, withIntermediateDirectories: true)
            try fileManager.copyItem(at: payloadOverrides, to: stagedOverrides)
            items.append(
                InstallItem(
                    relativePath: "manual_assignment_overrides.json",
                    sourceURL: stagedOverrides,
                    copiedPath: nil,
                    onlyIfMissing: true
                )
            )
        }
        return items
    }

    private func retiredInstallItems(destination: URL) -> [InstallItem] {
        let replacedRoots = Set(Self.installedCodeDirectories)
        return Self.retiredCodePaths.compactMap { relativePath in
            guard let first = relativePath.split(separator: "/").first,
                  !replacedRoots.contains(String(first)),
                  itemExists(destination.appendingPathComponent(relativePath)) else {
                return nil
            }
            return InstallItem(
                relativePath: relativePath,
                sourceURL: nil,
                copiedPath: nil,
                onlyIfMissing: false
            )
        }
    }

    private func installedPayloadMatches(
        _ validated: ValidatedEnginePayload,
        at destination: URL
    ) throws -> Bool {
        let installedManifestURL = destination.appendingPathComponent(Self.installedManifestRelativePath)
        guard isRegularFile(installedManifestURL), !isSymbolicLink(installedManifestURL),
              (try? Data(contentsOf: installedManifestURL)) == (try? Data(contentsOf: validated.manifestURL)) else {
            return false
        }

        var expectedManagedFiles: [String: EnginePayloadManifestFile] = [:]
        for file in validated.manifest.files {
            if let installedPath = installedRelativePath(for: file.path) {
                expectedManagedFiles[installedPath] = file
            }
        }
        for (relativePath, file) in expectedManagedFiles {
            let target = destination.appendingPathComponent(relativePath)
            guard isRegularFile(target), !isSymbolicLink(target),
                  try regularFileSize(target) == file.bytes,
                  try sha256Hex(target) == file.sha256 else {
                return false
            }
        }

        let managedRoots = Self.installedCodeDirectories + ["runtime/app-python-packages"]
        var actualManagedFiles = Set<String>()
        for rootPath in managedRoots {
            let root = destination.appendingPathComponent(rootPath, isDirectory: true)
            guard itemExists(root), !isSymbolicLink(root) else { return false }
            let files = try regularFiles(in: root, excluding: nil)
            for relativePath in files.keys {
                actualManagedFiles.insert("\(rootPath)/\(relativePath)")
            }
        }
        let expectedUnderManagedRoots = Set(expectedManagedFiles.keys.filter { relativePath in
            managedRoots.contains { relativePath == $0 || relativePath.hasPrefix("\($0)/") }
        })
        return actualManagedFiles == expectedUnderManagedRoots
    }

    private func installedRelativePath(for payloadPath: String) -> String? {
        if payloadPath.hasPrefix("python-packages/") {
            return "runtime/app-python-packages/\(payloadPath.dropFirst("python-packages/".count))"
        }
        if Self.installedCodeDirectories.contains(where: {
            payloadPath == $0 || payloadPath.hasPrefix("\($0)/")
        }) {
            return payloadPath
        }
        if Self.rootCodeFiles.contains(payloadPath) {
            return payloadPath
        }
        if payloadPath == "EnginePayloadVersion.txt" {
            return Self.installedVersionRelativePath
        }
        return nil
    }

    private func rollback(_ committed: ReversedCollection<[CommittedInstallItem]>) throws {
        for item in committed {
            if item.installedNewItem, itemExists(item.targetURL) {
                try fileManager.removeItem(at: item.targetURL)
            }
            if item.hadBackup {
                guard itemExists(item.backupURL), !itemExists(item.targetURL) else {
                    throw EngineInstallerError.rollbackFailed("rollback-path-conflict-\(item.relativePath)")
                }
                try fileManager.createDirectory(
                    at: item.targetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: item.backupURL, to: item.targetURL)
            }
        }
    }

    private func makeScriptsExecutable(in rootURL: URL) throws {
        let executableExtensions: Set<String> = ["sh", "js", "mjs", "py"]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw EngineInstallerError.invalidPayload("unable-to-enumerate-staged-payload")
        }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw EngineInstallerError.invalidPayload("symlink-in-staged-payload")
            }
            guard values.isRegularFile == true else { continue }
            guard executableExtensions.contains(fileURL.pathExtension)
                    || Self.rootCodeFiles.contains(fileURL.lastPathComponent) else {
                continue
            }
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        }
    }

    private func regularFiles(in rootURL: URL, excluding excludedURL: URL?) throws -> [String: URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw EngineInstallerError.invalidPayload("unable-to-enumerate-payload")
        }
        var files: [String: URL] = [:]
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                throw EngineInstallerError.invalidPayload("symlink-present")
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else {
                throw EngineInstallerError.invalidPayload("non-regular-file-present")
            }
            if let excludedURL, fileURL.standardizedFileURL == excludedURL.standardizedFileURL {
                continue
            }
            let relativePath = relativePath(of: fileURL, under: rootURL)
            guard isSafeRelativePath(relativePath), files[relativePath] == nil else {
                throw EngineInstallerError.invalidPayload("invalid-inventory-path")
            }
            files[relativePath] = fileURL
        }
        return files
    }

    private func validateDestination(_ destination: URL, payloadRoot: URL) throws {
        if itemExists(destination), isSymbolicLink(destination) {
            throw EngineInstallerError.unsafeDestination("destination-is-symlink")
        }
        let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let payloadPath = payloadRoot.resolvingSymlinksInPath().standardizedFileURL.path
        if destinationPath == payloadPath || destinationPath.hasPrefix("\(payloadPath)/") {
            throw EngineInstallerError.unsafeDestination("destination-overlaps-payload")
        }
    }

    private func validateManagedTarget(
        _ target: URL,
        relativePath: String,
        destination: URL
    ) throws {
        guard isSafeRelativePath(relativePath) else {
            throw EngineInstallerError.unsafeDestination("invalid-managed-path")
        }
        var current = destination
        for component in relativePath.split(separator: "/").dropLast() {
            current.appendPathComponent(String(component), isDirectory: true)
            if itemExists(current), isSymbolicLink(current) {
                throw EngineInstallerError.unsafeDestination("symlinked-managed-ancestor-\(component)")
            }
        }
        if itemExists(target), isSymbolicLink(target) {
            return
        }
    }

    private func relativePath(of fileURL: URL, under rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func itemExists(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let type = try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeRegular
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let type = try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSymbolicLink
    }

    private func regularFileSize(_ url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw EngineInstallerError.invalidPayload("non-regular-file")
        }
        return size.int64Value
    }

    private func sha256Hex(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func isLowerHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private struct InstallItem {
        var relativePath: String
        var sourceURL: URL?
        var copiedPath: String?
        var onlyIfMissing: Bool
    }

    private struct CommittedInstallItem {
        var relativePath: String
        var targetURL: URL
        var backupURL: URL
        var hadBackup: Bool
        var installedNewItem: Bool
        var copiedPath: String?
    }

    private static let installedManifestRelativePath = "runtime/automation/app_engine_payload_manifest.json"
    private static let installedVersionRelativePath = "runtime/automation/app_engine_payload_version"
    private static let installLockName = ".klms-engine-install.lock"
    private static let transactionPrefix = ".klms-engine-install-"
    private static let requiredPythonPayloadFiles = [
        "bs4/__init__.py",
        "soupsieve/__init__.py",
        "typing_extensions.py",
    ]

    public static let rootCodeFiles: [String] = [
        "klms_login_assist.sh",
        "sync_klms_core.sh",
        "sync_klms_notice.sh",
        "sync_klms_all.sh",
        "run_all.sh",
        "run_all_full.sh",
        "refresh_course_files.sh",
        "verify_sync_state.sh",
        "doctor.sh",
        "sync_report.sh",
        "process_klms_assignments.sh",
        "klms_v2_build_state.sh",
    ]

    public static let installedCodeDirectories: [String] = [
        "src",
        "bin",
        "examples",
        "tools",
    ]

    public static let retiredCodePaths: [String] = [
        "docs",
        "legacy",
        "launchd",
        "run_all_parallel.sh",
        "bin/run_all_parallel.sh",
        "src/js/download_klms_media_via_safari.js",
        "src/js/export_panopto_transcripts.js",
        "src/js/fetch_active_safari_page.js",
        "src/js/sync_klms_calendar_jxa.js",
        "src/swift/sync_klms_calendar.swift",
        "kaikey_auto_login.sh",
        "kaikey_approve_number.sh",
        "kaikey_setup.sh",
        "bin/kaikey_auto_login.sh",
        "bin/kaikey_approve_number.sh",
        "bin/kaikey_setup.sh",
        "src/js/kaikey_cli.mjs",
        "src/js/kaikey_safari_step.js",
        "kaikey_state.json",
    ]

    private static let recoverableManagedPaths: Set<String> = {
        let replacedRoots = Set(installedCodeDirectories)
        let retiredRoots = retiredCodePaths.filter { relativePath in
            guard let first = relativePath.split(separator: "/").first else { return false }
            return !replacedRoots.contains(String(first))
        }
        return Set(
            installedCodeDirectories
                + ["runtime/app-python-packages"]
                + rootCodeFiles
                + retiredRoots
                + [
                    installedManifestRelativePath,
                    installedVersionRelativePath,
                    "config.env",
                    "manual_assignment_overrides.json",
                ]
        )
    }()
}
