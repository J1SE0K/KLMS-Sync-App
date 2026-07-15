import Foundation
import XCTest

final class RealtimePreviewIntegrationTests: XCTestCase {
    func testMacExecutionAndHandshakePoliciesAreWiredAtSuspensionBoundaries() throws {
        let source = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift"),
            encoding: .utf8
        )
        let connectionReset = try sourceSlice(
            source,
            from: "private func resetServerRelaySessionForConnectionChange()",
            to: "func copyServerRelayConnectionInfo()"
        )
        let localRun = try sourceSlice(
            source,
            from: "private func run(\n        _ command: KLMSEngineCommand",
            to: "func cancelRunningCommand("
        )
        let eventStream = try sourceSlice(
            source,
            from: "private func runServerRelayEventStream(key: String)",
            to: "private func scheduleServerRelayImmediateFollowUp()"
        )
        let workerInbox = try sourceSlice(
            source,
            from: "func processServerRelayCommands(",
            to: "private func processServerRelayCancelRequest("
        )

        XCTAssertFalse(
            connectionReset.contains("pendingRunCancellation"),
            "A relay account/connection reset must not mutate an active run's cancellation intent."
        )
        XCTAssertTrue(localRun.contains("pendingRunCancellation.isRequested(for: commandIdentity)"))
        XCTAssertTrue(localRun.contains("pendingRunCancellation.clear(ifMatching: commandIdentity)"))

        let remoteClaim = try XCTUnwrap(workerInbox.range(of: "guard relayExecutionGate.claim(executionOwner)")?.lowerBound)
        let remoteRunningMutation = try XCTUnwrap(workerInbox.range(of: "running.status = .running")?.lowerBound)
        let remoteServerMutation = try XCTUnwrap(workerInbox.range(of: "try await store.update(running)")?.lowerBound)
        XCTAssertLessThan(remoteClaim, remoteRunningMutation)
        XCTAssertLessThan(remoteClaim, remoteServerMutation)
        XCTAssertTrue(workerInbox.contains("preclaimedExecutionOwner: executionOwner"))
        XCTAssertTrue(workerInbox.contains("publishServerRelayWorkerCompletionIfCurrent("))
        XCTAssertFalse(workerInbox.contains("running: false"))

