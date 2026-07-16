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
}

public final class CredentialPersistenceCoordinator: @unchecked Sendable {
    private let generationLock = NSLock()
    private let operationQueue: DispatchQueue
    private var generation: UInt64

    public init(
        initialGeneration: UInt64 = 0,
        queueLabel: String = "com.local.klmssync.credential-persistence"
    ) {
        generation = initialGeneration
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
        operation: @escaping @Sendable (VersionedCredentialEnvelope) -> Void
    ) async {
        let envelope = VersionedCredentialEnvelope(
            generation: expectedGeneration,
            value: value
        )
        await withCheckedContinuation { continuation in
            operationQueue.async { [self] in
                generationLock.lock()
                let shouldPersist = generation == expectedGeneration
                generationLock.unlock()
                if shouldPersist {
                    operation(envelope)
                }
                continuation.resume()
            }
        }
    }
}
