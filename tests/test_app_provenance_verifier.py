from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import unittest


PROJECT_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = PROJECT_DIR / "tools" / "verify_klms_app_provenance.py"
SPEC = importlib.util.spec_from_file_location("app_provenance_verifier", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
provenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provenance)


class AppProvenanceVerifierTests(unittest.TestCase):
    def test_otool_section_round_trips_json_payload(self) -> None:
        payload = {
            "dirty": False,
            "schemaVersion": 1,
            "sourceRevision": "a" * 40,
            "sourceTree": "b" * 40,
        }
        encoded = (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode()
        words = [
            encoded[index:index + 4][::-1].hex()
            for index in range(0, len(encoded), 4)
        ]
        lines = ["Contents of (__TEXT,__klms_prov) section"]
        for index in range(0, len(words), 4):
            lines.append(f"000000010000{index:04x} " + " ".join(words[index:index + 4]))

        decoded = provenance.parse_otool_section("\n".join(lines))

        self.assertEqual(json.loads(decoded), payload)

    def test_otool_section_rejects_missing_bytes(self) -> None:
        with self.assertRaises(SystemExit):
            provenance.parse_otool_section("Contents of (__TEXT,__klms_prov) section\n")


if __name__ == "__main__":
    unittest.main()
