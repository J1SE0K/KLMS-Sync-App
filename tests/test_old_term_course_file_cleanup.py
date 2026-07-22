import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT_DIR / "src" / "python" / "cleanup_old_term_course_files.py"
ROOT_HELPER = PROJECT_DIR / "src" / "python" / "managed_course_file_roots.py"


def initialize_root(root: Path) -> None:
    subprocess.run(
        [
            sys.executable,
            str(ROOT_HELPER),
            "--root",
            str(root),
            "--purpose",
            "course-files",
            "--approved-root",
            str(root),
            "--initialize",
        ],
        check=True,
        capture_output=True,
        text=True,
    )


class OldTermCourseFileCleanupTests(unittest.TestCase):
    def test_moves_non_current_course_files_and_rewrites_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output_root = root / "course_files"
            current_file = output_root / "2026 Summer" / "공공정책 특강" / "current.pdf"
            old_file = output_root / "2025 Spring" / "영미단편소설" / "old.pdf"
            current_file.parent.mkdir(parents=True)
            old_file.parent.mkdir(parents=True)
            current_file.write_text("current", encoding="utf-8")
            old_file.write_text("old", encoding="utf-8")
            initialize_root(output_root)

            manifest_path = root / "manifest.json"
            terms_path = root / "academic_terms.json"
            result_path = root / "old_term_cleanup.json"
            trash_root = root / "trash"

            manifest_path.write_text(
                json.dumps(
                    [
                        {
                            "course": "공공정책 특강",
                            "filename": "current.pdf",
                            "relative_path": "2026 Summer/공공정책 특강/current.pdf",
                            "absolute_path": str(current_file),
                        },
                        {
                            "course": "영미단편소설",
                            "filename": "old.pdf",
                            "relative_path": "2025 Spring/영미단편소설/old.pdf",
                            "absolute_path": str(old_file),
                        },
                    ],
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            terms_path.write_text(
                json.dumps(
                    {
                        "selected_year": 2026,
                        "selected_semester": "여름학기",
                        "courses": [{"title": "공공정책 특강", "code": "HSS000"}],
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

            subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--manifest-json",
                    str(manifest_path),
                    "--academic-terms-json",
                    str(terms_path),
                    "--output-json",
                    str(result_path),
                    "--root",
                    str(output_root),
                    "--trash-root",
                    str(trash_root),
                ],
                check=True,
                cwd=PROJECT_DIR,
            )

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            result = json.loads(result_path.read_text(encoding="utf-8"))

            self.assertEqual([item["course"] for item in manifest], ["공공정책 특강"])
            self.assertTrue(current_file.exists())
            self.assertFalse(old_file.exists())
            self.assertEqual(result["status"], "ok")
            self.assertEqual(result["removed_count"], 1)
            self.assertEqual(result["kept_count"], 1)
            self.assertTrue(Path(result["items"][0]["trash_path"]).exists())

    def test_skips_when_current_term_catalog_is_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            file_path = root / "course_files" / "old.pdf"
            file_path.parent.mkdir(parents=True)
            file_path.write_text("old", encoding="utf-8")
            initialize_root(file_path.parent)

            manifest_path = root / "manifest.json"
            terms_path = root / "academic_terms.json"
            result_path = root / "old_term_cleanup.json"

            original_manifest = [
                {
                    "course": "영미단편소설",
                    "filename": "old.pdf",
                    "relative_path": "old.pdf",
                    "absolute_path": str(file_path),
                }
            ]
            manifest_path.write_text(
                json.dumps(original_manifest, ensure_ascii=False),
                encoding="utf-8",
            )
            terms_path.write_text("{}", encoding="utf-8")

            subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--manifest-json",
                    str(manifest_path),
                    "--academic-terms-json",
                    str(terms_path),
                    "--output-json",
                    str(result_path),
                    "--root",
                    str(file_path.parent),
                ],
                check=True,
                cwd=PROJECT_DIR,
            )

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            result = json.loads(result_path.read_text(encoding="utf-8"))

            self.assertEqual(manifest, original_manifest)
            self.assertTrue(file_path.exists())
            self.assertEqual(result["status"], "skipped")
            self.assertEqual(result["reason"], "current-term-courses-unavailable")

    def test_rejects_manifest_path_outside_managed_root(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output_root = root / "course_files"
            output_root.mkdir()
            initialize_root(output_root)
            outside = root / "outside.pdf"
            outside.write_text("keep", encoding="utf-8")
            manifest_path = root / "manifest.json"
            terms_path = root / "academic_terms.json"
            result_path = root / "old_term_cleanup.json"
            manifest_path.write_text(
                json.dumps(
                    [{
                        "course": "old course",
                        "relative_path": "../outside.pdf",
                        "absolute_path": str(outside),
                    }]
                ),
                encoding="utf-8",
            )
            terms_path.write_text(
                json.dumps({
                    "selected_year": 2026,
                    "selected_semester": "여름학기",
                    "courses": [{"title": "current course"}],
                }),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--manifest-json",
                    str(manifest_path),
                    "--academic-terms-json",
                    str(terms_path),
                    "--output-json",
                    str(result_path),
                    "--root",
                    str(output_root),
                    "--trash-root",
                    str(root / "trash"),
                ],
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("escapes its root", result.stderr)
            self.assertEqual(outside.read_text(encoding="utf-8"), "keep")


if __name__ == "__main__":
    unittest.main()
