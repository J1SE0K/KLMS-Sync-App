import json
import subprocess
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
DOWNLOAD_SCRIPT = PROJECT_DIR / "src" / "js" / "download_klms_files.js"


class SafariDirectFetchStateTests(unittest.TestCase):
    @staticmethod
    def extract_function(text: str, name: str) -> str:
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

    def run_probe(self, expression: str, function_names: tuple[str, ...]) -> dict[str, object]:
        text = DOWNLOAD_SCRIPT.read_text(encoding="utf-8")
        functions = "\n\n".join(
            self.extract_function(text, name) for name in function_names
        )
        script = "\n".join(
            [
                'const vm = require("vm");',
                'const payload = "x".repeat(1024);',
                "const window = {__klmsDirectFetchBatches: {batch: {",
                "  status: 'done', startedAt: 10, finishedAt: 20, error: '',",
                "  results: [{index: 12, ok: true, base64: payload}, {index: 13, ok: true, base64: payload}]",
                "}}};",
                "function runSafariJavaScript(_windowRef, source) {",
                "  return vm.runInNewContext(source, {window, JSON});",
                "}",
                functions,
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

    def test_batch_poll_returns_only_small_progress_metadata(self) -> None:
        payload = self.run_probe(
            "readSafariDirectFetchBatch({}, 'batch')",
            ("readSafariDirectFetchBatch",),
        )

        self.assertEqual(payload["status"], "done")
        self.assertEqual(payload["resultCount"], 2)
        self.assertNotIn("results", payload)
        self.assertLess(len(json.dumps(payload)), 512)

    def test_batch_result_reader_transfers_one_payload_at_a_time(self) -> None:
        payload = self.run_probe(
            "readSafariDirectFetchBatch({}, 'batch', 12)",
            ("readSafariDirectFetchBatch",),
        )

        self.assertEqual(payload["index"], 12)
        self.assertTrue(payload["ok"])
        self.assertEqual(len(payload["base64"]), 1024)

    def test_batch_waits_for_page_readiness_before_starting(self) -> None:
        text = DOWNLOAD_SCRIPT.read_text(encoding="utf-8")
        function = self.extract_function(text, "prefetchDirectDownloadBatch")
        page_url = "https://klms.kaist.ac.kr/course/view.php?id=1"
        script = "\n".join(
            [
                "let ready = false; const calls = [];",
                "function collectDirectFetchBatchItems() { return [{index: 0, url: 'https://klms.kaist.ac.kr/pluginfile.php/1/file.pdf', expectedFilename: 'file.pdf'}]; }",
                "function waitForHtmlDocumentReady(_windowRef, _timeout, expectedUrl) { ready = true; calls.push(`ready:${expectedUrl}`); return true; }",
                "function startSafariDirectFetchBatch() { calls.push('start'); return {ok: true}; }",
                "function waitForSafariDirectFetchBatch() { return ready ? {status: 'done', resultCount: 1} : {status: 'timeout', resultCount: 0}; }",
                "function readSafariDirectFetchBatch() { return {index: 0, ok: true, base64: 'eA=='}; }",
                "function clearSafariDirectFetchBatch() {}",
                "function fetchedPayloadCompatibleWithExpected() { return true; }",
                "function resolveFetchedFilename() { return 'file.pdf'; }",
                "function joinPath(...parts) { return parts.join('/'); }",
                "function sanitizeFileComponent(value) { return value; }",
                "function baseName(value) { return value.split('/').pop(); }",
                "function ensureDir() {}",
                "function writeBase64File() {}",
                "function isRegularFile() { return true; }",
                "function fileSize() { return 1; }",
                function,
                f"const downloads = prefetchDirectDownloadBatch({{}}, [{{}}], 0, {{backupRoot: '/tmp', directFetchMaxBytes: 1, directFetchBatchTimeoutSeconds: 1, expectedPageUrl: '{page_url}'}});",
                "console.log(JSON.stringify({calls, downloadCount: Object.keys(downloads).length}));",
            ]
        )

        result = subprocess.run(
            ["node", "-e", script],
            check=True,
            capture_output=True,
            text=True,
        )
        payload = json.loads(result.stdout)

        self.assertEqual(payload["calls"], [f"ready:{page_url}", "start"])
        self.assertEqual(payload["downloadCount"], 1)

    def test_page_readiness_rejects_complete_previous_document(self) -> None:
        text = DOWNLOAD_SCRIPT.read_text(encoding="utf-8")
        function = self.extract_function(text, "getHtmlDocumentReadyState")
        script = "\n".join(
            [
                'const vm = require("vm");',
                "const document = {readyState: 'complete', body: {}, title: 'Old', location: {href: 'https://klms.kaist.ac.kr/course/view.php?id=old'}};",
                "function runSafariJavaScript(_windowRef, source) { return vm.runInNewContext(source, {document, JSON}); }",
                function,
                "const state = getHtmlDocumentReadyState({}, 'https://klms.kaist.ac.kr/course/view.php?id=new');",
                "console.log(JSON.stringify(state));",
            ]
        )

        result = subprocess.run(
            ["node", "-e", script],
            check=True,
            capture_output=True,
            text=True,
        )
        payload = json.loads(result.stdout)

        self.assertFalse(payload["ready"])

    def test_batch_wait_stops_when_navigation_erases_its_state(self) -> None:
        text = DOWNLOAD_SCRIPT.read_text(encoding="utf-8")
        function = self.extract_function(text, "waitForSafariDirectFetchBatch")
        script = "\n".join(
            [
                "let now = 0; let readCount = 0;",
                "const Date = {now() { now += 1000; return now; }};",
                "function delay() {}",
                "function readSafariDirectFetchBatch() { readCount += 1; return {status: 'missing', resultCount: 0}; }",
                function,
                "const state = waitForSafariDirectFetchBatch({}, 'batch', 5);",
                "console.log(JSON.stringify({state, readCount}));",
            ]
        )

        result = subprocess.run(
            ["node", "-e", script],
            check=True,
            capture_output=True,
            text=True,
        )
        payload = json.loads(result.stdout)

        self.assertEqual(payload["state"]["status"], "missing")
        self.assertEqual(payload["readCount"], 1)

    def test_reusable_page_does_not_reload_the_current_document(self) -> None:
        text = DOWNLOAD_SCRIPT.read_text(encoding="utf-8")
        function = self.extract_function(text, "openReusableDownloadPage")
        page_url = "https://klms.kaist.ac.kr/course/view.php?id=1"
        script = "\n".join(
            [
                "const calls = []; const windowRef = {currentTab() { return {}; }};",
                "function safariBackgroundWindowEnabled() { return false; }",
                "function safariReuseExistingWindowEnabled() { return false; }",
                "function reusableWindowByReference() { return windowRef; }",
                "function findKlmsWindow() { return null; }",
                "function findReusableEmptyWindow() { return null; }",
                "function createSafariWindow() { throw new Error('unexpected create'); }",
                "function prepareBackgroundWindow() {}",
                "function safeValue(getter) { try { return getter(); } catch (_error) { return null; } }",
                f"function currentTabUrl() {{ return '{page_url}'; }}",
                "function navigateTabWithoutFocus() { calls.push('navigate'); }",
                "function waitForWindowUrl() { calls.push('wait'); }",
                "const safariLaunchedByScript = false;",
                function,
                f"openReusableDownloadPage({{}}, windowRef, '{page_url}');",
                "console.log(JSON.stringify(calls));",
            ]
        )

        result = subprocess.run(
            ["node", "-e", script],
            check=True,
            capture_output=True,
            text=True,
        )

        self.assertEqual(json.loads(result.stdout), [])


if __name__ == "__main__":
    unittest.main()
