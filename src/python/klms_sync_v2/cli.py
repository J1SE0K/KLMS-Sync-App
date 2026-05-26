from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
import sys
from typing import Any

from .models import Assignment, Event, Notice, Page
from .overrides import split_override_key
from .pipeline import build_sync_state
from .render import render_error_html, render_success_html
from .text import html_to_text, one_line, split_course_title


KST = timezone(timedelta(hours=9))


def legacy():
    from . import legacy_bridge

    return legacy_bridge


def load_json(path: str | Path) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def load_optional_json(path: str | Path | None, default: Any) -> Any:
    if not path:
        return default
    target = Path(path)
    if not target.exists():
        return default
    return load_json(target)


def write_json(path: str | Path, value: Any) -> None:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def load_detail_pages(path: str | Path) -> list[Page]:
    records = load_json(path)
    if not isinstance(records, list):
        raise ValueError(f"detail pages must be a JSON array: {path}")
    return [Page.from_fetch_record(record) for record in records]


def load_optional_pages(path: str | Path | None) -> list[Page]:
    if not path:
        return []
    target = Path(path)
    if not target.exists():
        return []
    records = load_json(target)
    if not isinstance(records, list):
        raise ValueError(f"pages must be a JSON array: {target}")
    return [Page.from_fetch_record(record) for record in records]


def load_notices(path: str | Path) -> tuple[str, list[Notice]]:
    digest = load_json(path)
    generated_at = str(digest.get("generated_at") or "")
    notices: list[Notice] = []
    for course in digest.get("courses") or []:
        for record in course.get("notices") or []:
            merged = dict(record)
            merged.setdefault("course", course.get("course") or "")
            notices.append(Notice.from_digest_record(merged))
    return generated_at, notices


def load_optional_notices(path: str | Path | None) -> tuple[str, list[Notice]]:
    if not path:
        return "", []
    target = Path(path)
    if not target.exists():
        return "", []
    return load_notices(target)


def now_kst_label() -> str:
    return datetime.now(KST).strftime("%Y-%m-%d %H:%M KST")


def looks_like_login_page(page: Page) -> bool:
    url = page.url.lower()
    text = one_line(html_to_text(page.html) or page.text).lower()
    if "/login/" in url or "sso.kaist.ac.kr" in url:
        return True
    if "로그인" in text and ("password" in text or "비밀번호" in text or "kaist" in text):
        return True
    if "login" in text and ("password" in text or "username" in text):
        return True
    return False


def validate_pages_for_state_build(pages: list[Page]) -> str:
    if any(looks_like_login_page(page) for page in pages):
        return "KLMS 로그인 세션이 풀렸어. 다시 로그인해 줘."
    return ""


def notice_from_article_page(page: Page) -> Notice | None:
    if "/mod/courseboard/article.php" not in page.url:
        return None
    text = one_line(html_to_text(page.html) or page.text)
    if not text:
        return None
    course_code, board_title = split_course_title(page.title)
    if not re.search(r"(notice|공지|q&a)", board_title, re.IGNORECASE):
        return None

    course = course_code
    course_match = re.search(r"([^\s][^()]{2,120})\(" + re.escape(course_code) + r"(?:\([^)]*\))?\)", text)
    if course_match:
        course = one_line(re.sub(r"<[^>]+>", "", course_match.group(1)))

    article_title = ""
    title_match = re.search(
        r"(?:Notice|공지|Q&A)\s+(.+?)\s+작성자\s*:",
        text,
        flags=re.IGNORECASE,
    )
    if title_match:
        article_title = one_line(title_match.group(1))
    if not article_title:
        return None

    body = text
    body_match = re.search(
        r"조회수\s*:\s*\d+\s+(.+?)(?:\s+(?:이전글|다음글|목록)\s*:|\s+목록\s+×|\s+Home\s+세션\s+연장|$)",
        text,
        flags=re.IGNORECASE,
    )
    if body_match:
        body = one_line(body_match.group(1))

    return Notice(
        url=page.url,
        course=course,
        title=article_title,
        body_text=body,
    )


