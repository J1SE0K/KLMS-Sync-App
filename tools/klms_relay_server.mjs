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
const MAX_SYNC_ITEMS = 2_000;

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

  expireStalePendingCommands();

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
    if (state.commands.some((item) => ["pending", "running"].includes(item.status))) {
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
  const id = String(raw.id || crypto.randomUUID());
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

function expireStalePendingCommands() {
  const now = Date.now();
  let changed = false;
  for (const command of state.commands) {
    if (command.status === "pending" && now - Date.parse(command.createdAt) > 60 * 60 * 1000) {
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
  const commands = db.prepare(`
    SELECT id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json
    FROM commands
    ORDER BY updated_at DESC
    LIMIT ?
  `).all(MAX_COMMANDS).map(rowToCommand);
  const latestCommand = parseJSON(getMeta("latestCommand"), null) || commands[0] || null;
  return {
    status: normalizeStatus(parseJSON(getMeta("status"), defaultStatus)),
    latestCommand,
    commands,
    running: getMeta("running") === "true",
    message: getMeta("message") || "서버 준비됨",
    updatedAt: getMeta("updatedAt") || new Date().toISOString(),
  };
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
