#!/bin/zsh

klms_default_runtime_namespace() {
  local entry_path="${1:-}"
  local entry_name="${entry_path:t}"

  case "$entry_name" in
    sync_klms_core.sh)
      print -r -- "core"
      ;;
    sync_klms_notice.sh)
      print -r -- "notice"
      ;;
    refresh_course_files.sh)
      print -r -- "files"
      ;;
    run_all.sh|run_all_full.sh|sync_klms_all.sh)
      print -r -- "all"
      ;;
    *)
      print -r -- "shared"
      ;;
  esac
}

klms_default_app_data_dir() {
  print -r -- "$HOME/Library/Application Support/KLMSNotesSync"
}

klms_is_source_checkout_dir() {
  local root="${1:-}"
  [[ -d "$root/apps/KLMSync" && -d "$root/src" && -d "$root/bin" ]]
}

klms_default_readonly_data_dir() {
  local script_dir="${1:?missing script dir}"
  local installed_dir="${KLMS_INSTALLED_DATA_DIR:-$(klms_default_app_data_dir)}"

  if [[ "$script_dir" != "$installed_dir" ]] \
    && klms_is_source_checkout_dir "$script_dir" \
    && [[ -d "$installed_dir/runtime" ]]; then
    print -r -- "$installed_dir"
  else
    print -r -- "$script_dir"
  fi
}

