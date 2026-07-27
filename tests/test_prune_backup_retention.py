import os
import tempfile
import unittest
from pathlib import Path

from src.python.prune_backup_retention import (
    PruneBackupRetentionError,
    apply_retention,
)


class PruneBackupRetentionTests(unittest.TestCase):
    def create_batch(self, root: Path, key: str, contents: bytes, modified_ns: int) -> None:
        recovery = root / f"{key}_course_files"
        recovery.mkdir(parents=True)
        (recovery / "recovered.pdf").write_bytes(contents)
        manifest = root / f"{key}_course_files.json"
        manifest.write_text("{}", encoding="utf-8")
        os.utime(recovery, ns=(modified_ns, modified_ns))
        os.utime(manifest, ns=(modified_ns, modified_ns))

    def test_retention_prunes_directories_and_manifests_by_count_and_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "backups"
            root.mkdir()
            self.create_batch(root, "20260720-010101", b"aaaa", 1_000_000_000)
            self.create_batch(root, "20260721-010101", b"bbbb", 2_000_000_000)
            self.create_batch(root, "20260722-010101", b"cccc", 3_000_000_000)

            payload = apply_retention(
                root,
                enabled=True,
                keep_batches=2,
                maximum_bytes=12,
            )

            self.assertEqual(
                payload["kept_batches"],
                ["20260722-010101", "20260721-010101"],
            )
            self.assertEqual(payload["managed_bytes_after"], 12)
            self.assertFalse((root / "20260720-010101_course_files").exists())
            self.assertFalse((root / "20260720-010101_course_files.json").exists())

            reserved = apply_retention(
                root,
                enabled=True,
                keep_batches=2,
                maximum_bytes=12,
                reserve_bytes=6,
            )
            self.assertEqual(reserved["kept_batches"], ["20260722-010101"])
            self.assertFalse((root / "20260721-010101_course_files").exists())
            self.assertFalse((root / "20260721-010101_course_files.json").exists())

    def test_disabled_retention_removes_generated_backups_but_not_unknown_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "backups"
            root.mkdir()
            self.create_batch(root, "20260722-010101-123", b"recovery", 3_000_000_000)
            sentinel = root / "keep-me.txt"
            sentinel.write_text("user", encoding="utf-8")

            payload = apply_retention(
                root,
                enabled=False,
                keep_batches=0,
                maximum_bytes=1024,
            )

            self.assertEqual(payload["kept_batches"], [])
            self.assertEqual(payload["managed_bytes_after"], 0)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "user")

    def test_dry_run_and_symlink_validation_never_delete_recovery_data(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "backups"
            root.mkdir()
            self.create_batch(root, "20260722-010101", b"recovery", 3_000_000_000)

            preview = apply_retention(
                root,
                enabled=False,
                keep_batches=0,
                maximum_bytes=1024,
                dry_run=True,
            )
            self.assertEqual(preview["removed_batches"], ["20260722-010101"])
            self.assertTrue((root / "20260722-010101_course_files").exists())

            outside = Path(tmp) / "outside"
            outside.write_text("outside", encoding="utf-8")
            (root / "20260722-010101_course_files" / "linked").symlink_to(outside)
            with self.assertRaises(PruneBackupRetentionError):
                apply_retention(
                    root,
                    enabled=True,
                    keep_batches=1,
                    maximum_bytes=1024,
                )
            self.assertEqual(outside.read_text(encoding="utf-8"), "outside")


if __name__ == "__main__":
    unittest.main()
