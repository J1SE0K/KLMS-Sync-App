import XCTest
@testable import KLMSShared

private final class FakeLocalRemoteTokenKeychainBackend: LocalRemoteTokenKeychainBackend {
    struct Key: Hashable {
        var account: String
        var service: String
    }

    var storage: [Key: String]
    var failingSaveServices: Set<String>
    private(set) var deletedKeys: [Key]

    init(
        storage: [Key: String] = [:],
        failingSaveServices: Set<String> = []
    ) {
        self.storage = storage
        self.failingSaveServices = failingSaveServices
        deletedKeys = []
    }

    func load(account: String, service: String) -> String? {
        storage[Key(account: account, service: service)]
    }

    @discardableResult
    func save(_ token: String, account: String, service: String) -> Bool {
        guard !failingSaveServices.contains(service) else {
            return false
        }
        storage[Key(account: account, service: service)] = token
        return true
    }

    func delete(account: String, service: String) {
        let key = Key(account: account, service: service)
        deletedKeys.append(key)
        storage.removeValue(forKey: key)
    }
}

final class RemoteCommandModelTests: XCTestCase {
    func testPendingCommandBecomesMacUnavailableForDisplayAfterTimeout() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let recent = RemoteRunCommand(
            kind: .fullSync,
            createdAt: now.addingTimeInterval(-30)
        )
        let expired = RemoteRunCommand(
            kind: .fullSync,
            createdAt: now.addingTimeInterval(-901)
        )

