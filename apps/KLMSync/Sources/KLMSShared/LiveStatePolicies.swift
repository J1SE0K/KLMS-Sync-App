import Foundation

public enum AdaptiveLayoutMode: String, Codable, CaseIterable, Sendable {
    case compact
    case medium
    case wide
}

public enum AdaptiveLayoutPolicy {
    public static let compactUpperBound: CGFloat = 720
    public static let mediumUpperBound: CGFloat = 1_040

    public static func mode(for width: CGFloat) -> AdaptiveLayoutMode {
        if width < compactUpperBound {
            return .compact
        }
        if width < mediumUpperBound {
            return .medium
        }
        return .wide
    }
}

public enum MacWorkspaceNavigationMode: String, Codable, CaseIterable, Sendable {
    case compact
    case rail
    case sidebar
}

public struct MacWorkspaceLayoutMetrics: Equatable, Sendable {
    public var windowWidth: CGFloat
    public var navigationColumnWidth: CGFloat
    public var workspaceWidth: CGFloat
    public var documentWidth: CGFloat
    public var horizontalContentPadding: CGFloat
    public var contentWidth: CGFloat
    public var navigationMode: MacWorkspaceNavigationMode
    public var contentMode: AdaptiveLayoutMode

    public init(
        windowWidth: CGFloat,
        navigationColumnWidth: CGFloat,
        workspaceWidth: CGFloat,
        documentWidth: CGFloat,
        horizontalContentPadding: CGFloat,
        contentWidth: CGFloat,
        navigationMode: MacWorkspaceNavigationMode,
        contentMode: AdaptiveLayoutMode
    ) {
        self.windowWidth = windowWidth
        self.navigationColumnWidth = navigationColumnWidth
        self.workspaceWidth = workspaceWidth
        self.documentWidth = documentWidth
        self.horizontalContentPadding = horizontalContentPadding
        self.contentWidth = contentWidth
        self.navigationMode = navigationMode
        self.contentMode = contentMode
    }
}

/// Uses three stable Mac navigation presentations: no sidebar in narrow
/// windows, an exact 65pt icon rail in medium windows, and a fixed-width
/// labeled sidebar once the window can contain it without clipping.
public enum MacWorkspaceLayoutPolicy {
    public static let minimumWindowWidth: CGFloat = 640
    public static let compactWorkspacePlateauStart: CGFloat = 720
    public static let narrowNavigationUpperBound: CGFloat = 760
    public static let railColumnWidth: CGFloat = 65
    public static let fullSidebarMinimumWindowWidth: CGFloat = 1_200
    public static let sidebarColumnWidth: CGFloat = 185
    public static let sidebarPresentationMinimumWidth: CGFloat = 140
    public static let compactContentUpperBound: CGFloat = 700
    public static let wideContentLowerBound: CGFloat = 900

    public static func metrics(for rawWindowWidth: CGFloat) -> MacWorkspaceLayoutMetrics {
        let windowWidth = max(0, rawWindowWidth)
        let navigationColumnWidth = navigationWidth(for: windowWidth)
        let workspaceWidth = max(0, windowWidth - navigationColumnWidth)
        let documentWidth = workspaceWidth
        let horizontalContentPadding = contentPadding(for: documentWidth)
        let contentWidth = max(0, documentWidth - (horizontalContentPadding * 2))
        let navigationMode: MacWorkspaceNavigationMode
        if navigationColumnWidth < railColumnWidth {
            navigationMode = .compact
        } else if navigationColumnWidth - 1 < sidebarPresentationMinimumWidth {
            navigationMode = .rail
        } else {
            navigationMode = .sidebar
        }

        return MacWorkspaceLayoutMetrics(
            windowWidth: windowWidth,
            navigationColumnWidth: navigationColumnWidth,
            workspaceWidth: workspaceWidth,
            documentWidth: documentWidth,
            horizontalContentPadding: horizontalContentPadding,
            contentWidth: contentWidth,
            navigationMode: navigationMode,
            contentMode: contentMode(
                forWorkspaceWidth: workspaceWidth,
                contentWidth: contentWidth
            )
        )
    }

    private static func navigationWidth(for windowWidth: CGFloat) -> CGFloat {
        if windowWidth < narrowNavigationUpperBound {
            return 0
        }
        if windowWidth < fullSidebarMinimumWindowWidth {
            return railColumnWidth
        }
        return sidebarColumnWidth
    }

