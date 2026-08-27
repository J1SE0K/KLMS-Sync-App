import crypto from "node:crypto";

const COLLECTIONS = ["assignments", "exams", "notices", "files"];
const NUMERIC_FIELDS = ["guild_id", "channel_id", "thread_id", "user_id"];
const SENSITIVE_DIGEST_KEYS = /(?:html|cookie|authorization|token|secret|password|sesskey|auth[_-]?code|two[_-]?digit[_-]?code)/i;

function assertJsonValue(value, seen = new Set()) {
  if (value === null || typeof value === "string" || typeof value === "boolean") return;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new TypeError("non-JSON value");
    return;
  }
  if (typeof value !== "object") throw new TypeError("non-JSON value");
  if (seen.has(value)) throw new TypeError("non-JSON value");
  seen.add(value);
  try {
    if (Array.isArray(value)) {
      for (let index = 0; index < value.length; index += 1) {
        if (!Object.hasOwn(value, index)) throw new TypeError("non-JSON value");
        assertJsonValue(value[index], seen);
      }
      if (Object.getOwnPropertySymbols(value).length) throw new TypeError("non-JSON value");
      return;
    }
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) throw new TypeError("non-JSON value");
    if (Object.getOwnPropertySymbols(value).length) throw new TypeError("non-JSON value");
    for (const key of Object.keys(value)) assertJsonValue(value[key], seen);
  } finally {
    seen.delete(value);
  }
}

function asciiJsonString(value) {
  return JSON.stringify(value).replace(/[\u0080-\uffff]/g, (character) => (
    `\\u${character.charCodeAt(0).toString(16).padStart(4, "0")}`
  ));
}

function comparePythonStrings(left, right) {
  const leftPoints = Array.from(left, (character) => character.codePointAt(0));
  const rightPoints = Array.from(right, (character) => character.codePointAt(0));
  const length = Math.min(leftPoints.length, rightPoints.length);
  for (let index = 0; index < length; index += 1) {
    if (leftPoints[index] !== rightPoints[index]) return leftPoints[index] - rightPoints[index];
  }
  return leftPoints.length - rightPoints.length;
}

