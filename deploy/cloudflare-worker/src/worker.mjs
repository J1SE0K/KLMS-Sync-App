const MAX_BODY_BYTES = 1024 * 1024;
const MAX_COMMANDS = 100;
const MAX_ITEM_ACTIONS = 200;
const MAX_SETTING_ACTIONS = 100;
const MAX_REQUEST_LOG_ENTRIES = 100;
const MAX_SYNC_ITEMS = 2000;
const MAX_SYNC_EXTRAS = 200;
const MAX_SHARED_RUN_LOGS = 20;
const MAX_SHARED_RUN_LOG_CHARS = 6000;
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
const WORKER_INBOX_LONG_POLL_INTERVAL_MS = 350;
const SHARED_SETTING_DEFINITIONS = [
  {
    key: "KLMS_APPEARANCE_MODE",
    title: "화면 모드",
    value: "system",
    valueKind: "choice",
    options: ["system", "light", "dark"],
  },
  {
    key: "KLMS_UPDATE_NOTICE_NOTES",
    title: "공지 메모 업데이트",
    value: "1",
    valueKind: "bool",
    options: [],
  },
];

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
  phaseDetail: null,
  loginRequired: false,
  authDigits: null,
  authStatusMessage: null,
};

let schemaReady = false;

export class RelayRealtimeRoom {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/connect") {
      if (request.headers.get("Upgrade") !== "websocket") {
        return sendJSON(426, { error: "websocket required" });
      }
      const role = sanitizeRealtimeRole(url.searchParams.get("role"));
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      server.serializeAttachment({
        role,
        connectedAt: new Date().toISOString(),
      });
      this.state.acceptWebSocket(server);
      server.send(JSON.stringify({
        type: "hello",
        role,
        sentAt: new Date().toISOString(),
      }));
      return new Response(null, { status: 101, webSocket: client });
    }

    if (request.method === "POST" && url.pathname === "/broadcast") {
      const body = await readJSON(request);
      this.broadcast({
        type: "changed",
        reason: sanitizePublicText(body.reason) || "updated",
        updatedAt: sanitizePublicText(body.updatedAt) || new Date().toISOString(),
      });
      return sendJSON(200, { ok: true, connections: this.state.getWebSockets().length });
    }

    return sendJSON(404, { error: "not found" });
  }

  async webSocketMessage(webSocket, message) {
    if (String(message || "") === "ping") {
      webSocket.send(JSON.stringify({ type: "pong", sentAt: new Date().toISOString() }));
    }
  }

  async webSocketClose() {}
  async webSocketError() {}

  broadcast(payload) {
    const message = JSON.stringify(payload);
    for (const webSocket of this.state.getWebSockets()) {
      try {
        webSocket.send(message);
      } catch (_error) {
        try {
          webSocket.close(1011, "send failed");
        } catch (_closeError) {}
      }
    }
  }
}

export default {
  async fetch(request, env) {
    try {
      return await route(request, env);
    } catch (error) {
      console.error(error);
      return sendJSON(500, { error: "server error" });
    }
  },
  async scheduled(_event, env, ctx) {
    ctx.waitUntil(cleanupExpiredFileAccess(database(env), env));
  },
};

