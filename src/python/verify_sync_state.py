#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
from typing import Any

from klms_sync_v2.cli import load_file_manifest_items
from klms_sync_v2.classifiers import classify_notice
from klms_sync_v2.dates import is_past
from klms_sync_v2.models import Assignment, Event, Notice


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-dir", required=True)
    parser.add_argument("--state-json", required=True)
    parser.add_argument("--calendar-lines")
    parser.add_argument("--reminders-lines")
    parser.add_argument("--overrides-json")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--write-json")
    return parser


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def parse_calendar_lines(path: Path | None) -> dict[str, Any]:
    return parse_key_value_lines(path)


def parse_reminders_lines(path: Path | None) -> dict[str, Any]:
    return parse_key_value_lines(path)


def parse_key_value_lines(path: Path | None) -> dict[str, Any]:
    result: dict[str, Any] = {}
    if path is None or not path.exists():
        return result
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if value.isdigit():
            result[key.strip()] = int(value)
        elif value in {"true", "false"}:
            result[key.strip()] = value == "true"
        else:
            result[key.strip()] = value
    return result


def ok_check(name: str, ok: bool, detail: str = "") -> dict[str, Any]:
    return {"name": name, "status": "ok" if ok else "fail", "detail": detail}


def warn_check(name: str, detail: str = "") -> dict[str, Any]:
    return {"name": name, "status": "warn", "detail": detail}


def normalize_url(value: Any) -> str:
    return str(value or "").split("#", 1)[0].strip()


def compact_text(*values: Any) -> str:
    return re.sub(r"\s+", " ", " ".join(str(value or "") for value in values)).strip()


