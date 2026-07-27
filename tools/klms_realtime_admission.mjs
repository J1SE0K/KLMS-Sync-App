export const REALTIME_ROLE_CONNECTION_LIMITS = Object.freeze({
  total: 32,
  client: 24,
  worker: 8,
});

export const REALTIME_MESSAGE_RATE_POLICY = Object.freeze({
  capacity: 30,
  refillPerMillisecond: 2 / 1_000,
});

export const REALTIME_SNAPSHOT_REQUEST_RATE_POLICY = Object.freeze({
  capacity: 3,
  refillPerMillisecond: 6 / 60_000,
});

export function realtimeRoleConnectionAllowed(existingRoles, requestedRole) {
  if (requestedRole !== "client" && requestedRole !== "worker") return false;
  let total = 0;
  let matchingRole = 0;
  for (const value of existingRoles || []) {
    total += 1;
    const role = typeof value === "string" ? value : value?.role;
    if (role === requestedRole) matchingRole += 1;
  }
  return total < REALTIME_ROLE_CONNECTION_LIMITS.total
    && matchingRole < REALTIME_ROLE_CONNECTION_LIMITS[requestedRole];
}

export function admitRealtimeMessage(state, messageType, now = Date.now()) {
  const common = consumeRealtimeTokenBucket(
    state?.common,
    REALTIME_MESSAGE_RATE_POLICY,
    now,
  );
  const nextState = {
    common: common.bucket,
    snapshotRequest: state?.snapshotRequest || null,
  };
  if (!common.allowed) {
    return { allowed: false, reason: "realtime message rate limit exceeded", state: nextState };
  }
  if (messageType !== "snapshot-request") {
    return { allowed: true, reason: "", state: nextState };
  }
  const snapshotRequest = consumeRealtimeTokenBucket(
    state?.snapshotRequest,
    REALTIME_SNAPSHOT_REQUEST_RATE_POLICY,
    now,
  );
  nextState.snapshotRequest = snapshotRequest.bucket;
  return {
    allowed: snapshotRequest.allowed,
    reason: snapshotRequest.allowed ? "" : "snapshot request rate limit exceeded",
    state: nextState,
  };
}

export function consumeRealtimeTokenBucket(bucket, policy, now = Date.now()) {
  const timestamp = Number.isFinite(now) && now >= 0 ? now : Date.now();
  const previousTimestamp = Number.isFinite(bucket?.lastRefillAt)
    ? Math.max(0, bucket.lastRefillAt)
    : timestamp;
  const previousTokens = Number.isFinite(bucket?.tokens)
    ? Math.max(0, Math.min(policy.capacity, bucket.tokens))
    : policy.capacity;
  const elapsed = Math.max(0, timestamp - previousTimestamp);
  const available = Math.min(
    policy.capacity,
    previousTokens + elapsed * policy.refillPerMillisecond,
  );
  const allowed = available >= 1;
  return {
    allowed,
    bucket: {
      tokens: allowed ? available - 1 : available,
      lastRefillAt: Math.max(previousTimestamp, timestamp),
    },
  };
}
