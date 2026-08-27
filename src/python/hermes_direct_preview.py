from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import parse_qsl, urljoin, urlsplit, urlunsplit

from bs4 import BeautifulSoup

KLMS_ORIGIN = "https://klms.kaist.ac.kr"
MODULE_TYPES = {
    "courseboard": "notice",
    "assign": "assignment",
    "quiz": "exam",
    "forum": "forum",
    "resource": "file",
    "folder": "file",
    "page": "file",
    "book": "file",
    "url": "file",
    "lti": "file",
    "vod": "file",
    "h5pactivity": "file",
    "feedback": "other",
}
LEGACY_TYPES = {
    "courseboard": "notice",
    "assign": "assignment",
    "quiz": "exam",
    "resource": "file",
    "folder": "file",
    "page": "file",
    "book": "file",
    "url": "file",
    "lti": "file",
    "vod": "file",
}
COUNT_TYPES = ("notice", "assignment", "exam", "file", "forum", "other")


def canonical_digest(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _course_id(url: str) -> str:
    match = re.search(r"(?:^|[?&])id=(\d+)(?:&|$)", urlsplit(str(url or "")).query)
    if match:
        return match.group(1)
    query = urlsplit(str(url or "")).query
    match = re.search(r"(?:^|&)id=(\d+)(?:&|$)", query)
    return match.group(1) if match else ""


def _normalize_url(raw: str) -> str:
    absolute = urljoin(f"{KLMS_ORIGIN}/", str(raw or "").strip())
    parsed = urlsplit(absolute)
    if parsed.scheme != "https" or parsed.netloc.lower() != "klms.kaist.ac.kr":
        return ""
    return urlunsplit(("https", "klms.kaist.ac.kr", parsed.path, parsed.query, ""))


def _course_page_id(url: str) -> str:
    parsed = urlsplit(_normalize_url(url))
    if parsed.path != "/course/view.php":
        return ""
    values = [value for key, value in parse_qsl(parsed.query, keep_blank_values=True) if key == "id"]
    return values[0] if len(values) == 1 and re.fullmatch(r"[0-9]+", values[0]) else ""


def _course_title(soup: BeautifulSoup, fallback: str = "") -> str:
    title = soup.title.get_text(" ", strip=True) if soup.title else str(fallback or "").strip()
    return re.sub(r"^강좌:\s*", "", title).strip()


def _classify(path: str) -> tuple[str, str] | None:
    match = re.match(r"^/mod/([^/]+)/", path)
    if not match:
        return None
    module = match.group(1).lower()
    return module, MODULE_TYPES.get(module, "other")


def _extract_course(page: dict[str, Any]) -> dict[str, Any] | None:
    requested = _normalize_url(str(page.get("requestedUrl") or ""))
    final_url = _normalize_url(str(page.get("url") or ""))
    course_id = _course_page_id(requested)
    final_course_id = _course_page_id(final_url)
    if not course_id or final_course_id != course_id:
        raise ValueError(
            f"final URL course id mismatch: requested {course_id or 'invalid'}, final {final_course_id or 'invalid'}"
        )
    status = int(page.get("status") or 0)
    if not 200 <= status < 300:
        return None

    soup = BeautifulSoup(str(page.get("html") or ""), "html.parser")
    activities: list[dict[str, str]] = []
    seen: set[str] = set()
    for anchor in soup.select("a[href]"):
        url = _normalize_url(str(anchor.get("href") or ""))
        if not url or url in seen:
            continue
        classification = _classify(urlsplit(url).path)
        if not classification:
            continue
        module, activity_type = classification
        seen.add(url)
        title = anchor.get_text(" ", strip=True) or f"{module}:{_course_id(url)}"
        activities.append(
            {
                "course_id": course_id,
                "course_page": requested,
                "title": title,
                "type": activity_type,
                "module": module,
                "url": url,
            }
        )

    activities.sort(key=lambda item: (item["type"], item["url"], item["title"]))
    return {
        "course_id": course_id,
        "course_page": requested,
        "course_title": _course_title(soup, str(page.get("title") or "")),
        "activities": activities,
    }


def _flatten(preview: dict[str, Any], allowed_course_ids: set[str] | None = None) -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}
    for course in preview.get("courses") or []:
        course_id = str(course.get("course_id") or _course_id(str(course.get("course_page") or "")))
        if allowed_course_ids and course_id not in allowed_course_ids:
            continue
        for raw in course.get("activities") or []:
            url = _normalize_url(str(raw.get("url") or ""))
            if not url:
                continue
            raw_type = str(raw.get("type") or "other")
            identity = f"{course_id}\u0000{url}"
            result[identity] = {
                "course_id": course_id,
                "url": url,
                "title": str(raw.get("title") or "").strip(),
                "type": LEGACY_TYPES.get(raw_type, raw_type),
            }
    return result


