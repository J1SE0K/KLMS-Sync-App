#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path, PurePosixPath
from typing import Any


def fail(message: str) -> None:
    raise SystemExit(f"engine-payload-summary status=fail reason={message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_allowlist(path: Path) -> set[str]:
    entries: set[str] = set()
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        entry = raw_line.strip()
        if not entry:
            continue
        relative = PurePosixPath(entry)
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or relative.as_posix() != entry
            or "\\" in entry
            or entry in entries
        ):
            fail(f"invalid-allowlist-line-{line_number}")
        entries.add(entry)
    if not entries:
        fail("empty-allowlist")
    return entries


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        fail("invalid-manifest")
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 2:
        fail("unsupported-manifest")
    return payload


def main() -> None:
    parser = argparse.ArgumentParser(description="Verify a packaged KLMS engine payload.")
    parser.add_argument("payload", type=Path)
    parser.add_argument("--allowlist", required=True, type=Path)
    parser.add_argument("--python-allowlist", required=True, type=Path)
    parser.add_argument("--expected-revision")
    parser.add_argument("--require-clean", action="store_true")
    parser.add_argument("--json", action="store_true", dest="json_output")
    args = parser.parse_args()

    payload_root = args.payload.resolve()
    allowlist_path = args.allowlist.resolve()
    python_allowlist_path = args.python_allowlist.resolve()
    if not payload_root.is_dir() or not allowlist_path.is_file() or not python_allowlist_path.is_file():
        fail("missing-input")

    allowlist = load_allowlist(allowlist_path)
    python_allowlist = load_allowlist(python_allowlist_path)
    manifest_path = payload_root / "EnginePayloadManifest.json"
    manifest = load_manifest(manifest_path)
    version_path = payload_root / "EnginePayloadVersion.txt"
    try:
        payload_version = version_path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        fail("missing-version")
    if not payload_version or manifest.get("payloadVersion") != payload_version:
        fail("version-mismatch")

    source_revision = manifest.get("sourceRevision")
    dirty = manifest.get("dirty")
    if not isinstance(source_revision, str) or not re.fullmatch(r"[0-9a-f]{40}", source_revision):
        fail("missing-source-revision")
    if not isinstance(dirty, bool):
        fail("invalid-dirty-flag")
    if args.expected_revision and source_revision != args.expected_revision:
        fail("source-revision-mismatch")
    if args.require_clean and dirty:
        fail("dirty-payload")
    if dirty:
        if not payload_version.startswith(f"{source_revision}-dirty-"):
            fail("dirty-version-mismatch")
    elif payload_version != source_revision:
        fail("clean-version-mismatch")
    if manifest.get("allowlistSHA256") != sha256(allowlist_path):
        fail("allowlist-digest-mismatch")
    if manifest.get("pythonAllowlistSHA256") != sha256(python_allowlist_path):
        fail("python-allowlist-digest-mismatch")

    actual_files: dict[str, Path] = {}
    for candidate in sorted(payload_root.rglob("*")):
        if candidate.is_symlink():
            fail("symlink-present")
        if not candidate.is_file() or candidate == manifest_path:
            continue
        relative = candidate.relative_to(payload_root).as_posix()
        if relative.endswith(".pyc") or "__pycache__" in PurePosixPath(relative).parts:
            fail("cache-artifact-present")
        actual_files[relative] = candidate

    expected_files = {
        *allowlist,
        *(f"python-packages/{relative}" for relative in python_allowlist),
        "EnginePayloadVersion.txt",
    }
    missing = sorted(expected_files - actual_files.keys())
    if missing:
        fail(f"allowlisted-file-missing-{missing[0]}")
    unexpected = sorted(actual_files.keys() - expected_files)
    if unexpected:
        fail(f"unexpected-file-{unexpected[0]}")

    raw_entries = manifest.get("files")
    if not isinstance(raw_entries, list):
        fail("invalid-file-inventory")
    manifest_entries: dict[str, dict[str, Any]] = {}
    for entry in raw_entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            fail("invalid-file-entry")
        relative = entry["path"]
        if relative in manifest_entries:
            fail("duplicate-file-entry")
        if (
            relative not in actual_files
            or not isinstance(entry.get("bytes"), int)
            or entry["bytes"] < 0
            or not isinstance(entry.get("sha256"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])
        ):
            fail("invalid-file-entry")
        manifest_entries[relative] = entry
    if manifest_entries.keys() != actual_files.keys():
        fail("inventory-path-mismatch")

    total_bytes = 0
    for relative, path in actual_files.items():
        entry = manifest_entries[relative]
        size = path.stat().st_size
        total_bytes += size
        if entry.get("bytes") != size or entry.get("sha256") != sha256(path):
            fail(f"inventory-digest-mismatch-{relative}")
    if manifest.get("fileCount") != len(actual_files):
        fail("file-count-mismatch")
    if manifest.get("totalBytes") != total_bytes:
        fail("byte-count-mismatch")

    required_vendor = [
        payload_root / "python-packages" / "bs4" / "__init__.py",
        payload_root / "python-packages" / "soupsieve" / "__init__.py",
        payload_root / "python-packages" / "typing_extensions.py",
    ]
    if not all(path.is_file() for path in required_vendor):
        fail("missing-python-runtime")

    summary = {
        "schemaVersion": 1,
        "status": "pass",
        "candidate": source_revision,
        "dirty": dirty,
        "fileCount": len(actual_files),
        "totalBytes": total_bytes,
        "payloadVersion": payload_version,
    }
    if args.json_output:
        print(json.dumps(summary, sort_keys=True))
    else:
        print(
            "engine-payload-summary"
            " status=pass"
            f" candidate={source_revision}"
            f" dirty={str(dirty).lower()}"
            f" files={len(actual_files)}"
            f" bytes={total_bytes}"
        )


if __name__ == "__main__":
    main()
