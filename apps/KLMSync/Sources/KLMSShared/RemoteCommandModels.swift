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
    case verify
    case doctor
    case report
    case v2BuildState

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
        case .verify:
            .verify
        case .doctor:
            .doctor
        case .report:
            .report
        case .v2BuildState:
            .v2BuildState
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
        case .verify:
            self = .verify
        case .doctor:
            self = .doctor
        case .report:
            self = .report
        case .v2BuildState:
            self = .v2BuildState
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
    public var noticeNew: Int
    public var noticeUpdated: Int
    public var noticeIgnored: Int
    public var fileTotal: Int
    public var newFiles: Int
    public var quarantine: Int
    public var filePruned: Int
    public var fileArchivePruned: Int
    public var calendarCreated: Int
    public var calendarUpdated: Int
    public var calendarDeleted: Int
    public var phase: String
    public var loginRequired: Bool
    public var authDigits: String?
    public var authStatusMessage: String?

    enum CodingKeys: String, CodingKey {
        case assignments
        case exams
        case helpDesk
        case notices
        case noticeNew
        case noticeUpdated
        case noticeIgnored
        case fileTotal
        case newFiles
        case quarantine
        case filePruned
        case fileArchivePruned
        case calendarCreated
        case calendarUpdated
        case calendarDeleted
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
        noticeNew: Int = 0,
        noticeUpdated: Int = 0,
        noticeIgnored: Int = 0,
        fileTotal: Int = 0,
        newFiles: Int = 0,
        quarantine: Int = 0,
        filePruned: Int = 0,
        fileArchivePruned: Int = 0,
        calendarCreated: Int = 0,
        calendarUpdated: Int = 0,
        calendarDeleted: Int = 0,
        phase: String = "",
        loginRequired: Bool = false,
        authDigits: String? = nil,
        authStatusMessage: String? = nil
    ) {
        self.assignments = assignments
        self.exams = exams
        self.helpDesk = helpDesk
        self.notices = notices
        self.noticeNew = noticeNew
        self.noticeUpdated = noticeUpdated
        self.noticeIgnored = noticeIgnored
        self.fileTotal = fileTotal
        self.newFiles = newFiles
        self.quarantine = quarantine
        self.filePruned = filePruned
        self.fileArchivePruned = fileArchivePruned
        self.calendarCreated = calendarCreated
        self.calendarUpdated = calendarUpdated
        self.calendarDeleted = calendarDeleted
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
        noticeNew = snapshot.syncReport?.notices.new ?? 0
        noticeUpdated = snapshot.syncReport?.notices.updated ?? 0
        noticeIgnored = snapshot.syncReport?.notices.ignored ?? 0
        fileTotal = snapshot.syncReport?.files.total ?? 0
        newFiles = counts.newFiles
        quarantine = counts.quarantine
        filePruned = snapshot.syncReport?.files.pruned ?? 0
        fileArchivePruned = snapshot.syncReport?.files.archivePruned ?? 0
        calendarCreated = snapshot.syncReport?.calendar.created ?? 0
        calendarUpdated = snapshot.syncReport?.calendar.updated ?? 0
        calendarDeleted = snapshot.syncReport?.calendar.deleted ?? 0
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
        noticeNew = container.decodeIfPresentDefault(Int.self, forKey: .noticeNew, default: 0)
        noticeUpdated = container.decodeIfPresentDefault(Int.self, forKey: .noticeUpdated, default: 0)
        noticeIgnored = container.decodeIfPresentDefault(Int.self, forKey: .noticeIgnored, default: 0)
        fileTotal = container.decodeIfPresentDefault(Int.self, forKey: .fileTotal, default: 0)
        newFiles = container.decodeIfPresentDefault(Int.self, forKey: .newFiles, default: 0)
        quarantine = container.decodeIfPresentDefault(Int.self, forKey: .quarantine, default: 0)
        filePruned = container.decodeIfPresentDefault(Int.self, forKey: .filePruned, default: 0)
        fileArchivePruned = container.decodeIfPresentDefault(Int.self, forKey: .fileArchivePruned, default: 0)
        calendarCreated = container.decodeIfPresentDefault(Int.self, forKey: .calendarCreated, default: 0)
        calendarUpdated = container.decodeIfPresentDefault(Int.self, forKey: .calendarUpdated, default: 0)
        calendarDeleted = container.decodeIfPresentDefault(Int.self, forKey: .calendarDeleted, default: 0)
        phase = container.decodeIfPresentDefault(String.self, forKey: .phase, default: "")
        loginRequired = container.decodeIfPresentDefault(Bool.self, forKey: .loginRequired, default: false)
        authDigits = try container.decodeIfPresent(String.self, forKey: .authDigits)
        authStatusMessage = try container.decodeIfPresent(String.self, forKey: .authStatusMessage)
    }

    public var calendarChangeTotal: Int {
        calendarCreated + calendarUpdated + calendarDeleted
    }

    public var fileCleanupTotal: Int {
        filePruned + fileArchivePruned
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

protocol LocalRemoteTokenKeychainBackend {
    func load(account: String, service: String) -> String?

    @discardableResult
    func save(_ token: String, account: String, service: String) -> Bool

    func delete(account: String, service: String)
}

private struct SecurityLocalRemoteTokenKeychainBackend: LocalRemoteTokenKeychainBackend {
    func load(account: String, service: String) -> String? {
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
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    @discardableResult
    func save(_ token: String, account: String, service: String) -> Bool {
        #if canImport(Security)
        guard let data = token.data(using: .utf8), !token.isEmpty else {
            delete(account: account, service: service)
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

    func delete(account: String, service: String) {
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

public enum LocalRemoteTokenStore {
    private static let service = "com.local.KLMSync.localRemoteToken"
    private static let legacyServiceByteGroups: [[UInt8]] = [
        [
            99, 111, 109, 46, 106, 105, 115, 101, 111, 107, 46, 75, 76, 77, 83, 121,
            110, 99, 46, 108, 111, 99, 97, 108, 82, 101, 109, 111, 116, 101, 84,
            111, 107, 101, 110,
        ],
    ]

    private static var legacyServices: [String] {
        legacyServiceByteGroups.compactMap { String(bytes: $0, encoding: .utf8) }
    }

    static var serviceForTesting: String {
        service
    }

    static var legacyServicesForTesting: [String] {
        legacyServices
    }

    public static func load(account: String) -> String? {
        load(account: account, backend: SecurityLocalRemoteTokenKeychainBackend())
    }

    static func load(account: String, backend: LocalRemoteTokenKeychainBackend) -> String? {
        if let token = normalizedToken(backend.load(account: account, service: service)) {
            return token
        }
        for legacyService in legacyServices {
            guard let token = normalizedToken(backend.load(account: account, service: legacyService)) else {
                continue
            }
            if save(token, account: account, service: service, backend: backend) {
                backend.delete(account: account, service: legacyService)
            }
            return token
        }
        return nil
    }

    @discardableResult
    public static func save(_ token: String, account: String) -> Bool {
        save(
            token,
            account: account,
            service: service,
            backend: SecurityLocalRemoteTokenKeychainBackend()
        )
    }

    @discardableResult
    static func save(
        _ token: String,
        account: String,
        service: String,
        backend: LocalRemoteTokenKeychainBackend
    ) -> Bool {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            backend.delete(account: account, service: service)
            return false
        }
        return backend.save(trimmedToken, account: account, service: service)
    }

    public static func delete(account: String) {
        delete(account: account, backend: SecurityLocalRemoteTokenKeychainBackend())
    }

    static func delete(account: String, backend: LocalRemoteTokenKeychainBackend) {
        backend.delete(account: account, service: service)
        for legacyService in legacyServices {
            backend.delete(account: account, service: legacyService)
        }
    }

    private static func normalizedToken(_ token: String?) -> String? {
        token?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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

public struct ServerRelayConnectionInfo: Sendable, Equatable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parse(
        urlText: String,
        tokenText: String = ""
    ) -> ServerRelayConnectionInfo? {
        let rawURLText = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTokenText = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        let combinedText = [rawURLText, rawTokenText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let extractedURL = labeledValue(in: combinedText, labels: ["서버 주소", "서버", "Relay URL", "Server URL", "URL"])
            ?? firstURL(in: combinedText)
            ?? rawURLText
        let extractedToken = rawTokenText.isEmpty
            ? labeledToken(in: combinedText, labels: Self.clientTokenLabels + Self.legacyTokenLabels)
            : rawTokenText
        guard let baseURL = normalizedBaseURL(extractedURL),
              let token = extractedToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        return ServerRelayConnectionInfo(baseURL: baseURL, token: token)
    }

    public static let clientTokenLabels = [
        "클라이언트 토큰",
        "Client Token",
        "Client Relay Token",
        "iPhone 토큰",
        "Windows 토큰",
    ]

    public static let workerTokenLabels = [
        "Mac worker 토큰",
        "Worker Token",
        "Worker Relay Token",
        "Mac 토큰",
    ]

    public static let legacyTokenLabels = [
        "토큰",
        "Token",
        "Relay Token",
        "Server Token",
    ]

    public static func labeledToken(in text: String, labels: [String]) -> String? {
        labeledValue(in: text, labels: labels)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
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

    private static func firstURL(in text: String) -> String? {
        let pattern = #"https?://[^\s]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }
        return nsText.substring(with: match.range)
    }

    private static func normalizedBaseURL(_ value: String) -> URL? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://\(text)"
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        components.scheme = scheme
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.isEmpty ? "" : "/\(path)"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        return url
    }
}

public enum ServerRelayClientError: LocalizedError, Sendable {
    case emptyURL
    case emptyToken
    case insecureURL(String)
    case invalidURL
    case invalidResponse
    case serverRejected(Int, String)

    public var errorDescription: String? {
        switch self {
        case .emptyURL:
            return "서버 주소를 입력해 주세요."
        case .emptyToken:
            return "서버 토큰을 입력해 주세요."
        case let .insecureURL(host):
            return "\(host)은 HTTPS가 아닙니다. 외부 접속용 서버는 HTTPS 주소를 사용해야 합니다."
        case .invalidURL:
            return "서버 주소 형식이 올바르지 않습니다."
        case .invalidResponse:
            return "서버 응답을 해석하지 못했습니다."
        case let .serverRejected(statusCode, message):
            if statusCode == 401 {
                return "서버 인증 실패: 서버 주소와 클라이언트/워커 토큰이 최신 값인지 확인해 주세요."
            }
            return message.isEmpty ? "서버 요청이 실패했습니다." : message
        }
    }
}

public struct ServerRelayCommandListResponse: Codable, Sendable, Equatable {
    public var commands: [RemoteRunCommand]
    public var status: SanitizedRemoteStatus
    public var latestCommand: RemoteRunCommand?
    public var running: Bool

    public init(
        commands: [RemoteRunCommand] = [],
        status: SanitizedRemoteStatus = SanitizedRemoteStatus(),
        latestCommand: RemoteRunCommand? = nil,
        running: Bool = false
    ) {
        self.commands = commands
        self.status = status
        self.latestCommand = latestCommand
        self.running = running
    }
}

public struct ServerRelayStatusUpdate: Codable, Sendable, Equatable {
    public var status: SanitizedRemoteStatus
    public var latestCommand: RemoteRunCommand?
    public var running: Bool
    public var message: String

    public init(
        status: SanitizedRemoteStatus,
        latestCommand: RemoteRunCommand? = nil,
        running: Bool = false,
        message: String = ""
    ) {
        self.status = status
        self.latestCommand = latestCommand
        self.running = running
        self.message = message
    }
}

public struct ServerRelaySyncData: Codable, Sendable, Equatable {
    public var generatedAt: String
    public var items: [ServerRelaySyncItem]

    public init(generatedAt: String = "", items: [ServerRelaySyncItem] = []) {
        self.generatedAt = generatedAt
        self.items = items
    }
}

public struct ServerRelaySyncItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: String
    public var course: String
    public var title: String
    public var timestamp: String
    public var status: String
    public var detail: String
    public var attachmentCount: Int
    public var updatedAt: String
    public var isRead: Bool
    public var isImportant: Bool
    public var isHidden: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case course
        case title
        case timestamp
        case status
        case detail
        case attachmentCount
        case updatedAt
        case isRead
        case isImportant
        case isHidden
    }

    public init(
        id: String,
        kind: String,
        course: String = "",
        title: String,
        timestamp: String = "",
        status: String = "",
        detail: String = "",
        attachmentCount: Int = 0,
        updatedAt: String = ServerRelaySyncItem.isoTimestamp(),
        isRead: Bool = false,
        isImportant: Bool = false,
        isHidden: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.course = course
        self.title = title
        self.timestamp = timestamp
        self.status = status
        self.detail = detail
        self.attachmentCount = attachmentCount
        self.updatedAt = updatedAt
        self.isRead = isRead
        self.isImportant = isImportant
        self.isHidden = isHidden
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        course = try container.decodeIfPresent(String.self, forKey: .course) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        attachmentCount = try container.decodeIfPresent(Int.self, forKey: .attachmentCount) ?? 0
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ServerRelaySyncItem.isoTimestamp()
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        isImportant = try container.decodeIfPresent(Bool.self, forKey: .isImportant) ?? false
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }

    public static func stableID(kind: String, parts: [String]) -> String {
        let payload = ([kind] + parts)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\u{1F}")
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return payload
        #endif
    }

    public static func isoTimestamp(date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

public enum ServerRelayItemActionKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case assignmentComplete
    case assignmentRestore
    case assignmentHide
    case assignmentUnhide
    case examPromote
    case examIgnore
    case examRestore
    case noticeRead
    case noticeUnread
    case noticeImportant
    case noticeUnimportant
    case noticeHide
    case noticeUnhide
    case fileHide
    case fileUnhide

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .assignmentComplete:
            "과제 완료"
        case .assignmentRestore:
            "과제 복구"
        case .assignmentHide:
            "과제 숨김"
        case .assignmentUnhide:
            "과제 숨김 해제"
        case .examPromote:
            "시험으로 확정"
        case .examIgnore:
            "시험 아님"
        case .examRestore:
            "시험 복구"
        case .noticeRead:
            "공지 읽음"
        case .noticeUnread:
            "공지 읽지 않음"
        case .noticeImportant:
            "공지 중요"
        case .noticeUnimportant:
            "공지 중요 해제"
        case .noticeHide:
            "공지 숨김"
        case .noticeUnhide:
            "공지 숨김 해제"
        case .fileHide:
            "파일 숨김"
        case .fileUnhide:
            "파일 숨김 해제"
        }
    }
}

public enum ServerRelayItemActionStatus: String, Codable, Sendable {
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
            "처리 중"
        case .completed:
            "완료"
        case .failed:
            "실패"
        case .macUnavailable:
            "Mac 응답 없음"
        }
    }
}

public struct ServerRelayItemAction: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var action: ServerRelayItemActionKind
    public var itemID: String
    public var itemKind: String
    public var itemTitle: String
    public var status: ServerRelayItemActionStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var message: String

    public init(
        id: UUID = UUID(),
        action: ServerRelayItemActionKind,
        itemID: String,
        itemKind: String,
        itemTitle: String = "",
        status: ServerRelayItemActionStatus = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        message: String = ""
    ) {
        self.id = id
        self.action = action
        self.itemID = itemID
        self.itemKind = itemKind
        self.itemTitle = itemTitle
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.message = message
    }
}

public struct ServerRelayItemActionListResponse: Codable, Sendable, Equatable {
    public var actions: [ServerRelayItemAction]

    public init(actions: [ServerRelayItemAction] = []) {
        self.actions = actions
    }
}

public enum ServerRelayFileAccessStatus: String, Codable, Sendable {
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
            "파일 준비 중"
        case .completed:
            "열기 가능"
        case .failed:
            "실패"
        case .macUnavailable:
            "Mac 응답 없음"
        }
    }

    public var isInFlight: Bool {
        self == .pending || self == .running
    }
}

