#!/usr/bin/env node

import http from "node:http";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import { DatabaseSync } from "node:sqlite";
import os from "node:os";
import path from "node:path";

const HOST = process.env.KLMS_RELAY_HOST || "127.0.0.1";
const PORT = Number.parseInt(process.env.KLMS_RELAY_PORT || "18484", 10);
const CLIENT_TOKEN = (process.env.KLMS_RELAY_CLIENT_TOKEN || "").trim();
const WORKER_TOKEN = (process.env.KLMS_RELAY_WORKER_TOKEN || "").trim();
const DB_PATH = process.env.KLMS_RELAY_DB
  ? expandHome(process.env.KLMS_RELAY_DB)
  : path.join(os.homedir(), ".local", "state", "klms-sync-relay.sqlite");
const MAX_BODY_BYTES = 1024 * 1024;
const MAX_COMMANDS = 100;
const MAX_ITEM_ACTIONS = 200;
const MAX_SETTING_ACTIONS = 100;
const MAX_REQUEST_LOG_ENTRIES = 100;
const MAX_SYNC_ITEMS = 2_000;
const MAX_SYNC_EXTRAS = 200;
const MAX_FILE_ACCESS_REQUESTS = 100;
const DEFAULT_MAX_FILE_UPLOAD_BYTES = 25 * 1024 * 1024;
const DEFAULT_DAILY_FILE_UPLOADS = 20;
const DEFAULT_DAILY_FILE_UPLOAD_BYTES = 250 * 1024 * 1024;
const DEFAULT_DAILY_FILE_DOWNLOADS = 100;
const DEFAULT_FILE_DOWNLOADS_PER_LINK = 3;
const DEFAULT_FILE_PREVIEW_MAX_BYTES = 25 * 1024 * 1024;
const DEFAULT_TEXT_FILE_PREVIEW_MAX_BYTES = 512 * 1024;
const STALE_PENDING_COMMAND_MS = 60 * 60 * 1000;
const STALE_RUNNING_COMMAND_MS = 2 * 60 * 1000;
const STALE_PENDING_ITEM_ACTION_MS = 60 * 60 * 1000;
const STALE_PENDING_SETTING_ACTION_MS = 60 * 60 * 1000;
const STALE_PENDING_FILE_ACCESS_MS = 10 * 60 * 1000;
const CANCEL_REQUEST_TTL_MS = 10 * 60 * 1000;
const DEFAULT_FILE_ACCESS_TTL_MS = 5 * 60 * 1000;
const WORKER_INBOX_LONG_POLL_MAX_MS = 25 * 1000;
const WORKER_INBOX_LONG_POLL_INTERVAL_MS = 250;
const FILE_DIR = process.env.KLMS_RELAY_FILE_DIR
  ? expandHome(process.env.KLMS_RELAY_FILE_DIR)
  : path.join(path.dirname(DB_PATH), "files");

