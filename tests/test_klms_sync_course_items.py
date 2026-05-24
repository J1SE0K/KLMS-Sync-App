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

    def test_exact_ignored_dashboard_course_name_is_not_collected(self) -> None:
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


if __name__ == "__main__":
    unittest.main()
