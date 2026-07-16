# KLMS Sync security best-practices report — 2026-07-14, updated 2026-07-16

## Executive summary

No confirmed open Critical or High finding remains in the reviewed relay, file-transfer, command, local-client reset, backup, restore, or local-cleanup paths. The previously identified path traversal, quota race/I/O abuse, malformed-command poisoning, non-atomic active-command creation, unsafe WAL backup, stale prior-account data, unknown-namespace cleanup, authentication-rate-limit poisoning, and partial-parser deletion issues have code and regression-test closures.

The operational cleanup finding is closed: root cleanup is namespace-allowlisted, dry-run and protected-root tests pass, and the completed cleanup preserved the unknown personal result, speech model, and synchronization state byte-for-byte.

This is a repository-grounded secure-coding review, not an external penetration test. Runtime TLS/edge configuration, physical-device privacy behavior, WAN adversarial conditions, memory-graph evidence, and long soak behavior remain unverified.

## Scope and method

Reviewed surfaces:

- Self-hosted Node relay: `tools/klms_relay_server.mjs`, `deploy/relay/`
- Cloudflare Worker/D1/R2 relay: `deploy/cloudflare-worker/`
- Windows Electron client boundary and reset behavior: `apps/KLMSyncWindows/`
- Swift relay models and Mac/iOS session reset paths: `apps/KLMSync/`
- Core sync state/file transactions: `src/`, `bin/`, `tests/`

The available security references directly cover browser JavaScript and Node/Express-style server risks. This project uses custom Node HTTP and Cloudflare Workers rather than Express, so their input-validation, filesystem, file-serving, dependency, and DoS principles were applied where relevant. There is no matching reference for Swift or this non-web Python pipeline; those portions are assessed against repository invariants and tests.

Static high-signal checks covered DOM/code-execution sinks, filesystem paths, subprocess use, token storage, body limits, authentication comparison, CORS, WebSocket authorization, SQL mutation boundaries, file cleanup, and dependency audits.

## Critical findings

None confirmed in the reviewed snapshot.

## High findings — resolved

### SEC-01 — Worker-controlled file path traversal

- Severity: High
- Location: `tools/klms_relay_server.mjs:1363-1375`, `:5467-5491`
- Evidence: Worker patches cannot set `objectKey` or other server-owned file fields. A valid key must be `file-access/<request UUID>/<object UUID>-<safe name>`, and the resolved canonical path must remain beneath `FILE_DIR`.
- Impact before fix: A compromised or faulty worker credential could read or delete files with relay-process privileges.
- Resolution: Server-generated keys, strict segment/UUID validation, canonical-root enforcement, and validation before read/delete.
- Regression: `deploy/relay/test_relay.mjs:240-267` rejects `../sentinel.txt` and proves the sentinel survives.
- Status: **Resolved**

### SEC-02 — Non-atomic download quota and pre-quota storage I/O

- Severity: High
- Location: `tools/klms_relay_server.mjs:5228-5445`; `deploy/cloudflare-worker/src/worker.mjs:2479-2511`, `:5573-5685`; `deploy/cloudflare-worker/migrations/0009_file_download_reservations.sql:1-15`
- Evidence: Both relays persist a random reservation token before local-file/R2 reads. Success finalizes it; missing objects and storage exceptions atomically release per-link/daily quota; stale leases are recovered. Cleanup refuses to remove an object with an active reservation.
- Impact before fix: Concurrent requests could exceed link/daily limits and still incur storage I/O/cost after quota exhaustion.
- Resolution: Transactional reservation/finalize/release protocol with idempotent stale recovery.
- Regression: Self-host contention permits 1 of 12 and records exactly 1 file read (`deploy/relay/test_relay.mjs:353-403`). Cloudflare permits 7 of 50 and records exactly 7 R2 GETs; missing/throw cases release quota and allow retry (`deploy/cloudflare-worker/test/smoke.mjs:1223-1317`). Local D1 integration enforces exact concurrent limits (`deploy/cloudflare-worker/test/integration.mjs:190-209`).
- Status: **Resolved**

### SEC-03 — Malformed command/inbox poisoning and duplicate active commands

