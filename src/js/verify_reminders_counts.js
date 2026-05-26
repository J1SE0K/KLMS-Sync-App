#!/usr/bin/osascript -l JavaScript

ObjC.import("stdlib");

const MARKER_PREFIXES = ["KLMS_SYNC_ITEM_ID:", "KLMS_ASSIGN_ID:"];

function parseArgs(argv) {
  const args = {
    assignmentList: "KLMS 과제",
  };
  const values = argv || [];
  for (let i = 0; i < values.length; i += 1) {
    const arg = String(values[i] || "");
    if (arg.startsWith("--assignment-list=")) {
      args.assignmentList = arg.slice("--assignment-list=".length);
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
  const list = findList(remindersApp, args.assignmentList);
  const lines = [];
  if (!list) {
    lines.push("reminders_assignment_list_exists=false");
    lines.push("reminders_assignment_active_count=0");
    lines.push("reminders_assignment_marker_count=0");
    return lines.join("\n");
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

  lines.push("reminders_assignment_list_exists=true");
  lines.push(`reminders_assignment_active_count=${activeCount}`);
  lines.push(`reminders_assignment_marker_count=${markerCount}`);
  return lines.join("\n");
}
