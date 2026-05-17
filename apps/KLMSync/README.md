# KLMSync App

SwiftUI app layer for the existing `klms-notes-sync` engine.

## Targets

- `KLMSMac`: macOS menu bar app that installs and runs the local KLMS sync engine.
- `KLMSiOS`: iPhone companion scaffold for remote command/status workflows.
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
