import Foundation

#if canImport(Network)
import Network
#endif

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

    public var displayName: String {
        engineCommand.displayName
    }
}

public enum RemoteCommandStatus: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case macUnavailable

    public var displayName: String {
        switch self {
        case .pending:
            "대기 중"
        case .running:
            "실행 중"
        case .completed:
            "완료"
        case .failed:
            "실패"
        case .macUnavailable:
            "Mac 응답 없음"
        }
    }

    public var isInFlight: Bool {
        switch self {
        case .pending, .running:
            true
        case .completed, .failed, .macUnavailable:
            false
        }
    }

    public var isTerminal: Bool {
        !isInFlight
    }
}

public struct RemoteRunCommand: Identifiable, Codable, Sendable, Equatable {
    public static let macUnavailableInterval: TimeInterval = 5 * 60
    public static let staleExecutionInterval: TimeInterval = 60 * 60

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

    public func displayStatus(
        now: Date = Date(),
        unavailableInterval: TimeInterval = Self.macUnavailableInterval
    ) -> RemoteCommandStatus {
        guard status == .pending, now.timeIntervalSince(createdAt) > unavailableInterval else {
            return status
        }
        return .macUnavailable
    }

    public func isStaleForExecution(
        now: Date = Date(),
        staleInterval: TimeInterval = Self.staleExecutionInterval
    ) -> Bool {
        status == .pending && now.timeIntervalSince(createdAt) > staleInterval
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

public enum LocalRemoteAction: String, Codable, Sendable {
    case status
    case run
}

public struct LocalRemoteRequest: Codable, Sendable, Equatable {
    public var token: String
    public var action: LocalRemoteAction
    public var kind: RemoteCommandKind?

    public init(token: String, action: LocalRemoteAction, kind: RemoteCommandKind? = nil) {
        self.token = token
        self.action = action
        self.kind = kind
    }
}

public struct LocalRemoteResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var message: String
    public var status: SanitizedRemoteStatus
    public var latestCommand: RemoteRunCommand?
    public var running: Bool

    public init(
        ok: Bool = true,
        message: String = "",
        status: SanitizedRemoteStatus = SanitizedRemoteStatus(),
        latestCommand: RemoteRunCommand? = nil,
        running: Bool = false
    ) {
        self.ok = ok
        self.message = message
        self.status = status
        self.latestCommand = latestCommand
        self.running = running
    }
}

public enum LocalRemoteClientError: LocalizedError, Sendable {
    case networkUnavailable
    case invalidPort
    case emptyHost
    case emptyToken
    case connectionFailed(String)
    case invalidResponse
    case serverRejected(String)

    public var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            "이 빌드는 로컬 네트워크 연결을 사용할 수 없습니다."
        case .invalidPort:
            "포트 번호가 올바르지 않습니다."
        case .emptyHost:
            "Mac 주소를 입력해 주세요."
        case .emptyToken:
            "Mac 앱에 표시된 토큰을 입력해 주세요."
        case let .connectionFailed(message):
            message.isEmpty ? "Mac 앱에 연결하지 못했습니다." : message
        case .invalidResponse:
            "Mac 앱 응답을 해석하지 못했습니다."
        case let .serverRejected(message):
            message
        }
    }
}

#if canImport(Network)
public struct LocalRemoteClient: Sendable {
    public var host: String
    public var port: UInt16
    public var token: String
    private static let connectionTimeoutSeconds: TimeInterval = 8

    public init(host: String, port: UInt16, token: String) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func fetchStatus() async throws -> LocalRemoteResponse {
        try await send(LocalRemoteRequest(token: token, action: .status))
    }

    public func run(_ kind: RemoteCommandKind) async throws -> LocalRemoteResponse {
        try await send(LocalRemoteRequest(token: token, action: .run, kind: kind))
    }

    private func send(_ request: LocalRemoteRequest) async throws -> LocalRemoteResponse {
        guard !host.isEmpty else { throw LocalRemoteClientError.emptyHost }
        guard port > 0 else { throw LocalRemoteClientError.invalidPort }
        guard !token.isEmpty else { throw LocalRemoteClientError.emptyToken }

        let endpointHost = NWEndpoint.Host(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw LocalRemoteClientError.invalidPort
        }
        let connection = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)
        let requestData = try JSONEncoder.klmsLocalRemote.encode(request) + Data([0x0A])
        let responseData: Data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            LocalRemoteClientSession(
                connection: connection,
                requestData: requestData,
                timeoutSeconds: Self.connectionTimeoutSeconds,
                continuation: continuation
            ).start()
        }

        let response = try JSONDecoder.klmsLocalRemote.decode(LocalRemoteResponse.self, from: responseData)
        if !response.ok {
            throw LocalRemoteClientError.serverRejected(response.message)
        }
        return response
    }
}

private final class LocalRemoteClientSession: @unchecked Sendable {
    private let connection: NWConnection
    private let requestData: Data
    private let timeoutSeconds: TimeInterval
    private let continuation: CheckedContinuation<Data, Error>
    private let queue = DispatchQueue(label: "KLMSLocalRemoteClient")
    private let lock = NSLock()
    private var didResume = false
    private var buffer = Data()

    init(
        connection: NWConnection,
        requestData: Data,
        timeoutSeconds: TimeInterval,
        continuation: CheckedContinuation<Data, Error>
    ) {
        self.connection = connection
        self.requestData = requestData
        self.timeoutSeconds = timeoutSeconds
        self.continuation = continuation
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                self.send()
            case let .failed(error):
                self.resume(.failure(LocalRemoteClientError.connectionFailed(error.localizedDescription)))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeoutSeconds) { [self] in
            self.resume(.failure(LocalRemoteClientError.connectionFailed("Mac 앱 연결 시간이 초과되었습니다.")))
        }
    }

    private func send() {
        connection.send(content: requestData, completion: .contentProcessed { [self] error in
            if let error {
                self.resume(.failure(LocalRemoteClientError.connectionFailed(error.localizedDescription)))
            } else {
                self.receive()
            }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let error {
                self.resume(.failure(LocalRemoteClientError.connectionFailed(error.localizedDescription)))
                return
            }
            if let data {
                self.buffer.append(data)
                if let newlineIndex = self.buffer.firstIndex(of: 0x0A) {
                    self.resume(.success(Data(self.buffer[..<newlineIndex])))
                    return
                }
            }
            if isComplete {
                guard !self.buffer.isEmpty else {
                    self.resume(.failure(LocalRemoteClientError.invalidResponse))
                    return
                }
                self.resume(.success(self.buffer))
            } else {
                self.receive()
            }
        }
    }

    private func resume(_ result: Result<Data, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        connection.cancel()
        continuation.resume(with: result)
    }
}
#endif

public extension JSONEncoder {
    static var klmsLocalRemote: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    static var klmsLocalRemote: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
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
        } else {
            record["lastExitCode"] = nil
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
            createdAt: Self.dateValue(record["createdAt"]) ?? Date(),
            updatedAt: Self.dateValue(record["updatedAt"]) ?? Date(),
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

    private static func dateValue(_ value: Any?) -> Date? {
        if let date = value as? Date {
            return date
        }
        if let date = value as? NSDate {
            return date as Date
        }
        return nil
    }
}
#endif
