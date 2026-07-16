from __future__ import annotations

import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = PROJECT_DIR / "tools" / "generate_release_evidence_receipt.py"
SPEC = importlib.util.spec_from_file_location("release_evidence_receipt", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
receipt_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(receipt_module)

GATE_RUNNER_MODULE_PATH = PROJECT_DIR / "tools" / "run_release_gate.py"
GATE_RUNNER_SPEC = importlib.util.spec_from_file_location(
    "run_release_gate",
    GATE_RUNNER_MODULE_PATH,
)
assert GATE_RUNNER_SPEC is not None and GATE_RUNNER_SPEC.loader is not None
gate_runner_module = importlib.util.module_from_spec(GATE_RUNNER_SPEC)
GATE_RUNNER_SPEC.loader.exec_module(gate_runner_module)


class ReleaseEvidenceReceiptTests(unittest.TestCase):
    @staticmethod
    def gate_entry(gate_id: str = "python-core") -> dict[str, object]:
        return {
            "id": gate_id,
            "execution": {
                "workingDirectory": ".",
                "environment": {"PYTHONPATH": "vendor/python-packages"},
                "steps": [
                    {"argv": ["python3", "-B", "-m", "unittest", "discover", "-s", "tests"]}
                ],
            },
        }

    def test_gate_logs_are_bound_to_exact_candidate(self) -> None:
        candidate = "a" * 40
        entry = self.gate_entry()
        invocation_digest = receipt_module.gate_execution_digest(entry)
        inventory_digest = "b" * 64
        with tempfile.TemporaryDirectory() as tmp:
            evidence = Path(tmp)
            log = evidence / "python-core.log"
            log.write_text(
                f"gate-evidence schema=2 gate=python-core candidate={candidate} "
                f"invocation_sha256={invocation_digest} inventory_sha256={inventory_digest} "
                "started_at=2026-07-16T00:00:00Z\n"
                f"gate-evidence-summary status=pass gate=python-core candidate={candidate} "
                f"invocation_sha256={invocation_digest} inventory_sha256={inventory_digest} exit=0\n",
                encoding="utf-8",
            )
            log.chmod(0o600)

            gates = receipt_module.verify_gate_logs(
                evidence,
                [entry],
                candidate,
                inventory_digest,
            )
            self.assertEqual(gates[0]["id"], "python-core")
            self.assertEqual(gates[0]["status"], "pass")
            self.assertEqual(gates[0]["invocationSHA256"], invocation_digest)
            self.assertRegex(gates[0]["logSHA256"], r"^[0-9a-f]{64}$")

            with self.assertRaises(SystemExit):
                receipt_module.verify_gate_logs(
                    evidence,
                    [entry],
                    "c" * 40,
                    inventory_digest,
                )

            altered_entry = self.gate_entry()
            altered_entry["execution"]["steps"] = [{"argv": ["/usr/bin/true"]}]
            with self.assertRaises(SystemExit):
                receipt_module.verify_gate_logs(
                    evidence,
                    [altered_entry],
                    candidate,
                    inventory_digest,
                )

    def test_gate_logs_must_be_private_and_have_one_authoritative_summary(self) -> None:
        candidate = "a" * 40
        entry = self.gate_entry()
        invocation_digest = receipt_module.gate_execution_digest(entry)
        inventory_digest = "b" * 64
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "python-core.log"
            log.write_text(
                f"gate-evidence schema=2 gate=python-core candidate={candidate} "
                f"invocation_sha256={invocation_digest} inventory_sha256={inventory_digest} "
                "started_at=2026-07-16T00:00:00Z\n"
                f"gate-evidence-summary status=pass gate=python-core candidate={candidate} "
                f"invocation_sha256={invocation_digest} inventory_sha256={inventory_digest} exit=0\n",
                encoding="utf-8",
            )
            log.chmod(0o644)
            with self.assertRaises(SystemExit):
                receipt_module.verify_gate_logs(Path(tmp), [entry], candidate, inventory_digest)

            log.chmod(0o600)
            with log.open("a", encoding="utf-8") as handle:
                handle.write(
                    f"gate-evidence-summary status=fail gate=python-core candidate={candidate} "
                    f"invocation_sha256={invocation_digest} inventory_sha256={inventory_digest} exit=1\n"
                )
            with self.assertRaises(SystemExit):
                receipt_module.verify_gate_logs(Path(tmp), [entry], candidate, inventory_digest)

    def test_gate_logs_reject_noncanonical_gate_ids_without_nested_regex(self) -> None:
        candidate = "a" * 40
        entry = self.gate_entry("python--core")
        invocation_digest = receipt_module.gate_execution_digest(entry)
        inventory_digest = "b" * 64
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "python--core.log"
            log.write_text(
                f"gate-evidence schema=2 gate=python--core candidate={candidate} "
                f"invocation_sha256={invocation_digest} inventory_sha256={inventory_digest} "
                "started_at=2026-07-16T00:00:00Z\n"
                f"gate-evidence-summary status=pass gate=python--core candidate={candidate} "
                f"invocation_sha256={invocation_digest} inventory_sha256={inventory_digest} exit=0\n",
                encoding="utf-8",
            )
            log.chmod(0o600)
            with self.assertRaises(SystemExit):
                receipt_module.verify_gate_logs(Path(tmp), [entry], candidate, inventory_digest)

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
        candidate_committed_at = receipt_module.datetime.now(receipt_module.timezone.utc)
        evidence = receipt_module.verify_external_evidence(
            None,
            [],
            required,
            "a" * 40,
            candidate_committed_at,
        )
        self.assertEqual(
            evidence,
            [
                {"id": "physical-devices", "status": "missing"},
                {"id": "impaired-wan", "status": "missing"},
            ],
        )

        with self.assertRaises(SystemExit):
            receipt_module.verify_external_evidence(
                None,
                ["physical-devices=pass"],
                required,
                "a" * 40,
                candidate_committed_at,
            )

    def test_external_pass_requires_private_exact_candidate_report(self) -> None:
        candidate = "a" * 40
        evidence_id = "physical-devices"
        candidate_committed_at = (
            receipt_module.datetime.now(receipt_module.timezone.utc)
            - receipt_module.timedelta(hours=2)
        )
        observed_at = candidate_committed_at + receipt_module.timedelta(hours=1)
        with tempfile.TemporaryDirectory() as tmp:
            evidence_dir = Path(tmp)
            report = evidence_dir / f"{evidence_id}.report.txt"
            report.write_text("Physical iPhone and iPad matrix passed.\n", encoding="utf-8")
            report.chmod(0o600)
            report_data = report.read_bytes()
            record = evidence_dir / f"{evidence_id}.external.json"
            record.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "id": evidence_id,
                        "candidate": candidate,
                        "status": "pass",
                        "observedAt": observed_at.isoformat().replace("+00:00", "Z"),
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

            verified = receipt_module.verify_external_evidence(
                evidence_dir,
                [f"{evidence_id}=pass"],
                [evidence_id],
                candidate,
                candidate_committed_at,
            )
            self.assertEqual(verified[0]["status"], "pass")
            self.assertEqual(verified[0]["reportBytes"], len(report_data))
            self.assertRegex(verified[0]["recordSHA256"], r"^[0-9a-f]{64}$")

            with self.assertRaises(SystemExit):
                receipt_module.verify_external_evidence(
                    evidence_dir,
                    [f"{evidence_id}=pass"],
                    [evidence_id],
                    "b" * 40,
                    candidate_committed_at,
                )

            report.write_text("tampered\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                receipt_module.verify_external_evidence(
                    evidence_dir,
                    [f"{evidence_id}=pass"],
                    [evidence_id],
                    candidate,
                    candidate_committed_at,
                )

    def test_receipt_write_is_atomic_and_private(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "receipt.json"
            receipt_module.atomic_write_json(output, {"schemaVersion": 1, "candidate": "a" * 40})
            self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["schemaVersion"], 1)
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)

    def test_score_model_is_exact_and_external_evidence_caps_it_at_94(self) -> None:
        inventory = receipt_module.load_inventory(
            PROJECT_DIR / "docs" / "quality-gate-inventory.json"
        )

        base_score, caps = receipt_module.verified_score_model(inventory)

        self.assertEqual(base_score, 100)
        self.assertEqual(caps["missingMandatoryExternalEvidence"], 94)

        invalid = json.loads(json.dumps(inventory))
        invalid["scoreModel"]["areas"]["functionAndDataIntegrity"] = 19
        with self.assertRaises(SystemExit):
            receipt_module.verified_score_model(invalid)

    def test_receipt_write_removes_temporary_output_when_final_guard_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "receipt.json"

            def reject() -> None:
                raise SystemExit("candidate changed")

            with self.assertRaises(SystemExit):
                receipt_module.atomic_write_json(
                    output,
                    {"schemaVersion": 1},
                    before_replace=reject,
                )

            self.assertFalse(output.exists())
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_gate_runner_rejects_caller_supplied_command(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(PROJECT_DIR / "tools" / "run_release_gate.py"),
                "python-core",
                "--",
                "/usr/bin/true",
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 64)
        self.assertIn("usage:", result.stderr)

    def test_gate_runner_rejects_symlinked_evidence_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            private_target = root / "private"
            private_target.mkdir(mode=0o700)
            alias = root / "evidence"
            alias.symlink_to(private_target, target_is_directory=True)

            with self.assertRaises(SystemExit):
                gate_runner_module.private_directory(alias, repo)

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
