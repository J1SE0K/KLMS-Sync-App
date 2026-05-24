from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone, timedelta
import re


KST = timezone(timedelta(hours=9))

KO_DATETIME_RE = re.compile(
    r"(?P<year>20\d{2})\s*년\s*"
    r"(?P<month>\d{1,2})\s*월\s*"
    r"(?P<day>\d{1,2})\s*일"
    r"(?:\s*\([^)]*\))?\s*"
    r"(?:(?P<ampm>오전|오후)\s*)?"
    r"(?P<hour>\d{1,2})"
    r"(?:\s*:\s*(?P<minute>\d{1,2}))?"
)
SLASH_DATETIME_RE = re.compile(
    r"(?<!\d)(?P<month>\d{1,2})\s*/\s*(?P<day>\d{1,2})"
    r"(?:\s*(?P<hour>\d{1,2})\s*:\s*(?P<minute>\d{2})(?::\d{2})?)"
)
SLASH_RANGE_RE = re.compile(
    r"(?<!\d)(?P<month>\d{1,2})\s*/\s*(?P<day>\d{1,2})"
    r".{0,32}?"
    r"(?P<start_hour>\d{1,2})\s*:\s*(?P<start_minute>\d{2})\s*(?P<start_ampm>AM|PM|am|pm)?"
    r"\s*(?:-|~|to|부터|에서)\s*"
    r"(?P<end_hour>\d{1,2})\s*:\s*(?P<end_minute>\d{2})\s*(?P<end_ampm>AM|PM|am|pm)?"
)
EN_MONTH_RE = re.compile(
    r"\b(?P<month>Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|"
    r"Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"
    r"\s+(?P<day>\d{1,2})(?:st|nd|rd|th)?"
    r"(?:,\s*(?P<year>20\d{2}))?"
    r".{0,24}?"
    r"(?P<hour>\d{1,2})\s*:\s*(?P<minute>\d{2})(?::\d{2})?\s*(?P<ampm>AM|PM|am|pm)?"
)
EN_MONTH_RANGE_RE = re.compile(
    r"\b(?P<month>Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|"
    r"Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"
    r"\s+(?P<day>\d{1,2})(?:st|nd|rd|th)?"
    r"(?:,\s*(?P<year>20\d{2}))?"
    r".{0,40}?"
    r"(?P<start_hour>\d{1,2})\s*:\s*(?P<start_minute>\d{2})\s*(?P<start_ampm>AM|PM|am|pm)?"
    r"\s*(?:-|~|to|부터|에서)\s*"
    r"(?P<end_hour>\d{1,2})\s*:\s*(?P<end_minute>\d{2})\s*(?P<end_ampm>AM|PM|am|pm)?"
)
REFERENCE_DATETIME_RE = re.compile(
    r"\b(?P<year>20\d{2})[-/.](?P<month>\d{1,2})[-/.](?P<day>\d{1,2})"
    r"[ T]+(?P<hour>\d{1,2}):(?P<minute>\d{2})"
)

MONTHS = {
    "jan": 1,
    "feb": 2,
    "mar": 3,
    "apr": 4,
    "may": 5,
    "jun": 6,
    "jul": 7,
    "aug": 8,
    "sep": 9,
    "oct": 10,
    "nov": 11,
    "dec": 12,
}


@dataclass(frozen=True)
class ParsedDate:
    display: str
    iso: str
    start_iso: str = ""


def parse_reference_year(generated_at: str, default: int | None = None) -> int:
    match = re.search(r"\b(20\d{2})\b", generated_at or "")
    if match:
        return int(match.group(1))
    return default or datetime.now(KST).year


def parse_reference_datetime(generated_at: str) -> datetime | None:
    text = (generated_at or "").strip()
    if not text:
        return None

    iso_candidate = text.removesuffix(" KST")
    try:
        parsed = datetime.fromisoformat(iso_candidate.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=KST)
        return parsed.astimezone(KST)
    except ValueError:
        pass

    match = REFERENCE_DATETIME_RE.search(text)
    if not match:
        return None
    return build_datetime(
        int(match.group("year")),
        int(match.group("month")),
        int(match.group("day")),
        int(match.group("hour")),
        int(match.group("minute")),
    )


def normalize_ampm(hour: int, ampm: str | None) -> int:
    ampm = (ampm or "").lower()
    if ampm in ("오후", "pm") and hour < 12:
        return hour + 12
    if ampm in ("오전", "am") and hour == 12:
        return 0
    return hour


