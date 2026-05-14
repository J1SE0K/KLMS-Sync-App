from __future__ import annotations

from copy import deepcopy
from typing import Any

from .exam_fields import extract_coverage, extract_location, online_exam_location
from .models import Event, SyncState
from .text import clipped, one_line


def split_override_key(key: str) -> tuple[str, str]:
    if "::" not in key:
        return key, ""
    url, title = key.rsplit("::", 1)
    return url, title


def apply_overrides(
    state: SyncState,
    overrides: dict[str, Any] | None,
    source_by_url: dict[str, dict[str, str]] | None = None,
) -> SyncState:
    if not overrides:
        return state

    source_by_url = source_by_url or {}
    updated = deepcopy(state)

    assignment_overrides = overrides.get("assignments") or {}
    removed_assignment_urls = {
        split_override_key(str(url))[0]
        for url, status in assignment_overrides.items()
        if str(status).lower() in {"completed", "ignored"}
    }
    if removed_assignment_urls:
        updated.assignments = [
            item for item in updated.assignments if item.url not in removed_assignment_urls
        ]
        updated.assignment_candidates = [
            item for item in updated.assignment_candidates if item.url not in removed_assignment_urls
        ]

    exam_overrides = overrides.get("exams") or {}
    for key, spec in exam_overrides.items():
        url, title_from_key = split_override_key(str(key))
        spec = spec if isinstance(spec, dict) else {"status": spec}
        status = str(spec.get("status") or "").lower()

        updated.exams = [item for item in updated.exams if item.url != url]
        updated.exam_candidates = [item for item in updated.exam_candidates if item.url != url]
        if status != "approved":
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

        updated.exams.append(
            Event(
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
        )

    updated.exams.sort(key=lambda item: (item.sync_due, item.course, item.title))
    return updated
