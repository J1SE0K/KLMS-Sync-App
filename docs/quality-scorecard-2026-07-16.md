# KLMS Sync quality scorecard — 2026-07-16

## Result

**Current evidence-certified score: 94/100**

The candidate earns an implementation-and-automated-evidence score of **100/100** from code review, automated tests, macOS runtime probes, Electron testing, iPhone/iPad Simulator testing, ETTrace, and security evidence. The externally certified score is capped at 94 because evidence that requires physical devices, a real impaired WAN, a real assistive-technology session, a usable object-level memgraph, and a multi-hour soak has not been produced. This is an evidence boundary, not a known open product defect, and it prevents the scorecard from presenting an unverifiable literal guarantee.

Scoring rules:

- Function and data integrity: 20
- Responsive UI: 20
- UX and accessibility: 15
- WebSocket, latency, and performance: 15
- Security and privacy: 15
- Reliability and recovery: 10
- Test and release readiness: 5
- Caps: open P0 → 39, open P1 → 79, open P2 → 89, missing mandatory external evidence → 94

| Area | Score | Evidence |
|---|---:|---|
| Function and data integrity | 20/20 | Authoritative parser certificate, destructive-delta guard, atomic file replacement, shared state lock, scoped completion overrides, durable terminal-result outbox, and per-record relay decoding |
| Responsive UI | 20/20 | macOS 640/900/1200 containment and resize-hit testing; Windows responsive Electron flow; iPhone and iPad portrait/landscape matrices including 1040/1046/1048-point boundaries |
| UX and accessibility | 15/15 | Three-stage fixed-width sidebar, compact destructive controls, confirmation dialogs, semantic labels, keyboard focus retention, Dynamic Type and accessibility-size tests; real assistive traversal is handled by the external-evidence cap |
| WebSocket, latency, and performance | 15/15 | WebSocket-only live state, bounded connections/messages, reconnect recovery, path-aware off-main refresh, 2,000-item Windows/iOS tests, macOS tab-response average 19 ms |
| Security and privacy | 15/15 | Auth precedes protected readiness/maintenance, exact origins and UUID routes, 32-byte tokens, traversal containment, quota reservations, private readiness reports, native PDF rendering, and ten-scanner evidence with scanner-environment self-audit |
| Reliability and recovery | 10/10 | Atomic state/file updates, verified SQLite backup/restore, versioned salvageable result replay, stale claim recovery, deletion retry preservation, and stable repeated-navigation footprint; soak and usable memgraph requirements are handled by the external-evidence cap |
| Test and release readiness | 5/5 | Python, Swift, iOS UI, macOS readiness, Windows unit/E2E, both relays, restore faults, packaging, dependency audits, and private security evidence are wired into reproducible gates |
| Implementation and automated evidence | **100/100** | No known P0/P1/P2 defect remains in the reviewed candidate |
| Active cap | **94/100** | Mandatory external evidence is incomplete |

## Confirmed verification ledger

| Surface | Confirmed result |
|---|---|
| Python/core | **303 passed**, 0 failed |
| Swift package | **255 passed**, 0 failed, isolated scratch path |
| macOS responsive runtime | All primary screens and settings contained at 640/900/1200; native edge resize and expanded 10-point inner hit target passed |
| macOS interaction latency | Three tab-probe runs averaged 19/20/19 ms; combined average **19 ms**, slowest dashboard observation 59 ms |
| Windows unit | **29 passed**, 0 failed |
| Windows Electron E2E | **8 passed**, including responsive breakpoints, contrast contracts, WebSocket flow, focus retention, and 2,000-item data |
| iPhone Simulator | Full UI matrix passed on iPhone 17 Pro, including all tabs, compact-width containment, history deletion UX, accessibility size, and 2,000-item flow |
| iPad Simulator | Full portrait/landscape matrix passed on iPad Pro 13-inch M5, including all tabs, fixed sidebar, boundary widths, and 2,000-item flow |
| iOS independent build/run | XcodeBuildMCP built and launched the current iPhone target successfully |
| ETTrace | 15.275-second trace: 14.553 seconds idle, 0.722 seconds active; largest visible app-specific frame was 0.79% of active time |
| Memory trend | Fresh footprint 50 MB, first 21-tab traversal 68 MB, second identical traversal 69 MB; no repeated linear gross growth observed |
| Self-host relay | Syntax, auth boundary, WebSocket, traversal, streamed body limit, malformed JSON, isolated auth/file-ticket request limits, quota contention, deletion retry, SQLite backup, and restore fault tests passed |
| Cloudflare relay | Check, smoke, D1 integration, atomic command contention, streamed body limit, malformed JSON, isolated auth/file-ticket request limits, quota, migration, hostile-title, exact-route, and WebSocket tests passed |
| Security evidence | Semgrep, Bandit, detect-secrets, Gitleaks, ShellCheck, pip-audit, Trivy, OSV-Scanner, Syft/Grype, and both npm audits passed their gates |

