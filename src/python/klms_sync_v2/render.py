from __future__ import annotations

from html import escape
from typing import Any

from .text import one_line


def div(value: str) -> str:
    return f"<div>{value}</div>"


def br() -> str:
    return "<div><br></div>"


def compact(value: str, limit: int = 220) -> str:
    value = one_line(value)
    if len(value) <= limit:
        return value
    return value[: limit - 1].rstrip() + "..."


def item_lines(item: dict[str, Any], *, date_label: str) -> list[str]:
    lines = [
        div(f"<b>{escape(str(item.get('title') or ''))}</b>"),
        div(f"{date_label}: {escape(one_line(str(item.get('due') or '확인 필요')))}"),
    ]
    if item.get("course"):
        lines.append(div(f"과목: {escape(str(item['course']))}"))
    if item.get("source_title"):
        lines.append(div(f"출처: {escape(str(item['source_title']))}"))
    if item.get("coverage_summary"):
        lines.append(div(f"시험 범위: {escape(compact(str(item['coverage_summary']), 160))}"))
    if item.get("location"):
        lines.append(div(f"위치: {escape(str(item['location']))}"))
    if item.get("instructions"):
        lines.append(div(f"메모: {escape(compact(str(item['instructions'])))}"))
    if item.get("url"):
        url = escape(str(item["url"]), quote=True)
        lines.append(div(f'링크: <a href="{url}">KLMS 열기</a>'))
    lines.append(br())
    return lines


def completion_reason_label(reason: str) -> str:
    return {
        "manual_completed": "앱에서 완료 처리됨",
        "submitted": "KLMS 제출 완료",
        "past_due": "마감 지남",
        "auto_completed": "자동 완료 처리됨",
        "submitted_match": "제출 완료 항목과 일치",
    }.get(reason, "")


def completed_item_lines(item: dict[str, Any]) -> list[str]:
    lines = [
        div(f"☑ <b>{escape(str(item.get('title') or ''))}</b>"),
        div(f"마감: {escape(one_line(str(item.get('due') or '확인 필요')))}"),
    ]
    if item.get("course"):
        lines.append(div(f"과목: {escape(str(item['course']))}"))
    reason = completion_reason_label(str(item.get("completion_reason") or ""))
    if reason:
        lines.append(div(f"상태: {escape(reason)}"))
    if item.get("source_title"):
        lines.append(div(f"출처: {escape(str(item['source_title']))}"))
    if item.get("url"):
        url = escape(str(item["url"]), quote=True)
        lines.append(div(f'링크: <a href="{url}">KLMS 열기</a>'))
    lines.append(br())
    return lines


def render_success_html(state: dict[str, Any]) -> str:
    content = state.get("content") or {}
    assignments = content.get("assignments") or []
    completed_assignments = content.get("completed_assignments") or []
    exams = content.get("exam_items") or []
    exam_candidates = content.get("exam_candidates") or []
    assignment_candidates = content.get("assignment_candidates") or []
    help_desk = content.get("help_desk_items") or []
    generated_at = state.get("generated_at") or ""

    lines = [
        div(
            f"총 {len(assignments)}개 과제 / {len(exams)}개 시험 일정 / "
            f"{len(help_desk)}개 헬프데스크 안내 / {len(assignment_candidates)}개 과제 후보 / "
            f"{len(exam_candidates)}개 시험 후보 / {len(completed_assignments)}개 완료 기록"
        ),
        div(f"마지막 반영: {escape(str(generated_at))}"),
    ]
    if (
        not assignments
        and not completed_assignments
        and not exams
        and not exam_candidates
        and not assignment_candidates
        and not help_desk
    ):
        lines.append(div("현재 확인된 과제, 시험 일정, 헬프데스크 안내가 없어."))
        return "\n".join(lines)

    lines.append(br())
    sections = [
        ("시험 후보 (확인 필요)", exam_candidates, "일정"),
        ("헬프데스크", help_desk, "일정"),
        ("시험 일정", exams, "일정"),
        ("과제", assignments, "마감"),
        ("과제 후보 (확인 필요)", assignment_candidates, "마감"),
    ]
    for heading, items, date_label in sections:
        if not items:
            continue
        lines.append(div(f"<b>{escape(heading)}</b>"))
        for item in items:
            lines.extend(item_lines(item, date_label=date_label))
    if completed_assignments:
        lines.append(div("<b>완료 기록</b>"))
        for item in completed_assignments:
            lines.extend(completed_item_lines(item))
    return "\n".join(lines)


def render_error_html(message: str, previous_state: dict[str, Any]) -> str:
    last_success = (
        previous_state.get("generated_at") if previous_state.get("status") == "ok" else ""
    )
    lines = [
        div("<b>KLMS 동기화</b>"),
        div(f"문제가 생겨서 이번 동기화는 반영하지 못했어: {escape(message)}"),
    ]
    if last_success:
        lines.append(div(f"마지막 정상 반영: {escape(str(last_success))}"))
    return "\n".join(lines)
