#!/usr/bin/osascript -l JavaScript

ObjC.import("Foundation");

const MARKER = "[[KLMS 자동 동기화]]";
const NATIVE_NOTICE_RENDER_STYLE_VERSION = "2026-05-27-functional-notes-v17-archive-style-aliases";
let DEBUG_STDERR_ENABLED = false;
let ACTIVE_STAGE_TELEMETRY = null;
let COMMAND_TIMING_ENABLED = true;
let COMMAND_TIMING_MIN_DURATION_MS = 0;

eval(readText(`${scriptDirectory()}/src/js/sync_calendar_bridge.js`));
eval(readText(`${scriptDirectory()}/src/js/sync_reminders_bridge.js`));
eval(readText(`${scriptDirectory()}/src/js/sync_notice_bridge.js`));
if (
  typeof syncCalendarsFromState !== "function" ||
  typeof syncRemindersFromState !== "function" ||
  typeof syncNoticeSummary !== "function"
) {
  throw new Error("Failed to load sync bridge modules.");
}

function parseCliArgs(argv, scriptDir) {
  const args = Array.isArray(argv) ? argv.slice() : [];
  let configPath = `${scriptDir}/config.env`;
  let scope = "core";
  let usePrefetchedDashboard = false;
  let dryRun = false;

  args.forEach((arg) => {
    const value = String(arg || "").trim();
    if (!value) {
      return;
    }
    if (value.startsWith("--scope=")) {
      const parsedScope = value.slice("--scope=".length).trim().toLowerCase();
      if (!["core", "notice", "all"].includes(parsedScope)) {
        throw new Error(`Unsupported scope: ${parsedScope}`);
      }
      scope = parsedScope;
      return;
    }
    if (value === "--use-prefetched-dashboard") {
      usePrefetchedDashboard = true;
      return;
    }
    if (value === "--dry-run") {
      dryRun = true;
      return;
    }
    if (value.startsWith("--")) {
      throw new Error(`Unknown argument: ${value}`);
    }
    configPath = value;
  });

  return { configPath, scope, usePrefetchedDashboard, dryRun };
}

