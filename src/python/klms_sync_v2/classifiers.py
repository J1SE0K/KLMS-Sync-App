from __future__ import annotations

import re

from .dates import parse_due_datetime
from .exam_fields import extract_coverage, extract_location, online_exam_location
from .models import Assignment, Event, Notice, Page
from .text import clipped, html_to_text, one_line, split_course_title, strip_access_suffix


SUBMITTED_RE = re.compile(
    r"(채점을 위해 제출되었습니다|제출 완료|Submitted for grading|Submitted)",
    re.IGNORECASE,
)
NOT_SUBMITTED_RE = re.compile(r"(시도 하지 않음|You have not made a submission yet)", re.IGNORECASE)
ASSIGNMENT_WORD_RE = re.compile(
    r"(assignment|homework|hw\b|project|과제|쪽글|report|proposal)",
    re.IGNORECASE,
)
EXAM_WORD_RE = re.compile(r"(midterm|final|exam|고사|시험)", re.IGNORECASE)
HELP_DESK_RE = re.compile(r"(help\s*desk|헬프\s*데스크|헬프데스크)", re.IGNORECASE)
DEADLINE_RE = re.compile(r"(deadline|due|마감|제출\s*기한)", re.IGNORECASE)


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

    menu_markers = [
        "포럼 선택",
        "기출문제은행",
        "마이크로러닝",
        "CELT 교수법",
        "Panopto 사용법",
        "CELT 학습법 특강",
    ]
    for course_pattern in course_patterns:
        for match in re.finditer(r"\(" + course_pattern, text):
            prefix = one_line(text[max(0, match.start() - 240) : match.start()])
            candidate = prefix
            for marker in menu_markers:
                if marker in candidate:
                    candidate = candidate.split(marker)[-1]
            candidate = one_line(candidate).strip(" -–—:/")
            if candidate and len(candidate) <= 120:
                return candidate

    match = None
    for course_pattern in course_patterns:
        match = re.search(r"([^\s][^()]{2,120})\(" + course_pattern, text)
        if match:
            break
    if not match:
        return course
    candidate = one_line(match.group(1))
    for marker in menu_markers:
        if marker in candidate:
            candidate = candidate.split(marker)[-1]
    return one_line(candidate)


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
        return Event(
            url=page.url,
            course=course,
            title="헬프데스크",
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

    if "/mod/assign/" in page.url or ASSIGNMENT_WORD_RE.search(title):
        if status == "제출 완료":
            return None, "submitted"
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

    due = parse_due_datetime(text, generated_at)
    if not due:
        return None, "missing-due"

    if HELP_DESK_RE.search(text):
        title = "중간고사 헬프데스크" if re.search(r"(midterm|중간)", text, re.IGNORECASE) else "헬프데스크"
        instructions = clipped(notice.body_text or notice.summary)
        return Event(
            url=notice.url,
            course=notice.course,
            title=title,
            due=due.display,
            sync_due=due.iso,
            sync_start=due.start_iso,
            source="notice",
            source_title=notice.title,
            instructions=instructions,
            location=extract_location(instructions),
            category="help_desk",
            type="help_desk",
        ), "help-desk"

    if EXAM_WORD_RE.search(text) and not ASSIGNMENT_WORD_RE.search(text):
        title = "중간고사" if re.search(r"(midterm|중간)", text, re.IGNORECASE) else notice.title
        instructions = clipped(notice.body_text or notice.summary)
        return Event(
            url=notice.url,
            course=notice.course,
            title=title,
            due=due.display,
            sync_due=due.iso,
            sync_start=due.start_iso,
            source="notice",
            source_title=notice.title,
            instructions=instructions,
            location=extract_location(instructions),
            coverage=extract_coverage(instructions),
            category="exam_candidate",
            type="exam",
        ), "exam-candidate"

    if ASSIGNMENT_WORD_RE.search(text) and DEADLINE_RE.search(text):
        title_match = re.search(
            r"\b(Project\s+\d+|HW\s*\d+|(?:Programming|Written)\s+Assignment\s+\d+|Assignment\s+\d+)\b",
            text,
            re.IGNORECASE,
        )
        title = title_match.group(1) if title_match else notice.title
        return Assignment(
            url=notice.url,
            course=notice.course,
            title=one_line(title),
            due=due.display,
            sync_due=due.iso,
            source="notice",
            source_title=notice.title,
            instructions=notice.title,
            type="assignment_notice",
        ), "assignment-notice"

    return None, "not-relevant"
