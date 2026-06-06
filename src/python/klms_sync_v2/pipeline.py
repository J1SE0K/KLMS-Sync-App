from __future__ import annotations

from collections.abc import Iterable
from dataclasses import replace
import re
from urllib.parse import parse_qsl, urlparse

from .classifiers import classify_detail_page, classify_notice, clean_detail_instructions
from .classifiers import course_name_from_text
from .dates import is_past
from .models import Assignment, Event, Notice, Page, SyncState
from .overrides import apply_overrides
from .text import clipped, html_to_text, one_line, split_course_title, strip_access_suffix


def _identity_text(value: str) -> str:
    return one_line(str(value or "")).casefold()


def _canonical_url_identity(url: str) -> str:
    normalized = one_line(url)
    if not normalized:
        return ""

    parsed = urlparse(normalized)
    path = parsed.path.lower()
    query = {key.lower(): value for key, value in parse_qsl(parsed.query, keep_blank_values=True)}
    if "/mod/courseboard/article.php" in path and query.get("bwid"):
        return f"{path}?bwid={query['bwid']}"
    if query.get("id"):
        return f"{path}?id={query['id']}"
    if query.get("bwid"):
        return f"{path}?bwid={query['bwid']}"
    return normalized.casefold()


def assignment_identity_key(item: Assignment) -> tuple[str, str, str, str]:
    course = _identity_text(item.course)
    title = _identity_text(item.title)
    due = _identity_text(item.sync_due or item.due)
    if course and title and due:
        return ("logical", course, title, due)

    return ("url", _canonical_url_identity(item.url), title, due)


def _assignment_module_score(item: Assignment) -> int:
    match = re.search(r"/mod/([^/]+)/", item.url)
    module = match.group(1).lower() if match else ""
    if module in {"assign", "quiz"}:
        return 3
    if module == "courseboard":
        return 2
    return 1


def _assignment_quality_score(item: Assignment) -> tuple[int, int, int, int, int, int, int]:
    category_score = 3 if item.category == "assignment" else 2 if item.category == "assignment_candidate" else 1
    status_score = 3 if item.record_status == "active" else 2 if item.record_status == "completed" else 1
    return (
        _assignment_module_score(item),
        category_score,
        status_score,
        1 if item.sync_due else 0,
        len(one_line(item.instructions)),
        len(one_line(item.source_title)),
        len(one_line(item.url)),
    )


def merge_assignment(existing: Assignment, candidate: Assignment) -> Assignment:
    base, fallback = (
        (candidate, existing)
        if _assignment_quality_score(candidate) > _assignment_quality_score(existing)
        else (existing, candidate)
    )
    updates: dict[str, str | bool] = {}
    for field in (
        "url",
        "course",
        "title",
        "due",
        "sync_due",
        "source",
        "source_title",
        "submission",
        "category",
        "type",
        "record_status",
        "completion_reason",
    ):
        if not getattr(base, field) and getattr(fallback, field):
            updates[field] = getattr(fallback, field)
    if len(one_line(fallback.instructions)) > len(one_line(base.instructions)):
        updates["instructions"] = fallback.instructions
    if not base.auto_completed and fallback.auto_completed and base.record_status == "completed":
        updates["auto_completed"] = True
    return replace(base, **updates)


def dedupe_assignments(items: Iterable[Assignment]) -> list[Assignment]:
    indexes: dict[tuple[str, str, str, str], int] = {}
    deduped: list[Assignment] = []
    for item in items:
        key = assignment_identity_key(item)
        if key in indexes:
            index = indexes[key]
            deduped[index] = merge_assignment(deduped[index], item)
            continue
        indexes[key] = len(deduped)
        deduped.append(item)
    return deduped


def dedupe_assignment_state(state: SyncState) -> SyncState:
    state.assignments = dedupe_assignments(state.assignments)
    state.completed_assignments = dedupe_assignments(state.completed_assignments)
    state.assignment_records = dedupe_assignments(state.assignment_records)
    state.assignment_candidates = dedupe_assignments(state.assignment_candidates)
    return state


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
    state = dedupe_assignment_state(state)
    state = apply_overrides(
        state,
        overrides,
        source_by_url,
        generated_at=generated_at,
        include_past=include_past,
    )
    return dedupe_assignment_state(state)