function run(argv) {
  const steps = [];
  const stageTelemetry = createStageTelemetry("");
  ACTIVE_STAGE_TELEMETRY = stageTelemetry;
  try {
    beginStage(steps, stageTelemetry, "start");
    const scriptDir = scriptDirectory();
    const cli = parseCliArgs(argv, scriptDir);

    beginStage(steps, stageTelemetry, "current-dir");
    const configPath = cli.configPath;
    const scope = cli.scope;
    const usePrefetchedDashboard = cli.usePrefetchedDashboard;
    const config = parseEnvFile(configPath);
    applyRuntimeConfigOverrides(config);
    const dryRun = cli.dryRun || envValue("KLMS_DRY_RUN") === "1";
    DEBUG_STDERR_ENABLED = config.KLMS_DEBUG_STDERR === "1";
    COMMAND_TIMING_ENABLED = config.SYNC_COMMAND_TIMING_ENABLED !== "0";
    COMMAND_TIMING_MIN_DURATION_MS = Math.max(
      0,
      Math.round(Number(config.SYNC_COMMAND_TIMING_MIN_DURATION_MS || "0"))
    );
    debugStderr(`sync start scope=${scope}`);
    const examCalendarEnabled = config.EXAM_CALENDAR_SYNC_ENABLED !== "0";
    const helpDeskCalendarEnabled = config.HELP_DESK_CALENDAR_SYNC_ENABLED === "1";
    const remindersEnabled = config.REMINDERS_SYNC_ENABLED === "1";
    const noticeSummaryEnabled = config.NOTICE_SUMMARY_ENABLED !== "0";
    const noticeNativeStableNoopSkipEnabled = readEnabledConfig(
      config,
      "NOTICE_NATIVE_STABLE_NOOP_SKIP",
      true
    );
    const noticeNativeAlwaysCaptureStateEnabled = readEnabledConfig(
      config,
      "NOTICE_NATIVE_ALWAYS_CAPTURE_STATE",
      true
    );
    const noticeNativeDeferStateOnlyRenderEnabled = readEnabledConfig(
      config,
      "NOTICE_NATIVE_DEFER_STATE_ONLY_RENDER",
      false
    );
    const noticeNativeForceArchivePostCaptureRenderEnabled = readEnabledConfig(
      config,
      "NOTICE_NATIVE_FORCE_ARCHIVE_POST_CAPTURE_RENDER",
      false
    );
    const calendarSkipUnchangedDesired = readEnabledConfig(
      config,
      "CALENDAR_SKIP_UNCHANGED_DESIRED",
      true
    );
    const skipUnchangedSideEffects = readEnabledConfig(
      config,
      "SYNC_SKIP_UNCHANGED_CALENDAR_REMINDERS",
      true
    );
    const sharedRunStartedEpoch = Number(envValue("KLMS_RUN_STARTED_EPOCH") || "0");
    const reminderDeviceAlertMode = config.REMINDER_DEVICE_ALERT_MODE || "adaptive";
    const reminderDeviceAlertsEnabled =
      reminderDeviceAlertMode.toLowerCase() !== "off" &&
      config.REMINDER_DEVICE_ALERTS_ENABLED !== "0";
    const reminderStageAlertsEnabled = config.REMINDER_STAGE_ALERTS_ENABLED !== "0";
    const cleanDisabledStageAlerts = readEnabledConfig(
      config,
      "REMINDER_CLEAN_DISABLED_STAGE_ALERTS",
      false
    );
    const recreateStageAlertList = readEnabledConfig(
      config,
      "REMINDER_RECREATE_STAGE_ALERT_LIST",
      true
    );
    const reminderAlertListName = config.REMINDER_ALERT_LIST_NAME || "KLMS 알림";
    const completedReminderRetentionDays = Math.max(
      0,
      Number(config.COMPLETED_REMINDER_RETENTION_DAYS || "0")
    );
    beginStage(steps, stageTelemetry, "config");
    const dashboardUrl = config.KLMS_DASHBOARD_URL || "https://klms.kaist.ac.kr/my/";
    const waitSeconds = Number(config.SAFARI_WAIT_SECONDS || "6");

    const runtimeDir = `${scriptDir}/runtime`;
    const cacheDir = `${runtimeDir}/cache`;
    const stateDir = `${runtimeDir}/state`;
    const tmpDir = `${runtimeDir}/tmp`;
    const pythonPath = buildPythonPath(scriptDir, runtimeDir);
    const runtimeNamespace = scope === "notice" ? "notice" : "core";
    const workCacheDir = `${cacheDir}/${runtimeNamespace}`;
    const workTmpDir = `${tmpDir}/${runtimeNamespace}`;
    ensureDir(cacheDir);
    ensureDir(stateDir);
    ensureDir(tmpDir);
    ensureDir(workCacheDir);
    ensureDir(workTmpDir);

    const syncMode = (config.SYNC_MODE || "auto").trim().toLowerCase();
    const minimalExplorationEnabled = readEnabledConfig(
      config,
      "SYNC_MINIMAL_EXPLORATION_ENABLED",
      true
    );
    const fetchAutoFullMinCoverage = Math.max(
      0,
      Math.min(
        1,
        resolveFloatConfig(
          config,
          "FETCH_AUTO_FULL_MIN_COVERAGE",
          minimalExplorationEnabled ? 0.2 : 0.5
        )
      )
    );
    const fetchAutoRequireLastFull = readEnabledConfig(
      config,
      "FETCH_AUTO_REQUIRE_LAST_FULL",
      minimalExplorationEnabled ? false : true
    );
    const fetchAutoFullOnTtlExpire = readEnabledConfig(
      config,
      "FETCH_AUTO_FULL_ON_TTL_EXPIRE",
      minimalExplorationEnabled ? false : true
    );
    const fetchMinWaitSeconds = Math.max(0, Number(config.FETCH_MIN_WAIT_SECONDS || "1.5"));
    const fetchStablePolls = Math.max(1, Math.round(Number(config.FETCH_STABLE_POLLS || "2")));
    const fetchCompleteReuseSeconds = Math.max(
      0,
      Math.round(Number(config.FETCH_COMPLETE_REUSE_SECONDS || "3600"))
    );
    const syncFullTtlSeconds = Math.max(
      3600,
      Math.round(Number(config.SYNC_FULL_TTL_SECONDS || "259200"))
    );
    const coursePageStaleSeconds = Math.max(
      0,
      Math.round(Number(config.SYNC_COURSE_PAGE_STALE_SECONDS || "43200"))
    );
    const allWeekCoursePageStaleSeconds = Math.max(
      0,
      Math.round(Number(config.SYNC_ALL_WEEK_COURSE_PAGE_STALE_SECONDS || "43200"))
    );
    const detailQuickLimit = Math.max(
      0,
      resolveIntegerConfig(
        config,
        "SYNC_DETAIL_QUICK_LIMIT",
        minimalExplorationEnabled ? 0 : 12
      )
    );
    const detailStaleSeconds = Math.max(
      0,
      Math.round(Number(config.SYNC_DETAIL_STALE_SECONDS || "21600"))
    );
    const supplementalQuickLimit = Math.max(
      0,
      resolveIntegerConfig(
        config,
        "SYNC_SUPPLEMENTAL_QUICK_LIMIT",
        minimalExplorationEnabled ? 0 : 24
      )
    );
    const supplementalStaleSeconds = Math.max(
      0,
      Math.round(Number(config.SYNC_SUPPLEMENTAL_STALE_SECONDS || "43200"))
    );
    const noticeSharedFallbackMaxAgeSeconds = Math.max(
      0,
      resolveIntegerConfig(
        config,
        "NOTICE_SHARED_FALLBACK_MAX_AGE_SECONDS",
        Math.max(coursePageStaleSeconds, allWeekCoursePageStaleSeconds, supplementalStaleSeconds)
      )
    );
    const supplementalDetailQuickLimit = Math.max(
      0,
      resolveIntegerConfig(
        config,
        "SYNC_SUPPLEMENTAL_DETAIL_QUICK_LIMIT",
        resolveIntegerConfig(
          config,
          "SYNC_SUPPLEMENTAL_QUICK_LIMIT",
          minimalExplorationEnabled ? 0 : 2
        )
      )
    );
    const supplementalDetailPinnedQuickLimit = Math.max(
      0,
      resolveIntegerConfig(
        config,
        "SYNC_SUPPLEMENTAL_DETAIL_PINNED_QUICK_LIMIT",
        minimalExplorationEnabled ? 0 : 2
      )
    );
    const supplementalDetailStaleSeconds = Math.max(
      0,
      Math.round(
        Number(
          config.SYNC_SUPPLEMENTAL_DETAIL_STALE_SECONDS ||
            config.SYNC_SUPPLEMENTAL_STALE_SECONDS ||
            "21600"
        )
      )
    );
    const secondarySupplementalQuickLimit = Math.max(
      0,
      resolveIntegerConfig(
        config,
        "SYNC_SECONDARY_SUPPLEMENTAL_QUICK_LIMIT",
        minimalExplorationEnabled ? 0 : 2
      )
    );
    const secondarySupplementalStaleSeconds = Math.max(
      0,
      Math.round(Number(config.SYNC_SECONDARY_SUPPLEMENTAL_STALE_SECONDS || "86400"))
    );
    const includeNonRelevantPrimarySupplementalDetail = readEnabledConfig(
      config,
      "SYNC_SUPPLEMENTAL_DETAIL_INCLUDE_NON_RELEVANT_PRIMARY",
      minimalExplorationEnabled ? false : true
    );
    const alwaysFetchMinIntervalSeconds = Math.max(
      0,
      resolveIntegerConfig(
        config,
        "SYNC_ALWAYS_FETCH_MIN_INTERVAL_SECONDS",
        minimalExplorationEnabled ? 1800 : 0
      )
    );
    const supplementalAlwaysFetchPatterns = minimalExplorationEnabled
      ? ["/mod/courseboard/view\\.php"]
      : ["/mod/courseboard/view\\.php", "/index\\.php\\?id="];
    const supplementalDetailAlwaysFetchPatterns = minimalExplorationEnabled
      ? []
      : ["/mod/courseboard/view\\.php", "/index\\.php\\?id="];
    const noticeBoardPaginationAlwaysFetchPatterns = minimalExplorationEnabled
      ? []
      : ["/mod/courseboard/view\\.php"];
    const fetchCacheStatePath =
      config.FETCH_CACHE_STATE_PATH || `${workCacheDir}/fetch_state.json`;
    const stageTimingJson = `${workCacheDir}/stage_timings.json`;
    const dryRunReportJson = `${workCacheDir}/dry_run_report.json`;
    const remindersDesiredHashTxt = `${workCacheDir}/reminders_desired_hash.txt`;
    const calendarDesiredHashTxt = `${workCacheDir}/calendar_desired_hash.txt`;
    const calendarSyncResultJson = `${workCacheDir}/calendar_sync_result.json`;

    const baseFetchOptions = {
      backend: "safari",
      mode: syncMode,
      cacheStatePath: fetchCacheStatePath,
      tmpDir: workTmpDir,
      minWaitSeconds: fetchMinWaitSeconds,
      stablePolls: fetchStablePolls,
      autoFullMinCoverage: fetchAutoFullMinCoverage,
      autoFullRequireLastFull: fetchAutoRequireLastFull,
      autoFullOnTtlExpire: fetchAutoFullOnTtlExpire,
      alwaysFetchMinIntervalSeconds,
      completeReuseSeconds: fetchCompleteReuseSeconds,
    };
    stageTelemetry.outputPath = stageTimingJson;
    stageTelemetry.scope = scope;
    persistStageTelemetry(stageTelemetry);

    const dashboardJson = `${workCacheDir}/dashboard.json`;
    const dashboardFetchSummaryJson = `${workCacheDir}/dashboard_fetch_summary.json`;
    const coursePagesJson = `${workCacheDir}/course_pages.json`;
    const courseFetchSummaryJson = `${workCacheDir}/course_fetch_summary.json`;
    const courseUrlsTxt = `${workCacheDir}/course_urls.txt`;
    const allWeekCoursePagesJson = `${workCacheDir}/all_week_course_pages.json`;
    const allWeekCourseFetchSummaryJson = `${workCacheDir}/all_week_course_fetch_summary.json`;
    const allWeekCourseUrlsTxt = `${workCacheDir}/all_week_course_urls.txt`;
    const supplementalPrimaryPagesJson = `${workCacheDir}/supplemental_primary_pages.json`;
    const supplementalPrimaryFetchSummaryJson = `${workCacheDir}/supplemental_primary_fetch_summary.json`;
    const noticeBoardPageUrlsTxt = `${workCacheDir}/notice_board_page_urls.txt`;
    const noticeBoardExtraPagesJson = `${workCacheDir}/notice_board_extra_pages.json`;
    const noticeBoardExtraFetchSummaryJson = `${workCacheDir}/notice_board_extra_fetch_summary.json`;
    const supplementalSecondaryPagesJson = `${workCacheDir}/supplemental_secondary_pages.json`;
    const supplementalSecondaryFetchSummaryJson = `${workCacheDir}/supplemental_secondary_fetch_summary.json`;
    const supplementalPagesJson = `${workCacheDir}/supplemental_pages.json`;
    const supplementalPrimaryUrlsTxt = `${workCacheDir}/supplemental_primary_urls.txt`;
    const supplementalSecondaryUrlsTxt = `${workCacheDir}/supplemental_secondary_urls.txt`;
    const supplementalUrlsTxt = `${workCacheDir}/supplemental_urls.txt`;
    const allWeekSupplementalPrimaryUrlsTxt = `${workCacheDir}/all_week_supplemental_primary_urls.txt`;
    const allWeekSupplementalSecondaryUrlsTxt = `${workCacheDir}/all_week_supplemental_secondary_urls.txt`;
    const detailsJson = `${workCacheDir}/details.json`;
    const detailFetchSummaryJson = `${workCacheDir}/detail_fetch_summary.json`;
    const detailUrlsTxt = `${workCacheDir}/detail_urls.txt`;
    const supplementalDetailPagesJson = `${workCacheDir}/supplemental_detail_pages.json`;
    const supplementalDetailFetchSummaryJson = `${workCacheDir}/supplemental_detail_fetch_summary.json`;
    const supplementalDetailUrlsTxt = `${workCacheDir}/supplemental_detail_urls.txt`;
    const boardArticleStateJson = `${workCacheDir}/board_article_state.json`;
    const boardArticleStatePendingJson = `${workCacheDir}/board_article_state.next.json`;
    const noticeBoardStateJson = `${cacheDir}/notice_board_state.json`;
    const noticeBoardStatePendingJson = `${cacheDir}/notice_board_state.next.json`;
    const noticeSummaryStateJson = `${cacheDir}/notice_summary_state.json`;
    const noticeUserStateJson = `${cacheDir}/notice_user_state.json`;
    const noticeNoteRenderStateJson = `${cacheDir}/notice_note_render_state.json`;
    const noticeArchiveNoteRenderStateJson = `${cacheDir}/notice_archive_note_render_state.json`;
    const courseFileManifestJson = `${cacheDir}/course_file_manifest.json`;
    const noticeArticleUrlsTxt = `${cacheDir}/notice_article_urls.txt`;
    const noticeArticlePagesJson = `${cacheDir}/notice_article_pages.json`;
    const noticeArticleFetchSummaryJson = `${cacheDir}/notice_article_fetch_summary.json`;
    const noticeDigestJson = `${cacheDir}/notice_digest.json`;
    const noticeDigestErrorTxt = `${cacheDir}/notice_digest_error.txt`;
    const noticeNoteRenderWarningTxt = `${cacheDir}/notice_note_render_warning.txt`;
    const noticeRenderErrorSummaryJson = `${cacheDir}/notice_render_error_summary.json`;
    const noticeNoteName = config.NOTICE_NOTE_NAME || "KLMS 공지";
    const noticeArchiveNoteName = config.NOTICE_ARCHIVE_NOTE_NAME || "KLMS 확인한 공지";
    const sharedCoursePagesJson =
      envValue("KLMS_SHARED_COURSE_PAGES_JSON") || `${cacheDir}/core/course_pages.json`;
    const sharedAllWeekCoursePagesJson =
      envValue("KLMS_SHARED_ALL_WEEK_COURSE_PAGES_JSON") ||
      `${cacheDir}/core/all_week_course_pages.json`;
    const sharedSupplementalPrimaryPagesJson =
      envValue("KLMS_SHARED_SUPPLEMENTAL_PRIMARY_PAGES_JSON") ||
      `${cacheDir}/core/supplemental_primary_pages.json`;
    const overridesJson =
      config.OVERRIDES_JSON_PATH || `${scriptDir}/manual_assignment_overrides.json`;
    const outputHtml = `${cacheDir}/generated_section.html`;
    const outputState = `${stateDir}/next_state.json`;
    const outputStatus = `${cacheDir}/status.json`;
    const stateJson = `${stateDir}/state.json`;
    let noticeSummaryAlreadySynced = false;
    let noticeSummaryPrebuildSnapshot = null;
    const noticePaths = {
      dashboardUrl,
      dashboardJson,
      dashboardFetchSummaryJson,
      coursePagesJson,
      courseFetchSummaryJson,
      courseUrlsTxt,
      allWeekCoursePagesJson,
      allWeekCourseFetchSummaryJson,
      allWeekCourseUrlsTxt,
      supplementalPrimaryPagesJson,
      supplementalPrimaryFetchSummaryJson,
      noticeBoardPageUrlsTxt,
      noticeBoardExtraPagesJson,
      noticeBoardExtraFetchSummaryJson,
      supplementalPrimaryUrlsTxt,
      allWeekSupplementalPrimaryUrlsTxt,
      noticeBoardStateJson,
      noticeBoardStatePendingJson,
      noticeSummaryStateJson,
      noticeUserStateJson,
      noticeNoteRenderStateJson,
      noticeArchiveNoteRenderStateJson,
      courseFileManifestJson,
      noticeArticleUrlsTxt,
      noticeArticlePagesJson,
      noticeArticleFetchSummaryJson,
      noticeDigestJson,
      noticeDigestErrorTxt,
      noticeNoteRenderWarningTxt,
      noticeRenderErrorSummaryJson,
      dryRunReportJson,
      dryRun,
      overridesJson,
      noticeAutoImportantKeywordsApply:
        config.NOTICE_AUTO_IMPORTANT_KEYWORDS_APPLY === "1",
      noticeNoteName,
      noticeArchiveNoteName,
      noticeNativeStableNoopSkipEnabled,
      noticeNativeAlwaysCaptureStateEnabled,
      noticeNativeDeferStateOnlyRenderEnabled,
      noticeNativeForceArchivePostCaptureRenderEnabled,
      noticeNativeEnvironment: nativeNoticeEnvironment(config),
      syncFullTtlSeconds,
      coursePageStaleSeconds,
      allWeekCoursePageStaleSeconds,
      courseFallbackPagePaths: freshExistingFilesSinceOrWithin(
        [sharedCoursePagesJson],
        sharedRunStartedEpoch,
        noticeSharedFallbackMaxAgeSeconds
      ),
      allWeekCourseFallbackPagePaths: freshExistingFilesSinceOrWithin(
        [sharedAllWeekCoursePagesJson],
        sharedRunStartedEpoch,
        noticeSharedFallbackMaxAgeSeconds
      ),
      supplementalQuickLimit,
      supplementalStaleSeconds,
      supplementalAlwaysFetchPatterns,
      supplementalPrimaryFallbackPagePaths: freshExistingFilesSinceOrWithin(
        [sharedSupplementalPrimaryPagesJson],
        sharedRunStartedEpoch,
        noticeSharedFallbackMaxAgeSeconds
      ),
      noticeBoardPaginationAlwaysFetchPatterns,
      stageTimingJson,
    };

    if (scope === "notice") {
      beginStage(steps, stageTelemetry, "notice-only");
      debugStderr("enter notice-only");
      if (!noticeSummaryEnabled) {
        completeStageTelemetry(stageTelemetry, { status: "skipped" });
        return "status=skipped scope=notice reason=disabled";
      }
      const noticeSummary = runStandaloneNoticeSummary(
        scriptDir,
        waitSeconds,
        baseFetchOptions,
        noticePaths,
        steps,
        usePrefetchedDashboard,
        stageTelemetry
      );
      if (dryRun) {
        writeDryRunReport(dryRunReportJson, {
          scope,
          status: "ok",
          would_create: noticeSummary.newCount,
          would_update: noticeSummary.updatedCount,
          would_delete: 0,
          would_download: 0,
          would_prune: 0,
          skipped_side_effects: ["native-notes-render"],
          notice_counts: {
            total: noticeSummary.noticeCount,
            new: noticeSummary.newCount,
            updated: noticeSummary.updatedCount,
          },
        });
      }
      completeStageTelemetry(stageTelemetry, {
        status: "ok",
        result: {
          notice_count: noticeSummary.noticeCount,
          new_count: noticeSummary.newCount,
          updated_count: noticeSummary.updatedCount,
          render_warning_count: noticeSummary.renderWarningCount || 0,
        },
      });
      return `status=ok scope=notice dry_run=${dryRun ? "1" : "0"} notice_count=${noticeSummary.noticeCount} new=${noticeSummary.newCount} updated=${noticeSummary.updatedCount}`;
    }

    if (remindersEnabled && !dryRun) {
      beginStage(steps, stageTelemetry, "completed-reminders-import");
      debugStderr("before completed-reminders-import");
      const remindersListName = config.REMINDERS_LIST_NAME || "KLMS 과제";
      const remindersIssueListName =
        config.REMINDERS_ISSUE_LIST_NAME || "KLMS 확인 필요";
      importCompletedRemindersToOverrides(stateJson, overridesJson, [
        remindersListName,
        remindersIssueListName,
      ]);
      debugStderr("after completed-reminders-import");
    }
    if (remindersEnabled && dryRun) {
      beginStage(steps, stageTelemetry, "completed-reminders-import-dry-run");
      debugStderr("dry-run skip completed-reminders-import");
    }

    beginStage(steps, stageTelemetry, "dashboard-fetch");
    debugStderr("before dashboard-fetch");
    const dashboardPages =
      usePrefetchedDashboard && fileExists(dashboardJson)
        ? loadPagesJson(dashboardJson)
        : fetchPages([dashboardUrl], waitSeconds, scriptDir, {
            ...baseFetchOptions,
            context: "sync-dashboard",
            mode: "full",
            outputPath: dashboardJson,
            summaryPath: dashboardFetchSummaryJson,
            requireAll: true,
          });
    assertRequiredPageCount(
      "대시보드 페이지를 가져오지 못했어. Safari에서 KLMS가 열린 상태인지 확인한 뒤 다시 실행해 줘.",
      dashboardPages,
      1
    );
    assertNoLoginPages(
      "대시보드 정리를 시작하는 중 KLMS 로그인 세션이 풀렸어. 다시 로그인해 줘.",
      dashboardPages
    );
    debugStderr("after dashboard-fetch");

    beginStage(steps, stageTelemetry, "course-list");
    debugStderr("before course-list");
    const courseUrlsOutput = runCommand(
      [
        "/usr/bin/env",
        `PYTHONPATH=${pythonPath}`,
        "python3",
        "-m",
        "klms_sync_v2.cli",
        "list-course-urls",
        "--dashboard-json",
        dashboardJson,
      ],
      scriptDir
    );
    writeText(courseUrlsTxt, courseUrlsOutput);
    debugStderr("after course-list");

    const courseUrls = courseUrlsOutput
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);

    beginStage(steps, stageTelemetry, "course-fetch");
    debugStderr("before course-fetch");
    const coursePages =
      courseUrls.length > 0
        ? fetchPages(courseUrls, waitSeconds, scriptDir, {
            ...baseFetchOptions,
            context: "sync-course-pages",
            staleSeconds: coursePageStaleSeconds,
            outputPath: coursePagesJson,
            summaryPath: courseFetchSummaryJson,
          })
        : [];
    debugStderr("after course-fetch");

    const allWeekCourseUrls = uniqueStrings(courseUrls.map(toAllWeekCourseUrl).filter(Boolean));
    writeText(allWeekCourseUrlsTxt, allWeekCourseUrls.join("\n"));

    beginStage(steps, stageTelemetry, "all-week-course-fetch");
    debugStderr("before all-week-course-fetch");
    const allWeekCoursePages =
      allWeekCourseUrls.length > 0
        ? fetchPages(allWeekCourseUrls, waitSeconds, scriptDir, {
            ...baseFetchOptions,
            context: "sync-all-week-course-pages",
            staleSeconds: allWeekCoursePageStaleSeconds,
            outputPath: allWeekCoursePagesJson,
            summaryPath: allWeekCourseFetchSummaryJson,
          })
        : [];
    debugStderr("after all-week-course-fetch");

    beginStage(steps, stageTelemetry, "supplemental-primary-list");
    debugStderr("before supplemental-primary-list");
    const supplementalPrimaryUrlsFromCourseOutput = runCommand(
      [
        "/usr/bin/env",
        `PYTHONPATH=${pythonPath}`,
        "python3",
        "-m",
        "klms_sync_v2.cli",
        "list-supplemental-urls",
        "--course-pages-json",
        coursePagesJson,
        "--tier=primary",
      ],
      scriptDir
    );
    const supplementalPrimaryUrlsFromCourse = parseNonEmptyLines(
      supplementalPrimaryUrlsFromCourseOutput
    );
    debugStderr("after supplemental-primary-list");

    let allWeekSupplementalPrimaryUrlsOutput = "";
    if (allWeekCourseUrls.length > 0) {
      beginStage(steps, stageTelemetry, "all-week-supplemental-primary-list");
      allWeekSupplementalPrimaryUrlsOutput = runCommand(
        [
          "/usr/bin/env",
          `PYTHONPATH=${pythonPath}`,
          "python3",
          "-m",
          "klms_sync_v2.cli",
          "list-supplemental-urls",
          "--course-pages-json",
          allWeekCoursePagesJson,
          "--tier=primary",
        ],
        scriptDir
      );
    }
    writeText(allWeekSupplementalPrimaryUrlsTxt, allWeekSupplementalPrimaryUrlsOutput);

    const supplementalPrimaryUrlsFromAllWeeks = parseNonEmptyLines(
      allWeekSupplementalPrimaryUrlsOutput
    );
    const supplementalPrimaryUrls = uniqueStrings([
      ...supplementalPrimaryUrlsFromCourse,
      ...supplementalPrimaryUrlsFromAllWeeks,
    ]);
    writeText(supplementalPrimaryUrlsTxt, supplementalPrimaryUrls.join("\n"));

    beginStage(steps, stageTelemetry, "supplemental-primary-fetch");
    debugStderr("before supplemental-primary-fetch");
    const supplementalPrimaryPages =
      supplementalPrimaryUrls.length > 0
        ? fetchPages(supplementalPrimaryUrls, waitSeconds, scriptDir, {
            ...baseFetchOptions,
            context: "sync-supplemental-primary-pages",
            outputPath: supplementalPrimaryPagesJson,
            summaryPath: supplementalPrimaryFetchSummaryJson,
            fullTtlSeconds: syncFullTtlSeconds,
            quickLimit: supplementalQuickLimit,
            staleSeconds: supplementalStaleSeconds,
            alwaysFetchPatterns: supplementalAlwaysFetchPatterns,
          })
        : [];
    debugStderr("after supplemental-primary-fetch");

    beginStage(steps, stageTelemetry, "supplemental-secondary-list");
    debugStderr("before supplemental-secondary-list");
    const supplementalSecondaryUrlsFromCourseOutput = runCommand(
      [
        "/usr/bin/env",
        `PYTHONPATH=${pythonPath}`,
        "python3",
        "-m",
        "klms_sync_v2.cli",
        "list-supplemental-urls",
        "--course-pages-json",
        coursePagesJson,
        "--tier=secondary",
      ],
      scriptDir
    );
    const supplementalSecondaryUrlsFromCourse = parseNonEmptyLines(
      supplementalSecondaryUrlsFromCourseOutput
    );
    debugStderr("after supplemental-secondary-list");

    let allWeekSupplementalSecondaryUrlsOutput = "";
    if (allWeekCourseUrls.length > 0) {
      beginStage(steps, stageTelemetry, "all-week-supplemental-secondary-list");
      allWeekSupplementalSecondaryUrlsOutput = runCommand(
        [
          "/usr/bin/env",
          `PYTHONPATH=${pythonPath}`,
          "python3",
          "-m",
          "klms_sync_v2.cli",
          "list-supplemental-urls",
          "--course-pages-json",
          allWeekCoursePagesJson,
          "--tier=secondary",
        ],
        scriptDir
      );
    }
    writeText(allWeekSupplementalSecondaryUrlsTxt, allWeekSupplementalSecondaryUrlsOutput);

    const supplementalSecondaryUrlsFromAllWeeks = parseNonEmptyLines(
      allWeekSupplementalSecondaryUrlsOutput
    );
    const supplementalSecondaryUrls = uniqueStrings([
      ...supplementalSecondaryUrlsFromCourse,
      ...supplementalSecondaryUrlsFromAllWeeks,
    ]);
    writeText(supplementalSecondaryUrlsTxt, supplementalSecondaryUrls.join("\n"));

    beginStage(steps, stageTelemetry, "supplemental-secondary-fetch");
    debugStderr("before supplemental-secondary-fetch");
    const supplementalSecondaryPages =
      supplementalSecondaryUrls.length > 0
        ? fetchPages(supplementalSecondaryUrls, waitSeconds, scriptDir, {
            ...baseFetchOptions,
            context: "sync-supplemental-secondary-pages",
            outputPath: supplementalSecondaryPagesJson,
            summaryPath: supplementalSecondaryFetchSummaryJson,
            fullTtlSeconds: syncFullTtlSeconds,
            quickLimit: secondarySupplementalQuickLimit,
            probeOrder: "oldest",
            staleSeconds: secondarySupplementalStaleSeconds,
          })
        : [];
    debugStderr("after supplemental-secondary-fetch");

    const supplementalUrls = uniqueStrings([
      ...supplementalPrimaryUrls,
      ...supplementalSecondaryUrls,
    ]);
    writeText(supplementalUrlsTxt, supplementalUrls.join("\n"));
    const supplementalPages = mergePagesByRequestedUrl([
      ...supplementalPrimaryPages,
      ...supplementalSecondaryPages,
    ]);
    writeText(supplementalPagesJson, JSON.stringify(supplementalPages));

    beginStage(steps, stageTelemetry, "detail-list");
    debugStderr("before detail-list");
    const detailUrlsOutput = runCommand(
      [
        "/usr/bin/env",
        `PYTHONPATH=${pythonPath}`,
        "python3",
        "-m",
        "klms_sync_v2.cli",
        "list-detail-urls",
        "--dashboard-json",
        dashboardJson,
        "--course-pages-json",
        coursePagesJson,
      ],
      scriptDir
    );
    writeText(detailUrlsTxt, detailUrlsOutput);
    debugStderr("after detail-list");

    const detailUrls = detailUrlsOutput
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);

    beginStage(steps, stageTelemetry, "details-fetch");
    debugStderr("before details-fetch");
    const detailPages =
      detailUrls.length > 0
        ? fetchPages(detailUrls, waitSeconds, scriptDir, {
            ...baseFetchOptions,
            context: "sync-detail-pages",
            outputPath: detailsJson,
            summaryPath: detailFetchSummaryJson,
            fullTtlSeconds: syncFullTtlSeconds,
            quickLimit: detailQuickLimit,
            staleSeconds: detailStaleSeconds,
          })
        : [];
    debugStderr("after details-fetch");

    beginStage(steps, stageTelemetry, "supplemental-detail-list");
    debugStderr("before supplemental-detail-list");
    const previousSupplementalDetailUrls = uniqueStrings([
      ...parseNonEmptyLines(
        fileExists(supplementalDetailUrlsTxt) ? readText(supplementalDetailUrlsTxt) : ""
      ),
      ...cachedPageRequestedUrls(supplementalDetailPagesJson),
    ]);
    const supplementalDetailUrlsOutput = runCommand(
      [
        "/usr/bin/env",
        `PYTHONPATH=${pythonPath}`,
        "python3",
        "-m",
        "klms_sync_v2.cli",
        "list-supplemental-detail-urls",
        "--supplemental-pages-json",
        supplementalPagesJson,
        "--board-article-state-json",
        boardArticleStateJson,
        ...(includeNonRelevantPrimarySupplementalDetail
          ? ["--include-non-relevant-primary"]
          : []),
        ...(fileExists(supplementalDetailPagesJson)
          ? ["--existing-detail-pages-json", supplementalDetailPagesJson]
          : []),
        "--output-board-article-state-json",
        boardArticleStatePendingJson,
      ],
      scriptDir
    );
    debugStderr("after supplemental-detail-list");

    const supplementalDetailUrls = supplementalDetailUrlsOutput
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    const pinnedSupplementalDetailUrls = extractPinnedSupplementalDetailUrls(stateJson);
    const prioritizedSupplementalDetailUrls = prioritizeSupplementalDetailUrls(
      supplementalDetailUrls,
      previousSupplementalDetailUrls,
      pinnedSupplementalDetailUrls
    );
    const newSupplementalDetailCount = prioritizedSupplementalDetailUrls.filter(
      (url) => previousSupplementalDetailUrls.indexOf(url) === -1
    ).length;
    const pinnedSupplementalDetailCount = prioritizedSupplementalDetailUrls.filter((url) =>
      pinnedSupplementalDetailUrls.has(url)
    ).length;
    const dynamicSupplementalDetailQuickLimit = Math.max(
      supplementalDetailQuickLimit,
      newSupplementalDetailCount +
        Math.min(supplementalDetailPinnedQuickLimit, pinnedSupplementalDetailCount)
    );
    writeText(supplementalDetailUrlsTxt, prioritizedSupplementalDetailUrls.join("\n"));

    beginStage(steps, stageTelemetry, "supplemental-detail-fetch");
    debugStderr("before supplemental-detail-fetch");
    const skipSupplementalDetailFetch =
      prioritizedSupplementalDetailUrls.length > 0 &&
      fileExists(supplementalDetailPagesJson) &&
      dynamicSupplementalDetailQuickLimit === 0 &&
      newSupplementalDetailCount === 0 &&
      pinnedSupplementalDetailCount === 0;
    const supplementalDetailPages =
      skipSupplementalDetailFetch
        ? loadPagesJson(supplementalDetailPagesJson)
        : prioritizedSupplementalDetailUrls.length > 0
        ? fetchPages(prioritizedSupplementalDetailUrls, waitSeconds, scriptDir, {
            ...baseFetchOptions,
            context: "sync-supplemental-detail-pages",
            outputPath: supplementalDetailPagesJson,
            summaryPath: supplementalDetailFetchSummaryJson,
            fullTtlSeconds: syncFullTtlSeconds,
            quickLimit: dynamicSupplementalDetailQuickLimit,
            probeOrder: "oldest",
            staleSeconds: supplementalDetailStaleSeconds,
            alwaysFetchPatterns: supplementalDetailAlwaysFetchPatterns,
          })
        : [];
    if (skipSupplementalDetailFetch) {
      writeText(
        supplementalDetailFetchSummaryJson,
        JSON.stringify({
          context: "sync-supplemental-detail-pages",
          backend: String((baseFetchOptions && baseFetchOptions.backend) || "safari"),
          requested_mode: "auto",
          effective_mode: "skipped",
          skip_reason: "unchanged-url-list-and-zero-quick-limit",
          total_urls: prioritizedSupplementalDetailUrls.length,
          fetched_urls: 0,
          reused_urls: prioritizedSupplementalDetailUrls.length,
          changed_urls: 0,
          out_path: supplementalDetailPagesJson,
          cache_state_path: String((baseFetchOptions && baseFetchOptions.cacheStatePath) || ""),
        })
      );
      recordFetchSummaryTelemetry(supplementalDetailFetchSummaryJson, "sync-supplemental-detail-pages");
    }
    debugStderr("after supplemental-detail-fetch");

    if (noticeSummaryEnabled && scope !== "notice") {
      beginStage(steps, stageTelemetry, "notice-summary-prebuild");
      debugStderr("before notice-summary-prebuild");
      const noticeSnapshot = snapshotFiles([
        noticeBoardStateJson,
        noticeBoardStatePendingJson,
        noticeSummaryStateJson,
        noticeUserStateJson,
        noticeNoteRenderStateJson,
        noticeArchiveNoteRenderStateJson,
        noticeDigestJson,
      ]);
      try {
        // Build state from the current notice digest so notice-only assignment
        // announcements are not delayed until the next core sync.
        syncNoticeSummary(
          scriptDir,
          waitSeconds,
          baseFetchOptions,
          { ...noticePaths, skipNativeRender: true },
          stageTelemetry
        );
        noticeSummaryPrebuildSnapshot = noticeSnapshot;
        noticeSummaryAlreadySynced = scope !== "all";
        writeText(noticeDigestErrorTxt, "");
      } catch (noticeError) {
        restoreFileSnapshot(noticeSnapshot);
        noticeSummaryPrebuildSnapshot = null;
        writeText(noticeDigestErrorTxt, String(noticeError));
        writeText(noticeNoteRenderWarningTxt, "");
        writeText(
          noticeRenderErrorSummaryJson,
          JSON.stringify(classifyNoticeRenderError(String(noticeError)), null, 2)
        );
        debugStderr(`notice-summary-prebuild warning ignored: ${String(noticeError)}`);
      }
      debugStderr("after notice-summary-prebuild");
    }

    beginStage(steps, stageTelemetry, "build-note");
    debugStderr("before build-note");
    try {
      runCommand(
        [
          "/usr/bin/env",
          `PYTHONPATH=${pythonPath}`,
          "python3",
          "-m",
          "klms_sync_v2.cli",
          "build-note",
          "--dashboard-json",
          dashboardJson,
          "--course-pages-json",
          coursePagesJson,
          "--all-week-course-pages-json",
          allWeekCoursePagesJson,
          "--course-file-manifest-json",
          courseFileManifestJson,
          "--details-json",
          detailsJson,
          "--supplemental-pages-json",
          supplementalPagesJson,
          "--supplemental-detail-pages-json",
          supplementalDetailPagesJson,
          ...(fileExists(noticeDigestJson)
            ? ["--notice-digest-json", noticeDigestJson]
            : []),
          "--overrides-json",
          overridesJson,
          "--state-json",
          stateJson,
          "--output-html",
          outputHtml,
          "--output-state",
          outputState,
          "--output-status",
          outputStatus,
        ],
        scriptDir
      );
    } finally {
      if (noticeSummaryPrebuildSnapshot) {
        restoreFileSnapshot(noticeSummaryPrebuildSnapshot);
        noticeSummaryPrebuildSnapshot = null;
      }
    }
    debugStderr("after build-note");
    if (fileExists(boardArticleStatePendingJson)) {
      moveFile(boardArticleStatePendingJson, boardArticleStateJson);
    }

    beginStage(steps, stageTelemetry, "status");
    debugStderr("before status");
    const status = JSON.parse(readText(outputStatus));
    debugStderr(`after status status=${status.status}`);

    if (status.status === "ok" && (examCalendarEnabled || helpDeskCalendarEnabled)) {
      if (skipUnchangedSideEffects && status.changed === false) {
        beginStage(steps, stageTelemetry, "calendar-sync-skipped");
        debugStderr("skip calendar-sync changed=false");
      } else {
        const calendarOptions = {
          examEnabled: examCalendarEnabled,
          helpDeskEnabled: helpDeskCalendarEnabled,
          tmpDir: workTmpDir,
          resultJson: calendarSyncResultJson,
        };
        const calendarDesiredHash = buildCalendarDesiredHash(outputState, config, calendarOptions);
        const previousCalendarDesiredHash = fileExists(calendarDesiredHashTxt)
          ? readText(calendarDesiredHashTxt).trim()
          : "";
        if (
          calendarSkipUnchangedDesired &&
          previousCalendarDesiredHash &&
          previousCalendarDesiredHash === calendarDesiredHash
        ) {
          beginStage(steps, stageTelemetry, "calendar-sync-skipped-hash");
          debugStderr("skip calendar-sync desired hash unchanged");
        } else {
          beginStage(steps, stageTelemetry, "calendar-sync");
          debugStderr("before calendar-sync");
          syncCalendarsFromState(outputState, scriptDir, config, calendarOptions);
          writeText(calendarDesiredHashTxt, `${calendarDesiredHash}\n`);
          debugStderr("after calendar-sync");
        }
      }
    }

    if (status.status === "ok" && remindersEnabled && !dryRun) {
      if (skipUnchangedSideEffects && status.changed === false) {
        beginStage(steps, stageTelemetry, "reminders-sync-skipped");
        debugStderr("skip reminders-sync changed=false");
      } else {
        const remindersListName = config.REMINDERS_LIST_NAME || "KLMS 과제";
        const remindersIssueListName =
          config.REMINDERS_ISSUE_LIST_NAME || "KLMS 확인 필요";
        const reminderOptions = {
          deviceAlertsEnabled: reminderDeviceAlertsEnabled,
          deviceAlertMode: reminderDeviceAlertMode,
          stageAlertsEnabled: reminderStageAlertsEnabled,
          cleanDisabledStageAlerts,
          recreateStageAlertList,
          alertListName: reminderAlertListName,
        };
        const remindersDesiredHash = buildRemindersDesiredHash(
          outputState,
          remindersListName,
          remindersIssueListName,
          completedReminderRetentionDays,
          reminderOptions
        );
        const previousRemindersDesiredHash = fileExists(remindersDesiredHashTxt)
          ? readText(remindersDesiredHashTxt).trim()
          : "";
        if (previousRemindersDesiredHash === remindersDesiredHash) {
          beginStage(steps, stageTelemetry, "reminders-sync-skipped-hash");
          debugStderr("skip reminders-sync desired hash unchanged");
        } else {
          beginStage(steps, stageTelemetry, "reminders-sync");
          debugStderr("before reminders-sync");
          syncRemindersFromState(
            outputState,
            remindersListName,
            remindersIssueListName,
            completedReminderRetentionDays,
            reminderOptions
          );
          writeText(remindersDesiredHashTxt, `${remindersDesiredHash}\n`);
          debugStderr("after reminders-sync");
        }
      }
    }
    if (status.status === "ok" && remindersEnabled && dryRun) {
      beginStage(steps, stageTelemetry, "reminders-sync-dry-run");
      debugStderr("dry-run skip reminders-sync");
    }
    if (status.status === "ok" && !dryRun) {
      beginStage(steps, stageTelemetry, "move-state");
      moveFile(outputState, stateJson);
    }
    if (status.status === "ok" && dryRun) {
      beginStage(steps, stageTelemetry, "dry-run-report");
      writeDryRunReport(dryRunReportJson, {
        scope,
        status: status.status,
        would_create: 0,
        would_update: status.changed ? 1 : 0,
        would_delete: 0,
        would_download: 0,
        would_prune: 0,
        skipped_side_effects: [
          ...(examCalendarEnabled || helpDeskCalendarEnabled ? ["calendar-sync"] : []),
          ...(remindersEnabled ? ["reminders-sync"] : []),
          "state-commit",
        ],
        state_counts: {
          assignments: status.assignment_count || 0,
          exams: status.exam_count || 0,
          help_desk: status.help_desk_count || 0,
        },
      });
    }
    if (status.status === "ok" && noticeSummaryEnabled && scope === "all" && !noticeSummaryAlreadySynced) {
      beginStage(steps, stageTelemetry, "notice-summary");
      const noticeSnapshot = snapshotFiles([
        noticeBoardStateJson,
        noticeBoardStatePendingJson,
        noticeSummaryStateJson,
        noticeUserStateJson,
        noticeNoteRenderStateJson,
        noticeArchiveNoteRenderStateJson,
        noticeDigestJson,
      ]);
      try {
        syncNoticeSummary(scriptDir, waitSeconds, baseFetchOptions, noticePaths, stageTelemetry);
        writeText(noticeDigestErrorTxt, "");
      } catch (noticeError) {
        restoreFileSnapshot(noticeSnapshot);
        writeText(noticeDigestErrorTxt, String(noticeError));
        writeText(noticeNoteRenderWarningTxt, "");
        writeText(
          noticeRenderErrorSummaryJson,
          JSON.stringify(classifyNoticeRenderError(String(noticeError)), null, 2)
        );
      }
    }
    completeStageTelemetry(stageTelemetry, {
      status: status.status,
      result: {
        changed: status.changed,
        assignment_count: status.assignment_count || 0,
        exam_count: status.exam_count || 0,
        exam_candidate_count: status.exam_candidate_count || 0,
        help_desk_count: status.help_desk_count || 0,
        assignment_candidate_count: status.assignment_candidate_count || 0,
        dry_run: dryRun,
      },
    });
    return `status=${status.status} scope=${scope} dry_run=${dryRun ? "1" : "0"} changed=${status.changed} assignments=${status.assignment_count} exams=${status.exam_count || 0} exam_candidates=${status.exam_candidate_count || 0} help_desk=${status.help_desk_count || 0} assignment_candidates=${status.assignment_candidate_count || 0}`;
  } catch (error) {
    completeStageTelemetry(stageTelemetry, {
      status: "error",
      failedStage: steps.length > 0 ? steps[steps.length - 1] : "",
      error: String(error),
    });
    return `FAILED(${steps.join(" > ")}) ${error}`;
  }
}

