import Foundation

public struct AppDataBackupRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var url: URL
    public var createdAt: Date
    public var fileCount: Int

    public init(id: String, url: URL, createdAt: Date, fileCount: Int) {
        self.id = id
        self.url = url
        self.createdAt = createdAt
        self.fileCount = fileCount
    }
}

public struct AppDataBackupManager {
    public var paths: KLMSPaths
    public var fileManager: FileManager

    public init(paths: KLMSPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func createBackup(now: Date = Date()) throws -> AppDataBackupRecord {
        let id = Self.timestamp(for: now)
        let root = paths.backupsURL.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        var copied = 0
        for item in backupItems {
            let source = item.source
            guard fileManager.fileExists(atPath: source.path) else {
                continue
            }
            let destination = root.appendingPathComponent(item.relativePath)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
            copied += 1
        }

        try manifestText(id: id, createdAt: now, fileCount: copied)
            .write(to: root.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
        return AppDataBackupRecord(id: id, url: root, createdAt: now, fileCount: copied)
    }

    public func latestBackup() -> AppDataBackupRecord? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: paths.backupsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return entries
            .compactMap(record(for:))
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    public func restoreLatestBackup() throws -> AppDataBackupRecord? {
        guard let latest = latestBackup() else {
            return nil
        }
        try restore(latest)
        return latest
    }

    public func restore(_ record: AppDataBackupRecord) throws {
        for item in backupItems {
            let source = record.url.appendingPathComponent(item.relativePath)
            guard fileManager.fileExists(atPath: source.path) else {
                continue
            }
            try fileManager.createDirectory(at: item.source.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: item.source.path) {
                try fileManager.removeItem(at: item.source)
            }
            try fileManager.copyItem(at: source, to: item.source)
        }
    }

    private var backupItems: [(relativePath: String, source: URL)] {
        [
            ("config.env", paths.configURL),
            ("manual_assignment_overrides.json", paths.overridesURL),
            ("runtime/cache/notice_user_state.json", paths.noticeUserStateURL),
            ("runtime/cache/app_user_state.json", paths.appUserStateURL),
            ("runtime/state/state.json", paths.stateJSONURL),
            ("runtime/cache/sync_report.json", paths.syncReportURL),
            ("runtime/cache/course_file_manifest.json", paths.courseFileManifestURL),
        ]
    }

    private func record(for url: URL) -> AppDataBackupRecord? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey]),
              values.isDirectory == true else {
            return nil
        }
        let fileCount = backupItems.filter {
            fileManager.fileExists(atPath: url.appendingPathComponent($0.relativePath).path)
        }.count
        let createdAt = values.creationDate ?? Self.date(from: url.lastPathComponent) ?? .distantPast
        return AppDataBackupRecord(id: url.lastPathComponent, url: url, createdAt: createdAt, fileCount: fileCount)
    }

    private func manifestText(id: String, createdAt: Date, fileCount: Int) -> String {
        """
        id=\(id)
        created_at=\(ISO8601DateFormatter().string(from: createdAt))
        file_count=\(fileCount)
        engine_root=\(paths.engineRoot.path)
        """
    }

    private static func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "backup-\(formatter.string(from: date))"
    }

    private static func date(from id: String) -> Date? {
        guard id.hasPrefix("backup-") else {
            return nil
        }
        let text = String(id.dropFirst("backup-".count))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: text)
    }
}
