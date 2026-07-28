# KLMS Sync quality scorecard policy — 2026-07-16

## Current score

This tracked document deliberately does not hard-code a score for the current source tree.
A score is valid only when `tools/generate_release_evidence_receipt.py` produces a private
receipt for one exact, clean commit and the matching built app. Any source change expires
that receipt and every independent review attached to it.

The receipt is the single source of truth. Until it exists, the candidate is **not yet
evidence-certified**. Passing automated checks alone is not described as a literal 100/100.
The generated `evidenceCertifiedScore` is calculated from the committed 100-point rubric
and its active caps; the generator rejects a malformed or non-100-point score model.

For current executions, `docs/quality-gate-inventory.json`, the exact-SHA gate logs, and the
generated receipt are the operational authority. Earlier design specifications under
`docs/superpowers/specs/` remain design history and rationale; they do not replace or amend
an inventory command, skip allowance, or receipt result. Every mandatory gate allows zero
skips. A complementary iPhone/iPad test target may omit a scenario only when the union of
the required iPhone and iPad matrix executes that scenario and the inventory-bound summary
proves full coverage with zero mandatory skips.

## Scoring model

| Area | Points |
|---|---:|
| Function and data integrity | 20 |
| Responsive UI | 20 |
| UX and accessibility | 15 |
| WebSocket, latency, and performance | 15 |
| Security and privacy | 15 |
| Reliability and recovery | 10 |
| Test and release readiness | 5 |
| Total | 100 |

Quality caps are fail-closed:

- Open P0 finding: at most 39
- Open P1 finding: at most 79
- Open P2 finding: at most 89
- Missing mandatory external evidence: at most 94

## Evidence required for a candidate receipt

The committed inventory in `docs/quality-gate-inventory.json` defines the exact commands
and is hashed into every gate log. A release candidate must have all of the following:

- Clean, full 40-character commit SHA and a matching clean app payload/provenance manifest
- Python/core, Swift, macOS runtime, isolated WebSocket UI latency/recovery, payload,
  iOS Simulator, Windows, both relay, and security gates executed through
  `tools/run_release_gate.sh`
- Five exact-SHA independent reviews: goal/constraints, code quality, security/privacy,
  hands-on runtime, and visual/accessibility
- Private mode-0600 logs and reports outside the repository, with byte counts and SHA-256
  digests verified again immediately before the receipt is atomically published

The generator rejects caller-supplied commands, dirty source, stale candidate SHAs,
unbound app bundles, public/symlinked evidence files, duplicate summaries, altered reports,
and a candidate or app that changes during receipt creation.

## Mandatory external evidence

These checks cannot be replaced by Simulator, static analysis, or a command-line assertion:

- Physical iPhone and iPad launch, rotation, background/foreground, file-transfer, and
  interaction matrix
- Controlled real-WAN latency, packet-loss, offline/reconnect, relay-restart, and failover
  matrix
- End-to-end VoiceOver, Switch Control, and hardware-keyboard traversal
- Multi-hour reconnect, sync, cancel, transfer, memory, descriptor, and relay-restart soak

Each external `pass` must be backed by a private `<id>.external.json` record and matching
`<id>.report.txt`. The record must bind the exact candidate SHA, observation timestamp,
report filename, byte count, and SHA-256 digest, and the observation must occur after the
candidate commit and not in the future. A bare `--external-evidence <id>=pass`
argument is rejected. Missing any item keeps `externalEvidenceComplete` false and
`maximumDefensibleScore` at 94.

## Closed risks retained as regression contracts

The test and review gates preserve the original closure criteria:

- Incomplete or non-authoritative KLMS input cannot commit an empty dashboard or authorize
  downstream deletion.
- Dry runs cannot mutate Calendar or Reminders.
- Course files use verified staging and atomic replacement; refresh failure blocks pruning.
- Core and notice jobs share the lock required by their shared state.
- Relay storage keys are server-owned and canonically contained; commands, UUIDs, origins,
  message/body sizes, connections, quotas, and rates are validated or bounded.
- Reminder completion overrides require stable item identity rather than title alone.
- Malformed inbox records are isolated; command insertion and quota accounting are atomic.
- Cancellation remains cancellation; account/relay reset clears server-derived history.
- SQLite backup uses a consistent backup API and verified atomic publication.
- Optimistic iOS actions distinguish definitive rejection from an unknown POST outcome and
  reconcile by exact identifier before rollback.
- Credentials, logs, release artifacts, and app payloads fail closed on provenance,
  permissions, redaction, and integrity boundaries.

This document defines how to earn and interpret the score. It is not itself evidence that a
specific build earned one.
