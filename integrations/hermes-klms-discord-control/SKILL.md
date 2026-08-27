---
name: klms-sync
description: "Use /klms-sync with stepwise clarify buttons for safe approved KLMS sync."
version: 1.0.0
platforms: [windows, macos]
metadata:
  hermes:
    tags: [klms, discord, sync, approval, safari]
---

# KLMS Discord control

This artifact is a control surface, not a Discord gateway or bot. Use the existing Hermes Discord channel and the `/klms-sync` command surface only.

## Contract

1. `start-auth`: ask the Mac Safari bridge to begin authentication, then show a clarify button for `verify-login`. Display exactly the two-digit challenge once; never log credentials or the full code.
2. `verify-login`: require a positive login verification result before showing clarify buttons for term/course allowlists.
3. `preview`: require string `semester_code` (for example `"20"`), apply the selected-term/course allowlist and scope, and return only the canonical JSON SHA-256 hex digest. Show clarify buttons for `approve` or refresh.
4. `approve`: record explicit approval bound to numeric guild/channel/thread/user metadata, selected terms/courses, scope, digest, created/expiry times, nonce, and idempotency key.
5. `execute`: revalidate every binding, reject forged approval and replay, then execute through the existing Mac Safari bridge. No Windows direct KLMS browser and no separate Discord gateway.
6. `post-verify`: read the result back and report success only when verification succeeds; a failed execute may retry once, while failed post-verification is never success.

Destructive file deletion and external side effects remain behind the explicit approval step. Logs must be redacted at the boundary.
