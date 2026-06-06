import Foundation

public struct FileSyncPreview: Decodable, Sendable, Equatable {
    public var manifestCount: Int
    public var actualFileCount: Int
    public var newURLCount: Int
    public var movedCount: Int
    public var localMissingCount: Int
    public var recoverableMissingCount: Int
    public var freshDownloadCandidateCount: Int
    public var pruneCandidateCount: Int
    public var typeMismatchCandidateCount: Int
    public var newURLEntries: [FilePreviewEntry]
    public var movedEntries: [FilePreviewEntry]
    public var localMissingEntries: [FilePreviewEntry]
    public var recoverableMissingEntries: [FilePreviewEntry]
    public var freshDownloadCandidates: [FilePreviewEntry]
    public var pruneCandidates: [String]
    public var typeMismatchCandidates: [FilePreviewEntry]

    enum CodingKeys: String, CodingKey {
        case manifestCount = "manifest_count"
        case actualFileCount = "actual_file_count"
        case newURLCount = "new_url_count"
        case movedCount = "moved_count"
        case localMissingCount = "local_missing_count"
        case recoverableMissingCount = "recoverable_missing_count"
        case freshDownloadCandidateCount = "fresh_download_candidate_count"
        case pruneCandidateCount = "prune_candidate_count"
        case typeMismatchCandidateCount = "type_mismatch_candidate_count"
        case newURLEntries = "new_url_entries"
        case movedEntries = "moved_entries"
        case localMissingEntries = "local_missing_entries"
        case recoverableMissingEntries = "recoverable_missing_entries"
        case freshDownloadCandidates = "fresh_download_candidates"
        case pruneCandidates = "prune_candidates"
        case typeMismatchCandidates = "type_mismatch_candidates"
    }

    public init(
        manifestCount: Int = 0,
        actualFileCount: Int = 0,
        newURLCount: Int = 0,
        movedCount: Int = 0,
        localMissingCount: Int = 0,
        recoverableMissingCount: Int = 0,
        freshDownloadCandidateCount: Int = 0,
        pruneCandidateCount: Int = 0,
        typeMismatchCandidateCount: Int = 0,
        newURLEntries: [FilePreviewEntry] = [],
        movedEntries: [FilePreviewEntry] = [],
        localMissingEntries: [FilePreviewEntry] = [],
        recoverableMissingEntries: [FilePreviewEntry] = [],
        freshDownloadCandidates: [FilePreviewEntry] = [],
        pruneCandidates: [String] = [],
        typeMismatchCandidates: [FilePreviewEntry] = []
    ) {
        self.manifestCount = manifestCount
        self.actualFileCount = actualFileCount
        self.newURLCount = newURLCount
        self.movedCount = movedCount
        self.localMissingCount = localMissingCount
        self.recoverableMissingCount = recoverableMissingCount
        self.freshDownloadCandidateCount = freshDownloadCandidateCount
        self.pruneCandidateCount = pruneCandidateCount
        self.typeMismatchCandidateCount = typeMismatchCandidateCount
        self.newURLEntries = newURLEntries
        self.movedEntries = movedEntries
        self.localMissingEntries = localMissingEntries
        self.recoverableMissingEntries = recoverableMissingEntries
        self.freshDownloadCandidates = freshDownloadCandidates
        self.pruneCandidates = pruneCandidates
        self.typeMismatchCandidates = typeMismatchCandidates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifestCount = container.decodeIfPresentDefault(Int.self, forKey: .manifestCount, default: 0)
        actualFileCount = container.decodeIfPresentDefault(Int.self, forKey: .actualFileCount, default: 0)
        newURLCount = container.decodeIfPresentDefault(Int.self, forKey: .newURLCount, default: 0)
        movedCount = container.decodeIfPresentDefault(Int.self, forKey: .movedCount, default: 0)
        localMissingCount = container.decodeIfPresentDefault(Int.self, forKey: .localMissingCount, default: 0)
        recoverableMissingCount = container.decodeIfPresentDefault(Int.self, forKey: .recoverableMissingCount, default: 0)
        freshDownloadCandidateCount = container.decodeIfPresentDefault(Int.self, forKey: .freshDownloadCandidateCount, default: 0)
        pruneCandidateCount = container.decodeIfPresentDefault(Int.self, forKey: .pruneCandidateCount, default: 0)
        typeMismatchCandidateCount = container.decodeIfPresentDefault(Int.self, forKey: .typeMismatchCandidateCount, default: 0)
        newURLEntries = container.decodeIfPresentDefault([FilePreviewEntry].self, forKey: .newURLEntries, default: [])
        movedEntries = container.decodeIfPresentDefault([FilePreviewEntry].self, forKey: .movedEntries, default: [])
        localMissingEntries = container.decodeIfPresentDefault([FilePreviewEntry].self, forKey: .localMissingEntries, default: [])
        recoverableMissingEntries = container.decodeIfPresentDefault([FilePreviewEntry].self, forKey: .recoverableMissingEntries, default: [])
        freshDownloadCandidates = container.decodeIfPresentDefault([FilePreviewEntry].self, forKey: .freshDownloadCandidates, default: [])
        pruneCandidates = container.decodeIfPresentDefault([String].self, forKey: .pruneCandidates, default: [])
        typeMismatchCandidates = container.decodeIfPresentDefault([FilePreviewEntry].self, forKey: .typeMismatchCandidates, default: [])
    }
}

