import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

from klms_sync_v2.classifiers import classify_detail_page, classify_notice  # noqa: E402
from klms_sync_v2.dates import parse_due_datetime  # noqa: E402
from klms_sync_v2.models import Notice, Page  # noqa: E402
from klms_sync_v2.pipeline import build_sync_state  # noqa: E402


class V2CoreTests(unittest.TestCase):
    def test_korean_due_datetime_parses_to_kst_iso(self) -> None:
        parsed = parse_due_datetime("마감 일시 2026년 5월 18일(월요일) 오후 6:30")

        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.iso, "2026-05-18T18:30:00+09:00")

    def test_english_month_range_uses_end_as_due_and_start_as_start(self) -> None:
        parsed = parse_due_datetime(
            "March 31 (Tuesday), from 10:30 to 12:00",
            "2026-05-13 19:18 KST",
        )

        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.display, "2026년 3월 31일(화요일) 오전 10:30 - 오후 12:00")
        self.assertEqual(parsed.start_iso, "2026-03-31T10:30:00+09:00")
        self.assertEqual(parsed.iso, "2026-03-31T12:00:00+09:00")

    def test_slash_range_uses_end_as_due_and_start_as_start(self) -> None:
        parsed = parse_due_datetime(
            "Thursday, 5/14, from 10:30 AM to 11:30 AM",
            "2026-05-13 19:18 KST",
        )

        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.display, "2026년 5월 14일(목요일) 오전 10:30 - 오전 11:30")
        self.assertEqual(parsed.start_iso, "2026-05-14T10:30:00+09:00")
        self.assertEqual(parsed.iso, "2026-05-14T11:30:00+09:00")

    def test_notice_deadline_project_becomes_assignment(self) -> None:
        notice = Notice(
            url="https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=2",
            course="데이타베이스 개론",
            title="[Notice] Project 3 Announcement, KiteDB (deadline 5/31 23:59)",
        )

        item, reason = classify_notice(notice, "2026-05-13 19:18 KST")

        self.assertEqual(reason, "assignment-notice")
        self.assertEqual(item.title, "Project 3")
        self.assertEqual(item.sync_due, "2026-05-31T23:59:00+09:00")

    def test_submitted_assignment_detail_is_excluded(self) -> None:
        page = Page(
            url="https://klms.kaist.ac.kr/mod/assign/view.php?id=1228325",
            title="CS.30000_2026_1: Written Assignment 3",
            html="""
            <div>제출 상태 채점을 위해 제출되었습니다.</div>
            <div>마감 일시 2026년 5월 13일(수요일) 오후 11:59</div>
            """,
        )

        item, reason = classify_detail_page(page, "2026-05-13 19:18 KST")

        self.assertIsNone(item)
        self.assertEqual(reason, "submitted")

    def test_submitted_detail_blocks_matching_notice_assignment(self) -> None:
        detail_pages = [
            Page(
                url="https://klms.kaist.ac.kr/mod/assign/view.php?id=1228325",
                title="CS.30000_2026_1: Written Assignment 3",
                html="제출 상태 채점을 위해 제출되었습니다. 마감 일시 2026년 5월 13일(수요일) 오후 11:59",
            )
        ]
        notices = [
            Notice(
                url="https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=2",
                course="알고리즘 개론",
                title="Written Assignment 3 is released (~5/13 23:59:00)",
            )
        ]

        state = build_sync_state(
            generated_at="2026-05-13 19:18 KST",
            detail_pages=detail_pages,
            notices=notices,
        )

        self.assertEqual(state.assignments, [])

    def test_submitted_written_assignment_does_not_block_programming_assignment_same_number(self) -> None:
        detail_pages = [
            Page(
                url="https://klms.kaist.ac.kr/mod/assign/view.php?id=1228325",
                title="CS.30000_2026_1: Written Assignment 3",
                html="제출 상태 채점을 위해 제출되었습니다. 마감 일시 2026년 5월 13일(수요일) 오후 11:59",
            )
        ]
        notices = [
            Notice(
                url="https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=2",
                course="알고리즘 개론",
                title="Programming Assignment 3 is released (~5/21 23:59:00)",
                body_text="The programming assignment is released on Elice. The deadline is 5/21 23:59:00.",
            )
        ]

        state = build_sync_state(
            generated_at="2026-05-14 20:39 KST",
            detail_pages=detail_pages,
            notices=notices,
        )

        self.assertEqual(len(state.assignments), 1)
        self.assertEqual(state.assignments[0].title, "Programming Assignment 3")

    def test_nano_quiz_detail_is_not_exam(self) -> None:
        page = Page(
            url="https://klms.kaist.ac.kr/mod/url/view.php?id=1230079",
            title="CS.30600(A)_2026_1: Nano Quiz - 25.05.07(Wed)",
            html="Due Date: May 18, 11:59:59 PM",
        )

        item, reason = classify_detail_page(page, "2026-05-13 19:18 KST")

        self.assertIsNone(item)
        self.assertEqual(reason, "not-relevant")

    def test_unsubmitted_assignment_detail_is_active(self) -> None:
        page = Page(
            url="https://klms.kaist.ac.kr/mod/assign/view.php?id=1230112",
            title="TS.30025_2026_1: 11주차 과제",
            html="""
            <div>기출문제은행 마이크로러닝 CELT 교수법 Panopto 사용법 CELT 학습법 특강 지성과 문명 강독:우주(TS.30025_2026_1)</div>
            <div>제출 상태 시도 하지 않음</div>
            <div>마감 일시 2026년 5월 18일(월요일) 오후 6:30</div>
            """,
        )

        item, reason = classify_detail_page(page, "2026-05-13 19:18 KST")

        self.assertEqual(reason, "assignment")
        self.assertEqual(item.title, "11주차 과제")
        self.assertEqual(item.course, "지성과 문명 강독:우주")
        self.assertEqual(item.submission, "시도 하지 않음")
        self.assertEqual(item.instructions, "")

    def test_parenthesized_course_name_is_preserved(self) -> None:
        page = Page(
            url="https://klms.kaist.ac.kr/mod/assign/view.php?id=1231095",
            title="TS.30023_2026_1: [11주차] 필드트립, PRD, IA",
            html="""
            <div>기출문제은행 마이크로러닝 CELT 교수법 Panopto 사용법 CELT 학습법 특강 기술을 통한 사회적 혁신실험 (III) &lt;디자인&gt;(TS.30023_2026_1)</div>
            <div>제출 상태 시도 하지 않음</div>
            <div>마감 일시 2026년 5월 14일(목요일) 오후 4:00</div>
            """,
        )

        item, reason = classify_detail_page(page, "2026-05-13 19:18 KST")

        self.assertEqual(reason, "assignment")
        self.assertEqual(item.course, "기술을 통한 사회적 혁신실험 (III) <디자인>")
        self.assertEqual(item.title, "[11주차] 필드트립, PRD, IA")

    def test_pipeline_builds_legacy_state_shape(self) -> None:
        detail_pages = [
            Page(
                url="https://klms.kaist.ac.kr/mod/assign/view.php?id=1230112",
                title="TS.30025_2026_1: 11주차 과제",
                html="지성과 문명 강독:우주(TS.30025_2026_1) 제출 상태 시도 하지 않음 마감 일시 2026년 5월 18일(월요일) 오후 6:30",
            )
        ]
        notices = [
            Notice(
                url="https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=2",
                course="데이타베이스 개론",
                title="[Notice] Project 3 Announcement, KiteDB (deadline 5/31 23:59)",
            )
        ]

        state = build_sync_state(
            generated_at="2026-05-13 19:18 KST",
            detail_pages=detail_pages,
            notices=notices,
        )
        legacy = state.to_legacy_state()

        self.assertEqual(legacy["status"], "ok")
        self.assertEqual(len(legacy["content"]["assignments"]), 2)
        self.assertEqual(legacy["content"]["assignments"][0]["title"], "11주차 과제")
        self.assertEqual(legacy["content"]["assignments"][0]["course"], "지성과 문명 강독:우주")

    def test_approved_exam_override_promotes_source_to_exam(self) -> None:
        notices = [
            Notice(
                url="https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1193650&bwid=424238",
                course="전기 전자공학특강",
                title="Schedule Update: HW1 Deadline & Midterm Exam",
                body_text="Midterm exam has been postponed.",
            )
        ]
        overrides = {
            "exams": {
                "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1193650&bwid=424238::중간고사": {
                    "status": "approved",
                    "due": "2026년 4월 8일(수요일) 오전 10:30 - 오후 12:00",
                    "sync_start": "2026-04-08T10:30:00+09:00",
                    "sync_due": "2026-04-08T12:00:00+09:00",
                    "instructions_append": "시험 범위: Lecture 3",
                }
            }
        }

        state = build_sync_state(
            generated_at="2026-05-13 19:18 KST",
            detail_pages=[],
            notices=notices,
            overrides=overrides,
        )

        self.assertEqual(len(state.exams), 1)
        self.assertEqual(state.exams[0].course, "전기 전자공학특강")
        self.assertEqual(state.exams[0].title, "중간고사")
        self.assertEqual(state.exams[0].sync_start, "2026-04-08T10:30:00+09:00")
        self.assertEqual(state.exams[0].coverage, "Lecture 3")

    def test_cli_build_state(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            details = tmp_dir / "details.json"
            digest = tmp_dir / "notice_digest.json"
            output = tmp_dir / "state.json"
            details.write_text(
                json.dumps(
                    [
                        {
                            "requestedUrl": "https://klms.kaist.ac.kr/mod/assign/view.php?id=1230112",
                            "title": "TS.30025_2026_1: 11주차 과제",
                            "html": "제출 상태 시도 하지 않음 마감 일시 2026년 5월 18일(월요일) 오후 6:30",
                        }
                    ],
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            digest.write_text(
                json.dumps(
                    {
                        "generated_at": "2026-05-13 19:18 KST",
                        "courses": [
                            {
                                "course": "데이타베이스 개론",
                                "notices": [
                                    {
                                        "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=2",
                                        "title": "[Notice] Project 3 Announcement, KiteDB (deadline 5/31 23:59)",
                                    }
                                ],
                            }
                        ],
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "klms_sync_v2.cli",
                    "build-state",
                    "--details-json",
                    str(details),
                    "--notice-digest-json",
                    str(digest),
                    "--output-json",
                    str(output),
                    "--legacy",
                ],
                cwd=PROJECT_DIR,
                env={"PYTHONPATH": str(PROJECT_DIR / "src" / "python")},
                text=True,
                capture_output=True,
                check=True,
            )

            self.assertIn('"assignment_count": 2', result.stdout)
            rendered = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(len(rendered["content"]["assignments"]), 2)

    def test_cli_build_note_uses_supplemental_article_without_digest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            details = tmp_dir / "details.json"
            supplemental = tmp_dir / "supplemental_detail_pages.json"
            state = tmp_dir / "state.json"
            output_state = tmp_dir / "next_state.json"
            output_status = tmp_dir / "status.json"
            output_html = tmp_dir / "section.html"
            details.write_text("[]", encoding="utf-8")
            state.write_text("{}", encoding="utf-8")
            supplemental.write_text(
                json.dumps(
                    [
                        {
                            "requestedUrl": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1193350&bwid=432642",
                            "title": "CS.30600(A)_2026_1 : Notice",
                            "html": """
                            <html><body>
                              데이타베이스 개론(CS.30600(A)_2026_1(A))
                              Notice [Notice] Project 3 Announcement, KiteDB (deadline 5/31 23:59)
                              작성자 : TA 작성일 : 2026년 5월 11일(월요일) 오전 9:00 조회수 : 10
                              세 번째 Kite Project 입니다. Project 3 deadline 5/31 23:59
                              이전글 :
                            </body></html>
                            """,
                        }
                    ],
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "klms_sync_v2.cli",
                    "build-note",
                    "--details-json",
                    str(details),
                    "--supplemental-detail-pages-json",
                    str(supplemental),
                    "--state-json",
                    str(state),
                    "--output-html",
                    str(output_html),
                    "--output-state",
                    str(output_state),
                    "--output-status",
                    str(output_status),
                    "--generated-at",
                    "2026-05-13 19:18 KST",
                ],
                cwd=PROJECT_DIR,
                env={"PYTHONPATH": str(PROJECT_DIR / "src" / "python")},
                text=True,
                capture_output=True,
                check=True,
            )

            self.assertIn('"assignment_count": 1', result.stdout)
            rendered = json.loads(output_state.read_text(encoding="utf-8"))
            self.assertEqual(rendered["content"]["assignments"][0]["course"], "데이타베이스 개론")
            self.assertEqual(rendered["content"]["assignments"][0]["title"], "Project 3")
            status = json.loads(output_status.read_text(encoding="utf-8"))
            self.assertTrue(status["changed"])

    def test_cli_build_note_login_page_writes_error_state(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            details = tmp_dir / "details.json"
            state = tmp_dir / "state.json"
            output_state = tmp_dir / "next_state.json"
            output_status = tmp_dir / "status.json"
            details.write_text(
                json.dumps(
                    [
                        {
                            "requestedUrl": "https://klms.kaist.ac.kr/login/index.php",
                            "title": "KLMS Login",
                            "html": "<form><input name='username'><input type='password'>로그인</form>",
                        }
                    ],
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            state.write_text("{}", encoding="utf-8")

            subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "klms_sync_v2.cli",
                    "build-note",
                    "--details-json",
                    str(details),
                    "--state-json",
                    str(state),
                    "--output-state",
                    str(output_state),
                    "--output-status",
                    str(output_status),
                ],
                cwd=PROJECT_DIR,
                env={"PYTHONPATH": str(PROJECT_DIR / "src" / "python")},
                text=True,
                capture_output=True,
                check=True,
            )

            rendered = json.loads(output_state.read_text(encoding="utf-8"))
            status = json.loads(output_status.read_text(encoding="utf-8"))
            self.assertEqual(rendered["status"], "error")
            self.assertEqual(status["status"], "error")


if __name__ == "__main__":
    unittest.main()
