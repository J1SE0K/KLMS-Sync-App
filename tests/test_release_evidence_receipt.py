from __future__ import annotations

import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PROJECT_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = PROJECT_DIR / "tools" / "generate_release_evidence_receipt.py"
SPEC = importlib.util.spec_from_file_location("release_evidence_receipt", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
receipt_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(receipt_module)


class ReleaseEvidenceReceiptTests(unittest.TestCase):
    def test_gate_logs_are_bound_to_exact_candidate(self) -> None:
        candidate = "a" * 40
        with tempfile.TemporaryDirectory() as tmp:
            evidence = Path(tmp)
            log = evidence / "python-core.log"
            log.write_text(
                f"gate-evidence schema=1 gate=python-core candidate={candidate} "
                "started_at=2026-07-16T00:00:00Z\n"
                f"gate-evidence-summary status=pass gate=python-core candidate={candidate} exit=0\n",
                encoding="utf-8",
            )
            log.chmod(0o600)

            gates = receipt_module.verify_gate_logs(evidence, ["python-core"], candidate)
            self.assertEqual(gates[0]["id"], "python-core")
            self.assertEqual(gates[0]["status"], "pass")
            self.assertRegex(gates[0]["logSHA256"], r"^[0-9a-f]{64}$")

            with self.assertRaises(SystemExit):
                receipt_module.verify_gate_logs(evidence, ["python-core"], "b" * 40)

    def test_gate_logs_must_be_private_and_have_one_authoritative_summary(self) -> None:
        candidate = "a" * 40
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "python-core.log"
            log.write_text(
                f"gate-evidence schema=1 gate=python-core candidate={candidate} "
                "started_at=2026-07-16T00:00:00Z\n"
                f"gate-evidence-summary status=pass gate=python-core candidate={candidate} exit=0\n",
                encoding="utf-8",
            )
            log.chmod(0o644)
            with self.assertRaises(SystemExit):
                receipt_module.verify_gate_logs(Path(tmp), ["python-core"], candidate)

            log.chmod(0o600)
            with log.open("a", encoding="utf-8") as handle:
                handle.write(
                    f"gate-evidence-summary status=fail gate=python-core candidate={candidate} exit=1\n"
                )
            with self.assertRaises(SystemExit):
                receipt_module.verify_gate_logs(Path(tmp), ["python-core"], candidate)

    def test_gate_logs_reject_noncanonical_gate_ids_without_nested_regex(self) -> None:
        candidate = "a" * 40
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "python--core.log"
            log.write_text(
                f"gate-evidence schema=1 gate=python--core candidate={candidate} "
                "started_at=2026-07-16T00:00:00Z\n"
                f"gate-evidence-summary status=pass gate=python--core candidate={candidate} exit=0\n",
                encoding="utf-8",
            )
            log.chmod(0o600)
            with self.assertRaises(SystemExit):
                receipt_module.verify_gate_logs(Path(tmp), ["python--core"], candidate)

    def test_review_evidence_binds_report_and_candidate(self) -> None:
        candidate = "a" * 40
        review_id = "code-quality"
        with tempfile.TemporaryDirectory() as tmp:
            evidence = Path(tmp)
            report = evidence / f"{review_id}.report.txt"
            report.write_text("No P0, P1, or P2 findings.\n", encoding="utf-8")
            report.chmod(0o600)
            report_data = report.read_bytes()
            record = evidence / f"{review_id}.review.json"
            record.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "id": review_id,
                        "candidate": candidate,
                        "status": "pass",
                        "openFindings": {"p0": 0, "p1": 0, "p2": 0},
                        "reviewedAt": "2026-07-16T00:00:00Z",
                        "reportFileName": report.name,
                        "reportBytes": len(report_data),
                        "reportSHA256": hashlib.sha256(report_data).hexdigest(),
                    },
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            record.chmod(0o600)

            reviews = receipt_module.verify_review_evidence(evidence, [review_id], candidate)
            self.assertEqual(reviews[0]["status"], "pass")
            self.assertEqual(reviews[0]["openFindings"], {"p0": 0, "p1": 0, "p2": 0})

            report.write_text("tampered\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                receipt_module.verify_review_evidence(evidence, [review_id], candidate)

    def test_external_evidence_defaults_to_missing_without_overclaiming(self) -> None:
        required = ["physical-devices", "impaired-wan"]
        evidence = receipt_module.parse_external_evidence(
            ["physical-devices=pass"],
            required,
        )
        self.assertEqual(
            evidence,
            [
                {"id": "physical-devices", "status": "pass"},
                {"id": "impaired-wan", "status": "missing"},
            ],
        )

    def test_receipt_write_is_atomic_and_private(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "receipt.json"
            receipt_module.atomic_write_json(output, {"schemaVersion": 1, "candidate": "a" * 40})
            self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["schemaVersion"], 1)
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)

    def test_review_recorder_writes_private_exact_sha_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            tools = repo / "tools"
            docs = repo / "docs"
            tools.mkdir(parents=True)
            docs.mkdir()
            shutil.copy2(PROJECT_DIR / "tools" / "record_release_review.py", tools)
            (docs / "quality-gate-inventory.json").write_text(
                json.dumps({"independentReviewGates": ["code-quality"]}),
                encoding="utf-8",
            )
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "KLMS Test"], check=True)
            subprocess.run(
                ["git", "-C", str(repo), "config", "user.email", "klms-test@example.invalid"],
                check=True,
            )
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "fixture"], check=True)
            candidate = subprocess.run(
                ["git", "-C", str(repo), "rev-parse", "HEAD"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            report = root / "review.txt"
            report.write_text("No release-blocking findings.\n", encoding="utf-8")
            report.chmod(0o600)
            evidence = root / "evidence"

            result = subprocess.run(
                [
                    "python3",
                    str(tools / "record_release_review.py"),
                    "--lane",
                    "code-quality",
                    "--report",
                    str(report),
                    "--evidence-dir",
                    str(evidence),
                    "--status",
                    "pass",
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            record_path = evidence / "code-quality.review.json"
            recorded = json.loads(record_path.read_text(encoding="utf-8"))
            self.assertEqual(recorded["candidate"], candidate)
            self.assertEqual(recorded["openFindings"], {"p0": 0, "p1": 0, "p2": 0})
            self.assertEqual(record_path.stat().st_mode & 0o777, 0o600)
            self.assertEqual((evidence / "code-quality.report.txt").stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