klms_init_context() {
  local entry_path="${1:?missing entry path}"
  local config_path="${2:-}"
  local runtime_namespace=""
  local lock_name=""
  local key
  local -a runtime_override_keys=(
    KLMS_APP_RUN
    KLMS_SCRIPT_NOTIFICATIONS_ENABLED
    LANG
    LC_ALL
    LC_CTYPE
    PYTHONIOENCODING
    PYTHONUTF8
    KLMS_PYTHON_BIN
    KLMS_PYTHONPATH_DIR
    KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED
    KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED
    KLMS_LOGIN_ASSIST_ENABLED
    KLMS_LOGIN_ASSIST_MODE
    KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE
    KLMS_FORCE_LOGIN_PREFLIGHT
    KLMS_LOGIN_STATUS_REUSE_SECONDS
    KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS
    KAIKEY_REFRESH_PREEXISTING_TWOFACTOR_ENABLED
    OVERRIDES_JSON_PATH
    SYNC_MODE
    FILE_REFRESH_MODE
    FILE_OUTPUT_ROOT
    FILE_DOWNLOAD_WORK_ROOT
    FILE_DOWNLOAD_ARCHIVE_ROOT
    FILE_FORCE_DOWNLOAD
    FILE_KEEP_FRESH_DOWNLOADS
    FILE_WEEKLY_FOLDERS_ENABLED
    FILE_SKIP_DOWNLOAD_WHEN_PREVIEW_EMPTY
    FILE_ALWAYS_FETCH_MIN_INTERVAL_SECONDS
    FILE_PRESERVE_DOWNLOAD_ARCHIVE
    FILE_NEW_FILES_ROOT
    FILE_QUARANTINE_ROOT
    NOTICE_NATIVE_NOTE_BIN_PATH
    NOTICE_COLLAPSE_SECTIONS
    NOTICE_COLLAPSE_COURSES
    NOTICE_COLLAPSE_NOTICE_ITEMS
    NOTICE_STYLE_NOTICE_ITEMS_AS_HEADINGS
    NOTICE_HIDE_HIDDEN_ITEMS
    NOTICE_NATIVE_STABLE_NOOP_SKIP
    NOTICE_NATIVE_ALWAYS_CAPTURE_STATE
    NOTICE_NATIVE_DEFER_STATE_ONLY_RENDER
    NOTICE_NATIVE_FORCE_ARCHIVE_POST_CAPTURE_RENDER
    NOTICE_NATIVE_VERIFY_STABLE_SKIP_FORMAT
    NOTICE_NATIVE_POST_RENDER_VERIFY
    NOTICE_NATIVE_INITIAL_COLLAPSE_ENABLED
    NOTICE_NATIVE_ENABLE_BATCH_CHECKLIST_FORMAT
    NOTICE_NATIVE_DISABLE_BATCH_CHECKLIST_FORMAT
    NOTICE_NATIVE_DISABLE_FAST_CHECKLIST_FORMAT
    NOTICE_NATIVE_ENABLE_UI_STYLE_FORMAT
    NOTICE_NATIVE_DISABLE_UI_STYLE_FORMAT
    NOTICE_NATIVE_NOTE_MAX_ATTEMPTS
    NOTICE_NATIVE_NOTE_RETRY_DELAY_SECONDS
    NOTICE_NATIVE_NOTE_TIMEOUT_SECONDS
    NOTICE_NATIVE_NOTE_TIMEOUT_GRACE_SECONDS
    NOTICE_NATIVE_STYLE_BUDGET_SECONDS
    NOTICE_NATIVE_BOLD_REINFORCE_LIMIT
    NOTICE_NATIVE_VALIDATE_STYLE
    NOTICE_NATIVE_SELECTION_SETTLE_SECONDS
    NOTICE_NATIVE_CHECKLIST_PRESS_SETTLE_US
    NOTICE_NATIVE_PREFORMATTED_PASTE_ONLY
    NOTICE_NATIVE_PLAIN_TEXT_PASTE
    NOTICE_DEBUG_CAPTURE
    NOTICE_DEBUG_AUTOMATION
    NOTICE_TIMING
  )
  local -A runtime_override_present=()
  local -A runtime_override_values=()

  for key in "${runtime_override_keys[@]}"; do
    if (( ${+parameters[$key]} )); then
      runtime_override_present[$key]=1
      runtime_override_values[$key]="${(P)key}"
    fi
  done

  : "${LANG:=ko_KR.UTF-8}"
  : "${LC_ALL:=ko_KR.UTF-8}"
  : "${LC_CTYPE:=ko_KR.UTF-8}"
  : "${PYTHONIOENCODING:=utf-8}"
  : "${PYTHONUTF8:=1}"
  export LANG LC_ALL LC_CTYPE PYTHONIOENCODING PYTHONUTF8

  SCRIPT_DIR="$(cd "$(dirname "$entry_path")" && pwd)"
  if [[ -z "${KLMS_DATA_DIR:-}" ]]; then
    KLMS_DATA_DIR="$(klms_default_readonly_data_dir "$SCRIPT_DIR")"
  fi
  KLMS_SRC_DIR="$SCRIPT_DIR/src"
  KLMS_SH_DIR="$KLMS_SRC_DIR/sh"
  KLMS_JS_DIR="$KLMS_SRC_DIR/js"
  KLMS_PYTHON_DIR="$KLMS_SRC_DIR/python"
  KLMS_SWIFT_DIR="$KLMS_SRC_DIR/swift"
  CONFIG_PATH="${config_path:-$KLMS_DATA_DIR/config.env}"
  if [[ -f "$CONFIG_PATH" ]]; then
    source "$CONFIG_PATH"
  fi
  for key in "${runtime_override_keys[@]}"; do
    if [[ "${runtime_override_present[$key]:-0}" == "1" ]]; then
      typeset -gx "$key=${runtime_override_values[$key]}"
    fi
  done

  runtime_namespace="${KLMS_RUNTIME_NAMESPACE:-$(klms_default_runtime_namespace "$entry_path")}"

  RUNTIME_DIR="${KLMS_RUNTIME_DIR:-$KLMS_DATA_DIR/runtime}"
  CACHE_DIR="$RUNTIME_DIR/cache"
  WORK_CACHE_DIR="$CACHE_DIR/$runtime_namespace"
  TMP_ROOT_DIR="$RUNTIME_DIR/tmp"
  TMP_DIR="$TMP_ROOT_DIR/$runtime_namespace"
  AUTOMATION_DIR="$RUNTIME_DIR/automation"
  local preferred_lock_root
  local fallback_lock_root
  local lock_probe_dir
  preferred_lock_root="${KLMS_SHARED_SYNC_LOCK_ROOT:-$HOME/Library/Application Support/KLMSNotesSync/runtime/automation}"
  fallback_lock_root="$AUTOMATION_DIR/shared-locks"

  mkdir -p "$CACHE_DIR" "$WORK_CACHE_DIR" "$TMP_DIR" "$AUTOMATION_DIR"
  klms_configure_python_runtime
  lock_probe_dir="$preferred_lock_root/.lock-write-probe.$$"
  if ! mkdir -p "$preferred_lock_root" 2>/dev/null || ! mkdir "$lock_probe_dir" 2>/dev/null; then
    preferred_lock_root="$fallback_lock_root"
    mkdir -p "$preferred_lock_root"
  else
    rmdir "$lock_probe_dir" 2>/dev/null || true
  fi
  KLMS_SHARED_SYNC_LOCK_ROOT="$preferred_lock_root"

  KLMS_DASHBOARD_URL="${KLMS_DASHBOARD_URL:-https://klms.kaist.ac.kr/my/}"
  SAFARI_WAIT_SECONDS="${SAFARI_WAIT_SECONDS:-6}"
  FETCH_MIN_WAIT_SECONDS="${FETCH_MIN_WAIT_SECONDS:-1.5}"
  FETCH_STABLE_POLLS="${FETCH_STABLE_POLLS:-2}"
  FETCH_CACHE_STATE_PATH="${FETCH_CACHE_STATE_PATH:-$WORK_CACHE_DIR/fetch_state.json}"
  KLMS_LOGIN_STATUS_PATH="${KLMS_LOGIN_STATUS_PATH:-${KLMS_LOGIN_STATUS_CACHE_PATH:-$CACHE_DIR/login_status.json}}"
  KLMS_LOGIN_STATUS_CACHE_PATH="$KLMS_LOGIN_STATUS_PATH"
  KLMS_LOGIN_FAST_TAB_CHECK_ENABLED="${KLMS_LOGIN_FAST_TAB_CHECK_ENABLED:-1}"
  KLMS_FORCE_LOGIN_PREFLIGHT="${KLMS_FORCE_LOGIN_PREFLIGHT:-0}"
  KLMS_LOGIN_STATUS_REUSE_SECONDS="${KLMS_LOGIN_STATUS_REUSE_SECONDS:-900}"
  KLMS_LOGIN_URL="${KLMS_LOGIN_URL:-$KLMS_DASHBOARD_URL}"
  KLMS_LOGIN_OPEN_SAFARI_ON_FAILURE="${KLMS_LOGIN_OPEN_SAFARI_ON_FAILURE:-1}"
  KLMS_LOGIN_ASSIST_ENABLED="${KLMS_LOGIN_ASSIST_ENABLED:-${KAIKEY_LOGIN_ASSIST_ENABLED:-${KAIKEY_AUTO_LOGIN_ENABLED:-0}}}"
  KLMS_LOGIN_ASSIST_EARLY_ENABLED="${KLMS_LOGIN_ASSIST_EARLY_ENABLED:-1}"
  KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE="${KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE:-${KAIKEY_LOGIN_ASSIST_ALLOW_NONINTERACTIVE:-0}}"
  KAIKEY_AUTO_LOGIN_ENABLED="${KAIKEY_AUTO_LOGIN_ENABLED:-0}"
  KAIKEY_AUTO_APPROVE_ENABLED="${KAIKEY_AUTO_APPROVE_ENABLED:-0}"
  KAIKEY_STATE_PATH="${KAIKEY_STATE_PATH:-$HOME/Library/Application Support/KLMSNotesSync/kaikey_state.json}"
  lock_name="${KLMS_SYNC_LOCK_NAME:-$runtime_namespace}"
  KLMS_SHARED_SYNC_LOCK_DIR="${KLMS_SHARED_SYNC_LOCK_DIR:-$KLMS_SHARED_SYNC_LOCK_ROOT/${lock_name}.lock}"
  KLMS_SHARED_SYNC_LOCK_WAIT_SECONDS="${KLMS_SHARED_SYNC_LOCK_WAIT_SECONDS:-900}"
  KLMS_LOGIN_PREFETCH_READY=0
  KLMS_LOGIN_ASSIST_READY=0
  KLMS_LAST_LOGIN_ERROR_MESSAGE=""
  export KLMS_DATA_DIR KLMS_SRC_DIR KLMS_SH_DIR KLMS_JS_DIR KLMS_PYTHON_DIR KLMS_SWIFT_DIR
}

