#!/bin/zsh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_SWIFT_TESTS="${KLMS_READINESS_SWIFT_TESTS:-1}"
RUN_MAC_CHECKS="${KLMS_READINESS_MAC:-1}"
RUN_IOS_BUILD="${KLMS_READINESS_IOS_BUILD:-1}"
RUN_IOS_LAUNCH="${KLMS_READINESS_IOS_LAUNCH:-1}"
READINESS_TEMP_DIR=""
CANONICAL_MAC_APP_PATH="$HOME/Applications/KLMS Sync.app"
CANONICAL_APP_WAS_RUNNING=0
if [[ -n "${KLMS_MAC_APP_PATH:-}" ]]; then
  MAC_APP_PATH="$KLMS_MAC_APP_PATH"
else
  READINESS_TEMP_DIR="$(mktemp -d "${TMPDIR:-/private/tmp}/klms-sync-readiness.XXXXXX")"
  READINESS_TEMP_DIR="$(cd "$READINESS_TEMP_DIR" && pwd -P)"
  MAC_APP_PATH="$READINESS_TEMP_DIR/KLMS Sync.app"
fi
MAC_RELAUNCH_DELAY_SECONDS="${KLMS_READINESS_MAC_RELAUNCH_DELAY_SECONDS:-5}"
MAC_SAFE_CAPTURE_FIXTURE="${KLMS_MAC_AX_SAFE_FIXTURE:-0}"
ALLOW_DESTRUCTIVE_ACTIONS="${KLMS_READINESS_ALLOW_DESTRUCTIVE_ACTIONS:-0}"
REQUIRE_CLEAN_WORKTREE="${KLMS_READINESS_REQUIRE_CLEAN:-0}"
CANDIDATE_REVISION="unavailable"
WORKTREE_STATE="unknown"
GIT_METADATA_STATE="invalid"
if candidate_revision="$(git -C "$ROOT_DIR" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
    && git_status="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all 2>/dev/null)" \
    && [[ ${#candidate_revision} -eq 40 ]] \
    && [[ "$candidate_revision" != *[^0-9a-f]* ]]; then
  CANDIDATE_REVISION="$candidate_revision"
  GIT_METADATA_STATE="valid"
  if [[ -n "$git_status" ]]; then
    WORKTREE_STATE="dirty"
  else
    WORKTREE_STATE="clean"
  fi
fi

cleanup_readiness() {
  if [[ -n "$READINESS_TEMP_DIR" ]]; then
    /usr/bin/pkill -f "$MAC_APP_PATH/Contents/MacOS/KLMSMac" >/dev/null 2>&1 || true
    /bin/sleep 1
    rm -rf "$READINESS_TEMP_DIR"
    if (( CANONICAL_APP_WAS_RUNNING == 1 )) && [[ -d "$CANONICAL_MAC_APP_PATH" ]]; then
      /usr/bin/open "$CANONICAL_MAC_APP_PATH" >/dev/null 2>&1 || true
    fi
  fi
}

trap cleanup_readiness EXIT

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

verify_clean_worktree() {
  [[ "$WORKTREE_STATE" == "clean" ]]
}

verify_git_metadata() {
  [[ "$GIT_METADATA_STATE" == "valid" ]]
}

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
  if /usr/bin/pgrep -x KLMSMac >/dev/null 2>&1; then
    CANONICAL_APP_WAS_RUNNING=1
  fi
  /usr/bin/pkill -x KLMSMac >/dev/null 2>&1 || true
  for _ in {1..100}; do
    if ! /usr/bin/pgrep -x KLMSMac >/dev/null 2>&1; then
      break
    fi
    /bin/sleep 0.1
  done
  if /usr/bin/pgrep -x KLMSMac >/dev/null 2>&1; then
    print -ru2 -- "Timed out waiting for previous KLMS Sync processes to terminate."
    return 1
  fi
  if [[ "$MAC_SAFE_CAPTURE_FIXTURE" == "1" ]]; then
    KLMS_MAC_SAFE_CAPTURE_FIXTURE=1 \
      "$MAC_APP_PATH/Contents/MacOS/KLMSMac" >/dev/null 2>&1 &!
  else
    /usr/bin/open -n "$MAC_APP_PATH"
  fi
  for _ in {1..100}; do
    if /usr/bin/pgrep -x KLMSMac >/dev/null 2>&1; then
      /bin/sleep "$MAC_RELAUNCH_DELAY_SECONDS"
      print -r -- "$MAC_APP_PATH"
      return 0
    fi
    /bin/sleep 0.1
  done
  print -ru2 -- "Timed out waiting for the candidate KLMS Sync process to launch."
  return 1
}

print -r -- "KLMS Sync readiness check"

record_step "git-metadata" verify_git_metadata
if [[ "$REQUIRE_CLEAN_WORKTREE" == "1" ]]; then
  record_step "clean-worktree" verify_clean_worktree
fi

if [[ "$RUN_SWIFT_TESTS" == "1" ]]; then
  record_step "swift-tests" swift test \
    --enable-xctest \
    --disable-swift-testing \
    --package-path "$ROOT_DIR/apps/KLMSync" \
    --scratch-path /private/tmp/klmsync-swiftpm-scratch \
    --jobs 1
fi

if [[ "$RUN_MAC_CHECKS" == "1" ]]; then
  record_step "mac-build" /usr/bin/env \
    OUTPUT_APP="$MAC_APP_PATH" \
    KLMS_PAYLOAD_REQUIRE_CLEAN="$REQUIRE_CLEAN_WORKTREE" \
    "$ROOT_DIR/tools/build_klms_mac_app.sh"
  record_step "mac-relaunch" relaunch_mac_app
  record_step "mac-accessibility-smoke" /usr/bin/env \
    KLMS_MAC_APP_PATH="$MAC_APP_PATH" \
    KLMS_MAC_AX_VERIFY_ADAPTIVE_RESIZE=1 \
    swift "$ROOT_DIR/tools/smoke_klms_mac_accessibility.swift"
  record_step "mac-resize-hit-area" /usr/bin/env \
    KLMS_MAC_APP_PATH="$MAC_APP_PATH" \
    swift "$ROOT_DIR/tools/smoke_klms_mac_resize_hit_area.swift"
  record_step "mac-basic-actions" /usr/bin/env \
    KLMS_MAC_APP_PATH="$MAC_APP_PATH" \
    KLMS_MAC_SMOKE_ALLOW_DESTRUCTIVE_ACTIONS="$ALLOW_DESTRUCTIVE_ACTIONS" \
    swift "$ROOT_DIR/tools/smoke_klms_mac_basic_actions.swift"
  record_step "mac-tab-response" /usr/bin/env \
    KLMS_MAC_APP_PATH="$MAC_APP_PATH" \
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
    mac-build|mac-relaunch|mac-accessibility-smoke|mac-resize-hit-area|mac-basic-actions|mac-tab-response)
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
  print -r -- "readiness-summary status=ok candidate=${CANDIDATE_REVISION} worktree=${WORKTREE_STATE} swift_tests=${swift_state} mac=${mac_state} ios_build=${ios_build_state} ios_launch=${ios_launch_state} git_metadata=${GIT_METADATA_STATE}"
  exit 0
fi

for failed_step in "${failed_steps[@]}"; do
  print_failure_hint "$failed_step"
done

print -ru2 -- "readiness-summary status=fail candidate=${CANDIDATE_REVISION} worktree=${WORKTREE_STATE} swift_tests=${swift_state} mac=${mac_state} ios_build=${ios_build_state} ios_launch=${ios_launch_state} git_metadata=${GIT_METADATA_STATE} failed=${(j:,:)failed_steps}"
exit 1
