const crypto = require("node:crypto");

const VERSION = 1;
const MAX_FRAME_BYTES = 64 * 1024;
const MAX_STREAM_BYTES = 8 * 1024 * 1024;
const MAX_CHUNK_COUNT = 254;
const SCOPES = new Set([
  "status", "syncData", "commands", "itemActions", "settingActions", "sharedSettings",
  "runLogs", "fileAccess", "requestLog", "cancel"
]);
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HEX_BYTES_PATTERN = /^[0-9a-f]{16}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;

class RelaySnapshotProtocolError extends Error {
  constructor(closeCode, message) {
    super(message);
    this.closeCode = closeCode;
  }
}

class RelaySnapshotAssembler {
  constructor() {
    this.reservation = null;
  }

  discard() {
    this.reservation = null;
  }

  ingest(raw, expectedSessionID) {
    const text = Buffer.isBuffer(raw) ? raw.toString("utf8") : String(raw);
    const frameBytes = Buffer.byteLength(text);
    if (frameBytes > MAX_FRAME_BYTES) throw new RelaySnapshotProtocolError(1009, "snapshot frame too large");
    let frame;
    try {
      frame = JSON.parse(text);
    } catch {
      throw new RelaySnapshotProtocolError(1002, "invalid snapshot frame");
    }
    const totalPayloadBytes = parseHexBytes(frame?.totalPayloadBytes);
    const reservedWireBytes = parseHexBytes(frame?.reservedWireBytes);
    const payloadBytes = parseHexBytes(frame?.payloadBytes);
    if (frame?.version !== VERSION
        || frame?.sessionID !== expectedSessionID
        || !UUID_PATTERN.test(String(frame?.sessionID || ""))
        || !UUID_PATTERN.test(String(frame?.streamID || ""))
        || !Number.isSafeInteger(frame?.revision)
        || frame.revision < 0
        || !validScopes(frame?.scopes)
        || !Number.isSafeInteger(frame?.chunkCount)
        || frame.chunkCount < 1
        || frame.chunkCount > MAX_CHUNK_COUNT
        || frame?.reservedFrames !== frame.chunkCount + 2
        || frame.reservedFrames > 256
        || !SHA256_PATTERN.test(String(frame?.payloadSHA256 || ""))
        || totalPayloadBytes == null
        || reservedWireBytes == null
        || payloadBytes == null) {
      throw new RelaySnapshotProtocolError(1002, "invalid snapshot binding");
    }
    if (totalPayloadBytes > MAX_STREAM_BYTES) {
      throw new RelaySnapshotProtocolError(1009, "snapshot payload too large");
    }
    if (reservedWireBytes > MAX_STREAM_BYTES) {
      throw new RelaySnapshotProtocolError(1013, "snapshot reservation unavailable");
    }

    if (frame.type === "snapshot-begin") {
      if (this.reservation || frame.index !== -1 || payloadBytes !== 0 || frame.payload != null) {
        throw new RelaySnapshotProtocolError(1002, "invalid snapshot begin order");
      }
      this.reservation = {
        begin: frame,
        expectedIndex: 0,
        chunks: [],
        payloadBytes: 0,
        wireBytes: frameBytes
      };
      return {
        action: "ready",
        frame: {
          version: VERSION,
          type: "snapshot-ready",
          sessionID: frame.sessionID,
          streamID: frame.streamID,
          revision: frame.revision,
          reservedFrames: frame.reservedFrames,
          reservedWireBytes: frame.reservedWireBytes
        }
      };
    }

    if (frame.type === "snapshot-chunk") {
      const current = this.reservation;
      let chunk;
      try {
        chunk = Buffer.from(String(frame.payload || ""), "base64");
      } catch {
        chunk = null;
      }
      if (!current
          || !matchingBinding(frame, current.begin)
          || frame.index !== current.expectedIndex
          || frame.index >= frame.chunkCount
          || !chunk
          || chunk.toString("base64") !== frame.payload
          || chunk.length !== payloadBytes
          || current.payloadBytes + chunk.length > totalPayloadBytes) {
        this.discard();
        throw new RelaySnapshotProtocolError(1002, "invalid snapshot chunk");
      }
      current.chunks.push(chunk);
      current.expectedIndex += 1;
      current.payloadBytes += chunk.length;
      current.wireBytes += frameBytes;
      return { action: "staged" };
    }

    if (frame.type === "snapshot-end") {
      const current = this.reservation;
      if (!current
          || !matchingBinding(frame, current.begin)
          || current.expectedIndex !== frame.chunkCount
          || frame.index !== frame.chunkCount
          || payloadBytes !== 0
          || frame.payload != null
          || current.payloadBytes !== totalPayloadBytes
          || current.wireBytes + frameBytes !== reservedWireBytes) {
        this.discard();
        throw new RelaySnapshotProtocolError(1002, "invalid snapshot end");
      }
      const payloadBuffer = Buffer.concat(current.chunks, current.payloadBytes);
      const digest = crypto.createHash("sha256").update(payloadBuffer).digest("hex");
      if (digest !== frame.payloadSHA256) {
        this.discard();
        throw new RelaySnapshotProtocolError(1002, "snapshot digest mismatch");
      }
      let payload;
      try {
        payload = JSON.parse(payloadBuffer.toString("utf8"));
      } catch {
        this.discard();
        throw new RelaySnapshotProtocolError(1002, "invalid snapshot payload");
      }
      if (payload?.version !== VERSION
          || payload?.revision !== frame.revision
          || JSON.stringify(payload?.scopes) !== JSON.stringify(frame.scopes)
          || (payload?.requestID ?? null) !== (frame.requestID ?? null)) {
        this.discard();
        throw new RelaySnapshotProtocolError(1002, "snapshot payload binding mismatch");
      }
      this.discard();
      return { action: "complete", payload };
    }

    this.discard();
    throw new RelaySnapshotProtocolError(1002, "unsupported snapshot frame");
  }
}