public struct FilePreviewEntry: Decodable, Sendable, Equatable, Identifiable {
    public var course: String
    public var filename: String
    public var relativePath: String
    public var effectiveRelativePath: String
    public var url: String
    public var sourceURL: String
    public var previousRelativePath: String?
    public var previousFilename: String?
    public var expectedPath: String?
    public var recoverySourcePath: String?

    public var id: String { url.isEmpty ? effectiveRelativePath : url }

    enum CodingKeys: String, CodingKey {
        case course
        case filename
        case relativePath = "relative_path"
        case effectiveRelativePath = "effective_relative_path"
        case url
        case sourceURL = "source_url"
        case previousRelativePath = "previous_relative_path"
        case previousFilename = "previous_filename"
        case expectedPath = "expected_path"
        case recoverySourcePath = "recovery_source_path"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        course = container.decodeIfPresentDefault(String.self, forKey: .course, default: "")
        filename = container.decodeIfPresentDefault(String.self, forKey: .filename, default: "")
        relativePath = container.decodeIfPresentDefault(String.self, forKey: .relativePath, default: "")
        effectiveRelativePath = container.decodeIfPresentDefault(String.self, forKey: .effectiveRelativePath, default: "")
        url = container.decodeIfPresentDefault(String.self, forKey: .url, default: "")
        sourceURL = container.decodeIfPresentDefault(String.self, forKey: .sourceURL, default: "")
        previousRelativePath = try? container.decodeIfPresent(String.self, forKey: .previousRelativePath)
        previousFilename = try? container.decodeIfPresent(String.self, forKey: .previousFilename)
        expectedPath = try? container.decodeIfPresent(String.self, forKey: .expectedPath)
        recoverySourcePath = try? container.decodeIfPresent(String.self, forKey: .recoverySourcePath)
    }
}

public struct CourseFileDownloadResult: Decodable, Sendable, Equatable {
    public var fileCount: Int
    public var newFilesCopiedCount: Int
    public var quarantineCount: Int
    public var results: [DownloadItem]
    public var dryRun: Bool

    enum CodingKeys: String, CodingKey {
        case fileCount
        case newFilesCopiedCount
        case quarantineCount
        case results
        case dryRun = "dry_run"
    }

    public init(fileCount: Int = 0, newFilesCopiedCount: Int = 0, quarantineCount: Int = 0, results: [DownloadItem] = [], dryRun: Bool = false) {
        self.fileCount = fileCount
        self.newFilesCopiedCount = newFilesCopiedCount
        self.quarantineCount = quarantineCount
        self.results = results
        self.dryRun = dryRun
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileCount = container.decodeIfPresentDefault(Int.self, forKey: .fileCount, default: 0)
        newFilesCopiedCount = container.decodeIfPresentDefault(Int.self, forKey: .newFilesCopiedCount, default: 0)
        quarantineCount = container.decodeIfPresentDefault(Int.self, forKey: .quarantineCount, default: 0)
        results = container.decodeIfPresentDefault([DownloadItem].self, forKey: .results, default: [])
        dryRun = container.decodeIfPresentDefault(Bool.self, forKey: .dryRun, default: false)
    }

    public var skippedExistingCount: Int {
        results.filter(\.skippedExisting).count
    }

    public var restoredFromArchiveCount: Int {
        results.filter(\.restoredFromArchive).count
    }

    public var reusedLoggedFileCount: Int {
        results.filter(\.reusedLoggedFile).count
    }

    public var failedCount: Int {
        results.filter { $0.failed || $0.quarantined }.count
    }

    public var freshDownloadCount: Int {
        max(
            0,
            results.count - skippedExistingCount - restoredFromArchiveCount - reusedLoggedFileCount - failedCount
        )
    }
}

public struct DownloadItem: Decodable, Sendable, Equatable, Identifiable {
    public var url: String
    public var relativePath: String
    public var skippedExisting: Bool
    public var restoredFromArchive: Bool
    public var reusedLoggedFile: Bool
    public var copiedToNewFilesInbox: Bool
    public var failed: Bool
    public var quarantined: Bool
    public var error: String
    public var quarantinePath: String