def notices_from_article_pages(pages: list[Page]) -> list[Notice]:
    notices: list[Notice] = []
    seen: set[str] = set()
    for page in pages:
        notice = notice_from_article_page(page)
        if not notice or notice.url in seen:
            continue
        seen.add(notice.url)
        notices.append(notice)
    return notices


def merge_notices(*groups: list[Notice]) -> list[Notice]:
    merged: list[Notice] = []
    seen: set[str] = set()
    for group in groups:
        for notice in group:
            if notice.url in seen:
                continue
            seen.add(notice.url)
            merged.append(notice)
    return merged


def assignment_override_urls(overrides: dict[str, Any] | None) -> set[str]:
    if not overrides:
        return set()
    assignment_overrides = overrides.get("assignments") or {}
    if not isinstance(assignment_overrides, dict):
        return set()
    return {split_override_key(str(key))[0] for key in assignment_overrides}


def legacy_assignment_to_v2(record: dict[str, Any]) -> Assignment:
    title = clean_source_title(str(record.get("title") or ""))
    return Assignment(
        url=str(record.get("url") or ""),
        course=one_line(str(record.get("course") or "")),
        title=title,
        due=one_line(str(record.get("due") or record.get("schedule") or "")),
        sync_due=one_line(str(record.get("sync_due") or "")),
        source=one_line(str(record.get("time_source") or "source")),
        source_title=one_line(str(record.get("source_title") or title)),
        submission=one_line(str(record.get("submission") or "")),
        instructions=one_line(str(record.get("instructions") or "")),
        category="assignment",
        type=one_line(str(record.get("type") or "assign")),
    )


def legacy_event_to_v2(record: dict[str, Any]) -> Event:
    title = clean_source_title(str(record.get("title") or ""))
    return Event(
        url=str(record.get("url") or ""),
        course=one_line(str(record.get("course") or "")),
        title=title,
        due=one_line(str(record.get("due") or record.get("schedule") or "")),
        sync_due=one_line(str(record.get("sync_due") or "")),
        sync_start=one_line(str(record.get("sync_start") or "")),
        source=one_line(str(record.get("time_source") or "source")),
        source_title=one_line(str(record.get("source_title") or title)),
        instructions=one_line(str(record.get("instructions") or "")),
        location=one_line(str(record.get("location") or "")),
        coverage=one_line(str(record.get("coverage") or record.get("coverage_summary") or "")),
        category="exam",
        type=one_line(str(record.get("type") or "exam")),
    )


def clean_source_title(value: str) -> str:
    return re.sub(r"^\[(?:과제|퀴즈|시험|공지)\]\s*", "", one_line(value))


def load_source_items(
    *,
    dashboard_json: str | None,
    course_pages_json: str | None,
    all_week_course_pages_json: str | None,
    overrides: dict[str, Any] | None,
) -> tuple[list[Assignment], list[Event], dict[str, dict[str, str]]]:
    if not dashboard_json:
        return [], [], {}
    dashboard_path = Path(dashboard_json)
    if not dashboard_path.exists():
        return [], [], {}

    legacy_module = legacy().legacy
    dashboard = legacy_module.parse_dashboard_page(legacy_module.load_single_page(dashboard_path))
    if dashboard.status != "ok":
        return [], [], {}

    course_pages = legacy().load_pages(course_pages_json) + legacy().load_pages(
        all_week_course_pages_json
    )
    override_urls = assignment_override_urls(overrides)
    assignments: list[Assignment] = []
    events: list[Event] = []
    metadata: dict[str, dict[str, str]] = {}
    seen_urls: set[str] = set()

    for source_item in legacy_module.collect_candidate_items(dashboard, course_pages):
        if source_item.url in seen_urls:
            continue
        seen_urls.add(source_item.url)
        record = legacy_module.merge_assignment(source_item, None)
        title = clean_source_title(str(record.get("title") or source_item.title))
        metadata[source_item.url] = {
            "course": one_line(source_item.course),
            "title": title,
            "instructions": one_line(str(record.get("instructions") or "")),
        }
        has_resolved_time = bool(record.get("sync_due"))
        has_visible_schedule = bool(one_line(source_item.schedule))
        has_manual_override = source_item.url in override_urls
        if not (has_resolved_time or has_visible_schedule or has_manual_override):
            continue
        if has_resolved_time and legacy_module.assignment_should_be_exam_item(record):
            exam_record = legacy_module.assignment_to_exam_item(record)
            events.append(legacy_event_to_v2(exam_record))
        else:
            assignments.append(legacy_assignment_to_v2(record))

    return assignments, events, metadata


