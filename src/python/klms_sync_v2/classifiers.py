from __future__ import annotations

import re

from .dates import parse_due_date_only, parse_due_datetime
from .exam_fields import extract_coverage, extract_location, online_exam_location
from .models import Assignment, Event, Notice, Page
from .text import (
    clipped,
    clean_course_candidate,
    html_to_text,
    one_line,
    split_course_title,
    strip_access_suffix,
    strip_klms_menu_prefix,
)


SUBMITTED_RE = re.compile(
    r"(채점을 위해 제출되었습니다|제출 완료|Submitted for grading|Submitted)",
    re.IGNORECASE,
)
NOT_SUBMITTED_RE = re.compile(r"(시도 하지 않음|You have not made a submission yet)", re.IGNORECASE)
ASSIGNMENT_WORD_RE = re.compile(
    r"(assignment|homework|hw\s*#?\s*\d*|wa\s*#?\s*\d+|pa\s*#?\s*\d+|"
    r"project|nano\s+quiz|quiz\b|과제|쪽글|퀴즈|report|proposal)",
    re.IGNORECASE,
)
ASSIGNMENT_RESULT_TITLE_RE = re.compile(
    r"(score|grade|solution|answer|statistics|claim|award|criteria|"
    r"성적|점수|채점|정답|해설|풀이|통계|이의\s*신청)",
    re.IGNORECASE,
)
EXAM_WORD_RE = re.compile(r"(midterm|final|exam|고사|시험)", re.IGNORECASE)
EXAM_RESULT_TITLE_RE = re.compile(
    r"(score|scores|grade|grades|grading|claim|statistics|result|results|posted|uploaded|"
    r"성적|점수|채점|이의|문의|통계|결과|공개)",
    re.IGNORECASE,
)
EXAM_CANCELLATION_RE = re.compile(r"(no\s+(?:midterm|final|exam)|시험\s*없|고사\s*없)", re.IGNORECASE)
HELP_DESK_RE = re.compile(r"(help\s*desk|헬프\s*데스크|헬프데스크)", re.IGNORECASE)
DEADLINE_RE = re.compile(
    r"(deadline|due|submit|submission|마감|기한|까지|제출)",
    re.IGNORECASE,
)


def submission_status(text: str) -> str:
    if NOT_SUBMITTED_RE.search(text):
        return "시도 하지 않음"
    if SUBMITTED_RE.search(text):
        return "제출 완료"
    return ""


def course_name_from_text(course: str, text: str) -> str:
    course = one_line(course)
    if not course:
        return ""
    course_patterns = [re.escape(course)]
    if "_2026_" in course:
        course_patterns.append(re.escape(course.split("_2026_", 1)[0]))

    for course_pattern in course_patterns:
        for match in re.finditer(r"\(" + course_pattern, text):
            prefix = one_line(text[max(0, match.start() - 240) : match.start()])
            candidate = clean_course_candidate(prefix)
            if candidate and len(candidate) <= 120:
                return candidate

    match = None
    for course_pattern in course_patterns:
        match = re.search(r"([^\s][^()]{2,120})\(" + course_pattern, text)
        if match:
            break
    if not match:
        return course
    return clean_course_candidate(match.group(1))


def clean_detail_instructions(text: str) -> str:
    text = one_line(text)
    if not text:
        return ""
    fields: list[str] = []
    location = extract_location(text)
    coverage = extract_coverage(text)
    if location:
        fields.append(f"시험 장소: {location}")
    if coverage:
        fields.append(f"시험 범위: {coverage}")
    if fields:
        return clipped(" ".join(fields))
    if (
        "메인 콘텐츠로 건너뛰기" in text
        or "강의실모바일메뉴" in text
        or "기출문제은행 마이크로러닝" in text
    ):
        return ""
    return clipped(text)


def exam_display_title(text: str, fallback: str) -> str:
    if re.search(r"(final|기말)", text, re.IGNORECASE):
        return "기말고사"
    if re.search(r"(midterm|중간)", text, re.IGNORECASE):
        return "중간고사"
    return one_line(fallback)


def clean_notice_source_title(value: str) -> str:
    raw = one_line(value)
    title = strip_access_suffix(strip_klms_menu_prefix(value))
    polluted = (
        len(title) > 180
        or "메인 콘텐츠로 건너뛰기" in title
        or "강의실모바일메뉴" in title
        or "기출문제은행 마이크로러닝" in title
        or "기출문제은행 마이크로러닝" in raw
    )
    if polluted and HELP_DESK_RE.search(raw):
        return "중간고사 헬프데스크" if re.search(r"(midterm|중간)", raw, re.IGNORECASE) else "헬프데스크"
    if polluted:
        return ""
    return title


def notice_course_name(notice: Notice, text: str) -> str:
    raw_course = one_line(notice.course)
    inferred = course_name_from_text(raw_course, text)
    cleaned = clean_course_candidate(inferred or raw_course)
    return cleaned or raw_course