function stable(value) {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort(comparePythonStrings).map((key) => `${asciiJsonString(key)}:${stable(value[key])}`).join(",")}}`;
  }
  return asciiJsonString(value);
}

export function canonicalDigest(value) {
  assertJsonValue(value);
  return crypto.createHash("sha256").update(stable(value), "utf8").digest("hex");
}

function normalizeTerm(term) {
  if (!term || !Number.isInteger(term.year) || typeof term.semester_code !== "string"
      || !/^\d{2}$/.test(term.semester_code)) throw new Error("invalid term");
  return { year: term.year, semester_code: term.semester_code };
}

export function filterActiveTerm(items, term) {
  const normalized = normalizeTerm(term);
  return (Array.isArray(items) ? items : []).filter((item) => item && item.excluded !== true
    && item.year === normalized.year && item.semester_code === normalized.semester_code);
}

export function redactAuthChallenge(code) {
  const value = String(code ?? "");
  if (!/^\d{2}$/.test(value)) throw new Error("invalid challenge");
  return { two_digit_code: value };
}

function numeric(value) {
  if (typeof value !== "string" || !/^\d+$/.test(value)) throw new Error("invalid Discord metadata");
  return value;
}

function metadata(input) {
  const result = {};
  for (const field of NUMERIC_FIELDS) result[field] = numeric(input[field] ?? input[field.replace(/_([a-z])/g, (_, c) => c.toUpperCase())]);
  return result;
}

function same(a, b) { return stable(a) === stable(b); }

function safeDigestValue(value, seen = new Set()) {
  if (Array.isArray(value)) {
    if (seen.has(value)) throw new TypeError("non-JSON value");
    seen.add(value);
    try {
      const result = [];
      for (let index = 0; index < value.length; index += 1) {
        if (!Object.hasOwn(value, index)) throw new TypeError("non-JSON value");
        result.push(safeDigestValue(value[index], seen));
      }
      return result;
    } finally {
      seen.delete(value);
    }
  }
  if (value && typeof value === "object") {
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) throw new TypeError("non-JSON value");
    if (Object.getOwnPropertySymbols(value).length || seen.has(value)) throw new TypeError("non-JSON value");
    seen.add(value);
    try {
      const result = {};
      for (const key of Object.keys(value).sort()) {
        if (SENSITIVE_DIGEST_KEYS.test(key)) continue;
        result[key] = safeDigestValue(value[key], seen);
      }
      return result;
    } finally {
      seen.delete(value);
    }
  }
  assertJsonValue(value);
  return value;
}

function digestPayload(raw, selectedTerms, courseAllowlist, scope) {
  const items = {};
  for (const collection of COLLECTIONS) {
    items[collection] = filterActiveTerm(raw?.[collection], selectedTerms[0])
      .filter((item) => courseAllowlist.length === 0 || courseAllowlist.includes(String(item.course_id)))
      .map((item) => safeDigestValue(item))
      .sort((left, right) => comparePythonStrings(stable(left), stable(right)));
  }
  return { selected_terms: selectedTerms, course_allowlist: courseAllowlist, scope, items };
}

function publicRequest(request) {
  const { digestPayload: _digestPayload, ...safe } = request;
  return JSON.parse(JSON.stringify(safe));
}

export function createCoordinator({ bridge = {}, now = () => Date.now(), idFactory = () => crypto.randomUUID(), nonceFactory = () => crypto.randomBytes(16).toString("hex"), ttlMs = 10 * 60 * 1000 } = {}) {
  const verifyLogin = bridge.verifyLogin ?? (async () => false);
  const previewBridge = bridge.preview ?? (async () => ({}));
  const executeBridge = bridge.execute ?? (async () => ({ ok: false }));
  const postVerify = bridge.postVerify ?? (async () => ({ ok: false }));
  let activeAuthAttempt = null;
  const usedAuthAttemptNonces = new Set();
  const requests = new Map();
  const requestsByIdempotency = new Map();

  function assertCurrent(input, eventContext, stored) {
    const currentOwner = metadata(eventContext);
    if (!same(currentOwner, stored.owner)) throw new Error("binding mismatch");
    const incomingTerms = (input.selected_terms ?? input.selectedTerms ?? []).map(normalizeTerm);
    const incomingCourses = (input.course_allowlist ?? input.courseAllowlist ?? []).map(String);
    if (!same(incomingTerms, stored.selected_terms) || !same(incomingCourses, stored.course_allowlist) || input.scope !== stored.scope) throw new Error("scope mismatch");
    if (input.digest !== stored.digest) throw new Error("digest mismatch");
    if (input.nonce !== stored.nonce) throw new Error("nonce mismatch");
    if (input.idempotency_key !== stored.idempotency_key) throw new Error("idempotency key mismatch");
    if (now() >= stored.expires_at) throw new Error("expired");
  }

  function boundPayload(stored) {
    return {
      id: stored.id,
      owner: stored.owner,
      selected_terms: stored.selected_terms,
      course_allowlist: stored.course_allowlist,
      scope: stored.scope,
      digest: stored.digest,
      digest_payload: stored.digestPayload,
      nonce: stored.nonce,
      idempotency_key: stored.idempotency_key,
    };
  }

  return {
    beginAuthAttempt(input, eventContext) {
      const attemptNonce = String(input?.attempt_nonce ?? "");
      if (!attemptNonce || usedAuthAttemptNonces.has(attemptNonce)) throw new Error("auth attempt replay");
      const owner = metadata(eventContext);
      usedAuthAttemptNonces.add(attemptNonce);
      activeAuthAttempt = { attempt_nonce: attemptNonce, owner, displayed: false };
      return { started: true };
    },

    publishAuthChallenge(code, input, eventContext) {
      const challenge = redactAuthChallenge(code);
      const attemptNonce = String(input?.attempt_nonce ?? "");
      const owner = metadata(eventContext);
      if (!activeAuthAttempt || attemptNonce !== activeAuthAttempt.attempt_nonce
          || !same(owner, activeAuthAttempt.owner)) throw new Error("auth attempt mismatch");
      if (activeAuthAttempt.displayed) return { displayed: false };
      activeAuthAttempt.displayed = true;
      return challenge;
    },

    async preview(input, eventContext) {
      const owner = metadata(eventContext);
      const selected_terms = (input.selected_terms ?? input.selectedTerms ?? []).map(normalizeTerm);
      if (selected_terms.length !== 1) throw new Error("invalid term");
      const course_allowlist = (input.course_allowlist ?? input.courseAllowlist ?? []).map(String);
      const scope = String(input.scope ?? "");
      if (!scope) throw new Error("invalid scope");
      if (!await verifyLogin()) throw new Error("login verification failed");
      const idempotency_key = input.idempotency_key == null ? "" : String(input.idempotency_key);
      const idempotencyOwnerKey = `${stable(owner)}:${idempotency_key}`;
      if (idempotency_key && requestsByIdempotency.has(idempotencyOwnerKey)) {
        const existing = requestsByIdempotency.get(idempotencyOwnerKey);
        if (!same(selected_terms, existing.selected_terms)
            || !same(course_allowlist, existing.course_allowlist)
            || scope !== existing.scope) {
          throw new Error("idempotency key conflict");
        }
        if (existing.promise) return existing.promise;
        return { request: publicRequest(existing), digest: existing.digest, approved: existing.approved };
      }
      let reservation = null;
      if (idempotency_key) {
        let resolveReservation;
        let rejectReservation;
        const promise = new Promise((resolve, reject) => {
          resolveReservation = resolve;
          rejectReservation = reject;
        });
        reservation = {
          promise,
          resolve: resolveReservation,
          reject: rejectReservation,
          selected_terms,
          course_allowlist,
          scope,
        };
        requestsByIdempotency.set(idempotencyOwnerKey, reservation);
      }
      try {
        const raw = await previewBridge(selected_terms[0]);
      const digestPayloadValue = digestPayload(raw, selected_terms, course_allowlist, scope);
      const created_at = now();
      const requestId = idFactory();
      const request = {
        id: requestId, owner, selected_terms, course_allowlist, scope,
        ...owner,
        digestPayload: digestPayloadValue, digest: canonicalDigest(digestPayloadValue),
        created_at, expires_at: created_at + ttlMs, nonce: nonceFactory(), approved: false,
        idempotency_key: idempotency_key || `${owner.guild_id}:${owner.channel_id}:${owner.thread_id}:${owner.user_id}:${requestId}`,
        attempts: 0, write_invoked: false, terminal: false,
      };
      requests.set(request.id, request);
      if (idempotency_key) {
        requestsByIdempotency.set(idempotencyOwnerKey, request);
        reservation.resolve({ request: publicRequest(request), digest: request.digest, approved: false });
      }
      return { request: publicRequest(request), digest: request.digest, approved: false };
      } catch (error) {
        if (idempotency_key && requestsByIdempotency.get(idempotencyOwnerKey) === reservation) {
          requestsByIdempotency.delete(idempotencyOwnerKey);
          reservation.reject(error);
        }
        throw error;
      }
    },

    approve(input, eventContext) {
      const stored = requests.get(input?.id);
      if (!stored) throw new Error("unknown request");
      assertCurrent(input, eventContext, stored);
      if (stored.terminal || stored.approved) throw new Error("replay");
      stored.approved = true;
      stored.approved_at = now();
      return publicRequest(stored);
    },

    async execute(input, eventContext) {
      const stored = requests.get(input?.id);
      if (!stored) throw new Error("unknown request");
      if (!input?.approved || !stored.approved || stored.terminal) throw new Error("replay");
      assertCurrent(input, eventContext, stored);
      if (!stored.write_invoked && !stored.writePromise) {
        let writeStarted = false;
        stored.writePromise = (async () => {
          const freshRaw = await previewBridge(stored.selected_terms[0]);
          const freshDigestPayload = digestPayload(
            freshRaw,
            stored.selected_terms,
            stored.course_allowlist,
            stored.scope,
          );
          if (canonicalDigest(freshDigestPayload) !== stored.digest || !same(freshDigestPayload, stored.digestPayload)) {
            throw new Error("fresh preview mismatch");
          }
          stored.write_invoked = true;
          writeStarted = true;
          const result = await executeBridge(boundPayload(stored));
          if (!result || result.ok !== true) throw new Error("write failed");
          stored.writeResult = result;
          return result;
        })();
        try {
          await stored.writePromise;
        } catch (error) {
          if (!writeStarted) stored.writePromise = null;
          throw error;
        }
      } else if (stored.writePromise) {
        await stored.writePromise;
      }
      if (!stored.postVerifyPromise) {
        stored.postVerifyPromise = (async () => {
          const result = await postVerify(boundPayload(stored));
          if (!result || result.ok !== true) throw new Error("post-verification failed");
          return result;
        })();
      }
      try {
        const result = await stored.postVerifyPromise;
        stored.terminal = true;
        return result;
      } catch (error) {
        stored.postVerifyPromise = null;
        throw error;
      }
    },
  };
}
