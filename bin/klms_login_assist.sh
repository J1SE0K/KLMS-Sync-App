#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KLMS_JS_DIR="$SCRIPT_DIR/src/js"
CONFIG_PATH="${1:-$SCRIPT_DIR/config.env}"
KLMS_APP_RUN_ENV="${KLMS_APP_RUN:-0}"
KLMS_SCRIPT_NOTIFICATIONS_ENABLED_ENV="${KLMS_SCRIPT_NOTIFICATIONS_ENABLED:-}"
KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS_ENV="${KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS:-}"
KLMS_LOGIN_ASSIST_REFRESH_PREEXISTING_TWOFACTOR_ENABLED_ENV="${KLMS_LOGIN_ASSIST_REFRESH_PREEXISTING_TWOFACTOR_ENABLED:-}"
KLMS_LOGIN_ASSIST_AUTHENTICATED_RECHECK_SECONDS_ENV="${KLMS_LOGIN_ASSIST_AUTHENTICATED_RECHECK_SECONDS:-}"
KLMS_LOGIN_ASSIST_APPROVAL_TIMEOUT_SECONDS_ENV="${KLMS_LOGIN_ASSIST_APPROVAL_TIMEOUT_SECONDS:-}"

if [[ -f "$CONFIG_PATH" ]]; then
  source "$CONFIG_PATH"
fi
if [[ "$KLMS_APP_RUN_ENV" == "1" ]]; then
  KLMS_APP_RUN="1"
  KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS="${KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS_ENV:-0}"
  KLMS_LOGIN_ASSIST_REFRESH_PREEXISTING_TWOFACTOR_ENABLED="${KLMS_LOGIN_ASSIST_REFRESH_PREEXISTING_TWOFACTOR_ENABLED_ENV:-0}"
  KLMS_LOGIN_ASSIST_AUTHENTICATED_RECHECK_SECONDS="${KLMS_LOGIN_ASSIST_AUTHENTICATED_RECHECK_SECONDS_ENV:-0}"
  KLMS_LOGIN_ASSIST_APPROVAL_TIMEOUT_SECONDS="${KLMS_LOGIN_ASSIST_APPROVAL_TIMEOUT_SECONDS_ENV:-60}"
fi
if [[ "$KLMS_SCRIPT_NOTIFICATIONS_ENABLED_ENV" == "0" ]]; then
  KLMS_SCRIPT_NOTIFICATIONS_ENABLED="0"
fi

KLMS_LOGIN_URL="${KLMS_LOGIN_URL:-${KLMS_DASHBOARD_URL:-https://klms.kaist.ac.kr/my/}}"
KLMS_LOGIN_ASSIST_APPROVAL_TIMEOUT_SECONDS="${KLMS_LOGIN_ASSIST_APPROVAL_TIMEOUT_SECONDS:-300}"
KLMS_LOGIN_ASSIST_POLL_SECONDS="${KLMS_LOGIN_ASSIST_POLL_SECONDS:-0.2}"
KLMS_LOGIN_ASSIST_STEP_TIMEOUT_SECONDS="${KLMS_LOGIN_ASSIST_STEP_TIMEOUT_SECONDS:-12}"
KLMS_LOGIN_ASSIST_STEP_POLL_MS="${KLMS_LOGIN_ASSIST_STEP_POLL_MS:-75}"
KLMS_LOGIN_ASSIST_AUTH_CHECK_SECONDS="${KLMS_LOGIN_ASSIST_AUTH_CHECK_SECONDS:-1.2}"
KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS="${KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS:-0}"
KLMS_LOGIN_ASSIST_REFRESH_PREEXISTING_TWOFACTOR_ENABLED="${KLMS_LOGIN_ASSIST_REFRESH_PREEXISTING_TWOFACTOR_ENABLED:-0}"
KLMS_LOGIN_ASSIST_AUTHENTICATED_RECHECK_SECONDS="${KLMS_LOGIN_ASSIST_AUTHENTICATED_RECHECK_SECONDS:-6}"
KLMS_LOGIN_ASSIST_NOTIFY_DIGITS_ENABLED="${KLMS_LOGIN_ASSIST_NOTIFY_DIGITS_ENABLED:-1}"
KLMS_SCRIPT_NOTIFICATIONS_ENABLED="${KLMS_SCRIPT_NOTIFICATIONS_ENABLED:-1}"
if [[ "${KLMS_APP_RUN:-0}" == "1" || "$KLMS_SCRIPT_NOTIFICATIONS_ENABLED" == "0" ]]; then
  KLMS_LOGIN_ASSIST_NOTIFY_DIGITS_ENABLED="0"
