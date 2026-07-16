export function consumeBoundedRateWindow(
  windows,
  key,
  limit,
  maxEntries,
  now = Date.now(),
  windowMilliseconds = 60_000,
) {
  const current = windows.get(key);
  if (current?.expiresAt > now) {
    if (current.count >= limit) return false;
    current.count += 1;
    return true;
  }
  if (current) windows.delete(key);

  if (windows.size >= maxEntries) {
    for (const [candidateKey, candidate] of windows) {
      if (candidate.expiresAt <= now) windows.delete(candidateKey);
    }
  }
  if (windows.size >= maxEntries) return false;

  windows.set(key, { count: 1, expiresAt: now + windowMilliseconds });
  return true;
}
