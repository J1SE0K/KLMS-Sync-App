#!/usr/bin/env python3

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import shutil
import stat
from typing import TypedDict

try:
    from managed_course_file_roots import lexical_absolute_path, _reject_symlink_components
except ModuleNotFoundError:
    from .managed_course_file_roots import lexical_absolute_path, _reject_symlink_components


BATCH_ENTRY_PATTERN = re.compile(
    r"^(?P<batch>\d{8}-\d{6}(?:-\d+)?)_(?:course_files|archive)(?:\.json)?$"
)


class PruneBackupRetentionError(ValueError):
    pass


@dataclass(frozen=True)
class BackupBatch:
    key: str
    entries: tuple[Path, ...]
    size_bytes: int
    modified_ns: int


class PruneBackupRetentionResult(TypedDict):
    enabled: bool
    dry_run: bool
    keep_batches: int
    maximum_bytes: int
    reserve_bytes: int
    managed_bytes_before: int
    managed_bytes_after: int
    over_limit: bool
    kept_batches: list[str]
    removed_batches: list[str]
    removed_bytes: int


def apply_retention(
    backup_root_value: str | Path,
    *,
    enabled: bool,
    keep_batches: int,
    maximum_bytes: int,
    reserve_bytes: int = 0,
    dry_run: bool = False,
) -> PruneBackupRetentionResult:
    if enabled and keep_batches < 1:
        raise PruneBackupRetentionError("enabled recovery retention must keep at least one batch")
    if maximum_bytes < 1:
        raise PruneBackupRetentionError("recovery retention maximum bytes must be positive")
    if reserve_bytes < 0 or reserve_bytes > maximum_bytes:
        raise PruneBackupRetentionError("recovery retention reserve exceeds its byte limit")

    lexical_root = lexical_absolute_path(backup_root_value)
    _reject_symlink_components(lexical_root)
    root = lexical_root.resolve(strict=False)
    if root.exists() and not root.is_dir():
        raise PruneBackupRetentionError(f"recovery backup root is not a directory: {root}")
    if not root.exists() and not dry_run:
        root.mkdir(parents=True, mode=0o700)
    if root.exists():
        metadata = root.stat()
        if metadata.st_uid != os.getuid():
            raise PruneBackupRetentionError(f"recovery backup root is owned by another user: {root}")
        if not dry_run:
            os.chmod(root, 0o700)

    batches = _collect_batches(root) if root.exists() else []
    available_bytes = maximum_bytes - reserve_bytes
    kept: list[BackupBatch] = []
    removed: list[BackupBatch] = []
    kept_bytes = 0
    for batch in sorted(batches, key=lambda item: (item.modified_ns, item.key), reverse=True):
        within_count = enabled and len(kept) < keep_batches
        within_bytes = kept_bytes + batch.size_bytes <= available_bytes
        keep_oversized_newest = enabled and not kept and reserve_bytes == 0
        if within_count and (within_bytes or keep_oversized_newest):
            kept.append(batch)
            kept_bytes += batch.size_bytes
        else:
            removed.append(batch)

    if not dry_run:
        for batch in removed:
            for entry in batch.entries:
                _remove_validated_entry(entry)

    removed_bytes = sum(batch.size_bytes for batch in removed)
    return {
        "enabled": enabled,
        "dry_run": dry_run,
        "keep_batches": keep_batches if enabled else 0,
        "maximum_bytes": maximum_bytes,
        "reserve_bytes": reserve_bytes,
        "managed_bytes_before": kept_bytes + removed_bytes,
        "managed_bytes_after": kept_bytes,
        "over_limit": kept_bytes + reserve_bytes > maximum_bytes,
        "kept_batches": [batch.key for batch in kept],
        "removed_batches": [batch.key for batch in removed],
        "removed_bytes": removed_bytes,
    }


def _collect_batches(root: Path) -> list[BackupBatch]:
    grouped: dict[str, list[Path]] = {}
    for entry in root.iterdir():
        match = BATCH_ENTRY_PATTERN.fullmatch(entry.name)
        if match:
            grouped.setdefault(match.group("batch"), []).append(entry)
    batches: list[BackupBatch] = []
    for key, entries in grouped.items():
        size_bytes = 0
        modified_ns = 0
        for entry in entries:
            size_bytes += _validated_entry_size(entry)
            modified_ns = max(modified_ns, entry.lstat().st_mtime_ns)
        batches.append(
            BackupBatch(
                key=key,
                entries=tuple(sorted(entries)),
                size_bytes=size_bytes,
                modified_ns=modified_ns,
            )
        )
    return batches


def _validated_entry_size(entry: Path) -> int:
    metadata = entry.lstat()
    if stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise PruneBackupRetentionError(f"unsafe recovery backup entry: {entry}")
    if stat.S_ISREG(metadata.st_mode):
        return metadata.st_size
    if not stat.S_ISDIR(metadata.st_mode):
        raise PruneBackupRetentionError(f"unsupported recovery backup entry: {entry}")
    total = 0
    for child in entry.rglob("*"):
        child_metadata = child.lstat()
        if stat.S_ISLNK(child_metadata.st_mode) or child_metadata.st_uid != os.getuid():
            raise PruneBackupRetentionError(f"unsafe recovery backup entry: {child}")
        if stat.S_ISREG(child_metadata.st_mode):
            total += child_metadata.st_size
        elif not stat.S_ISDIR(child_metadata.st_mode):
            raise PruneBackupRetentionError(f"unsupported recovery backup entry: {child}")
    return total


def _remove_validated_entry(entry: Path) -> None:
    _validated_entry_size(entry)
    if entry.is_dir():
        shutil.rmtree(entry)
    else:
        entry.unlink()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--backup-root", required=True)
    parser.add_argument("--enabled", action="store_true")
    parser.add_argument("--keep-batches", required=True, type=int)
    parser.add_argument("--maximum-bytes", required=True, type=int)
    parser.add_argument("--reserve-bytes", type=int, default=0)
    parser.add_argument("--dry-run", action="store_true")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    payload = apply_retention(
        args.backup_root,
        enabled=args.enabled,
        keep_batches=args.keep_batches,
        maximum_bytes=args.maximum_bytes,
        reserve_bytes=args.reserve_bytes,
        dry_run=args.dry_run,
    )
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
