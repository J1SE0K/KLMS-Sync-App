#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import stat
import subprocess
from typing import Any


SHA40 = re.compile(r"[0-9a-f]{40}")


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


def load_provenance(app: Path) -> dict[str, Any]:
    executable = app / "Contents" / "MacOS" / "KLMSMac"
    resource = app / "Contents" / "Resources" / "KLMSAppBuildProvenance.json"
    for path, reason in (
        (executable, "invalid-app-executable"),
        (resource, "invalid-app-provenance-resource"),
    ):
        try:
            metadata = path.lstat()
        except OSError:
            fail(reason)
        if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            fail(reason)
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
        embedded_payload = json.loads(embedded.decode("utf-8"))
        resource_payload = json.loads(resource.read_text(encoding="utf-8"))
    except (UnicodeError, OSError, json.JSONDecodeError):
        fail("invalid-app-provenance-json")
    if embedded_payload != resource_payload or not isinstance(embedded_payload, dict):
        fail("app-provenance-copy-mismatch")
    return embedded_payload


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
    arguments = parser.parse_args()
    payload = verify_provenance(
        arguments.app.expanduser().resolve(),
        arguments.expected_revision,
        arguments.expected_tree,
        arguments.require_clean,
    )
    print(
        "app-provenance-summary status=pass"
        f" candidate={payload['sourceRevision']} tree={payload['sourceTree']}"
        f" dirty={str(payload['dirty']).lower()}"
    )


if __name__ == "__main__":
    main()
