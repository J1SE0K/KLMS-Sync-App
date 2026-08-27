import test from "node:test";
import assert from "node:assert/strict";
import {
  createCoordinator,
  canonicalDigest,
  redactAuthChallenge,
  filterActiveTerm,
} from "./klms_discord_coordinator.mjs";

const owner = { guildId: "100", channelId: "200", threadId: "300", userId: "400" };
const term = { year: 2026, semester_code: "20" };
const scope = { selectedTerms: [term], courseAllowlist: ["CS101"], scope: "course" };

function bridge(overrides = {}) {
  return {
    verifyLogin: async () => true,
    preview: async () => ({ assignments: [{ id: "a", year: 2026, semester_code: "20", course_id: "CS101" }] }),
    execute: async () => ({ ok: true }),
    postVerify: async () => ({ ok: true }),
    ...overrides,
  };
}

test("semester_code is a string and does not accept integer semester assumptions", () => {
  assert.deepEqual(filterActiveTerm([{ year: 2026, semester_code: "20" }], term), [{ year: 2026, semester_code: "20" }]);
  assert.throws(() => filterActiveTerm([], { year: 2026, semester_code: 20 }), /invalid term/);
});

test("auth challenge reset requires trusted owner and a fresh attempt nonce", () => {
  const c = createCoordinator({ bridge: bridge() });
  const firstAttempt = { attempt_nonce: "auth-attempt-1" };
  const secondAttempt = { attempt_nonce: "auth-attempt-2" };

  c.beginAuthAttempt(firstAttempt, owner);
  assert.throws(() => c.publishAuthChallenge("123", firstAttempt, owner), /challenge/);
  assert.deepEqual(c.publishAuthChallenge("42", firstAttempt, owner), { two_digit_code: "42" });
  assert.deepEqual(c.publishAuthChallenge("42", firstAttempt, owner), { displayed: false });
  assert.throws(() => c.beginAuthAttempt(firstAttempt, owner), /auth attempt replay/);
  assert.throws(
    () => c.publishAuthChallenge("43", firstAttempt, { ...owner, userId: "999" }),
    /auth attempt mismatch/,
  );
  c.beginAuthAttempt(secondAttempt, owner);
  assert.deepEqual(c.publishAuthChallenge("43", secondAttempt, owner), { two_digit_code: "43" });
});

test("preview digest is canonical JSON SHA-256 hex", () => {
  const value = { b: 1, a: ["x"] };
  assert.match(canonicalDigest(value), /^[0-9a-f]{64}$/);
  assert.equal(canonicalDigest(value), canonicalDigest({ a: ["x"], b: 1 }));
});

test("canonical digest matches Python ensure_ascii=True for Korean text", () => {
  assert.equal(
    canonicalDigest({ scope: "과목" }),
    "29129e3c266714f1b09c78e3551f1f684b55779fd7ae085246ff2025f5d6319d",
  );
});

test("canonical digest matches Python JSON escaping edge cases", () => {
  assert.equal(
    canonicalDigest({ emoji: "😀", separator: "\u2028" }),
    "2fbc28cd82bc09b2f8f2bc0cd141fd04d24e2b97abaf1e50884ec14e8d61a789",
  );
  assert.equal(
    canonicalDigest({ text: "line\n\"quote\"\\slash/\t", controls: "\b\f\r" }),
    "b0255d50c335abb2023d78e2eed598e7f22a53169becfee56e2f0369a62576ba",
  );
  assert.equal(
    canonicalDigest({ "😀": "emoji", "\ue000": "private", "과목": "scope" }),
    "801bbebd6ce0922f036df544c8bcfeed2eb239f179ce1e04c18422fd6556da41",
  );
});

test("canonical digest rejects every non-JSON value and sparse arrays", () => {
  const sparse = [1, 2, 3];
  delete sparse[1];
  const invalidValues = [
    undefined,
    () => true,
    Symbol("invalid"),
    1n,
    Number.NaN,
    Number.POSITIVE_INFINITY,
    Number.NEGATIVE_INFINITY,
    sparse,
    { nested: undefined },
    { nested: () => true },
    { nested: Symbol("invalid") },
    { nested: 1n },
  ];
  for (const value of invalidValues) {
    assert.throws(() => canonicalDigest(value), /non-JSON value/);
  }
});

test("preview rejects non-JSON item fields instead of omitting them from the digest", async () => {
  const c = createCoordinator({
    bridge: bridge({
      preview: async () => ({
        assignments: [{ id: "a", year: 2026, semester_code: "20", course_id: "CS101", title: undefined }],
      }),
    }),
  });

  await assert.rejects(() => c.preview(scope, owner), /non-JSON value/);
});

