import Foundation

public enum RemoteCommandKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case fullSync
    case coreSync
    case noticeSync
    case filesSync
    case report

    public var id: String { rawValue }

    public var engineCommand: KLMSEngineCommand {
        switch self {
        case .fullSync:
            .fullSync
        case .coreSync:
            .coreSync
        case .noticeSync:
            .noticeSync
        case .filesSync:
            .filesSync
        case .report:
            .report
        }
    }
}

public enum RemoteCommandStatus: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case macUnavailable
}

public struct RemoteRunCommand: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: RemoteCommandKind
    public var status: RemoteCommandStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var lastExitCode: Int?
    public var loginRequired: Bool
    public var summary: SanitizedRemoteStatus

    public init(
        id: UUID = UUID(),
        kind: RemoteCommandKind,
        status: RemoteCommandStatus = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastExitCode: Int? = nil,
        loginRequired: Bool = false,
        summary: SanitizedRemoteStatus = SanitizedRemoteStatus()
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastExitCode = lastExitCode
        self.loginRequired = loginRequired
        self.summary = summary
    }
}

public struct SanitizedRemoteStatus: Codable, Sendable, Equatable {
    public var assignments: Int
    public var exams: Int
    public var helpDesk: Int
    public var notices: Int
    public var newFiles: Int
    public var quarantine: Int
    public var phase: String

    public init(
        assignments: Int = 0,
        exams: Int = 0,
        helpDesk: Int = 0,
        notices: Int = 0,
        newFiles: Int = 0,
        quarantine: Int = 0,
        phase: String = ""
    ) {
        self.assignments = assignments
        self.exams = exams
        self.helpDesk = helpDesk
        self.notices = notices
        self.newFiles = newFiles
        self.quarantine = quarantine
        self.phase = phase
    }

    public init(snapshot: EngineSnapshot, phase: String = "") {
        assignments = snapshot.syncReport?.state.assignments ?? snapshot.legacyState?.content.assignments.count ?? 0
        exams = snapshot.syncReport?.state.exams ?? snapshot.legacyState?.content.examItems.count ?? 0
        helpDesk = snapshot.syncReport?.state.helpdesk ?? snapshot.legacyState?.content.helpDeskItems.count ?? 0
        notices = snapshot.syncReport?.notices.total ?? 0
        newFiles = snapshot.syncReport?.files.newFiles ?? snapshot.downloadResult?.newFilesCopiedCount ?? 0
        quarantine = snapshot.syncReport?.files.quarantine ?? snapshot.quarantineReport?.quarantineCount ?? 0
        self.phase = phase
    }
}

public protocol RemoteCommandStore: Sendable {
    func create(_ command: RemoteRunCommand) async throws
    func fetchPending() async throws -> [RemoteRunCommand]
    func fetchRecent(limit: Int) async throws -> [RemoteRunCommand]
    func update(_ command: RemoteRunCommand) async throws
}

#if canImport(CloudKit)
import CloudKit

public final class CloudKitCommandStore: RemoteCommandStore, @unchecked Sendable {
    private let database: CKDatabase
    private let recordType = "RunCommand"

    public init(containerIdentifier: String? = nil) {
        if let containerIdentifier {
            database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        } else {
            database = CKContainer.default().privateCloudDatabase
        }
    }

    public func create(_ command: RemoteRunCommand) async throws {
        let record = try record(from: command)
        _ = try await database.save(record)
    }

    public func fetchPending() async throws -> [RemoteRunCommand] {
        let predicate = NSPredicate(format: "status == %@", RemoteCommandStatus.pending.rawValue)
        let query = CKQuery(recordType: recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let result = try await database.records(matching: query, resultsLimit: 20)
        return result.matchResults.compactMap { _, matchResult in
            guard case let .success(record) = matchResult else { return nil }
            return command(from: record)
        }
    }

    public func fetchRecent(limit: Int = 10) async throws -> [RemoteRunCommand] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        let result = try await database.records(matching: query, resultsLimit: limit)
        return result.matchResults.compactMap { _, matchResult in
            guard case let .success(record) = matchResult else { return nil }
            return command(from: record)
        }
    }

    public func update(_ command: RemoteRunCommand) async throws {
        let recordID = CKRecord.ID(recordName: command.id.uuidString)
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch {
            record = CKRecord(recordType: recordType, recordID: recordID)
        }
        apply(command, to: record)
        _ = try await database.save(record)
    }

    private func record(from command: RemoteRunCommand) throws -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: command.id.uuidString))
        apply(command, to: record)
        return record
    }

    private func apply(_ command: RemoteRunCommand, to record: CKRecord) {
        record["kind"] = command.kind.rawValue as NSString
        record["status"] = command.status.rawValue as NSString
        record["createdAt"] = command.createdAt as NSDate
        record["updatedAt"] = command.updatedAt as NSDate
        if let lastExitCode = command.lastExitCode {
            record["lastExitCode"] = NSNumber(value: lastExitCode)
        }
        record["loginRequired"] = NSNumber(value: command.loginRequired)
        record["assignments"] = NSNumber(value: command.summary.assignments)
        record["exams"] = NSNumber(value: command.summary.exams)
        record["helpDesk"] = NSNumber(value: command.summary.helpDesk)
        record["notices"] = NSNumber(value: command.summary.notices)
        record["newFiles"] = NSNumber(value: command.summary.newFiles)
        record["quarantine"] = NSNumber(value: command.summary.quarantine)
        record["phase"] = command.summary.phase as NSString
    }

    private func command(from record: CKRecord) -> RemoteRunCommand? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let kindRaw = record["kind"] as? String,
              let kind = RemoteCommandKind(rawValue: kindRaw) else {
            return nil
        }
        let status = (record["status"] as? String).flatMap(RemoteCommandStatus.init(rawValue:)) ?? .pending
        return RemoteRunCommand(
            id: id,
            kind: kind,
            status: status,
            createdAt: (record["createdAt"] as? Date) ?? Date(),
            updatedAt: (record["updatedAt"] as? Date) ?? Date(),
            lastExitCode: (record["lastExitCode"] as? NSNumber)?.intValue,
            loginRequired: (record["loginRequired"] as? NSNumber)?.boolValue ?? false,
            summary: SanitizedRemoteStatus(
                assignments: (record["assignments"] as? NSNumber)?.intValue ?? 0,
                exams: (record["exams"] as? NSNumber)?.intValue ?? 0,
                helpDesk: (record["helpDesk"] as? NSNumber)?.intValue ?? 0,
                notices: (record["notices"] as? NSNumber)?.intValue ?? 0,
                newFiles: (record["newFiles"] as? NSNumber)?.intValue ?? 0,
                quarantine: (record["quarantine"] as? NSNumber)?.intValue ?? 0,
                phase: (record["phase"] as? String) ?? ""
            )
        )
    }
}
#endif
