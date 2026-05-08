#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMMON_SH="$SCRIPT_DIR/src/sh/klms_common.sh"
source "$COMMON_SH"

CONFIG_ARG=""
PROCESSOR_ARGS=()

if (( $# > 0 )) && [[ "$1" != --* ]]; then
  CONFIG_ARG="$1"
  shift
fi
PROCESSOR_ARGS=("$@")

klms_init_context "$SCRIPT_DIR/process_klms_assignments.sh" "$CONFIG_ARG"

KLMS_SHARED_SYNC_LOCK_DIR="$KLMS_SHARED_SYNC_LOCK_ROOT/assignment-work.lock"
klms_acquire_shared_sync_lock
trap 'klms_release_shared_sync_lock' EXIT

ASSIGNMENT_PROCESSOR_OUTPUT_ROOT="${ASSIGNMENT_PROCESSOR_OUTPUT_ROOT:-$RUNTIME_DIR/assignment_work}"
ASSIGNMENT_GENERATION_PROVIDER="${ASSIGNMENT_GENERATION_PROVIDER:-codex}"
ASSIGNMENT_CODEX_BIN="${ASSIGNMENT_CODEX_BIN:-$(command -v codex || true)}"
ASSIGNMENT_CODEX_TIMEOUT_SECONDS="${ASSIGNMENT_CODEX_TIMEOUT_SECONDS:-300}"
ASSIGNMENT_MAX_LINKED_MATERIALS="${ASSIGNMENT_MAX_LINKED_MATERIALS:-8}"

/usr/bin/env python3 "$KLMS_PYTHON_DIR/process_klms_assignments.py" \
  --state-json "$RUNTIME_DIR/state/state.json" \
  --manifest-json "$CACHE_DIR/course_file_manifest.json" \
  --download-log-json "$CACHE_DIR/course_file_download_log.json" \
  --output-root "$ASSIGNMENT_PROCESSOR_OUTPUT_ROOT" \
  --provider "$ASSIGNMENT_GENERATION_PROVIDER" \
  --codex-bin "$ASSIGNMENT_CODEX_BIN" \
  --codex-timeout-seconds "$ASSIGNMENT_CODEX_TIMEOUT_SECONDS" \
  --max-linked-materials "$ASSIGNMENT_MAX_LINKED_MATERIALS" \
  "${PROCESSOR_ARGS[@]}"