public struct ServerRelayFileAccessRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var itemID: String
    public var itemKind: String
    public var itemTitle: String
    public var status: ServerRelayFileAccessStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var message: String
    public var downloadURL: String?
    public var expiresAt: Date?
    public var sizeBytes: Int?

    public init(
        id: UUID = UUID(),
        itemID: String,
        itemKind: String = "file",
        itemTitle: String = "",
        status: ServerRelayFileAccessStatus = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        message: String = "",
        downloadURL: String? = nil,
        expiresAt: Date? = nil,
        sizeBytes: Int? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.itemKind = itemKind
        self.itemTitle = itemTitle
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.message = message
        self.downloadURL = downloadURL
        self.expiresAt = expiresAt
        self.sizeBytes = sizeBytes
    }

    public var isDownloadAvailable: Bool {
        guard status == .completed,
              downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        if let expiresAt {
            return expiresAt > Date()
        }
        return true
    }
}

public struct ServerRelayFileAccessListResponse: Codable, Sendable, Equatable {
    public var requests: [ServerRelayFileAccessRequest]

    public init(requests: [ServerRelayFileAccessRequest] = []) {
        self.requests = requests
    }
}

public struct ServerRelayCommandStore: RemoteCommandStore {
    public var baseURL: URL
    public var token: String
    public var allowsInsecureHTTP: Bool

