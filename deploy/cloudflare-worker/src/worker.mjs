const MAX_BODY_BYTES = 1024 * 1024;
const MAX_COMMANDS = 100;
const MAX_ITEM_ACTIONS = 200;
const MAX_SYNC_ITEMS = 2000;
const STALE_PENDING_COMMAND_MS = 60 * 60 * 1000;
const STALE_RUNNING_COMMAND_MS = 2 * 60 * 1000;
const STALE_PENDING_ITEM_ACTION_MS = 60 * 60 * 1000;

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

let schemaReady = false;

export default {
  async fetch(request, env) {
    try {
      return await route(request, env);
    } catch (error) {
      console.error(error);
      return sendJSON(500, { error: "server error" });
    }
  },
};

async function route(request, env) {
  const db = database(env);
  const url = new URL(request.url);
  const pathname = normalizedPath(url.pathname, env);

  if (request.method === "GET" && pathname === "/healthz") {
    return sendJSON(200, {
      ok: true,
      storage: "cloudflare-d1",
      configured: Boolean(relayToken(env)),
    });
  }

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: baseHeaders() });
  }

  if (!pathname.startsWith("/v1/")) {
    return sendJSON(404, { error: "not found" });
  }
  if (!(await authorized(request, env))) {
    return sendJSON(401, { error: "unauthorized" });
  }

  await ensureSchema(db);
  let state = await loadState(db);
  if (await expireStaleRecords(db, state)) {
    state = await loadState(db);
  }

  if (request.method === "GET" && pathname === "/v1/status") {
    return sendJSON(200, relayResponse(state));
  }

  if (request.method === "POST" && pathname === "/v1/status") {
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
    await saveMetaState(db, state);
    return sendJSON(200, relayResponse(state));
  }

  if (request.method === "GET" && pathname === "/v1/sync-data") {
    const kind = (url.searchParams.get("kind") || "").trim();
    const limit = boundedInt(url.searchParams.get("limit"), 250, 1, MAX_SYNC_ITEMS);
    return sendJSON(200, await syncDataResponse(db, { kind, limit }));
  }

  if (request.method === "POST" && pathname === "/v1/sync-data") {
    const body = await readJSON(request);
    const items = Array.isArray(body.items)
      ? body.items.map(normalizeSyncItem).filter(Boolean).slice(0, MAX_SYNC_ITEMS)
      : [];
    await replaceSyncItems(db, items, body.generatedAt);
    return sendJSON(200, await syncDataResponse(db, { limit: MAX_SYNC_ITEMS }));
  }

  if (request.method === "POST" && pathname === "/v1/commands") {
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
    state.latestCommand = command;
    state.status = command.summary;
    state.running = false;
    state.message = `${displayCommandName(command.kind)} 요청 대기 중`;
    state.updatedAt = new Date().toISOString();
    await saveMetaState(db, state);
    return sendJSON(201, command);
  }

  if (request.method === "GET" && pathname === "/v1/commands/pending") {
    return sendJSON(200, commandListResponse(state, state.commands
      .filter((command) => command.status === "pending")
      .sort((lhs, rhs) => Date.parse(lhs.createdAt) - Date.parse(rhs.createdAt))));
  }

  if (request.method === "GET" && pathname === "/v1/commands/recent") {
    const limit = boundedInt(url.searchParams.get("limit"), 10, 1, 50);
    return sendJSON(200, commandListResponse(state, state.commands
      .slice()
      .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))
      .slice(0, limit)));
  }

  const commandMatch = pathname.match(/^\/v1\/commands\/([0-9a-fA-F-]+)$/);
  if (request.method === "PUT" && commandMatch) {
    const body = await readJSON(request);
    const command = normalizeCommand({ ...body, id: commandMatch[1] }, body.status || "pending");
    await upsertCommand(db, command);
    state.latestCommand = command;
    state.status = normalizeStatus(command.summary || state.status, command.status);
    state.running = command.status === "running";
    state.message = `${displayCommandName(command.kind)} · ${displayStatus(command.status)}`;
    state.updatedAt = new Date().toISOString();
    await saveMetaState(db, state);
    return sendJSON(200, command);
  }

  if (request.method === "POST" && pathname === "/v1/item-actions") {
    const body = await readJSON(request);
    const action = normalizeItemAction(body, "pending");
    if (!action.action || !action.itemID || !action.itemKind) {
      return sendJSON(400, { error: "missing item action target" });
    }
    await upsertItemAction(db, action);
    state.message = `${displayItemActionName(action.action)} 요청 대기 중`;
    state.updatedAt = new Date().toISOString();
    await saveMetaState(db, state);
    return sendJSON(201, action);
  }

  if (request.method === "GET" && pathname === "/v1/item-actions/pending") {
    return sendJSON(200, itemActionListResponse(state.itemActions
      .filter((action) => action.status === "pending")
      .sort((lhs, rhs) => Date.parse(lhs.createdAt) - Date.parse(rhs.createdAt))));
  }

  if (request.method === "GET" && pathname === "/v1/item-actions/recent") {
    const limit = boundedInt(url.searchParams.get("limit"), 20, 1, 50);
    return sendJSON(200, itemActionListResponse(state.itemActions
      .slice()
      .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))
      .slice(0, limit)));
  }

  const itemActionMatch = pathname.match(/^\/v1\/item-actions\/([0-9a-fA-F-]+)$/);
  if (request.method === "PUT" && itemActionMatch) {
    const body = await readJSON(request);
    const action = normalizeItemAction({ ...body, id: itemActionMatch[1] }, body.status || "pending");
    await upsertItemAction(db, action);
    state.message = `${displayItemActionName(action.action)} · ${displayStatus(action.status)}`;
    state.updatedAt = new Date().toISOString();
    await saveMetaState(db, state);
    return sendJSON(200, action);
  }

  return sendJSON(404, { error: "not found" });
}