        let transportStart = try XCTUnwrap(eventStream.range(of: "task.resume()")?.lowerBound)
        let helloTimeoutStart = try XCTUnwrap(eventStream.range(of: "let helloTimeout = Task")?.lowerBound)
        let firstFrameReceive = try XCTUnwrap(eventStream.range(of: "let helloMessage = try await task.receive()")?.lowerBound)
        let helloAcceptance = try XCTUnwrap(eventStream.range(of: "handshake.observeFirstFrame(hello) == .accepted")?.lowerBound)
        let connectedMessage = try XCTUnwrap(eventStream.range(of: "serverRelayStatusMessage = \"서버 실시간 연결됨\"")?.lowerBound)
        let heartbeatStart = try XCTUnwrap(eventStream.range(of: "let heartbeat = Task")?.lowerBound)
        let backoffReset = try XCTUnwrap(
            eventStream.range(
                of: "reconnectAttempt = 0",
                range: helloAcceptance..<eventStream.endIndex
            )?.lowerBound
        )
        XCTAssertLessThan(transportStart, firstFrameReceive)
        XCTAssertLessThan(transportStart, helloTimeoutStart)
        XCTAssertLessThan(helloTimeoutStart, firstFrameReceive)
        XCTAssertLessThan(firstFrameReceive, helloAcceptance)
        XCTAssertLessThan(helloAcceptance, connectedMessage)
        XCTAssertLessThan(helloAcceptance, backoffReset)
        XCTAssertLessThan(helloAcceptance, heartbeatStart)
        XCTAssertLessThan(backoffReset, heartbeatStart)
    }

    func testMacWorkerPreviewRunsDuringDashboardFetchAndInvalidatesOlderSnapshot() throws {
        let source = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/KLMSMac/KLMSMacModel.swift"),
            encoding: .utf8
        )
        let eventHandler = try sourceSlice(
            source,
            from: "private func handleServerRelayEvent(",
            to: "private func scheduleServerRelayEventBatch("
        )
        let eventBatch = try sourceSlice(
            source,
            from: "private func scheduleServerRelayEventBatch(",
            to: "private func finishServerRelayEventBatch("
        )
        let workerPreview = try sourceSlice(
            source,
            from: "private func scheduleServerRelayWorkerPreview(",
            to: "private func scheduleServerRelayEventBatch("
        )
        let dashboardPreview = try sourceSlice(
            source,
            from: "private func scheduleServerRelayDashboardPreview(",
            to: "private func scheduleServerRelayEventBatch("
        )
        let workerInbox = try sourceSlice(
            source,
            from: "func processServerRelayCommands(",
            to: "private func processServerRelayCancelRequest("
        )
        let dashboardRefresh = try sourceSlice(
            source,
            from: "func refreshServerRelayDashboardNow(",
            to: "private static func isServerRelayAuthorizationError("
        )

        XCTAssertTrue(eventHandler.contains("RelayRealtimePreviewPolicy.shouldStartWorkerPreview("))
        XCTAssertTrue(eventHandler.contains("serverRelayEventBatchIsRefreshingWorker"))
        XCTAssertTrue(eventHandler.contains("activeServerRelayCommandCheckOperationID != nil"))
        XCTAssertTrue(eventHandler.contains("scheduleServerRelayWorkerStatePreview(generation: generation)"))
        XCTAssertTrue(eventHandler.contains("scheduleServerRelayWorkerPreview(generation: generation)"))
        XCTAssertTrue(eventHandler.contains("RelayRealtimePreviewPolicy.shouldStartSnapshotPreview("))
        XCTAssertTrue(eventHandler.contains("serverRelayDashboardPreviewTask != nil"))
        XCTAssertTrue(eventHandler.contains("requiresSnapshot: requiresSnapshot"))
        XCTAssertTrue(eventHandler.contains("scheduleServerRelayDashboardPreview(generation: generation)"))
        XCTAssertTrue(eventBatch.contains("serverRelayEventBatchIsRefreshingDashboard = true"))
        XCTAssertTrue(eventBatch.contains("await self.refreshServerRelayDashboardNow("))
        XCTAssertTrue(eventBatch.contains("serverRelayEventBatchOperationID == operationID"))
        XCTAssertTrue(eventBatch.contains("serverRelayEventBatchIsRefreshingDashboard = false"))

        XCTAssertTrue(workerPreview.contains("let operationID = serverRelayWorkerPreviewOperationID"))
        XCTAssertTrue(workerPreview.contains("let sessionGeneration = serverRelaySessionGeneration"))
        XCTAssertTrue(workerPreview.contains("isServerRelayWorkerPreviewOwner("))
        XCTAssertTrue(workerPreview.contains("await self.processServerRelayCommands("))

        XCTAssertTrue(dashboardPreview.contains("serverRelayDashboardPreviewTask?.cancel()"))
        XCTAssertTrue(dashboardPreview.contains("serverRelayDashboardPreviewOperationID &+= 1"))
        XCTAssertTrue(dashboardPreview.contains("serverRelaySyncDataFetchOperationID &+= 1"))
        XCTAssertTrue(dashboardPreview.contains("isServerRelayDashboardPreviewOwner("))
        XCTAssertTrue(dashboardPreview.contains("await self.refreshServerRelayDashboardNow("))
        XCTAssertTrue(workerPreview.contains("serverRelayWorkerStatePreviewTask?.cancel()"))
        XCTAssertTrue(workerPreview.contains("fetchWorkerInbox(since: nil, waitSeconds: 0)"))
        XCTAssertTrue(workerPreview.contains("serverRelayRecentRequestLog = requestLog"))
        XCTAssertTrue(workerPreview.contains("serverRelayRecentFileAccessRequests = fileRequests"))
        XCTAssertTrue(workerPreview.contains("applyServerRelaySharedSettings(inbox.sharedSettings, merge: false)"))
        XCTAssertFalse(workerPreview.contains("serverRelayLastInboxUpdatedAt = inbox.statusResponse.updatedAt"))

        XCTAssertTrue(eventBatch.contains("serverRelayEventBatchIsRefreshingWorker = true"))
        XCTAssertTrue(eventBatch.contains("serverRelayEventBatchIsRefreshingWorker = false"))

        XCTAssertTrue(workerInbox.contains("var didApplyInboxState = false"))
        XCTAssertTrue(workerInbox.contains("if didApplyInboxState {"))
        XCTAssertTrue(workerInbox.contains("serverRelaySnapshotMutationEpoch &+= 1"))
        XCTAssertTrue(dashboardRefresh.contains("fetchMutationEpoch: mutationEpoch"))
        XCTAssertTrue(dashboardRefresh.contains("currentMutationEpoch: serverRelaySnapshotMutationEpoch"))
        XCTAssertTrue(dashboardRefresh.contains("case .invalidated:"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceSlice(
        _ source: String,
        from start: String,
        to end: String
    ) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(
            source.range(of: end, range: startRange.upperBound..<source.endIndex)
        )
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
