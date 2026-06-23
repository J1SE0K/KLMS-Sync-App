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

## iPhone/iPad companion

The iPhone/iPad app only creates remote requests and reads sanitized status counts. It does not scrape KLMS, does not receive raw logs, and does not store KLMS URLs, `config.env`, Kaikey state, or local file paths. When a user asks to open a file, the Mac worker uploads only that local `course_files` file to the server relay's temporary file store and the link expires automatically.

The checked-in Xcode target is a universal iOS/iPadOS app. iPhone uses the compact tab layout, while iPad uses the adaptive split layout so the section list and selected detail can stay visible together. Do not create a separate iPad-only target unless the app needs a different bundle identifier or entitlement set.

The supported remote path is the HTTPS server relay. Run the Cloudflare Workers + D1/R2 relay in `deploy/cloudflare-worker`, then enter the relay URL plus the client token in iPhone/iPad/Windows and the worker token in the Mac app. The relay stores command/status metadata plus sanitized assignment, exam, notice, and file list rows. KLMS scraping and macOS app integrations still run on the Mac, and raw logs, KLMS URLs, `config.env`, Kaikey state, and absolute local file paths are not uploaded. See [server-relay.md](../../docs/server-relay.md) for setup and API details.

The old same-Wi-Fi local remote control path is development-only fallback. Do not expose the raw local remote port to the public internet. CloudKit is not the default path for this app; the checked-in iOS entitlements stay empty so the app can build with a free Apple ID.

The Windows companion lives in `apps/KLMSyncWindows`. It uses the same relay API as the iPhone/iPad app and can read the dashboard, browse sanitized item lists, toggle notice read/important state, request temporary file links, and create remote sync requests. The Windows implementation guide is tracked in `docs/windows-implementation-guide.md`.

On the Mac worker, install the relay as a background service with:

```sh
tools/install_klms_relay_agent.sh install
```

The relay uses WebSocket realtime events with a short fallback check. Mac executes one sync command at a time. iPhone/iPad can still show the last server data when the Mac worker is off; new sync and file-link requests wait until the Mac worker is available.

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

For an actual iPhone or iPad device build with a free Apple ID, configure the generated Xcode target with:

- a unique bundle identifier;
- your Personal Team;
- no iCloud capability;
- no relay URL or token committed into the Xcode project.

The checked-in Xcode project intentionally uses generic signing values. Keep your real Team ID, bundle identifier, provisioning profile, relay URL, and relay token as local Xcode/app settings only. Do not commit those values; commit only setup steps and `.example` templates.

For repeatable local device builds, create the ignored file `Config/KLMSiOS.local.xcconfig`:

```xcconfig
KLMS_IOS_DEVELOPMENT_TEAM = YOURTEAMID
KLMS_IOS_BUNDLE_IDENTIFIER = com.example.KLMSync.iOS
```

Before shipping a UI change, check both layouts:

```sh
swift test --package-path apps/KLMSync --scratch-path /private/tmp/klmsync-swiftpm-scratch
tools/build_klms_ios_sim.sh
CODE_SIGNING_ALLOWED=NO tools/build_klms_ios_device.sh
```

For the full Mac/iPhone/iPad readiness gate, run:

```sh
tools/verify_klms_app_readiness.sh
```

The readiness helper runs the Swift tests, Mac app build, Mac accessibility smoke, Mac tab-response probe, signed iOS build, and iPhone/iPad launch verification. Its summary marks omitted gates as `skipped`, so a run that disables iOS launch verification is not treated as full device readiness. It redacts local paths and signing-related values in its output. If the devices are locked or the developer app is not trusted yet, the iOS launch step fails with the same `launch-check pending` or `launch-check blocked` wording as the install helpers.

Then run a signed device build with local signing settings:

```sh
tools/build_klms_ios_device.sh
```

The helper validates `Config/KLMSiOS.local.xcconfig` before it starts `xcodebuild`. Empty values, `YOURTEAMID`, `com.example.KLMSync.iOS`, and the checked-in `com.local.KLMSync.iOS` placeholder fail fast so a real iPhone/iPad install does not spend time building an unsigned or non-unique app.

If Xcode has a signed-in development account but the provisioning profile has not been created yet, allow Xcode to create or update the local profile:

