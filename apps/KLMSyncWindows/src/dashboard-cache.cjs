"use strict";

const crypto = require("node:crypto");

const DASHBOARD_CACHE_SCHEMA_VERSION = 1;
const DASHBOARD_CACHE_MAX_PLAINTEXT_BYTES = 12 * 1024 * 1024;
const DASHBOARD_CACHE_MAX_ENCRYPTED_BYTES = 16 * 1024 * 1024;
const DASHBOARD_CACHE_MAX_FUTURE_CLOCK_SKEW_MS = 24 * 60 * 60 * 1000;

function credentialBinding(relayURL, token) {
  const normalizedURL = String(relayURL || "").trim();
  const normalizedToken = String(token || "").trim();
  if (!normalizedURL || !normalizedToken) return "";
  return crypto.createHash("sha256")
    .update(normalizedURL)
    .update("\0")
    .update(normalizedToken)
    .digest("hex");
}

function createDashboardCacheEnvelope({ relayURL, token, payload, storedAt = new Date() }) {
  const binding = credentialBinding(relayURL, token);
  if (!binding) throw new TypeError("dashboard cache credentials are incomplete");
  const normalizedPayload = normalizeDashboardCachePayload(payload);
  const timestamp = storedAt instanceof Date ? storedAt : new Date(storedAt);
  if (!Number.isFinite(timestamp.getTime())) throw new TypeError("dashboard cache timestamp is invalid");
  return {
    schemaVersion: DASHBOARD_CACHE_SCHEMA_VERSION,
    credentialBinding: binding,
    storedAt: timestamp.toISOString(),
    payload: normalizedPayload
  };
}

function dashboardCachePayloadForCredentials(envelope, { relayURL, token, now = new Date() }) {
  if (!envelope || typeof envelope !== "object" || Array.isArray(envelope)) return null;
  const binding = credentialBinding(relayURL, token);
  if (!binding || envelope.schemaVersion !== DASHBOARD_CACHE_SCHEMA_VERSION) return null;
  if (!safeEqualText(envelope.credentialBinding, binding)) return null;
  const storedAt = Date.parse(envelope.storedAt || "");
  const currentTime = now instanceof Date ? now.getTime() : new Date(now).getTime();
  if (!Number.isFinite(storedAt)
      || !Number.isFinite(currentTime)
      || storedAt > currentTime + DASHBOARD_CACHE_MAX_FUTURE_CLOCK_SKEW_MS) {
    return null;
  }
  try {
    return normalizeDashboardCachePayload(envelope.payload);
  } catch {
    return null;
  }
}

function normalizeDashboardCachePayload(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("dashboard cache payload must be an object");
  }
  const revision = Number(value.revision);
  if (!Number.isSafeInteger(revision) || revision < 0) {
    throw new TypeError("dashboard cache revision is invalid");
  }
  if (!value.status || typeof value.status !== "object" || Array.isArray(value.status)) {
    throw new TypeError("dashboard cache status is invalid");
  }
  if (!value.syncData || typeof value.syncData !== "object" || Array.isArray(value.syncData)) {
    throw new TypeError("dashboard cache sync data is invalid");
  }
  const serialized = JSON.stringify({
    version: DASHBOARD_CACHE_SCHEMA_VERSION,
    revision,
    status: value.status,
    syncData: value.syncData
  });
  if (Buffer.byteLength(serialized, "utf8") > DASHBOARD_CACHE_MAX_PLAINTEXT_BYTES) {
    throw new RangeError("dashboard cache payload is too large");
  }
  return JSON.parse(serialized);
}

function safeEqualText(left, right) {
  const leftBuffer = Buffer.from(String(left || ""), "utf8");
  const rightBuffer = Buffer.from(String(right || ""), "utf8");
  return leftBuffer.length === rightBuffer.length
    && leftBuffer.length > 0
    && crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

module.exports = {
  DASHBOARD_CACHE_MAX_ENCRYPTED_BYTES,
  DASHBOARD_CACHE_MAX_PLAINTEXT_BYTES,
  DASHBOARD_CACHE_SCHEMA_VERSION,
  createDashboardCacheEnvelope,
  credentialBinding,
  dashboardCachePayloadForCredentials,
  normalizeDashboardCachePayload
};
