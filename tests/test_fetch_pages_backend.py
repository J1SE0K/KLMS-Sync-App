import json
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

import fetch_pages_backend  # noqa: E402


class FetchPagesBackendTests(unittest.TestCase):
    def test_load_previous_pages_discards_oversized_cache(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "pages.json"
            path.write_text(json.dumps([{"html": "abcdef"}]), encoding="utf-8")

            pages, discarded = fetch_pages_backend.load_previous_pages(
                path,
                discard_previous=False,
                max_previous_bytes=1,
            )

        self.assertEqual(pages, [])
        self.assertTrue(discarded)

    def test_load_previous_pages_keeps_valid_cache_under_limit(self) -> None:
        payload = [{"requestedUrl": "https://klms.kaist.ac.kr/my/", "html": "<html></html>"}]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "pages.json"
            path.write_text(json.dumps(payload), encoding="utf-8")

            pages, discarded = fetch_pages_backend.load_previous_pages(
                path,
                discard_previous=False,
                max_previous_bytes=10_000,
            )

        self.assertEqual(pages, payload)
        self.assertFalse(discarded)


if __name__ == "__main__":
    unittest.main()
