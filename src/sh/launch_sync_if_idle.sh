#!/bin/zsh

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KLMS_SH_DIR="$SCRIPT_DIR/src/sh"
KLMS_JS_DIR="$SCRIPT_DIR/src/js"
CONFIG_PATH="$SCRIPT_DIR/config.env"
RUNTIME_DIR="$SCRIPT_DIR/runtime"
AUTOMATION_DIR="$RUNTIME_DIR/automation"
LOG_DIR="$RUNTIME_DIR/logs"
LOCK_DIR="$AUTOMATION_DIR/launch.lock"
LAST_ATTEMPT_FILE="$AUTOMATION_DIR/last_attempt_epoch"
ALERT_STATE_FILE="$AUTOMATION_DIR/reminder_alert_state.json"
LOGIN_PROMPT_EPOCH_FILE="$AUTOMATION_DIR/login_prompt_epoch"
LOGIN_WATCH_LOCK_DIR="$AUTOMATION_DIR/login-watch.lock"
LAUNCH_LOG="$LOG_DIR/launch-agent.log"
NEXT_STATE_FILE="$RUNTIME_DIR/state/next_state.json"
STATE_FILE="$RUNTIME_DIR/state/state.json"
SYNC_OUTPUT_FILE=""
SYNC_STATUS_FILE=""

mkdir -p "$AUTOMATION_DIR" "$LOG_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi

cleanup() {
  if [[ -n "$SYNC_OUTPUT_FILE" ]]; then
    rm -f "$SYNC_OUTPUT_FILE" 2>/dev/null || true
  fi
  if [[ -n "$SYNC_STATUS_FILE" ]]; then
    rm -f "$SYNC_STATUS_FILE" 2>/dev/null || true
  fi
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

source "$CONFIG_PATH"

KLMS_AUTO_SYNC_ENABLED="${KLMS_AUTO_SYNC_ENABLED:-1}"
KLMS_LOGIN_URL="${KLMS_LOGIN_URL:-${KLMS_DASHBOARD_URL:-https://klms.kaist.ac.kr/my/}}"
LOGIN_PROMPT_COOLDOWN_SECONDS="${LOGIN_PROMPT_COOLDOWN_SECONDS:-3600}"
LOGIN_PROMPT_OPEN_SAFARI="${LOGIN_PROMPT_OPEN_SAFARI:-0}"
MACOS_REMINDER_NOTIFICATIONS_ENABLED="${MACOS_REMINDER_NOTIFICATIONS_ENABLED:-0}"
SYNC_ABORT_ON_USER_ACTIVITY="${SYNC_ABORT_ON_USER_ACTIVITY:-1}"
SYNC_ACTIVE_ABORT_IDLE_SECONDS="${SYNC_ACTIVE_ABORT_IDLE_SECONDS:-30}"
SYNC_ACTIVE_POLL_SECONDS="${SYNC_ACTIVE_POLL_SECONDS:-5}"

case "${KLMS_AUTO_SYNC_ENABLED:l}" in
  0|false|no|off)
    timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '[%s] auto-sync disabled\n' "$timestamp" >> "$LAUNCH_LOG"
    exit 0
    ;;
esac

current_idle_seconds() {
  local idle_seconds
  idle_seconds="$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {idle=int($NF/1000000000); found=1} END {if (found) print idle}')"
  if [[ -z "$idle_seconds" || "$idle_seconds" != <-> ]]; then
    idle_seconds=0
  fi
  print -r -- "$idle_seconds"
}

child_pids_for() {
  local parent_pid="$1"
  /bin/ps -axo pid=,ppid= | awk -v parent="$parent_pid" '$2 == parent {print $1}'
}

terminate_process_tree() {
  local target_pid="$1"
  local child_pid

  for child_pid in $(child_pids_for "$target_pid"); do
    terminate_process_tree "$child_pid"
  done
  kill -TERM "$target_pid" >/dev/null 2>&1 || true
}

reset_login_prompt_state() {
  rm -f "$LOGIN_PROMPT_EPOCH_FILE"
}

