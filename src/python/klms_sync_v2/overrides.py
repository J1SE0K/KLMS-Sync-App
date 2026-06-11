from __future__ import annotations

from copy import deepcopy
from dataclasses import replace
from typing import Any

from .exam_fields import extract_coverage, extract_location, online_exam_location
from .dates import is_past
from .models import Assignment, Event, SyncState
from .text import clipped, one_line


def split_override_key(key: str) -> tuple[str, str]:
    if "::" not in key:
        return key, ""
    url, title = key.rsplit("::", 1)
    return url, title


def exam_override_candidate_keys(item: Event) -> list[str]:
    url = one_line(item.url)
    title = one_line(item.title)
    course = one_line(item.course)
    due = one_line(item.sync_due or item.due)
    return [
        url,
        f"{url}::{title}" if url and title else "",
        f"{course}::{title}::{due}" if course and title and due else "",
        f"{course}::{title}" if course and title else "",
    ]


def exam_override_identity(item: Event) -> str:
    for key in exam_override_candidate_keys(item)[2:] + exam_override_candidate_keys(item)[:2]:
        if key:
            return key
    return ""


def assignment_override_candidate_keys(item: Assignment) -> list[str]:
    url = one_line(item.url)
    title = one_line(item.title)
    course = one_line(item.course)
    due = one_line(item.sync_due or item.due)
    return [
        url,
        f"{url}::{title}" if url and title else "",
        f"{course}::{title}::{due}" if course and title and due else "",
        f"{course}::{title}" if course and title else "",
    ]


def assignment_override_identity(item: Assignment) -> str:
    for key in assignment_override_candidate_keys(item)[2:] + assignment_override_candidate_keys(item)[:2]:
        if key:
            return key
    return ""


def normalize_assignment_overrides(payload: Any) -> dict[str, str]:
    if not isinstance(payload, dict):
        return {}
    normalized: dict[str, str] = {}
    for key, status in payload.items():
        normalized_key = one_line(str(key))
        normalized_status = one_line(str(status)).lower()
        if normalized_key and normalized_status:
            normalized[normalized_key] = normalized_status
    return normalized


def assignment_override_status(item: Assignment, overrides: dict[str, str]) -> str:
    for key in assignment_override_candidate_keys(item):
        if key and key in overrides:
            return overrides[key]
    return ""


