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
    }

    func testLocalRemoteRequestAndResponseRoundTrip() throws {
        let request = LocalRemoteRequest(
            token: "ABCD2345",
            action: .run,
            kind: .fullSync
        )
        let requestData = try JSONEncoder.klmsLocalRemote.encode(request)
        let decodedRequest = try JSONDecoder.klmsLocalRemote.decode(LocalRemoteRequest.self, from: requestData)

        XCTAssertEqual(decodedRequest, request)

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
        )
        let responseData = try JSONEncoder.klmsLocalRemote.encode(response)
        let decodedResponse = try JSONDecoder.klmsLocalRemote.decode(LocalRemoteResponse.self, from: responseData)

        XCTAssertEqual(decodedResponse, response)
    }
}
