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

    def test_reminder_verification_counts_marked_items_not_only_open_items(self) -> None:
        checks = verify_sync_state.live_reminder_checks(
            {
                "reminders_assignment_list_exists": True,
                "reminders_assignment_active_count": 8,
                "reminders_assignment_marker_count": 9,
                "reminders_issue_active_count": 1,
                "reminders_issue_marker_count": 1,
                "reminders_alert_active_count": 2,
                "reminders_alert_marker_count": 2,
            },
            assignment_count=9,
        )

        by_name = {item["name"]: item for item in checks}
        self.assertEqual(by_name["reminders_assignment_count_matches_state"]["status"], "ok")
        self.assertEqual(
            by_name["reminders_assignment_count_matches_state"]["detail"],
            "active=8 markers=9 state=9",
        )
        self.assertEqual(by_name["reminders_total_count_consistent"]["status"], "ok")

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
                                        "article_id": "10",
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
                                        "article_id": "11",
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
                    {"notice_id": "article:10"},
                    {"notice_id": "article:11"},
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
                        "reminders_issue_list_exists=true",
                        "reminders_issue_active_count=0",
                        "reminders_issue_marker_count=0",
                        "reminders_alert_list_exists=true",
                        "reminders_alert_active_count=4",
                        "reminders_alert_marker_count=4",
                        "reminders_total_active_count=6",
                        "reminders_total_marker_count=6",
                    ]
                ),
                encoding="utf-8",
            )

            payload = verify_sync_state.build_payload(
                cache_dir, state_json, calendar_lines, reminders_lines
            )

        self.assertEqual(payload["status"], "ok")
        checks = {item["name"]: item for item in payload["checks"]}
        self.assertEqual(checks["notice_render_complete"]["status"], "ok")
        self.assertEqual(checks["notice_exam_detection_covered_by_state"]["status"], "ok")
        self.assertEqual(checks["manifest_assignment_detection_covered_by_state"]["status"], "ok")
        self.assertEqual(checks["reminders_assignment_count_matches_state"]["status"], "ok")
        self.assertEqual(payload["reminders"]["assignment_active_count"], 2)
        self.assertEqual(payload["reminders"]["alert_active_count"], 4)
        self.assertEqual(payload["reminders"]["total_active_count"], 6)

    def test_notice_assignment_update_can_be_covered_by_logical_state_item(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cache_dir = root / "cache"
            cache_dir.mkdir()
            notice_url = "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1189554&bwid=435776"
            state_json = root / "state.json"
            (cache_dir / "notice_digest.json").write_text(
                json.dumps(
                    {
                        "generated_at": "2026-06-01 20:00 KST",
                        "courses": [
                            {
                                "course": "알고리즘 개론",
                                "notices": [
                                    {
                                        "url": notice_url,
                                        "title": "Update on due date of Written Assignment 4 (June 9th, 23:59)",
                                        "body_text": "The due date of Written Assignment 4 is June 9th, 23:59.",
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
                json.dumps({"rendered_notices": [{"notice_id": notice_url}]}),
                encoding="utf-8",
            )
            state_json.write_text(
                json.dumps(
                    {
                        "status": "ok",
                        "generated_at": "2026-06-01 20:00 KST",
                        "content": {
                            "kind": "success",
                            "assignments": [
                                {
                                    "url": "https://klms.kaist.ac.kr/mod/assign/view.php?id=1234595",
                                    "course": "알고리즘 개론",
                                    "title": "Written Assignment 4",
                                    "sync_due": "2026-06-09T23:59:00+09:00",
                                }
                            ],
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
        self.assertEqual(checks["notice_assignment_detection_covered_by_state"]["status"], "ok")

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

    def test_past_exam_records_are_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cache_dir = root / "cache"
            cache_dir.mkdir()
            (cache_dir / "notice_digest.json").write_text(
                json.dumps({"generated_at": "2026-06-02 12:20 KST", "courses": []}),
                encoding="utf-8",
            )
            state_json = root / "state.json"
            past_exam = {
                "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=11",
                "course": "전기 전자공학특강<전자공학을 위한 사이버 보안 개론>",
                "title": "Midterm 2",
                "due": "2026년 5월 6일(수요일) 오전 10:30 - 오후 12:00",
                "sync_due": "2026-05-06T12:00:00+09:00",
                "instructions": "시험 범위: Lecture 3",
                "coverage_summary": "Lecture 3",
                "record_status": "completed",
                "completion_reason": "past_due",
            }
            state_json.write_text(
                json.dumps(
                    {
                        "status": "ok",
                        "generated_at": "2026-06-02 12:20 KST",
                        "content": {
                            "kind": "success",
                            "assignments": [],
                            "assignment_records": [],
                            "completed_assignments": [],
                            "assignment_candidates": [],
                            "exam_items": [],
                            "exam_candidates": [],
                            "past_exams": [past_exam],
                            "exam_records": [past_exam],
                            "help_desk_items": [],
                        },
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

            payload = verify_sync_state.build_payload(cache_dir, state_json, None)

        checks = {item["name"]: item for item in payload["checks"]}
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(checks["past_exam_items_absent"]["status"], "ok")
        self.assertEqual(payload["state"]["past_exam_count"], 1)
        self.assertEqual(payload["state"]["exam_record_count"], 1)


if __name__ == "__main__":
    unittest.main()
