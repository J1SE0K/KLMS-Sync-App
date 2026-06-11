from __future__ import annotations

import html
import re


SCRIPT_RE = re.compile(r"<script[\s\S]*?</script>", re.IGNORECASE)
STYLE_RE = re.compile(r"<style[\s\S]*?</style>", re.IGNORECASE)
TAG_RE = re.compile(r"<[^>]+>")
SPACE_RE = re.compile(r"\s+")
KLMS_MENU_MARKERS = (
    "포럼 선택",
    "기출문제은행",
    "마이크로러닝",
    "CELT 교수법",
    "Panopto 사용법",
    "CELT 학습법 특강",
)


def html_to_text(value: str) -> str:
    cleaned = SCRIPT_RE.sub(" ", value or "")
    cleaned = STYLE_RE.sub(" ", cleaned)
    cleaned = TAG_RE.sub(" ", cleaned)
    cleaned = html.unescape(cleaned)
    return SPACE_RE.sub(" ", cleaned).strip()


def one_line(value: str) -> str:
    return SPACE_RE.sub(" ", (value or "").replace("\xa0", " ")).strip()


def split_course_title(title: str) -> tuple[str, str]:
    title = one_line(title)
    if ":" not in title:
        return "", title
    course, item = title.split(":", 1)
    return normalize_course_name(course), one_line(item)


def normalize_course_name(value: str) -> str:
    value = one_line(value)
    value = value.removeprefix("강좌:")
    return re.sub(r"\s+", " ", value).strip()


def strip_klms_menu_prefix(value: str) -> str:
    value = one_line(value)
    for marker in KLMS_MENU_MARKERS:
        if marker in value:
            value = value.rsplit(marker, 1)[-1]
    value = re.sub(r"^[\])>\\|/:;,\s-]+", "", value)
    value = re.sub(r"^\[?KLMS[^\]]*\]?\s*", "", value, flags=re.IGNORECASE)
    return one_line(value)


def clean_course_candidate(value: str) -> str:
    value = strip_klms_menu_prefix(value)
    value = re.sub(
        r"\s*[-–—]\s*(?:중간|기말)?(?:고사|시험)?\s*헬프\s*데스크.*$",
        "",
        value,
        flags=re.IGNORECASE,
    )
    value = re.sub(r"\s*[-–—]\s*(?:midterm|final)?(?:\s+exam)?\s+help\s*desk.*$", "", value, flags=re.IGNORECASE)
    return one_line(value).strip(" -–—:/")


def strip_access_suffix(value: str) -> str:
    value = one_line(value)
    return re.sub(r"\s*(URL|파일|Folder)$", "", value).strip()


def clipped(value: str, max_len: int = 600) -> str:
    value = one_line(value)
    if len(value) <= max_len:
        return value
    return value[: max_len - 1].rstrip() + "..."
