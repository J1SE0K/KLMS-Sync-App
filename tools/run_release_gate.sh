#!/bin/zsh

set -euo pipefail
umask 077

if (( $# < 3 )) || [[ "$2" != "--" ]]; then
  print -ru2 -- "usage: tools/run_release_gate.sh <gate-id> -- <command> [args...]"
  exit 64
fi

GATE_ID="$1"
shift 2
case "$GATE_ID" in
  ""|*[!a-z0-9-]*|-*|*-|*--*)
    print -ru2 -- "gate id must contain lowercase letters, digits, and single hyphens"
    exit 64
    ;;
esac

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
EVIDENCE_DIR="${KLMS_RELEASE_EVIDENCE_DIR:-${TMPDIR:-/private/tmp}/klms-release-evidence}"
mkdir -p "$EVIDENCE_DIR"
chmod 700 "$EVIDENCE_DIR"

if ! CANDIDATE="$(git -C "$ROOT_DIR" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
    || [[ ${#CANDIDATE} -ne 40 ]] \
    || [[ "$CANDIDATE" == *[^0-9a-f]* ]]; then
  print -ru2 -- "gate-evidence-summary status=fail gate=${GATE_ID} reason=invalid-git-candidate"
  exit 70
fi
if ! WORKTREE_STATUS="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all 2>/dev/null)"; then
  print -ru2 -- "gate-evidence-summary status=fail gate=${GATE_ID} reason=git-status-unavailable"
  exit 70
fi
if [[ -n "$WORKTREE_STATUS" ]]; then
  print -ru2 -- "gate-evidence-summary status=fail gate=${GATE_ID} candidate=${CANDIDATE} reason=dirty-worktree"
  exit 70
fi

TEMP_LOG="$(mktemp "$EVIDENCE_DIR/.${GATE_ID}.XXXXXX")"
FINAL_LOG="$EVIDENCE_DIR/${GATE_ID}.log"
cleanup_gate_log() {
  rm -f "$TEMP_LOG"
}
trap cleanup_gate_log EXIT

print -r -- "gate-evidence schema=1 gate=${GATE_ID} candidate=${CANDIDATE} started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  | tee "$TEMP_LOG"
set +e
"$@" 2>&1 | tee -a "$TEMP_LOG"
COMMAND_STATUS=${pipestatus[1]}
set -e

FINAL_CANDIDATE=""
FINAL_WORKTREE_STATUS="invalid"
if FINAL_CANDIDATE="$(git -C "$ROOT_DIR" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
    && FINAL_WORKTREE_STATUS="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all 2>/dev/null)" \
    && [[ "$FINAL_CANDIDATE" == "$CANDIDATE" ]] \
    && [[ -z "$FINAL_WORKTREE_STATUS" ]] \
    && (( COMMAND_STATUS == 0 )); then
  print -r -- "gate-evidence-summary status=pass gate=${GATE_ID} candidate=${CANDIDATE} exit=0" \
    | tee -a "$TEMP_LOG"
  mv -f "$TEMP_LOG" "$FINAL_LOG"
  trap - EXIT
  chmod 600 "$FINAL_LOG"
  exit 0
fi

print -r -- "gate-evidence-summary status=fail gate=${GATE_ID} candidate=${CANDIDATE} exit=${COMMAND_STATUS}" \
  | tee -a "$TEMP_LOG"
mv -f "$TEMP_LOG" "$FINAL_LOG"
trap - EXIT
chmod 600 "$FINAL_LOG"
if (( COMMAND_STATUS == 0 )); then
  exit 70
fi
exit "$COMMAND_STATUS"
