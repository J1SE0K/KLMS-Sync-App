import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
ROOT_HELPER = PROJECT_DIR / "src" / "python" / "managed_course_file_roots.py"


def initialize_root(root: Path, purpose: str = "course-files") -> None:
    subprocess.run(
        [
            sys.executable,
            str(ROOT_HELPER),
            "--root",
            str(root),
            "--purpose",
            purpose,
            "--approved-root",
            str(root),
            "--initialize",
        ],
        check=True,
        capture_output=True,
        text=True,
    )


class PruneCourseFilesTests(unittest.TestCase):
    def test_prune_removes_untracked_files_and_empty_dirs(self) -> None:
        script = PROJECT_DIR / "src" / "python" / "prune_course_files.py"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            root = tmp_path / "archive"
            tracked_file = root / "Course" / "resources" / "Week Notes.pdf"
            stale_file = root / "Course" / "resources" / "강의 자료" / "Old.pdf"
            ds_store = root / ".DS_Store"
            tracked_file.parent.mkdir(parents=True)
            stale_file.parent.mkdir(parents=True)
            tracked_file.write_text("tracked", encoding="utf-8")
            stale_file.write_text("stale", encoding="utf-8")
            ds_store.write_text("finder", encoding="utf-8")
            initialize_root(root)

            manifest_path = tmp_path / "manifest.json"
            manifest_path.write_text(
                json.dumps(
                    [
                        {
                            "relative_path": "Course/resources/Week Notes.pdf",
                        }
                    ]
                ),
                encoding="utf-8",
            )

            dry_run = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--manifest-json",
                    str(manifest_path),
                    "--root",
                    str(root),
                    "--dry-run",
                    "--backup-manifest",
                    str(tmp_path / "dry-backup.json"),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            dry_payload = json.loads(dry_run.stdout)
            self.assertEqual(dry_payload["deleted_file_count"], 2)
            self.assertEqual(dry_payload["backup_manifest_path"], str(tmp_path / "dry-backup.json"))
            self.assertTrue(stale_file.exists())
            self.assertTrue(ds_store.exists())
            dry_backup = json.loads((tmp_path / "dry-backup.json").read_text(encoding="utf-8"))
            self.assertEqual(dry_backup["deleted_file_count"], 2)

            applied = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--manifest-json",
                    str(manifest_path),
                    "--root",
                    str(root),
                    "--backup-manifest",
                    str(tmp_path / "apply-backup.json"),
                    "--recovery-root",
                    str(tmp_path / "recovery"),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            applied_payload = json.loads(applied.stdout)

            self.assertEqual(applied_payload["actual_files_after"], 1)
            self.assertEqual(applied_payload["backup_manifest_path"], str(tmp_path / "apply-backup.json"))
            self.assertTrue(tracked_file.exists())
            self.assertFalse(stale_file.exists())
            self.assertFalse(ds_store.exists())
            self.assertFalse(stale_file.parent.exists())
            recovery_entries = json.loads((tmp_path / "apply-backup.json").read_text(encoding="utf-8"))["deleted_files"]
            recovered_stale = next(item for item in recovery_entries if item["relative_path"].endswith("Old.pdf"))
            self.assertEqual(Path(recovered_stale["recovery_path"]).read_text(encoding="utf-8"), "stale")
            self.assertEqual(len(recovered_stale["sha256"]), 64)

    def test_prune_can_use_preview_effective_tracked_paths(self) -> None:
        script = PROJECT_DIR / "src" / "python" / "prune_course_files.py"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            root = tmp_path / "course_files"
            old_named_file = root / "Course" / "resources" / "slides.pdf"
            old_named_file.parent.mkdir(parents=True)
            old_named_file.write_text("tracked by previous download log", encoding="utf-8")
            initialize_root(root)

            manifest_path = tmp_path / "manifest.json"
            manifest_path.write_text(
                json.dumps(
                    [
                        {
                            "relative_path": "Course/resources/slides final.pdf",
                        }
                    ]
                ),
                encoding="utf-8",
            )
            preview_path = tmp_path / "preview.json"
            preview_path.write_text(
                json.dumps({"tracked_relative_paths": ["Course/resources/slides.pdf"]}),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--manifest-json",
                    str(manifest_path),
                    "--root",
                    str(root),
                    "--dry-run",
                    "--tracked-relative-paths-json",
                    str(preview_path),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            payload = json.loads(result.stdout)
            self.assertEqual(payload["deleted_file_count"], 0)
            self.assertTrue(old_named_file.exists())

            self.assertFalse((tmp_path / "recovery").exists())

    def test_prune_rejects_unmarked_nonempty_and_protected_roots(self) -> None:
        script = PROJECT_DIR / "src" / "python" / "prune_course_files.py"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            root = tmp_path / "unowned"
            root.mkdir()
            sentinel = root / "sentinel.txt"
            sentinel.write_text("keep", encoding="utf-8")
            manifest_path = tmp_path / "manifest.json"
            manifest_path.write_text("[]", encoding="utf-8")

            unmarked = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--manifest-json",
                    str(manifest_path),
                    "--root",
                    str(root),
                    "--recovery-root",
                    str(tmp_path / "recovery"),
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(unmarked.returncode, 0)
            self.assertIn("managed root marker is missing", unmarked.stderr)
            self.assertTrue(sentinel.exists())

            protected = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--manifest-json",
                    str(manifest_path),
                    "--root",
                    str(Path.home()),
                    "--dry-run",
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(protected.returncode, 0)
            self.assertIn("refusing protected managed root", protected.stderr)

    def test_prune_rejects_manifest_traversal_and_symlink_entries(self) -> None:
        script = PROJECT_DIR / "src" / "python" / "prune_course_files.py"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            root = tmp_path / "course_files"
            root.mkdir()
            initialize_root(root)
            outside = tmp_path / "outside.txt"
            outside.write_text("outside", encoding="utf-8")
            (root / "escape.pdf").symlink_to(outside)
            manifest_path = tmp_path / "manifest.json"
            manifest_path.write_text(
                json.dumps([{"relative_path": "../outside.txt"}]),
                encoding="utf-8",
            )

            traversal = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--manifest-json",
                    str(manifest_path),
                    "--root",
                    str(root),
                    "--dry-run",
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(traversal.returncode, 0)
            self.assertIn("escapes its root", traversal.stderr)
            self.assertEqual(outside.read_text(encoding="utf-8"), "outside")

            manifest_path.write_text("[]", encoding="utf-8")
            symlink = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--manifest-json",
                    str(manifest_path),
                    "--root",
                    str(root),
                    "--dry-run",
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(symlink.returncode, 0)
            self.assertIn("containing a symlink", symlink.stderr)
            self.assertEqual(outside.read_text(encoding="utf-8"), "outside")


if __name__ == "__main__":
    unittest.main()