function parseNonEmptyLines(text) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function createStageTelemetry(scope) {
  const startedMs = Date.now();
  return {
    version: 2,
    scope: String(scope || ""),
    run_started_at: new Date(startedMs).toISOString(),
    run_started_ms: startedMs,
    completed_at: "",
    status: "running",
    failed_stage: "",
    error: "",
    outputPath: "",
    stages: [],
    currentStage: null,
    events: [],
    noticeRenderResults: [],
    result: {},
  };
}

function beginStage(steps, stageTelemetry, name) {
  if (stageTelemetry) {
    finalizeCurrentStage(stageTelemetry, "ok");
    stageTelemetry.currentStage = {
      name,
      started_at: new Date().toISOString(),
      started_ms: Date.now(),
    };
    persistStageTelemetry(stageTelemetry);
  }
  steps.push(name);
}

function finalizeCurrentStage(stageTelemetry, status, errorMessage) {
  if (!stageTelemetry || !stageTelemetry.currentStage) {
    return;
  }
  const currentStage = stageTelemetry.currentStage;
  const finishedMs = Date.now();
  stageTelemetry.stages.push({
    name: currentStage.name,
    started_at: currentStage.started_at,
    finished_at: new Date(finishedMs).toISOString(),
    duration_ms: Math.max(0, finishedMs - currentStage.started_ms),
    status: status || "ok",
    error: errorMessage ? String(errorMessage) : "",
  });
  stageTelemetry.currentStage = null;
  persistStageTelemetry(stageTelemetry);
}

