import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

from klms_sync_v2.classifiers import classify_detail_page, classify_notice  # noqa: E402
from klms_sync_v2.dates import is_past, parse_due_date_only, parse_due_datetime  # noqa: E402
from klms_sync_v2.models import Assignment, Event, Notice, Page  # noqa: E402
from klms_sync_v2.pipeline import build_sync_state  # noqa: E402


class V2CoreTests(unittest.TestCase):
    def test_korean_due_datetime_parses_to_kst_iso(self) -> None:
        parsed = parse_due_datetime("마감 일시 2026년 5월 18일(월요일) 오후 6:30")

        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.iso, "2026-05-18T18:30:00+09:00")

    def test_korean_month_day_deadline_defaults_to_end_of_day(self) -> None:
        parsed = parse_due_date_only(
            "7주차 과제의 경우, 중간고사 시험 일정으로 인해 4월 27일 마감입니다.",
            "2026-05-13 19:18 KST",
        )

        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.iso, "2026-04-27T23:59:00+09:00")

    def test_slash_date_with_weekday_and_pm_parses(self) -> None:
        parsed = parse_due_datetime(
            "성적 문의가 있는 경우 5/3 (Sun) 11:59 PM까지 메일로 보내주시기 바랍니다.",
            "2026-05-13 19:18 KST",
        )

        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.iso, "2026-05-03T23:59:00+09:00")

    def test_due_label_beats_uploaded_timestamp(self) -> None:
        parsed = parse_due_datetime(
            "HW3 (Due: 6/15 23:59) HW3.pdf 2026년 5월 25일 오후 3:40 "
            "제출 상태 시도 하지 않음 마감 일시 2026년 6월 15일(월요일) 오후 11:59",
            "2026-05-27 11:12 KST",
        )

        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.iso, "2026-06-15T23:59:00+09:00")

    def test_english_due_label_beats_quiz_open_timestamp(self) -> None:
        parsed = parse_due_datetime(
            "Attendance Quiz for Week 13 Due: May 30, 23:59 "
            "이 퀴즈는 2026년 5월 26일(화요일) 오전 10:30 에 개봉됨",
            "2026-05-27 11:12 KST",
        )

        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.iso, "2026-05-30T23:59:00+09:00")

    def test_english_month_range_uses_end_as_due_and_start_as_start(self) -> None:
        parsed = parse_due_datetime(
            "March 31 (Tuesday), from 10:30 to 12:00",
            "2026-05-13 19:18 KST",
        )

        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.display, "2026년 3월 31일(화요일) 오전 10:30 - 오후 12:00")
        self.assertEqual(parsed.start_iso, "2026-03-31T10:30:00+09:00")
        self.assertEqual(parsed.iso, "2026-03-31T12:00:00+09:00")

    def test_english_day_month_h_notation_range_parses(self) -> None:
        parsed = parse_due_datetime(
            "The exam will be taken on the 4th of June at the classroom from 14h:30 to 15h:30.",
            "2026-05-27 19:18 KST",
        )

        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.display, "2026년 6월 4일(목요일) 오후 2:30 - 오후 3:30")
        self.assertEqual(parsed.start_iso, "2026-06-04T14:30:00+09:00")
        self.assertEqual(parsed.iso, "2026-06-04T15:30:00+09:00")

    def test_english_day_month_space_h_notation_range_parses(self) -> None:
        parsed = parse_due_datetime(
            "The exam will be taken on the 16th of April from 14h 30 to 15h 30 in our lecture room.",
            "2026-03-20 19:18 KST",
        )

        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.display, "2026년 4월 16일(목요일) 오후 2:30 - 오후 3:30")
        self.assertEqual(parsed.start_iso, "2026-04-16T14:30:00+09:00")
        self.assertEqual(parsed.iso, "2026-04-16T15:30:00+09:00")

    def test_slash_range_uses_end_as_due_and_start_as_start(self) -> None:
        parsed = parse_due_datetime(
            "Thursday, 5/14, from 10:30 AM to 11:30 AM",
            "2026-05-13 19:18 KST",
        )

        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.display, "2026년 5월 14일(목요일) 오전 10:30 - 오전 11:30")
        self.assertEqual(parsed.start_iso, "2026-05-14T10:30:00+09:00")
        self.assertEqual(parsed.iso, "2026-05-14T11:30:00+09:00")

    def test_is_past_uses_generated_at_label_not_wall_clock(self) -> None:
        self.assertFalse(
            is_past("2026-05-18T18:30:00+09:00", "2026-05-13 19:18 KST")
        )
        self.assertTrue(
            is_past("2026-05-13T18:30:00+09:00", "2026-05-13 19:18 KST")
        )

    def test_duplicate_source_assignments_do_not_duplicate_completed_lists(self) -> None:
        item = Assignment(
            url="https://klms.kaist.ac.kr/mod/assign/view.php?id=1",
            course="테스트",
            title="과제",
            due="2026년 5월 13일 오후 6:30",
            sync_due="2026-05-13T18:30:00+09:00",
            source="source",
        )

        state = build_sync_state(
            generated_at="2026-05-13 19:18 KST",
            detail_pages=[],
            notices=[],
            source_assignments=[item, item],
        )

        self.assertEqual(len(state.assignment_records), 1)
        self.assertEqual(len(state.completed_assignments), 1)

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

    def test_exam_notice_with_assignment_coverage_becomes_exam(self) -> None:
        notice = Notice(
            url="https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=6",
            course="알고리즘 개론",
            title="Announcement for the Midterm",
            body_text=(
                "Time: April 23th, 9:00 am - 11:45 am. "
                "Range: week 1 to week 7 lectures, WA 1-2 and PA 1-2."
            ),
        )

        item, reason = classify_notice(notice, "2026-04-01 19:18 KST")

        self.assertEqual(reason, "exam-notice")
        self.assertEqual(item.category, "exam")
        self.assertEqual(item.title, "중간고사")
        self.assertEqual(item.coverage, "week 1 to week 7 lectures, WA 1-2 and PA 1-2")

    def test_final_exam_notice_becomes_exam(self) -> None:
        notice = Notice(
            url="https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=8",
            course="데이타베이스 개론",
            title="[Notice] Final Exam Schedule",
            body_text=(
                "The final exam for CS360 will be held on Wednesday, June 17, "
                "from 13:00 to 16:00 in the Auditorium."
            ),
        )

        item, reason = classify_notice(notice, "2026-05-27 19:18 KST")

        self.assertEqual(reason, "exam-notice")
        self.assertEqual(item.category, "exam")
        self.assertEqual(item.title, "기말고사")
        self.assertEqual(item.sync_due, "2026-06-17T16:00:00+09:00")
        self.assertEqual(item.location, "Auditorium")

    def test_essay_exam_notice_keeps_topic_as_coverage(self) -> None:
        notice = Notice(
            url="https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=10",
            course="영미 단편소설",
            title="기말 고사 건 / On Final-term Exam",
            body_text=(
                "기말 고사 관련 내용입니다. 아래 주제를 분석하세요. "
                "주제 : 주 교재와 부 교재를 매개로 <탈식민주의의 관점으로 보는 젠터 불평등 문제>를 분석하세요. "
                "주의사항 1. 반드시 주/부 교재에서 인용문을 합해서 5개 이상 달아야 합니다. "
                "3. 시험은 6월 4일 수업 시간에 치르고, 시험 시간은 1시간입니다. "
                "Please analyse the following topic. "
                "<Write an essay on the issue of \"gender inequality from post-colonial perspective\" "
                "by recommending on our main and secondary texts.> "
                "The exam will be taken on the 4th of June at the classroom from 14h:30 to 15h:30."
            ),
        )

        item, reason = classify_notice(notice, "2026-05-27 19:18 KST")

        self.assertEqual(reason, "exam-notice")
        self.assertEqual(item.category, "exam")
        self.assertEqual(item.title, "기말고사")
        self.assertEqual(item.sync_due, "2026-06-04T15:30:00+09:00")
        self.assertIn("탈식민주의", item.coverage)
        self.assertIn("주/부 교재", item.instructions)

    def test_exam_grade_claim_notice_is_not_tracked_as_exam(self) -> None:
        notice = Notice(
            url="https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=9",
            course="알고리즘 개론",
            title="Midterm Grade Posted / Claim Session (05/14 10:30am~11:45am)",
            body_text=(
                "The midterm exam scores have been released. We will hold a claim session "
                "on Thursday, 5/14, from 10:30 AM to 11:30 AM."
            ),
        )

        item, reason = classify_notice(notice, "2026-05-01 19:18 KST")

        self.assertEqual(reason, "not-relevant")
        self.assertIsNone(item)

    def test_mixed_hw_deadline_and_exam_title_does_not_hide_assignment(self) -> None:
        notice = Notice(
            url="https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=7",
            course="전기 전자공학특강",
            title="Schedule Update: HW1 Deadline & Midterm Exam",
            body_text="HW1 deadline has been extended to 3/27 23:59. Midterm exam details are separate.",
        )

        item, reason = classify_notice(notice, "2026-03-20 19:18 KST")

        self.assertEqual(reason, "assignment-notice")
        self.assertEqual(item.category, "assignment")
        self.assertEqual(item.title, "HW1")
        self.assertEqual(item.sync_due, "2026-03-27T23:59:00+09:00")

    def test_notice_submit_by_date_becomes_assignment_without_deadline_word(self) -> None:
        notice = Notice(
            url="https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=3",
            course="데이타베이스 개론",
            title="[IMPORTANT] Reminder: Mandatory Nano Quiz for GitHub Classroom Registration",
            body_text=(
                "Mandatory Nano Quiz 를 아직 제출하지 않은 학생들은 "
                "2026년 3월 15일(일) 23:59까지 반드시 제출해주시기 바랍니다."
            ),
        )

        item, reason = classify_notice(notice, "2026-03-10 19:18 KST")

        self.assertEqual(reason, "assignment-notice")
        self.assertEqual(item.title, "Nano Quiz")
        self.assertEqual(item.sync_due, "2026-03-15T23:59:00+09:00")

    def test_notice_korean_assignment_deadline_without_year_becomes_assignment(self) -> None:
        notice = Notice(
            url="https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=4",
            course="지성과 문명 강독:우주",
            title="7주차 과제 마감 기한",
            body_text="7주차 과제의 경우, 중간고사 시험 일정으로 인해 4월 27일 마감입니다.",
        )

        item, reason = classify_notice(notice, "2026-04-20 19:18 KST")

        self.assertEqual(reason, "assignment-notice")
        self.assertEqual(item.title, "7주차 과제")
        self.assertEqual(item.sync_due, "2026-04-27T23:59:00+09:00")

    def test_notice_assignment_grade_inquiry_deadline_is_not_tracked_as_assignment(self) -> None:
        notice = Notice(
            url="https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=5",
            course="데이타베이스 개론",
            title="[Notice] Nano Quiz Grades and Answers Uploaded",
            body_text=(
                "Nano Quiz 성적이 업로드되었습니다. 성적에 대한 문의가 있는 경우 "
                "5/3 (Sun) 11:59 PM까지 메일로 보내주시기 바랍니다."
            ),
        )

        item, reason = classify_notice(notice, "2026-05-01 19:18 KST")

        self.assertEqual(reason, "not-relevant")
        self.assertIsNone(item)

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

        self.assertEqual(reason, "submitted")
        self.assertIsNotNone(item)
        self.assertEqual(item.record_status, "completed")
        self.assertEqual(item.completion_reason, "submitted")

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
        self.assertEqual(len(state.completed_assignments), 1)
        self.assertEqual(len(state.assignment_records), 1)
        self.assertTrue(
            all(item.record_status == "completed" for item in state.assignment_records)
        )

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

    def test_nano_quiz_detail_is_assignment_not_exam(self) -> None:
        page = Page(
            url="https://klms.kaist.ac.kr/mod/url/view.php?id=1230079",
            title="CS.30600(A)_2026_1: Nano Quiz - 25.05.07(Wed)",
            html="Due Date: May 18, 11:59:59 PM",
        )

        item, reason = classify_detail_page(page, "2026-05-13 19:18 KST")

        self.assertIsNotNone(item)
        self.assertEqual(reason, "assignment")
        self.assertEqual(item.category, "assignment")
        self.assertEqual(item.title, "Nano Quiz - 25.05.07(Wed)")

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

    def test_assignment_detail_uses_real_due_date_not_upload_date(self) -> None:
        page = Page(
            url="https://klms.kaist.ac.kr/mod/assign/view.php?id=1234405",
            title="EE.49904(B)_2026_1: HW3 (Due: 6/15 23:59)",
            html="""
            <div>전기 전자공학특강&lt;전자공학을 위한 사이버 보안 개론&gt;(EE.49904(B)_2026_1(B))</div>
            <div>HW3 (Due: 6/15 23:59) HW3.pdf 2026년 5월 25일 오후 3:40</div>
            <div>제출 상태 시도 하지 않음</div>
            <div>마감 일시 2026년 6월 15일(월요일) 오후 11:59</div>
            """,
        )

        item, reason = classify_detail_page(page, "2026-05-27 11:12 KST")

        self.assertEqual(reason, "assignment")
        self.assertEqual(item.title, "HW3 (Due: 6/15 23:59)")
        self.assertEqual(item.sync_due, "2026-06-15T23:59:00+09:00")
        self.assertEqual(item.submission, "시도 하지 않음")

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
            generated_at="2026-04-01 19:18 KST",
            detail_pages=[],
            notices=notices,
            overrides=overrides,
        )

        self.assertEqual(len(state.exams), 1)
        self.assertEqual(state.exams[0].course, "전기 전자공학특강")
        self.assertEqual(state.exams[0].title, "중간고사")
        self.assertEqual(state.exams[0].sync_start, "2026-04-08T10:30:00+09:00")
        self.assertEqual(state.exams[0].coverage, "Lecture 3")

    def test_past_approved_exam_is_hidden_from_state(self) -> None:
        state = build_sync_state(
            generated_at="2026-05-27 19:18 KST",
            detail_pages=[],
            notices=[],
            source_events=[
                Event(
                    url="https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=10",
                    course="영미 단편소설",
                    title="중간고사",
                    due="2026년 4월 16일 오후 2:30 - 오후 3:30",
                    sync_due="2026-04-16T15:30:00+09:00",
                    sync_start="2026-04-16T14:30:00+09:00",
                    source="notice",
                    category="exam",
                )
            ],
        )

        self.assertEqual(state.exams, [])

    def test_past_approved_exam_override_is_hidden_from_state(self) -> None:
        state = build_sync_state(
            generated_at="2026-05-27 19:18 KST",
            detail_pages=[],
            notices=[],
            source_events=[
                Event(
                    url="https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=10",
                    course="영미 단편소설",
                    title="중간고사",
                    due="2026년 4월 16일 오후 2:30 - 오후 3:30",
                    sync_due="2026-04-16T15:30:00+09:00",
                    sync_start="2026-04-16T14:30:00+09:00",
                    source="notice",
                    category="exam_candidate",
                )
            ],
            overrides={
                "exams": {
                    "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=10::중간고사": {
                        "status": "approved",
                        "due": "2026년 4월 16일 오후 2:30 - 오후 3:30",
                        "sync_due": "2026-04-16T15:30:00+09:00",
                        "sync_start": "2026-04-16T14:30:00+09:00",
                    }
                }
            },
        )

        self.assertEqual(state.exams, [])
        self.assertEqual(state.exam_candidates, [])

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

    def test_cli_build_state_uses_course_file_manifest_candidates(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            details = tmp_dir / "details.json"
            digest = tmp_dir / "notice_digest.json"
            manifest = tmp_dir / "course_file_manifest.json"
            output = tmp_dir / "state.json"
            details.write_text("[]", encoding="utf-8")
            digest.write_text(
                json.dumps({"generated_at": "2026-05-27 19:18 KST", "courses": []}),
                encoding="utf-8",
            )
            manifest.write_text(
                json.dumps(
                    [
                        {
                            "url": "https://klms.kaist.ac.kr/mod/resource/view.php?id=10",
                            "course": "지성과 문명 강독:우주",
                            "section_title": "14주차",
                            "activity_title": "14주차 쪽글 및 과제",
                            "filename": "20260603-topic.pdf",
                            "klms_timestamp_label": "마감 일시",
                            "klms_timestamp_text": "2026년 6월 3일(수요일) 오후 6:30",
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
                    "build-state",
                    "--details-json",
                    str(details),
                    "--notice-digest-json",
                    str(digest),
                    "--course-file-manifest-json",
                    str(manifest),
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

            self.assertIn('"assignment_candidate_count": 1', result.stdout)
            rendered = json.loads(output.read_text(encoding="utf-8"))
            candidates = rendered["content"]["assignment_candidates"]
            self.assertEqual(candidates[0]["title"], "14주차 쪽글 및 과제")
            self.assertEqual(candidates[0]["time_source"], "file")

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

    def test_cli_build_note_renders_completed_assignment_records(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            details = tmp_dir / "details.json"
            state = tmp_dir / "state.json"
            output_state = tmp_dir / "next_state.json"
            output_status = tmp_dir / "status.json"
            output_html = tmp_dir / "section.html"
            details.write_text(
                json.dumps(
                    [
                        {
                            "requestedUrl": "https://klms.kaist.ac.kr/mod/assign/view.php?id=1228325",
                            "title": "CS.30000_2026_1: Written Assignment 3",
                            "html": "제출 상태 채점을 위해 제출되었습니다. 마감 일시 2026년 5월 13일(수요일) 오후 11:59",
                        }
                    ],
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            state.write_text("{}", encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "klms_sync_v2.cli",
                    "build-note",
                    "--details-json",
                    str(details),
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

            self.assertIn('"assignment_count": 0', result.stdout)
            self.assertIn('"completed_assignment_count": 1', result.stdout)
            html = output_html.read_text(encoding="utf-8")
            self.assertIn("완료 기록", html)
            self.assertIn("KLMS 제출 완료", html)
            status = json.loads(output_status.read_text(encoding="utf-8"))
            self.assertEqual(status["completed_assignment_count"], 1)
            self.assertEqual(status["assignment_record_count"], 1)

    def test_cli_build_note_ignores_linear_algebra_dashboard_assignment(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            dashboard = tmp_dir / "dashboard.json"
            details = tmp_dir / "details.json"
            state = tmp_dir / "state.json"
            output_state = tmp_dir / "next_state.json"
            output_status = tmp_dir / "status.json"
            output_html = tmp_dir / "section.html"
            dashboard.write_text(
                json.dumps(
                    [
                        {
                            "requestedUrl": "https://klms.kaist.ac.kr/my/",
                            "title": "Dashboard",
                            "html": """
                            <div class="list-box assign">
                              <a href="https://klms.kaist.ac.kr/mod/assign/view.php?id=1234195">열기</a>
                              <ul>
                                <li>2026.05.23~2026.06.14</li>
                                <li>[과제] Project Submission</li>
                                <li>데이터과학을 위한 선형대수학</li>
                              </ul>
                            </div>
                            """,
                        }
                    ],
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            details.write_text("[]", encoding="utf-8")
            state.write_text("{}", encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "klms_sync_v2.cli",
                    "build-note",
                    "--dashboard-json",
                    str(dashboard),
                    "--details-json",
                    str(details),
                    "--state-json",
                    str(state),
                    "--output-html",
                    str(output_html),
                    "--output-state",
                    str(output_state),
                    "--output-status",
                    str(output_status),
                    "--generated-at",
                    "2026-05-26 19:18 KST",
                ],
                cwd=PROJECT_DIR,
                env={"PYTHONPATH": str(PROJECT_DIR / "src" / "python")},
                text=True,
                capture_output=True,
                check=True,
            )

            self.assertIn('"assignment_count": 0', result.stdout)
            rendered = json.loads(output_state.read_text(encoding="utf-8"))
            self.assertEqual(rendered["content"]["assignments"], [])

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

    def test_cli_check_login_status_accepts_klms_non_login_page_like_legacy_app(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            pages = Path(tmp) / "dashboard.json"
            pages.write_text(
                json.dumps(
                    [
                        {
                            "requestedUrl": "https://klms.kaist.ac.kr/my/",
                            "url": "https://klms.kaist.ac.kr/my/",
                            "title": "KLMS",
                            "html": "<html><body></body></html>",
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
                    "check-login-status",
                    "--pages-json",
                    str(pages),
                ],
                cwd=PROJECT_DIR,
                env={"PYTHONPATH": str(PROJECT_DIR / "src" / "python")},
                text=True,
                capture_output=True,
                check=True,
            )

            payload = json.loads(result.stdout)
            self.assertEqual(payload["status"], "ok")

    def test_cli_check_login_status_accepts_klms_dashboard_title(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            pages = Path(tmp) / "dashboard.json"
            pages.write_text(
                json.dumps(
                    [
                        {
                            "requestedUrl": "https://klms.kaist.ac.kr/my/",
                            "url": "https://klms.kaist.ac.kr/my/",
                            "title": "강의 현황",
                            "html": "",
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
                    "check-login-status",
                    "--pages-json",
                    str(pages),
                ],
                cwd=PROJECT_DIR,
                env={"PYTHONPATH": str(PROJECT_DIR / "src" / "python")},
                text=True,
                capture_output=True,
                check=True,
            )

            payload = json.loads(result.stdout)
            self.assertEqual(payload["status"], "ok")

    def test_cli_check_login_status_rejects_sso_twofactor_page(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            pages = Path(tmp) / "dashboard.json"
            pages.write_text(
                json.dumps(
                    [
                        {
                            "requestedUrl": "https://klms.kaist.ac.kr/my/",
                            "url": "https://sso.kaist.ac.kr/auth/twofactor/mfa/login2factor",
                            "title": "Single Sign On",
                            "html": '<input id="login_id_mfa"><input type="password">',
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
                    "check-login-status",
                    "--pages-json",
                    str(pages),
                ],
                cwd=PROJECT_DIR,
                env={"PYTHONPATH": str(PROJECT_DIR / "src" / "python")},
                text=True,
                capture_output=True,
                check=True,
            )

            payload = json.loads(result.stdout)
            self.assertEqual(payload["status"], "error")
            self.assertEqual(payload["error"], "login_required")


if __name__ == "__main__":
    unittest.main()
