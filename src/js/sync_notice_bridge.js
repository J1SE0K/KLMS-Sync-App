function filterNoticeBoardUrls(urls) {
  return uniqueStrings(
    (urls || []).filter((url) => /\/mod\/courseboard\/view\.php/i.test(String(url || "")))
  );
}

function runStandaloneNoticeSummary(
  scriptDir,
  waitSeconds,
  baseFetchOptions,
  paths,
  steps,
  usePrefetchedDashboard,
  stageTelemetry
) {
  const pythonPath = buildPythonPath(scriptDir, `${scriptDir}/runtime`);
  beginStage(steps, stageTelemetry, "notice-dashboard-fetch");
  const dashboardPages =
    usePrefetchedDashboard && fileExists(paths.dashboardJson)
      ? loadPagesJson(paths.dashboardJson)
      : fetchPages([paths.dashboardUrl], waitSeconds, scriptDir, {
          ...baseFetchOptions,
          context: "notice-dashboard",
          mode: "full",
          outputPath: paths.dashboardJson,
          summaryPath: paths.dashboardFetchSummaryJson,
          requireAll: true,
        });
  assertRequiredPageCount(
    "공지 대시보드 페이지를 가져오지 못했어. Safari에서 KLMS가 열린 상태인지 확인한 뒤 다시 실행해 줘.",
    dashboardPages,
    1
  );
  assertNoLoginPages(
    "공지 정리를 시작하는 중 KLMS 로그인 세션이 풀렸어. 다시 로그인해 줘.",
    dashboardPages
  );

  beginStage(steps, stageTelemetry, "notice-course-list");
  const courseUrlsOutput = runCommand(
    [
      "/usr/bin/env",
      `PYTHONPATH=${pythonPath}`,
      "python3",
      "-m",
      "klms_sync_v2.cli",
      "list-course-urls",
      "--dashboard-json",
      paths.dashboardJson,
    ],
    scriptDir
  );
  writeText(paths.courseUrlsTxt, courseUrlsOutput);
  const courseUrls = parseNonEmptyLines(courseUrlsOutput);

  beginStage(steps, stageTelemetry, "notice-course-fetch");
  const coursePages =
    courseUrls.length > 0
      ? fetchPages(courseUrls, waitSeconds, scriptDir, {
          ...baseFetchOptions,
          context: "notice-course-pages",
          staleSeconds: paths.coursePageStaleSeconds,
          outputPath: paths.coursePagesJson,
          summaryPath: paths.courseFetchSummaryJson,
          fallbackPagePaths: paths.courseFallbackPagePaths || [],
          reuseFallbackAlwaysFetch: true,
        })
      : [];
  assertNoLoginPages(
    "공지 정리를 위해 과목 페이지를 읽는 중 KLMS 로그인 세션이 풀렸어. 다시 로그인해 줘.",
    coursePages
  );

  const allWeekCourseUrls = uniqueStrings(courseUrls.map(toAllWeekCourseUrl).filter(Boolean));
  writeText(paths.allWeekCourseUrlsTxt, allWeekCourseUrls.join("\n"));

  beginStage(steps, stageTelemetry, "notice-all-week-course-fetch");
  const allWeekCoursePages =
    allWeekCourseUrls.length > 0
      ? fetchPages(allWeekCourseUrls, waitSeconds, scriptDir, {
          ...baseFetchOptions,
          context: "notice-all-week-course-pages",
          staleSeconds: paths.allWeekCoursePageStaleSeconds,
          outputPath: paths.allWeekCoursePagesJson,
          summaryPath: paths.allWeekCourseFetchSummaryJson,
          fallbackPagePaths: paths.allWeekCourseFallbackPagePaths || [],
          reuseFallbackAlwaysFetch: true,
        })
      : [];
  assertNoLoginPages(
    "공지 정리를 위해 과목 주간 페이지를 읽는 중 KLMS 로그인 세션이 풀렸어. 다시 로그인해 줘.",
    allWeekCoursePages
  );

  beginStage(steps, stageTelemetry, "notice-supplemental-primary-list");
  const supplementalPrimaryUrlsFromCourseOutput = runCommand(
    [
      "/usr/bin/env",
      `PYTHONPATH=${pythonPath}`,
      "python3",
      "-m",
      "klms_sync_v2.cli",
      "list-supplemental-urls",
      "--course-pages-json",
      paths.coursePagesJson,
      "--tier=primary",
    ],
    scriptDir
  );
  const supplementalPrimaryUrlsFromCourse = parseNonEmptyLines(
    supplementalPrimaryUrlsFromCourseOutput
  );

  let allWeekSupplementalPrimaryUrlsOutput = "";
  if (allWeekCourseUrls.length > 0) {
    beginStage(steps, stageTelemetry, "notice-all-week-supplemental-primary-list");
    allWeekSupplementalPrimaryUrlsOutput = runCommand(
      [
        "/usr/bin/env",
        `PYTHONPATH=${pythonPath}`,
        "python3",
        "-m",
        "klms_sync_v2.cli",
        "list-supplemental-urls",
        "--course-pages-json",
        paths.allWeekCoursePagesJson,
        "--tier=primary",
      ],
      scriptDir
    );
  }
  writeText(paths.allWeekSupplementalPrimaryUrlsTxt, allWeekSupplementalPrimaryUrlsOutput);

  const supplementalPrimaryUrls = filterNoticeBoardUrls([
    ...supplementalPrimaryUrlsFromCourse,
    ...parseNonEmptyLines(allWeekSupplementalPrimaryUrlsOutput),
  ]);
  writeText(paths.supplementalPrimaryUrlsTxt, supplementalPrimaryUrls.join("\n"));

  beginStage(steps, stageTelemetry, "notice-supplemental-primary-fetch");
  if (supplementalPrimaryUrls.length > 0) {
    const supplementalPrimaryPages = fetchPages(supplementalPrimaryUrls, waitSeconds, scriptDir, {
      ...baseFetchOptions,
      context: "notice-supplemental-primary-pages",
      outputPath: paths.supplementalPrimaryPagesJson,
      summaryPath: paths.supplementalPrimaryFetchSummaryJson,
      fullTtlSeconds: paths.syncFullTtlSeconds,
      quickLimit: paths.supplementalQuickLimit,
      staleSeconds: paths.supplementalStaleSeconds,
      alwaysFetchPatterns: paths.supplementalAlwaysFetchPatterns,
      fallbackPagePaths: paths.supplementalPrimaryFallbackPagePaths || [],
      reuseFallbackAlwaysFetch: true,
    });
    assertNoLoginPages(
      "공지 정리를 위해 공지 게시판을 읽는 중 KLMS 로그인 세션이 풀렸어. 다시 로그인해 줘.",
      supplementalPrimaryPages
    );
  } else {
    writeText(paths.supplementalPrimaryPagesJson, JSON.stringify([]));
  }

  beginStage(steps, stageTelemetry, "notice-board-pagination-list");
  const noticeBoardPageUrlsOutput = runCommand(
    [
      "/usr/bin/env",
      `PYTHONPATH=${pythonPath}`,
      "python3",
      "-m",
      "klms_sync_v2.cli",
      "list-notice-board-page-urls",
      "--supplemental-primary-pages-json",
      paths.supplementalPrimaryPagesJson,
    ],
    scriptDir
  );
  writeText(paths.noticeBoardPageUrlsTxt, noticeBoardPageUrlsOutput);
  const noticeBoardPageUrls = parseNonEmptyLines(noticeBoardPageUrlsOutput);

  if (noticeBoardPageUrls.length > 0) {
    beginStage(steps, stageTelemetry, "notice-board-pagination-fetch");
    const noticeBoardExtraPages = fetchPages(noticeBoardPageUrls, waitSeconds, scriptDir, {
      ...baseFetchOptions,
      context: "notice-board-extra-pages",
      outputPath: paths.noticeBoardExtraPagesJson,
      summaryPath: paths.noticeBoardExtraFetchSummaryJson,
      fullTtlSeconds: paths.syncFullTtlSeconds,
      quickLimit: paths.supplementalQuickLimit,
      staleSeconds: paths.supplementalStaleSeconds,
      alwaysFetchPatterns: paths.noticeBoardPaginationAlwaysFetchPatterns,
    });
    assertNoLoginPages(
      "공지 정리를 위해 공지 게시판 추가 페이지를 읽는 중 KLMS 로그인 세션이 풀렸어. 다시 로그인해 줘.",
      noticeBoardExtraPages
    );
    const mergedSupplementalPrimaryPages = mergePagesByRequestedUrl([
      ...loadPagesJson(paths.supplementalPrimaryPagesJson),
      ...noticeBoardExtraPages,
    ]);
    writeText(paths.supplementalPrimaryPagesJson, JSON.stringify(mergedSupplementalPrimaryPages));
  } else {
    writeText(paths.noticeBoardExtraPagesJson, JSON.stringify([]));
    writeText(
      paths.noticeBoardExtraFetchSummaryJson,
      JSON.stringify({
        context: "notice-board-extra-pages",
        backend: String((baseFetchOptions && baseFetchOptions.backend) || "safari"),
        requested_mode: "full",
        effective_mode: "noop",
        total_urls: 0,
        fetched_urls: 0,
        reused_urls: 0,
        changed_urls: 0,
        out_path: paths.noticeBoardExtraPagesJson,
        cache_state_path: String(
          (baseFetchOptions && baseFetchOptions.cacheStatePath) || ""
        ),
        fetched_url_list: [],
        reused_url_list: [],
        changed_url_list: [],
      })
    );
  }

  beginStage(steps, stageTelemetry, "notice-summary");
  const noticeSyncResult = syncNoticeSummary(
    scriptDir,
    waitSeconds,
    baseFetchOptions,
    paths,
    stageTelemetry
  );
  writeText(paths.noticeDigestErrorTxt, "");

  const noticeDigest = JSON.parse(readText(paths.noticeDigestJson));
  return {
    noticeCount: Number(noticeDigest.notice_count || 0),
    newCount: Number(noticeDigest.new_count || 0),
    updatedCount: Number(noticeDigest.updated_count || 0),
    courseCount: Array.isArray(noticeDigest.courses) ? noticeDigest.courses.length : 0,
    renderWarningCount: (noticeSyncResult.renderWarnings || []).length,
  };
}