    public var id: String { url.isEmpty ? relativePath : url }

    enum CodingKeys: String, CodingKey {
        case url
        case relativePath = "relative_path"
        case skippedExisting = "skipped_existing"
        case restoredFromArchive = "restored_from_archive"
        case reusedLoggedFile = "reused_logged_file"
        case copiedToNewFilesInbox = "copied_to_new_files_inbox"
        case failed
        case quarantined
        case error
        case quarantinePath = "quarantine_path"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = container.decodeIfPresentDefault(String.self, forKey: .url, default: "")
        relativePath = container.decodeIfPresentDefault(String.self, forKey: .relativePath, default: "")
        skippedExisting = container.decodeIfPresentDefault(Bool.self, forKey: .skippedExisting, default: false)
        restoredFromArchive = container.decodeIfPresentDefault(Bool.self, forKey: .restoredFromArchive, default: false)
        reusedLoggedFile = container.decodeIfPresentDefault(Bool.self, forKey: .reusedLoggedFile, default: false)
        copiedToNewFilesInbox = container.decodeIfPresentDefault(Bool.self, forKey: .copiedToNewFilesInbox, default: false)
        failed = container.decodeIfPresentDefault(Bool.self, forKey: .failed, default: false)
        quarantined = container.decodeIfPresentDefault(Bool.self, forKey: .quarantined, default: false)
        error = container.decodeIfPresentDefault(String.self, forKey: .error, default: "")
        quarantinePath = container.decodeIfPresentDefault(String.self, forKey: .quarantinePath, default: "")
    }
}

public struct QuarantineReport: Decodable, Sendable, Equatable {
    public var quarantineRoot: String
    public var quarantineCount: Int
    public var records: [QuarantineRecord]

    enum CodingKeys: String, CodingKey {
        case quarantineRoot
        case quarantineCount
        case records
    }

    public init(quarantineRoot: String = "", quarantineCount: Int = 0, records: [QuarantineRecord] = []) {
        self.quarantineRoot = quarantineRoot
        self.quarantineCount = quarantineCount
        self.records = records
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quarantineRoot = container.decodeIfPresentDefault(String.self, forKey: .quarantineRoot, default: "")
        quarantineCount = container.decodeIfPresentDefault(Int.self, forKey: .quarantineCount, default: 0)
        records = container.decodeIfPresentDefault([QuarantineRecord].self, forKey: .records, default: [])
    }
}

public struct QuarantineRecord: Decodable, Sendable, Equatable, Identifiable {
    public var url: String
    public var quarantinePath: String
    public var quarantineRelativePath: String
    public var bytes: Int

    public var id: String { quarantinePath }

    enum CodingKeys: String, CodingKey {
        case url
        case quarantinePath = "quarantine_path"
        case quarantineRelativePath = "quarantine_relative_path"
        case bytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = container.decodeIfPresentDefault(String.self, forKey: .url, default: "")
        quarantinePath = container.decodeIfPresentDefault(String.self, forKey: .quarantinePath, default: "")
        quarantineRelativePath = container.decodeIfPresentDefault(String.self, forKey: .quarantineRelativePath, default: "")
        bytes = container.decodeIfPresentDefault(Int.self, forKey: .bytes, default: 0)
    }
}

public struct CleanupResult: Decodable, Sendable, Equatable {
    public var fileCount: Int
    public var actions: [CleanupAction]
    public var dryRun: Bool

    enum CodingKeys: String, CodingKey {
        case fileCount
        case actions
        case dryRun = "dry_run"
    }

    public init(fileCount: Int = 0, actions: [CleanupAction] = [], dryRun: Bool = false) {
        self.fileCount = fileCount
        self.actions = actions
        self.dryRun = dryRun
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileCount = container.decodeIfPresentDefault(Int.self, forKey: .fileCount, default: 0)
        actions = container.decodeIfPresentDefault([CleanupAction].self, forKey: .actions, default: [])
        dryRun = container.decodeIfPresentDefault(Bool.self, forKey: .dryRun, default: false)
    }

    public func actionCount(_ actionName: String) -> Int {
        actions.filter { $0.action == actionName }.count
    }
}

public struct CleanupAction: Decodable, Sendable, Equatable, Identifiable {
    public var action: String
    public var path: String

    public var id: String { "\(action)-\(path)" }

    enum CodingKeys: String, CodingKey {
        case action
        case path
    }

    public init(action: String = "", path: String = "") {
        self.action = action
        self.path = path
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = container.decodeIfPresentDefault(String.self, forKey: .action, default: "")
        path = container.decodeIfPresentDefault(String.self, forKey: .path, default: "")
    }
}