def status_from_state(state_payload: dict[str, Any], previous_state: dict[str, Any]) -> dict[str, Any]:
    content = state_payload.get("content") or {}
    previous_content = previous_state.get("content") or {}
    return {
        "changed": content != previous_content,
        "status": state_payload.get("status") or "ok",
        "assignment_count": len(content.get("assignments") or []),
        "completed_assignment_count": len(content.get("completed_assignments") or []),
        "assignment_record_count": len(content.get("assignment_records") or []),
        "exam_count": len(content.get("exam_items") or []),
        "exam_candidate_count": len(content.get("exam_candidates") or []),
        "assignment_candidate_count": len(content.get("assignment_candidates") or []),
        "help_desk_count": len(content.get("help_desk_items") or []),
    }


def command_build_state(args: argparse.Namespace) -> int:
    generated_at, notices = load_notices(args.notice_digest_json)
    if args.generated_at:
        generated_at = args.generated_at
    detail_pages = load_detail_pages(args.details_json)
    overrides = load_json(args.overrides_json) if args.overrides_json else None
    state = build_sync_state(
        generated_at=generated_at,
        detail_pages=detail_pages,
        notices=notices,
        overrides=overrides,
        include_past=args.include_past,
    )
    output = state.to_legacy_state() if args.legacy else state.to_debug_dict()
    if args.output_json:
        write_json(args.output_json, output)
    print(json.dumps(state.summary(), ensure_ascii=False, sort_keys=True))
    return 0


def command_build_note(args: argparse.Namespace) -> int:
    previous_state = load_optional_json(args.state_json, {})
    detail_pages = load_optional_pages(args.details_json)
    supplemental_pages = load_optional_pages(args.supplemental_pages_json)
    supplemental_detail_pages = load_optional_pages(args.supplemental_detail_pages_json)
    all_state_pages = detail_pages + supplemental_pages + supplemental_detail_pages

    validation_error = validate_pages_for_state_build(all_state_pages)
    if validation_error:
        payload = {
            "status": "error",
            "generated_at": now_kst_label(),
            "content": {
                "kind": "error",
                "message": validation_error,
                "last_success_at": previous_state.get("generated_at", ""),
            },
            "html": render_error_html(validation_error, previous_state),
        }
    else:
        digest_generated_at, digest_notices = load_optional_notices(args.notice_digest_json)
        page_notices = notices_from_article_pages(supplemental_detail_pages)
        generated_at = args.generated_at or digest_generated_at or now_kst_label()
        overrides = load_optional_json(args.overrides_json, None)
        source_assignments, source_events, source_metadata = load_source_items(
            dashboard_json=args.dashboard_json,
            course_pages_json=args.course_pages_json,
            all_week_course_pages_json=args.all_week_course_pages_json,
            overrides=overrides,
        )
        state = build_sync_state(
            generated_at=generated_at,
            detail_pages=detail_pages,
            notices=merge_notices(digest_notices, page_notices),
            source_assignments=source_assignments,
            source_events=source_events,
            source_metadata=source_metadata,
            overrides=overrides,
            include_past=args.include_past,
        )
        payload = state.to_legacy_state()
        payload["html"] = render_success_html(payload)

    if args.output_html:
        Path(args.output_html).write_text(str(payload.get("html") or ""), encoding="utf-8")
    write_json(args.output_state, payload)
    write_json(args.output_status, status_from_state(payload, previous_state))
    print(json.dumps(status_from_state(payload, previous_state), ensure_ascii=False, sort_keys=True))
    return 0


def command_list_course_urls(args: argparse.Namespace) -> int:
    legacy().print_lines(legacy().list_course_urls(args.dashboard_json))
    return 0


def command_list_detail_urls(args: argparse.Namespace) -> int:
    legacy().print_lines(
        legacy().list_detail_urls(args.dashboard_json, args.course_pages_json)
    )
    return 0