fi
KLMS_LOGIN_ASSIST_OSASCRIPT_BIN="${KLMS_LOGIN_ASSIST_OSASCRIPT_BIN:-/usr/bin/osascript}"

json_get() {
  local json="$1"
  local key="$2"
  local python_bin="${KLMS_PYTHON_BIN:-python3}"
  printf '%s' "$json" | "$python_bin" -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$key"
}

load_display_name() {
  if [[ -n "${KLMS_SSO_LOGIN_ID:-}" ]]; then
    print -r -- "$KLMS_SSO_LOGIN_ID"
    return 0
  fi
  if [[ -n "${KAIST_SSO_LOGIN_ID:-}" ]]; then
    print -r -- "$KAIST_SSO_LOGIN_ID"
    return 0
  fi
  return 1
}

notify_digits_if_enabled() {
  local digits="$1"
  [[ "$KLMS_LOGIN_ASSIST_NOTIFY_DIGITS_ENABLED" == "1" ]] || return 0

  "$KLMS_LOGIN_ASSIST_OSASCRIPT_BIN" \
    -e 'on run argv' \
    -e 'set authNumber to item 1 of argv' \
    -e 'display notification "휴대폰 KAIST 인증 화면에서 " & authNumber & " 를 선택해 주세요." with title "KLMS 인증 번호"' \
    -e 'end run' \
    "$digits" >/dev/null 2>&1 || true
}

DISPLAY_NAME="$(load_display_name)" || {
  print -r -- "status=skipped reason=missing-login-id"
  print -r -- "KLMS_SSO_LOGIN_ID 또는 KAIST_SSO_LOGIN_ID를 config.env에 설정해 줘." >&2
  exit 2
}

deadline_epoch="$(( $(date +%s) + KLMS_LOGIN_ASSIST_APPROVAL_TIMEOUT_SECONDS ))"
last_status=""
last_digits=""
last_digits_epoch=0
last_auth_check_epoch=0
submitted_login_this_run=0
preexisting_twofactor_refresh_attempted=0

