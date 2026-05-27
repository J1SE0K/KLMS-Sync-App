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
    return cleanup_location(
        first_capture(
            text,
            [
                r"(?:시험\s*)?(?:장소|고사장)\s*[:：]\s*(.+?)(?=\s*(?:시험\s*범위|범위|Date\s*&\s*Time|Coverage|Range|Time|Place|Location|$))",
                r"\b(?:Location|Place|Venue|Room)\s*:\s*(.+?)(?=\s*(?:Range|Coverage|Exam\s*Range|Time|Date\s*&\s*Time|시험\s*범위|시험\s*일시|$))",
                r"\b(?:in|at)\s+(?:the\s+)?((?:[A-Z][A-Za-z0-9'’().&+-]*\s*){1,8}(?:Auditorium|Room|Hall|Classroom|Lecture\s+Room|Lab|Building))\b",
            ],
        )
    )


def cleanup_location(value: str) -> str:
    return re.sub(r"^(?:the|a|an)\s+", "", value, flags=re.IGNORECASE)


def extract_coverage(text: str) -> str:
    return first_capture(
        text,
        [
            r"(?:시험\s*)?범위\s*[:：]\s*(.+?)(?=\s*(?:Date\s*&\s*Time|Location|Place|Venue|Room|Coverage|Range|Time|시험\s*일시|시험\s*장소|$))",
            r"\b(?:Coverage|Range|Exam\s*Range)\s*:\s*(.+?)(?=\s*(?:[•⦁]|Time|Date\s*&\s*Time|Location|Place|Venue|Room|시험\s*일시|시험\s*장소|$))",
            r"(?:주제|논제)\s*[:：]\s*(.+?)(?=\s*(?:주의\s*사항|주의사항|시험은|시험\s*시간|Please\s+analyse|Please\s+analyze|$))",
            r"<\s*(Write\s+an\s+essay.+?)\s*>",
        ],
    )


def online_exam_location(url: str) -> str:
    if re.search(r"/mod/(?:assign|quiz)/view\.php", url or "", flags=re.IGNORECASE):
        return url
    return ""
