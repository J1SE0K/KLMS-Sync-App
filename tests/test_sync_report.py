import json
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

import sync_report  # noqa: E402


class SyncReportTests(unittest.TestCase):
    def test_combined_slowest_stages_are_sorted_across_scopes(self) -> None:
        stages = sync_report.combined_slowest_stages(
            {"slowest_stages": [{"name": "core", "duration_ms": 1000}]},
            {"slowest_stages": [{"name": "notice", "duration_ms": 3000}]},
            {"slowest_stages": [{"name": "files", "duration_ms": 5000}]},
        )

        self.assertEqual([item["name"] for item in stages], ["files", "notice", "core"])

    def test_report_uses_next_state_when_state_json_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cache_dir = root / "cache"
            state_dir = root / "state"
            cache_dir.mkdir()
            state_dir.mkdir()
            (state_dir / "next_state.json").write_text(
                json.dumps(
                    {
                        "content": {
                            "assignments": [{"title": "A"}],
                            "exam_items": [{"title": "E"}],
                            "help_desk_items": [{"title": "H"}],
                        }
                    }
                ),
                encoding="utf-8",
            )

            report = sync_report.build_report(cache_dir, state_dir / "state.json")

        self.assertEqual(report["state"], {"assignments": 1, "exams": 1, "helpdesk": 1})

    def test_report_uses_scoped_file_cache_when_top_level_file_cache_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cache_dir = root / "cache"
            state_dir = root / "state"
            files_dir = cache_dir / "files"
            files_dir.mkdir(parents=True)
            state_dir.mkdir()
            (state_dir / "state.json").write_text('{"content": {}}', encoding="utf-8")
            (files_dir / "course_file_download_result.json").write_text(
                json.dumps(
                    {
                        "fileCount": 72,
                        "quarantineCount": 2,
                        "results": [
                            {"copied_to_new_files_inbox": True},
                            {"copied_to_new_files_inbox": False},
                        ],
                    }
                ),
                encoding="utf-8",
            )
            (files_dir / "course_file_prune_result.json").write_text(
                '{"deleted_file_count": 3}', encoding="utf-8"
            )
            (files_dir / "course_file_archive_prune_result.json").write_text(
                '{"deleted_file_count": 4}', encoding="utf-8"
            )

            report = sync_report.build_report(cache_dir, state_dir / "state.json")

        self.assertEqual(
            report["files"],
            {
                "total": 72,
                "new_files": 1,
                "quarantine": 2,
                "pruned": 3,
                "archive_pruned": 4,
            },
        )


if __name__ == "__main__":
    unittest.main()
