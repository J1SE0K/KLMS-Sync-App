import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
ROOT_HELPER = PROJECT_DIR / "src" / "python" / "managed_course_file_roots.py"
PRUNE_SCRIPT = PROJECT_DIR / "src" / "python" / "prune_course_files.py"


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


class PruneRecoveryLimitTests(unittest.TestCase):
    def test_prune_refuses_oversized_recovery_before_deleting_any_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            root = tmp_path / "course_files"
            root.mkdir()
            initialize_root(root)
            first = root / "first.pdf"
            second = root / "second.pdf"
            first.write_bytes(b"1234")
            second.write_bytes(b"5678")
            manifest_path = tmp_path / "manifest.json"
            manifest_path.write_text("[]", encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(PRUNE_SCRIPT),
                    "--manifest-json",
                    str(manifest_path),
                    "--root",
                    str(root),
                    "--recovery-root",
                    str(tmp_path / "recovery"),
                    "--maximum-recovery-bytes",
                    "7",
                ],
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("recovery data exceeds", result.stderr)
            self.assertEqual(first.read_bytes(), b"1234")
            self.assertEqual(second.read_bytes(), b"5678")
