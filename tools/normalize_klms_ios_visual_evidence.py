#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import tempfile
from typing import Any


SHA40 = re.compile(r"[0-9a-f]{40}")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MAX_MANIFEST_BYTES = 5 * 1024 * 1024
MAX_ATTACHMENT_BYTES = 100 * 1024 * 1024


def fail(message: str) -> None:
    raise SystemExit(f"ios-visual-evidence-summary status=fail reason={message}")


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def require_owned_directory(path: Path, *, create: bool) -> Path:
    absolute = Path(os.path.abspath(path.expanduser()))
    try:
        metadata = absolute.lstat()
    except FileNotFoundError:
        if not create:
            fail("missing-source-directory")
        absolute.mkdir(mode=0o700, parents=True)
        metadata = absolute.lstat()
    except OSError:
        fail("invalid-evidence-directory")
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        fail("invalid-evidence-directory")
    if metadata.st_uid != os.getuid():
        fail("invalid-evidence-directory")
    if create:
        os.chmod(absolute, 0o700)
        if any(absolute.iterdir()):
            fail("output-directory-not-empty")
    return absolute


def require_regular_file(path: Path, *, maximum_bytes: int, reason: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError:
        fail(f"missing-{reason}")
    invalid_kind = not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode)
    invalid_owner_or_size = (
        metadata.st_uid != os.getuid()
        or not 0 < metadata.st_size <= maximum_bytes
    )
    if invalid_kind or invalid_owner_or_size:
        fail(f"invalid-{reason}")
    return metadata


def png_dimensions(path: Path) -> tuple[int, int]:
    with path.open("rb") as handle:
        header = handle.read(24)
    if len(header) != 24 or header[:8] != PNG_SIGNATURE or header[12:16] != b"IHDR":
        fail(f"invalid-png-{path.name}")
    return struct.unpack(">II", header[16:24])


def expected_orientation(family: str, human_name: str) -> str:
    lowered = human_name.lower()
    if family == "ipad":
        return "portrait" if "portrait" in lowered else "landscape"
    return "landscape" if "landscape" in lowered else "portrait"


def atomic_copy(source: Path, destination: Path) -> None:
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.",
        dir=destination.parent,
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        shutil.copyfile(source, temporary)
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_rotate(source: Path, destination: Path) -> None:
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.stem}.",
        suffix=".png",
        dir=destination.parent,
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        subprocess.run(
            ["/usr/bin/sips", "-r", "90", str(source), "--out", str(temporary)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        require_regular_file(
            temporary,
            maximum_bytes=MAX_ATTACHMENT_BYTES,
            reason="rotated-attachment",
        )
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
    except (OSError, subprocess.SubprocessError):
        fail(f"rotation-failed-{source.name}")
    finally:
        temporary.unlink(missing_ok=True)


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    text = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    data = text.encode("utf-8")
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


def load_source_manifest(source_dir: Path) -> tuple[Path, list[dict[str, Any]]]:
    source_manifest = source_dir / "manifest.json"
    require_regular_file(
        source_manifest,
        maximum_bytes=MAX_MANIFEST_BYTES,
        reason="source-manifest",
    )
    try:
        payload = json.loads(source_manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        fail("invalid-source-manifest")
    if not isinstance(payload, list) or not all(isinstance(value, dict) for value in payload):
        fail("invalid-source-manifest")
    return source_manifest, payload


def normalize(
    *,
    family: str,
    source_dir: Path,
    output_dir: Path,
    candidate: str,
) -> int:
    source = require_owned_directory(source_dir, create=False)
    output = require_owned_directory(output_dir, create=True)
    source_manifest, payload = load_source_manifest(source)
    records: list[dict[str, Any]] = []
    seen: set[str] = set()

    for test in payload:
        attachments = test.get("attachments", [])
        if not isinstance(attachments, list):
            fail("invalid-source-manifest")
        for attachment in attachments:
            if not isinstance(attachment, dict):
                fail("invalid-source-manifest")
            filename = attachment.get("exportedFileName")
            valid_filename = (
                isinstance(filename, str)
                and bool(filename)
                and Path(filename).name == filename
                and filename not in seen
            )
            if not valid_filename:
                fail("invalid-attachment-filename")
            seen.add(filename)
            attachment_source = source / filename
            require_regular_file(
                attachment_source,
                maximum_bytes=MAX_ATTACHMENT_BYTES,
                reason="attachment",
            )
            destination = output / filename
            human_name_value = attachment.get("suggestedHumanReadableName")
            human_name = (
                human_name_value
                if isinstance(human_name_value, str) and human_name_value
                else filename
            )
            record: dict[str, Any] = {
                "fileName": filename,
                "suggestedHumanReadableName": human_name,
                "sourceSHA256": digest(attachment_source),
            }

            if attachment_source.suffix.lower() == ".png":
                before_width, before_height = png_dimensions(attachment_source)
                orientation = expected_orientation(family, human_name)
                is_landscape_pixels = before_width > before_height
                needs_rotation = (orientation == "landscape") != is_landscape_pixels
                if needs_rotation:
                    atomic_rotate(attachment_source, destination)
                else:
                    atomic_copy(attachment_source, destination)
                after_width, after_height = png_dimensions(destination)
                is_normalized_landscape = after_width > after_height
                if (orientation == "landscape") != is_normalized_landscape:
                    fail(f"orientation-normalization-{filename}")
                record.update(
                    {
                        "expectedOrientation": orientation,
                        "rotatedClockwiseDegrees": 90 if needs_rotation else 0,
                        "pixelWidth": after_width,
                        "pixelHeight": after_height,
                    }
                )
            else:
                atomic_copy(attachment_source, destination)
                record["expectedOrientation"] = "not-applicable"
            record["outputSHA256"] = digest(destination)
            records.append(record)

    if not any(record["expectedOrientation"] != "not-applicable" for record in records):
        fail("missing-screenshot-attachments")

    copied_manifest = output / "xcresult-manifest.json"
    atomic_copy(source_manifest, copied_manifest)
    records.sort(key=lambda record: (record["suggestedHumanReadableName"], record["fileName"]))
    atomic_write_json(
        output / "manifest.json",
        {
            "schemaVersion": 1,
            "candidate": candidate,
            "family": family,
            "sourceManifestFile": copied_manifest.name,
            "sourceManifestSHA256": digest(copied_manifest),
            "attachments": records,
        },
    )
    return len(records)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Normalize and attest KLMS iOS xcresult screenshot attachments."
    )
    parser.add_argument("--family", required=True, choices=("iphone", "ipad"))
    parser.add_argument("--source-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--candidate", required=True)
    arguments = parser.parse_args()
    if not SHA40.fullmatch(arguments.candidate):
        fail("invalid-candidate")
    count = normalize(
        family=arguments.family,
        source_dir=arguments.source_dir,
        output_dir=arguments.output_dir,
        candidate=arguments.candidate,
    )
    print(
        "ios-visual-evidence-summary"
        f" status=pass family={arguments.family}"
        f" candidate={arguments.candidate} attachments={count}"
    )


if __name__ == "__main__":
    main()
