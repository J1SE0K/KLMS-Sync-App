#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_IDENTIFIER="${IOS_DEVICE_IDENTIFIER:-${1:-}}"
APP_PATH="${IOS_APP_PATH:-}"
BUILD_FIRST="${IOS_DEVICE_BUILD_FIRST:-1}"
LAUNCH_AFTER_INSTALL="${IOS_DEVICE_LAUNCH:-1}"
TIMEOUT_SECONDS="${IOS_DEVICE_TIMEOUT_SECONDS:-120}"
INSTALL_ALL_MODE=0

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

if ! /usr/bin/codesign -dv "$APP_PATH" >/dev/null 2>&1; then
  print -ru2 -- "The app bundle is not signed, so iPhone/iPad cannot install it."
  print -ru2 -- "Build a signed device app first: IOS_DEVICE_IDENTIFIER=<device-id-or-name|all> $0"
  print -ru2 -- "Use CODE_SIGNING_ALLOWED=NO builds only for compile checks, not device installs."
  exit 2
fi

install_one_device() {
  local target_device="$1"
  local device_label="${2:-device}"
  xcrun devicectl device install app \
    --device "$target_device" \
    --timeout "$TIMEOUT_SECONDS" \
    --quiet \
    "$APP_PATH"

  if [[ "$LAUNCH_AFTER_INSTALL" != "1" ]]; then
    print -r -- "${device_label}: installed"
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
      print -ru2 -- "${device_label}: installed, but launch was denied because the device is locked. Unlock the device and rerun with IOS_DEVICE_BUILD_FIRST=0 IOS_APP_PATH=\"$APP_PATH\"."
      if [[ "$INSTALL_ALL_MODE" == "1" ]]; then
        return 3
      fi
      exit 3
    fi
    /usr/bin/sed "s/${BUNDLE_IDENTIFIER//\//\\/}/<bundle-id>/g" "$LAUNCH_OUTPUT" >&2
    rm -f "$LAUNCH_OUTPUT"
    if [[ "$INSTALL_ALL_MODE" == "1" ]]; then
      return 1
    fi
    exit 1
  fi
  rm -f "$LAUNCH_OUTPUT"
  print -r -- "${device_label}: installed-and-launched"
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
        print(f"{identifier}\t{hardware.get('deviceType', 'device')}")
PY
  rm -f "$devices_json"
}

if [[ "$DEVICE_IDENTIFIER" == "all" ]]; then
  INSTALL_ALL_MODE=1
  device_ids=("${(@f)$(discover_ios_devices)}")
  if (( ${#device_ids[@]} == 0 )); then
    print -ru2 -- "No paired iPhone/iPad device with Developer Mode enabled was found."
    exit 2
  fi
  print -r -- "installing-on-${#device_ids[@]}-ios-devices"
  overall_status=0
  for device_entry in "${device_ids[@]}"; do
    target_device="${device_entry%%$'\t'*}"
    device_label="${device_entry#*$'\t'}"
    if [[ "$device_label" == "$device_entry" || -z "$device_label" ]]; then
      device_label="device"
    fi
    set +e
    install_one_device "$target_device" "$device_label"
    device_status=$?
    set -e
    if (( device_status == 0 )); then
      continue
    fi
    if (( overall_status == 0 )); then
      overall_status="$device_status"
    fi
  done
  exit "$overall_status"
else
  install_one_device "$DEVICE_IDENTIFIER" "device"
fi