async function route(request, env) {
  const url = new URL(request.url);
  const pathname = normalizedPath(url.pathname, env);

  if (request.method === "GET" && pathname === "/healthz") {
    return sendJSON(200, {
      ok: true,
      storage: "cloudflare-d1",
      fileStorage: env?.RELAY_FILES ? "cloudflare-r2" : "not-configured",
      fileRelayLimits: publicFileAccessLimits(env),
      configured: relayTokens(env).configured,
    });
  }

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: baseHeaders() });
  }

  if (!pathname.startsWith("/v1/")) {
    return sendJSON(404, { error: "not found" });
  }

  if (request.method === "GET" && pathname === "/v1/events") {
    const role = sanitizeRealtimeRole(url.searchParams.get("role"));
    if (!(await authorized(request, env, role === "worker" ? "worker" : "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const room = realtimeRoom(env);
    if (!room) {
      return sendJSON(501, { error: "realtime not configured" });
    }
    return room.fetch(new Request("https://klms-sync-relay.internal/connect" + url.search, request));
  }

  if (request.method === "GET" && pathname === "/v1/events/poll") {
    const role = sanitizeRealtimeRole(url.searchParams.get("role"));
    if (!(await authorized(request, env, role === "worker" ? "worker" : "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const db = database(env);
    await ensureSchema(db);
    return sendJSON(200, await waitForRelayEventChange(db, url.searchParams));
  }

  const downloadMatch = pathname.match(/^\/v1\/file-access\/([0-9a-fA-F-]+)\/download$/);
  if (request.method === "GET" && downloadMatch) {
    const db = database(env);
    await ensureSchema(db);
    await cleanupExpiredFileAccess(db, env);
    return downloadFileAccess(db, env, request, downloadMatch[1]);
  }

  const requiredRole = requiredRoleFor(request.method, pathname);
  if (!requiredRole) {
    return sendJSON(404, { error: "not found" });
  }
  if (!(await authorized(request, env, requiredRole))) {
    return sendJSON(401, { error: "unauthorized" });
  }

  const db = database(env);
  await ensureSchema(db);
  await cleanupExpiredFileAccess(db, env);
  await expireStaleFileAccessRequests(db);
  let state = await loadState(db);
  if (await expireStaleRecords(db, state)) {
    state = await loadState(db);
  }

  if (request.method === "GET" && pathname === "/v1/worker/inbox") {
    if (!(await authorized(request, env, "worker"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    state = await waitForWorkerInboxChange(db, state, url.searchParams);
    return sendJSON(200, await workerInboxResponse(db, request, env, state));
  }

  if (request.method === "GET" && pathname === "/v1/status") {
    if (!(await authorized(request, env, "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    return sendJSON(200, relayResponse(state));
  }

  if (request.method === "POST" && pathname === "/v1/status") {
    if (!(await authorized(request, env, "worker"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const body = await readJSON(request);
    const now = new Date().toISOString();
    state.status = normalizeStatus(body.status || body);
    state.running = Boolean(body.running);
    state.message = String(body.message || "");
    if (body.latestCommand) {
      const command = normalizeCommand(body.latestCommand, body.latestCommand.status || "running");
      await upsertCommand(db, command);
      state.latestCommand = command;
    }
    state.updatedAt = now;
    await saveMetaState(db, state, env);
    return sendJSON(200, relayResponse(state));
  }

  if (request.method === "GET" && pathname === "/v1/sync-data") {
    if (!(await authorized(request, env, "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const kind = (url.searchParams.get("kind") || "").trim();
    const limit = boundedInt(url.searchParams.get("limit"), 250, 1, MAX_SYNC_ITEMS);
    return sendJSON(200, await syncDataResponse(db, { kind, limit }));
  }

  if (request.method === "GET" && pathname === "/v1/shared-settings") {
    if (!(await authorized(request, env, "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    return sendJSON(200, await sharedSettingsResponse(db));
  }

  const sharedSettingMatch = pathname.match(/^\/v1\/shared-settings\/([A-Z][A-Z0-9_]*)$/);
  if (request.method === "PUT" && sharedSettingMatch) {
    if (!(await authorized(request, env, "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const body = await readJSON(request);
    const setting = await updateSharedSetting(db, env, sharedSettingMatch[1], body, request);
    if (!setting) {
      return sendJSON(400, { error: "unsupported shared setting" });
    }
    return sendJSON(200, setting);
  }

  if (request.method === "POST" && pathname === "/v1/sync-data") {
    if (!(await authorized(request, env, "worker"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const body = await readJSON(request);
    const items = Array.isArray(body.items)
      ? body.items.map(normalizeSyncItem).filter(Boolean).slice(0, MAX_SYNC_ITEMS)
      : [];
    await replaceSyncItems(db, items, body.generatedAt, {
      dryRunReports: normalizeDryRunReports(body.dryRunReports),
      calendarChanges: normalizeCalendarChanges(body.calendarChanges),
      settings: normalizeSettings(body.settings),
      runLogs: normalizeRunLogs(body.runLogs),
      verifySummary: normalizeVerifySummary(body.verifySummary),
    });
    await touchRelayEvent(db, env, {
      reason: "sync-data",
      updatedAt: new Date().toISOString(),
    });
    return sendJSON(200, await syncDataResponse(db, { limit: MAX_SYNC_ITEMS }));
  }

  if (request.method === "DELETE" && pathname === "/v1/sync-data/run-logs") {
    if (!(await authorized(request, env, "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    return sendJSON(200, await clearSharedRunLogs(db, env));
  }

  if (request.method === "POST" && pathname === "/v1/cancel") {
    if (!(await authorized(request, env, "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const body = await readJSON(request);
    const cancelRequest = normalizeCancelRequest({
      requested: true,
      requestedAt: body.requestedAt || new Date().toISOString(),
      commandID: body.commandID || body.commandId || body.command_id,
      message: body.message || "사용자가 실행 중단을 요청했습니다.",
    });
    if (!cancelRequest.commandID) {
      return sendJSON(400, { error: "missing command id" });
    }
    const pendingCancel = await cancelPendingCommandIfNeeded(db, state, cancelRequest, request, env);
    if (pendingCancel) {
      return sendJSON(200, pendingCancel);
    }
    await setCancelRequest(db, cancelRequest);
    await appendRequestLog(db, request, {
      action: "동기화 중단 요청",
      status: "accepted",
      message: cancelRequest.message,
    });
    state.message = "실행 중단 요청 대기 중";
    state.updatedAt = new Date().toISOString();
    await saveMetaState(db, state, env, "cancel:requested");
    return sendJSON(202, cancelRequest);
  }

  if (request.method === "GET" && pathname === "/v1/cancel") {
    if (!(await authorized(request, env, "worker"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    return sendJSON(200, await loadCancelRequest(db));
  }

  if (request.method === "DELETE" && pathname === "/v1/cancel") {
    if (!(await authorized(request, env, "worker"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    await clearCancelRequest(db);
    return sendJSON(200, normalizeCancelRequest({ requested: false }));
  }

  if (request.method === "POST" && pathname === "/v1/commands") {
    if (!(await authorized(request, env, "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const body = await readJSON(request);
    const command = normalizeCommand(body, "pending");
    if (!command.kind) {
      return sendJSON(400, { error: "missing command kind" });
    }
    if (state.commands.some((item) => commandBlocksNewRequest(item, state.running))) {
      return sendJSON(409, { error: "already running or pending" });
    }
    command.summary = normalizeStatus(command.summary || state.status, "pending");
    command.loginRequired = Boolean(command.loginRequired);
    await upsertCommand(db, command);
    await appendRequestLog(db, request, {
      action: `${displayCommandName(command.kind)} 요청`,
      status: "queued",
      message: "원격 실행 요청을 서버에 기록했습니다.",
    });
    state.latestCommand = command;
    state.status = command.summary;
    state.running = false;
    state.message = `${displayCommandName(command.kind)} 요청 대기 중`;
    state.updatedAt = new Date().toISOString();
    await saveMetaState(db, state, env, "commands:pending");
    return sendJSON(201, command);
  }

  if (request.method === "GET" && pathname === "/v1/commands/pending") {
    if (!(await authorized(request, env, "worker"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    return sendJSON(200, commandListResponse(state, state.commands
      .filter((command) => command.status === "pending")
      .sort((lhs, rhs) => Date.parse(lhs.createdAt) - Date.parse(rhs.createdAt))));
  }

  if (request.method === "GET" && pathname === "/v1/commands/recent") {
    if (!(await authorized(request, env, "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const limit = boundedInt(url.searchParams.get("limit"), 10, 1, 50);
    const clearTimes = await displayLogClearTimes(db);
    return sendJSON(200, commandListResponse(state, filterDisplayCommands(state.commands, clearTimes.command)
      .slice()
      .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))
      .slice(0, limit)));
  }

  const commandMatch = pathname.match(/^\/v1\/commands\/([0-9a-fA-F-]+)$/);
  if (request.method === "PUT" && commandMatch) {
    if (!(await authorized(request, env, "worker"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const body = await readJSON(request);
    const command = normalizeCommand({ ...body, id: commandMatch[1] }, body.status || "pending");
    await upsertCommand(db, command);
    state.latestCommand = command;
    state.status = normalizeStatus(command.summary || state.status, command.status);
    state.running = command.status === "running";
    state.message = `${displayCommandName(command.kind)} · ${displayStatus(command.status)}`;
    state.updatedAt = new Date().toISOString();
    await saveMetaState(db, state, env, `commands:${command.status || "updated"}`);
    return sendJSON(200, command);
  }

  if (request.method === "POST" && pathname === "/v1/item-actions") {
    if (!(await authorized(request, env, "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const body = await readJSON(request);
    const action = normalizeItemAction(body, "pending");
    if (!action.action || !action.itemID || !action.itemKind) {
      return sendJSON(400, { error: "missing item action target" });
    }
    await upsertItemAction(db, action);
    await appendRequestLog(db, request, {
      action: displayItemActionName(action.action),
      status: "queued",
      message: action.itemTitle || action.itemID,
    });
    state.message = `${displayItemActionName(action.action)} 요청 대기 중`;
    state.updatedAt = new Date().toISOString();
    await saveMetaState(db, state, env, "item-actions:pending");
    return sendJSON(201, action);
  }

  if (request.method === "GET" && pathname === "/v1/item-actions/pending") {
    if (!(await authorized(request, env, "worker"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    return sendJSON(200, itemActionListResponse(state.itemActions
      .filter((action) => action.status === "pending")
      .sort((lhs, rhs) => Date.parse(lhs.createdAt) - Date.parse(rhs.createdAt))));
  }

  if (request.method === "GET" && pathname === "/v1/item-actions/recent") {
    if (!(await authorized(request, env, "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const limit = boundedInt(url.searchParams.get("limit"), 20, 1, 50);
    return sendJSON(200, itemActionListResponse(state.itemActions
      .slice()
      .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))
      .slice(0, limit)));
  }

  const itemActionMatch = pathname.match(/^\/v1\/item-actions\/([0-9a-fA-F-]+)$/);
  if (request.method === "PUT" && itemActionMatch) {
    if (!(await authorized(request, env, "worker"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const body = await readJSON(request);
    const action = normalizeItemAction({ ...body, id: itemActionMatch[1] }, body.status || "pending");
    await upsertItemAction(db, action);
    state.message = `${displayItemActionName(action.action)} · ${displayStatus(action.status)}`;
    state.updatedAt = new Date().toISOString();
    await saveMetaState(db, state, env, `item-actions:${action.status || "updated"}`);
    return sendJSON(200, action);
  }

  if (request.method === "POST" && pathname === "/v1/setting-actions") {
    if (!(await authorized(request, env, "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const body = await readJSON(request);
    const action = normalizeSettingAction(body, "pending");
    if (!action.key) {
      return sendJSON(400, { error: "missing setting key" });
    }
    await upsertSettingAction(db, action);
    await appendRequestLog(db, request, {
      action: `${action.title || action.key} 설정 변경`,
      status: "queued",
      message: "설정 변경 요청을 서버에 기록했습니다.",
    });
    state.message = `${action.title || action.key} 설정 변경 요청 대기 중`;
    state.updatedAt = new Date().toISOString();
    await saveMetaState(db, state, env, "setting-actions:pending");
    return sendJSON(201, action);
  }

  if (request.method === "GET" && pathname === "/v1/setting-actions/pending") {
    if (!(await authorized(request, env, "worker"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    return sendJSON(200, settingActionListResponse(state.settingActions
      .filter((action) => action.status === "pending")
      .sort((lhs, rhs) => Date.parse(lhs.createdAt) - Date.parse(rhs.createdAt))));
  }

  if (request.method === "GET" && pathname === "/v1/setting-actions/recent") {
    if (!(await authorized(request, env, "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const limit = boundedInt(url.searchParams.get("limit"), 20, 1, 50);
    return sendJSON(200, settingActionListResponse(state.settingActions
      .slice()
      .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))
      .slice(0, limit)));
  }

  const settingActionMatch = pathname.match(/^\/v1\/setting-actions\/([0-9a-fA-F-]+)$/);
  if (request.method === "PUT" && settingActionMatch) {
    if (!(await authorized(request, env, "worker"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const body = await readJSON(request);
    const action = normalizeSettingAction({ ...body, id: settingActionMatch[1] }, body.status || "pending");
    await upsertSettingAction(db, action);
    state.message = `${action.title || action.key} · ${displayStatus(action.status)}`;
    state.updatedAt = new Date().toISOString();
    await saveMetaState(db, state, env, `setting-actions:${action.status || "updated"}`);
    return sendJSON(200, action);
  }

  if (request.method === "POST" && pathname === "/v1/file-access") {
    if (!(await authorized(request, env, "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const body = await readJSON(request);
    const fileRequest = normalizeFileAccessRequest(body, "pending");
    if (!fileRequest.itemID || fileRequest.itemKind !== "file") {
      return sendJSON(400, { error: "missing file target" });
    }
    const pendingRequests = await loadFileAccessRequests(db, {
      statuses: ["pending", "running"],
      order: "created",
      limit: MAX_FILE_ACCESS_REQUESTS,
    });
    if (pendingRequests.length >= fileAccessLimits(env).maxPendingRequests) {
      return sendJSON(429, { error: "file access queue limit reached" });
    }
    await upsertFileAccessRequest(db, fileRequest);
    await appendRequestLog(db, request, {
      action: "파일 열기 요청",
      status: "queued",
      message: fileRequest.itemTitle || fileRequest.itemID,
    });
    state.message = `파일 열기 요청 대기 중: ${fileRequest.itemTitle || fileRequest.itemID}`;
    state.updatedAt = new Date().toISOString();
    await saveMetaState(db, state, env, "file-access:pending");
    return sendJSON(201, fileAccessResponseItem(fileRequest, request, env));
  }

  if (request.method === "GET" && pathname === "/v1/file-access/pending") {
    if (!(await authorized(request, env, "worker"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const limit = boundedInt(url.searchParams.get("limit"), 20, 1, MAX_FILE_ACCESS_REQUESTS);
    return sendJSON(200, fileAccessListResponse(
      await loadFileAccessRequests(db, {
        statuses: ["pending"],
        order: "created",
        limit,
      }),
      request,
      env
    ));
  }

  if (request.method === "GET" && pathname === "/v1/file-access/recent") {
    if (!(await authorized(request, env, "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const limit = boundedInt(url.searchParams.get("limit"), 20, 1, MAX_FILE_ACCESS_REQUESTS);
    const clearTimes = await displayLogClearTimes(db);
    return sendJSON(200, fileAccessListResponse(
      filterDisplayFileAccess(await loadFileAccessRequests(db, { limit: MAX_FILE_ACCESS_REQUESTS }), clearTimes.fileAccess).slice(0, limit),
      request,
      env
    ));
  }

  if (request.method === "GET" && pathname === "/v1/request-log/recent") {
    if (!(await authorized(request, env, "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const limit = boundedInt(url.searchParams.get("limit"), 20, 1, MAX_REQUEST_LOG_ENTRIES);
    return sendJSON(200, await requestLogResponse(db, limit));
  }

  if (request.method === "DELETE" && pathname === "/v1/logs/display") {
    if (!(await authorized(request, env, "client"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const scope = normalizeLogClearScope(url.searchParams.get("scope"));
    return sendJSON(200, await clearDisplayLogs(db, env, state, scope));
  }

  if (request.method === "DELETE" && pathname === "/v1/logs") {
    if (!(await authorized(request, env, "worker"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const scope = normalizeLogClearScope(url.searchParams.get("scope"));
    if (scope === "fileAccess" && await hasActiveFileAccessWork(db)) {
      return sendJSON(409, { error: "active file access request is still running" });
    }
    return sendJSON(200, await clearRelayLogs(db, env, state, scope));
  }

  const fileAccessMatch = pathname.match(/^\/v1\/file-access\/([0-9a-fA-F-]+)$/);
  if (request.method === "PUT" && fileAccessMatch) {
    if (!(await authorized(request, env, "worker"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const body = await readJSON(request);
    const current = await getFileAccessRequest(db, fileAccessMatch[1]);
    if (!current) {
      return sendJSON(404, { error: "file request not found" });
    }
    const fileRequest = normalizeFileAccessRequest({
      ...current,
      ...body,
      id: fileAccessMatch[1],
      itemID: body.itemID || body.itemId || current.itemID,
      itemKind: body.itemKind || current.itemKind,
      itemTitle: body.itemTitle || current.itemTitle,
    }, body.status || current.status || "pending");
    await upsertFileAccessRequest(db, fileRequest);
    await touchRelayEvent(db, env, {
      reason: `file-access:${fileRequest.status}`,
      updatedAt: fileRequest.updatedAt,
    });
    return sendJSON(200, fileAccessResponseItem(fileRequest, request, env));
  }

  const fileUploadMatch = pathname.match(/^\/v1\/file-access\/([0-9a-fA-F-]+)\/upload$/);
  if (request.method === "PUT" && fileUploadMatch) {
    if (!(await authorized(request, env, "worker"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    return uploadFileAccess(db, env, request, fileUploadMatch[1]);
  }

  return sendJSON(404, { error: "not found" });
}

function requiredRoleFor(method, pathname) {
  if (method === "GET" && pathname === "/v1/worker/inbox") return "worker";
  if (method === "GET" && pathname === "/v1/status") return "client";
  if (method === "POST" && pathname === "/v1/status") return "worker";
  if (method === "GET" && pathname === "/v1/sync-data") return "client";
  if (method === "GET" && pathname === "/v1/shared-settings") return "client";
  if (method === "PUT" && /^\/v1\/shared-settings\/[A-Z][A-Z0-9_]*$/.test(pathname)) return "client";
  if (method === "POST" && pathname === "/v1/sync-data") return "worker";
  if (method === "DELETE" && pathname === "/v1/sync-data/run-logs") return "client";
  if (method === "POST" && pathname === "/v1/cancel") return "client";
  if (method === "GET" && pathname === "/v1/cancel") return "worker";
  if (method === "DELETE" && pathname === "/v1/cancel") return "worker";
  if (method === "POST" && pathname === "/v1/commands") return "client";
  if (method === "GET" && pathname === "/v1/commands/pending") return "worker";
  if (method === "GET" && pathname === "/v1/commands/recent") return "client";
  if (method === "PUT" && /^\/v1\/commands\/[0-9a-fA-F-]+$/.test(pathname)) return "worker";
  if (method === "POST" && pathname === "/v1/item-actions") return "client";
  if (method === "GET" && pathname === "/v1/item-actions/pending") return "worker";
  if (method === "GET" && pathname === "/v1/item-actions/recent") return "client";
  if (method === "PUT" && /^\/v1\/item-actions\/[0-9a-fA-F-]+$/.test(pathname)) return "worker";
  if (method === "POST" && pathname === "/v1/setting-actions") return "client";
  if (method === "GET" && pathname === "/v1/setting-actions/pending") return "worker";
  if (method === "GET" && pathname === "/v1/setting-actions/recent") return "client";
  if (method === "PUT" && /^\/v1\/setting-actions\/[0-9a-fA-F-]+$/.test(pathname)) return "worker";
  if (method === "POST" && pathname === "/v1/file-access") return "client";
  if (method === "GET" && pathname === "/v1/file-access/pending") return "worker";
  if (method === "GET" && pathname === "/v1/file-access/recent") return "client";
  if (method === "GET" && pathname === "/v1/request-log/recent") return "client";
  if (method === "DELETE" && pathname === "/v1/logs/display") return "client";
  if (method === "DELETE" && pathname === "/v1/logs") return "worker";
  if (method === "PUT" && /^\/v1\/file-access\/[0-9a-fA-F-]+$/.test(pathname)) return "worker";
  if (method === "PUT" && /^\/v1\/file-access\/[0-9a-fA-F-]+\/upload$/.test(pathname)) return "worker";
  return null;
}

async function workerInboxResponse(db, request, env, state) {
  const clearTimes = await displayLogClearTimes(db);
  const [
    requestLog,
    recentFileAccess,
    pendingFileAccess,
    cancelRequest,
    sharedSettings,
  ] = await Promise.all([
    requestLogResponse(db, 20),
    loadFileAccessRequests(db, { limit: 8 }),
    loadFileAccessRequests(db, {
      statuses: ["pending"],
      order: "created",
      limit: 20,
    }),
    loadCancelRequest(db),
    loadSharedSettings(db),
  ]);
  return {
    statusResponse: relayResponse(state),
    recentRequestLog: requestLog.entries,
    recentFileAccessRequests: fileAccessListResponse(
      filterDisplayFileAccess(recentFileAccess, clearTimes.fileAccess),
      request,
      env
    ).requests,
    pendingFileAccessRequests: fileAccessListResponse(pendingFileAccess, request, env).requests,
    pendingSettingActions: state.settingActions
      .filter((action) => action.status === "pending")
      .sort((lhs, rhs) => Date.parse(lhs.createdAt) - Date.parse(rhs.createdAt)),
    pendingItemActions: state.itemActions
      .filter((action) => action.status === "pending")
      .sort((lhs, rhs) => Date.parse(lhs.createdAt) - Date.parse(rhs.createdAt)),
    pendingCommands: state.commands
      .filter((command) => command.status === "pending")
      .sort((lhs, rhs) => Date.parse(lhs.createdAt) - Date.parse(rhs.createdAt)),
    cancelRequest,
    sharedSettings,
  };
}

async function waitForWorkerInboxChange(db, state, searchParams) {
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
    return state;
  }
  if (Date.parse(state.updatedAt || "") > sinceEpoch || await hasWorkerInboxWork(db, state)) {
    return state;
  }

  const deadline = Date.now() + waitMs;
  let current = state;
  while (Date.now() < deadline) {
    await sleep(Math.min(WORKER_INBOX_LONG_POLL_INTERVAL_MS, Math.max(25, deadline - Date.now())));
    current = await loadState(db);
    if (Date.parse(current.updatedAt || "") > sinceEpoch || await hasWorkerInboxWork(db, current)) {
      return current;
    }
  }
  return current;
}

async function waitForRelayEventChange(db, searchParams) {
  const since = String(searchParams.get("since") || "").trim();
  const sinceEpoch = Date.parse(since);
  const waitSeconds = boundedInt(searchParams.get("waitSeconds"), 0, 0, 25);
  const waitMs = boundedInt(
    searchParams.get("waitMs"),
    waitSeconds * 1000,
    0,
    WORKER_INBOX_LONG_POLL_MAX_MS
  );
  let current = await relayEventSnapshot(db);
  if (waitMs <= 0 || !Number.isFinite(sinceEpoch) || Date.parse(current.updatedAt || "") > sinceEpoch) {
    return current;
  }

  const deadline = Date.now() + waitMs;
  while (Date.now() < deadline) {
    await sleep(Math.min(WORKER_INBOX_LONG_POLL_INTERVAL_MS, Math.max(25, deadline - Date.now())));
    current = await relayEventSnapshot(db);
    if (Date.parse(current.updatedAt || "") > sinceEpoch) {
      return current;
    }
  }
  return current;
}

async function relayEventSnapshot(db) {
  const [eventUpdatedAt, eventReason, stateUpdatedAt, syncDataUpdatedAt] = await Promise.all([
    getMeta(db, "relayEventUpdatedAt"),
    getMeta(db, "relayEventReason"),
    getMeta(db, "updatedAt"),
    getMeta(db, "syncDataUpdatedAt"),
  ]);
  return {
    type: "changed",
    reason: sanitizePublicText(eventReason) || "state",
    updatedAt: newestTimestamp([
      eventUpdatedAt,
      stateUpdatedAt,
      syncDataUpdatedAt,
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

async function hasWorkerInboxWork(db, state) {
  if (state.commands.some((command) => command.status === "pending")) {
    return true;
  }
  if (state.itemActions.some((action) => action.status === "pending")) {
    return true;
  }
  if ((state.settingActions || []).some((action) => action.status === "pending")) {
    return true;
  }
  const cancelRequest = await loadCancelRequest(db);
  if (cancelRequest.requested) {
    return true;
  }
  const pendingFileAccess = await loadFileAccessRequests(db, {
    statuses: ["pending"],
    order: "created",
    limit: 1,
  });
  return pendingFileAccess.length > 0;
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function database(env) {
  if (!env?.RELAY_DB) {
    throw new Error("RELAY_DB D1 binding is required.");
  }
  return env.RELAY_DB;
}

function relayTokens(env) {
  const client = String(env?.RELAY_CLIENT_TOKEN || env?.KLMS_RELAY_CLIENT_TOKEN || "").trim();
  const worker = String(env?.RELAY_WORKER_TOKEN || env?.KLMS_RELAY_WORKER_TOKEN || "").trim();
  return {
    client,
    worker,
    configured: Boolean(client && worker && client !== worker),
  };
}

async function authorized(request, env, role) {
  const tokens = relayTokens(env);
  if (!tokens.configured) {
    return false;
  }
  const header = request.headers.get("Authorization") || "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) {
    return false;
  }
  const actual = match[1].trim();
  if (role === "client" && await constantTimeEqual(tokens.client, actual)) {
    return true;
  }
  return constantTimeEqual(tokens.worker, actual);
}

async function constantTimeEqual(expected, actual) {
  const encoder = new TextEncoder();
  const [expectedHash, actualHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
    crypto.subtle.digest("SHA-256", encoder.encode(actual)),
  ]);
  const expectedBytes = new Uint8Array(expectedHash);
  const actualBytes = new Uint8Array(actualHash);
  let diff = expected.length ^ actual.length;
  for (let index = 0; index < expectedBytes.length; index += 1) {
    diff |= expectedBytes[index] ^ actualBytes[index];
  }
  return diff === 0;
}

function sanitizeRealtimeRole(value) {
  return String(value || "").trim().toLowerCase() === "worker" ? "worker" : "client";
}

function realtimeRoom(env) {
  if (!env?.RELAY_REALTIME) {
    return null;
  }
  return env.RELAY_REALTIME.get(env.RELAY_REALTIME.idFromName("default"));
}

async function notifyRelayChange(env, payload = {}) {
  const room = realtimeRoom(env);
  if (!room) {
    return;
  }
  try {
    await room.fetch("https://klms-sync-relay.internal/broadcast", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch (error) {
    console.warn("realtime notify failed", error?.message || error);
  }
}

async function touchRelayEvent(db, env, payload = {}) {
  const updatedAt = sanitizePublicText(payload.updatedAt) || new Date().toISOString();
  const reason = sanitizePublicText(payload.reason) || "updated";
  if (db) {
    await db.batch([
      setMetaStatement(db, "relayEventUpdatedAt", updatedAt),
      setMetaStatement(db, "relayEventReason", reason),
    ]);
  }
  await notifyRelayChange(env, {
    ...payload,
    reason,
    updatedAt,
  });
}

function normalizedPath(pathname, env) {
  const normalized = `/${String(pathname || "/")
    .split("/")
    .filter(Boolean)
    .join("/")}`;
  const configuredPrefix = String(env?.RELAY_PATH_PREFIX || "").trim();
  const prefixes = [configuredPrefix, "/relay"]
    .map((prefix) => `/${String(prefix).split("/").filter(Boolean).join("/")}`)
    .filter((prefix) => prefix !== "/");
  for (const prefix of prefixes) {
    if (normalized === prefix) {
      return "/";
    }
    if (normalized.startsWith(`${prefix}/`)) {
      return normalized.slice(prefix.length) || "/";
    }
  }
  return normalized;
}

async function ensureSchema(db) {
  void db;
  schemaReady = true;
}

async function loadState(db) {
  const [status, latestCommand, running, message, updatedAt, commands, itemActions, settingActions] = await Promise.all([
    getJSONMeta(db, "status", defaultStatus),
    getJSONMeta(db, "latestCommand", null),
    getMeta(db, "running"),
    getMeta(db, "message"),
    getMeta(db, "updatedAt"),
    loadCommands(db),
    loadItemActions(db),
    loadSettingActions(db),
  ]);
  const storedLatest = latestCommand
    ? normalizeCommand(latestCommand, latestCommand.status || "pending")
    : null;
  const newestStoredCommand = commands[0] || null;
  const normalizedLatest = newestStoredCommand && (
    !storedLatest ||
    newestStoredCommand.id === storedLatest.id ||
    Date.parse(newestStoredCommand.updatedAt) >= Date.parse(storedLatest.updatedAt)
  )
    ? newestStoredCommand
    : storedLatest;
  return {
    status: normalizeStatus(status),
    latestCommand: normalizedLatest,
    commands,
    itemActions,
    settingActions,
    running: running === "true",
    message: message || "서버 준비됨",
    updatedAt: updatedAt || new Date().toISOString(),
  };
}

async function loadCommands(db) {
  const result = await db.prepare(`
    SELECT id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json, options_json
    FROM commands
    ORDER BY updated_at DESC
    LIMIT ?
  `).bind(MAX_COMMANDS * 2).all();
  return deduplicateByID((result.results || []).map(rowToCommand), MAX_COMMANDS);
}

async function loadItemActions(db) {
  const result = await db.prepare(`
    SELECT id, action, item_id, item_kind, item_title, status, created_at, updated_at, message
    FROM item_actions
    ORDER BY updated_at DESC
    LIMIT ?
  `).bind(MAX_ITEM_ACTIONS * 2).all();
  return deduplicateByID((result.results || []).map(rowToItemAction), MAX_ITEM_ACTIONS);
}

async function loadSettingActions(db) {
  const raw = parseJSON(await getMeta(db, "settingActions"), []);
  return deduplicateByID(
    (Array.isArray(raw) ? raw : []).map((item) => normalizeSettingAction(item, item?.status || "pending")),
    MAX_SETTING_ACTIONS
  );
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

async function saveMetaState(db, state, env = null, reason = "state") {
  await db.batch([
    setMetaStatement(db, "status", JSON.stringify(normalizeStatus(state.status || defaultStatus))),
    setMetaStatement(db, "latestCommand", JSON.stringify(state.latestCommand || null)),
    setMetaStatement(db, "running", state.running ? "true" : "false"),
    setMetaStatement(db, "message", String(state.message || "")),
    setMetaStatement(db, "updatedAt", String(state.updatedAt || new Date().toISOString())),
  ]);
  await touchRelayEvent(db, env, {
    reason,
    updatedAt: state.updatedAt || new Date().toISOString(),
  });
}

async function getMeta(db, key) {
  const row = await db.prepare("SELECT value FROM meta WHERE key = ?").bind(key).first();
  return row?.value;
}

async function getJSONMeta(db, key, fallback) {
  return parseJSON(await getMeta(db, key), fallback);
}

function setMetaStatement(db, key, value) {
  return db.prepare(`
    INSERT INTO meta(key, value)
    VALUES(?, ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value
  `).bind(key, String(value));
}

async function upsertCommand(db, command) {
  await db.prepare(`
    INSERT INTO commands (
      id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json, options_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      kind = excluded.kind,
      status = excluded.status,
      created_at = excluded.created_at,
      updated_at = excluded.updated_at,
      last_exit_code = excluded.last_exit_code,
      login_required = excluded.login_required,
      summary_json = excluded.summary_json,
      options_json = excluded.options_json
  `).bind(
    command.id,
    command.kind,
    command.status,
    command.createdAt,
    command.updatedAt,
    Number.isInteger(command.lastExitCode) ? command.lastExitCode : null,
    command.loginRequired ? 1 : 0,
    JSON.stringify(normalizeStatus(command.summary || defaultStatus, command.status)),
    JSON.stringify(normalizeCommandOptions(command.options))
  ).run();
  await trimCommands(db);
}

async function trimCommands(db) {
  await db.prepare(`
    DELETE FROM commands
    WHERE id NOT IN (
      SELECT id FROM commands ORDER BY updated_at DESC LIMIT ?
    )
  `).bind(MAX_COMMANDS).run();
}

async function upsertItemAction(db, action) {
  await db.prepare(`
    INSERT INTO item_actions (
      id, action, item_id, item_kind, item_title, status, created_at, updated_at, message
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      action = excluded.action,
      item_id = excluded.item_id,
      item_kind = excluded.item_kind,
      item_title = excluded.item_title,
      status = excluded.status,
      created_at = excluded.created_at,
      updated_at = excluded.updated_at,
      message = excluded.message
  `).bind(
    action.id,
    action.action,
    action.itemID,
    action.itemKind,
    action.itemTitle,
    action.status,
    action.createdAt,
    action.updatedAt,
    action.message
  ).run();
  await trimItemActions(db);
}

async function upsertSettingAction(db, action) {
  const current = await loadSettingActions(db);
  const next = deduplicateByID([action, ...current], MAX_SETTING_ACTIONS);
  await setMetaStatement(db, "settingActions", JSON.stringify(next)).run();
}

async function requestLogResponse(db, limit = 20) {
  const clearTimes = await displayLogClearTimes(db);
  return {
    entries: filterDisplayRequestLog(
      await loadRequestLog(db),
      clearTimes.requestLog
    ).slice(0, Math.max(1, Math.min(MAX_REQUEST_LOG_ENTRIES, limit))),
  };
}

async function appendRequestLog(db, request, raw) {
  const entry = normalizeRequestLogEntry(request, raw);
  const entries = [entry, ...(await loadRequestLog(db)).filter((item) => item.id !== entry.id)]
    .sort((lhs, rhs) => Date.parse(rhs.createdAt) - Date.parse(lhs.createdAt))
    .slice(0, MAX_REQUEST_LOG_ENTRIES);
  await setMetaStatement(db, "requestLog", JSON.stringify(entries)).run();
}

async function loadRequestLog(db) {
  const raw = parseJSON(await getMeta(db, "requestLog"), []);
  return (Array.isArray(raw) ? raw : [])
    .map((item) => normalizeRequestLogEntry(null, item))
    .sort((lhs, rhs) => Date.parse(rhs.createdAt) - Date.parse(lhs.createdAt))
    .slice(0, MAX_REQUEST_LOG_ENTRIES);
}

async function displayLogClearTimes(db) {
  return {
    command: await getMeta(db, "displayCommandLogClearedAt"),
    requestLog: await getMeta(db, "displayRequestLogClearedAt"),
    fileAccess: await getMeta(db, "displayFileAccessLogClearedAt"),
  };
}

function filterDisplayCommands(commands, clearedAt) {
  const clearTime = Date.parse(clearedAt || "") || 0;
  if (clearTime <= 0) {
    return commands;
  }
  return commands.filter((command) => (
    command.status === "pending"
    || command.status === "running"
    || (Date.parse(command.updatedAt) || 0) > clearTime
  ));
}

function filterDisplayRequestLog(entries, clearedAt) {
  const clearTime = Date.parse(clearedAt || "") || 0;
  if (clearTime <= 0) {
    return entries;
  }
  return entries.filter((entry) => (Date.parse(entry.createdAt) || 0) > clearTime);
}

function filterDisplayFileAccess(requests, clearedAt) {
  const clearTime = Date.parse(clearedAt || "") || 0;
  if (clearTime <= 0) {
    return requests;
  }
  return requests.filter((request) => (
    request.status === "pending"
    || request.status === "running"
    || (Date.parse(request.updatedAt) || 0) > clearTime
  ));
}

async function hasActiveRelayWork(db, state) {
  if (state.running) {
    return true;
  }
  if (state.commands.some((command) => command.status === "pending" || command.status === "running")) {
    return true;
  }
  if (state.itemActions.some((action) => action.status === "pending" || action.status === "running")) {
    return true;
  }
  if (state.settingActions.some((action) => action.status === "pending" || action.status === "running")) {
    return true;
  }
  return hasActiveFileAccessWork(db);
}

async function hasActiveFileAccessWork(db) {
  const activeFileAccess = await loadFileAccessRequests(db, {
    statuses: ["pending", "running"],
    order: "created",
    limit: 1,
  });
  return activeFileAccess.length > 0;
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

async function clearDisplayLogs(db, env, state, scope = "all") {
  const clearedAt = new Date().toISOString();
  const shouldClearAll = scope === "all";
  const shouldClearCommands = shouldClearAll || scope === "command";
  const shouldClearRequestLog = shouldClearAll || scope === "requestLog";
  const shouldClearFileAccess = shouldClearAll || scope === "fileAccess";
  const [requestLog, fileAccessRows] = await Promise.all([
    shouldClearRequestLog ? loadRequestLog(db) : Promise.resolve([]),
    shouldClearFileAccess ? loadFileAccessRequests(db, { limit: MAX_FILE_ACCESS_REQUESTS }) : Promise.resolve([]),
  ]);
  const result = {
    clearedAt,
    commands: shouldClearCommands
      ? filterDisplayCommands(state.commands, "").filter((command) => command.status !== "pending" && command.status !== "running").length
      : 0,
    itemActions: 0,
    settingActions: 0,
    fileAccessRequests: shouldClearFileAccess
      ? fileAccessRows.filter((request) => request.status !== "pending" && request.status !== "running").length
      : 0,
    requestLogEntries: shouldClearRequestLog ? requestLog.length : 0,
  };
  const statements = [];
  if (shouldClearCommands) {
    statements.push(setMetaStatement(db, "displayCommandLogClearedAt", clearedAt));
  }
  if (shouldClearRequestLog) {
    statements.push(setMetaStatement(db, "displayRequestLogClearedAt", clearedAt));
  }
  if (shouldClearFileAccess) {
    statements.push(setMetaStatement(db, "displayFileAccessLogClearedAt", clearedAt));
  }
  if (statements.length > 0) {
    await db.batch(statements);
  }
  await touchRelayEvent(db, env, {
    reason: `logs-display:${scope}`,
    updatedAt: clearedAt,
  });
  return result;
}

async function clearRelayLogs(db, env, state, scope = "all") {
  const clearedAt = new Date().toISOString();
  const shouldClearAll = scope === "all";
  const shouldClearCommands = shouldClearAll || scope === "command";
  const shouldClearRequestLog = shouldClearAll || scope === "requestLog";
  const shouldClearFileAccess = shouldClearAll || scope === "fileAccess";
  const [fileAccessRows, requestLog] = await Promise.all([
    shouldClearFileAccess ? loadFileAccessRequests(db, { limit: MAX_FILE_ACCESS_REQUESTS }) : Promise.resolve([]),
    shouldClearRequestLog ? loadRequestLog(db) : Promise.resolve([]),
  ]);
  const fileAccessRowsToClear = shouldClearAll
    ? fileAccessRows.filter((request) => request.status !== "pending" && request.status !== "running")
    : fileAccessRows;
  for (const fileRequest of fileAccessRowsToClear) {
    if (!env?.RELAY_FILES || !fileRequest.objectKey) {
      continue;
    }
    try {
      await env.RELAY_FILES.delete(fileRequest.objectKey);
    } catch (error) {
      console.error("failed to delete file access object while clearing logs", fileRequest.objectKey, error);
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
      ? state.settingActions.filter((action) => action.status !== "pending" && action.status !== "running").length
      : 0,
    fileAccessRequests: fileAccessRowsToClear.length,
    requestLogEntries: requestLog.length,
  };

  const statements = [];
  if (shouldClearCommands) {
    statements.push(db.prepare("DELETE FROM commands WHERE status NOT IN ('pending', 'running')"));
  }
  if (shouldClearAll) {
    statements.push(
      db.prepare("DELETE FROM item_actions WHERE status NOT IN ('pending', 'running')"),
      setMetaStatement(
        db,
        "settingActions",
        JSON.stringify(state.settingActions.filter((action) => action.status === "pending" || action.status === "running"))
      )
    );
  }
  if (shouldClearFileAccess) {
    statements.push(shouldClearAll
      ? db.prepare("DELETE FROM file_access_requests WHERE status NOT IN ('pending', 'running')")
      : db.prepare("DELETE FROM file_access_requests"));
  }
  if (shouldClearRequestLog) {
    statements.push(setMetaStatement(db, "requestLog", "[]"));
  }
  if (statements.length > 0) {
    await db.batch(statements);
  }

  if (shouldClearCommands) {
    state.commands = state.commands.filter((command) => command.status === "pending" || command.status === "running");
    state.latestCommand = state.commands[0] || null;
    state.running = state.commands.some((command) => command.status === "running") || state.running && Boolean(state.latestCommand);
  }
  if (shouldClearAll) {
    state.itemActions = state.itemActions.filter((action) => action.status === "pending" || action.status === "running");
    state.settingActions = state.settingActions.filter((action) => action.status === "pending" || action.status === "running");
    state.message = "로그를 지웠습니다.";
    state.updatedAt = clearedAt;
    await saveMetaState(db, state, env);
  } else if (shouldClearCommands) {
    state.message = "최근 실행 요청 기록을 지웠습니다.";
    state.updatedAt = clearedAt;
    await saveMetaState(db, state, env);
  } else {
    await touchRelayEvent(db, env, {
      reason: `logs:${scope}`,
      updatedAt: clearedAt,
    });
  }
  return result;
}

function normalizeRequestLogEntry(request, raw = {}) {
  const url = request ? new URL(request.url) : null;
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
  const headerSource = request.headers.get("x-klms-client");
  if (headerSource) {
    return headerSource;
  }
  const userAgent = request.headers.get("user-agent") || "";
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

async function loadCancelRequest(db) {
  const cancelRequest = normalizeCancelRequest(parseJSON(await getMeta(db, "cancelRequest"), {}));
  if (!cancelRequest.requested) {
    await clearCancelRequest(db);
  }
  return cancelRequest;
}

async function setCancelRequest(db, cancelRequest) {
  await setMetaStatement(db, "cancelRequest", JSON.stringify(normalizeCancelRequest(cancelRequest))).run();
}

async function clearCancelRequest(db) {
  await setMetaStatement(db, "cancelRequest", JSON.stringify(normalizeCancelRequest({ requested: false }))).run();
}

async function trimItemActions(db) {
  await db.prepare(`
    DELETE FROM item_actions
    WHERE id NOT IN (
      SELECT id FROM item_actions ORDER BY updated_at DESC LIMIT ?
    )
  `).bind(MAX_ITEM_ACTIONS).run();
}

async function loadFileAccessRequests(db, { statuses = [], order = "updated", limit = MAX_FILE_ACCESS_REQUESTS } = {}) {
  const orderSQL = order === "created" ? "created_at ASC" : "updated_at DESC";
  let result;
  if (statuses.length > 0) {
    const placeholders = statuses.map(() => "?").join(", ");
    result = await db.prepare(`
      SELECT id, item_id, item_kind, item_title, status, created_at, updated_at, message,
             object_key, download_ticket, expires_at, content_type, size_bytes, download_count
      FROM file_access_requests
      WHERE status IN (${placeholders})
      ORDER BY ${orderSQL}
      LIMIT ?
    `).bind(...statuses, limit).all();
  } else {
    result = await db.prepare(`
      SELECT id, item_id, item_kind, item_title, status, created_at, updated_at, message,
             object_key, download_ticket, expires_at, content_type, size_bytes, download_count
      FROM file_access_requests
      ORDER BY ${orderSQL}
      LIMIT ?
    `).bind(limit).all();
  }
  return deduplicateByID((result.results || []).map(rowToFileAccessRequest), limit);
}

async function getFileAccessRequest(db, id) {
  const row = await db.prepare(`
    SELECT id, item_id, item_kind, item_title, status, created_at, updated_at, message,
           object_key, download_ticket, expires_at, content_type, size_bytes, download_count
    FROM file_access_requests
    WHERE id = ?
  `).bind(String(id || "").toLowerCase()).first();
  return row ? rowToFileAccessRequest(row) : null;
}

async function upsertFileAccessRequest(db, fileRequest) {
  await db.prepare(`
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
  `).bind(
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
  ).run();
  await trimFileAccessRequests(db);
}

async function trimFileAccessRequests(db) {
  await db.prepare(`
    DELETE FROM file_access_requests
    WHERE object_key IS NULL
      AND id NOT IN (
      SELECT id FROM file_access_requests ORDER BY updated_at DESC LIMIT ?
    )
  `).bind(MAX_FILE_ACCESS_REQUESTS).run();
}

async function expireStaleFileAccessRequests(db) {
  const now = Date.now();
  const rows = await loadFileAccessRequests(db, {
    statuses: ["pending", "running"],
    order: "created",
    limit: MAX_FILE_ACCESS_REQUESTS,
  });
  for (const fileRequest of rows) {
    if (ageMs(fileRequest.createdAt, now) <= STALE_PENDING_FILE_ACCESS_MS) {
      continue;
    }
    await upsertFileAccessRequest(db, {
      ...fileRequest,
      status: "macUnavailable",
      updatedAt: new Date().toISOString(),
      message: "Mac 앱이 제한 시간 안에 파일을 준비하지 않았습니다.",
    });
  }
}

async function cleanupExpiredFileAccess(db, env) {
  const nowISO = new Date().toISOString();
  const result = await db.prepare(`
    SELECT id, object_key
    FROM file_access_requests
    WHERE expires_at IS NOT NULL
      AND expires_at <= ?
  `).bind(nowISO).all();
  const rows = result.results || [];
  for (const row of rows) {
    if (env?.RELAY_FILES && row.object_key) {
      try {
        await env.RELAY_FILES.delete(row.object_key);
      } catch (error) {
        console.error("failed to delete expired file object", row.object_key, error);
      }
    }
  }
  if (rows.length > 0) {
    await db.prepare(`
      DELETE FROM file_access_requests
      WHERE expires_at IS NOT NULL
        AND expires_at <= ?
    `).bind(nowISO).run();
  }
}

async function uploadFileAccess(db, env, request, id) {
  if (!env?.RELAY_FILES) {
    return sendJSON(503, { error: "file relay storage is not configured" });
  }
  const current = await getFileAccessRequest(db, id);
  if (!current) {
    return sendJSON(404, { error: "file request not found" });
  }
  const limits = fileAccessLimits(env);
  const contentLength = Number.parseInt(request.headers.get("content-length") || "0", 10);
  if (!Number.isFinite(contentLength) || contentLength <= 0) {
    return sendJSON(411, { error: "content length is required for file uploads" });
  }
  if (contentLength > limits.maxUploadBytes) {
    return sendJSON(413, { error: `file too large; limit is ${limits.maxUploadBytes} bytes` });
  }
  const quota = await loadFileAccessQuota(db);
  if (quota.uploadCount >= limits.dailyUploads) {
    return sendJSON(429, { error: "daily file upload count limit reached" });
  }
  if (quota.uploadBytes + contentLength > limits.dailyUploadBytes) {
    return sendJSON(429, { error: "daily file upload byte limit reached" });
  }
  const filename = sanitizeFilename(
    decodeHeaderFilename(request.headers.get("x-klms-filename"))
      || current.itemTitle
      || "klms-file"
  );
  const contentType = (
    request.headers.get("content-type")
      || request.headers.get("x-klms-content-type")
      || "application/octet-stream"
  ).split(";")[0].trim() || "application/octet-stream";
  const objectKey = `file-access/${current.id}/${crypto.randomUUID()}-${filename}`;
  const ticket = randomToken();
  const expiresAt = new Date(Date.now() + limits.ttlMs).toISOString();
  const body = request.body ?? await request.arrayBuffer();

  await env.RELAY_FILES.put(objectKey, body, {
    httpMetadata: { contentType },
    customMetadata: {
      requestID: current.id,
      itemID: current.itemID,
      itemTitle: current.itemTitle,
    },
  });

  const updated = {
    ...current,
    status: "completed",
    updatedAt: new Date().toISOString(),
    message: "파일 링크 준비 완료",
    objectKey,
    downloadTicket: ticket,
    expiresAt,
    contentType,
    sizeBytes: contentLength,
    downloadCount: 0,
  };
  await upsertFileAccessRequest(db, updated);
  await touchRelayEvent(db, env, {
    reason: "file-access:completed",
    updatedAt: updated.updatedAt,
  });
  await appendRequestLog(db, request, {
    action: "파일 업로드 완료",
    status: "completed",
    message: filename,
    source: "Mac",
  });
  await saveFileAccessQuota(db, {
    ...quota,
    uploadCount: quota.uploadCount + 1,
    uploadBytes: quota.uploadBytes + contentLength,
  });
  return sendJSON(200, fileAccessResponseItem(updated, request, env));
}

async function downloadFileAccess(db, env, request, id) {
  const url = new URL(request.url);
  const ticket = url.searchParams.get("ticket") || "";
  const wantsPreview = url.searchParams.has("preview") && !url.searchParams.has("download");
  const wantsRawPreview = wantsPreview && url.searchParams.has("raw");
  const fileRequest = await getFileAccessRequest(db, id);
  if (!fileRequest || fileRequest.status !== "completed" || !fileRequest.objectKey || !fileRequest.downloadTicket) {
    return fileAccessDownloadPage({
      request,
      status: 404,
      title: "파일 링크를 찾을 수 없습니다",
      message: "요청한 파일 링크가 없거나 이미 정리되었습니다.",
    });
  }
  if (fileRequest.downloadTicket !== ticket) {
    return fileAccessDownloadPage({
      request,
      status: 401,
      title: "권한이 없는 링크입니다",
      message: "링크의 인증 정보가 맞지 않습니다. 앱에서 파일 링크를 다시 요청해 주세요.",
    });
  }
  if (fileRequest.expiresAt && Date.parse(fileRequest.expiresAt) <= Date.now()) {
    await cleanupExpiredFileAccess(db, env);
    return fileAccessDownloadPage({
      request,
      fileRequest,
      status: 410,
      title: "파일 링크가 만료되었습니다",
      message: "임시 파일은 만료 후 자동 삭제됩니다. 앱에서 파일 링크를 다시 요청해 주세요.",
    });
  }
  const limits = fileAccessLimits(env);
  if (Number(fileRequest.downloadCount || 0) >= limits.downloadsPerLink) {
    return fileAccessDownloadPage({
      request,
      fileRequest,
      status: 429,
      title: "다운로드 횟수를 모두 사용했습니다",
      message: "이 링크의 다운로드 가능 횟수를 초과했습니다. 앱에서 새 링크를 요청해 주세요.",
    });
  }
  const quota = await loadFileAccessQuota(db);
  if (quota.downloadCount >= limits.dailyDownloads) {
    return fileAccessDownloadPage({
      request,
      fileRequest,
      status: 429,
      title: "오늘 다운로드 한도에 도달했습니다",
      message: "과금 방지를 위해 오늘의 파일 다운로드 한도를 넘기지 않도록 막았습니다.",
    });
  }
  if (wantsPreview) {
    const preview = filePreviewDetails(fileRequest, limits.previewMaxBytes, limits.textPreviewMaxBytes);
    if (!preview.available) {
      return fileAccessDownloadPage({
        request,
        fileRequest,
        status: 415,
        title: "미리보기를 지원하지 않는 파일입니다",
        message: preview.message || "이 형식은 브라우저에서 바로 볼 수 없어 다운로드만 지원합니다.",
      });
    }
    if (!env?.RELAY_FILES) {
      return fileAccessDownloadPage({
        request,
        fileRequest,
        status: 503,
        title: "파일 저장소가 설정되지 않았습니다",
        message: "서버의 임시 파일 저장소 설정을 확인해 주세요.",
      });
    }
    if (!wantsRawPreview) {
      return fileAccessPreviewPage({
        request,
        fileRequest,
        preview,
        status: 200,
        title: "KLMS 파일 미리보기",
        message: "미리보기 화면입니다. 확대/축소와 페이지 이동을 사용할 수 있습니다.",
      });
    }
    const object = await env.RELAY_FILES.get(fileRequest.objectKey);
    if (!object) {
      return fileAccessDownloadPage({
        request,
        fileRequest,
        status: 404,
        title: "파일을 찾을 수 없습니다",
        message: "임시 저장소의 파일이 이미 정리되었습니다. 앱에서 파일 링크를 다시 요청해 주세요.",
      });
    }
    await upsertFileAccessRequest(db, {
      ...fileRequest,
      downloadCount: Number(fileRequest.downloadCount || 0) + 1,
      updatedAt: new Date().toISOString(),
    });
    await appendRequestLog(db, request, {
      action: "파일 미리보기",
      status: "completed",
      message: fileRequest.itemTitle || "파일",
      source: "웹",
      method: "GET",
      path: "/v1/file-access/:id/download?preview",
    });
    await saveFileAccessQuota(db, {
      ...quota,
      downloadCount: quota.downloadCount + 1,
    });
    await touchRelayEvent(db, env, {
      reason: "file-access:previewed",
      updatedAt: new Date().toISOString(),
    });
    return fileAccessObjectResponse(fileRequest, object, { disposition: "inline", preview });
  }
  if (!url.searchParams.has("download")) {
    return fileAccessDownloadPage({
      request,
      fileRequest,
      status: 200,
      title: "KLMS 파일 다운로드",
      message: "Mac이 준비한 임시 파일 링크입니다. 미리보기로 먼저 확인하거나 바로 다운로드하세요.",
      canDownload: true,
      previewMaxBytes: limits.previewMaxBytes,
      textPreviewMaxBytes: limits.textPreviewMaxBytes,
    });
  }
  if (!env?.RELAY_FILES) {
    return fileAccessDownloadPage({
      request,
      fileRequest,
      status: 503,
      title: "파일 저장소가 설정되지 않았습니다",
      message: "서버의 임시 파일 저장소 설정을 확인해 주세요.",
    });
  }
  const object = await env.RELAY_FILES.get(fileRequest.objectKey);
  if (!object) {
    return fileAccessDownloadPage({
      request,
      fileRequest,
      status: 404,
      title: "파일을 찾을 수 없습니다",
      message: "임시 저장소의 파일이 이미 정리되었습니다. 앱에서 파일 링크를 다시 요청해 주세요.",
    });
  }
  await upsertFileAccessRequest(db, {
    ...fileRequest,
    downloadCount: Number(fileRequest.downloadCount || 0) + 1,
    updatedAt: new Date().toISOString(),
  });
  await appendRequestLog(db, request, {
    action: "파일 다운로드",
    status: "completed",
    message: fileRequest.itemTitle || "파일",
    source: "웹",
    method: "GET",
    path: "/v1/file-access/:id/download",
  });
  await saveFileAccessQuota(db, {
    ...quota,
    downloadCount: quota.downloadCount + 1,
  });
  await touchRelayEvent(db, env, {
    reason: "file-access:downloaded",
    updatedAt: new Date().toISOString(),
  });
  return fileAccessObjectResponse(fileRequest, object, { disposition: "attachment" });
}

async function expireStaleRecords(db, state) {
  const now = Date.now();
  const commandUpdates = [];
  for (const command of state.commands) {
    if (command.status === "pending" && ageMs(command.createdAt, now) > STALE_PENDING_COMMAND_MS) {
      commandUpdates.push(markCommandUnavailable(command));
    } else if (command.status === "running" && !state.running && ageMs(command.updatedAt, now) > STALE_RUNNING_COMMAND_MS) {
      commandUpdates.push(markCommandUnavailable(command));
    }
  }
  const actionUpdates = [];
  for (const action of state.itemActions) {
    if (action.status === "pending" && ageMs(action.createdAt, now) > STALE_PENDING_ITEM_ACTION_MS) {
      actionUpdates.push({
        ...action,
        status: "macUnavailable",
        updatedAt: new Date().toISOString(),
        message: "Mac 앱이 제한 시간 안에 처리하지 않았습니다.",
      });
    }
  }
  const settingActionUpdates = [];
  for (const action of state.settingActions || []) {
    if (action.status === "pending" && ageMs(action.createdAt, now) > STALE_PENDING_SETTING_ACTION_MS) {
      settingActionUpdates.push({
        ...action,
        status: "macUnavailable",
        updatedAt: new Date().toISOString(),
        message: "Mac 앱이 제한 시간 안에 처리하지 않았습니다.",
      });
    }
  }
  if (commandUpdates.length === 0 && actionUpdates.length === 0 && settingActionUpdates.length === 0) {
    return false;
  }
  for (const command of commandUpdates) {
    await upsertCommand(db, command);
  }
  for (const action of actionUpdates) {
    await upsertItemAction(db, action);
  }
  for (const action of settingActionUpdates) {
    await upsertSettingAction(db, action);
  }
  return true;
}

function markCommandUnavailable(command) {
  return {
    ...command,
    status: "macUnavailable",
    updatedAt: new Date().toISOString(),
    summary: normalizeStatus(command.summary || defaultStatus, "macUnavailable"),
  };
}

function markCommandCancelled(command, message) {
  const summary = normalizeStatus(command.summary || defaultStatus, "cancelled");
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

async function cancelPendingCommandIfNeeded(db, state, cancelRequest, request, env) {
  const command = state.commands.find((item) => item.id === cancelRequest.commandID);
  if (!command || command.status !== "pending") {
    return null;
  }
  const message = "Mac이 처리하기 전에 원격 실행 요청을 취소했습니다.";
  const cancelled = markCommandCancelled(command, message);
  await upsertCommand(db, cancelled);
  state.commands = state.commands.map((item) => item.id === cancelled.id ? cancelled : item);
  await clearCancelRequest(db);
  await appendRequestLog(db, request, {
    action: "원격 실행 요청 취소",
    status: "cancelled",
    message,
  });
  state.latestCommand = cancelled;
  state.status = cancelled.summary;
  state.running = false;
  state.message = `${displayCommandName(cancelled.kind)} · ${displayStatus(cancelled.status)}`;
  state.updatedAt = cancelled.updatedAt;
  await saveMetaState(db, state, env, "commands:cancelled");
  return normalizeCancelRequest({
    requested: false,
    requestedAt: cancelRequest.requestedAt,
    commandID: cancelRequest.commandID,
    message,
  });
}

function commandListResponse(state, commands) {
  const latestCommand = commands.find((command) => command.id === state.latestCommand?.id) || commands[0] || null;
  return {
    commands,
    status: normalizeStatus(state.status, state.running ? "running" : undefined),
    latestCommand,
    running: Boolean(state.running),
  };
}

function itemActionListResponse(actions) {
  return { actions };
}

function settingActionListResponse(actions) {
  return { actions };
}

function fileAccessListResponse(requests, request, env) {
  return {
    requests: requests.map((fileRequest) => fileAccessResponseItem(fileRequest, request, env)),
  };
}

function fileAccessResponseItem(fileRequest, request, env) {
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
    response.downloadURL = downloadURLFor(fileRequest, request, env);
  }
  return response;
}

function fileAccessDownloadPage({
  request,
  fileRequest = null,
  status = 200,
  title = "KLMS 파일 다운로드",
  message = "",
  canDownload = false,
  previewMaxBytes = DEFAULT_FILE_PREVIEW_MAX_BYTES,
  textPreviewMaxBytes = DEFAULT_TEXT_FILE_PREVIEW_MAX_BYTES,
}) {
  const downloadURL = canDownload ? downloadActionURL(request) : "";
  const preview = canDownload ? filePreviewDetails(fileRequest, previewMaxBytes, textPreviewMaxBytes) : { available: false, kind: "", label: "", message: "" };
  const previewURL = preview.available ? previewActionURL(request) : "";
  const previewButton = canDownload ? filePreviewActionMarkup(preview, previewURL) : "";
  const previewHelp = canDownload
    ? `<p class="action-note">${escapeHTML(preview.available ? `${preview.label} 파일을 웹에서 바로 열어볼 수 있습니다.` : preview.message || "이 파일은 브라우저 미리보기를 지원하지 않습니다.")}</p>`
    : "";
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
    :root { color-scheme: light dark; --accent: #2563eb; --ok: #16a34a; --ink: #172033; --muted: #64748b; --panel: rgba(255,255,255,.86); --line: rgba(148,163,184,.35); }
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
    .actions { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; padding: 18px 28px 8px; }
    .button { text-align: center; text-decoration: none; border-radius: 12px; padding: 13px 16px; font-weight: 800; background: var(--accent); color: white; box-shadow: 0 10px 24px rgba(37,99,235,.26); }
    .button.secondary { background: rgba(100,116,139,.14); color: var(--ink); box-shadow: none; border: 1px solid var(--line); }
    .button.disabled { background: rgba(100,116,139,.10); color: var(--muted); box-shadow: none; border: 1px solid var(--line); cursor: not-allowed; }
    .action-note { padding: 0 28px 18px; font-size: 12px; color: var(--muted); }
    .note { padding: 0 28px 24px; font-size: 12px; color: var(--muted); }
    @media (prefers-color-scheme: dark) { :root { --ink: #e5e7eb; --muted: #a3aebf; --panel: rgba(15,23,42,.82); --line: rgba(148,163,184,.22); } body { background: radial-gradient(circle at 20% 0%, #1e3a8a 0, transparent 32%), linear-gradient(135deg, #020617, #111827 65%, #0f172a); } .file { background: rgba(15,23,42,.7); } .chip { background: rgba(148,163,184,.16); color: #cbd5e1; } .button.secondary { background: rgba(148,163,184,.16); color: var(--ink); } }
    @media (max-width: 640px) { body { padding: 14px; place-items: start center; } .top { padding: 22px 18px 14px; } .actions { grid-template-columns: 1fr; padding: 16px 18px 8px; } .action-note { padding: 0 18px 16px; } .note { padding: 0 18px 20px; } }
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
      </div>
      ${canDownload ? `<div class="actions">${previewButton}<a class="button secondary" href="${escapeHTML(downloadURL)}">파일 다운로드</a></div>${previewHelp}` : ""}
      <div class="note">이 링크는 임시 링크입니다. 만료되면 서버의 파일과 기록이 자동 정리됩니다.</div>
    </section>
  </main>
  <script>
    for (const el of document.querySelectorAll("[data-expires]")) {
      const d = new Date(el.dataset.expires);
      if (!Number.isNaN(d.getTime())) el.textContent = "만료 " + d.toLocaleString("ko-KR", { dateStyle: "medium", timeStyle: "short" });
    }
  </script>
</body>
</html>`;
  return new Response(html, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Content-Security-Policy": "default-src 'none'; img-src 'self'; media-src 'self'; frame-src 'self'; connect-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'",
      "Referrer-Policy": "no-referrer",
    },
  });
}

function downloadActionURL(request) {
  const url = new URL(request.url);
  url.searchParams.set("download", "1");
  url.searchParams.delete("preview");
  return url.toString();
}

function previewActionURL(request) {
  const url = new URL(request.url);
  url.searchParams.set("preview", "1");
  url.searchParams.delete("download");
  url.searchParams.delete("raw");
  return url.toString();
}

function rawPreviewActionURL(request) {
  const url = new URL(request.url);
  url.searchParams.set("preview", "1");
  url.searchParams.set("raw", "1");
  url.searchParams.delete("download");
  return url.toString();
}

function fileAccessObjectResponse(fileRequest, object, { disposition = "attachment", preview = null } = {}) {
  const headers = new Headers();
  headers.set("Cache-Control", "no-store");
  headers.set("Content-Type", effectiveFileContentType(fileRequest, object, { disposition, preview }));
  headers.set("Content-Disposition", contentDisposition(fileRequest.itemTitle || "KLMS file", disposition));
  if (Number.isFinite(Number(fileRequest.sizeBytes))) {
    headers.set("Content-Length", String(Number(fileRequest.sizeBytes)));
  }
  return new Response(object.body, { status: 200, headers });
}

function filePreviewActionMarkup(preview, previewURL) {
  if (preview.available) {
    const url = escapeHTML(previewURL);
    return `<a class="button" href="${url}">미리보기</a>`;
  }
  return `<span class="button disabled" aria-disabled="true">미리보기 불가</span>`;
}

function fileAccessPreviewPage({
  request,
  fileRequest,
  preview,
  status = 200,
  title = "KLMS 파일 미리보기",
  message = "",
}) {
  const rawURL = rawPreviewActionURL(request);
  const backURL = previewBackURL(request);
  const downloadURL = downloadActionURL(request);
  const filename = fileRequest?.itemTitle || "KLMS 파일";
  const sizeText = formatBytes(fileRequest?.sizeBytes);
  const expiresText = fileRequest?.expiresAt || "";
  const downloadCount = Number.isFinite(Number(fileRequest?.downloadCount)) ? Number(fileRequest.downloadCount) : 0;
  const viewerMarkup = filePreviewViewerMarkup(preview, rawURL);
  const isPDFPreview = preview?.kind === "pdf";
  const html = `<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHTML(title)}</title>
  <style>
    :root { color-scheme: light dark; --accent: #2563eb; --ink: #172033; --muted: #64748b; --panel: rgba(255,255,255,.9); --line: rgba(148,163,184,.35); --surface: rgba(248,250,252,.84); }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: var(--ink); background: radial-gradient(circle at 20% 0%, #dbeafe 0, transparent 30%), linear-gradient(135deg, #f8fafc, #eef2ff 55%, #ecfeff); }
    main { width: min(1160px, calc(100vw - 24px)); margin: 0 auto; padding: 18px 0 28px; }
    .shell { background: var(--panel); backdrop-filter: blur(16px); border: 1px solid var(--line); border-radius: 18px; box-shadow: 0 24px 60px rgba(15,23,42,.14); overflow: hidden; }
    .top { padding: 18px 20px 14px; border-bottom: 1px solid var(--line); }
    .badge { display: inline-flex; padding: 6px 10px; border-radius: 999px; background: rgba(37,99,235,.10); color: var(--accent); font-size: 12px; font-weight: 800; }
    h1 { margin: 12px 0 6px; font-size: clamp(22px, 4vw, 30px); line-height: 1.15; letter-spacing: 0; }
    p { margin: 0; color: var(--muted); line-height: 1.55; }
    .file { margin-top: 12px; padding: 12px; border: 1px solid var(--line); border-radius: 14px; background: var(--surface); }
    .filename { font-weight: 850; word-break: break-word; }
    .meta { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 9px; }
    .chip { padding: 6px 9px; border-radius: 999px; background: rgba(100,116,139,.11); color: #475569; font-size: 12px; font-weight: 700; }
    .toolbar { position: sticky; top: 0; z-index: 2; display: flex; flex-wrap: wrap; gap: 8px; align-items: center; padding: 12px 14px; border-bottom: 1px solid var(--line); background: rgba(248,250,252,.94); backdrop-filter: blur(14px); }
    .tool-group { display: inline-flex; gap: 6px; align-items: center; padding: 4px; border: 1px solid var(--line); border-radius: 12px; background: rgba(255,255,255,.72); }
    button, .button { min-height: 34px; border: 0; border-radius: 9px; padding: 0 11px; background: rgba(100,116,139,.12); color: var(--ink); font: inherit; font-weight: 800; text-decoration: none; cursor: pointer; display: inline-flex; align-items: center; justify-content: center; }
    button.primary, .button.primary { background: var(--accent); color: white; box-shadow: 0 10px 22px rgba(37,99,235,.22); }
    button:disabled { color: var(--muted); cursor: not-allowed; opacity: .55; }
    .status { margin-left: auto; color: var(--muted); font-size: 13px; font-weight: 750; }
    .viewer { min-height: min(74vh, 760px); background: rgba(15,23,42,.05); }
    .pdf-frame { width: 100%; height: min(74vh, 760px); border: 0; background: white; display: block; }
    .image-stage { height: min(74vh, 760px); overflow: auto; display: grid; place-items: start center; padding: 18px; background: #0f172a; }
    .image-stage img { max-width: 100%; transform-origin: top center; transition: transform .12s ease; border-radius: 8px; background: white; box-shadow: 0 16px 40px rgba(0,0,0,.28); }
    .text-stage { height: min(74vh, 760px); overflow: auto; background: #fff; color: #111827; }
    .text-page { min-height: 100%; margin: 0; padding: 20px; white-space: pre-wrap; word-break: break-word; font: 15px/1.6 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
    .media-stage { min-height: min(74vh, 760px); display: grid; place-items: center; padding: 24px; background: rgba(15,23,42,.08); }
    .media-stage video, .media-stage audio { width: min(100%, 920px); }
    .empty { padding: 24px; color: var(--muted); }
    .note { padding: 12px 18px 18px; color: var(--muted); font-size: 12px; }
    @media (prefers-color-scheme: dark) { :root { --ink: #e5e7eb; --muted: #a3aebf; --panel: rgba(15,23,42,.86); --line: rgba(148,163,184,.22); --surface: rgba(15,23,42,.72); } body { background: radial-gradient(circle at 20% 0%, #1e3a8a 0, transparent 32%), linear-gradient(135deg, #020617, #111827 65%, #0f172a); } .chip { background: rgba(148,163,184,.16); color: #cbd5e1; } .toolbar { background: rgba(15,23,42,.92); } .tool-group { background: rgba(15,23,42,.74); } .text-stage { background: #111827; color: #e5e7eb; } }
    @media (max-width: 700px) { main { width: 100%; padding: 0; } .shell { border-radius: 0; min-height: 100vh; } .top { padding: 14px; } .toolbar { gap: 7px; padding: 10px; } .tool-group { flex: 1 1 auto; } button, .button { flex: 1 1 auto; padding: 0 9px; } .status { width: 100%; margin-left: 0; text-align: center; } .viewer, .pdf-frame, .image-stage, .text-stage { height: calc(100vh - 270px); min-height: 420px; } }
  </style>
</head>
<body>
  <main data-kind="${escapeHTML(preview.kind)}" data-raw-url="${escapeHTML(rawURL)}">
    <section class="shell">
      <div class="top">
        <div class="badge">${status === 200 ? "미리보기" : "확인 필요"}</div>
        <h1>${escapeHTML(title)}</h1>
        <p>${escapeHTML(message)}</p>
        <div class="file"><div class="filename">${escapeHTML(filename)}</div><div class="meta">${sizeText ? `<span class="chip">${escapeHTML(sizeText)}</span>` : ""}${expiresText ? `<span class="chip" data-expires="${escapeHTML(expiresText)}">만료 ${escapeHTML(expiresText)}</span>` : ""}<span class="chip">형식 ${escapeHTML(preview.label)}</span><span class="chip" data-download-count="${downloadCount}">열람/다운로드 ${downloadCount}회</span></div></div>
      </div>
      <div class="toolbar">
        <a class="button" href="${escapeHTML(backURL)}">뒤로</a>
        ${isPDFPreview ? "" : `<div class="tool-group">
          <button type="button" data-action="prev">이전</button>
          <button type="button" data-action="next">다음</button>
        </div>
        <div class="tool-group">
          <button type="button" data-action="zoom-out">축소</button>
          <button type="button" data-action="fit">맞춤</button>
          <button type="button" data-action="zoom-in">확대</button>
        </div>`}
        <a class="button primary" href="${escapeHTML(downloadURL)}">다운로드</a>
        ${isPDFPreview ? `<div class="status">PDF 쪽수/배율은 아래 뷰어 안쪽 표시가 실제 상태입니다.</div>` : `<div class="status" data-status>1 / 1 · 100%</div>`}
      </div>
      <div class="viewer">${viewerMarkup}</div>
      <div class="note">${isPDFPreview ? "PDF는 브라우저 내장 뷰어가 현재 쪽수와 배율을 실시간으로 표시합니다. 바깥 화면은 다운로드와 파일 정보만 담당합니다." : "텍스트와 이미지는 위 도구막대로 페이지 이동과 확대/축소를 조절할 수 있습니다."}</div>
    </section>
  </main>
  <script>
    const root = document.querySelector("main");
    const kind = root.dataset.kind;
    const rawURL = root.dataset.rawUrl;
    const status = document.querySelector("[data-status]");
    const usageChip = document.querySelector("[data-download-count]");
    let usageBumped = false;
    let page = 1;
    let zoom = 1;
    let pages = [""];
    const bumpUsage = () => {
      if (!usageChip || usageBumped) return;
      usageBumped = true;
      const current = Number.parseInt(usageChip.dataset.downloadCount || "0", 10);
      const next = Number.isFinite(current) ? current + 1 : 1;
      usageChip.dataset.downloadCount = String(next);
      usageChip.textContent = "열람/다운로드 " + next + "회";
    };
    const setStatus = () => {
      if (!status) return;
      if (kind === "pdf") {
        status.textContent = "PDF " + page + "쪽 · " + Math.round(zoom * 100) + "%";
        return;
      }
      const max = Math.max(1, pages.length);
      status.textContent = page + " / " + max + " · " + Math.round(zoom * 100) + "%";
    };
    const boundedPage = (value) => kind === "pdf" ? Math.max(1, value) : Math.min(Math.max(1, value), Math.max(1, pages.length));
    const pdfURL = () => rawURL + "#page=" + page + "&zoom=" + Math.round(zoom * 100);
    const render = () => {
      page = boundedPage(page);
      if (kind === "text") {
        const pre = document.querySelector("[data-text-page]");
        if (pre) {
          pre.textContent = pages[page - 1] || "";
          pre.style.fontSize = Math.max(10, Math.round(15 * zoom)) + "px";
        }
      } else if (kind === "image") {
        const img = document.querySelector("[data-image-preview]");
        if (img) img.style.transform = "scale(" + zoom + ")";
      } else if (kind === "pdf") {
        const frame = document.querySelector("[data-pdf-preview]");
        if (frame) frame.src = pdfURL();
      }
      setStatus();
    };
    const splitTextPages = (text) => {
      const target = 3600;
      const chunks = [];
      let current = "";
      for (const line of String(text || "").split("\\n")) {
        if (current.length + line.length + 1 > target && current) {
          chunks.push(current);
          current = "";
        }
        current += (current ? "\\n" : "") + line;
      }
      if (current || chunks.length === 0) chunks.push(current);
      return chunks;
    };
    if (kind === "text") {
      fetch(rawURL, { cache: "no-store" })
        .then((res) => {
          if (!res.ok) return Promise.reject(new Error("preview failed"));
          bumpUsage();
          return res.text();
        })
        .then((text) => { pages = splitTextPages(text); page = 1; render(); })
        .catch(() => { pages = ["미리보기를 불러오지 못했습니다. 다운로드해서 확인해 주세요."]; render(); });
    } else {
      pages = [""];
      render();
      const resource = document.querySelector("[data-image-preview], [data-pdf-preview], video, audio");
      if (resource) {
        resource.addEventListener("load", bumpUsage, { once: true });
        resource.addEventListener("loadedmetadata", bumpUsage, { once: true });
        if (resource.tagName === "IMG" && resource.complete && resource.naturalWidth > 0) bumpUsage();
      }
    }
    const bindAction = (name, handler) => {
      const button = document.querySelector("[data-action='" + name + "']");
      if (button) button.addEventListener("click", handler);
    };
    bindAction("prev", () => { page -= 1; render(); });
    bindAction("next", () => { page += 1; render(); });
    bindAction("zoom-out", () => { zoom = Math.max(.35, +(zoom - .15).toFixed(2)); render(); });
    bindAction("zoom-in", () => { zoom = Math.min(3, +(zoom + .15).toFixed(2)); render(); });
    bindAction("fit", () => { zoom = 1; render(); });
    for (const el of document.querySelectorAll("[data-expires]")) {
      const d = new Date(el.dataset.expires);
      if (!Number.isNaN(d.getTime())) el.textContent = "만료 " + d.toLocaleString("ko-KR", { dateStyle: "medium", timeStyle: "short" });
    }
  </script>
</body>
</html>`;
  return new Response(html, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Content-Security-Policy": "default-src 'none'; img-src 'self'; media-src 'self'; frame-src 'self'; connect-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'",
      "Referrer-Policy": "no-referrer",
    },
  });
}

function previewBackURL(request) {
  const url = new URL(request.url);
  url.searchParams.delete("preview");
  url.searchParams.delete("raw");
  url.searchParams.delete("download");
  return url.toString();
}

function filePreviewViewerMarkup(preview, rawURL) {
  const url = escapeHTML(rawURL);
  if (preview.kind === "image") {
    return `<div class="image-stage"><img data-image-preview src="${url}" alt="파일 미리보기"></div>`;
  }
  if (preview.kind === "text") {
    return `<div class="text-stage"><pre class="text-page" data-text-page>미리보기를 불러오는 중입니다.</pre></div>`;
  }
  if (preview.kind === "audio") {
    return `<div class="media-stage"><audio controls src="${url}"></audio></div>`;
  }
  if (preview.kind === "video") {
    return `<div class="media-stage"><video controls src="${url}"></video></div>`;
  }
  if (preview.kind === "pdf") {
    return `<iframe class="pdf-frame" data-pdf-preview title="파일 미리보기" src="${url}#page=1&zoom=100"></iframe>`;
  }
  return `<div class="empty">이 파일은 웹 미리보기를 지원하지 않습니다. 다운로드해서 확인해 주세요.</div>`;
}

function relayResponse(state) {
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

function normalizeFileAccessRequest(raw, fallbackStatus) {
  const now = new Date().toISOString();
  const id = String(raw.id || crypto.randomUUID()).toLowerCase();
  return {
    id,
    itemID: String(raw.itemID || raw.itemId || "").trim(),
    itemKind: String(raw.itemKind || "file").trim(),
    itemTitle: String(raw.itemTitle || "").trim(),
    status: String(raw.status || fallbackStatus),
    createdAt: raw.createdAt || now,
    updatedAt: raw.updatedAt || now,
    message: String(raw.message || ""),
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

function normalizeSettingAction(raw, fallbackStatus) {
  const now = new Date().toISOString();
  const id = String(raw?.id || crypto.randomUUID()).toLowerCase();
  return {
    id,
    key: sanitizeSettingKey(raw?.key),
    value: sanitizePublicText(raw?.value),
    title: sanitizePublicText(raw?.title),
    status: String(raw?.status || fallbackStatus),
    createdAt: raw?.createdAt || raw?.created_at || now,
    updatedAt: raw?.updatedAt || raw?.updated_at || now,
    message: sanitizePublicText(raw?.message),
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
  status.phaseDetail = sanitizePublicText(status.phaseDetail) || null;
  status.loginRequired = Boolean(status.loginRequired);
  status.authDigits = status.authDigits == null ? null : String(status.authDigits);
  status.authStatusMessage = status.authStatusMessage == null ? null : String(status.authStatusMessage);
  return status;
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

function sanitizeLogText(value) {
  let text = String(value || "").trim();
  if (!text) {
    return "";
  }
  text = text
    .replace(/KAIST 인증 번호:\s*\d{1,3}/g, "KAIST 인증 번호: --")
    .replace(/digits=\d{1,3}/g, "digits=--")
    .replace(/https?:\/\/klms\.kaist\.ac\.kr\/[^\s"'<>]+/gi, "[KLMS URL]")
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, "[email]");
  const lines = text
    .split(/\r?\n/)
    .map((line) => line.trimEnd())
    .filter((line) => !looksPrivateLogLine(line));
  const joined = lines.join("\n");
  if (joined.length <= MAX_SHARED_RUN_LOG_CHARS) {
    return joined;
  }
  return `...\n${joined.slice(-MAX_SHARED_RUN_LOG_CHARS)}`;
}

function looksPrivateLogLine(text) {
  if (/\/Users\//i.test(text) || /\/var\/folders\//i.test(text)) {
    return true;
  }
  if (/(주소|address)/i.test(text)) {
    return true;
  }
  if (/[가-힣A-Za-z0-9_.-]+(로|길)\s*\d{1,4}(\s*-\s*\d{1,4})?/.test(text)) {
    return true;
  }
  return false;
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

async function replaceSyncItems(db, items, generatedAt, extras = {}) {
  const now = new Date().toISOString();
  const runLogsClearedAt = await getMeta(db, "syncDataRunLogsClearedAt");
  const runLogs = normalizeRunLogs(extras.runLogs, runLogsClearedAt);
  await db.batch([
    setMetaStatement(db, "syncDataItems", JSON.stringify(items.slice(0, MAX_SYNC_ITEMS))),
    setMetaStatement(db, "syncDataDryRunReports", JSON.stringify(extras.dryRunReports || [])),
    setMetaStatement(db, "syncDataCalendarChanges", JSON.stringify(extras.calendarChanges || [])),
    setMetaStatement(db, "syncDataSettings", JSON.stringify(extras.settings || [])),
    setMetaStatement(db, "syncDataRunLogs", JSON.stringify(runLogs)),
    setMetaStatement(db, "syncDataVerifySummary", JSON.stringify(extras.verifySummary || null)),
    setMetaStatement(db, "syncDataGeneratedAt", String(generatedAt || now)),
    setMetaStatement(db, "syncDataUpdatedAt", now),
  ]);
}

async function syncDataResponse(db, { kind = "", limit = 250 } = {}) {
  const items = parseJSON(await getMeta(db, "syncDataItems"), []);
  const dryRunReports = parseJSON(await getMeta(db, "syncDataDryRunReports"), []);
  const calendarChanges = parseJSON(await getMeta(db, "syncDataCalendarChanges"), []);
  const settings = parseJSON(await getMeta(db, "syncDataSettings"), []);
  const sharedSettings = await loadSharedSettings(db);
  const runLogs = parseJSON(await getMeta(db, "syncDataRunLogs"), []);
  const verifySummary = parseJSON(await getMeta(db, "syncDataVerifySummary"), null);
  const runLogsClearedAt = await getMeta(db, "syncDataRunLogsClearedAt");
  const trimmedKind = String(kind || "").trim();
  const filtered = (Array.isArray(items) ? items : [])
    .map(normalizeSyncItem)
    .filter(Boolean)
    .filter((item) => !trimmedKind || item.kind === trimmedKind)
    .sort(compareSyncItems)
    .slice(0, limit);
  return {
    generatedAt: await getMeta(db, "syncDataGeneratedAt") || "",
    updatedAt: await getMeta(db, "syncDataUpdatedAt") || "",
    items: filtered,
    dryRunReports: normalizeDryRunReports(dryRunReports),
    calendarChanges: normalizeCalendarChanges(calendarChanges),
    settings: normalizeSettings(settings),
    sharedSettings,
    runLogs: normalizeRunLogs(runLogs, runLogsClearedAt),
    verifySummary: normalizeVerifySummary(verifySummary),
  };
}

async function sharedSettingsResponse(db) {
  return {
    settings: await loadSharedSettings(db),
  };
}

async function loadSharedSettings(db) {
  const stored = normalizeSettings(parseJSON(await getMeta(db, "sharedSettings"), []));
  return normalizedSharedSettings(stored);
}

async function updateSharedSetting(db, env, key, body, request) {
  const setting = normalizeSharedSettingInput(key, body);
  if (!setting) {
    return null;
  }
  const current = await loadSharedSettings(db);
  const next = normalizedSharedSettings([
    ...current.filter((item) => item.key !== setting.key),
    setting,
  ]);
  await db.batch([
    setMetaStatement(db, "sharedSettings", JSON.stringify(next)),
    setMetaStatement(db, "updatedAt", setting.updatedAt),
  ]);
  await appendRequestLog(db, request, {
    action: `${setting.title} 변경`,
    status: "updated",
    message: "서버 공유 설정을 바로 저장했습니다.",
  });
  await touchRelayEvent(db, env, {
    reason: "shared-settings",
    updatedAt: setting.updatedAt,
  });
  return setting;
}

function normalizedSharedSettings(stored) {
  const storedByKey = new Map(normalizeSettings(stored).map((setting) => [setting.key, setting]));
  return SHARED_SETTING_DEFINITIONS.map((definition) => {
    const storedSetting = storedByKey.get(definition.key);
    const value = normalizeSharedSettingValue(definition, storedSetting?.value ?? definition.value);
    return {
      key: definition.key,
      title: definition.title,
      value,
      valueKind: definition.valueKind,
      options: definition.options,
      editable: true,
      updatedAt: storedSetting?.updatedAt || "",
    };
  });
}

function normalizeSharedSettingInput(key, body) {
  const normalizedKey = sanitizeSettingKey(key || body?.key);
  const definition = SHARED_SETTING_DEFINITIONS.find((item) => item.key === normalizedKey);
  if (!definition) {
    return null;
  }
  return {
    key: definition.key,
    title: definition.title,
    value: normalizeSharedSettingValue(definition, body?.value),
    valueKind: definition.valueKind,
    options: definition.options,
    editable: true,
    updatedAt: new Date().toISOString(),
  };
}

function normalizeSharedSettingValue(definition, value) {
  if (definition.valueKind === "bool") {
    return normalizeBoolean(value) ? "1" : "0";
  }
  const text = sanitizePublicText(value) || definition.value;
  if (definition.valueKind === "choice") {
    return definition.options.includes(text) ? text : definition.value;
  }
  return text;
}

async function clearSharedRunLogs(db, env) {
  const clearedAt = new Date().toISOString();
  const previous = normalizeRunLogs(parseJSON(await getMeta(db, "syncDataRunLogs"), []));
  await db.batch([
    setMetaStatement(db, "syncDataRunLogs", "[]"),
    setMetaStatement(db, "syncDataRunLogsClearedAt", clearedAt),
    setMetaStatement(db, "syncDataUpdatedAt", clearedAt),
  ]);
  await touchRelayEvent(db, env, {
    reason: "sync-data:run-logs-clear",
    updatedAt: clearedAt,
  });
  return {
    clearedAt,
    runLogs: previous.length,
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

function normalizeVerifySummary(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  return {
    status: sanitizePublicText(raw.status) || "missing",
    updatedAt: sanitizePublicText(raw.updatedAt || raw.updated_at) || "",
    checks: Array.isArray(raw.checks)
      ? raw.checks.map(normalizeVerifyCheck).filter(Boolean).slice(0, 80)
      : [],
  };
}

function normalizeVerifyCheck(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  const name = sanitizePublicText(raw.name);
  if (!name) {
    return null;
  }
  return {
    name,
    status: sanitizePublicText(raw.status) || "missing",
    detail: sanitizePublicText(raw.detail || raw.message),
  };
}

function normalizeRunLogs(raw, clearedAt = "") {
  if (!Array.isArray(raw)) {
    return [];
  }
  const clearedTime = Date.parse(clearedAt || "") || 0;
  return raw
    .slice(0, MAX_SHARED_RUN_LOGS * 2)
    .map((log) => {
      const now = new Date().toISOString();
      const startedAt = sanitizePublicText(log?.startedAt || log?.started_at) || now;
      const finishedAt = sanitizePublicText(log?.finishedAt || log?.finished_at) || startedAt;
      const updatedAt = sanitizePublicText(log?.updatedAt || log?.updated_at) || finishedAt;
      const finishedTime = Date.parse(finishedAt) || Date.parse(updatedAt) || 0;
      if (clearedTime > 0 && finishedTime <= clearedTime) {
        return null;
      }
      return {
        id: normalizeUUIDText(log?.id) || crypto.randomUUID(),
        command: sanitizePublicText(log?.command),
        commandTitle: sanitizePublicText(log?.commandTitle || log?.command_title) || "동기화",
        status: sanitizePublicText(log?.status) || "기록됨",
        startedAt,
        finishedAt,
        updatedAt,
        duration: sanitizePublicText(log?.duration),
        exitCode: boundedInt(log?.exitCode ?? log?.exit_code, 0, -999, 999),
        dryRun: normalizeBoolean(log?.dryRun ?? log?.dry_run),
        wasCancelled: normalizeBoolean(log?.wasCancelled ?? log?.was_cancelled),
        needsAttention: normalizeBoolean(log?.needsAttention ?? log?.needs_attention),
        outputTail: sanitizeLogText(log?.outputTail || log?.output_tail),
      };
    })
    .filter(Boolean)
    .sort((lhs, rhs) => Date.parse(rhs.finishedAt) - Date.parse(lhs.finishedAt))
    .slice(0, MAX_SHARED_RUN_LOGS);
}

function sanitizeSettingKey(value) {
  const key = String(value || "").trim();
  return /^[A-Z][A-Z0-9_]*$/.test(key) ? key : "";
}

function sanitizeSettingValueKind(value) {
  const kind = String(value || "text");
  return ["bool", "number", "text", "choice"].includes(kind) ? kind : "text";
}

function compareSyncItems(lhs, rhs) {
  const updatedDelta = Date.parse(rhs.updatedAt || "") - Date.parse(lhs.updatedAt || "");
  if (Number.isFinite(updatedDelta) && updatedDelta !== 0) {
    return updatedDelta;
  }
  const timestampDelta = String(rhs.timestamp || "").localeCompare(String(lhs.timestamp || ""));
  if (timestampDelta !== 0) {
    return timestampDelta;
  }
  const courseDelta = String(lhs.course || "").localeCompare(String(rhs.course || ""), "ko");
  if (courseDelta !== 0) {
    return courseDelta;
  }
  return String(lhs.title || "").localeCompare(String(rhs.title || ""), "ko");
}

function commandBlocksNewRequest(command, running) {
  if (command.status === "pending") {
    return true;
  }
  return command.status === "running" && running;
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

function ageMs(timestamp, now) {
  const parsed = Date.parse(timestamp || "");
  if (!Number.isFinite(parsed)) {
    return Number.POSITIVE_INFINITY;
  }
  return now - parsed;
}

function boundedInt(value, fallback, min, max) {
  const parsed = Number.parseInt(String(value || ""), 10);
  if (!Number.isInteger(parsed)) {
    return fallback;
  }
  return Math.max(min, Math.min(max, parsed));
}

function fileAccessLimits(env) {
  return {
    maxUploadBytes: boundedInt(env?.FILE_RELAY_MAX_UPLOAD_BYTES, DEFAULT_MAX_FILE_UPLOAD_BYTES, 1, 100 * 1024 * 1024),
    dailyUploads: boundedInt(env?.FILE_RELAY_DAILY_UPLOADS, DEFAULT_DAILY_FILE_UPLOADS, 1, 1_000),
    dailyUploadBytes: boundedInt(env?.FILE_RELAY_DAILY_UPLOAD_BYTES, DEFAULT_DAILY_FILE_UPLOAD_BYTES, 1, 10 * 1024 * 1024 * 1024),
    dailyDownloads: boundedInt(env?.FILE_RELAY_DAILY_DOWNLOADS, DEFAULT_DAILY_FILE_DOWNLOADS, 1, 100_000),
    downloadsPerLink: boundedInt(env?.FILE_RELAY_DOWNLOADS_PER_LINK, DEFAULT_FILE_DOWNLOADS_PER_LINK, 1, 100),
    previewMaxBytes: boundedInt(env?.FILE_RELAY_PREVIEW_MAX_BYTES, DEFAULT_FILE_PREVIEW_MAX_BYTES, 1, 100 * 1024 * 1024),
    textPreviewMaxBytes: boundedInt(env?.FILE_RELAY_TEXT_PREVIEW_MAX_BYTES, DEFAULT_TEXT_FILE_PREVIEW_MAX_BYTES, 1, 5 * 1024 * 1024),
    ttlMs: boundedInt(env?.FILE_RELAY_TTL_SECONDS, DEFAULT_FILE_ACCESS_TTL_MS / 1000, 60, 60 * 60) * 1000,
    maxPendingRequests: boundedInt(env?.FILE_RELAY_MAX_PENDING_REQUESTS, 20, 1, MAX_FILE_ACCESS_REQUESTS),
  };
}

function publicFileAccessLimits(env) {
  const limits = fileAccessLimits(env);
  return {
    maxUploadBytes: limits.maxUploadBytes,
    dailyUploads: limits.dailyUploads,
    dailyUploadBytes: limits.dailyUploadBytes,
    dailyDownloads: limits.dailyDownloads,
    downloadsPerLink: limits.downloadsPerLink,
    previewMaxBytes: limits.previewMaxBytes,
    textPreviewMaxBytes: limits.textPreviewMaxBytes,
    ttlSeconds: Math.floor(limits.ttlMs / 1000),
    maxPendingRequests: limits.maxPendingRequests,
  };
}

function quotaKeyForToday(now = new Date()) {
  return `fileAccessQuota:${now.toISOString().slice(0, 10)}`;
}

async function loadFileAccessQuota(db) {
  const key = quotaKeyForToday();
  const raw = parseJSON(await getMeta(db, key), {});
  return {
    key,
    uploadCount: Number.isFinite(Number(raw.uploadCount)) ? Number(raw.uploadCount) : 0,
    uploadBytes: Number.isFinite(Number(raw.uploadBytes)) ? Number(raw.uploadBytes) : 0,
    downloadCount: Number.isFinite(Number(raw.downloadCount)) ? Number(raw.downloadCount) : 0,
  };
}

async function saveFileAccessQuota(db, quota) {
  await setMetaStatement(db, quota.key || quotaKeyForToday(), JSON.stringify({
    uploadCount: Number(quota.uploadCount || 0),
    uploadBytes: Number(quota.uploadBytes || 0),
    downloadCount: Number(quota.downloadCount || 0),
    updatedAt: new Date().toISOString(),
  })).run();
}

function downloadURLFor(fileRequest, request, env) {
  const url = new URL(request.url);
  url.pathname = prefixedPath(
    `/v1/file-access/${fileRequest.id}/download`,
    env,
    new URL(request.url).pathname
  );
  url.search = "";
  url.searchParams.set("ticket", fileRequest.downloadTicket);
  return url.toString();
}

function prefixedPath(target, env, currentPath) {
  const configuredPrefix = String(env?.RELAY_PATH_PREFIX || "").trim();
  const prefixes = [configuredPrefix, "/relay"]
    .map((prefix) => `/${String(prefix).split("/").filter(Boolean).join("/")}`)
    .filter((prefix) => prefix !== "/");
  for (const prefix of prefixes) {
    if (currentPath === prefix || currentPath.startsWith(`${prefix}/`)) {
      return `${prefix}${target}`;
    }
  }
  return target;
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

function effectiveFileContentType(fileRequest, object = null, { disposition = "attachment", preview = null } = {}) {
  if (disposition === "inline" && preview?.contentType) {
    return preview.contentType;
  }
  const stored = String(fileRequest?.contentType || object?.httpMetadata?.contentType || "")
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
    .replace(/\*/g, "%2A");
}

function randomToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes).map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function readJSON(request) {
  const length = Number.parseInt(request.headers.get("content-length") || "0", 10);
  if (Number.isFinite(length) && length > MAX_BODY_BYTES) {
    throw new Error("request body too large");
  }
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > MAX_BODY_BYTES) {
    throw new Error("request body too large");
  }
  if (!text.trim()) {
    return {};
  }
  return JSON.parse(text);
}

function sendJSON(statusCode, value) {
  return new Response(JSON.stringify(value), {
    status: statusCode,
    headers: baseHeaders(),
  });
}

function baseHeaders() {
  return {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, PUT, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type, Accept, X-KLMS-Filename, X-KLMS-Content-Type",
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
    case "fileTrash":
      return "파일 휴지통";
    case "calendarVerify":
      return "캘린더 상태 확인";
    case "calendarApply":
      return "KLMS 기준 반영";
    case "calendarCreate":
      return "캘린더 일정 등록";
    case "calendarEdit":
      return "캘린더 내용 수정";
    case "calendarDelete":
      return "캘린더 일정 삭제";
    case "mailDashboardAdd":
      return "메일 항목 반영";
    case "mailDashboardRemove":
      return "메일 항목 제거";
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
