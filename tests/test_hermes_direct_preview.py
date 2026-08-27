import json
import sys
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

from hermes_direct_preview import build_diff, build_preview, canonical_digest  # noqa: E402


class HermesDirectPreviewTests(unittest.TestCase):
    def test_build_preview_filters_allowlist_classifies_modules_and_strips_html(self) -> None:
        pages = [
            {
                "requestedUrl": "https://klms.kaist.ac.kr/course/view.php?id=101",
                "url": "https://klms.kaist.ac.kr/course/view.php?id=101",
                "status": 200,
                "html": """
                    <html><head><title>강좌: 테스트 과목</title></head><body>
                    <a href='/mod/courseboard/view.php?id=1'>공지</a>
                    <a href='/mod/assign/view.php?id=2'>과제</a>
                    <a href='/mod/quiz/view.php?id=3'>시험</a>
                    <a href='/mod/resource/view.php?id=4#section'>자료</a>
                    <a href='/mod/resource/view.php?id=4'>자료 중복</a>
                    <a href='/mod/forum/view.php?id=5'>포럼</a>
                    <a href='https://example.com/mod/resource/view.php?id=6'>외부</a>
                    </body></html>
                """,
            },
            {
                "requestedUrl": "https://klms.kaist.ac.kr/course/view.php?id=999",
                "url": "https://klms.kaist.ac.kr/course/view.php?id=999",
                "status": 200,
                "html": "<html><title>제외 과목</title></html>",
            },
        ]

        preview = build_preview(
            pages,
            active_course_ids={"101"},
            term={"year": 2026, "semester_code": "20", "label": "2026년 가을학기"},
            generated_at="2026-08-26T00:00:00Z",
        )

        self.assertEqual(preview["course_pages"], 1)
        self.assertEqual(preview["activity_counts"], {
            "notice": 1,
            "assignment": 1,
            "exam": 1,
            "file": 1,
            "forum": 1,
            "other": 0,
            "total": 5,
        })
        self.assertEqual(preview["courses"][0]["course_title"], "테스트 과목")
        self.assertEqual(len(preview["courses"][0]["activities"]), 5)
        self.assertNotIn("html", json.dumps(preview))
        self.assertRegex(preview["digest_sha256"], r"^[0-9a-f]{64}$")

    def test_digest_is_stable_and_excludes_generation_time(self) -> None:
        payload = {"b": 1, "a": [2]}
        self.assertEqual(canonical_digest(payload), canonical_digest({"a": [2], "b": 1}))

    def test_diff_reports_added_changed_and_removed_without_authorizing_delete(self) -> None:
        previous = {
            "courses": [{"activities": [
                {"url": "https://klms.kaist.ac.kr/mod/assign/view.php?id=1", "title": "old", "type": "assignment"},
                {"url": "https://klms.kaist.ac.kr/mod/quiz/view.php?id=2", "title": "gone", "type": "exam"},
            ]}]
        }
        current = {
            "courses": [{"activities": [
                {"url": "https://klms.kaist.ac.kr/mod/assign/view.php?id=1", "title": "new", "type": "assignment"},
                {"url": "https://klms.kaist.ac.kr/mod/resource/view.php?id=3", "title": "file", "type": "file"},
            ]}]
        }

        diff = build_diff(previous, current)
        self.assertEqual(diff["added"], 1)
        self.assertEqual(diff["changed"], 1)
        self.assertEqual(diff["removed_candidates"], 1)
        self.assertFalse(diff["deletion_authorized"])

    def test_diff_uses_course_id_and_url_for_shared_navigation_links(self) -> None:
        shared = "https://klms.kaist.ac.kr/mod/courseboard/view.php?id=1"
        previous = {
            "courses": [
                {"course_id": "101", "activities": [{"url": shared, "title": "공지", "type": "notice"}]},
                {"course_id": "202", "activities": [{"url": shared, "title": "공지", "type": "notice"}]},
            ]
        }
        current = {
            "courses": [
                {"course_id": "202", "activities": [{"url": shared, "title": "공지", "type": "notice"}]},
                {"course_id": "101", "activities": [{"url": shared, "title": "공지", "type": "notice"}]},
            ]
        }

        diff = build_diff(previous, current)
        self.assertEqual(diff["added"], 0)
        self.assertEqual(diff["changed"], 0)
        self.assertEqual(diff["removed_candidates"], 0)

    def test_build_preview_rejects_final_url_course_id_mismatch(self) -> None:
        pages = [{
            "requestedUrl": "https://klms.kaist.ac.kr/course/view.php?id=101",
            "url": "https://klms.kaist.ac.kr/course/view.php?id=202",
            "status": 200,
            "html": "<html><title>잘못 리디렉션된 과목</title></html>",
        }]

        with self.assertRaisesRegex(ValueError, "final URL course id mismatch"):
            build_preview(
                pages,
                active_course_ids={"101"},
                term={"year": 2026, "semester_code": "20", "label": "2026년 가을학기"},
                generated_at="2026-08-26T00:00:00Z",
            )

    def test_build_preview_rejects_duplicate_authoritative_course_pages(self) -> None:
        page = {
            "requestedUrl": "https://klms.kaist.ac.kr/course/view.php?id=101",
            "url": "https://klms.kaist.ac.kr/course/view.php?id=101",
            "status": 200,
            "html": "<html><title>중복 과목</title></html>",
        }

        with self.assertRaisesRegex(ValueError, "duplicate authoritative course page: 101"):
            build_preview(
                [page, dict(page)],
                active_course_ids={"101"},
                term={"year": 2026, "semester_code": "20", "label": "2026년 가을학기"},
                generated_at="2026-08-26T00:00:00Z",
            )


if __name__ == "__main__":
    unittest.main()