function completeStageTelemetry(stageTelemetry, options) {
  if (!stageTelemetry) {
    return;
  }
  const resolvedStatus = String((options && options.status) || "ok");
  finalizeCurrentStage(
    stageTelemetry,
    resolvedStatus === "error" ? "error" : "ok",
    options && options.error
  );
  stageTelemetry.completed_at = new Date().toISOString();
  stageTelemetry.status = resolvedStatus;
  stageTelemetry.failed_stage = String((options && options.failedStage) || "");
  stageTelemetry.error = options && options.error ? String(options.error) : "";
  stageTelemetry.result = (options && options.result) || {};
  persistStageTelemetry(stageTelemetry);
}

function persistStageTelemetry(stageTelemetry) {
  if (!stageTelemetry || !stageTelemetry.outputPath) {
    return;
  }
  const payload = {
    version: stageTelemetry.version,
    scope: stageTelemetry.scope,
    run_started_at: stageTelemetry.run_started_at,
    completed_at: stageTelemetry.completed_at,
    elapsed_ms: Math.max(0, Date.now() - Number(stageTelemetry.run_started_ms || Date.now())),
    status: stageTelemetry.status,
    failed_stage: stageTelemetry.failed_stage,
    error: stageTelemetry.error,
    stages: stageTelemetry.stages,
    events: stageTelemetry.events || [],
    slowest_stages: slowestTelemetryEntries(stageTelemetry.stages || [], 8),
    slowest_events: slowestTelemetryEntries(stageTelemetry.events || [], 12),
    current_stage: stageTelemetry.currentStage
      ? {
          name: stageTelemetry.currentStage.name,
          started_at: stageTelemetry.currentStage.started_at,
          elapsed_ms: Math.max(0, Date.now() - stageTelemetry.currentStage.started_ms),
        }
      : null,
    notice_render_results: stageTelemetry.noticeRenderResults || [],
    result: stageTelemetry.result || {},
  };
  ensureDir(parentDirectory(stageTelemetry.outputPath));
  writeText(stageTelemetry.outputPath, JSON.stringify(payload));
}

