from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


PROJECT_DIR = Path(__file__).resolve().parents[1]
VERIFIER = PROJECT_DIR / "tools" / "verify_klms_engine_payload.py"
REVISION = "a" * 40


class EnginePayloadVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.payload = self.root / "payload"
        self.allowlist = self.root / "allowlist.txt"
        self.python_allowlist = self.root / "python-allowlist.txt"
        self.allowlist.write_text("run_all_full.sh\n", encoding="utf-8")
        self.python_allowlist.write_text(
            "bs4/__init__.py\n"
            "soupsieve/__init__.py\n"
            "typing_extensions.py\n",
            encoding="utf-8",
        )
        self.write_file("run_all_full.sh", b"#!/bin/zsh\n")
        self.write_file("python-packages/bs4/__init__.py", b"# bs4\n")
        self.write_file("python-packages/soupsieve/__init__.py", b"# soupsieve\n")
        self.write_file("python-packages/typing_extensions.py", b"# typing\n")
        self.write_file("EnginePayloadVersion.txt", f"{REVISION}\n".encode())
        self.write_manifest()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_exact_inventory_passes(self) -> None:
        result = self.run_verifier()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"candidate={REVISION}", result.stdout)

    def test_unlisted_python_file_is_rejected(self) -> None:
        self.write_file("python-packages/attacker.py", b"raise SystemExit\n")
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected-file-python-packages/attacker.py", result.stderr)

    def test_tampered_file_digest_is_rejected(self) -> None:
        self.write_file("python-packages/bs4/__init__.py", b"tampered\n")
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("inventory-digest-mismatch", result.stderr)

    def test_non_sha_source_revision_is_rejected(self) -> None:
        self.write_manifest(source_revision="local-build")
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing-source-revision", result.stderr)

    def test_python_allowlist_digest_is_bound_to_manifest(self) -> None:
        self.python_allowlist.write_text(
            self.python_allowlist.read_text(encoding="utf-8") + "extra.py\n",
            encoding="utf-8",
        )
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("python-allowlist-digest-mismatch", result.stderr)

    def write_file(self, relative_path: str, data: bytes) -> None:
        path = self.payload / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def write_manifest(self, source_revision: str = REVISION) -> None:
        manifest_path = self.payload / "EnginePayloadManifest.json"
        files = []
        for path in sorted(self.payload.rglob("*")):
            if path == manifest_path or not path.is_file():
                continue
            data = path.read_bytes()
            files.append(
                {
                    "path": path.relative_to(self.payload).as_posix(),
                    "bytes": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                }
            )
        manifest_path.write_text(
            json.dumps(
                {
                    "schemaVersion": 2,
                    "payloadVersion": REVISION,
                    "sourceRevision": source_revision,
                    "dirty": False,
                    "allowlistSHA256": hashlib.sha256(self.allowlist.read_bytes()).hexdigest(),
                    "pythonAllowlistSHA256": hashlib.sha256(
                        self.python_allowlist.read_bytes()
                    ).hexdigest(),
                    "fileCount": len(files),
                    "totalBytes": sum(item["bytes"] for item in files),
                    "files": files,
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

    def run_verifier(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(VERIFIER),
                str(self.payload),
                "--allowlist",
                str(self.allowlist),
                "--python-allowlist",
                str(self.python_allowlist),
                "--expected-revision",
                REVISION,
            ],
            check=False,
            capture_output=True,
            text=True,
        )


if __name__ == "__main__":
    unittest.main()
