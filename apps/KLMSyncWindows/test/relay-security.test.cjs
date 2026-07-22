const assert = require("node:assert/strict");
const test = require("node:test");

const {
  configWithoutLegacyPlaintextToken,
  isLoopbackHost,
  isPrivateHost,
  normalizeEndpoint,
  normalizeRelayDownloadURL,
  normalizeRelayURL,
  validateDownloadCapability,
  validateRelayURL
} = require("../src/relay-security.cjs");

test("legacy plaintext relay tokens are removed instead of being reused", () => {
  const plaintext = configWithoutLegacyPlaintextToken({
    relayURL: "https://relay.example.com",
    token: "legacy-secret",
    tokenEncrypted: false,
    configRevision: 7
  });
  assert.equal(plaintext.changed, true);
  assert.deepEqual(plaintext.config, {
    relayURL: "https://relay.example.com",
    configRevision: 7
  });

  const encrypted = configWithoutLegacyPlaintextToken({
    token: "encrypted-value",
    tokenEncrypted: true
  });
  assert.equal(encrypted.changed, false);
  assert.equal(encrypted.config.token, "encrypted-value");
});

test("relay endpoints cannot escape the authenticated v1 namespace", () => {
  assert.equal(normalizeEndpoint("/healthz"), "/healthz");
  assert.equal(normalizeEndpoint("/v1/status?limit=1"), "/v1/status?limit=1");
  assert.throws(() => normalizeEndpoint("/v1/%2e%2e/healthz"), /허용되지 않은/);
  assert.throws(() => normalizeEndpoint("https://example.com/v1/status"), /허용되지 않은/);
});

test("relay URLs allow HTTP only on an exact loopback host", () => {
  assert.equal(normalizeRelayURL("https://relay.example.com/"), "https://relay.example.com");
  assert.equal(normalizeRelayURL("http://localhost:18484/"), "http://localhost:18484");
  assert.equal(normalizeRelayURL("http://127.0.0.1:18484"), "http://127.0.0.1:18484");
  assert.equal(normalizeRelayURL("http://[::1]:18484"), "http://[::1]:18484");
  assert.doesNotThrow(() => validateRelayURL("https://relay.example.com/base"));
  assert.doesNotThrow(() => validateRelayURL("https://192.168.1.2:18484"));
  assert.doesNotThrow(() => validateRelayURL("https://relay.local:18484"));
  for (const value of [
    "http://relay.example.com",
    "http://192.168.1.2:18484",
    "http://relay.local:18484",
    "http://127.0.0.2:18484",
    "http://worker.localhost:18484",
    "https://relay.example.com/\nstatus",
    "https://user:secret@relay.example.com",
    "https://relay.example.com?token=secret"
  ]) {
    assert.throws(() => validateRelayURL(value));
  }
});

test("file downloads require the configured relay origin, exact path and header capability", () => {
  const requestID = "8dfd4cca-4d78-4d4e-954b-65791b95623c";
  assert.equal(
    normalizeRelayDownloadURL(
      `https://relay.example.com/relay/v1/file-access/${requestID}/download`,
      "https://relay.example.com/relay",
      requestID
    ),
    `https://relay.example.com/relay/v1/file-access/${requestID}/download`
  );
  assert.equal(validateDownloadCapability("a".repeat(32)), "a".repeat(32));
  assert.throws(() => validateDownloadCapability("short"), /권한/);
  for (const value of [
    `https://other.example.com/relay/v1/file-access/${requestID}/download`,
    `https://relay.example.com/v1/file-access/${requestID}/download`,
    `https://relay.example.com/relay/v1/file-access/${requestID}/download?ticket=secret`,
    `https://user:secret@relay.example.com/relay/v1/file-access/${requestID}/download`,
    `javascript:alert(1)`
  ]) {
    assert.throws(() => normalizeRelayDownloadURL(
      value,
      "https://relay.example.com/relay",
      requestID
    ));
  }
});

test("private host detection covers local IPv4 and IPv6 ranges", () => {
  assert.equal(isLoopbackHost("localhost"), true);
  assert.equal(isLoopbackHost("127.0.0.1"), true);
  assert.equal(isLoopbackHost("::1"), true);
  assert.equal(isLoopbackHost("127.0.0.2"), false);
  assert.equal(isLoopbackHost("worker.localhost"), false);
  assert.equal(isPrivateHost("10.0.0.1"), true);
  assert.equal(isPrivateHost("172.31.0.1"), true);
  assert.equal(isPrivateHost("192.168.1.1"), true);
  assert.equal(isPrivateHost("fe80::1"), true);
  assert.equal(isPrivateHost("relay.example.com"), false);
});
