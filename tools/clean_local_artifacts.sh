#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DRY_RUN=0
INCLUDE_SWIFT_BUILD=1

usage() {
  cat <<'EOF'
Usage: tools/clean_local_artifacts.sh [--dry-run] [--keep-swift-build]

Removes only regenerable local artifacts:
  - SwiftPM build output under apps/KLMSync/.build
  - Python __pycache__ directories
  - runtime/tmp
  - transient runtime log/html warning files

It intentionally preserves config.env, manual overrides, runtime/state,
runtime/cache JSON state, course_files, and downloaded KLMS files.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --keep-swift-build)
      INCLUDE_SWIFT_BUILD=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      print -u2 -- "Unknown argument: $1"
      usage >&2
      exit 1
      ;;
  esac
done

deleted_count=0

remove_path() {
  local target="$1"
  [[ -e "$target" || -L "$target" ]] || return 0
  case "$target" in
    "$REPO_ROOT"|"$REPO_ROOT/"|"$REPO_ROOT/runtime"|"$REPO_ROOT/runtime/"|"$REPO_ROOT/course_files"|"$REPO_ROOT/course_files/")
      print -u2 -- "Refusing to remove protected path: $target"
      return 1
      ;;
  esac
  if (( DRY_RUN )); then
    print -r -- "would_remove $target"
  else
    rm -rf "$target"
    print -r -- "removed $target"
  fi
  deleted_count=$((deleted_count + 1))
}

if (( INCLUDE_SWIFT_BUILD )); then
  remove_path "$REPO_ROOT/apps/KLMSync/.build"
fi

remove_path "$REPO_ROOT/runtime/tmp"
remove_path "$REPO_ROOT/runtime/cache/notice_native_note_timing.log"
remove_path "$REPO_ROOT/runtime/cache/notice_note_render_warning.txt"
remove_path "$REPO_ROOT/runtime/cache/generated_section.html"

while IFS= read -r pycache_dir; do
  remove_path "$pycache_dir"
done < <(
  find "$REPO_ROOT/src" "$REPO_ROOT/tests" "$REPO_ROOT/runtime/python-packages" \
    -type d -name __pycache__ -prune 2>/dev/null | sort
)

print -r -- "clean_local_artifacts count=$deleted_count dry_run=$DRY_RUN"