has_login_error() {
  local sync_output="$1"
  local candidate=""

  if [[ "$sync_output" == *"로그인"* ]]; then
    return 0
  fi

  if [[ -f "$NEXT_STATE_FILE" ]]; then
    candidate="$NEXT_STATE_FILE"
  elif [[ -f "$STATE_FILE" ]]; then
    candidate="$STATE_FILE"
  else
    return 1
  fi

  grep -q '로그인' "$candidate"
}

prompt_login_if_needed() {
  local sync_output="${1:-}"
  local prompt_now_epoch
  local last_prompt=0
  local timestamp
  local auth_digits=""

  prompt_now_epoch="$(date +%s)"
  if [[ -f "$LOGIN_PROMPT_EPOCH_FILE" ]]; then
    last_prompt="$(<"$LOGIN_PROMPT_EPOCH_FILE")"
  fi

  if [[ "$last_prompt" == <-> ]] && (( prompt_now_epoch - last_prompt < LOGIN_PROMPT_COOLDOWN_SECONDS )); then
    timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '[%s] login-prompt suppressed cooldown=%ss\n' "$timestamp" "$LOGIN_PROMPT_COOLDOWN_SECONDS" >> "$LAUNCH_LOG"
    return 0
  fi

  if [[ "$sync_output" =~ 'KAIST 인증 번호: ([0-9][0-9])' ]]; then
    auth_digits="${match[1]}"
  elif [[ "$sync_output" =~ 'digits=([0-9][0-9])' ]]; then
    auth_digits="${match[1]}"
  fi

  if [[ -n "$auth_digits" ]]; then
    /usr/bin/osascript \
      -e 'on run argv' \
      -e 'set authNumber to item 1 of argv' \
      -e 'display notification "휴대폰 KAIST 인증 화면에서 " & authNumber & " 를 선택해 주세요." with title "KLMS 인증 번호"' \
      -e 'end run' \
      "$auth_digits" >/dev/null 2>&1 || true
  else
    /usr/bin/osascript -e 'display notification "KLMS 로그인 보조를 시작하지 못했어요. Safari의 KLMS 로그인 화면을 확인해 주세요." with title "KLMS 동기화"' >/dev/null 2>&1 || true
  fi
  if [[ "$LOGIN_PROMPT_OPEN_SAFARI" == "1" ]]; then
    /usr/bin/osascript \
      -e 'on run argv' \
      -e 'set targetUrl to item 1 of argv' \
      -e 'tell application "Safari" to make new document with properties {URL:targetUrl}' \
      -e 'end run' \
      "$KLMS_LOGIN_URL" >/dev/null 2>&1 || true
  fi
  print -r -- "$prompt_now_epoch" > "$LOGIN_PROMPT_EPOCH_FILE"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf '[%s] login-prompt notified backend=%s open_safari=%s url=%s digits=%s\n' \
    "$timestamp" "safari" "$LOGIN_PROMPT_OPEN_SAFARI" "$KLMS_LOGIN_URL" "${auth_digits:-none}" >> "$LAUNCH_LOG"
}

start_login_watch_if_needed() {
  local timestamp

  if [[ -d "$LOGIN_WATCH_LOCK_DIR" ]]; then
    return 0
  fi

  nohup /bin/zsh "$KLMS_SH_DIR/watch_klms_login_recovery.sh" >/dev/null 2>&1 &
  timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf '[%s] login-watch spawn pid=%s\n' "$timestamp" "$!" >> "$LAUNCH_LOG"
}

timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
if [[ "$MACOS_REMINDER_NOTIFICATIONS_ENABLED" == "1" ]]; then
  alert_output="$(cd "$SCRIPT_DIR" && osascript -l JavaScript "$KLMS_JS_DIR/notify_klms_reminders.js" ./config.env "$ALERT_STATE_FILE" 2>&1)" || true
  printf '[%s] alerts %s\n' "$timestamp" "$alert_output" >> "$LAUNCH_LOG"