def classify_detail_page(page: Page, generated_at: str) -> tuple[Assignment | Event | None, str]:
    raw_text = html_to_text(page.html) or page.text
    text = one_line(raw_text)
    course, title = split_course_title(page.title)
    course = course_name_from_text(course, text)
    title = strip_access_suffix(title)
    if not page.url:
        return None, "missing-url"

    due = parse_due_datetime(text, generated_at)
    if not due:
        return None, "missing-due"

    status = submission_status(text)
    title_and_text = f"{title} {text}"
    if HELP_DESK_RE.search(title_and_text):
        instructions = clean_detail_instructions(text)
        help_desk_title = "중간고사 헬프데스크" if re.search(r"(midterm|중간)", title_and_text, re.IGNORECASE) else "헬프데스크"
        return Event(
            url=page.url,
            course=course,
            title=help_desk_title,
            due=due.display,
            sync_due=due.iso,
            sync_start=due.start_iso,
            source="detail",
            source_title=title,
            instructions=instructions,
            location=extract_location(instructions),
            category="help_desk",
            type="help_desk",
        ), "help-desk"

    if EXAM_WORD_RE.search(title) and not ASSIGNMENT_WORD_RE.search(title):
        instructions = clean_detail_instructions(text)
        return Event(
            url=page.url,
            course=course,
            title=title,
            due=due.display,
            sync_due=due.iso,
            sync_start=due.start_iso,
            source="detail",
            source_title=title,
            instructions=instructions,
            location=extract_location(instructions) or online_exam_location(page.url),
            coverage=extract_coverage(instructions),
            category="exam",
            type="exam",
        ), "exam"

    if re.search(r"/mod/(?:assign|quiz)/", page.url, re.IGNORECASE) or ASSIGNMENT_WORD_RE.search(title):
        if status == "제출 완료":
            return Assignment(
                url=page.url,
                course=course,
                title=title,
                due=due.display,
                sync_due=due.iso,
                source="detail",
                submission=status,
                instructions=clean_detail_instructions(text),
                type="assign",
                auto_completed=True,
                record_status="completed",
                completion_reason="submitted",
            ), "submitted"
        if EXAM_WORD_RE.search(title) and not ASSIGNMENT_WORD_RE.search(title):
            return None, "exam-assignment-page"
        return Assignment(
            url=page.url,
            course=course,
            title=title,
            due=due.display,
            sync_due=due.iso,
            source="detail",
            submission=status,
            instructions=clean_detail_instructions(text),
            type="assign",
        ), "assignment"

    return None, "not-relevant"


def classify_notice(notice: Notice, generated_at: str) -> tuple[Assignment | Event | None, str]:
    text = one_line(" ".join([notice.body_text, notice.summary, notice.title]))
    if not text:
        return None, "empty"

    course = notice_course_name(notice, text)
    source_title = clean_notice_source_title(notice.title)
    due = parse_due_datetime(text, generated_at)

    if HELP_DESK_RE.search(text):
        if not due:
            return None, "missing-due"
        title = "중간고사 헬프데스크" if re.search(r"(midterm|중간)", text, re.IGNORECASE) else "헬프데스크"
        instructions = clipped(notice.body_text or notice.summary, 1200)
        return Event(
            url=notice.url,
            course=course,
            title=title,
            due=due.display,
            sync_due=due.iso,
            sync_start=due.start_iso,
            source="notice",
            source_title=source_title or title,
            instructions=instructions,
            location=extract_location(instructions),
            category="help_desk",
            type="help_desk",
        ), "help-desk"

    if EXAM_CANCELLATION_RE.search(text):
        return None, "not-relevant"

    if EXAM_WORD_RE.search(text) and not ASSIGNMENT_WORD_RE.search(notice.title):
        if EXAM_RESULT_TITLE_RE.search(notice.title):
            return None, "not-relevant"
        if not due:
            return None, "missing-due"
        title = exam_display_title(text, notice.title)
        instructions = clipped(notice.body_text or notice.summary, 1200)
        return Event(
            url=notice.url,
            course=course,
            title=title,
            due=due.display,
            sync_due=due.iso,
            sync_start=due.start_iso,
            source="notice",
            source_title=source_title or title,
            instructions=instructions,
            location=extract_location(instructions),
            coverage=extract_coverage(instructions),
            category="exam",
            type="exam",
        ), "exam-notice"

    if (
        ASSIGNMENT_WORD_RE.search(text)
        and DEADLINE_RE.search(text)
        and not ASSIGNMENT_RESULT_TITLE_RE.search(notice.title)
    ):
        due = due or parse_due_date_only(text, generated_at)
        if not due:
            return None, "missing-due"
        title_match = re.search(
            r"\b(Project\s+\d+|HW\s*#?\s*\d+|(?:Programming|Written)\s+Assignment\s+\d+|Assignment\s+\d+|Nano\s+Quiz(?:\s*#?\s*\d+)?|Quiz(?:\s*#?\s*\d+)?)\b|(?:\d+\s*주차\s*)?과제|퀴즈\s*\d*",
            text,
            re.IGNORECASE,
        )
        title = notice.title
        if title_match:
            title = title_match.group(1) or title_match.group(0)
        else:
            title = source_title or "과제"
        return Assignment(
            url=notice.url,
            course=course,
            title=one_line(title),
            due=due.display,
            sync_due=due.iso,
            source="notice",
            source_title=source_title or one_line(title),
            instructions=clipped(notice.body_text or notice.summary or source_title),
            type="assignment_notice",
        ), "assignment-notice"

    return None, "missing-due" if not due else "not-relevant"
