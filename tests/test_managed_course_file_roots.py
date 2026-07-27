import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
ROOT_HELPER = PROJECT_DIR / "src" / "python" / "managed_course_file_roots.py"


class ManagedCourseFileRootAdoptionTests(unittest.TestCase):
    def run_adoption(self, root: Path, manifest: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(ROOT_HELPER),
                "--root",
                str(root),
                "--purpose",
                "course-files",
                "--initialize",
                "--adopt-from-manifest",
                str(manifest),
            ],
            capture_output=True,
            text=True,
        )

    def test_matching_prior_manifest_adopts_populated_custom_root(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            root = tmp_path / "custom-course-files"
            tracked = root / "Course" / "자료" / "강의.pdf"
            tracked.parent.mkdir(parents=True)
            tracked.write_text("preserve", encoding="utf-8")
            manifest = tmp_path / "download-log.json"
            manifest.write_text(
                json.dumps(
                    {
                        "results": [
                            {
                                "relative_path": "Course/자료/강의.pdf",
                                "downloads_relative_path": "Course/자료/강의.pdf",
                                "manifest_relative_path": "Course/자료/강의.pdf",
                            }
                        ]
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

            result = self.run_adoption(root, manifest)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(tracked.read_text(encoding="utf-8"), "preserve")
            self.assertTrue((root / ".klms-sync-managed-root.json").is_file())

    def test_extra_file_or_manifest_traversal_refuses_adoption_without_changes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            root = tmp_path / "custom-course-files"
            root.mkdir()
            tracked = root / "tracked.pdf"
            extra = root / "sentinel.txt"
            tracked.write_text("tracked", encoding="utf-8")
            extra.write_text("keep", encoding="utf-8")
            manifest = tmp_path / "manifest.json"
            manifest.write_text(json.dumps([{"relative_path": "tracked.pdf"}]), encoding="utf-8")

            result = self.run_adoption(root, manifest)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("untracked file", result.stderr)
            self.assertFalse((root / ".klms-sync-managed-root.json").exists())
            self.assertEqual(extra.read_text(encoding="utf-8"), "keep")

            manifest.write_text(json.dumps([{"relative_path": "../sentinel.txt"}]), encoding="utf-8")
            traversal = self.run_adoption(root, manifest)
            self.assertNotEqual(traversal.returncode, 0)
            self.assertIn("escapes its root", traversal.stderr)
            self.assertFalse((root / ".klms-sync-managed-root.json").exists())

    def test_symlink_or_missing_manifest_refuses_adoption_without_changes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            outside = tmp_path / "outside.pdf"
            outside.write_text("outside", encoding="utf-8")
            root = tmp_path / "custom-course-files"
            root.mkdir()
            (root / "linked.pdf").symlink_to(outside)
            manifest = tmp_path / "manifest.json"
            manifest.write_text(json.dumps([{"relative_path": "linked.pdf"}]), encoding="utf-8")

            symlink = self.run_adoption(root, manifest)

            self.assertNotEqual(symlink.returncode, 0)
            self.assertIn("containing a symlink", symlink.stderr)
            self.assertFalse((root / ".klms-sync-managed-root.json").exists())
            self.assertEqual(outside.read_text(encoding="utf-8"), "outside")

            (root / "linked.pdf").unlink()
            (root / "tracked.pdf").write_text("tracked", encoding="utf-8")
            missing = self.run_adoption(root, tmp_path / "missing.json")
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("without a prior manifest", missing.stderr)
            self.assertFalse((root / ".klms-sync-managed-root.json").exists())


if __name__ == "__main__":
    unittest.main()
