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

    def test_always_fetch_pattern_respects_min_interval(self) -> None:
        url = "https://klms.kaist.ac.kr/mod/courseboard/view.php?id=1"
        page = {"requestedUrl": url, "html": "<html>cached</html>"}
        context_state = {
            "urls": {
                url: {
                    "last_fetched_at": fetch_pages_backend.now_utc_iso(),
                    "fingerprint": fetch_pages_backend.page_fingerprint(page),
                }
            }
        }

        selected = fetch_pages_backend.choose_urls_to_fetch(
            urls=[url],
            previous_lookup={url: page},
            context_state=context_state,
            mode="quick",
            quick_limit=0,
            stale_seconds=3600,
            always_fetch_min_interval_seconds=1800,
            always_fetch_patterns=[r"/mod/courseboard/view\.php"],
            fallback_url_set=set(),
            probe_order="index",
        )

        self.assertEqual(selected, [])

    def test_always_fetch_pattern_runs_without_interval(self) -> None:
        url = "https://klms.kaist.ac.kr/mod/courseboard/view.php?id=1"
        page = {"requestedUrl": url, "html": "<html>cached</html>"}

        selected = fetch_pages_backend.choose_urls_to_fetch(
            urls=[url],
            previous_lookup={url: page},
            context_state={"urls": {url: {"last_fetched_at": fetch_pages_backend.now_utc_iso()}}},
            mode="quick",
            quick_limit=0,
            stale_seconds=3600,
            always_fetch_min_interval_seconds=0,
            always_fetch_patterns=[r"/mod/courseboard/view\.php"],
            fallback_url_set=set(),
            probe_order="index",
        )

        self.assertEqual(selected, [url])

    def test_update_context_state_preserves_reused_fetch_timestamp(self) -> None:
        url = "https://klms.kaist.ac.kr/course/view.php?id=1"
        old_fetched_at = "2026-04-01T00:00:00Z"
        old_changed_at = "2026-04-01T00:00:00Z"
        page = {"requestedUrl": url, "title": "Course", "html": "<html>cached</html>"}
        context_state = {
            "urls": {
                url: {
                    "fingerprint": fetch_pages_backend.page_fingerprint(page),
                    "last_fetched_at": old_fetched_at,
                    "last_changed_at": old_changed_at,
                    "backend": "safari",
                }
            }
        }

        fetch_pages_backend.update_context_state(
            context_state,
            pages=[page],
            backend="safari",
            effective_mode="quick",
            fetched_urls=set(),
        )

        self.assertEqual(context_state["urls"][url]["last_fetched_at"], old_fetched_at)
        self.assertEqual(context_state["urls"][url]["last_changed_at"], old_changed_at)

    def test_update_context_state_advances_fetched_timestamp(self) -> None:
        url = "https://klms.kaist.ac.kr/course/view.php?id=1"
        old_fetched_at = "2026-04-01T00:00:00Z"
        page = {"requestedUrl": url, "title": "Course", "html": "<html>changed</html>"}
        context_state = {
            "urls": {
                url: {
                    "fingerprint": "old",
                    "last_fetched_at": old_fetched_at,
                    "last_changed_at": old_fetched_at,
                    "backend": "safari",
                }
            }
        }

        fetch_pages_backend.update_context_state(
            context_state,
            pages=[page],
            backend="safari",
            effective_mode="quick",
            fetched_urls={url},
        )

        self.assertNotEqual(context_state["urls"][url]["last_fetched_at"], old_fetched_at)
        self.assertNotEqual(context_state["urls"][url]["last_changed_at"], old_fetched_at)


if __name__ == "__main__":
    unittest.main()
