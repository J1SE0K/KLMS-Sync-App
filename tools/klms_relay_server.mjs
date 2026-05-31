#!/usr/bin/env node

import http from "node:http";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import { DatabaseSync } from "node:sqlite";
import os from "node:os";
import path from "node:path";

const HOST = process.env.KLMS_RELAY_HOST || "127.0.0.1";
const PORT = Number.parseInt(process.env.KLMS_RELAY_PORT || "18484", 10);
const TOKEN = (process.env.KLMS_RELAY_TOKEN || "").trim();
const DB_PATH = process.env.KLMS_RELAY_DB
  ? expandHome(process.env.KLMS_RELAY_DB)
  : path.join(os.homedir(), ".local", "state", "klms-sync-relay.sqlite");
const MAX_BODY_BYTES = 1024 * 1024;
const MAX_COMMANDS = 100;
const MAX_ITEM_ACTIONS = 200;
const MAX_SYNC_ITEMS = 2_000;
const STALE_PENDING_COMMAND_MS = 60 * 60 * 1000;
const STALE_RUNNING_COMMAND_MS = 2 * 60 * 1000;
const STALE_PENDING_ITEM_ACTION_MS = 60 * 60 * 1000;

if (!TOKEN) {
  console.error("KLMS_RELAY_TOKEN is required.");
  process.exit(64);
}
if (!Number.isInteger(PORT) || PORT <= 0 || PORT > 65535) {
  console.error("KLMS_RELAY_PORT must be a valid TCP port.");
  process.exit(64);
}

const defaultStatus = {
  assignments: 0,
  exams: 0,
  helpDesk: 0,
  notices: 0,
  noticeNew: 0,
  noticeUpdated: 0,
  noticeIgnored: 0,
  fileTotal: 0,
  newFiles: 0,
  quarantine: 0,
  filePruned: 0,
  fileArchivePruned: 0,
  calendarCreated: 0,
  calendarUpdated: 0,
  calendarDeleted: 0,
  phase: "idle",
  loginRequired: false,
  authDigits: null,
  authStatusMessage: null,
};

await fs.mkdir(path.dirname(DB_PATH), { recursive: true });
const db = new DatabaseSync(DB_PATH);
initDatabase();
let state = loadState();

const server = http.createServer(async (request, response) => {
  try {
    await route(request, response);
  } catch (error) {
    console.error(error);
    sendJSON(response, 500, { error: "server error" });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`KLMS relay server listening on http://${HOST}:${PORT}`);
  console.log(`Database: ${DB_PATH}`);
});

