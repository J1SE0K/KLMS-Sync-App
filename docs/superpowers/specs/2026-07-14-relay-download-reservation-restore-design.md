# Relay Download Reservation and Restore Recovery Design

## Scope

Close two remaining relay integrity gaps without changing any UI or Swift source:

1. A valid file ticket must not cause more storage reads than the configured atomic download allowance under concurrent requests.
2. A database restore must restart the relay and restore the pre-restore safety backup after any ordinary command failure once the relay has been stopped.

## Download architecture

Both self-hosted SQLite and Cloudflare D1 use the existing atomic link-count and daily-quota mutation as a reservation before touching file storage. A successful reservation returns the quota key/date needed for compensation. Requests that lose the reservation return the existing limit/conflict response without calling `fs.readFile` or R2 `get`.

The request log uses one stable entry ID for the reservation lifecycle. Reservation writes it as running. A successful storage lookup updates the same entry to completed. A missing object, storage exception, or finalization failure releases exactly that reservation's link and daily counts and updates the same entry to failed. Release/finalize operations are guarded by a reservation token so retries cannot release another request's count or finalize twice.

Reservation tokens are persisted in a `file_download_reservations` table keyed by token, with request ID, quota key/date, and creation time. This supports multiple downloads per link while letting finalize/release atomically delete exactly one token. A repeated finalize/release sees no token and becomes a no-op. Reservations older than ten minutes are compensatingly released by normal file-access maintenance so a crashed request cannot permanently consume quota.

## Restore architecture

After the relay stops and the safety backup exists, an EXIT trap owns recovery until readiness succeeds. The trap is gated by a committed flag and re-entry guard. On any nonzero exit it restores the safety backup and starts the relay. Signal traps exit nonzero and therefore flow through the same EXIT recovery path. After the restored database passes readiness, the script marks the transaction committed and removes traps.

The recovery path preserves the original failing exit status where possible. A rollback or restart failure is reported explicitly and must not recurse through the trap.

## Verification

- Self-hosted tests count actual local object reads immediately before `fs.readFile`. With N concurrent requests and allowance Q, the count delta must be no greater than Q, and response counts must match Q successes plus N-Q limit responses.
- Cloudflare tests add a `FakeR2.getCount` metric and enforce the same invariant.
- Both backends inject missing-object/storage failures and verify link count, daily quota, and reservation state are restored; repeated finalize/release calls must be harmless.
- A mocked `docker compose` harness injects failures during database replacement, relay startup, and readiness. Each case must prove the safety backup restore and relay start were attempted exactly once.
- Existing relay smoke/integration tests, JavaScript checks, shell syntax checks, and whitespace validation must remain green.

## Non-goals

- UI, Swift, or product-layout changes.
- New public endpoints or production diagnostics.
- Relaxing existing ticket expiry, object-key validation, or quota limits.
