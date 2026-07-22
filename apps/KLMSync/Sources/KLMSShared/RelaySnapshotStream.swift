import CryptoKit
import Foundation

public enum RelaySnapshotProtocol {
    public static let version = 1
    public static let maximumFrameBytes = 64 * 1024
    public static let maximumStreamBytes = 8 * 1024 * 1024
    public static let maximumChunkCount = 254
}

public struct RelayRealtimeSnapshotPayload: Codable, Sendable, Equatable {
    public var version: Int
    public var revision: Int64
    public var scopes: [RelayEventScope]
    public var requestID: String?
    public var status: LocalRemoteResponse?
    public var commands: ServerRelayCommandListResponse?
    public var syncData: ServerRelaySyncData?
    public var itemActions: ServerRelayItemActionListResponse?
    public var settingActions: ServerRelaySettingActionListResponse?
    public var fileAccess: ServerRelayFileAccessListResponse?
    public var requestLog: ServerRelayRequestLogResponse?
    public var sharedSettings: ServerRelaySettingListResponse?
    public var workerInbox: ServerRelayWorkerInbox?
}

public struct RelaySnapshotRequestFrame: Codable, Sendable, Equatable {
    public var version: Int
    public var type: String
    public var sessionID: String
    public var requestID: String
    public var revision: Int64
    public var scopes: [RelayEventScope]

    public init(sessionID: String, requestID: String, revision: Int64, scopes: [RelayEventScope]) {
        version = RelaySnapshotProtocol.version
        type = "snapshot-request"
        self.sessionID = sessionID
        self.requestID = requestID
        self.revision = revision
        self.scopes = scopes
    }
}

public struct RelaySnapshotReadyFrame: Codable, Sendable, Equatable {
    public var version: Int
    public var type: String
    public var sessionID: String
    public var streamID: String
    public var revision: Int64
    public var reservedFrames: Int
    public var reservedWireBytes: String

    public init(
        sessionID: String,
        streamID: String,
        revision: Int64,
        reservedFrames: Int,
        reservedWireBytes: String
    ) {
        version = RelaySnapshotProtocol.version
        type = "snapshot-ready"
        self.sessionID = sessionID
        self.streamID = streamID
        self.revision = revision
        self.reservedFrames = reservedFrames
        self.reservedWireBytes = reservedWireBytes
    }
}

public struct RelaySnapshotFrame: Codable, Sendable, Equatable {
    public var version: Int
    public var type: String
    public var sessionID: String
    public var streamID: String
    public var revision: Int64
    public var scopes: [RelayEventScope]
    public var requestID: String?
    public var chunkCount: Int
    public var totalPayloadBytes: String
    public var reservedFrames: Int
    public var reservedWireBytes: String
    public var payloadSHA256: String
    public var index: Int
    public var payloadBytes: String
    public var payload: String?
}

public enum RelaySnapshotStreamResult: Sendable, Equatable {
    case ready(RelaySnapshotReadyFrame)
    case staged
    case complete(RelayRealtimeSnapshotPayload)
}

public struct RelaySnapshotStreamError: Error, Sendable, Equatable {
    public var closeCode: Int
    public var reason: String

    public init(closeCode: Int, reason: String) {
        self.closeCode = closeCode
        self.reason = reason
    }
}

public struct RelaySnapshotStreamAssembler: Sendable {
    private struct Reservation: Sendable {
        var begin: RelaySnapshotFrame
        var expectedIndex: Int
        var stagedPayload: Data
        var receivedWireBytes: Int
    }

    private var reservation: Reservation?

    public init() {}

    public var isReserved: Bool { reservation != nil }

    public mutating func discard() {
        reservation = nil
    }

