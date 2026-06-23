#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_IDENTIFIER="${IOS_DEVICE_IDENTIFIER:-${1:-all}}"
APP_PATH="${IOS_APP_PATH:-/private/tmp/klms-ios-device-build/Debug-iphoneos/KLMSiOS.app}"
LOCAL_CONFIG="$ROOT_DIR/apps/KLMSync/Config/KLMSiOS.local.xcconfig"
BUNDLE_IDENTIFIER="${IOS_BUNDLE_IDENTIFIER:-}"
TIMEOUT_SECONDS="${IOS_DEVICE_TIMEOUT_SECONDS:-60}"
WAIT_FOR_AVAILABLE_SECONDS="${IOS_DEVICE_WAIT_FOR_AVAILABLE_SECONDS:-20}"
DISCOVERY_POLL_SECONDS="${IOS_DEVICE_DISCOVERY_POLL_SECONDS:-2}"
MANUAL_LAUNCH_STATUS=4
BLOCKED_LAUNCH_STATUS=5
REQUIRED_DEVICE_TYPES="${IOS_DEVICE_REQUIRE_TYPES:-}"
TUNNEL_WARMUP_SECONDS="${IOS_DEVICE_TUNNEL_WARMUP_SECONDS:-15}"
OPEN_SETTINGS_ON_BLOCKED="${IOS_DEVICE_OPEN_SETTINGS_ON_BLOCKED:-1}"
OPEN_SETTINGS_TIMEOUT_SECONDS="${IOS_DEVICE_OPEN_SETTINGS_TIMEOUT_SECONDS:-10}"
TRUST_RETRY_SECONDS="${IOS_DEVICE_TRUST_RETRY_SECONDS:-30}"
TRUST_RETRY_POLL_SECONDS="${IOS_DEVICE_TRUST_RETRY_POLL_SECONDS:-3}"