def comparable_title(value: Any) -> str:
    text = compact_text(value).casefold()
    text = re.sub(r"^\[(?:과제|퀴즈|시험|공지)\]\s*", "", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def state_items(content: dict[str, Any], sections: tuple[str, ...]) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for section in sections:
        for item in content.get(section) or []:
            if isinstance(item, dict):
                items.append(item)
    return items


def state_url_set(content: dict[str, Any], sections: tuple[str, ...]) -> set[str]:
    return {normalize_url(item.get("url")) for item in state_items(content, sections) if normalize_url(item.get("url"))}


def assignment_key_set(content: dict[str, Any]) -> set[tuple[str, str]]:
    return {
        (compact_text(item.get("course")), comparable_title(item.get("title")))
        for item in state_items(
            content,
            ("assignments", "assignment_candidates", "completed_assignments", "assignment_records"),
        )
        if compact_text(item.get("course")) and comparable_title(item.get("title"))
    }


def event_key_set(content: dict[str, Any]) -> set[tuple[str, str, str]]:
    return {
        (
            compact_text(item.get("course")),
            comparable_title(item.get("title")),
            compact_text(item.get("sync_due") or item.get("due")),
        )
        for item in state_items(content, ("exam_items", "exam_candidates", "help_desk_items"))
        if compact_text(item.get("course")) and comparable_title(item.get("title"))
    }


def classified_notice_records(
    notice_digest: dict[str, Any],
    generated_at: str,
) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    assignment_records: list[dict[str, str]] = []
    exam_records: list[dict[str, str]] = []
    if not isinstance(notice_digest, dict):
        return assignment_records, exam_records

    for course in notice_digest.get("courses", []):
        if not isinstance(course, dict):
            continue
        course_name = compact_text(course.get("course"))
        for record in course.get("notices", []):
            if not isinstance(record, dict):
                continue
            merged = dict(record)
            merged.setdefault("course", course_name)
            notice = Notice.from_digest_record(merged)
            item, _reason = classify_notice(notice, generated_at)
            payload = {
                "course": compact_text(notice.course),
                "title": compact_text(notice.title),
                "url": normalize_url(notice.url),
            }
            if isinstance(item, Assignment):
                if is_past(item.sync_due, generated_at):
                    continue
                assignment_records.append(payload)
            elif isinstance(item, Event) and item.category in {"exam", "exam_candidate"}:
                if not is_past(item.sync_due, generated_at):
                    exam_records.append(payload)

    return assignment_records, exam_records


def load_overrides(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    payload = load_json(path, {})
    return payload if isinstance(payload, dict) else {}


def override_status(value: Any) -> str:
    if isinstance(value, dict):
        return str(value.get("status") or "").strip().lower()
    return str(value or "").strip().lower()


def ignored_override_urls(overrides: dict[str, Any], section: str) -> set[str]:
    values = overrides.get(section) if isinstance(overrides, dict) else {}
    if not isinstance(values, dict):
        return set()
    ignored_statuses = {"ignored", "hidden", "skip", "not_exam", "not_assignment", "false_positive"}
    result: set[str] = set()
    for key, value in values.items():
        if override_status(value) in ignored_statuses:
            result.add(normalize_url(str(key).split("::", 1)[0]))
    return result


def summarize_missing(records: list[dict[str, str]], limit: int = 5) -> str:
    samples = [
        compact_text(record.get("course"), "|", record.get("title"))
        for record in records[:limit]
    ]
    suffix = f" sample={'; '.join(samples)}" if samples else ""
    return f"missing={len(records)}{suffix}"


def calendar_result_totals(cache_dir: Path) -> dict[str, int] | None:
    payload = load_json(cache_dir / "core" / "calendar_sync_result.json", None)
    if not isinstance(payload, dict):
        return None
    totals: dict[str, int] = {}
    for summary in payload.get("summaries") or []:
        if not isinstance(summary, dict):
            continue
        bucket = str(summary.get("bucket") or "").strip()
        if not bucket:
            continue
        try:
            totals[bucket] = int(summary.get("total") or 0)
        except (TypeError, ValueError):
            totals[bucket] = 0
    return totals


def live_reminder_checks(reminders: dict[str, Any], assignment_count: int) -> list[dict[str, Any]]:
    error = str(reminders.get("reminders_error", "") or "").strip()
    if error:
        return [warn_check("reminders_access", error)]
    if not reminders:
        return [warn_check("reminders_access", "skipped: reminders verification unavailable")]
    active_count = int(reminders.get("reminders_assignment_active_count", 0) or 0)
    marker_count = int(reminders.get("reminders_assignment_marker_count", 0) or 0)
    list_exists = bool(reminders.get("reminders_assignment_list_exists", False))
    issue_active_count = int(reminders.get("reminders_issue_active_count", 0) or 0)
    issue_marker_count = int(reminders.get("reminders_issue_marker_count", 0) or 0)
    alert_active_count = int(reminders.get("reminders_alert_active_count", 0) or 0)
    alert_marker_count = int(reminders.get("reminders_alert_marker_count", 0) or 0)
    total_active_count = int(
        reminders.get(
            "reminders_total_active_count",
            active_count + issue_active_count + alert_active_count,
        )
        or 0
    )
    total_marker_count = int(
        reminders.get(
            "reminders_total_marker_count",
            marker_count + issue_marker_count + alert_marker_count,
        )
        or 0
    )
    return [
        ok_check("reminders_access", True, "available"),
        ok_check("reminders_assignment_list_exists", list_exists or assignment_count == 0, f"exists={list_exists}"),
        ok_check(
            "reminders_assignment_count_matches_state",
            marker_count == assignment_count,
            f"active={active_count} markers={marker_count} state={assignment_count}",
        ),
        ok_check(
            "reminders_total_count_consistent",
            total_marker_count == marker_count + issue_marker_count + alert_marker_count
            and total_active_count == active_count + issue_active_count + alert_active_count,
            (
                f"total_active={total_active_count} assignment={active_count} "
                f"issue={issue_active_count} alert={alert_active_count}"
            ),
        ),
    ]


def build_payload(
    cache_dir: Path,
    state_json: Path,
    calendar_lines: Path | None,
    reminders_lines: Path | None = None,
    overrides_json: Path | None = None,
) -> dict[str, Any]:
    notice_digest = load_json(cache_dir / "notice_digest.json", {})
    notice_primary = load_json(cache_dir / "notice_note_render_state.json", {})
    notice_archive = load_json(cache_dir / "notice_archive_note_render_state.json", {})
    state = load_json(state_json, {})
    manifest = load_json(cache_dir / "course_file_manifest.json", [])
    if not isinstance(manifest, list):
        manifest = []

    digest_urls: list[str] = []
    for course in notice_digest.get("courses", []):
        for notice in course.get("notices", []):
            url = notice.get("url")
            if url:
                digest_urls.append(url)

    rendered_urls: set[str] = set()
    for render_state in (notice_primary, notice_archive):
        for item in render_state.get("rendered_notices", []):
            url = item.get("notice_id")
            if url:
                rendered_urls.add(url)

    missing_notice_urls = sorted(set(digest_urls) - rendered_urls)

    missing_files: list[str] = []
    for item in manifest:
        if not isinstance(item, dict):
            continue
        absolute_path = item.get("absolute_path")
        relative_path = item.get("relative_path", "")
        if not absolute_path or not os.path.isfile(absolute_path):
            missing_files.append(relative_path or absolute_path or "<unknown>")

    content = state.get("content", {}) if isinstance(state, dict) else {}
    if not isinstance(content, dict):
        content = {}
    generated_at = str(state.get("generated_at") or notice_digest.get("generated_at") or "")
    exam_items = content.get("exam_items", []) if isinstance(content, dict) else []
    exam_candidates = content.get("exam_candidates", []) if isinstance(content, dict) else []
    helpdesk_items = content.get("help_desk_items", []) if isinstance(content, dict) else []
    assignments = content.get("assignments", []) if isinstance(content, dict) else []
    assignment_candidates = content.get("assignment_candidates", []) if isinstance(content, dict) else []
    completed_assignments = content.get("completed_assignments", []) if isinstance(content, dict) else []
    assignment_records = content.get("assignment_records", []) if isinstance(content, dict) else []

    overrides = load_overrides(overrides_json)
    ignored_exam_urls = ignored_override_urls(overrides, "exams")
    ignored_assignment_urls = ignored_override_urls(overrides, "assignments")

    exam_urls = state_url_set(content, ("exam_items", "exam_candidates"))
    assignment_urls = state_url_set(
        content,
        ("assignments", "assignment_candidates", "completed_assignments", "assignment_records"),
    )
    assignment_keys = assignment_key_set(content)
    event_keys = event_key_set(content)

    classified_notice_assignments, classified_notice_exams = classified_notice_records(
        notice_digest,
        generated_at,
    )
    notice_exam_candidates = [
        record for record in classified_notice_exams if record["url"] not in ignored_exam_urls
    ]
    missing_notice_exams = [
        record for record in notice_exam_candidates if record["url"] not in exam_urls
    ]
    notice_assignment_candidates = [
        record for record in classified_notice_assignments if record["url"] not in ignored_assignment_urls
    ]
    missing_notice_assignments = [
        record for record in notice_assignment_candidates if record["url"] not in assignment_urls
    ]

    file_assignment_missing: list[dict[str, str]] = []
    file_event_missing: list[dict[str, str]] = []
    file_assignment_count = 0
    file_event_count = 0
    file_manifest_parse_error = ""
    try:
        file_assignments, file_events, _file_metadata = load_file_manifest_items(
            str(cache_dir / "course_file_manifest.json"),
            generated_at=generated_at,
            previous_state=None,
        )
        file_assignment_count = len([item for item in file_assignments if not is_past(item.sync_due, generated_at)])
        file_event_count = len([item for item in file_events if not is_past(item.sync_due, generated_at)])
        for item in file_assignments:
            if is_past(item.sync_due, generated_at):
                continue
            key = (compact_text(item.course), comparable_title(item.title))
            if normalize_url(item.url) not in assignment_urls and key not in assignment_keys:
                file_assignment_missing.append(
                    {"course": item.course, "title": item.title, "url": normalize_url(item.url)}
                )
        for item in file_events:
            if is_past(item.sync_due, generated_at):
                continue
            key = (compact_text(item.course), comparable_title(item.title), compact_text(item.sync_due))
            if normalize_url(item.url) not in exam_urls and key not in event_keys:
                file_event_missing.append(
                    {"course": item.course, "title": item.title, "url": normalize_url(item.url)}
                )
    except Exception as error:  # pragma: no cover - defensive for corrupted runtime files
        file_manifest_parse_error = str(error)

    past_exam_items = [
        item
        for item in exam_items
        if isinstance(item, dict) and is_past(str(item.get("sync_due") or ""), generated_at)
    ]
    missing_exam_info = [
        item
        for item in exam_items
        if isinstance(item, dict)
        and not compact_text(
            item.get("instructions"),
            item.get("location"),
            item.get("coverage"),
            item.get("coverage_summary"),
        )
    ]

    calendar = parse_calendar_lines(calendar_lines)
    calendar_exam_count = int(calendar.get("calendar_exam_count", 0) or 0)
    calendar_helpdesk_count = int(calendar.get("calendar_helpdesk_count", 0) or 0)
    legacy_assignment = bool(calendar.get("legacy_calendar_assignment_exists", False))
    legacy_alert = bool(calendar.get("legacy_calendar_alert_exists", False))
    calendar_error = str(calendar.get("calendar_error", "") or "").strip()
    calendar_totals = calendar_result_totals(cache_dir)

    if calendar_error:
        calendar_checks = [
            warn_check("calendar_access", calendar_error),
            warn_check("calendar_exam_count_matches_state", "skipped: calendar unavailable"),
            warn_check("calendar_helpdesk_count_matches_state", "skipped: calendar unavailable"),
            warn_check("legacy_calendars_absent", "skipped: calendar unavailable"),
        ]
    else:
        calendar_checks = [
            ok_check("calendar_access", True, "available"),
            ok_check("calendar_exam_count_matches_state", calendar_exam_count == len(exam_items), f"calendar={calendar_exam_count} state={len(exam_items)}"),
            ok_check("calendar_helpdesk_count_matches_state", calendar_helpdesk_count == len(helpdesk_items), f"calendar={calendar_helpdesk_count} state={len(helpdesk_items)}"),
            ok_check("legacy_calendars_absent", not legacy_assignment and not legacy_alert, f"assignment={legacy_assignment} alert={legacy_alert}"),
        ]
    if calendar_totals is None:
        calendar_checks.extend(
            [
                warn_check("calendar_result_exam_matches_state", "skipped: calendar result missing"),
                warn_check("calendar_result_helpdesk_matches_state", "skipped: calendar result missing"),
            ]
        )
    else:
        calendar_checks.extend(
            [
                ok_check(
                    "calendar_result_exam_matches_state",
                    int(calendar_totals.get("exam", 0) or 0) == len(exam_items),
                    f"result={int(calendar_totals.get('exam', 0) or 0)} state={len(exam_items)}",
                ),
                ok_check(
                    "calendar_result_helpdesk_matches_state",
                    int(calendar_totals.get("helpdesk", 0) or 0) == len(helpdesk_items),
                    f"result={int(calendar_totals.get('helpdesk', 0) or 0)} state={len(helpdesk_items)}",
                ),
            ]
        )

    reminders = parse_reminders_lines(reminders_lines)
    reminder_checks = live_reminder_checks(reminders, len(assignments))
    if not reminders and len(assignments) > 0:
        reminder_hash = cache_dir / "core" / "reminders_desired_hash.txt"
        reminder_checks.append(
            ok_check(
                "reminders_desired_hash_exists",
                reminder_hash.exists(),
                str(reminder_hash) if reminder_hash.exists() else "missing",
            )
        )

    checks = [
        ok_check("notice_render_complete", len(missing_notice_urls) == 0, f"missing={len(missing_notice_urls)}"),
        ok_check(
            "notice_exam_detection_covered_by_state",
            len(missing_notice_exams) == 0,
            summarize_missing(missing_notice_exams),
        ),
        ok_check(
            "notice_assignment_detection_covered_by_state",
            len(missing_notice_assignments) == 0,
            summarize_missing(missing_notice_assignments),
        ),
        ok_check("manifest_files_exist", len(missing_files) == 0, f"missing={len(missing_files)}"),
        ok_check(
            "manifest_classification_parseable",
            not file_manifest_parse_error,
            file_manifest_parse_error or f"assignments={file_assignment_count} exams={file_event_count}",
        ),
        ok_check(
            "manifest_assignment_detection_covered_by_state",
            len(file_assignment_missing) == 0,
            summarize_missing(file_assignment_missing),
        ),
        ok_check(
            "manifest_exam_detection_covered_by_state",
            len(file_event_missing) == 0,
            summarize_missing(file_event_missing),
        ),
        ok_check(
            "past_exam_items_absent",
            len(past_exam_items) == 0,
            summarize_missing(
                [
                    {
                        "course": str(item.get("course") or ""),
                        "title": str(item.get("title") or ""),
                    }
                    for item in past_exam_items
                ]
            ),
        ),
        ok_check(
            "exam_information_present",
            len(missing_exam_info) == 0,
            summarize_missing(
                [
                    {
                        "course": str(item.get("course") or ""),
                        "title": str(item.get("title") or ""),
                    }
                    for item in missing_exam_info
                ]
            ),
        ),
    ] + calendar_checks + reminder_checks
    status = "fail" if any(item["status"] == "fail" for item in checks) else "ok"

    return {
        "status": status,
        "notices": {
            "digest_count": len(digest_urls),
            "rendered_count": len(rendered_urls),
            "missing_count": len(missing_notice_urls),
            "missing_urls": missing_notice_urls,
            "exam_candidate_count": len(notice_exam_candidates),
            "missing_exam_candidate_count": len(missing_notice_exams),
            "missing_exam_candidates": missing_notice_exams,
            "assignment_candidate_count": len(notice_assignment_candidates),
            "missing_assignment_candidate_count": len(missing_notice_assignments),
            "missing_assignment_candidates": missing_notice_assignments,
        },
        "files": {
            "manifest_file_count": len(manifest),
            "missing_file_count": len(missing_files),
            "missing_files": missing_files,
            "derived_assignment_count": file_assignment_count,
            "missing_derived_assignment_count": len(file_assignment_missing),
            "missing_derived_assignments": file_assignment_missing,
            "derived_exam_count": file_event_count,
            "missing_derived_exam_count": len(file_event_missing),
            "missing_derived_exams": file_event_missing,
            "classification_error": file_manifest_parse_error,
        },
        "state": {
            "assignment_count": len(assignments),
            "assignment_candidate_count": len(assignment_candidates),
            "completed_assignment_count": len(completed_assignments),
            "assignment_record_count": len(assignment_records),
            "exam_count": len(exam_items),
            "exam_candidate_count": len(exam_candidates),
            "past_exam_count": len(past_exam_items),
            "missing_exam_info_count": len(missing_exam_info),
            "helpdesk_count": len(helpdesk_items),
            "exam_items": [
                {"course": item.get("course", ""), "title": item.get("title", ""), "due": item.get("due", "")}
                for item in exam_items
            ],
            "helpdesk_items": [
                {"course": item.get("course", ""), "title": item.get("title", ""), "due": item.get("due", "")}
                for item in helpdesk_items
            ],
        },
        "calendar": {
            "exam_count": calendar_exam_count,
            "helpdesk_count": calendar_helpdesk_count,
            "legacy_assignment_exists": legacy_assignment,
            "legacy_alert_exists": legacy_alert,
            "error": calendar_error,
            "result_totals": calendar_totals or {},
        },
        "reminders": {
            "assignment_active_count": int(reminders.get("reminders_assignment_active_count", 0) or 0),
            "assignment_marker_count": int(reminders.get("reminders_assignment_marker_count", 0) or 0),
            "assignment_list_exists": bool(reminders.get("reminders_assignment_list_exists", False)),
            "issue_active_count": int(reminders.get("reminders_issue_active_count", 0) or 0),
            "issue_marker_count": int(reminders.get("reminders_issue_marker_count", 0) or 0),
            "issue_list_exists": bool(reminders.get("reminders_issue_list_exists", False)),
            "alert_active_count": int(reminders.get("reminders_alert_active_count", 0) or 0),
            "alert_marker_count": int(reminders.get("reminders_alert_marker_count", 0) or 0),
            "alert_list_exists": bool(reminders.get("reminders_alert_list_exists", False)),
            "total_active_count": int(
                reminders.get(
                    "reminders_total_active_count",
                    int(reminders.get("reminders_assignment_active_count", 0) or 0)
                    + int(reminders.get("reminders_issue_active_count", 0) or 0)
                    + int(reminders.get("reminders_alert_active_count", 0) or 0),
                )
                or 0
            ),
            "total_marker_count": int(
                reminders.get(
                    "reminders_total_marker_count",
                    int(reminders.get("reminders_assignment_marker_count", 0) or 0)
                    + int(reminders.get("reminders_issue_marker_count", 0) or 0)
                    + int(reminders.get("reminders_alert_marker_count", 0) or 0),
                )
                or 0
            ),
            "error": str(reminders.get("reminders_error", "") or ""),
        },
        "checks": checks,
    }


def print_text(payload: dict[str, Any]) -> None:
    notices = payload["notices"]
    files = payload["files"]
    state = payload["state"]
    calendar = payload["calendar"]
    reminders = payload["reminders"]
    print(f"notice_digest_count={notices['digest_count']}")
    print(f"notice_rendered_count={notices['rendered_count']}")
    print(f"notice_missing_count={notices['missing_count']}")
    for url in notices["missing_urls"]:
        print(f"notice_missing_url={url}")
    print(f"notice_exam_candidate_count={notices['exam_candidate_count']}")
    print(f"notice_missing_exam_candidate_count={notices['missing_exam_candidate_count']}")
    print(f"notice_assignment_candidate_count={notices['assignment_candidate_count']}")
    print(f"notice_missing_assignment_candidate_count={notices['missing_assignment_candidate_count']}")
    print(f"manifest_file_count={files['manifest_file_count']}")
    print(f"manifest_missing_file_count={files['missing_file_count']}")
    for path in files["missing_files"]:
        print(f"manifest_missing_file={path}")
    print(f"manifest_derived_assignment_count={files['derived_assignment_count']}")
    print(f"manifest_missing_derived_assignment_count={files['missing_derived_assignment_count']}")
    print(f"manifest_derived_exam_count={files['derived_exam_count']}")
    print(f"manifest_missing_derived_exam_count={files['missing_derived_exam_count']}")
    print(f"state_assignment_count={state['assignment_count']}")
    print(f"state_assignment_candidate_count={state['assignment_candidate_count']}")
    print(f"state_completed_assignment_count={state['completed_assignment_count']}")
    print(f"state_assignment_record_count={state['assignment_record_count']}")
    print(f"state_exam_count={state['exam_count']}")
    print(f"state_exam_candidate_count={state['exam_candidate_count']}")
    print(f"state_past_exam_count={state['past_exam_count']}")
    print(f"state_missing_exam_info_count={state['missing_exam_info_count']}")
    for item in state["exam_items"]:
        print(f"state_exam={item['course']} | {item['title']} | {item['due']}")
    print(f"state_helpdesk_count={state['helpdesk_count']}")
    for item in state["helpdesk_items"]:
        print(f"state_helpdesk={item['course']} | {item['title']} | {item['due']}")
    print(f"calendar_exam_count={calendar['exam_count']}")
    print(f"calendar_helpdesk_count={calendar['helpdesk_count']}")
    print(f"legacy_calendar_assignment_exists={'true' if calendar['legacy_assignment_exists'] else 'false'}")
    print(f"legacy_calendar_alert_exists={'true' if calendar['legacy_alert_exists'] else 'false'}")
    print(f"reminders_assignment_active_count={reminders['assignment_active_count']}")
    print(f"reminders_assignment_marker_count={reminders['assignment_marker_count']}")
    print(f"reminders_assignment_list_exists={'true' if reminders['assignment_list_exists'] else 'false'}")
    print(f"reminders_issue_active_count={reminders['issue_active_count']}")
    print(f"reminders_issue_marker_count={reminders['issue_marker_count']}")
    print(f"reminders_issue_list_exists={'true' if reminders['issue_list_exists'] else 'false'}")
    print(f"reminders_alert_active_count={reminders['alert_active_count']}")
    print(f"reminders_alert_marker_count={reminders['alert_marker_count']}")
    print(f"reminders_alert_list_exists={'true' if reminders['alert_list_exists'] else 'false'}")
    print(f"reminders_total_active_count={reminders['total_active_count']}")
    print(f"reminders_total_marker_count={reminders['total_marker_count']}")


def main() -> int:
    args = build_parser().parse_args()
    payload = build_payload(
        Path(args.cache_dir),
        Path(args.state_json),
        Path(args.calendar_lines) if args.calendar_lines else None,
        Path(args.reminders_lines) if args.reminders_lines else None,
        Path(args.overrides_json) if args.overrides_json else None,
    )
    if args.write_json:
        Path(args.write_json).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print_text(payload)
    return 0 if payload["status"] == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
