# KLMSync App

SwiftUI app layer for the existing `klms-notes-sync` engine.

## Targets

- `KLMSMac`: macOS menu bar app that installs and runs the local KLMS sync engine.
- `KLMSiOS`: universal iPhone/iPad companion UI for remote command/status workflows.
- `KLMSShared`: shared models, `.env` editing, command construction, JSON parsing, sync lock reading, and relay command types.

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

CloudKit signing is opt-in for local builds. A Mac or iPhone app with iCloud entitlements needs a matching Apple Developer App ID, provisioning profile, and iCloud container; Apple Personal Team/free Apple ID signing does not support the iCloud capability. Adding the entitlement without that provisioning can make the app fail to launch. The default iPhone entitlement file is intentionally empty so the app can run on a free account with local-network remote control. After the CloudKit container is ready, build the Mac app with `ENABLE_CLOUDKIT_ENTITLEMENT=1 ICLOUD_CONTAINER_IDENTIFIER=iCloud.<your.container> tools/build_klms_mac_app.sh`, enable the same iCloud container on the iPhone target, and add `KLMS_ENABLE_CLOUDKIT` to the iPhone target's Swift active compilation conditions.

## iPhone/iPad companion

The iPhone/iPad app only creates remote requests and reads sanitized status counts. It does not scrape KLMS, does not receive raw logs, and does not store KLMS URLs, `config.env`, Kaikey state, or local file paths. When a user asks to open a file, the Mac worker uploads only that local `course_files` file to the server relay's temporary file store and the link expires automatically.

The checked-in Xcode target is a universal iOS/iPadOS app. iPhone uses the compact tab layout, while iPad uses the adaptive split layout so the section list and selected detail can stay visible together. Do not create a separate iPad-only target unless the app needs a different bundle identifier or entitlement set.

For a free Apple ID, use local-network remote control:

- Turn on local remote control in the Mac app.
- Copy the Mac connection info into the iPhone/iPad app.
- Keep both devices on the same Wi-Fi, or put both devices on the same private VPN and enter the Mac VPN address.
- Do not expose the raw local remote port to the public internet.

For use away from the same network, run the HTTPS relay server in `deploy/cloudflare-worker`, then enter the relay URL plus the client token in iPhone/iPad/Windows and the worker token in the Mac app. The relay stores command/status metadata plus sanitized assignment, exam, notice, and file list rows. KLMS scraping and macOS app integrations still run on the Mac, and raw logs, KLMS URLs, `config.env`, Kaikey state, and absolute local file paths are not uploaded.

The Windows companion lives in `apps/KLMSyncWindows`. It uses the same relay API as the iPhone/iPad app and can read the dashboard, browse sanitized item lists, toggle notice read/important state, request temporary file links, and create remote sync requests. The Windows implementation guide is tracked in `docs/windows-implementation-guide.md`.

On the Mac worker, install the relay as a background service with:

```sh
tools/install_klms_relay_agent.sh install
```

For CloudKit mode, turn on `iPhone 요청 자동 처리` from the Mac app command panel or Settings > iPhone. The Mac app polls CloudKit every 20 seconds while it is running, marks old pending requests as `Mac 응답 없음`, and executes only one sync command at a time.

The checked-in iPhone Xcode project is generated at:

```sh
apps/KLMSync/Xcode/KLMSiOS/KLMSiOS.xcodeproj
```

Regenerate it after adding/removing shared source files:

```sh
tools/generate_klms_ios_xcode_project.py
```

Compile the iPhone/iPad companion for the iOS Simulator SDK without signing:

```sh
tools/build_klms_ios_sim.sh
```

The build product is written under `/private/tmp/klms-ios-build`. This avoids Xcode build database writes inside the repository.

Open the iPhone project in Xcode:

```sh
tools/open_klms_ios_project.sh
```

For an actual iPhone device build with a free Apple ID, configure the generated Xcode target with:

- a unique bundle identifier;
- your Personal Team;
- no iCloud capability.

The checked-in Xcode project intentionally uses generic signing values. Keep your real Team ID, bundle identifier, provisioning profile, relay URL, and relay token as local Xcode/app settings only. Do not commit those values; commit only setup steps and `.example` templates.

For repeatable local device builds, create the ignored file `Config/KLMSiOS.local.xcconfig`:

```xcconfig
KLMS_IOS_DEVELOPMENT_TEAM = YOURTEAMID
KLMS_IOS_BUNDLE_IDENTIFIER = com.yourname.KLMSync.iOS
```

This launches the companion UI with local-network remote execution available. For CloudKit remote execution, configure the target with a paid Apple Developer team and:

- bundle identifier matched to the same Apple developer team as the Mac app;
- iCloud capability enabled with CloudKit;
- `Config/KLMSiOS.entitlements` attached and using the same iCloud container as the Mac app;
- `KLMS_ENABLE_CLOUDKIT` added to Swift active compilation conditions;
- a matching iOS runtime/device support package installed in Xcode.

If the app is ad-hoc signed, macOS can treat each rebuilt bundle as a different privacy subject. When Notes automation works from Terminal/Codex but fails from `KLMS Sync.app`, reset the app privacy records and grant them again:

```sh
tools/reset_klms_app_permissions.sh
```

Then enable `KLMS Sync` in System Settings > Privacy & Security > Accessibility, and allow the app's Automation prompts for Notes, Safari, System Events, Calendar, and Reminders.
