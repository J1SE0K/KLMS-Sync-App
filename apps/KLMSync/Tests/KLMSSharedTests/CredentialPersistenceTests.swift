import Foundation
import XCTest
@testable import KLMSShared

final class CredentialPersistenceTests: XCTestCase {
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
