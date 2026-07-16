#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import subprocess
from typing import Any


SHA40 = re.compile(r"[0-9a-f]{40}")
APP_EXECUTABLES = (
    "Contents/MacOS/KLMSMac",
    "Contents/Helpers/KLMSNoticeNativeNote.app/Contents/MacOS/KLMSNoticeNativeNote",
)


def fail(reason: str) -> None:
    raise SystemExit(f"app-provenance-summary status=fail reason={reason}")


def parse_otool_section(output: str) -> bytes:
    chunks: list[bytes] = []
    for line in output.splitlines():
        fields = line.strip().split()
        if len(fields) < 2 or not re.fullmatch(r"[0-9a-fA-F]+", fields[0]):
            continue
        for field in fields[1:]:
            if not re.fullmatch(r"[0-9a-fA-F]{2,8}", field) or len(field) % 2:
                fail("invalid-mach-o-provenance-section")
            try:
                chunks.append(bytes.fromhex(field)[::-1])
            except ValueError:
                fail("invalid-mach-o-provenance-section")
    if not chunks:
        fail("missing-mach-o-provenance-section")
    return b"".join(chunks).rstrip(b"\x00")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def embedded_provenance(executable: Path) -> dict[str, Any]:
    result = subprocess.run(
        ["/usr/bin/otool", "-s", "__TEXT", "__klms_prov", str(executable)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        fail("mach-o-provenance-read-failed")
    embedded = parse_otool_section(result.stdout)
    try:
        payload = json.loads(embedded.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        fail("invalid-app-provenance-json")
    if not isinstance(payload, dict):
        fail("invalid-app-provenance-json")
    return payload


def load_provenance(app: Path) -> dict[str, Any]:
    resource = app / "Contents" / "Resources" / "KLMSAppBuildProvenance.json"
    paths = [(app / relative, "invalid-app-executable") for relative in APP_EXECUTABLES]
    paths.append((resource, "invalid-app-provenance-resource"))
    for path, reason in paths:
        try:
            metadata = path.lstat()
        except OSError:
            fail(reason)
        if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            fail(reason)
    try:
        resource_payload = json.loads(resource.read_text(encoding="utf-8"))
    except (UnicodeError, OSError, json.JSONDecodeError):
        fail("invalid-app-provenance-json")
    if not isinstance(resource_payload, dict):
        fail("invalid-app-provenance-json")
    for relative in APP_EXECUTABLES:
        if embedded_provenance(app / relative) != resource_payload:
            fail("app-provenance-copy-mismatch")
    return resource_payload


def artifact_tree_sha256(app: Path) -> str:
    try:
        app_metadata = app.lstat()
    except OSError:
        fail("invalid-app-bundle")
    if not stat.S_ISDIR(app_metadata.st_mode) or stat.S_ISLNK(app_metadata.st_mode):
        fail("invalid-app-bundle")
    digest = hashlib.sha256()
    for path in sorted(app.rglob("*"), key=lambda value: value.relative_to(app).as_posix()):
        try:
            metadata = path.lstat()
        except OSError:
            fail("invalid-app-artifact-entry")
        relative = path.relative_to(app).as_posix()
        if stat.S_ISLNK(metadata.st_mode):
            fail("invalid-app-artifact-entry")
        if stat.S_ISDIR(metadata.st_mode):
            entry = [relative, "directory", stat.S_IMODE(metadata.st_mode), 0, None]
        elif stat.S_ISREG(metadata.st_mode):
            entry = [relative, "file", stat.S_IMODE(metadata.st_mode), metadata.st_size, sha256(path)]
        else:
            fail("invalid-app-artifact-entry")
        digest.update(json.dumps(entry, separators=(",", ":")).encode("utf-8") + b"\n")
    return digest.hexdigest()


def parse_codesign_metadata(output: str) -> dict[str, Any]:
    values: dict[str, str] = {}
    for line in output.splitlines():
        key, separator, value = line.partition("=")
        if separator and key not in values:
            values[key] = value.strip()
    cd_hash = values.get("CDHash", "").lower()
    if not re.fullmatch(r"[0-9a-f]{40,64}", cd_hash):
        fail("missing-executable-cdhash")
    team = values.get("TeamIdentifier")
    if team in {None, "", "not set"}:
        team = None
    return {
        "cdHash": cd_hash,
        "teamIdentifier": team,
        "signature": values.get("Signature", "unknown"),
    }


def codesign_metadata(executable: Path) -> dict[str, Any]:
    result = subprocess.run(
        ["/usr/bin/codesign", "--display", "--verbose=4", str(executable)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        fail("executable-code-signature-unavailable")
    return parse_codesign_metadata(result.stdout + "\n" + result.stderr)


def describe_artifact(app: Path, payload: dict[str, Any]) -> dict[str, Any]:
    executables: list[dict[str, Any]] = []
    for relative in APP_EXECUTABLES:
        executable = app / relative
        metadata = codesign_metadata(executable)
        executables.append({
            "relativePath": relative,
            "sha256": sha256(executable),
            **metadata,
        })
    if len({entry["teamIdentifier"] for entry in executables}) != 1:
        fail("executable-signing-team-mismatch")
    return {
        "schemaVersion": 1,
        "sourceRevision": payload["sourceRevision"],
        "sourceTree": payload["sourceTree"],
        "dirty": payload["dirty"],
        "artifactSHA256": artifact_tree_sha256(app),
        "buildProvenanceSHA256": sha256(app / "Contents" / "Resources" / "KLMSAppBuildProvenance.json"),
        "executables": executables,
    }


def verify_provenance(
    app: Path,
    expected_revision: str,
    expected_tree: str,
    require_clean: bool,
) -> dict[str, Any]:
    payload = load_provenance(app)
    if (
        payload.get("schemaVersion") != 1
        or payload.get("sourceRevision") != expected_revision
        or payload.get("sourceTree") != expected_tree
        or not SHA40.fullmatch(str(payload.get("sourceRevision") or ""))
        or not SHA40.fullmatch(str(payload.get("sourceTree") or ""))
        or not isinstance(payload.get("dirty"), bool)
    ):
        fail("app-provenance-mismatch")
    if require_clean and payload["dirty"]:
        fail("dirty-app-provenance")
    return payload


def main() -> None:
    parser = argparse.ArgumentParser(description="Verify KLMS Mac executable source provenance.")
    parser.add_argument("app", type=Path)
    parser.add_argument("--expected-revision", required=True)
    parser.add_argument("--expected-tree", required=True)
    parser.add_argument("--require-clean", action="store_true")
    parser.add_argument("--json", action="store_true")
    arguments = parser.parse_args()
    payload = verify_provenance(
        arguments.app.expanduser().resolve(),
        arguments.expected_revision,
        arguments.expected_tree,
        arguments.require_clean,
    )
    artifact = describe_artifact(arguments.app.expanduser().resolve(), payload)
    if arguments.json:
        print(json.dumps(artifact, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
        return
    main_executable, helper_executable = artifact["executables"]
    team_identifier = main_executable["teamIdentifier"] or "adhoc"
    print(
        "app-provenance-summary status=pass"
        f" candidate={payload['sourceRevision']} tree={payload['sourceTree']}"
        f" dirty={str(payload['dirty']).lower()}"
        f" artifact_sha256={artifact['artifactSHA256']}"
        f" main_sha256={main_executable['sha256']} main_cdhash={main_executable['cdHash']}"
        f" helper_sha256={helper_executable['sha256']} helper_cdhash={helper_executable['cdHash']}"
        f" signing_team={team_identifier}"
    )


if __name__ == "__main__":
    main()