function syncNoticeSummary(scriptDir, waitSeconds, baseFetchOptions, paths, stageTelemetry) {
  const pythonPath = buildPythonPath(scriptDir, `${scriptDir}/runtime`);
  const previousNoticeSummaryExists = fileExists(paths.noticeSummaryStateJson);
  const noticeArticleUrlsOutput = runTelemetryEvent(
    stageTelemetry,
    "notice-summary",
    "list-notice-article-urls",
    () =>
      runCommand(
        [
          "/usr/bin/env",
          `PYTHONPATH=${pythonPath}`,
          "python3",
          "-m",
          "klms_sync_v2.cli",
          "list-notice-article-urls",
          "--supplemental-primary-pages-json",
          paths.supplementalPrimaryPagesJson,
          "--course-pages-json",
          paths.coursePagesJson,
          "--notice-board-state-json",
          paths.noticeBoardStateJson,
          "--output-notice-board-state-json",
          paths.noticeBoardStatePendingJson,
          ...(previousNoticeSummaryExists
            ? ["--notice-summary-state-json", paths.noticeSummaryStateJson]
            : []),
        ],
        scriptDir
      )
  );

  writeText(paths.noticeArticleUrlsTxt, noticeArticleUrlsOutput);
  const noticeArticleUrls = parseNonEmptyLines(noticeArticleUrlsOutput);
  const noticeArticlePages =
    noticeArticleUrls.length > 0
      ? runTelemetryEvent(stageTelemetry, "notice-summary", "fetch-notice-article-pages", () =>
          fetchPages(noticeArticleUrls, waitSeconds, scriptDir, {
            ...baseFetchOptions,
            context: "sync-notice-article-pages",
            mode: "full",
            outputPath: paths.noticeArticlePagesJson,
            summaryPath: paths.noticeArticleFetchSummaryJson,
          })
        )
      : [];

  assertNoLoginPages(
    "공지 본문을 읽는 중 KLMS 로그인 세션이 풀렸어. 다시 로그인해 줘.",
    noticeArticlePages
  );

  if (noticeArticleUrls.length === 0) {
    writeText(paths.noticeArticlePagesJson, JSON.stringify(noticeArticlePages));
    writeText(
      paths.noticeArticleFetchSummaryJson,
      JSON.stringify({
        context: "sync-notice-article-pages",
        backend: String((baseFetchOptions && baseFetchOptions.backend) || "safari"),
        requested_mode: "full",
        effective_mode: "noop",
        total_urls: 0,
        fetched_urls: 0,
        reused_urls: 0,
        changed_urls: 0,
        out_path: paths.noticeArticlePagesJson,
        cache_state_path: String(
          (baseFetchOptions && baseFetchOptions.cacheStatePath) || ""
        ),
        fetched_url_list: [],
        reused_url_list: [],
        changed_url_list: [],
      })
    );
  }

  const noticeBoardStateForDigest = fileExists(paths.noticeBoardStatePendingJson)
    ? paths.noticeBoardStatePendingJson
    : paths.noticeBoardStateJson;

  runTelemetryEvent(
    stageTelemetry,
    "notice-summary",
    "build-notice-digest",
    () =>
      runCommand(
        [
          "/usr/bin/env",
          `PYTHONPATH=${pythonPath}`,
          "python3",
          "-m",
          "klms_sync_v2.cli",
          "build-notice-digest",
          "--notice-board-state-json",
          noticeBoardStateForDigest,
          "--notice-article-pages-json",
          paths.noticeArticlePagesJson,
          ...(previousNoticeSummaryExists
            ? ["--notice-summary-state-json", paths.noticeSummaryStateJson]
            : []),
          "--course-file-manifest-json",
          paths.courseFileManifestJson,
          "--overrides-json",
          paths.overridesJson,
          ...(paths.noticeAutoImportantKeywordsApply
            ? ["--auto-important-keywords-apply"]
            : []),
          "--output-notice-summary-state-json",
          paths.noticeSummaryStateJson,
          "--output-notice-digest-json",
          paths.noticeDigestJson,
        ],
        scriptDir
      )
  );
  if (fileExists(paths.noticeBoardStatePendingJson)) {
    runTelemetryEvent(stageTelemetry, "notice-summary", "move-notice-board-state", () =>
      moveFile(paths.noticeBoardStatePendingJson, paths.noticeBoardStateJson)
    );
  }

  if (paths.skipNativeRender) {
    writeText(paths.noticeNoteRenderWarningTxt, "");
    writeText(paths.noticeRenderErrorSummaryJson, JSON.stringify({ status: "ok" }, null, 2));
    return {
      results: [{ target: "render", status: "skipped", reason: "prebuild" }],
      renderWarnings: [],
    };
  }

  if (paths.dryRun) {
    writeText(paths.noticeNoteRenderWarningTxt, "");
    writeText(paths.noticeRenderErrorSummaryJson, JSON.stringify({ status: "ok" }, null, 2));
    return {
      results: [{ target: "render", status: "skipped", reason: "dry-run" }],
      renderWarnings: [],
    };
  }

  const renderResult = runTelemetryEvent(
    stageTelemetry,
    "notice-summary",
    "update-native-notice-notes",
    () =>
      updateNoticeNativeNote(
        scriptDir,
        paths.noticeNoteName || "KLMS 공지",
        paths.noticeArchiveNoteName || "KLMS 확인한 공지",
        paths.noticeDigestJson,
        paths.noticeUserStateJson,
        paths.noticeNoteRenderStateJson,
        paths.noticeArchiveNoteRenderStateJson,
        paths.noticeNativeStableNoopSkipEnabled,
        paths.noticeNativeAlwaysCaptureStateEnabled,
        paths.noticeNativeDeferStateOnlyRenderEnabled,
        paths.noticeNativeForceArchivePostCaptureRenderEnabled,
        paths.noticeNativeEnvironment || [],
        stageTelemetry
      )
  );
  const renderWarningText = (renderResult.renderWarnings || []).join("\n\n");
  const nonFatalRenderWarning = noticeRenderWarningsAreNonFatal(renderResult);
  if (renderWarningText) {
    const summary = classifyNoticeRenderError(renderWarningText);
    if (nonFatalRenderWarning) {
      summary.status = "warn";
      summary.nonfatal = true;
    }
    writeText(paths.noticeNoteRenderWarningTxt, renderWarningText);
    writeText(
      paths.noticeRenderErrorSummaryJson,
      JSON.stringify(summary, null, 2)
    );
  } else {
    writeText(paths.noticeNoteRenderWarningTxt, "");
    writeText(paths.noticeRenderErrorSummaryJson, JSON.stringify({ status: "ok" }, null, 2));
  }
  if (stageTelemetry && renderResult.results) {
    stageTelemetry.noticeRenderResults = renderResult.results;
    persistStageTelemetry(stageTelemetry);
  }
  if (renderWarningText && !nonFatalRenderWarning) {
    throw new Error(renderWarningText);
  }
  return renderResult;
}

