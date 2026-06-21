#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_IDENTIFIER="${IOS_DEVICE_IDENTIFIER:-${1:-}}"
APP_PATH="${IOS_APP_PATH:-}"
BUILD_FIRST="${IOS_DEVICE_BUILD_FIRST:-1}"
LAUNCH_AFTER_INSTALL="${IOS_DEVICE_LAUNCH:-1}"
TIMEOUT_SECONDS="${IOS_DEVICE_TIMEOUT_SECONDS:-120}"

if [[ -z "$DEVICE_IDENTIFIER" ]]; then
  print -ru2 -- "Usage: IOS_DEVICE_IDENTIFIER=<device-id-or-name|all> $0"
  print -ru2 -- "Tip: list devices with: xcrun devicectl list devices"
  exit 2
fi

if [[ "$BUILD_FIRST" == "1" ]]; then
  APP_PATH="$("$ROOT_DIR/tools/build_klms_ios_device.sh" | tail -n 1)"
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  print -ru2 -- "Missing app bundle. Set IOS_APP_PATH or keep IOS_DEVICE_BUILD_FIRST=1."
  exit 2
fi

BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
if [[ -z "$BUNDLE_IDENTIFIER" ]]; then
  print -ru2 -- "Could not read CFBundleIdentifier from $APP_PATH"
  exit 2
fi

install_one_device() {
  local target_device="$1"
  xcrun devicectl device install app \
    --device "$target_device" \
    --timeout "$TIMEOUT_SECONDS" \
    --quiet \
    "$APP_PATH"

  if [[ "$LAUNCH_AFTER_INSTALL" != "1" ]]; then
    print -r -- "installed"
    return 0
  fi

  local LAUNCH_OUTPUT
  LAUNCH_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/klms-ios-launch.XXXXXX")"
  if ! xcrun devicectl device process launch \
    --device "$target_device" \
    --timeout "$TIMEOUT_SECONDS" \
    --quiet \
    --terminate-existing \
    "$BUNDLE_IDENTIFIER" >"$LAUNCH_OUTPUT" 2>&1; then
    if /usr/bin/grep -Eiq "locked|could not be, unlocked|unable to launch" "$LAUNCH_OUTPUT"; then
      rm -f "$LAUNCH_OUTPUT"
      print -ru2 -- "Installed, but launch was denied because the device is locked. Unlock the device and rerun with IOS_DEVICE_BUILD_FIRST=0 IOS_APP_PATH=\"$APP_PATH\"."
      exit 3
    fi
    /usr/bin/sed "s/${BUNDLE_IDENTIFIER//\//\\/}/<bundle-id>/g" "$LAUNCH_OUTPUT" >&2
    rm -f "$LAUNCH_OUTPUT"
    exit 1
  fi
  rm -f "$LAUNCH_OUTPUT"
  print -r -- "installed-and-launched"
}

discover_ios_devices() {
  local devices_json
  devices_json="$(mktemp "${TMPDIR:-/tmp}/klms-ios-devices.XXXXXX.json")"
  xcrun devicectl list devices --json-output "$devices_json" --quiet >/dev/null
  /usr/bin/python3 - <<'PY' "$devices_json"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    devices = json.load(handle).get("result", {}).get("devices", [])

for device in devices:
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    properties = device.get("deviceProperties", {})
    if hardware.get("platform") != "iOS":
        continue
    if hardware.get("deviceType") not in {"iPhone", "iPad"}:
        continue
    if connection.get("pairingState") != "paired":
        continue
    if properties.get("developerModeStatus") == "disabled":
        continue
    identifier = device.get("identifier")
    if identifier:
        print(identifier)
PY
  rm -f "$devices_json"
}

if [[ "$DEVICE_IDENTIFIER" == "all" ]]; then
  device_ids=("${(@f)$(discover_ios_devices)}")
  if (( ${#device_ids[@]} == 0 )); then
    print -ru2 -- "No paired iPhone/iPad device with Developer Mode enabled was found."
    exit 2
  fi
  print -r -- "installing-on-${#device_ids[@]}-ios-devices"
  for target_device in "${device_ids[@]}"; do
    install_one_device "$target_device"
  done
else
  install_one_device "$DEVICE_IDENTIFIER"
fi
