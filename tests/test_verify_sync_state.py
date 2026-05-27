import json
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

import verify_sync_state  # noqa: E402


class VerifySyncStateTests(unittest.TestCase):
    def test_calendar_unavailable_is_warning_not_global_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cache_dir = root / "cache"
            cache_dir.mkdir()
            state_json = root / "state.json"
            calendar_lines = root / "calendar.txt"
            state_json.write_text(
                json.dumps(
                    {
                        "content": {
                            "assignments": [],
                            "exam_items": [
                                {
                                    "course": "C",
                                    "title": "T",
                                    "due": "D",
                                    "instructions": "시험 안내",
                                }
                            ],
                            "help_desk_items": [],
                        }
                    }
                ),
                encoding="utf-8",
            )
            calendar_lines.write_text(
                "calendar_error=Calendar access was not granted.\n",
                encoding="utf-8",
            )

            payload = verify_sync_state.build_payload(cache_dir, state_json, calendar_lines)

        self.assertEqual(payload["status"], "ok")
        checks = {item["name"]: item for item in payload["checks"]}
        self.assertEqual(checks["calendar_access"]["status"], "warn")
        self.assertEqual(checks["calendar_exam_count_matches_state"]["status"], "warn")
        self.assertEqual(payload["calendar"]["error"], "Calendar access was not granted.")

    def test_notice_file_calendar_and_reminder_coverage_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cache_dir = root / "cache"
            cache_dir.mkdir()
            (cache_dir / "core").mkdir()
            file_path = root / "nano.pdf"
            file_path.write_text("quiz", encoding="utf-8")
            exam_url = "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=10"
            project_url = "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=11"
            file_url = "https://klms.kaist.ac.kr/mod/url/view.php?id=99"
            state_json = root / "state.json"
            calendar_lines = root / "calendar.txt"
            reminders_lines = root / "reminders.txt"

            (cache_dir / "notice_digest.json").write_text(
                json.dumps(
                    {
                        "generated_at": "2026-05-27 19:18 KST",
                        "courses": [
                            {
                                "course": "영미 단편소설",
                                "notices": [
                                    {
                                        "url": exam_url,
                                        "title": "기말 고사 건 / On Final-term Exam",
                                        "body_text": "The exam will be taken on the 4th of June from 14h 30 to 15h 30.",
                                    }
                                ],
                            },
                            {
                                "course": "데이타베이스 개론",
                                "notices": [
                                    {
                                        "url": project_url,
                                        "title": "Project 3 Announcement",
                                        "body_text": "deadline 5/31 23:59",
                                    }
                                ],
                            },
                        ],
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            render_state = {
                "rendered_notices": [
                    {"notice_id": exam_url},
                    {"notice_id": project_url},
                ]
            }
            (cache_dir / "notice_note_render_state.json").write_text(
                json.dumps(render_state), encoding="utf-8"
            )
            (cache_dir / "notice_archive_note_render_state.json").write_text(
                json.dumps({"rendered_notices": []}), encoding="utf-8"
            )
            (cache_dir / "course_file_manifest.json").write_text(
                json.dumps(
                    [
                        {
                            "course": "데이타베이스 개론",
                            "url": file_url,
                            "activity_title": "Nano Quiz - 25.05.29",
                            "filename": "nano.pdf",
                            "section_title": "13주차",
                            "klms_timestamp_label": "Due",
                            "klms_timestamp_text": "2026년 6월 3일 오후 11:59",
                            "absolute_path": str(file_path),
                            "relative_path": "nano.pdf",
                        }
                    ],
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            state_json.write_text(
                json.dumps(
                    {
                        "status": "ok",
                        "generated_at": "2026-05-27 19:18 KST",
                        "content": {
                            "kind": "success",
                            "assignments": [
                                {
                                    "url": project_url,
                                    "course": "데이타베이스 개론",
                                    "title": "Project 3",
                                    "sync_due": "2026-05-31T23:59:00+09:00",
                                },
                                {
                                    "url": file_url,
                                    "course": "데이타베이스 개론",
                                    "title": "Nano Quiz - 25.05.29",
                                    "sync_due": "2026-06-03T23:59:00+09:00",
                                },
                            ],
                            "assignment_records": [],
                            "completed_assignments": [],
                            "assignment_candidates": [],
                            "exam_items": [
                                {
                                    "url": exam_url,
                                    "course": "영미 단편소설",
                                    "title": "기말고사",
                                    "due": "2026년 6월 4일 오후 2:30 - 오후 3:30",
                                    "sync_due": "2026-06-04T15:30:00+09:00",
                                    "instructions": "The exam will be taken on the 4th of June.",
                                }
                            ],
                            "exam_candidates": [],
                            "help_desk_items": [],
                        },
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            calendar_lines.write_text(
                "\n".join(
                    [
                        "calendar_exam_count=1",
                        "calendar_helpdesk_count=0",
                        "legacy_calendar_assignment_exists=false",
                        "legacy_calendar_alert_exists=false",
                    ]
                ),
                encoding="utf-8",
            )
            (cache_dir / "core" / "calendar_sync_result.json").write_text(
                json.dumps({"summaries": [{"bucket": "exam", "total": 1}, {"bucket": "helpdesk", "total": 0}]}),
                encoding="utf-8",
            )
            reminders_lines.write_text(
                "\n".join(
                    [
                        "reminders_assignment_list_exists=true",
                        "reminders_assignment_active_count=2",
                        "reminders_assignment_marker_count=2",
                    ]
                ),
                encoding="utf-8",
            )

            payload = verify_sync_state.build_payload(
                cache_dir, state_json, calendar_lines, reminders_lines
            )

        self.assertEqual(payload["status"], "ok")
        checks = {item["name"]: item for item in payload["checks"]}
        self.assertEqual(checks["notice_exam_detection_covered_by_state"]["status"], "ok")
        self.assertEqual(checks["manifest_assignment_detection_covered_by_state"]["status"], "ok")
        self.assertEqual(checks["reminders_assignment_count_matches_state"]["status"], "ok")

    def test_likely_exam_notice_missing_from_state_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cache_dir = root / "cache"
            cache_dir.mkdir()
            exam_url = "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=10"
            state_json = root / "state.json"
            (cache_dir / "notice_digest.json").write_text(
                json.dumps(
                    {
                        "generated_at": "2026-05-27 19:18 KST",
                        "courses": [
                            {
                                "course": "영미 단편소설",
                                "notices": [
                                    {
                                        "url": exam_url,
                                        "title": "기말 고사 건 / On Final-term Exam",
                                        "body_text": "The exam will be taken on the 4th of June from 14h 30 to 15h 30.",
                                    }
                                ],
                            }
                        ],
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            (cache_dir / "notice_note_render_state.json").write_text(
                json.dumps({"rendered_notices": [{"notice_id": exam_url}]}),
                encoding="utf-8",
            )
            state_json.write_text(
                json.dumps(
                    {
                        "status": "ok",
                        "generated_at": "2026-05-27 19:18 KST",
                        "content": {
                            "kind": "success",
                            "assignments": [],
                            "assignment_records": [],
                            "completed_assignments": [],
                            "assignment_candidates": [],
                            "exam_items": [],
                            "exam_candidates": [],
                            "help_desk_items": [],
                        },
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

            payload = verify_sync_state.build_payload(cache_dir, state_json, None)

        checks = {item["name"]: item for item in payload["checks"]}
        self.assertEqual(payload["status"], "fail")
        self.assertEqual(checks["notice_exam_detection_covered_by_state"]["status"], "fail")

    def test_past_exam_in_state_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cache_dir = root / "cache"
            cache_dir.mkdir()
            (cache_dir / "notice_digest.json").write_text(
                json.dumps({"generated_at": "2026-05-27 19:18 KST", "courses": []}),
                encoding="utf-8",
            )
            state_json = root / "state.json"
            state_json.write_text(
                json.dumps(
                    {
                        "status": "ok",
                        "generated_at": "2026-05-27 19:18 KST",
                        "content": {
                            "kind": "success",
                            "assignments": [],
                            "assignment_records": [],
                            "completed_assignments": [],
                            "assignment_candidates": [],
                            "exam_items": [
                                {
                                    "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=10",
                                    "course": "영미 단편소설",
                                    "title": "중간고사",
                                    "due": "2026년 4월 16일",
                                    "sync_due": "2026-04-16T15:30:00+09:00",
                                    "instructions": "시험 안내",
                                }
                            ],
                            "exam_candidates": [],
                            "help_desk_items": [],
                        },
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

            payload = verify_sync_state.build_payload(cache_dir, state_json, None)

        checks = {item["name"]: item for item in payload["checks"]}
        self.assertEqual(payload["status"], "fail")
        self.assertEqual(checks["past_exam_items_absent"]["status"], "fail")


if __name__ == "__main__":
    unittest.main()