function noticeRenderWarningsAreNonFatal(renderResult) {
  if (envValue("KLMS_APP_RUN") === "1") {
    return false;
  }
  const results = Array.isArray(renderResult && renderResult.results)
    ? renderResult.results
    : [];
  if (results.some((item) =>
    item &&
    item.target === "render" &&
    item.status === "skipped" &&
    item.reason === "capture-failed-preserve-user-state"
  )) {
    return true;
  }
  const warnings = results.filter((item) => item && item.status === "warning");
  return warnings.length > 0 && warnings.every((item) =>
    noticeRenderWarningIsRecoverable(item.error)
  );
}

function noticeRenderWarningIsRecoverable(text) {
  return /Could not confirm the cursor is in the target Notes note|Could not place the cursor in the target Notes editor|Could not confirm Notes selection|Focused UI element is not inside the target Notes editor|Typing target is not Notes|Notes selection moved away from the target note/i.test(
    String(text || "")
  );
}

function sleepSeconds(seconds) {
  $.NSThread.sleepForTimeInterval(Math.max(0, Number(seconds) || 0));
}

function runNativeNoticeCommandWithRecoverableRetry(stageTelemetry, targetName, command, scriptDir) {
  const maxAttempts = 2;
  let lastError = null;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      return runTelemetryEvent(
        stageTelemetry,
        "native-notice-note",
        targetName,
        () => runCommand(command, scriptDir)
      );
    } catch (error) {
      lastError = error;
      if (!noticeRenderWarningIsRecoverable(String(error)) || attempt >= maxAttempts) {
        throw error;
      }
      debugStderr(
        `native notice ${targetName} retrying after recoverable focus warning ` +
          `attempt=${attempt}/${maxAttempts}`
      );
      sleepSeconds(1.25);
    }
  }
  throw lastError;
}

