# KLMS Sync safe cleanup and resource optimization design

Date: 2026-07-14  
Status: approved

## Objective

Reduce regenerable disk usage and remove code that is provably unused without deleting personal data, KLMS synchronization state, the local speech-recognition model, credentials, or final quality evidence.

## Approved approach

Use the conservative allowlist approach.

- Preserve all unknown runtime directories and files by default.
- Delete only exact generated paths or KLMS-owned temporary namespaces.
- Remove source only after repository-wide reference checks and relevant tests show that it has no consumer.
- Preserve one final evidence set and one useful build cache where that materially reduces the next build time.

Alternatives were rejected:

- Aggressive wildcard cleanup would reclaim slightly more space but can delete personal output or require large dependency/model downloads.
- Code-only cleanup would avoid deletion risk but leave more than 20 GiB of duplicate local build products.

## Preservation contract

The cleanup must not modify or remove:

- `config.env`, manual overrides, signing configuration, relay credentials, or local Cloudflare configuration;
- `runtime/state`, `runtime/cache`, `runtime/archive`, assignment/exam work, installed helper binaries, or bundled Python packages;
- `runtime/models/ggml-large-v3-turbo.bin`;
- downloaded KLMS course files or transcripts;
- unknown children of `runtime/tmp`, including `runtime/tmp/violence_prevention_20260605`;
- the final Mac responsive matrix, accepted iPhone/iPad result bundles, ETTrace evidence, memgraph failure evidence, Windows performance JSON/screenshots, and quality/security reports.

The preservation contract is fail-closed: an unrecognized path is kept, not deleted.

## Cleanup architecture

### Runtime tmp cleanup

`cleanup_runtime_tmp.sh` distinguishes two scopes:

1. A specific KLMS namespace target may remove expired contents within that namespace.
2. The `runtime/tmp` root may traverse only an explicit allowlist of KLMS-owned namespaces such as `core`, `notice`, `files`, `all`, and `shared`, plus exact known generated root artifacts.

Unknown top-level children are skipped and reported. `tools/clean_local_artifacts.sh` must invoke this guarded cleaner instead of removing `runtime/tmp` wholesale.

### Repository artifacts

After tests finish, exact regenerable paths may be removed:

- SwiftPM `.build` output;
- Windows packaged `dist` output;
- Python bytecode caches and `.DS_Store` files;
- non-evidence test output that has a deterministic regeneration command.

Dependency directories are removed only after all validation is complete and their lockfiles are present. They remain reproducible with `npm ci`.

### `/private/tmp` artifacts

Select the final evidence and one useful Swift/iOS build cache first. Remove only an enumerated list of older KLMS scratch/DerivedData directories after confirming no process has an open working command in them. Do not use an unreviewed wildcard deletion.

## Unused-code policy

A candidate may be removed only when all of these hold:

1. its declaration has no source, test, generated-project, runtime string, shell-entrypoint, or documentation consumer;
2. it is not a public compatibility wrapper;
3. deleting it passes the language syntax/build gate and the closest behavioral regression suite;
4. a full final regression run still passes.

Ambiguous candidates are retained. Large-file splitting and network-fetch parallelization are separate future changes because they alter architecture or runtime behavior beyond cleanup.

## Error handling

- A cleanup command refuses protected roots and exits non-zero on an invalid target.
- A failed deletion is reported and does not broaden the next deletion attempt.
- Dry-run output lists every removal and every preserved unknown namespace.
- User data is never moved automatically as part of cleanup.
- If preservation assertions fail, no artifact deletion proceeds.

## Verification

Before deletion:

- add regression tests proving managed namespaces are cleaned and unknown namespaces survive;
- run the cleaner in dry-run mode and verify the preservation list;
- record before sizes and active processes.

After code and artifact cleanup:

- Python unittest suite;
- full Swift package suite;
- Windows syntax/unit/Electron E2E and performance fixture;
- self-host relay and restore tests;
- Cloudflare check/smoke/integration;
- shell and Node syntax checks;
- `git diff --check`;
- disk-size comparison and explicit checks that preserved paths still exist.

## Success criteria

- Personal/user state and the 1.5 GiB speech model are byte-for-byte preserved.
- Unknown `runtime/tmp` content survives both manual and full-run cleanup paths.
- At least 1 GiB is reclaimed inside the repository.
- Older enumerated KLMS scratch directories reclaim at least 20 GiB from `/private/tmp` while final evidence remains.
- No test or observable product behavior regresses.
