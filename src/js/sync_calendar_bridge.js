function syncCalendarsFromState(stateJsonPath, scriptDir, config, calendarOptions) {
  const durationMinutes = String(config.CALENDAR_EVENT_DURATION_MINUTES || "15");
  const lookbackDays = String(config.CALENDAR_LOOKBACK_DAYS || "365");
  const tmpDir = String((calendarOptions && calendarOptions.tmpDir) || `${scriptDir}/runtime/tmp/core`);
  const swiftModuleCacheDir = `${tmpDir}/swift-module-cache`;
  const clangModuleCacheDir = `${tmpDir}/clang-module-cache`;
  ensureDir(swiftModuleCacheDir);
  ensureDir(clangModuleCacheDir);
  const calendarBinary = String(config.KLMS_CALENDAR_BIN_PATH || "").trim();
  const command = calendarBinary
    ? [
        calendarBinary,
        stateJsonPath,
        `--duration-minutes=${durationMinutes}`,
        `--lookback-days=${lookbackDays}`,
      ]
    : [
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

  const output = runCommand(command, scriptDir);
  writeCalendarSyncResult(calendarOptions && calendarOptions.resultJson, output, "swift");
}

function runCalendarSyncStage(options) {
  if (options.status.status !== "ok" || !options.enabled) {
    return;
  }
  if (options.dryRun) {
    beginStage(options.steps, options.stageTelemetry, "calendar-sync-dry-run");
    debugStderr("dry-run skip calendar-sync");
    return;
  }
  if (
    options.skipUnchangedSideEffects &&
    options.status.changed === false
  ) {
    beginStage(options.steps, options.stageTelemetry, "calendar-sync-skipped");
    debugStderr("skip calendar-sync changed=false");
    return;
  }

  const desiredHash = buildCalendarDesiredHash(
    options.outputState,
    options.config,
    options.calendarOptions
  );
  const previousDesiredHash = fileExists(options.desiredHashPath)
    ? readText(options.desiredHashPath).trim()
    : "";
  if (
    options.skipUnchangedDesired &&
    previousDesiredHash &&
    previousDesiredHash === desiredHash
  ) {
    beginStage(
      options.steps,
      options.stageTelemetry,
      "calendar-sync-skipped-hash"
    );
    debugStderr("skip calendar-sync desired hash unchanged");
    return;
  }

  beginStage(options.steps, options.stageTelemetry, "calendar-sync");
  debugStderr("before calendar-sync");
  syncCalendarsFromState(
    options.outputState,
    options.scriptDir,
    options.config,
    options.calendarOptions
  );
  writeText(options.desiredHashPath, `${desiredHash}\n`);
  debugStderr("after calendar-sync");
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
