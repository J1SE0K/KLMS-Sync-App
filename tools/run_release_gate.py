#!/usr/bin/env python3

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any


SHA40 = re.compile(r"[0-9a-f]{40}")
GATE_ID = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
DEFAULT_STEP_TIMEOUT_SECONDS = 1_800
MAX_STEP_TIMEOUT_SECONDS = 14_400
DEFAULT_GATE_OUTPUT_BYTES = 64 * 1024 * 1024
MAX_GATE_OUTPUT_BYTES = 96 * 1024 * 1024


def fail(message: str, status: int = 70) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(status)


def git(repo: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["/usr/bin/git", "-C", str(repo), *arguments],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        fail(f"gate-evidence-summary status=fail reason=git-{arguments[0]}-unavailable")
    return result.stdout.strip()


def execution_digest(entry: dict[str, Any]) -> str:
    payload = {"id": entry.get("id"), "execution": entry.get("execution")}
    canonical = json.dumps(
        payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def file_digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def private_directory(path: Path, repo: Path) -> Path:
    absolute = Path(os.path.abspath(path.expanduser()))
    try:
        original_metadata = absolute.lstat()
    except FileNotFoundError:
        original_metadata = None
    except OSError:
        fail("gate-evidence-summary status=fail reason=invalid-evidence-directory")
    if original_metadata is not None and stat.S_ISLNK(original_metadata.st_mode):
        fail("gate-evidence-summary status=fail reason=invalid-evidence-directory")
    resolved = absolute.resolve(strict=False)
    if resolved == repo or repo in resolved.parents:
        fail("gate-evidence-summary status=fail reason=evidence-directory-inside-repository")
    try:
        resolved.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(resolved, 0o700)
        metadata = resolved.lstat()
    except OSError:
        fail("gate-evidence-summary status=fail reason=invalid-evidence-directory")
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_mode & 0o077
    ):
        fail("gate-evidence-summary status=fail reason=invalid-evidence-directory")
    return resolved


def validate_execution(entry: dict[str, Any], repo: Path) -> dict[str, Any]:
    execution = entry.get("execution")
    if not isinstance(execution, dict):
        fail("gate-evidence-summary status=fail reason=invalid-gate-execution")
    working_directory = execution.get("workingDirectory")
    environment = execution.get("environment")
    steps = execution.get("steps")
    timeout_seconds = execution.get("timeoutSeconds", DEFAULT_STEP_TIMEOUT_SECONDS)
    max_output_bytes = execution.get("maxOutputBytes", DEFAULT_GATE_OUTPUT_BYTES)
    if (
        not isinstance(working_directory, str)
        or not isinstance(environment, dict)
        or not all(isinstance(key, str) and isinstance(value, str) for key, value in environment.items())
        or not isinstance(steps, list)
        or not steps
        or not isinstance(timeout_seconds, int)
        or isinstance(timeout_seconds, bool)
        or not 1 <= timeout_seconds <= MAX_STEP_TIMEOUT_SECONDS
        or not isinstance(max_output_bytes, int)
        or isinstance(max_output_bytes, bool)
        or not 1 <= max_output_bytes <= MAX_GATE_OUTPUT_BYTES
        or not all(
            isinstance(step, dict)
            and isinstance(step.get("argv"), list)
            and bool(step["argv"])
            and all(isinstance(value, str) and value for value in step["argv"])
            for step in steps
        )
    ):
        fail("gate-evidence-summary status=fail reason=invalid-gate-execution")
    cwd = (repo / working_directory).resolve(strict=False)
    if cwd != repo and repo not in cwd.parents:
        fail("gate-evidence-summary status=fail reason=invalid-gate-working-directory")
    if not cwd.is_dir():
        fail("gate-evidence-summary status=fail reason=missing-gate-working-directory")
    return execution


def resolve_placeholders(
    value: str,
    *,
    evidence_dir: Path,
    gate_id: str,
    candidate: str,
    scanner_root: Path,
) -> str:
    replacements = {
        "<isolated-path>": str(evidence_dir / "work" / gate_id),
        "<isolated-module-cache>": str(evidence_dir / "work" / f"{gate_id}-module-cache"),
        "<private-evidence-dir>": str(evidence_dir / "security-reports"),
        "<scanner-root>": str(scanner_root),
        "<candidate-app>": str(evidence_dir / "artifacts" / f"KLMS Sync {candidate[:8]}.app"),
    }
    if value in replacements:
        target = Path(replacements[value])
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if value != "<candidate-app>":
            target.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.chmod(target, 0o700)
        return replacements[value]
    if "<" in value or ">" in value:
        fail("gate-evidence-summary status=fail reason=unknown-gate-placeholder")
    return value


def execution_environment(values: dict[str, str]) -> dict[str, str]:
    inherited_keys = (
        "HOME",
        "TMPDIR",
        "DEVELOPER_DIR",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "TERM",
        "USER",
        "LOGNAME",
        "SHELL",
        "__CF_USER_TEXT_ENCODING",
    )
    environment = {key: os.environ[key] for key in inherited_keys if key in os.environ}
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
    environment.update(values)
    return environment


def write_line(log: Any, value: str) -> None:
    encoded = (value + "\n").encode("utf-8")
    log.write(encoded)
    log.flush()
    sys.stdout.buffer.write(encoded)
    sys.stdout.buffer.flush()


def terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        if process.poll() is None:
            process.wait()
        return
    except PermissionError:
        if process.poll() is None:
            process.terminate()
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        process.poll()
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            if process.poll() is None:
                process.wait()
            return
        except PermissionError:
            if process.poll() is not None:
                return
            break
        time.sleep(0.05)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        if process.poll() is None:
            process.kill()
    if process.poll() is None:
        process.wait()


def stream_process(
    process: subprocess.Popen[bytes],
    log: Any,
    *,
    timeout_seconds: float,
    max_output_bytes: int,
    mirror_output: bool = True,
) -> tuple[int, int, str | None]:
    if process.stdout is None:
        terminate_process_group(process)
        return 70, 0, "missing-output-pipe"
    descriptor = process.stdout.fileno()
    os.set_blocking(descriptor, False)
    selector = selectors.DefaultSelector()
    selector.register(descriptor, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout_seconds
    output_bytes = 0
    reached_eof = False
    abort_reason: str | None = None
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                abort_reason = "timeout"
                break
            events = selector.select(min(remaining, 0.25))
            for key, _ in events:
                try:
                    chunk = os.read(key.fd, 64 * 1024)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fd)
                    reached_eof = True
                    continue
                allowed = max_output_bytes - output_bytes
                if allowed > 0:
                    accepted = chunk[:allowed]
                    log.write(accepted)
                    log.flush()
                    if mirror_output:
                        sys.stdout.buffer.write(accepted)
                        sys.stdout.buffer.flush()
                    output_bytes += len(accepted)
                if len(chunk) > allowed:
                    abort_reason = "output-limit"
                    break
            if abort_reason is not None:
                break
            if reached_eof and process.poll() is not None:
                return process.returncode, output_bytes, None
    finally:
        selector.close()
        process.stdout.close()
    terminate_process_group(process)
    return (124 if abort_reason == "timeout" else 74), output_bytes, abort_reason


def main() -> None:
    if len(sys.argv) != 2 or not GATE_ID.fullmatch(sys.argv[1]):
        fail("usage: tools/run_release_gate.sh <gate-id>", 64)
    gate_id = sys.argv[1]
    repo = Path(__file__).resolve().parents[1]
    inventory_path = repo / "docs" / "quality-gate-inventory.json"
    try:
        inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        fail("gate-evidence-summary status=fail reason=invalid-quality-gate-inventory")
    entries = inventory.get("automatedGates") if isinstance(inventory, dict) else None
    if not isinstance(entries, list):
        fail("gate-evidence-summary status=fail reason=invalid-quality-gate-inventory")
    matching = [entry for entry in entries if isinstance(entry, dict) and entry.get("id") == gate_id]
    if len(matching) != 1:
        fail("gate-evidence-summary status=fail reason=unknown-gate")
    entry = matching[0]
    execution = validate_execution(entry, repo)
    candidate = git(repo, "rev-parse", "--verify", "HEAD^{commit}")
    if not SHA40.fullmatch(candidate):
        fail(f"gate-evidence-summary status=fail gate={gate_id} reason=invalid-git-candidate")
    if git(repo, "status", "--porcelain", "--untracked-files=all"):
        fail(
            f"gate-evidence-summary status=fail gate={gate_id} "
            f"candidate={candidate} reason=dirty-worktree"
        )
    evidence_dir = private_directory(
        Path(os.environ.get("KLMS_RELEASE_EVIDENCE_DIR", ""))
        if os.environ.get("KLMS_RELEASE_EVIDENCE_DIR")
        else Path(os.environ.get("TMPDIR", "/private/tmp")) / "klms-release-evidence",
        repo,
    )
    scanner_root = private_directory(
        Path(os.environ.get("KLMS_SECURITY_SCANNER_ROOT", ""))
        if os.environ.get("KLMS_SECURITY_SCANNER_ROOT")
        else Path(os.environ.get("TMPDIR", "/private/tmp")) / "klms-security-scanners",
        repo,
    )
    invocation_sha = execution_digest(entry)
    inventory_sha = file_digest(inventory_path)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{gate_id}.", dir=evidence_dir)
    temporary = Path(temporary_name)
    final_log = evidence_dir / f"{gate_id}.log"
    status = 70
    try:
        with os.fdopen(descriptor, "wb") as log:
            started_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            write_line(
                log,
                f"gate-evidence schema=2 gate={gate_id} candidate={candidate} "
                f"invocation_sha256={invocation_sha} inventory_sha256={inventory_sha} "
                f"started_at={started_at}",
            )
            resolved_environment = {
                key: resolve_placeholders(
                    value,
                    evidence_dir=evidence_dir,
                    gate_id=gate_id,
                    candidate=candidate,
                    scanner_root=scanner_root,
                )
                for key, value in execution["environment"].items()
            }
            environment = execution_environment(resolved_environment)
            cwd = (repo / execution["workingDirectory"]).resolve()
            timeout_seconds = execution.get("timeoutSeconds", DEFAULT_STEP_TIMEOUT_SECONDS)
            max_output_bytes = execution.get("maxOutputBytes", DEFAULT_GATE_OUTPUT_BYTES)
            output_bytes = 0
            status = 0
            for step in execution["steps"]:
                if git(repo, "rev-parse", "--verify", "HEAD^{commit}") != candidate or git(
                    repo, "status", "--porcelain", "--untracked-files=all"
                ):
                    status = 70
                    break
                argv = [
                    resolve_placeholders(
                        value,
                        evidence_dir=evidence_dir,
                        gate_id=gate_id,
                        candidate=candidate,
                        scanner_root=scanner_root,
                    )
                    for value in step["argv"]
                ]
                executable = shutil.which(argv[0], path=environment["PATH"])
                if executable is None and "/" not in argv[0]:
                    status = 127
                    break
                try:
                    process = subprocess.Popen(
                        argv,
                        cwd=cwd,
                        env=environment,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                        start_new_session=True,
                    )
                except OSError:
                    status = 127
                    break
                status, emitted, abort_reason = stream_process(
                    process,
                    log,
                    timeout_seconds=timeout_seconds,
                    max_output_bytes=max_output_bytes - output_bytes,
                )
                output_bytes += emitted
                if abort_reason is not None:
                    write_line(
                        log,
                        f"gate-step-aborted reason={abort_reason} timeout_seconds={timeout_seconds} "
                        f"output_bytes={output_bytes} max_output_bytes={max_output_bytes}",
                    )
                if status != 0:
                    break
            final_candidate = git(repo, "rev-parse", "--verify", "HEAD^{commit}")
            final_status = git(repo, "status", "--porcelain", "--untracked-files=all")
            passed = status == 0 and final_candidate == candidate and not final_status
            if not passed and status == 0:
                status = 70
            write_line(
                log,
                f"gate-evidence-summary status={'pass' if passed else 'fail'} gate={gate_id} "
                f"candidate={candidate} invocation_sha256={invocation_sha} "
                f"inventory_sha256={inventory_sha} exit={status}",
            )
        os.chmod(temporary, 0o600)
        os.replace(temporary, final_log)
        os.chmod(final_log, 0o600)
    finally:
        temporary.unlink(missing_ok=True)
    raise SystemExit(status)


if __name__ == "__main__":
    main()
