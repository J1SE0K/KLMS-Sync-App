#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import shutil
from datetime import datetime
from pathlib import Path
from typing import Any
import unicodedata


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest-json", required=True)
    parser.add_argument("--academic-terms-json", required=True)
    parser.add_argument("--output-json", required=True)
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


def unique_destination(path: Path) -> Path:
    if not path.exists():
        return path
    stem = path.stem
    suffix = path.suffix
    parent = path.parent
    index = 2
    while True:
        candidate = parent / f"{stem} {index}{suffix}"
        if not candidate.exists():
            return candidate
        index += 1


def move_to_trash(path: Path, relative_path: str, trash_root: Path, dry_run: bool) -> str:
    destination = unique_destination(trash_root / relative_path)
    if not dry_run:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(path), str(destination))
    return str(destination)


def main() -> int:
    args = build_parser().parse_args()
    manifest_path = Path(args.manifest_json)
    terms_path = Path(args.academic_terms_json)
    output_path = Path(args.output_json)
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
        course = str(item.get("course") or "")
        if course_is_current(course, current_courses):
            kept.append(item)
            continue

        absolute_path = str(item.get("absolute_path") or "").strip()
        relative_path = str(item.get("relative_path") or item.get("filename") or absolute_path).strip()
        path = Path(absolute_path) if absolute_path else None
        exists = bool(path and path.is_file())
        destination = ""
        if exists and relative_path:
            destination = move_to_trash(path, relative_path, trash_root, args.dry_run)
        removed.append(
            {
                "course": course,
                "filename": item.get("filename") or "",
                "relative_path": relative_path,
                "absolute_path": absolute_path,
                "trash_path": destination,
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