test("preview digest binds title URL fingerprint and content fields", async () => {
  const fixed = { now: () => 1000, idFactory: () => "req", nonceFactory: () => "nonce" };
  const first = createCoordinator({
    ...fixed,
    bridge: bridge({ preview: async () => ({ assignments: [{ id: "a", year: 2026, semester_code: "20", course_id: "CS101", title: "old", url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=1", fingerprint: "one" }] }) }),
  });
  const second = createCoordinator({
    ...fixed,
    bridge: bridge({ preview: async () => ({ assignments: [{ id: "a", year: 2026, semester_code: "20", course_id: "CS101", title: "new", url: "https://klms.kaist.ac.kr/mod/assign/view.php?id=1", fingerprint: "two" }] }) }),
  });
  const a = await first.preview(scope, owner);
  const b = await second.preview(scope, owner);
  assert.notEqual(a.digest, b.digest);
});

test("request binds numeric Discord metadata, allowlists, scope, digest, TTL, nonce and idempotency", async () => {
  const c = createCoordinator({ bridge: bridge(), now: (() => { let n = 1000; return () => n; })(), idFactory: () => "req-1", nonceFactory: () => "nonce-1" });
  const result = await c.preview({ ...scope, ...{ guildId: "999", channelId: "999", threadId: "999", userId: "999" } }, owner);
  assert.equal(result.request.guild_id, "100");
  assert.match(result.request.digest, /^[0-9a-f]{64}$/);
  assert.equal(Object.hasOwn(result.request, "digestPayload"), false);
  assert.deepEqual(result.request.selected_terms, [term]);
  assert.deepEqual(result.request.course_allowlist, ["CS101"]);
  assert.equal(result.request.nonce, "nonce-1");
  assert.equal(result.request.idempotency_key, "100:200:300:400:req-1");
});

test("mutating a returned preview request cannot mutate the stored immutable payload", async () => {
  const c = createCoordinator({ bridge: bridge(), idFactory: () => "immutable", nonceFactory: () => "immutable-nonce" });
  const p = await c.preview(scope, owner);
  p.request.selected_terms[0].year = 1999;
  p.request.course_allowlist.push("FORGED");

  const restored = {
    ...p.request,
    selected_terms: [term],
    course_allowlist: ["CS101"],
  };
  assert.equal(c.approve(restored, owner).approved, true);
});

test("approve rejects an idempotency_key that differs from the stored request", async () => {
  const c = createCoordinator({ bridge: bridge(), idFactory: () => "idempotency", nonceFactory: () => "idempotency-nonce" });
  const p = await c.preview(scope, owner);

  assert.throws(
    () => c.approve({ ...p.request, idempotency_key: "forged" }, owner),
    /idempotency key mismatch/,
  );
});

test("approve uses trusted event context and ignores untrusted body metadata", async () => {
  const c = createCoordinator({ bridge: bridge(), idFactory: () => "trusted-owner", nonceFactory: () => "trusted-nonce" });
  const p = await c.preview(scope, owner);
  const forgedBody = { ...p.request, guild_id: "999", channel_id: "999", thread_id: "999", user_id: "999" };

  assert.throws(() => c.approve(p.request, { ...owner, userId: "999" }), /binding mismatch/);
  assert.equal(c.approve(forgedBody, owner).approved, true);
});

test("execute verifies trusted event context and ignores untrusted body metadata", async () => {
  const c = createCoordinator({ bridge: bridge(), idFactory: () => "trusted-execute", nonceFactory: () => "trusted-execute-nonce" });
  const p = await c.preview(scope, owner);
  const approved = c.approve(p.request, owner);

  await assert.rejects(() => c.execute(approved, { ...owner, threadId: "999" }), /binding mismatch/);
  const forgedBody = { ...approved, guild_id: "999", channel_id: "999", thread_id: "999", user_id: "999" };
  assert.deepEqual(await c.execute(forgedBody, owner), { ok: true });
});

test("approve and execute reject forged, cross-user/thread, changed scope/digest, expiry, and replay", async () => {
  let now = 1000;
  const c = createCoordinator({ bridge: bridge(), now: () => now, ttlMs: 100, idFactory: () => "req-1", nonceFactory: () => "nonce-1" });
  const p = await c.preview(scope, owner);
  assert.throws(() => c.approve(p.request, { ...owner, userId: "999" }), /binding/);
  assert.throws(() => c.approve({ ...p.request, digest: "f".repeat(64) }, owner), /digest/);
  const a = c.approve(p.request, owner);
  await assert.rejects(() => c.execute({ ...a, nonce: "forged" }, owner), /nonce/);
  await assert.rejects(() => c.execute(a, { ...owner, threadId: "999" }), /binding/);
  now = 1100;
  await assert.rejects(() => c.execute(a, owner), /expired/);
  const c2 = createCoordinator({ bridge: bridge(), idFactory: () => "req-2", nonceFactory: () => "nonce-2" });
  const p2 = await c2.preview(scope, owner);
  const a2 = c2.approve(p2.request, owner);
  await c2.execute(a2, owner);
  await assert.rejects(() => c2.execute(a2, owner), /replay/);
});

test("explicit idempotency key reuses the same preview request and rejects changed scope", async () => {
  let previews = 0;
  const c = createCoordinator({
    bridge: bridge({ preview: async () => { previews += 1; return { assignments: [] }; } }),
    idFactory: (() => { let n = 0; return () => `idem-${++n}`; })(),
  });
  const first = await c.preview({ ...scope, idempotency_key: "same" }, owner);
  const second = await c.preview({ ...scope, idempotency_key: "same" }, owner);
  assert.equal(second.request.id, first.request.id);
  assert.equal(previews, 1);
  await assert.rejects(
    () => c.preview({ ...scope, scope: "all", idempotency_key: "same" }, owner),
    /idempotency key conflict/,
  );
});

test("concurrent execute calls invoke the write only once", async () => {
  let writes = 0;
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const c = createCoordinator({
    bridge: bridge({
      execute: async () => { writes += 1; await gate; return { ok: true }; },
    }),
    idFactory: () => "concurrent",
    nonceFactory: () => "concurrent-nonce",
  });
  const p = await c.preview(scope, owner);
  const a = c.approve(p.request, owner);
  const first = c.execute(a, owner);
  const second = c.execute(a, owner);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(writes, 1);
  release();
  assert.deepEqual(await Promise.all([first, second]), [{ ok: true }, { ok: true }]);
});

test("execute and postVerify receive the same fully bound immutable payload", async () => {
  let executePayload;
  let verifyPayload;
  const c = createCoordinator({
    bridge: bridge({
      execute: async (payload) => { executePayload = payload; return { ok: true }; },
      postVerify: async (payload) => { verifyPayload = payload; return { ok: true }; },
    }),
    idFactory: () => "payload",
    nonceFactory: () => "payload-nonce",
  });
  const p = await c.preview(scope, owner);
  const approved = c.approve(p.request, owner);
  await c.execute(approved, owner);

  assert.deepEqual(executePayload, verifyPayload);
  assert.deepEqual(executePayload.owner, {
    guild_id: "100", channel_id: "200", thread_id: "300", user_id: "400",
  });
  assert.deepEqual(executePayload.selected_terms, [term]);
  assert.deepEqual(executePayload.course_allowlist, ["CS101"]);
  assert.equal(executePayload.scope, "course");
  assert.equal(executePayload.digest, p.digest);
  assert.equal(executePayload.nonce, "payload-nonce");
  assert.equal(executePayload.idempotency_key, "100:200:300:400:payload");
  assert.deepEqual(executePayload.digest_payload.selected_terms, [term]);
  assert.deepEqual(executePayload.digest_payload.course_allowlist, ["CS101"]);
});

test("execute rejects a fresh-preview mismatch before invoking the write", async () => {
  let previews = 0;
  let writes = 0;
  const c = createCoordinator({
    bridge: bridge({
      preview: async () => {
        previews += 1;
        return { assignments: [{ id: "a", year: 2026, semester_code: "20", course_id: "CS101", title: previews === 1 ? "old" : "new" }] };
      },
      execute: async () => { writes += 1; return { ok: true }; },
    }),
    idFactory: () => "fresh-preview",
    nonceFactory: () => "fresh-preview-nonce",
  });
  const p = await c.preview(scope, owner);
  const approved = c.approve(p.request, owner);

  await assert.rejects(() => c.execute(approved, owner), /fresh preview mismatch/);
  assert.equal(previews, 2);
  assert.equal(writes, 0);
});

test("postVerify ok:false rejects and a later execute verifies without repeating the write", async () => {
  let writes = 0;
  let verifications = 0;
  const c = createCoordinator({
    bridge: bridge({
      execute: async () => { writes += 1; return { ok: true }; },
      postVerify: async () => {
        verifications += 1;
        return { ok: verifications > 1 };
      },
    }),
    idFactory: () => "req-3",
    nonceFactory: () => "nonce-3",
  });
  const p = await c.preview(scope, owner);
  const a = c.approve(p.request, owner);

  await assert.rejects(() => c.execute(a, owner), /post-verification failed/);
  assert.equal(writes, 1);
  assert.deepEqual(await c.execute(a, owner), { ok: true });
  assert.equal(writes, 1);
  await assert.rejects(() => c.execute(a, owner), /replay/);
});