xcconfig_value() {
  local key="$1"
  /usr/bin/awk -F= -v key="$key" '
    /^[[:space:]]*(\/\/|#)/ { next }
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value=$2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      gsub(/"/, "", value)
      print value
      exit
    }
  ' "$LOCAL_CONFIG"
}

if [[ -z "$BUNDLE_IDENTIFIER" && -d "$APP_PATH" ]]; then
  BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
fi

if [[ -z "$BUNDLE_IDENTIFIER" && -f "$LOCAL_CONFIG" ]]; then
  BUNDLE_IDENTIFIER="$(xcconfig_value KLMS_IOS_BUNDLE_IDENTIFIER)"
fi

if [[ -z "$BUNDLE_IDENTIFIER" || "$BUNDLE_IDENTIFIER" == "com.example.KLMSync.iOS" || "$BUNDLE_IDENTIFIER" == "com.local.KLMSync.iOS" ]]; then
  print -ru2 -- "Could not determine the installed KLMS Sync bundle identifier."
  print -ru2 -- "Run tools/build_klms_ios_device.sh first, or set IOS_APP_PATH to the signed app bundle."
  exit 2
fi

redact_bundle_id() {
  /usr/bin/sed "s/${BUNDLE_IDENTIFIER//\//\\/}/<bundle-id>/g"
}

array_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

warm_device_connection() {
  local target_device="$1"
  local info_json
  local info_log
  info_json="$(mktemp "${TMPDIR:-/tmp}/klms-ios-device-info.XXXXXX")"
  info_log="$(mktemp "${TMPDIR:-/tmp}/klms-ios-device-info-log.XXXXXX")"
  xcrun devicectl device info details \
    --device "$target_device" \
    --timeout "$TUNNEL_WARMUP_SECONDS" \
    --quiet \
    --json-output "$info_json" \
    --log-output "$info_log" >/dev/null 2>&1 || true
  rm -f "$info_json" "$info_log"
}

open_device_settings_for_trust() {
  local target_device="$1"
  local device_label="${2:-device}"
  if [[ "$OPEN_SETTINGS_ON_BLOCKED" != "1" ]]; then
    return 0
  fi
  local settings_output
  settings_output="$(mktemp "${TMPDIR:-/tmp}/klms-ios-settings-open.XXXXXX")"
  if xcrun devicectl device process launch \
    --device "$target_device" \
    --timeout "$OPEN_SETTINGS_TIMEOUT_SECONDS" \
    --quiet \
    com.apple.Preferences >"$settings_output" 2>&1; then
    rm -f "$settings_output"
    print -ru2 -- "${device_label}: opened Settings on the device for developer trust."
    return 0
  fi
  rm -f "$settings_output"
  print -ru2 -- "${device_label}: could not open Settings automatically; open Settings > General > VPN & Device Management manually."
  return 0
}

attempt_launch_once() {
  local target_device="$1"
  local device_label="${2:-device}"
  local emit_blocked_message="${3:-1}"
  local LAUNCH_OUTPUT
  LAUNCH_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/klms-ios-launch-check.XXXXXX")"
  if xcrun devicectl device process launch \
    --device "$target_device" \
    --timeout "$TIMEOUT_SECONDS" \
    --quiet \
    --terminate-existing \
    "$BUNDLE_IDENTIFIER" >"$LAUNCH_OUTPUT" 2>&1; then
    rm -f "$LAUNCH_OUTPUT"
    return 0
  fi

  if /usr/bin/grep -Eiq "invalid code signature|inadequate entitlements|profile has not been explicitly trusted|not trusted|Security" "$LAUNCH_OUTPUT"; then
    rm -f "$LAUNCH_OUTPUT"
    if [[ "$emit_blocked_message" == "1" ]]; then
      print -ru2 -- "${device_label}: launch-check blocked. On this device, open Settings > General > VPN & Device Management, trust the developer app, then rerun this launch check."
    fi
    return "$BLOCKED_LAUNCH_STATUS"
  fi
  if /usr/bin/grep -Eiq "locked|could not be, unlocked|unable to launch|LaunchServicesDataMismatch|LaunchServices GUID|not connected|unavailable|timed out" "$LAUNCH_OUTPUT"; then
    rm -f "$LAUNCH_OUTPUT"
    print -ru2 -- "${device_label}: launch-check pending. Unlock the device, keep USB connected, wait a few seconds if iOS just installed the app, then rerun this launch check."
    return "$MANUAL_LAUNCH_STATUS"
  fi

  redact_bundle_id <"$LAUNCH_OUTPUT" >&2
  rm -f "$LAUNCH_OUTPUT"
  return 1
}

retry_launch_after_trust() {
  local target_device="$1"
  local device_label="${2:-device}"
  if (( TRUST_RETRY_SECONDS <= 0 )); then
    return "$BLOCKED_LAUNCH_STATUS"
  fi
  local deadline=$(( $(current_epoch_seconds) + TRUST_RETRY_SECONDS ))
  print -ru2 -- "${device_label}: waiting up to ${TRUST_RETRY_SECONDS}s for developer trust, then retrying launch..."
  while (( $(current_epoch_seconds) < deadline )); do
    sleep "$TRUST_RETRY_POLL_SECONDS"
    if attempt_launch_once "$target_device" "$device_label" 0; then
      return 0
    fi
    local launch_status=$?
    if (( launch_status != BLOCKED_LAUNCH_STATUS )); then
      return "$launch_status"
    fi
  done
  return "$BLOCKED_LAUNCH_STATUS"
}

launch_one_device() {
  local target_device="$1"
  local device_label="${2:-device}"
  if attempt_launch_once "$target_device" "$device_label" 0; then
    return 0
  fi
  local launch_status=$?
  if (( launch_status == BLOCKED_LAUNCH_STATUS )); then
    open_device_settings_for_trust "$target_device" "$device_label"
    if retry_launch_after_trust "$target_device" "$device_label"; then
      return 0
    fi
    launch_status=$?
    if (( launch_status == BLOCKED_LAUNCH_STATUS )); then
      print -ru2 -- "${device_label}: launch-check blocked. On this device, open Settings > General > VPN & Device Management, trust the developer app, then rerun this launch check."
    fi
  fi
  return "$launch_status"
}

discover_ios_devices() {
  local quiet_unavailable="${1:-0}"
  local devices_json
  devices_json="$(mktemp "${TMPDIR:-/tmp}/klms-ios-devices.XXXXXX")"
  xcrun devicectl list devices --json-output "$devices_json" --quiet >/dev/null
  /usr/bin/python3 - <<'PY' "$devices_json" "$quiet_unavailable"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    devices = json.load(handle).get("result", {}).get("devices", [])

quiet_unavailable = len(sys.argv) > 2 and sys.argv[2] == "1"

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
    tunnel_state = connection.get("tunnelState") or ""
    if tunnel_state == "unavailable":
        if not quiet_unavailable:
            print(
                f"Skipping {hardware.get('deviceType', 'device')}: device is paired but unavailable. "
                "Unlock it, reconnect the cable, and accept the Trust prompt if shown.",
                file=sys.stderr,
            )
        continue
    identifier = device.get("identifier")
    if identifier:
        launch_ready = 1 if tunnel_state == "connected" else 0
        print(f"{identifier}\t{hardware.get('deviceType', 'device')}\t{launch_ready}\t{tunnel_state}")
PY
  rm -f "$devices_json"
}

current_epoch_seconds() {
  /bin/date +%s
}

wait_for_ios_devices() {
  local deadline=$(( $(current_epoch_seconds) + WAIT_FOR_AVAILABLE_SECONDS ))
  local discovered_devices=""
  local announced_wait=0
  while true; do
    discovered_devices="$(discover_ios_devices 1)"
    if [[ -n "$discovered_devices" ]]; then
      print -r -- "$discovered_devices"
      return 0
    fi
    local now_seconds="$(current_epoch_seconds)"
    if (( WAIT_FOR_AVAILABLE_SECONDS <= 0 || now_seconds >= deadline )); then
      discover_ios_devices 0 >/dev/null || true
      return 1
    fi
    if (( announced_wait == 0 )); then
      print -ru2 -- "Waiting up to ${WAIT_FOR_AVAILABLE_SECONDS}s for an unlocked iPhone/iPad to become available..."
      announced_wait=1
    fi
    local remaining=$(( deadline - now_seconds ))
    local nap="$DISCOVERY_POLL_SECONDS"
    if (( remaining < nap )); then
      nap="$remaining"
    fi
    if (( nap <= 0 )); then
      continue
    fi
    sleep "$nap"
  done
}

if [[ "$DEVICE_IDENTIFIER" == "all" ]]; then
  set +e
  discovered_devices="$(wait_for_ios_devices)"
  discovery_status=$?
  set -e
  if (( discovery_status != 0 || ${#discovered_devices} == 0 )); then
    print -ru2 -- "No available iPhone/iPad device with Developer Mode enabled was found."
    print -ru2 -- "Unlock the device, reconnect USB, accept the Trust prompt, then retry."
    exit 2
  fi

  device_entries=("${(@f)discovered_devices}")
  print -r -- "launch-checking-${#device_entries[@]}-ios-devices"
  launched_count=0
  manual_launch_count=0
  pending_launch_count=0
  blocked_launch_count=0
  failed_count=0
  overall_status=0
  seen_device_types=()
  launched_device_types=()
  for device_entry in "${device_entries[@]}"; do
    target_device="${device_entry%%$'\t'*}"
    device_rest="${device_entry#*$'\t'}"
    device_label="${device_rest%%$'\t'*}"
    launch_rest="${device_rest#*$'\t'}"
    launch_ready="${launch_rest%%$'\t'*}"
    tunnel_state="${launch_rest#*$'\t'}"
    if [[ "$device_label" == "$device_entry" || -z "$device_label" ]]; then
      device_label="device"
    fi
    if [[ "$launch_ready" == "$device_rest" || -z "$launch_ready" ]]; then
      launch_ready="1"
    fi
    seen_device_types+=("$device_label")
    if [[ "$launch_ready" != "1" ]]; then
      warm_device_connection "$target_device"
    fi
    set +e
    launch_one_device "$target_device" "$device_label"
    device_status=$?
    set -e
    if (( device_status == 0 )); then
      print -r -- "${device_label}: launch-verified"
      launched_count=$(( launched_count + 1 ))
      launched_device_types+=("$device_label")
      continue
    fi
    if (( device_status == MANUAL_LAUNCH_STATUS )); then
      pending_launch_count=$(( pending_launch_count + 1 ))
      manual_launch_count=$(( manual_launch_count + 1 ))
    elif (( device_status == BLOCKED_LAUNCH_STATUS )); then
      blocked_launch_count=$(( blocked_launch_count + 1 ))
      manual_launch_count=$(( manual_launch_count + 1 ))
    else
      failed_count=$(( failed_count + 1 ))
    fi
    if (( overall_status == 0 )); then
      overall_status="$device_status"
    fi
  done
  if [[ -n "$REQUIRED_DEVICE_TYPES" ]]; then
    required_device_types=("${(@s:,:)REQUIRED_DEVICE_TYPES}")
    for required_device_type in "${required_device_types[@]}"; do
      if [[ -z "$required_device_type" ]]; then
        continue
      fi
      if ! array_contains "$required_device_type" "${seen_device_types[@]}"; then
        print -ru2 -- "${required_device_type}: launch-check missing. Connect and unlock this device, confirm Developer Mode is enabled, then rerun this launch check."
        failed_count=$(( failed_count + 1 ))
        if (( overall_status == 0 )); then
          overall_status=3
        fi
        continue
      fi
      if ! array_contains "$required_device_type" "${launched_device_types[@]}" && (( overall_status == 0 )); then
        overall_status="$MANUAL_LAUNCH_STATUS"
      fi
    done
  fi
  print -r -- "launch-check-summary launched=${launched_count} launched_types=${(j:,:)launched_device_types} pending=${pending_launch_count} blocked=${blocked_launch_count} manual_launch_needed=${manual_launch_count} failed=${failed_count}"
  exit "$overall_status"
fi

set +e
launch_one_device "$DEVICE_IDENTIFIER" "device"
device_status=$?
set -e
if (( device_status == 0 )); then
  print -r -- "device: launch-verified"
fi
exit "$device_status"