    public init(
        baseURL: URL,
        token: String,
        allowsInsecureHTTP: Bool = false
    ) throws {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw ServerRelayClientError.emptyToken
        }
        self.baseURL = Self.normalizedBaseURL(baseURL)
        self.token = trimmedToken
        self.allowsInsecureHTTP = allowsInsecureHTTP
        try validateURL()
    }

    public init(
        urlText: String,
        token: String,
        allowsInsecureHTTP: Bool = false
    ) throws {
        guard let info = ServerRelayConnectionInfo.parse(urlText: urlText, tokenText: token) else {
            if urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ServerRelayClientError.emptyURL
            }
            if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ServerRelayClientError.emptyToken
            }
            throw ServerRelayClientError.invalidURL
        }
        try self.init(
            baseURL: info.baseURL,
            token: info.token,
            allowsInsecureHTTP: allowsInsecureHTTP
        )
    }

    public func create(_ command: RemoteRunCommand) async throws {
        let _: RemoteRunCommand = try await send(
            method: "POST",
            path: "/v1/commands",
            body: command
        )
    }

    public func fetchPending() async throws -> [RemoteRunCommand] {
        let response: ServerRelayCommandListResponse = try await send(
            method: "GET",
            path: "/v1/commands/pending"
        )
        return response.commands
    }

    public func fetchRecent(limit: Int = 10) async throws -> [RemoteRunCommand] {
        let response: ServerRelayCommandListResponse = try await send(
            method: "GET",
            path: "/v1/commands/recent",
            queryItems: [URLQueryItem(name: "limit", value: "\(limit)")]
        )
        return response.commands
    }

    public func update(_ command: RemoteRunCommand) async throws {
        let _: RemoteRunCommand = try await send(
            method: "PUT",
            path: "/v1/commands/\(command.id.uuidString)",
            body: command
        )
    }

    public func fetchStatusResponse() async throws -> LocalRemoteResponse {
        try await send(method: "GET", path: "/v1/status")
    }

    public func publishStatus(
        _ status: SanitizedRemoteStatus,
        latestCommand: RemoteRunCommand?,
        running: Bool,
        message: String = ""
    ) async throws {
        let update = ServerRelayStatusUpdate(
            status: status,
            latestCommand: latestCommand,
            running: running,
            message: message
        )
        let _: LocalRemoteResponse = try await send(
            method: "POST",
            path: "/v1/status",
            body: update
        )
    }

    public func publishSyncData(_ syncData: ServerRelaySyncData) async throws {
        let _: ServerRelaySyncData = try await send(
            method: "POST",
            path: "/v1/sync-data",
            body: syncData
        )
    }

    public func fetchSyncData(kind: String? = nil, limit: Int = 250) async throws -> ServerRelaySyncData {
        var queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let kind, !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "kind", value: kind))
        }
        return try await send(
            method: "GET",
            path: "/v1/sync-data",
            queryItems: queryItems
        )
    }

    public func createItemAction(_ action: ServerRelayItemAction) async throws {
        let _: ServerRelayItemAction = try await send(
            method: "POST",
            path: "/v1/item-actions",
            body: action
        )
    }

    public func fetchPendingItemActions() async throws -> [ServerRelayItemAction] {
        let response: ServerRelayItemActionListResponse = try await send(
            method: "GET",
            path: "/v1/item-actions/pending"
        )
        return response.actions
    }

    public func fetchRecentItemActions(limit: Int = 20) async throws -> [ServerRelayItemAction] {
        let response: ServerRelayItemActionListResponse = try await send(
            method: "GET",
            path: "/v1/item-actions/recent",
            queryItems: [URLQueryItem(name: "limit", value: "\(limit)")]
        )
        return response.actions
    }

    public func updateItemAction(_ action: ServerRelayItemAction) async throws {
        let _: ServerRelayItemAction = try await send(
            method: "PUT",
            path: "/v1/item-actions/\(action.id.uuidString)",
            body: action
        )
    }

    public func createFileAccessRequest(_ fileRequest: ServerRelayFileAccessRequest) async throws -> ServerRelayFileAccessRequest {
        try await send(
            method: "POST",
            path: "/v1/file-access",
            body: fileRequest
        )
    }

    public func fetchPendingFileAccessRequests(limit: Int = 20) async throws -> [ServerRelayFileAccessRequest] {
        let response: ServerRelayFileAccessListResponse = try await send(
            method: "GET",
            path: "/v1/file-access/pending",
            queryItems: [URLQueryItem(name: "limit", value: "\(limit)")]
        )
        return response.requests
    }

    public func fetchRecentFileAccessRequests(limit: Int = 20) async throws -> [ServerRelayFileAccessRequest] {
        let response: ServerRelayFileAccessListResponse = try await send(
            method: "GET",
            path: "/v1/file-access/recent",
            queryItems: [URLQueryItem(name: "limit", value: "\(limit)")]
        )
        return response.requests
    }

    public func updateFileAccessRequest(_ fileRequest: ServerRelayFileAccessRequest) async throws {
        let _: ServerRelayFileAccessRequest = try await send(
            method: "PUT",
            path: "/v1/file-access/\(fileRequest.id.uuidString)",
            body: fileRequest
        )
    }

    public func uploadFileAccessRequest(
        _ fileRequest: ServerRelayFileAccessRequest,
        fileURL: URL,
        filename: String,
        contentType: String = "application/octet-stream"
    ) async throws -> ServerRelayFileAccessRequest {
        var request = URLRequest(url: endpoint(
            "/v1/file-access/\(fileRequest.id.uuidString)/upload",
            queryItems: []
        ))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(
            filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "klms-file",
            forHTTPHeaderField: "X-KLMS-Filename"
        )
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServerRelayClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder.klmsLocalRemote.decode(ServerRelayErrorResponse.self, from: data))?.error
                ?? String(data: data, encoding: .utf8)
                ?? ""
            throw ServerRelayClientError.serverRejected(httpResponse.statusCode, message)
        }
        do {
            return try JSONDecoder.klmsLocalRemote.decode(ServerRelayFileAccessRequest.self, from: data)
        } catch {
            throw ServerRelayClientError.invalidResponse
        }
    }

    private func send<T: Decodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> T {
        try await send(method: method, path: path, queryItems: queryItems, bodyData: nil)
    }

    private func send<T: Decodable, Body: Encodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Body
    ) async throws -> T {
        let bodyData = try JSONEncoder.klmsLocalRemote.encode(body)
        return try await send(method: method, path: path, queryItems: queryItems, bodyData: bodyData)
    }

    private func send<T: Decodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        bodyData: Data?
    ) async throws -> T {
        var request = URLRequest(url: endpoint(path, queryItems: queryItems))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServerRelayClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder.klmsLocalRemote.decode(ServerRelayErrorResponse.self, from: data))?.error
                ?? String(data: data, encoding: .utf8)
                ?? ""
            throw ServerRelayClientError.serverRejected(httpResponse.statusCode, message)
        }
        do {
            return try JSONDecoder.klmsLocalRemote.decode(T.self, from: data)
        } catch {
            throw ServerRelayClientError.invalidResponse
        }
    }

    private func endpoint(_ path: String, queryItems: [URLQueryItem]) -> URL {
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var url = baseURL
        for component in trimmedPath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        guard !queryItems.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.queryItems = queryItems
        return components.url ?? url
    }

    private func validateURL() throws {
        guard let scheme = baseURL.scheme?.lowercased(), !scheme.isEmpty,
              let host = baseURL.host, !host.isEmpty else {
            throw ServerRelayClientError.invalidURL
        }
        guard scheme == "https" || allowsInsecureHTTP || Self.isPrivateHost(host) else {
            throw ServerRelayClientError.insecureURL(host)
        }
    }

    private static func normalizedBaseURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = (components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = path.isEmpty ? "" : "/\(path)"
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? url
    }

    private static func isPrivateHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered.hasSuffix(".local") {
            return true
        }
        let octets = lowered.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            return false
        }
        if octets[0] == 10 || octets[0] == 127 {
            return true
        }
        if octets[0] == 192 && octets[1] == 168 {
            return true
        }
        if octets[0] == 172 && (16...31).contains(octets[1]) {
            return true
        }
        return false
    }
}