def apply_overrides(
    state: SyncState,
    overrides: dict[str, Any] | None,
    source_by_url: dict[str, dict[str, str]] | None = None,
    *,
    generated_at: str = "",
    include_past: bool = False,
) -> SyncState:
    if not overrides:
        return state

    source_by_url = source_by_url or {}
    updated = deepcopy(state)

    assignment_overrides = normalize_assignment_overrides(overrides.get("assignments") or {})
    if assignment_overrides:
        def status_for_assignment(item: Assignment) -> str:
            return assignment_override_status(item, assignment_overrides)

        def is_removed(item: Assignment) -> bool:
            return status_for_assignment(item) in {"completed", "ignored"}

        removed_items = [
            item
            for item in updated.assignments + updated.assignment_candidates
            if is_removed(item)
        ]
        updated.assignments = [item for item in updated.assignments if not is_removed(item)]
        updated.assignment_candidates = [
            item for item in updated.assignment_candidates if not is_removed(item)
        ]
        existing_record_keys = {
            assignment_override_identity(item) for item in updated.assignment_records
        }
        existing_completed_keys = {
            assignment_override_identity(item) for item in updated.completed_assignments
        }
        for item in removed_items:
            status = status_for_assignment(item)
            identity = assignment_override_identity(item)
            if status == "completed":
                completed = replace(
                    item,
                    auto_completed=True,
                    record_status="completed",
                    completion_reason="manual_completed",
                )
                if identity not in existing_completed_keys:
                    updated.completed_assignments.append(completed)
                    existing_completed_keys.add(identity)
                if identity not in existing_record_keys:
                    updated.assignment_records.append(completed)
                    existing_record_keys.add(identity)
            elif status == "ignored" and identity not in existing_record_keys:
                updated.assignment_records.append(replace(item, record_status="ignored"))
                existing_record_keys.add(identity)
        updated.assignment_records = [
            replace(
                item,
                auto_completed=True,
                record_status="completed",
                completion_reason=item.completion_reason or "manual_completed",
            )
            if status_for_assignment(item) == "completed"
            else replace(item, record_status=item.record_status or "ignored")
            if status_for_assignment(item) == "ignored"
            else item
            for item in updated.assignment_records
        ]

    exam_overrides = overrides.get("exams") or {}
    existing_exam_record_keys = {
        exam_override_identity(item) for item in updated.exam_records
    }
    existing_past_exam_keys = {
        exam_override_identity(item) for item in updated.past_exams
    }

    def append_exam_record(item: Event) -> None:
        identity = exam_override_identity(item)
        if identity and identity in existing_exam_record_keys:
            return
        updated.exam_records.append(item)
        if identity:
            existing_exam_record_keys.add(identity)

    def append_past_exam(item: Event) -> None:
        identity = exam_override_identity(item)
        if identity and identity not in existing_past_exam_keys:
            updated.past_exams.append(item)
            existing_past_exam_keys.add(identity)
        append_exam_record(item)

    for key, spec in exam_overrides.items():
        url, title_from_key = split_override_key(str(key))
        spec = spec if isinstance(spec, dict) else {"status": spec}
        status = str(spec.get("status") or "").lower()

        removed_items = [
            item
            for item in updated.exams + updated.exam_candidates + updated.past_exams
            if item.url == url
        ]
        updated.exams = [item for item in updated.exams if item.url != url]
        updated.exam_candidates = [item for item in updated.exam_candidates if item.url != url]
        updated.past_exams = [item for item in updated.past_exams if item.url != url]
        if status != "approved":
            if status in {"ignored", "hidden", "skip", "completed"}:
                for item in removed_items:
                    append_exam_record(
                        replace(
                            item,
                            record_status=status,
                            completion_reason="manual_completed" if status == "completed" else "",
                        )
                    )
            continue

        source = source_by_url.get(url, {})
        title = one_line(str(spec.get("title") or title_from_key or source.get("title") or "시험"))
        due = one_line(str(spec.get("due") or ""))
        sync_due = one_line(str(spec.get("sync_due") or ""))
        if not due or not sync_due:
            continue
        instructions = one_line(source.get("instructions") or "")
        append = one_line(str(spec.get("instructions_append") or ""))
        if append:
            instructions = one_line(" ".join([instructions, append]))
        location = one_line(str(spec.get("location") or ""))
        if not location:
            location = extract_location(instructions) or online_exam_location(url)
        coverage = one_line(str(spec.get("coverage_summary") or spec.get("coverage") or ""))
        if not coverage:
            coverage = extract_coverage(instructions)

        event = Event(
            url=url,
            course=one_line(str(spec.get("course") or source.get("course") or "")),
            title=title,
            due=due,
            sync_due=sync_due,
            sync_start=one_line(str(spec.get("sync_start") or "")),
            source="override",
            source_title=one_line(source.get("title") or title),
            instructions=clipped(instructions),
            location=location,
            coverage=coverage,
            category="exam",
            type="exam",
        )
        if not include_past and is_past(sync_due, generated_at or state.generated_at):
            append_past_exam(
                replace(event, record_status="completed", completion_reason="past_due")
            )
            continue

        active = replace(event, record_status="active")
        updated.exams.append(active)
        append_exam_record(active)

    updated.exams.sort(key=lambda item: (item.sync_due, item.course, item.title))
    updated.past_exams.sort(key=lambda item: (item.sync_due, item.course, item.title))
    updated.exam_records.sort(key=lambda item: (item.sync_due, item.course, item.title))
    updated.completed_assignments.sort(key=lambda item: (item.sync_due, item.course, item.title))
    updated.assignment_records.sort(key=lambda item: (item.sync_due, item.course, item.title))
    return updated