def build_diff(previous: dict[str, Any] | None, current: dict[str, Any]) -> dict[str, Any]:
    current_ids = {str(course.get("course_id") or "") for course in current.get("courses") or []}
    current_items = _flatten(current)
    previous_items = _flatten(previous or {}, current_ids)
    added_keys = sorted(set(current_items) - set(previous_items))
    removed_keys = sorted(set(previous_items) - set(current_items))
    changed_keys = sorted(
        key for key in set(current_items) & set(previous_items)
        if current_items[key] != previous_items[key]
    )
    return {
        "added": len(added_keys),
        "changed": len(changed_keys),
        "removed_candidates": len(removed_keys),
        "deletion_authorized": False,
        "added_urls": [current_items[key]["url"] for key in added_keys],
        "changed_urls": [current_items[key]["url"] for key in changed_keys],
        "removed_candidate_urls": [previous_items[key]["url"] for key in removed_keys],
    }


def build_preview(
    pages: Iterable[dict[str, Any]],
    *,
    active_course_ids: set[str],
    term: dict[str, Any],
    generated_at: str,
    previous: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if not isinstance(term.get("year"), int) or not re.fullmatch(r"\d{2}", str(term.get("semester_code") or "")):
        raise ValueError("invalid academic term")
    if not active_course_ids:
        raise ValueError("active course allowlist is empty")

    courses: list[dict[str, Any]] = []
    seen_course_ids: set[str] = set()
    for page in pages:
        course = _extract_course(page)
        if course and course["course_id"] in active_course_ids:
            course_id = str(course["course_id"])
            if course_id in seen_course_ids:
                raise ValueError(f"duplicate authoritative course page: {course_id}")
            seen_course_ids.add(course_id)
            courses.append(course)
    courses.sort(key=lambda item: item["course_id"])
    actual_ids = {course["course_id"] for course in courses}
    if actual_ids != active_course_ids:
        missing = sorted(active_course_ids - actual_ids)
        raise ValueError(f"missing authoritative course pages: {','.join(missing)}")

    counts = Counter(
        activity["type"]
        for course in courses
        for activity in course["activities"]
    )
    activity_counts = {name: int(counts.get(name, 0)) for name in COUNT_TYPES}
    activity_counts["total"] = sum(activity_counts.values())
    digest_payload = {
        "mode": "hermes-direct-safari",
        "status": "preview",
        "term": {
            "year": term["year"],
            "semester_code": str(term["semester_code"]),
            "label": str(term.get("label") or ""),
        },
        "active_course_ids": sorted(active_course_ids),
        "course_pages": len(courses),
        "activity_counts": activity_counts,
        "courses": courses,
    }
    preview = dict(digest_payload)
    preview["generated_at"] = generated_at
    preview["digest_sha256"] = canonical_digest(digest_payload)
    preview["diff"] = build_diff(previous, preview)
    return preview


def _load_json(path: Path | None, default: Any) -> Any:
    if not path or not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def _read_ids(path: Path) -> set[str]:
    ids: set[str] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        course_id = _course_page_id(line.strip()) if "?" in line else line.strip()
        if course_id and re.fullmatch(r"[0-9]+", course_id):
            ids.add(course_id)
    return ids


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--courses-json", required=True, type=Path)
    parser.add_argument("--active-course-ids-file", required=True, type=Path)
    parser.add_argument("--previous-preview", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--term-year", required=True, type=int)
    parser.add_argument("--semester-code", required=True)
    parser.add_argument("--term-label", required=True)
    parser.add_argument("--generated-at", required=True)
    args = parser.parse_args()

    preview = build_preview(
        _load_json(args.courses_json, []),
        active_course_ids=_read_ids(args.active_course_ids_file),
        term={
            "year": args.term_year,
            "semester_code": args.semester_code,
            "label": args.term_label,
        },
        generated_at=args.generated_at,
        previous=_load_json(args.previous_preview, {}),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(preview, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "status": "ok",
        "course_pages": preview["course_pages"],
        "activity_counts": preview["activity_counts"],
        "digest_sha256": preview["digest_sha256"],
        "diff": {
            "added": preview["diff"]["added"],
            "changed": preview["diff"]["changed"],
            "removed_candidates": preview["diff"]["removed_candidates"],
            "deletion_authorized": False,
        },
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
