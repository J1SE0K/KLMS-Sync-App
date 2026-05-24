#!/bin/zsh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KLMS_SWIFT_DIR="$SCRIPT_DIR/src/swift"
MODULE_CACHE_DIR="${NOTICE_NATIVE_NOTE_MODULE_CACHE_DIR:-$SCRIPT_DIR/runtime/tmp/swift-module-cache}"
BUILD_DIR="${NOTICE_NATIVE_NOTE_BUILD_DIR:-$SCRIPT_DIR/runtime/bin}"
BIN_PATH="$BUILD_DIR/update_notice_native_note"
APP_HELPER_BIN="${NOTICE_NATIVE_NOTE_BIN_PATH:-}"
MAX_ATTEMPTS="${NOTICE_NATIVE_NOTE_MAX_ATTEMPTS:-3}"
RETRY_DELAY_SECONDS="${NOTICE_NATIVE_NOTE_RETRY_DELAY_SECONDS:-1}"
TIMEOUT_SECONDS="${NOTICE_NATIVE_NOTE_TIMEOUT_SECONDS:-420}"
TIMEOUT_GRACE_SECONDS="${NOTICE_NATIVE_NOTE_TIMEOUT_GRACE_SECONDS:-3}"
TIMING_LOG="${NOTICE_NATIVE_NOTE_TIMING_LOG:-$SCRIPT_DIR/runtime/cache/notice_native_note_timing.log}"
DEFAULT_XCODE_SWIFTC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
DEFAULT_XCODE_SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
SWIFT_SOURCES=(
  "$KLMS_SWIFT_DIR/notice_native_note_support.swift"
  "$KLMS_SWIFT_DIR/update_notice_native_note.swift"
)

if [[ -n "$APP_HELPER_BIN" && -x "$APP_HELPER_BIN" ]]; then
  BIN_PATH="$APP_HELPER_BIN"
fi

mkdir -p "$MODULE_CACHE_DIR"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
mkdir -p "$BUILD_DIR"

timestamp_now() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

nonnegative_int_or_default() {
  local raw="${1:-}"
  local fallback="${2:-0}"
  if [[ "$raw" == <-> ]]; then
    print -r -- "$raw"
  else
    print -r -- "$fallback"
  fi
}

positive_int_or_default() {
  local raw="${1:-}"
  local fallback="${2:-1}"
  if [[ "$raw" == <-> && "$raw" -gt 0 ]]; then
    print -r -- "$raw"
  else
    print -r -- "$fallback"
  fi
}

log_timing() {
  mkdir -p "$(dirname "$TIMING_LOG")"
  printf '%s\t%s\n' "$(timestamp_now)" "$*" >> "$TIMING_LOG"
}

MAX_ATTEMPTS="$(positive_int_or_default "$MAX_ATTEMPTS" 3)"
RETRY_DELAY_SECONDS="$(nonnegative_int_or_default "$RETRY_DELAY_SECONDS" 1)"
TIMEOUT_SECONDS="$(nonnegative_int_or_default "$TIMEOUT_SECONDS" 420)"
TIMEOUT_GRACE_SECONDS="$(nonnegative_int_or_default "$TIMEOUT_GRACE_SECONDS" 3)"

if [[ -x "$DEFAULT_XCODE_SWIFTC" ]]; then
  SWIFTC_BIN="$DEFAULT_XCODE_SWIFTC"
  if [[ -d "$DEFAULT_XCODE_SDK" ]]; then
    SWIFTC_ARGS=(-sdk "$DEFAULT_XCODE_SDK")
  else
    SWIFTC_ARGS=()
  fi
else
  SWIFTC_BIN="$(command -v swiftc)"
  SWIFTC_ARGS=()
fi

NOTE_TITLE="KLMS 공지"
PASS_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --note-title)
      NOTE_TITLE="${2:-$NOTE_TITLE}"
      PASS_ARGS+=("$1" "$NOTE_TITLE")
      shift 2
      ;;
    *)
      PASS_ARGS+=("$1")
      shift
      ;;
  esac
done

needs_build=0
if [[ -n "$APP_HELPER_BIN" && -x "$APP_HELPER_BIN" ]]; then
  needs_build=0
elif [[ ! -x "$BIN_PATH" ]]; then
  needs_build=1
