import Foundation
import XCTest
@testable import KLMSShared

final class CredentialPersistenceTests: XCTestCase {
    func testLegacyCredentialCleanupKeepsMetadataWhenSecureDeletionFails() {
        var metadataWasCleared = false

        XCTAssertFalse(
            LegacyCredentialCleanupPolicy.perform(
                deleteSecureValues: { false },
                clearMetadata: { metadataWasCleared = true }
            )
        )
        XCTAssertFalse(metadataWasCleared)

        XCTAssertTrue(
            LegacyCredentialCleanupPolicy.perform(
                deleteSecureValues: { true },
                clearMetadata: { metadataWasCleared = true }
            )
        )
        XCTAssertTrue(metadataWasCleared)
    }

    func testRelayConnectionCredentialKeepsURLAndTokenInOneVersionedValue() throws {
        let pair = ServerRelayCredentialPair(
            serverURL: "https://new-relay.example/",
            clientToken: "new-client-token"
        )

        let encodedPair = try pair.encoded()
        let envelope = VersionedCredentialEnvelope(generation: 7, value: encodedPair)
        let persisted = try envelope.encoded()
        let restoredEnvelope = try XCTUnwrap(
            VersionedCredentialEnvelope.acceptedEnvelope(from: persisted, minimumGeneration: 7)
        )

        XCTAssertEqual(ServerRelayCredentialPair.decode(restoredEnvelope.value), pair)
        XCTAssertNil(
            ServerRelayCredentialPair.decode(
                #"{"version":1,"serverURL":"https://relay.example/","clientToken":""}"#
            ),
            "partially populated URL/token pairs must fail closed"
        )
    }

    func testRelayConnectionCrashBoundaryReturnsOnlyOldOrNewAtomicPair() async throws {
        let oldPair = ServerRelayCredentialPair(
            serverURL: "https://old-relay.example/",
            clientToken: "old-client-token"
        )
        let newPair = ServerRelayCredentialPair(
            serverURL: "https://new-relay.example/",
            clientToken: "new-client-token"
        )
        let oldValue = try oldPair.encoded()
        let newValue = try newPair.encoded()
        let coordinator = CredentialPersistenceCoordinator(
            initialGeneration: 3,
            initialValue: oldValue,
            queueLabel: "relay-connection-crash-boundary-test"
        )

        let failedGeneration = coordinator.begin()
        let failed = await coordinator.persist(newValue, generation: failedGeneration) { _ in false }
        guard case let .failed(lastPersisted) = failed else {
            return XCTFail("failed persistence must retain the previous atomic pair")
        }
        XCTAssertEqual(ServerRelayCredentialPair.decode(lastPersisted.value), oldPair)

        let successfulGeneration = coordinator.begin()
        let successful = await coordinator.persist(newValue, generation: successfulGeneration) { _ in true }
        guard case let .persisted(saved) = successful else {
            return XCTFail("successful persistence must expose the new atomic pair")
        }
        XCTAssertEqual(ServerRelayCredentialPair.decode(saved.value), newPair)

        let possiblePairs = [lastPersisted, saved].compactMap {
            ServerRelayCredentialPair.decode($0.value)
        }
        XCTAssertEqual(possiblePairs, [oldPair, newPair])
        XCTAssertFalse(possiblePairs.contains {
            $0.serverURL == oldPair.serverURL && $0.clientToken == newPair.clientToken
        })
        XCTAssertFalse(possiblePairs.contains {
            $0.serverURL == newPair.serverURL && $0.clientToken == oldPair.clientToken
        })
    }

    func testUnboundLegacyRelayFragmentsAlwaysRequireManualReentry() {
        let ambiguousUpgradeCrashStates = [
            UnboundServerRelayCredentialFragments(
                serverURL: "https://old-relay.example/",
                clientToken: "new-client-token",
                workerToken: ""
            ),
            UnboundServerRelayCredentialFragments(
                serverURL: "https://new-relay.example/",
                clientToken: "old-client-token",
                workerToken: ""
            ),
            UnboundServerRelayCredentialFragments(
                serverURL: "https://old-relay.example/",
                clientToken: "new-client-token",
                workerToken: "new-worker-token"
            ),
            UnboundServerRelayCredentialFragments(
                serverURL: "",
                clientToken: "orphaned-client-token",
                workerToken: ""
            ),
            UnboundServerRelayCredentialFragments(
                serverURL: "",
                clientToken: "",
                workerToken: "orphaned-worker-token"
            )
        ]

        for fragments in ambiguousUpgradeCrashStates {
            XCTAssertTrue(
                fragments.requiresManualReentry,
                "independently stored legacy fields cannot prove they belong together"
            )
        }
        XCTAssertFalse(
            UnboundServerRelayCredentialFragments(
                serverURL: " \n ",
                clientToken: "",
                workerToken: "\t"
            ).requiresManualReentry
        )
    }

    func testRelayCredentialFragmentsClassifyOnlyEmptyOrCompleteTriplesAsSavable() {
        for mask in 0 ..< 8 {
            let fragments = UnboundServerRelayCredentialFragments(
                serverURL: mask & 0b001 == 0 ? " \n " : "https://relay.example/",
                clientToken: mask & 0b010 == 0 ? "" : " client-token ",
                workerToken: mask & 0b100 == 0 ? "\t" : " worker-token "
            )
            let expected: UnboundServerRelayCredentialFragments.PopulationState
            switch mask {
            case 0:
                expected = .empty
            case 0b111:
                expected = .complete
            default:
                expected = .partial
            }
            XCTAssertEqual(fragments.populationState, expected, "unexpected state for mask \(mask)")
        }
    }