function classifyNoticeRenderError(text) {
  const message = String(text || "");
  const firstLine = message.split(/\r?\n/).find(Boolean) || "";
  let code = "unknown";
  let userMessage = "공지 메모 렌더링 오류를 확인해 주세요.";
  if (/not authorized|permission|not permitted|Automation|권한/i.test(message)) {
    code = "notes_permission_denied";
    userMessage = "Notes 권한 확인 필요";
  } else if (/capture-failed-preserve-user-state|capture/i.test(message)) {
    code = "capture_state_failed";
    userMessage = "읽음/중요 체크 상태 캡처 실패";
  } else if (/Could not confirm the cursor is in the target Notes note|Could not place the cursor in the target Notes editor|Could not confirm Notes selection|Focused UI element is not inside the target Notes editor|Typing target is not Notes|Notes selection moved away from the target note/i.test(message)) {
    code = "notes_focus_unconfirmed";
    userMessage = "Notes 포커스 확인 실패";
  } else if (/readability-format-check-failed|readable|format/i.test(message)) {
    code = "readability_format_failed";
    userMessage = "공지 문단 형식 검증 실패";
  } else if (/checklist|stray/i.test(message)) {
    code = "checklist_validation_failed";
    userMessage = "공지 체크리스트 검증 실패";
  } else if (/timed out|timeout/i.test(message)) {
    code = "render_timeout";
    userMessage = "공지 메모 렌더링 시간 초과";
  }
  return { status: "error", code, user_message: userMessage, raw_first_line: firstLine };
}

function nativeNoticeEnvironment(config) {
  const keys = [
    "NOTICE_COLLAPSE_SECTIONS",
    "NOTICE_COLLAPSE_COURSES",
    "NOTICE_COLLAPSE_NOTICE_ITEMS",
    "NOTICE_STYLE_NOTICE_ITEMS_AS_HEADINGS",
    "NOTICE_HIDE_HIDDEN_ITEMS",
    "NOTICE_NATIVE_ENABLE_BATCH_CHECKLIST_FORMAT",
    "NOTICE_NATIVE_DISABLE_BATCH_CHECKLIST_FORMAT",
    "NOTICE_NATIVE_DISABLE_FAST_CHECKLIST_FORMAT",
    "NOTICE_NATIVE_ENABLE_UI_STYLE_FORMAT",
    "NOTICE_NATIVE_DISABLE_UI_STYLE_FORMAT",
    "NOTICE_NATIVE_FORCE_ARCHIVE_POST_CAPTURE_RENDER",
    "NOTICE_NATIVE_VERIFY_STABLE_SKIP_FORMAT",
    "NOTICE_NATIVE_POST_RENDER_VERIFY",
    "NOTICE_NATIVE_INITIAL_COLLAPSE_ENABLED",
    "NOTICE_NATIVE_CONSERVATIVE_RENDER_FALLBACK",
    "NOTICE_NATIVE_NOTE_MAX_ATTEMPTS",
    "NOTICE_NATIVE_NOTE_RETRY_DELAY_SECONDS",
    "NOTICE_NATIVE_NOTE_TIMEOUT_SECONDS",
    "NOTICE_NATIVE_NOTE_TIMEOUT_GRACE_SECONDS",
    "NOTICE_NATIVE_STYLE_BUDGET_SECONDS",
    "NOTICE_NATIVE_BOLD_REINFORCE_LIMIT",
    "NOTICE_NATIVE_VALIDATE_STYLE",
    "NOTICE_NATIVE_SELECTION_SETTLE_SECONDS",
    "NOTICE_NATIVE_CHECKLIST_PRESS_SETTLE_US",
    "NOTICE_NATIVE_PREFORMATTED_PASTE_ONLY",
    "NOTICE_NATIVE_PLAIN_TEXT_PASTE",
    "NOTICE_DEBUG_CAPTURE",
    "NOTICE_DEBUG_AUTOMATION",
    "NOTICE_TIMING",
  ];
  return keys
    .filter((key) => Object.prototype.hasOwnProperty.call(config, key))
    .map((key) => [key, normalizeRuntimeEnvValue(config[key])])
    .filter((entry) => entry[1] !== "")
    .map((entry) => `${entry[0]}=${entry[1]}`);
}

function noticeTargetRequiresPostCaptureRender(
  targetKey,
  forceArchivePostCaptureRenderEnabled
) {
  return targetKey === "archive" && forceArchivePostCaptureRenderEnabled === true;
}

function nativeNoticeEnvHasKey(nativeEnvironment, key) {
  return (Array.isArray(nativeEnvironment) ? nativeEnvironment : []).some((entry) =>
    String(entry || "").startsWith(`${key}=`)
  );
}

function nativeNoticeDefaultEnvironment(nativeEnvironment) {
  const defaults = [];
  if (!nativeNoticeEnvHasKey(nativeEnvironment, "NOTICE_NATIVE_PLAIN_TEXT_PASTE")) {
    defaults.push("NOTICE_NATIVE_PLAIN_TEXT_PASTE=0");
  }
  if (!nativeNoticeEnvHasKey(nativeEnvironment, "NOTICE_NATIVE_NOTE_MAX_ATTEMPTS")) {
    defaults.push("NOTICE_NATIVE_NOTE_MAX_ATTEMPTS=3");
  }
  if (!nativeNoticeEnvHasKey(nativeEnvironment, "NOTICE_NATIVE_NOTE_RETRY_DELAY_SECONDS")) {
    defaults.push("NOTICE_NATIVE_NOTE_RETRY_DELAY_SECONDS=2");
  }
  return defaults;
}

function nativeNoticeVerifyStableSkipFormatEnabled(nativeEnvironment) {
  return nativeNoticeEnvironmentEnabled(
    nativeEnvironment,
    "NOTICE_NATIVE_VERIFY_STABLE_SKIP_FORMAT",
    false
  );
}

function nativeNoticePostRenderVerifyEnabled(nativeEnvironment) {
  return nativeNoticeEnvironmentEnabled(
    nativeEnvironment,
    "NOTICE_NATIVE_POST_RENDER_VERIFY",
    true
  );
}

