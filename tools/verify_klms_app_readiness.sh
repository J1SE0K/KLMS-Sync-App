#!/bin/zsh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_SWIFT_TESTS="${KLMS_READINESS_SWIFT_TESTS:-1}"
RUN_MAC_CHECKS="${KLMS_READINESS_MAC:-1}"
RUN_IOS_BUILD="${KLMS_READINESS_IOS_BUILD:-1}"
RUN_IOS_LAUNCH="${KLMS_READINESS_IOS_LAUNCH:-1}"
MAC_APP_PATH="${KLMS_MAC_APP_PATH:-$HOME/Applications/KLMS Sync.app}"
MAC_RELAUNCH_DELAY_SECONDS="${KLMS_READINESS_MAC_RELAUNCH_DELAY_SECONDS:-2}"

sanitize_output() {
  KLMS_REPO_ROOT="$ROOT_DIR" /usr/bin/perl -pe '
    BEGIN {
      $repo_root = $ENV{"KLMS_REPO_ROOT"} // "";
      $home_dir = $ENV{"HOME"} // "";
    }
    if ($repo_root ne "") {
      s/\Q$repo_root\E/<repo-root>/g;
    }
    if ($home_dir ne "") {
      s/\Q$home_dir\E/<home>/g;
    }
    s#/Users/[^/\s"'\''"]+#<home>#g;
    s/[A-Z0-9]{10}\.com\.[A-Za-z0-9._-]+/<app-identifier>/g;
    s/\bcom\.[A-Za-z0-9._-]*KLMSync\.iOS\b/<bundle-id>/g;
    s/[A-Fa-f0-9]{40}/<signing-identity-hash>/g;
    s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g;
  '
}

run_step() {
  local name="$1"
  shift
  print -r -- "== ${name} =="
  "$@" 2>&1 | sanitize_output
  local exit_status=${pipestatus[1]}
  if (( exit_status == 0 )); then
    print -r -- "ok: ${name}"
  else
    print -ru2 -- "fail: ${name} status=${exit_status}"
  fi
  return "$exit_status"
}

failed_steps=()

record_step() {
  local name="$1"
  shift
  run_step "$name" "$@"
  local exit_status=$?
  if (( exit_status != 0 )); then
    failed_steps+=("${name}:${exit_status}")
  fi
  return 0
}

print_failure_hint() {
  local failed_step="$1"
  case "$failed_step" in
    ios-device-launch:4)
      print -ru2 -- "hint: iOS launch is pending. Unlock every connected iPhone/iPad, keep USB connected, wait a few seconds if the app was just installed, then rerun the readiness check."
      ;;
    ios-device-launch:5)
      print -ru2 -- "hint: iOS build and signing are ready, but device trust is blocked. On each iPhone/iPad, open Settings > General > VPN & Device Management, trust the developer app, then open KLMS Sync or rerun the readiness check."
      ;;
  esac
}

relaunch_mac_app() {
  /usr/bin/osascript -e 'tell application "KLMS Sync" to quit' >/dev/null 2>&1 || true
  /bin/sleep 1
  /usr/bin/open -a "$MAC_APP_PATH"
  /bin/sleep "$MAC_RELAUNCH_DELAY_SECONDS"
  print -r -- "$MAC_APP_PATH"
}

print -r -- "KLMS Sync readiness check"

if [[ "$RUN_SWIFT_TESTS" == "1" ]]; then
  record_step "swift-tests" swift test --package-path "$ROOT_DIR/apps/KLMSync" --scratch-path /private/tmp/klmsync-swiftpm-scratch
fi

if [[ "$RUN_MAC_CHECKS" == "1" ]]; then
  record_step "mac-build" "$ROOT_DIR/tools/build_klms_mac_app.sh"
  record_step "mac-relaunch" relaunch_mac_app
  record_step "mac-accessibility-smoke" swift "$ROOT_DIR/tools/smoke_klms_mac_accessibility.swift"
  record_step "mac-tab-response" /usr/bin/env \
    KLMS_MAC_TAB_PROBE_RUNS=3 \
    KLMS_MAC_TAB_AVERAGE_LIMIT_MS=100 \
    KLMS_MAC_TAB_SLOWEST_LIMIT_MS=250 \
    swift "$ROOT_DIR/tools/probe_klms_mac_tab_response.swift"
fi

if [[ "$RUN_IOS_BUILD" == "1" ]]; then
  record_step "ios-signed-build" "$ROOT_DIR/tools/build_klms_ios_device.sh"
fi

if [[ "$RUN_IOS_LAUNCH" == "1" ]]; then
  record_step "ios-device-launch" /usr/bin/env \
    IOS_DEVICE_REQUIRE_TYPES=iPhone,iPad \
    "$ROOT_DIR/tools/verify_klms_ios_device_launch.sh"
fi

swift_state="skipped"
mac_state="skipped"
ios_build_state="skipped"
ios_launch_state="skipped"

if [[ "$RUN_SWIFT_TESTS" == "1" ]]; then
  swift_state="ready"
fi
if [[ "$RUN_MAC_CHECKS" == "1" ]]; then
  mac_state="ready"
fi
if [[ "$RUN_IOS_BUILD" == "1" ]]; then
  ios_build_state="ready"
fi
if [[ "$RUN_IOS_LAUNCH" == "1" ]]; then
  ios_launch_state="ready"
fi

for failed_step in "${failed_steps[@]}"; do
  case "${failed_step%%:*}" in
    swift-tests)
      swift_state="failed"
      ;;
    mac-build|mac-relaunch|mac-accessibility-smoke|mac-tab-response)
      mac_state="failed"
      ;;
    ios-signed-build)
      ios_build_state="failed"
      ;;
    ios-device-launch)
      ios_launch_state="failed"
      ;;
  esac
done

if (( ${#failed_steps[@]} == 0 )); then
  print -r -- "readiness-summary status=ok swift_tests=${swift_state} mac=${mac_state} ios_build=${ios_build_state} ios_launch=${ios_launch_state}"
  exit 0
fi

for failed_step in "${failed_steps[@]}"; do
  print_failure_hint "$failed_step"
done

print -ru2 -- "readiness-summary status=fail swift_tests=${swift_state} mac=${mac_state} ios_build=${ios_build_state} ios_launch=${ios_launch_state} failed=${(j:,:)failed_steps}"
exit 1
