#!/usr/bin/osascript -l JavaScript

ObjC.import("Foundation");

const MARKER = "[[KLMS 자동 동기화]]";
const REMINDER_MARKER_PREFIX = "KLMS_SYNC_ITEM_ID:";
const LEGACY_REMINDER_MARKER_PREFIXES = ["KLMS_ASSIGN_ID:"];
const REMINDER_MARKER_PREFIXES = [REMINDER_MARKER_PREFIX].concat(LEGACY_REMINDER_MARKER_PREFIXES);
const NATIVE_NOTICE_RENDER_STYLE_VERSION = "2026-05-27-functional-notes-v14-section-item-collapse-only";
let DEBUG_STDERR_ENABLED = false;
let ACTIVE_STAGE_TELEMETRY = null;
let COMMAND_TIMING_ENABLED = true;
let COMMAND_TIMING_MIN_DURATION_MS = 0;
const REMINDER_LIST_APPEARANCE = {
  "KLMS 과제": { color: "#0F766E", emblem: "" },
  "KLMS 확인 필요": { color: "#C2410C", emblem: "" },
  "KLMS 알림": { color: "#0F766E", emblem: "" },
};
const REMINDER_STAGE_ALERTS = [
  { key: "1d", label: "1일 전", ms: 24 * 3600 * 1000 },
  { key: "2h", label: "2시간 전", ms: 2 * 3600 * 1000 },
];

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

function filterNoticeBoardUrls(urls) {
  return uniqueStrings(
    (urls || []).filter((url) => /\/mod\/courseboard\/view\.php/i.test(String(url || "")))
  );
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
    html.includes('type="password"') ||
    html.includes("login_id_mfa") ||
    html.includes("single sign on") ||
    html.includes("비밀번호")
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
      const formatOutput = verifyNativeNoticeReadableFormat(target.key);
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
    noticeRenderVisibleKeys(primaryRenderState, archiveRenderState).join("\n") ===
      expectedNoticeVisibleKeys(expected).join("\n");
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
      const isRead = Boolean(fingerprint) && state.read_fingerprint === fingerprint;
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
  const collapseCourses =
    nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_COLLAPSE_COURSES", false);
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
    `display_mode=${targetKey === "archive" ? "archive" : "primary"}`,
    `collapse_sections=${nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_COLLAPSE_SECTIONS", false) ? "1" : "0"}`,
    `collapse_courses=${collapseCourses ? "1" : "0"}`,
    `collapse_notice_items=${nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_COLLAPSE_NOTICE_ITEMS", false) ? "1" : "0"}`,
    `style_notice_items=${nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_STYLE_NOTICE_ITEMS_AS_HEADINGS", false) ? "1" : "0"}`,
    `hide_hidden=${nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_HIDE_HIDDEN_ITEMS", true) ? "1" : "0"}`,
    `ui_style_menu=${uiStyleMenu ? "1" : "0"}`,
    `preformatted_paste_only=${nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_NATIVE_PREFORMATTED_PASTE_ONLY", false) ? "1" : "0"}`,
    `plain_text_paste=${nativeNoticeEnvironmentEnabled(nativeEnvironment, "NOTICE_NATIVE_PLAIN_TEXT_PASTE", false) ? "1" : "0"}`,
    `batch_checklist=${batchChecklist ? "1" : "0"}`,
    `fast_batch_checklist=${fastBatchChecklist ? "1" : "0"}`,
  ];
}

function noticeRenderVisibleKeys(primaryRenderState, archiveRenderState) {
  return [
    ...renderStateNoticeKeys(primaryRenderState),
    ...renderStateNoticeKeys(archiveRenderState),
  ].sort();
}

