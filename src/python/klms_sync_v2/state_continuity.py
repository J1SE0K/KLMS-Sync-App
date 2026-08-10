from __future__ import annotations

from typing import Any

from .models import Assignment, Event
from .text import one_line


def prior_active_assignment_records(
    previous_state: dict[str, Any],
    course_pages: list[dict[str, Any]],
    current_items: list[Assignment | Event],
) -> list[dict[str, Any]]:
    from . import legacy_bridge

    legacy_module = legacy_bridge.legacy
    visible_module_urls = {
        url
        for course_page in course_pages
        for url in legacy_module.course_page_semantic_certificate(
            course_page
        ).module_urls
    }
    current_urls = {
        legacy_module.normalize_url(item.url)
        for item in current_items
    }
    previous_content = previous_state.get("content")
    if not isinstance(previous_content, dict):
        return []

    records: list[dict[str, Any]] = []
    for section in ("assignment_records", "assignments"):
        previous_records = previous_content.get(section)
        if not isinstance(previous_records, list):
            continue
        for record in previous_records:
            if not isinstance(record, dict):
                continue
            url = legacy_module.normalize_url(str(record.get("url") or ""))
            record_status = one_line(str(record.get("record_status") or "active"))
            if (
                not url
                or record_status != "active"
                or url not in visible_module_urls
                or url in current_urls
            ):
                continue
            records.append(record)
            current_urls.add(url)
    return records