        XCTAssertEqual(
            recent.displayStatus(now: now, unavailableInterval: 900),
            .pending
        )
        XCTAssertEqual(
            expired.displayStatus(now: now, unavailableInterval: 900),
            .macUnavailable
        )
    }

    func testDefaultMacUnavailableDisplayIntervalMatchesServerPendingTimeout() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let command = RemoteRunCommand(
            kind: .fullSync,
            createdAt: now.addingTimeInterval(-(15 * 60 + 1))
        )

        XCTAssertEqual(RemoteRunCommand.macUnavailableInterval, 60 * 60)
        XCTAssertEqual(command.displayStatus(now: now), .pending)
    }

    func testOnlyOldPendingCommandsAreStaleForExecution() {
        let now = Date(timeIntervalSinceReferenceDate: 2_000)
        let freshPending = RemoteRunCommand(
            kind: .noticeSync,
            status: .pending,
            createdAt: now.addingTimeInterval(-300)
        )
        let stalePending = RemoteRunCommand(
            kind: .noticeSync,
            status: .pending,
            createdAt: now.addingTimeInterval(-3_601)
        )
        let staleRunning = RemoteRunCommand(
            kind: .noticeSync,
            status: .running,
            createdAt: now.addingTimeInterval(-3_601)
        )
        let staleCompleted = RemoteRunCommand(
            kind: .noticeSync,
            status: .completed,
            createdAt: now.addingTimeInterval(-3_601)
        )

        XCTAssertFalse(freshPending.isStaleForExecution(now: now, staleInterval: 3_600))
        XCTAssertTrue(stalePending.isStaleForExecution(now: now, staleInterval: 3_600))
        XCTAssertFalse(staleRunning.isStaleForExecution(now: now, staleInterval: 3_600))
        XCTAssertFalse(staleCompleted.isStaleForExecution(now: now, staleInterval: 3_600))
    }

    func testRemoteCommandStatusFlightStates() {
        XCTAssertTrue(RemoteCommandStatus.pending.isInFlight)
        XCTAssertTrue(RemoteCommandStatus.running.isInFlight)
        XCTAssertFalse(RemoteCommandStatus.completed.isInFlight)
        XCTAssertFalse(RemoteCommandStatus.failed.isInFlight)
        XCTAssertFalse(RemoteCommandStatus.cancelled.isInFlight)
        XCTAssertFalse(RemoteCommandStatus.macUnavailable.isInFlight)

        XCTAssertFalse(RemoteCommandStatus.pending.isTerminal)
        XCTAssertFalse(RemoteCommandStatus.running.isTerminal)
        XCTAssertTrue(RemoteCommandStatus.completed.isTerminal)
        XCTAssertTrue(RemoteCommandStatus.failed.isTerminal)
        XCTAssertTrue(RemoteCommandStatus.cancelled.isTerminal)
        XCTAssertTrue(RemoteCommandStatus.macUnavailable.isTerminal)
    }

    func testRemoteRunCommandOptionsRoundTrip() throws {
        let command = RemoteRunCommand(
            kind: .noticeSync,
            options: RemoteRunOptions(updateNoticeNotes: false, dryRun: true)
        )

        let data = try JSONEncoder.klmsLocalRemote.encode(command)
        let decoded = try JSONDecoder.klmsLocalRemote.decode(RemoteRunCommand.self, from: data)

        XCTAssertFalse(decoded.options.updateNoticeNotes)
        XCTAssertTrue(decoded.options.dryRun)
    }

    func testServerRelayLogClearResponseDecodesCounts() throws {
        let data = Data("""
        {
          "clearedAt": "2026-06-06T12:34:56Z",
          "commands": 2,
          "itemActions": 3,
          "settingActions": 1,
          "fileAccessRequests": 4,
          "requestLogEntries": 5
        }
        """.utf8)

        let decoded = try JSONDecoder.klmsLocalRemote.decode(ServerRelayLogClearResponse.self, from: data)

        let expectedDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-06T12:34:56Z"))
        XCTAssertEqual(decoded.clearedAt.timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.commands, 2)
        XCTAssertEqual(decoded.itemActions, 3)
        XCTAssertEqual(decoded.settingActions, 1)
        XCTAssertEqual(decoded.fileAccessRequests, 4)
        XCTAssertEqual(decoded.requestLogEntries, 5)
    }

    func testServerRelayLogClearScopeCommandRawValue() {
        XCTAssertEqual(ServerRelayLogClearScope.command.rawValue, "command")
    }

    func testServerRelaySyncDataRunLogsRoundTripAndLegacyDefault() throws {
        let startedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-07T01:00:00Z"))
        let finishedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-07T01:00:05Z"))
        let syncData = ServerRelaySyncData(
            generatedAt: "2026-06-07T01:00:05Z",
            runLogs: [
                ServerRelayRunLog(
                    id: "run-1",
                    command: "full",
                    commandTitle: "전체 동기화",
                    status: "성공",
                    startedAt: startedAt,
                    finishedAt: finishedAt,
                    updatedAt: finishedAt,
                    duration: "5초",
                    exitCode: 0,
                    dryRun: false,
                    wasCancelled: false,
                    needsAttention: false,
                    outputTail: "정상 완료"
                )
            ]
        )

        let encoded = try JSONEncoder.klmsLocalRemote.encode(syncData)
        let decoded = try JSONDecoder.klmsLocalRemote.decode(ServerRelaySyncData.self, from: encoded)

        XCTAssertEqual(decoded.runLogs.count, 1)
        XCTAssertEqual(decoded.runLogs[0].commandTitle, "전체 동기화")
        XCTAssertEqual(decoded.runLogs[0].outputTail, "정상 완료")

        let legacy = try JSONDecoder.klmsLocalRemote.decode(
            ServerRelaySyncData.self,
            from: Data(#"{"generatedAt":"2026-06-07T01:00:05Z","items":[]}"#.utf8)
        )
        XCTAssertTrue(legacy.runLogs.isEmpty)
    }

    func testRemoteRunCommandOptionsDefaultToUpdatingNoticeNotesForLegacyPayloads() throws {
        let payload = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "kind": "fullSync",
          "status": "pending",
          "createdAt": "2026-06-01T00:00:00Z",
          "updatedAt": "2026-06-01T00:00:00Z",
          "loginRequired": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder.klmsLocalRemote.decode(RemoteRunCommand.self, from: payload)

        XCTAssertTrue(decoded.options.updateNoticeNotes)
        XCTAssertFalse(decoded.options.dryRun)
    }

    func testServerRelaySyncDataCarriesVerifySummary() throws {
        let syncData = ServerRelaySyncData(
            generatedAt: "2026-06-08T07:00:00Z",
            verifySummary: ServerRelayVerifySummary(
                status: "fail",
                updatedAt: "2026-06-08T07:01:00Z",
                checks: [
                    VerifyCheck(
                        name: "calendar_exam_count_matches_state",
                        status: "fail",
                        detail: "calendar=1 state=2"
                    )
                ]
            )
        )

        let encoded = try JSONEncoder.klmsLocalRemote.encode(syncData)
        let decoded = try JSONDecoder.klmsLocalRemote.decode(ServerRelaySyncData.self, from: encoded)

        XCTAssertEqual(decoded.verifySummary?.status, "fail")
        XCTAssertEqual(decoded.verifySummary?.issueChecks.first?.diagnosticTitle, "캘린더 시험 1개 누락")
    }

    func testSanitizedRemoteStatusUsesCountsPhaseAndLoginAttention() {
        let report = SyncReport(
            status: "ok",
            state: .init(assignments: 2, exams: 4, helpdesk: 1),
            notices: .init(total: 63, new: 7, updated: 2, ignored: 4),
            files: .init(total: 72, newFiles: 3, quarantine: 1, pruned: 5, archivePruned: 6),
            calendar: .init(created: 8, updated: 9, deleted: 10)
        )
        let doctor = DoctorResult(
            status: "fail",
            checks: [
                DoctorCheck(
                    name: "klms-login-cache",
                    status: "warn",
                    detail: "KLMS 로그인이 풀린 것 같아. 다시 로그인해 줘."
                )
            ]
        )
        let status = SanitizedRemoteStatus(
            snapshot: EngineSnapshot(syncReport: report, doctorResult: doctor),
            phase: "completed"
        )

        XCTAssertEqual(status.assignments, 2)
        XCTAssertEqual(status.exams, 4)
        XCTAssertEqual(status.helpDesk, 1)
        XCTAssertEqual(status.notices, 59)
        XCTAssertEqual(status.noticeNew, 7)
        XCTAssertEqual(status.noticeUpdated, 2)
        XCTAssertEqual(status.noticeIgnored, 4)
        XCTAssertEqual(status.fileTotal, 72)
        XCTAssertEqual(status.newFiles, 3)
        XCTAssertEqual(status.quarantine, 1)
        XCTAssertEqual(status.filePruned, 5)
        XCTAssertEqual(status.fileArchivePruned, 6)
        XCTAssertEqual(status.calendarCreated, 8)
        XCTAssertEqual(status.calendarUpdated, 9)
        XCTAssertEqual(status.calendarDeleted, 10)
        XCTAssertEqual(status.calendarChangeTotal, 27)
        XCTAssertEqual(status.fileCleanupTotal, 11)
        XCTAssertEqual(status.phase, "completed")
        XCTAssertTrue(status.loginRequired)
        XCTAssertNil(status.authDigits)
    }

    func testSanitizedRemoteStatusDecodesOlderPayloadWithoutLoginFields() throws {
        let data = Data(
            """
            {"assignments":1,"exams":2,"helpDesk":3,"notices":4,"newFiles":5,"quarantine":0,"phase":"idle"}
            """.utf8
        )

        let status = try JSONDecoder.klmsLocalRemote.decode(SanitizedRemoteStatus.self, from: data)

        XCTAssertEqual(status.assignments, 1)
        XCTAssertEqual(status.phase, "idle")
        XCTAssertNil(status.phaseDetail)
        XCTAssertEqual(status.noticeNew, 0)
        XCTAssertEqual(status.fileTotal, 0)
        XCTAssertEqual(status.calendarCreated, 0)
        XCTAssertFalse(status.loginRequired)
        XCTAssertNil(status.authDigits)
        XCTAssertNil(status.authStatusMessage)
    }

    func testSanitizedRemoteStatusCarriesAuthCompletionMessage() throws {
        let status = SanitizedRemoteStatus(
            assignments: 1,
            exams: 2,
            notices: 5,
            noticeNew: 1,
            noticeUpdated: 2,
            noticeIgnored: 3,
            fileTotal: 9,
            newFiles: 4,
            filePruned: 5,
            fileArchivePruned: 6,
            calendarCreated: 7,
            calendarUpdated: 8,
            calendarDeleted: 9,
            phase: "running",
            phaseDetail: "공지",
            authStatusMessage: "인증 완료됨"
        )

        let data = try JSONEncoder.klmsLocalRemote.encode(status)
        let decoded = try JSONDecoder.klmsLocalRemote.decode(SanitizedRemoteStatus.self, from: data)

        XCTAssertEqual(decoded.assignments, 1)
        XCTAssertEqual(decoded.exams, 2)
        XCTAssertEqual(decoded.notices, 5)
        XCTAssertEqual(decoded.noticeNew, 1)
        XCTAssertEqual(decoded.noticeUpdated, 2)
        XCTAssertEqual(decoded.noticeIgnored, 3)
        XCTAssertEqual(decoded.fileTotal, 9)
        XCTAssertEqual(decoded.newFiles, 4)
        XCTAssertEqual(decoded.filePruned, 5)
        XCTAssertEqual(decoded.fileArchivePruned, 6)
        XCTAssertEqual(decoded.calendarCreated, 7)
        XCTAssertEqual(decoded.calendarUpdated, 8)
        XCTAssertEqual(decoded.calendarDeleted, 9)
        XCTAssertEqual(decoded.phase, "running")
        XCTAssertEqual(decoded.phaseDetail, "공지")
        XCTAssertFalse(decoded.loginRequired)
        XCTAssertNil(decoded.authDigits)
        XCTAssertEqual(decoded.authStatusMessage, "인증 완료됨")
    }

    func testServerRelayFileAccessRequestRoundTrip() throws {
        let expiresAt = Date(timeIntervalSince1970: 4_102_444_800)
        let request = ServerRelayFileAccessRequest(
            itemID: "file-1",
            itemKind: "file",
            itemTitle: "기말 정리.pdf",
            status: .completed,
            message: "파일 링크 준비 완료",
            downloadURL: "https://relay.example/v1/file-access/id/download?ticket=abc",
            expiresAt: expiresAt,
            sizeBytes: 1_024
        )

        let data = try JSONEncoder.klmsLocalRemote.encode(request)
        let decoded = try JSONDecoder.klmsLocalRemote.decode(ServerRelayFileAccessRequest.self, from: data)

        XCTAssertEqual(decoded.itemID, "file-1")
        XCTAssertEqual(decoded.itemKind, "file")
        XCTAssertEqual(decoded.itemTitle, "기말 정리.pdf")
        XCTAssertEqual(decoded.status, .completed)
        XCTAssertEqual(decoded.message, "파일 링크 준비 완료")
        XCTAssertEqual(decoded.downloadURL, "https://relay.example/v1/file-access/id/download?ticket=abc")
        XCTAssertEqual(decoded.expiresAt, expiresAt)
        XCTAssertEqual(decoded.sizeBytes, 1_024)
        XCTAssertTrue(decoded.isDownloadAvailable)
    }

    func testServerRelayFileAccessRequestDecodesCloudflareFractionalDates() throws {
        let json = """
        {
          "id": "3E222DF2-8D38-47D8-83A2-C12ED5DC75D2",
          "itemID": "file-1",
          "itemKind": "file",
          "itemTitle": "기말 정리.pdf",
          "status": "completed",
          "createdAt": "2026-06-04T10:51:25.123Z",
          "updatedAt": "2026-06-04T10:51:26.456Z",
          "message": "파일 링크 준비 완료",
          "downloadURL": "https://relay.example/v1/file-access/id/download?ticket=abc",
          "expiresAt": "2099-06-04T11:51:26.789Z",
          "sizeBytes": 1024,
          "downloadCount": 0
        }
        """

        let decoded = try JSONDecoder.klmsLocalRemote.decode(
            ServerRelayFileAccessRequest.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.itemID, "file-1")
        XCTAssertEqual(decoded.status, .completed)
        XCTAssertEqual(decoded.itemTitle, "기말 정리.pdf")
        XCTAssertEqual(decoded.sizeBytes, 1_024)
        XCTAssertNotNil(decoded.expiresAt)
        XCTAssertTrue(decoded.isDownloadAvailable)
    }

    func testLocalRemoteConnectionInfoParsesCopiedMacConnectionText() {
        let text = """
        KLMS Sync iPhone 연결 정보
        Mac 주소: 10.249.54.97:18483
        토큰: 337TY82EXTX2
        """

        let info = LocalRemoteConnectionInfo.parse(hostText: text)

        XCTAssertEqual(info?.host, "10.249.54.97")
        XCTAssertEqual(info?.port, 18483)
        XCTAssertEqual(info?.token, "337TY82EXTX2")
    }

    func testLocalRemoteConnectionInfoParsesHostPortFieldAndSeparateToken() {
        let info = LocalRemoteConnectionInfo.parse(
            hostText: "10.249.54.97:18483",
            portText: "",
            tokenText: "337TY82EXTX2"
        )

        XCTAssertEqual(info?.host, "10.249.54.97")
        XCTAssertEqual(info?.port, 18483)
        XCTAssertEqual(info?.token, "337TY82EXTX2")
    }

    func testServerRelayConnectionInfoParsesCopiedConnectionText() {
        let text = """
        KLMS Sync 서버 연결 정보
        서버 URL: https://klms-sync.example.com/relay/
        클라이언트 토큰: client-token-123
        Mac worker 토큰: worker-token-456
        """

        let info = ServerRelayConnectionInfo.parse(urlText: text)

        XCTAssertEqual(info?.baseURL.absoluteString, "https://klms-sync.example.com/relay")
        XCTAssertEqual(info?.token, "client-token-123")
        XCTAssertEqual(
            ServerRelayConnectionInfo.labeledToken(in: text, labels: ServerRelayConnectionInfo.workerTokenLabels),
            "worker-token-456"
        )

        let legacyText = text.replacingOccurrences(of: "서버 URL:", with: "서버 주소:")
        let legacyInfo = ServerRelayConnectionInfo.parse(urlText: legacyText)
        XCTAssertEqual(legacyInfo?.baseURL.absoluteString, "https://klms-sync.example.com/relay")
        XCTAssertEqual(legacyInfo?.token, "client-token-123")
    }

    func testServerRelayConnectionInfoAllowsPublicHTTPSURLWithDigits() {
        let text = """
        KLMS Sync 서버 연결 정보
        서버 URL: https://klms-sync-relay.user12345.workers.dev
        클라이언트 토큰: client-token-123
        """

        let info = ServerRelayConnectionInfo.parse(urlText: text)

        XCTAssertEqual(info?.baseURL.absoluteString, "https://klms-sync-relay.user12345.workers.dev")
        XCTAssertEqual(info?.token, "client-token-123")
    }

    func testServerRelayCommandStoreRejectsPublicHTTPByDefault() {
        XCTAssertThrowsError(
            try ServerRelayCommandStore(urlText: "http://example.com", token: "token")
        ) { error in
            guard case ServerRelayClientError.invalidURL = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testServerRelayConnectionInfoRejectsPrivateURLsByDefault() {
        let text = """
        KLMS Sync 서버 연결 정보
        서버 URL: http://192.168.0.12:18484
        클라이언트 토큰: client-token-123
        """

        XCTAssertNil(ServerRelayConnectionInfo.parse(urlText: text))
        let blockedURLs = [
            "https://127.0.0.1:18484",
            "https://0.0.0.0",
            "https://10.20.30.40",
            "https://172.16.0.1",
            "https://172.31.255.255",
            "https://192.168.1.10",
            "https://169.254.1.10",
            "https://100.64.0.1",
            "https://100.127.255.255",
            "https://[::1]:18484",
            "https://[fc00::1]",
            "https://[fd12:3456::1]",
            "https://[fe80::1]",
            "https://[::ffff:192.168.0.10]",
            "https://macbook.local",
        ]
        for url in blockedURLs {
            XCTAssertNil(ServerRelayConnectionInfo.normalizedPublicRelayURL(url), url)
        }
        XCTAssertNotNil(ServerRelayConnectionInfo.normalizedPublicRelayURL("https://example.com"))
    }

    func testServerRelayCommandStoreRejectsPrivateURLByDefault() {
        XCTAssertThrowsError(
            try ServerRelayCommandStore(urlText: "https://127.0.0.1:18484", token: "token")
        ) { error in
            guard case ServerRelayClientError.invalidURL = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testServerRelayCommandStoreAllowsPrivateHTTPOnlyWhenExplicitlyEnabledForDevelopment() throws {
        let store = try ServerRelayCommandStore(
            urlText: "http://127.0.0.1:18484",
            token: "token",
            allowsInsecureHTTP: true
        )

        XCTAssertEqual(store.baseURL.absoluteString, "http://127.0.0.1:18484")
    }

    func testServerRelayUnauthorizedErrorExplainsTokenMismatch() throws {
        let error = ServerRelayClientError.serverRejected(401, "unauthorized")

        XCTAssertEqual(
            error.errorDescription,
            "서버 인증 실패: 서버 URL과 클라이언트/워커 토큰이 최신 값인지 확인해 주세요."
        )
    }

    func testLocalRemoteTokenStoreMigratesLegacyKeychainToken() throws {
        let account = "server-relay-ios"
        let currentService = LocalRemoteTokenStore.serviceForTesting
        let legacyService = try XCTUnwrap(LocalRemoteTokenStore.legacyServicesForTesting.first)
        let legacyKey = FakeLocalRemoteTokenKeychainBackend.Key(
            account: account,
            service: legacyService
        )
        let currentKey = FakeLocalRemoteTokenKeychainBackend.Key(
            account: account,
            service: currentService
        )
        let backend = FakeLocalRemoteTokenKeychainBackend(
            storage: [legacyKey: "  migrated-token  "]
        )

        let token = LocalRemoteTokenStore.load(account: account, backend: backend)

        XCTAssertEqual(token, "migrated-token")
        XCTAssertEqual(backend.storage[currentKey], "migrated-token")
        XCTAssertNil(backend.storage[legacyKey])
        XCTAssertTrue(backend.deletedKeys.contains(legacyKey))
    }

    func testLocalRemoteTokenStoreKeepsLegacyTokenWhenMigrationSaveFails() throws {
        let account = "server-relay-ios"
        let currentService = LocalRemoteTokenStore.serviceForTesting
        let legacyService = try XCTUnwrap(LocalRemoteTokenStore.legacyServicesForTesting.first)
        let legacyKey = FakeLocalRemoteTokenKeychainBackend.Key(
            account: account,
            service: legacyService
        )
        let currentKey = FakeLocalRemoteTokenKeychainBackend.Key(
            account: account,
            service: currentService
        )
        let backend = FakeLocalRemoteTokenKeychainBackend(
            storage: [legacyKey: "legacy-token"],
            failingSaveServices: [currentService]
        )

        let token = LocalRemoteTokenStore.load(account: account, backend: backend)

        XCTAssertEqual(token, "legacy-token")
        XCTAssertEqual(backend.storage[legacyKey], "legacy-token")
        XCTAssertNil(backend.storage[currentKey])
        XCTAssertFalse(backend.deletedKeys.contains(legacyKey))
    }

    func testServerRelaySyncDataRoundTripWithoutRawURLs() throws {
        let item = ServerRelaySyncItem(
            id: ServerRelaySyncItem.stableID(kind: "notice", parts: ["https://klms.example/private/notice"]),
            kind: "notice",
            course: "영미 단편소설",
            title: "기말고사 안내",
            timestamp: "2026-05-31T10:00:00Z",
            status: "new",
            detail: "시험 범위 공지",
            attachmentCount: 1,
            updatedAt: "2026-05-31T10:01:00Z",
            isRead: true,
            isImportant: true
        )
        let dryRun = DryRunReport(scope: "notice", status: "ok", wouldCreate: 1)
        let calendarChange = CalendarChange(
            action: "created",
            calendar: "KLMS 시험",
            bucket: "exam",
            title: "기말고사",
            course: "영미 단편소설",
            startAt: "2026-06-12 10:00",
            changes: ["시간 생성"]
        )
        let setting = ServerRelaySetting(
            key: EnvKnownKey.fileRefreshMode.rawValue,
            title: "파일 탐색 모드",
            value: "auto",
            valueKind: .choice,
            options: ["auto", "quick"]
        )
        let data = ServerRelaySyncData(
            generatedAt: "2026-05-31T10:01:00Z",
            items: [item],
            dryRunReports: [dryRun],
            calendarChanges: [calendarChange],
            settings: [setting]
        )

        let encoded = try JSONEncoder.klmsLocalRemote.encode(data)
        let rawJSON = String(data: encoded, encoding: .utf8) ?? ""
        let decoded = try JSONDecoder.klmsLocalRemote.decode(ServerRelaySyncData.self, from: encoded)

        XCTAssertEqual(decoded.generatedAt, "2026-05-31T10:01:00Z")
        XCTAssertEqual(decoded.items, [item])
        XCTAssertTrue(decoded.items[0].isRead)
        XCTAssertTrue(decoded.items[0].isImportant)
        XCTAssertFalse(decoded.items[0].isHidden)
        XCTAssertEqual(decoded.dryRunReports, [dryRun])
        XCTAssertEqual(decoded.calendarChanges, [calendarChange])
        XCTAssertEqual(decoded.settings, [setting])
        XCTAssertFalse(rawJSON.contains("https://klms.example/private/notice"))
    }

    func testServerRelaySyncItemDecodesOlderPayloadWithoutInteractionFlags() throws {
        let payload = """
        {
          "id": "notice-1",
          "kind": "notice",
          "course": "영미 단편소설",
          "title": "기말고사 안내",
          "timestamp": "2026-05-31T10:00:00Z",
          "status": "new",
          "detail": "시험 범위 공지",
          "attachmentCount": 1,
          "updatedAt": "2026-05-31T10:01:00Z"
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder.klmsLocalRemote.decode(ServerRelaySyncItem.self, from: payload)

        XCTAssertFalse(item.isRead)
        XCTAssertFalse(item.isImportant)
        XCTAssertFalse(item.isHidden)
    }

    func testRemoteCommandKindMapsFromEngineCommands() {
        XCTAssertEqual(RemoteCommandKind(engineCommand: .fullSync), .fullSync)
        XCTAssertEqual(RemoteCommandKind(engineCommand: .coreSync), .coreSync)
        XCTAssertEqual(RemoteCommandKind(engineCommand: .noticeSync), .noticeSync)
        XCTAssertEqual(RemoteCommandKind(engineCommand: .filesSync), .filesSync)
        XCTAssertEqual(RemoteCommandKind(engineCommand: .verify), .verify)
        XCTAssertEqual(RemoteCommandKind(engineCommand: .doctor), .doctor)
        XCTAssertEqual(RemoteCommandKind(engineCommand: .report), .report)
        XCTAssertEqual(RemoteCommandKind(engineCommand: .v2BuildState), .v2BuildState)
    }

    func testLocalRemoteCancelRequestIsSignedAndAuthorized() throws {
        let request = LocalRemoteRequest(
            token: "ABCD2345",
            action: .cancel,
            nonce: "cancel-nonce-1",
            issuedAt: Date(timeIntervalSince1970: 1_779_788_400)
        )
        let requestData = try JSONEncoder.klmsLocalRemote.encode(request)
        let decodedRequest = try JSONDecoder.klmsLocalRemote.decode(LocalRemoteRequest.self, from: requestData)

        XCTAssertEqual(decodedRequest.action, .cancel)
        XCTAssertNil(decodedRequest.kind)
        XCTAssertTrue(decodedRequest.isAuthorized(token: "ABCD2345", now: Date(timeIntervalSince1970: 1_779_788_401)))
        XCTAssertFalse(decodedRequest.isAuthorized(token: "WRONG2345", now: Date(timeIntervalSince1970: 1_779_788_401)))
        XCTAssertFalse(String(data: requestData, encoding: .utf8)?.contains("ABCD2345") ?? true)
    }

    func testLocalRemoteRequestAndResponseRoundTrip() throws {
        let request = LocalRemoteRequest(
            token: "ABCD2345",
            action: .run,
            kind: .fullSync,
            nonce: "nonce-1",
            issuedAt: Date(timeIntervalSince1970: 1_779_788_400)
        )
        let requestData = try JSONEncoder.klmsLocalRemote.encode(request)
        let decodedRequest = try JSONDecoder.klmsLocalRemote.decode(LocalRemoteRequest.self, from: requestData)

        XCTAssertEqual(decodedRequest, request)
        XCTAssertTrue(decodedRequest.isAuthorized(token: "ABCD2345", now: Date(timeIntervalSince1970: 1_779_788_410)))
        XCTAssertFalse(decodedRequest.isAuthorized(token: "WRONG2345", now: Date(timeIntervalSince1970: 1_779_788_410)))
        XCTAssertFalse(decodedRequest.isAuthorized(token: "ABCD2345", now: Date(timeIntervalSince1970: 1_779_788_600)))
        XCTAssertFalse(String(data: requestData, encoding: .utf8)?.contains("ABCD2345") ?? true)

        let command = RemoteRunCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            kind: .noticeSync,
            status: .running,
            createdAt: Date(timeIntervalSince1970: 1_779_788_400),
            updatedAt: Date(timeIntervalSince1970: 1_779_788_401),
            summary: SanitizedRemoteStatus(assignments: 1, exams: 2, helpDesk: 3, notices: 4, newFiles: 5, quarantine: 0, phase: "running")
        )
        let response = LocalRemoteResponse(
            message: "공지 동기화 실행을 시작했습니다.",
            status: command.summary,
            latestCommand: command,
            running: true
        ).signed(
            token: "ABCD2345",
            request: request,
            issuedAt: Date(timeIntervalSince1970: 1_779_788_411)
        )
        let responseData = try JSONEncoder.klmsLocalRemote.encode(response)
        let decodedResponse = try JSONDecoder.klmsLocalRemote.decode(LocalRemoteResponse.self, from: responseData)

        XCTAssertEqual(decodedResponse, response)
        XCTAssertTrue(decodedResponse.isAuthorized(
            token: "ABCD2345",
            request: request,
            now: Date(timeIntervalSince1970: 1_779_788_412)
        ))
        XCTAssertFalse(decodedResponse.isAuthorized(
            token: "WRONG2345",
            request: request,
            now: Date(timeIntervalSince1970: 1_779_788_412)
        ))
        XCTAssertFalse(String(data: responseData, encoding: .utf8)?.contains("ABCD2345") ?? true)
    }

    func testLocalRemoteResponseSignatureRejectsTamperingAndReplayBinding() {
        let request = LocalRemoteRequest(
            token: "ABCD2345",
            action: .status,
            nonce: "nonce-1",
            issuedAt: Date(timeIntervalSince1970: 1_779_788_400)
        )
        let response = LocalRemoteResponse(
            message: "대기 중",
            status: SanitizedRemoteStatus(assignments: 1, exams: 2, phase: "idle")
        ).signed(
            token: "ABCD2345",
            request: request,
            issuedAt: Date(timeIntervalSince1970: 1_779_788_401)
        )

        XCTAssertTrue(response.isAuthorized(
            token: "ABCD2345",
            request: request,
            now: Date(timeIntervalSince1970: 1_779_788_402)
        ))

        var tampered = response
        tampered.status.assignments = 99
        XCTAssertFalse(tampered.isAuthorized(
            token: "ABCD2345",
            request: request,
            now: Date(timeIntervalSince1970: 1_779_788_402)
        ))

        let replayedAgainstDifferentRequest = LocalRemoteRequest(
            token: "ABCD2345",
            action: .status,
            nonce: "nonce-2",
            issuedAt: Date(timeIntervalSince1970: 1_779_788_400)
        )
        XCTAssertFalse(response.isAuthorized(
            token: "ABCD2345",
            request: replayedAgainstDifferentRequest,
            now: Date(timeIntervalSince1970: 1_779_788_402)
        ))

        XCTAssertFalse(response.isAuthorized(
            token: "ABCD2345",
            request: request,
            now: Date(timeIntervalSince1970: 1_779_788_700)
        ))
    }

    func testLocalRemoteResponseDecodesOlderUnsignedPayloadButDoesNotAuthorize() throws {
        let request = LocalRemoteRequest(
            token: "ABCD2345",
            action: .status,
            nonce: "nonce-1",
            issuedAt: Date(timeIntervalSince1970: 1_779_788_400)
        )
        let data = Data(
            """
            {"ok":true,"message":"대기 중","status":{"assignments":1,"exams":2,"helpDesk":0,"notices":0,"newFiles":0,"quarantine":0,"phase":"idle","loginRequired":false},"running":false}
            """.utf8
        )

        let response = try JSONDecoder.klmsLocalRemote.decode(LocalRemoteResponse.self, from: data)

        XCTAssertEqual(response.message, "대기 중")
        XCTAssertFalse(response.isAuthorized(
            token: "ABCD2345",
            request: request,
            now: Date(timeIntervalSince1970: 1_779_788_402)
        ))
    }
}
