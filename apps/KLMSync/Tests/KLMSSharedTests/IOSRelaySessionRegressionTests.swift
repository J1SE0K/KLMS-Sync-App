import Foundation
import KLMSShared
import XCTest

final class IOSRelaySessionRegressionTests: XCTestCase {
    func testHTTPWorkUsesRelaySessionGenerationInsteadOfWebSocketGeneration() throws {
        let source = try iosSource()
        let httpWork = try sourceSlice(
            source,
            from: "func submitMailDashboardItem",
            to: "private func configureServerRelayEventStream"
        )
        let sharedSettingsApply = try sourceSlice(
            source,
            from: "private func applySharedSettings(",
            to: "private static func serverRelaySettingDate"
        )

        XCTAssertTrue(source.contains("private var relaySessionGeneration: UInt64 = 0"))
        XCTAssertTrue(source.contains("relaySessionGeneration &+= 1"))
        XCTAssertTrue(source.contains("private func isCurrentRelaySession(generation: UInt64) -> Bool"))
        XCTAssertGreaterThanOrEqual(
            httpWork.components(separatedBy: "let generation = relaySessionGeneration").count - 1,
            12
        )
        XCTAssertTrue(httpWork.contains("let refreshGeneration = relaySessionGeneration"))
        XCTAssertFalse(httpWork.contains("relayEventCursor.connectionGeneration"))
        XCTAssertTrue(sharedSettingsApply.contains("let generation = relaySessionGeneration"))
        XCTAssertFalse(sharedSettingsApply.contains("relayEventCursor.connectionGeneration"))

        let eventStream = try sourceSlice(
            source,
            from: "private func runServerRelayEventStream",
            to: "func ensureServerRelayRealtimeConnection"
        )
        XCTAssertTrue(eventStream.contains("let generation = relayEventCursor.beginConnection()"))
        XCTAssertTrue(eventStream.contains("relayEventCursor.isCurrent(generation: generation)"))
        let connectionStartup = try sourceSlice(
            eventStream,
            from: "task.resume()",
            to: "var lastMessageAt = Date()"
        )
        XCTAssertTrue(connectionStartup.contains("let helloMessage = try await task.receive()"))
        XCTAssertTrue(connectionStartup.contains("RelayHeartbeatPolicy.helloTimeoutNanoseconds"))
        XCTAssertTrue(connectionStartup.contains("helloTimeout.cancel()"))
        XCTAssertTrue(connectionStartup.contains("hello.type == .hello"))
        XCTAssertTrue(connectionStartup.contains("hello.version == 1"))
        XCTAssertTrue(connectionStartup.contains("handleRelayEvent(helloMessage, generation: generation)"))
        XCTAssertTrue(connectionStartup.contains("connectionMessage = \"서버 실시간 연결됨\""))
        XCTAssertLessThan(
            try XCTUnwrap(connectionStartup.range(of: "handleRelayEvent(helloMessage")?.lowerBound),
            try XCTUnwrap(connectionStartup.range(of: "connectionMessage = \"서버 실시간 연결됨\"")?.lowerBound)
        )
        XCTAssertFalse(connectionStartup.contains("await refreshRecent"))
    }

    func testRelayEventBatchReplacesOldGenerationOwnerAndReschedulesDrainedDirtyScopes() throws {
        let source = try iosSource()
        let batch = try sourceSlice(
            source,
            from: "private func scheduleRelayEventBatch(",
            to: "private func applyRelayEventLocalClear"
        )

        XCTAssertTrue(batch.contains("if relayEventBatchGeneration == generation"))
        XCTAssertTrue(batch.contains("existingTask.cancel()"))
        XCTAssertTrue(batch.contains("let operationID = relayEventBatchOperationID"))
        XCTAssertTrue(batch.contains("isRelayEventBatchOwner(operationID: operationID, generation: generation)"))
        XCTAssertTrue(batch.contains("self.relayDirtyScopes.insert(\n                        dirty.scopes"))
        XCTAssertTrue(batch.contains("generation: self.relayEventCursor.connectionGeneration"))
        XCTAssertTrue(batch.contains("relayEventBatchOperationID == operationID"))
        XCTAssertTrue(batch.contains("relayEventBatchGeneration == generation"))
    }

