# KLMS Sync quality scorecard — 2026-07-14

## Result

**Current overall score: 94/100 (evidence cap)**

The automated, simulator, and local runtime evidence supports a raw score of 97/100. The cleanup data-loss path is closed with a fail-closed namespace allowlist, dry-run validation, regression coverage, and a completed cleanup that preserved the unknown personal directory byte-for-byte. The score remains capped at 94 because mandatory physical-device, real-network, assistive-technology, successful memgraph, and soak evidence is still missing. This is a working-tree assessment, not a claim that every device, network, or long-running production condition has been proven.

Scoring rules:

- Function/data integrity: 20
- Responsive UI: 20
- UX/accessibility: 15
- WebSocket/latency/performance: 15
- Security/privacy: 15
- Reliability/recovery: 10
- Test/release readiness: 5
- Caps: open P0 → 39, open P1 → 79, open P2 → 89, missing mandatory evidence → 94

| Area | Score | Evidence |
|---|---:|---|
| Function/data integrity | 20/20 | 287 Python regressions; fail-closed authoritative fetch/build; dry-run isolation; transactional file/override handling; unknown tmp namespaces are preserved by contract and test |
| Responsive UI | 19/20 | Mac `final8` matrix at 640/900/1200 plus boundary captures; Windows responsive E2E; iPhone/iPad simulator matrix |
| UX/accessibility | 14/15 | 44 pt controls, semantic labels, Dynamic Type and accessibility contracts; real assistive-technology traversal remains unverified |
| WebSocket/latency/performance | 15/15 | Poll endpoint removed; WebSocket-only realtime evidence; Mac five-run tab probe; Windows 2,000-item evidence; iPhone/iPad 2,000-item focused evidence |
| Security/privacy | 15/15 | Known path, command, quota, cleanup, backup, and stale-account-data risks closed; both npm audits report zero findings |
| Reliability/recovery | 9/10 | Atomic state/file updates, verified SQLite backup, restore rollback/fault tests, persistent download reservations, and fail-closed cleanup; soak and usable memgraph evidence remain missing |
| Test/release readiness | 5/5 | CI covers Python, Swift, iOS simulator UI, relay/Cloudflare, Windows unit/E2E, audits, and packaging |
| Raw total | **97/100** |  |
| Active cap | **94/100** | Physical devices, WAN/loss, real assistive technology, memgraph, and soak are not verified |

## Confirmed test ledger

| Surface | Confirmed result |
|---|---|
| Python/core | **287 passed** |
| Swift full package | **243 passed**, 0 failures |
| Mac Swift focus | **133 passed** |
| Mac responsive evidence | `final8` visual/containment matrix passed; five tab-response runs averaged **233 ms**, slowest observation **392 ms** |
| Windows unit | **24 passed** |
| Windows Electron E2E | **8 passed** |
| Windows 2,000-item fixture | initial reconcile/render **113.4 ms**, outside-initial-window search **93.8 ms**, WebSocket update **129.3 ms**, focus retained, scroll drift 0 px, polling 0, idle HTTP delta 0 |
| iPhone 2,000-item fixture | snapshot apply **537.862 ms**, classification **2.292 ms**, search **2.937 ms**, cache **1.037 ms**, total **544.128 ms**; lazy window and selection restoration passed |
| iPad Pro 13 M5 2,000-item fixture | snapshot apply **806.309 ms**, classification **2.839 ms**, search **3.797 ms**, cache **2.485 ms**, total **815.430 ms**; lazy window and selection restoration passed |
| iOS independent plugin run | XcodeBuildMCP iPhone and iPad build/run passed; iPad semantic snapshot exposed all seven navigation targets |
| Self-host relay | syntax/integrity/WebSocket/concurrency/backup tests passed |
| Cloudflare relay | check, smoke, local D1 integration, concurrency, migration, WebSocket tests passed |
| Dependency audit | Windows and Cloudflare `npm audit`: **0 findings** |
| CI | `.github/workflows/ci.yml` uses `macos-26`, Ubuntu, and Windows runners |
| Safe cleanup | dry-run validated **116** allowlisted removals and preserved the unknown personal namespace; actual cleanup reclaimed **1.35 GiB** in-repo and **24.64 GiB** from `/private/tmp` while model, personal file, state, and final evidence hashes/paths remained intact |

