import XCTest
@testable import KLMSShared

final class RelayWorkerInboxQueueTests: XCTestCase {
    func testLatestStreamedInboxReplacesOlderUnconsumedState() {
        var queue = RelayWorkerInboxQueue()
        let first = inbox(updatedAt: "1")
        let latest = inbox(updatedAt: "2")

        queue.replace(with: first)
        queue.replace(with: latest)

        XCTAssertEqual(queue.take(), latest)
        XCTAssertFalse(queue.hasValue)
    }

    func testStreamedInboxNeverRequiresBootstrapFetch() {
        let decision = RelayWorkerInboxConsumptionPolicy.decision(
            hasStreamedInbox: true,
            replayedTerminalState: false
        )

        XCTAssertEqual(decision, .useStreamed)
        XCTAssertFalse(
            RelayWorkerInboxConsumptionPolicy.shouldScheduleNetworkFollowUp(after: decision)
        )
    }

    func testTerminalReplayInvalidatesOlderStreamedInbox() {
        let decision = RelayWorkerInboxConsumptionPolicy.decision(
            hasStreamedInbox: true,
            replayedTerminalState: true
        )

        XCTAssertEqual(decision, .awaitFreshStream)
        XCTAssertFalse(
            RelayWorkerInboxConsumptionPolicy.shouldScheduleNetworkFollowUp(after: decision)
        )
    }

    func testMissingStreamedInboxUsesOneBootstrapFetch() {
        let decision = RelayWorkerInboxConsumptionPolicy.decision(
            hasStreamedInbox: false,
            replayedTerminalState: true
        )

        XCTAssertEqual(decision, .fetchBootstrap)
        XCTAssertTrue(
            RelayWorkerInboxConsumptionPolicy.shouldScheduleNetworkFollowUp(after: decision)
        )
    }

    private func inbox(updatedAt: String) -> ServerRelayWorkerInbox {
        ServerRelayWorkerInbox(
            statusResponse: LocalRemoteResponse(updatedAt: updatedAt)
        )
    }
}
