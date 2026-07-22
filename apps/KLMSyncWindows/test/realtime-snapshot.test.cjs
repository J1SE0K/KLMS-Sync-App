const assert = require("node:assert/strict");
const { randomUUID } = require("node:crypto");
const test = require("node:test");

const {
  RelaySnapshotAssembler,
  RelaySnapshotProtocolError,
  createSnapshotRequest,
  snapshotFrameType
} = require("../src/realtime-snapshot.cjs");
const { encodeRealtimeSnapshot } = require("./e2e/fake-relay.cjs");

function fixture(options = {}) {
  const sessionID = options.sessionID || randomUUID();
  const requestID = options.requestID === undefined ? randomUUID() : options.requestID;
  const scopes = options.scopes || ["status", "syncData"];
  const revision = options.revision ?? 17;
  const payload = options.payload || {
    version: 1,
    revision,
    scopes,
    requestID,
    status: { ok: true, revision },
    syncData: { revision, items: [{ id: "large", title: "가".repeat(40_000) }] }
  };
  return {
    sessionID,
    requestID,
    payload,
    encoded: encodeRealtimeSnapshot({ sessionID, revision, scopes, requestID, payload })
  };
}

function expectProtocolError(action, closeCode) {
  assert.throws(action, (error) => (
    error instanceof RelaySnapshotProtocolError && error.closeCode === closeCode
  ));
}

test("assembles a multi-frame snapshot only after its authenticated end frame", () => {
  const stream = fixture();
  const assembler = new RelaySnapshotAssembler();
  const ready = assembler.ingest(stream.encoded.beginFrame, stream.sessionID);
  assert.equal(ready.action, "ready");
  assert.equal(ready.frame.streamID, stream.encoded.streamID);
  assert.equal(ready.frame.reservedFrames, stream.encoded.reservedFrames);
  assert.equal(ready.frame.reservedWireBytes, stream.encoded.reservedWireBytes);

  for (const frame of stream.encoded.dataFrames.slice(0, -1)) {
    assert.deepEqual(assembler.ingest(frame, stream.sessionID), { action: "staged" });
  }
  const completed = assembler.ingest(stream.encoded.dataFrames.at(-1), stream.sessionID);
  assert.equal(completed.action, "complete");
  assert.deepEqual(completed.payload, stream.payload);
});

test("rejects reordered, duplicate and cross-session chunks without yielding partial state", () => {
  const stream = fixture();
  const chunks = stream.encoded.dataFrames.slice(0, -1);
  assert.ok(chunks.length >= 2);

  const reordered = new RelaySnapshotAssembler();
  reordered.ingest(stream.encoded.beginFrame, stream.sessionID);
  expectProtocolError(() => reordered.ingest(chunks[1], stream.sessionID), 1002);

  const duplicated = new RelaySnapshotAssembler();
  duplicated.ingest(stream.encoded.beginFrame, stream.sessionID);
  assert.equal(duplicated.ingest(chunks[0], stream.sessionID).action, "staged");
  expectProtocolError(() => duplicated.ingest(chunks[0], stream.sessionID), 1002);

  const crossSession = new RelaySnapshotAssembler();
  crossSession.ingest(stream.encoded.beginFrame, stream.sessionID);
  expectProtocolError(() => crossSession.ingest(chunks[0], randomUUID()), 1002);
});

test("rejects payload corruption at the digest boundary", () => {
  const stream = fixture({ payload: {
    version: 1,
    revision: 17,
    scopes: ["status", "syncData"],
    requestID: null,
    status: { ok: true },
    syncData: { items: [{ id: "one", title: "digest" }] }
  }, requestID: null });
  const assembler = new RelaySnapshotAssembler();
  assembler.ingest(stream.encoded.beginFrame, stream.sessionID);
  const chunk = JSON.parse(stream.encoded.dataFrames[0]);
  chunk.payload = `${chunk.payload[0] === "A" ? "B" : "A"}${chunk.payload.slice(1)}`;
  assert.equal(assembler.ingest(JSON.stringify(chunk), stream.sessionID).action, "staged");
  expectProtocolError(
    () => assembler.ingest(stream.encoded.dataFrames.at(-1), stream.sessionID),
    1002
  );
});

test("enforces frame, payload and reservation capacity before allocation", () => {
  const stream = fixture({ payload: {
    version: 1,
    revision: 17,
    scopes: ["status", "syncData"],
    requestID: null
  }, requestID: null });

  expectProtocolError(
    () => new RelaySnapshotAssembler().ingest(`{"padding":"${"x".repeat(64 * 1024)}"}`, stream.sessionID),
    1009
  );

  const oversizedPayload = JSON.parse(stream.encoded.beginFrame);
  oversizedPayload.totalPayloadBytes = "0000000000800001";
  expectProtocolError(
    () => new RelaySnapshotAssembler().ingest(JSON.stringify(oversizedPayload), stream.sessionID),
    1009
  );

  const unavailableReservation = JSON.parse(stream.encoded.beginFrame);
  unavailableReservation.reservedWireBytes = "0000000000800001";
  expectProtocolError(
    () => new RelaySnapshotAssembler().ingest(JSON.stringify(unavailableReservation), stream.sessionID),
    1013
  );
});

test("validates manual snapshot requests and identifies stream frame types", () => {
  const sessionID = randomUUID();
  const requestID = randomUUID();
  assert.deepEqual(createSnapshotRequest({
    sessionID,
    requestID,
    revision: 9,
    scopes: ["status", "commands"]
  }), {
    version: 1,
    type: "snapshot-request",
    sessionID,
    requestID,
    revision: 9,
    scopes: ["status", "commands"]
  });
  assert.equal(snapshotFrameType('{"type":"snapshot-begin"}'), "snapshot-begin");
  assert.equal(snapshotFrameType("not-json"), "");
  expectProtocolError(() => createSnapshotRequest({
    sessionID: "not-a-uuid",
    requestID,
    revision: 9,
    scopes: ["status"]
  }), 1002);
  expectProtocolError(() => createSnapshotRequest({
    sessionID,
    requestID,
    revision: 9,
    scopes: ["status", "status"]
  }), 1002);
});
