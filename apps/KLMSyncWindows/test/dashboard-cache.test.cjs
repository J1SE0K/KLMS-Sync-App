"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  DASHBOARD_CACHE_MAX_PLAINTEXT_BYTES,
  createDashboardCacheEnvelope,
  dashboardCachePayloadForCredentials
} = require("../src/dashboard-cache.cjs");

const credentials = {
  relayURL: "https://relay.example/klms",
  token: "a".repeat(64)
};
const payload = {
  revision: 42,
  status: { status: { assignments: 2 }, running: false, message: "저장됨" },
  syncData: { items: [{ id: "cached-assignment", kind: "assignment", title: "캐시 과제" }] }
};

test("credential-bound dashboard cache survives stale-while-revalidate offline startup", () => {
  const now = new Date("2026-07-22T00:00:00.000Z");
  const envelope = createDashboardCacheEnvelope({
    ...credentials,
    payload,
    storedAt: new Date(now.getTime() - (30 * 24 * 60 * 60 * 1000))
  });

  assert.deepEqual(dashboardCachePayloadForCredentials(envelope, { ...credentials, now }), {
    version: 1,
    ...payload
  });
  assert.equal(dashboardCachePayloadForCredentials(envelope, {
    relayURL: credentials.relayURL,
    token: "b".repeat(64),
    now
  }), null);
  assert.equal(dashboardCachePayloadForCredentials({ ...envelope, schemaVersion: 2 }, {
    ...credentials,
    now
  }), null);
});

test("dashboard cache rejects corrupt, future and oversized payloads", () => {
  const now = new Date("2026-07-22T00:00:00.000Z");
  const envelope = createDashboardCacheEnvelope({ ...credentials, payload, storedAt: now });
  assert.equal(dashboardCachePayloadForCredentials({
    ...envelope,
    storedAt: new Date(now.getTime() + (25 * 60 * 60 * 1000)).toISOString()
  }, { ...credentials, now }), null);
  assert.throws(() => createDashboardCacheEnvelope({
    ...credentials,
    payload: {
      ...payload,
      syncData: { padding: "x".repeat(DASHBOARD_CACHE_MAX_PLAINTEXT_BYTES) }
    }
  }), /too large/);
});