    func testSharedSettingEqualTimestampPolicyDistinguishesExternalObservation() throws {
        let source = try iosSource()
        let mutation = try sourceSlice(
            source,
            from: "private func updateSharedSetting(",
            to: "private func clearPendingSharedSettingMutation"
        )
        let authoritativeApply = try sourceSlice(
            source,
            from: "private func applySharedSettings(",
            to: "private static func serverRelaySettingDate"
        )

        XCTAssertTrue(mutation.contains("let authoritativeObservationVersion ="))
        XCTAssertTrue(mutation.contains("authoritativeObservationIsUnchanged"))
        XCTAssertTrue(mutation.contains("let savedWasAccepted = authoritativeObservationIsUnchanged"))
        XCTAssertTrue(mutation.contains("isStrictlyNewerThan: committedSetting"))
        XCTAssertTrue(mutation.contains("if savedWasAccepted {\n                    _ = self.applySharedSettings([saved], merge: true)"))
        XCTAssertTrue(mutation.contains("self.restoreSharedSetting(key: key, previousSetting: committedSetting)"))
        XCTAssertTrue(authoritativeApply.contains("sharedSettingAuthoritativeObservationSequence &+= 1"))
        XCTAssertTrue(authoritativeApply.contains("candidateDate > baselineDate"))
        XCTAssertTrue(authoritativeApply.contains("candidate.updatedAt > baseline.updatedAt"))

        let timestamp = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(
            shouldAcceptSavedSetting(
                observationAtStart: 4,
                observationAtResponse: 4,
                savedAt: timestamp,
                committedAt: timestamp
            ),
            "Without an intervening authoritative snapshot, an equal-timestamp successful PUT is the committed value."
        )
        XCTAssertFalse(
            shouldAcceptSavedSetting(
                observationAtStart: 4,
                observationAtResponse: 5,
                savedAt: timestamp,
                committedAt: timestamp
            ),
            "After an external authoritative observation, an equal-timestamp late PUT must not replace that baseline."
        )
        let externalVisibleValue = "external-C"
        let lateSavedValue = "local-A"
        let visibleValue = shouldAcceptSavedSetting(
            observationAtStart: 4,
            observationAtResponse: 5,
            savedAt: timestamp,
            committedAt: timestamp
        ) ? lateSavedValue : externalVisibleValue
        XCTAssertEqual(visibleValue, externalVisibleValue)
        XCTAssertTrue(
            shouldAcceptSavedSetting(
                observationAtStart: 4,
                observationAtResponse: 5,
                savedAt: timestamp.addingTimeInterval(1),
                committedAt: timestamp
            )
        )
    }

