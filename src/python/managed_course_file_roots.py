#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
from typing import Any, Iterable


MARKER_FILENAME = ".klms-sync-managed-root.json"
MARKER_SCHEMA_VERSION = 1
IGNORED_MANAGED_FILES = {MARKER_FILENAME, "README.md"}
SYSTEM_ROOT_SYMLINK_ALIASES = {Path("/etc"), Path("/tmp"), Path("/var")}

try:
    from managed_course_file_adoption import validate_adoptable_root
except ModuleNotFoundError:
    from .managed_course_file_adoption import validate_adoptable_root


class ManagedRootError(ValueError):
    pass


def canonical_root(value: str | Path) -> Path:
    path = lexical_absolute_path(value)
    return path.resolve(strict=False)


def lexical_absolute_path(value: str | Path) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = Path.cwd() / path
    return Path(os.path.abspath(path))


def validate_relative_path(value: Any) -> Path:
    text = str(value or "").strip()
    if not text or "\x00" in text or "\\" in text:
        raise ManagedRootError("managed file path must be a non-empty POSIX relative path")
    path = Path(text)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise ManagedRootError(f"managed file path escapes its root: {text}")
    return path


def prepare_managed_root(
    root_value: str | Path,
    purpose: str,
    *,
    approved_roots: Iterable[str | Path] = (),
    protected_roots: Iterable[str | Path] = (),
    adopt_from_manifests: Iterable[str | Path] = (),
    initialize: bool = False,
    allow_unmarked: bool = False,
) -> Path:
    purpose = str(purpose or "").strip()
    if not purpose:
        raise ManagedRootError("managed root purpose is required")
    lexical_root = lexical_absolute_path(root_value)
    _reject_symlink_components(lexical_root)
    root = lexical_root.resolve(strict=False)
    approved = {canonical_root(value) for value in approved_roots}
    protected = default_protected_roots() | {canonical_root(value) for value in protected_roots}
    if root in protected or root == Path(root.anchor):
        raise ManagedRootError(f"refusing protected managed root: {root}")
    if root.exists() and not root.is_dir():
        raise ManagedRootError(f"managed root is not a directory: {root}")
    if root.exists() and root.stat().st_uid != os.getuid():
        raise ManagedRootError(f"managed root is owned by another user: {root}")

    marker = root / MARKER_FILENAME
    if marker.exists() or marker.is_symlink():
        _validate_marker(marker, root, purpose)
        return root
    if allow_unmarked and not initialize:
        return root
    if not initialize:
        raise ManagedRootError(f"managed root marker is missing: {marker}")
    if root.exists() and root not in approved and any(root.iterdir()):
        validate_adoptable_root(root, adopt_from_manifests)

    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(root, 0o700)
    _write_marker(marker, root, purpose)
    return root


def managed_member(root: Path, relative_value: Any, *, must_exist: bool = False) -> Path:
    relative = validate_relative_path(relative_value)
    candidate = root / relative
    _reject_symlink_components(candidate, stop_at=root)
    resolved = candidate.resolve(strict=False)
    if not resolved.is_relative_to(root):
        raise ManagedRootError(f"managed file path escapes its root: {relative.as_posix()}")
    if must_exist:
        metadata = candidate.lstat()
        if not stat.S_ISREG(metadata.st_mode):
            raise ManagedRootError(f"managed file is not a regular file: {candidate}")
    return candidate


def recover_file(source: Path, root: Path, relative_value: Any, recovery_root_value: str | Path) -> dict[str, Any]:
    relative = validate_relative_path(relative_value)
    source = managed_member(root, relative, must_exist=True)
    lexical_recovery_root = lexical_absolute_path(recovery_root_value)
    _reject_symlink_components(lexical_recovery_root)
    recovery_root = lexical_recovery_root.resolve(strict=False)
    if recovery_root == root or recovery_root.is_relative_to(root):
        raise ManagedRootError("recovery root must be outside the managed source root")
    recovery_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if recovery_root.stat().st_uid != os.getuid():
        raise ManagedRootError(f"recovery root is owned by another user: {recovery_root}")
    os.chmod(recovery_root, 0o700)

    destination = _unique_destination(recovery_root / relative)
    _mkdir_private(destination.parent, recovery_root)
    temporary = destination.with_name(f".{destination.name}.partial-{secrets.token_hex(8)}")
    source_descriptor = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    initial = os.fstat(source_descriptor)
    digest = hashlib.sha256()
    try:
        with os.fdopen(source_descriptor, "rb", closefd=True) as source_handle:
            with open(temporary, "xb") as destination_handle:
                os.chmod(temporary, 0o600)
                while chunk := source_handle.read(1024 * 1024):
                    destination_handle.write(chunk)
                    digest.update(chunk)
                destination_handle.flush()
                os.fsync(destination_handle.fileno())
        if temporary.stat().st_size != initial.st_size:
            raise ManagedRootError(f"recovery copy size mismatch: {source}")
        current = source.lstat()
        if (current.st_dev, current.st_ino, current.st_size) != (initial.st_dev, initial.st_ino, initial.st_size):
            raise ManagedRootError(f"managed file changed during recovery copy: {source}")
        os.replace(temporary, destination)
        _fsync_directory(destination.parent)
        source.unlink()
        _fsync_directory(source.parent)
    finally:
        temporary.unlink(missing_ok=True)
    return {
        "recovery_path": str(destination),
        "sha256": digest.hexdigest(),
        "size": initial.st_size,
    }


