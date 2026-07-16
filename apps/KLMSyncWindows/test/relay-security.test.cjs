const assert = require("node:assert/strict");
const test = require("node:test");

const {
  configWithoutLegacyPlaintextToken,
  isLoopbackHost,
  isPrivateHost,
  normalizeExternalURL,
  normalizeEndpoint,
  normalizeRelayURL,
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

test("external navigation rejects active schemes, credentials and remote plaintext HTTP", () => {
  assert.equal(normalizeExternalURL("https://downloads.example.com/file?id=1"), "https://downloads.example.com/file?id=1");
  assert.equal(normalizeExternalURL("http://127.0.0.1:18484/file"), "http://127.0.0.1:18484/file");
  for (const value of [
    "javascript:alert(1)",
    "data:text/html,<script>alert(1)</script>",
    "file:///etc/passwd",
    "http://192.168.1.2/file",
    "https://user:secret@downloads.example.com/file",
    "https://downloads.example.com/\nfile"
  ]) {
    assert.throws(() => normalizeExternalURL(value));
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
