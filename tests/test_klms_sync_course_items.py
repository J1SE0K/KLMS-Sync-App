import sys
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

import klms_sync  # noqa: E402


def course_page(html: str) -> dict[str, str]:
    return {
        "html": html,
        "requestedUrl": "https://klms.kaist.ac.kr/course/view.php?id=100001",
        "title": "강좌: Example Course",
    }


class CourseItemParsingTests(unittest.TestCase):
    def test_ignored_dashboard_course_is_not_collected(self) -> None:
        dashboard = klms_sync.DashboardParseResult(
            status="ok",
            items=[
                klms_sync.DashboardItem(
                    url="https://klms.kaist.ac.kr/mod/assign/view.php?id=100002",
                    title="[과제] Homework 8",
                    course="KLMS",
                    schedule="~2026.05.10",
                    item_type="assign",
                )
            ],
        )

        items = klms_sync.collect_candidate_items(dashboard, [])

        self.assertEqual(items, [])

    def test_linear_algebra_course_is_ignored_by_substring(self) -> None:
        dashboard = klms_sync.DashboardParseResult(
            status="ok",
            items=[
                klms_sync.DashboardItem(
                    url="https://klms.kaist.ac.kr/mod/assign/view.php?id=1228234",
                    title="Homework 8",
                    course="데이터과학을 위한 선형대수학",
                    schedule="~2026.05.11",
                    item_type="assign",
                )
            ],
        )

        items = klms_sync.collect_candidate_items(dashboard, [])

        self.assertEqual(items, [])

    def test_linear_algebra_intro_course_is_ignored(self) -> None:
        dashboard = klms_sync.DashboardParseResult(
            status="ok",
            items=[
                klms_sync.DashboardItem(
                    url="https://klms.kaist.ac.kr/mod/assign/view.php?id=222222",
                    title="Homework",
                    course="선형대수학 개론",
                    schedule="~2026.05.11",
                    item_type="assign",
                )
            ],
        )

        items = klms_sync.collect_candidate_items(dashboard, [])

        self.assertEqual(items, [])

    def test_linear_algebra_intro_course_without_space_is_ignored(self) -> None:
        dashboard = klms_sync.DashboardParseResult(
            status="ok",
            items=[
                klms_sync.DashboardItem(
                    url="https://klms.kaist.ac.kr/mod/assign/view.php?id=222223",
                    title="Homework",
                    course="선형대수학개론",
                    schedule="~2026.05.11",
                    item_type="assign",
                )
            ],
        )

        items = klms_sync.collect_candidate_items(dashboard, [])

        self.assertEqual(items, [])

    def test_dedupe_assignment_items_merges_same_logical_assignment(self) -> None:
        items = [
            {
                "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1193350&bwid=432642",
                "category": "assignment",
                "course": "데이타베이스 개론",
                "title": "Project 3",
                "due": "2026년 5월 31일 오후 11:59",
                "sync_due": "2026-05-31T23:59:00+09:00",
                "instructions": "short",
            },
            {
                "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1193350&bwid=432643",
                "category": "assignment",
                "course": "데이타베이스 개론",
                "title": "Project 3",
                "due": "2026년 5월 31일 오후 11:59",
                "sync_due": "2026-05-31T23:59:00+09:00",
                "instructions": "longer duplicate assignment body",
            },
        ]

        deduped = klms_sync.dedupe_assignment_items(items)

        self.assertEqual(len(deduped), 1)
        self.assertEqual(deduped[0]["instructions"], "longer duplicate assignment body")

    def test_dedupe_assignment_items_keeps_different_titles_with_same_courseboard_id(self) -> None:
        items = [
            {
                "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1189554&bwid=432001",
                "category": "assignment",
                "course": "영미 단편소설",
                "title": "Written Assignment 2",
                "sync_due": "2026-05-20T23:59:00+09:00",
            },
            {
                "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1189554&bwid=432002",
                "category": "assignment",
                "course": "영미 단편소설",
                "title": "Programming Assignment 2",
                "sync_due": "2026-05-20T23:59:00+09:00",
            },
        ]

        deduped = klms_sync.dedupe_assignment_items(items)

        self.assertEqual(len(deduped), 2)

    def test_placeholder_dashboard_course_is_recovered_from_course_page(self) -> None:
        url = "https://klms.kaist.ac.kr/mod/assign/view.php?id=1231095"
        dashboard = klms_sync.DashboardParseResult(
            status="ok",
            items=[
                klms_sync.DashboardItem(
                    url=url,
                    title="[11주차] 필드트립, PRD, IA",
                    course=")",
                    schedule="~2026.05.14",
                    item_type="assign",
                )
            ],
        )
        html = f"""
        <html><body>
          <li class="activity assign modtype_assign" id="module-1231095">
            <div class="activityinstance">
              <a href="{url}">
                <span class="instancename">[11주차] 필드트립, PRD, IA</span>
              </a>
            </div>
            <div class="contentafterlink">마감 일시: 2026년 5월 14일 오후 4:00</div>
          </li>
        </body></html>
        """

        items = klms_sync.collect_candidate_items(dashboard, [course_page(html)])

        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].course, "Example Course")

    def test_lecture_upload_notice_is_not_tracked_as_assignment(self) -> None:
        html = """
        <html><body>
          <li class="activity url modtype_url" id="module-100003">
            <div class="activityinstance">
              <a href="https://klms.kaist.ac.kr/mod/url/view.php?id=100003">
                <span class="instancename">
                  NO Lecture video - 25.04.23
                  (Will be recorded and uploaded by April 29, 23:59)
                  <span class="accesshide">URL</span>
                </span>
              </a>
            </div>
          </li>
        </body></html>
        """

        items = klms_sync.parse_course_page(course_page(html))

        self.assertEqual(items, [])

    def test_url_quiz_with_due_date_is_still_tracked(self) -> None:
        html = """
        <html><body>
          <li class="activity url modtype_url" id="module-100004">
            <div class="activityinstance">
              <a href="https://klms.kaist.ac.kr/mod/url/view.php?id=100004">
                <span class="instancename">
                  Nano Quiz - 25.04.21(Mon)<span class="accesshide">URL</span>
                </span>
              </a>
            </div>
            <div class="contentafterlink">
              <p>Due Date: Monday, May 4, 11:59:59 PM.</p>
            </div>
          </li>
        </body></html>
        """

        items = klms_sync.parse_course_page(course_page(html))

        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].url, "https://klms.kaist.ac.kr/mod/url/view.php?id=100004")
        self.assertTrue(items[0].schedule)

    def test_notice_nano_quiz_with_due_date_becomes_assignment_candidate(self) -> None:
        page = {
            "requestedUrl": "https://klms.kaist.ac.kr/mod/courseboard/article.php?bwid=100004",
            "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?bwid=100004",
            "course": "Example Course",
            "title": "Nano Quiz - 25.04.21(Mon)",
            "html": """
            <html><body>
              <h1>Nano Quiz - 25.04.21(Mon)</h1>
              <p>Due Date: Monday, May 4, 11:59:59 PM.</p>
            </body></html>
            """,
        }

        items = klms_sync.extract_assignment_candidate_items([page], [])

        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["category"], "assignment_candidate")
        self.assertEqual(items[0]["title"], "Nano Quiz")
        self.assertIn("May 4", items[0]["due"])

    def test_exam_notice_title_combines_with_body_date_and_time(self) -> None:
        page = {
            "requestedUrl": "https://klms.kaist.ac.kr/mod/courseboard/article.php?bwid=100005",
            "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?bwid=100005",
            "title": "Midterm Exam Notice",
            "html": """
            <html><body>
              <nav><a href="/course/view.php?id=100001">Example Course</a></nav>
              <h1>Midterm Exam Notice</h1>
              <div class="courseboard"><div class="content">
                <p>Date &amp; Time: April 23rd, 2026, 9:00 am - 11:45 am</p>
                <p>Place: KAIST E15 Auditorium</p>
                <p>Range: Week 1 to Week 7 lectures.</p>
              </div></div>
            </body></html>
            """,
        }

        items = klms_sync.extract_exam_items([page])

        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["course"], "Example Course")
        self.assertEqual(items[0]["title"], "중간고사")
        self.assertEqual(items[0]["timing_precision"], "time-range")
        self.assertIn("오전 9:00 - 오전 11:45", items[0]["due"])
        self.assertEqual(items[0]["location"], "KAIST E15 Auditorium")
        self.assertEqual(items[0]["coverage"], "Week 1 to Week 7 lectures")

    def test_exam_notice_parses_h_notation_time_range(self) -> None:
        page = {
            "requestedUrl": "https://klms.kaist.ac.kr/mod/courseboard/article.php?bwid=100006",
            "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?bwid=100006",
            "title": "Mid-term exam essay topic",
            "html": """
            <html><body>
              <nav><a href="/course/view.php?id=100001">World Literature</a></nav>
              <h1>Mid-term exam essay topic</h1>
              <div class="courseboard"><div class="content">
                <p>The exam will be taken on the 16th of April, 2026 from 14h 30 to 15h 30 in our lecture room.</p>
              </div></div>
            </body></html>
            """,
        }

        items = klms_sync.extract_exam_items([page])

        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["course"], "World Literature")
        self.assertEqual(items[0]["title"], "중간고사")
        self.assertEqual(items[0]["timing_precision"], "time-range")
        self.assertIn("오후 2:30 - 오후 3:30", items[0]["due"])

    def test_notice_digest_exam_page_keeps_course_and_class_time(self) -> None:
        digest = {
            "courses": [
                {
                    "course": "영미 단편소설",
                    "notices": [
                        {
                            "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1189366&bwid=434501",
                            "title": "기말 고사 건 / On Final-term Exam",
                            "body_text": (
                                "시험은 2026년 6월 4일 수업 시간에 봅니다. "
                                "The exam will be taken on the 4th of June at the classroom "
                                "from 14h:30 to 15h:30."
                            ),
                        }
                    ],
                }
            ]
        }
        pages = klms_sync.build_notice_digest_candidate_pages(digest)
        class_times = klms_sync.normalize_class_time_overrides(
            {"영미 단편소설": "목요일 14:30-15:30"}
        )

        items = klms_sync.apply_exam_class_time_fallback(
            klms_sync.extract_exam_items(pages, {"unrelated": "Other Course"}),
            class_times,
        )

        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["course"], "영미 단편소설")
        self.assertEqual(items[0]["title"], "기말고사")
        self.assertEqual(items[0]["timing_precision"], "class-time")
        self.assertEqual(items[0]["sync_start"], "2026-06-04T14:30:00+09:00")
        self.assertEqual(items[0]["sync_due"], "2026-06-04T15:30:00+09:00")

    def test_past_exam_items_are_not_visible(self) -> None:
        past = {
            "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=100007",
            "type": "exam",
            "category": "exam",
            "course": "Example Course",
            "title": "중간고사",
            "due": "2020년 4월 16일",
            "sync_due": "2020-04-16T15:30:00+09:00",
            "approval_status": "approved",
        }
        future = {
            "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=100008",
            "type": "exam",
            "category": "exam",
            "course": "Example Course",
            "title": "기말고사",
            "due": "2099년 6월 4일",
            "sync_due": "2099-06-04T15:30:00+09:00",
            "approval_status": "approved",
        }

        approved, candidates = klms_sync.split_exam_items_for_confirmation([past, future])
        (
            approved_with_records,
            candidates_with_records,
            past_records,
            exam_records,
        ) = klms_sync.split_exam_items_for_confirmation_with_records([past, future])

        self.assertEqual(candidates, [])
        self.assertEqual(len(approved), 1)
        self.assertEqual(approved[0]["title"], "기말고사")
        self.assertEqual(candidates_with_records, [])
        self.assertEqual(approved_with_records[0]["title"], "기말고사")
        self.assertEqual(len(past_records), 1)
        self.assertEqual(past_records[0]["title"], "중간고사")
        self.assertEqual(past_records[0]["record_status"], "completed")
        self.assertEqual(past_records[0]["completion_reason"], "past_due")
        self.assertEqual(len(exam_records), 2)

    def test_duplicate_exam_items_are_deduped_by_course_title_and_time(self) -> None:
        first = {
            "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=100007",
            "type": "exam",
            "category": "exam",
            "course": "데이타베이스 개론",
            "title": "기말고사",
            "due": "2026년 6월 17일 오후 1:00 - 오후 4:00",
            "sync_due": "2026-06-17T16:00:00+09:00",
            "sync_start": "2026-06-17T13:00:00+09:00",
            "instructions": "시험 범위: 전체",
        }
        second = {
            **first,
            "url": "https://klms.kaist.ac.kr/mod/assign/view.php?id=100008",
            "instructions": "시험 범위: 전체 및 SQL",
        }

        deduped = klms_sync.dedupe_sync_items([first, second])

        self.assertEqual(len(deduped), 1)
        self.assertEqual(deduped[0]["course"], "데이타베이스 개론")
        self.assertIn("SQL", deduped[0]["instructions"])

    def test_success_payload_keeps_completed_assignment_records(self) -> None:
        completed = {
            "url": "https://klms.kaist.ac.kr/mod/url/view.php?id=100004",
            "type": "assignment_notice",
            "category": "assignment",
            "course": "Example Course",
            "title": "Nano Quiz",
            "due": "Monday, May 4, 11:59:59 PM",
            "submission": "",
            "instructions": "",
            "record_status": "completed",
            "completion_reason": "past_due",
            "auto_completed": True,
        }

        payload = klms_sync.build_success_payload([], [], [], [], [], [completed], [completed])
        content = payload["content"]

        self.assertEqual(content["assignments"], [])
        self.assertEqual(len(content["completed_assignments"]), 1)
        self.assertEqual(len(content["assignment_records"]), 1)
        self.assertEqual(content["completed_assignments"][0]["record_status"], "completed")
        self.assertIn("완료 기록", payload["html"])

    def test_success_payload_keeps_past_exam_records(self) -> None:
        past_exam = {
            "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=100010",
            "type": "exam",
            "category": "exam",
            "course": "Example Course",
            "title": "Midterm 2",
            "due": "2026년 5월 6일 오전 10:30 - 오후 12:00",
            "sync_due": "2026-05-06T12:00:00+09:00",
            "sync_start": "2026-05-06T10:30:00+09:00",
            "instructions": "시험 범위: Lecture 3",
            "record_status": "completed",
            "completion_reason": "past_due",
        }

        payload = klms_sync.build_success_payload(
            [], [], [], [], [], past_exams=[past_exam], exam_records=[past_exam]
        )
        content = payload["content"]

        self.assertEqual(content["exam_items"], [])
        self.assertEqual(len(content["past_exams"]), 1)
        self.assertEqual(len(content["exam_records"]), 1)
        self.assertEqual(content["past_exams"][0]["completion_reason"], "past_due")
        self.assertIn("지난 시험 기록", payload["html"])


if __name__ == "__main__":
    unittest.main()