while (( $(date +%s) <= deadline_epoch )); do
  step_json="$("$KLMS_LOGIN_ASSIST_OSASCRIPT_BIN" -l JavaScript "$KLMS_JS_DIR/klms_login_safari_step.js" \
    "--url=$KLMS_LOGIN_URL" \
    "--display-name=$DISPLAY_NAME" \
    "--max-seconds=$KLMS_LOGIN_ASSIST_STEP_TIMEOUT_SECONDS" \
    "--poll-ms=$KLMS_LOGIN_ASSIST_STEP_POLL_MS" 2>/dev/null || true)"

  if [[ -z "$step_json" ]]; then
    sleep "$KLMS_LOGIN_ASSIST_POLL_SECONDS"
    continue
  fi

  step_status="$(json_get "$step_json" status 2>/dev/null || true)"
  last_status="$step_status"
  submitted_login="$(json_get "$step_json" submittedLogin 2>/dev/null || true)"
  if [[ "$submitted_login" == "True" || "$submitted_login" == "true" ]]; then
    submitted_login_this_run=1
  fi

  case "$step_status" in
    authenticated)
      if [[ "$submitted_login_this_run" != "1" && -z "$last_digits" ]]; then
        print -r -- "status=ok stage=already_authenticated source=login-assist-safari"
        print -r -- "KLMS 이미 로그인되어 있습니다."
      else
        print -r -- "status=ok stage=authenticated"
      fi
      exit 0
      ;;
    twofactor_digits)
      digits="$(json_get "$step_json" digits 2>/dev/null || true)"
      if [[ "$digits" == <-> && "${#digits}" == "2" ]]; then
        now_epoch="$(date +%s)"
        if [[ "$submitted_login_this_run" != "1" ]] \
          && [[ "$KLMS_LOGIN_ASSIST_REFRESH_PREEXISTING_TWOFACTOR_ENABLED" == "1" ]] \
          && [[ "$preexisting_twofactor_refresh_attempted" != "1" ]]; then
          preexisting_twofactor_refresh_attempted=1
          refresh_json="$("$KLMS_LOGIN_ASSIST_OSASCRIPT_BIN" -l JavaScript "$KLMS_JS_DIR/klms_login_safari_step.js" \
            "--url=$KLMS_LOGIN_URL" \
            "--display-name=$DISPLAY_NAME" \
            "--refresh-twofactor=1" \
            "--max-seconds=0" 2>/dev/null || true)"
          refresh_status="$(json_get "$refresh_json" status 2>/dev/null || true)"
          if [[ "$refresh_status" == "twofactor_refreshed" ]]; then
            print -r -- "기존 KAIST 인증 화면을 새로 요청했어."
            last_digits=""
            last_digits_epoch=0
            submitted_login_this_run=0
            sleep "$KLMS_LOGIN_ASSIST_POLL_SECONDS"
            continue
          fi
        fi
        if [[ "$digits" != "$last_digits" && -n "$last_digits" ]]; then
          digits="$last_digits"
        elif [[ "$digits" != "$last_digits" ]]; then
          last_digits="$digits"
          last_digits_epoch="$now_epoch"
          print -r -- "KAIST 인증 번호: $digits"
          notify_digits_if_enabled "$digits"
          print -r -- "휴대폰 인증 화면에서 같은 번호를 선택하면 동기화를 계속 진행해."
        fi
        if [[ "$KLMS_LOGIN_ASSIST_AUTHENTICATED_RECHECK_SECONDS" == <-> ]] \
          && (( KLMS_LOGIN_ASSIST_AUTHENTICATED_RECHECK_SECONDS > 0 )) \
          && (( now_epoch - last_digits_epoch >= KLMS_LOGIN_ASSIST_AUTHENTICATED_RECHECK_SECONDS )) \
          && (( now_epoch - last_auth_check_epoch >= KLMS_LOGIN_ASSIST_AUTHENTICATED_RECHECK_SECONDS )); then
          last_auth_check_epoch="$now_epoch"
          check_json="$("$KLMS_LOGIN_ASSIST_OSASCRIPT_BIN" -l JavaScript "$KLMS_JS_DIR/klms_login_safari_step.js" \
            "--url=$KLMS_LOGIN_URL" \
            "--display-name=$DISPLAY_NAME" \
            "--check-authenticated=1" \
            "--auth-check-seconds=$KLMS_LOGIN_ASSIST_AUTH_CHECK_SECONDS" \
            "--max-seconds=$KLMS_LOGIN_ASSIST_STEP_TIMEOUT_SECONDS" \
            "--poll-ms=$KLMS_LOGIN_ASSIST_STEP_POLL_MS" 2>/dev/null || true)"
          check_status="$(json_get "$check_json" status 2>/dev/null || true)"
          if [[ "$check_status" == "authenticated" ]]; then
            print -r -- "status=ok stage=authenticated"
            exit 0
          fi
        elif [[ "$KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS" == <-> ]] \
          && (( KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS > 0 )) \
          && (( now_epoch - last_digits_epoch >= KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS )); then
          refresh_json="$("$KLMS_LOGIN_ASSIST_OSASCRIPT_BIN" -l JavaScript "$KLMS_JS_DIR/klms_login_safari_step.js" \
            "--url=$KLMS_LOGIN_URL" \
            "--display-name=$DISPLAY_NAME" \
            "--refresh-twofactor=1" \
            "--max-seconds=0" 2>/dev/null || true)"
          refresh_status="$(json_get "$refresh_json" status 2>/dev/null || true)"
          if [[ "$refresh_status" == "twofactor_refreshed" ]]; then
            print -r -- "KAIST 인증 번호를 새로 요청했어."
            last_digits=""
            last_digits_epoch="$now_epoch"
            submitted_login_this_run=0
            sleep "$KLMS_LOGIN_ASSIST_POLL_SECONDS"
            continue
          fi
        fi
        sleep "$KLMS_LOGIN_ASSIST_POLL_SECONDS"
      fi
      ;;
    login_submitted)
      submitted_login_this_run=1
      ;;
    twofactor_refreshed)
      submitted_login_this_run=0
      ;;
    navigated|klms_redirect_clicked|twofactor_pending|waiting)
      ;;
    error)
      reason="$(json_get "$step_json" error 2>/dev/null || true)"
      print -r -- "status=failed stage=safari reason=${reason:-unknown}"
      exit 1
      ;;
  esac

  sleep "$KLMS_LOGIN_ASSIST_POLL_SECONDS"
done

if [[ -n "$last_digits" ]]; then
  print -r -- "status=timeout last_status=${last_status:-unknown} digits=$last_digits"
else
  print -r -- "status=timeout last_status=${last_status:-unknown}"
fi
exit 1
