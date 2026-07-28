from __future__ import annotations

import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Union


PROJECT_DIR = Path(__file__).resolve().parents[1]
VERIFIER = PROJECT_DIR / "tools" / "security" / "verify_security_reports.mjs"
SECURITY_RUNNER = PROJECT_DIR / "tools" / "security" / "run_security_evidence.sh"
EMPTY_COORDINATE_DIGEST = hashlib.sha256(b"").hexdigest()
JSONPayload = Union[
    dict[str, "JSONPayload"],
    list["JSONPayload"],
    str,
    int,
    float,
    bool,
    None,
]


class SecurityReportVerifierTests(unittest.TestCase):
    def test_runner_enumerates_expensive_semgrep_targets(self) -> None:
        source = SECURITY_RUNNER.read_text(encoding="utf-8")

        self.assertIn('relative_filename="${filename#"$scan_tree/"}"', source)
        self.assertIn('expensive_semgrep_targets+=("$relative_filename")', source)
        self.assertIn('all_javascript_semgrep_targets+=("$relative_filename")', source)
        self.assertIn('"${expensive_semgrep_targets[@]}"', source)
        self.assertIn('"${all_javascript_semgrep_targets[@]}"', source)
        self.assertNotIn('--exclude "src/js/download_klms_files.js"', source)
        self.assertNotIn('--exclude "deploy/relay/test_relay.mjs"', source)

    def test_accepts_complete_semgrep_scan_without_timeouts(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            evidence_dir, policy_path = self._write_valid_fixture(Path(raw_root))

            result = self._run_verifier(evidence_dir, policy_path)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("security-report-verification ok", result.stdout)

    def test_apple_common_scope_does_not_require_windows_audit(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            evidence_dir, policy_path = self._write_valid_fixture(Path(raw_root))
            (evidence_dir / "npm-audit-windows.json").unlink()

            result = self._run_verifier(
                evidence_dir,
                policy_path,
                scope="apple-common",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("scope=apple-common", result.stdout)

    def test_rejects_unknown_security_scope(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            evidence_dir, policy_path = self._write_valid_fixture(Path(raw_root))

            result = self._run_verifier(evidence_dir, policy_path, scope="partial")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsupported security scope", result.stderr)

    def test_rejects_semgrep_top_level_errors(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            evidence_dir, policy_path = self._write_valid_fixture(Path(raw_root))
            self._write_json(
                evidence_dir / "semgrep.json",
                {
                    "errors": [{"message": "synthetic scanner error"}],
                    "results": [],
                    "time": {"fixpoint_timeouts": []},
                },
            )

            result = self._run_verifier(evidence_dir, policy_path)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Semgrep scan errors", result.stderr)

    def test_rejects_semgrep_fixpoint_timeouts(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            evidence_dir, policy_path = self._write_valid_fixture(Path(raw_root))
            self._write_json(
                evidence_dir / "semgrep.json",
                {
                    "errors": [],
                    "results": [],
                    "time": {
                        "fixpoint_timeouts": [
                            {
                                "path": "src/js/download_klms_files.js",
                                "rule_ids": ["javascript.lang.security.audit.detect-non-literal-require"],
                            }
                        ]
                    },
                },
            )

            result = self._run_verifier(evidence_dir, policy_path)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Semgrep fixpoint timeouts", result.stderr)

    def test_rejects_supplemental_semgrep_fixpoint_timeouts(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            evidence_dir, policy_path = self._write_valid_fixture(Path(raw_root))
            self._write_json(
                evidence_dir / "semgrep-expensive-production.json",
                {
                    "errors": [],
                    "results": [],
                    "time": {
                        "fixpoint_timeouts": [
                            {
                                "path": "tools/example.mjs",
                                "rule_ids": ["example"],
                            }
                        ]
                    },
                },
            )

            result = self._run_verifier(evidence_dir, policy_path)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "semgrep-expensive-production.json fixpoint timeouts",
                result.stderr,
            )

    def _write_valid_fixture(self, root: Path) -> tuple[Path, Path]:
        evidence_dir = root / "evidence"
        evidence_dir.mkdir()
        policy_path = root / "policy.json"
        scanner_policy = {
            "expectedFindings": 0,
            "coordinatesSha256": EMPTY_COORDINATE_DIGEST,
            "adjudications": [],
        }
        self._write_json(
            policy_path,
            {
                "semgrep": scanner_policy,
                "detectSecrets": scanner_policy,
            },
        )
        reports = {
            "semgrep.json": {
                "errors": [],
                "results": [],
                "time": {"fixpoint_timeouts": []},
            },
            "detect-secrets.json": {"results": {}},
            "bandit.json": {"results": []},
            "gitleaks.json": [],
            "trivy.json": {"Results": []},
            "grype.json": {"matches": []},
            "osv.json": {"results": []},
            "pip-audit.json": {"dependencies": []},
            "scanner-pip-audit.json": {"dependencies": []},
            "npm-audit-cloudflare.json": {"metadata": {"vulnerabilities": {"total": 0}}},
            "npm-audit-windows.json": {"metadata": {"vulnerabilities": {"total": 0}}},
            "sbom.cdx.json": {
                "bomFormat": "CycloneDX",
                "components": [{"name": "fixture", "version": "1"}],
            },
        }
        for filename in (
            "semgrep-insecure-object-assign.json",
            "semgrep-expensive-production.json",
            "semgrep-download-jxa.json",
            "semgrep-relay-test.json",
            "semgrep-download-jxa-boundary.json",
        ):
            reports[filename] = {
                "errors": [],
                "results": [],
                "time": {"fixpoint_timeouts": []},
            }
        for filename, payload in reports.items():
            self._write_json(evidence_dir / filename, payload)
        return evidence_dir, policy_path

    def _run_verifier(
        self,
        evidence_dir: Path,
        policy_path: Path,
        *,
        scope: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = ["node", str(VERIFIER), str(evidence_dir), str(policy_path)]
        if scope is not None:
            command.append(scope)
        return subprocess.run(
            command,
            cwd=PROJECT_DIR,
            text=True,
            capture_output=True,
            check=False,
        )

    def _write_json(self, path: Path, payload: JSONPayload) -> None:
        path.write_text(
            json.dumps(payload, ensure_ascii=False),
            encoding="utf-8",
        )


if __name__ == "__main__":
    unittest.main()
