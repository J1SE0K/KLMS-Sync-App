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

    func testPublicLogRedactorMatchesSharedHostileCorpus() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/public_log_redaction_cases.json")
        let fixture = try JSONDecoder().decode(
            PublicLogRedactionFixture.self,
            from: Data(contentsOf: fixtureURL)
        )

        XCTAssertEqual(fixture.version, 3)
        for testCase in fixture.cases {
            let output = RelayPublicLogRedactor.redact(testCase.input)
            XCTAssertEqual(output, testCase.expected, testCase.id)
            XCTAssertEqual(RelayPublicLogRedactor.redact(output), output, "\(testCase.id) must be idempotent")
        }
    }

    func testPublicLogRedactorUsesLineAndUTF8ByteBounds() {
        let lines = (0..<45).map { String(format: "line-%02d", $0) }.joined(separator: "\n")
        let lineBounded = RelayPublicLogRedactor.redact(lines)
        XCTAssertEqual(lineBounded.components(separatedBy: "\n").count, 40)
        XCTAssertTrue(lineBounded.hasPrefix("line-05\n"))

        let byteBounded = RelayPublicLogRedactor.redact(
            String(repeating: "가", count: 10),
            maximumUTF8Bytes: 10
        )
        XCTAssertEqual(byteBounded, "...\n가가")
        XCTAssertLessThanOrEqual(byteBounded.utf8.count, 10)

        let deeplyNested = String(repeating: "[", count: 2_000)
            + "{\"token\":\"deep-secret\"}"
            + String(repeating: "]", count: 2_000)
        let deepOutput = RelayPublicLogRedactor.redact(deeplyNested)
        XCTAssertTrue(deepOutput.contains("[credential]"))
        XCTAssertFalse(deepOutput.contains("deep-secret"))
        XCTAssertLessThanOrEqual(deepOutput.utf8.count, 6_000)

        let malformedPEMEndFlood = String(
            repeating: "-----END PRIVATE KEY-----\n",
            count: 20_000
        ) + "tail"
        let malformedPEMEndFloodOutput = RelayPublicLogRedactor.redact(malformedPEMEndFlood)
        XCTAssertTrue(malformedPEMEndFloodOutput.hasSuffix("tail"))
        XCTAssertFalse(malformedPEMEndFloodOutput.localizedCaseInsensitiveContains("PRIVATE KEY"))
    }

    func testTerminalCommandPersistsAcrossStoreInstancesUntilAcknowledged() async throws {
        try await withTemporaryStore { url in
            let command = RemoteRunCommand(
                id: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!,
                kind: .fullSync,
                status: .completed,
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 200),
                lastExitCode: 0
            )
            let firstStore = RemoteCommandTerminalOutboxStore(url: url)

            try await firstStore.enqueue(
                command,
                relayURL: "https://relay.example.test/",
                workerTokenFingerprint: "token-fingerprint"
            )

            let reloadedStore = RemoteCommandTerminalOutboxStore(url: url)
            let pending = try await reloadedStore.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )
            XCTAssertEqual(pending.map(\.command.id), [command.id])
            XCTAssertEqual(pending.map(\.command.status), [.completed])

            try await reloadedStore.acknowledge(
                deliveryID: pending[0].deliveryID,
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )
            let remaining = try await reloadedStore.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testOutboxScopesTerminalResultToOriginalRelayCredential() async throws {
        try await withTemporaryStore { url in
            let command = RemoteRunCommand(kind: .filesSync, status: .failed)
            let store = RemoteCommandTerminalOutboxStore(url: url)
            try await store.enqueue(
                command,
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "original-token"
            )

            let replacementTokenEntries = try await store.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "replacement-token"
            )
            XCTAssertTrue(replacementTokenEntries.isEmpty)
            let otherRelayEntries = try await store.pending(
                relayURL: "https://other.example.test",
                workerTokenFingerprint: "original-token"
            )
            XCTAssertTrue(otherRelayEntries.isEmpty)
            let originalEntries = try await store.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "original-token"
            )
            XCTAssertEqual(originalEntries.count, 1)
        }
    }

    func testOutboxRejectsInFlightCommands() async throws {
        try await withTemporaryStore { url in
            let store = RemoteCommandTerminalOutboxStore(url: url)

            do {
                _ = try await store.enqueue(
                    RemoteRunCommand(kind: .doctor, status: .running),
                    relayURL: "https://relay.example.test",
                    workerTokenFingerprint: "token-fingerprint"
                )
                XCTFail("An in-flight command must not enter the terminal outbox")
            } catch {
                XCTAssertEqual(error as? RemoteCommandTerminalOutboxError, .commandIsNotTerminal)
            }
        }
    }

    func testMalformedOutboxIsQuarantinedAndRecreated() async throws {
        try await withTemporaryStore { url in
            let malformed = Data("{broken".utf8)
            try malformed.write(to: url)
            let store = RemoteCommandTerminalOutboxStore(url: url)

            let pending = try await store.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )
            XCTAssertTrue(pending.isEmpty)

            let quarantined = try quarantinedFiles(for: url)
            XCTAssertEqual(quarantined.count, 1)
            XCTAssertEqual(try Data(contentsOf: quarantined[0]), malformed)
            let rebuilt = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            XCTAssertEqual((rebuilt["version"] as? NSNumber)?.intValue, 2)
            XCTAssertEqual((rebuilt["entries"] as? [Any])?.count, 0)
        }
    }

    func testOutboxSalvagesValidEntriesAroundMalformedRecord() async throws {
        try await withTemporaryStore { url in
            let command = RemoteRunCommand(kind: .noticeSync, status: .completed)
            let store = RemoteCommandTerminalOutboxStore(url: url)
            try await store.enqueue(
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

            let pending = try await store.pending(
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

    func testOutboxDropsExpiredFutureAndExcessEntries() async throws {
        try await withTemporaryStore { url in
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

            let pending = try await RemoteCommandTerminalOutboxStore(url: url).pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )

            XCTAssertEqual(pending.count, 100)
            XCTAssertTrue(pending.allSatisfy { $0.enqueuedAt <= now.addingTimeInterval(5 * 60) })
            XCTAssertTrue(pending.allSatisfy { $0.enqueuedAt >= now.addingTimeInterval(-(30 * 24 * 60 * 60)) })
        }
    }

    func testVersion1MigratesToStableDeliveryID() async throws {
        try await withTemporaryStore { url in
            let command = RemoteRunCommand(kind: .coreSync, status: .completed)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let commandObject = try JSONSerialization.jsonObject(with: encoder.encode(command))
            let enqueuedAt = Date()
            let legacyDocument = try JSONSerialization.data(withJSONObject: [
                "version": 1,
                "entries": [[
                    "relayURL": "https://relay.example.test/",
                    "workerTokenFingerprint": "token-fingerprint",
                    "command": commandObject,
                    "enqueuedAt": ISO8601DateFormatter().string(from: enqueuedAt),
                ]],
            ])
            try legacyDocument.write(to: url)
            let store = RemoteCommandTerminalOutboxStore(url: url)

            let first = try await store.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )
            let second = try await store.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )

            XCTAssertEqual(first.count, 1)
            XCTAssertEqual(second.map(\.deliveryID), first.map(\.deliveryID))
            let migrated = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            XCTAssertEqual((migrated["version"] as? NSNumber)?.intValue, 2)
            let migratedEntry = try XCTUnwrap((migrated["entries"] as? [[String: Any]])?.first)
            XCTAssertEqual(migratedEntry["deliveryID"] as? String, first[0].deliveryID.uuidString)
        }
    }

    func testStaleAcknowledgementDoesNotDeleteReplacement() async throws {
        try await withTemporaryStore { url in
            let now = Date()
            let store = RemoteCommandTerminalOutboxStore(url: url)
            let commandID = UUID()
            let first = try await store.enqueue(
                RemoteRunCommand(id: commandID, kind: .fullSync, status: .completed),
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint",
                enqueuedAt: now
            )
            let replacement = try await store.enqueue(
                RemoteRunCommand(id: commandID, kind: .fullSync, status: .failed),
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint",
                enqueuedAt: now.addingTimeInterval(1)
            )

            try await store.acknowledge(
                deliveryID: first.entry.deliveryID,
                relayURL: first.entry.relayURL,
                workerTokenFingerprint: first.entry.workerTokenFingerprint
            )
            let pending = try await store.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )

            XCTAssertEqual(pending.map(\.deliveryID), [replacement.entry.deliveryID])
            XCTAssertEqual(pending.map(\.command.status), [.failed])
        }
    }

    func testConcurrentEnqueuesDoNotLoseEntries() async throws {
        try await withTemporaryStore { url in
            let store = RemoteCommandTerminalOutboxStore(url: url)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<40 {
                    group.addTask {
                        try await store.enqueue(
                            RemoteRunCommand(kind: .report, status: .completed),
                            relayURL: "https://relay.example.test",
                            workerTokenFingerprint: "token-fingerprint"
                        )
                    }
                }
                try await group.waitForAll()
            }
            let pending = try await store.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )
            XCTAssertEqual(pending.count, 40)
            XCTAssertEqual(Set(pending.map(\.command.id)).count, 40)
        }
    }

    func testPerIdentityLimitDoesNotEvictAnotherIdentity() async throws {
        try await withTemporaryStore { url in
            let now = Date()
            let policy = RemoteCommandTerminalOutboxPolicy(
                maximumEntriesPerIdentity: 3,
                maximumEntries: 4
            )
            let store = RemoteCommandTerminalOutboxStore(url: url, policy: policy, now: { now })
            try await store.enqueue(
                RemoteRunCommand(kind: .doctor, status: .completed),
                relayURL: "https://relay-b.example.test",
                workerTokenFingerprint: "token-b",
                enqueuedAt: now.addingTimeInterval(-10)
            )
            for offset in 0..<4 {
                try await store.enqueue(
                    RemoteRunCommand(kind: .report, status: .completed),
                    relayURL: "https://relay-a.example.test",
                    workerTokenFingerprint: "token-a",
                    enqueuedAt: now.addingTimeInterval(TimeInterval(offset))
                )
            }

            let identityA = try await store.pending(
                relayURL: "https://relay-a.example.test",
                workerTokenFingerprint: "token-a"
            )
            let identityB = try await store.pending(
                relayURL: "https://relay-b.example.test",
                workerTokenFingerprint: "token-b"
            )
            XCTAssertEqual(identityA.count, 3)
            XCTAssertEqual(identityB.count, 1)
        }
    }

    func testGlobalLimitEvictsOldestAcrossIdentities() async throws {
        try await withTemporaryStore { url in
            let now = Date()
            let policy = RemoteCommandTerminalOutboxPolicy(
                maximumEntriesPerIdentity: 10,
                maximumEntries: 3
            )
            let store = RemoteCommandTerminalOutboxStore(url: url, policy: policy, now: { now })
            var entriesByOffset: [Int: UUID] = [:]
            for (relay, fingerprint, offset) in [
                ("https://relay-a.example.test", "token-a", -4),
                ("https://relay-b.example.test", "token-b", -3),
                ("https://relay-b.example.test", "token-b", -2),
                ("https://relay-a.example.test", "token-a", -1),
            ] {
                let result = try await store.enqueue(
                    RemoteRunCommand(kind: .report, status: .completed),
                    relayURL: relay,
                    workerTokenFingerprint: fingerprint,
                    enqueuedAt: now.addingTimeInterval(TimeInterval(offset))
                )
                entriesByOffset[offset] = result.entry.deliveryID
            }
            let identityA = try await store.pending(
                relayURL: "https://relay-a.example.test",
                workerTokenFingerprint: "token-a"
            )
            let identityB = try await store.pending(
                relayURL: "https://relay-b.example.test",
                workerTokenFingerprint: "token-b"
            )
            let retained = Set((identityA + identityB).map(\.deliveryID))
            XCTAssertEqual(retained, Set([-3, -2, -1].compactMap { entriesByOffset[$0] }))
        }
    }

    func testOversizedDocumentAndRepeatedCorruptionHaveBoundedPrivateQuarantine() async throws {
        try await withTemporaryStore { url in
            let now = Date()
            let policy = RemoteCommandTerminalOutboxPolicy(
                maximumDocumentBytes: 128,
                maximumEncodedEntryBytes: 1_024,
                maximumEntriesPerIdentity: 10,
                maximumEntries: 10,
                maximumQuarantineFiles: 2,
                maximumQuarantineBytes: 32,
                maximumQuarantineTotalBytes: 64
            )
            let store = RemoteCommandTerminalOutboxStore(url: url, policy: policy, now: { now })
            for iteration in 0..<5 {
                try Data(repeating: UInt8(iteration), count: 4_096).write(to: url)
                let pending = try await store.pending(
                    relayURL: "https://relay.example.test",
                    workerTokenFingerprint: "token-fingerprint"
                )
                XCTAssertTrue(pending.isEmpty)
            }

            let quarantined = try quarantinedFiles(for: url)
            XCTAssertEqual(quarantined.count, 2)
            XCTAssertLessThanOrEqual(
                quarantined.reduce(0) { total, file in
                    total + (fileResourceSize(file) ?? Int.max)
                },
                64
            )
            for file in quarantined {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            }
            let canonicalAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((canonicalAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testOversizedEntryIsRejectedWithoutDamagingExistingEntry() async throws {
        try await withTemporaryStore { url in
            let policy = RemoteCommandTerminalOutboxPolicy(maximumEncodedEntryBytes: 1_024)
            let store = RemoteCommandTerminalOutboxStore(url: url, policy: policy)
            let existing = try await store.enqueue(
                RemoteRunCommand(kind: .verify, status: .completed),
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )
            var oversizedStatus = SanitizedRemoteStatus()
            oversizedStatus.phaseDetail = String(repeating: "x", count: 4_096)
            do {
                _ = try await store.enqueue(
                    RemoteRunCommand(kind: .report, status: .failed, summary: oversizedStatus),
                    relayURL: "https://relay.example.test",
                    workerTokenFingerprint: "token-fingerprint"
                )
                XCTFail("An oversized entry must be rejected")
            } catch {
                XCTAssertEqual(error as? RemoteCommandTerminalOutboxError, .entryTooLarge)
            }
            let pending = try await store.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )
            XCTAssertEqual(pending.map(\.deliveryID), [existing.entry.deliveryID])
        }
    }

    func testDocumentPruningUsesTheSameEncodingAsPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let referenceURL = directory.appendingPathComponent("reference.json")
        let constrainedURL = directory.appendingPathComponent("constrained.json")
        var status = SanitizedRemoteStatus()
        status.phaseDetail = String(repeating: "near-limit-status-", count: 24)
        let command = RemoteRunCommand(kind: .report, status: .failed, summary: status)

        _ = try await RemoteCommandTerminalOutboxStore(url: referenceURL).enqueue(
            command,
            relayURL: "https://relay.example.test",
            workerTokenFingerprint: "token-fingerprint"
        )
        let persistedBytes = try Data(contentsOf: referenceURL).count
        let policy = RemoteCommandTerminalOutboxPolicy(
            maximumDocumentBytes: persistedBytes - 1,
            maximumEncodedEntryBytes: persistedBytes * 2
        )
        let constrainedStore = RemoteCommandTerminalOutboxStore(
            url: constrainedURL,
            policy: policy
        )

        do {
            _ = try await constrainedStore.enqueue(
                command,
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )
            XCTFail("The newest entry must be rejected when its persisted document exceeds the limit")
        } catch {
            XCTAssertEqual(error as? RemoteCommandTerminalOutboxError, .entryCouldNotBeStored)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: constrainedURL.path))
    }

    func testUnknownDocumentVersionIsQuarantined() async throws {
        try await withTemporaryStore { url in
            let data = try JSONSerialization.data(withJSONObject: ["version": 999, "entries": []])
            try data.write(to: url)
            let store = RemoteCommandTerminalOutboxStore(url: url)
            let pending = try await store.pending(
                relayURL: "https://relay.example.test",
                workerTokenFingerprint: "token-fingerprint"
            )
            XCTAssertTrue(pending.isEmpty)
            XCTAssertEqual(try quarantinedFiles(for: url).count, 1)
            let rebuilt = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            XCTAssertEqual((rebuilt["version"] as? NSNumber)?.intValue, 2)
        }
    }

    private func quarantinedFiles(for url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".corrupt-") }
    }

    private func fileResourceSize(_ url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    private func withTemporaryStore(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory.appendingPathComponent("terminal-command-outbox.json"))
    }
}

private struct PublicLogRedactionFixture: Decodable {
    var version: Int
    var cases: [PublicLogRedactionCase]
}

private struct PublicLogRedactionCase: Decodable {
    var id: String
    var input: String
    var expected: String
}
