import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(Security)
import Security
#endif

#if canImport(Network)
import Network
#endif

public enum RemoteCommandKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case fullSync
    case coreSync
    case noticeSync
    case filesSync
    case doctor
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
        case .doctor:
            .doctor
        case .report:
            .report
        }
    }

    public var displayName: String {
        engineCommand.displayName
    }

    public init?(engineCommand: KLMSEngineCommand?) {
        guard let engineCommand else { return nil }
        switch engineCommand {
        case .fullSync:
            self = .fullSync
        case .coreSync:
            self = .coreSync
        case .noticeSync:
            self = .noticeSync
        case .filesSync:
            self = .filesSync
        case .doctor:
            self = .doctor
        case .report:
            self = .report
        case .verify, .v2BuildState:
            return nil
        }
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
    public var loginRequired: Bool
    public var authDigits: String?
    public var authStatusMessage: String?

    enum CodingKeys: String, CodingKey {
        case assignments
        case exams
        case helpDesk
        case notices
        case newFiles
        case quarantine
        case phase
        case loginRequired
        case authDigits
        case authStatusMessage
    }

    public init(
        assignments: Int = 0,
        exams: Int = 0,
        helpDesk: Int = 0,
        notices: Int = 0,
        newFiles: Int = 0,
        quarantine: Int = 0,
        phase: String = "",
        loginRequired: Bool = false,
        authDigits: String? = nil,
        authStatusMessage: String? = nil
    ) {
        self.assignments = assignments
        self.exams = exams
        self.helpDesk = helpDesk
        self.notices = notices
        self.newFiles = newFiles
        self.quarantine = quarantine
        self.phase = phase
        self.loginRequired = loginRequired
        self.authDigits = authDigits
        self.authStatusMessage = authStatusMessage
    }

    public init(snapshot: EngineSnapshot, phase: String = "") {
        let counts = snapshot.visibleCounts
        assignments = counts.assignments
        exams = counts.exams
        helpDesk = counts.helpDesk
        notices = counts.notices
        newFiles = counts.newFiles
        quarantine = counts.quarantine
        self.phase = phase
        authDigits = nil
        authStatusMessage = nil
        loginRequired = snapshot.loginPromptDetected
            || snapshot.issues.contains { issue in
                issue.sourceName == "auth-digits"
                    || issue.sourceName == "login-required"
                    || issue.sourceName == "klms-login-cache"
            }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assignments = container.decodeIfPresentDefault(Int.self, forKey: .assignments, default: 0)
        exams = container.decodeIfPresentDefault(Int.self, forKey: .exams, default: 0)
        helpDesk = container.decodeIfPresentDefault(Int.self, forKey: .helpDesk, default: 0)
        notices = container.decodeIfPresentDefault(Int.self, forKey: .notices, default: 0)
        newFiles = container.decodeIfPresentDefault(Int.self, forKey: .newFiles, default: 0)
        quarantine = container.decodeIfPresentDefault(Int.self, forKey: .quarantine, default: 0)
        phase = container.decodeIfPresentDefault(String.self, forKey: .phase, default: "")
        loginRequired = container.decodeIfPresentDefault(Bool.self, forKey: .loginRequired, default: false)
        authDigits = try container.decodeIfPresent(String.self, forKey: .authDigits)
        authStatusMessage = try container.decodeIfPresent(String.self, forKey: .authStatusMessage)
    }
}

public protocol RemoteCommandStore: Sendable {
    func create(_ command: RemoteRunCommand) async throws
    func fetchPending() async throws -> [RemoteRunCommand]
    func fetchRecent(limit: Int) async throws -> [RemoteRunCommand]
    func update(_ command: RemoteRunCommand) async throws
}

public struct LocalRemoteConnectionInfo: Sendable, Equatable {
    public static let defaultPort: UInt16 = 18483

    public var host: String
    public var port: UInt16
    public var token: String?

    public init(host: String, port: UInt16 = Self.defaultPort, token: String? = nil) {
        self.host = host
        self.port = port
        self.token = token
    }

