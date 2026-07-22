import CryptoKit
import Foundation
import XCTest
@testable import KLMSShared

final class RelaySnapshotStreamTests: XCTestCase {
    private struct Fixture {
        var sessionID: String
        var requestID: String?
        var payload: RelayRealtimeSnapshotPayload
        var begin: Data
        var dataFrames: [Data]
    }

    func testMultiFrameSnapshotBecomesVisibleOnlyAfterAuthenticatedEnd() throws {
        let fixture = try makeFixture(extraPayloadBytes: 120_000)
        var assembler = RelaySnapshotStreamAssembler()

        guard case .ready(let ready) = try assembler.ingest(
            fixture.begin,
            expectedSessionID: fixture.sessionID
        ) else {
            return XCTFail("The first frame did not reserve the stream.")
        }
        XCTAssertTrue(assembler.isReserved)
        XCTAssertGreaterThan(ready.reservedFrames, 3)

        for frame in fixture.dataFrames.dropLast() {
            XCTAssertEqual(
                try assembler.ingest(frame, expectedSessionID: fixture.sessionID),
                .staged
            )
            XCTAssertTrue(assembler.isReserved)
        }
        XCTAssertEqual(
            try assembler.ingest(fixture.dataFrames.last!, expectedSessionID: fixture.sessionID),
            .complete(fixture.payload)
        )
        XCTAssertFalse(assembler.isReserved)
    }

    func testReorderedDuplicateAndCrossSessionChunksAreRejected() throws {
        let fixture = try makeFixture(extraPayloadBytes: 120_000)
        let chunks = Array(fixture.dataFrames.dropLast())
        XCTAssertGreaterThanOrEqual(chunks.count, 2)

        var reordered = RelaySnapshotStreamAssembler()
        _ = try reordered.ingest(fixture.begin, expectedSessionID: fixture.sessionID)
        assertStreamError(1002) {
            _ = try reordered.ingest(chunks[1], expectedSessionID: fixture.sessionID)
        }

        var duplicated = RelaySnapshotStreamAssembler()
        _ = try duplicated.ingest(fixture.begin, expectedSessionID: fixture.sessionID)
        XCTAssertEqual(
            try duplicated.ingest(chunks[0], expectedSessionID: fixture.sessionID),
            .staged
        )
        assertStreamError(1002) {
            _ = try duplicated.ingest(chunks[0], expectedSessionID: fixture.sessionID)
        }

        var crossSession = RelaySnapshotStreamAssembler()
        _ = try crossSession.ingest(fixture.begin, expectedSessionID: fixture.sessionID)
        assertStreamError(1002) {
            _ = try crossSession.ingest(chunks[0], expectedSessionID: UUID().uuidString)
        }
    }

    func testDigestCorruptionIsRejectedAtEnd() throws {
        let fixture = try makeFixture(extraPayloadBytes: 64)
        var assembler = RelaySnapshotStreamAssembler()
        _ = try assembler.ingest(fixture.begin, expectedSessionID: fixture.sessionID)

        var chunk = try JSONDecoder().decode(RelaySnapshotFrame.self, from: fixture.dataFrames[0])
        let firstCharacter = chunk.payload!.first == "A" ? "B" : "A"
        chunk.payload = firstCharacter + chunk.payload!.dropFirst()
        let corruptedChunk = try frameEncoder().encode(chunk)
        XCTAssertEqual(
            try assembler.ingest(corruptedChunk, expectedSessionID: fixture.sessionID),
            .staged
        )
        assertStreamError(1002) {
            _ = try assembler.ingest(
                fixture.dataFrames.last!,
                expectedSessionID: fixture.sessionID
            )
        }
        XCTAssertFalse(assembler.isReserved)
    }

    func testFramePayloadAndReservationLimitsAreEnforcedBeforeStaging() throws {
        let fixture = try makeFixture(extraPayloadBytes: 64)
        var frameTooLarge = RelaySnapshotStreamAssembler()
        assertStreamError(1009) {
            _ = try frameTooLarge.ingest(
                Data(repeating: 0x78, count: RelaySnapshotProtocol.maximumFrameBytes + 1),
                expectedSessionID: fixture.sessionID
            )
        }

        var oversizedPayloadFrame = try JSONDecoder().decode(
            RelaySnapshotFrame.self,
            from: fixture.begin
        )
        oversizedPayloadFrame.totalPayloadBytes = "0000000000800001"
        var oversizedPayload = RelaySnapshotStreamAssembler()
        assertStreamError(1009) {
            _ = try oversizedPayload.ingest(
                frameEncoder().encode(oversizedPayloadFrame),
                expectedSessionID: fixture.sessionID
            )
        }

        var unavailableReservationFrame = try JSONDecoder().decode(
            RelaySnapshotFrame.self,
            from: fixture.begin
        )
        unavailableReservationFrame.reservedWireBytes = "0000000000800001"
        var unavailableReservation = RelaySnapshotStreamAssembler()
        assertStreamError(1013) {
            _ = try unavailableReservation.ingest(
                frameEncoder().encode(unavailableReservationFrame),
                expectedSessionID: fixture.sessionID
            )
        }
    }

