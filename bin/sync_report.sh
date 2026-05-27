#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMMON_SH="$SCRIPT_DIR/src/sh/klms_common.sh"
source "$COMMON_SH"

OUTPUT_JSON=0
CONFIG_ARG=""
DATA_MODE="auto"
DATA_DIR_ARG=""
for arg in "$@"; do
  case "$arg" in
    --json)
      OUTPUT_JSON=1
      ;;
    --text)
      OUTPUT_JSON=0
      ;;
    --installed)
      DATA_MODE="installed"
      ;;
    --source)
      DATA_MODE="source"
      ;;
    --data-dir=*)
      DATA_MODE="custom"
      DATA_DIR_ARG="${arg#--data-dir=}"
      ;;
    *)
      CONFIG_ARG="$arg"
      ;;
  esac
done

case "$DATA_MODE" in
  installed)
    KLMS_DATA_DIR="${KLMS_INSTALLED_DATA_DIR:-$(klms_default_app_data_dir)}"
    ;;
  source)
    KLMS_DATA_DIR="$SCRIPT_DIR"
    ;;
  custom)
    KLMS_DATA_DIR="$DATA_DIR_ARG"
    ;;
  *)
    KLMS_DATA_DIR="$(klms_default_readonly_data_dir "$SCRIPT_DIR")"
    ;;
esac
export KLMS_DATA_DIR

klms_init_context "$SCRIPT_DIR/sync_report.sh" "$CONFIG_ARG"
RESULT_JSON="$CACHE_DIR/sync_report.json"
args=(
  "$KLMS_PYTHON_BIN"
  "$KLMS_PYTHON_DIR/sync_report.py"
  --cache-dir "$CACHE_DIR"
  --state-json "$RUNTIME_DIR/state/state.json"
  --write-json "$RESULT_JSON"
)
if (( OUTPUT_JSON )); then
  args+=(--json)
fi
"${args[@]}"