    private static func contentPadding(for workspaceWidth: CGFloat) -> CGFloat {
        if workspaceWidth <= compactWorkspacePlateauStart {
            return 12
        }
        if workspaceWidth < compactWorkspacePlateauStart + 8 {
            return 12 + ((workspaceWidth - compactWorkspacePlateauStart) / 2)
        }
        return 16
    }

    private static func contentMode(
        forWorkspaceWidth workspaceWidth: CGFloat,
        contentWidth: CGFloat
    ) -> AdaptiveLayoutMode {
        if contentWidth < compactContentUpperBound {
            return .compact
        }
        if workspaceWidth < wideContentLowerBound {
            return .medium
        }
        return .wide
    }
}

public enum SyncActionIntent: Sendable, Equatable {
    case run
    case cancel

    public static func capture(isRunning: Bool) -> SyncActionIntent {
        isRunning ? .cancel : .run
    }
}

/// Keeps a cancellation request attached to the exact run that received it.
/// Connection/session resets must not turn a request for one run into either a
/// cancellation of a later run or no cancellation at all.
public struct RunCancellationIntent<Identity>: Sendable where Identity: Equatable & Sendable {
    public private(set) var requestedIdentity: Identity?

    public init(requestedIdentity: Identity? = nil) {
        self.requestedIdentity = requestedIdentity
    }

    public mutating func request(for identity: Identity) {
        requestedIdentity = identity
    }

    public func isRequested(for identity: Identity) -> Bool {
        requestedIdentity == identity
    }

    public mutating func clear(ifMatching identity: Identity) {
        guard requestedIdentity == identity else { return }
        requestedIdentity = nil
    }

    public mutating func clear() {
        requestedIdentity = nil
    }
}

public enum RelayExecutionOwner: Sendable, Equatable {
    case localRun(UInt64)
    case remoteCommand(UUID)
}

/// A main-actor-owned, non-suspending claim gate for command execution. The
/// caller claims before its first network await and releases only its own claim.
public struct RelayExecutionGate: Sendable, Equatable {
    public private(set) var owner: RelayExecutionOwner?

    public init(owner: RelayExecutionOwner? = nil) {
        self.owner = owner
    }

    public var isClaimed: Bool {
        owner != nil
    }

    @discardableResult
    public mutating func claim(_ candidate: RelayExecutionOwner) -> Bool {
        guard let owner else {
            self.owner = candidate
            return true
        }
        return owner == candidate
    }

    public func isOwned(by candidate: RelayExecutionOwner) -> Bool {
        owner == candidate
    }

    public mutating func release(ifOwnedBy candidate: RelayExecutionOwner) {
        guard owner == candidate else { return }
        owner = nil
    }
}

public enum RemoteCommandActionIntent: Sendable, Equatable {
    case run(RemoteCommandKind)
    case cancel(kind: RemoteCommandKind, commandID: UUID)

    public static func capture(
        kind: RemoteCommandKind,
        activeCommand: RemoteRunCommand?
    ) -> RemoteCommandActionIntent {
        guard let activeCommand,
              activeCommand.kind == kind,
              activeCommand.displayStatus().isInFlight else {
            return .run(kind)
        }
        return .cancel(kind: kind, commandID: activeCommand.id)
    }
}

public enum RemoteCommandMonotonicMergePolicy {
    public static func preferred(
        current: RemoteRunCommand?,
        incoming: RemoteRunCommand
    ) -> RemoteRunCommand {
        guard let current, current.id == incoming.id else {
            return incoming
        }

        let currentIsTerminal = current.status.isTerminal
        let incomingIsTerminal = incoming.status.isTerminal
        if currentIsTerminal != incomingIsTerminal {
            return currentIsTerminal ? current : incoming
        }
        if current.updatedAt != incoming.updatedAt {
            return current.updatedAt > incoming.updatedAt ? current : incoming
        }
        if current.status == .running, incoming.status == .pending {
            return current
        }
        return incoming
    }
}

