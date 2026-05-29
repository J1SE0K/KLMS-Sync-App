#!/usr/bin/osascript -l JavaScript

ObjC.import("stdlib");

const MARKER_PREFIXES = ["KLMS_SYNC_ITEM_ID:", "KLMS_ASSIGN_ID:"];

function parseArgs(argv) {
  const args = {
    assignmentList: "KLMS 과제",
    issueList: "KLMS 확인 필요",
    alertList: "KLMS 알림",
  };
  const values = argv || [];
  for (let i = 0; i < values.length; i += 1) {
    const arg = String(values[i] || "");
    if (arg.startsWith("--assignment-list=")) {
      args.assignmentList = arg.slice("--assignment-list=".length);
    } else if (arg.startsWith("--issue-list=")) {
      args.issueList = arg.slice("--issue-list=".length);
    } else if (arg.startsWith("--alert-list=")) {
      args.alertList = arg.slice("--alert-list=".length);
    }
  }
  return args;
}

function safeString(fn) {
  try {
    const value = fn();
    return value == null ? "" : String(value);
  } catch (_error) {
    return "";
  }
}

function safeBool(fn) {
  try {
    return Boolean(fn());
  } catch (_error) {
    return false;
  }
}

function extractIdentifier(text) {
  const lines = String(text || "").split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    for (let j = 0; j < MARKER_PREFIXES.length; j += 1) {
      if (lines[i].startsWith(MARKER_PREFIXES[j])) {
        return lines[i].slice(MARKER_PREFIXES[j].length);
      }
    }
  }
  return "";
}

function findList(remindersApp, name) {
  const allLists = remindersApp.lists() || [];
  const matches = [];
  for (let i = 0; i < allLists.length; i += 1) {
    if (safeString(() => allLists[i].name()) === name) {
      matches.push(allLists[i]);
    }
  }
  if (matches.length === 0) {
    return null;
  }
  if (matches.length > 1) {
    throw new Error(`Multiple Reminders lists found: ${name}`);
  }
  return matches[0];
}

function run(argv) {
  const args = parseArgs(argv);
  const remindersApp = Application("/System/Applications/Reminders.app");
  const lines = [];
  const assignment = countMarkedReminders(remindersApp, args.assignmentList);
  const issue = countMarkedReminders(remindersApp, args.issueList);
  const alert = countMarkedReminders(remindersApp, args.alertList);

  lines.push(`reminders_assignment_list_exists=${assignment.exists ? "true" : "false"}`);
  lines.push(`reminders_assignment_active_count=${assignment.activeCount}`);
  lines.push(`reminders_assignment_marker_count=${assignment.markerCount}`);
  lines.push(`reminders_issue_list_exists=${issue.exists ? "true" : "false"}`);
  lines.push(`reminders_issue_active_count=${issue.activeCount}`);
  lines.push(`reminders_issue_marker_count=${issue.markerCount}`);
  lines.push(`reminders_alert_list_exists=${alert.exists ? "true" : "false"}`);
  lines.push(`reminders_alert_active_count=${alert.activeCount}`);
  lines.push(`reminders_alert_marker_count=${alert.markerCount}`);
  lines.push(`reminders_total_active_count=${assignment.activeCount + issue.activeCount + alert.activeCount}`);
  lines.push(`reminders_total_marker_count=${assignment.markerCount + issue.markerCount + alert.markerCount}`);
  return lines.join("\n");
}

function countMarkedReminders(remindersApp, listName) {
  const list = findList(remindersApp, listName);
  if (!list) {
    return {
      exists: false,
      activeCount: 0,
      markerCount: 0,
    };
  }

  let activeCount = 0;
  let markerCount = 0;
  const reminders = list.reminders();
  for (let i = 0; i < reminders.length; i += 1) {
    const reminder = reminders[i];
    const identifier = extractIdentifier(safeString(() => reminder.body()));
    if (!identifier) {
      continue;
    }
    markerCount += 1;
    if (!safeBool(() => reminder.completed())) {
      activeCount += 1;
    }
  }

  return {
    exists: true,
    activeCount,
    markerCount,
  };
}