else
  for source_path in "${SWIFT_SOURCES[@]}"; do
    if [[ "$source_path" -nt "$BIN_PATH" ]]; then
      needs_build=1
      break
    fi
  done
fi

if (( needs_build )); then
  tmp_bin="$BIN_PATH.tmp.$$"
  "$SWIFTC_BIN" "${SWIFTC_ARGS[@]}" "${SWIFT_SOURCES[@]}" -o "$tmp_bin"
  mv "$tmp_bin" "$BIN_PATH"
fi

run_native_note_once() {
  local timeout_flag="$BUILD_DIR/update_notice_native_note.timeout.$$.$RANDOM"
  local watchdog_pid=""
  local timeout_seconds="${TIMEOUT_SECONDS:-420}"
  local timeout_grace_seconds="${TIMEOUT_GRACE_SECONDS:-3}"
  local started_epoch
  local finished_epoch
  local duration_s
  local args_text="${(j: :)PASS_ARGS}"
  rm -f "$timeout_flag"

  "$BIN_PATH" "${PASS_ARGS[@]}" &
  local target_pid="${!:-}"
  if [[ -z "$target_pid" ]]; then
    log_timing "attempt_finish pid=missing result=launch-failed exit_status=127 duration_s=0"
    return 127
  fi
  started_epoch="$(date +%s)"
  log_timing "attempt_start pid=$target_pid timeout_s=$timeout_seconds args=$args_text"

  if [[ "$timeout_seconds" -gt 0 ]]; then
    (
      sleep "$timeout_seconds"
      if [[ -n "${target_pid:-}" ]] && kill -0 "$target_pid" >/dev/null 2>&1; then
        : > "$timeout_flag"
        kill -TERM "$target_pid" >/dev/null 2>&1 || true
        sleep "$timeout_grace_seconds"
        kill -KILL "$target_pid" >/dev/null 2>&1 || true
      fi
    ) >/dev/null 2>&1 &
    watchdog_pid=$!
  fi

  local exit_status=0
  set +e
  wait "$target_pid"
  exit_status=$?
  set -e

  if [[ -n "${watchdog_pid:-}" ]]; then
    kill "$watchdog_pid" >/dev/null 2>&1 || true
    wait "$watchdog_pid" >/dev/null 2>&1 || true
  fi

  finished_epoch="$(date +%s)"
  duration_s=$((finished_epoch - started_epoch))

  if [[ -f "$timeout_flag" ]]; then
    rm -f "$timeout_flag"
    log_timing "attempt_finish pid=$target_pid result=timeout exit_status=$exit_status duration_s=$duration_s"
    return 124
  fi

  log_timing "attempt_finish pid=$target_pid result=exit exit_status=$exit_status duration_s=$duration_s"
  return "$exit_status"
}

attempt=1
while true; do
  set +e
  run_native_note_once
  attempt_status=$?
  set -e
  if [[ "$attempt_status" -eq 0 ]]; then
    exit 0
  fi

  if (( attempt >= MAX_ATTEMPTS )); then
    if [[ "$attempt_status" -eq 124 ]]; then
      printf 'update_notice_native_note failed: attempt %d/%d timed out after %ss\n' \
        "$attempt" \
        "$MAX_ATTEMPTS" \
        "$TIMEOUT_SECONDS" \
        >&2
    else
      printf 'update_notice_native_note failed: attempt %d/%d exited with %d\n' \
        "$attempt" \
        "$MAX_ATTEMPTS" \
        "$attempt_status" \
        >&2
    fi
    exit "$attempt_status"
  fi

  if [[ "$attempt_status" -eq 124 ]]; then
    printf 'update_notice_native_note attempt %d/%d timed out after %ss; retrying in %ss\n' \
      "$attempt" \
      "$MAX_ATTEMPTS" \
      "$TIMEOUT_SECONDS" \
      "$RETRY_DELAY_SECONDS" \
      >&2
  else
    printf 'update_notice_native_note attempt %d/%d failed with exit %d; retrying in %ss\n' \
      "$attempt" \
      "$MAX_ATTEMPTS" \
      "$attempt_status" \
      "$RETRY_DELAY_SECONDS" \
      >&2
  fi
  sleep "$RETRY_DELAY_SECONDS"
  attempt=$((attempt + 1))
done
