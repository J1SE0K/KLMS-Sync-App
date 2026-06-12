import Foundation

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
        environment: [String: String] = ProcessInfo.processInfo.environment,
        filePath: String = #filePath
    ) -> EnginePayload? {
        if let bundled = bundledResourceURL?.appendingPathComponent("EnginePayload", isDirectory: true) {
            let payload = EnginePayload(
                rootURL: bundled,
                version: explicitVersion(in: bundled) ?? "bundled"
            )
            if payload.hasEngineLayout {
                return payload
            }
        }

        if let override = environment["KLMS_SYNC_ENGINE_SOURCE"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            let payload = EnginePayload(rootURL: url, version: sourceVersion(in: url) ?? "override")
            if payload.hasEngineLayout {
                return payload
            }
        }

        if let sourceRoot = findRepositoryRoot(from: URL(fileURLWithPath: filePath)) {
            return EnginePayload(rootURL: sourceRoot, version: sourceVersion(in: sourceRoot) ?? "source")
        }

        return nil
    }

    private func findRepositoryRoot(from fileURL: URL) -> URL? {
        var current = fileURL.deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("sync_klms_core.sh").path),
               FileManager.default.fileExists(atPath: current.appendingPathComponent("src", isDirectory: true).path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
        return nil
    }

    private func sourceVersion(in rootURL: URL) -> String? {
        let base = gitVersion(in: rootURL) ?? explicitVersion(in: rootURL) ?? "source"
        guard let fingerprint = sourceFingerprint(in: rootURL) else {
            return base
        }
        return "\(base)-\(fingerprint)"
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

    private func gitVersion(in rootURL: URL) -> String? {
        let gitDirectory = rootURL.appendingPathComponent(".git", isDirectory: true)
        let headURL = gitDirectory.appendingPathComponent("HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !head.isEmpty else {
            return nil
        }
        if head.hasPrefix("ref: ") {
            let ref = String(head.dropFirst("ref: ".count))
            let refURL = gitDirectory.appendingPathComponent(ref)
            if let hash = try? String(contentsOf: refURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               hash.count >= 7 {
                return String(hash.prefix(7))
            }
        }
        return head.count >= 7 ? String(head.prefix(7)) : head
    }

    private func sourceFingerprint(in rootURL: URL) -> String? {
        var fileCount = 0
        var totalBytes = 0
        var latestModifiedMilliseconds = 0
        let roots = [
            rootURL.appendingPathComponent("src", isDirectory: true),
            rootURL.appendingPathComponent("bin", isDirectory: true),
            rootURL.appendingPathComponent("examples", isDirectory: true),
            rootURL.appendingPathComponent("tools", isDirectory: true),
            rootURL.appendingPathComponent("runtime/python-packages", isDirectory: true),
        ]

        for root in roots {
            accumulateFingerprint(
                rootURL: root,
                fileCount: &fileCount,
                totalBytes: &totalBytes,
                latestModifiedMilliseconds: &latestModifiedMilliseconds
            )
        }

        for file in EngineInstaller.rootCodeFiles {
            accumulateFingerprint(
                fileURL: rootURL.appendingPathComponent(file),
                fileCount: &fileCount,
                totalBytes: &totalBytes,
                latestModifiedMilliseconds: &latestModifiedMilliseconds
            )
        }

        guard fileCount > 0 else {
            return nil
        }
        return "files\(fileCount)-bytes\(totalBytes)-mtime\(latestModifiedMilliseconds)"
    }

    private func accumulateFingerprint(
        rootURL: URL,
        fileCount: inout Int,
        totalBytes: inout Int,
        latestModifiedMilliseconds: inout Int
    ) {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for case let fileURL as URL in enumerator {
            accumulateFingerprint(
                fileURL: fileURL,
                fileCount: &fileCount,
                totalBytes: &totalBytes,
                latestModifiedMilliseconds: &latestModifiedMilliseconds
            )
        }
    }

    private func accumulateFingerprint(
        fileURL: URL,
        fileCount: inout Int,
        totalBytes: inout Int,
        latestModifiedMilliseconds: inout Int
    ) {
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true else {
            return
        }
        fileCount += 1
        totalBytes += values.fileSize ?? 0
        if let modified = values.contentModificationDate {
            latestModifiedMilliseconds = max(
                latestModifiedMilliseconds,
                Int((modified.timeIntervalSince1970 * 1000).rounded())
            )
        }
    }
}

public struct EngineInstaller {
    public var fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func installIfNeeded(
        payload: EnginePayload,
        destination: URL,
        force: Bool = false
    ) throws -> EngineInstallResult {
        let versionURL = destination
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("app_engine_payload_version")
        let currentVersion = try? String(contentsOf: versionURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requiredScript = destination.appendingPathComponent("run_all_full.sh")
        let alreadyInstalled = fileManager.fileExists(atPath: requiredScript.path)

        if !force, alreadyInstalled, currentVersion == payload.version {
            return EngineInstallResult(
                installed: false,
                sourceURL: payload.rootURL,
                destinationURL: destination,
                version: payload.version,
                copiedPaths: [],
                createdConfig: false
            )
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: versionURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var copied: [String] = []
        for directory in ["src", "bin", "examples", "docs", "tools"] {
            let source = payload.rootURL.appendingPathComponent(directory, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let target = destination.appendingPathComponent(directory, isDirectory: true)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: source, to: target)
            copied.append(directory)
        }

        try installPythonPackagesIfPresent(from: payload.rootURL, to: destination, copiedPaths: &copied)

        for file in Self.rootCodeFiles {
            let source = payload.rootURL.appendingPathComponent(file)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let target = destination.appendingPathComponent(file)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: source, to: target)
            copied.append(file)
        }

        try removeRetiredCodePaths(in: destination)

        let configURL = destination.appendingPathComponent("config.env")
        var createdConfig = false
        if !fileManager.fileExists(atPath: configURL.path) {
            let example = destination
                .appendingPathComponent("examples", isDirectory: true)
                .appendingPathComponent("config.env.example")
            if fileManager.fileExists(atPath: example.path) {
                try fileManager.copyItem(at: example, to: configURL)
                createdConfig = true
            }
        }

        let overridesURL = destination.appendingPathComponent("manual_assignment_overrides.json")
        let sourceOverridesURL = payload.rootURL.appendingPathComponent("manual_assignment_overrides.json")
        if !fileManager.fileExists(atPath: overridesURL.path),
           fileManager.fileExists(atPath: sourceOverridesURL.path) {
            try fileManager.copyItem(at: sourceOverridesURL, to: overridesURL)
        }

        try makeScriptsExecutable(in: destination)
        try payload.version.write(to: versionURL, atomically: true, encoding: .utf8)

        return EngineInstallResult(
            installed: true,
            sourceURL: payload.rootURL,
            destinationURL: destination,
            version: payload.version,
            copiedPaths: copied,
            createdConfig: createdConfig
        )
    }

    private func makeScriptsExecutable(in rootURL: URL) throws {
        let executableExtensions: Set<String> = ["sh", "js", "mjs", "py"]
        let roots = [
            rootURL,
            rootURL.appendingPathComponent("bin", isDirectory: true),
            rootURL.appendingPathComponent("src", isDirectory: true),
        ]

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                guard executableExtensions.contains(fileURL.pathExtension) || Self.rootCodeFiles.contains(fileURL.lastPathComponent) else {
                    continue
                }
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
            }
        }
    }

    private func removeRetiredCodePaths(in rootURL: URL) throws {
        for relativePath in Self.retiredCodePaths {
            let url = rootURL.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func installPythonPackagesIfPresent(
        from payloadRoot: URL,
        to destination: URL,
        copiedPaths: inout [String]
    ) throws {
        let candidates = [
            payloadRoot.appendingPathComponent("python-packages", isDirectory: true),
            payloadRoot.appendingPathComponent("runtime/python-packages", isDirectory: true),
        ]
        guard let source = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return
        }

        let target = destination
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("app-python-packages", isDirectory: true)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.copyItem(at: source, to: target)
        copiedPaths.append("runtime/app-python-packages")
    }

    public static let rootCodeFiles: [String] = [
        "kaikey_auto_login.sh",
        "kaikey_approve_number.sh",
        "kaikey_setup.sh",
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

    public static let retiredCodePaths: [String] = [
        "legacy",
        "launchd",
        "run_all_parallel.sh",
        "bin/run_all_parallel.sh",
        "src/js/download_klms_media_via_safari.js",
        "src/js/export_panopto_transcripts.js",
        "src/js/fetch_active_safari_page.js",
        "src/js/sync_klms_calendar_jxa.js",
        "src/swift/sync_klms_calendar.swift",
    ]
}