function runTelemetryEvent(stageTelemetry, group, name, fn) {
  const startedMs = Date.now();
  const event = {
    group: String(group || ""),
    name: String(name || ""),
    stage: currentTelemetryStageName(stageTelemetry),
    started_at: new Date(startedMs).toISOString(),
    finished_at: "",
    duration_ms: 0,
    status: "running",
    error: "",
  };
  if (stageTelemetry) {
    appendTelemetryEvent(stageTelemetry, event);
  }
  try {
    const result = fn();
    const finishedMs = Date.now();
    event.finished_at = new Date(finishedMs).toISOString();
    event.duration_ms = Math.max(0, finishedMs - startedMs);
    event.status = "ok";
    if (stageTelemetry) {
      persistStageTelemetry(stageTelemetry);
    }
    return result;
  } catch (error) {
    const finishedMs = Date.now();
    event.finished_at = new Date(finishedMs).toISOString();
    event.duration_ms = Math.max(0, finishedMs - startedMs);
    event.status = "error";
    event.error = String(error);
    if (stageTelemetry) {
      persistStageTelemetry(stageTelemetry);
    }
    throw error;
  }
}

function appendTelemetryEvent(stageTelemetry, event) {
  if (!stageTelemetry || !event) {
    return;
  }
  stageTelemetry.events = stageTelemetry.events || [];
  stageTelemetry.events.push(event);
  persistStageTelemetry(stageTelemetry);
}

