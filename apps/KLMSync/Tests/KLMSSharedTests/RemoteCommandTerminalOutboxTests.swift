import Foundation
import XCTest
@testable import KLMSShared

final class RemoteCommandTerminalOutboxTests: XCTestCase {
    func testPublicLogRedactorRemovesCredentialsURLsAndCrossPlatformPaths() {
        let input = """
        Authorization: Bearer relay-secret-value
        worker_token=another-secret
        /private/tmp/KLMS secret/output.log
        /Volumes/External/User Data/file.pdf
        /home/student/private.txt
        C:\\Users\\student\\AppData\\Local\\secret.txt
        \\\\server\\share\\private.txt
        https://relay.example/v1/status?token=query-secret
        student@example.test
        정상 단계 완료
        """

        let output = RelayPublicLogRedactor.redact(input)

        XCTAssertFalse(output.localizedCaseInsensitiveContains("relay-secret-value"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("another-secret"))
        XCTAssertFalse(output.contains("/private/tmp"))
        XCTAssertFalse(output.contains("/Volumes"))
        XCTAssertFalse(output.contains("/home"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("C:\\Users"))
        XCTAssertFalse(output.contains("\\\\server"))
        XCTAssertFalse(output.contains("query-secret"))
        XCTAssertFalse(output.contains("student@example.test"))
        XCTAssertTrue(output.contains("[credential]"))
        XCTAssertTrue(output.contains("[local-path]"))
        XCTAssertTrue(output.contains("[URL]"))
        XCTAssertTrue(output.contains("[email]"))
        XCTAssertTrue(output.contains("정상 단계 완료"))
    }

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
            XCTAssertEqual(pending.map(\.command.id), [command.id])
            XCTAssertEqual(pending.map(\.command.status), [.completed])

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

    func testMalformedOutboxIsQuarantinedAndRecreated() throws {
        try withTemporaryStore { url in
            let malformed = Data("{broken".utf8)
            try malformed.write(to: url)
            let store = RemoteCommandTerminalOutboxStore(url: url)

            XCTAssertTrue(try store.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            ).isEmpty)

            let quarantined = try quarantinedFiles(for: url)
            XCTAssertEqual(quarantined.count, 1)
            XCTAssertEqual(try Data(contentsOf: quarantined[0]), malformed)
            let rebuilt = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            XCTAssertEqual((rebuilt["version"] as? NSNumber)?.intValue, 1)
            XCTAssertEqual((rebuilt["entries"] as? [Any])?.count, 0)
        }
    }

    func testOutboxSalvagesValidEntriesAroundMalformedRecord() throws {
        try withTemporaryStore { url in
            let command = RemoteRunCommand(kind: .noticeSync, status: .completed)
            let store = RemoteCommandTerminalOutboxStore(url: url)
            try store.enqueue(
                command,
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )
            var document = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            var entries = try XCTUnwrap(document["entries"] as? [Any])
            entries.append(["relayURL": 7, "workerTokenFingerprint": false])
            document["entries"] = entries
            let mixed = try JSONSerialization.data(withJSONObject: document)
            try mixed.write(to: url)

            let pending = try store.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )

            XCTAssertEqual(pending.map(\.command.id), [command.id])
            XCTAssertEqual(pending.map(\.command.status), [.completed])
            XCTAssertEqual(try quarantinedFiles(for: url).count, 1)
            let rebuilt = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            XCTAssertEqual((rebuilt["entries"] as? [Any])?.count, 1)
        }
    }

    func testOutboxDropsExpiredFutureAndExcessEntries() throws {
        try withTemporaryStore { url in
            let now = Date()
            var entries = (0..<300).map { index in
                RemoteCommandTerminalOutboxEntry(
                    relayURL: "https://relay.example.test",
                    workerTokenFingerprint: "token-fingerprint",
                    command: RemoteRunCommand(kind: .report, status: .completed),
                    enqueuedAt: now.addingTimeInterval(TimeInterval(index - 300))
                )
            }
            entries.append(RemoteCommandTerminalOutboxEntry(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint",
                command: RemoteRunCommand(kind: .report, status: .completed),
                enqueuedAt: now.addingTimeInterval(-(31 * 24 * 60 * 60))
            ))
            entries.append(RemoteCommandTerminalOutboxEntry(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint",
                command: RemoteRunCommand(kind: .report, status: .completed),
                enqueuedAt: now.addingTimeInterval(10 * 60)
            ))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let encodedEntries = try JSONSerialization.jsonObject(with: encoder.encode(entries))
            let document = try JSONSerialization.data(withJSONObject: [
                "version": 1,
                "entries": encodedEntries,
            ])
            try document.write(to: url)

            let pending = try RemoteCommandTerminalOutboxStore(url: url).pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )

            XCTAssertEqual(pending.count, 256)
            XCTAssertTrue(pending.allSatisfy { $0.enqueuedAt <= now.addingTimeInterval(5 * 60) })
            XCTAssertTrue(pending.allSatisfy { $0.enqueuedAt >= now.addingTimeInterval(-(30 * 24 * 60 * 60)) })
        }
    }

    private func quarantinedFiles(for url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".corrupt-") }
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
