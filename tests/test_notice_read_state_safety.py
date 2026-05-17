import re
import shutil
import subprocess
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class NoticeReadStateSafetyTests(unittest.TestCase):
    def test_notice_sync_has_no_stable_autoread_path(self) -> None:
        sources = [
            PROJECT_DIR / "src" / "js" / "sync_klms_notes.js",
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift",
        ]
        forbidden = [
            "autoread",
            "markStableDigestNoticesRead",
            "skipStableOnlyCapture",
            "read_fingerprint = fingerprint",
            "readFingerprint = fingerprint",
        ]

        for source in sources:
            text = source.read_text(encoding="utf-8")
            for token in forbidden:
                with self.subTest(source=source.name, token=token):
                    self.assertNotIn(token, text)

    def test_capture_failure_skips_render_to_preserve_checklists(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )

        self.assertIn("capture-failed-preserve-user-state", text)
        self.assertIn("throw new Error(renderWarningText)", text)

    def test_notice_accessibility_tree_searches_are_cycle_guarded(self) -> None:
        text = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("let axTraversalNodeLimit", text)
        self.assertIn("func axElementKey(_ element: AXUIElement) -> String", text)
        self.assertIn("guard visited.insert(key).inserted", text)
        self.assertIn("findFirst(child, where: predicate, visited: &visited)", text)
        self.assertIn("collectElements(child, where: predicate, visited: &visited, matches: &matches)", text)
        self.assertIn("findMenuItem(named: target, in: child, visited: &visited)", text)

    def test_notice_capture_reads_only_checklist_lines_by_exact_range(self) -> None:
        text = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        capture = text[
            text.index("func capturedChecklistLines") : text.index(
                "func captureChecklistValue", text.index("func capturedChecklistLines")
            )
        ]

        self.assertIn("clampedLineRange", capture)
        self.assertIn("checklistLineMatchesLabel(label, expectedLabel: readChecklistLabel)", capture)
        self.assertIn("checklistLineMatchesLabel(label, expectedLabel: importantChecklistLabel)", capture)
        self.assertIn("range: entry.range", capture)
        self.assertNotIn("range: fullRange", capture)

    def test_notice_capture_uses_full_attributed_text_for_checklist_prefixes(self) -> None:
        text = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        caller = text[
            text.index("let allChecklistLines = capturedChecklistLines") : text.index(
                "let capturedBlocks =", text.index("let allChecklistLines = capturedChecklistLines")
            )
        ]

        self.assertIn("attributedText: attributedString", caller)
        self.assertIn("LineRange(location: 0, length: textLength)", caller)

    def test_notice_capture_allows_plaintext_drift_when_all_titles_resolve(self) -> None:
        text = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("resolvedTitleCount == renderedTitles.count", text)
        self.assertIn("Proceeding capture despite plaintext drift", text)
        self.assertIn("resolved_titles=\\(resolvedTitleCount)/\\(renderedTitles.count)", text)

    def test_archive_capture_cannot_create_read_state(self) -> None:
        text = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("displayMode == .primary && readChecked", text)
        self.assertIn("displayMode == .archive && readChecked", text)
        self.assertIn("plaintextHash(for: currentText) != expectedPlaintextHash", text)

    def test_archive_capture_can_create_important_state(self) -> None:
        text = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("displayMode == .primary || displayMode == .archive", text)
        self.assertIn("state.important = importantChecked", text)
        self.assertIn("suspiciousImportantThreshold", text)
        self.assertIn("importantTrueCount >= suspiciousImportantThreshold", text)
        self.assertIn("capture-failed-preserve-user-state: suspicious bulk", text)
        self.assertNotIn("ignoring archive important=true capture", text)
        self.assertNotIn("ignoring archive important=false capture", text)

    def test_large_notice_render_uses_rich_paste_and_optional_format_menu_styles(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        support = (
            PROJECT_DIR / "src" / "swift" / "notice_native_note_support.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("html: html, attributedText: attributed", renderer)
        self.assertIn("font-size:\\(cssFontSize(line.fontSize))pt", renderer)
        self.assertIn("NSFont.boldSystemFont(ofSize: line.fontSize)", renderer)
        self.assertIn("uiStyleMenuFormattingEnabled", renderer)
        self.assertIn('NOTICE_NATIVE_ENABLE_UI_STYLE_FORMAT', support)
        self.assertIn('NOTICE_NATIVE_DISABLE_UI_STYLE_FORMAT', support)
        self.assertNotIn('NOTICE_NATIVE_ENABLE_UI_STYLE_FALLBACK"] == "1"', renderer)
        self.assertIn('menuItems: ["제목", "Title"]', renderer)
        self.assertIn('menuItems: ["머리말", "Heading"]', renderer)
        self.assertIn('menuItems: ["부머리말", "Subheading"]', renderer)
        self.assertIn("reason=rich_paste_default", renderer)
        self.assertIn("readability_validation_targets_finish", renderer)

    def test_notice_render_batches_adjacent_checklist_lines(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        support = (
            PROJECT_DIR / "src" / "swift" / "notice_native_note_support.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("batchChecklistFormattingEnabled", support)
        self.assertIn("fastBatchChecklistFormattingEnabled", support)
        self.assertIn("NOTICE_NATIVE_ENABLE_BATCH_CHECKLIST_FORMAT", support)
        self.assertIn("NOTICE_NATIVE_DISABLE_BATCH_CHECKLIST_FORMAT", support)
        self.assertIn("NOTICE_NATIVE_DISABLE_FAST_CHECKLIST_FORMAT", support)
        self.assertIn("styleVersion = \"style_version\"", support)
        self.assertIn("checklistPairSelectionRange", renderer)
        self.assertIn("checklist_format_batch_start", renderer)
        self.assertIn("fallbackRanges.append(resolved.readRange)", renderer)
        self.assertIn("styleVersion: nativeNoticeRenderStyleVersion", renderer)

    def test_archive_empty_state_uses_guidance_copy(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        support = (
            PROJECT_DIR / "src" / "swift" / "notice_native_note_support.swift"
        ).read_text(encoding="utf-8")

        self.assertNotIn("확인한 공지가 없어.", renderer)
        self.assertNotIn("표시할 공지가 없습니다.", renderer)
        self.assertIn("noticeArchiveEmptyGuidanceLine", renderer)
        self.assertIn(
            '\\"읽음\\"만 체크한 공지는 다음 동기화 때 KLMS 확인한 공지에 표시됩니다.',
            support,
        )
        self.assertIn(
            '\\"중요\\"를 체크한 공지는 다음 동기화 때 KLMS 공지 상단의 중요 공지에 표시됩니다.',
            support,
        )
        self.assertIn("새 글/수정 글은 새로운 공지에", support)
        self.assertIn(
            '\\"읽음\\"만 체크한 공지는 다음 동기화 때 이 메모에 표시됩니다.',
            support,
        )

    def test_notice_render_assigns_readability_font_hierarchy(self) -> None:
        support = (
            PROJECT_DIR / "src" / "swift" / "notice_native_note_support.swift"
        ).read_text(encoding="utf-8")
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        for token in [
            "noticeDocumentTitleFontSize",
            "noticeSectionHeadingFontSize",
            "noticeCourseHeadingFontSize",
            "noticeItemTitleFontSize",
            "noticeMetaFontSize",
        ]:
            with self.subTest(token=token):
                self.assertIn(token, support)
                self.assertIn(token, renderer)

        self.assertIn(
            "appendLine(noteTitle, bold: true, fontSize: noticeDocumentTitleFontSize)",
            renderer,
        )
        self.assertIn(
            "appendLine(finalTitle, bold: true, fontSize: noticeItemTitleFontSize)",
            renderer,
        )
        self.assertIn("cssFontSize(line.fontSize)", renderer)
        self.assertIn("let noticeBodyFontSize: CGFloat = 14", support)
        self.assertIn("line-height:1.42", renderer)

    def test_notice_format_menu_does_not_toggle_bold_off(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("func missingBoldTargets", renderer)
        self.assertIn("func reinforceMissingBoldTargetsIfNeeded", renderer)
        self.assertIn("func boldBlockTextsContain", renderer)
        self.assertIn("func currentLineRange", renderer)
        self.assertIn('replacingOccurrences(of: "&amp", with: "&")', renderer)
        self.assertIn("bold_reinforce_start", renderer)
        self.assertIn("bold_reinforce_finish", renderer)
        self.assertIn("font-weight\\s*:\\s*(?:bold|bolder|[6-9]00)", renderer)
        self.assertNotIn("applyBold(summaryRange)", renderer)
        self.assertNotIn("applyBold(meta)", renderer)
        self.assertNotIn("applyBold(attachmentHeading)", renderer)

    def test_notice_layout_skips_empty_sections_and_compacts_body_noise(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("func appendPrimarySection", renderer)
        self.assertIn("guard count > 0 else", renderer)
        self.assertIn("noticePrimaryEmptyGuidanceLine", renderer)
        self.assertIn("(?im)^\\s*-{20,}\\s*$", renderer)
        self.assertIn("Original\\s+due|New\\s+due|Original|New|Due", renderer)
        self.assertIn("(?=#{1,6}\\s+)", renderer)
        self.assertIn('"  위치: \\(displayPath)"', renderer)

    def test_notice_header_does_not_dump_all_check_guidance(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertNotIn("func appendNoticeGuidanceBlock", renderer)
        self.assertNotIn('appendLine("체크 안내"', renderer)
        self.assertNotIn("appendNoticeGuidanceBlock(includeFreshGuidance:", renderer)

    def test_notice_category_and_course_headings_are_collapsible_groups(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        support = (
            PROJECT_DIR / "src" / "swift" / "notice_native_note_support.swift"
        ).read_text(encoding="utf-8")
        config = (PROJECT_DIR / "examples" / "config.env.example").read_text(
            encoding="utf-8"
        )

        self.assertIn('environment["NOTICE_COLLAPSE_SECTIONS"] != "0"', support)
        self.assertIn("collapseNoticeCoursesEnabled", support)
        self.assertIn("collapseNoticeItemsEnabled", support)
        self.assertIn("styleNoticeItemsAsHeadingsEnabled", support)
        self.assertIn("uiCollapsibleGroupStyleFormattingEnabled", support)
        self.assertIn("noticeCollapseStyleSettleDelay", support)
        self.assertIn("let mode: NoticeDisplayMode", support)
        self.assertIn("uiCollapsibleGroupStyleFormattingEnabled", renderer)
        self.assertIn("func shouldCollapseNoticeCourses(_ plan: RenderPlan) -> Bool", renderer)
        self.assertIn("func shouldCollapseNoticeItems(_ plan: RenderPlan) -> Bool", renderer)
        self.assertIn("collapseNoticeCoursesEnabled || plan.mode == .archive", renderer)
        self.assertIn("return collapseNoticeItemsEnabled", renderer)
        self.assertIn('menuItems: ["제목", "Title"]', renderer)
        self.assertIn('menuItems: ["머리말", "Heading"]', renderer)
        self.assertIn(
            "if uiStyleMenuFormattingEnabled || styleNoticeItemsAsHeadingsEnabled || effectiveCollapseNoticeItemsEnabled",
            renderer,
        )
        self.assertIn("collapse_heading_retry", renderer)
        self.assertIn("if effectiveCollapseCoursesEnabled", renderer)
        self.assertIn("if effectiveCollapseNoticeItemsEnabled", renderer)
        self.assertIn("collapseHeading(range, label: \"course-\\(offset + 1)\")", renderer)
        self.assertIn("collapseHeading(range, label: \"section-\\(offset + 1)\")", renderer)
        self.assertIn("display_mode=\\(noticeDisplayModeName(plan.mode))", renderer)
        self.assertIn("collapse_courses=\\(shouldCollapseNoticeCourses(plan) ? \"1\" : \"0\")", renderer)
        self.assertIn("collapse_notice_items=\\(shouldCollapseNoticeItems(plan) ? \"1\" : \"0\")", renderer)
        self.assertIn("style_notice_items=\\(styleNoticeItemsAsHeadingsEnabled ? \"1\" : \"0\")", renderer)
        self.assertIn("NOTICE_COLLAPSE_SECTIONS=\"1\"", config)
        self.assertIn("NOTICE_COLLAPSE_COURSES=\"0\"", config)
        self.assertIn("NOTICE_COLLAPSE_NOTICE_ITEMS=\"0\"", config)
        self.assertIn("NOTICE_STYLE_NOTICE_ITEMS_AS_HEADINGS=\"1\"", config)
        self.assertIn("NOTICE_NATIVE_ENABLE_BATCH_CHECKLIST_FORMAT=\"1\"", config)

        collapse_block_index = renderer.index("var collapsedSections = 0")
        notice_index = renderer.index("if effectiveCollapseNoticeItemsEnabled", collapse_block_index)
        course_index = renderer.index("let courseCollapseRanges", collapse_block_index)
        section_index = renderer.index("let sectionCollapseRanges", collapse_block_index)
        self.assertLess(notice_index, course_index)
        self.assertLess(course_index, section_index)

    def test_notice_ui_operations_force_target_note_focus(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("func focusNotesEditor(_ context: NotesEditorContext", renderer)
        self.assertIn("AXUIElementPerformAction(context.window, kAXRaiseAction", renderer)
        self.assertIn("trySetAttr(context.app, kAXFocusedWindowAttribute", renderer)
        self.assertIn("func pressMenuIfAvailable(_ context: NotesEditorContext", renderer)
        self.assertIn("paste(context: context, text: plaintext, html: html, attributedText: attributed)", renderer)
        self.assertIn("ensureChecklistStates(\n        context: context,", renderer)
        self.assertIn("ensureCheckedItemsStayInPlace(\n        context: context,", renderer)
        self.assertIn("notes.selection = [note]", renderer)
        self.assertIn("text areas of entire contents of w", renderer)
        self.assertNotIn("text area 1 of scroll area 3", renderer)
        self.assertNotIn("paste(context.app, text:", renderer)

    def test_archive_notice_note_renders_before_primary(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        js = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )

        self.assertLess(
            js.index('{ key: "archive", args: ["--render-only", "--archive-only"] }'),
            js.index('{ key: "primary", args: ["--render-only", "--primary-only"] }'),
        )
        self.assertLess(
            renderer.index("let archivedCollapsedSections = arguments.target == \"primary\""),
            renderer.index("let collapsedSections = arguments.target == \"archive\""),
        )
        self.assertIn("noticeTargetRequiresPostCaptureRender", js)
        self.assertIn("targetComparison && targetComparison.matches && !mustRenderAfterCapture", js)
        self.assertIn("allowNoOpSkip: false", renderer)

    def test_notice_native_config_is_passed_to_swift_wrapper(self) -> None:
        js = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )

        self.assertIn("function nativeNoticeEnvironment(config)", js)
        self.assertIn('"NOTICE_COLLAPSE_SECTIONS"', js)
        self.assertIn('"NOTICE_COLLAPSE_COURSES"', js)
        self.assertIn('"NOTICE_NATIVE_ENABLE_BATCH_CHECKLIST_FORMAT"', js)
        self.assertIn('"NOTICE_STYLE_NOTICE_ITEMS_AS_HEADINGS"', js)
        self.assertIn('"NOTICE_NATIVE_DISABLE_FAST_CHECKLIST_FORMAT"', js)
        self.assertIn("noticeNativeEnvironment", js)
        self.assertIn("...nativeEnv", js)

    def test_notice_prebuild_warning_does_not_fail_core_sync(self) -> None:
        js = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )
        prebuild = js[
            js.index('beginStage(steps, stageTelemetry, "notice-summary-prebuild")') :
            js.index('debugStderr("after notice-summary-prebuild")')
        ]

        self.assertIn("notice-summary-prebuild warning ignored", prebuild)
        self.assertNotIn("throw noticeError", prebuild)

    def test_notice_summary_failure_restores_previous_notice_cache(self) -> None:
        js = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )
        prebuild = js[
            js.index('beginStage(steps, stageTelemetry, "notice-summary-prebuild")') :
            js.index('debugStderr("after notice-summary-prebuild")')
        ]
        final_summary = js[
            js.index('beginStage(steps, stageTelemetry, "notice-summary");') :
            js.index("completeStageTelemetry(stageTelemetry", js.index('beginStage(steps, stageTelemetry, "notice-summary");'))
        ]

        self.assertIn("const noticeSnapshot = snapshotFiles", prebuild)
        self.assertIn("restoreFileSnapshot(noticeSnapshot)", prebuild)
        self.assertIn("const noticeSnapshot = snapshotFiles", final_summary)
        self.assertIn("restoreFileSnapshot(noticeSnapshot)", final_summary)

    def test_core_notice_prebuild_skips_native_render_and_restores_cache_after_build_note(self) -> None:
        js = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )
        prebuild = js[
            js.index('beginStage(steps, stageTelemetry, "notice-summary-prebuild")') :
            js.index('debugStderr("after notice-summary-prebuild")')
        ]
        build_note = js[
            js.index('beginStage(steps, stageTelemetry, "build-note")') :
            js.index('debugStderr("after build-note")')
        ]
        sync_notice_summary = js[
            js.index("function syncNoticeSummary") :
            js.index("function classifyNoticeRenderError")
        ]

        self.assertIn("skipNativeRender: true", prebuild)
        self.assertIn("noticeSummaryPrebuildSnapshot = noticeSnapshot", prebuild)
        self.assertIn("finally", build_note)
        self.assertIn("restoreFileSnapshot(noticeSummaryPrebuildSnapshot)", build_note)
        self.assertIn("paths.skipNativeRender", sync_notice_summary)
        self.assertIn('reason: "prebuild"', sync_notice_summary)

    def test_notice_style_version_is_shared_between_swift_and_js(self) -> None:
        support = (
            PROJECT_DIR / "src" / "swift" / "notice_native_note_support.swift"
        ).read_text(encoding="utf-8")
        js = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )

        swift_match = re.search(r'nativeNoticeRenderStyleVersion = "([^"]+)"', support)
        js_match = re.search(r'NATIVE_NOTICE_RENDER_STYLE_VERSION = "([^"]+)"', js)
        self.assertIsNotNone(swift_match)
        self.assertIsNotNone(js_match)
        self.assertEqual(swift_match.group(1), js_match.group(1))

    def test_swift_process_capture_does_not_pipe_large_outputs(self) -> None:
        text = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        run_process = text[
            text.index("func runProcessResult") : text.index(
                "func runProcessOutput", text.index("func runProcessResult")
            )
        ]

        self.assertIn("FileManager.default.temporaryDirectory", run_process)
        self.assertIn("FileHandle(forWritingTo:", run_process)
        self.assertNotIn("Pipe()", run_process)
        self.assertNotIn("readDataToEndOfFile", run_process)

    def test_stable_noop_verifies_notice_readability_format(self) -> None:
        text = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )

        stable_noop_index = text.index("stable-noop-after-capture")
        verify_index = text.index("verifyNoticeNativeNoteReadableFormat")
        self.assertLess(verify_index, stable_noop_index)
        self.assertIn("readability-format-check-failed", text)
        self.assertIn("Native notice note readability format missing", text)
        self.assertIn("noteReadableStyleMetricsViaAppleScript", text)
        self.assertIn("font_size_tags", text)
        self.assertIn("heading_tags", text)
        self.assertIn("large_font_tags", text)
        self.assertIn("minimumLargeFontTags", text)
        self.assertIn('targetKey === "primary" ? 20 : 1', text)
        self.assertIn("NATIVE_NOTICE_RENDER_STYLE_VERSION", text)
        self.assertIn("noticeRenderStyleVersion", text)
        self.assertIn("style_version", text)
        self.assertNotIn("return body of note", text)

    def test_notice_capture_short_circuits_after_expand_all_when_complete(self) -> None:
        text = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("func captureTextContainsExpectedNotices", text)
        self.assertIn("normalizedTitles.allSatisfy", text)
        self.assertIn("skipping per-notice expansion", text)
        self.assertLess(
            text.index("captureTextContainsExpectedNotices("),
            text.index("for rendered in previousRenderState.renderedNotices.reversed()"),
        )

    def test_supplemental_detail_quick_limit_respects_cached_pages(self) -> None:
        js = (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(
            encoding="utf-8"
        )
        config = (PROJECT_DIR / "examples" / "config.env.example").read_text(
            encoding="utf-8"
        )

        self.assertIn("function cachedPageRequestedUrls", js)
        self.assertIn("...cachedPageRequestedUrls(supplementalDetailPagesJson)", js)
        self.assertIn("SYNC_SUPPLEMENTAL_DETAIL_PINNED_QUICK_LIMIT", js)
        self.assertIn("supplementalDetailPinnedQuickLimit", js)
        self.assertIn('SYNC_SUPPLEMENTAL_DETAIL_PINNED_QUICK_LIMIT="0"', config)

    def test_stable_noop_expected_state_uses_native_notice_order(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("node is not installed")

        script = r"""
const fs = require("fs");
const path = "src/js/sync_klms_notes.js";
const source = fs.readFileSync(path, "utf8");

function extractFunction(name) {
  const marker = `function ${name}(`;
  const start = source.indexOf(marker);
  if (start < 0) throw new Error(`missing ${name}`);
  const bodyStart = source.indexOf("{", start);
  let depth = 0;
  for (let index = bodyStart; index < source.length; index += 1) {
    const char = source[index];
    if (char === "{") depth += 1;
    if (char === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(start, index + 1);
    }
  }
  throw new Error(`unterminated ${name}`);
}

eval([
  extractFunction("expectedNoticeNativeRenderState"),
  extractFunction("noticeIdentifierForDigestNotice"),
  extractFunction("oneLineText"),
].join("\n"));

const digest = {
  courses: [
    {
      course: "Course A",
      notices: [
        { url: "stable-1", fingerprint: "fp-stable", change_state: "stable" },
        { url: "important-1", fingerprint: "fp-important", change_state: "stable" },
        { url: "fresh-1", fingerprint: "fp-fresh", change_state: "new" },
        { url: "read-1", fingerprint: "fp-read", change_state: "stable" },
      ],
    },
  ],
};
const userState = {
  notices: {
    "important-1": { important: true },
    "read-1": { read_fingerprint: "fp-read" },
  },
};

const expected = expectedNoticeNativeRenderState(digest, userState);
console.log(JSON.stringify({
  primary: expected.primary.map((notice) => notice.notice_id),
  archive: expected.archive.map((notice) => notice.notice_id),
}));
"""
        result = subprocess.run(
            [node, "-e", script],
            cwd=PROJECT_DIR,
            text=True,
            check=True,
            capture_output=True,
        )

        self.assertEqual(
            result.stdout.strip(),
            '{"primary":["important-1","fresh-1","stable-1"],"archive":["read-1"]}',
        )


if __name__ == "__main__":
    unittest.main()