function snapshotFrameType(raw) {
  try {
    const value = JSON.parse(Buffer.isBuffer(raw) ? raw.toString("utf8") : String(raw));
    return typeof value?.type === "string" ? value.type : "";
  } catch {
    return "";
  }
}

function createSnapshotRequest({ sessionID, requestID, revision, scopes }) {
  if (!UUID_PATTERN.test(String(sessionID || ""))
      || !UUID_PATTERN.test(String(requestID || ""))
      || !Number.isSafeInteger(revision)
      || revision < 0
      || !validScopes(scopes)) {
    throw new RelaySnapshotProtocolError(1002, "invalid snapshot request");
  }
  return {
    version: VERSION,
    type: "snapshot-request",
    sessionID,
    requestID,
    revision,
    scopes
  };
}

function matchingBinding(frame, begin) {
  return frame.sessionID === begin.sessionID
    && frame.streamID === begin.streamID
    && frame.revision === begin.revision
    && JSON.stringify(frame.scopes) === JSON.stringify(begin.scopes)
    && (frame.requestID ?? null) === (begin.requestID ?? null)
    && frame.chunkCount === begin.chunkCount
    && frame.totalPayloadBytes === begin.totalPayloadBytes
    && frame.reservedFrames === begin.reservedFrames
    && frame.reservedWireBytes === begin.reservedWireBytes
    && frame.payloadSHA256 === begin.payloadSHA256;
}

function parseHexBytes(value) {
  if (!HEX_BYTES_PATTERN.test(String(value || ""))) return null;
  const parsed = Number.parseInt(value, 16);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

function validScopes(scopes) {
  return Array.isArray(scopes)
    && scopes.length > 0
    && new Set(scopes).size === scopes.length
    && scopes.every((scope) => SCOPES.has(scope));
}

module.exports = {
  RelaySnapshotAssembler,
  RelaySnapshotProtocolError,
  createSnapshotRequest,
  snapshotFrameType
};