function nativeNoticeEnvironmentEnabled(nativeEnvironment, key, fallback) {
  const value = nativeNoticeEnvironmentValue(nativeEnvironment, key);
  if (value === null) {
    return fallback;
  }
  if (/^(1|true|yes|on)$/i.test(value)) {
    return true;
  }
  if (/^(0|false|no|off)$/i.test(value)) {
    return false;
  }
  return fallback;
}

function nativeNoticeEnvironmentValue(nativeEnvironment, key) {
  const combined = Array.isArray(nativeEnvironment) ? nativeEnvironment : [];
  const prefix = `${key}=`;
  const entry = combined.find((item) => String(item || "").startsWith(prefix));
  if (!entry) {
    return null;
  }
  return String(entry).slice(prefix.length).trim();
}

function updateNoticeNativeNote(
  scriptDir,
  noteName,
  archiveNoteName,
  noticeDigestJsonPath,
  noticeUserStateJsonPath,
  noticeRenderStateJsonPath,
  archiveNoticeRenderStateJsonPath,
  stableNoopSkipEnabled,
  alwaysCaptureStateEnabled,
  deferStateOnlyRenderEnabled,
  forceArchivePostCaptureRenderEnabled,
  nativeEnvironment,
  stageTelemetry
) {
  const commonArgs = [
    "--note-title",
    noteName,
    "--archive-note-title",
    archiveNoteName,
    "--notice-state-json",
    noticeUserStateJsonPath,
    "--render-state-json",
    noticeRenderStateJsonPath,
    "--archive-render-state-json",
    archiveNoticeRenderStateJsonPath,
    noticeDigestJsonPath,
  ];
  const captureArgs = ["--capture-only", ...commonArgs];
  const nativeEnv = Array.isArray(nativeEnvironment) ? nativeEnvironment : [];
  const nativeDefaultEnv = nativeNoticeDefaultEnvironment(nativeEnv);
  const effectiveNativeEnv = [...nativeDefaultEnv, ...nativeEnv];
  const nativeCommand = (args, extraEnv) => [
    "/usr/bin/env",
    ...nativeDefaultEnv,
    ...nativeEnv,
    ...(extraEnv || []),
    `${scriptDir}/src/sh/update_notice_native_note.sh`,
    ...args,
  ];
  const captureCommand = nativeCommand(
    captureArgs,
    alwaysCaptureStateEnabled === false ? [] : ["NOTICE_CAPTURE_STABLE_WITH_UI=1"]
  );
  const targets = [
    { key: "archive", args: ["--render-only", "--archive-only"] },
    { key: "primary", args: ["--render-only", "--primary-only"] },
  ];
  const verifyNativeNoticeReadableFormat = (targetKey) =>
    verifyNoticeNativeNoteReadableFormat(
      targetKey,
      targetKey === "archive" ? archiveNoticeRenderStateJsonPath : noticeRenderStateJsonPath,
      nativeCommand([
        "--verify-only",
        targetKey === "archive" ? "--archive-only" : "--primary-only",
        ...commonArgs,
      ], []),
      scriptDir
    );
  const hasPostCaptureRenderTarget = targets.some((target) =>
    noticeTargetRequiresPostCaptureRender(target.key, forceArchivePostCaptureRenderEnabled)
  );
  const results = [];
  const renderWarnings = [];
  const verifyStableSkipFormatEnabled =
    nativeNoticeVerifyStableSkipFormatEnabled(effectiveNativeEnv);
  const postRenderVerifyEnabled =
    nativeNoticePostRenderVerifyEnabled(effectiveNativeEnv);
  let stableComparison = null;
  let captureSucceeded = false;

  if (
    stableNoopSkipEnabled !== false &&
    alwaysCaptureStateEnabled === false &&
    !hasPostCaptureRenderTarget
  ) {
    stableComparison = noticeNativeRenderComparison(
      noticeDigestJsonPath,
      noticeUserStateJsonPath,
      noticeRenderStateJsonPath,
      archiveNoticeRenderStateJsonPath,
      effectiveNativeEnv
    );
    if (
      stableComparison.canCompare &&
      stableComparison.primary.matches &&
      stableComparison.archive.matches
    ) {
      try {
        const formatOutputs = verifyStableSkipFormatEnabled
          ? [
              verifyNativeNoticeReadableFormat("archive"),
              verifyNativeNoticeReadableFormat("primary"),
            ]
          : [];
        const output = [
          `Skipped native notice notes: stable_noop=1 capture=skipped notice_count=${stableComparison.expected.total} ` +
            `primary=${stableComparison.expected.primary.length} archived=${stableComparison.expected.archive.length}`,
          ...formatOutputs,
        ].filter(Boolean).join("\n");
        debugStderr(String(output || "skip native notice notes stable-noop-before-capture"));
        results.push({
          target: "stable-noop-before-capture",
          status: "skipped",
          output,
        });
        return { results, renderWarnings };
      } catch (error) {
        const reason = `readability-format-check-failed: ${String(error)}`;
        results.push({
          target: "stable-noop-before-capture",
          status: "not-skipped",
          reason,
        });
        debugStderr(`native notice stable-noop before capture not skipped: ${reason}`);
      }
    } else if (!stableComparison.canCompare && stableComparison.reason) {
      debugStderr(`native notice stable-noop before capture not skipped: ${stableComparison.reason}`);
    }
  }

  try {
    const shouldRunCapture = alwaysCaptureStateEnabled !== false;
    const output = shouldRunCapture
      ? runNativeNoticeCommandWithRecoverableRetry(
        stageTelemetry,
        "capture",
        captureCommand,
        scriptDir
      )
      : "Skipped native notice checklist capture: always_capture_state=0";
    results.push({
      target: "capture",
      status: shouldRunCapture ? "ok" : "skipped",
      output: String(output || "").trim(),
    });
    captureSucceeded = true;
  } catch (error) {
    const message = `Native notice note render warning (capture): ${String(error)}`;
    results.push({
      target: "capture",
      status: "warning",
      error: String(error),
    });
    renderWarnings.push(message);
    debugStderr(message);
  }

  if (!captureSucceeded) {
    results.push({
      target: "render",
      status: "skipped",
      reason: "capture-failed-preserve-user-state",
    });
    debugStderr("native notice render skipped: capture failed, preserving existing checklist state");
    return { results, renderWarnings };
  }

  if (stableNoopSkipEnabled !== false) {
    if (!stableComparison) {
      stableComparison = noticeNativeRenderComparison(
        noticeDigestJsonPath,
        noticeUserStateJsonPath,
        noticeRenderStateJsonPath,
        archiveNoticeRenderStateJsonPath,
        effectiveNativeEnv
      );
    }
    if (
      stableComparison.canCompare &&
      stableComparison.primary.matches &&
      stableComparison.archive.matches &&
      !hasPostCaptureRenderTarget
    ) {
      try {
        const formatOutputs = verifyStableSkipFormatEnabled
          ? [
              verifyNativeNoticeReadableFormat("archive"),
              verifyNativeNoticeReadableFormat("primary"),
            ]
          : [];
        const output = [
          `Skipped native notice notes: stable_noop=1 notice_count=${stableComparison.expected.total} ` +
            `primary=${stableComparison.expected.primary.length} archived=${stableComparison.expected.archive.length}`,
          ...formatOutputs,
        ].filter(Boolean).join("\n");
        debugStderr(String(output || "skip native notice notes stable-noop-after-capture"));
        results.push({
          target: "stable-noop-after-capture",
          status: "skipped",
          output,
        });
        return { results, renderWarnings };
      } catch (error) {
        const reason = `readability-format-check-failed: ${String(error)}`;
        results.push({
          target: "stable-noop-after-capture",
          status: "not-skipped",
          reason,
        });
        debugStderr(`native notice stable-noop after capture not skipped: ${reason}`);
      }
    }
    if (!stableComparison.canCompare && stableComparison.reason) {
      debugStderr(`native notice stable-noop after capture not skipped: ${stableComparison.reason}`);
    } else if (stableComparison.canCompare) {
      const differingTargets = ["archive", "primary"].filter(
        (key) => !stableComparison[key].matches
      );
      if (differingTargets.length > 0) {
        debugStderr(
          `native notice stable-noop after capture partially differs: ${differingTargets.join(",")}`
        );
      }
    }
  }

  if (
    deferStateOnlyRenderEnabled !== false &&
    stableComparison &&
    stableComparison.canCompare &&
    stableComparison.stateOnlyDiff &&
    !hasPostCaptureRenderTarget
  ) {
    const differingTargets = ["archive", "primary"].filter(
      (key) => !stableComparison[key].matches
    );
    try {
      const formatOutputs = verifyStableSkipFormatEnabled
        ? [
            verifyNativeNoticeReadableFormat("archive"),
            verifyNativeNoticeReadableFormat("primary"),
          ]
        : [];
      const output = [
        `Deferred native notice notes: state_only=1 differing=${differingTargets.join(",")} ` +
          `notice_count=${stableComparison.expected.total} ` +
          `primary=${stableComparison.expected.primary.length} archived=${stableComparison.expected.archive.length}`,
        ...formatOutputs,
      ].filter(Boolean).join("\n");
      debugStderr(output);
      results.push({
        target: "state-only-render-deferred",
        status: "skipped",
        output,
      });
      return { results, renderWarnings };
    } catch (error) {
      const reason = `readability-format-check-failed: ${String(error)}`;
      results.push({
        target: "state-only-render-deferred",
        status: "not-skipped",
        reason,
      });
      debugStderr(`native notice state-only render not deferred: ${reason}`);
    }
  }

  targets.forEach((target) => {
    try {
      const targetComparison =
        stableNoopSkipEnabled !== false &&
        stableComparison &&
        stableComparison.canCompare
          ? stableComparison[target.key]
          : null;
      const mustRenderAfterCapture = noticeTargetRequiresPostCaptureRender(
        target.key,
        forceArchivePostCaptureRenderEnabled
      );
      if (targetComparison && targetComparison.matches && !mustRenderAfterCapture) {
        try {
          const formatOutput = verifyStableSkipFormatEnabled
            ? verifyNativeNoticeReadableFormat(target.key)
            : "";
          const output =
            `Skipped native notice note: target=${target.key} stable_noop=1 ` +
            `notices=${targetComparison.expectedLength}` +
            (formatOutput ? `\n${formatOutput}` : "");
          debugStderr(output);
          results.push({
            target: `${target.key}-stable-noop`,
            status: "skipped",
            output,
          });
          return;
        } catch (error) {
          debugStderr(
            `native notice target stable-noop not skipped: target=${target.key} ` +
              `reason=readability-format-check-failed: ${String(error)}`
          );
        }
      }

      const output = runNativeNoticeCommandWithRecoverableRetry(
        stageTelemetry,
        target.key,
        nativeCommand([...target.args, ...commonArgs], []),
        scriptDir
      );
      const formatOutput = postRenderVerifyEnabled
        ? verifyNativeNoticeReadableFormat(target.key)
        : "";
      results.push({
        target: target.key,
        status: "ok",
        output: [String(output || "").trim(), formatOutput].filter(Boolean).join("\n"),
      });
    } catch (error) {
      const message = `Native notice note render warning (${target.key}): ${String(error)}`;
      results.push({
        target: target.key,
        status: "warning",
        error: String(error),
      });
      renderWarnings.push(message);
      debugStderr(message);
    }
  });

  return { results, renderWarnings };
}