    func testOptimisticRelayMutationsSurviveOlderSnapshots() throws {
        let source = try iosSource()
        let refreshApply = try sourceSlice(
            source,
            from: "private func apply(_ syncData:",
            to: "private func rebuildDerivedStateAfterServerSyncDataApply"
        )
        let displayLogRefresh = try sourceSlice(
            source,
            from: "private func commandsOverlayingPendingSubmissions",
            to: "func checkServerRelayConnection"
        )
        let statusApply = try sourceSlice(
            source,
            from: "private func apply(_ response: LocalRemoteResponse)",
            to: "private func shouldNotifyAuthSuccess"
        )

        XCTAssertTrue(source.contains("private var pendingSubmittedCommandsByID"))
        XCTAssertTrue(source.contains("private var pendingItemActionOverlaysByID"))
        XCTAssertTrue(source.contains("private var pendingFileAccessRequestsByID"))
        XCTAssertTrue(displayLogRefresh.contains("commandsOverlayingPendingSubmissions"))
        XCTAssertTrue(displayLogRefresh.contains("confirmsTerminalState: Bool = true"))
        XCTAssertTrue(displayLogRefresh.contains("fileAccessRequestsOverlayingPendingSubmissions"))
        XCTAssertTrue(displayLogRefresh.contains("itemActionsOverlayingPendingSubmissions"))
        XCTAssertTrue(statusApply.contains("let pendingCommand = pendingSubmittedCommandsByID.values"))
        XCTAssertTrue(statusApply.contains("let statusCommand = pendingCommand ?? mergedLatestCommand"))
        XCTAssertTrue(statusApply.contains("let incomingStatus = statusCommand?.summary ?? response.status"))
        XCTAssertTrue(statusApply.contains("confirmsTerminalState: false"))
        XCTAssertTrue(source.contains("let statusCommandID,"))
        XCTAssertTrue(source.contains("$0.id == statusCommandID && $0.status.isTerminal"))
        XCTAssertTrue(source.contains("status = confirmedTerminalCommand.summary"))
        XCTAssertTrue(displayLogRefresh.contains("RemoteCommandMonotonicMergePolicy.preferred("))
        XCTAssertTrue(refreshApply.contains("pendingItemActionOverlaysByID.values.map(\\.action)"))
        XCTAssertTrue(refreshApply.contains("if sharedRunLogsClearPending"))
        XCTAssertTrue(refreshApply.contains("incomingSharedRunLogs = []"))
        XCTAssertTrue(source.contains("sharedRunLogsClearPending = true\n            clearSharedRunLogDisplayState()"))
    }

    func testServerTokenPersistenceSerializesStartedKeychainWrites() throws {
        let source = try iosSource()
        let schedule = try sourceSlice(
            source,
            from: "private func schedulePersistServerToken",
            to: "nonisolated private static func persistServerToken"
        )

        let persistenceSource = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/KLMSShared/CredentialPersistence.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(persistenceSource.contains("public final class CredentialPersistenceCoordinator: @unchecked Sendable"))
        XCTAssertTrue(source.contains("private let serverTokenPersistenceCoordinator: CredentialPersistenceCoordinator"))
        XCTAssertTrue(schedule.contains("await persistenceCoordinator.persist(token, generation: persistenceGeneration)"))
        XCTAssertTrue(persistenceSource.contains("operationQueue = DispatchQueue("))
        XCTAssertTrue(persistenceSource.contains("operationQueue.async"))
        XCTAssertFalse(source.contains("operationQueue.sync"))
        XCTAssertFalse(persistenceSource.contains("operationQueue.sync"))
        XCTAssertTrue(source.contains("VersionedCredentialEnvelope.acceptedValue("))
        XCTAssertFalse(schedule.contains("Task.detached"))
    }