if (!CLIENT_TOKEN || !WORKER_TOKEN) {
  console.error("KLMS_RELAY_CLIENT_TOKEN and KLMS_RELAY_WORKER_TOKEN are required.");
  process.exit(64);
}
if (CLIENT_TOKEN === WORKER_TOKEN) {
  console.error("KLMS_RELAY_CLIENT_TOKEN and KLMS_RELAY_WORKER_TOKEN must be different.");
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
await fs.mkdir(FILE_DIR, { recursive: true });
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

  if (request.method === "GET" && url.pathname === "/v1/events/poll") {
    const role = sanitizeRealtimeRole(url.searchParams.get("role"));
    if (!authorized(request, role === "worker" ? "worker" : "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    sendJSON(response, 200, await waitForRelayEventChange(url.searchParams));
    return;
  }

  expireStaleCommands();
  expireStalePendingItemActions();
  expireStalePendingSettingActions();
  expireStaleFileAccessRequests();
  await cleanupExpiredFileAccess();

  const fileDownloadMatch = url.pathname.match(/^\/v1\/file-access\/([0-9a-fA-F-]+)\/download$/);
  if (request.method === "GET" && fileDownloadMatch) {
    await downloadFileAccess(response, url, fileDownloadMatch[1]);
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/worker/inbox") {
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    await waitForWorkerInboxChange(url.searchParams);
    sendJSON(response, 200, workerInboxResponse(request));
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/status") {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
    sendJSON(response, 200, relayResponse());
    return;
  }

  if (request.method === "POST" && url.pathname === "/v1/status") {
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
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
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
    const kind = (url.searchParams.get("kind") || "").trim();
    const limit = Math.max(1, Math.min(
      MAX_SYNC_ITEMS,
      Number.parseInt(url.searchParams.get("limit") || "250", 10) || 250
    ));
    sendJSON(response, 200, syncDataResponse({ kind, limit }));
    return;
  }

  if (request.method === "POST" && url.pathname === "/v1/sync-data") {
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
    const body = await readJSON(request);
    const items = Array.isArray(body.items) ? body.items.map(normalizeSyncItem).filter(Boolean) : [];
    replaceSyncItems(items, body.generatedAt, {
      dryRunReports: normalizeDryRunReports(body.dryRunReports),
      calendarChanges: normalizeCalendarChanges(body.calendarChanges),
      settings: normalizeSettings(body.settings),
    });
    touchRelayEvent("sync-data");
    sendJSON(response, 200, syncDataResponse({ limit: MAX_SYNC_ITEMS }));
    return;
  }

  if (request.method === "POST" && url.pathname === "/v1/cancel") {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    const body = await readJSON(request);
    const cancelRequest = normalizeCancelRequest({
      requested: true,
      requestedAt: body.requestedAt || new Date().toISOString(),
      commandID: body.commandID || body.commandId || body.command_id,
      message: body.message || "사용자가 실행 중단을 요청했습니다.",
    });
    if (!cancelRequest.commandID) {
      sendJSON(response, 400, { error: "missing command id" });
      return;
    }
    const pendingCancel = await cancelPendingCommandIfNeeded(cancelRequest, request);
    if (pendingCancel) {
      sendJSON(response, 200, pendingCancel);
      return;
    }
    setMeta("cancelRequest", JSON.stringify(cancelRequest));
    appendRequestLog(request, {
      action: "동기화 중단 요청",
      status: "accepted",
      message: cancelRequest.message,
    });
    state.message = "실행 중단 요청 대기 중";
    state.updatedAt = new Date().toISOString();
    await saveState();
    sendJSON(response, 202, cancelRequest);
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/cancel") {
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    sendJSON(response, 200, loadCancelRequest());
    return;
  }

  if (request.method === "DELETE" && url.pathname === "/v1/cancel") {
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    clearCancelRequest();
    sendJSON(response, 200, normalizeCancelRequest({ requested: false }));
    return;
  }

  if (request.method === "POST" && url.pathname === "/v1/commands") {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
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
    appendRequestLog(request, {
      action: `${displayCommandName(command.kind)} 요청`,
      status: "queued",
      message: "원격 실행 요청을 서버에 기록했습니다.",
    });
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
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
    sendJSON(response, 200, commandListResponse(
      state.commands
        .filter((command) => command.status === "pending")
        .sort((lhs, rhs) => Date.parse(lhs.createdAt) - Date.parse(rhs.createdAt))
    ));
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/commands/recent") {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
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
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
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
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
    const body = await readJSON(request);
    const action = normalizeItemAction(body, "pending");
    if (!action.action || !action.itemID || !action.itemKind) {
      sendJSON(response, 400, { error: "missing item action target" });
      return;
    }
    upsertItemAction(action);
    appendRequestLog(request, {
      action: displayItemActionName(action.action),
      status: "queued",
      message: action.itemTitle || action.itemID,
    });
    state.message = `${displayItemActionName(action.action)} 요청 대기 중`;
    state.updatedAt = new Date().toISOString();
    await saveState();
    sendJSON(response, 201, action);
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/item-actions/pending") {
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
    sendJSON(response, 200, itemActionListResponse(
      state.itemActions
        .filter((action) => action.status === "pending")
        .sort((lhs, rhs) => Date.parse(lhs.createdAt) - Date.parse(rhs.createdAt))
    ));
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/item-actions/recent") {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
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
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
    const body = await readJSON(request);
    const action = normalizeItemAction({ ...body, id: itemActionMatch[1] }, body.status || "pending");
    upsertItemAction(action);
    state.message = `${displayItemActionName(action.action)} · ${displayStatus(action.status)}`;
    state.updatedAt = new Date().toISOString();
    await saveState();
    sendJSON(response, 200, action);
    return;
  }

  if (request.method === "POST" && url.pathname === "/v1/setting-actions") {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
    expireStalePendingSettingActions();
    const body = await readJSON(request);
    const action = normalizeSettingAction(body, "pending");
    if (!action.key) {
      sendJSON(response, 400, { error: "missing setting key" });
      return;
    }
    upsertSettingAction(action);
    appendRequestLog(request, {
      action: `${action.title || action.key} 설정 변경`,
      status: "queued",
      message: "설정 변경 요청을 서버에 기록했습니다.",
    });
    state.message = `${action.title || action.key} 설정 변경 요청 대기 중`;
    state.updatedAt = new Date().toISOString();
    await saveState();
    sendJSON(response, 201, action);
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/setting-actions/pending") {
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
    expireStalePendingSettingActions();
    sendJSON(response, 200, settingActionListResponse(
      state.settingActions
        .filter((action) => action.status === "pending")
        .sort((lhs, rhs) => Date.parse(lhs.createdAt) - Date.parse(rhs.createdAt))
    ));
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/setting-actions/recent") {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
    expireStalePendingSettingActions();
    const limit = Math.max(1, Math.min(50, Number.parseInt(url.searchParams.get("limit") || "20", 10) || 20));
    sendJSON(response, 200, settingActionListResponse(
      state.settingActions
        .slice()
        .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))
        .slice(0, limit)
    ));
    return;
  }

  const settingActionMatch = url.pathname.match(/^\/v1\/setting-actions\/([0-9a-fA-F-]+)$/);
  if (request.method === "PUT" && settingActionMatch) {
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
    expireStalePendingSettingActions();
    const body = await readJSON(request);
    const action = normalizeSettingAction({ ...body, id: settingActionMatch[1] }, body.status || "pending");
    upsertSettingAction(action);
    state.message = `${action.title || action.key} · ${displayStatus(action.status)}`;
    state.updatedAt = new Date().toISOString();
    await saveState();
    sendJSON(response, 200, action);
    return;
  }

  if (request.method === "POST" && url.pathname === "/v1/file-access") {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    const body = await readJSON(request);
    const fileRequest = normalizeFileAccessRequest(body, "pending");
    if (!fileRequest.itemID || fileRequest.itemKind !== "file") {
      sendJSON(response, 400, { error: "missing file target" });
      return;
    }
    const pendingRequests = loadFileAccessRequests({
      statuses: ["pending", "running"],
      order: "created",
      limit: MAX_FILE_ACCESS_REQUESTS,
    });
    if (pendingRequests.length >= fileAccessLimits().maxPendingRequests) {
      sendJSON(response, 429, { error: "file access queue limit reached" });
      return;
    }
    upsertFileAccessRequest(fileRequest);
    appendRequestLog(request, {
      action: "파일 열기 요청",
      status: "queued",
      message: fileRequest.itemTitle || fileRequest.itemID,
    });
    state.message = `파일 열기 요청 대기 중: ${fileRequest.itemTitle || fileRequest.itemID}`;
    state.updatedAt = new Date().toISOString();
    await saveState();
    sendJSON(response, 201, fileAccessResponseItem(fileRequest, request));
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/file-access/pending") {
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    const limit = boundedInt(url.searchParams.get("limit"), 20, 1, MAX_FILE_ACCESS_REQUESTS);
    sendJSON(response, 200, fileAccessListResponse(loadFileAccessRequests({
      statuses: ["pending"],
      order: "created",
      limit,
    }), request));
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/file-access/recent") {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    const limit = boundedInt(url.searchParams.get("limit"), 20, 1, MAX_FILE_ACCESS_REQUESTS);
    sendJSON(response, 200, fileAccessListResponse(loadFileAccessRequests({ limit }), request));
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/request-log/recent") {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    const limit = boundedInt(url.searchParams.get("limit"), 20, 1, MAX_REQUEST_LOG_ENTRIES);
    sendJSON(response, 200, requestLogResponse(limit));
    return;
  }

  if (request.method === "DELETE" && url.pathname === "/v1/logs") {
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    const scope = normalizeLogClearScope(url.searchParams.get("scope"));
    if (scope === "fileAccess" && hasActiveFileAccessWork()) {
      sendJSON(response, 409, { error: "active file access request is still running" });
      return;
    }
    sendJSON(response, 200, await clearRelayLogs(scope));
    return;
  }

  const fileAccessMatch = url.pathname.match(/^\/v1\/file-access\/([0-9a-fA-F-]+)$/);
  if (request.method === "PUT" && fileAccessMatch) {
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    const body = await readJSON(request);
    const current = getFileAccessRequest(fileAccessMatch[1]);
    if (!current) {
      sendJSON(response, 404, { error: "file request not found" });
      return;
    }
    const fileRequest = normalizeFileAccessRequest({
      ...current,
      ...body,
      id: fileAccessMatch[1],
      itemID: body.itemID || body.itemId || current.itemID,
      itemKind: body.itemKind || current.itemKind,
      itemTitle: body.itemTitle || current.itemTitle,
    }, body.status || current.status || "pending");
    upsertFileAccessRequest(fileRequest);
    touchRelayEvent(`file-access:${fileRequest.status}`, fileRequest.updatedAt);
    sendJSON(response, 200, fileAccessResponseItem(fileRequest, request));
    return;
  }

  const fileUploadMatch = url.pathname.match(/^\/v1\/file-access\/([0-9a-fA-F-]+)\/upload$/);
  if (request.method === "PUT" && fileUploadMatch) {
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    await uploadFileAccess(response, request, fileUploadMatch[1]);
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

function settingActionListResponse(actions) {
  return { actions };
}

function fileAccessListResponse(requests, request) {
  return {
    requests: requests.map((fileRequest) => fileAccessResponseItem(fileRequest, request)),
  };
}

function workerInboxResponse(request) {
  return {
    statusResponse: relayResponse(),
    recentRequestLog: requestLogResponse(20).entries,
    recentFileAccessRequests: fileAccessListResponse(
      loadFileAccessRequests({ limit: 8 }),
      request
    ).requests,
    pendingFileAccessRequests: fileAccessListResponse(
      loadFileAccessRequests({
        statuses: ["pending"],
        order: "created",
        limit: 20,
      }),
      request
    ).requests,
    pendingSettingActions: (state.settingActions || [])
      .filter((action) => action.status === "pending")
      .sort((lhs, rhs) => Date.parse(lhs.createdAt) - Date.parse(rhs.createdAt)),
    pendingItemActions: state.itemActions
      .filter((action) => action.status === "pending")
      .sort((lhs, rhs) => Date.parse(lhs.createdAt) - Date.parse(rhs.createdAt)),
    pendingCommands: state.commands
      .filter((command) => command.status === "pending")
      .sort((lhs, rhs) => Date.parse(lhs.createdAt) - Date.parse(rhs.createdAt)),
    cancelRequest: loadCancelRequest(),
  };
}

async function waitForWorkerInboxChange(searchParams) {
  const since = String(searchParams.get("since") || "").trim();
  const sinceEpoch = Date.parse(since);
  const waitSeconds = boundedInt(searchParams.get("waitSeconds"), 0, 0, 25);
  const waitMs = boundedInt(
    searchParams.get("waitMs"),
    waitSeconds * 1000,
    0,
    WORKER_INBOX_LONG_POLL_MAX_MS
  );
  if (waitMs <= 0 || !Number.isFinite(sinceEpoch)) {
    return;
  }
  if (Date.parse(state.updatedAt || "") > sinceEpoch || hasWorkerInboxWork()) {
    return;
  }

  const deadline = Date.now() + waitMs;
  while (Date.now() < deadline) {
    await sleep(Math.min(WORKER_INBOX_LONG_POLL_INTERVAL_MS, Math.max(25, deadline - Date.now())));
    expireStaleCommands();
    expireStalePendingItemActions();
    if (Date.parse(state.updatedAt || "") > sinceEpoch || hasWorkerInboxWork()) {
      return;
    }
  }
}

async function waitForRelayEventChange(searchParams) {
  const since = String(searchParams.get("since") || "").trim();
  const sinceEpoch = Date.parse(since);
  const waitSeconds = boundedInt(searchParams.get("waitSeconds"), 0, 0, 25);
  const waitMs = boundedInt(
    searchParams.get("waitMs"),
    waitSeconds * 1000,
    0,
    WORKER_INBOX_LONG_POLL_MAX_MS
  );
  let current = relayEventSnapshot();
  if (waitMs <= 0 || !Number.isFinite(sinceEpoch) || Date.parse(current.updatedAt || "") > sinceEpoch) {
    return current;
  }

  const deadline = Date.now() + waitMs;
  while (Date.now() < deadline) {
    await sleep(Math.min(WORKER_INBOX_LONG_POLL_INTERVAL_MS, Math.max(25, deadline - Date.now())));
    expireStaleCommands();
    expireStalePendingItemActions();
    expireStalePendingSettingActions();
    expireStaleFileAccessRequests();
    current = relayEventSnapshot();
    if (Date.parse(current.updatedAt || "") > sinceEpoch) {
      return current;
    }
  }
  return current;
}

function relayEventSnapshot() {
  return {
    type: "changed",
    reason: sanitizePublicText(getMeta("relayEventReason")) || "state",
    updatedAt: newestTimestamp([
      getMeta("relayEventUpdatedAt"),
      getMeta("updatedAt"),
      getMeta("syncDataUpdatedAt"),
    ]) || new Date().toISOString(),
  };
}

function newestTimestamp(values) {
  let newest = "";
  let newestEpoch = Number.NEGATIVE_INFINITY;
  for (const value of values) {
    const text = String(value || "").trim();
    const epoch = Date.parse(text);
    if (Number.isFinite(epoch) && epoch > newestEpoch) {
      newest = text;
      newestEpoch = epoch;
    }
  }
  return newest;
}

function hasWorkerInboxWork() {
  if (state.commands.some((command) => command.status === "pending")) {
    return true;
  }
  if (state.itemActions.some((action) => action.status === "pending")) {
    return true;
  }
  if ((state.settingActions || []).some((action) => action.status === "pending")) {
    return true;
  }
  if (loadCancelRequest().requested) {
    return true;
  }
  return loadFileAccessRequests({
    statuses: ["pending"],
    order: "created",
    limit: 1,
  }).length > 0;
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function sanitizeRealtimeRole(value) {
  return String(value || "").trim().toLowerCase() === "worker" ? "worker" : "client";
}

function requestLogResponse(limit = 20) {
  return {
    entries: loadRequestLog().slice(0, Math.max(1, Math.min(MAX_REQUEST_LOG_ENTRIES, limit))),
  };
}

function fileAccessResponseItem(fileRequest, request) {
  const response = {
    id: fileRequest.id,
    itemID: fileRequest.itemID,
    itemKind: fileRequest.itemKind,
    itemTitle: fileRequest.itemTitle,
    status: fileRequest.status,
    createdAt: fileRequest.createdAt,
    updatedAt: fileRequest.updatedAt,
    message: fileRequest.message,
    downloadURL: null,
    expiresAt: fileRequest.expiresAt || null,
    sizeBytes: Number.isFinite(Number(fileRequest.sizeBytes)) ? Number(fileRequest.sizeBytes) : null,
    downloadCount: Number.isFinite(Number(fileRequest.downloadCount)) ? Number(fileRequest.downloadCount) : 0,
  };
  if (
    fileRequest.status === "completed"
    && fileRequest.downloadTicket
    && fileRequest.expiresAt
    && Date.parse(fileRequest.expiresAt) > Date.now()
  ) {
    response.downloadURL = downloadURLFor(fileRequest, request);
  }
  return response;
}

function relayResponse() {
  return {
    ok: true,
    message: state.message || "",
    status: normalizeStatus(state.status, state.running ? "running" : undefined),
    latestCommand: state.latestCommand || null,
    running: Boolean(state.running),
    updatedAt: state.updatedAt || null,
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
    options: normalizeCommandOptions(raw.options || raw.options_json),
  };
}

function normalizeCommandOptions(raw) {
  const parsed = typeof raw === "string" ? parseJSON(raw, {}) : raw || {};
  return {
    updateNoticeNotes: parsed.updateNoticeNotes !== false && parsed.update_notice_notes !== false,
    dryRun: normalizeBoolean(parsed.dryRun ?? parsed.dry_run),
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

function normalizeSettingAction(raw, fallbackStatus) {
  const now = new Date().toISOString();
  const id = String(raw.id || crypto.randomUUID()).toLowerCase();
  return {
    id,
    key: sanitizeSettingKey(raw.key),
    value: sanitizePublicText(raw.value),
    title: sanitizePublicText(raw.title),
    status: String(raw.status || fallbackStatus),
    createdAt: raw.createdAt || raw.created_at || now,
    updatedAt: raw.updatedAt || raw.updated_at || now,
    message: sanitizePublicText(raw.message),
  };
}

function normalizeFileAccessRequest(raw, fallbackStatus) {
  const now = new Date().toISOString();
  const id = String(raw.id || crypto.randomUUID()).toLowerCase();
  return {
    id,
    itemID: String(raw.itemID || raw.itemId || "").trim(),
    itemKind: String(raw.itemKind || "file").trim(),
    itemTitle: sanitizePublicText(raw.itemTitle),
    status: String(raw.status || fallbackStatus),
    createdAt: raw.createdAt || raw.created_at || now,
    updatedAt: raw.updatedAt || raw.updated_at || now,
    message: sanitizePublicText(raw.message),
    objectKey: raw.objectKey || raw.object_key || null,
    downloadTicket: raw.downloadTicket || raw.download_ticket || null,
    expiresAt: raw.expiresAt || raw.expires_at || null,
    contentType: raw.contentType || raw.content_type || null,
    sizeBytes: Number.isFinite(Number(raw.sizeBytes ?? raw.size_bytes))
      ? Number(raw.sizeBytes ?? raw.size_bytes)
      : null,
    downloadCount: Number.isFinite(Number(raw.downloadCount ?? raw.download_count))
      ? Number(raw.downloadCount ?? raw.download_count)
      : 0,
  };
}

function normalizeCancelRequest(raw) {
  const requestedAt = raw?.requestedAt || raw?.requested_at || null;
  const commandID = normalizeUUIDText(raw?.commandID || raw?.commandId || raw?.command_id);
  const requested = Boolean(commandID) && normalizeBoolean(raw?.requested) && (
    !requestedAt || ageMs(requestedAt, Date.now()) <= CANCEL_REQUEST_TTL_MS
  );
  return {
    requested,
    requestedAt: requested ? requestedAt || new Date().toISOString() : null,
    commandID: requested ? commandID : null,
    message: sanitizePublicText(raw?.message),
  };
}

function appendRequestLog(request, raw) {
  const entry = normalizeRequestLogEntry(request, raw);
  const entries = [entry, ...loadRequestLog().filter((item) => item.id !== entry.id)]
    .sort((lhs, rhs) => Date.parse(rhs.createdAt) - Date.parse(lhs.createdAt))
    .slice(0, MAX_REQUEST_LOG_ENTRIES);
  setMeta("requestLog", JSON.stringify(entries));
}

function loadRequestLog() {
  const raw = parseJSON(getMeta("requestLog"), []);
  return (Array.isArray(raw) ? raw : [])
    .map((item) => normalizeRequestLogEntry(null, item))
    .sort((lhs, rhs) => Date.parse(rhs.createdAt) - Date.parse(lhs.createdAt))
    .slice(0, MAX_REQUEST_LOG_ENTRIES);
}

function hasActiveRelayWork() {
  if (state.running) {
    return true;
  }
  if (state.commands.some((command) => command.status === "pending" || command.status === "running")) {
    return true;
  }
  if (state.itemActions.some((action) => action.status === "pending" || action.status === "running")) {
    return true;
  }
  if ((state.settingActions || []).some((action) => action.status === "pending" || action.status === "running")) {
    return true;
  }
  return hasActiveFileAccessWork();
}

function hasActiveFileAccessWork() {
  return loadFileAccessRequests({
    statuses: ["pending", "running"],
    order: "created",
    limit: 1,
  }).length > 0;
}

function normalizeLogClearScope(value) {
  const text = String(value || "").trim().toLowerCase();
  if (["requestlog", "request-log", "request", "server", "serverrequest", "server-request"].includes(text)) {
    return "requestLog";
  }
  if (["command", "commands", "run", "runs", "recent", "recentcommand", "recent-command", "recentcommands", "recent-commands"].includes(text)) {
    return "command";
  }
  if (["fileaccess", "file-access", "file", "files"].includes(text)) {
    return "fileAccess";
  }
  return "all";
}

async function clearRelayLogs(scope = "all") {
  const clearedAt = new Date().toISOString();
  const shouldClearAll = scope === "all";
  const shouldClearCommands = shouldClearAll || scope === "command";
  const shouldClearRequestLog = shouldClearAll || scope === "requestLog";
  const shouldClearFileAccess = shouldClearAll || scope === "fileAccess";
  const fileAccessRows = shouldClearFileAccess
    ? loadFileAccessRequests({ limit: MAX_FILE_ACCESS_REQUESTS })
    : [];
  const fileAccessRowsToClear = shouldClearAll
    ? fileAccessRows.filter((request) => request.status !== "pending" && request.status !== "running")
    : fileAccessRows;
  const requestLog = shouldClearRequestLog ? loadRequestLog() : [];
  for (const fileRequest of fileAccessRowsToClear) {
    if (!fileRequest.objectKey) {
      continue;
    }
    try {
      await fs.unlink(localFileObjectPath(fileRequest.objectKey));
    } catch (error) {
      if (error?.code !== "ENOENT") {
        console.error("failed to delete file access object while clearing logs", error);
      }
    }
  }

  const result = {
    clearedAt,
    commands: shouldClearCommands
      ? state.commands.filter((command) => command.status !== "pending" && command.status !== "running").length
      : 0,
    itemActions: shouldClearAll
      ? state.itemActions.filter((action) => action.status !== "pending" && action.status !== "running").length
      : 0,
    settingActions: shouldClearAll
      ? (state.settingActions || []).filter((action) => action.status !== "pending" && action.status !== "running").length
      : 0,
    fileAccessRequests: fileAccessRowsToClear.length,
    requestLogEntries: requestLog.length,
  };

  db.exec("BEGIN IMMEDIATE");
  try {
    if (shouldClearCommands) {
      db.prepare("DELETE FROM commands WHERE status NOT IN ('pending', 'running')").run();
    }
    if (shouldClearAll) {
      db.prepare("DELETE FROM item_actions WHERE status NOT IN ('pending', 'running')").run();
      setMeta(
        "settingActions",
        JSON.stringify((state.settingActions || []).filter((action) => action.status === "pending" || action.status === "running"))
      );
    }
    if (shouldClearFileAccess) {
      if (shouldClearAll) {
        db.prepare("DELETE FROM file_access_requests WHERE status NOT IN ('pending', 'running')").run();
      } else {
        db.prepare("DELETE FROM file_access_requests").run();
      }
    }
    if (shouldClearRequestLog) {
      setMeta("requestLog", "[]");
    }
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }

  if (shouldClearCommands) {
    state.commands = state.commands.filter((command) => command.status === "pending" || command.status === "running");
    state.latestCommand = state.commands[0] || null;
    state.running = state.commands.some((command) => command.status === "running") || state.running && Boolean(state.latestCommand);
  }
  if (shouldClearAll) {
    state.itemActions = state.itemActions.filter((action) => action.status === "pending" || action.status === "running");
    state.settingActions = (state.settingActions || []).filter((action) => action.status === "pending" || action.status === "running");
    state.message = "로그를 지웠습니다.";
    state.updatedAt = clearedAt;
    await saveState();
  } else if (shouldClearCommands) {
    state.message = "최근 실행 요청 기록을 지웠습니다.";
    state.updatedAt = clearedAt;
    await saveState();
  } else {
    touchRelayEvent(`logs:${scope}`, clearedAt);
  }
  return result;
}

function normalizeRequestLogEntry(request, raw = {}) {
  const url = request
    ? new URL(request.url || "/", `http://${request.headers.host || "localhost"}`)
    : null;
  return {
    id: normalizeUUIDText(raw.id) || crypto.randomUUID(),
    source: sanitizeRequestSource(raw.source || requestSource(request)),
    action: sanitizePublicText(raw.action),
    method: sanitizePublicText(raw.method || request?.method || ""),
    path: sanitizeRequestPath(raw.path || url?.pathname || ""),
    status: sanitizePublicText(raw.status || "ok"),
    message: sanitizePublicText(raw.message),
    createdAt: raw.createdAt || raw.created_at || new Date().toISOString(),
  };
}

function requestSource(request) {
  if (!request) {
    return "";
  }
  const headerSource = request.headers["x-klms-client"];
  if (headerSource) {
    return headerSource;
  }
  const userAgent = String(request.headers["user-agent"] || "");
  if (/iphone|ipad|ios/i.test(userAgent)) {
    return "iPhone";
  }
  if (/windows|electron/i.test(userAgent)) {
    return "Windows";
  }
  if (/macintosh|darwin|mac os/i.test(userAgent)) {
    return "Mac";
  }
  return "알 수 없음";
}

function sanitizeRequestSource(value) {
  const text = String(value || "").trim().toLowerCase();
  if (text.includes("iphone") || text.includes("ios") || text.includes("ipad")) {
    return "iPhone";
  }
  if (text.includes("windows")) {
    return "Windows";
  }
  if (text.includes("mac")) {
    return "Mac";
  }
  if (text.includes("web") || text.includes("browser") || text.includes("웹")) {
    return "웹";
  }
  return sanitizePublicText(value) || "알 수 없음";
}

function sanitizeRequestPath(value) {
  const pathText = sanitizePublicText(value).split("?")[0];
  return pathText.replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, ":id");
}

function normalizeUUIDText(value) {
  const text = String(value || "").trim().toLowerCase();
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(text)
    ? text
    : "";
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

function upsertSettingAction(action) {
  state.settingActions = (state.settingActions || []).filter((item) => item.id !== action.id);
  state.settingActions.unshift(action);
  state.settingActions = state.settingActions
    .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))
    .slice(0, MAX_SETTING_ACTIONS);
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

function markCommandCancelled(command, message) {
  const summary = normalizeStatus(command.summary || state.status, "cancelled");
  summary.phaseDetail = message || "사용자가 실행 전에 요청을 취소했습니다.";
  summary.loginRequired = false;
  summary.authDigits = null;
  summary.authStatusMessage = null;
  return {
    ...command,
    status: "cancelled",
    updatedAt: new Date().toISOString(),
    lastExitCode: null,
    loginRequired: false,
    summary,
  };
}

async function cancelPendingCommandIfNeeded(cancelRequest, request) {
  const command = state.commands.find((item) => item.id === cancelRequest.commandID);
  if (!command || command.status !== "pending") {
    return null;
  }
  const message = "Mac이 처리하기 전에 원격 실행 요청을 취소했습니다.";
  const cancelled = markCommandCancelled(command, message);
  upsertCommand(cancelled);
  clearCancelRequest();
  appendRequestLog(request, {
    action: "원격 실행 요청 취소",
    status: "cancelled",
    message,
  });
  state.latestCommand = cancelled;
  state.status = cancelled.summary;
  state.running = false;
  state.message = `${displayCommandName(cancelled.kind)} · ${displayStatus(cancelled.status)}`;
  state.updatedAt = cancelled.updatedAt;
  await saveState();
  return normalizeCancelRequest({
    requested: false,
    requestedAt: cancelRequest.requestedAt,
    commandID: cancelRequest.commandID,
    message,
  });
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

function expireStalePendingSettingActions() {
  const now = Date.now();
  let changed = false;
  for (const action of state.settingActions || []) {
    if (action.status === "pending" && ageMs(action.createdAt, now) > STALE_PENDING_SETTING_ACTION_MS) {
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

function authorized(request, role) {
  const header = request.headers.authorization || "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) {
    return false;
  }
  const actual = Buffer.from(match[1].trim());
  if (role === "client" && tokenMatches(actual, CLIENT_TOKEN)) {
    return true;
  }
  return tokenMatches(actual, WORKER_TOKEN);
}

function tokenMatches(actual, expectedToken) {
  const expected = Buffer.from(expectedToken);
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

async function readRawBody(request, maxBytes) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxBytes) {
      throw new Error("request body too large");
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
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
      summary_json TEXT NOT NULL,
      options_json TEXT NOT NULL DEFAULT '{}'
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
    CREATE TABLE IF NOT EXISTS file_access_requests (
      id TEXT PRIMARY KEY,
      item_id TEXT NOT NULL,
      item_kind TEXT NOT NULL,
      item_title TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      message TEXT NOT NULL DEFAULT '',
      object_key TEXT,
      download_ticket TEXT,
      expires_at TEXT,
      content_type TEXT,
      size_bytes INTEGER,
      download_count INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS file_access_requests_status_created_at_idx
      ON file_access_requests(status, created_at ASC);
    CREATE INDEX IF NOT EXISTS file_access_requests_updated_at_idx
      ON file_access_requests(updated_at DESC);
  `);
  try {
    db.exec("ALTER TABLE commands ADD COLUMN options_json TEXT NOT NULL DEFAULT '{}'");
  } catch {
    // Older local relay DBs already have the column after the first upgraded run.
  }
}

function loadState() {
  const commands = deduplicateByID(db.prepare(`
    SELECT id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json, options_json
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
  const storedSettingActions = parseJSON(getMeta("settingActions"), []);
  return {
    status: normalizeStatus(parseJSON(getMeta("status"), defaultStatus)),
    latestCommand,
    commands,
    itemActions,
    settingActions: deduplicateByID(
      (Array.isArray(storedSettingActions) ? storedSettingActions : [])
        .map((item) => normalizeSettingAction(item, item.status || "pending")),
      MAX_SETTING_ACTIONS
    ),
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
        id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json, options_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        JSON.stringify(normalizeStatus(command.summary || defaultStatus, command.status)),
        JSON.stringify(normalizeCommandOptions(command.options))
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
    setMeta("settingActions", JSON.stringify((state.settingActions || []).slice(0, MAX_SETTING_ACTIONS)));
    db.exec("COMMIT");
    touchRelayEvent("state", state.updatedAt);
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

function touchRelayEvent(reason = "updated", updatedAt = new Date().toISOString()) {
  setMeta("relayEventUpdatedAt", sanitizePublicText(updatedAt) || new Date().toISOString());
  setMeta("relayEventReason", sanitizePublicText(reason) || "updated");
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
    options: parseJSON(row.options_json, {}),
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

function rowToFileAccessRequest(row) {
  return normalizeFileAccessRequest({
    id: row.id,
    itemID: row.item_id,
    itemKind: row.item_kind,
    itemTitle: row.item_title,
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    message: row.message,
    objectKey: row.object_key,
    downloadTicket: row.download_ticket,
    expiresAt: row.expires_at,
    contentType: row.content_type,
    sizeBytes: row.size_bytes,
    downloadCount: row.download_count,
  }, row.status || "pending");
}

function loadFileAccessRequests({ statuses = [], order = "updated", limit = MAX_FILE_ACCESS_REQUESTS } = {}) {
  const orderSQL = order === "created" ? "created_at ASC" : "updated_at DESC";
  let rows;
  if (statuses.length > 0) {
    const placeholders = statuses.map(() => "?").join(", ");
    rows = db.prepare(`
      SELECT id, item_id, item_kind, item_title, status, created_at, updated_at, message,
             object_key, download_ticket, expires_at, content_type, size_bytes, download_count
      FROM file_access_requests
      WHERE status IN (${placeholders})
      ORDER BY ${orderSQL}
      LIMIT ?
    `).all(...statuses, limit);
  } else {
    rows = db.prepare(`
      SELECT id, item_id, item_kind, item_title, status, created_at, updated_at, message,
             object_key, download_ticket, expires_at, content_type, size_bytes, download_count
      FROM file_access_requests
      ORDER BY ${orderSQL}
      LIMIT ?
    `).all(limit);
  }
  return deduplicateByID(rows.map(rowToFileAccessRequest), limit);
}

function getFileAccessRequest(id) {
  const row = db.prepare(`
    SELECT id, item_id, item_kind, item_title, status, created_at, updated_at, message,
           object_key, download_ticket, expires_at, content_type, size_bytes, download_count
    FROM file_access_requests
    WHERE id = ?
  `).get(String(id || "").toLowerCase());
  return row ? rowToFileAccessRequest(row) : null;
}

function upsertFileAccessRequest(fileRequest) {
  db.prepare(`
    INSERT INTO file_access_requests (
      id, item_id, item_kind, item_title, status, created_at, updated_at, message,
      object_key, download_ticket, expires_at, content_type, size_bytes, download_count
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      item_id = excluded.item_id,
      item_kind = excluded.item_kind,
      item_title = excluded.item_title,
      status = excluded.status,
      created_at = excluded.created_at,
      updated_at = excluded.updated_at,
      message = excluded.message,
      object_key = excluded.object_key,
      download_ticket = excluded.download_ticket,
      expires_at = excluded.expires_at,
      content_type = excluded.content_type,
      size_bytes = excluded.size_bytes,
      download_count = excluded.download_count
  `).run(
    fileRequest.id,
    fileRequest.itemID,
    fileRequest.itemKind,
    fileRequest.itemTitle,
    fileRequest.status,
    fileRequest.createdAt,
    fileRequest.updatedAt,
    fileRequest.message,
    fileRequest.objectKey || null,
    fileRequest.downloadTicket || null,
    fileRequest.expiresAt || null,
    fileRequest.contentType || null,
    Number.isFinite(Number(fileRequest.sizeBytes)) ? Number(fileRequest.sizeBytes) : null,
    Number.isFinite(Number(fileRequest.downloadCount)) ? Number(fileRequest.downloadCount) : 0
  );
  trimFileAccessRequests();
}

function trimFileAccessRequests() {
  db.prepare(`
    DELETE FROM file_access_requests
    WHERE object_key IS NULL
      AND id NOT IN (
        SELECT id FROM file_access_requests ORDER BY updated_at DESC LIMIT ?
      )
  `).run(MAX_FILE_ACCESS_REQUESTS);
}

function expireStaleFileAccessRequests() {
  const now = Date.now();
  const rows = loadFileAccessRequests({
    statuses: ["pending", "running"],
    order: "created",
    limit: MAX_FILE_ACCESS_REQUESTS,
  });
  for (const fileRequest of rows) {
    if (ageMs(fileRequest.createdAt, now) <= STALE_PENDING_FILE_ACCESS_MS) {
      continue;
    }
    upsertFileAccessRequest({
      ...fileRequest,
      status: "macUnavailable",
      updatedAt: new Date().toISOString(),
      message: "Mac 앱이 제한 시간 안에 파일을 준비하지 않았습니다.",
    });
  }
}

async function cleanupExpiredFileAccess() {
  const nowISO = new Date().toISOString();
  const rows = db.prepare(`
    SELECT id, object_key
    FROM file_access_requests
    WHERE expires_at IS NOT NULL
      AND expires_at <= ?
  `).all(nowISO);
  for (const row of rows) {
    if (row.object_key) {
      try {
        await fs.unlink(localFileObjectPath(row.object_key));
      } catch (error) {
        if (error?.code !== "ENOENT") {
          console.error("failed to delete expired file object", error);
        }
      }
    }
  }
  if (rows.length > 0) {
    db.prepare(`
      DELETE FROM file_access_requests
      WHERE expires_at IS NOT NULL
        AND expires_at <= ?
    `).run(nowISO);
  }
}

async function uploadFileAccess(response, request, id) {
  const current = getFileAccessRequest(id);
  if (!current) {
    sendJSON(response, 404, { error: "file request not found" });
    return;
  }
  const limits = fileAccessLimits();
  const contentLength = Number.parseInt(request.headers["content-length"] || "0", 10);
  if (Number.isFinite(contentLength) && contentLength > limits.maxUploadBytes) {
    sendJSON(response, 413, { error: `file too large; limit is ${limits.maxUploadBytes} bytes` });
    return;
  }
  const quota = loadFileAccessQuota();
  if (quota.uploadCount >= limits.dailyUploads) {
    sendJSON(response, 429, { error: "daily file upload count limit reached" });
    return;
  }
  if (Number.isFinite(contentLength) && contentLength > 0 && quota.uploadBytes + contentLength > limits.dailyUploadBytes) {
    sendJSON(response, 429, { error: "daily file upload byte limit reached" });
    return;
  }

  const body = await readRawBody(request, limits.maxUploadBytes);
  if (body.length <= 0) {
    sendJSON(response, 411, { error: "file content is required" });
    return;
  }
  if (quota.uploadBytes + body.length > limits.dailyUploadBytes) {
    sendJSON(response, 429, { error: "daily file upload byte limit reached" });
    return;
  }

  const filename = sanitizeFilename(
    decodeHeaderFilename(request.headers["x-klms-filename"])
      || current.itemTitle
      || "klms-file"
  );
  const contentType = String(
    request.headers["content-type"]
      || request.headers["x-klms-content-type"]
      || "application/octet-stream"
  ).split(";")[0].trim() || "application/octet-stream";
  const objectKey = `file-access/${current.id}/${crypto.randomUUID()}-${filename}`;
  await fs.mkdir(path.dirname(localFileObjectPath(objectKey)), { recursive: true });
  await fs.writeFile(localFileObjectPath(objectKey), body);

  const updated = {
    ...current,
    status: "completed",
    updatedAt: new Date().toISOString(),
    message: "파일 링크 준비 완료",
    objectKey,
    downloadTicket: randomToken(),
    expiresAt: new Date(Date.now() + limits.ttlMs).toISOString(),
    contentType,
    sizeBytes: body.length,
    downloadCount: 0,
  };
  upsertFileAccessRequest(updated);
  touchRelayEvent("file-access:completed", updated.updatedAt);
  appendRequestLog(request, {
    action: "파일 업로드 완료",
    status: "completed",
    message: filename,
    source: "Mac",
  });
  saveFileAccessQuota({
    ...quota,
    uploadCount: quota.uploadCount + 1,
    uploadBytes: quota.uploadBytes + body.length,
  });
  sendJSON(response, 200, fileAccessResponseItem(updated, request));
}

async function downloadFileAccess(response, url, id) {
  const wantsPreview = url.searchParams.has("preview") && !url.searchParams.has("download");
  const ticket = url.searchParams.get("ticket") || "";
  const fileRequest = getFileAccessRequest(id);
  if (!fileRequest || fileRequest.status !== "completed" || !fileRequest.objectKey || !fileRequest.downloadTicket) {
    sendFileAccessDownloadPage(response, url, {
      status: 404,
      title: "파일 링크를 찾을 수 없습니다",
      message: "요청한 파일 링크가 없거나 이미 정리되었습니다.",
    });
    return;
  }
  if (fileRequest.downloadTicket !== ticket) {
    sendFileAccessDownloadPage(response, url, {
      status: 403,
      title: "권한이 없는 링크입니다",
      message: "링크의 인증 정보가 맞지 않습니다. 앱에서 파일 링크를 다시 요청해 주세요.",
    });
    return;
  }
  if (fileRequest.expiresAt && Date.parse(fileRequest.expiresAt) <= Date.now()) {
    await cleanupExpiredFileAccess();
    sendFileAccessDownloadPage(response, url, {
      fileRequest,
      status: 410,
      title: "파일 링크가 만료되었습니다",
      message: "임시 파일은 만료 후 자동 삭제됩니다. 앱에서 파일 링크를 다시 요청해 주세요.",
    });
    return;
  }
  const limits = fileAccessLimits();
  if (Number(fileRequest.downloadCount || 0) >= limits.downloadsPerLink) {
    sendFileAccessDownloadPage(response, url, {
      fileRequest,
      status: 429,
      title: "다운로드 횟수를 모두 사용했습니다",
      message: "이 링크의 다운로드 가능 횟수를 초과했습니다. 앱에서 새 링크를 요청해 주세요.",
    });
    return;
  }
  const quota = loadFileAccessQuota();
  if (quota.downloadCount >= limits.dailyDownloads) {
    sendFileAccessDownloadPage(response, url, {
      fileRequest,
      status: 429,
      title: "오늘 다운로드 한도에 도달했습니다",
      message: "과금 방지를 위해 오늘의 파일 다운로드 한도를 넘기지 않도록 막았습니다.",
    });
    return;
  }
  if (wantsPreview) {
    const preview = filePreviewDetails(fileRequest, limits.previewMaxBytes, limits.textPreviewMaxBytes);
    if (!preview.available) {
      sendFileAccessDownloadPage(response, url, {
        fileRequest,
        status: 415,
        title: "미리보기를 지원하지 않는 파일입니다",
        message: preview.message || "이 형식은 브라우저에서 바로 볼 수 없어 다운로드만 지원합니다.",
      });
      return;
    }
    let data;
    try {
      data = await fs.readFile(localFileObjectPath(fileRequest.objectKey));
    } catch (error) {
      if (error?.code === "ENOENT") {
        sendFileAccessDownloadPage(response, url, {
          fileRequest,
          status: 404,
          title: "파일을 찾을 수 없습니다",
          message: "임시 저장소의 파일이 이미 정리되었습니다. 앱에서 파일 링크를 다시 요청해 주세요.",
        });
        return;
      }
      throw error;
    }
    upsertFileAccessRequest({
      ...fileRequest,
      downloadCount: Number(fileRequest.downloadCount || 0) + 1,
      updatedAt: new Date().toISOString(),
    });
    appendRequestLog(null, {
      action: "파일 미리보기",
      status: "completed",
      message: fileRequest.itemTitle || "파일",
      method: "GET",
      path: "/v1/file-access/:id/download?preview",
      source: "웹",
    });
    saveFileAccessQuota({
      ...quota,
      downloadCount: quota.downloadCount + 1,
    });
    touchRelayEvent("file-access:previewed");
    sendLocalFileObject(response, fileRequest, data, { disposition: "inline", preview });
    return;
  }
  if (!url.searchParams.has("download")) {
    sendFileAccessDownloadPage(response, url, {
      fileRequest,
      status: 200,
      title: "KLMS 파일 미리보기",
      message: "Mac이 준비한 임시 파일 링크입니다. PDF와 이미지는 이 페이지에서 바로 열어 보고, 필요할 때만 다운로드하세요.",
      canDownload: true,
      previewMaxBytes: limits.previewMaxBytes,
      textPreviewMaxBytes: limits.textPreviewMaxBytes,
    });
    return;
  }
  let data;
  try {
    data = await fs.readFile(localFileObjectPath(fileRequest.objectKey));
  } catch (error) {
    if (error?.code === "ENOENT") {
      sendFileAccessDownloadPage(response, url, {
        fileRequest,
        status: 404,
        title: "파일을 찾을 수 없습니다",
        message: "임시 저장소의 파일이 이미 정리되었습니다. 앱에서 파일 링크를 다시 요청해 주세요.",
      });
      return;
    }
    throw error;
  }
  const updated = {
    ...fileRequest,
    downloadCount: Number(fileRequest.downloadCount || 0) + 1,
    updatedAt: new Date().toISOString(),
  };
  upsertFileAccessRequest(updated);
  appendRequestLog(null, {
    action: "파일 다운로드",
    status: "completed",
    message: fileRequest.itemTitle || "파일",
    method: "GET",
    path: "/v1/file-access/:id/download",
    source: "웹",
  });
  saveFileAccessQuota({
    ...quota,
    downloadCount: quota.downloadCount + 1,
  });
  touchRelayEvent("file-access:downloaded", updated.updatedAt);
  sendLocalFileObject(response, fileRequest, data, { disposition: "attachment" });
}

function sendFileAccessDownloadPage(response, url, {
  fileRequest = null,
  status = 200,
  title = "KLMS 파일 미리보기",
  message = "",
  canDownload = false,
  previewMaxBytes = DEFAULT_FILE_PREVIEW_MAX_BYTES,
  textPreviewMaxBytes = DEFAULT_TEXT_FILE_PREVIEW_MAX_BYTES,
}) {
  const downloadURL = canDownload ? downloadActionURL(url) : "";
  const preview = canDownload ? filePreviewDetails(fileRequest, previewMaxBytes, textPreviewMaxBytes) : { available: false, kind: "", label: "", message: "" };
  const previewURL = preview.available ? previewActionURL(url) : "";
  const previewMarkup = fileRequest && canDownload ? filePreviewMarkup(preview, previewURL) : "";
  const filename = fileRequest?.itemTitle || "KLMS 파일";
  const sizeText = formatBytes(fileRequest?.sizeBytes);
  const expiresText = fileRequest?.expiresAt || "";
  const downloadCount = Number.isFinite(Number(fileRequest?.downloadCount)) ? Number(fileRequest.downloadCount) : 0;
  const html = `<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHTML(title)}</title>
  <style>
    :root { color-scheme: light dark; --accent: #2563eb; --ink: #172033; --muted: #64748b; --panel: rgba(255,255,255,.86); --line: rgba(148,163,184,.35); }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: var(--ink); background: radial-gradient(circle at 20% 0%, #dbeafe 0, transparent 30%), linear-gradient(135deg, #f8fafc, #eef2ff 55%, #ecfeff); display: grid; place-items: center; padding: 28px; }
    main { width: min(860px, 100%); }
    .card { background: var(--panel); backdrop-filter: blur(16px); border: 1px solid var(--line); border-radius: 18px; box-shadow: 0 24px 60px rgba(15,23,42,.14); overflow: hidden; }
    .top { padding: 28px 28px 18px; }
    .badge { display: inline-flex; align-items: center; gap: 8px; padding: 7px 11px; border-radius: 999px; background: rgba(37,99,235,.10); color: var(--accent); font-size: 13px; font-weight: 700; }
    h1 { margin: 16px 0 8px; font-size: clamp(24px, 5vw, 34px); line-height: 1.12; letter-spacing: 0; }
    p { margin: 0; color: var(--muted); line-height: 1.55; }
    .file { margin: 18px 0 0; padding: 14px; border: 1px solid var(--line); border-radius: 14px; background: rgba(248,250,252,.72); }
    .filename { font-weight: 800; word-break: break-word; }
    .meta { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 10px; }
    .chip { padding: 6px 9px; border-radius: 999px; background: rgba(100,116,139,.11); color: #475569; font-size: 12px; font-weight: 650; }
    .preview { margin: 18px 0 0; border: 1px solid var(--line); border-radius: 14px; overflow: hidden; background: rgba(15,23,42,.04); }
    .preview-head { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 12px 14px; border-bottom: 1px solid var(--line); }
    .preview-title { font-weight: 800; }
    .preview-body { min-height: 220px; background: rgba(255,255,255,.62); }
    .preview-frame { display: block; width: 100%; height: min(62vh, 520px); border: 0; background: white; }
    .preview-text { width: 100%; min-height: 220px; max-height: min(62vh, 520px); margin: 0; padding: 14px; overflow: auto; white-space: pre-wrap; word-break: break-word; background: #fff; color: #111827; font: 13px/1.55 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
    .preview-image { display: block; width: 100%; max-height: min(62vh, 520px); object-fit: contain; background: #0f172a; }
    .preview-media { display: block; width: 100%; padding: 18px; }
    .preview-empty { padding: 16px 14px; color: var(--muted); line-height: 1.5; }
    .actions { display: flex; gap: 10px; padding: 18px 28px 28px; }
    a.button { flex: 1; text-align: center; text-decoration: none; border-radius: 12px; padding: 13px 16px; font-weight: 800; background: var(--accent); color: white; box-shadow: 0 10px 24px rgba(37,99,235,.26); }
    .note { padding: 0 28px 24px; font-size: 12px; color: var(--muted); }
    @media (prefers-color-scheme: dark) { :root { --ink: #e5e7eb; --muted: #a3aebf; --panel: rgba(15,23,42,.82); --line: rgba(148,163,184,.22); } body { background: radial-gradient(circle at 20% 0%, #1e3a8a 0, transparent 32%), linear-gradient(135deg, #020617, #111827 65%, #0f172a); } .file { background: rgba(15,23,42,.7); } .chip { background: rgba(148,163,184,.16); color: #cbd5e1; } .preview { background: rgba(15,23,42,.62); } .preview-body { background: rgba(2,6,23,.7); } }
    @media (max-width: 640px) { body { padding: 14px; place-items: start center; } .top { padding: 22px 18px 14px; } .actions { padding: 16px 18px 22px; } .note { padding: 0 18px 20px; } .preview-frame, .preview-image { height: 360px; max-height: 58vh; } }
  </style>
</head>
<body>
  <main>
    <section class="card">
      <div class="top">
        <div class="badge">${status === 200 ? "준비 완료" : "확인 필요"}</div>
        <h1>${escapeHTML(title)}</h1>
        <p>${escapeHTML(message)}</p>
        ${fileRequest ? `<div class="file"><div class="filename">${escapeHTML(filename)}</div><div class="meta">${sizeText ? `<span class="chip">${escapeHTML(sizeText)}</span>` : ""}${expiresText ? `<span class="chip" data-expires="${escapeHTML(expiresText)}">만료 ${escapeHTML(expiresText)}</span>` : ""}<span class="chip" data-download-count="${downloadCount}">열람/다운로드 ${downloadCount}회</span></div></div>` : ""}
        ${previewMarkup}
      </div>
      ${canDownload ? `<div class="actions"><a class="button" href="${escapeHTML(downloadURL)}">파일 다운로드</a></div>` : ""}
      <div class="note">이 링크는 임시 링크입니다. 만료되면 서버의 파일과 기록이 자동 정리됩니다.</div>
    </section>
  </main>
  <script>
    for (const el of document.querySelectorAll("[data-expires]")) {
      const d = new Date(el.dataset.expires);
      if (!Number.isNaN(d.getTime())) el.textContent = "만료 " + d.toLocaleString("ko-KR", { dateStyle: "medium", timeStyle: "short" });
    }
    const usageChip = document.querySelector("[data-download-count]");
    const countedPreviewElements = new WeakSet();
    function setUsageCount(value) {
      if (!usageChip) return;
      usageChip.dataset.downloadCount = String(value);
      usageChip.textContent = "열람/다운로드 " + value + "회";
    }
    function bumpUsageCount(el) {
      if (!usageChip || (el && countedPreviewElements.has(el))) return;
      if (el) countedPreviewElements.add(el);
      const current = Number.parseInt(usageChip.dataset.downloadCount || "0", 10);
      setUsageCount(Number.isFinite(current) ? current + 1 : 1);
    }
    for (const el of document.querySelectorAll("[data-preview-resource]")) {
      el.addEventListener("load", () => bumpUsageCount(el), { once: true });
      el.addEventListener("loadedmetadata", () => bumpUsageCount(el), { once: true });
      if (el.tagName === "IMG" && el.complete && el.naturalWidth > 0) {
        bumpUsageCount(el);
      }
    }
    for (const el of document.querySelectorAll("[data-preview-text-url]")) {
      fetch(el.dataset.previewTextUrl, { cache: "no-store" })
        .then((res) => {
          if (!res.ok) return Promise.reject(new Error("preview failed"));
          bumpUsageCount(el);
          return res.text();
        })
        .then((text) => { el.textContent = text || "미리볼 내용이 없습니다."; })
        .catch(() => { el.textContent = "미리보기를 불러오지 못했습니다. 다운로드해서 확인해 주세요."; });
    }
  </script>
</body>
</html>`;
  response.writeHead(status, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
    "Content-Security-Policy": "default-src 'none'; img-src 'self'; media-src 'self'; frame-src 'self'; connect-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'",
    "Referrer-Policy": "no-referrer",
  });
  response.end(html);
}

function downloadActionURL(url) {
  const next = new URL(url.toString());
  next.searchParams.set("download", "1");
  next.searchParams.delete("preview");
  return next.toString();
}

function previewActionURL(url) {
  const next = new URL(url.toString());
  next.searchParams.set("preview", "1");
  next.searchParams.delete("download");
  return next.toString();
}

function sendLocalFileObject(response, fileRequest, data, { disposition = "attachment", preview = null } = {}) {
  response.writeHead(200, {
    "Content-Type": effectiveFileContentType(fileRequest, { disposition, preview }),
    "Content-Disposition": contentDisposition(fileRequest.itemTitle || "KLMS file", disposition),
    "Content-Length": String(data.length),
    "Cache-Control": "no-store",
  });
  response.end(data);
}

function filePreviewMarkup(preview, previewURL) {
  if (preview.available) {
    const url = escapeHTML(previewURL);
    const label = escapeHTML(preview.label);
    if (preview.kind === "image") {
      return `<div class="preview"><div class="preview-head"><span class="preview-title">파일 미리보기</span><span class="chip">${label}</span></div><div class="preview-body"><img class="preview-image" data-preview-resource src="${url}" alt="파일 미리보기"></div></div>`;
    }
    if (preview.kind === "text") {
      return `<div class="preview"><div class="preview-head"><span class="preview-title">파일 미리보기</span><span class="chip">${label}</span></div><div class="preview-body"><pre class="preview-text" data-preview-text-url="${url}">미리보기를 불러오는 중입니다.</pre></div></div>`;
    }
    if (preview.kind === "audio") {
      return `<div class="preview"><div class="preview-head"><span class="preview-title">파일 미리보기</span><span class="chip">${label}</span></div><div class="preview-body"><audio class="preview-media" data-preview-resource controls src="${url}"></audio></div></div>`;
    }
    if (preview.kind === "video") {
      return `<div class="preview"><div class="preview-head"><span class="preview-title">파일 미리보기</span><span class="chip">${label}</span></div><div class="preview-body"><video class="preview-media" data-preview-resource controls src="${url}"></video></div></div>`;
    }
    return `<div class="preview"><div class="preview-head"><span class="preview-title">파일 미리보기</span><span class="chip">${label}</span></div><div class="preview-body"><iframe class="preview-frame" data-preview-resource title="파일 미리보기" src="${url}"></iframe></div></div>`;
  }
  return `<div class="preview"><div class="preview-head"><span class="preview-title">파일 미리보기</span><span class="chip">지원 안 함</span></div><div class="preview-empty">${escapeHTML(preview.message || "이 파일은 브라우저 미리보기를 지원하지 않습니다. 다운로드해서 확인해 주세요.")}</div></div>`;
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
    course: sanitizePublicText(raw.course),
    academicTerm: sanitizePublicText(raw.academicTerm),
    academicYear: Number.isFinite(Number(raw.academicYear)) ? Number(raw.academicYear) : null,
    academicSemester: sanitizePublicText(raw.academicSemester),
    title: sanitizePublicText(raw.title),
    timestamp: sanitizePublicText(raw.timestamp),
    status: sanitizePublicText(raw.status),
    detail: sanitizePublicText(raw.detail),
    attachmentCount: Number.isFinite(Number(raw.attachmentCount)) ? Number(raw.attachmentCount) : 0,
    updatedAt: String(raw.updatedAt || now),
    isRead: normalizeBoolean(raw.isRead),
    isImportant: normalizeBoolean(raw.isImportant),
    isHidden: normalizeBoolean(raw.isHidden),
  };
}

function normalizeBoolean(value) {
  if (typeof value === "boolean") {
    return value;
  }
  if (typeof value === "number") {
    return value !== 0;
  }
  if (typeof value === "string") {
    return ["1", "true", "yes", "y", "on"].includes(value.trim().toLowerCase());
  }
  return false;
}

function replaceSyncItems(items, generatedAt, extras = {}) {
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
    setMeta("syncDataDryRunReports", JSON.stringify(extras.dryRunReports || []));
    setMeta("syncDataCalendarChanges", JSON.stringify(extras.calendarChanges || []));
    setMeta("syncDataSettings", JSON.stringify(extras.settings || []));
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
  const dryRunReports = parseJSON(getMeta("syncDataDryRunReports"), []);
  const calendarChanges = parseJSON(getMeta("syncDataCalendarChanges"), []);
  const settings = parseJSON(getMeta("syncDataSettings"), []);
  return {
    generatedAt: getMeta("syncDataGeneratedAt") || "",
    updatedAt: getMeta("syncDataUpdatedAt") || "",
    items: rows.map((row) => normalizeSyncItem(parseJSON(row.payload_json, null))).filter(Boolean),
    dryRunReports: normalizeDryRunReports(dryRunReports),
    calendarChanges: normalizeCalendarChanges(calendarChanges),
    settings: normalizeSettings(settings),
  };
}

function normalizeDryRunReports(raw) {
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw.slice(0, MAX_SYNC_EXTRAS).map((report) => ({
    scope: sanitizePublicText(report?.scope),
    status: sanitizePublicText(report?.status) || "missing",
    would_create: boundedInt(report?.would_create ?? report?.wouldCreate, 0, 0, 1_000_000),
    would_update: boundedInt(report?.would_update ?? report?.wouldUpdate, 0, 0, 1_000_000),
    would_delete: boundedInt(report?.would_delete ?? report?.wouldDelete, 0, 0, 1_000_000),
    would_download: boundedInt(report?.would_download ?? report?.wouldDownload, 0, 0, 1_000_000),
    would_prune: boundedInt(report?.would_prune ?? report?.wouldPrune, 0, 0, 1_000_000),
    would_prune_course_files: boundedInt(report?.would_prune_course_files ?? report?.wouldPruneCourseFiles, 0, 0, 1_000_000),
    would_prune_archive: boundedInt(report?.would_prune_archive ?? report?.wouldPruneArchive, 0, 0, 1_000_000),
    skipped_side_effects: Array.isArray(report?.skipped_side_effects ?? report?.skippedSideEffects)
      ? (report.skipped_side_effects ?? report.skippedSideEffects).map(sanitizePublicText).filter(Boolean).slice(0, 50)
      : [],
    prune_backup_manifest: "",
    archive_prune_backup_manifest: "",
  }));
}

function normalizeCalendarChanges(raw) {
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw.slice(0, MAX_SYNC_EXTRAS).map((change) => ({
    action: sanitizePublicText(change?.action),
    calendar: sanitizePublicText(change?.calendar),
    bucket: sanitizePublicText(change?.bucket),
    identifier: sanitizePublicText(change?.identifier),
    title: sanitizePublicText(change?.title),
    course: sanitizePublicText(change?.course),
    url: "",
    start_at: sanitizePublicText(change?.start_at ?? change?.startAt),
    due_at: sanitizePublicText(change?.due_at ?? change?.dueAt),
    location: "",
    changes: Array.isArray(change?.changes) ? change.changes.map(sanitizePublicText).filter(Boolean).slice(0, 50) : [],
    raw: "",
    parse_error: sanitizePublicText(change?.parse_error ?? change?.parseError),
  }));
}

function normalizeSettings(raw) {
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw.slice(0, MAX_SYNC_EXTRAS).map((setting) => ({
    key: sanitizeSettingKey(setting?.key),
    title: sanitizePublicText(setting?.title),
    value: sanitizePublicText(setting?.value),
    valueKind: sanitizeSettingValueKind(setting?.valueKind ?? setting?.value_kind),
    options: Array.isArray(setting?.options) ? setting.options.map(sanitizePublicText).filter(Boolean).slice(0, 20) : [],
    editable: normalizeBoolean(setting?.editable ?? true),
    updatedAt: String(setting?.updatedAt || setting?.updated_at || new Date().toISOString()),
  })).filter((setting) => setting.key);
}

function sanitizePublicText(value) {
  const text = String(value || "").trim();
  if (!text) {
    return "";
  }
  if (looksPrivateText(text)) {
    return "";
  }
  return text.replace(/\/Users\/[^\s"'<>]+/g, "[local-path]");
}

function looksPrivateText(text) {
  if (/\/Users\//i.test(text)) {
    return true;
  }
  if (/(주소|address)/i.test(text)) {
    return true;
  }
  if (/(?<!\d)\d{5}(?!\d)/.test(text)) {
    return true;
  }
  if (/[가-힣A-Za-z0-9_.-]+(로|길)\s*\d{1,4}(\s*-\s*\d{1,4})?/.test(text)) {
    return true;
  }
  return false;
}

function sanitizeSettingKey(value) {
  const key = String(value || "").trim();
  return /^[A-Z][A-Z0-9_]*$/.test(key) ? key : "";
}

function sanitizeSettingValueKind(value) {
  const kind = String(value || "text");
  return ["bool", "number", "text", "choice"].includes(kind) ? kind : "text";
}

function boundedInt(value, fallback, min, max) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isInteger(parsed)) {
    return fallback;
  }
  return Math.max(min, Math.min(max, parsed));
}

function fileAccessLimits() {
  return {
    maxUploadBytes: boundedInt(process.env.KLMS_FILE_RELAY_MAX_UPLOAD_BYTES, DEFAULT_MAX_FILE_UPLOAD_BYTES, 1, 100 * 1024 * 1024),
    dailyUploads: boundedInt(process.env.KLMS_FILE_RELAY_DAILY_UPLOADS, DEFAULT_DAILY_FILE_UPLOADS, 1, 1_000),
    dailyUploadBytes: boundedInt(process.env.KLMS_FILE_RELAY_DAILY_UPLOAD_BYTES, DEFAULT_DAILY_FILE_UPLOAD_BYTES, 1, 10 * 1024 * 1024 * 1024),
    dailyDownloads: boundedInt(process.env.KLMS_FILE_RELAY_DAILY_DOWNLOADS, DEFAULT_DAILY_FILE_DOWNLOADS, 1, 100_000),
    downloadsPerLink: boundedInt(process.env.KLMS_FILE_RELAY_DOWNLOADS_PER_LINK, DEFAULT_FILE_DOWNLOADS_PER_LINK, 1, 100),
    previewMaxBytes: boundedInt(process.env.KLMS_FILE_RELAY_PREVIEW_MAX_BYTES, DEFAULT_FILE_PREVIEW_MAX_BYTES, 1, 100 * 1024 * 1024),
    textPreviewMaxBytes: boundedInt(process.env.KLMS_FILE_RELAY_TEXT_PREVIEW_MAX_BYTES, DEFAULT_TEXT_FILE_PREVIEW_MAX_BYTES, 1, 5 * 1024 * 1024),
    ttlMs: boundedInt(process.env.KLMS_FILE_RELAY_TTL_SECONDS, DEFAULT_FILE_ACCESS_TTL_MS / 1000, 60, 60 * 60) * 1000,
    maxPendingRequests: boundedInt(process.env.KLMS_FILE_RELAY_MAX_PENDING_REQUESTS, 20, 1, MAX_FILE_ACCESS_REQUESTS),
  };
}

function quotaKeyForToday(now = new Date()) {
  return `fileAccessQuota:${now.toISOString().slice(0, 10)}`;
}

function loadFileAccessQuota() {
  const raw = parseJSON(getMeta(quotaKeyForToday()), {});
  return {
    key: quotaKeyForToday(),
    uploadCount: Number.isFinite(Number(raw.uploadCount)) ? Number(raw.uploadCount) : 0,
    uploadBytes: Number.isFinite(Number(raw.uploadBytes)) ? Number(raw.uploadBytes) : 0,
    downloadCount: Number.isFinite(Number(raw.downloadCount)) ? Number(raw.downloadCount) : 0,
  };
}

function saveFileAccessQuota(quota) {
  setMeta(quota.key || quotaKeyForToday(), JSON.stringify({
    uploadCount: Number(quota.uploadCount || 0),
    uploadBytes: Number(quota.uploadBytes || 0),
    downloadCount: Number(quota.downloadCount || 0),
    updatedAt: new Date().toISOString(),
  }));
}

function randomToken() {
  return crypto.randomBytes(24).toString("base64url");
}

function downloadURLFor(fileRequest, request) {
  const url = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);
  url.pathname = `/v1/file-access/${fileRequest.id}/download`;
  url.search = "";
  url.searchParams.set("ticket", fileRequest.downloadTicket);
  return url.toString();
}

function localFileObjectPath(objectKey) {
  const safeKey = String(objectKey || "")
    .split("/")
    .filter(Boolean)
    .map(sanitizeFilename)
    .join(path.sep);
  return path.join(FILE_DIR, safeKey || "klms-file");
}

function sanitizeFilename(value) {
  const normalized = String(value || "klms-file")
    .replace(/[\\/:*?"<>|\u0000-\u001F]/g, "_")
    .replace(/\s+/g, " ")
    .trim();
  return (normalized || "klms-file").slice(0, 160);
}

function decodeHeaderFilename(value) {
  const raw = String(value || "").trim();
  if (!raw) {
    return "";
  }
  try {
    return decodeURIComponent(raw);
  } catch {
    return raw;
  }
}

function contentDisposition(filename, disposition = "attachment") {
  const safe = sanitizeFilename(filename);
  const ascii = safe.replace(/[^\x20-\x7E]/g, "_").replace(/"/g, "'");
  const mode = disposition === "inline" ? "inline" : "attachment";
  return `${mode}; filename="${ascii}"; filename*=UTF-8''${encodeRFC5987ValueChars(safe)}`;
}

function filePreviewDetails(
  fileRequest,
  previewMaxBytes = DEFAULT_FILE_PREVIEW_MAX_BYTES,
  textPreviewMaxBytes = DEFAULT_TEXT_FILE_PREVIEW_MAX_BYTES
) {
  if (!fileRequest) {
    return { available: false, kind: "", label: "", message: "" };
  }
  const filename = String(fileRequest.itemTitle || "");
  const extension = filename.includes(".") ? filename.split(".").pop().toLowerCase() : "";
  const contentType = effectiveFileContentType(fileRequest).split(";")[0].trim().toLowerCase();
  let preview = {
    available: false,
    kind: "",
    label: "",
    message: "이 형식은 브라우저에서 바로 볼 수 없어 다운로드만 지원합니다.",
  };
  if (contentType === "application/pdf") {
    preview = { available: true, kind: "pdf", label: "PDF", contentType, message: "" };
  } else if (contentType.startsWith("image/") && extension !== "svg") {
    preview = { available: true, kind: "image", label: "이미지", contentType, message: "" };
  } else if (contentType.startsWith("audio/")) {
    preview = { available: true, kind: "audio", label: "오디오", contentType, message: "" };
  } else if (contentType.startsWith("video/")) {
    preview = { available: true, kind: "video", label: "동영상", contentType, message: "" };
  } else if (
    contentType.startsWith("text/")
    || ["txt", "md", "markdown", "csv", "tsv", "json", "xml", "log", "svg"].includes(extension)
  ) {
    preview = { available: true, kind: "text", label: "텍스트", contentType: "text/plain; charset=utf-8", message: "" };
  }
  if (!preview.available) return preview;
  const bytes = Number(fileRequest.sizeBytes || 0);
  const maxBytes = preview.kind === "text" ? textPreviewMaxBytes : previewMaxBytes;
  if (Number.isFinite(bytes) && bytes > maxBytes) {
    return {
      available: false,
      kind: "",
      label: "",
      message: `파일이 ${formatBytes(maxBytes)}보다 커서 미리보기를 생략했습니다. 다운로드해서 확인해 주세요.`,
    };
  }
  return preview;
}

function effectiveFileContentType(fileRequest, { disposition = "attachment", preview = null } = {}) {
  if (disposition === "inline" && preview?.contentType) {
    return preview.contentType;
  }
  const stored = String(fileRequest?.contentType || "")
    .split(";")[0]
    .trim()
    .toLowerCase();
  if (stored && stored !== "application/octet-stream" && stored !== "binary/octet-stream") {
    return stored;
  }
  return inferredContentTypeForFilename(fileRequest?.itemTitle || "");
}

function inferredContentTypeForFilename(filename) {
  const extension = String(filename || "").split(".").pop()?.toLowerCase() || "";
  switch (extension) {
    case "pdf": return "application/pdf";
    case "png": return "image/png";
    case "jpg":
    case "jpeg": return "image/jpeg";
    case "gif": return "image/gif";
    case "webp": return "image/webp";
    case "bmp": return "image/bmp";
    case "mp3": return "audio/mpeg";
    case "m4a": return "audio/mp4";
    case "wav": return "audio/wav";
    case "aac": return "audio/aac";
    case "ogg": return "audio/ogg";
    case "mp4":
    case "m4v": return "video/mp4";
    case "mov": return "video/quicktime";
    case "webm": return "video/webm";
    case "txt":
    case "md":
    case "markdown":
    case "csv":
    case "tsv":
    case "json":
    case "xml":
    case "log":
    case "svg": return "text/plain; charset=utf-8";
    default: return "application/octet-stream";
  }
}

function formatBytes(value) {
  const bytes = Number(value || 0);
  if (!Number.isFinite(bytes) || bytes <= 0) return "";
  const units = ["B", "KB", "MB", "GB"];
  let size = bytes;
  let unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex += 1;
  }
  const digits = size >= 10 || unitIndex === 0 ? 0 : 1;
  return `${size.toFixed(digits)} ${units[unitIndex]}`;
}

function escapeHTML(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function encodeRFC5987ValueChars(value) {
  return encodeURIComponent(value)
    .replace(/['()]/g, escape)
    .replace(/\*/g, "%2A")
    .replace(/%(?:7C|60|5E)/g, unescape);
}

function loadCancelRequest() {
  const cancelRequest = normalizeCancelRequest(parseJSON(getMeta("cancelRequest"), {}));
  if (!cancelRequest.requested) {
    clearCancelRequest();
  }
  return cancelRequest;
}

function clearCancelRequest() {
  setMeta("cancelRequest", JSON.stringify(normalizeCancelRequest({ requested: false })));
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
    case "fileTrash":
      return "파일 휴지통";
    case "calendarVerify":
      return "캘린더 상태 확인";
    case "calendarApply":
      return "KLMS 기준 반영";
    case "calendarEdit":
      return "캘린더 내용 수정";
    case "calendarDelete":
      return "KLMS 기준 반영";
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
    case "verify":
      return "상태 검사";
    case "doctor":
      return "권한/환경 진단";
    case "report":
      return "요약 갱신";
    case "v2BuildState":
      return "상태 파일 재생성";
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
    case "cancelled":
      return "취소됨";
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
