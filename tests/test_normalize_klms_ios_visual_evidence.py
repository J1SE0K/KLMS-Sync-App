from __future__ import annotations

import binascii
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import tempfile
import unittest
import zlib


PROJECT_DIR = Path(__file__).resolve().parents[1]
NORMALIZER = PROJECT_DIR / "tools" / "normalize_klms_ios_visual_evidence.py"
CANDIDATE = "1" * 40


class NormalizeKLMSIOSVisualEvidenceTests(unittest.TestCase):
    def test_normalizes_landscape_and_preserves_portrait_with_attestation(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "source"
            output = root / "output"
            source.mkdir(mode=0o700)
            self._write_png(source / "landscape.png", width=2, height=4)
            self._write_png(source / "portrait.png", width=2, height=4)
            (source / "metrics.txt").write_text('{"durationMs":12}\n', encoding="utf-8")
            self._write_manifest(
                source,
                [
                    ("landscape.png", "klms-ipad-wide-navigation-sidebar.png"),
                    ("portrait.png", "klms-ipad-portrait-medium-navigation-rail.png"),
                    ("metrics.txt", "klms-ios-performance.json"),
                ],
            )

            result = self._run(source=source, output=output, family="ipad")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("status=pass", result.stdout)
            manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["candidate"], CANDIDATE)
            self.assertEqual(manifest["family"], "ipad")
            records = {entry["fileName"]: entry for entry in manifest["attachments"]}
            self.assertEqual(
                (records["landscape.png"]["pixelWidth"], records["landscape.png"]["pixelHeight"]),
                (4, 2),
            )
            self.assertEqual(records["landscape.png"]["rotatedClockwiseDegrees"], 90)
            self.assertEqual(
                (records["portrait.png"]["pixelWidth"], records["portrait.png"]["pixelHeight"]),
                (2, 4),
            )
            self.assertEqual(records["portrait.png"]["rotatedClockwiseDegrees"], 0)
            self.assertEqual(records["metrics.txt"]["expectedOrientation"], "not-applicable")
            for filename in ("landscape.png", "portrait.png", "metrics.txt", "manifest.json"):
                mode = stat.S_IMODE((output / filename).stat().st_mode)
                self.assertEqual(mode & 0o077, 0)

    def test_rejects_manifest_path_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "source"
            output = root / "output"
            source.mkdir(mode=0o700)
            self._write_manifest(source, [("../outside.png", "klms-iphone-section-status.png")])

            result = self._run(source=source, output=output, family="iphone")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("invalid-attachment-filename", result.stderr)

    def _run(
        self,
        *,
        source: Path,
        output: Path,
        family: str,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(NORMALIZER),
                "--family",
                family,
                "--source-dir",
                str(source),
                "--output-dir",
                str(output),
                "--candidate",
                CANDIDATE,
            ],
            cwd=PROJECT_DIR,
            text=True,
            capture_output=True,
            check=False,
        )

    def _write_manifest(
        self,
        source: Path,
        attachments: list[tuple[str, str]],
    ) -> None:
        payload = [
            {
                "testIdentifier": "KLMSiOSUITests/example",
                "attachments": [
                    {
                        "exportedFileName": filename,
                        "suggestedHumanReadableName": human_name,
                    }
                    for filename, human_name in attachments
                ],
            }
        ]
        (source / "manifest.json").write_text(
            json.dumps(payload, ensure_ascii=False),
            encoding="utf-8",
        )

    def _write_png(self, path: Path, *, width: int, height: int) -> None:
        def chunk(kind: bytes, data: bytes) -> bytes:
            return (
                struct.pack(">I", len(data))
                + kind
                + data
                + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF)
            )

        rows = b"".join(
            b"\x00" + bytes([40, 80, 120, 255]) * width
            for _ in range(height)
        )
        path.write_bytes(
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows))
            + chunk(b"IEND", b"")
        )


if __name__ == "__main__":
    unittest.main()