else
  printf '[%s] alerts status=skipped macos-reminder-notifications-disabled\n' "$timestamp" >> "$LAUNCH_LOG"
fi

SYNC_INTERVAL_SECONDS="${SYNC_INTERVAL_SECONDS:-21600}"
MIN_IDLE_SECONDS="${MIN_IDLE_SECONDS:-600}"

if [[ "$SYNC_INTERVAL_SECONDS" == <-> ]] && (( SYNC_INTERVAL_SECONDS <= 0 )); then
  timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf '[%s] auto-sync disabled interval=%ss\n' "$timestamp" "$SYNC_INTERVAL_SECONDS" >> "$LAUNCH_LOG"
  exit 0
fi

now_epoch="$(date +%s)"
last_attempt=0
if [[ -f "$LAST_ATTEMPT_FILE" ]]; then
  last_attempt="$(<"$LAST_ATTEMPT_FILE")"
fi

if [[ "$last_attempt" == <-> ]] && (( now_epoch - last_attempt < SYNC_INTERVAL_SECONDS )); then
  exit 0
fi

idle_seconds="$(current_idle_seconds)"

if (( idle_seconds < MIN_IDLE_SECONDS )); then
  exit 0
fi

print -r -- "$now_epoch" > "$LAST_ATTEMPT_FILE"

timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
SYNC_OUTPUT_FILE="$AUTOMATION_DIR/launch-sync-output.$$"
SYNC_STATUS_FILE="$AUTOMATION_DIR/launch-sync-status.$$"
rm -f "$SYNC_OUTPUT_FILE" "$SYNC_STATUS_FILE"

(
  cd "$SCRIPT_DIR"
  set +e
  /bin/zsh ./run_all.sh ./config.env > "$SYNC_OUTPUT_FILE" 2>&1
  print -r -- "$?" > "$SYNC_STATUS_FILE"
) &
sync_pid="$!"
aborted_for_activity=0
abort_idle_seconds=0

while kill -0 "$sync_pid" >/dev/null 2>&1; do
  sleep "$SYNC_ACTIVE_POLL_SECONDS"
  if [[ "$SYNC_ABORT_ON_USER_ACTIVITY" == "1" ]]; then
    abort_idle_seconds="$(current_idle_seconds)"
    if (( abort_idle_seconds < SYNC_ACTIVE_ABORT_IDLE_SECONDS )); then
      aborted_for_activity=1
      terminate_process_tree "$sync_pid"
      wait "$sync_pid" >/dev/null 2>&1 || true
      break
    fi
  fi
done

if (( aborted_for_activity == 0 )); then
  wait "$sync_pid" >/dev/null 2>&1 || true
fi

sync_output="$(cat "$SYNC_OUTPUT_FILE" 2>/dev/null || true)"
if [[ -f "$SYNC_STATUS_FILE" ]]; then
  sync_exit="$(<"$SYNC_STATUS_FILE")"
else
  sync_exit=130
fi
printf '[%s] idle=%ss exit=%s %s\n' "$timestamp" "$idle_seconds" "$sync_exit" "$sync_output" >> "$LAUNCH_LOG"

if (( aborted_for_activity == 1 )); then
  printf '[%s] aborted=user-activity idle=%ss threshold=%ss\n' \
    "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
    "$abort_idle_seconds" \
    "$SYNC_ACTIVE_ABORT_IDLE_SECONDS" >> "$LAUNCH_LOG"
  exit 0
fi

if (( sync_exit == 0 )); then
  reset_login_prompt_state
  exit 0
fi

if has_login_error "$sync_output"; then
  # Login expiry should retry again on the next 15-minute wake so the sync
  # can recover shortly after the user finishes Safari OTP approval.
  print -r -- "0" > "$LAST_ATTEMPT_FILE"
  start_login_watch_if_needed
  prompt_login_if_needed "$sync_output"
else
  /usr/bin/osascript -e 'display notification "KLMS 동기화가 실패했어요. 로그를 확인해 주세요." with title "KLMS 동기화"' >/dev/null 2>&1 || true
fi