```sh
IOS_ALLOW_PROVISIONING_UPDATES=1 tools/build_klms_ios_device.sh
```

If the signed build says `No Accounts`, `Invalid credentials in keychain`, or `No profiles for ...`, open Xcode > Settings > Accounts and confirm the Apple ID used for device development is signed in. Then make sure `Config/KLMSiOS.local.xcconfig` uses that account's current Team ID and a unique bundle identifier. The helper prints the full xcodebuild log path and the compile-only fallback command.

Device build output is sanitized by default. Local home/repo paths, Team IDs, app identifiers, provisioning profile IDs, signing hashes, and account emails are replaced with placeholders in the terminal and in the temporary build log. Keep `Config/KLMSiOS.local.xcconfig` ignored and never paste real signing values into tracked docs or issues.

`CODE_SIGNING_ALLOWED=NO` is only for compile checks. iPhone and iPad devices reject unsigned app bundles, so install with the signed build path produced by the normal device build or let the install helper build it for you.

To install and launch the signed app on a connected device:

```sh
IOS_DEVICE_IDENTIFIER="<device id or name>" tools/install_klms_ios_device.sh
```

The install helper builds first by default, so the same local signing checks and `No Accounts` guidance apply before the app is copied to the device.

To install the same signed build on every paired iPhone/iPad with Developer Mode enabled:

```sh
IOS_DEVICE_IDENTIFIER=all IOS_DEVICE_LAUNCH=0 tools/install_klms_ios_device.sh
```

The device must be unlocked for the launch step. If iOS is still refreshing app registration after installation, the helper retries launch verification briefly before giving up. Tune that with `IOS_DEVICE_LAUNCH_RETRIES` and `IOS_DEVICE_LAUNCH_RETRY_DELAY_SECONDS`. If the helper says `installed; launch-check skipped` or `installed; launch-check pending`, the app is already installed; unlock the device and open KLMS Sync manually, or rerun the same install command after the device is ready. If the helper says `installed; launch-check blocked`, open Settings > General > VPN & Device Management on that iPhone/iPad, trust the developer app, then open KLMS Sync or rerun the same install command to verify launch. To install without launching, use `IOS_DEVICE_LAUNCH=0`. When installing to `all`, the helper waits up to 45 seconds for paired iPhone/iPad devices to become available, prints a generic `iPhone` or `iPad` label for each result, skips devices that CoreDevice still reports as unavailable, continues with the remaining devices, and ends with `install-summary installed=... launched=... installed_only=... manual_launch_needed=... failed=...`. That line separates total installed devices, devices launched by the helper, install-only devices, and devices that need a manual app open. It still exits non-zero when a requested launch could not be verified. Set `IOS_DEVICE_WAIT_FOR_AVAILABLE_SECONDS=0` to fail immediately. If a device is skipped, unlock it, reconnect USB, accept the Trust prompt, and confirm Developer Mode is enabled. If installation says the app is not signed, rebuild without `CODE_SIGNING_ALLOWED=NO`.

After trusting the developer app on a device, verify launch without reinstalling:

```sh
IOS_DEVICE_IDENTIFIER=all tools/verify_klms_ios_device_launch.sh
```

The launch checker prints generic `iPhone`/`iPad` labels and ends with `launch-check-summary launched=... manual_launch_needed=... failed=...`. It uses the signed app bundle or ignored local iOS config only to find the bundle identifier, and it redacts that identifier from error output.

Run it once on an iPhone and once on an iPad. iPhone must show the compact `상태 / 로그 / 설정` tab flow with dashboard detail opened inline. iPad must show the split workspace with the section list on the left and the selected detail on the right. Important banners such as KAIST auth digits and running/cancel status must stay visible above the selected screen on both devices.

If the app is ad-hoc signed, macOS can treat each rebuilt bundle as a different privacy subject. When Notes automation works from Terminal/Codex but fails from `KLMS Sync.app`, reset the app privacy records and grant them again:

```sh
tools/reset_klms_app_permissions.sh
```

Then enable `KLMS Sync` in System Settings > Privacy & Security > Accessibility, and allow the app's Automation prompts for Notes, Safari, System Events, Calendar, and Reminders.