function noticeRenderStyleVersion(renderStateJsonPath) {
  if (!renderStateJsonPath || !fileExists(renderStateJsonPath)) {
    return "";
  }
  try {
    const state = JSON.parse(readText(renderStateJsonPath));
    return String(state && state.style_version || "");
  } catch (error) {
    return "";
  }
}

function verifyNoticeNativeNoteReadableFormat(targetKey, renderStateJsonPath, command, scriptDir) {
  const styleVersion = noticeRenderStyleVersion(renderStateJsonPath);
  if (styleVersion !== NATIVE_NOTICE_RENDER_STYLE_VERSION) {
    throw new Error(
      `Native notice note readability format stale (${targetKey}): ` +
        `style_version=${styleVersion || "unknown"}`
    );
  }
  const verificationOutput = runCommand(command, scriptDir);
  return [
    `Verified native notice readability format: ${targetKey} style_version=${styleVersion}`,
    String(verificationOutput || "").trim(),
  ].filter(Boolean).join("\n");
}

function maybeSkipStableNoticeNativeUpdate(
  noticeDigestJsonPath,
  noticeUserStateJsonPath,
  noticeRenderStateJsonPath,
  archiveNoticeRenderStateJsonPath,
  nativeEnvironment
) {
  const comparison = noticeNativeRenderComparison(
    noticeDigestJsonPath,
    noticeUserStateJsonPath,
    noticeRenderStateJsonPath,
    archiveNoticeRenderStateJsonPath,
    nativeEnvironment
  );
  if (!comparison.canCompare) {
    return { skipped: false, reason: comparison.reason };
  }
  if (!comparison.primary.matches) {
    return { skipped: false, reason: "primary-render-state-differs" };
  }
  if (!comparison.archive.matches) {
    return { skipped: false, reason: "archive-render-state-differs" };
  }
  return {
    skipped: true,
    output:
      `Skipped native notice notes: stable_noop=1 notice_count=${comparison.expected.total} ` +
      `primary=${comparison.expected.primary.length} archived=${comparison.expected.archive.length}`,
  };
}