function currentTelemetryStageName(stageTelemetry) {
  return String((stageTelemetry && stageTelemetry.currentStage && stageTelemetry.currentStage.name) || "");
}

function slowestTelemetryEntries(entries, limit) {
  return (entries || [])
    .filter((entry) => String(entry.status || "") !== "running")
    .slice()
    .sort((left, right) => Number(right.duration_ms || 0) - Number(left.duration_ms || 0))
    .slice(0, limit || 8)
    .map((entry) => ({
      group: entry.group || "",
      name: entry.name || "",
      stage: entry.stage || "",
      duration_ms: Number(entry.duration_ms || 0),
      started_at: entry.started_at || "",
      finished_at: entry.finished_at || "",
      status: entry.status || "",
    }));
}

function readEnabledConfig(config, key, fallback) {
  const raw = safeString(() => config[key]).trim();
  if (!raw) {
    return fallback;
  }
  if (/^(1|true|yes|on)$/i.test(raw)) {
    return true;
  }
  if (/^(0|false|no|off)$/i.test(raw)) {
    return false;
  }
  return fallback;
}

function resolveIntegerConfig(config, key, fallback) {
  const raw = safeString(() => config[key]).trim();
  if (!raw) {
    return fallback;
  }
  const parsed = Math.round(Number(raw));
  return Number.isFinite(parsed) ? parsed : fallback;
}

