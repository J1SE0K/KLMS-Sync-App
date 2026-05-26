from __future__ import annotations

from collections.abc import Iterable
from dataclasses import replace
import re

from .classifiers import classify_detail_page, classify_notice, clean_detail_instructions
from .classifiers import course_name_from_text
from .dates import is_past
from .models import Assignment, Event, Notice, Page, SyncState
from .overrides import apply_overrides
from .text import clipped, html_to_text, one_line, split_course_title, strip_access_suffix


def submitted_assignment_tokens(page: Page) -> set[str]:
    _course, title = split_course_title(page.title)
    normalized = one_line(title).lower()
    tokens = {normalized} if normalized else set()
    match = re.search(
        r"\b(?:(written|programming)\s+)?assignment\s+(\d+)\b",
        normalized,
        re.IGNORECASE,
    )
    if match:
        prefix = match.group(1)
        number = match.group(2)
        if prefix:
            tokens.add(f"{prefix.lower()} assignment {number}")
        else:
            tokens.add(f"assignment {number}")
    match = re.search(r"\bhw\s*#?\s*(\d+)\b", normalized, re.IGNORECASE)
    if match:
        tokens.add(f"hw {match.group(1)}")
    return tokens


def build_sync_state(
    *,
    generated_at: str,
    detail_pages: Iterable[Page],
    notices: Iterable[Notice],
    source_assignments: Iterable[Assignment] = (),
    source_events: Iterable[Event] = (),
    source_metadata: dict[str, dict[str, str]] | None = None,
    overrides: dict | None = None,
    include_past: bool = False,
) -> SyncState:
    state = SyncState(generated_at=generated_at)
    seen_assignments: set[str] = set()
    seen_events: set[tuple[str, str]] = set()
    submitted_tokens: set[str] = set()
    materialized_detail_pages = list(detail_pages)
    materialized_notices = list(notices)
    materialized_source_assignments = list(source_assignments)
    materialized_source_events = list(source_events)
    source_by_url: dict[str, dict[str, str]] = {}
    source_metadata_by_url = source_metadata or {}

    for page in materialized_detail_pages:
        raw_text = html_to_text(page.html) or page.text
        course, title = split_course_title(page.title)
        source_info = source_metadata_by_url.get(page.url, {})
        source_by_url[page.url] = {
            "course": course_name_from_text(course, one_line(raw_text))
            or source_info.get("course", ""),
            "title": strip_access_suffix(title),
            "instructions": clean_detail_instructions(raw_text),
        }
        _item, reason = classify_detail_page(page, generated_at)
        if reason == "submitted":
            submitted_tokens.update(submitted_assignment_tokens(page))

    for notice in materialized_notices:
        source_by_url[notice.url] = {
            "course": notice.course,
            "title": notice.title,
            "instructions": clipped(notice.body_text or notice.summary),
        }

    for item in materialized_source_assignments:
        source_by_url.setdefault(
            item.url,
            {
                "course": item.course,
                "title": item.title,
                "instructions": clipped(item.instructions),
            },
        )

    for item in materialized_source_events:
        source_by_url.setdefault(
            item.url,
            {
                "course": item.course,
                "title": item.title,
                "instructions": clipped(item.instructions),
            },
        )

    for url, source_info in source_metadata_by_url.items():
        source_by_url.setdefault(url, source_info)

    def enrich_assignment(item: Assignment) -> Assignment:
        source_info = source_metadata_by_url.get(item.url)
        if not source_info:
            return item
        if item.course and item.source_title and item.instructions:
            return item
        return replace(
            item,
            course=item.course or source_info.get("course", ""),
            source_title=item.source_title or source_info.get("title", ""),
            instructions=item.instructions or source_info.get("instructions", ""),
        )

    def enrich_event(item: Event) -> Event:
        source_info = source_metadata_by_url.get(item.url)
        if not source_info:
            return item
        if item.course and item.source_title and item.instructions:
            return item
        return replace(
            item,
            course=item.course or source_info.get("course", ""),
            source_title=item.source_title or source_info.get("title", ""),
            instructions=item.instructions or source_info.get("instructions", ""),
        )

    def add_assignment(item: Assignment) -> None:
        def record_assignment(record: Assignment) -> bool:
            if record.url in seen_assignments:
                return False
            seen_assignments.add(record.url)
            state.assignment_records.append(record)
            return True

        if item.record_status == "completed" or item.auto_completed:
            if record_assignment(item):
                state.completed_assignments.append(item)
            return
        if not include_past and is_past(item.sync_due, generated_at):
            completed = replace(
                item,
                auto_completed=True,
                record_status="completed",
                completion_reason="past_due",
            )
            if record_assignment(completed):
                state.completed_assignments.append(completed)
            return
        normalized = one_line(" ".join([item.title, item.source_title])).lower()
        if any(token and token in normalized for token in submitted_tokens):
            completed = replace(
                item,
                auto_completed=True,
                record_status="completed",
                completion_reason="submitted_match",
            )
            if record_assignment(completed):
                state.completed_assignments.append(completed)
            return
        active = replace(item, record_status=item.record_status or "active")
        if not record_assignment(active):
            return
        if item.category == "assignment_candidate":
            state.assignment_candidates.append(active)
        else:
            state.assignments.append(active)

    def add_event(item: Event) -> None:
        if item.category in {"exam", "exam_candidate"} and not include_past and is_past(item.sync_due, generated_at):
            return
        key = (item.url, item.category)
        if key in seen_events:
            return
        seen_events.add(key)
        if item.category == "help_desk":
            state.help_desk_items.append(item)
        elif item.category == "exam_candidate":
            state.exam_candidates.append(item)
        else:
            state.exams.append(item)

    for page in materialized_detail_pages:
        item, _reason = classify_detail_page(page, generated_at)
        if isinstance(item, Assignment):
            add_assignment(enrich_assignment(item))
        elif isinstance(item, Event):
            add_event(enrich_event(item))

    for item in materialized_source_assignments:
        add_assignment(enrich_assignment(item))

    for item in materialized_source_events:
        add_event(enrich_event(item))

    for notice in materialized_notices:
        item, _reason = classify_notice(notice, generated_at)
        if isinstance(item, Assignment):
            add_assignment(item)
        elif isinstance(item, Event):
            add_event(item)

    state.assignments.sort(key=lambda item: (item.sync_due, item.course, item.title))
    state.completed_assignments.sort(key=lambda item: (item.sync_due, item.course, item.title))
    state.assignment_records.sort(key=lambda item: (item.sync_due, item.course, item.title))
    state.assignment_candidates.sort(key=lambda item: (item.sync_due, item.course, item.title))
    state.exams.sort(key=lambda item: (item.sync_due, item.course, item.title))
    state.exam_candidates.sort(key=lambda item: (item.sync_due, item.course, item.title))
    state.help_desk_items.sort(key=lambda item: (item.sync_due, item.course, item.title))
    return apply_overrides(state, overrides, source_by_url)
