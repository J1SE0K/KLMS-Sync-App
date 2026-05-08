import json
import subprocess
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class DownloadFilenameSafetyTests(unittest.TestCase):
    def run_download_filename_helpers(self, expression: str):
        text = (PROJECT_DIR / "src" / "js" / "download_klms_files.js").read_text(
            encoding="utf-8"
        )
        helpers = "\n\n".join(
            self.extract_function(text, name)
            for name in (
                "splitFileName",
                "extensionFamily",
                "sanitizeDownloadFilename",
                "isTransientDownloadName",
                "isServerTemporaryFilename",
                "canonicalExpectedFilenameForTemporaryDownload",
                "canonicalFilenameForDownloadedName",
            )
        )
        script = "\n".join(
            [
                "function baseName(path) { return String(path || '').split('/').pop(); }",
                helpers,
                f"console.log(JSON.stringify({expression}));",
            ]
        )
        result = subprocess.run(
            ["node", "-e", script],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(result.stdout)

    def extract_function(self, text: str, name: str) -> str:
        marker = f"function {name}("
        start = text.index(marker)
        brace = text.index("{", start)
        depth = 0
        for index in range(brace, len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    return text[start : index + 1]
        raise AssertionError(f"Could not extract {name}")

    def test_logged_filename_reuse_rejects_cross_source_ambiguous_names(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "download_klms_files.js").read_text(
            encoding="utf-8"
        )

        self.assertIn("ambiguousRecordedFilenames", text)
        self.assertIn("downloadLogFilenameReuseAllowed", text)
        self.assertIn("filenameCompatibleWithExpected", text)
        self.assertIn("freshDownloadFilenameMatchesExpected", text)
        self.assertIn('expectedFamily === "presentation"', text)
        self.assertIn("fetchedPayloadCompatibleWithExpected", text)
        self.assertIn("text/html", text)
        self.assertIn("Downloaded filename does not match expected file type", text)
        self.assertIn("quarantineDownloadedFile", text)
        self.assertIn("course_file_quarantine_report.json", text)
        self.assertIn("copyFreshDownloadToInbox", text)
        self.assertIn("KLMS New Files", text)
        self.assertIn("result.course", text)
        self.assertIn("result.source_url", text)
        self.assertIn("isServerTemporaryFilename", text)
        self.assertIn("canonicalFilenameForDownloadedName", text)

    def test_server_temp_download_name_uses_manifest_stem_and_downloaded_extension(self) -> None:
        payload = self.run_download_filename_helpers(
            """[
                isServerTemporaryFilename("Lec 1_temp.pptx"),
                isServerTemporaryFilename("attempt.pdf"),
                canonicalFilenameForDownloadedName("Lec 1_temp.pptx", "Lecture 1 slide.ppt"),
                canonicalFilenameForDownloadedName("Lec 1_temp.pptx", "Lec 1_temp.pptx", {link_text: "Lecture 1 slide"}),
                canonicalFilenameForDownloadedName("Lec 2.pptx", "Lecture 2 slides.ppt")
            ]"""
        )

        self.assertEqual(
            payload,
            [
                True,
                False,
                "Lecture 1 slide.pptx",
                "Lecture 1 slide.pptx",
                "Lec 2.pptx",
            ],
        )


if __name__ == "__main__":
    unittest.main()
