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
import tempfile
from typing import Any


SHA40 = re.compile(r"[0-9a-f]{40}")


def fail(reason: str) -> None:
    raise SystemExit(f"review-evidence-summary status=fail reason={reason}")


def run_git(repo: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        fail("git-metadata-unavailable")
    return result.stdout.strip()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def require_outside_repository(path: Path, repo: Path, reason: str) -> None:
    resolved = path.resolve(strict=False)
    if resolved == repo or repo in resolved.parents:
        fail(f"{reason}-must-be-outside-repository")


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def load_review_ids(repo: Path) -> set[str]:
    try:
        inventory = json.loads(
            (repo / "docs" / "quality-gate-inventory.json").read_text(encoding="utf-8")
        )
    except (OSError, UnicodeError, json.JSONDecodeError):
        fail("invalid-quality-gate-inventory")
    values = inventory.get("independentReviewGates") if isinstance(inventory, dict) else None
    if not isinstance(values, list) or not values or not all(isinstance(value, str) for value in values):
        fail("invalid-independent-review-inventory")
    return set(values)


def main() -> None:
    parser = argparse.ArgumentParser(description="Record an exact-SHA independent KLMS release review.")
    parser.add_argument("--lane", required=True)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--status", required=True, choices=("pass", "fail"))
    parser.add_argument("--open-p0", type=int, default=0)
    parser.add_argument("--open-p1", type=int, default=0)
    parser.add_argument("--open-p2", type=int, default=0)
    arguments = parser.parse_args()

    repo = Path(__file__).resolve().parents[1]
    report = Path(os.path.abspath(arguments.report.expanduser()))
    evidence_dir = Path(os.path.abspath(arguments.evidence_dir.expanduser()))
    require_outside_repository(report, repo, "review-report")
    require_outside_repository(evidence_dir, repo, "review-evidence-directory")
    if arguments.lane not in load_review_ids(repo):
        fail("unknown-review-lane")
    findings = {
        "p0": arguments.open_p0,
        "p1": arguments.open_p1,
        "p2": arguments.open_p2,
    }
    if any(value < 0 for value in findings.values()):
        fail("invalid-open-finding-count")
    if arguments.status == "pass" and any(findings.values()):
        fail("passing-review-has-open-blockers")

    candidate = run_git(repo, "rev-parse", "--verify", "HEAD^{commit}")
    if not SHA40.fullmatch(candidate):
        fail("invalid-candidate")
    if run_git(repo, "status", "--porcelain", "--untracked-files=all"):
        fail("dirty-worktree")

    try:
        metadata = report.lstat()
    except OSError:
        fail("missing-review-report")
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_mode & 0o077
        or metadata.st_size <= 0
        or metadata.st_size > 2 * 1024 * 1024
    ):
        fail("invalid-review-report")
    try:
        report_data = report.read_bytes()
        report_data.decode("utf-8")
    except (OSError, UnicodeError):
        fail("invalid-review-report")

    if evidence_dir.is_symlink():
        fail("invalid-review-evidence-directory")
    try:
        evidence_dir.mkdir(parents=True, exist_ok=True)
        evidence_metadata = evidence_dir.lstat()
    except OSError:
        fail("invalid-review-evidence-directory")
    if (
        not stat.S_ISDIR(evidence_metadata.st_mode)
        or stat.S_ISLNK(evidence_metadata.st_mode)
        or evidence_metadata.st_uid != os.getuid()
    ):
        fail("invalid-review-evidence-directory")
    os.chmod(evidence_dir, 0o700)
    canonical_report = evidence_dir / f"{arguments.lane}.report.txt"
    record_path = evidence_dir / f"{arguments.lane}.review.json"
    atomic_write(canonical_report, report_data)
    record: dict[str, Any] = {
        "schemaVersion": 1,
        "id": arguments.lane,
        "candidate": candidate,
        "status": arguments.status,
        "openFindings": findings,
        "reviewedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "reportFileName": canonical_report.name,
        "reportBytes": len(report_data),
        "reportSHA256": sha256_bytes(report_data),
    }
    record_data = (json.dumps(record, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()
    atomic_write(record_path, record_data)

    final_candidate = run_git(repo, "rev-parse", "--verify", "HEAD^{commit}")
    final_status = run_git(repo, "status", "--porcelain", "--untracked-files=all")
    if final_candidate != candidate or final_status:
        canonical_report.unlink(missing_ok=True)
        record_path.unlink(missing_ok=True)
        fail("candidate-changed-during-review-recording")
    print(
        "review-evidence-summary"
        f" status={arguments.status} lane={arguments.lane} candidate={candidate}"
        f" p0={findings['p0']} p1={findings['p1']} p2={findings['p2']}"
    )


if __name__ == "__main__":
    main()
