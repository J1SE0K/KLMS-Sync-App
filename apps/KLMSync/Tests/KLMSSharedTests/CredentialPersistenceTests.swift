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
    }

    func testCoordinatorSkipsGenerationInvalidatedBeforePersistenceStarts() async {
        let recorder = LockedStringRecorder()
        let coordinator = CredentialPersistenceCoordinator(
            initialGeneration: 8,
            queueLabel: "credential-persistence-test-skip"
        )
        let staleGeneration = coordinator.begin()
        let currentGeneration = coordinator.begin()

        await coordinator.persist("stale", generation: staleGeneration) { envelope in
            recorder.append(envelope.value)
        }
        await coordinator.persist("current", generation: currentGeneration) { envelope in
            recorder.append(envelope.value)
        }

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
        await persistence.value
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
