import re
import shutil
import subprocess
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


def read_notice_js() -> str:
    return "\n".join(
        [
            (PROJECT_DIR / "src" / "js" / "sync_klms_notes.js").read_text(encoding="utf-8"),
            (PROJECT_DIR / "src" / "js" / "sync_notice_bridge.js").read_text(encoding="utf-8"),
        ]
    )


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
        text = read_notice_js()

        self.assertIn("capture-failed-preserve-user-state", text)
        self.assertIn("nativeNoticeCaptureFailureCanRenderWithPreservedState", text)
        self.assertIn("capture-state-preserved", text)
        self.assertIn("noticeRenderWarningsAreNonFatal", text)
        self.assertIn("noticeRenderWarningIsRecoverable", text)
        self.assertIn("if (renderWarningText && !nonFatalRenderWarning)", text)
        self.assertIn('summary.status = "warn"', text)

    def test_suspicious_capture_drop_renders_with_preserved_state(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("node is not installed")

        script = r"""
const fs = require("fs");
const source = fs.readFileSync("src/js/sync_notice_bridge.js", "utf8");

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
  extractFunction("nativeNoticeEnvHasKey"),
  extractFunction("nativeNoticeDefaultEnvironment"),
  extractFunction("nativeNoticeVerifyStableSkipFormatEnabled"),
  extractFunction("nativeNoticePostRenderVerifyEnabled"),
  extractFunction("nativeNoticeEnvironmentEnabled"),
  extractFunction("nativeNoticeEnvironmentValue"),
  extractFunction("noticeTargetRequiresPostCaptureRender"),
  extractFunction("nativeNoticeCaptureFailureCanRenderWithPreservedState"),
  extractFunction("updateNoticeNativeNote"),
].join("\n"));

let calls = [];
function debugStderr() {}
function runNativeNoticeCommandWithRecoverableRetry(stageTelemetry, target, command) {
  calls.push(target);
  if (target === "capture") {
    throw new Error("capture-failed-preserve-user-state: suspicious read state drop before=67 after=0 captured_ids=69");
  }
  return `rendered ${target}`;
}
function verifyNoticeNativeNoteReadableFormat() {
  return "";
}

const result = updateNoticeNativeNote(
  "/engine",
  "KLMS 공지",
  "KLMS 확인한 공지",
  "/digest.json",
  "/notice_state.json",
  "/primary_render_state.json",
  "/archive_render_state.json",
  false,
  true,
  false,
  false,
  [],
  null
);

console.log(JSON.stringify({
  calls,
  preserved: result.results.some((item) => item.target === "capture-state-preserved"),
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
            '{"calls":["capture","archive","primary"],"preserved":true}',
        )

    def test_notice_render_summary_is_cleared_on_skipped_paths(self) -> None:
        text = read_notice_js()

        self.assertIn("paths.noticeRenderErrorSummaryJson", text)
        self.assertIn('JSON.stringify({ status: "ok" }, null, 2)', text)
        self.assertIn("JSON.stringify(classifyNoticeRenderError(String(noticeError)), null, 2)", text)

    def test_notes_focus_render_warning_is_nonfatal(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("node is not installed")

        script = r"""
const fs = require("fs");
const source = fs.readFileSync("src/js/sync_notice_bridge.js", "utf8");

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
  extractFunction("noticeRenderWarningsAreNonFatal"),
  extractFunction("noticeRenderWarningIsRecoverable"),
  extractFunction("classifyNoticeRenderError"),
].join("\n"));

