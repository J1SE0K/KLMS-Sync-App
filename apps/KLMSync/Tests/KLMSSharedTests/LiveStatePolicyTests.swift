import XCTest
@testable import KLMSShared

final class LiveStatePolicyTests: XCTestCase {
    func testPrelaunchCancellationSurvivesRelayConnectionResetForItsRunOnly() {
        var cancellation = RunCancellationIntent<String>()
        var relaySession = RelaySessionGeneration()
        let cancelledRun = "run-41"

        cancellation.request(for: cancelledRun)
        _ = relaySession.reset()

        XCTAssertTrue(
            cancellation.isRequested(for: cancelledRun),
            "Changing relay connection state must not erase a cancellation that belongs to an active local run."
        )
        cancellation.clear(ifMatching: "run-42")
        XCTAssertTrue(cancellation.isRequested(for: cancelledRun))
        cancellation.clear(ifMatching: cancelledRun)
        XCTAssertFalse(cancellation.isRequested(for: cancelledRun))
    }

    func testLocalRunClaimWinsWhenItStartsDuringWorkerInboxAwait() {
        var gate = RelayExecutionGate()
        let remoteCheckerObservedIdleBeforeAwait = !gate.isClaimed
        XCTAssertTrue(remoteCheckerObservedIdleBeforeAwait)

        XCTAssertTrue(gate.claim(.localRun(7)))
        XCTAssertFalse(
            gate.claim(.remoteCommand(UUID())),
            "The remote row must remain pending instead of being marked running after a local run claims the slot."
        )
        XCTAssertEqual(gate.owner, .localRun(7))
    }

    func testSideActionCompletionCannotClearAnotherRunsPublishedOwnership() {
        var gate = RelayExecutionGate()
        XCTAssertTrue(gate.claim(.localRun(9)))

        // File/settings/item side-actions do not own the command slot. Their
        // completion publisher reads this current state instead of supplying a
        // hard-coded false value.
        XCTAssertTrue(gate.isClaimed)
        XCTAssertEqual(gate.owner, .localRun(9))
        gate.release(ifOwnedBy: .remoteCommand(UUID()))
        XCTAssertTrue(gate.isClaimed, "Only the execution owner may clear the published running state.")
        gate.release(ifOwnedBy: .localRun(9))
        XCTAssertFalse(gate.isClaimed)
    }

    func testRelayHandshakeWaitsForValidHelloBeforeResettingBackoff() {
        var delayedHandshake = RelayWebSocketHandshakeState()
        var reconnectAttempt = 3

        XCTAssertTrue(delayedHandshake.isAwaitingHello)
        XCTAssertFalse(delayedHandshake.isConnected)
        XCTAssertEqual(reconnectAttempt, 3, "A delayed first frame must not look connected or reset backoff.")

        XCTAssertEqual(
            delayedHandshake.observeFirstFrame(
                RelayEventEnvelope(type: .changed, revision: 10)
            ),
            .rejected
        )
        XCTAssertFalse(delayedHandshake.isConnected)
        XCTAssertEqual(reconnectAttempt, 3)

        var validHandshake = RelayWebSocketHandshakeState()
        XCTAssertEqual(
            validHandshake.observeFirstFrame(
                RelayEventEnvelope(version: 1, type: .hello, revision: 10)
            ),
            .accepted
        )
        if validHandshake.isConnected {
            reconnectAttempt = 0
        }
        XCTAssertEqual(reconnectAttempt, 0)
    }

    func testSyncActionIntentRemainsTheTapTimeIntentAcrossStateChanges() {
        let runIntent = SyncActionIntent.capture(isRunning: false)
        let cancelIntent = SyncActionIntent.capture(isRunning: true)

        XCTAssertEqual(runIntent, .run, "A run tap must not turn into cancellation if work starts before its Task executes.")
        XCTAssertEqual(cancelIntent, .cancel, "A cancel tap must not turn into a new run if work finishes before its Task executes.")

        let tappedCommandID = UUID()
        let replacementCommandID = UUID()
        let tappedCommand = RemoteRunCommand(
            id: tappedCommandID,
            kind: .fullSync,
            status: .running
        )
        let capturedRemoteIntent = RemoteCommandActionIntent.capture(
            kind: .fullSync,
            activeCommand: tappedCommand
        )
        XCTAssertEqual(
            capturedRemoteIntent,
            .cancel(kind: .fullSync, commandID: tappedCommandID)
        )
        XCTAssertNotEqual(
            capturedRemoteIntent,
            .cancel(kind: .fullSync, commandID: replacementCommandID),
            "A later command must not replace the server UUID captured by the cancel tap."
        )
    }

