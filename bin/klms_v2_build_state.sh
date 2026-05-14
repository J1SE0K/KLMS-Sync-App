#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMMON_SH="$SCRIPT_DIR/src/sh/klms_common.sh"
source "$COMMON_SH"

klms_parse_entry_args "$@"
klms_init_context "$SCRIPT_DIR/klms_v2_build_state.sh" "$KLMS_ENTRY_CONFIG_ARG"

DETAILS_JSON="${DETAILS_JSON:-$CACHE_DIR/core/details.json}"
NOTICE_DIGEST_JSON="${NOTICE_DIGEST_JSON:-$CACHE_DIR/notice_digest.json}"
OUTPUT_JSON="${OUTPUT_JSON:-$TMP_DIR/v2_state.json}"
OVERRIDES_JSON="${OVERRIDES_JSON_PATH:-$SCRIPT_DIR/manual_assignment_overrides.json}"

override_args=()
if [[ -f "$OVERRIDES_JSON" ]]; then
  override_args=(--overrides-json "$OVERRIDES_JSON")
fi

python3 -m klms_sync_v2.cli build-state \
  --details-json "$DETAILS_JSON" \
  --notice-digest-json "$NOTICE_DIGEST_JSON" \
  --output-json "$OUTPUT_JSON" \
  "${override_args[@]}" \
  --legacy