async function route(request, response) {
  const url = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);
  if (request.method === "GET" && url.pathname === "/healthz") {
    sendJSON(response, 200, { ok: true });
    return;
  }

  if (!url.pathname.startsWith("/v1/")) {
    sendJSON(response, 404, { error: "not found" });
    return;
  }
  if (!authorized(request)) {
    sendJSON(response, 401, { error: "unauthorized" });
    return;
  }

  expireStaleCommands();
  expireStalePendingItemActions();

  if (request.method === "GET" && url.pathname === "/v1/status") {
    sendJSON(response, 200, relayResponse());
    return;
  }

  if (request.method === "POST" && url.pathname === "/v1/status") {
    const body = await readJSON(request);
    state.status = normalizeStatus(body.status || body);
    state.running = Boolean(body.running);
    state.message = String(body.message || "");
    if (body.latestCommand) {
      const command = normalizeCommand(body.latestCommand, body.latestCommand.status || "running");
      upsertCommand(command);
      state.latestCommand = command;
    }
    state.updatedAt = new Date().toISOString();
    await saveState();
    sendJSON(response, 200, relayResponse());
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/sync-data") {
    const kind = (url.searchParams.get("kind") || "").trim();
    const limit = Math.max(1, Math.min(
      MAX_SYNC_ITEMS,
      Number.parseInt(url.searchParams.get("limit") || "250", 10) || 250
    ));
    sendJSON(response, 200, syncDataResponse({ kind, limit }));
    return;
  }

  if (request.method === "POST" && url.pathname === "/v1/sync-data") {
    const body = await readJSON(request);
    const items = Array.isArray(body.items) ? body.items.map(normalizeSyncItem).filter(Boolean) : [];
    replaceSyncItems(items, body.generatedAt);
    sendJSON(response, 200, syncDataResponse({ limit: MAX_SYNC_ITEMS }));
    return;
  }

  if (request.method === "POST" && url.pathname === "/v1/commands") {
    const body = await readJSON(request);
    const command = normalizeCommand(body, "pending");
    if (!command.kind) {
      sendJSON(response, 400, { error: "missing command kind" });
      return;
    }
    if (state.commands.some(commandBlocksNewRequest)) {
      sendJSON(response, 409, { error: "already running or pending" });
      return;
    }
    command.summary = normalizeStatus(command.summary || state.status, "pending");
    command.loginRequired = Boolean(command.loginRequired);
    upsertCommand(command);
    state.latestCommand = command;
    state.status = command.summary;
    state.running = false;
    state.message = `${displayCommandName(command.kind)} 요청 대기 중`;
    state.updatedAt = new Date().toISOString();
    await saveState();
    sendJSON(response, 201, command);
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/commands/pending") {
    sendJSON(response, 200, commandListResponse(
      state.commands
        .filter((command) => command.status === "pending")
        .sort((lhs, rhs) => Date.parse(lhs.createdAt) - Date.parse(rhs.createdAt))
    ));
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/commands/recent") {
    const limit = Math.max(1, Math.min(50, Number.parseInt(url.searchParams.get("limit") || "10", 10) || 10));
    sendJSON(response, 200, commandListResponse(
      state.commands
        .slice()
        .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))
        .slice(0, limit)
    ));
    return;
  }

  const commandMatch = url.pathname.match(/^\/v1\/commands\/([0-9a-fA-F-]+)$/);
  if (request.method === "PUT" && commandMatch) {
    const body = await readJSON(request);
    const command = normalizeCommand({ ...body, id: commandMatch[1] }, body.status || "pending");
    upsertCommand(command);
    state.latestCommand = command;
    state.status = normalizeStatus(command.summary || state.status, command.status);
    state.running = command.status === "running";
    state.message = `${displayCommandName(command.kind)} · ${displayStatus(command.status)}`;
    state.updatedAt = new Date().toISOString();
    await saveState();
    sendJSON(response, 200, command);
    return;
  }

  if (request.method === "POST" && url.pathname === "/v1/item-actions") {
    const body = await readJSON(request);
    const action = normalizeItemAction(body, "pending");
    if (!action.action || !action.itemID || !action.itemKind) {
      sendJSON(response, 400, { error: "missing item action target" });
      return;
    }
    upsertItemAction(action);
    state.message = `${displayItemActionName(action.action)} 요청 대기 중`;
    state.updatedAt = new Date().toISOString();
    await saveState();
    sendJSON(response, 201, action);
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/item-actions/pending") {
    sendJSON(response, 200, itemActionListResponse(
      state.itemActions
        .filter((action) => action.status === "pending")
        .sort((lhs, rhs) => Date.parse(lhs.createdAt) - Date.parse(rhs.createdAt))
    ));
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/item-actions/recent") {
    const limit = Math.max(1, Math.min(50, Number.parseInt(url.searchParams.get("limit") || "20", 10) || 20));
    sendJSON(response, 200, itemActionListResponse(
      state.itemActions
        .slice()
        .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))
        .slice(0, limit)
    ));
    return;
  }

  const itemActionMatch = url.pathname.match(/^\/v1\/item-actions\/([0-9a-fA-F-]+)$/);
  if (request.method === "PUT" && itemActionMatch) {
    const body = await readJSON(request);
    const action = normalizeItemAction({ ...body, id: itemActionMatch[1] }, body.status || "pending");
    upsertItemAction(action);
    state.message = `${displayItemActionName(action.action)} · ${displayStatus(action.status)}`;
    state.updatedAt = new Date().toISOString();
    await saveState();
    sendJSON(response, 200, action);
    return;
  }

  sendJSON(response, 404, { error: "not found" });
}