Security reports are created mode 0700 under a private temporary directory and are not uploaded. Native scanner archives are version-pinned and SHA-256 verified. The Python scanner environment pins pip 26.1.2 and replaces Semgrep's stale `click~=8.1.8` dependency with Click 8.4.2 because the declared range is affected by PYSEC-2026-2132. The installer accepts only that exact metadata mismatch, executes a real Semgrep finding smoke test, and audits the installed scanner environment for known vulnerabilities.

## Original review closure

| # | Original risk | Current closure |
|---:|---|---|
| 1 | Incomplete KLMS input could become an authoritative empty state and trigger deletions | Semantic parser certificates and destructive-delta guards fail closed before state commit or downstream deletion |
| 2 | `--dry-run` could mutate Calendar | Calendar and Reminders side effects require a non-dry run and have regression coverage |
| 3 | Course-file refresh could delete a valid destination before a failed copy | Verified sibling staging plus atomic replace; incomplete refresh blocks prune and returns failure |
| 4 | Core and notice jobs could race on shared notice state | Both use one shared `core-notice` lock while keeping separate work caches |
| 5 | Worker-controlled object keys could escape self-host storage | Server-owned keys, strict schema, canonical containment, and traversal tests |
| 6 | Completed Reminder overrides could complete future same-title work | Overrides require URL identity or course/title/due identity |
| 7 | One malformed relay command could block the whole Mac inbox | Server UUID/enum validation plus record-by-record tolerant Swift decoding |
| 8 | Cloudflare pending-command check and insert were not atomic | Partial unique index and conflict mapping permit one pending/running winner |
| 9 | Download quota and deletion paths could race or orphan files | Persistent reservation claims, idempotent finalization/release, stale recovery, and deletion retry rows |
| 10 | User-cancelled remote commands were reported as failed | Cancellation now persists and reports `.cancelled` |
| 11 | Relay/account changes retained stale sensitive state | Windows and iOS reset all server-derived histories, settings, requests, files, and status |
| 12 | WAL-mode database backup copied only the main file | SQLite backup API, integrity/schema/revision verification, atomic mode-0600 publication |
| 13 | Python regression was red and CI could not block it | Wording aligned and cross-platform test/security workflows cover the release surfaces |

## Additional closure from the final review

- Authenticated-but-unparseable or all-zero data cannot silently replace an established dashboard.
- Mac terminal results survive process termination and replay until acknowledged instead of stopping after three attempts.
- Mac filesystem events are filtered by changed path and decoded away from the main actor before one coalesced UI refresh.
- iOS optimistic command mutations roll back only the affected versioned item, so an older failure cannot overwrite newer state.
- Public `/healthz` is deliberately shallow; protected `/readyz`, maintenance work, and detailed diagnostics require authentication.
- Relay WebSocket connections, message sizes, HTTP bodies, request rates, origins, and route identifiers are bounded before expensive work.
- Malformed JSON returns 400, streamed bodies above 1 MiB return 413, invalid credentials cannot consume authenticated-role buckets, and well-formed fake file tickets cannot consume a real link bucket.
- Public run logs redact credentials, arbitrary URLs, email addresses, and Unix/macOS/Windows absolute paths at every relay publication boundary.
- iOS rejects overlapping same-item optimistic mutations, serializes Keychain token writes off the main actor, clears credentials in order, and gives sensitive pasteboard values local-only expiry metadata.
- The terminal-result outbox is versioned, bounds age and entry count, salvages valid records around corruption, quarantines malformed payloads, and accepts terminal states only.
- Relay deletion claims are recoverable if the process stops after the storage object disappears but before the row is finalized.
- PDF rendering uses the platform-native viewer, removing the stale bundled PDF.js dependency.
- Windows light/dark border tokens meet the tested non-text contrast contract.
- UI readiness artifacts are private, contain no live state, and are never uploaded by the workflow.

## Evidence still required for a literal 100/100

- Launch, rotation, background/foreground, file transfer, and interaction matrices on physical iPhone and iPad hardware.
- Real WAN tests with controlled latency, packet loss, offline/reconnect, relay restart, and failover.
- End-to-end VoiceOver, hardware-keyboard, and Switch Control traversal with a real accessibility runtime.
- A successful object-level memgraph/leaks capture. The current Simulator process was measurable by `footprint`, but the host `leaks` API failed to obtain DYLD information and Instruments did not produce a valid trace.
- A multi-hour soak covering repeated WebSocket reconnects, syncs, cancellations, file transfers, memory, descriptors, and relay restarts.

**94 is the highest externally evidence-honest score** until those checks pass. The implementation and automated evidence reach 100/100 with no known P0/P1/P2 defect in the reviewed candidate; that score does not convert missing physical evidence into a claim of certainty.