def default_protected_roots() -> set[Path]:
    home = Path.home().resolve()
    values = {
        Path("/"),
        home,
        home / "Desktop",
        home / "Documents",
        home / "Downloads",
        home / "Library",
        home / "Library" / "Application Support",
    }
    return {path.resolve(strict=False) for path in values}


def _validate_marker(marker: Path, root: Path, purpose: str) -> None:
    metadata = marker.lstat()
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise ManagedRootError(f"managed root marker is not a regular file: {marker}")
    if metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise ManagedRootError(f"managed root marker permissions are unsafe: {marker}")
    try:
        payload = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ManagedRootError(f"managed root marker is invalid: {marker}") from error
    expected = {
        "schemaVersion": MARKER_SCHEMA_VERSION,
        "purpose": purpose,
        "root": str(root),
    }
    if payload != expected:
        raise ManagedRootError(f"managed root marker does not match this root: {marker}")


def _write_marker(marker: Path, root: Path, purpose: str) -> None:
    payload = {
        "schemaVersion": MARKER_SCHEMA_VERSION,
        "purpose": purpose,
        "root": str(root),
    }
    data = (json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n").encode()
    temporary = marker.with_name(f".{marker.name}.partial-{secrets.token_hex(8)}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, marker)
        os.chmod(marker, 0o600)
        _fsync_directory(root)
    finally:
        temporary.unlink(missing_ok=True)


def _reject_symlink_components(path: Path, *, stop_at: Path | None = None) -> None:
    current = path
    while True:
        if current.exists() or current.is_symlink():
            if current.is_symlink() and current not in SYSTEM_ROOT_SYMLINK_ALIASES:
                raise ManagedRootError(f"managed path contains a symlink: {current}")
        if current == stop_at or current == current.parent:
            return
        current = current.parent


def _unique_destination(path: Path) -> Path:
    if not path.exists() and not path.is_symlink():
        return path
    for index in range(2, 10_000):
        candidate = path.with_name(f"{path.stem} {index}{path.suffix}")
        if not candidate.exists() and not candidate.is_symlink():
            return candidate
    raise ManagedRootError(f"could not reserve recovery destination: {path}")


def _mkdir_private(path: Path, boundary: Path) -> None:
    pending: list[Path] = []
    current = path
    while current != boundary:
        pending.append(current)
        current = current.parent
        if not current.is_relative_to(boundary):
            raise ManagedRootError(f"recovery destination escapes its root: {path}")
    for directory in reversed(pending):
        if directory.exists() or directory.is_symlink():
            if directory.is_symlink() or not directory.is_dir():
                raise ManagedRootError(f"unsafe recovery directory: {directory}")
        else:
            directory.mkdir(mode=0o700)
        os.chmod(directory, 0o700)


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--purpose", required=True)
    parser.add_argument("--approved-root", action="append", default=[])
    parser.add_argument("--protected-root", action="append", default=[])
    parser.add_argument("--adopt-from-manifest", action="append", default=[])
    parser.add_argument("--initialize", action="store_true")
    parser.add_argument("--allow-unmarked", action="store_true")
    args = parser.parse_args()
    root = prepare_managed_root(
        args.root,
        args.purpose,
        approved_roots=args.approved_root,
        protected_roots=args.protected_root,
        adopt_from_manifests=args.adopt_from_manifest,
        initialize=args.initialize,
        allow_unmarked=args.allow_unmarked,
    )
    print(json.dumps({"ok": True, "root": str(root), "purpose": args.purpose}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