klms_parse_entry_args() {
  KLMS_ENTRY_CONFIG_ARG=""
  KLMS_ENTRY_EXTRA_ARGS=()
  KLMS_DRY_RUN="${KLMS_DRY_RUN:-0}"

  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run)
        KLMS_DRY_RUN=1
        KLMS_ENTRY_EXTRA_ARGS+=("--dry-run")
        ;;
      --)
        ;;
      *)
        KLMS_ENTRY_CONFIG_ARG="$arg"
        ;;
    esac
  done
  export KLMS_DRY_RUN
}

klms_configure_python_runtime() {
  local python_bin="${KLMS_PYTHON_BIN:-}"
  local python_packages_dir="${KLMS_PYTHONPATH_DIR:-$RUNTIME_DIR/python-packages}"
  local joined_pythonpath=""

  if [[ -n "$python_bin" ]]; then
    if [[ -x "$python_bin" ]]; then
      PATH="${python_bin:h}:$PATH"
      export PATH
    else
      print -r -- "warning: KLMS_PYTHON_BIN is not executable: $python_bin" >&2
    fi
  fi

  local python_path_parts=()
  [[ -d "${KLMS_PYTHON_DIR:-}" ]] && python_path_parts+=("$KLMS_PYTHON_DIR")
  [[ -d "$python_packages_dir" ]] && python_path_parts+=("$python_packages_dir")

  if (( ${#python_path_parts[@]} > 0 )); then
    local part
    for part in "${python_path_parts[@]}"; do
      if [[ -z "$joined_pythonpath" ]]; then
        joined_pythonpath="$part"
      else
        joined_pythonpath="$joined_pythonpath:$part"
      fi
    done
    if [[ -n "${PYTHONPATH:-}" ]]; then
      PYTHONPATH="$joined_pythonpath:$PYTHONPATH"
    else
      PYTHONPATH="$joined_pythonpath"
    fi
    export PYTHONPATH
  fi
}

klms_shared_sync_lock_owner_pid() {
  local pid_file="${KLMS_SHARED_SYNC_LOCK_DIR}/pid"
  if [[ -f "$pid_file" ]]; then
    <"$pid_file"
  fi
}

klms_shared_sync_lock_owner_running() {
  local owner_pid="$1"
  [[ "$owner_pid" == <-> ]] || return 1
  kill -0 "$owner_pid" 2>/dev/null
}

klms_cleanup_stale_shared_sync_lock() {
  [[ -d "$KLMS_SHARED_SYNC_LOCK_DIR" ]] || return 0

  local owner_pid
  owner_pid="$(klms_shared_sync_lock_owner_pid)"
  if klms_shared_sync_lock_owner_running "$owner_pid"; then
    return 0
  fi

  rm -f "$KLMS_SHARED_SYNC_LOCK_DIR/pid" \
    "$KLMS_SHARED_SYNC_LOCK_DIR/command" \
    "$KLMS_SHARED_SYNC_LOCK_DIR/acquired_at"
  rmdir "$KLMS_SHARED_SYNC_LOCK_DIR" 2>/dev/null || true
}

klms_acquire_shared_sync_lock() {
  if [[ "${KLMS_SHARED_SYNC_LOCK_HELD:-0}" == "1" ]]; then
    local owner_pid
    owner_pid="$(klms_shared_sync_lock_owner_pid)"
    if [[ "$owner_pid" == "$$" ]]; then
      return 0
    fi
  fi

  local wait_seconds now_epoch deadline_epoch owner_pid
  wait_seconds="${KLMS_SHARED_SYNC_LOCK_WAIT_SECONDS:-900}"
  now_epoch="$(date +%s)"
  deadline_epoch="$(( now_epoch + wait_seconds ))"

  while ! mkdir "$KLMS_SHARED_SYNC_LOCK_DIR" 2>/dev/null; do
    klms_cleanup_stale_shared_sync_lock
    if mkdir "$KLMS_SHARED_SYNC_LOCK_DIR" 2>/dev/null; then
      break
    fi

    if (( $(date +%s) >= deadline_epoch )); then
      owner_pid="$(klms_shared_sync_lock_owner_pid)"
      if [[ "$owner_pid" == <-> ]]; then
        print -r -- "Another KLMS sync is still running (pid=$owner_pid)." >&2
      else
        print -r -- "Another KLMS sync is still running." >&2
      fi
      return 1
    fi

    sleep 1
  done

  print -r -- "$$" > "$KLMS_SHARED_SYNC_LOCK_DIR/pid"
  print -r -- "${0:-unknown}" > "$KLMS_SHARED_SYNC_LOCK_DIR/command"
  date '+%Y-%m-%d %H:%M:%S %Z' > "$KLMS_SHARED_SYNC_LOCK_DIR/acquired_at"
  export KLMS_SHARED_SYNC_LOCK_HELD=1
  export KLMS_SHARED_SYNC_LOCK_DIR
}

klms_release_shared_sync_lock() {
  [[ "${KLMS_SHARED_SYNC_LOCK_HELD:-0}" == "1" ]] || return 0
  [[ -d "$KLMS_SHARED_SYNC_LOCK_DIR" ]] || return 0

  local owner_pid
  owner_pid="$(klms_shared_sync_lock_owner_pid)"
  if [[ "$owner_pid" != "$$" ]]; then
    return 0
  fi

  rm -f "$KLMS_SHARED_SYNC_LOCK_DIR/pid" \
    "$KLMS_SHARED_SYNC_LOCK_DIR/command" \
    "$KLMS_SHARED_SYNC_LOCK_DIR/acquired_at"
  rmdir "$KLMS_SHARED_SYNC_LOCK_DIR" 2>/dev/null || true
}

klms_write_login_status_ok() {
  local now_epoch
  now_epoch="$(date +%s)"
  cat > "$KLMS_LOGIN_STATUS_PATH" <<EOF
{"checked_at_epoch":$now_epoch,"logged_in":true}
EOF
}

klms_clear_login_status() {
  rm -f "$KLMS_LOGIN_STATUS_PATH"
}

klms_recent_login_status_ok() {
  local reuse_seconds="${KLMS_LOGIN_STATUS_REUSE_SECONDS:-0}"
  [[ "$reuse_seconds" == <-> ]] || return 1
  (( reuse_seconds > 0 )) || return 1
  [[ -s "$KLMS_LOGIN_STATUS_PATH" ]] || return 1
  [[ -s "$CACHE_DIR/dashboard.json" ]] || return 1

  python3 - "$KLMS_LOGIN_STATUS_PATH" "$reuse_seconds" <<'PY'
import json
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
reuse_seconds = int(sys.argv[2])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)

checked_at = int(float(payload.get("checked_at_epoch") or 0))
if payload.get("logged_in") is True and checked_at > 0 and time.time() - checked_at <= reuse_seconds:
    raise SystemExit(0)
raise SystemExit(1)
PY
}

klms_open_login_page_if_enabled() {
  [[ "${KLMS_LOGIN_OPEN_SAFARI_ON_FAILURE:-1}" == "1" ]] || return 0

  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'set targetUrl to item 1 of argv' \
    -e 'set shouldMinimize to true' \
    -e 'if (count of argv) > 1 and item 2 of argv is "0" then set shouldMinimize to false' \
    -e 'tell application "Safari"' \
    -e 'try' \
    -e 'make new document with properties {URL:targetUrl}' \
    -e 'if shouldMinimize then set miniaturized of front window to true' \
    -e 'on error' \
    -e 'make new document with properties {URL:targetUrl}' \
    -e 'if shouldMinimize then set miniaturized of front window to true' \
    -e 'end try' \
    -e 'end tell' \
    -e 'end run' \
    "$KLMS_LOGIN_URL" "${KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED:-1}" >/dev/null 2>&1 || true
}

klms_login_assist_enabled() {
  [[ "${KLMS_LOGIN_ASSIST_ENABLED:-${KAIKEY_LOGIN_ASSIST_ENABLED:-${KAIKEY_AUTO_LOGIN_ENABLED:-0}}}" == "1" ]]
}

klms_try_login_assist() {
  klms_login_assist_enabled || return 1
  [[ -f "$SCRIPT_DIR/kaikey_auto_login.sh" ]] || return 1
  if [[ "${KAIKEY_AUTO_APPROVE_ENABLED:-0}" != "1" && "${KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE:-${KAIKEY_LOGIN_ASSIST_ALLOW_NONINTERACTIVE:-0}}" != "1" && ! -t 1 ]]; then
    return 1
  fi

  if /bin/zsh "$SCRIPT_DIR/kaikey_auto_login.sh" "$CONFIG_PATH"; then
    print -r -- "KLMS 로그인 보조 완료" >&2
    return 0
  else
    print -r -- "KLMS 로그인 보조 실패" >&2
    return 1
  fi
}

klms_try_kaikey_auto_login() {
  klms_try_login_assist
}

klms_fast_tab_login_state() {
  if [[ "${KLMS_LOGIN_FAST_TAB_CHECK_ENABLED:-1}" != "1" ]]; then
    print -r -- "unknown"
    return 0
  fi

  local tabs_json
  tabs_json="$(cd "$SCRIPT_DIR" && /usr/bin/osascript -l JavaScript "$KLMS_JS_DIR/inspect_klms_tabs.js" 2>/dev/null)" || {
    print -r -- "unknown"
    return 0
  }

  python3 -c '
import json
import sys

def looks_like_login(url: str, title: str) -> bool:
    url_lower = (url or "").lower()
    title_lower = (title or "").lower()
    return (
        "login" in url_lower
        or "portal.kaist.ac.kr" in url_lower
        or "log in" in title_lower
        or "single sign on" in title_lower
    )

payload = json.load(sys.stdin)
tabs = payload.get("tabs") or []
has_authenticated = False
has_login = False

for tab in tabs:
    url = str(tab.get("url") or "")
    title = str(tab.get("title") or "")
    if "klms.kaist.ac.kr" not in url.lower():
        continue
    if looks_like_login(url, title):
        has_login = True
    else:
        has_authenticated = True

if has_login and not has_authenticated:
    print("login_required")
elif has_authenticated:
    print("authenticated")
else:
    print("unknown")
' <<< "$tabs_json"
}

klms_check_login_pages() {
  local pages_json="$1"
  local error_message="${2:-KLMS 로그인이 풀린 것 같아. 다시 로그인해 줘.}"
  local report_failure="${3:-1}"
  local status_json login_result message

  status_json="$(cd "$SCRIPT_DIR" && /usr/bin/env python3 -m klms_sync_v2.cli check-login-status --pages-json "$pages_json")"
  login_result="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","error"))' <<< "$status_json")"

  if [[ "$login_result" == "ok" ]]; then
    klms_write_login_status_ok
    return 0
  fi

  klms_clear_login_status
  message="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("message",""))' <<< "$status_json")"
  if [[ -z "$message" ]]; then
    message="$error_message"
  fi
  KLMS_LAST_LOGIN_ERROR_MESSAGE="$message"
  if [[ "$report_failure" == "1" ]]; then
    klms_open_login_page_if_enabled
    print -r -- "$message" >&2
  fi
  return 1
}