The Windows measurements are stored in `apps/KLMSyncWindows/output/playwright/windows-2000-item-performance-metrics.json`. The Mac matrix and probe are current-session artifacts under `/private/tmp/klmsync-responsive-final8/`.

## Original 13-defect closure

| # | Original risk | Closure evidence | Regression evidence |
|---:|---|---|---|
| 1 | Incomplete/authenticated-but-unparseable KLMS input could be committed as an authoritative empty state and delete Calendar/Reminders items. | Empty course sets and incomplete, empty, or login-page coverage now fail closed (`src/js/sync_klms_notes.js:1643-1692`); the Python state build rejects a missing or failed dashboard parse (`src/python/klms_sync_v2/cli.py:408-424`). | `tests/test_core_sync_safety.py:28-147`, `:231-260` |
| 2 | `--dry-run` could mutate Calendar while claiming it was skipped. | Calendar and Reminders side effects require `!dryRun`; dry-run receives its own skipped stage/report (`src/js/sync_klms_notes.js:1141-1231`). | `tests/test_core_sync_safety.py:149-179` |
| 3 | Course-file refresh could remove a valid destination before a failed replacement and then continue to prune. | Copy now stages a verified sibling and atomically replaces with `mv` (`src/js/download_klms_files.js:3110-3159`); any incomplete result blocks prune and exits non-zero (`bin/refresh_course_files.sh:200-251`, `:1391-1398`). | `tests/test_download_filename_safety.py:116-202`; `tests/test_shell_entrypoint_cleanup.py` |
| 4 | Core and notice jobs used different locks while mutating the same notice state. | Both namespaces resolve to the shared `core-notice` lock while retaining separate work caches (`src/sh/klms_common.sh:26-36`). | `tests/test_shell_entrypoint_cleanup.py:51-69` |
| 5 | A worker-supplied `objectKey` could escape the self-hosted file root. | File metadata is server-owned (`tools/klms_relay_server.mjs:1363-1375`); object keys have a strict three-segment schema and the canonical path must remain under `FILE_DIR` (`:5467-5491`). | `deploy/relay/test_relay.mjs:240-267`, including traversal sentinel preservation |
| 6 | Completing a Reminder stored a broad `course::title` override that could complete a different future assignment. | Assignment overrides now require URL identity or `course::title::due` (`src/js/sync_reminders_bridge.js:932-948`; `src/python/klms_sync_v2/overrides.py:40-49`). | `tests/test_v2_core.py:269-324` |
| 7 | Invalid relay command kind/UUID or one malformed inbox record could block the entire Mac inbox. | Relay boundaries validate UUID/enums (`deploy/cloudflare-worker/src/worker.mjs:3842-3884`); Swift arrays decode record-by-record and discard malformed legacy elements (`apps/KLMSync/Sources/KLMSShared/RemoteCommandModels.swift:2668-2699`). | `deploy/cloudflare-worker/test/smoke.mjs:65-85`; `apps/KLMSync/Tests/KLMSSharedTests/LiveStatePolicyTests.swift:787-823` |
| 8 | Cloudflare's “no pending command, then insert” sequence was non-atomic. | A partial unique index permits only one pending/running command (`deploy/cloudflare-worker/migrations/0004_relay_integrity.sql:1-15`), and insertion maps the constraint race to HTTP 409 (`deploy/cloudflare-worker/src/worker.mjs:713-743`). | `deploy/cloudflare-worker/test/smoke.mjs:242-253`; integration also proves one winner under 20 concurrent requests |
| 9 | Download quotas were read-modify-write races, and failed file deletion could orphan storage or discard its DB row. | Persistent reservation tokens are created before storage I/O and finalized/released idempotently (`deploy/cloudflare-worker/migrations/0009_file_download_reservations.sql:1-15`; `deploy/cloudflare-worker/src/worker.mjs:5573-5685`); failed deletion preserves the row for retry (`tools/klms_relay_server.mjs:1695-1723`). | Cloudflare: `deploy/cloudflare-worker/test/integration.mjs:190-209`, `test/smoke.mjs:1223-1317`; self-host: `deploy/relay/test_relay.mjs:353-448`, `:492-507` |
| 10 | A user-cancelled remote command was stored as failed. | Terminal resolution explicitly prefers `.cancelled` (`apps/KLMSync/Sources/KLMSShared/LiveStatePolicies.swift:618-624`) and Mac applies it to persisted terminal state (`apps/KLMSync/Sources/KLMSMac/KLMSMacModel.swift:5685-5701`). | `apps/KLMSync/Tests/KLMSSharedTests/LiveStatePolicyTests.swift:768-784` |
| 11 | Clearing/changing relay connection retained prior-account logs, requests, settings, and status. | Windows central reset clears every server-derived collection (`apps/KLMSyncWindows/src/relay-state.js:367-389`); iOS invalidates the session, clears histories/status, and clears loaded sync/settings data (`apps/KLMSync/Sources/KLMSiOS/KLMSiOSApp.swift:4011-4063`, `:5061-5079`). | `apps/KLMSyncWindows/test/relay-state.test.cjs:265-289`; `apps/KLMSync/Tests/KLMSSharedTests/DashboardDataModelTests.swift:7607-7724` |
| 12 | Copying only the main WAL-mode SQLite file could create stale or inconsistent backups. | Backup uses Node SQLite's backup API, verifies `quick_check`, required schema and revision, then publishes a mode-0600 file atomically (`tools/klms_relay_server.mjs:5817-5878`); the shell wrapper invokes backup and verification (`deploy/relay/backup_db.sh:47-52`). | Concurrent live-write backup verification: `deploy/relay/test_relay.mjs:600-703` |
| 13 | The Python suite was red after a Korean Calendar label change, and no CI blocked regressions. | Source/test wording is aligned and CI now runs core, Swift/iOS, relay/Cloudflare, Windows unit/E2E, audits, and packaging (`.github/workflows/ci.yml:14-117`). | Python **287 passed**; Mac focus **133 passed**; Windows **24 + 8 passed** |

