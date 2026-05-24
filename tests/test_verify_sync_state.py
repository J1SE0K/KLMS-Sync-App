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
                            "exam_items": [{"course": "C", "title": "T", "due": "D"}],
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


if __name__ == "__main__":
    unittest.main()
