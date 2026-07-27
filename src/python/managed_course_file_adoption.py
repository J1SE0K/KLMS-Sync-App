from __future__ import annotations

import json
import os
from pathlib import Path
import stat
from typing import Any, Iterable
import unicodedata


ADOPTION_IGNORED_FILES = {
    ".klms-sync-managed-root.json",
    "README.md",
    ".DS_Store",
}
ADOPTION_MANIFEST_PATH_FIELDS = (
    "relative_path",
    "downloads_relative_path",
    "manifest_relative_path",
)
MAX_ADOPTION_MANIFEST_BYTES = 64 * 1024 * 1024


def validate_adoptable_root(root: Path, manifest_values: Iterable[str | Path]) -> None:
    (
        ManagedRootError,
        lexical_absolute_path,
        validate_relative_path,
        reject_symlink_components,
    ) = _root_dependencies()
    tracked_paths: set[str] = set()
    loaded_manifest = False
    for manifest_value in manifest_values:
        manifest_path = lexical_absolute_path(manifest_value)
        if not manifest_path.exists() and not manifest_path.is_symlink():
            continue
        loaded_manifest = True
        tracked_paths.update(
            _tracked_paths_from_adoption_manifest(
                manifest_path,
                ManagedRootError=ManagedRootError,
                validate_relative_path=validate_relative_path,
                reject_symlink_components=reject_symlink_components,
            )
        )
    if not loaded_manifest:
        raise ManagedRootError(f"refusing to claim non-empty unmarked root without a prior manifest: {root}")

    for path in root.rglob("*"):
        if path.is_symlink():
            raise ManagedRootError(f"refusing to claim a managed root containing a symlink: {path}")
        metadata = path.lstat()
        if metadata.st_uid != os.getuid():
            raise ManagedRootError(f"managed root entry is owned by another user: {path}")
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise ManagedRootError(f"managed root contains a non-regular entry: {path}")
        relative_path = path.relative_to(root).as_posix()
        if relative_path in ADOPTION_IGNORED_FILES:
            continue
        if _canonical_adoption_path(relative_path) not in tracked_paths:
            raise ManagedRootError(f"refusing to claim untracked file in managed root: {path}")


def _tracked_paths_from_adoption_manifest(
    manifest_path: Path,
    *,
    ManagedRootError: type[ValueError],
    validate_relative_path: Any,
    reject_symlink_components: Any,
) -> set[str]:
    reject_symlink_components(manifest_path)
    metadata = manifest_path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise ManagedRootError(f"adoption manifest is not a regular file: {manifest_path}")
    if metadata.st_uid != os.getuid():
        raise ManagedRootError(f"adoption manifest is owned by another user: {manifest_path}")
    if metadata.st_size > MAX_ADOPTION_MANIFEST_BYTES:
        raise ManagedRootError(f"adoption manifest is too large: {manifest_path}")
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ManagedRootError(f"adoption manifest is invalid: {manifest_path}") from error
    if isinstance(payload, list):
        entries = payload
    elif isinstance(payload, dict) and isinstance(payload.get("results"), list):
        entries = payload["results"]
    else:
        raise ManagedRootError(f"adoption manifest has an unsupported shape: {manifest_path}")

    tracked_paths: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        for field in ADOPTION_MANIFEST_PATH_FIELDS:
            value = str(entry.get(field) or "").strip()
            if value:
                tracked_paths.add(_canonical_adoption_path(validate_relative_path(value).as_posix()))
    return tracked_paths


def _canonical_adoption_path(value: str) -> str:
    return unicodedata.normalize("NFC", value).casefold()


def _root_dependencies() -> tuple[type[ValueError], Any, Any, Any]:
    try:
        from managed_course_file_roots import (
            ManagedRootError,
            _reject_symlink_components,
            lexical_absolute_path,
            validate_relative_path,
        )
    except ModuleNotFoundError:
        from .managed_course_file_roots import (
            ManagedRootError,
            _reject_symlink_components,
            lexical_absolute_path,
            validate_relative_path,
        )
    return (
        ManagedRootError,
        lexical_absolute_path,
        validate_relative_path,
        _reject_symlink_components,
    )