function commandListResponse(commands) {
  return {
    commands,
    status: normalizeStatus(state.status, state.running ? "running" : undefined),
    latestCommand: state.latestCommand || commands[0] || null,
    running: Boolean(state.running),
  };
}

function itemActionListResponse(actions) {
  return { actions };
}

function relayResponse() {
  return {
    ok: true,
    message: state.message || "",
    status: normalizeStatus(state.status, state.running ? "running" : undefined),
    latestCommand: state.latestCommand || null,
    running: Boolean(state.running),
    requestNonce: null,
    responseIssuedAtEpochSeconds: null,
    signature: null,
  };
}

function normalizeCommand(raw, fallbackStatus) {
  const now = new Date().toISOString();
  const id = String(raw.id || crypto.randomUUID()).toLowerCase();
  return {
    id,
    kind: String(raw.kind || ""),
    status: String(raw.status || fallbackStatus),
    createdAt: raw.createdAt || now,
    updatedAt: raw.updatedAt || now,
    lastExitCode: Number.isInteger(raw.lastExitCode) ? raw.lastExitCode : null,
    loginRequired: Boolean(raw.loginRequired),
    summary: normalizeStatus(raw.summary || defaultStatus, raw.status || fallbackStatus),
  };
}

function normalizeItemAction(raw, fallbackStatus) {
  const now = new Date().toISOString();
  const id = String(raw.id || crypto.randomUUID()).toLowerCase();
  return {
    id,
    action: String(raw.action || ""),
    itemID: String(raw.itemID || raw.itemId || ""),
    itemKind: String(raw.itemKind || ""),
    itemTitle: String(raw.itemTitle || ""),
    status: String(raw.status || fallbackStatus),
    createdAt: raw.createdAt || now,
    updatedAt: raw.updatedAt || now,
    message: String(raw.message || ""),
  };
}

function normalizeStatus(raw, fallbackPhase) {
  const status = { ...defaultStatus, ...(raw || {}) };
  for (const key of [
    "assignments",
    "exams",
    "helpDesk",
    "notices",
    "noticeNew",
    "noticeUpdated",
    "noticeIgnored",
    "fileTotal",
    "newFiles",
    "quarantine",
    "filePruned",
    "fileArchivePruned",
    "calendarCreated",
    "calendarUpdated",
    "calendarDeleted",
  ]) {
    status[key] = Number.isFinite(Number(status[key])) ? Number(status[key]) : 0;
  }
  status.phase = String(fallbackPhase || status.phase || "");
  status.loginRequired = Boolean(status.loginRequired);
  status.authDigits = status.authDigits == null ? null : String(status.authDigits);
  status.authStatusMessage = status.authStatusMessage == null ? null : String(status.authStatusMessage);
  return status;
}

function upsertCommand(command) {
  state.commands = state.commands.filter((item) => item.id !== command.id);
  state.commands.unshift(command);
  state.commands = state.commands
    .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))
    .slice(0, MAX_COMMANDS);
}

function upsertItemAction(action) {
  state.itemActions = state.itemActions.filter((item) => item.id !== action.id);
  state.itemActions.unshift(action);
  state.itemActions = state.itemActions
    .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))
    .slice(0, MAX_ITEM_ACTIONS);
}

function commandBlocksNewRequest(command) {
  if (command.status === "pending") {
    return true;
  }
  return command.status === "running" && state.running;
}

