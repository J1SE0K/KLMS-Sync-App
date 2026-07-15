#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET_WAS_EXPLICIT=0
if (( ${+KLMS_RUNTIME_TMP_CLEANUP_TARGET} )); then
  TARGET_WAS_EXPLICIT=1
fi
TMP_DIR="${KLMS_RUNTIME_TMP_CLEANUP_TARGET:-$SCRIPT_DIR/runtime/tmp}"
MAX_AGE_HOURS=""
MANAGED_ROOT=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-age-hours)
      MAX_AGE_HOURS="${2:-}"
      shift 2
      ;;
    --managed-root)
      MANAGED_ROOT=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      print -u2 -- "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# Calling the script directly targets runtime/tmp, so default to the guarded
# managed-root policy. Explicit namespace targets keep the legacy scoped mode.
if (( ! TARGET_WAS_EXPLICIT )); then
  MANAGED_ROOT=1
fi

python3 - "$TMP_DIR" "$MAX_AGE_HOURS" "$MANAGED_ROOT" "$DRY_RUN" "$SCRIPT_DIR" <<'PY'
from __future__ import annotations

import fnmatch
import math
import shutil
import sys
import time
from pathlib import Path

raw_tmp_dir = Path(sys.argv[1]).expanduser()
if raw_tmp_dir.is_symlink():
    raise SystemExit(f"invalid cleanup target: {raw_tmp_dir}")
tmp_dir = raw_tmp_dir.resolve(strict=False)
max_age_hours_raw = sys.argv[2] if len(sys.argv) > 2 else ""
managed_root = sys.argv[3] == "1"
dry_run = sys.argv[4] == "1"
repo_root = Path(sys.argv[5]).resolve(strict=False)

protected_roots = {
    Path("/").resolve(),
    Path.home().resolve(),
    repo_root,
    repo_root / "runtime",
    repo_root / "course_files",
}
if tmp_dir in protected_roots:
    raise SystemExit(f"refusing protected cleanup target: {tmp_dir}")
if tmp_dir.exists() and (tmp_dir.is_symlink() or not tmp_dir.is_dir()):
    raise SystemExit(f"invalid cleanup target: {tmp_dir}")
if not tmp_dir.exists():
    if dry_run:
        print(f"cleanup_runtime_tmp target_missing={tmp_dir} dry_run=1")
        raise SystemExit(0)
    tmp_dir.mkdir(parents=True)

max_age_hours = None
if max_age_hours_raw:
    try:
        max_age_hours = float(max_age_hours_raw)
    except ValueError as error:
        raise SystemExit("invalid --max-age-hours") from error
    if not math.isfinite(max_age_hours) or max_age_hours < 0:
        raise SystemExit("invalid --max-age-hours")
cutoff_epoch = None if max_age_hours is None else time.time() - (max_age_hours * 3600)

managed_namespaces = {"all", "core", "files", "notice", "shared"}
remove_names = {
    ".DS_Store",
    "__pycache__",
    "pycache",
    "swift-module-cache",
    "download_test_archive",
    "download_test_output",
    "download_backups",
}

remove_globs = [
    "*.pyc",
    "*.pyo",
    "*-urls.txt",
    "*test*.txt",
    "dashboard_urls.txt",
    "file_nested*_urls*.txt",
    "file_seed_changed_urls.txt",
    "file_nested_changed_urls.txt",
    "klms_login_preflight_urls.txt",
    "klms_single_manifest.json",
    "nano_quiz_pages.json",
    "notice_digest_note.html",
    "notice_note_title.txt",
    "seen_urls.txt",
    "seen_round2_urls.txt",
    "notice_user_state.json",
    "notice_note_render_state.json",
    "test_generated_section.html",
    "verify*_notice_render_state.json",
    "verify*_notice_user_state.json",
    "verify_http_dashboard*.json",
    "*test*.json",
    "direct_fetch_test.json",
    "db_*_live.json",
    "abs_test_dashboard.json",
]


def matches_generated_name(path: Path) -> bool:
    return path.name in remove_names or any(
        fnmatch.fnmatch(path.name, pattern) for pattern in remove_globs
    )


def descendants(root: Path) -> list[Path]:
    if root.is_symlink() or not root.is_dir():
        return []
    return list(root.rglob("*"))


preserved_unknown: list[Path] = []
scan_roots: list[Path] = []
exact_root_candidates: list[Path] = []

if managed_root:
    for child in sorted(tmp_dir.iterdir(), key=lambda path: path.name):
        if child.name in managed_namespaces and child.is_dir() and not child.is_symlink():
            scan_roots.append(child)
        elif matches_generated_name(child):
            exact_root_candidates.append(child)
        else:
            preserved_unknown.append(child)
else:
    scan_roots.append(tmp_dir)

candidates: set[Path] = set(exact_root_candidates)
for scan_root in scan_roots:
    for path in descendants(scan_root):
        if matches_generated_name(path):
            candidates.add(path)
            continue
        if cutoff_epoch is None:
            continue
        try:
            modified_epoch = path.lstat().st_mtime
        except FileNotFoundError:
            continue
        if modified_epoch < cutoff_epoch:
            candidates.add(path)

# A directory may only be deleted by the age policy when every surviving child
# is also a candidate. This avoids removing a fresh file through an old parent.
for path in sorted(candidates, key=lambda item: len(item.parts), reverse=True):
    if not path.is_dir() or path.is_symlink() or matches_generated_name(path):
        continue
    try:
        children = list(path.iterdir())
    except FileNotFoundError:
        continue
    if any(child not in candidates for child in children):
        candidates.discard(path)

for path in preserved_unknown:
    print(f"preserved_unknown {path}")

deleted_files = 0
deleted_dirs = 0
failed = 0
for path in sorted(candidates, key=lambda item: (len(item.parts), str(item)), reverse=True):
    if not path.exists() and not path.is_symlink():
        continue
    if dry_run:
        print(f"would_remove {path}")
        continue
    try:
        if path.is_symlink() or not path.is_dir():
            path.unlink()
            deleted_files += 1
        elif matches_generated_name(path):
            shutil.rmtree(path)
            deleted_dirs += 1
        else:
            path.rmdir()
            deleted_dirs += 1
        print(f"removed {path}")
    except FileNotFoundError:
        continue
    except OSError as error:
        failed += 1
        print(f"remove_failed {path}: {error}", file=sys.stderr)

# Remove empty generated subdirectories left by name-based cleanup, but never
# remove the target itself or a managed top-level namespace.
for scan_root in scan_roots:
    for path in sorted(descendants(scan_root), key=lambda item: len(item.parts), reverse=True):
        if path in candidates or path.is_symlink() or not path.is_dir():
            continue
        try:
            next(path.iterdir())
        except StopIteration:
            if dry_run:
                print(f"would_remove_empty {path}")
            else:
                try:
                    path.rmdir()
                    deleted_dirs += 1
                    print(f"removed_empty {path}")
                except OSError as error:
                    failed += 1
                    print(f"remove_failed {path}: {error}", file=sys.stderr)
        except (FileNotFoundError, NotADirectoryError):
            pass

print(
    "cleanup_runtime_tmp "
    f"deleted_files={deleted_files} deleted_dirs={deleted_dirs} "
    f"preserved_unknown={len(preserved_unknown)} failed={failed} "
    f"managed_root={int(managed_root)} dry_run={int(dry_run)}"
)
if failed:
    raise SystemExit(1)
PY
