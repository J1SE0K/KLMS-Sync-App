#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_SUPPORT="${KLMS_RELAY_APP_SUPPORT:-$HOME/Library/Application Support/KLMSNotesSync}"
ENV_FILE="${KLMS_RELAY_ENV_FILE:-$APP_SUPPORT/runtime/relay/relay.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  print -u2 -- "Missing relay env file: $ENV_FILE"
  print -u2 -- "Run tools/install_klms_relay_agent.sh install first."
  exit 78
fi

set -a
source "$ENV_FILE"
set +a

NODE_BIN="${KLMS_RELAY_NODE:-}"
SERVER_SCRIPT="${KLMS_RELAY_SERVER_SCRIPT:-$ENGINE_ROOT/tools/klms_relay_server.mjs}"

if [[ -z "$NODE_BIN" || ! -x "$NODE_BIN" ]]; then
  print -u2 -- "Invalid KLMS_RELAY_NODE: $NODE_BIN"
  exit 69
fi
if [[ ! -f "$SERVER_SCRIPT" ]]; then
  print -u2 -- "Missing relay server script: $SERVER_SCRIPT"
  exit 66
fi

cd "$ENGINE_ROOT"
exec "$NODE_BIN" "$SERVER_SCRIPT"
