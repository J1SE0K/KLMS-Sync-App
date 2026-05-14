from __future__ import annotations

import re

from .text import one_line


def first_capture(text: str, patterns: list[str]) -> str:
    compact = one_line(text)
    for pattern in patterns:
        match = re.search(pattern, compact, flags=re.IGNORECASE)
        if match and match.group(1):
            return cleanup(match.group(1))
    return ""


def cleanup(value: str) -> str:
    return one_line(value).rstrip(" .;,")


def extract_location(text: str) -> str:
    return first_capture(
        text,
        [
            r"(?:시험\s*)?(?:장소|고사장)\s*[:：]\s*(.+?)(?=\s*(?:시험\s*범위|범위|Date\s*&\s*Time|Coverage|Range|Time|Place|Location|$))",
            r"\b(?:Location|Place|Venue|Room)\s*:\s*(.+?)(?=\s*(?:Range|Coverage|Exam\s*Range|Time|Date\s*&\s*Time|시험\s*범위|시험\s*일시|$))",
        ],
    )


def extract_coverage(text: str) -> str:
    return first_capture(
        text,
        [
            r"(?:시험\s*)?범위\s*[:：]\s*(.+?)(?=\s*(?:Date\s*&\s*Time|Location|Place|Venue|Room|Coverage|Range|Time|시험\s*일시|시험\s*장소|$))",
            r"\b(?:Coverage|Range|Exam\s*Range)\s*:\s*(.+?)(?=\s*(?:[•⦁]|Time|Date\s*&\s*Time|Location|Place|Venue|Room|시험\s*일시|시험\s*장소|$))",
        ],
    )


def online_exam_location(url: str) -> str:
    if re.search(r"/mod/(?:assign|quiz)/view\.php", url or "", flags=re.IGNORECASE):
        return url
    return ""