    public mutating func ingest(
        _ data: Data,
        expectedSessionID: String
    ) throws -> RelaySnapshotStreamResult {
        guard data.count <= RelaySnapshotProtocol.maximumFrameBytes else {
            throw RelaySnapshotStreamError(closeCode: 1009, reason: "snapshot frame too large")
        }
        let frame: RelaySnapshotFrame
        do {
            frame = try JSONDecoder().decode(RelaySnapshotFrame.self, from: data)
        } catch {
            throw RelaySnapshotStreamError(closeCode: 1002, reason: "invalid snapshot frame")
        }
        guard frame.version == RelaySnapshotProtocol.version,
              frame.sessionID == expectedSessionID,
              UUID(uuidString: frame.sessionID) != nil,
              UUID(uuidString: frame.streamID) != nil,
              frame.revision >= 0,
              !frame.scopes.isEmpty,
              Set(frame.scopes).count == frame.scopes.count,
              frame.chunkCount > 0,
              frame.chunkCount <= RelaySnapshotProtocol.maximumChunkCount,
              frame.reservedFrames == frame.chunkCount + 2,
              frame.reservedFrames <= 256,
              frame.payloadSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let totalPayloadBytes = Self.hexByteCount(frame.totalPayloadBytes),
              let reservedWireBytes = Self.hexByteCount(frame.reservedWireBytes),
              let declaredPayloadBytes = Self.hexByteCount(frame.payloadBytes) else {
            throw RelaySnapshotStreamError(closeCode: 1002, reason: "invalid snapshot binding")
        }
        guard totalPayloadBytes <= RelaySnapshotProtocol.maximumStreamBytes else {
            throw RelaySnapshotStreamError(closeCode: 1009, reason: "snapshot payload too large")
        }
        guard reservedWireBytes <= RelaySnapshotProtocol.maximumStreamBytes else {
            throw RelaySnapshotStreamError(closeCode: 1013, reason: "snapshot reservation unavailable")
        }

        switch frame.type {
        case "snapshot-begin":
            guard reservation == nil,
                  frame.index == -1,
                  declaredPayloadBytes == 0,
                  frame.payload == nil else {
                throw RelaySnapshotStreamError(closeCode: 1002, reason: "invalid snapshot begin order")
            }
            var staged = Data()
            staged.reserveCapacity(totalPayloadBytes)
            reservation = Reservation(
                begin: frame,
                expectedIndex: 0,
                stagedPayload: staged,
                receivedWireBytes: data.count
            )
            return .ready(RelaySnapshotReadyFrame(
                sessionID: frame.sessionID,
                streamID: frame.streamID,
                revision: frame.revision,
                reservedFrames: frame.reservedFrames,
                reservedWireBytes: frame.reservedWireBytes
            ))
        case "snapshot-chunk":
            guard var current = reservation,
                  Self.matches(frame, current.begin),
                  frame.index == current.expectedIndex,
                  frame.index < frame.chunkCount,
                  let encoded = frame.payload,
                  let chunk = Data(base64Encoded: encoded),
                  chunk.base64EncodedString() == encoded,
                  chunk.count == declaredPayloadBytes,
                  current.stagedPayload.count + chunk.count <= totalPayloadBytes else {
                reservation = nil
                throw RelaySnapshotStreamError(closeCode: 1002, reason: "invalid snapshot chunk")
            }
            current.stagedPayload.append(chunk)
            current.expectedIndex += 1
            current.receivedWireBytes += data.count
            reservation = current
            return .staged
        case "snapshot-end":
            guard let current = reservation,
                  Self.matches(frame, current.begin),
                  current.expectedIndex == frame.chunkCount,
                  frame.index == frame.chunkCount,
                  declaredPayloadBytes == 0,
                  frame.payload == nil,
                  current.stagedPayload.count == totalPayloadBytes,
                  current.receivedWireBytes + data.count == reservedWireBytes else {
                reservation = nil
                throw RelaySnapshotStreamError(closeCode: 1002, reason: "invalid snapshot end")
            }
            let digest = SHA256.hash(data: current.stagedPayload)
                .map { String(format: "%02x", $0) }
                .joined()
            guard digest == frame.payloadSHA256 else {
                reservation = nil
                throw RelaySnapshotStreamError(closeCode: 1002, reason: "snapshot digest mismatch")
            }
            let payload: RelayRealtimeSnapshotPayload
            do {
                payload = try JSONDecoder.klmsLocalRemote.decode(
                    RelayRealtimeSnapshotPayload.self,
                    from: current.stagedPayload
                )
            } catch {
                reservation = nil
                throw RelaySnapshotStreamError(closeCode: 1002, reason: "invalid snapshot payload")
            }
            guard payload.version == RelaySnapshotProtocol.version,
                  payload.revision == frame.revision,
                  payload.scopes == frame.scopes,
                  payload.requestID == frame.requestID else {
                reservation = nil
                throw RelaySnapshotStreamError(closeCode: 1002, reason: "snapshot payload binding mismatch")
            }
            reservation = nil
            return .complete(payload)
        default:
            reservation = nil
            throw RelaySnapshotStreamError(closeCode: 1002, reason: "unsupported snapshot frame")
        }
    }

    private static func matches(_ frame: RelaySnapshotFrame, _ begin: RelaySnapshotFrame) -> Bool {
        frame.sessionID == begin.sessionID
            && frame.streamID == begin.streamID
            && frame.revision == begin.revision
            && frame.scopes == begin.scopes
            && frame.requestID == begin.requestID
            && frame.chunkCount == begin.chunkCount
            && frame.totalPayloadBytes == begin.totalPayloadBytes
            && frame.reservedFrames == begin.reservedFrames
            && frame.reservedWireBytes == begin.reservedWireBytes
            && frame.payloadSHA256 == begin.payloadSHA256
    }

    private static func hexByteCount(_ value: String) -> Int? {
        guard value.range(of: #"^[0-9a-f]{16}$"#, options: .regularExpression) != nil,
              let parsed = UInt64(value, radix: 16),
              parsed <= UInt64(Int.max) else {
            return nil
        }
        return Int(parsed)
    }
}