function noticeNativeRenderComparison(
  noticeDigestJsonPath,
  noticeUserStateJsonPath,
  noticeRenderStateJsonPath,
  archiveNoticeRenderStateJsonPath,
  nativeEnvironment
) {
  const digest = JSON.parse(readText(noticeDigestJsonPath));
  if (noticeDigestHasFreshNotices(digest)) {
    return { canCompare: false, reason: "digest-has-fresh-notices" };
  }
  if (Number(digest.new_count || 0) > 0 || Number(digest.updated_count || 0) > 0) {
    return { canCompare: false, reason: "digest-counts-fresh" };
  }
  if (!fileExists(noticeRenderStateJsonPath) || !fileExists(archiveNoticeRenderStateJsonPath)) {
    return { canCompare: false, reason: "render-state-missing" };
  }

  const userState = loadNoticeUserState(noticeUserStateJsonPath, digest);

  const primaryRenderState = JSON.parse(readText(noticeRenderStateJsonPath));
  const archiveRenderState = JSON.parse(readText(archiveNoticeRenderStateJsonPath));
  const expected = expectedNoticeNativeRenderState(digest, userState, nativeEnvironment);
  const primary = compareRenderStateToExpected(
    primaryRenderState,
    expected.primary,
    "primary",
    nativeEnvironment
  );
  const archive = compareRenderStateToExpected(
    archiveRenderState,
    expected.archive,
    "archive",
    nativeEnvironment
  );
  const stateOnlyDiff =
    (!primary.matches || !archive.matches) &&
    primary.styleVersionMatches &&
    archive.styleVersionMatches &&
    renderStateNoticeKeys(primaryRenderState).join("\n") ===
      expectedNoticeKeys(expected.primary).join("\n") &&
    renderStateNoticeKeys(archiveRenderState).join("\n") ===
      expectedNoticeKeys(expected.archive).join("\n");
  return {
    canCompare: true,
    expected,
    stateOnlyDiff,
    primary,
    archive,
  };
}

function loadNoticeUserState(path, digest) {
  if (fileExists(path)) {
    const loaded = JSON.parse(readText(path));
    loaded.notices = loaded.notices && typeof loaded.notices === "object" ? loaded.notices : {};
    return loaded;
  }
  return {
    version: 1,
    updated_at: String(digest.generated_at || ""),
    notices: {},
  };
}

function noticeDigestHasFreshNotices(digest) {
  return (digest.courses || []).some((course) =>
    (course.notices || []).some((notice) => {
      const changeState = String(notice.change_state || "stable");
      return changeState === "new" || changeState === "updated";
    })
  );
}

function expectedNoticeNativeRenderState(digest, userState, nativeEnvironment) {
  const primaryImportant = [];
  const primaryFresh = [];
  const primaryUnread = [];
  const primaryAllVisible = [];
  const archive = [];
  let total = 0;
  const hideHidden = nativeNoticeEnvironmentEnabled(
    nativeEnvironment,
    "NOTICE_HIDE_HIDDEN_ITEMS",
    true
  );
  (digest.courses || []).forEach((course) => {
    const courseName = String(course.course || "");
    const importantCourse = [];
    const freshCourse = [];
    const unreadCourse = [];
    const allVisibleCourse = [];
    const archiveCourse = [];
    (course.notices || []).forEach((notice) => {
      total += 1;
      const noticeId = noticeIdentifierForDigestNotice(courseName, notice);
      const fingerprint = String(notice.fingerprint || "");
      const state = userState.notices[noticeId] || {};
      const isImportant = state.important === true;
      const isRead = noticeInteractionStateIsRead(state, fingerprint);
      const isHidden = state.hidden === true;
      if (hideHidden && isHidden) {
        return;
      }
      const changeState = String(notice.change_state || "stable");
      const isFresh = changeState === "new" || changeState === "updated";
      const rendered = (shouldCheckRead, shouldCheckImportant) => ({
        notice_id: noticeId,
        fingerprint,
        should_check_read: Boolean(shouldCheckRead),
        should_check_important: Boolean(shouldCheckImportant),
      });
      allVisibleCourse.push(rendered(isRead, isImportant));
      if (isImportant) {
        importantCourse.push(rendered(isRead, true));
      } else if (!isRead) {
        if (isFresh) {
          freshCourse.push(rendered(false, false));
        } else {
          unreadCourse.push(rendered(false, false));
        }
      }
      if (isRead && !isImportant) {
        archiveCourse.push(rendered(true, false));
      }
    });
    primaryImportant.push(...importantCourse);
    primaryFresh.push(...freshCourse);
    primaryUnread.push(...unreadCourse);
    primaryAllVisible.push(...allVisibleCourse);
    archive.push(...archiveCourse);
  });
  const groupedPrimary = [...primaryImportant, ...primaryFresh, ...primaryUnread];
  const primary = groupedPrimary.length > 0 ? groupedPrimary : primaryAllVisible;
  return { primary, archive, total };
}

function noticeInteractionStateIsRead(state, fingerprint) {
  if (String(state && state.read_at || "").trim()) {
    return true;
  }
  return Boolean(fingerprint) && String(state && state.read_fingerprint || "") === fingerprint;
}

function renderStateMatchesExpected(renderState, expected) {
  return compareRenderStateToExpected(renderState, expected, "primary", []).matches;
}