    func testVersionedEnvelopeRejectsStaleCredential() throws {
        let encoded = try VersionedCredentialEnvelope(
            generation: 41,
            value: "synthetic-token"
        ).encoded()

        XCTAssertEqual(
            VersionedCredentialEnvelope.acceptedValue(
                from: encoded,
                expectedGeneration: 41
            ),
            "synthetic-token"
        )
        XCTAssertNil(
            VersionedCredentialEnvelope.acceptedValue(
                from: encoded,
                expectedGeneration: 42
            )
        )
        XCTAssertEqual(
            VersionedCredentialEnvelope.acceptedEnvelope(
                from: encoded,
                minimumGeneration: 40
            )?.generation,
            41
        )
        XCTAssertNil(
            VersionedCredentialEnvelope.acceptedEnvelope(
                from: encoded,
                minimumGeneration: 42
            )
        )
    }

    func testCoordinatorSkipsGenerationInvalidatedBeforePersistenceStarts() async {
        let recorder = LockedStringRecorder()
        let coordinator = CredentialPersistenceCoordinator(
            initialGeneration: 8,
            queueLabel: "credential-persistence-test-skip"
        )
        let staleGeneration = coordinator.begin()
        let currentGeneration = coordinator.begin()

        let staleResult = await coordinator.persist("stale", generation: staleGeneration) { envelope in
            recorder.append(envelope.value)
            return true
        }
        let currentResult = await coordinator.persist("current", generation: currentGeneration) { envelope in
            recorder.append(envelope.value)
            return true
        }

        XCTAssertEqual(staleResult, .superseded)
        XCTAssertEqual(
            currentResult,
            .persisted(VersionedCredentialEnvelope(generation: currentGeneration, value: "current"))
        )
        XCTAssertEqual(recorder.snapshot(), ["current"])
    }

    func testSlowCredentialStoreDoesNotBlockMainActor() async {
        let operationStarted = DispatchSemaphore(value: 0)
        let allowOperationToFinish = DispatchSemaphore(value: 0)
        let coordinator = CredentialPersistenceCoordinator(
            queueLabel: "credential-persistence-test-main-actor"
        )
        let generation = coordinator.begin()
        let persistence = Task { @MainActor in
            await coordinator.persist("token", generation: generation) { _ in
                operationStarted.signal()
                allowOperationToFinish.wait()
                return true
            }
        }

        XCTAssertEqual(operationStarted.wait(timeout: .now() + 2), .success)
        let clock = ContinuousClock()
        let startedAt = clock.now
        let marker = await MainActor.run { "responsive" }
        let elapsed = startedAt.duration(to: clock.now)
        XCTAssertEqual(marker, "responsive")
        XCTAssertLessThan(elapsed, .milliseconds(100))

        allowOperationToFinish.signal()
        let persistenceResult = await persistence.value
        XCTAssertEqual(
            persistenceResult,
            .persisted(VersionedCredentialEnvelope(generation: generation, value: "token"))
        )
    }

    func testNewerGenerationAlwaysPersistsAfterAnAlreadyStartedWrite() async {
        let operationStarted = DispatchSemaphore(value: 0)
        let allowFirstOperationToFinish = DispatchSemaphore(value: 0)
        let recorder = LockedStringRecorder()
        let coordinator = CredentialPersistenceCoordinator(
            queueLabel: "credential-persistence-test-linearization"
        )
        let firstGeneration = coordinator.begin()
        let firstPersistence = Task {
            await coordinator.persist("first", generation: firstGeneration) { envelope in
                operationStarted.signal()
                allowFirstOperationToFinish.wait()
                recorder.append(envelope.value)
                return true
            }
        }
        XCTAssertEqual(operationStarted.wait(timeout: .now() + 2), .success)
        let secondGeneration = coordinator.begin()
        let secondPersistence = Task {
            await coordinator.persist("second", generation: secondGeneration) { envelope in
                recorder.append(envelope.value)
                return true
            }
        }

        allowFirstOperationToFinish.signal()
        let firstResult = await firstPersistence.value
        let secondResult = await secondPersistence.value
        XCTAssertEqual(
            firstResult,
            .persisted(VersionedCredentialEnvelope(generation: firstGeneration, value: "first"))
        )
        XCTAssertEqual(
            secondResult,
            .persisted(VersionedCredentialEnvelope(generation: secondGeneration, value: "second"))
        )

        XCTAssertEqual(recorder.snapshot(), ["first", "second"])
    }

    func testCoordinatorReportsStoreFailure() async {
        let coordinator = CredentialPersistenceCoordinator(
            queueLabel: "credential-persistence-test-failure"
        )
        let generation = coordinator.begin()

        let result = await coordinator.persist("token", generation: generation) { _ in false }

        XCTAssertEqual(
            result,
            .failed(lastPersisted: VersionedCredentialEnvelope(generation: 0, value: ""))
        )
    }

    func testFailureCarriesTheLastSuccessfullyPersistedEnvelope() async {
        let coordinator = CredentialPersistenceCoordinator(
            initialGeneration: 4,
            initialValue: "initial",
            queueLabel: "credential-persistence-test-last-success"
        )
        let successfulGeneration = coordinator.begin()
        _ = await coordinator.persist("saved", generation: successfulGeneration) { _ in true }
        let failingGeneration = coordinator.begin()

        let result = await coordinator.persist("unsaved", generation: failingGeneration) { _ in false }

        XCTAssertEqual(
            result,
            .failed(
                lastPersisted: VersionedCredentialEnvelope(
                    generation: successfulGeneration,
                    value: "saved"
                )
            )
        )
    }
}

private final class LockedStringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
