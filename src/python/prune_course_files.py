#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path
import stat
from typing import Any
import unicodedata

from managed_course_file_roots import (
    IGNORED_MANAGED_FILES,
    prepare_managed_root,
    recover_file,
    validate_relative_path,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest-json", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--backup-manifest")
    parser.add_argument("--tracked-relative-paths-json")
    parser.add_argument("--recovery-root")
    parser.add_argument("--maximum-recovery-bytes", type=int)
    parser.add_argument("--root-purpose", default="course-files")
    return parser


def canonical_relative_path(value: str) -> str:
    return unicodedata.normalize("NFC", value).casefold()


def main() -> int:
    args = build_parser().parse_args()
    manifest_path = Path(args.manifest_json)
    root = prepare_managed_root(
        args.root,
        args.root_purpose,
        allow_unmarked=args.dry_run,
    )
    if not args.dry_run and not args.recovery_root:
        raise SystemExit("--recovery-root is required for content-backed pruning")
    if args.maximum_recovery_bytes is not None and args.maximum_recovery_bytes < 1:
        raise SystemExit("--maximum-recovery-bytes must be positive")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, list):
        raise SystemExit(f"Manifest must be a JSON array: {manifest_path}")

    tracked_paths = load_tracked_paths(args, manifest)

    deletion_candidates: list[tuple[Path, dict[str, Any]]] = []
    actual_files_before = 0

    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise SystemExit(f"Refusing to prune a managed root containing a symlink: {path}")
        if path.is_dir():
            continue
        relative_path = path.relative_to(root).as_posix()
        if relative_path in IGNORED_MANAGED_FILES:
            continue
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode):
            raise SystemExit(f"Refusing to prune a non-regular managed entry: {path}")
        actual_files_before += 1
        if canonical_relative_path(relative_path) in tracked_paths:
            continue
        entry: dict[str, Any] = {
            "relative_path": relative_path,
            "absolute_path": str(path),
            "size": metadata.st_size,
            "mtime": metadata.st_mtime,
        }
        deletion_candidates.append((path, entry))

    planned_recovery_bytes = sum(int(entry["size"]) for _path, entry in deletion_candidates)
    if (
        not args.dry_run
        and args.maximum_recovery_bytes is not None
        and planned_recovery_bytes > args.maximum_recovery_bytes
    ):
        raise SystemExit(
            "Refusing to prune because recovery data exceeds --maximum-recovery-bytes "
            f"({planned_recovery_bytes} > {args.maximum_recovery_bytes})"
        )

    deleted_file_entries: list[dict[str, Any]] = []
    for path, entry in deletion_candidates:
        if not args.dry_run:
            entry.update(recover_file(path, root, entry["relative_path"], args.recovery_root))
        deleted_file_entries.append(entry)
    deleted_files = [entry["relative_path"] for entry in deleted_file_entries]

    deleted_dirs: list[str] = []
    if not args.dry_run:
        for directory in sorted((path for path in root.rglob("*") if path.is_dir()), reverse=True):
            try:
                directory.relative_to(root)
            except ValueError:
                continue
            if directory == root:
                continue
            if any(directory.iterdir()):
                continue
            deleted_dirs.append(directory.relative_to(root).as_posix())
            directory.rmdir()

    actual_files_after = sum(
        1
        for path in root.rglob("*")
        if path.is_file() and path.relative_to(root).as_posix() not in IGNORED_MANAGED_FILES
    )

    backup_manifest_path = ""
    if args.backup_manifest:
        backup_path = Path(args.backup_manifest)
        backup_path.parent.mkdir(parents=True, exist_ok=True)
        backup_payload = {
            "manifest_path": str(manifest_path.resolve()),
            "root": str(root),
            "dry_run": args.dry_run,
            "deleted_file_count": len(deleted_files),
            "planned_recovery_bytes": planned_recovery_bytes,
            "deleted_files": deleted_file_entries,
        }
        backup_path.write_text(json.dumps(backup_payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        backup_manifest_path = str(backup_path)

    payload: dict[str, Any] = {
        "manifest_path": str(manifest_path.resolve()),
        "root": str(root),
        "tracked_files": len(tracked_paths),
        "actual_files_before": actual_files_before,
        "actual_files_after": actual_files_after,
        "deleted_files": deleted_files,
        "deleted_file_count": len(deleted_files),
        "planned_recovery_bytes": planned_recovery_bytes,
        "backup_manifest_path": backup_manifest_path,
        "deleted_dirs": deleted_dirs,
        "deleted_dir_count": len(deleted_dirs),
        "dry_run": args.dry_run,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def load_tracked_paths(args: argparse.Namespace, manifest: list[Any]) -> set[str]:
    if args.tracked_relative_paths_json:
        preview_path = Path(args.tracked_relative_paths_json)
        preview = json.loads(preview_path.read_text(encoding="utf-8"))
        values = preview.get("tracked_relative_paths") if isinstance(preview, dict) else None
        if not isinstance(values, list):
            raise SystemExit(f"tracked_relative_paths must be a list: {preview_path}")
        return {
            canonical_relative_path(validate_relative_path(value).as_posix())
            for value in values
            if str(value or "").strip()
        }

    return {
        canonical_relative_path(validate_relative_path(item["relative_path"]).as_posix())
        for item in manifest
        if isinstance(item, dict) and item.get("relative_path")
    }


if __name__ == "__main__":
    raise SystemExit(main())
