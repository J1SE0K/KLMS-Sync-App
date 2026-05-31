#!/bin/zsh

set -euo pipefail

ACTION="${1:-install}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_SUPPORT="${KLMS_RELAY_APP_SUPPORT:-$HOME/Library/Application Support/KLMSNotesSync}"
INSTALL_TOOLS_DIR="$APP_SUPPORT/tools"
RELAY_DIR="$APP_SUPPORT/runtime/relay"
LOG_DIR="$APP_SUPPORT/runtime/logs"
ENV_FILE="${KLMS_RELAY_ENV_FILE:-$RELAY_DIR/relay.env}"
LABEL="${KLMS_RELAY_LAUNCHD_LABEL:-com.local.klms-sync-relay}"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
GUI_DOMAIN="gui/$(id -u)"
DEFAULT_HOST="${KLMS_RELAY_HOST:-127.0.0.1}"
DEFAULT_PORT="${KLMS_RELAY_PORT:-18484}"
DEFAULT_DB="${KLMS_RELAY_DB:-$RELAY_DIR/klms-sync-relay.sqlite}"
SERVER_SCRIPT="${KLMS_RELAY_SERVER_SCRIPT:-$INSTALL_TOOLS_DIR/klms_relay_server.mjs}"
RUNNER_SCRIPT="${KLMS_RELAY_RUNNER_SCRIPT:-$INSTALL_TOOLS_DIR/run_klms_relay_agent.sh}"
AGENT_WORKING_DIR="${KLMS_RELAY_WORKING_DIR:-$APP_SUPPORT}"

case "$ACTION" in
  install|uninstall|status|print-config) ;;
  *)
    print -u2 -- "Usage: $0 [install|uninstall|status|print-config]"
    exit 64
    ;;
esac

find_node() {
  if command -v node >/dev/null 2>&1; then
    command -v node
    return
  fi
  for candidate in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
    if [[ -x "$candidate" ]]; then
      print -r -- "$candidate"
      return
    fi
  done
  return 1
}

generate_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return
  fi
  uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]'
}

read_existing_env_value() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 1
  awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }' "$ENV_FILE"
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  print -r -- "$value"
}

shell_quote() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  print -r -- "'$value'"
}

write_env_file() {
  local node_bin="$1"
  local token="$2"

  mkdir -p "$RELAY_DIR" "$LOG_DIR"
  umask 077
  cat > "$ENV_FILE" <<EOF
KLMS_RELAY_HOST=$DEFAULT_HOST
KLMS_RELAY_PORT=$DEFAULT_PORT
KLMS_RELAY_TOKEN=$token
KLMS_RELAY_DB=$(shell_quote "$DEFAULT_DB")
KLMS_RELAY_NODE=$(shell_quote "$node_bin")
KLMS_RELAY_SERVER_SCRIPT=$(shell_quote "$SERVER_SCRIPT")
EOF
  chmod 600 "$ENV_FILE"
}

install_tool_files() {
  mkdir -p "$INSTALL_TOOLS_DIR"
  cp -X "$SCRIPT_DIR/klms_relay_server.mjs" "$INSTALL_TOOLS_DIR/klms_relay_server.mjs"
  cp -X "$SCRIPT_DIR/run_klms_relay_agent.sh" "$INSTALL_TOOLS_DIR/run_klms_relay_agent.sh"
  chmod +x "$INSTALL_TOOLS_DIR/klms_relay_server.mjs" "$INSTALL_TOOLS_DIR/run_klms_relay_agent.sh"
}

write_plist() {
  mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
  local label_xml; label_xml="$(xml_escape "$LABEL")"
  local runner_xml; runner_xml="$(xml_escape "$RUNNER_SCRIPT")"
  local working_xml; working_xml="$(xml_escape "$AGENT_WORKING_DIR")"
  local stdout_xml; stdout_xml="$(xml_escape "$LOG_DIR/relay.stdout.log")"
  local stderr_xml; stderr_xml="$(xml_escape "$LOG_DIR/relay.stderr.log")"

  cat > "$PLIST_DST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label_xml</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$runner_xml</string>
  </array>

  <key>WorkingDirectory</key>
  <string>$working_xml</string>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>StandardOutPath</key>
  <string>$stdout_xml</string>

  <key>StandardErrorPath</key>
  <string>$stderr_xml</string>
</dict>
</plist>
EOF
}

health_url() {
  local host="${KLMS_RELAY_HOST:-$DEFAULT_HOST}"
  local port="${KLMS_RELAY_PORT:-$DEFAULT_PORT}"
  print -r -- "http://$host:$port/healthz"
}

print_config() {
  local token
  token="$(read_existing_env_value KLMS_RELAY_TOKEN || true)"
  print -r -- "서버 주소: http://$DEFAULT_HOST:$DEFAULT_PORT"
  if [[ -n "$token" ]]; then
    print -r -- "토큰: $token"
  else
    print -r -- "토큰: relay.env 생성 전"
  fi
  print -r -- "DB: $DEFAULT_DB"
  print -r -- "환경 파일: $ENV_FILE"
  print -r -- "LaunchAgent: $PLIST_DST"
}

install_agent() {
  local node_bin="${KLMS_RELAY_NODE:-}"
  if [[ -z "$node_bin" ]]; then
    node_bin="$(find_node)" || {
      print -u2 -- "node executable not found. Install Node.js first."
      exit 69
    }
  fi
  if [[ ! -x "$node_bin" ]]; then
    print -u2 -- "node is not executable: $node_bin"
    exit 69
  fi
  install_tool_files

  local existing_token token
  existing_token="$(read_existing_env_value KLMS_RELAY_TOKEN || true)"
  token="${KLMS_RELAY_TOKEN:-$existing_token}"
  if [[ -z "$token" ]]; then
    token="$(generate_token)"
  fi

  write_env_file "$node_bin" "$token"
  write_plist

  launchctl bootout "$GUI_DOMAIN" "$PLIST_DST" >/dev/null 2>&1 || true
  launchctl bootstrap "$GUI_DOMAIN" "$PLIST_DST"
  launchctl enable "$GUI_DOMAIN/$LABEL"

  print -r -- "Installed $PLIST_DST"
  print_config
}

uninstall_agent() {
  launchctl bootout "$GUI_DOMAIN" "$PLIST_DST" >/dev/null 2>&1 || true
  rm -f "$PLIST_DST"
  print -r -- "Removed $PLIST_DST"
  print -r -- "DB/env/logs are preserved under $RELAY_DIR and $LOG_DIR"
}

status_agent() {
  launchctl print "$GUI_DOMAIN/$LABEL" 2>/dev/null | sed -n '1,40p' || {
    print -r -- "$LABEL is not loaded"
  }
  if command -v curl >/dev/null 2>&1; then
    print -r -- ""
    curl -fsS "$(health_url)" || true
    print -r -- ""
  fi
}

case "$ACTION" in
  install)
    install_agent
    ;;
  uninstall)
    uninstall_agent
    ;;
  status)
    status_agent
    ;;
  print-config)
    print_config
    ;;
esac