klms_require_login() {
  local app_run_login_assist_attempted=0
  local fast_tab_state="unknown"
  local force_login_preflight="${KLMS_FORCE_LOGIN_PREFLIGHT:-0}"

  if [[ "${KLMS_PARENT_LOGIN_ASSIST_READY:-0}" == "1" ]]; then
    KLMS_LOGIN_ASSIST_READY=1
  fi

  if [[ "${KLMS_PARENT_LOGIN_PREFLIGHT_READY:-0}" == "1" && "${KLMS_USE_EXISTING_DASHBOARD:-0}" == "1" && -s "$WORK_CACHE_DIR/dashboard.json" ]]; then
    klms_check_login_pages "$WORK_CACHE_DIR/dashboard.json" || return 1
    KLMS_LOGIN_PREFETCH_READY=1
    return 0
  fi

  fast_tab_state="$(klms_fast_tab_login_state)"

  if [[ "$force_login_preflight" != "1" && "${KLMS_APP_RUN:-0}" == "1" ]]; then
    if klms_recent_login_status_ok; then
      KLMS_LOGIN_PREFETCH_READY=1
      return 0
    fi
    if [[ "$fast_tab_state" == "authenticated" ]]; then
      klms_write_login_status_ok
      KLMS_LOGIN_PREFETCH_READY=1
      KLMS_LOGIN_ASSIST_READY=1
      return 0
    fi
  fi

  if [[ "$force_login_preflight" != "1" && "${KLMS_APP_RUN:-0}" != "1" && "$fast_tab_state" == "login_required" && "$app_run_login_assist_attempted" != "1" ]]; then
    klms_clear_login_status
    if ! klms_try_login_assist; then
      klms_open_login_page_if_enabled
      print -r -- "KLMS 로그인이 풀린 것 같아. 다시 로그인해 줘." >&2
      return 1
    fi
    klms_write_login_status_ok
    KLMS_LOGIN_ASSIST_READY=1
  fi

  if [[ "$force_login_preflight" != "1" && "${KLMS_APP_RUN:-0}" != "1" && "$fast_tab_state" != "login_required" ]] && klms_recent_login_status_ok; then
    KLMS_LOGIN_PREFETCH_READY=1
    return 0
  fi

  if [[ "${KLMS_APP_RUN:-0}" != "1" && "$fast_tab_state" == "unknown" && "${KLMS_LOGIN_ASSIST_EARLY_ENABLED:-1}" == "1" && "$app_run_login_assist_attempted" != "1" ]]; then
    klms_try_login_assist || true
  fi

  local url_file="$TMP_DIR/klms_login_preflight_urls.txt"
  local pages_json="$CACHE_DIR/dashboard.json"

  printf '%s\n' "$KLMS_DASHBOARD_URL" > "$url_file"
  print -r -- "[login $(date '+%Y-%m-%d %H:%M:%S %Z')] preflight start" >&2
  (
    cd "$SCRIPT_DIR"
    /usr/bin/env python3 "$KLMS_PYTHON_DIR/fetch_pages_backend.py" \
      --backend=safari \
      --mode=full \
      --context=klms-login-preflight \
      --wait="$SAFARI_WAIT_SECONDS" \
      --min-wait="$FETCH_MIN_WAIT_SECONDS" \
      --stable-polls="$FETCH_STABLE_POLLS" \
      --out="$pages_json" \
      --cache-state="$FETCH_CACHE_STATE_PATH" \
      --discard-previous \
      --allow-login-pages \
      --url-file="$url_file"
  )

  if ! klms_check_login_pages "$pages_json" "KLMS 로그인이 풀린 것 같아. 다시 로그인해 줘." 0; then
    if klms_try_login_assist; then
      (
        cd "$SCRIPT_DIR"
        /usr/bin/env python3 "$KLMS_PYTHON_DIR/fetch_pages_backend.py" \
          --backend=safari \
          --mode=full \
          --context=klms-login-preflight \
          --wait="$SAFARI_WAIT_SECONDS" \
          --min-wait="$FETCH_MIN_WAIT_SECONDS" \
          --stable-polls="$FETCH_STABLE_POLLS" \
          --out="$pages_json" \
          --cache-state="$FETCH_CACHE_STATE_PATH" \
          --discard-previous \
          --allow-login-pages \
          --url-file="$url_file"
      )
      klms_check_login_pages "$pages_json" || return 1
    else
      klms_open_login_page_if_enabled
      print -r -- "${KLMS_LAST_LOGIN_ERROR_MESSAGE:-KLMS 로그인이 풀린 것 같아. 다시 로그인해 줘.}" >&2
      return 1
    fi
  fi
  print -r -- "[login $(date '+%Y-%m-%d %H:%M:%S %Z')] preflight finish status=ok" >&2
  KLMS_LOGIN_PREFETCH_READY=1
  return 0
}

