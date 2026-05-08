import io
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

import process_klms_assignments  # noqa: E402


def state_payload(assignments):
    return {
        "status": "ok",
        "content": {
            "kind": "success",
            "assignments": assignments,
            "exam_items": [],
            "exam_candidates": [],
            "assignment_candidates": [],
            "help_desk_items": [],
        },
    }


def assignment(**overrides):
    payload = {
        "url": "https://klms.kaist.ac.kr/mod/assign/view.php?id=12345",
        "type": "assign",
        "category": "assignment",
        "course": "Example Course",
        "title": "Homework 1",
        "due": "2026년 5월 10일(일요일) 오후 11:59",
        "sync_due": "2026-05-10T23:59:00+09:00",
        "instructions": "Submit a PDF report about Week 1 slides.",
        "submission": "",
    }
    payload.update(overrides)
    return payload


class ProcessKlmsAssignmentsTests(unittest.TestCase):
    def test_deterministic_processor_creates_assignment_work_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            state_json = tmp_path / "state.json"
            manifest_json = tmp_path / "manifest.json"
            output_root = tmp_path / "assignment_work"
            material_path = tmp_path / "course_files" / "Example Course" / "Week 1 Slides.pdf"
            material_path.parent.mkdir(parents=True)
            material_path.write_text("slides", encoding="utf-8")

            state_json.write_text(json.dumps(state_payload([assignment()])), encoding="utf-8")
            manifest_json.write_text(
                json.dumps(
                    [
                        {
                            "course": "Example Course",
                            "filename": "Week 1 Slides.pdf",
                            "relative_path": "Example Course/resources/Week 1 Slides.pdf",
                            "absolute_path": str(material_path),
                            "url": "https://klms.kaist.ac.kr/mod/resource/view.php?id=20001",
                            "source_url": "https://klms.kaist.ac.kr/mod/resource/index.php?id=10001",
                            "source_title": "Week 1",
                            "section_title": "1주차",
                            "activity_title": "Week 1 Slides",
                        }
                    ]
                ),
                encoding="utf-8",
            )

            args = process_klms_assignments.build_parser().parse_args(
                [
                    "--state-json",
                    str(state_json),
                    "--manifest-json",
                    str(manifest_json),
                    "--output-root",
                    str(output_root),
                    "--provider",
                    "deterministic",
                ]
            )
            result = process_klms_assignments.process_assignments(args)

            self.assertEqual(result.index["assignment_count"], 1)
            self.assertEqual(result.index["processed_count"], 1)
            entry = result.index["assignments"][0]
            brief = Path(entry["brief_path"]).read_text(encoding="utf-8")
            checklist = Path(entry["assignment_dir"], "checklist.md").read_text(encoding="utf-8")
            draft = Path(entry["assignment_dir"], "draft_template.md").read_text(encoding="utf-8")

            self.assertIn("Homework 1", brief)
            self.assertIn("Week 1 Slides.pdf", brief)
            self.assertIn("작성 보조용", brief)
            self.assertIn("- [ ] KLMS 원문 다시 열어 요구사항 확인", checklist)
            self.assertIn("not a completed submission", draft)

    def test_completed_assignments_are_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            state_json = tmp_path / "state.json"
            output_root = tmp_path / "assignment_work"
            state_json.write_text(
                json.dumps(
                    state_payload(
                        [
                            assignment(submission="제출되었습니다"),
                            assignment(url="https://klms.kaist.ac.kr/mod/assign/view.php?id=222"),
                        ]
                    )
                ),
                encoding="utf-8",
            )

            args = process_klms_assignments.build_parser().parse_args(
                [
                    "--state-json",
                    str(state_json),
                    "--output-root",
                    str(output_root),
                    "--provider",
                    "deterministic",
                ]
            )
            result = process_klms_assignments.process_assignments(args)

            self.assertEqual(result.index["assignment_count"], 1)
            self.assertEqual(result.index["assignments"][0]["assignment_id"], "assign-222")

    def test_second_run_skips_unchanged_assignment(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            state_json = tmp_path / "state.json"
            output_root = tmp_path / "assignment_work"
            state_json.write_text(json.dumps(state_payload([assignment()])), encoding="utf-8")
            args = process_klms_assignments.build_parser().parse_args(
                [
                    "--state-json",
                    str(state_json),
                    "--output-root",
                    str(output_root),
                    "--provider",
                    "deterministic",
                ]
            )

            first = process_klms_assignments.process_assignments(args)
            second = process_klms_assignments.process_assignments(args)

            self.assertEqual(first.index["processed_count"], 1)
            self.assertEqual(second.index["processed_count"], 0)
            self.assertEqual(second.index["skipped_count"], 1)

    def test_codex_provider_uses_schema_and_last_message(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            state_json = tmp_path / "state.json"
            output_root = tmp_path / "assignment_work"
            fake_codex = tmp_path / "codex"
            state_json.write_text(json.dumps(state_payload([assignment()])), encoding="utf-8")
            fake_codex.write_text(
                """#!/bin/sh
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output-last-message" ]; then
    shift
    out="$1"
  fi
  shift
done
cat >/dev/null
printf '%s' '{"summary":"Fake summary","requirements":["Read prompt"],"deliverables":["Outline"],"plan":["Draft"],"draft_template":"# Fake Draft","questions":["Any rubric?"],"integrity_notes":["User writes final answer"]}' > "$out"
""",
                encoding="utf-8",
            )
            fake_codex.chmod(fake_codex.stat().st_mode | stat.S_IXUSR)

            args = process_klms_assignments.build_parser().parse_args(
                [
                    "--state-json",
                    str(state_json),
                    "--output-root",
                    str(output_root),
                    "--provider",
                    "codex",
                    "--codex-bin",
                    str(fake_codex),
                    "--force",
                ]
            )
            result = process_klms_assignments.process_assignments(args)

            entry = result.index["assignments"][0]
            brief = Path(entry["brief_path"]).read_text(encoding="utf-8")
            status = json.loads(Path(entry["assignment_dir"], "status.json").read_text(encoding="utf-8"))

            self.assertIn("Fake summary", brief)
            self.assertEqual(status["provider"], "codex")
            self.assertEqual(status["provider_status"]["status"], "ok")
            self.assertTrue(Path(entry["assignment_dir"], "codex_output_schema.json").exists())

    def test_select_processes_only_chosen_assignment(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            state_json = tmp_path / "state.json"
            output_root = tmp_path / "assignment_work"
            first = assignment(
                url="https://klms.kaist.ac.kr/mod/assign/view.php?id=111",
                title="Homework 1",
            )
            second = assignment(
                url="https://klms.kaist.ac.kr/mod/assign/view.php?id=222",
                title="Homework 2",
            )
            state_json.write_text(json.dumps(state_payload([first, second])), encoding="utf-8")
            args = process_klms_assignments.build_parser().parse_args(
                [
                    "--state-json",
                    str(state_json),
                    "--output-root",
                    str(output_root),
                    "--provider",
                    "deterministic",
                    "--select",
                ]
            )

            with patch("sys.stdin", io.StringIO("2\n")), patch("sys.stderr", io.StringIO()):
                result = process_klms_assignments.process_assignments(args)

            self.assertEqual(result.index["assignment_count"], 1)
            self.assertEqual(result.index["assignments"][0]["assignment_id"], "assign-222")
            self.assertEqual(result.index["assignments"][0]["title"], "Homework 2")

    def test_parse_assignment_selection_supports_lists_ranges_and_cancel(self) -> None:
        parse = process_klms_assignments.parse_assignment_selection

        self.assertEqual(parse("1, 3-4", 5), [0, 2, 3])
        self.assertEqual(parse("all", 3), [0, 1, 2])
        self.assertEqual(parse("q", 3), [])
        self.assertIsNone(parse("4", 3))
        self.assertIsNone(parse("3-1", 3))


if __name__ == "__main__":
    unittest.main()