function compareRenderStateToExpected(renderState, expected, targetKey, nativeEnvironment) {
  const expectedLength = Array.isArray(expected) ? expected.length : 0;
  if (String(renderState && renderState.style_version || "") !== NATIVE_NOTICE_RENDER_STYLE_VERSION) {
    return {
      matches: false,
      reason: "style-version-differs",
      expectedLength,
      styleVersionMatches: false,
    };
  }
  const expectedSignature = noticeExpectedRenderSignature(expected, targetKey, nativeEnvironment);
  const actualSignature = String(renderState && renderState.render_signature || "");
  if (!actualSignature) {
    return {
      matches: false,
      reason: "render-signature-missing",
      expectedLength,
      styleVersionMatches: true,
    };
  }
  if (actualSignature !== expectedSignature) {
    return {
      matches: false,
      reason: "render-signature-differs",
      expectedLength,
      styleVersionMatches: true,
    };
  }
  const rendered = (renderState && renderState.rendered_notices) || [];
  if (!Array.isArray(rendered) || rendered.length !== expected.length) {
    return {
      matches: false,
      reason: "notice-count-differs",
      expectedLength,
      styleVersionMatches: true,
    };
  }
  for (let index = 0; index < expected.length; index += 1) {
    const actual = rendered[index] || {};
    const desired = expected[index] || {};
    if (String(actual.notice_id || "") !== String(desired.notice_id || "")) {
      return {
        matches: false,
        reason: "notice-order-differs",
        expectedLength,
        styleVersionMatches: true,
      };
    }
    if (String(actual.fingerprint || "") !== String(desired.fingerprint || "")) {
      return {
        matches: false,
        reason: "notice-fingerprint-differs",
        expectedLength,
        styleVersionMatches: true,
      };
    }
    if (
      actual.should_check_read != null &&
      Boolean(actual.should_check_read) !== Boolean(desired.should_check_read)
    ) {
      return {
        matches: false,
        reason: "read-check-state-differs",
        expectedLength,
        styleVersionMatches: true,
      };
    }
    if (
      actual.should_check_important != null &&
      Boolean(actual.should_check_important) !== Boolean(desired.should_check_important)
    ) {
      return {
        matches: false,
        reason: "important-check-state-differs",
        expectedLength,
        styleVersionMatches: true,
      };
    }
  }
  return {
    matches: true,
    reason: "",
    expectedLength,
    styleVersionMatches: true,
  };
}

function noticeExpectedRenderSignature(expected, targetKey, nativeEnvironment) {
  const components = noticeRenderSignatureComponents(targetKey, nativeEnvironment);
  (Array.isArray(expected) ? expected : []).forEach((notice) => {
    components.push([
      String(notice.notice_id || ""),
      String(notice.fingerprint || ""),
      notice.should_check_read ? "read=1" : "read=0",
      notice.should_check_important ? "important=1" : "important=0",
    ].join("|"));
  });
  return stableHash(components.join("\u001f"));
}

function noticeRenderSignatureComponents(targetKey, nativeEnvironment) {
  const displayMode = targetKey === "archive" ? "archive" : "primary";
  const initialCollapseEnabled =
    nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_NATIVE_INITIAL_COLLAPSE_ENABLED", true);
  const collapseSections =
    initialCollapseEnabled &&
    nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_COLLAPSE_SECTIONS", false);
  const collapseCourses =
    initialCollapseEnabled &&
    nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_COLLAPSE_COURSES", false);
  const collapseNoticeItems =
    initialCollapseEnabled &&
    nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_COLLAPSE_NOTICE_ITEMS", false);
  const batchChecklist =
    nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_NATIVE_ENABLE_BATCH_CHECKLIST_FORMAT", false) &&
    !nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_NATIVE_DISABLE_BATCH_CHECKLIST_FORMAT", false);
  const fastBatchChecklist =
    batchChecklist &&
    !nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_NATIVE_DISABLE_FAST_CHECKLIST_FORMAT", false);
  const uiStyleMenu =
    nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_NATIVE_ENABLE_UI_STYLE_FORMAT", false) &&
    !nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_NATIVE_DISABLE_UI_STYLE_FORMAT", false);
  return [
    NATIVE_NOTICE_RENDER_STYLE_VERSION,
    `display_mode=${displayMode}`,
    `collapse_sections=${collapseSections ? "1" : "0"}`,
    `collapse_courses=${collapseCourses ? "1" : "0"}`,
    `collapse_notice_items=${collapseNoticeItems ? "1" : "0"}`,
    `style_notice_items=${nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_STYLE_NOTICE_ITEMS_AS_HEADINGS", false) ? "1" : "0"}`,
    `hide_hidden=${nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_HIDE_HIDDEN_ITEMS", true) ? "1" : "0"}`,
    `ui_style_menu=${uiStyleMenu ? "1" : "0"}`,
    `preformatted_paste_only=${nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_NATIVE_PREFORMATTED_PASTE_ONLY", false) ? "1" : "0"}`,
    `plain_text_paste=${nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_NATIVE_PLAIN_TEXT_PASTE", false) ? "1" : "0"}`,
    `batch_checklist=${batchChecklist ? "1" : "0"}`,
    `fast_batch_checklist=${fastBatchChecklist ? "1" : "0"}`,
  ];
}

function renderStateNoticeKeys(renderState) {
  const rendered = (renderState && renderState.rendered_notices) || [];
  if (!Array.isArray(rendered)) {
    return [];
  }
  return expectedNoticeKeys(rendered);
}

function expectedNoticeKeys(notices) {
  if (!Array.isArray(notices)) {
    return [];
  }
  return notices.map((notice) =>
    `${String(notice && notice.notice_id || "")}\u0000${String(notice && notice.fingerprint || "")}`
  );
}

function noticeIdentifierForDigestNotice(courseName, notice) {
  const url = String(notice.url || "").trim();
  if (url) {
    return url;
  }
  const articleId = String(notice.article_id || "").trim();
  if (articleId) {
    return `article:${articleId}`;
  }
  return `${courseName}|${oneLineText(notice.title)}|${oneLineText(notice.posted_at)}`;
}

function oneLineText(value) {
  return String(value || "")
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .split("\n")
    .map((part) => part.trim())
    .filter(Boolean)
    .join(" ");
}