klms_run_sync_scope() {
  local scope="$1"
  shift || true
  local extra_args=()
  if [[ "${KLMS_LOGIN_PREFETCH_READY:-0}" == "1" ]]; then
    extra_args+=("--use-prefetched-dashboard")
  fi

  /usr/bin/osascript -l JavaScript \
    "$KLMS_JS_DIR/sync_klms_notes.js" \
    "$CONFIG_PATH" \
    "--scope=$scope" \
    "${extra_args[@]}" \
    "$@"
}

klms_run_sync_scope_entrypoint() {
  local scope="$1"
  shift || true
  local sync_output

  klms_acquire_shared_sync_lock
  trap 'klms_release_shared_sync_lock' EXIT
  klms_require_login
  sync_output="$(klms_run_sync_scope "$scope" "$@")"
  print -r -- "$sync_output"
  if [[ "$sync_output" != status=ok* ]]; then
    return 1
  fi
  klms_cleanup_runtime_tmp_if_enabled
}

klms_export_shared_sync_cache_defaults() {
  export KLMS_RUN_STARTED_EPOCH="${KLMS_RUN_STARTED_EPOCH:-$(date +%s)}"
  export KLMS_SHARED_COURSE_PAGES_JSON="${KLMS_SHARED_COURSE_PAGES_JSON:-$CACHE_DIR/core/course_pages.json}"
  export KLMS_SHARED_ALL_WEEK_COURSE_PAGES_JSON="${KLMS_SHARED_ALL_WEEK_COURSE_PAGES_JSON:-$CACHE_DIR/core/all_week_course_pages.json}"
  export KLMS_SHARED_SUPPLEMENTAL_PRIMARY_PAGES_JSON="${KLMS_SHARED_SUPPLEMENTAL_PRIMARY_PAGES_JSON:-$CACHE_DIR/core/supplemental_primary_pages.json}"
}