def command_list_supplemental_urls(args: argparse.Namespace) -> int:
    legacy().print_lines(
        legacy().list_supplemental_urls(args.course_pages_json, args.tier)
    )
    return 0


def command_list_supplemental_detail_urls(args: argparse.Namespace) -> int:
    legacy().print_lines(
        legacy().list_supplemental_detail_urls(
            args.supplemental_pages_json,
            board_article_state_json=args.board_article_state_json,
            existing_detail_pages_json=args.existing_detail_pages_json,
            output_board_article_state_json=args.output_board_article_state_json,
            include_non_relevant_primary=args.include_non_relevant_primary,
        )
    )
    return 0


def command_list_notice_board_page_urls(args: argparse.Namespace) -> int:
    legacy().print_lines(
        legacy().list_notice_board_page_urls(args.supplemental_primary_pages_json)
    )
    return 0


def command_list_notice_article_urls(args: argparse.Namespace) -> int:
    legacy().print_lines(
        legacy().list_notice_article_urls(
            args.supplemental_primary_pages_json,
            course_pages_json=args.course_pages_json,
            notice_board_state_json=args.notice_board_state_json,
            notice_summary_state_json=args.notice_summary_state_json,
            output_notice_board_state_json=args.output_notice_board_state_json,
        )
    )
    return 0


def command_build_notice_digest(args: argparse.Namespace) -> int:
    legacy().build_notice_digest(
        notice_board_state_json=args.notice_board_state_json,
        notice_article_pages_json=args.notice_article_pages_json,
        notice_summary_state_json=args.notice_summary_state_json,
        course_file_manifest_json=args.course_file_manifest_json,
        overrides_json=args.overrides_json,
        auto_important_keywords_apply=args.auto_important_keywords_apply,
        output_notice_summary_state_json=args.output_notice_summary_state_json,
        output_notice_digest_json=args.output_notice_digest_json,
    )
    return 0


def command_list_file_seed_urls(args: argparse.Namespace) -> int:
    legacy().print_lines(legacy().list_file_seed_urls(args.course_pages_json))
    return 0


def command_build_linked_html_index(args: argparse.Namespace) -> int:
    legacy().build_linked_html_index(
        pages_json=args.pages_json,
        existing_index_json=args.existing_index_json,
        changed_requested_url_file=args.changed_requested_url_file,
        output_index_json=args.output_index_json,
        output_urls_txt=args.output_urls_txt,
        file_scan=args.file_scan,
    )
    return 0