function resolveFloatConfig(config, key, fallback) {
  const raw = safeString(() => config[key]).trim();
  if (!raw) {
    return fallback;
  }
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function extractPinnedSupplementalDetailUrls(stateJsonPath) {
  if (!fileExists(stateJsonPath)) {
    return new Set();
  }

  try {
    const state = JSON.parse(readText(stateJsonPath));
    const content = (state && state.content) || {};
    const urls = new Set();
    ["exam_items", "help_desk_items", "exam_candidates", "assignment_candidates"].forEach((bucket) => {
      ((content && content[bucket]) || []).forEach((item) => {
        const url = String((item && item.url) || "").trim();
        if (url && /\/mod\/courseboard\/article\.php/i.test(url)) {
          urls.add(url);
        }
      });
    });
    return urls;
  } catch (error) {
    return new Set();
  }
}

function prioritizeSupplementalDetailUrls(urls, previousUrls, pinnedUrls) {
  const previousSet = new Set(previousUrls || []);
  const pinnedSet = pinnedUrls instanceof Set ? pinnedUrls : new Set(pinnedUrls || []);
  const ordered = [];
  const seen = new Set();

  const append = (value) => {
    const url = String(value || "").trim();
    if (!url || seen.has(url)) {
      return;
    }
    seen.add(url);
    ordered.push(url);
  };

  (urls || []).forEach((url) => {
    if (!previousSet.has(url)) {
      append(url);
    }
  });
  (urls || []).forEach((url) => {
    if (pinnedSet.has(url)) {
      append(url);
    }
  });
  pinnedSet.forEach(append);
  (urls || []).forEach(append);
  return ordered;
}

function cachedPageRequestedUrls(path) {
  if (!path || !fileExists(path)) {
    return [];
  }
  try {
    return uniqueStrings(
      loadPagesJson(path).map((page) =>
        String((page && (page.requestedUrl || page.url)) || "").trim()
      )
    );
  } catch (error) {
    return [];
  }
}

function uniqueStrings(values) {
  const seen = new Set();
  const ordered = [];
  for (const value of values || []) {
    if (!value || seen.has(value)) {
      continue;
    }
    seen.add(value);
    ordered.push(value);
  }
  return ordered;
}

function looksLikeLoginPage(page) {
  const url = String((page && (page.url || page.finalUrl || page.requestedUrl)) || "").toLowerCase();
  const title = String((page && page.title) || "").toLowerCase();
  const html = String((page && page.html) || "").toLowerCase();
  return (
    url.includes("/login/") ||
    url.includes("ssologin") ||
    url.includes("sso.kaist.ac.kr") ||
    url.includes("portal.kaist.ac.kr") ||
    url.includes("login2factor") ||
    title.includes("ssologin") ||
    title.includes("single sign on") ||
    html.includes("login/ssologin.php") ||
    html.includes('name="username"') ||
    html.includes("login_id_mfa") ||
    html.includes("single sign on")
  );
}

function assertNoLoginPages(message, pages) {
  if (Array.isArray(pages) && pages.some((page) => looksLikeLoginPage(page))) {
    throw new Error(message);
  }
}

function assertRequiredPageCount(message, pages, expectedCount) {
  if (!Array.isArray(pages) || pages.length < expectedCount) {
    throw new Error(message);
  }
}

function mergePagesByRequestedUrl(pages) {
  const merged = [];
  const seen = new Set();
  for (const page of pages || []) {
    const requestedUrl = String(
      (page && (page.requestedUrl || page.url)) || ""
    ).trim();
    if (!requestedUrl || seen.has(requestedUrl)) {
      continue;
    }
    seen.add(requestedUrl);
    merged.push(page);
  }
  return merged;
}

function toAllWeekCourseUrl(courseViewUrl) {
  const text = String(courseViewUrl || "");
  const match = text.match(/[?&]id=(\d+)/);
  if (!match) {
    return "";
  }
  const originMatch = text.match(/^https?:\/\/[^/]+/);
  const origin = originMatch ? originMatch[0] : "https://klms.kaist.ac.kr";
  return `${origin}/course/view.php?id=${match[1]}&section=0`;
}

function fetchPages(urls, waitSeconds, scriptDir, options) {
  if (!urls || urls.length === 0) {
    return [];
  }

  const context = String((options && options.context) || "fetch");
  const tmpDir = String((options && options.tmpDir) || `${scriptDir}/runtime/tmp`);
  ensureDir(tmpDir);
  const slug = context.replace(/[^a-z0-9_-]+/gi, "-").replace(/^-+|-+$/g, "") || "fetch";
  const timestamp = String(Date.now());
  const urlFilePath = `${tmpDir}/${slug}-${timestamp}-urls.txt`;
  const outputPath =
    (options && options.outputPath) || `${tmpDir}/${slug}-${timestamp}-pages.json`;
  writeText(urlFilePath, `${urls.join("\n")}\n`);

  const command = [
    "/usr/bin/env",
    "python3",
    `${scriptDir}/src/python/fetch_pages_backend.py`,
    `--backend=${(options && options.backend) || "safari"}`,
    `--mode=${(options && options.mode) || "auto"}`,
    `--context=${context}`,
    `--wait=${waitSeconds}`,
    `--min-wait=${(options && options.minWaitSeconds) || "1.5"}`,
    `--stable-polls=${(options && options.stablePolls) || "2"}`,
    `--out=${outputPath}`,
    `--cache-state=${(options && options.cacheStatePath) || `${scriptDir}/runtime/cache/fetch_state.json`}`,
    `--url-file=${urlFilePath}`,
    `--quick-limit=${(options && options.quickLimit) || "0"}`,
    `--probe-order=${(options && options.probeOrder) || "index"}`,
    `--stale-seconds=${(options && options.staleSeconds) || "21600"}`,
    `--always-fetch-min-interval-seconds=${(options && options.alwaysFetchMinIntervalSeconds) || "0"}`,
    `--complete-reuse-seconds=${(options && options.completeReuseSeconds) || "0"}`,
    `--full-ttl-seconds=${(options && options.fullTtlSeconds) || "259200"}`,
    `--auto-full-min-coverage=${safeValue(() =>
      options.autoFullMinCoverage != null ? options.autoFullMinCoverage : "0.5"
    )}`,
    `--auto-full-require-last-full=${(options && options.autoFullRequireLastFull) ? "1" : "0"}`,
    `--auto-full-on-ttl-expire=${(options && options.autoFullOnTtlExpire) ? "1" : "0"}`,
  ];
  if (options && options.summaryPath) {
    command.push(`--summary-out=${options.summaryPath}`);
  }
  if (options && options.requireAll) {
    command.push("--require-all");
  }
  if (options && options.reuseFallbackAlwaysFetch) {
    command.push("--reuse-fallback-always-fetch");
  }
  (options && options.fallbackPagePaths ? options.fallbackPagePaths : []).forEach(
    (fallbackPath) => {
      if (fallbackPath && fileExists(fallbackPath)) {
        command.push(`--fallback-pages-json=${fallbackPath}`);
      }
    }
  );

  (options && options.alwaysFetchPatterns ? options.alwaysFetchPatterns : []).forEach(
    (pattern) => {
      if (pattern) {
        command.push(`--always-fetch-pattern=${pattern}`);
      }
    }
  );

  try {
    runCommand(command, scriptDir);
  } finally {
    removeFileIfExists(urlFilePath);
  }
  recordFetchSummaryTelemetry(options && options.summaryPath, context);
  const pages = JSON.parse(readText(outputPath));
  if (
    options &&
    options.requireAll &&
    (!Array.isArray(pages) || pages.length < urls.length)
  ) {
    throw new Error(
      `${context}: required page fetch returned ${
        Array.isArray(pages) ? pages.length : "invalid"
      } / ${urls.length}`
    );
  }
  return pages;
}

function recordFetchSummaryTelemetry(summaryPath, context) {
  if (!ACTIVE_STAGE_TELEMETRY || !summaryPath || !fileExists(summaryPath)) {
    return;
  }
  const summary = safeValue(() => JSON.parse(readText(summaryPath)));
  if (!summary) {
    return;
  }
  appendTelemetryEvent(ACTIVE_STAGE_TELEMETRY, {
    group: "fetch-summary",
    name: String(context || summary.context || "fetch"),
    stage: currentTelemetryStageName(ACTIVE_STAGE_TELEMETRY),
    started_at: String(summary.started_at || ""),
    finished_at: String(summary.finished_at || ""),
    duration_ms: Number(summary.duration_ms || 0),
    status: "ok",
    error: "",
    backend: String(summary.backend || ""),
    requested_mode: String(summary.requested_mode || ""),
    effective_mode: String(summary.effective_mode || ""),
    total_urls: Number(summary.total_urls || 0),
    selected_urls: Number(summary.selected_urls || 0),
    fetched_urls: Number(summary.fetched_urls || 0),
    reused_urls: Number(summary.reused_urls || 0),
    missing_urls: Number(summary.missing_urls || 0),
    changed_urls: Number(summary.changed_urls || 0),
    output_path: String(summary.out_path || ""),
  });
}

function safeString(getter) {
  try {
    const value = getter();
    return value == null ? "" : String(value);
  } catch (error) {
    return "";
  }
}

function safeValue(getter) {
  try {
    return getter();
  } catch (error) {
    return null;
  }
}

function safeDate(getter) {
  const value = safeValue(getter);
  if (!value) {
    return null;
  }
  return value instanceof Date ? value : new Date(value);
}

function sameDate(lhs, rhs) {
  if (!lhs && !rhs) {
    return true;
  }
  if (!lhs || !rhs) {
    return false;
  }
  return Math.abs(lhs.getTime() - rhs.getTime()) < 1000;
}

function parseEnvFile(path) {
  const content = readText(path);
  const config = {};

  content.split(/\r?\n/).forEach((line) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) {
      return;
    }

    const match = trimmed.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!match) {
      return;
    }

    let value = match[2].trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    config[match[1]] = value;
  });

  return config;
}

function applyRuntimeConfigOverrides(config) {
  const overrideKeys = [
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
    "NOTICE_NATIVE_ALWAYS_CAPTURE_STATE",
    "NOTICE_NATIVE_STABLE_NOOP_SKIP",
    "NOTICE_NATIVE_DEFER_STATE_ONLY_RENDER",
    "NOTICE_NATIVE_FORCE_ARCHIVE_POST_CAPTURE_RENDER",
    "NOTICE_NATIVE_VERIFY_STABLE_SKIP_FORMAT",
    "NOTICE_NATIVE_POST_RENDER_VERIFY",
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
  overrideKeys.forEach((key) => {
    const value = normalizeRuntimeEnvValue(envValue(key));
    if (value !== "") {
      config[key] = value;
    }
  });

}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\"'\"'`)}'`;
}

function ensureDir(path) {
  const error = Ref();
  const ok = $.NSFileManager.defaultManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(
    $(path).stringByStandardizingPath,
    true,
    $.NSDictionary.dictionary,
    error
  );
  if (!ok) {
    const message = error[0] ? ObjC.unwrap(error[0].localizedDescription) : "unknown error";
    throw new Error(`Failed to create directory ${path}: ${message}`);
  }
}

function fileExists(path) {
  return Boolean($.NSFileManager.defaultManager.fileExistsAtPath($(path).stringByStandardizingPath));
}

function removeFileIfExists(path) {
  if (!path || !fileExists(path)) {
    return;
  }
  const error = Ref();
  const ok = $.NSFileManager.defaultManager.removeItemAtPathError(
    $(path).stringByStandardizingPath,
    error
  );
  if (!ok) {
    const message = error[0] ? ObjC.unwrap(error[0].localizedDescription) : "unknown error";
    throw new Error(`Failed to remove ${path}: ${message}`);
  }
}

function envValue(key) {
  const value = $.NSProcessInfo.processInfo.environment.objectForKey($(key));
  if (value === null || value === undefined) {
    return "";
  }
  try {
    return normalizeRuntimeEnvValue(ObjC.unwrap(value));
  } catch (error) {
    return "";
  }
}

function normalizeRuntimeEnvValue(value) {
  if (value === null || value === undefined) {
    return "";
  }
  const text = String(value).trim();
  if (!text || /^(undefined|null)$/i.test(text)) {
    return "";
  }
  return text;
}

function buildPythonPath(scriptDir, runtimeDir) {
  const parts = [
    `${scriptDir}/src/python`,
    `${runtimeDir}/python-packages`,
    envValue("PYTHONPATH"),
  ].filter((part) => String(part || "").trim());
  return parts.join(":");
}