## Additional risks found and closed

1. **Download reservation happened after storage reads.** A request could force file/R2 reads even after quota exhaustion. Both relays now reserve before I/O, release on missing/throw, finalize on successful delivery, and recover stale leases. Self-host contention proves one read for one allowed download; Cloudflare contention proves seven R2 reads for seven allowed downloads.
2. **Restore recovery did not cover every failure after stopping the relay.** `deploy/relay/restore_db.sh:54-79` now has an EXIT recovery path installed before stop (`:107-122`), restores the safety backup when available, restarts the relay, and accepts success only after `/readyz`. `deploy/relay/test_restore_db.mjs:11-121` fault-injects stop, safety-backup, replacement, signal, startup, readiness, and success paths.

## Cleanup integrity closure

- Root cleanup traverses only `all`, `core`, `files`, `notice`, and `shared`; unknown top-level children are reported and retained (`src/sh/cleanup_runtime_tmp.sh:88-183`).
- Both full-run cleanup and the local artifact cleaner explicitly select managed-root mode (`src/sh/klms_common.sh:779-786`; `tools/clean_local_artifacts.sh:74-79`).
- Regression tests prove normal cleanup and dry-run preserve unknown namespaces and reject protected or symlink targets (`tests/test_shell_entrypoint_cleanup.py:685-809`).
- The reviewed dry-run proposed 116 removals, all inside the allowlist, and reported `runtime/tmp/violence_prevention_20260605` as `preserved_unknown`.
- Actual cleanup preserved the speech model, personal result file, and `runtime/state` aggregate SHA-256 values exactly; retained final Mac/iOS/performance evidence; and reclaimed **25.99 GiB** total without removing dependency directories.

## Evidence still required for 100/100

- Launch and interaction matrix on physical iPhone and iPad hardware.
- Real WAN tests with latency, packet loss, offline/reconnect, and relay failover.
- End-to-end VoiceOver/keyboard/Switch Control traversal by a real accessibility runtime.
- A successful memgraph/leaks capture; the current simulator attempt did not produce a usable memgraph.
- Multi-hour soak with repeated WebSocket reconnects, syncs, file transfers, and memory/handle trend checks.

**94 is the highest evidence-honest score** until the remaining physical-device, WAN, assistive-technology, memgraph, and soak checks pass.