/// Starts independent relay reads together and hands each result to the main
/// actor as soon as that read completes. A slow snapshot must not become a
/// barrier for smaller status, command, or action responses that are already
/// ready to update the UI.
public enum RelayEndpointCompletionConsumer {
    public static func consume<Input: Sendable, Output: Sendable>(
        _ operations: [@Sendable () async -> Input],
        onCompletion: @MainActor @escaping @Sendable (Input) -> Output
    ) async -> [Output] {
        await withTaskGroup(of: Input.self, returning: [Output].self) { group in
            for operation in operations {
                group.addTask {
                    await operation()
                }
            }

            var outputs = [Output]()
            outputs.reserveCapacity(operations.count)
            for await input in group {
                outputs.append(await onCompletion(input))
            }
            return outputs
        }
    }
}

public enum RelayRealtimePreviewPolicy {
    private static let workerScopes: Set<RelayEventScope> = [
        .status,
        .commands,
        .itemActions,
        .settingActions,
        .fileAccess,
        .requestLog,
        .cancel,
    ]
    private static let snapshotScopes: Set<RelayEventScope> = [
        .syncData,
        .runLogs,
        .sharedSettings,
    ]

    public static func shouldStartWorkerPreview(
        snapshotRefreshIsInFlight: Bool,
        scopes: Set<RelayEventScope>
    ) -> Bool {
        snapshotRefreshIsInFlight && !scopes.isDisjoint(with: workerScopes)
    }

    public static func shouldStartSnapshotPreview(
        snapshotRefreshIsInFlight: Bool,
        scopes: Set<RelayEventScope>,
        requiresSnapshot: Bool = false
    ) -> Bool {
        snapshotRefreshIsInFlight
            && (requiresSnapshot || !scopes.isDisjoint(with: snapshotScopes))
    }
}

public struct RelayEndpointApplyEpochs<Endpoint: Hashable & Sendable>: Sendable {
    private var storage: [Endpoint: UInt64] = [:]

    public init() {}

    @discardableResult
    public mutating func begin(for endpoint: Endpoint) -> UInt64 {
        let next = (storage[endpoint] ?? 0) &+ 1
        storage[endpoint] = next
        return next
    }

    public func owns(endpoint: Endpoint, epoch: UInt64) -> Bool {
        storage[endpoint] == epoch
    }

    public mutating func reset() {
        storage.removeAll(keepingCapacity: false)
    }
}

public enum RelayEventScope: String, Codable, CaseIterable, Sendable, Hashable {
    case status
    case syncData
    case commands
    case itemActions
    case settingActions
    case sharedSettings
    case runLogs
    case fileAccess
    case requestLog
    case cancel
}

public enum RelayEventType: String, Codable, Sendable {
    case hello
    case changed
    case ping
    case pong
}