function fileModificationEpoch(path) {
  if (!fileExists(path)) {
    return 0;
  }
  const error = Ref();
  const attributes = $.NSFileManager.defaultManager.attributesOfItemAtPathError(
    $(path).stringByStandardizingPath,
    error
  );
  if (!attributes) {
    return 0;
  }
  const modifiedAt = attributes.objectForKey($.NSFileModificationDate);
  if (!modifiedAt) {
    return 0;
  }
  return Number(modifiedAt.timeIntervalSince1970);
}

function freshExistingFilesSince(paths, startedEpoch) {
  const threshold = Number(startedEpoch || 0);
  if (!Number.isFinite(threshold) || threshold <= 0) {
    return [];
  }
  return (paths || []).filter((path) => fileExists(path) && fileModificationEpoch(path) >= threshold);
}

function freshExistingFilesSinceOrWithin(paths, startedEpoch, maxAgeSeconds) {
  const sameRunPaths = freshExistingFilesSince(paths, startedEpoch);
  if (sameRunPaths.length > 0) {
    return sameRunPaths;
  }
  const maxAge = Number(maxAgeSeconds || 0);
  if (!Number.isFinite(maxAge) || maxAge <= 0) {
    return [];
  }
  const nowEpoch = Date.now() / 1000;
  return (paths || []).filter((path) => {
    if (!fileExists(path)) {
      return false;
    }
    const modifiedEpoch = fileModificationEpoch(path);
    return modifiedEpoch > 0 && nowEpoch - modifiedEpoch <= maxAge;
  });
}

function parentDirectory(path) {
  return ObjC.unwrap($(path).stringByDeletingLastPathComponent);
}

function baseName(path) {
  return ObjC.unwrap($(String(path || "")).lastPathComponent);
}

function readText(path) {
  const nsPath = $(path).stringByStandardizingPath;
  const error = Ref();
  const text = $.NSString.stringWithContentsOfFileEncodingError(
    nsPath,
    $.NSUTF8StringEncoding,
    error
  );
  if (!text) {
    throw new Error(
      `Failed to read ${path}: ${ObjC.unwrap(error[0].localizedDescription)}`
    );
  }
  return ObjC.unwrap(text);
}

function loadPagesJson(path) {
  const payload = JSON.parse(readText(path));
  if (!Array.isArray(payload)) {
    throw new Error(`Expected page array in ${path}`);
  }
  return payload;
}

function writeText(path, text) {
  const nsPath = $(path).stringByStandardizingPath;
  const nsText = $(text);
  const error = Ref();
  const ok = nsText.writeToFileAtomicallyEncodingError(
    nsPath,
    true,
    $.NSUTF8StringEncoding,
    error
  );
  if (!ok) {
    throw new Error(
      `Failed to write ${path}: ${ObjC.unwrap(error[0].localizedDescription)}`
    );
  }
}

function snapshotFiles(paths) {
  return paths.map((path) => ({
    path,
    exists: fileExists(path),
    text: fileExists(path) ? readText(path) : "",
  }));
}

function restoreFileSnapshot(snapshots) {
  snapshots.forEach((snapshot) => {
    if (snapshot.exists) {
      writeText(snapshot.path, snapshot.text);
    } else {
      removeFileIfExists(snapshot.path);
    }
  });
}

function writeDryRunReport(path, payload) {
  const report = {
    generated_at: new Date().toISOString(),
    dry_run: true,
    would_create: Number((payload && payload.would_create) || 0),
    would_update: Number((payload && payload.would_update) || 0),
    would_delete: Number((payload && payload.would_delete) || 0),
    would_download: Number((payload && payload.would_download) || 0),
    would_prune: Number((payload && payload.would_prune) || 0),
    skipped_side_effects: (payload && payload.skipped_side_effects) || [],
    ...payload,
  };
  writeText(path, JSON.stringify(report, null, 2));
  debugStderr(`dry-run report written ${path}`);
}

function stableHash(text) {
  const value = String(text || "");
  let hash = 2166136261;
  for (let i = 0; i < value.length; i += 1) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return hash.toString(16).padStart(8, "0");
}

function moveFile(src, dst) {
  runCommand(["/bin/rm", "-f", dst], currentDirectory());
  runCommand(["/bin/mv", src, dst], currentDirectory());
}

function currentDirectory() {
  return ObjC.unwrap($.NSFileManager.defaultManager.currentDirectoryPath);
}

function scriptDirectory() {
  const args = ObjC.deepUnwrap($.NSProcessInfo.processInfo.arguments) || [];
  for (let i = args.length - 1; i >= 0; i -= 1) {
    const value = String(args[i] || "");
    if (value.endsWith(".js")) {
      const sourceDir = ObjC.unwrap($(value).stringByDeletingLastPathComponent);
      if (sourceDir === "src/js") {
        return currentDirectory();
      }
      if (sourceDir.endsWith("/src/js")) {
        return sourceDir.slice(0, -"/src/js".length);
      }
      return sourceDir;
    }
  }
  return currentDirectory();
}

function runCommand(argv, cwd) {
  const commandText = argv.join(" ");
  debugStderr(`runCommand:start ${commandText}`);
  const telemetry = ACTIVE_STAGE_TELEMETRY && COMMAND_TIMING_ENABLED ? ACTIVE_STAGE_TELEMETRY : null;
  const startedMs = Date.now();
  const commandEvent = telemetry
    ? {
        group: "command",
        name: commandTelemetryName(argv),
        stage: currentTelemetryStageName(telemetry),
        command: argv.map((item) => String(item)),
        cwd: String(cwd || ""),
        started_at: new Date(startedMs).toISOString(),
        finished_at: "",
        duration_ms: 0,
        status: "running",
        exit_status: null,
        stdout_bytes: 0,
        stderr_bytes: 0,
        error: "",
      }
    : null;
  if (telemetry && COMMAND_TIMING_MIN_DURATION_MS === 0) {
    appendTelemetryEvent(telemetry, commandEvent);
  }

  const task = $.NSTask.alloc.init;
  task.setLaunchPath($(argv[0]));
  task.setArguments($(argv.slice(1)));
  if (cwd) {
    task.setCurrentDirectoryPath($(cwd));
  }

  const stdoutPipe = $.NSPipe.pipe;
  const stderrPipe = $.NSPipe.pipe;
  task.setStandardOutput(stdoutPipe);
  task.setStandardError(stderrPipe);

  try {
    task.launch;
    task.waitUntilExit;
  } catch (error) {
    finishCommandTelemetryEvent(telemetry, commandEvent, startedMs, {
      status: "error",
      exitStatus: null,
      stdoutBytes: 0,
      stderrBytes: 0,
      error: String(error),
    });
    throw error;
  }

  const stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile;
  const stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile;
  const stdoutText = nsDataToString(stdoutData);
  const stderrText = nsDataToString(stderrData);
  const exitStatus = Number(task.terminationStatus);
  const stdoutBytes = nsDataLength(stdoutData);
  const stderrBytes = nsDataLength(stderrData);

  if (exitStatus !== 0) {
    const errorText = stderrText || stdoutText || `Command failed: ${commandText}`;
    finishCommandTelemetryEvent(telemetry, commandEvent, startedMs, {
      status: "error",
      exitStatus,
      stdoutBytes,
      stderrBytes,
      error: errorText,
    });
    throw new Error(errorText);
  }

  finishCommandTelemetryEvent(telemetry, commandEvent, startedMs, {
    status: "ok",
    exitStatus,
    stdoutBytes,
    stderrBytes,
    error: "",
  });
  debugStderr(`runCommand:done ${argv[0]}`);
  return stdoutText;
}

function commandTelemetryName(argv) {
  const parts = (argv || []).map((item) => String(item || ""));
  const executable = baseName(parts[0] || "command");
  const script = parts.find((part) => /\.(py|js|swift|sh|mjs)$/.test(part));
  if (script) {
    return `${executable} ${baseName(script)}`;
  }
  return executable;
}

function finishCommandTelemetryEvent(telemetry, event, startedMs, result) {
  if (!telemetry || !event) {
    return;
  }
  const finishedMs = Date.now();
  const durationMs = Math.max(0, finishedMs - startedMs);
  event.finished_at = new Date(finishedMs).toISOString();
  event.duration_ms = durationMs;
  event.status = String(result.status || "ok");
  event.exit_status = result.exitStatus;
  event.stdout_bytes = Number(result.stdoutBytes || 0);
  event.stderr_bytes = Number(result.stderrBytes || 0);
  event.error = result.error ? firstLine(String(result.error), 400) : "";
  if (COMMAND_TIMING_MIN_DURATION_MS > 0 && durationMs >= COMMAND_TIMING_MIN_DURATION_MS) {
    appendTelemetryEvent(telemetry, event);
    return;
  }
  persistStageTelemetry(telemetry);
}

function nsDataLength(data) {
  if (!data) {
    return 0;
  }
  return Number(data.length || 0);
}

function firstLine(text, maxLength) {
  const line = String(text || "").split(/\r?\n/)[0] || "";
  const limit = Math.max(1, maxLength || 400);
  return line.length > limit ? `${line.slice(0, limit)}...` : line;
}

function debugStderr(message) {
  if (!DEBUG_STDERR_ENABLED) {
    return;
  }
  const text = `[sync_klms_notes] ${String(message || "")}\n`;
  const data = $(text).dataUsingEncoding($.NSUTF8StringEncoding);
  $.NSFileHandle.fileHandleWithStandardError.writeData(data);
}

function nsDataToString(data) {
  if (!data || data.length === 0) {
    return "";
  }
  const text = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
  return text ? ObjC.unwrap(text) : "";
}
