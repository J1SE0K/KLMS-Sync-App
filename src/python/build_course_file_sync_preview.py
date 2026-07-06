#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import unicodedata
from pathlib import Path
from typing import Any


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest-json", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--download-log-json", required=True)
    parser.add_argument("--download-archive-root", required=True)
    parser.add_argument("--output-json", required=True)
    return parser


def main_with_args(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    manifest_path = Path(args.manifest_json)
    output_root = Path(args.output_root).expanduser().resolve()
    download_log_path = Path(args.download_log_json).expanduser().resolve()
    archive_root = Path(args.download_archive_root).expanduser().resolve()
    output_path = Path(args.output_json).expanduser().resolve()

    manifest = load_json(manifest_path, [])
    if not isinstance(manifest, list):
        raise SystemExit(f"Manifest must be a JSON array: {manifest_path}")

    previous_results = previous_download_results(download_log_path)
    previous_by_url = {
        normalized_url(item.get("url")): item
        for item in previous_results
        if normalized_url(item.get("url"))
    }

    actual_files = current_output_files(output_root)

    tracked_paths: dict[str, str] = {}
    new_url_entries: list[dict[str, Any]] = []
    moved_entries: list[dict[str, Any]] = []
    local_missing_entries: list[dict[str, Any]] = []
    recoverable_missing_entries: list[dict[str, Any]] = []
    fresh_download_candidates: list[dict[str, Any]] = []
    timestamp_refresh_candidates: list[dict[str, Any]] = []
    type_mismatch_candidates: list[dict[str, Any]] = []

    for item in manifest:
        if not isinstance(item, dict):
            continue
        relative_path = str(item.get("relative_path") or "").strip()
        filename = str(item.get("filename") or Path(relative_path).name).strip()
        url = normalized_url(item.get("url"))
        previous = previous_by_url.get(url) if url else None
        effective_relative_path = effective_entry_relative_path(item, previous)
        if effective_relative_path:
            tracked_paths[canonical_relative_path(effective_relative_path)] = effective_relative_path

        if previous is not None:
            previous_relative_path = str(previous.get("relative_path") or "").strip()
            if previous_relative_path and canonical_relative_path(previous_relative_path) != canonical_relative_path(effective_relative_path):
                moved_entries.append(
                    {
                        **compact_entry(item, effective_relative_path),
                        "previous_relative_path": previous_relative_path,
                    }
                )

            previous_filename = str(
                previous.get("filename")
                or previous.get("downloads_filename")
                or Path(str(previous.get("destination_path") or "")).name
            ).strip()
            if previous_filename and not filename_compatible(previous_filename, filename):
                type_mismatch_candidates.append(
                    {
                        **compact_entry(item, effective_relative_path),
                        "previous_filename": previous_filename,
                    }
                )

        if effective_relative_path:
            output_path_for_entry = output_root / Path(effective_relative_path)
            archive_path_for_entry = archive_root / Path(effective_relative_path)
            reusable_relative_paths = reusable_entry_relative_paths(
                effective_relative_path,
                previous,
            )
            reusable_paths = [
                root / Path(relative_path)
                for relative_path in reusable_relative_paths
                for root in (output_root, archive_root)
            ]
            reusable_existing_paths = [
                path
                for path in [archive_path_for_entry, *reusable_paths]
                if path.is_file()
            ]
            if url and previous is None and not output_path_for_entry.is_file():
                new_url_entries.append(compact_entry(item, effective_relative_path))
            if not output_path_for_entry.is_file():
                missing_entry = {
                    **compact_entry(item, effective_relative_path),
                    "expected_path": str(output_path_for_entry),
                    "recovery_source_path": str(reusable_existing_paths[0]) if reusable_existing_paths else "",
                }
                local_missing_entries.append(missing_entry)
                if reusable_existing_paths:
                    recoverable_missing_entries.append(missing_entry)
                else:
                    fresh_download_candidates.append(missing_entry)
            elif existing_file_needs_timestamp_refresh(item, output_path_for_entry, previous):
                timestamp_refresh_candidates.append(
                    {
                        **compact_entry(item, effective_relative_path),
                        "expected_path": str(output_path_for_entry),
                        "previous_klms_timestamp_epoch": str(normalized_epoch((previous or {}).get("klms_timestamp_epoch"))),
                        "current_klms_timestamp_epoch": str(normalized_epoch(item.get("klms_timestamp_epoch"))),
                    }
                )

    prune_candidates = sorted(
        relative_path
        for canonical, relative_path in actual_files.items()
        if canonical not in tracked_paths
    )

    payload = {
        "manifest_path": str(manifest_path.resolve()),
        "output_root": str(output_root),
        "download_log_path": str(download_log_path),
        "download_archive_root": str(archive_root),
        "manifest_count": len(manifest),
        "actual_file_count": len(actual_files),
        "new_url_count": len(new_url_entries),
        "moved_count": len(moved_entries),
        "local_missing_count": len(local_missing_entries),
        "recoverable_missing_count": len(recoverable_missing_entries),
        "fresh_download_candidate_count": len(fresh_download_candidates),
        "timestamp_refresh_candidate_count": len(timestamp_refresh_candidates),
        "prune_candidate_count": len(prune_candidates),
        "type_mismatch_candidate_count": len(type_mismatch_candidates),
        "tracked_relative_paths": sorted(tracked_paths.values()),
        "new_url_entries": new_url_entries,
        "moved_entries": moved_entries,
        "local_missing_entries": local_missing_entries,
        "recoverable_missing_entries": recoverable_missing_entries,
        "fresh_download_candidates": fresh_download_candidates,
        "timestamp_refresh_candidates": timestamp_refresh_candidates,
        "prune_candidates": prune_candidates,
        "type_mismatch_candidates": type_mismatch_candidates,
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(
        "file-preview "
        f"manifest={payload['manifest_count']} "
        f"new_urls={payload['new_url_count']} "
        f"moved={payload['moved_count']} "
        f"local_missing={payload['local_missing_count']} "
        f"recoverable_missing={payload['recoverable_missing_count']} "
        f"fresh_download_candidates={payload['fresh_download_candidate_count']} "
        f"timestamp_refresh_candidates={payload['timestamp_refresh_candidate_count']} "
        f"prune_candidates={payload['prune_candidate_count']} "
        f"type_mismatch_candidates={payload['type_mismatch_candidate_count']}"
    )
    return 0


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def previous_download_results(path: Path) -> list[dict[str, Any]]:
    payload = load_json(path, {})
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict) and isinstance(payload.get("results"), list):
        return [item for item in payload["results"] if isinstance(item, dict)]
    return []


def current_output_files(root: Path) -> dict[str, str]:
    if not root.exists():
        return {}
    files: dict[str, str] = {}
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        relative_path = path.relative_to(root).as_posix()
        if relative_path in {"README.md", ".DS_Store"}:
            continue
        files[canonical_relative_path(relative_path)] = relative_path
    return files


def normalized_epoch(value: Any) -> int:
    try:
        epoch = int(float(value or 0))
    except Exception:
        return 0
    return epoch if epoch > 0 else 0


def file_mtime_epoch(path: Path) -> int:
    try:
        return int(path.stat().st_mtime)
    except Exception:
        return 0


def epochs_match(left: int, right: int) -> bool:
    return left > 0 and right > 0 and abs(left - right) <= 1


def existing_file_needs_timestamp_refresh(
    item: dict[str, Any],
    output_path: Path,
    previous: dict[str, Any] | None,
) -> bool:
    current_epoch = normalized_epoch(item.get("klms_timestamp_epoch"))
    if current_epoch <= 0:
        return False

    previous_epoch = normalized_epoch((previous or {}).get("klms_timestamp_epoch"))
    if epochs_match(current_epoch, previous_epoch):
        return False

    local_epoch = file_mtime_epoch(output_path)
    if epochs_match(current_epoch, local_epoch):
        return False

    if previous_epoch > 0:
        return current_epoch > previous_epoch + 1
    if local_epoch > 0:
        return current_epoch > local_epoch + 1
    return False


def compact_entry(item: dict[str, Any], effective_relative_path: str = "") -> dict[str, str]:
    return {
        "course": str(item.get("course") or ""),
        "filename": str(item.get("filename") or ""),
        "relative_path": str(item.get("relative_path") or ""),
        "effective_relative_path": effective_relative_path or str(item.get("relative_path") or ""),
        "url": str(item.get("url") or ""),
        "source_url": str(item.get("source_url") or ""),
    }


def effective_entry_relative_path(item: dict[str, Any], previous: dict[str, Any] | None) -> str:
    manifest_relative_path = str(item.get("relative_path") or item.get("filename") or "").strip()
    manifest_filename = str(item.get("filename") or Path(manifest_relative_path).name).strip()
    relative_dir = Path(manifest_relative_path).parent.as_posix()
    if relative_dir == ".":
        relative_dir = ""

    previous_filename = ""
    if previous is not None:
        previous_filename = str(
            previous.get("filename")
            or previous.get("downloads_filename")
            or Path(str(previous.get("destination_path") or "")).name
        ).strip()

    active_filename = (
        previous_filename
        if previous_filename and filename_compatible(previous_filename, manifest_filename)
        else manifest_filename
    )
    if not active_filename:
        return manifest_relative_path
    return str(Path(relative_dir) / active_filename) if relative_dir else active_filename


def reusable_entry_relative_paths(
    effective_relative_path: str,
    previous: dict[str, Any] | None,
) -> list[str]:
    paths: list[str] = []
    if previous is not None:
        for field in ("relative_path", "downloads_relative_path", "manifest_relative_path"):
            value = str(previous.get(field) or "").strip()
            if value:
                paths.append(value)

    seen: set[str] = set()
    unique_paths: list[str] = []
    effective_canonical = canonical_relative_path(effective_relative_path)
    for path in paths:
        canonical = canonical_relative_path(path)
        if not canonical or canonical == effective_canonical or canonical in seen:
            continue
        seen.add(canonical)
        unique_paths.append(path)
    return unique_paths


def canonical_relative_path(value: Any) -> str:
    return unicodedata.normalize("NFC", str(value or "").strip()).casefold()


def normalized_url(value: Any) -> str:
    text = str(value or "").strip()
    return (
        text.replace("forcedownload=1&", "")
        .replace("&forcedownload=1", "")
        .replace("?forcedownload=1", "")
        .rstrip("?&")
    )


def filename_compatible(actual: str, expected: str) -> bool:
    if not actual:
        return False
    if not expected or actual == expected:
        return True
    actual_family = extension_family(Path(actual).suffix.lower())
    expected_family = extension_family(Path(expected).suffix.lower())
    if not actual_family or not expected_family:
        return True
    return actual_family == expected_family


def extension_family(extension: str) -> str:
    if extension in {".ppt", ".pptx"}:
        return "presentation"
    if extension in {".doc", ".docx"}:
        return "document"
    if extension in {".xls", ".xlsx"}:
        return "spreadsheet"
    return extension


if __name__ == "__main__":
    raise SystemExit(main_with_args())