    func testManualRequestBindsSessionRequestRevisionAndScopes() throws {
        let sessionID = UUID().uuidString.lowercased()
        let requestID = UUID().uuidString.lowercased()
        let request = RelaySnapshotRequestFrame(
            sessionID: sessionID,
            requestID: requestID,
            revision: 9,
            scopes: [.status, .commands]
        )
        let decoded = try JSONDecoder().decode(
            RelaySnapshotRequestFrame.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded.version, RelaySnapshotProtocol.version)
        XCTAssertEqual(decoded.type, "snapshot-request")
        XCTAssertEqual(decoded.sessionID, sessionID)
        XCTAssertEqual(decoded.requestID, requestID)
        XCTAssertEqual(decoded.revision, 9)
        XCTAssertEqual(decoded.scopes, [.status, .commands])
    }

    private func makeFixture(extraPayloadBytes: Int) throws -> Fixture {
        let sessionID = UUID().uuidString.lowercased()
        let requestID = UUID().uuidString.lowercased()
        let revision: Int64 = 17
        let scopes: [RelayEventScope] = [.status, .syncData]
        let payloadObject: [String: Any] = [
            "version": RelaySnapshotProtocol.version,
            "revision": revision,
            "scopes": scopes.map(\.rawValue),
            "requestID": requestID,
            "padding": String(repeating: "x", count: extraPayloadBytes),
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys])
        let payload = try JSONDecoder.klmsLocalRemote.decode(
            RelayRealtimeSnapshotPayload.self,
            from: payloadData
        )
        let rawChunkBytes = 43 * 1024
        let chunks: [Data] = stride(from: 0, to: max(payloadData.count, 1), by: rawChunkBytes).map { offset in
            payloadData.subdata(in: offset..<min(payloadData.count, offset + rawChunkBytes))
        }
        XCTAssertLessThanOrEqual(chunks.count, RelaySnapshotProtocol.maximumChunkCount)
        let streamID = UUID().uuidString.lowercased()
        let digest = SHA256.hash(data: payloadData)
            .map { String(format: "%02x", $0) }
            .joined()
        let totalPayloadBytes = fixedHex(payloadData.count)
        let reservedFrames = chunks.count + 2
        var frames = [RelaySnapshotFrame(
            version: RelaySnapshotProtocol.version,
            type: "snapshot-begin",
            sessionID: sessionID,
            streamID: streamID,
            revision: revision,
            scopes: scopes,
            requestID: requestID,
            chunkCount: chunks.count,
            totalPayloadBytes: totalPayloadBytes,
            reservedFrames: reservedFrames,
            reservedWireBytes: "0000000000000000",
            payloadSHA256: digest,
            index: -1,
            payloadBytes: fixedHex(0),
            payload: nil
        )]
        frames.append(contentsOf: chunks.enumerated().map { index, chunk in
            RelaySnapshotFrame(
                version: RelaySnapshotProtocol.version,
                type: "snapshot-chunk",
                sessionID: sessionID,
                streamID: streamID,
                revision: revision,
                scopes: scopes,
                requestID: requestID,
                chunkCount: chunks.count,
                totalPayloadBytes: totalPayloadBytes,
                reservedFrames: reservedFrames,
                reservedWireBytes: "0000000000000000",
                payloadSHA256: digest,
                index: index,
                payloadBytes: fixedHex(chunk.count),
                payload: chunk.base64EncodedString()
            )
        })
        frames.append(RelaySnapshotFrame(
            version: RelaySnapshotProtocol.version,
            type: "snapshot-end",
            sessionID: sessionID,
            streamID: streamID,
            revision: revision,
            scopes: scopes,
            requestID: requestID,
            chunkCount: chunks.count,
            totalPayloadBytes: totalPayloadBytes,
            reservedFrames: reservedFrames,
            reservedWireBytes: "0000000000000000",
            payloadSHA256: digest,
            index: chunks.count,
            payloadBytes: fixedHex(0),
            payload: nil
        ))
        let encoder = frameEncoder()
        let provisional = try frames.map { try encoder.encode($0) }
        let reservedWireBytes = fixedHex(provisional.reduce(0) { $0 + $1.count })
        for index in frames.indices {
            frames[index].reservedWireBytes = reservedWireBytes
        }
        let encoded = try frames.map { try encoder.encode($0) }
        XCTAssertEqual(fixedHex(encoded.reduce(0) { $0 + $1.count }), reservedWireBytes)
        XCTAssertTrue(encoded.allSatisfy { $0.count <= RelaySnapshotProtocol.maximumFrameBytes })
        return Fixture(
            sessionID: sessionID,
            requestID: requestID,
            payload: payload,
            begin: encoded[0],
            dataFrames: Array(encoded.dropFirst())
        )
    }

    private func frameEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func fixedHex(_ value: Int) -> String {
        String(format: "%016llx", UInt64(value))
    }

    private func assertStreamError(
        _ closeCode: Int,
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                (error as? RelaySnapshotStreamError)?.closeCode,
                closeCode,
                file: file,
                line: line
            )
        }
    }
}