- Severity: High
- Location: `deploy/cloudflare-worker/src/worker.mjs:3842-3884`, `:4060-4113`; `deploy/cloudflare-worker/migrations/0004_relay_integrity.sql:1-15`; `apps/KLMSync/Sources/KLMSShared/RemoteCommandModels.swift:2668-2699`
- Evidence: Relay entrypoints require valid UUIDs and allowlisted command kinds/statuses. D1 has a partial unique index for one pending/running command. Swift decodes array elements lossily, so one malformed legacy row cannot discard valid work.
- Impact before fix: Invalid persisted data could block the Mac worker inbox until expiry, while concurrent clients could create multiple active commands.
- Resolution: Boundary validation, stored-row filtering/sanitization, DB invariant, conflict-to-409 mapping, and record-level decoding isolation.
- Regression: `deploy/cloudflare-worker/test/smoke.mjs:65-85`, `:242-253`; `deploy/cloudflare-worker/test/integration.mjs:109-177`; `apps/KLMSync/Tests/KLMSSharedTests/LiveStatePolicyTests.swift:787-823`.
- Status: **Resolved**

## Medium findings — resolved

### SEC-04 — Unsafe WAL backup and incomplete restore recovery

- Severity: Medium
- Location: `deploy/relay/backup_db.sh:47-52`; `tools/klms_relay_server.mjs:5817-5878`; `deploy/relay/restore_db.sh:42-79`, `:107-150`
- Evidence: Backup uses SQLite's backup API rather than copying the main database file, verifies `PRAGMA quick_check`, required tables, and relay revision, publishes atomically with owner-only permissions, and refuses overwrite. Restore verifies input first, installs EXIT/signal recovery before stopping service, creates a safety backup, replaces through a sibling file, and commits only after `/readyz` succeeds.
- Impact before fix: A live WAL database could restore without recent commits, or a failed replacement/startup/readiness step could leave the service stopped or on a bad database.
- Resolution: Verified snapshot backup plus fail-safe rollback/restart state machine.
- Regression: Concurrent live writes during backup (`deploy/relay/test_relay.mjs:600-703`) and seven restore fault scenarios (`deploy/relay/test_restore_db.mjs:11-121`).
- Status: **Resolved**

### SEC-05 — File deletion/DB-row inconsistency

- Severity: Medium
- Location: `tools/klms_relay_server.mjs:1695-1723`
- Evidence: Cleanup claims terminal rows, attempts object deletion, and records failure instead of deleting the authoritative DB row when filesystem deletion fails.
- Impact before fix: The database could forget a file whose object remained on disk, leaving an untracked persistent object.
- Resolution: Preserve failed rows for retry/remediation; delete the row only after successful or already-missing object cleanup.
- Regression: `deploy/relay/test_relay.mjs:492-507`.
- Status: **Resolved**

### SEC-06 — Prior relay/account data retained after connection clear or switch

- Severity: Medium (privacy)
- Location: `apps/KLMSyncWindows/src/relay-state.js:367-389`; `apps/KLMSyncWindows/src/renderer.js:277-324`; `apps/KLMSync/Sources/KLMSiOS/KLMSiOSApp.swift:4011-4063`, `:5061-5079`
- Evidence: Windows and iOS reset commands, request/file histories, settings, sync items, status, optimistic overlays, revision/session cursors, and persisted cached sync data on connection generation change.
- Impact before fix: A new relay/account view could display sensitive titles or status from the previous connection.
- Resolution: One centralized server-derived-state reset per platform plus generation invalidation for late responses.
- Regression: `apps/KLMSyncWindows/test/relay-state.test.cjs:265-289`; `apps/KLMSync/Tests/KLMSSharedTests/DashboardDataModelTests.swift:7607-7724`.
- Status: **Resolved**

## Verified defense-in-depth controls

- Bearer-token role separation for client and worker endpoints; comparisons are constant-time (`tools/klms_relay_server.mjs:2064-2074`, `:2258-2260`; `deploy/cloudflare-worker/src/worker.mjs:1194-1208`).
- JSON bodies are streamed into a 1 MiB cap; malformed JSON returns 400 and oversized input returns 413 in both relays. The limit is enforced without first materializing an unbounded request body.
- Valid client/worker credentials use role-scoped request buckets separate from failed-authentication IP buckets. Public file downloads use an IP bucket until the stored ticket matches and only then consume the real link bucket, so syntactically valid fake tickets cannot throttle a valid link.
- Public run-log publication removes bearer/basic/digest credentials, token/secret/password/cookie/session/API-key assignments, arbitrary HTTP(S) URLs, email addresses, and Unix/macOS/Windows absolute paths. A final forbidden-pattern pass drops any residual sensitive line.
- iOS Keychain persistence is serialized on a utility queue with generation invalidation, and clearing waits behind earlier writes before deleting. Sensitive iOS pasteboard entries are local-only with system expiry; macOS marks them transient/concealed and clears matching content after 60 seconds or graceful termination.
- The local terminal-result outbox accepts terminal statuses only, validates relay identity, limits age/future skew/count, salvages valid records independently, and quarantines corrupted documents before rewriting a normalized version.
- File preview responses use nonce-based CSP, deny framing, set `nosniff`, and use same-origin resource policy; exercised by `deploy/relay/test_relay.mjs:268-281`.
- Windows stores the relay token with Electron `safeStorage`; plaintext fallback is rejected when encryption is unavailable (`apps/KLMSyncWindows/src/main.cjs:217-234`).
- Backups use directory mode 0700 and file mode 0600, are verified before publication, and cannot overwrite an existing backup.
- Both JavaScript dependency trees report **0 npm audit findings** in the confirmed run.
- CI runs syntax, regression, integration, audit, simulator UI, Windows E2E, and packaging gates (`.github/workflows/ci.yml:14-117`).

