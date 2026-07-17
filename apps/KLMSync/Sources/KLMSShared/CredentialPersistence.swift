import Foundation

public struct VersionedCredentialEnvelope: Codable, Equatable, Sendable {
    public var generation: UInt64
    public var value: String

    public init(generation: UInt64, value: String) {
        self.generation = generation
        self.value = value
    }

    public func encoded() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Credential envelope is not valid UTF-8."
                )
            )
        }
        return encoded
    }

    public static func decode(_ encoded: String) -> VersionedCredentialEnvelope? {
        guard let data = encoded.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(VersionedCredentialEnvelope.self, from: data)
    }

    public static func acceptedValue(
        from encoded: String,
        expectedGeneration: UInt64
    ) -> String? {
        guard let envelope = decode(encoded), envelope.generation == expectedGeneration else {
            return nil
        }
        return envelope.value
    }

    public static func acceptedEnvelope(
        from encoded: String,
        minimumGeneration: UInt64
    ) -> VersionedCredentialEnvelope? {
        guard let envelope = decode(encoded), envelope.generation >= minimumGeneration else {
            return nil
        }
        return envelope
    }
}

public struct ServerRelayCredentialPair: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var version: Int
    public var serverURL: String
    public var clientToken: String

    public init(serverURL: String, clientToken: String) {
        version = Self.schemaVersion
        self.serverURL = serverURL
        self.clientToken = clientToken
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Relay connection credential is not valid UTF-8."
                )
            )
        }
        return encoded
    }

    public static func decode(_ encoded: String) -> ServerRelayCredentialPair? {
        guard let data = encoded.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ServerRelayCredentialPair.self, from: data),
              decoded.version == schemaVersion,
              decoded.serverURL.isEmpty == decoded.clientToken.isEmpty else {
            return nil
        }
        return decoded
    }
}

/// Values from the legacy clients were stored in independent locations and have no
/// transaction identifier that can prove they were saved as one connection. Any
/// nonempty fragment therefore requires the user to re-enter the complete tuple.
public struct UnboundServerRelayCredentialFragments: Equatable, Sendable {
    /// Whether independently supplied relay fields form no connection, a complete
    /// connection, or a partial tuple that must never be persisted as verified.
    public enum PopulationState: Equatable, Sendable {
        case empty
        case complete
        case partial
    }

    public var serverURL: String
    public var clientToken: String
    public var workerToken: String

    public init(serverURL: String, clientToken: String, workerToken: String) {
        self.serverURL = serverURL
        self.clientToken = clientToken
        self.workerToken = workerToken
    }

    public var populationState: PopulationState {
        let populatedFieldCount = [serverURL, clientToken, workerToken].reduce(into: 0) { count, value in
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        switch populatedFieldCount {
        case 0:
            return .empty
        case 3:
            return .complete
        default:
            return .partial
        }
    }

    public var requiresManualReentry: Bool {
        populationState != .empty
    }
}

public enum CredentialPersistenceResult: Sendable, Equatable {
    case persisted(VersionedCredentialEnvelope)
    case superseded
    case failed(lastPersisted: VersionedCredentialEnvelope)
}

public final class CredentialPersistenceCoordinator: @unchecked Sendable {
    private let generationLock = NSLock()
    private let operationQueue: DispatchQueue
    private var generation: UInt64
    private var lastPersistedEnvelope: VersionedCredentialEnvelope

    public init(
        initialGeneration: UInt64 = 0,
        initialValue: String = "",
        queueLabel: String = "com.local.klmssync.credential-persistence"
    ) {
        generation = initialGeneration
        lastPersistedEnvelope = VersionedCredentialEnvelope(
            generation: initialGeneration,
            value: initialValue
        )
        operationQueue = DispatchQueue(label: queueLabel, qos: .utility)
    }

    public func begin(after minimumGeneration: UInt64 = 0) -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        generation = max(generation, minimumGeneration)
        generation &+= 1
        return generation
    }

    public func persist(
        _ value: String,
        generation expectedGeneration: UInt64,
        operation: @escaping @Sendable (VersionedCredentialEnvelope) -> Bool
    ) async -> CredentialPersistenceResult {
        let envelope = VersionedCredentialEnvelope(
            generation: expectedGeneration,
            value: value
        )
        return await withCheckedContinuation { continuation in
            operationQueue.async { [self] in
                generationLock.lock()
                let shouldPersist = generation == expectedGeneration
                generationLock.unlock()
                if shouldPersist {
                    if operation(envelope) {
                        lastPersistedEnvelope = envelope
                        continuation.resume(returning: .persisted(envelope))
                    } else {
                        continuation.resume(returning: .failed(lastPersisted: lastPersistedEnvelope))
                    }
                } else {
                    continuation.resume(returning: .superseded)
                }
            }
        }
    }
}
