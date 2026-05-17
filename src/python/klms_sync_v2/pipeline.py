from __future__ import annotations

from collections.abc import Iterable
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
    overrides: dict | None = None,
    include_past: bool = False,
) -> SyncState:
    state = SyncState(generated_at=generated_at)
    seen_assignments: set[str] = set()
    seen_events: set[tuple[str, str]] = set()
    submitted_tokens: set[str] = set()
    materialized_detail_pages = list(detail_pages)
    materialized_notices = list(notices)
    source_by_url: dict[str, dict[str, str]] = {}

    for page in materialized_detail_pages:
        raw_text = html_to_text(page.html) or page.text
        course, title = split_course_title(page.title)
        source_by_url[page.url] = {
            "course": course_name_from_text(course, one_line(raw_text)),
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

    def add_assignment(item: Assignment) -> None:
        if not include_past and is_past(item.sync_due, generated_at):
            return
        normalized = one_line(" ".join([item.title, item.source_title])).lower()
        if any(token and token in normalized for token in submitted_tokens):
            return
        if item.url in seen_assignments:
            return
        seen_assignments.add(item.url)
        if item.category == "assignment_candidate":
            state.assignment_candidates.append(item)
        else:
            state.assignments.append(item)

    def add_event(item: Event) -> None:
        if item.category == "exam_candidate" and not include_past and is_past(item.sync_due, generated_at):
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
            add_assignment(item)
        elif isinstance(item, Event):
            add_event(item)

    for notice in materialized_notices:
        item, _reason = classify_notice(notice, generated_at)
        if isinstance(item, Assignment):
            add_assignment(item)
        elif isinstance(item, Event):
            add_event(item)

    state.assignments.sort(key=lambda item: (item.sync_due, item.course, item.title))
    state.assignment_candidates.sort(key=lambda item: (item.sync_due, item.course, item.title))
    state.exams.sort(key=lambda item: (item.sync_due, item.course, item.title))
    state.exam_candidates.sort(key=lambda item: (item.sync_due, item.course, item.title))
    state.help_desk_items.sort(key=lambda item: (item.sync_due, item.course, item.title))
    return apply_overrides(state, overrides, source_by_url)
