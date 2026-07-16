#!/usr/bin/env python3

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from typing import Any


SHA40 = re.compile(r"[0-9a-f]{40}")
GATE_SUMMARY = re.compile(
    r"gate-evidence-summary status=pass gate=([a-z0-9-]+) "
    r"candidate=([0-9a-f]{40}) exit=0"
)
GATE_HEADER = re.compile(
    r"gate-evidence schema=1 gate=([a-z0-9-]+) "
    r"candidate=([0-9a-f]{40}) started_at=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"
)


def fail(reason: str) -> None:
    raise SystemExit(f"release-evidence-summary status=fail reason={reason}")


def run_git(repo: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        fail(f"git-{'-'.join(arguments[:1])}-unavailable")
    return result.stdout.strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_private_regular_file(path: Path, reason: str, maximum_bytes: int) -> int:
    try:
        metadata = path.lstat()
    except OSError:
        fail(f"missing-{reason}")
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_mode & 0o077
        or metadata.st_size <= 0
        or metadata.st_size > maximum_bytes
    ):
        fail(f"invalid-{reason}")
    return metadata.st_size


def load_inventory(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        fail("invalid-quality-gate-inventory")
    if not isinstance(value, dict) or value.get("schemaVersion") != 1:
        fail("unsupported-quality-gate-inventory")
    return value


def parse_external_evidence(
    values: list[str],
    required_ids: list[str],
) -> list[dict[str, str]]:
    statuses: dict[str, str] = {}
    for value in values:
        evidence_id, separator, status = value.partition("=")
        if not separator or evidence_id not in required_ids or status not in {"pass", "missing"}:
            fail("invalid-external-evidence")
        if evidence_id in statuses:
            fail("duplicate-external-evidence")
        statuses[evidence_id] = status
    return [
        {"id": evidence_id, "status": statuses.get(evidence_id, "missing")}
        for evidence_id in required_ids
    ]


def valid_gate_id(value: str) -> bool:
    return (
        bool(value)
        and not value.startswith("-")
        and not value.endswith("-")
        and "--" not in value
    )


def verify_gate_logs(evidence_dir: Path, gate_ids: list[str], candidate: str) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for gate_id in gate_ids:
        path = evidence_dir / f"{gate_id}.log"
        size = require_private_regular_file(
            path,
            f"gate-evidence-{gate_id}",
            100 * 1024 * 1024,
        )
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError):
            fail(f"invalid-gate-evidence-{gate_id}")
        headers = [match for line in lines if (match := GATE_HEADER.fullmatch(line))]
        summary_lines = [line for line in lines if line.startswith("gate-evidence-summary ")]
        if len(headers) != 1 or len(summary_lines) != 1:
            fail(f"invalid-gate-summary-{gate_id}")
        summary = GATE_SUMMARY.fullmatch(summary_lines[0])
        header = headers[0]
        if (
            summary is None
            or not valid_gate_id(header.group(1))
            or not valid_gate_id(summary.group(1))
            or header.group(1) != gate_id
            or header.group(2) != candidate
            or summary.group(1) != gate_id
            or summary.group(2) != candidate
        ):
            fail(f"gate-candidate-mismatch-{gate_id}")
        results.append(
            {
                "id": gate_id,
                "status": "pass",
                "logBytes": size,
                "logSHA256": sha256(path),
            }
        )
    return results


