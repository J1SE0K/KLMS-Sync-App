import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


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

    def test_fallback_url_suppresses_always_fetch_probe(self) -> None:
        url = "https://klms.kaist.ac.kr/mod/courseboard/view.php?id=1"
        page = {"requestedUrl": url, "html": "<html>fresh fallback</html>"}

        selected = fetch_pages_backend.choose_urls_to_fetch(
            urls=[url],
            previous_lookup={url: page},
            context_state={"urls": {}},
            mode="quick",
            quick_limit=0,
            stale_seconds=3600,
            always_fetch_min_interval_seconds=0,
            always_fetch_patterns=[r"/mod/courseboard/view\.php"],
            fallback_url_set={url},
            probe_order="index",
        )

        self.assertEqual(selected, [])

    def test_complete_recent_cached_pages_reuses_full_url_set(self) -> None:
        url = "https://klms.kaist.ac.kr/course/view.php?id=1"
        page = {"requestedUrl": url, "html": "<html>cached</html>"}

        reused = fetch_pages_backend.complete_recent_cached_pages(
            urls=[url],
            previous_lookup={url: page},
            context_state={"last_run_at": fetch_pages_backend.now_utc_iso()},
            max_age_seconds=900,
        )

        self.assertEqual(reused, [page])

    def test_complete_recent_cached_pages_requires_every_url(self) -> None:
        url = "https://klms.kaist.ac.kr/course/view.php?id=1"

        reused = fetch_pages_backend.complete_recent_cached_pages(
            urls=[url],
            previous_lookup={},
            context_state={"last_run_at": fetch_pages_backend.now_utc_iso()},
            max_age_seconds=900,
        )

        self.assertIsNone(reused)

    def test_reusable_pages_match_existing_output_requires_same_order_and_objects(self) -> None:
        first_url = "https://klms.kaist.ac.kr/course/view.php?id=1"
        second_url = "https://klms.kaist.ac.kr/course/view.php?id=2"
        first_page = {"requestedUrl": first_url, "html": "<html>1</html>"}
        second_page = {"requestedUrl": second_url, "html": "<html>2</html>"}

        self.assertTrue(
            fetch_pages_backend.reusable_pages_match_existing_output(
                [first_url, second_url],
                [first_page, second_page],
                [first_page, second_page],
            )
        )
        self.assertFalse(
            fetch_pages_backend.reusable_pages_match_existing_output(
                [first_url, second_url],
                [first_page, second_page],
                [second_page, first_page],
            )
        )
        self.assertFalse(
            fetch_pages_backend.reusable_pages_match_existing_output(
                [first_url],
                [{"requestedUrl": first_url, "html": "<html>fallback</html>"}],
                [first_page],
            )
        )

    def test_default_safari_batch_size_matches_xhr_batch_limit(self) -> None:
        text = (PROJECT_DIR / "src" / "python" / "fetch_pages_backend.py").read_text(
            encoding="utf-8"
        )
        safari_text = (PROJECT_DIR / "src" / "js" / "fetch_pages_with_safari.js").read_text(
            encoding="utf-8"
        )

        self.assertIn('KLMS_FETCH_SAFARI_BATCH_SIZE") or "20"', text)
        self.assertIn("urls.length <= 20", safari_text)

    def test_recent_empty_fetch_summary_suppresses_immediate_retry(self) -> None:
        url = "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=2"
        with tempfile.TemporaryDirectory() as tmp:
            summary_path = Path(tmp) / "summary.json"
            summary_path.write_text(
                json.dumps(
                    {
                        "finished_at": fetch_pages_backend.now_utc_iso(),
                        "total_urls": 1,
                        "fetched_urls": 0,
                        "missing_urls": 1,
                        "selected_url_list": [url],
                    }
                ),
                encoding="utf-8",
            )

            summary = fetch_pages_backend.recent_empty_fetch_summary(
                summary_path=summary_path,
                urls=[url],
                max_age_seconds=900,
            )

        self.assertIsNotNone(summary)

    def test_require_all_ignores_recent_empty_fetch_summary(self) -> None:
        url = "https://klms.kaist.ac.kr/my/"
        page = {"requestedUrl": url, "url": url, "title": "KLMS", "html": "<html>ok</html>"}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out_path = root / "dashboard.json"
            state_path = root / "fetch_state.json"
            summary_path = root / "summary.json"
            summary_path.write_text(
                json.dumps(
                    {
                        "finished_at": fetch_pages_backend.now_utc_iso(),
                        "total_urls": 1,
                        "fetched_urls": 0,
                        "missing_urls": 1,
                        "selected_url_list": [url],
                    }
                ),
                encoding="utf-8",
            )

            with mock.patch.object(
                fetch_pages_backend,
                "fetch_pages_with_safari",
                return_value=[page],
            ) as fetch_mock:
                with mock.patch(
                    "sys.argv",
                    [
                        "fetch_pages_backend.py",
                        "--backend=safari",
                        "--mode=full",
                        "--context=sync-dashboard",
                        "--out",
                        str(out_path),
                        "--cache-state",
                        str(state_path),
                        "--summary-out",
                        str(summary_path),
                        "--complete-reuse-seconds=900",
                        "--require-all",
                        url,
                    ],
                ):
                    status = fetch_pages_backend.main()

            self.assertEqual(status, 0)
            self.assertTrue(fetch_mock.called)
            self.assertEqual(json.loads(out_path.read_text(encoding="utf-8")), [page])

    def test_require_all_missing_pages_fails_without_overwriting_previous_output(self) -> None:
        url = "https://klms.kaist.ac.kr/my/"
        previous_payload = [{"requestedUrl": url, "url": url, "title": "", "html": ""}]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out_path = root / "dashboard.json"
            state_path = root / "fetch_state.json"
            summary_path = root / "summary.json"
            out_path.write_text(json.dumps(previous_payload), encoding="utf-8")

            with mock.patch.object(
                fetch_pages_backend,
                "fetch_pages_with_safari",
                return_value=[],
            ):
                with mock.patch(
                    "sys.argv",
                    [
                        "fetch_pages_backend.py",
                        "--backend=safari",
                        "--mode=full",
                        "--context=sync-dashboard",
                        "--out",
                        str(out_path),
                        "--cache-state",
                        str(state_path),
                        "--summary-out",
                        str(summary_path),
                        "--require-all",
                        url,
                    ],
                ):
                    status = fetch_pages_backend.main()

            self.assertEqual(status, 2)
            self.assertEqual(json.loads(out_path.read_text(encoding="utf-8")), previous_payload)
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertEqual(summary["status"], "error")
            self.assertEqual(summary["error"], "missing-required-pages")
            self.assertEqual(summary["missing_url_list"], [url])

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