function database(env) {
  if (!env?.RELAY_DB) {
    throw new Error("RELAY_DB D1 binding is required.");
  }
  return env.RELAY_DB;
}

function relayToken(env) {
  return String(env?.RELAY_TOKEN || env?.KLMS_RELAY_TOKEN || "").trim();
}

async function authorized(request, env) {
  const token = relayToken(env);
  if (!token) {
    return false;
  }
  const header = request.headers.get("Authorization") || "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) {
    return false;
  }
  return constantTimeEqual(token, match[1].trim());
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
  const [status, latestCommand, running, message, updatedAt, commands, itemActions] = await Promise.all([
    getJSONMeta(db, "status", defaultStatus),
    getJSONMeta(db, "latestCommand", null),
    getMeta(db, "running"),
    getMeta(db, "message"),
    getMeta(db, "updatedAt"),
    loadCommands(db),
    loadItemActions(db),
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
    running: running === "true",
    message: message || "서버 준비됨",
    updatedAt: updatedAt || new Date().toISOString(),
  };
}

async function loadCommands(db) {
  const result = await db.prepare(`
    SELECT id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json
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

async function saveMetaState(db, state) {
  await db.batch([
    setMetaStatement(db, "status", JSON.stringify(normalizeStatus(state.status || defaultStatus))),
    setMetaStatement(db, "latestCommand", JSON.stringify(state.latestCommand || null)),
    setMetaStatement(db, "running", state.running ? "true" : "false"),
    setMetaStatement(db, "message", String(state.message || "")),
    setMetaStatement(db, "updatedAt", String(state.updatedAt || new Date().toISOString())),
  ]);
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
      id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      kind = excluded.kind,
      status = excluded.status,
      created_at = excluded.created_at,
      updated_at = excluded.updated_at,
      last_exit_code = excluded.last_exit_code,
      login_required = excluded.login_required,
      summary_json = excluded.summary_json
  `).bind(
    command.id,
    command.kind,
    command.status,
    command.createdAt,
    command.updatedAt,
    Number.isInteger(command.lastExitCode) ? command.lastExitCode : null,
    command.loginRequired ? 1 : 0,
    JSON.stringify(normalizeStatus(command.summary || defaultStatus, command.status))
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

async function trimItemActions(db) {
  await db.prepare(`
    DELETE FROM item_actions
    WHERE id NOT IN (
      SELECT id FROM item_actions ORDER BY updated_at DESC LIMIT ?
    )
  `).bind(MAX_ITEM_ACTIONS).run();
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
  if (commandUpdates.length === 0 && actionUpdates.length === 0) {
    return false;
  }
  for (const command of commandUpdates) {
    await upsertCommand(db, command);
  }
  for (const action of actionUpdates) {
    await upsertItemAction(db, action);
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

function commandListResponse(state, commands) {
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

function relayResponse(state) {
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

async function replaceSyncItems(db, items, generatedAt) {
  const now = new Date().toISOString();
  await db.batch([
    setMetaStatement(db, "syncDataItems", JSON.stringify(items.slice(0, MAX_SYNC_ITEMS))),
    setMetaStatement(db, "syncDataGeneratedAt", String(generatedAt || now)),
    setMetaStatement(db, "syncDataUpdatedAt", now),
  ]);
}

async function syncDataResponse(db, { kind = "", limit = 250 } = {}) {
  const items = parseJSON(await getMeta(db, "syncDataItems"), []);
  const trimmedKind = String(kind || "").trim();
  const filtered = (Array.isArray(items) ? items : [])
    .filter((item) => !trimmedKind || item.kind === trimmedKind)
    .sort(compareSyncItems)
    .slice(0, limit);
  return {
    generatedAt: await getMeta(db, "syncDataGeneratedAt") || "",
    updatedAt: await getMeta(db, "syncDataUpdatedAt") || "",
    items: filtered,
  };
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
    "Access-Control-Allow-Headers": "Authorization, Content-Type, Accept",
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