def verify_review_evidence(
    evidence_dir: Path,
    review_ids: list[str],
    candidate: str,
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for review_id in review_ids:
        record_path = evidence_dir / f"{review_id}.review.json"
        require_private_regular_file(
            record_path,
            f"review-evidence-{review_id}",
            2 * 1024 * 1024,
        )
        try:
            record = json.loads(record_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError):
            fail(f"invalid-review-evidence-{review_id}")
        if not isinstance(record, dict):
            fail(f"invalid-review-evidence-{review_id}")
        findings = record.get("openFindings")
        report_name = record.get("reportFileName")
        if (
            record.get("schemaVersion") != 1
            or record.get("id") != review_id
            or record.get("candidate") != candidate
            or record.get("status") != "pass"
            or findings != {"p0": 0, "p1": 0, "p2": 0}
            or not isinstance(report_name, str)
            or report_name != f"{review_id}.report.txt"
            or not isinstance(record.get("reviewedAt"), str)
            or not SHA40.fullmatch(candidate)
        ):
            fail(f"review-candidate-or-status-mismatch-{review_id}")
        report_path = evidence_dir / report_name
        report_size = require_private_regular_file(
            report_path,
            f"review-report-{review_id}",
            2 * 1024 * 1024,
        )
        report_digest = sha256(report_path)
        if record.get("reportBytes") != report_size or record.get("reportSHA256") != report_digest:
            fail(f"review-report-digest-mismatch-{review_id}")
        results.append(
            {
                "id": review_id,
                "status": "pass",
                "openFindings": findings,
                "reportBytes": report_size,
                "reportSHA256": report_digest,
                "recordSHA256": sha256(record_path),
            }
        )
    return results


def verify_app(repo: Path, app: Path, candidate: str) -> dict[str, Any]:
    if sys.platform != "darwin":
        fail("release-receipt-requires-macos")
    payload = app / "Contents" / "Resources" / "EnginePayload"
    manifest_path = payload / "EnginePayloadManifest.json"
    executable = app / "Contents" / "MacOS" / "KLMSMac"
    if app.is_symlink() or not app.is_dir() or not manifest_path.is_file() or not executable.is_file():
        fail("invalid-app-bundle")
    verifier = repo / "tools" / "verify_klms_engine_payload.py"
    result = subprocess.run(
        [
            sys.executable,
            str(verifier),
            str(payload),
            "--allowlist",
            str(repo / "apps" / "KLMSync" / "EnginePayloadAllowlist.txt"),
            "--python-allowlist",
            str(repo / "apps" / "KLMSync" / "EnginePythonPayloadAllowlist.txt"),
            "--expected-revision",
            candidate,
            "--require-clean",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        fail("app-payload-verification-failed")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        fail("invalid-app-payload-manifest")
    if (
        manifest.get("schemaVersion") != 2
        or manifest.get("sourceRevision") != candidate
        or manifest.get("payloadVersion") != candidate
        or manifest.get("dirty") is not False
    ):
        fail("app-payload-provenance-mismatch")
    signature = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
        check=False,
        capture_output=True,
        text=True,
    )
    if signature.returncode != 0:
        fail("app-code-signature-invalid")
    return {
        "bundleName": app.name,
        "payloadManifestSHA256": sha256(manifest_path),
        "executableSHA256": sha256(executable),
        "sourceRevision": candidate,
        "dirty": False,
        "codeSignatureVerified": True,
    }


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate an exact-SHA KLMS release evidence receipt.")
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--review-evidence-dir", required=True, type=Path)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--external-evidence", action="append", default=[])
    arguments = parser.parse_args()

    repo = Path(__file__).resolve().parents[1]
    output = Path(os.path.abspath(arguments.output.expanduser()))
    evidence_dir = Path(os.path.abspath(arguments.evidence_dir.expanduser()))
    review_evidence_dir = Path(os.path.abspath(arguments.review_evidence_dir.expanduser()))
    app = Path(os.path.abspath(arguments.app.expanduser()))
    resolved_output = output.resolve(strict=False)
    resolved_evidence_dir = evidence_dir.resolve(strict=False)
    resolved_review_evidence_dir = review_evidence_dir.resolve(strict=False)
    if resolved_output == repo or repo in resolved_output.parents:
        fail("receipt-output-must-be-outside-repository")
    if resolved_evidence_dir == repo or repo in resolved_evidence_dir.parents:
        fail("evidence-directory-must-be-outside-repository")
    if resolved_review_evidence_dir == repo or repo in resolved_review_evidence_dir.parents:
        fail("review-evidence-directory-must-be-outside-repository")
    if output.is_symlink():
        fail("receipt-output-must-not-be-symlink")
    for directory, reason in (
        (evidence_dir, "evidence-directory"),
        (review_evidence_dir, "review-evidence-directory"),
    ):
        try:
            metadata = directory.lstat()
        except OSError:
            fail(f"missing-{reason}")
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or stat.S_ISLNK(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_mode & 0o077
        ):
            fail(f"invalid-{reason}")

    candidate = run_git(repo, "rev-parse", "--verify", "HEAD^{commit}")
    if not SHA40.fullmatch(candidate):
        fail("invalid-candidate")
    if run_git(repo, "status", "--porcelain", "--untracked-files=all"):
        fail("dirty-worktree")

    inventory = load_inventory(repo / "docs" / "quality-gate-inventory.json")
    automated_gates = inventory.get("automatedGates")
    if (
        not isinstance(automated_gates, list)
        or not automated_gates
        or not all(
            isinstance(entry, dict)
            and isinstance(entry.get("id"), str)
            and re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", entry["id"])
            and isinstance(entry.get("command"), str)
            and entry["command"]
            for entry in automated_gates
        )
    ):
        fail("invalid-automated-gate-inventory")
    gate_ids = [entry["id"] for entry in automated_gates]
    if len(gate_ids) != len(set(gate_ids)):
        fail("invalid-automated-gate-inventory")
    external_ids = inventory.get("mandatoryExternalEvidence", [])
    if (
        not isinstance(external_ids, list)
        or len(external_ids) != len(set(external_ids))
        or not all(
            isinstance(value, str)
            and re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", value)
            for value in external_ids
        )
    ):
        fail("invalid-external-evidence-inventory")
    review_ids = inventory.get("independentReviewGates", [])
    if (
        not isinstance(review_ids, list)
        or not review_ids
        or len(review_ids) != len(set(review_ids))
        or not all(
            isinstance(value, str)
            and re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", value)
            for value in review_ids
        )
    ):
        fail("invalid-independent-review-inventory")

    gates = verify_gate_logs(evidence_dir, gate_ids, candidate)
    reviews = verify_review_evidence(review_evidence_dir, review_ids, candidate)
    app_evidence = verify_app(repo, app, candidate)
    external = parse_external_evidence(arguments.external_evidence, external_ids)
    external_complete = all(entry["status"] == "pass" for entry in external)
    receipt = {
        "schemaVersion": 1,
        "candidate": candidate,
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "repositoryClean": True,
        "automatedGatesComplete": True,
        "independentReviewsComplete": True,
        "qualityGateInventorySHA256": sha256(repo / "docs" / "quality-gate-inventory.json"),
        "app": app_evidence,
        "gates": gates,
        "reviews": reviews,
        "externalEvidence": external,
        "externalEvidenceComplete": external_complete,
        "maximumDefensibleScore": 100 if external_complete else 94,
    }
    atomic_write_json(output, receipt)
    print(
        "release-evidence-summary"
        f" status=pass candidate={candidate} gates={len(gates)} reviews={len(reviews)}"
        f" external_complete={str(external_complete).lower()} receipt={output}"
    )


if __name__ == "__main__":
    main()