function envValue() { return ""; }
const warning = "Native notice note render warning (archive): Error: Could not confirm the cursor is in the target Notes note: KLMS 확인한 공지";
const nonfatal = noticeRenderWarningsAreNonFatal({
  results: [{ target: "archive", status: "warning", error: warning }],
});
const summary = classifyNoticeRenderError(warning);
envValue = (key) => key === "KLMS_APP_RUN" ? "1" : "";
const appNonfatal = noticeRenderWarningsAreNonFatal({
  results: [{ target: "archive", status: "warning", error: warning }],
});
console.log(JSON.stringify({ nonfatal, appNonfatal, code: summary.code }));
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
            '{"nonfatal":true,"appNonfatal":false,"code":"notes_focus_unconfirmed"}',
        )

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

    def test_archive_capture_can_restore_read_state(self) -> None:
        text = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("if readChecked", text)
        self.assertIn("state.readFingerprint = rendered.fingerprint", text)
        self.assertIn("state.readAt = timestamp", text)
        self.assertIn("preserving existing read state on unchecked capture", text)
        self.assertNotIn("ignoring archive read=true capture", text)
        self.assertNotIn("state.readFingerprint = nil", text)
        self.assertNotIn("state.readAt = nil", text)
        self.assertIn("plaintextHash(for: currentText) != expectedPlaintextHash", text)

    def test_notice_capture_rejects_bulk_state_drop(self) -> None:
        text = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("func suspiciousNoticeCaptureRegression", text)
        self.assertIn("suspicious read state drop", text)
        self.assertIn("suspicious important state drop", text)
        self.assertIn("userStateBeforeCapture", text)
        self.assertIn("fail(\"capture-failed-preserve-user-state: \\(regression)\")", text)

    def test_legacy_notice_capture_does_not_clear_existing_read_state(self) -> None:
        text = (
            PROJECT_DIR / "src" / "swift" / "capture_notice_native_state.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("state.readFingerprint = rendered.fingerprint", text)
        self.assertNotIn("state.readFingerprint = nil", text)
        self.assertNotIn("state.readAt = nil", text)

    def test_archive_capture_can_create_important_state(self) -> None:
        text = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("displayMode == .primary || displayMode == .archive", text)
        self.assertIn("state.important = importantChecked", text)
        self.assertIn("suspiciousImportantThreshold", text)
        self.assertIn("importantTrueCount >= suspiciousImportantThreshold", text)
        self.assertIn("$0.rendered.shouldCheckImportant == true", text)
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

        self.assertIn("attributedText: pasteAttributedText", renderer)
        self.assertNotIn("forType: .html", renderer)
        self.assertIn("NSFont.systemFont(ofSize: line.fontSize)", renderer)
        self.assertIn("NSFont.boldSystemFont(ofSize: line.fontSize)", renderer)
        self.assertIn("uiStyleMenuFormattingEnabled", renderer)
        self.assertIn("plainTextPasteEnabled", renderer)
        self.assertIn('NOTICE_NATIVE_ENABLE_UI_STYLE_FORMAT', support)
        self.assertIn('NOTICE_NATIVE_DISABLE_UI_STYLE_FORMAT', support)
        self.assertIn('NOTICE_NATIVE_PLAIN_TEXT_PASTE', support)
        self.assertIn('NOTICE_NATIVE_DISABLE_UI_STYLE_FORMAT"] == "1"', renderer)
        self.assertIn("shouldCollapseNoticeSections(plan)", renderer)
        self.assertIn("placeCaretForFormatting(\n            context: context,", renderer)
        self.assertNotIn('NOTICE_NATIVE_ENABLE_UI_STYLE_FALLBACK"] == "1"', renderer)
        self.assertIn(
            "initialNoticeCollapseEnabled && collapseNoticeCoursesEnabled && !plan.courseHeadingLineIndexes.isEmpty",
            renderer[renderer.index("func shouldCollapseNoticeCourses") : renderer.index("func shouldCollapseNoticeItems")],
        )
        self.assertIn("func shouldStyleNoticeCourses", renderer)
        self.assertIn("func shouldStyleNoticeItems", renderer)
        self.assertIn("noticeTitleStyleMenuItems", renderer)
        self.assertIn("noticeHeadingStyleMenuItems", renderer)
        self.assertIn("noticeSubheadingStyleMenuItems", renderer)
        self.assertIn('let noticeSubheadingStyleMenuItems = ["부머리말", "부제목", "소제목", "Subheading"]', support)
        self.assertIn("reason=rich_paste_default", renderer)
        self.assertIn("readability_validation_targets_finish", renderer)
        self.assertIn("case .chunked:", renderer)
        self.assertIn("case .conservative:", renderer)
        self.assertIn("conservativeRenderFallbackEnabled", support)
        self.assertIn("line-by-line conservative render is disabled", renderer)
        self.assertIn("attributedNoticeText(for: lines)", renderer)
        self.assertIn("attributedNoticeText(text: text, like: line)", renderer)
        self.assertNotIn("_ = strategy", renderer)

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

    def test_notice_render_keeps_headings_in_body_font_size(self) -> None:
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
            "appendLine(noticeHeadingText(finalTitle), bold: true, fontSize: noticeTitleFontSize())",
            renderer,
        )
        self.assertIn("cssFontSize(line.fontSize)", renderer)
        self.assertIn("let noticeBodyFontSize: CGFloat = 14", support)
        self.assertIn("let noticeSectionHeadingFontSize: CGFloat = 19", support)
        self.assertIn("let noticeDocumentTitleFontSize: CGFloat = 23", support)
        self.assertNotIn("line-height:1.42", renderer)

    def test_notice_format_menu_does_not_toggle_bold_off(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("func missingBoldTargets", renderer)
        self.assertIn("func reinforceMissingBoldTargetsIfNeeded", renderer)
        self.assertIn("func currentLineRange", renderer)
        self.assertIn("boldInspectionResult(textArea: context.textArea", renderer)
        self.assertIn("bold_reinforce_start", renderer)
        self.assertIn("bold_reinforce_finish", renderer)
        self.assertNotIn("func boldBlockTextsContain", renderer)
        self.assertNotIn("applyBold(summaryRange)", renderer)
        self.assertNotIn("applyBold(meta)", renderer)
        self.assertNotIn("applyBold(attachmentHeading)", renderer)

    def test_notice_layout_skips_empty_sections_and_compacts_body_noise(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("func appendPrimarySection", renderer)
        self.assertIn("guard count > 0 else", renderer)
        self.assertIn("primaryFallbackAllNotices", renderer)
        self.assertIn("allVisibleCourses", renderer)
        self.assertIn('sectionHeadingText("전체 공지", count: allVisibleNoticeCount)', renderer)
        self.assertIn('sectionHeadingText("확인한 공지", count: visibleUnreadCount)', renderer)
        self.assertIn("} else if visibleUnreadCount > 0 {", renderer)
        self.assertIn('"\\(title) (\\(count)건)"', renderer)
        self.assertIn('"\\(course.title) (\\(course.notices.count)건)"', renderer)
        self.assertIn("func noticeHeadingText(_ title: String) -> String", renderer)
        self.assertNotIn('"[분류] \\(title) (\\(count)건)"', renderer)
        self.assertNotIn('"[과목] \\(course.title) (\\(course.notices.count)건)"', renderer)
        self.assertNotIn('"[공지] \\(title)"', renderer)
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

    def test_notice_category_and_course_headings_are_opt_in_collapsible_groups(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        support = (
            PROJECT_DIR / "src" / "swift" / "notice_native_note_support.swift"
        ).read_text(encoding="utf-8")
        config = (PROJECT_DIR / "examples" / "config.env.example").read_text(
            encoding="utf-8"
        )

        self.assertIn('environment["NOTICE_COLLAPSE_SECTIONS"] == "1"', support)
        self.assertIn("collapseNoticeCoursesEnabled", support)
        self.assertIn("collapseNoticeItemsEnabled", support)
        self.assertIn("initialNoticeCollapseEnabled", support)
        self.assertIn("styleNoticeItemsAsHeadingsEnabled", support)
        self.assertIn("hideHiddenNoticeItemsEnabled", support)
        self.assertIn("uiCollapsibleGroupStyleFormattingEnabled", support)
        self.assertIn("noticeCollapseStyleSettleDelay", support)
        self.assertIn("let mode: NoticeDisplayMode", support)
        self.assertIn("func shouldCollapseNoticeCourses(_ plan: RenderPlan) -> Bool", renderer)
        self.assertIn("func shouldCollapseNoticeItems(_ plan: RenderPlan) -> Bool", renderer)
        self.assertIn("func shouldCollapseNoticeSections(_ plan: RenderPlan) -> Bool", renderer)
        self.assertIn(
            "initialNoticeCollapseEnabled && collapseNoticeCoursesEnabled && !plan.courseHeadingLineIndexes.isEmpty",
            renderer[
                renderer.index("func shouldCollapseNoticeCourses")
                : renderer.index("func shouldCollapseNoticeItems")
            ],
        )
        self.assertIn("func shouldStyleNoticeCourses", renderer)
        self.assertIn("func shouldStyleNoticeItems", renderer)
        self.assertNotIn("collapseNoticeCoursesEnabled || plan.mode == .archive", renderer)
        self.assertIn("initialNoticeCollapseEnabled && collapseNoticeItemsEnabled && !plan.renderedNotices.isEmpty", renderer)
        self.assertIn("initialNoticeCollapseEnabled\n        && plan.mode == .primary\n        && collapseNoticeSectionsEnabled", renderer)
        self.assertIn("noticeTitleStyleMenuItems", renderer)
        self.assertIn("noticeHeadingStyleMenuItems", renderer)
        self.assertIn("noticeSubheadingStyleMenuItems", renderer)
        self.assertIn('let noticeSubheadingStyleMenuItems = ["부머리말", "부제목", "소제목", "Subheading"]', support)
        self.assertIn("let effectiveCollapseSectionsEnabled = shouldCollapseNoticeSections(plan)", renderer)
        self.assertIn("let effectiveStyleCoursesEnabled = shouldStyleNoticeCourses(plan)", renderer)
        self.assertIn("let effectiveStyleNoticeItemsEnabled = shouldStyleNoticeItems(plan)", renderer)
        self.assertIn("collapse_heading_retry", renderer)
        self.assertIn("collapse failed: \\(label)", renderer)
        self.assertIn("return (collapsedSections, collapseIssues)", renderer)
        self.assertIn("if effectiveCollapseCoursesEnabled", renderer)
        self.assertIn("if effectiveCollapseNoticeItemsEnabled", renderer)
        self.assertIn("if effectiveStyleCoursesEnabled", renderer)
        self.assertIn("if effectiveStyleNoticeItemsEnabled", renderer)
        self.assertIn("collapseHeading(range, label: \"course-\\(offset + 1)\")", renderer)
        self.assertIn("collapseHeading(range, label: \"section-\\(offset + 1)\")", renderer)
        self.assertIn("display_mode=\\(noticeDisplayModeName(plan.mode))", renderer)
        self.assertIn("collapse_sections=\\(shouldCollapseNoticeSections(plan) ? \"1\" : \"0\")", renderer)
        self.assertIn("collapse_courses=\\(shouldCollapseNoticeCourses(plan) ? \"1\" : \"0\")", renderer)
        self.assertIn("collapse_notice_items=\\(shouldCollapseNoticeItems(plan) ? \"1\" : \"0\")", renderer)
        self.assertIn("style_notice_items=\\(styleNoticeItemsAsHeadingsEnabled ? \"1\" : \"0\")", renderer)
        self.assertIn("plain_text_paste=\\(plainTextPasteEnabled ? \"1\" : \"0\")", renderer)
        self.assertIn("let isHidden = boolValue(state.hidden)", renderer)
        self.assertIn("if isHidden && hideHiddenNoticeItemsEnabled", renderer)
        self.assertIn("NOTICE_COLLAPSE_SECTIONS=\"0\"", config)
        self.assertIn("NOTICE_COLLAPSE_COURSES=\"0\"", config)
        self.assertIn("NOTICE_COLLAPSE_NOTICE_ITEMS=\"0\"", config)
        self.assertIn("NOTICE_STYLE_NOTICE_ITEMS_AS_HEADINGS=\"0\"", config)
        self.assertIn("NOTICE_HIDE_HIDDEN_ITEMS=\"1\"", config)
        self.assertIn("NOTICE_NATIVE_PLAIN_TEXT_PASTE=\"0\"", config)
        self.assertIn("NOTICE_NATIVE_ENABLE_BATCH_CHECKLIST_FORMAT=\"1\"", config)
        self.assertIn("NOTICE_NATIVE_ENABLE_UI_STYLE_FORMAT=\"0\"", config)

        collapse_block_index = renderer.index("var collapsedSections = 0")
        notice_index = renderer.index("if effectiveCollapseNoticeItemsEnabled", collapse_block_index)
        course_index = renderer.index("let courseCollapseRanges", collapse_block_index)
        section_index = renderer.index("let sectionCollapseRanges", collapse_block_index)
        self.assertLess(notice_index, course_index)
        self.assertLess(course_index, section_index)

    def test_notice_document_header_is_never_a_collapse_target(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        support = (
            PROJECT_DIR / "src" / "swift" / "notice_native_note_support.swift"
        ).read_text(encoding="utf-8")
        app_model = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "KLMSMacModel.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("func isDocumentHeaderLineIndex(_ index: Int, plan: RenderPlan) -> Bool", renderer)
        self.assertIn("index == plan.titleLineIndex || index == plan.summaryLineIndex", renderer)
        self.assertIn("guard !isDocumentHeaderLineIndex(index, plan: plan) else", renderer)
        self.assertIn("func noticeCollapseLineRangeGroups(", renderer)
        self.assertIn("restoreCollapsedNoticeStateAfterVerification(context: NotesEditorContext, noteTitle: String, plan: RenderPlan)", renderer)
        self.assertIn("noticeCollapseLineRangeGroups(plan: plan, lineRanges: lineRanges)", renderer)
        self.assertNotIn("Collapse All", renderer)
        self.assertNotIn("모두 접기", renderer)
        self.assertNotIn("collapseAllFirstEnabled", support)
        self.assertNotIn("NOTICE_NATIVE_COLLAPSE_ALL_FIRST", app_model)

    def test_notice_ui_operations_force_target_note_focus(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        support = (
            PROJECT_DIR / "src" / "swift" / "notice_native_note_support.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("func focusNotesEditor(_ context: NotesEditorContext", renderer)
        self.assertIn("AXUIElementPerformAction(context.window, kAXRaiseAction", renderer)
        self.assertIn("trySetAttr(context.app, kAXFocusedWindowAttribute", renderer)
        self.assertIn("func pressMenuIfAvailable(_ context: NotesEditorContext", renderer)
        self.assertIn("func reshowTargetNoteForContext", renderer)
        self.assertIn("func optionalNotesEditorContext", renderer)
        self.assertNotIn("func setManagedNoteBodyByScript", renderer)
        self.assertNotIn("func renderDirectNotesHTML", renderer)
        self.assertNotIn("func renderHTML", renderer)
        self.assertNotIn("render_fallback_body", renderer)
        self.assertNotIn("forceBodyFallbackRenderEnabled", support)
        self.assertIn("Retrying Notes context after re-showing target note", renderer)
        self.assertIn("retries: 50", renderer)
        self.assertIn("let pasteAttributedText = (plainTextPasteEnabled || preformattedPasteOnlyEnabled)", renderer)
        self.assertIn("paste(context: context, text: plaintext, attributedText: pasteAttributedText)", renderer)
        self.assertIn("paste(context: context, text: text, attributedText: pasteAttributedText)", renderer)
        self.assertRegex(renderer, r"ensureChecklistStates\(\s+context: context,")
        self.assertRegex(renderer, r"ensureCheckedItemsStayInPlace\(\s+context: context,")
        self.assertIn("notes.selection = [note]", renderer)
        self.assertIn("set frontmost to true", renderer)
        self.assertNotIn("text areas of entire contents", renderer)
        self.assertIn("kAXMenuBarItemRole", renderer)
        self.assertIn("AXUIElementPerformAction(topLevelMenuItem, kAXPressAction", renderer)
        self.assertIn("func preferredTopLevelMenuTitles", renderer)
        self.assertIn('preferred.append(contentsOf: ["포맷", "Format"])', renderer)
        self.assertIn("} else if desiredReadState {", renderer)
        self.assertIn("} else if desiredImportantState {", renderer)
        self.assertIn("timeoutSeconds: 4", renderer)
        self.assertIn("timed_out=", renderer)
        self.assertIn("NOTICE_NATIVE_STYLE_BUDGET_SECONDS", renderer)
        self.assertIn("scaledStyleBudgetSeconds", renderer)
        self.assertIn("configuredStyleBudgetSeconds", renderer)
        self.assertIn("style-fallback-bold", renderer)
        self.assertIn("style_budget_exhausted", renderer)
        self.assertIn(
            'styleIssues = ["style budget exhausted before functional Notes formatting could be verified"]',
            renderer,
        )
        self.assertNotIn("styleIssues = []", renderer)
        self.assertNotIn("text area 1 of scroll area 3", renderer)
        self.assertNotIn("paste(context.app, text:", renderer)

    def test_notice_renderer_does_not_post_global_input_events(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertNotIn("CGEventSource", renderer)
        self.assertNotIn("CGEvent(keyboardEventSource", renderer)
        self.assertNotIn(".post(tap: .cghidEventTap)", renderer)
        self.assertNotIn("sendCommandKey", renderer)
        self.assertNotIn("sendReturnKey", renderer)

    def test_notice_capture_context_failure_is_nonfatal(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        capture = renderer[
            renderer.index("func captureRenderedNoticeState") :
            renderer.index("func buildRenderPlan")
        ]

        self.assertIn("attemptResolveNotesEditorContext", capture)
        self.assertIn("Skipping capture because Notes editor context could not be confirmed", capture)
        self.assertNotIn("let captureContext = resolveNotesEditorContext", capture)

    def test_archive_notice_note_renders_before_primary(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        js = read_notice_js()

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
        self.assertIn("NOTICE_NATIVE_FORCE_ARCHIVE_POST_CAPTURE_RENDER", js)
        self.assertIn("allowNoOpSkip: true", renderer)

    def test_notice_native_config_is_passed_to_swift_wrapper(self) -> None:
        js = read_notice_js()

        self.assertIn("function nativeNoticeEnvironment(config)", js)
        self.assertIn('"NOTICE_COLLAPSE_SECTIONS"', js)
        self.assertIn('"NOTICE_COLLAPSE_COURSES"', js)
        self.assertIn('"NOTICE_NATIVE_ENABLE_BATCH_CHECKLIST_FORMAT"', js)
        self.assertIn('"NOTICE_STYLE_NOTICE_ITEMS_AS_HEADINGS"', js)
        self.assertIn('"NOTICE_HIDE_HIDDEN_ITEMS"', js)
        self.assertIn('"NOTICE_NATIVE_DISABLE_FAST_CHECKLIST_FORMAT"', js)
        self.assertIn('"NOTICE_NATIVE_NOTE_MAX_ATTEMPTS"', js)
        self.assertIn('"NOTICE_NATIVE_NOTE_RETRY_DELAY_SECONDS"', js)
        self.assertIn('"NOTICE_NATIVE_NOTE_TIMEOUT_SECONDS"', js)
        self.assertIn('"NOTICE_NATIVE_VERIFY_STABLE_SKIP_FORMAT"', js)
        self.assertIn('"NOTICE_NATIVE_POST_RENDER_VERIFY"', js)
        self.assertIn('"NOTICE_NATIVE_INITIAL_COLLAPSE_ENABLED"', js)
        self.assertIn('"NOTICE_NATIVE_CONSERVATIVE_RENDER_FALLBACK"', js)
        self.assertIn('"NOTICE_NATIVE_STYLE_BUDGET_SECONDS"', js)
        self.assertIn('"NOTICE_NATIVE_PLAIN_TEXT_PASTE"', js)
        self.assertIn("nativeNoticeDefaultEnvironment", js)
        self.assertIn("applyRuntimeConfigOverrides(config)", js)
        self.assertIn('"NOTICE_NATIVE_VERIFY_STABLE_SKIP_FORMAT",\n    "NOTICE_NATIVE_POST_RENDER_VERIFY"', js)
        self.assertIn('"NOTICE_NATIVE_POST_RENDER_VERIFY",\n    "NOTICE_NATIVE_INITIAL_COLLAPSE_ENABLED"', js)
        self.assertIn('"NOTICE_NATIVE_INITIAL_COLLAPSE_ENABLED",\n    "NOTICE_NATIVE_CONSERVATIVE_RENDER_FALLBACK"', js)
        self.assertIn('"NOTICE_NATIVE_CONSERVATIVE_RENDER_FALLBACK",\n    "NOTICE_NATIVE_NOTE_MAX_ATTEMPTS"', js)
        self.assertIn("nativeNoticePostRenderVerifyEnabled", js)
        self.assertNotIn("KLMS_APP_NOTICE_BODY_FALLBACK", js)
        self.assertNotIn("NOTICE_NATIVE_FORCE_BODY_FALLBACK", js)
        self.assertIn("runNativeNoticeCommandWithRecoverableRetry", js)
        self.assertIn("noticeNativeEnvironment", js)
        self.assertIn('envValue("KLMS_APP_RUN") === "1"', js)
        self.assertIn('"NOTICE_NATIVE_STABLE_NOOP_SKIP",\n      true', js)
        self.assertIn("...nativeDefaultEnv", js)
        self.assertIn("...nativeEnv", js)
        self.assertIn('defaults.push("NOTICE_NATIVE_PLAIN_TEXT_PASTE=0")', js)

    def test_runtime_env_undefined_does_not_disable_notice_formatting(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("node is not installed")

        script = r"""
const fs = require("fs");
const source = fs.readFileSync("src/js/sync_klms_notes.js", "utf8");

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
  extractFunction("normalizeRuntimeEnvValue"),
  extractFunction("applyRuntimeConfigOverrides"),
].join("\n"));

let mode = "undefined";
function envValue(key) {
  if (key === "NOTICE_COLLAPSE_SECTIONS") return mode;
  return "";
}

const config = {
  NOTICE_COLLAPSE_SECTIONS: "1",
  NOTICE_STYLE_NOTICE_ITEMS_AS_HEADINGS: "1",
};
applyRuntimeConfigOverrides(config);
const kept = config.NOTICE_COLLAPSE_SECTIONS;
mode = "0";
applyRuntimeConfigOverrides(config);
const overridden = config.NOTICE_COLLAPSE_SECTIONS;
console.log(JSON.stringify({ kept, overridden }));
"""
        result = subprocess.run(
            [node, "-e", script],
            cwd=PROJECT_DIR,
            text=True,
            check=True,
            capture_output=True,
        )

        self.assertEqual(result.stdout.strip(), '{"kept":"1","overridden":"0"}')

    def test_app_notice_post_render_verify_can_be_disabled(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("node is not installed")

        script = r"""
const fs = require("fs");
const source = fs.readFileSync("src/js/sync_notice_bridge.js", "utf8");

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
  extractFunction("nativeNoticeEnvHasKey"),
  extractFunction("nativeNoticeDefaultEnvironment"),
  extractFunction("nativeNoticeVerifyStableSkipFormatEnabled"),
  extractFunction("nativeNoticePostRenderVerifyEnabled"),
  extractFunction("nativeNoticeEnvironmentEnabled"),
  extractFunction("nativeNoticeEnvironmentValue"),
  extractFunction("noticeTargetRequiresPostCaptureRender"),
  extractFunction("updateNoticeNativeNote"),
].join("\n"));

let calls = [];
function debugStderr() {}
function runNativeNoticeCommandWithRecoverableRetry(stageTelemetry, target, command) {
  calls.push({ kind: "render", target, command });
  return `rendered ${target}`;
}
function verifyNoticeNativeNoteReadableFormat(target) {
  calls.push({ kind: "verify", target });
  return `verified ${target}`;
}

function runCase(flag) {
  calls = [];
  updateNoticeNativeNote(
    "/engine",
    "KLMS 공지",
    "KLMS 확인한 공지",
    "/digest.json",
    "/notice_state.json",
    "/primary_render_state.json",
    "/archive_render_state.json",
    false,
    false,
    false,
    false,
    [`NOTICE_NATIVE_POST_RENDER_VERIFY=${flag}`],
    null
  );
  return calls.map((call) => `${call.kind}:${call.target}`);
}

console.log(JSON.stringify({ off: runCase("0"), on: runCase("1") }));
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
            '{"off":["render:archive","render:primary"],"on":["render:archive","verify:archive","render:primary","verify:primary"]}',
        )

    def test_app_notice_requires_functional_notes_renderer(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")
        support = (
            PROJECT_DIR / "src" / "swift" / "notice_native_note_support.swift"
        ).read_text(encoding="utf-8")
        app_model = (
            PROJECT_DIR / "apps" / "KLMSync" / "Sources" / "KLMSMac" / "KLMSMacModel.swift"
        ).read_text(encoding="utf-8")

        self.assertIn('NOTICE_NATIVE_ENABLE_BATCH_CHECKLIST_FORMAT": "1"', app_model)
        self.assertIn('NOTICE_NATIVE_ENABLE_UI_STYLE_FORMAT": "1"', app_model)
        self.assertIn('NOTICE_NATIVE_VALIDATE_STYLE": "0"', app_model)
        self.assertIn('NOTICE_NATIVE_PREFORMATTED_PASTE_ONLY": "0"', app_model)
        self.assertIn('NOTICE_NATIVE_ALWAYS_CAPTURE_STATE": "1"', app_model)
        self.assertIn('NOTICE_NATIVE_STABLE_NOOP_SKIP": "1"', app_model)
        self.assertIn('NOTICE_NATIVE_VERIFY_STABLE_SKIP_FORMAT": "0"', app_model)
        self.assertIn('NOTICE_NATIVE_POST_RENDER_VERIFY": "1"', app_model)
        self.assertIn('NOTICE_NATIVE_INITIAL_COLLAPSE_ENABLED": "1"', app_model)
        self.assertIn('NOTICE_NATIVE_CONSERVATIVE_RENDER_FALLBACK": "0"', app_model)
        self.assertIn('NOTICE_COLLAPSE_SECTIONS": "0"', app_model)
        self.assertIn('NOTICE_COLLAPSE_COURSES": "1"', app_model)
        self.assertIn('NOTICE_COLLAPSE_NOTICE_ITEMS": "0"', app_model)
        self.assertIn('NOTICE_STYLE_NOTICE_ITEMS_AS_HEADINGS": "0"', app_model)
        self.assertNotIn("requireFunctionalNotesRenderEnabled", support)
        self.assertIn("Functional Notes editor unavailable", renderer)
        self.assertIn("Grant KLMS Sync Accessibility/Automation permissions", renderer)
        self.assertNotIn("method=applescript", renderer)
        self.assertNotIn("method=app-direct-html", renderer)

    def test_notice_prebuild_warning_does_not_fail_core_sync(self) -> None:
        js = read_notice_js()
        prebuild = js[
            js.index('beginStage(steps, stageTelemetry, "notice-summary-prebuild")') :
            js.index('debugStderr("after notice-summary-prebuild")')
        ]

        self.assertIn("notice-summary-prebuild warning ignored", prebuild)
        self.assertNotIn("throw noticeError", prebuild)

    def test_notice_summary_failure_restores_previous_notice_cache(self) -> None:
        js = read_notice_js()
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
        js = read_notice_js()
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
        js = read_notice_js()

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
        text = read_notice_js()

        stable_noop_index = text.index("stable-noop-after-capture")
        verify_index = text.index("verifyNoticeNativeNoteReadableFormat")
        self.assertLess(verify_index, stable_noop_index)
        self.assertIn("readability-format-check-failed", text)
        self.assertIn("Native notice note readability format stale", text)
        self.assertIn('"--verify-only"', text)
        self.assertIn('"NOTICE_NATIVE_VERIFY_STABLE_SKIP_FORMAT",\n    true', text)
        self.assertIn("runCommand(command, scriptDir)", text)
        self.assertIn("Verified native notice readability format", text)
        self.assertNotIn("noteReadableStyleMetricsViaAppleScript", text)
        self.assertNotIn("font_size_tags", text)
        self.assertNotIn("heading_tags", text)
        self.assertNotIn("large_font_tags", text)
        self.assertNotIn("minimumLargeFontTags", text)
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
        js = read_notice_js()
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
const path = "src/js/sync_notice_bridge.js";
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
  extractFunction("noticeInteractionStateIsRead"),
  extractFunction("nativeNoticeEnvironmentEnabled"),
  extractFunction("nativeNoticeEnvironmentValue"),
  extractFunction("noticeIdentifierForDigestNotice"),
  extractFunction("legacyNoticeIdentifiersForDigestNotice"),
  extractFunction("noticeInteractionStateForDigestNotice"),
  extractFunction("mergeNoticeInteractionState"),
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

    def test_notice_native_expected_state_keeps_primary_populated_when_all_read(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("node is not available")
        script = r"""
const fs = require("fs");
const path = "src/js/sync_notice_bridge.js";
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
  extractFunction("noticeInteractionStateIsRead"),
  extractFunction("nativeNoticeEnvironmentEnabled"),
  extractFunction("nativeNoticeEnvironmentValue"),
  extractFunction("noticeIdentifierForDigestNotice"),
  extractFunction("legacyNoticeIdentifiersForDigestNotice"),
  extractFunction("noticeInteractionStateForDigestNotice"),
  extractFunction("mergeNoticeInteractionState"),
  extractFunction("oneLineText"),
].join("\n"));

const digest = {
  courses: [
    {
      course: "Course A",
      notices: [
        { url: "read-1", fingerprint: "fp-read-1", change_state: "stable" },
        { url: "read-2", fingerprint: "fp-read-2", change_state: "stable" },
      ],
    },
  ],
};
const userState = {
  notices: {
    "read-1": { read_fingerprint: "fp-read-1" },
    "read-2": { read_fingerprint: "fp-read-2" },
  },
};

const expected = expectedNoticeNativeRenderState(digest, userState);
console.log(JSON.stringify({
  primary: expected.primary.map((notice) => notice.notice_id),
  primaryChecked: expected.primary.map((notice) => notice.should_check_read),
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
            '{"primary":["read-1","read-2"],"primaryChecked":[true,true],"archive":["read-1","read-2"]}',
        )

    def test_notice_expected_state_reuses_legacy_url_state_for_article_id(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("node is not available")
        script = r"""
const fs = require("fs");
const path = "src/js/sync_notice_bridge.js";
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
  extractFunction("noticeInteractionStateIsRead"),
  extractFunction("nativeNoticeEnvironmentEnabled"),
  extractFunction("nativeNoticeEnvironmentValue"),
  extractFunction("noticeIdentifierForDigestNotice"),
  extractFunction("legacyNoticeIdentifiersForDigestNotice"),
  extractFunction("noticeInteractionStateForDigestNotice"),
  extractFunction("mergeNoticeInteractionState"),
  extractFunction("oneLineText"),
].join("\n"));

const legacyUrl = "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=2&page=2&bwid=435776";
const digest = {
  courses: [
    {
      course: "Course A",
      notices: [
        { url: legacyUrl, article_id: "435776", fingerprint: "fp-current", change_state: "new" },
        { url: "unread-1", fingerprint: "fp-unread", change_state: "stable" },
      ],
    },
  ],
};
const userState = {
  notices: {
    [legacyUrl]: { read_at: "2026-06-01T00:00:00+09:00", read_fingerprint: "fp-old" },
  },
};

const expected = expectedNoticeNativeRenderState(digest, userState);
console.log(JSON.stringify({
  primary: expected.primary.map((notice) => notice.notice_id),
  archive: expected.archive.map((notice) => notice.notice_id),
  archiveChecked: expected.archive.map((notice) => notice.should_check_read),
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
            '{"primary":["unread-1"],"archive":["article:435776"],"archiveChecked":[true]}',
        )

    def test_notice_read_at_survives_fingerprint_drift_for_native_expected_state(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("node is not available")
        script = r"""
const fs = require("fs");
const path = "src/js/sync_notice_bridge.js";
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
  extractFunction("noticeInteractionStateIsRead"),
  extractFunction("nativeNoticeEnvironmentEnabled"),
  extractFunction("nativeNoticeEnvironmentValue"),
  extractFunction("noticeIdentifierForDigestNotice"),
  extractFunction("legacyNoticeIdentifiersForDigestNotice"),
  extractFunction("noticeInteractionStateForDigestNotice"),
  extractFunction("mergeNoticeInteractionState"),
  extractFunction("oneLineText"),
].join("\n"));

const digest = {
  courses: [
    {
      course: "Course A",
      notices: [
        { url: "read-1", fingerprint: "fp-current", change_state: "new" },
        { url: "unread-1", fingerprint: "fp-unread", change_state: "stable" },
      ],
    },
  ],
};
const userState = {
  notices: {
    "read-1": { read_at: "2026-06-01T00:00:00+09:00", read_fingerprint: "fp-old" },
  },
};

const expected = expectedNoticeNativeRenderState(digest, userState);
console.log(JSON.stringify({
  primary: expected.primary.map((notice) => notice.notice_id),
  archive: expected.archive.map((notice) => notice.notice_id),
  archiveChecked: expected.archive.map((notice) => notice.should_check_read),
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
            '{"primary":["unread-1"],"archive":["read-1"],"archiveChecked":[true]}',
        )

    def test_notice_state_only_defer_does_not_hide_target_moves(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("node is not available")
        script = r"""
const fs = require("fs");
const path = "src/js/sync_notice_bridge.js";
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

const NATIVE_NOTICE_RENDER_STYLE_VERSION = "test-style";
function stableHash(text) {
  return `hash:${text}`;
}
const files = {};
function fileExists(path) {
  return Object.prototype.hasOwnProperty.call(files, path);
}
function readText(path) {
  return files[path];
}

eval([
  extractFunction("noticeNativeRenderComparison"),
  extractFunction("loadNoticeUserState"),
  extractFunction("noticeDigestHasFreshNotices"),
  extractFunction("expectedNoticeNativeRenderState"),
  extractFunction("noticeInteractionStateIsRead"),
  extractFunction("compareRenderStateToExpected"),
  extractFunction("noticeExpectedRenderSignature"),
  extractFunction("noticeRenderSignatureComponents"),
  extractFunction("nativeNoticeEnvironmentEnabled"),
  extractFunction("nativeNoticeEnvironmentValue"),
  extractFunction("renderStateNoticeKeys"),
  extractFunction("expectedNoticeKeys"),
  extractFunction("noticeIdentifierForDigestNotice"),
  extractFunction("legacyNoticeIdentifiersForDigestNotice"),
  extractFunction("noticeInteractionStateForDigestNotice"),
  extractFunction("mergeNoticeInteractionState"),
  extractFunction("oneLineText"),
].join("\n"));

const digest = {
  generated_at: "2026-06-01T00:00:00+09:00",
  new_count: 0,
  updated_count: 0,
  courses: [
    {
      course: "Course A",
      notices: [
        { url: "read-1", fingerprint: "fp-read", change_state: "stable" },
        { url: "unread-1", fingerprint: "fp-unread", change_state: "stable" },
      ],
    },
  ],
};
const userState = {
  notices: {
    "read-1": { read_at: "2026-06-01T00:00:00+09:00", read_fingerprint: "fp-read" },
  },
};
const stalePrimaryRenderState = {
  style_version: NATIVE_NOTICE_RENDER_STYLE_VERSION,
  render_signature: "old-primary-signature",
  rendered_notices: [
    { notice_id: "read-1", fingerprint: "fp-read", should_check_read: false, should_check_important: false },
    { notice_id: "unread-1", fingerprint: "fp-unread", should_check_read: false, should_check_important: false },
  ],
};
const staleArchiveRenderState = {
  style_version: NATIVE_NOTICE_RENDER_STYLE_VERSION,
  render_signature: "old-archive-signature",
  rendered_notices: [],
};
files["/digest.json"] = JSON.stringify(digest);
files["/notice_user_state.json"] = JSON.stringify(userState);
files["/primary_render_state.json"] = JSON.stringify(stalePrimaryRenderState);
files["/archive_render_state.json"] = JSON.stringify(staleArchiveRenderState);

const comparison = noticeNativeRenderComparison(
  "/digest.json",
  "/notice_user_state.json",
  "/primary_render_state.json",
  "/archive_render_state.json",
  []
);
console.log(JSON.stringify({
  stateOnlyDiff: comparison.stateOnlyDiff,
  primary: comparison.expected.primary.map((notice) => notice.notice_id),
  archive: comparison.expected.archive.map((notice) => notice.notice_id),
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
            '{"stateOnlyDiff":false,"primary":["unread-1"],"archive":["read-1"]}',
        )

    def test_notice_render_noop_ignores_generated_timestamp_only(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("func stableRenderLineText", renderer)
        self.assertIn('text.hasPrefix("기준 시각:")', renderer)
        self.assertIn('"기준 시각: <ignored>\\(text[separatorRange.lowerBound...])"', renderer)
        self.assertIn("previousRenderState?.updatedAt == timestamp", renderer)
        self.assertIn("stablePlaintextHash(for: snapshot.plaintext)", renderer)
        self.assertIn("stablePlaintextHash(for: desiredPlaintext)", renderer)

    def test_notice_render_comparison_uses_render_signature_not_generated_at(self) -> None:
        js = read_notice_js()

        self.assertIn("noticeExpectedRenderSignature", js)
        self.assertIn("render_signature", js)
        self.assertIn('reason: "render-signature-differs"', js)
        self.assertNotIn("renderStateTimestampMatches", js)
        self.assertNotIn("compareRenderStateTimestamp", js)
        self.assertNotIn('reason: "generated-at-differs"', js)

    def test_notes_context_fallback_accepts_selected_note_id(self) -> None:
        renderer = (
            PROJECT_DIR / "src" / "swift" / "update_notice_native_note.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("expectedAnchorTexts.isEmpty || selectedNoteIDs().contains(expectedNoteID)", renderer)
        self.assertIn("Falling back to the focused Notes text area for selected note id", renderer)
        self.assertIn("Could not confirm Notes selection for explicit note", renderer)
        self.assertIn("timeoutSeconds: 15", renderer)
        self.assertNotIn("focusedEmptyExplicitNote", renderer)
        self.assertIn("func createManagedNote", renderer)
        self.assertIn("Ignoring stale explicit Notes note id", renderer)
        self.assertIn("Explicit Notes note id is stale", renderer)
        self.assertIn("Thread.sleep(forTimeInterval: 1.0)", renderer)
        self.assertIn('"AXVisibleChildren"', renderer)
        self.assertIn("func selectedContextStillMatches", renderer)
        self.assertIn("activateApplication(pid: targetPID)", renderer)
        self.assertIn("frontmost of first process whose unix id", renderer)
        self.assertNotIn(".activateIgnoringOtherApps", renderer)
        self.assertIn('role == kAXTextAreaRole as String || role == "AXTextView"', renderer)
        self.assertIn("if !textAreaFocused && !matchesAnchor && !selectedExpectedNote", renderer)
        self.assertIn("CFHash(element)", renderer)
        self.assertIn("String(value.prefix(80))", renderer)
        self.assertNotIn("Unmanaged.passUnretained(element).toOpaque()", renderer)
        self.assertNotIn("text areas of entire contents", renderer)


if __name__ == "__main__":
    unittest.main()
