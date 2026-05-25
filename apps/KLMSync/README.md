# KLMSync App

SwiftUI app layer for the existing `klms-notes-sync` engine.

## Targets

- `KLMSMac`: macOS menu bar app that installs and runs the local KLMS sync engine.
- `KLMSiOS`: iPhone companion UI for remote command/status workflows.
- `KLMSShared`: shared models, `.env` editing, command construction, JSON parsing, LaunchAgent helpers, and CloudKit command types.

## Development

From this directory:

```sh
swift test
swift run KLMSMac
```

When run from source, `KLMSMac` locates the repository checkout and installs code into `~/Library/Application Support/KLMSNotesSync`. A packaged app can include a full `EnginePayload` resource with the same top-level layout as the repository.

To build a local `.app` bundle from the repository root:

```sh
tools/build_klms_mac_app.sh
```

The bundle is written to `~/Applications/KLMS Sync.app` by default. The build script injects the current engine code into the app resource bundle as `EnginePayload`; private runtime data stays in `~/Library/Application Support/KLMSNotesSync` and is preserved by the installer. Set `DIST_DIR=/path/to/output` when a different output directory is needed.

CloudKit signing is opt-in for local builds. A Mac app with iCloud entitlements needs a matching Apple Developer App ID, provisioning profile, and iCloud container; adding the entitlement without that provisioning can make macOS refuse to launch the app. After the CloudKit container is ready, build with `ENABLE_CLOUDKIT_ENTITLEMENT=1 ICLOUD_CONTAINER_IDENTIFIER=iCloud.<your.container> tools/build_klms_mac_app.sh`. The iPhone target must use the same container in `Config/KLMSiOS.entitlements`.

## iPhone companion

The iPhone app only creates `RunCommand` records and reads sanitized status counts. It does not scrape KLMS, does not receive raw logs, and does not store KLMS URLs, `config.env`, Kaikey state, or local file paths in CloudKit.

On the Mac app, turn on `iPhone 요청 자동 처리` from the command panel or Settings > iPhone. The Mac app polls CloudKit every 20 seconds while it is running, marks old pending requests as `Mac 응답 없음`, and executes only one sync command at a time.

For an actual device build, create or configure an Xcode iOS app target with:

- bundle identifier matched to the same Apple developer team as the Mac app;
- iCloud capability enabled with CloudKit;
- `Config/KLMSiOS.entitlements` attached and using the same iCloud container as the Mac app;
- the `KLMSiOS` and `KLMSShared` source folders included in the target.

If the app is ad-hoc signed, macOS can treat each rebuilt bundle as a different privacy subject. When Notes automation works from Terminal/Codex but fails from `KLMS Sync.app`, reset the app privacy records and grant them again:

```sh
tools/reset_klms_app_permissions.sh
```

Then enable `KLMS Sync` in System Settings > Privacy & Security > Accessibility, and allow the app's Automation prompts for Notes, Safari, System Events, Calendar, and Reminders.
