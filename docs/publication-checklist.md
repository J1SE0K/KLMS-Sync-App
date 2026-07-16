# Publication Checklist

Use this checklist before pushing the repository to a public GitHub repo.

## Files

- `config.env` is local only and ignored.
- `manual_assignment_overrides.json` is local only and ignored.
- `apps/KLMSync/Config/KLMSiOS.local.xcconfig` is local only and ignored.
- `runtime/`, `course_files/`, `course_transcripts/`, and `course_videos/` are ignored.
- QR screenshots, cookies, logs, launchd plists, and downloaded KLMS files are not tracked.
- One-off scripts containing a real semester, course, student, assistant, or submission dataset are not tracked.
- Real relay URLs, relay tokens, Cloudflare account IDs, Cloudflare API tokens, Apple Team IDs, bundle IDs containing a personal name/account, and device identifiers are local only. Commit placeholders and setup steps instead.

## Scans

Run these before publishing:

```sh
git status --short
git status --ignored --short
git ls-files | rg '(^|/)(config\.env|manual_assignment_overrides\.json)$|^(runtime|course_files|course_transcripts|course_videos)/'
git grep -n -E '(/Users/|bwid=[0-9]+|MoodleSession|MOODLEID_|[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,})' -- ':!docs/publication-checklist.md'
git grep -n -E '(학번|주민|전화|실명|your-kaist-id|student-id)' -- ':!docs/publication-checklist.md'
```

The first command should show only intentional source/documentation changes. The ignored status may show local private files, but those files must not appear in `git status --short` as tracked or untracked commit candidates.

## Verification

Run syntax checks and focused tests:

```sh
python3 -m unittest discover -s tests
node --check src/js/klms_login_safari_step.js
node --check src/js/sync_klms_notes.js
node --check src/js/download_klms_files.js
zsh -n *.sh bin/*.sh src/sh/*.sh
swiftc -typecheck src/swift/decode_qr_image.swift
swiftc -typecheck src/swift/verify_calendar_counts.swift
swiftc -typecheck src/swift/notice_native_note_support.swift src/swift/update_notice_native_note.swift
```

Some runtime checks need Safari, macOS Automation permissions, Reminders, Calendar, Notes, and an active KLMS session. Do not record or publish outputs containing course pages or account data.

Run the app readiness gate before shipping Mac/iPhone/iPad UI or relay changes:

```sh
tools/verify_klms_app_readiness.sh
```

This helper runs Swift tests, the signed Mac app build, Mac accessibility smoke, Mac basic-actions smoke, the Mac tab-response probe, signed iOS build, and iPhone/iPad launch verification. The basic-actions smoke verifies the dashboard action and log-clear controls without activating data-destructive actions, then checks Command-Q and the app reopen path. Set `KLMS_MAC_SMOKE_ALLOW_DESTRUCTIVE_ACTIONS=1` only in an isolated fixture profile when the clear actions themselves must be pressed. Treat a skipped or pending iPhone/iPad launch gate as incomplete device readiness, not as a clean release.

For a release candidate, run every command in `docs/quality-gate-inventory.json`
through the exact-SHA wrapper and keep the private logs outside the repository:

```sh
export KLMS_RELEASE_EVIDENCE_DIR=/private/tmp/klms-release-evidence
tools/run_release_gate.sh python-core -- \
  env PYTHONPATH=vendor/python-packages python3 -B -m unittest discover -s tests
```

After all automated gates pass, generate the private receipt outside the repository:

```sh
tools/record_release_review.py \
  --lane goal-and-constraint \
  --report /private/tmp/goal-and-constraint-review.txt \
  --evidence-dir /private/tmp/klms-release-reviews \
  --status pass
tools/generate_release_evidence_receipt.py \
  --evidence-dir "$KLMS_RELEASE_EVIDENCE_DIR" \
  --review-evidence-dir /private/tmp/klms-release-reviews \
  --app "$HOME/Applications/KLMS Sync.app" \
  --output /private/tmp/klms-release-receipt.json
```

The receipt stays capped at 94 until every mandatory physical-device, impaired-WAN,
assistive-input, and soak item is supplied explicitly as external pass evidence.

## GitHub

Create an empty public repository, then push only after the scans are clean:

```sh
git remote add origin git@github.com:<owner>/<repo>.git
git push -u origin main
```

After pushing, check the GitHub file list in the browser. If a secret or private artifact was pushed, rotate the exposed credential first, then rewrite or delete the public history.