def to_iso(year: int, month: int, day: int, hour: int, minute: int) -> str:
    return datetime(year, month, day, hour, minute, tzinfo=KST).isoformat()


def korean_weekday(value: datetime) -> str:
    return ["월요일", "화요일", "수요일", "목요일", "금요일", "토요일", "일요일"][
        value.weekday()
    ]


def korean_clock(value: datetime) -> str:
    hour = value.hour % 12 or 12
    meridiem = "오전" if value.hour < 12 else "오후"
    return f"{meridiem} {hour}:{value.minute:02d}"


def korean_datetime_display(value: datetime) -> str:
    return (
        f"{value.year}년 {value.month}월 {value.day}일({korean_weekday(value)}) "
        f"{korean_clock(value)}"
    )


def korean_range_display(start: datetime, end: datetime) -> str:
    if start.date() == end.date():
        return (
            f"{start.year}년 {start.month}월 {start.day}일({korean_weekday(start)}) "
            f"{korean_clock(start)} - {korean_clock(end)}"
        )
    return f"{korean_datetime_display(start)} - {korean_datetime_display(end)}"


def build_datetime(year: int, month: int, day: int, hour: int, minute: int) -> datetime:
    return datetime(year, month, day, hour, minute, tzinfo=KST)


def parse_due_datetime(text: str, generated_at: str = "") -> ParsedDate | None:
    text = text or ""
    year = parse_reference_year(generated_at)

    match = SLASH_RANGE_RE.search(text)
    if match:
        end_ampm = match.group("end_ampm")
        start_ampm = match.group("start_ampm") or end_ampm
        start = build_datetime(
            year,
            int(match.group("month")),
            int(match.group("day")),
            normalize_ampm(int(match.group("start_hour")), start_ampm),
            int(match.group("start_minute")),
        )
        end = build_datetime(
            year,
            int(match.group("month")),
            int(match.group("day")),
            normalize_ampm(int(match.group("end_hour")), end_ampm),
            int(match.group("end_minute")),
        )
        return ParsedDate(
            display=korean_range_display(start, end),
            iso=end.isoformat(),
            start_iso=start.isoformat(),
        )

    match = EN_MONTH_RANGE_RE.search(text)
    if match:
        month = MONTHS[match.group("month")[:3].lower()]
        end_ampm = match.group("end_ampm")
        start_ampm = match.group("start_ampm") or end_ampm
        start = build_datetime(
            int(match.group("year") or year),
            month,
            int(match.group("day")),
            normalize_ampm(int(match.group("start_hour")), start_ampm),
            int(match.group("start_minute")),
        )
        end = build_datetime(
            int(match.group("year") or year),
            month,
            int(match.group("day")),
            normalize_ampm(int(match.group("end_hour")), end_ampm),
            int(match.group("end_minute")),
        )
        return ParsedDate(
            display=korean_range_display(start, end),
            iso=end.isoformat(),
            start_iso=start.isoformat(),
        )

    match = KO_DATETIME_RE.search(text)
    if match:
        hour = normalize_ampm(int(match.group("hour")), match.group("ampm"))
        minute = int(match.group("minute") or "0")
        value = build_datetime(
            int(match.group("year")),
            int(match.group("month")),
            int(match.group("day")),
            hour,
            minute,
        )
        return ParsedDate(display=korean_datetime_display(value), iso=value.isoformat())

    match = SLASH_DATETIME_RE.search(text)
    if match:
        value = build_datetime(
            year,
            int(match.group("month")),
            int(match.group("day")),
            int(match.group("hour")),
            int(match.group("minute")),
        )
        return ParsedDate(display=korean_datetime_display(value), iso=value.isoformat())

    match = EN_MONTH_RE.search(text)
    if match:
        month = MONTHS[match.group("month")[:3].lower()]
        hour = normalize_ampm(int(match.group("hour")), match.group("ampm"))
        minute = int(match.group("minute"))
        value = build_datetime(
            int(match.group("year") or year),
            month,
            int(match.group("day")),
            hour,
            minute,
        )
        return ParsedDate(display=korean_datetime_display(value), iso=value.isoformat())

    return None


def is_past(iso_value: str, generated_at: str = "") -> bool:
    if not iso_value:
        return False
    try:
        parsed = datetime.fromisoformat(iso_value)
    except ValueError:
        return False
    reference = parse_reference_datetime(generated_at or "") or datetime.now(KST)
    return parsed < reference
