import Foundation
import XCTest
@testable import KLMSShared

final class RemoteCommandTerminalOutboxTests: XCTestCase {
    func testTerminalCommandPersistsAcrossStoreInstancesUntilAcknowledged() throws {
        try withTemporaryStore { url in
            let command = RemoteRunCommand(
                id: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!,
                kind: .fullSync,
                status: .completed,
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 200),
                lastExitCode: 0
            )
            let firstStore = RemoteCommandTerminalOutboxStore(url: url)

            try firstStore.enqueue(
                command,
                relayURL: "https://relay.example.test/",
                workerTokenFingerprint: "token-fingerprint"
            )

            let reloadedStore = RemoteCommandTerminalOutboxStore(url: url)
            let pending = try reloadedStore.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )
            XCTAssertEqual(pending.map(\.command), [command])

            try reloadedStore.acknowledge(
                commandID: command.id,
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )
            XCTAssertTrue(try reloadedStore.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            ).isEmpty)
        }
    }

    func testOutboxScopesTerminalResultToOriginalRelayCredential() throws {
        try withTemporaryStore { url in
            let command = RemoteRunCommand(kind: .filesSync, status: .failed)
            let store = RemoteCommandTerminalOutboxStore(url: url)
            try store.enqueue(
                command,
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "original-token"
            )

            XCTAssertTrue(try store.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "replacement-token"
            ).isEmpty)
            XCTAssertTrue(try store.pending(
                relayURL: "https://other.example.test",
                workerTokenFingerprint: "original-token"
            ).isEmpty)
            XCTAssertEqual(try store.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "original-token"
            ).count, 1)
        }
    }

    func testOutboxRejectsInFlightCommands() throws {
        try withTemporaryStore { url in
            let store = RemoteCommandTerminalOutboxStore(url: url)

            XCTAssertThrowsError(
                try store.enqueue(
                    RemoteRunCommand(kind: .doctor, status: .running),
                    relayURL: "https://relay.example.test",
                    workerTokenFingerprint: "token-fingerprint"
                )
            )
        }
    }

    private func withTemporaryStore(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("terminal-command-outbox.json"))
    }
}