## Low/accepted design assumptions

### SEC-07 — Wildcard CORS with bearer authentication

- Severity: Low / accepted for the current personal native-client design
- Location: `deploy/cloudflare-worker/src/worker.mjs:5939-5946`
- Evidence: The Worker allows any origin but does not use cookie authentication or `Access-Control-Allow-Credentials`; every protected route still requires a client/worker bearer token.
- Rationale: Native/Electron clients do not have one stable browser origin. CORS is not treated as authorization.
- Residual risk: If a bearer token is exposed to malicious browser content, the wildcard policy removes an origin-level containment layer.
- Follow-up condition: If a hosted browser client is introduced, replace `*` with an explicit origin allowlist and add origin-specific tests.
- Status: **Accepted for current scope**

### SEC-08 — Fixed local `eval` bridge loading and detached HTML parsing

- Severity: Informational
- Location: `src/js/sync_klms_notes.js:12-14`; `src/js/fetch_pages_with_safari.js:158-169`, `:226-237`
- Evidence: `eval` loads three fixed repository-local bridge paths, not request data. `innerHTML` is assigned only to a detached document to extract a title from allowlisted same-origin KLMS responses, not to the app UI DOM.
- Residual risk: Tampering with installed local scripts already implies local-code execution. Keep installed files owner-controlled and do not make these paths configurable from relay input.
- Status: **Reviewed; no untrusted source-to-execution/UI-DOM path established**

## Operational-integrity finding — resolved

### OPS-01 — Root tmp cleanup can remove unknown personal content

- Severity: P1 product-integrity / Medium security-adjacent
- Location: `tools/clean_local_artifacts.sh:74-79`; `src/sh/klms_common.sh:779-786`; `src/sh/cleanup_runtime_tmp.sh:88-183`; `bin/run_all.sh:20`; `bin/run_all_full.sh:21`
- Evidence before fix: the artifact cleaner removed `runtime/tmp` wholesale, while full-run cleanup targeted the tmp root with default age zero. The root contained `runtime/tmp/violence_prevention_20260605/결과요약_20260605.txt`, an unknown personal result document rather than a KLMS-generated namespace.
- Impact: a successful sync or manual cleanup could delete unrelated personal output without a recovery prompt.
- Resolution: root cleanup now traverses only five KLMS-owned namespaces, reports and preserves unknown top-level children, refuses protected roots, and supports a non-mutating dry-run. Full-run and manual cleanup both opt into that guarded mode.
- Regression: `tests/test_shell_entrypoint_cleanup.py:685-809` covers managed cleanup, unknown-namespace preservation, dry-run preservation, protected/symlink target refusal, and both caller contracts.
- Runtime verification: the reviewed dry-run contained 116 allowlisted removals and one preserved unknown namespace. Actual cleanup reclaimed 25.99 GiB while the personal result, 1.5 GiB speech model, and aggregate synchronization-state SHA-256 values remained unchanged.
- Status: **Resolved**

## Unverified security and operational evidence

- TLS, DNS, tunnel, Cloudflare account, firewall, and reverse-proxy behavior were not independently inspected at runtime. Lack of repository evidence is not treated as proof that a control is missing.
- No external penetration test or independent credential-rotation exercise was performed.
- Physical iPhone/iPad privacy behavior and actual clipboard auto-clear timing were not device-verified.
- WAN packet loss, hostile reconnect ordering, and long-running abuse/soak tests remain unverified.
- The simulator leak attempt did not yield a usable memgraph, so this report does not claim leak-free behavior or secret-free heap retention.
- Real VoiceOver/Switch Control traversal has not been observed; accessibility labels are code/test verified only.

These missing gates do not reopen a confirmed source-level vulnerability, but they prevent a literal “100% secure” claim.
