const REMINDER_MARKER_PREFIX = "KLMS_SYNC_ITEM_ID:";
const LEGACY_REMINDER_MARKER_PREFIXES = ["KLMS_ASSIGN_ID:"];
const REMINDER_MARKER_PREFIXES = [REMINDER_MARKER_PREFIX].concat(LEGACY_REMINDER_MARKER_PREFIXES);
const REMINDER_LIST_APPEARANCE = {
  "KLMS 과제": { color: "#0F766E", emblem: "" },
  "KLMS 확인 필요": { color: "#C2410C", emblem: "" },
  "KLMS 알림": { color: "#0F766E", emblem: "" },
};
const REMINDER_STAGE_ALERTS = [
  { key: "1d", label: "1일 전", ms: 24 * 3600 * 1000 },
  { key: "2h", label: "2시간 전", ms: 2 * 3600 * 1000 },
];

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
