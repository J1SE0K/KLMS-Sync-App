import XCTest
@testable import KLMSShared

final class RemoteCommandModelTests: XCTestCase {
    func testPendingCommandBecomesMacUnavailableForDisplayAfterTimeout() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let recent = RemoteRunCommand(
            kind: .fullSync,
            createdAt: now.addingTimeInterval(-30)
        )
        let expired = RemoteRunCommand(
            kind: .fullSync,
            createdAt: now.addingTimeInterval(-301)
        )

        XCTAssertEqual(
            recent.displayStatus(now: now, unavailableInterval: 300),
            .pending
        )
        XCTAssertEqual(
            expired.displayStatus(now: now, unavailableInterval: 300),
            .macUnavailable
        )
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
        XCTAssertFalse(RemoteCommandStatus.macUnavailable.isInFlight)

        XCTAssertFalse(RemoteCommandStatus.pending.isTerminal)
        XCTAssertFalse(RemoteCommandStatus.running.isTerminal)
        XCTAssertTrue(RemoteCommandStatus.completed.isTerminal)
        XCTAssertTrue(RemoteCommandStatus.failed.isTerminal)
        XCTAssertTrue(RemoteCommandStatus.macUnavailable.isTerminal)
    }

    func testSanitizedRemoteStatusUsesCountsPhaseAndLoginAttention() {
        let report = SyncReport(
            status: "ok",
            state: .init(assignments: 2, exams: 4, helpdesk: 1),
            notices: .init(total: 63, new: 7, updated: 0, ignored: 0),
            files: .init(total: 72, newFiles: 3, quarantine: 1, pruned: 0, archivePruned: 0)
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
        XCTAssertEqual(status.notices, 63)
        XCTAssertEqual(status.newFiles, 3)
        XCTAssertEqual(status.quarantine, 1)
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
        XCTAssertFalse(status.loginRequired)
        XCTAssertNil(status.authDigits)
        XCTAssertNil(status.authStatusMessage)
    }

    func testSanitizedRemoteStatusCarriesAuthCompletionMessage() throws {
        let status = SanitizedRemoteStatus(
            assignments: 1,
            exams: 2,
            phase: "running",
            authStatusMessage: "인증 완료됨"
        )

        let data = try JSONEncoder.klmsLocalRemote.encode(status)
        let decoded = try JSONDecoder.klmsLocalRemote.decode(SanitizedRemoteStatus.self, from: data)

        XCTAssertEqual(decoded.assignments, 1)
        XCTAssertEqual(decoded.exams, 2)
        XCTAssertEqual(decoded.phase, "running")
        XCTAssertFalse(decoded.loginRequired)
        XCTAssertNil(decoded.authDigits)
        XCTAssertEqual(decoded.authStatusMessage, "인증 완료됨")
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

    func testRemoteCommandKindMapsFromEngineCommands() {
        XCTAssertEqual(RemoteCommandKind(engineCommand: .fullSync), .fullSync)
        XCTAssertEqual(RemoteCommandKind(engineCommand: .coreSync), .coreSync)
        XCTAssertEqual(RemoteCommandKind(engineCommand: .noticeSync), .noticeSync)
        XCTAssertEqual(RemoteCommandKind(engineCommand: .filesSync), .filesSync)
        XCTAssertEqual(RemoteCommandKind(engineCommand: .doctor), .doctor)
        XCTAssertEqual(RemoteCommandKind(engineCommand: .report), .report)
        XCTAssertNil(RemoteCommandKind(engineCommand: .verify))
        XCTAssertNil(RemoteCommandKind(engineCommand: .v2BuildState))
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
