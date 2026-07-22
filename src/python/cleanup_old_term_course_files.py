#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from datetime import datetime
from pathlib import Path
from typing import Any
import unicodedata

from managed_course_file_roots import (
    managed_member,
    prepare_managed_root,
    recover_file,
    validate_relative_path,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest-json", required=True)
    parser.add_argument("--academic-terms-json", required=True)
    parser.add_argument("--output-json", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--trash-root")
    return parser


def normalized_key(value: str) -> str:
    return (
        unicodedata.normalize("NFC", str(value or ""))
        .casefold()
        .replace(" ", "")
        .strip()
    )


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def selected_course_keys(catalog: dict[str, Any]) -> set[str]:
    selected_year = catalog.get("selected_year")
    selected_semester = str(catalog.get("selected_semester") or "").strip()
    courses = catalog.get("courses")
    if selected_year is None or not selected_semester or not isinstance(courses, list):
        return set()

    keys: set[str] = set()
    for course in courses:
        if not isinstance(course, dict):
            continue
        title = normalized_key(course.get("title") or "")
        code = normalized_key(course.get("code") or "")
        if title:
            keys.add(title)
        if code:
            keys.add(code)
    return keys


def course_is_current(course: str, current_course_keys: set[str]) -> bool:
    key = normalized_key(course)
    if not key:
        return True
    return any(key == current or key.startswith(current) or current.startswith(key) for current in current_course_keys)


def main() -> int:
    args = build_parser().parse_args()
    manifest_path = Path(args.manifest_json)
    terms_path = Path(args.academic_terms_json)
    output_path = Path(args.output_json)
    root = prepare_managed_root(
        args.root,
        "course-files",
        allow_unmarked=args.dry_run,
    )
    trash_root = Path(args.trash_root).expanduser() if args.trash_root else (
        Path.home()
        / ".Trash"
        / "KLMS Sync Old Term Files"
        / datetime.now().strftime("%Y%m%d-%H%M%S")
    )

    manifest = load_json(manifest_path, [])
    catalog = load_json(terms_path, {})
    if not isinstance(manifest, list):
        raise SystemExit(f"Manifest must be a JSON array: {manifest_path}")
    if not isinstance(catalog, dict):
        catalog = {}

    current_courses = selected_course_keys(catalog)
    selected_term = (
        f"{catalog.get('selected_year')}년 {catalog.get('selected_semester')}"
        if catalog.get("selected_year") and catalog.get("selected_semester")
        else ""
    )
    if not current_courses:
        payload = {
            "status": "skipped",
            "reason": "current-term-courses-unavailable",
            "selected_term": selected_term,
            "removed_count": 0,
            "kept_count": len(manifest),
            "dry_run": bool(args.dry_run),
            "items": [],
        }
        output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return 0

    kept: list[dict[str, Any]] = []
    removed: list[dict[str, Any]] = []
    for item in manifest:
        if not isinstance(item, dict):
            continue
        relative = validate_relative_path(item.get("relative_path") or item.get("filename"))
        path = managed_member(root, relative)
        normalized_item = {
            **item,
            "relative_path": relative.as_posix(),
            "absolute_path": str(path),
        }
        course = str(item.get("course") or "")
        if course_is_current(course, current_courses):
            kept.append(normalized_item)
            continue

        exists = path.exists() or path.is_symlink()
        recovery: dict[str, Any] = {}
        if exists:
            managed_member(root, relative, must_exist=True)
            if not args.dry_run:
                recovery = recover_file(path, root, relative, trash_root)
        removed.append(
            {
                "course": course,
                "filename": item.get("filename") or "",
                "relative_path": relative.as_posix(),
                "absolute_path": str(path),
                "trash_path": recovery.get("recovery_path", ""),
                "sha256": recovery.get("sha256", ""),
                "file_existed": exists,
            }
        )

    if not args.dry_run:
        manifest_path.write_text(json.dumps(kept, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    payload = {
        "status": "ok",
        "selected_term": selected_term,
        "removed_count": len(removed),
        "kept_count": len(kept),
        "dry_run": bool(args.dry_run),
        "trash_root": "" if args.dry_run else str(trash_root),
        "items": removed,
    }
    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