function expectedNoticeVisibleKeys(expected) {
  return [
    ...expectedNoticeKeys(expected.primary),
    ...expectedNoticeKeys(expected.archive),
  ].sort();
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

function syncCalendarsFromState(stateJsonPath, scriptDir, config, calendarOptions) {
  const durationMinutes = String(config.CALENDAR_EVENT_DURATION_MINUTES || "15");
  const lookbackDays = String(config.CALENDAR_LOOKBACK_DAYS || "365");
  const tmpDir = String((calendarOptions && calendarOptions.tmpDir) || `${scriptDir}/runtime/tmp/core`);
  const swiftModuleCacheDir = `${tmpDir}/swift-module-cache`;
  const clangModuleCacheDir = `${tmpDir}/clang-module-cache`;
  ensureDir(swiftModuleCacheDir);
  ensureDir(clangModuleCacheDir);
  const command = [
    "/usr/bin/env",
    `SWIFT_MODULE_CACHE_PATH=${swiftModuleCacheDir}`,
    `CLANG_MODULE_CACHE_PATH=${clangModuleCacheDir}`,
    "/usr/bin/swift",
    "-module-cache-path",
    swiftModuleCacheDir,
    `${scriptDir}/src/swift/sync_klms_calendar_suite.swift`,
    stateJsonPath,
    `--duration-minutes=${durationMinutes}`,
    `--lookback-days=${lookbackDays}`,
  ];

  if (calendarOptions && calendarOptions.examEnabled) {
    command.push(`--exam-calendar=${config.EXAM_CALENDAR_NAME || "시험"}`);
  }
  if (calendarOptions && calendarOptions.helpDeskEnabled) {
    command.push(`--helpdesk-calendar=${config.HELP_DESK_CALENDAR_NAME || "기타"}`);
  }

  if (command.length > 3) {
    try {
      const output = runCommand(command, scriptDir);
      writeCalendarSyncResult(calendarOptions && calendarOptions.resultJson, output, "swift");
    } catch (error) {
      if (config.CALENDAR_SYNC_APPLESCRIPT_FALLBACK !== "1") {
        throw error;
      }
      debugStderr("deprecated-calendar-jxa-fallback");
      runCommand(["/bin/sh", "-c", "printf '%s\\n' deprecated-calendar-jxa-fallback >&2"], scriptDir);

      const fallbackCommand = [
        "/usr/bin/osascript",
        "-l",
        "JavaScript",
        `${scriptDir}/src/js/sync_klms_calendar_jxa.js`,
        stateJsonPath,
        `--duration-minutes=${durationMinutes}`,
        `--lookback-days=${lookbackDays}`,
      ];
      if (calendarOptions && calendarOptions.examEnabled) {
        fallbackCommand.push(`--exam-calendar=${config.EXAM_CALENDAR_NAME || "시험"}`);
      }
      if (calendarOptions && calendarOptions.helpDeskEnabled) {
        fallbackCommand.push(`--helpdesk-calendar=${config.HELP_DESK_CALENDAR_NAME || "기타"}`);
      }
      const fallbackOutput = runCommand(fallbackCommand, scriptDir);
      writeCalendarSyncResult(calendarOptions && calendarOptions.resultJson, fallbackOutput, "jxa-deprecated");
    }
  }
}

function writeCalendarSyncResult(path, output, backend) {
  if (!path) {
    return;
  }
  const summaries = [];
  const changes = [];
  String(output || "")
    .split(/\r?\n/)
    .filter(Boolean)
    .forEach((line) => {
      if (line.startsWith("calendar_change_json=")) {
        const raw = line.slice("calendar_change_json=".length);
        try {
          changes.push(JSON.parse(raw));
        } catch (error) {
          changes.push({
            raw: line,
            parse_error: String((error && error.message) || error),
          });
        }
        return;
      }
      const item = { raw: line };
      line.split(/\s+/).forEach((part) => {
        const pieces = part.split("=");
        if (pieces.length === 2) {
          const key = pieces[0];
          const value = pieces[1];
          item[key] = /^\d+$/.test(value) ? Number(value) : value;
        }
      });
      summaries.push(item);
    });
  writeText(
    path,
    JSON.stringify(
      {
        backend,
        generated_at: new Date().toISOString(),
        summaries,
        changes,
      },
      null,
      2
    )
  );
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

function syncRemindersFromState(
  stateJsonPath,
  listName,
  issueListName,
  completedReminderRetentionDays,
  reminderOptions
) {
  const state = JSON.parse(readText(stateJsonPath));
  if (state.status !== "ok" || !state.content || state.content.kind !== "success") {
    throw new Error("State is not syncable for reminders.");
  }

  const remindersApp = Application("/System/Applications/Reminders.app");
  const reminderSnapshot = runTelemetryEvent(
    ACTIVE_STAGE_TELEMETRY,
    "reminders",
    "snapshot-lists",
    () => buildReminderAppSnapshot(remindersApp)
  );
  const desired = runTelemetryEvent(
    ACTIVE_STAGE_TELEMETRY,
    "reminders",
    "build-desired",
    () => buildDesiredReminders(normalizeSyncEntries(state.content), reminderOptions)
  );
  const retentionMs = completedReminderRetentionDays * 24 * 3600 * 1000;
  const activeSummary = syncReminderList(
    remindersApp,
    reminderSnapshot,
    listName,
    desired.active,
    retentionMs
  );
  const issueSummary = syncReminderList(
    remindersApp,
    reminderSnapshot,
    issueListName,
    desired.issues,
    retentionMs
  );
  const alertListName = (reminderOptions && reminderOptions.alertListName) || "KLMS 알림";
  let alertSummary = "reminders-alerts=skipped disabled";
  if (reminderOptions && reminderOptions.stageAlertsEnabled) {
    alertSummary = syncReminderList(
      remindersApp,
      reminderSnapshot,
      alertListName,
      desired.alerts,
      0,
      { recreateList: reminderOptions.recreateStageAlertList !== false }
    );
  } else if (
    reminderOptions &&
    reminderOptions.cleanDisabledStageAlerts &&
    findReminderList(remindersApp, alertListName, reminderSnapshot)
  ) {
    alertSummary = syncReminderList(remindersApp, reminderSnapshot, alertListName, [], 0);
  }
  return `${activeSummary} ${issueSummary} ${alertSummary}`;
}

function buildRemindersDesiredHash(
  stateJsonPath,
  listName,
  issueListName,
  completedReminderRetentionDays,
  reminderOptions
) {
  const state = JSON.parse(readText(stateJsonPath));
  if (state.status !== "ok" || !state.content || state.content.kind !== "success") {
    return stableHash(readText(stateJsonPath));
  }

  const options = reminderOptions || {};
  const desired = buildDesiredReminders(normalizeSyncEntries(state.content), options);
  return stableHash(
    JSON.stringify({
      listName,
      issueListName,
      completedReminderRetentionDays,
      options: {
        deviceAlertsEnabled: Boolean(options.deviceAlertsEnabled),
        deviceAlertMode: options.deviceAlertMode || "adaptive",
        stageAlertsEnabled: Boolean(options.stageAlertsEnabled),
        cleanDisabledStageAlerts: Boolean(options.cleanDisabledStageAlerts),
        recreateStageAlertList: options.recreateStageAlertList !== false,
        alertListName: options.alertListName || "KLMS 알림",
      },
      desired,
    })
  );
}

function buildCalendarDesiredHash(stateJsonPath, config, calendarOptions) {
  const state = JSON.parse(readText(stateJsonPath));
  if (state.status !== "ok" || !state.content || state.content.kind !== "success") {
    return stableHash(readText(stateJsonPath));
  }

  const options = calendarOptions || {};
  const content = state.content || {};
  const normalizeCalendarItem = (item) => ({
    category: item && item.category || "",
    course: item && item.course || "",
    title: item && item.title || "",
    due: item && item.due || "",
    submission: item && item.submission || "",
    instructions: item && item.instructions || "",
    url: item && item.url || "",
    sync_start: item && item.sync_start || "",
    sync_due: item && item.sync_due || "",
    timing_precision: item && item.timing_precision || "",
    time_source: item && item.time_source || "",
    source_title: item && item.source_title || "",
    location: item && item.location || "",
    coverage: item && item.coverage || "",
    coverage_summary: item && item.coverage_summary || "",
  });
  const sortCalendarItems = (items) =>
    (Array.isArray(items) ? items : [])
      .map(normalizeCalendarItem)
      .sort((left, right) =>
        [
          left.category,
          left.url,
          left.course,
          left.title,
          left.sync_due || left.due,
        ].join("\u0000").localeCompare([
          right.category,
          right.url,
          right.course,
          right.title,
          right.sync_due || right.due,
        ].join("\u0000"))
      );

  return stableHash(
    JSON.stringify({
      options: {
        examEnabled: Boolean(options.examEnabled),
        helpDeskEnabled: Boolean(options.helpDeskEnabled),
        examCalendarName: config.EXAM_CALENDAR_NAME || "시험",
        helpDeskCalendarName: config.HELP_DESK_CALENDAR_NAME || "기타",
        durationMinutes: String(config.CALENDAR_EVENT_DURATION_MINUTES || "15"),
        lookbackDays: String(config.CALENDAR_LOOKBACK_DAYS || "365"),
      },
      exam_items: options.examEnabled ? sortCalendarItems(content.exam_items) : [],
      help_desk_items: options.helpDeskEnabled ? sortCalendarItems(content.help_desk_items) : [],
    })
  );
}

function importCompletedRemindersToOverrides(stateJsonPath, overridesJsonPath, listNames) {
  if (!fileExists(stateJsonPath)) {
    return "completed-reminders=skipped state-missing";
  }

  const state = JSON.parse(readText(stateJsonPath));
  if (state.status !== "ok" || !state.content || state.content.kind !== "success") {
    return "completed-reminders=skipped state-not-syncable";
  }

  const identifierToUrl = {};
  normalizeSyncEntries(state.content)
    .filter(
      (entry) =>
        entry.category !== "exam" &&
        entry.category !== "exam_candidate" &&
        entry.category !== "assignment_candidate" &&
        entry.category !== "help_desk"
    )
    .forEach((entry) => {
      const identifier = reminderIdentifierForItem(entry);
      if (identifier && entry.url) {
        identifierToUrl[identifier] = entry.url;
      }
    });

  const knownIdentifiers = Object.keys(identifierToUrl);
  if (knownIdentifiers.length === 0) {
    return "completed-reminders=skipped no-known-assignments";
  }

  const remindersApp = Application("/System/Applications/Reminders.app");
  const reminderSnapshot = runTelemetryEvent(
    ACTIVE_STAGE_TELEMETRY,
    "completed-reminders",
    "snapshot-lists",
    () => buildReminderAppSnapshot(remindersApp)
  );
  const completedIdentifiers = runTelemetryEvent(
    ACTIVE_STAGE_TELEMETRY,
    "completed-reminders",
    "collect-completed",
    () => collectCompletedReminderIdentifiers(
      remindersApp,
      listNames,
      reminderSnapshot
    )
  );
  if (completedIdentifiers.length === 0) {
    return "completed-reminders=ok imported=0 changed=0";
  }

  const overrideDocument = loadAssignmentOverrideDocument(overridesJsonPath);
  let imported = 0;
  let changed = 0;

  completedIdentifiers.forEach((identifier) => {
    const url = identifierToUrl[identifier];
    if (!url) {
      return;
    }
    imported += 1;
    if (overrideDocument.assignments[url] !== "completed") {
      overrideDocument.assignments[url] = "completed";
      changed += 1;
    }
  });

  if (changed > 0) {
    writeAssignmentOverrideDocument(overridesJsonPath, overrideDocument);
  }

  return `completed-reminders=ok imported=${imported} changed=${changed}`;
}

function buildReminderAppSnapshot(remindersApp) {
  const listsByName = {};
  const remindersByListId = {};
  const loadedListIds = {};

  (safeValue(() => remindersApp.lists()) || []).forEach((list) => {
    const listName = safeString(() => list.name());
    if (!listName) {
      return;
    }
    if (!listsByName[listName]) {
      listsByName[listName] = [];
    }
    listsByName[listName].push(list);
  });

  return {
    listsByName,
    remindersByListId,
    loadedListIds,
  };
}

function rememberReminderListSnapshot(reminderSnapshot, list) {
  if (!reminderSnapshot || !list) {
    return;
  }

  const listName = safeString(() => list.name());
  const listId = safeString(() => list.id());
  if (!listName || !listId) {
    return;
  }

  const existing = reminderSnapshot.listsByName[listName] || [];
  if (!existing.some((item) => safeString(() => item.id()) === listId)) {
    reminderSnapshot.listsByName[listName] = existing.concat([list]);
  }
  if (!reminderSnapshot.remindersByListId[listId]) {
    reminderSnapshot.remindersByListId[listId] = [];
  }
  reminderSnapshot.loadedListIds[listId] = true;
}

function loadReminderItemsForList(list, reminderSnapshot) {
  const listId = safeString(() => list && list.id());
  if (!listId || !reminderSnapshot) {
    return safeValue(() => (list ? list.reminders() : [])) || [];
  }

  if (!reminderSnapshot.loadedListIds[listId]) {
    reminderSnapshot.remindersByListId[listId] = safeValue(() => list.reminders()) || [];
    reminderSnapshot.loadedListIds[listId] = true;
  }

  return reminderSnapshot.remindersByListId[listId] || [];
}

function syncReminderList(
  remindersApp,
  reminderSnapshot,
  listName,
  desiredReminders,
  completedRetentionMs,
  options
) {
  if (options && options.recreateList) {
    runTelemetryEvent(
      ACTIVE_STAGE_TELEMETRY,
      "reminders",
      `recreate-list:${listName}`,
      () => {
        const existing = findReminderList(remindersApp, listName, reminderSnapshot);
        if (existing) {
          forgetReminderListSnapshot(reminderSnapshot, listName, existing);
          remindersApp.delete(existing);
        }
      }
    );
  }

  const list = runTelemetryEvent(
    ACTIVE_STAGE_TELEMETRY,
    "reminders",
    `resolve-list:${listName}`,
    () => getOrCreateReminderList(remindersApp, listName, reminderSnapshot)
  );
  const listId = safeString(() => list.id());
  const desiredById = {};

  desiredReminders.forEach((item) => {
    desiredById[item.identifier] = item;
  });

  const existingReminders = runTelemetryEvent(
    ACTIVE_STAGE_TELEMETRY,
    "reminders",
    `load-list:${listName}`,
    () => loadReminderItemsForList(list, reminderSnapshot)
      .filter((item) => extractIdentifierFromText(safeString(() => item.body())))
  );

  const seenExistingIdentifiers = new Set();
  const existingIds = new Set();
  let created = 0;
  let updated = 0;
  let deleted = 0;
  let retainedCompleted = 0;

  runTelemetryEvent(
    ACTIVE_STAGE_TELEMETRY,
    "reminders",
    `reconcile-existing:${listName}`,
    () => {
      existingReminders.forEach((reminder) => {
        const identifier = extractIdentifierFromText(safeString(() => reminder.body()));
        if (!identifier) {
          return;
        }

        if (
          identifier.startsWith("exam:") ||
          identifier.startsWith("assignment-candidate:")
        ) {
          remindersApp.delete(reminder);
          deleted += 1;
          return;
        }

        if (seenExistingIdentifiers.has(identifier)) {
          remindersApp.delete(reminder);
          deleted += 1;
          return;
        }
        seenExistingIdentifiers.add(identifier);

        const desired = desiredById[identifier];
        if (!desired) {
          if (shouldRetainCompletedReminder(reminder, completedRetentionMs, identifier)) {
            retainedCompleted += 1;
            return;
          }
          remindersApp.delete(reminder);
          deleted += 1;
          return;
        }

        const updateResult = applyReminderIfNeeded(reminder, desired);
        if (updateResult === "recreate") {
          remindersApp.delete(reminder);
          deleted += 1;
          return;
        }

        if (updateResult === "updated") {
          updated += 1;
        }

        existingIds.add(identifier);
      });
    }
  );

  runTelemetryEvent(
    ACTIVE_STAGE_TELEMETRY,
    "reminders",
    `create-missing:${listName}`,
    () => {
      desiredReminders.forEach((desired) => {
        if (existingIds.has(desired.identifier)) {
          return;
        }
        const properties = {
          name: desired.title,
          body: desired.body,
        };
        if (desired.dueDate) {
          properties.dueDate = desired.dueDate;
        }
        if (desired.remindMeDate) {
          properties.remindMeDate = desired.remindMeDate;
        }

        const createdReminder = remindersApp.make({
          new: "reminder",
          at: list,
          withProperties: properties,
        });
        if (reminderSnapshot && listId) {
          if (!reminderSnapshot.remindersByListId[listId]) {
            reminderSnapshot.remindersByListId[listId] = [];
          }
          reminderSnapshot.remindersByListId[listId].push(createdReminder);
        }
        created += 1;
      });
    }
  );

  return `reminders=${listName} created=${created} updated=${updated} deleted=${deleted} retained_completed=${retainedCompleted} total=${desiredReminders.length}`;
}

function forgetReminderListSnapshot(reminderSnapshot, listName, list) {
  if (!reminderSnapshot || !listName || !list) {
    return;
  }

  const listId = safeString(() => list.id());
  if (listId) {
    delete reminderSnapshot.remindersByListId[listId];
    delete reminderSnapshot.loadedListIds[listId];
  }

  const existing = reminderSnapshot.listsByName[listName] || [];
  reminderSnapshot.listsByName[listName] = existing.filter((item) => {
    const itemId = safeString(() => item.id());
    return !listId || itemId !== listId;
  });
}

function collectCompletedReminderIdentifiers(remindersApp, listNames, reminderSnapshot) {
  const identifiers = new Set();

  listNames.forEach((listName) => {
    if (!listName) {
      return;
    }

    const list = findReminderList(remindersApp, listName, reminderSnapshot);
    if (!list) {
      return;
    }

    const listId = safeString(() => list.id());
    const completedItems = loadReminderItemsForList(list, reminderSnapshot);
    completedItems
      .filter((item) => safeValue(() => item.completed()))
      .forEach((item) => {
        const identifier = extractIdentifierFromText(safeString(() => item.body()));
        if (
          identifier &&
          !identifier.startsWith("exam:") &&
          !identifier.startsWith("assignment-candidate:") &&
          !identifier.startsWith("helpdesk:")
        ) {
          identifiers.add(identifier);
        }
      });
  });

  return Array.from(identifiers);
}

function shouldRetainCompletedReminder(reminder, retentionMs, identifier) {
  if (!safeValue(() => reminder.completed())) {
    return false;
  }
  if (shouldDeleteCompletedReminderImmediately(identifier)) {
    return false;
  }
  if (!(retentionMs > 0)) {
    return false;
  }

  const completionDate =
    safeDate(() => reminder.completionDate()) ||
    safeDate(() => reminder.modificationDate()) ||
    safeDate(() => reminder.creationDate());

  if (!completionDate) {
    return true;
  }

  return Date.now() - completionDate.getTime() < retentionMs;
}

function shouldDeleteCompletedReminderImmediately(identifier) {
  if (!identifier) {
    return false;
  }

  if (identifier.startsWith("alert:")) {
    return true;
  }

  return (
    !identifier.startsWith("exam:") &&
    !identifier.startsWith("assignment-candidate:") &&
    !identifier.startsWith("helpdesk:")
  );
}

function findReminderList(remindersApp, listName, reminderSnapshot) {
  const matches = reminderSnapshot
    ? reminderSnapshot.listsByName[listName] || []
    : remindersApp.lists().filter((list) => safeString(() => list.name()) === listName);
  if (matches.length > 1) {
    throw new Error(`Multiple reminders lists found for '${listName}'.`);
  }
  return matches.length === 1 ? matches[0] : null;
}

function getOrCreateReminderList(remindersApp, listName, reminderSnapshot) {
  const existing = findReminderList(remindersApp, listName, reminderSnapshot);
  if (existing) {
    applyReminderListAppearance(existing, listName);
    return existing;
  }

  const account = preferredReminderAccount(remindersApp);
  if (!account) {
    throw new Error("Could not find a Reminders account to create the KLMS list in.");
  }

  const created = remindersApp.make({
    new: "list",
    at: account,
    withProperties: { name: listName },
  });
  applyReminderListAppearance(created, listName);
  rememberReminderListSnapshot(reminderSnapshot, created);
  return created;
}

function preferredReminderAccount(remindersApp) {
  const accounts = safeValue(() => remindersApp.accounts()) || [];
  const iCloudAccount = accounts.find((account) =>
    safeString(() => account.name()).toLowerCase().includes("icloud")
  );
  return iCloudAccount || safeValue(() => remindersApp.defaultAccount()) || accounts[0] || null;
}

function applyReminderListAppearance(list, listName) {
  const appearance = REMINDER_LIST_APPEARANCE[listName];
  if (!appearance || !list) {
    return;
  }

  if (appearance.color && safeString(() => list.color()) !== appearance.color) {
    list.color = appearance.color;
  }
  if (
    Object.prototype.hasOwnProperty.call(appearance, "emblem") &&
    safeString(() => list.emblem()) !== appearance.emblem
  ) {
    list.emblem = appearance.emblem;
  }
}

function buildDesiredReminders(entries, reminderOptions) {
  const active = [];
  const issues = [];
  const alerts = [];
  const options = reminderOptions || {};

  entries.forEach((entry) => {
    if (entry.category === "help_desk") {
      return;
    }
    if (entry.category === "exam") {
      return;
    }
    if (entry.category === "exam_candidate") {
      return;
    }
    if (entry.category === "assignment_candidate") {
      return;
    }
    if (isCompletedAssignment(entry)) {
      return;
    }

    const dueDate = parseReminderDueDate(entry.sync_due, entry.due);
    const identifier = reminderIdentifierForItem(entry);
    const titlePrefix = entry.category === "exam" ? "[시험] " : "";
    const title = entry.course
      ? `[${entry.course}] ${titlePrefix}${entry.title}`
      : `${titlePrefix}${entry.title}`;
    const scheduleLabel = entry.category === "exam" ? "일정" : "마감";
    const detailLabel = entry.category === "exam" ? "메모" : "해야 할 일";
    const issuePrefix = entry.category === "exam" ? "시험 일정" : "마감 정보";
    const lines = [];
    lines.push(
      `종류: ${
        entry.category === "exam"
          ? "시험 일정"
          : "과제"
      }`
    );
    if (entry.course) {
      lines.push(`과목: ${entry.course}`);
    }
    if (entry.due) {
      lines.push(`${scheduleLabel}: ${entry.due}`);
    } else {
      lines.push(`${scheduleLabel}: 확인 필요`);
    }
    if (entry.category === "exam" && entry.timing_precision === "date") {
      lines.push("시간: KLMS에서 날짜만 확인됨");
    }
    if (entry.source_title) {
      lines.push(`출처: ${entry.source_title}`);
    }
    if (entry.instructions) {
      lines.push(`${detailLabel}: ${entry.instructions}`);
    }
    lines.push(`링크: ${entry.url}`);

    if (!dueDate) {
      lines.unshift(`분류: ${issuePrefix} 확인 필요`);
      lines.push(`${REMINDER_MARKER_PREFIX}${identifier}`);
      issues.push({
        identifier,
        title,
        dueDate: null,
        remindMeDate: null,
        body: lines.join("\n"),
      });
      return;
    }

    if (dueDate.getTime() <= Date.now()) {
      lines.unshift(`분류: ${entry.category === "exam" ? "시험 일정 경과" : "기한 경과"}`);
      lines.push(`${REMINDER_MARKER_PREFIX}${identifier}`);
      issues.push({
        identifier,
        title,
        dueDate,
        remindMeDate: null,
        body: lines.join("\n"),
      });
      return;
    }

    lines.push(`${REMINDER_MARKER_PREFIX}${identifier}`);
    const remindMeDate = buildReminderAlertDate(dueDate, options);
    active.push({
      identifier,
      title,
      dueDate,
      remindMeDate,
      body: lines.join("\n"),
    });

    if (options.stageAlertsEnabled) {
      alerts.push(...buildStageAlertReminders(entry, identifier, title, dueDate));
    }
  });

  return { active, issues, alerts };
}

function isCompletedAssignment(assignment) {
  if (assignment.category === "exam") {
    return false;
  }
  if (assignment.auto_completed) {
    return true;
  }

  const submission = normalizeWhitespace(String(assignment.submission || ""));
  if (!submission) {
    return false;
  }

  return [
    "채점을 위해 제출되었습니다",
    "제출되었습니다",
    "제출 완료",
    "채점 완료",
    "submitted for grading",
    "submitted",
    "graded",
  ].some((keyword) => submission.toLowerCase().includes(keyword.toLowerCase()));
}

function normalizeSyncEntries(content) {
  const assignments = Array.isArray(content.assignments) ? content.assignments : [];
  const examItems = Array.isArray(content.exam_items) ? content.exam_items : [];
  const examCandidates = Array.isArray(content.exam_candidates) ? content.exam_candidates : [];
  const assignmentCandidates = Array.isArray(content.assignment_candidates)
    ? content.assignment_candidates
    : [];
  const helpDeskItems = Array.isArray(content.help_desk_items) ? content.help_desk_items : [];
  return assignments
    .concat(examItems)
    .concat(examCandidates)
    .concat(assignmentCandidates)
    .concat(helpDeskItems)
    .map((item) => ({
      auto_completed: Boolean(item.auto_completed),
      category: item.category || "assignment",
      course: item.course || "",
      due: item.due || "",
      instructions: item.instructions || "",
      source_title: item.source_title || "",
      submission: item.submission || "",
      sync_due: item.sync_due || "",
      timing_precision: item.timing_precision || "",
      title: item.title || "",
      url: item.url || "",
    }));
}

function reminderIdentifierForItem(entry) {
  const baseIdentifier = syncItemBaseIdentifierFromUrl(entry.url);
  if (entry.category === "help_desk") {
    const titlePart = encodeIdentifierFragment(entry.title);
    const duePart = encodeIdentifierFragment(entry.sync_due || entry.due);
    return `helpdesk:${baseIdentifier}:${titlePart}:${duePart}`;
  }

  if (entry.category === "assignment_candidate") {
    const titlePart = encodeIdentifierFragment(entry.title);
    const duePart = encodeIdentifierFragment(entry.sync_due || entry.due);
    return `assignment-candidate:${baseIdentifier}:${titlePart}:${duePart}`;
  }

  if (entry.category !== "exam" && entry.category !== "exam_candidate") {
    return baseIdentifier;
  }

  const titlePart = encodeIdentifierFragment(entry.title);
  const duePart = encodeIdentifierFragment(entry.sync_due || entry.due);
  return `exam:${baseIdentifier}:${titlePart}:${duePart}`;
}

function encodeIdentifierFragment(value) {
  return encodeURIComponent(normalizeWhitespace(String(value || "")).toLowerCase());
}

function loadAssignmentOverrideDocument(path) {
  if (!fileExists(path)) {
    return { payload: { assignments: {} }, assignments: {} };
  }

  const payload = JSON.parse(readText(path));
  if (payload && typeof payload === "object" && !Array.isArray(payload)) {
    if (payload.assignments && typeof payload.assignments === "object") {
      return {
        payload,
        assignments: normalizeOverrideAssignments(payload.assignments),
      };
    }
    return {
      payload: { assignments: normalizeOverrideAssignments(payload) },
      assignments: normalizeOverrideAssignments(payload),
    };
  }

  return { payload: { assignments: {} }, assignments: {} };
}

function normalizeOverrideAssignments(payload) {
  const assignments = {};
  Object.keys(payload || {}).forEach((key) => {
    const normalizedKey = String(key || "").trim();
    const normalizedValue = String(payload[key] || "")
      .trim()
      .toLowerCase();
    if (normalizedKey && normalizedValue) {
      assignments[normalizedKey] = normalizedValue;
    }
  });
  return assignments;
}

function writeAssignmentOverrideDocument(path, document) {
  const assignments = {};
  Object.keys(document.assignments || {})
    .sort()
    .forEach((key) => {
      assignments[key] = document.assignments[key];
    });

  const payload =
    document.payload && typeof document.payload === "object" && !Array.isArray(document.payload)
      ? { ...document.payload, assignments }
      : { assignments };

  ensureDir(parentDirectory(path));
  writeText(path, JSON.stringify(payload, null, 2) + "\n");
}

function applyReminderIfNeeded(reminder, desired) {
  let changed = false;

  if (safeString(() => reminder.name()) !== desired.title) {
    reminder.name = desired.title;
    changed = true;
  }
  if (safeString(() => reminder.body()) !== desired.body) {
    reminder.body = desired.body;
    changed = true;
  }

  const currentDueDate = safeDate(() => reminder.dueDate());
  if (!desired.dueDate && currentDueDate) {
    return "recreate";
  }
  if (!sameDate(currentDueDate, desired.dueDate)) {
    reminder.dueDate = desired.dueDate;
    changed = true;
  }

  const currentRemindMeDate = safeDate(() => reminder.remindMeDate());
  // Reminders mirrors dueDate into remindMeDate, so keep dueDate as the baseline.
  const effectiveDesiredRemindMeDate = desired.remindMeDate || desired.dueDate || null;
  if (!effectiveDesiredRemindMeDate && currentRemindMeDate) {
    return "recreate";
  }

  if (
    effectiveDesiredRemindMeDate &&
    !sameDate(currentRemindMeDate, effectiveDesiredRemindMeDate)
  ) {
    reminder.remindMeDate = effectiveDesiredRemindMeDate;
    changed = true;
  }

  return changed ? "updated" : "unchanged";
}

function parseReminderDueDate(syncDue, text) {
  if (syncDue) {
    const parsed = new Date(syncDue);
    if (!Number.isNaN(parsed.getTime())) {
      return parsed;
    }
  }

  const koreanMatch = text.match(
    /(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일.*?(오전|오후)\s*(\d{1,2}):(\d{2})/
  );
  if (koreanMatch) {
    let hour = Number(koreanMatch[5]) % 12;
    if (koreanMatch[4] === "오후") {
      hour += 12;
    }
    return new Date(
      Number(koreanMatch[1]),
      Number(koreanMatch[2]) - 1,
      Number(koreanMatch[3]),
      hour,
      Number(koreanMatch[6]),
      0,
      0
    );
  }

  const dottedRangeMatch = text.match(
    /(\d{4})\.(\d{1,2})\.(\d{1,2})\s*~\s*(\d{4})\.(\d{1,2})\.(\d{1,2})/
  );
  if (dottedRangeMatch) {
    return new Date(
      Number(dottedRangeMatch[4]),
      Number(dottedRangeMatch[5]) - 1,
      Number(dottedRangeMatch[6]),
      23,
      59,
      0,
      0
    );
  }

  const dottedDateMatch = text.match(/(\d{4})\.(\d{1,2})\.(\d{1,2})/);
  if (dottedDateMatch) {
    return new Date(
      Number(dottedDateMatch[1]),
      Number(dottedDateMatch[2]) - 1,
      Number(dottedDateMatch[3]),
      23,
      59,
      0,
      0
    );
  }

  return null;
}

function buildReminderAlertDate(dueDate, options) {
  if (!(dueDate instanceof Date) || Number.isNaN(dueDate.getTime())) {
    return null;
  }

  if (!options || options.deviceAlertsEnabled === false) {
    return null;
  }

  const mode = String(options.deviceAlertMode || "adaptive").toLowerCase();
  if (mode === "off") {
    return null;
  }

  if (mode === "due") {
    return dueDate;
  }

  const now = Date.now();
  const remainingMs = dueDate.getTime() - now;
  if (remainingMs <= 0) {
    return null;
  }

  if (remainingMs > 24 * 3600 * 1000) {
    return new Date(dueDate.getTime() - 24 * 3600 * 1000);
  }
  if (remainingMs > 2 * 3600 * 1000) {
    return new Date(dueDate.getTime() - 2 * 3600 * 1000);
  }
  if (remainingMs > 15 * 60 * 1000) {
    return new Date(dueDate.getTime() - 15 * 60 * 1000);
  }
  return dueDate;
}

function buildStageAlertReminders(entry, identifier, title, dueDate) {
  const now = Date.now();
  return REMINDER_STAGE_ALERTS.flatMap((stage) => {
    const remindAtMs = dueDate.getTime() - stage.ms;
    if (remindAtMs <= now) {
      return [];
    }
    const remindAt = new Date(remindAtMs);

    const kindLabel = entry.category === "exam" ? "시험 일정 알림" : "과제 알림";
    const scheduleLabel = entry.category === "exam" ? "원래 일정" : "원래 마감";
    const lines = [];
    lines.push(`분류: ${kindLabel}`);
    lines.push(`알림 시점: ${stage.label}`);
    if (entry.course) {
      lines.push(`과목: ${entry.course}`);
    }
    if (entry.due) {
      lines.push(`${scheduleLabel}: ${entry.due}`);
    }
    if (entry.source_title) {
      lines.push(`출처: ${entry.source_title}`);
    }
    if (entry.instructions) {
      lines.push(`메모: ${entry.instructions}`);
    }
    lines.push(`링크: ${entry.url}`);
    lines.push(`${REMINDER_MARKER_PREFIX}alert:${stage.key}:${identifier}`);

    return [
      {
        identifier: `alert:${stage.key}:${identifier}`,
        title: `[${stage.label}] ${title}`,
        dueDate: remindAt,
        remindMeDate: remindAt,
        body: lines.join("\n"),
      },
    ];
  });
}

function syncItemBaseIdentifierFromUrl(url) {
  try {
    const parsedUrl = new URL(String(url));
    const id = parsedUrl.searchParams.get("id");
    return id || String(url);
  } catch (error) {
    return String(url);
  }
}

function normalizeWhitespace(text) {
  return String(text || "")
    .replace(/\u00a0/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function extractIdentifierFromText(text) {
  const lines = String(text || "").split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    for (let j = 0; j < REMINDER_MARKER_PREFIXES.length; j += 1) {
      if (lines[i].startsWith(REMINDER_MARKER_PREFIXES[j])) {
        return lines[i].slice(REMINDER_MARKER_PREFIXES[j].length);
      }
    }
  }
  return "";
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