def command_check_login_status(args: argparse.Namespace) -> int:
    pages = load_json(args.pages_json)
    if not isinstance(pages, list) or not pages:
        payload = {
            "status": "error",
            "error": "empty_pages",
            "message": "KLMS 대시보드 확인에 실패했어. 다시 시도해 줘.",
            "url": "",
            "title": "",
        }
    else:
        page = pages[0] if isinstance(pages[0], dict) else {}
        url = str(page.get("url") or page.get("finalUrl") or page.get("requestedUrl") or "")
        title = str(page.get("title") or "")
        html = str(page.get("html") or "")
        if looks_like_login_page(Page(url=url, title=title, html=html)):
            payload = {
                "status": "error",
                "error": "login_required",
                "message": "KLMS 로그인이 풀린 것 같아. 다시 로그인해 줘.",
                "url": url,
                "title": title,
            }
        else:
            payload = {"status": "ok", "error": "", "message": "", "url": url, "title": title}
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="klms-sync-v2")
    subparsers = parser.add_subparsers(dest="command", required=True)

    build_state = subparsers.add_parser("build-state")
    build_state.add_argument("--details-json", required=True)
    build_state.add_argument("--notice-digest-json", required=True)
    build_state.add_argument("--output-json")
    build_state.add_argument("--generated-at")
    build_state.add_argument("--overrides-json")
    build_state.add_argument("--include-past", action="store_true")
    build_state.add_argument("--legacy", action="store_true")
    build_state.set_defaults(func=command_build_state)

    course_urls = subparsers.add_parser("list-course-urls")
    course_urls.add_argument("--dashboard-json", required=True)
    course_urls.set_defaults(func=command_list_course_urls)

    detail_urls = subparsers.add_parser("list-detail-urls")
    detail_urls.add_argument("--dashboard-json", required=True)
    detail_urls.add_argument("--course-pages-json")
    detail_urls.set_defaults(func=command_list_detail_urls)

    supplemental_urls = subparsers.add_parser("list-supplemental-urls")
    supplemental_urls.add_argument("--course-pages-json", required=True)
    supplemental_urls.add_argument("--tier", choices=("all", "primary", "secondary"), default="all")
    supplemental_urls.set_defaults(func=command_list_supplemental_urls)

    supplemental_detail_urls = subparsers.add_parser("list-supplemental-detail-urls")
    supplemental_detail_urls.add_argument("--supplemental-pages-json", required=True)
    supplemental_detail_urls.add_argument("--board-article-state-json")
    supplemental_detail_urls.add_argument("--existing-detail-pages-json")
    supplemental_detail_urls.add_argument("--output-board-article-state-json")
    supplemental_detail_urls.add_argument("--include-non-relevant-primary", action="store_true")
    supplemental_detail_urls.set_defaults(func=command_list_supplemental_detail_urls)

    notice_board_pages = subparsers.add_parser("list-notice-board-page-urls")
    notice_board_pages.add_argument("--supplemental-primary-pages-json", required=True)
    notice_board_pages.set_defaults(func=command_list_notice_board_page_urls)

    notice_articles = subparsers.add_parser("list-notice-article-urls")
    notice_articles.add_argument("--supplemental-primary-pages-json", required=True)
    notice_articles.add_argument("--course-pages-json")
    notice_articles.add_argument("--notice-board-state-json")
    notice_articles.add_argument("--notice-summary-state-json")
    notice_articles.add_argument("--output-notice-board-state-json")
    notice_articles.set_defaults(func=command_list_notice_article_urls)

    notice_digest = subparsers.add_parser("build-notice-digest")
    notice_digest.add_argument("--notice-board-state-json", required=True)
    notice_digest.add_argument("--notice-article-pages-json")
    notice_digest.add_argument("--notice-summary-state-json")
    notice_digest.add_argument("--course-file-manifest-json")
    notice_digest.add_argument("--overrides-json")
    notice_digest.add_argument("--auto-important-keywords-apply", action="store_true")
    notice_digest.add_argument("--output-notice-summary-state-json", required=True)
    notice_digest.add_argument("--output-notice-digest-json", required=True)
    notice_digest.set_defaults(func=command_build_notice_digest)

    file_seed_urls = subparsers.add_parser("list-file-seed-urls")
    file_seed_urls.add_argument("--course-pages-json", required=True)
    file_seed_urls.set_defaults(func=command_list_file_seed_urls)

    linked_html_index = subparsers.add_parser("build-linked-html-index")
    linked_html_index.add_argument("--pages-json", required=True)
    linked_html_index.add_argument("--existing-index-json")
    linked_html_index.add_argument("--changed-requested-url-file")
    linked_html_index.add_argument("--output-index-json", required=True)
    linked_html_index.add_argument("--output-urls-txt", required=True)
    linked_html_index.add_argument("--file-scan", action="store_true")
    linked_html_index.set_defaults(func=command_build_linked_html_index)

    login_status = subparsers.add_parser("check-login-status")
    login_status.add_argument("--pages-json", required=True)
    login_status.set_defaults(func=command_check_login_status)

    build_note = subparsers.add_parser("build-note")
    build_note.add_argument("--dashboard-json")
    build_note.add_argument("--course-pages-json")
    build_note.add_argument("--all-week-course-pages-json")
    build_note.add_argument("--details-json", required=True)
    build_note.add_argument("--supplemental-pages-json")
    build_note.add_argument("--supplemental-detail-pages-json")
    build_note.add_argument("--notice-digest-json")
    build_note.add_argument("--overrides-json")
    build_note.add_argument("--state-json", required=True)
    build_note.add_argument("--output-html")
    build_note.add_argument("--output-state", required=True)
    build_note.add_argument("--output-status", required=True)
    build_note.add_argument("--generated-at")
    build_note.add_argument("--include-past", action="store_true")
    build_note.set_defaults(func=command_build_note)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
