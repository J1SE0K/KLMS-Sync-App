import json
import subprocess
import tempfile
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
                "isExactKlmsHttpsUrl",
                "canDirectFetchKlmsFile",
                "splitFileName",
                "extensionFamily",
                "sanitizeDownloadFilename",
                "isTransientDownloadName",
                "isServerTemporaryFilename",
                "comparableDownloadFilename",
                "withForcedDownload",
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

    def test_direct_fetch_requires_exact_klms_https_origin(self) -> None:
        self.assertEqual(
            self.run_download_filename_helpers(
                "["
                "canDirectFetchKlmsFile('https://klms.kaist.ac.kr/pluginfile.php/1/file.pdf'),"
                "canDirectFetchKlmsFile('http://klms.kaist.ac.kr/pluginfile.php/1/file.pdf'),"
                "canDirectFetchKlmsFile('https://evil.example/?u=klms.kaist.ac.kr/pluginfile.php/1/file.pdf'),"
                "canDirectFetchKlmsFile('https://klms.kaist.ac.kr.evil.example/pluginfile.php/1/file.pdf'),"
                "canDirectFetchKlmsFile('https://klms.kaist.ac.kr@evil.example/pluginfile.php/1/file.pdf')"
                "]"
            ),
            [True, False, False, False, False],
        )

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
        self.assertIn("comparableDownloadFilename", text)
        self.assertIn(".replace(/[\\s.]+$/g, \"\")", text)
        self.assertIn('return "presentation";', text)
        self.assertIn("return expectedFamily === actualFamily;", text)
        self.assertIn("fetchedPayloadCompatibleWithExpected", text)
        self.assertIn("text/html", text)
        self.assertIn("Downloaded filename does not match expected file type", text)
        self.assertIn("quarantineDownloadedFile", text)
        self.assertIn("course_file_quarantine_report.json", text)
        self.assertIn("continueOnQuarantine", text)
        self.assertIn("continueOnDownloadFailure", text)
        self.assertIn("continue-on-download-failure", text)
        self.assertIn("download_failure: true", text)
        self.assertIn("isLoginRequiredDownloadError", text)
        self.assertIn("isInlinePluginPdfDownload", text)
        self.assertIn("browserDownloadProbeSeconds", text)
        self.assertIn("boundedDownloadProbeSeconds(perFileTimeoutSeconds, 20)", text)
        self.assertIn("boundedDownloadProbeSeconds(perFileStartTimeoutSeconds, 10)", text)
        self.assertIn("fetchTimeoutMs = 20000", text)
        self.assertIn("AbortController", text)
        self.assertIn("controller.abort()", text)
        self.assertIn("Promise.race([fetchPromise, timeoutPromise])", text)
        self.assertIn("direct-fetch-timeout", text)
        self.assertIn("quarantined: true", text)
        self.assertIn("failed: true", text)
        self.assertIn("copyFreshDownloadToInbox", text)
        self.assertIn("KLMS New Files", text)
        self.assertIn("preserveOrRemoveDownloadedCopy", text)
        self.assertIn("preserveDownloadArchive", text)
        self.assertIn("buildPreviousDownloadStateIndex", text)
        self.assertIn("existingFileRefreshDecision", text)
        self.assertIn("local-klms-timestamp-current", text)
        self.assertIn("local-file-mtime-matches-klms-timestamp", text)
        self.assertIn("klms-timestamp-newer-than-previous-record", text)
        self.assertIn("reusableRelativePathKey", text)
        self.assertIn("klms-timestamp-newer-than-local-file", text)
        self.assertIn("refreshed_existing_file", text)
        self.assertIn("dateValue instanceof Date", text)
        self.assertIn("previousDownloadResult", text)
        self.assertIn("mergeDownloadHistories", text)
        self.assertIn("resolveCachedDirectResource", text)
        self.assertIn("downloadFile\\('([^']+)'\\s*,\\s*'([^']+)'\\)", text)
        self.assertIn("nextModuleIndex", text)
        self.assertIn("result.course", text)
        self.assertIn("result.source_url", text)
        self.assertIn("isServerTemporaryFilename", text)
        self.assertIn("canonicalFilenameForDownloadedName", text)

    def test_atomic_copy_preserves_destination_on_staging_failure(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "download_klms_files.js").read_text(
            encoding="utf-8"
        )
        helpers = "\n\n".join(
            self.extract_function(text, name)
            for name in (
                "copyFile",
                "samePath",
                "standardizeOptionalPath",
                "standardizePath",
                "isRegularFile",
                "fileExists",
                "isDirectory",
                "ensureDir",
                "directoryName",
                "joinPath",
                "baseName",
                "fileSize",
                "removeFileIfExists",
                "runProcess",
                "nsDataToString",
                "unwrapError",
            )
        )
        with tempfile.TemporaryDirectory() as tmp:
            helper_script = Path(tmp) / "atomic-copy-test.js"
            fixture_root = Path(tmp) / "fixture"
            helper_script.write_text(
                f"""
ObjC.import("Foundation");
{helpers}
function readText(path) {{
  const error = Ref();
  const value = $.NSString.stringWithContentsOfFileEncodingError(
    $(path), $.NSUTF8StringEncoding, error
  );
  if (!value) throw new Error(`read failed: ${{path}}`);
  return ObjC.unwrap(value);
}}
function writeText(path, value) {{
  const error = Ref();
  if (!$(value).writeToFileAtomicallyEncodingError($(path), true, $.NSUTF8StringEncoding, error)) {{
    throw new Error(`write failed: ${{path}}`);
  }}
}}
function run(argv) {{
  const root = String(argv[0]);
  ensureDir(root);
  const destination = joinPath(root, "destination.txt");
  const source = joinPath(root, "source.txt");
  writeText(destination, "old-value");
  let rejected = false;
  try {{ copyFile(joinPath(root, "missing.txt"), destination); }} catch (_error) {{ rejected = true; }}
  const preserved = readText(destination);
  writeText(source, "new-value");
  copyFile(source, destination);
  const replaced = readText(destination);
  const names = ObjC.deepUnwrap(
    $.NSFileManager.defaultManager.contentsOfDirectoryAtPathError($(root), null)
  );
  return JSON.stringify({{
    rejected,
    preserved,
    replaced,
    temporaryFiles: names.filter((name) => String(name).includes(".klms-tmp-")),
  }});
}}
""",
                encoding="utf-8",
            )
            result = subprocess.run(
                ["/usr/bin/osascript", "-l", "JavaScript", str(helper_script), str(fixture_root)],
                check=True,
                capture_output=True,
                text=True,
            )

        self.assertEqual(
            json.loads(result.stdout),
            {
                "rejected": True,
                "preserved": "old-value",
                "replaced": "new-value",
                "temporaryFiles": [],
            },
        )

    def test_download_filename_matching_ignores_trailing_klms_period(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "download_klms_files.js").read_text(
            encoding="utf-8"
        )
        helpers = "\n\n".join(
            self.extract_function(text, name)
            for name in (
                "splitFileName",
                "extensionFamily",
                "isTransientDownloadName",
                "comparableDownloadFilename",
                "isCandidateFilename",
                "fileExtension",
                "filenameCompatibleWithExpected",
                "freshDownloadFilenameMatchesExpected",
            )
        )
        script = "\n".join(
            [
                "function baseName(path) { return String(path || '').split('/').pop(); }",
                helpers,
                "const actual = '3-1 opt)Russell, Stuart. 2019. Human Compatible (~Chp5).';",
                "const expected = '3-1 opt)Russell, Stuart. 2019. Human Compatible (~Chp5)';",
                "console.log(JSON.stringify({",
                "  candidate: isCandidateFilename(actual, expected),",
                "  compatible: filenameCompatibleWithExpected(actual, expected),",
                "  fresh: freshDownloadFilenameMatchesExpected(actual, expected)",
                "}));",
            ]
        )
        result = subprocess.run(
            ["node", "-e", script],
            check=True,
            capture_output=True,
            text=True,
        )
        payload = json.loads(result.stdout)
        self.assertEqual(payload, {"candidate": True, "compatible": True, "fresh": True})

    def test_existing_file_refresh_uses_previous_record_or_local_mtime(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "download_klms_files.js").read_text(
            encoding="utf-8"
        )
        helpers = "\n\n".join(
            self.extract_function(text, name)
            for name in (
                "stripForcedDownloadFlag",
                "reusableFileKey",
                "reusableUrlKey",
                "reusableRelativePathKey",
                "previousDownloadStateForEntry",
                "normalizedKlmsTimestampEpoch",
                "existingFileRefreshDecision",
            )
        )
        script = "\n".join(
            [
                "const $ = { NSFileModificationDate: 'mtime' };",
                "function fileDateEpoch(path) { return String(path).includes('current') ? 200 : 100; }",
                helpers,
                "const entry = { url: 'https://klms.kaist.ac.kr/mod/resource/view.php?id=1', filename: 'file.pdf', relative_path: 'Course/file.pdf', klms_timestamp_epoch: 200 };",
                "const staleWithoutPrevious = existingFileRefreshDecision(entry, '/tmp/stale.pdf', {});",
                "const matchingPreviousIndex = { [reusableUrlKey(entry.url)]: { filename: 'file.pdf', klms_timestamp_epoch: 200 } };",
                "const matchingPrevious = existingFileRefreshDecision(entry, '/tmp/stale.pdf', matchingPreviousIndex);",
                "const relativePreviousIndex = { [reusableRelativePathKey(entry.relative_path)]: { filename: 'file.pdf', klms_timestamp_epoch: 200 } };",
                "const matchingRelativePrevious = existingFileRefreshDecision({ ...entry, url: 'https://klms.kaist.ac.kr/mod/resource/view.php?id=2' }, '/tmp/stale.pdf', relativePreviousIndex);",
                "const previousIndex = { [reusableUrlKey(entry.url)]: { filename: 'file.pdf', klms_timestamp_epoch: 150 } };",
                "const currentLocal = existingFileRefreshDecision(entry, '/tmp/current.pdf', previousIndex);",
                "const staleWithPrevious = existingFileRefreshDecision(entry, '/tmp/stale.pdf', previousIndex);",
                "console.log(JSON.stringify({ staleWithoutPrevious, matchingPrevious, matchingRelativePrevious, currentLocal, staleWithPrevious }));",
            ]
        )
        result = subprocess.run(
            ["node", "-e", script],
            check=True,
            capture_output=True,
            text=True,
        )
        payload = json.loads(result.stdout)

        self.assertTrue(payload["staleWithoutPrevious"]["refresh"])
        self.assertEqual(payload["staleWithoutPrevious"]["reason"], "klms-timestamp-newer-than-local-file")
        self.assertFalse(payload["matchingPrevious"]["refresh"])
        self.assertEqual(payload["matchingPrevious"]["reason"], "local-klms-timestamp-current")
        self.assertFalse(payload["matchingRelativePrevious"]["refresh"])
        self.assertEqual(
            payload["matchingRelativePrevious"]["reason"],
            "local-klms-timestamp-current",
        )
        self.assertFalse(payload["currentLocal"]["refresh"])
        self.assertEqual(payload["currentLocal"]["reason"], "local-file-mtime-matches-klms-timestamp")
        self.assertTrue(payload["staleWithPrevious"]["refresh"])
        self.assertEqual(
            payload["staleWithPrevious"]["reason"],
            "klms-timestamp-newer-than-previous-record",
        )

    def test_download_wait_is_completion_based_after_download_starts(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "download_klms_files.js").read_text(
            encoding="utf-8"
        )
        wait_block = text[
            text.index("function waitForDownloadedFile")
            : text.index("function freshDownloadFilenameMatchesExpected")
        ]
        refresh_text = (PROJECT_DIR / "bin" / "refresh_course_files.sh").read_text(
            encoding="utf-8"
        )
        runner_text = (PROJECT_DIR / "src" / "sh" / "run_download_files_step.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn('FILE_DOWNLOAD_TIMEOUT_SECONDS="${FILE_DOWNLOAD_TIMEOUT_SECONDS:-0}"', refresh_text)
        self.assertIn("FILE_DOWNLOAD_START_TIMEOUT_SECONDS", refresh_text)
        self.assertIn("FILE_DOWNLOAD_STALL_TIMEOUT_SECONDS", refresh_text)
        self.assertIn('FILE_DOWNLOAD_PARALLELISM="${FILE_DOWNLOAD_PARALLELISM:-3}"', refresh_text)
        self.assertIn("FILE_DIRECT_FETCH_MAX_BYTES", refresh_text)
        self.assertIn("--download-parallelism=$DOWNLOAD_PARALLELISM", runner_text)
        self.assertIn("--direct-fetch-max-bytes=$DIRECT_FETCH_MAX_BYTES", runner_text)
        self.assertIn("prefetchDirectDownloadBatch", text)
        self.assertIn("Safari 다운로드 폴더", (PROJECT_DIR / "docs" / "feature-behavior.md").read_text(encoding="utf-8"))
        self.assertIn("isLargeDirectFetchBatchCandidate", text)
        self.assertIn("waitForDownloadedFile", wait_block)
        self.assertIn("--download-start-timeout=$DOWNLOAD_START_TIMEOUT_SECONDS", runner_text)
        self.assertIn("--download-stall-timeout=$DOWNLOAD_STALL_TIMEOUT_SECONDS", runner_text)
        self.assertIn("const hardDeadline = timeoutSeconds > 0", wait_block)
        self.assertIn("const stallTimeoutSeconds", wait_block)
        self.assertIn("lastProgressSignature", wait_block)
        self.assertIn("lastProgressAt", wait_block)
        self.assertIn("if (activeDownloadCandidates.length > 0 || unstableFinalCandidateSeen)", wait_block)
        self.assertIn("sawActiveDownload = true", wait_block)
        self.assertIn("unstableFinalCandidateSeen", wait_block)
        self.assertIn("stallTimeoutSeconds > 0", wait_block)
        self.assertIn("continue;", wait_block)
        self.assertIn("transientDownloadMatchesExpected", wait_block)
        self.assertIn("Download did not complete", text)

    def test_resource_download_url_uses_redirect_before_forcedownload(self) -> None:
        self.assertEqual(
            self.run_download_filename_helpers(
                "withForcedDownload('https://klms.kaist.ac.kr/mod/resource/view.php?id=1220344')"
            ),
            "https://klms.kaist.ac.kr/mod/resource/view.php?id=1220344&redirect=1&forcedownload=1",
        )
        self.assertEqual(
            self.run_download_filename_helpers(
                "withForcedDownload('https://klms.kaist.ac.kr/pluginfile.php/1/mod_resource/content/1/HW1.pdf')"
            ),
            "https://klms.kaist.ac.kr/pluginfile.php/1/mod_resource/content/1/HW1.pdf?forcedownload=1",
        )

    def test_direct_safari_fetch_does_not_skip_inline_pdf_pluginfiles(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "download_klms_files.js").read_text(
            encoding="utf-8"
        )
        direct_fetch = text[
            text.index("function fetchKlmsFileViaSafari")
            : text.index("function resolveFetchedFilename")
        ]
        binary_fetch = text[
            text.index("function fetchBinaryPayloadViaSafari")
            : text.index("function recoverSynapViewerPdf")
        ]

        self.assertIn("fetchBinaryPayloadViaSafari", direct_fetch)
        self.assertIn("startSafariDirectFetchBatch", binary_fetch)
        self.assertIn("waitForSafariDirectFetchBatch", binary_fetch)
        self.assertIn("clearSafariDirectFetchBatch", binary_fetch)
        self.assertNotIn("xhr.open('GET', targetUrl, false)", binary_fetch)
        self.assertNotIn("\\.pdf$", direct_fetch)
        redirected_block = text[
            text.index("const redirectedDirectUrl")
            : text.index("const viewerUrlHint")
        ]
        self.assertIn("waitForDirectFileUrlFromWindow", redirected_block)
        self.assertIn("navigateTabWithoutFocus(tab, directFetchPage, fileWindowRef)", redirected_block)
        self.assertIn("fetchKlmsFileViaSafari", redirected_block)

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
