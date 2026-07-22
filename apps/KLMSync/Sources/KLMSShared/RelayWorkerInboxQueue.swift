import Foundation

public enum RelayWorkerInboxConsumptionDecision: Sendable, Equatable {
    case useStreamed
    case fetchBootstrap
    case awaitFreshStream
}

public enum RelayWorkerInboxConsumptionPolicy {
    public static func decision(
        hasStreamedInbox: Bool,
        replayedTerminalState: Bool
    ) -> RelayWorkerInboxConsumptionDecision {
        guard hasStreamedInbox else { return .fetchBootstrap }
        return replayedTerminalState ? .awaitFreshStream : .useStreamed
    }

    public static func shouldScheduleNetworkFollowUp(
        after decision: RelayWorkerInboxConsumptionDecision
    ) -> Bool {
        decision == .fetchBootstrap
    }
}

public struct RelayWorkerInboxQueue: Sendable, Equatable {
    private var latest: ServerRelayWorkerInbox?

    public init() {}

    public var hasValue: Bool {
        latest != nil
    }

    public var current: ServerRelayWorkerInbox? {
        latest
    }

    public mutating func replace(with inbox: ServerRelayWorkerInbox) {
        latest = inbox
    }

    public mutating func take() -> ServerRelayWorkerInbox? {
        defer { latest = nil }
        return latest
    }

    public mutating func reset() {
        latest = nil
    }
}
