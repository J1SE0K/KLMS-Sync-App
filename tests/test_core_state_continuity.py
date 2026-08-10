import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
PYTHON_SUBPROCESS_ENV = {
    "PYTHONPATH": os.pathsep.join(
        (
            str(PROJECT_DIR / "src" / "python"),
            str(PROJECT_DIR / "vendor" / "python-packages"),
        )
    )
}
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

from klms_sync_v2.models import Assignment, Event  # noqa: E402
from klms_sync_v2.state_continuity import (  # noqa: E402
    prior_active_assignment_records,
)


def visible_course_page(*module_urls: str) -> dict[str, str]:
    course_url = "https://klms.kaist.ac.kr/course/view.php?id=43"
    activities = "".join(
        f'<li class="activity"><div class="activityinstance"><a href="{url}">item</a></div></li>'
        for url in module_urls
    )
    return {
        "requestedUrl": course_url,
        "url": course_url,
        "status": "200",
        "html": f'<main data-region="course-content"><ul class="topics">{activities}</ul></main>',
    }


class CoreStateContinuityTests(unittest.TestCase):
    def test_state_continuity_module_is_packaged_in_mac_app(self) -> None:
        # Given: the Mac app packages source files through an explicit allowlist.
        allowlist = PROJECT_DIR / "apps/KLMSync/EnginePayloadAllowlist.txt"
        # When: the packaged source paths are loaded.
        packaged_paths = allowlist.read_text(encoding="utf-8").splitlines()
        # Then: the continuity module required by the CLI is present at runtime.
        self.assertIn("src/python/klms_sync_v2/state_continuity.py", packaged_paths)

    def test_prior_active_assignment_records_filters_invalid_invisible_and_current_sources(
        self,
    ) -> None:
        visible_url = "https://klms.kaist.ac.kr/mod/forum/view.php?id=1"
        current_assignment_url = "https://klms.kaist.ac.kr/mod/assign/view.php?id=2"
        current_event_url = "https://klms.kaist.ac.kr/mod/quiz/view.php?id=3"
        retained_record = {"url": visible_url, "record_status": "active"}
        previous_state = {
            "content": {
                "assignment_records": [
                    retained_record,
                    {"url": current_assignment_url, "record_status": "active"},
                    {"url": current_event_url, "record_status": "active"},
                    {"url": "https://klms.kaist.ac.kr/mod/forum/view.php?id=99"},
                    {"url": visible_url, "record_status": "completed"},
                    {"record_status": "active"},
                    "invalid-record",
                ],
                "assignments": "invalid-section",
            }
        }
        current_items = [
            Assignment(current_assignment_url, "", "", "", "", "source"),
            Event(current_event_url, "", "", "", "", "source"),
        ]

        # When: continuity selection sees malformed, invisible, and current items.
        records = prior_active_assignment_records(
            previous_state,
            [visible_course_page(visible_url, current_assignment_url, current_event_url)],
            current_items,
        )

        # Then: only the visible active item absent from current sources survives.
        self.assertEqual(records, [retained_record])

    def test_prior_active_assignment_records_preserves_section_order_and_dedupes(
        self,
    ) -> None:
        first_url = "https://klms.kaist.ac.kr/mod/forum/view.php?id=1"
        second_url = "https://klms.kaist.ac.kr/mod/forum/view.php?id=2"
        first_record = {"url": first_url, "title": "first"}
        previous_state = {
            "content": {
                "assignment_records": [first_record],
                "assignments": [
                    {"url": first_url, "title": "duplicate"},
                    {"url": second_url, "record_status": "active"},
                ],
            }
        }

        # When: the same normalized URL appears in both supported sections.
        records = prior_active_assignment_records(
            previous_state,
            [visible_course_page(first_url, second_url)],
            [],
        )

        # Then: first-seen section order wins and a missing status means active.
        self.assertEqual(records, [first_record, previous_state["content"]["assignments"][1]])

    def test_cli_build_note_preserves_previous_active_assignment_when_module_remains_visible_without_schedule(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            dashboard = tmp_dir / "dashboard.json"
            course_pages = tmp_dir / "course_pages.json"
            details = tmp_dir / "details.json"
            previous_state = tmp_dir / "state.json"
            output_state = tmp_dir / "next_state.json"
            output_status = tmp_dir / "status.json"
            output_html = tmp_dir / "section.html"
            previous_url = "https://klms.kaist.ac.kr/mod/forum/view.php?id=1"

            # Given: KLMS still exposes the previous activity, but no longer shows
            # its schedule, so the current candidate parser does not emit it.
            dashboard.write_text(
                json.dumps(
                    [
                        {
                            "requestedUrl": "https://klms.kaist.ac.kr/my/",
                            "url": "https://klms.kaist.ac.kr/my/",
                            "title": "Dashboard",
                            "html": """
                            <div class="list-box assign">
                              <a href="https://klms.kaist.ac.kr/mod/assign/view.php?id=2">open</a>
                              <ul>
                                <li>2099.01.01~2099.01.02</li>
                                <li>Current assignment</li>
                                <li>Course</li>
                              </ul>
                            </div>
                            """,
                        }
                    ]
                ),
                encoding="utf-8",
            )
            course_url = "https://klms.kaist.ac.kr/course/view.php?id=43"
            course_pages.write_text(
                json.dumps(
                    [
                        {
                            "requestedUrl": course_url,
                            "url": course_url,
                            "status": 200,
                            "title": "Course",
                            "html": f"""
                            <main data-region="course-content">
                              <ul class="topics">
                                <li class="activity forum modtype_forum">
                                  <div class="activityinstance">
                                    <a href="{previous_url}">Previous activity</a>
                                  </div>
                                </li>
                              </ul>
                            </main>
                            """,
                        }
                    ]
                ),
                encoding="utf-8",
            )
            details.write_text("[]", encoding="utf-8")
            previous_record = {
                "url": previous_url,
                "type": "forum",
                "category": "assignment",
                "course": "Course",
                "course_id": "43",
                "title": "Previous activity",
                "due": "2026-01-02 23:59",
                "sync_due": "2026-01-02T23:59:00+09:00",
                "record_status": "active",
            }
            previous_state.write_text(
                json.dumps(
                    {
                        "status": "ok",
                        "generated_at": "2026-01-01 12:00 KST",
                        "content": {
                            "assignments": [previous_record],
                            "assignment_records": [previous_record],
                        },
                    }
                ),
                encoding="utf-8",
            )

            # When: core rebuilds the authoritative note state.
            result = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "klms_sync_v2.cli",
                    "build-note",
                    "--dashboard-json",
                    str(dashboard),
                    "--course-pages-json",
                    str(course_pages),
                    "--details-json",
                    str(details),
                    "--state-json",
                    str(previous_state),
                    "--output-html",
                    str(output_html),
                    "--output-state",
                    str(output_state),
                    "--output-status",
                    str(output_status),
                    "--generated-at",
                    "2026-08-10 19:00 KST",
                ],
                cwd=PROJECT_DIR,
                env=PYTHON_SUBPROCESS_ENV,
                text=True,
                capture_output=True,
                check=False,
            )

            # Then: the previous item is retained and expires normally instead of
            # turning the complete core build into a destructive-delta error.
            self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
            next_state = json.loads(output_state.read_text(encoding="utf-8"))
            status = json.loads(output_status.read_text(encoding="utf-8"))
            self.assertEqual(next_state["status"], "ok")
            self.assertEqual(status["status"], "ok")
            self.assertEqual(status["completed_assignment_count"], 1)
            self.assertEqual(
                next_state["content"]["completed_assignments"][0]["url"],
                previous_url,
            )


if __name__ == "__main__":
    unittest.main()
