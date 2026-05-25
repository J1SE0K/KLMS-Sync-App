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

    func testSanitizedRemoteStatusUsesOnlyCountsAndPhase() {
        let report = SyncReport(
            status: "ok",
            state: .init(assignments: 2, exams: 4, helpdesk: 1),
            notices: .init(total: 63, new: 7, updated: 0, ignored: 0),
            files: .init(total: 72, newFiles: 3, quarantine: 1, pruned: 0, archivePruned: 0)
        )
        let status = SanitizedRemoteStatus(
            snapshot: EngineSnapshot(syncReport: report),
            phase: "completed"
        )

        XCTAssertEqual(status.assignments, 2)
        XCTAssertEqual(status.exams, 4)
        XCTAssertEqual(status.helpDesk, 1)
        XCTAssertEqual(status.notices, 63)
        XCTAssertEqual(status.newFiles, 3)
        XCTAssertEqual(status.quarantine, 1)
        XCTAssertEqual(status.phase, "completed")
    }
}