/// A lossless-enough JSON representation for the relay's optional, scope-specific
/// delta. Clients keep this payload opaque until a scope has a versioned delta
/// schema and continue to reconcile the affected HTTP snapshot.
public indirect enum RelayJSONValue: Codable, Sendable, Equatable {
    case object([String: RelayJSONValue])
    case array([RelayJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: RelayJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([RelayJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported relay event delta value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct RelayEventEnvelope: Codable, Sendable, Equatable {
    public var version: Int
    public var type: RelayEventType?
    public var revision: Int64?
    public var eventID: String?
    public var sessionID: String?
    public var reason: String?
    public var scopes: [RelayEventScope]
    public var delta: [String: RelayJSONValue]?
    public var requiresSnapshot: Bool
    public var sentAt: String?
    public var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case version
        case type
        case revision
        case eventID
        case sessionID
        case reason
        case scopes
        case delta
        case requiresSnapshot
        case sentAt
        case updatedAt
    }

    public init(
        version: Int = 1,
        type: RelayEventType? = nil,
        revision: Int64? = nil,
        eventID: String? = nil,
        sessionID: String? = nil,
        reason: String? = nil,
        scopes: [RelayEventScope] = [],
        delta: [String: RelayJSONValue]? = nil,
        requiresSnapshot: Bool = false,
        sentAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.version = version
        self.type = type
        self.revision = revision
        self.eventID = eventID
        self.sessionID = sessionID
        self.reason = reason
        self.scopes = scopes
        self.delta = delta
        self.requiresSnapshot = requiresSnapshot
        self.sentAt = sentAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        type = try container.decodeIfPresent(RelayEventType.self, forKey: .type)
        revision = try container.decodeIfPresent(Int64.self, forKey: .revision)
        eventID = try container.decodeIfPresent(String.self, forKey: .eventID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        scopes = (try? container.decode([RelayEventScope].self, forKey: .scopes)) ?? []
        delta = try? container.decodeIfPresent([String: RelayJSONValue].self, forKey: .delta)
        requiresSnapshot = try container.decodeIfPresent(Bool.self, forKey: .requiresSnapshot) ?? false
        sentAt = try container.decodeIfPresent(String.self, forKey: .sentAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

public enum RelayWebSocketHandshakeObservation: Sendable, Equatable {
    case accepted
    case rejected
}

/// A relay socket is usable only after the server proves that it speaks the
/// expected versioned protocol with its first frame. Merely opening the TCP/WebSocket
/// transport is not a successful relay connection.
public struct RelayWebSocketHandshakeState: Sendable, Equatable {
    public private(set) var isAwaitingHello = true
    public private(set) var isConnected = false

    public init() {}

    public mutating func observeFirstFrame(
        _ event: RelayEventEnvelope?
    ) -> RelayWebSocketHandshakeObservation {
        guard isAwaitingHello else {
            return isConnected ? .accepted : .rejected
        }
        isAwaitingHello = false
        guard let event, event.version == 1, event.type == .hello else {
            isConnected = false
            return .rejected
        }
        isConnected = true
        return .accepted
    }
}

public enum RelayEventApplyDecision: Sendable, Equatable {
    case ignore
    case apply
    case reconcileSnapshot
}

public struct RelayEventCursor: Sendable, Equatable {
    public private(set) var connectionGeneration: UInt64
    public private(set) var lastAppliedRevision: Int64?
    public private(set) var lastObservedRevision: Int64?

    public init(
        connectionGeneration: UInt64 = 0,
        lastAppliedRevision: Int64? = nil,
        lastObservedRevision: Int64? = nil
    ) {
        self.connectionGeneration = connectionGeneration
        self.lastAppliedRevision = lastAppliedRevision
        self.lastObservedRevision = lastObservedRevision ?? lastAppliedRevision
    }

    @discardableResult
    public mutating func beginConnection() -> UInt64 {
        connectionGeneration &+= 1
        lastAppliedRevision = nil
        lastObservedRevision = nil
        return connectionGeneration
    }

    public func isCurrent(generation: UInt64) -> Bool {
        generation == connectionGeneration
    }

    /// Classifies an event without claiming that its HTTP snapshot was applied.
    /// `markApplied(revision:)` is the commit point after reconciliation succeeds.
    public mutating func decision(for event: RelayEventEnvelope) -> RelayEventApplyDecision {
        guard event.version == 1 else {
            return .reconcileSnapshot
        }
        if event.type == .ping {
            return .ignore
        }
        if event.type == .pong {
            guard let revision = event.revision else {
                return .ignore
            }
            if let lastObservedRevision, revision <= lastObservedRevision {
                return .ignore
            }
            lastObservedRevision = revision
            return .reconcileSnapshot
        }
        guard let revision = event.revision else {
            return event.requiresSnapshot ? .reconcileSnapshot : .apply
        }
        if let lastObservedRevision {
            if revision <= lastObservedRevision {
                return .ignore
            }
            if revision > lastObservedRevision + 1 || event.requiresSnapshot {
                self.lastObservedRevision = revision
                return .reconcileSnapshot
            }
        } else if event.type == .hello || event.requiresSnapshot {
            lastObservedRevision = revision
            return .reconcileSnapshot
        }
        lastObservedRevision = revision
        return .apply
    }

    public mutating func markApplied(revision: Int64?) {
        guard let revision else { return }
        if lastAppliedRevision == nil || revision > lastAppliedRevision! {
            lastAppliedRevision = revision
        }
        if lastObservedRevision == nil || revision > lastObservedRevision! {
            lastObservedRevision = revision
        }
    }
}

public struct RelayDirtyScopeAccumulator: Sendable, Equatable {
    private var storage = Set<RelayEventScope>()
    public private(set) var requiresSnapshot = false
    public private(set) var highestRevision: Int64?

    public init() {}

    public var scopes: Set<RelayEventScope> { storage }
    public var isEmpty: Bool { storage.isEmpty && !requiresSnapshot }

    public mutating func insert(
        _ scopes: some Sequence<RelayEventScope>,
        requiresSnapshot: Bool = false,
        revision: Int64? = nil
    ) {
        storage.formUnion(scopes)
        self.requiresSnapshot = self.requiresSnapshot || requiresSnapshot
        if let revision, highestRevision == nil || revision > highestRevision! {
            highestRevision = revision
        }
    }

    public mutating func drain() -> (
        scopes: Set<RelayEventScope>,
        requiresSnapshot: Bool,
        highestRevision: Int64?
    ) {
        let result = (storage, requiresSnapshot, highestRevision)
        storage.removeAll(keepingCapacity: true)
        requiresSnapshot = false
        highestRevision = nil
        return result
    }

    public mutating func reset() {
        storage.removeAll(keepingCapacity: false)
        requiresSnapshot = false
        highestRevision = nil
    }
}

public enum RemoteCommandCompletionStatus {
    public static func resolve(wasCancelled: Bool, succeeded: Bool) -> RemoteCommandStatus {
        if wasCancelled {
            return .cancelled
        }
        return succeeded ? .completed : .failed
    }
}

public enum RelayReconnectBackoff {
    private static let delays: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000]
    private static let maximumDelay: UInt64 = 2_000_000_000
    private static let jitterRatio = 0.1

    public static func nanoseconds(forAttempt attempt: Int) -> UInt64 {
        nanoseconds(
            forAttempt: attempt,
            jitterFraction: Double.random(in: -1...1)
        )
    }

    public static func nanoseconds(forAttempt attempt: Int, jitterFraction: Double) -> UInt64 {
        let base = Double(delays[min(max(attempt, 0), delays.count - 1)])
        let boundedJitter = min(max(jitterFraction, -1), 1)
        let jittered = base * (1 + boundedJitter * jitterRatio)
        return min(UInt64(max(jittered.rounded(), 0)), maximumDelay)
    }
}

public struct RelaySessionGeneration: Sendable, Equatable {
    public private(set) var current: UInt64

    public init(current: UInt64 = 0) {
        self.current = current
    }

    @discardableResult
    public mutating func reset() -> UInt64 {
        current &+= 1
        return current
    }

    public func isCurrent(_ generation: UInt64) -> Bool {
        current == generation
    }
}

public struct RelayOperationOwner: Sendable, Equatable {
    public private(set) var currentID: UInt64

    public init(currentID: UInt64 = 0) {
        self.currentID = currentID
    }

    @discardableResult
    public mutating func begin() -> UInt64 {
        currentID &+= 1
        return currentID
    }

    public mutating func invalidate() {
        currentID &+= 1
    }

    public func owns(_ operationID: UInt64) -> Bool {
        currentID == operationID
    }
}

public enum RelayEventBatchSchedulingPolicy {
    public static func shouldScheduleDeferredScopes(
        commandIsRunning: Bool,
        hasDirtyScopes: Bool
    ) -> Bool {
        !commandIsRunning && hasDirtyScopes
    }
}

public enum RelayRealtimeWorkStage: Sendable, Equatable {
    case workerInbox
    case dashboardSnapshot
}

public enum RelayRealtimeWorkOrder {
    public static func stages(
        refreshesWorker: Bool,
        refreshesDashboard: Bool
    ) -> [RelayRealtimeWorkStage] {
        var result = [RelayRealtimeWorkStage]()
        if refreshesWorker {
            result.append(.workerInbox)
        }
        if refreshesDashboard {
            result.append(.dashboardSnapshot)
        }
        return result
    }
}

public enum RelayMutationBaselinePolicy {
    public static func shouldAcceptResponse(
        requestObservationVersion: UInt64,
        currentObservationVersion: UInt64,
        responseIsStrictlyNewer: Bool
    ) -> Bool {
        requestObservationVersion == currentObservationVersion || responseIsStrictlyNewer
    }
}

public enum RelaySnapshotApplyDecision: Sendable, Equatable {
    case apply
    case superseded
    case invalidated
}

public enum RelaySnapshotApplyPolicy {
    public static func decision(
        fetchSessionGeneration: UInt64,
        currentSessionGeneration: UInt64,
        fetchOperationID: UInt64,
        currentOperationID: UInt64,
        fetchMutationEpoch: UInt64,
        currentMutationEpoch: UInt64
    ) -> RelaySnapshotApplyDecision {
        guard fetchSessionGeneration == currentSessionGeneration else { return .invalidated }
        guard fetchOperationID == currentOperationID else { return .superseded }
        guard fetchMutationEpoch == currentMutationEpoch else { return .invalidated }
        return .apply
    }
}

public struct RelayClaimedTerminalDisposition: Sendable, Equatable {
    public var persistsTerminalState: Bool
    public var appliesVisibleState: Bool

    public init(persistsTerminalState: Bool, appliesVisibleState: Bool) {
        self.persistsTerminalState = persistsTerminalState
        self.appliesVisibleState = appliesVisibleState
    }
}

public enum RelayClaimedOperationPolicy {
    public static func terminalDisposition(
        originalSessionIsCurrent: Bool
    ) -> RelayClaimedTerminalDisposition {
        RelayClaimedTerminalDisposition(
            persistsTerminalState: true,
            appliesVisibleState: originalSessionIsCurrent
        )
    }
}

@MainActor
public final class KeyedSerialTaskQueue<Key: Hashable> {
    private struct Entry {
        var id: UInt64
        var task: Task<Void, Never>
    }

    private var nextID: UInt64 = 0
    private var tails: [Key: Entry] = [:]
    private var operations: [UInt64: Task<Void, Never>] = [:]

    public init() {}

    public func enqueue(
        for key: Key,
        operation: @escaping @MainActor () async -> Void
    ) async {
        nextID &+= 1
        let operationID = nextID
        let predecessor = tails[key]?.task
        let task = Task { @MainActor in
            _ = await predecessor?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        tails[key] = Entry(id: operationID, task: task)
        operations[operationID] = task
        await task.value
        operations.removeValue(forKey: operationID)
        if tails[key]?.id == operationID {
            tails.removeValue(forKey: key)
        }
    }

    public func cancelAll() {
        operations.values.forEach { $0.cancel() }
        tails.values.forEach { $0.task.cancel() }
        operations.removeAll()
        tails.removeAll()
    }
}

public struct KeyedCommittedBaselineTracker<Key: Hashable, Value> {
    private struct Entry {
        var generation: UInt64
        var value: Value?
    }

    private var entries: [Key: Entry] = [:]

    public init() {}

    public mutating func beginMutation(
        for key: Key,
        generation: UInt64,
        committedValue: Value?
    ) {
        guard entries[key]?.generation != generation else { return }
        entries[key] = Entry(generation: generation, value: committedValue)
    }

    public mutating func recordCommittedValue(
        _ value: Value?,
        for key: Key,
        generation: UInt64
    ) {
        guard entries[key]?.generation == generation else { return }
        entries[key] = Entry(generation: generation, value: value)
    }

    public func committedValue(for key: Key, generation: UInt64) -> Value? {
        guard let entry = entries[key], entry.generation == generation else { return nil }
        return entry.value
    }

    public mutating func endMutationChain(for key: Key, generation: UInt64) {
        guard entries[key]?.generation == generation else { return }
        entries.removeValue(forKey: key)
    }

    public mutating func reset() {
        entries.removeAll()
    }
}

public struct KeyedMutationVersionTracker<Key: Hashable> {
    private var nextVersion: UInt64 = 0
    private var versions: [Key: UInt64] = [:]

    public init() {}

    public mutating func begin(for key: Key) -> UInt64? {
        guard versions[key] == nil else { return nil }
        nextVersion &+= 1
        versions[key] = nextVersion
        return nextVersion
    }

    public func owns(key: Key, version: UInt64) -> Bool {
        versions[key] == version
    }

    @discardableResult
    public mutating func end(key: Key, version: UInt64) -> Bool {
        guard owns(key: key, version: version) else { return false }
        versions.removeValue(forKey: key)
        return true
    }

    public mutating func reset() {
        versions.removeAll()
    }
}

public enum OptimisticRollbackPolicy {
    public static func shouldRestore<Value: Equatable>(
        ownsCurrentVersion: Bool,
        currentValue: Value,
        optimisticValue: Value
    ) -> Bool {
        ownsCurrentVersion && currentValue == optimisticValue
    }
}

public enum RelayHeartbeatPolicy {
    public static let helloTimeoutNanoseconds: UInt64 = 10_000_000_000
    public static let intervalNanoseconds: UInt64 = 10_000_000_000
    public static let staleTimeout: TimeInterval = 40

    public static func isStale(lastMessageAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastMessageAt) >= staleTimeout
    }
}