function expireStaleCommands() {
  const now = Date.now();
  let changed = false;
  for (const command of state.commands) {
    if (command.status === "pending" && ageMs(command.createdAt, now) > STALE_PENDING_COMMAND_MS) {
      command.status = "macUnavailable";
      command.updatedAt = new Date().toISOString();
      command.summary = normalizeStatus(command.summary || state.status, "macUnavailable");
      changed = true;
    } else if (command.status === "running" && !state.running && ageMs(command.updatedAt, now) > STALE_RUNNING_COMMAND_MS) {
      command.status = "macUnavailable";
      command.updatedAt = new Date().toISOString();
      command.summary = normalizeStatus(command.summary || state.status, "macUnavailable");
      changed = true;
    }
  }
  if (changed) {
    state.latestCommand = state.commands
      .slice()
      .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))[0] || null;
    try {
      saveState();
    } catch (error) {
      console.error(error);
    }
  }
}

function expireStalePendingItemActions() {
  const now = Date.now();
  let changed = false;
  for (const action of state.itemActions) {
    if (action.status === "pending" && ageMs(action.createdAt, now) > STALE_PENDING_ITEM_ACTION_MS) {
      action.status = "macUnavailable";
      action.updatedAt = new Date().toISOString();
      action.message = "Mac 앱이 제한 시간 안에 처리하지 않았습니다.";
      changed = true;
    }
  }
  if (changed) {
    try {
      saveState();
    } catch (error) {
      console.error(error);
    }
  }
}

function ageMs(timestamp, now) {
  const parsed = Date.parse(timestamp || "");
  if (!Number.isFinite(parsed)) {
    return Number.POSITIVE_INFINITY;
  }
  return now - parsed;
}

function authorized(request) {
  const header = request.headers.authorization || "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) {
    return false;
  }
  const expected = Buffer.from(TOKEN);
  const actual = Buffer.from(match[1].trim());
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
}

async function readJSON(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      throw new Error("request body too large");
    }
    chunks.push(chunk);
  }
  if (chunks.length === 0) {
    return {};
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function sendJSON(response, statusCode, value) {
  const body = JSON.stringify(value);
  response.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
  });
  response.end(body);
}