klms_prepare_prefetched_dashboard_for_namespaces() {
  local prefetched_dashboard="$CACHE_DIR/dashboard.json"
  local namespace

  for namespace in "$@"; do
    mkdir -p "$CACHE_DIR/$namespace"
    if [[ -s "$prefetched_dashboard" ]]; then
      cp "$prefetched_dashboard" "$CACHE_DIR/$namespace/dashboard.json"
    fi
  done
}

klms_run_serial_child_job() {
  local job_name="$1"
  local script_path="$2"
  shift 2
  local started_epoch
  local finished_epoch
  local job_status=0

  started_epoch="$(date +%s)"
  print -r -- "== $job_name start $(date '+%Y-%m-%d %H:%M:%S %Z') =="
  (
    cd "$SCRIPT_DIR"
    /usr/bin/env -u KLMS_SHARED_SYNC_LOCK_HELD -u KLMS_SHARED_SYNC_LOCK_DIR \
      KLMS_USE_EXISTING_DASHBOARD="${KLMS_LOGIN_PREFETCH_READY:-0}" \
      KLMS_PARENT_LOGIN_PREFLIGHT_READY="${KLMS_LOGIN_PREFETCH_READY:-0}" \
      KLMS_PARENT_LOGIN_ASSIST_READY="${KLMS_LOGIN_ASSIST_READY:-0}" \
      KLMS_RUN_STARTED_EPOCH="$KLMS_RUN_STARTED_EPOCH" \
      KLMS_SHARED_COURSE_PAGES_JSON="$KLMS_SHARED_COURSE_PAGES_JSON" \
      KLMS_SHARED_ALL_WEEK_COURSE_PAGES_JSON="$KLMS_SHARED_ALL_WEEK_COURSE_PAGES_JSON" \
      KLMS_SHARED_SUPPLEMENTAL_PRIMARY_PAGES_JSON="$KLMS_SHARED_SUPPLEMENTAL_PRIMARY_PAGES_JSON" \
      /bin/zsh "$script_path" "$CONFIG_PATH" "$@"
  ) || job_status=$?
  finished_epoch="$(date +%s)"
  print -r -- "== $job_name finish $(date '+%Y-%m-%d %H:%M:%S %Z') status=$job_status duration_s=$((finished_epoch - started_epoch)) =="
  return "$job_status"
}

klms_cleanup_runtime_tmp_if_enabled() {
  if [[ "${KLMS_RUNTIME_TMP_CLEANUP_ENABLED:-1}" != "1" ]]; then
    return 0
  fi

  local max_age_hours="${KLMS_RUNTIME_TMP_MAX_AGE_HOURS:-0}"
  KLMS_RUNTIME_TMP_CLEANUP_TARGET="$TMP_DIR" \
    /bin/zsh "$KLMS_SH_DIR/cleanup_runtime_tmp.sh" --max-age-hours "$max_age_hours" >/dev/null 2>&1 || true
}

klms_cleanup_tmp_root_if_enabled() {
  if [[ "${KLMS_RUNTIME_TMP_CLEANUP_ENABLED:-1}" != "1" ]]; then
    return 0
  fi

  local max_age_hours="${KLMS_RUNTIME_TMP_MAX_AGE_HOURS:-0}"
  KLMS_RUNTIME_TMP_CLEANUP_TARGET="$TMP_ROOT_DIR" \
    /bin/zsh "$KLMS_SH_DIR/cleanup_runtime_tmp.sh" --max-age-hours "$max_age_hours" >/dev/null 2>&1 || true
}