    func testRemoteCommandMergeCannotRegressTerminalStateWithReversedLatency() {
        let commandID = UUID()
        let olderPending = RemoteRunCommand(
            id: commandID,
            kind: .fullSync,
            status: .pending,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let newerCompleted = RemoteRunCommand(
            id: commandID,
            kind: .fullSync,
            status: .completed,
            createdAt: olderPending.createdAt,
            updatedAt: Date(timeIntervalSince1970: 30)
        )

        let commandsFirst = RemoteCommandMonotonicMergePolicy.preferred(
            current: olderPending,
            incoming: newerCompleted
        )
        let lateStatus = RemoteCommandMonotonicMergePolicy.preferred(
            current: commandsFirst,
            incoming: olderPending
        )
        XCTAssertEqual(lateStatus.status, .completed)

        let statusFirst = RemoteCommandMonotonicMergePolicy.preferred(
            current: newerCompleted,
            incoming: olderPending
        )
        XCTAssertEqual(statusFirst.status, .completed)

        var invalidLaterPending = olderPending
        invalidLaterPending.updatedAt = Date(timeIntervalSince1970: 40)
        XCTAssertEqual(
            RemoteCommandMonotonicMergePolicy.preferred(
                current: newerCompleted,
                incoming: invalidLaterPending
            ).status,
            .completed,
            "A command UUID is final once it reaches a terminal state."
        )
    }

    func testAdaptiveLayoutPolicyUsesContainerWidthThresholds() {
        XCTAssertEqual(AdaptiveLayoutPolicy.mode(for: 0), .compact)
        XCTAssertEqual(AdaptiveLayoutPolicy.mode(for: 719.99), .compact)
        XCTAssertEqual(AdaptiveLayoutPolicy.mode(for: 720), .medium)
        XCTAssertEqual(AdaptiveLayoutPolicy.mode(for: 1_039.99), .medium)
        XCTAssertEqual(AdaptiveLayoutPolicy.mode(for: 1_040), .wide)
    }

    func testMacNavigationUsesExactlyThreeFixedPresentations() {
        for width in Int(MacWorkspaceLayoutPolicy.minimumWindowWidth)...1_600 {
            let metrics = MacWorkspaceLayoutPolicy.metrics(for: CGFloat(width))
            let expectedNavigationWidth: CGFloat
            let expectedNavigationMode: MacWorkspaceNavigationMode
            if CGFloat(width) < MacWorkspaceLayoutPolicy.narrowNavigationUpperBound {
                expectedNavigationWidth = 0
                expectedNavigationMode = .compact
            } else if CGFloat(width) < MacWorkspaceLayoutPolicy.fullSidebarMinimumWindowWidth {
                expectedNavigationWidth = MacWorkspaceLayoutPolicy.railColumnWidth
                expectedNavigationMode = .rail
            } else {
                expectedNavigationWidth = MacWorkspaceLayoutPolicy.sidebarColumnWidth
                expectedNavigationMode = .sidebar
            }
            XCTAssertEqual(metrics.navigationColumnWidth, expectedNavigationWidth)
            XCTAssertEqual(metrics.navigationMode, expectedNavigationMode)
            XCTAssertEqual(metrics.documentWidth, metrics.workspaceWidth)
            XCTAssertEqual(
                metrics.navigationColumnWidth + metrics.workspaceWidth,
                CGFloat(width),
                accuracy: 0.001
            )
        }
    }

    func testMacWorkspaceKeepsTheFormer1039To1040BreakpointMonotonic() {
        let before = MacWorkspaceLayoutPolicy.metrics(for: 1_039)
        let after = MacWorkspaceLayoutPolicy.metrics(for: 1_040)

        XCTAssertEqual(before.navigationColumnWidth, MacWorkspaceLayoutPolicy.railColumnWidth)
        XCTAssertEqual(after.navigationColumnWidth, MacWorkspaceLayoutPolicy.railColumnWidth)
        XCTAssertEqual(after.workspaceWidth, before.workspaceWidth + 1)
        XCTAssertGreaterThan(after.contentWidth, before.contentWidth)
        XCTAssertEqual(before.contentMode, .wide)
        XCTAssertEqual(after.contentMode, .wide)
    }

    func testMacWorkspaceSeparatesNavigationPresentationFromContentLayout() {
        let compact = MacWorkspaceLayoutPolicy.metrics(for: 640)
        XCTAssertEqual(compact.navigationMode, .compact)
        XCTAssertEqual(compact.contentMode, .compact)
        XCTAssertEqual(compact.workspaceWidth, 640)

        let medium = MacWorkspaceLayoutPolicy.metrics(for: 900)
        XCTAssertEqual(medium.navigationMode, .rail)
        XCTAssertEqual(medium.contentMode, .medium)
        XCTAssertEqual(medium.workspaceWidth, 835)

        let wide = MacWorkspaceLayoutPolicy.metrics(for: 1_200)
        XCTAssertEqual(wide.navigationMode, .sidebar)
        XCTAssertEqual(wide.contentMode, .wide)
        XCTAssertEqual(wide.navigationColumnWidth, 185)
        XCTAssertEqual(wide.workspaceWidth, 1_015)
        XCTAssertEqual(wide.documentWidth, 1_015)

        let fixedRail = MacWorkspaceLayoutPolicy.metrics(for: 1_199)
        XCTAssertEqual(fixedRail.navigationMode, .rail)
        XCTAssertEqual(
            fixedRail.navigationColumnWidth,
            MacWorkspaceLayoutPolicy.railColumnWidth
        )

        let completedSidebarExpansion = MacWorkspaceLayoutPolicy.metrics(for: 1_200)
        XCTAssertEqual(
            completedSidebarExpansion.navigationColumnWidth,
            MacWorkspaceLayoutPolicy.sidebarColumnWidth
        )
        XCTAssertEqual(completedSidebarExpansion.workspaceWidth, wide.workspaceWidth)
    }

    func testMacWorkspaceColumnModeUsesPostNavigationWorkspaceWidth() {
        let compact = MacWorkspaceLayoutPolicy.metrics(for: 720)
        let belowBoundary = MacWorkspaceLayoutPolicy.metrics(for: 964.5)
        let atBoundary = MacWorkspaceLayoutPolicy.metrics(for: 965)

        XCTAssertEqual(compact.contentMode, .compact)
        XCTAssertEqual(belowBoundary.workspaceWidth, 899.5)
        XCTAssertEqual(belowBoundary.contentMode, .medium)
        XCTAssertEqual(atBoundary.workspaceWidth, 900)
        XCTAssertEqual(atBoundary.contentMode, .wide)
    }

    func testMacWorkspaceNavigationTransitionsUseThreeExactFixedWidths() {
        let expectations: [(CGFloat, CGFloat, CGFloat, MacWorkspaceNavigationMode)] = [
            (640, 0, 640, .compact),
            (720, 0, 720, .compact),
            (759, 0, 759, .compact),
            (760, 65, 695, .rail),
            (1_040, 65, 975, .rail),
            (1_080, 65, 1_015, .rail),
            (1_120, 65, 1_055, .rail),
            (1_199, 65, 1_134, .rail),
            (1_200, 185, 1_015, .sidebar),
            (1_240, 185, 1_055, .sidebar),
        ]

        for (windowWidth, navigationWidth, workspaceWidth, mode) in expectations {
            let metrics = MacWorkspaceLayoutPolicy.metrics(for: windowWidth)
            XCTAssertEqual(metrics.navigationColumnWidth, navigationWidth, accuracy: 0.001)
            XCTAssertEqual(metrics.workspaceWidth, workspaceWidth, accuracy: 0.001)
            XCTAssertEqual(metrics.navigationMode, mode)
        }
    }

    func testRelaySessionGenerationSurvivesWebSocketReconnectButNotAccountReset() {
        var session = RelaySessionGeneration()
        var eventCursor = RelayEventCursor()
        let capturedSession = session.current

        _ = eventCursor.beginConnection()
        _ = eventCursor.beginConnection()
        XCTAssertTrue(session.isCurrent(capturedSession))

        _ = session.reset()
        XCTAssertFalse(session.isCurrent(capturedSession))
    }

    func testRelayOperationOwnerPreventsStaleBatchAndCheckerCleanup() {
        var batchOwner = RelayOperationOwner()
        let staleBatch = batchOwner.begin()
        let currentBatch = batchOwner.begin()
        XCTAssertFalse(batchOwner.owns(staleBatch))
        XCTAssertTrue(batchOwner.owns(currentBatch))

        var checkerOwner = RelayOperationOwner()
        let staleChecker = checkerOwner.begin()
        let currentChecker = checkerOwner.begin()
        var checkerIsBusy = true
        if checkerOwner.owns(staleChecker) {
            checkerIsBusy = false
        }
        XCTAssertTrue(checkerIsBusy, "A stale checker defer must not clear the current owner's busy flag.")
        XCTAssertTrue(checkerOwner.owns(currentChecker))
    }

    func testCancelSuccessSchedulesDeferredScopesWhenCommandFinishedDuringAwait() {
        XCTAssertTrue(
            RelayEventBatchSchedulingPolicy.shouldScheduleDeferredScopes(
                commandIsRunning: false,
                hasDirtyScopes: true
            )
        )
        XCTAssertFalse(
            RelayEventBatchSchedulingPolicy.shouldScheduleDeferredScopes(
                commandIsRunning: true,
                hasDirtyScopes: true
            )
        )
    }

    @MainActor
    func testStalledDashboardStageCannotDelayWorkerPickup() async {
        let stages = RelayRealtimeWorkOrder.stages(
            refreshesWorker: true,
            refreshesDashboard: true
        )
        XCTAssertEqual(stages, [.workerInbox, .dashboardSnapshot])

        var workerWasPickedUp = false
        let pipeline = Task { @MainActor in
            for stage in stages {
                switch stage {
                case .workerInbox:
                    workerWasPickedUp = true
                case .dashboardSnapshot:
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
        while !workerWasPickedUp {
            await Task.yield()
        }
        XCTAssertTrue(workerWasPickedUp)
        XCTAssertFalse(pipeline.isCancelled)
        pipeline.cancel()
        _ = await pipeline.value
    }

    @MainActor
    func testRelayEndpointConsumersApplyFastAndLaterRealtimeWorkBeforeSlowReadsRelease() async {
        let recorder = RelayEndpointTestRecorder()
        let syncDataGate = RelayEndpointTestGate()
        let slowRequestLogGate = RelayEndpointTestGate()

        let fullRefreshOperations: [@Sendable () async -> RelayEndpointTestValue] = [
                {
                    await syncDataGate.wait()
                    return RelayEndpointTestValue.syncData
                },
                { .status },
                { .commands(1) },
                { .itemActions },
                { .settingActions },
            ]
        let fullRefresh = Task {
            await RelayEndpointCompletionConsumer.consume(fullRefreshOperations) { endpoint in
                recorder.record(endpoint)
                return endpoint
            }
        }

        let initialFastValues: Set<RelayEndpointTestValue> = [
            .status,
            .commands(1),
            .itemActions,
            .settingActions,
        ]
        for _ in 0..<1_000 where !initialFastValues.isSubset(of: Set(recorder.values)) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(initialFastValues.isSubset(of: Set(recorder.values)))
        XCTAssertFalse(recorder.values.contains(.syncData))

        let olderPreviewOperations: [@Sendable () async -> RelayEndpointTestValue] = [
                {
                    await slowRequestLogGate.wait()
                    return RelayEndpointTestValue.requestLog
                },
            ]
        let olderPreview = Task {
            await RelayEndpointCompletionConsumer.consume(olderPreviewOperations) { endpoint in
                recorder.record(endpoint)
                return endpoint
            }
        }
        for _ in 0..<1_000 {
            if await slowRequestLogGate.hasWaiter { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        let laterCommandOperations: [@Sendable () async -> RelayEndpointTestValue] = [
                { RelayEndpointTestValue.commands(2) },
            ]
        let laterCommandEvent = Task {
            await RelayEndpointCompletionConsumer.consume(laterCommandOperations) { endpoint in
                recorder.record(endpoint)
                return endpoint
            }
        }
        _ = await laterCommandEvent.value
        XCTAssertTrue(recorder.values.contains(.commands(2)))
        XCTAssertFalse(recorder.values.contains(.requestLog))
        XCTAssertFalse(recorder.values.contains(.syncData))

        await slowRequestLogGate.release()
        await syncDataGate.release()
        _ = await (olderPreview.value, fullRefresh.value)
        XCTAssertTrue(recorder.values.contains(.requestLog))
        XCTAssertTrue(recorder.values.contains(.syncData))
    }

    @MainActor
    func testNewerEndpointEpochPreventsOldItemAndFileResponsesFromRollingBackPreview() async {
        for endpoint in [RelayEndpointEpochTestKey.itemActions, .fileRequests] {
            let harness = RelayEndpointEpochHarness()
            let gate = RelayEndpointTestGate()
            let oldEpoch = harness.begin(endpoint)
            let oldResponse = Task {
                await gate.wait()
                harness.apply("old", endpoint: endpoint, epoch: oldEpoch)
            }
            for _ in 0..<1_000 {
                if await gate.hasWaiter { break }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }

            let previewEpoch = harness.begin(endpoint)
            harness.apply("new", endpoint: endpoint, epoch: previewEpoch)
            XCTAssertEqual(harness.value, "new")

            await gate.release()
            _ = await oldResponse.value
            XCTAssertEqual(
                harness.value,
                "new",
                "An endpoint response captured before the WebSocket preview must not replace the newer value."
            )
        }
    }

    @MainActor
    func testLaterSyncDataEventSupersedesSlowOldSnapshotBeforeRelease() async {
        let harness = RelayEndpointEpochHarness()
        let gate = RelayEndpointTestGate()
        let oldEpoch = harness.begin(.syncData)
        let slowOldSnapshot = Task {
            await gate.wait()
            harness.apply("old snapshot", endpoint: .syncData, epoch: oldEpoch)
        }
        for _ in 0..<1_000 {
            if await gate.hasWaiter { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        let laterEventEpoch = harness.begin(.syncData)
        harness.apply("new event snapshot", endpoint: .syncData, epoch: laterEventEpoch)
        XCTAssertEqual(harness.value, "new event snapshot")

        await gate.release()
        _ = await slowOldSnapshot.value
        XCTAssertEqual(
            harness.value,
            "new event snapshot",
            "A later syncData event must own the snapshot lane before the older request is released."
        )
    }

    @MainActor
    func testSlowWorkerStageDoesNotBlockLaterSnapshotAndDisplayedActionState() async {
        let workerGate = RelayEndpointTestGate()
        let recorder = RelayEndpointTestRecorder()
        let slowWorker = Task {
            await workerGate.wait()
            return "worker complete"
        }
        for _ in 0..<1_000 {
            if await workerGate.hasWaiter { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        let laterWebSocketPreviews: [@Sendable () async -> RelayEndpointTestValue] = [
            { .syncData },
            { .requestLog },
        ]
        _ = await RelayEndpointCompletionConsumer.consume(laterWebSocketPreviews) { endpoint in
            recorder.record(endpoint)
            return endpoint
        }

        XCTAssertEqual(Set(recorder.values), [.syncData, .requestLog])
        XCTAssertFalse(slowWorker.isCancelled)
        await workerGate.release()
        let workerResult = await slowWorker.value
        XCTAssertEqual(workerResult, "worker complete")
    }

    func testMutationBaselinePreservesEqualTimestampExternalObservation() {
        XCTAssertTrue(
            RelayMutationBaselinePolicy.shouldAcceptResponse(
                requestObservationVersion: 4,
                currentObservationVersion: 4,
                responseIsStrictlyNewer: false
            ),
            "Without an intervening authoritative observation, an equal-timestamp success is still the committed write."
        )
        XCTAssertFalse(
            RelayMutationBaselinePolicy.shouldAcceptResponse(
                requestObservationVersion: 4,
                currentObservationVersion: 5,
                responseIsStrictlyNewer: false
            ),
            "After external C was observed, delayed equal-timestamp A must not replace C."
        )
        XCTAssertTrue(
            RelayMutationBaselinePolicy.shouldAcceptResponse(
                requestObservationVersion: 4,
                currentObservationVersion: 5,
                responseIsStrictlyNewer: true
            )
        )
    }

    func testSnapshotStartedBeforeMutationCannotOverwriteOptimisticOrTerminalState() {
        XCTAssertEqual(
            RelaySnapshotApplyPolicy.decision(
                fetchSessionGeneration: 2,
                currentSessionGeneration: 2,
                fetchOperationID: 7,
                currentOperationID: 7,
                fetchMutationEpoch: 10,
                currentMutationEpoch: 11
            ),
            .invalidated
        )
        XCTAssertEqual(
            RelaySnapshotApplyPolicy.decision(
                fetchSessionGeneration: 2,
                currentSessionGeneration: 2,
                fetchOperationID: 7,
                currentOperationID: 8,
                fetchMutationEpoch: 11,
                currentMutationEpoch: 11
            ),
            .superseded
        )
        XCTAssertEqual(
            RelaySnapshotApplyPolicy.decision(
                fetchSessionGeneration: 2,
                currentSessionGeneration: 2,
                fetchOperationID: 8,
                currentOperationID: 8,
                fetchMutationEpoch: 11,
                currentMutationEpoch: 11
            ),
            .apply
        )
    }

    func testClaimedOperationStillPersistsTerminalStateAfterAccountSwitch() {
        XCTAssertEqual(
            RelayClaimedOperationPolicy.terminalDisposition(originalSessionIsCurrent: true),
            RelayClaimedTerminalDisposition(
                persistsTerminalState: true,
                appliesVisibleState: true
            )
        )
        XCTAssertEqual(
            RelayClaimedOperationPolicy.terminalDisposition(originalSessionIsCurrent: false),
            RelayClaimedTerminalDisposition(
                persistsTerminalState: true,
                appliesVisibleState: false
            ),
            "A claimed old-relay row must be terminalized without leaking its UI into the new account."
        )
    }

    @MainActor
    func testKeyedSerialTaskQueueKeepsLatestValueWithReversedLatency() async {
        let queue = KeyedSerialTaskQueue<String>()
        var serverValue = "original"
        var executionOrder = [String]()

        let older = Task { @MainActor in
            await queue.enqueue(for: "notice-notes") {
                executionOrder.append("older-start")
                try? await Task.sleep(nanoseconds: 40_000_000)
                serverValue = "older"
                executionOrder.append("older-end")
            }
        }
        while !executionOrder.contains("older-start") {
            await Task.yield()
        }
        let latest = Task { @MainActor in
            await queue.enqueue(for: "notice-notes") {
                executionOrder.append("latest-start")
                try? await Task.sleep(nanoseconds: 1_000_000)
                serverValue = "latest"
                executionOrder.append("latest-end")
            }
        }

        _ = await (older.value, latest.value)
        XCTAssertEqual(serverValue, "latest")
        XCTAssertEqual(
            executionOrder,
            ["older-start", "older-end", "latest-start", "latest-end"]
        )
    }

    func testCommittedBaselineDistinguishesSkippedOrFailedAndSuccessfulEarlierWrites() {
        var tracker = KeyedCommittedBaselineTracker<String, String>()

        tracker.beginMutation(for: "notice-notes", generation: 1, committedValue: "original")
        XCTAssertEqual(
            tracker.committedValue(for: "notice-notes", generation: 1),
            "original",
            "If the earlier write is skipped or fails, a later failure must restore the original value."
        )

        tracker.recordCommittedValue("older", for: "notice-notes", generation: 1)
        XCTAssertEqual(
            tracker.committedValue(for: "notice-notes", generation: 1),
            "older",
            "If the earlier write commits before the latest write fails, rollback must restore that committed value."
        )

        tracker.endMutationChain(for: "notice-notes", generation: 1)
        tracker.beginMutation(for: "notice-notes", generation: 2, committedValue: nil)
        XCTAssertNil(
            tracker.committedValue(for: "notice-notes", generation: 2),
            "A missing key must remain distinguishable as the committed baseline for removal."
        )
    }

    func testMutationVersionsIsolateItemsAndRejectOverlappingSameItemMutation() throws {
        var tracker = KeyedMutationVersionTracker<String>()
        let firstItemVersion = try XCTUnwrap(tracker.begin(for: "assignment-1"))
        let otherItemVersion = try XCTUnwrap(tracker.begin(for: "assignment-2"))

        XCTAssertTrue(tracker.owns(key: "assignment-1", version: firstItemVersion))
        XCTAssertTrue(tracker.end(key: "assignment-1", version: firstItemVersion))
        XCTAssertTrue(tracker.owns(key: "assignment-2", version: otherItemVersion))

        XCTAssertNil(tracker.begin(for: "assignment-2"))
        XCTAssertTrue(tracker.end(key: "assignment-2", version: otherItemVersion))
        XCTAssertNotNil(tracker.begin(for: "assignment-2"))
    }

    func testOptimisticRollbackRequiresCurrentVersionAndUnchangedOptimisticValue() {
        XCTAssertTrue(OptimisticRollbackPolicy.shouldRestore(
            ownsCurrentVersion: true,
            currentValue: "hidden",
            optimisticValue: "hidden"
        ))
        XCTAssertFalse(OptimisticRollbackPolicy.shouldRestore(
            ownsCurrentVersion: false,
            currentValue: "hidden",
            optimisticValue: "hidden"
        ))
        XCTAssertFalse(OptimisticRollbackPolicy.shouldRestore(
            ownsCurrentVersion: true,
            currentValue: "restored-by-newer-update",
            optimisticValue: "hidden"
        ))
    }

    func testRelayEventEnvelopeDecodesVersionedAndLegacyFrames() throws {
        let versioned = try JSONDecoder().decode(
            RelayEventEnvelope.self,
            from: Data(
                #"{"version":1,"type":"changed","revision":42,"eventID":"event-42","reason":"sync-data","scopes":["status","syncData"],"delta":{"count":3,"nested":{"ok":true},"items":["a",null]},"requiresSnapshot":false,"sentAt":"2026-07-13T12:00:00Z"}"#.utf8
            )
        )

        XCTAssertEqual(versioned.version, 1)
        XCTAssertEqual(versioned.type, .changed)
        XCTAssertEqual(versioned.revision, 42)
        XCTAssertEqual(versioned.scopes, [.status, .syncData])
        XCTAssertEqual(versioned.delta?["count"], .number(3))
        XCTAssertEqual(versioned.delta?["nested"], .object(["ok": .bool(true)]))
        XCTAssertEqual(versioned.delta?["items"], .array([.string("a"), .null]))

        let legacy = try JSONDecoder().decode(
            RelayEventEnvelope.self,
            from: Data(#"{"reason":"commands:pending","updatedAt":"2026-07-13T12:00:01Z"}"#.utf8)
        )
        XCTAssertEqual(legacy.version, 1)
        XCTAssertNil(legacy.type)
        XCTAssertNil(legacy.revision)
        XCTAssertEqual(legacy.reason, "commands:pending")
        XCTAssertEqual(legacy.scopes, [])
        XCTAssertFalse(legacy.requiresSnapshot)
    }

    func testRealtimePreviewPolicyIncludesSnapshotEventsWhileSnapshotIsInFlight() {
        XCTAssertTrue(
            RelayRealtimePreviewPolicy.shouldStartSnapshotPreview(
                snapshotRefreshIsInFlight: true,
                scopes: [.syncData]
            )
        )
        XCTAssertTrue(
            RelayRealtimePreviewPolicy.shouldStartSnapshotPreview(
                snapshotRefreshIsInFlight: true,
                scopes: [.commands],
                requiresSnapshot: true
            )
        )
        XCTAssertFalse(
            RelayRealtimePreviewPolicy.shouldStartSnapshotPreview(
                snapshotRefreshIsInFlight: false,
                scopes: [.syncData]
            )
        )
        XCTAssertFalse(
            RelayRealtimePreviewPolicy.shouldStartSnapshotPreview(
                snapshotRefreshIsInFlight: true,
                scopes: [.commands]
            )
        )
    }

    func testRelayEventCursorRejectsDuplicatesAndReconcilesGapsAndHeartbeatDrift() {
        var cursor = RelayEventCursor()
        let firstGeneration = cursor.beginConnection()

        XCTAssertTrue(cursor.isCurrent(generation: firstGeneration))
        XCTAssertEqual(
            cursor.decision(for: RelayEventEnvelope(type: .hello, revision: 10)),
            .reconcileSnapshot
        )
        XCTAssertNil(cursor.lastAppliedRevision)
        XCTAssertEqual(cursor.lastObservedRevision, 10)
        XCTAssertEqual(
            cursor.decision(for: RelayEventEnvelope(type: .changed, revision: 11, scopes: [.commands])),
            .apply
        )
        XCTAssertEqual(
            cursor.decision(for: RelayEventEnvelope(type: .changed, revision: 11, scopes: [.commands])),
            .ignore
        )
        XCTAssertEqual(
            cursor.decision(for: RelayEventEnvelope(type: .changed, revision: 13, scopes: [.syncData])),
            .reconcileSnapshot
        )
        XCTAssertEqual(cursor.decision(for: RelayEventEnvelope(type: .pong, revision: 13)), .ignore)
        XCTAssertEqual(cursor.decision(for: RelayEventEnvelope(type: .pong, revision: 14)), .reconcileSnapshot)
        XCTAssertEqual(cursor.decision(for: RelayEventEnvelope(type: .pong)), .ignore)
        XCTAssertEqual(cursor.decision(for: RelayEventEnvelope(type: .ping)), .ignore)
        XCTAssertNil(cursor.lastAppliedRevision)
        cursor.markApplied(revision: 14)
        XCTAssertEqual(cursor.lastAppliedRevision, 14)

        let secondGeneration = cursor.beginConnection()
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertFalse(cursor.isCurrent(generation: firstGeneration))
        XCTAssertNil(cursor.lastAppliedRevision)
    }

    func testDirtyScopeAccumulatorMergesBusyEventsUntilDrain() {
        var accumulator = RelayDirtyScopeAccumulator()
        accumulator.insert([.commands, .status])
        accumulator.insert([.syncData, .commands], requiresSnapshot: true, revision: 22)

        let dirty = accumulator.drain()
        XCTAssertEqual(dirty.scopes, [.commands, .status, .syncData])
        XCTAssertTrue(dirty.requiresSnapshot)
        XCTAssertEqual(dirty.highestRevision, 22)
        XCTAssertTrue(accumulator.isEmpty)
    }

    func testFailedBatchCanRequeueItsRevisionWithoutCommittingCursor() {
        var cursor = RelayEventCursor()
        _ = cursor.beginConnection()
        var accumulator = RelayDirtyScopeAccumulator()
        let event = RelayEventEnvelope(type: .changed, revision: 7, scopes: [.syncData])

        XCTAssertEqual(cursor.decision(for: event), .apply)
        accumulator.insert(event.scopes, revision: event.revision)
        let failedBatch = accumulator.drain()
        accumulator.insert(
            failedBatch.scopes,
            requiresSnapshot: failedBatch.requiresSnapshot,
            revision: failedBatch.highestRevision
        )

        XCTAssertNil(cursor.lastAppliedRevision)
        XCTAssertEqual(accumulator.highestRevision, 7)
        let retriedBatch = accumulator.drain()
        cursor.markApplied(revision: retriedBatch.highestRevision)
        XCTAssertEqual(cursor.lastAppliedRevision, 7)
    }

    func testCancelScopeCanBeRetriedAfterOneShotFailureWithoutANewEvent() {
        var accumulator = RelayDirtyScopeAccumulator()
        accumulator.insert([.cancel], revision: 41)

        let failedAttempt = accumulator.drain()
        XCTAssertEqual(failedAttempt.scopes, [.cancel])
        accumulator.insert([.cancel], revision: failedAttempt.highestRevision)

        let retry = accumulator.drain()
        XCTAssertEqual(retry.scopes, [.cancel])
        XCTAssertEqual(retry.highestRevision, 41)
        XCTAssertTrue(accumulator.isEmpty)
    }

    func testRemoteCommandCompletionPrefersCancellation() {
        XCTAssertEqual(
            RemoteCommandCompletionStatus.resolve(wasCancelled: true, succeeded: false),
            .cancelled
        )
        XCTAssertEqual(
            RemoteCommandCompletionStatus.resolve(wasCancelled: true, succeeded: true),
            .cancelled
        )
        XCTAssertEqual(
            RemoteCommandCompletionStatus.resolve(wasCancelled: false, succeeded: true),
            .completed
        )
        XCTAssertEqual(
            RemoteCommandCompletionStatus.resolve(wasCancelled: false, succeeded: false),
            .failed
        )
    }

    func testWorkerInboxDropsMalformedLegacyRowsWithoutDroppingValidCommands() throws {
        let validID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let valid = RemoteRunCommand(
            id: validID,
            kind: .fullSync,
            status: .pending,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let encoded = try JSONEncoder.klmsLocalRemote.encode(
            ServerRelayWorkerInbox(pendingCommands: [valid])
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let validObject = try XCTUnwrap(
            (object["pendingCommands"] as? [[String: Any]])?.first
        )
        object["pendingCommands"] = [
            validObject,
            ["id": "not-a-uuid", "kind": "unknown", "status": "pending"],
            "not-an-object"
        ]
        if var statusResponse = object["statusResponse"] as? [String: Any] {
            statusResponse["latestCommand"] = ["id": "not-a-uuid"]
            object["statusResponse"] = statusResponse
        }

        let mixedData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder.klmsLocalRemote.decode(
            ServerRelayWorkerInbox.self,
            from: mixedData
        )

        XCTAssertEqual(decoded.pendingCommands.map(\.id), [validID])
        XCTAssertNil(decoded.statusResponse.latestCommand)
    }

    func testReconnectBackoffIsBounded() {
        XCTAssertEqual(RelayReconnectBackoff.nanoseconds(forAttempt: -1, jitterFraction: 0), 250_000_000)
        XCTAssertEqual(RelayReconnectBackoff.nanoseconds(forAttempt: 0, jitterFraction: 0), 250_000_000)
        XCTAssertEqual(RelayReconnectBackoff.nanoseconds(forAttempt: 1, jitterFraction: 0), 500_000_000)
        XCTAssertEqual(RelayReconnectBackoff.nanoseconds(forAttempt: 2, jitterFraction: 0), 1_000_000_000)
        XCTAssertEqual(RelayReconnectBackoff.nanoseconds(forAttempt: 3, jitterFraction: 0), 2_000_000_000)
        XCTAssertEqual(RelayReconnectBackoff.nanoseconds(forAttempt: 100, jitterFraction: 1), 2_000_000_000)
        XCTAssertEqual(RelayReconnectBackoff.nanoseconds(forAttempt: 0, jitterFraction: -1), 225_000_000)
        XCTAssertEqual(RelayReconnectBackoff.nanoseconds(forAttempt: 0, jitterFraction: 1), 275_000_000)
    }

    func testHeartbeatReconnectsBlackholedSocketBeforeFortyFiveSeconds() {
        let lastMessageAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertLessThan(
            Double(RelayHeartbeatPolicy.helloTimeoutNanoseconds) / 1_000_000_000,
            RelayHeartbeatPolicy.staleTimeout
        )
        XCTAssertLessThan(RelayHeartbeatPolicy.staleTimeout, 45)
        XCTAssertFalse(
            RelayHeartbeatPolicy.isStale(
                lastMessageAt: lastMessageAt,
                now: lastMessageAt.addingTimeInterval(RelayHeartbeatPolicy.staleTimeout - 0.001)
            )
        )
        XCTAssertTrue(
            RelayHeartbeatPolicy.isStale(
                lastMessageAt: lastMessageAt,
                now: lastMessageAt.addingTimeInterval(RelayHeartbeatPolicy.staleTimeout)
            )
        )
    }
}

private enum RelayEndpointTestValue: Sendable, Hashable {
    case syncData
    case status
    case commands(Int)
    case itemActions
    case settingActions
    case requestLog
}

private actor RelayEndpointTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var hasWaiter: Bool {
        !waiters.isEmpty
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class RelayEndpointTestRecorder {
    private(set) var values: [RelayEndpointTestValue] = []

    func record(_ value: RelayEndpointTestValue) {
        values.append(value)
    }
}

private enum RelayEndpointEpochTestKey: Sendable, Hashable {
    case itemActions
    case fileRequests
    case syncData
}

@MainActor
private final class RelayEndpointEpochHarness {
    private var epochs = RelayEndpointApplyEpochs<RelayEndpointEpochTestKey>()
    private(set) var value = ""

    func begin(_ endpoint: RelayEndpointEpochTestKey) -> UInt64 {
        epochs.begin(for: endpoint)
    }

    func apply(
        _ value: String,
        endpoint: RelayEndpointEpochTestKey,
        epoch: UInt64
    ) {
        guard epochs.owns(endpoint: endpoint, epoch: epoch) else { return }
        self.value = value
    }
}
