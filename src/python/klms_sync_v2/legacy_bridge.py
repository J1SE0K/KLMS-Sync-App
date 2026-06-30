from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import klms_sync as legacy


def load_optional_json(path: str | None) -> dict[str, Any]:
    if not path:
        return {}
    target = Path(path)
    if not target.exists():
        return {}
    return legacy.load_optional_json(target)


def load_pages(path: str | None) -> list[dict[str, Any]]:
    if not path:
        return []
    return legacy.load_pages(Path(path))


def print_lines(values: list[str]) -> None:
    for value in values:
        print(value)


def list_course_urls(dashboard_json: str) -> list[str]:
    return legacy.parse_course_urls_from_dashboard(legacy.load_single_page(Path(dashboard_json)))


def build_academic_term_catalog(dashboard_json: str, output_json: str) -> None:
    catalog = legacy.parse_academic_term_catalog_from_dashboard(
        legacy.load_single_page(Path(dashboard_json))
    )
    legacy.write_json(Path(output_json), catalog.to_json())


def list_detail_urls(dashboard_json: str, course_pages_json: str | None = None) -> list[str]:
    dashboard_page = legacy.load_single_page(Path(dashboard_json))
    course_pages = load_pages(course_pages_json)
    dashboard = legacy.parse_dashboard_page(dashboard_page)
    return [item.url for item in legacy.collect_candidate_items(dashboard, course_pages)]


def list_supplemental_urls(course_pages_json: str, tier: str = "all") -> list[str]:
    return legacy.collect_supplemental_urls(load_pages(course_pages_json), tier)


def list_supplemental_detail_urls(
    supplemental_pages_json: str,
    *,
    board_article_state_json: str | None = None,
    existing_detail_pages_json: str | None = None,
    output_board_article_state_json: str | None = None,
    include_non_relevant_primary: bool = True,
) -> list[str]:
    urls, next_state = legacy.collect_supplemental_detail_urls(
        load_pages(supplemental_pages_json),
        load_optional_json(board_article_state_json),
        existing_detail_pages=load_pages(existing_detail_pages_json),
        include_non_relevant_primary=include_non_relevant_primary,
    )
    if output_board_article_state_json:
        legacy.write_json(Path(output_board_article_state_json), next_state)
    return urls


def list_notice_board_page_urls(supplemental_primary_pages_json: str) -> list[str]:
    return legacy.collect_notice_board_page_urls(load_pages(supplemental_primary_pages_json))


def list_notice_article_urls(
    supplemental_primary_pages_json: str,
    *,
    course_pages_json: str | None = None,
    notice_board_state_json: str | None = None,
    notice_summary_state_json: str | None = None,
    output_notice_board_state_json: str | None = None,
) -> list[str]:
    course_pages = load_pages(course_pages_json)
    urls, next_state = legacy.collect_notice_article_urls(
        load_pages(supplemental_primary_pages_json),
        load_optional_json(notice_board_state_json),
        load_optional_json(notice_summary_state_json),
        legacy.build_activity_course_lookup(course_pages),
    )
    if output_notice_board_state_json:
        legacy.write_json(Path(output_notice_board_state_json), next_state)
    return urls


def build_notice_digest(
    *,
    notice_board_state_json: str,
    notice_article_pages_json: str | None = None,
    notice_summary_state_json: str | None = None,
    course_file_manifest_json: str | None = None,
    overrides_json: str | None = None,
    auto_important_keywords_apply: bool = False,
    output_notice_summary_state_json: str,
    output_notice_digest_json: str,
) -> None:
    notice_board_state = load_optional_json(notice_board_state_json)
    notice_article_pages = load_pages(notice_article_pages_json)
    previous_summary = load_optional_json(notice_summary_state_json)
    course_file_manifest = load_optional_json(course_file_manifest_json)
    override_document = (
        legacy.load_override_document(Path(overrides_json))
        if overrides_json
        else {"notice_filters": {}}
    )
    next_summary, notice_digest = legacy.build_notice_digest(
        notice_board_state,
        notice_article_pages,
        previous_summary,
        course_file_manifest,
        override_document.get("notice_filters", {}),
        auto_important_keywords_apply,
    )
    legacy.write_json(Path(output_notice_summary_state_json), next_summary)
    legacy.write_json(Path(output_notice_digest_json), notice_digest)


def list_file_seed_urls(course_pages_json: str) -> list[str]:
    return legacy.collect_file_seed_urls(load_pages(course_pages_json))


def build_linked_html_index(
    *,
    pages_json: str,
    existing_index_json: str | None = None,
    changed_requested_url_file: str | None = None,
    output_index_json: str,
    output_urls_txt: str,
    file_scan: bool = False,
) -> None:
    changed_urls = (
        legacy.load_requested_url_set(Path(changed_requested_url_file))
        if changed_requested_url_file
        else None
    )
    urls, next_index = legacy.build_linked_html_index(
        load_pages(pages_json),
        existing_index=load_optional_json(existing_index_json),
        changed_requested_urls=changed_urls,
        file_scan_only=file_scan,
    )
    legacy.write_json(Path(output_index_json), next_index)
    legacy.write_text(Path(output_urls_txt), "\n".join(urls) + ("\n" if urls else ""))


def check_login_status(pages_json: str) -> dict[str, Any]:
    return legacy.analyze_login_status(load_pages(pages_json))


def json_compact(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
