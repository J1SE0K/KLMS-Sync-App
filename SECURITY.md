# Security Policy

## Sensitive Local Files

Never commit files that contain local account state, KLMS content, downloads, cookies, MFA registration data, or course-specific private information.

The repository intentionally ignores:

- `config.env`
- `manual_assignment_overrides.json`
- `runtime/`
- `course_files/`
- `course_transcripts/`
- `course_videos/`
- `launchd/*.plist`
- QR screenshots, cookies, logs, and local caches

`examples/config.env.example` and `examples/manual_assignment_overrides.example.json` are safe templates. Real local values should stay outside git.

## Login Assist and MFA

Login assist does not register the Mac as a KAIST MFA device. It only opens the Safari SSO flow, reads the displayed two-digit KAIST challenge, and waits for the user to choose the same number on the phone.

- Do not paste screenshots or logs that include the two-digit challenge, cookies, account identifiers, or KLMS content into public issues.
- Do not expose login assist through a public HTTP endpoint.
- iPhone/iPad/Windows should use the server relay client token only. Mac worker tokens must stay on the Mac.
- If a local credential or token may have leaked, rotate it before sharing a minimal reproduction.

KAIST MFA approval still happens on the user-owned phone. The Mac never performs hidden MFA approval.

## Reporting

This is an unofficial personal automation project. Do not include secrets, cookies, QR codes, state files, screenshots with account data, or course materials in public issues. For a suspected leak, rotate the affected credentials or MFA registration before sharing a minimal reproduction.
