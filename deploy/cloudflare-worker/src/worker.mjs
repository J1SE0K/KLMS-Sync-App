const MAX_BODY_BYTES = 1024 * 1024;
const MAX_COMMANDS = 100;
const MAX_ITEM_ACTIONS = 200;
const MAX_SYNC_ITEMS = 2000;
const MAX_FILE_ACCESS_REQUESTS = 100;
const DEFAULT_MAX_FILE_UPLOAD_BYTES = 25 * 1024 * 1024;
const DEFAULT_DAILY_FILE_UPLOADS = 20;
const DEFAULT_DAILY_FILE_UPLOAD_BYTES = 250 * 1024 * 1024;
const DEFAULT_DAILY_FILE_DOWNLOADS = 100;
const DEFAULT_FILE_DOWNLOADS_PER_LINK = 3;
const STALE_PENDING_COMMAND_MS = 60 * 60 * 1000;
const STALE_RUNNING_COMMAND_MS = 2 * 60 * 1000;
const STALE_PENDING_ITEM_ACTION_MS = 60 * 60 * 1000;
const STALE_PENDING_FILE_ACCESS_MS = 10 * 60 * 1000;
const DEFAULT_FILE_ACCESS_TTL_MS = 5 * 60 * 1000;

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
    await saveMetaState(db, state);
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

  if (request.method === "POST" && pathname === "/v1/sync-data") {
    if (!(await authorized(request, env, "worker"))) {
      return sendJSON(401, { error: "unauthorized" });
    }
    const body = await readJSON(request);
    const items = Array.isArray(body.items)
      ? body.items.map(normalizeSyncItem).filter(Boolean).slice(0, MAX_SYNC_ITEMS)
      : [];
    await replaceSyncItems(db, items, body.generatedAt);
    return sendJSON(200, await syncDataResponse(db, { limit: MAX_SYNC_ITEMS }));
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
    state.latestCommand = command;
    state.status = command.summary;
    state.running = false;
    state.message = `${displayCommandName(command.kind)} 요청 대기 중`;
    state.updatedAt = new Date().toISOString();
    await saveMetaState(db, state);
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
    return sendJSON(200, commandListResponse(state, state.commands
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
    await saveMetaState(db, state);
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
    state.message = `${displayItemActionName(action.action)} 요청 대기 중`;
    state.updatedAt = new Date().toISOString();
    await saveMetaState(db, state);
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
    await saveMetaState(db, state);
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
    state.message = `파일 열기 요청 대기 중: ${fileRequest.itemTitle || fileRequest.itemID}`;
    state.updatedAt = new Date().toISOString();
    await saveMetaState(db, state);
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
    return sendJSON(200, fileAccessListResponse(
      await loadFileAccessRequests(db, { limit }),
      request,
      env
    ));
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
  if (method === "GET" && pathname === "/v1/status") return "client";
  if (method === "POST" && pathname === "/v1/status") return "worker";
  if (method === "GET" && pathname === "/v1/sync-data") return "client";
  if (method === "POST" && pathname === "/v1/sync-data") return "worker";
  if (method === "POST" && pathname === "/v1/commands") return "client";
  if (method === "GET" && pathname === "/v1/commands/pending") return "worker";
  if (method === "GET" && pathname === "/v1/commands/recent") return "client";
  if (method === "PUT" && /^\/v1\/commands\/[0-9a-fA-F-]+$/.test(pathname)) return "worker";
  if (method === "POST" && pathname === "/v1/item-actions") return "client";
  if (method === "GET" && pathname === "/v1/item-actions/pending") return "worker";
  if (method === "GET" && pathname === "/v1/item-actions/recent") return "client";
  if (method === "PUT" && /^\/v1\/item-actions\/[0-9a-fA-F-]+$/.test(pathname)) return "worker";
  if (method === "POST" && pathname === "/v1/file-access") return "client";
  if (method === "GET" && pathname === "/v1/file-access/pending") return "worker";
  if (method === "GET" && pathname === "/v1/file-access/recent") return "client";
  if (method === "PUT" && /^\/v1\/file-access\/[0-9a-fA-F-]+$/.test(pathname)) return "worker";
  if (method === "PUT" && /^\/v1\/file-access\/[0-9a-fA-F-]+\/upload$/.test(pathname)) return "worker";
  return null;
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
  await saveFileAccessQuota(db, {
    ...quota,
    uploadCount: quota.uploadCount + 1,
    uploadBytes: quota.uploadBytes + contentLength,
  });
  return sendJSON(200, fileAccessResponseItem(updated, request, env));
}

async function downloadFileAccess(db, env, request, id) {
  const ticket = new URL(request.url).searchParams.get("ticket") || "";
  const fileRequest = await getFileAccessRequest(db, id);
  if (!fileRequest || fileRequest.status !== "completed" || !fileRequest.objectKey || !fileRequest.downloadTicket) {
    return sendJSON(404, { error: "file link not found" });
  }
  if (fileRequest.downloadTicket !== ticket) {
    return sendJSON(401, { error: "unauthorized" });
  }
  if (fileRequest.expiresAt && Date.parse(fileRequest.expiresAt) <= Date.now()) {
    await cleanupExpiredFileAccess(db, env);
    return sendJSON(410, { error: "file link expired" });
  }
  const limits = fileAccessLimits(env);
  if (Number(fileRequest.downloadCount || 0) >= limits.downloadsPerLink) {
    return sendJSON(429, { error: "file link download limit reached" });
  }
  const quota = await loadFileAccessQuota(db);
  if (quota.downloadCount >= limits.dailyDownloads) {
    return sendJSON(429, { error: "daily file download limit reached" });
  }
  if (!env?.RELAY_FILES) {
    return sendJSON(503, { error: "file relay storage is not configured" });
  }
  const object = await env.RELAY_FILES.get(fileRequest.objectKey);
  if (!object) {
    return sendJSON(404, { error: "file object not found" });
  }
  const headers = new Headers();
  headers.set("Cache-Control", "no-store");
  headers.set("Content-Type", fileRequest.contentType || object.httpMetadata?.contentType || "application/octet-stream");
  headers.set("Content-Disposition", contentDisposition(fileRequest.itemTitle || "KLMS file"));
  if (Number.isFinite(Number(fileRequest.sizeBytes))) {
    headers.set("Content-Length", String(Number(fileRequest.sizeBytes)));
  }
  await upsertFileAccessRequest(db, {
    ...fileRequest,
    downloadCount: Number(fileRequest.downloadCount || 0) + 1,
    updatedAt: new Date().toISOString(),
  });
  await saveFileAccessQuota(db, {
    ...quota,
    downloadCount: quota.downloadCount + 1,
  });
  return new Response(object.body, { status: 200, headers });
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

function contentDisposition(filename) {
  const safe = sanitizeFilename(filename);
  const ascii = safe.replace(/[^\x20-\x7E]/g, "_").replace(/"/g, "'");
  return `attachment; filename="${ascii}"; filename*=UTF-8''${encodeRFC5987ValueChars(safe)}`;
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
