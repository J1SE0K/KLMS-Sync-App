from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Literal


Category = Literal["assignment", "assignment_candidate", "exam", "exam_candidate", "help_desk"]


@dataclass(frozen=True)
class Page:
    url: str
    title: str = ""
    html: str = ""
    text: str = ""

    @classmethod
    def from_fetch_record(cls, record: dict[str, Any]) -> "Page":
        return cls(
            url=str(record.get("requestedUrl") or record.get("url") or ""),
            title=str(record.get("title") or ""),
            html=str(record.get("html") or record.get("text") or ""),
            text=str(record.get("text") or ""),
        )


@dataclass(frozen=True)
class Notice:
    url: str
    course: str
    title: str
    posted_at: str = ""
    body_text: str = ""
    summary: str = ""

    @classmethod
    def from_digest_record(cls, record: dict[str, Any]) -> "Notice":
        return cls(
            url=str(record.get("url") or ""),
            course=str(record.get("course") or ""),
            title=str(record.get("title") or ""),
            posted_at=str(record.get("posted_at") or ""),
            body_text=str(record.get("body_text") or ""),
            summary=str(record.get("summary") or ""),
        )


@dataclass(frozen=True)
class Assignment:
    url: str
    course: str
    title: str
    due: str
    sync_due: str
    source: str
    source_title: str = ""
    submission: str = ""
    instructions: str = ""
    category: Category = "assignment"
    type: str = "assign"
    auto_completed: bool = False
    record_status: str = ""
    completion_reason: str = ""

    def to_legacy_dict(self) -> dict[str, Any]:
        return {
            "url": self.url,
            "type": self.type,
            "category": self.category,
            "course": self.course,
            "title": self.title,
            "due": self.due,
            "submission": self.submission,
            "instructions": self.instructions,
            "timing_precision": "datetime",
            "time_source": self.source,
            "sync_start": "",
            "sync_due": self.sync_due,
            "source_title": self.source_title,
            "location": "",
            "coverage": "",
            "coverage_summary": "",
            "auto_completed": self.auto_completed,
            "record_status": self.record_status,
            "completion_reason": self.completion_reason,
        }


@dataclass(frozen=True)
class Event:
    url: str
    course: str
    title: str
    due: str
    sync_due: str
    source: str
    source_title: str = ""
    instructions: str = ""
    category: Category = "exam"
    type: str = "exam"
    sync_start: str = ""
    location: str = ""
    coverage: str = ""

    def to_legacy_dict(self) -> dict[str, Any]:
        return {
            "url": self.url,
            "type": self.type,
            "category": self.category,
            "course": self.course,
            "title": self.title,
            "due": self.due,
            "submission": "",
            "instructions": self.instructions,
            "timing_precision": "time-range" if self.sync_start else "datetime",
            "time_source": self.source,
            "sync_start": self.sync_start,
            "sync_due": self.sync_due,
            "source_title": self.source_title,
            "location": self.location,
            "coverage": self.coverage,
            "coverage_summary": self.coverage,
            "auto_completed": False,
        }


@dataclass
class SyncState:
    generated_at: str
    assignments: list[Assignment] = field(default_factory=list)
    completed_assignments: list[Assignment] = field(default_factory=list)
    assignment_records: list[Assignment] = field(default_factory=list)
    assignment_candidates: list[Assignment] = field(default_factory=list)
    exams: list[Event] = field(default_factory=list)
    exam_candidates: list[Event] = field(default_factory=list)
    help_desk_items: list[Event] = field(default_factory=list)

    def to_legacy_state(self) -> dict[str, Any]:
        return {
            "status": "ok",
            "generated_at": self.generated_at,
            "content": {
                "kind": "success",
                "assignments": [item.to_legacy_dict() for item in self.assignments],
                "completed_assignments": [
                    item.to_legacy_dict() for item in self.completed_assignments
                ],
                "assignment_records": [
                    item.to_legacy_dict() for item in self.assignment_records
                ],
                "exam_items": [item.to_legacy_dict() for item in self.exams],
                "exam_candidates": [item.to_legacy_dict() for item in self.exam_candidates],
                "assignment_candidates": [
                    item.to_legacy_dict() for item in self.assignment_candidates
                ],
                "help_desk_items": [item.to_legacy_dict() for item in self.help_desk_items],
            },
        }

    def summary(self) -> dict[str, Any]:
        return {
            "generated_at": self.generated_at,
            "assignment_count": len(self.assignments),
            "completed_assignment_count": len(self.completed_assignments),
            "assignment_record_count": len(self.assignment_records),
            "assignment_candidate_count": len(self.assignment_candidates),
            "exam_count": len(self.exams),
            "exam_candidate_count": len(self.exam_candidates),
            "help_desk_count": len(self.help_desk_items),
        }

    def to_debug_dict(self) -> dict[str, Any]:
        return asdict(self)