private struct ServerRelayErrorResponse: Decodable {
    var error: String
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
        record["noticeNew"] = NSNumber(value: command.summary.noticeNew)
        record["noticeUpdated"] = NSNumber(value: command.summary.noticeUpdated)
        record["noticeIgnored"] = NSNumber(value: command.summary.noticeIgnored)
        record["fileTotal"] = NSNumber(value: command.summary.fileTotal)
        record["newFiles"] = NSNumber(value: command.summary.newFiles)
        record["quarantine"] = NSNumber(value: command.summary.quarantine)
        record["filePruned"] = NSNumber(value: command.summary.filePruned)
        record["fileArchivePruned"] = NSNumber(value: command.summary.fileArchivePruned)
        record["calendarCreated"] = NSNumber(value: command.summary.calendarCreated)
        record["calendarUpdated"] = NSNumber(value: command.summary.calendarUpdated)
        record["calendarDeleted"] = NSNumber(value: command.summary.calendarDeleted)
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
                noticeNew: (record["noticeNew"] as? NSNumber)?.intValue ?? 0,
                noticeUpdated: (record["noticeUpdated"] as? NSNumber)?.intValue ?? 0,
                noticeIgnored: (record["noticeIgnored"] as? NSNumber)?.intValue ?? 0,
                fileTotal: (record["fileTotal"] as? NSNumber)?.intValue ?? 0,
                newFiles: (record["newFiles"] as? NSNumber)?.intValue ?? 0,
                quarantine: (record["quarantine"] as? NSNumber)?.intValue ?? 0,
                filePruned: (record["filePruned"] as? NSNumber)?.intValue ?? 0,
                fileArchivePruned: (record["fileArchivePruned"] as? NSNumber)?.intValue ?? 0,
                calendarCreated: (record["calendarCreated"] as? NSNumber)?.intValue ?? 0,
                calendarUpdated: (record["calendarUpdated"] as? NSNumber)?.intValue ?? 0,
                calendarDeleted: (record["calendarDeleted"] as? NSNumber)?.intValue ?? 0,
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