    func testServerAssignedIDsReplaceOptimisticOverlayKeys() throws {
        let source = try iosSource()
        let sharedSource = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/KLMSShared/RemoteCommandModels.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(sharedSource.contains("public func createReturningCommand(_ command: RemoteRunCommand) async throws -> RemoteRunCommand"))
        XCTAssertTrue(source.contains("let savedCommand = try await serverRelayStore.createReturningCommand(command)"))
        XCTAssertTrue(source.contains("pendingSubmittedCommandsByID.removeValue(forKey: command.id)"))
        XCTAssertTrue(source.contains("pendingSubmittedCommandsByID[savedCommand.id] = savedCommand"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "pendingItemActionOverlaysByID.removeValue(forKey: action.id)").count - 1,
            2
        )
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "pendingItemActionOverlaysByID[savedAction.id] = overlay").count - 1,
            2
        )
        XCTAssertTrue(source.contains("pendingFileAccessRequestsByID.removeValue(forKey: request.id)"))
        XCTAssertTrue(source.contains("pendingFileAccessRequestsByID[created.id] = created"))
        XCTAssertTrue(source.contains("$0.id == request.id || $0.id == created.id"))

        let optimisticID = UUID()
        let serverID = UUID()
        var pending = [optimisticID: "optimistic"]
        let optimisticValue = pending.removeValue(forKey: optimisticID)
        pending[serverID] = optimisticValue
        XCTAssertNil(pending[optimisticID])
        XCTAssertEqual(pending[serverID], "optimistic")
        pending.removeValue(forKey: serverID)
        XCTAssertTrue(pending.isEmpty, "A terminal row using the server UUID must retire the rekeyed overlay.")

        var recentIDs = [serverID, optimisticID]
        recentIDs.removeAll { $0 == optimisticID || $0 == serverID }
        recentIDs.insert(serverID, at: 0)
        XCTAssertEqual(recentIDs, [serverID], "A WebSocket row arriving before the POST response must not be duplicated.")
    }

    func testItemActionOverlayUsesExactLookupAndRejectsStalePostResponses() throws {
        let source = try iosSource()
        let sharedSource = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/KLMSShared/RemoteCommandModels.swift"),
            encoding: .utf8
        )
        let itemActionSubmission = try sourceSlice(
            source,
            from: "func createItemAction(_ actionKind:",
            to: "func createCalendarAction("
        )
        let calendarSubmission = try sourceSlice(
            source,
            from: "func createCalendarAction(",
            to: "func createManualCalendarAction("
        )
        let reconciliation = try sourceSlice(
            source,
            from: "private func itemActionsOverlayingPendingSubmissions",
            to: "private func visibleSettingActions"
        )

        XCTAssertTrue(sharedSource.contains("public func fetchItemAction(id: UUID) async throws -> ServerRelayItemAction"))
        XCTAssertTrue(source.contains("pendingItemActionIDs: Array(self.pendingItemActionOverlaysByID.keys)"))
        XCTAssertTrue(source.contains("store.fetchItemAction(id: id)"))
        XCTAssertTrue(reconciliation.contains("exactByID: [UUID: ExactItemActionLookup]"))
        XCTAssertTrue(reconciliation.contains("case .missing:"))
        XCTAssertTrue(reconciliation.contains("rollbackItemActionMutation(overlay)"))
        XCTAssertTrue(itemActionSubmission.contains("guard var overlay = pendingItemActionOverlaysByID.removeValue(forKey: action.id) else"))
        XCTAssertTrue(calendarSubmission.contains("guard var overlay = pendingItemActionOverlaysByID.removeValue(forKey: action.id) else"))
        XCTAssertTrue(itemActionSubmission.contains("removeRecentItemActions { $0.id == action.id }"))
        XCTAssertTrue(calendarSubmission.contains("removeRecentItemActions { $0.id == pendingActionID }"))
        XCTAssertFalse(itemActionSubmission.contains("$0.id == action.id || $0.itemID == item.id"))
        XCTAssertFalse(calendarSubmission.contains("$0.id == action.id || candidateIDs.contains($0.itemID)"))
    }

    func testCancelWaitsForServerCommandIdentityAndOldSubmissionCannotUnlockNewOne() throws {
        let source = try iosSource()
        let commandSubmission = try sourceSlice(
            source,
            from: "func createCommand(_ kind: RemoteCommandKind",
            to: "func cancelRunningCommand() async"
        )
        let cancelFlow = try sourceSlice(
            source,
            from: "func cancelRunningCommand() async",
            to: "func createSettingAction"
        )
        let dashboardCard = try sourceSlice(
            source,
            from: "private struct RemoteDashboardSyncCard: View",
            to: "private struct RemoteDashboardSyncCardContent"
        )

        XCTAssertTrue(source.contains("private var commandSubmissionOperationID: UInt64 = 0"))
        XCTAssertTrue(commandSubmission.contains("commandSubmissionOperationID &+= 1"))
        XCTAssertTrue(commandSubmission.contains("let submissionOperationID = commandSubmissionOperationID"))
        XCTAssertTrue(commandSubmission.contains("isSubmitting = true"))
        XCTAssertTrue(commandSubmission.contains("isCurrentRelaySession(generation: generation)"))
        XCTAssertTrue(commandSubmission.contains("commandSubmissionOperationID == submissionOperationID"))
        XCTAssertTrue(commandSubmission.contains("isSubmitting = false"))
        XCTAssertTrue(cancelFlow.contains("guard !isSubmitting else"))
        XCTAssertTrue(cancelFlow.contains("func cancelRunningCommand(expectedCommandID: UUID) async"))
        XCTAssertTrue(cancelFlow.contains("activeCommand.id != expectedCommandID"))
        XCTAssertTrue(cancelFlow.contains("requestCancel(commandID: commandID)"))
        XCTAssertTrue(source.contains("shouldShowCancelControl && !isSubmitting && !isCancelRequestedForLatestCommand"))
        XCTAssertTrue(dashboardCard.contains("isSubmitting: model.isSubmitting"))
        XCTAssertTrue(dashboardCard.contains("guard !model.isSubmitting else { return }"))
        XCTAssertTrue(dashboardCard.contains("if isSubmitting {\n            return true"))

        var currentSession: UInt64 = 2
        var currentOperation: UInt64 = 2
        var isSubmitting = true
        func finish(session: UInt64, operation: UInt64) {
            if session == currentSession, operation == currentOperation {
                isSubmitting = false
            }
        }
        finish(session: 1, operation: 1)
        XCTAssertTrue(isSubmitting, "A stale completion must not unlock a newer command submission.")
        finish(session: 2, operation: 2)
        XCTAssertFalse(isSubmitting)
        currentSession = 3
        currentOperation = 3
    }

    func testTapIntentCapturesServerUUIDBeforeTaskAndMonotonicMergeIsWiredIntoBothResponses() throws {
        let source = try iosSource()
        let actionFlow = try sourceSlice(
            source,
            from: "func runOrCancelRemoteCommand(_ kind: RemoteCommandKind)",
            to: "private struct RemoteDashboardPrimarySyncAction"
        )
        let statusApply = try sourceSlice(
            source,
            from: "private func apply(_ response: LocalRemoteResponse)",
            to: "private func shouldNotifyAuthSuccess"
        )
        let commandMerge = try sourceSlice(
            source,
            from: "private func commandsOverlayingPendingSubmissions",
            to: "private func visibleRequestLog"
        )

        let captureIndex = try XCTUnwrap(actionFlow.range(of: "let intent = RemoteCommandActionIntent.capture(")?.lowerBound)
        let taskIndex = try XCTUnwrap(actionFlow.range(of: "Task { @MainActor")?.lowerBound)
        XCTAssertLessThan(captureIndex, taskIndex, "The action and server UUID must be captured synchronously at tap time.")
        XCTAssertTrue(actionFlow.contains("case let .cancel(kind: _, commandID: commandID)"))
        XCTAssertTrue(actionFlow.contains("cancelRunningCommand(expectedCommandID: commandID)"))
        XCTAssertFalse(actionFlow.contains("if self.latestDisplayStatus?.isInFlight"))

        XCTAssertTrue(commandMerge.contains("RemoteCommandMonotonicMergePolicy.preferred("))
        XCTAssertTrue(commandMerge.contains("current: currentByID[incomingCommand.id]"))
        XCTAssertTrue(statusApply.contains("mergedLatestCommand = overlaidCommands.first(where: { $0.id == latestCommand.id })"))
        XCTAssertTrue(statusApply.contains("statusCommandID = statusCommand?.id"))
        XCTAssertTrue(statusApply.contains("let incomingStatus = statusCommand?.summary ?? response.status"))
    }

    func testRealtimeEndpointConsumersAreIndependentOwnedAndSupersedable() throws {
        let source = try iosSource()
        let refresh = try sourceSlice(
            source,
            from: "func refreshRecent(",
            to: "private static func fetchStatusResponseResult("
        )
        let eventHandling = try sourceSlice(
            source,
            from: "private func handleRelayEvent(",
            to: "private func scheduleRelayEventBatch("
        )

        XCTAssertTrue(refresh.contains("RelayEndpointCompletionConsumer.consume(operations)"))
        XCTAssertTrue(refresh.contains("relayEndpointApplyEpochs.begin(for: endpoint)"))
        XCTAssertTrue(refresh.contains("relayEndpointApplyEpochs.owns("))
        XCTAssertTrue(refresh.contains("applyRelayRefreshEndpoint("))
        XCTAssertFalse(refresh.contains("let syncDataResult = await syncDataTask"))
        XCTAssertFalse(refresh.contains("let responseResult = await responseTask"))

        XCTAssertTrue(eventHandling.contains("if refreshInProgress"))
        XCTAssertTrue(eventHandling.contains("scheduleRelayRealtimePreviews("))
        XCTAssertTrue(eventHandling.contains("relayRealtimePreviewTasks[endpoint]?.cancel()"))
        XCTAssertTrue(eventHandling.contains("relayEndpointApplyEpochs.begin(for: endpoint)"))
        XCTAssertTrue(eventHandling.contains("if scope.fetchesSyncData { endpoints.append(.syncData) }"))
        XCTAssertTrue(eventHandling.contains("let shouldLoadSyncData = endpoint == .syncData"))
        XCTAssertTrue(eventHandling.contains("fetchRelayRefreshEndpoint("))
        XCTAssertTrue(eventHandling.contains("isRelayRealtimePreviewOwnerCurrent("))
        XCTAssertTrue(eventHandling.contains("relayRealtimePreviewOperationIDs[endpoint] == operationID"))
        XCTAssertFalse(eventHandling.contains(".withoutSyncData"))
        XCTAssertTrue(source.contains("relayEndpointApplyEpochs.owns(endpoint: endpoint, epoch: applyEpoch)"))
    }

    func testCalendarOnlyFieldCorrectionsAreAppliedWithoutLossySignatures() throws {
        let source = try iosSource()
        let syncDataApply = try sourceSlice(
            source,
            from: "private func apply(_ syncData:",
            to: "private func rebuildDerivedStateAfterServerSyncDataApply"
        )

        XCTAssertTrue(syncDataApply.contains("if calendarChanges != syncData.calendarChanges"))
        XCTAssertFalse(syncDataApply.contains("nextCalendarChangesSignature"))
        XCTAssertFalse(source.contains("calendarChangesSignature"))
        XCTAssertFalse(source.contains("private static func signature(for changes: [CalendarChange])"))

        let original = CalendarChange(
            action: "updated",
            calendar: "KLMS 시험",
            bucket: "exam",
            identifier: "event-1",
            title: "중간고사",
            course: "자료구조",
            url: "https://example.invalid/exam",
            startAt: "2026-07-15T01:00:00Z",
            dueAt: "2026-07-15T02:00:00Z",
            location: "A 강의실",
            changes: ["장소"],
            raw: "",
            parseError: ""
        )
        var corrected = original
        corrected.location = "B 강의실"
        corrected.course = "자료구조 심화"
        corrected.parseError = "서버 정정"

        XCTAssertEqual(original.id, corrected.id, "The stable display identity intentionally does not include corrected detail fields.")
        XCTAssertNotEqual(original, corrected, "Direct Equatable comparison must still publish corrected detail fields.")
    }

    func testReportNotificationAuthorizationIsRequestedAtMostOnce() throws {
        let source = try iosSource()
        let notification = try sourceSlice(
            source,
            from: "private func postReportRefreshNotification(",
            to: "private func persistTrackedReportNotificationCommandIDs"
        )

        XCTAssertTrue(notification.contains("let settings = await center.notificationSettings()"))
        XCTAssertTrue(notification.contains("if authorizationStatus == .notDetermined"))
        XCTAssertEqual(
            notification.components(separatedBy: "requestAuthorization(options: [.alert, .sound])").count - 1,
            1
        )
        let request = try XCTUnwrap(notification.range(of: "requestAuthorization(options: [.alert, .sound])"))
        let undetermined = try XCTUnwrap(notification.range(of: "if authorizationStatus == .notDetermined"))
        XCTAssertGreaterThan(request.lowerBound, undetermined.lowerBound)
    }

    private func shouldAcceptSavedSetting(
        observationAtStart: UInt64,
        observationAtResponse: UInt64,
        savedAt: Date,
        committedAt: Date
    ) -> Bool {
        observationAtStart == observationAtResponse || savedAt > committedAt
    }

    private func iosSource() throws -> String {
        try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/KLMSiOS/KLMSiOSApp.swift"),
            encoding: .utf8
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceSlice(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
