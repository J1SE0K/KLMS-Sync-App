import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class SafariApplicationBindingTests(unittest.TestCase):
    def test_fetcher_binds_running_safari_by_name(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "fetch_pages_with_safari.js").read_text(
            encoding="utf-8"
        )

        self.assertIn('const safari = Application("Safari")', text)
        self.assertNotIn('Application("/Applications/Safari.app")', text)

    def test_fetcher_rejects_external_xhr_and_navigation_final_urls(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "fetch_pages_with_safari.js").read_text(
            encoding="utf-8"
        )

        self.assertIn("!isExactKlmsHttpsUrl(navigationPage.url)", text)
        self.assertIn("!isExactKlmsHttpsUrl(page && page.url)", text)
        self.assertIn("!isExactKlmsHttpsUrl(payload.url)", text)


if __name__ == "__main__":
    unittest.main()