function initDatabase() {
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA foreign_keys = ON;
    CREATE TABLE IF NOT EXISTS meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS commands (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      last_exit_code INTEGER,
      login_required INTEGER NOT NULL DEFAULT 0,
      summary_json TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS commands_updated_at_idx
      ON commands(updated_at DESC);
    CREATE INDEX IF NOT EXISTS commands_status_created_at_idx
      ON commands(status, created_at ASC);
    CREATE TABLE IF NOT EXISTS item_actions (
      id TEXT PRIMARY KEY,
      action TEXT NOT NULL,
      item_id TEXT NOT NULL,
      item_kind TEXT NOT NULL,
      item_title TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      message TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX IF NOT EXISTS item_actions_status_created_at_idx
      ON item_actions(status, created_at ASC);
    CREATE INDEX IF NOT EXISTS item_actions_updated_at_idx
      ON item_actions(updated_at DESC);
    CREATE TABLE IF NOT EXISTS sync_items (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      course TEXT NOT NULL DEFAULT '',
      title TEXT NOT NULL DEFAULT '',
      timestamp TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT '',
      detail TEXT NOT NULL DEFAULT '',
      attachment_count INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL,
      payload_json TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS sync_items_kind_updated_at_idx
      ON sync_items(kind, updated_at DESC);
    CREATE INDEX IF NOT EXISTS sync_items_course_title_idx
      ON sync_items(course, title);
  `);
}

function loadState() {
  const commands = deduplicateByID(db.prepare(`
    SELECT id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json
    FROM commands
    ORDER BY updated_at DESC
    LIMIT ?
  `).all(MAX_COMMANDS * 2).map(rowToCommand), MAX_COMMANDS);
  const storedLatestCommand = parseJSON(getMeta("latestCommand"), null);
  const latestCommand = storedLatestCommand
    ? normalizeCommand(storedLatestCommand, storedLatestCommand.status || "pending")
    : commands[0] || null;
  const itemActions = deduplicateByID(db.prepare(`
    SELECT id, action, item_id, item_kind, item_title, status, created_at, updated_at, message
    FROM item_actions
    ORDER BY updated_at DESC
    LIMIT ?
  `).all(MAX_ITEM_ACTIONS * 2).map(rowToItemAction), MAX_ITEM_ACTIONS);
  return {
    status: normalizeStatus(parseJSON(getMeta("status"), defaultStatus)),
    latestCommand,
    commands,
    itemActions,
    running: getMeta("running") === "true",
    message: getMeta("message") || "서버 준비됨",
    updatedAt: getMeta("updatedAt") || new Date().toISOString(),
  };
}

function deduplicateByID(items, limit) {
  const seen = new Set();
  return items
    .slice()
    .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))
    .filter((item) => {
      const id = String(item.id || "").toLowerCase();
      if (!id || seen.has(id)) {
        return false;
      }
      item.id = id;
      seen.add(id);
      return true;
    })
    .slice(0, limit);
}

function saveState() {
  db.exec("BEGIN IMMEDIATE");
  try {
    setMeta("status", JSON.stringify(normalizeStatus(state.status || defaultStatus)));
    setMeta("latestCommand", JSON.stringify(state.latestCommand || null));
    setMeta("running", state.running ? "true" : "false");
    setMeta("message", String(state.message || ""));
    setMeta("updatedAt", String(state.updatedAt || new Date().toISOString()));
    db.prepare("DELETE FROM commands").run();
    const insertCommand = db.prepare(`
      INSERT INTO commands (
        id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `);
    for (const command of state.commands.slice(0, MAX_COMMANDS)) {
      insertCommand.run(
        command.id,
        command.kind,
        command.status,
        command.createdAt,
        command.updatedAt,
        Number.isInteger(command.lastExitCode) ? command.lastExitCode : null,
        command.loginRequired ? 1 : 0,
        JSON.stringify(normalizeStatus(command.summary || defaultStatus, command.status))
      );
    }
    db.prepare("DELETE FROM item_actions").run();
    const insertItemAction = db.prepare(`
      INSERT INTO item_actions (
        id, action, item_id, item_kind, item_title, status, created_at, updated_at, message
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    for (const action of state.itemActions.slice(0, MAX_ITEM_ACTIONS)) {
      insertItemAction.run(
        action.id,
        action.action,
        action.itemID,
        action.itemKind,
        action.itemTitle,
        action.status,
        action.createdAt,
        action.updatedAt,
        action.message
      );
    }
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

function getMeta(key) {
  const row = db.prepare("SELECT value FROM meta WHERE key = ?").get(key);
  return row?.value;
}

function setMeta(key, value) {
  db.prepare(`
    INSERT INTO meta(key, value)
    VALUES(?, ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value
  `).run(key, String(value));
}

function parseJSON(value, fallback) {
  if (typeof value !== "string" || value.trim().length === 0) {
    return fallback;
  }
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function rowToCommand(row) {
  return normalizeCommand({
    id: row.id,
    kind: row.kind,
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    lastExitCode: Number.isInteger(row.last_exit_code) ? row.last_exit_code : null,
    loginRequired: Boolean(row.login_required),
    summary: parseJSON(row.summary_json, defaultStatus),
  }, row.status || "pending");
}

function rowToItemAction(row) {
  return normalizeItemAction({
    id: row.id,
    action: row.action,
    itemID: row.item_id,
    itemKind: row.item_kind,
    itemTitle: row.item_title,
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    message: row.message,
  }, row.status || "pending");
}

function normalizeSyncItem(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  const kind = String(raw.kind || "").trim();
  if (!kind) {
    return null;
  }
  const id = String(raw.id || "").trim() || crypto.randomUUID();
  const now = new Date().toISOString();
  return {
    id,
    kind,
    course: String(raw.course || "").trim(),
    title: String(raw.title || "").trim(),
    timestamp: String(raw.timestamp || "").trim(),
    status: String(raw.status || "").trim(),
    detail: String(raw.detail || "").trim(),
    attachmentCount: Number.isFinite(Number(raw.attachmentCount)) ? Number(raw.attachmentCount) : 0,
    updatedAt: String(raw.updatedAt || now),
  };
}

function replaceSyncItems(items, generatedAt) {
  const now = new Date().toISOString();
  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare("DELETE FROM sync_items").run();
    const insertItem = db.prepare(`
      INSERT INTO sync_items (
        id, kind, course, title, timestamp, status, detail, attachment_count, updated_at, payload_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    for (const item of items.slice(0, MAX_SYNC_ITEMS)) {
      const normalized = {
        ...item,
        updatedAt: item.updatedAt || now,
      };
      insertItem.run(
        normalized.id,
        normalized.kind,
        normalized.course,
        normalized.title,
        normalized.timestamp,
        normalized.status,
        normalized.detail,
        normalized.attachmentCount,
        normalized.updatedAt,
        JSON.stringify(normalized)
      );
    }
    setMeta("syncDataGeneratedAt", String(generatedAt || now));
    setMeta("syncDataUpdatedAt", now);
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

function syncDataResponse({ kind = "", limit = 250 } = {}) {
  const trimmedKind = String(kind || "").trim();
  const rows = trimmedKind
    ? db.prepare(`
        SELECT payload_json
        FROM sync_items
        WHERE kind = ?
        ORDER BY updated_at DESC, timestamp DESC, course ASC, title ASC
        LIMIT ?
      `).all(trimmedKind, limit)
    : db.prepare(`
        SELECT payload_json
        FROM sync_items
        ORDER BY updated_at DESC, timestamp DESC, course ASC, title ASC
        LIMIT ?
      `).all(limit);
  return {
    generatedAt: getMeta("syncDataGeneratedAt") || "",
    updatedAt: getMeta("syncDataUpdatedAt") || "",
    items: rows.map((row) => parseJSON(row.payload_json, null)).filter(Boolean),
  };
}

function displayItemActionName(action) {
  switch (action) {
    case "assignmentComplete":
      return "과제 완료";
    case "assignmentRestore":
      return "과제 복구";
    case "assignmentHide":
      return "과제 숨김";
    case "assignmentUnhide":
      return "과제 숨김 해제";
    case "examPromote":
      return "시험 확정";
    case "examIgnore":
      return "시험 아님";
    case "examRestore":
      return "시험 복구";
    case "noticeRead":
      return "공지 읽음";
    case "noticeUnread":
      return "공지 읽지 않음";
    case "noticeImportant":
      return "공지 중요";
    case "noticeUnimportant":
      return "공지 중요 해제";
    case "noticeHide":
      return "공지 숨김";
    case "noticeUnhide":
      return "공지 숨김 해제";
    case "fileHide":
      return "파일 숨김";
    case "fileUnhide":
      return "파일 숨김 해제";
    default:
      return action || "항목 처리";
  }
}

function displayCommandName(kind) {
  switch (kind) {
    case "fullSync":
      return "전체 동기화";
    case "coreSync":
      return "과제/시험";
    case "noticeSync":
      return "공지 메모";
    case "filesSync":
      return "파일 동기화";
    case "doctor":
      return "권한/환경 진단";
    case "report":
      return "요약 갱신";
    default:
      return kind || "요청";
  }
}

function displayStatus(status) {
  switch (status) {
    case "pending":
      return "대기 중";
    case "running":
      return "실행 중";
    case "completed":
      return "완료";
    case "failed":
      return "실패";
    case "macUnavailable":
      return "Mac 응답 없음";
    default:
      return status || "상태 없음";
  }
}

function expandHome(value) {
  if (value === "~") {
    return os.homedir();
  }
  if (value.startsWith("~/")) {
    return path.join(os.homedir(), value.slice(2));
  }
  return value;
}