    public static func parse(
        hostText: String,
        portText: String = "\(Self.defaultPort)",
        tokenText: String = ""
    ) -> LocalRemoteConnectionInfo? {
        let rawHostText = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPortText = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTokenText = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        let combinedText = [rawHostText, rawPortText, rawTokenText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let extractedHost = labeledValue(in: combinedText, labels: ["Mac 주소", "주소", "Host", "Address"])
            ?? firstIPv4Endpoint(in: rawHostText)?.host
            ?? firstIPv4Endpoint(in: combinedText)?.host
            ?? rawHostText
        let extractedPort = firstIPv4Endpoint(in: rawHostText)?.port
            ?? firstIPv4Endpoint(in: combinedText)?.port
            ?? UInt16(rawPortText)
            ?? Self.defaultPort
        let extractedToken = rawTokenText.isEmpty
            ? labeledValue(in: combinedText, labels: ["토큰", "Token"])
            : rawTokenText

        let normalizedHost = normalizeHost(extractedHost)
        guard !normalizedHost.isEmpty, extractedPort > 0 else {
            return nil
        }
        return LocalRemoteConnectionInfo(
            host: normalizedHost,
            port: extractedPort,
            token: extractedToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private static func labeledValue(in text: String, labels: [String]) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            for label in labels {
                guard let range = line.range(of: "\(label):", options: [.caseInsensitive]) else {
                    continue
                }
                let value = line[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static func firstIPv4Endpoint(in text: String) -> (host: String, port: UInt16?)? {
        let pattern = #"(?<![0-9])(\d{1,3}(?:\.\d{1,3}){3})(?::(\d{1,5}))?(?![0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }
        let host = nsText.substring(with: match.range(at: 1))
        let port: UInt16?
        if match.range(at: 2).location != NSNotFound {
            port = UInt16(nsText.substring(with: match.range(at: 2)))
        } else {
            port = nil
        }
        return (host, port)
    }

    private static func normalizeHost(_ value: String) -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: host), let parsedHost = url.host {
            host = parsedHost
        }
        if let endpoint = firstIPv4Endpoint(in: host) {
            host = endpoint.host
        }
        return host
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

public enum LocalRemoteTokenStore {
    private static let service = "com.jiseok.KLMSync.localRemoteToken"

    public static func load(account: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        #else
        return nil
        #endif
    }

    @discardableResult
    public static func save(_ token: String, account: String) -> Bool {
        #if canImport(Security)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmedToken.data(using: .utf8), !trimmedToken.isEmpty else {
            delete(account: account)
            return false
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }

    public static func delete(account: String) {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }
}

public enum LocalRemoteAction: String, Codable, Sendable {
    case status
    case run
    case cancel
}

public struct LocalRemoteRequest: Codable, Sendable, Equatable {
    public var action: LocalRemoteAction
    public var kind: RemoteCommandKind?
    public var nonce: String
    public var issuedAtEpochSeconds: Int64
    public var signature: String

    public init(
        token: String,
        action: LocalRemoteAction,
        kind: RemoteCommandKind? = nil,
        nonce: String = UUID().uuidString,
        issuedAt: Date = Date()
    ) {
        self.action = action
        self.kind = kind
        self.nonce = nonce
        issuedAtEpochSeconds = Int64(issuedAt.timeIntervalSince1970)
        signature = Self.signature(
            token: token,
            action: action,
            kind: kind,
            nonce: nonce,
            issuedAtEpochSeconds: issuedAtEpochSeconds
        )
    }

    public func isAuthorized(
        token: String,
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 120
    ) -> Bool {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !nonce.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let age = abs(now.timeIntervalSince1970 - TimeInterval(issuedAtEpochSeconds))
        guard age <= allowedClockSkew else {
            return false
        }
        let expected = Self.signature(
            token: token,
            action: action,
            kind: kind,
            nonce: nonce,
            issuedAtEpochSeconds: issuedAtEpochSeconds
        )
        return Self.timingSafeEqual(signature.lowercased(), expected.lowercased())
    }

    public static func signature(
        token: String,
        action: LocalRemoteAction,
        kind: RemoteCommandKind?,
        nonce: String,
        issuedAtEpochSeconds: Int64
    ) -> String {
        let payload = [
            action.rawValue,
            kind?.rawValue ?? "",
            nonce,
            String(issuedAtEpochSeconds),
        ].joined(separator: "\n")
        #if canImport(CryptoKit)
        let key = SymmetricKey(data: Data(token.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }

    fileprivate static func timingSafeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else {
            return false
        }
        var difference: UInt8 = 0
        for (lhsByte, rhsByte) in zip(lhsBytes, rhsBytes) {
            difference |= lhsByte ^ rhsByte
        }
        return difference == 0
    }
}

public struct LocalRemoteResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var message: String
    public var status: SanitizedRemoteStatus
    public var latestCommand: RemoteRunCommand?
    public var running: Bool
    public var requestNonce: String?
    public var responseIssuedAtEpochSeconds: Int64?
    public var signature: String?

    public init(
        ok: Bool = true,
        message: String = "",
        status: SanitizedRemoteStatus = SanitizedRemoteStatus(),
        latestCommand: RemoteRunCommand? = nil,
        running: Bool = false,
        requestNonce: String? = nil,
        responseIssuedAtEpochSeconds: Int64? = nil,
        signature: String? = nil
    ) {
        self.ok = ok
        self.message = message
        self.status = status
        self.latestCommand = latestCommand
        self.running = running
        self.requestNonce = requestNonce
        self.responseIssuedAtEpochSeconds = responseIssuedAtEpochSeconds
        self.signature = signature
    }

    public func signed(
        token: String,
        request: LocalRemoteRequest,
        issuedAt: Date = Date()
    ) -> LocalRemoteResponse {
        var response = self
        response.requestNonce = request.nonce
        response.responseIssuedAtEpochSeconds = Int64(issuedAt.timeIntervalSince1970)
        response.signature = Self.signature(
            token: token,
            request: request,
            response: response
        )
        return response
    }

    public func isAuthorized(
        token: String,
        request: LocalRemoteRequest,
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 120
    ) -> Bool {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              requestNonce == request.nonce,
              let responseIssuedAtEpochSeconds,
              let signature,
              !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let age = abs(now.timeIntervalSince1970 - TimeInterval(responseIssuedAtEpochSeconds))
        guard age <= allowedClockSkew else {
            return false
        }
        let expected = Self.signature(
            token: token,
            request: request,
            response: self
        )
        return LocalRemoteRequest.timingSafeEqual(signature.lowercased(), expected.lowercased())
    }

    public static func signature(
        token: String,
        request: LocalRemoteRequest,
        response: LocalRemoteResponse
    ) -> String {
        guard let requestNonce = response.requestNonce,
              let responseIssuedAtEpochSeconds = response.responseIssuedAtEpochSeconds else {
            return ""
        }
        let body = LocalRemoteResponseSignatureBody(
            requestAction: request.action,
            requestKind: request.kind,
            requestNonce: request.nonce,
            requestIssuedAtEpochSeconds: request.issuedAtEpochSeconds,
            responseRequestNonce: requestNonce,
            responseIssuedAtEpochSeconds: responseIssuedAtEpochSeconds,
            ok: response.ok,
            message: response.message,
            status: response.status,
            latestCommand: response.latestCommand,
            running: response.running
        )
        guard let payload = try? JSONEncoder.klmsLocalRemoteSignature.encode(body) else {
            return ""
        }
        #if canImport(CryptoKit)
        let key = SymmetricKey(data: Data(token.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return code.map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }
}

private struct LocalRemoteResponseSignatureBody: Codable {
    var requestAction: LocalRemoteAction
    var requestKind: RemoteCommandKind?
    var requestNonce: String
    var requestIssuedAtEpochSeconds: Int64
    var responseRequestNonce: String
    var responseIssuedAtEpochSeconds: Int64
    var ok: Bool
    var message: String
    var status: SanitizedRemoteStatus
    var latestCommand: RemoteRunCommand?
    var running: Bool
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
            "\(message.isEmpty ? "Mac 앱에 연결하지 못했습니다." : message) 같은 Wi-Fi 또는 개인 VPN에 연결되어 있는지, Mac 앱이 켜져 있는지, iOS 로컬 네트워크 권한을 허용했는지 확인해 주세요."
        case .invalidResponse:
            "Mac 앱 응답을 인증하거나 해석하지 못했습니다."
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

    public func cancelRunningCommand() async throws -> LocalRemoteResponse {
        try await send(LocalRemoteRequest(token: token, action: .cancel))
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
        guard response.isAuthorized(token: token, request: request) else {
            throw LocalRemoteClientError.invalidResponse
        }
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

    static var klmsLocalRemoteSignature: JSONEncoder {
        let encoder = JSONEncoder.klmsLocalRemote
        encoder.outputFormatting = [.sortedKeys]
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
        if let authStatusMessage = command.summary.authStatusMessage {
            record["authStatusMessage"] = authStatusMessage as NSString
        } else {
            record["authStatusMessage"] = nil
        }
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
                phase: (record["phase"] as? String) ?? "",
                authStatusMessage: record["authStatusMessage"] as? String
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
