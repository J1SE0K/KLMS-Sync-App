#!/usr/bin/env node

import http from "node:http";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import { DatabaseSync, backup as backupDatabase } from "node:sqlite";
import { isIP } from "node:net";
import os from "node:os";
import path from "node:path";
import { consumeBoundedRateWindow } from "./klms_bounded_rate_window.mjs";
import { redactPublicLogText } from "./klms_public_log_redactor.mjs";

const HOST = process.env.KLMS_RELAY_HOST || "127.0.0.1";
const PORT = Number.parseInt(process.env.KLMS_RELAY_PORT || "18484", 10);
const CLIENT_TOKEN = (process.env.KLMS_RELAY_CLIENT_TOKEN || "").trim();
const WORKER_TOKEN = (process.env.KLMS_RELAY_WORKER_TOKEN || "").trim();
const TRUSTED_PROXY_SECRET = (process.env.KLMS_RELAY_TRUSTED_PROXY_SECRET || "").trim();
const DB_PATH = process.env.KLMS_RELAY_DB
  ? expandHome(process.env.KLMS_RELAY_DB)
  : path.join(os.homedir(), ".local", "state", "klms-sync-relay.sqlite");
const MAX_BODY_BYTES = 1024 * 1024;
const MIN_RELAY_TOKEN_BYTES = 32;
const MAX_REALTIME_CONNECTIONS = 32;
const MAX_REALTIME_MESSAGE_BYTES = 4 * 1024;
const MAX_REALTIME_FRAME_BYTES = 64 * 1024;
const MAX_REALTIME_SNAPSHOT_BYTES = 8 * 1024 * 1024;
const MAX_REALTIME_SNAPSHOT_CHUNKS = 254;
const REALTIME_SNAPSHOT_CHUNK_BYTES = 43 * 1024;
const REQUESTS_PER_MINUTE = boundedInt(process.env.KLMS_RELAY_REQUESTS_PER_MINUTE, 600, 1, 6_000);
const PUBLIC_DOWNLOAD_INGRESS_PER_MINUTE = Math.min(
  REQUESTS_PER_MINUTE,
  boundedInt(process.env.KLMS_RELAY_PUBLIC_DOWNLOAD_INGRESS_PER_MINUTE, 60, 1, 600),
);
const PUBLIC_DOWNLOAD_LINKS_PER_MINUTE = Math.min(
  REQUESTS_PER_MINUTE,
  boundedInt(process.env.KLMS_RELAY_PUBLIC_DOWNLOAD_LINKS_PER_MINUTE, 60, 1, 600),
);
const MAX_AUTHORIZED_REQUEST_RATE_WINDOWS = 64;
const MAX_UNAUTHORIZED_REQUEST_RATE_WINDOWS = 512;
const MAX_PUBLIC_DOWNLOAD_INGRESS_WINDOWS = 512;
const MAX_PUBLIC_DOWNLOAD_LINK_WINDOWS = 128;
const MAX_COMMANDS = 100;
const MAX_ITEM_ACTIONS = 200;
const MAX_SETTING_ACTIONS = 100;
const MAX_REQUEST_LOG_ENTRIES = 100;
const MAX_SYNC_ITEMS = 2_000;
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
const SAFE_INLINE_IMAGE_CONTENT_TYPES = new Set([
  "image/avif",
  "image/bmp",
  "image/gif",
  "image/jpeg",
  "image/png",
  "image/webp",
]);
const SAFE_INLINE_AUDIO_CONTENT_TYPES = new Set([
  "audio/aac",
  "audio/flac",
  "audio/mp4",
  "audio/mpeg",
  "audio/ogg",
  "audio/wav",
  "audio/webm",
  "audio/x-wav",
]);
const SAFE_INLINE_VIDEO_CONTENT_TYPES = new Set([
  "video/mp4",
  "video/ogg",
  "video/quicktime",
  "video/webm",
]);
const STALE_PENDING_COMMAND_MS = 60 * 60 * 1000;
const STALE_RUNNING_COMMAND_MS = 2 * 60 * 1000;
const STALE_PENDING_ITEM_ACTION_MS = 60 * 60 * 1000;
const STALE_RUNNING_ITEM_ACTION_MS = 10 * 60 * 1000;
const STALE_PENDING_SETTING_ACTION_MS = 60 * 60 * 1000;
const STALE_RUNNING_SETTING_ACTION_MS = 10 * 60 * 1000;
const STALE_PENDING_FILE_ACCESS_MS = 10 * 60 * 1000;
const STALE_RUNNING_FILE_ACCESS_MS = 6 * 60 * 60 * 1000;
const FILE_DOWNLOAD_RESERVATION_LEASE_MS = 10 * 60 * 1000;
const CANCEL_REQUEST_TTL_MS = 10 * 60 * 1000;
const DEFAULT_FILE_ACCESS_TTL_MS = 5 * 60 * 1000;
const AUTH_DIGITS_PUBLIC_TTL_MS = 120 * 1000;
const REALTIME_EVENT_VERSION = 1;
const TEST_FILE_DELETE_DELAY_MS = process.env.NODE_ENV === "test"
  ? Math.max(0, Math.min(2_000, Number.parseInt(process.env.KLMS_RELAY_TEST_FILE_DELETE_DELAY_MS || "0", 10) || 0))
  : 0;
const TEST_FILE_READ_DELAY_MS = process.env.NODE_ENV === "test"
  ? Math.max(0, Math.min(2_000, Number.parseInt(process.env.KLMS_RELAY_TEST_FILE_READ_DELAY_MS || "0", 10) || 0))
  : 0;
const TEST_TRACK_FILE_OBJECT_READS = process.env.NODE_ENV === "test"
  && process.env.KLMS_RELAY_TEST_TRACK_FILE_OBJECT_READS === "1";
const TEST_TRACK_PUBLIC_DOWNLOAD_LOOKUPS = process.env.NODE_ENV === "test"
  && process.env.KLMS_RELAY_TEST_TRACK_PUBLIC_DOWNLOAD_LOOKUPS === "1";
const MAX_PUBLIC_TEXT_CHARS = 2_000;
const MAX_IDENTIFIER_CHARS = 512;
const COMMAND_KINDS = new Set([
  "fullSync", "coreSync", "noticeSync", "filesSync", "verify", "doctor", "report", "v2BuildState",
]);
const COMMAND_STATUSES = new Set(["pending", "running", "completed", "failed", "cancelled", "macUnavailable"]);
const COMMAND_OPTION_KEYS = new Set(["updateNoticeNotes", "update_notice_notes", "dryRun", "dry_run"]);
const RUN_LOG_COMMAND_TITLES = new Map([
  ["fullSync", "전체 동기화"],
  ["coreSync", "과제/시험"],
  ["noticeSync", "공지 메모"],
  ["filesSync", "파일 동기화"],
  ["full", "전체 동기화"],
  ["core", "과제/시험"],
  ["notice", "공지 메모"],
  ["files", "파일 동기화"],
  ["verify", "상태 검사"],
  ["doctor", "권한/환경 진단"],
  ["report", "요약 갱신"],
  ["v2BuildState", "상태 파일 재생성"],
]);
const ACTION_STATUSES = new Set(["pending", "running", "completed", "failed", "macUnavailable"]);
const STATUS_PHASES = new Set(["idle", ...COMMAND_STATUSES]);
const ITEM_ACTION_KINDS = new Set([
  "assignmentComplete", "assignmentRestore", "assignmentHide", "assignmentUnhide",
  "examPromote", "examIgnore", "examRestore",
  "noticeRead", "noticeUnread", "noticeImportant", "noticeUnimportant", "noticeHide", "noticeUnhide",
  "fileHide", "fileUnhide", "fileTrash",
  "calendarVerify", "calendarApply", "calendarCreate", "calendarEdit", "calendarDelete", "calendarOpen",
  "mailDashboardAdd", "mailDashboardRemove",
]);
const ITEM_KINDS = new Set([
  "assignment", "assignmentCandidate", "completedAssignment", "exam", "examCandidate", "helpDesk",
  "notice", "file", "calendar", "mailDashboard",
]);
const FILE_ACCESS_STATUSES = ACTION_STATUSES;
const REALTIME_SCOPES = new Set([
  "status", "syncData", "commands", "itemActions", "settingActions", "sharedSettings",
  "runLogs", "fileAccess", "requestLog", "cancel",
]);
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
const SYNC_SETTING_KEYS = new Set([
  "KLMS_LOGIN_ASSIST_ENABLED",
  "KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE",
  "KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED",
  "KLMS_SAFARI_BACKGROUND_WINDOW_MODE",
  "KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED",
  "CALENDAR_SKIP_UNCHANGED_DESIRED",
  "SYNC_MODE",
  "FILE_REFRESH_MODE",
  "FILE_SKIP_DOWNLOAD_WHEN_PREVIEW_EMPTY",
  "FILE_KEEP_FRESH_DOWNLOADS",
  "FILE_WEEKLY_FOLDERS_ENABLED",
  "FILE_PRESERVE_DOWNLOAD_ARCHIVE",
  "NOTICE_COLLAPSE_SECTIONS",
  "NOTICE_COLLAPSE_COURSES",
  "NOTICE_COLLAPSE_NOTICE_ITEMS",
  "NOTICE_STYLE_NOTICE_ITEMS_AS_HEADINGS",
  "NOTICE_HIDE_HIDDEN_ITEMS",
  "NOTICE_NATIVE_STABLE_NOOP_SKIP",
  "NOTICE_NATIVE_ALWAYS_CAPTURE_STATE",
  "NOTICE_NATIVE_VERIFY_STABLE_SKIP_FORMAT",
  "NOTICE_NATIVE_PLAIN_TEXT_PASTE",
  ...SHARED_SETTING_DEFINITIONS.map((definition) => definition.key),
]);
const FILE_DIR = process.env.KLMS_RELAY_FILE_DIR
  ? expandHome(process.env.KLMS_RELAY_FILE_DIR)
  : path.join(path.dirname(DB_PATH), "files");
const PUBLIC_URL = normalizePublicRelayURL(process.env.KLMS_RELAY_PUBLIC_URL || "");

const backupArgumentIndex = process.argv.indexOf("--backup");
if (backupArgumentIndex >= 0) {
  const backupPath = process.argv[backupArgumentIndex + 1];
  if (!backupPath) {
    console.error("--backup requires a destination path");
    process.exit(64);
  }
  await createVerifiedDatabaseBackup(DB_PATH, expandHome(backupPath));
  process.exit(0);
}

const verifyBackupArgumentIndex = process.argv.indexOf("--verify-backup");
if (verifyBackupArgumentIndex >= 0) {
  const backupPath = process.argv[verifyBackupArgumentIndex + 1];
  if (!backupPath) {
    console.error("--verify-backup requires a database path");
    process.exit(64);
  }
  console.log(JSON.stringify(await verifyDatabaseBackup(expandHome(backupPath))));
  process.exit(0);
}

const pruneBackupsArgumentIndex = process.argv.indexOf("--prune-backups");
if (pruneBackupsArgumentIndex >= 0) {
  const backupDirectory = process.argv[pruneBackupsArgumentIndex + 1];
  const retentionDays = Number.parseInt(process.argv[pruneBackupsArgumentIndex + 2] || "", 10);
  if (!backupDirectory || !Number.isInteger(retentionDays) || retentionDays < 1 || retentionDays > 3650) {
    console.error("--prune-backups requires a directory and retention days between 1 and 3650");
    process.exit(64);
  }
  console.log(JSON.stringify(await pruneDatabaseBackups(expandHome(backupDirectory), retentionDays)));
  process.exit(0);
}

if (!CLIENT_TOKEN || !WORKER_TOKEN) {
  console.error("KLMS_RELAY_CLIENT_TOKEN and KLMS_RELAY_WORKER_TOKEN are required.");
  process.exit(64);
}
if (Buffer.byteLength(CLIENT_TOKEN, "utf8") < MIN_RELAY_TOKEN_BYTES
    || Buffer.byteLength(WORKER_TOKEN, "utf8") < MIN_RELAY_TOKEN_BYTES) {
  console.error("KLMS_RELAY_CLIENT_TOKEN and KLMS_RELAY_WORKER_TOKEN must each be at least 32 bytes.");
  process.exit(64);
}
if (CLIENT_TOKEN === WORKER_TOKEN) {
  console.error("KLMS_RELAY_CLIENT_TOKEN and KLMS_RELAY_WORKER_TOKEN must be different.");
  process.exit(64);
}
if (TRUSTED_PROXY_SECRET && Buffer.byteLength(TRUSTED_PROXY_SECRET, "utf8") < MIN_RELAY_TOKEN_BYTES) {
  console.error("KLMS_RELAY_TRUSTED_PROXY_SECRET must be at least 32 bytes when configured.");
  process.exit(64);
}
if (!Number.isInteger(PORT) || PORT <= 0 || PORT > 65535) {
  console.error("KLMS_RELAY_PORT must be a valid TCP port.");
  process.exit(64);
}
if (!PUBLIC_URL && !isLoopbackHostname(HOST)) {
  console.error("KLMS_RELAY_PUBLIC_URL is required when the relay listens beyond loopback.");
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
const activeFileUploadClaims = new Set();
const db = new DatabaseSync(DB_PATH);
initDatabase();
recoverStaleFileDownloadReservations({ notify: false });
// This routine snapshots pending claims before filesystem awaits. Keep it
// before listen() so a live upload cannot finish underneath that snapshot.
await recoverInterruptedFileUploads({ recoverDeletionClaims: true, sweepUnreferencedObjects: true });
let state = loadState();
const realtimeClients = new Set();
const authorizedRequestRateWindows = new Map();
const unauthorizedRequestRateWindows = new Map();
const publicDownloadIngressRateWindows = new Map();
const publicDownloadLinkRateWindows = new Map();
let expiredFileCleanupPromise = null;

const server = http.createServer(async (request, response) => {
  try {
    await route(request, response);
  } catch (error) {
    if (error instanceof RelayConflictError) {
      sendJSON(response, 409, { error: error.message });
      return;
    }
    if (error instanceof RelayValidationError) {
      sendJSON(response, 400, { error: error.message });
      return;
    }
    if (error instanceof RelayPayloadTooLargeError) {
      sendJSON(response, 413, { error: error.message });
      return;
    }
    console.error(error);
    sendJSON(response, 500, { error: "server error" });
  }
});

server.on("upgrade", handleWebSocketUpgrade);

server.listen(PORT, HOST, () => {
  console.log(`KLMS relay server listening on http://${HOST}:${PORT}`);
  console.log(`Database: ${DB_PATH}`);
});
const expiredFileCleanupTimer = setInterval(scheduleExpiredFileAccessCleanup, 30_000);
expiredFileCleanupTimer.unref();

async function route(request, response) {
  const url = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);
  if (request.method === "GET" && url.pathname === "/healthz") {
    sendJSON(response, 200, { ok: true, service: "klms-relay" });
    return;
  }

  if (request.method === "GET" && url.pathname === "/readyz") {
    const access = rateLimitedAuthorization(request, "worker", "worker-readiness");
    if (!access.allowed) {
      sendRateLimitResponse(response);
      return;
    }
    if (!access.authorized) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    const readiness = relayReadiness();
    sendJSON(response, readiness.ok ? 200 : 503, readiness);
    return;
  }

  if (!url.pathname.startsWith("/v1/")) {
    sendJSON(response, 404, { error: "not found" });
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/events") {
    const role = parseRealtimeRole(url.searchParams.get("role"));
    if (!role) {
      sendJSON(response, 400, { error: "role must be client or worker" });
      return;
    }
    const access = rateLimitedAuthorization(request, role, `${role}-realtime`);
    if (!access.allowed) {
      sendRateLimitResponse(response);
      return;
    }
    if (!access.authorized) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    sendJSON(response, 426, { error: "websocket upgrade required" });
    return;
  }

  if (request.method === "GET" && url.pathname === "/v1/events/poll") {
    sendJSON(response, 410, { error: "event polling removed; use /v1/events websocket" });
    return;
  }

  const fileDownloadMatch = url.pathname.match(/^\/v1\/file-access\/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\/download$/);
  if (request.method === "GET" && fileDownloadMatch) {
    if (!consumePublicDownloadIngressRateLimit(request)) {
      sendRateLimitResponse(response);
      return;
    }
    if (url.searchParams.has("ticket")) {
      sendJSON(response, 400, { error: "download credentials are not accepted in URLs" });
      return;
    }
    if (!validDownloadTicket(downloadCapabilityFromRequest(request))) {
      sendFileAccessDownloadPage(response, url, {
        status: 403,
        title: "권한이 없는 링크입니다",
        message: "링크의 인증 정보가 올바르지 않습니다. 앱에서 파일 링크를 다시 요청해 주세요.",
      });
      return;
    }
    await downloadFileAccess(request, response, url, fileDownloadMatch[1]);
    return;
  }

  const requiredRole = requiredRoleFor(request.method, url.pathname);
  if (!requiredRole) {
    sendJSON(response, 404, { error: "not found" });
    return;
  }
  const access = rateLimitedAuthorization(request, requiredRole, requiredRole);
  if (!access.allowed) {
    sendRateLimitResponse(response);
    return;
  }
  if (!access.authorized) {
    sendJSON(response, 401, { error: "unauthorized" });
    return;
  }

  expireStaleCommands();
  expireStalePendingItemActions();
  expireStalePendingSettingActions();
  recoverStaleFileDownloadReservations();
  expireStaleFileAccessRequests();
  scheduleExpiredFileAccessCleanup();

  if (request.method === "GET" && url.pathname === "/v1/worker/inbox") {
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
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
    sendJSON(response, 200, relayResponse({ audience: "client" }));
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
    validateStatusUpdateBody(body);
    state.status = normalizeStatus(body.status || body);
    state.running = Boolean(body.running);
    state.message = String(body.message || "");
    if (body.latestCommand) {
      const existing = state.commands.find((item) => item.id === normalizeUUIDText(body.latestCommand.id));
      const command = workerCommandFromBody(body.latestCommand, existing);
      upsertCommand(command);
      state.latestCommand = command;
    }
    state.updatedAt = new Date().toISOString();
    await saveState();
    sendJSON(response, 200, relayResponse({ audience: "worker" }));
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

  if (request.method === "GET" && url.pathname === "/v1/shared-settings") {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    sendJSON(response, 200, sharedSettingsResponse());
    return;
  }

  const sharedSettingMatch = url.pathname.match(/^\/v1\/shared-settings\/([A-Z][A-Z0-9_]*)$/);
  if (request.method === "PUT" && sharedSettingMatch) {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    const body = await readJSON(request);
    const setting = updateSharedSetting(sharedSettingMatch[1], body, request);
    if (!setting) {
      sendJSON(response, 400, { error: "unsupported shared setting" });
      return;
    }
    sendJSON(response, 200, setting);
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
      termCatalog: normalizeTermCatalog(body.termCatalog),
      settings: normalizeSettings(body.settings),
      runLogs: normalizeRunLogs(body.runLogs),
      verifySummary: normalizeVerifySummary(body.verifySummary),
    });
    sendJSON(response, 200, syncDataResponse({ limit: MAX_SYNC_ITEMS }));
    return;
  }

  if (request.method === "DELETE" && url.pathname === "/v1/sync-data/run-logs") {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    sendJSON(response, 200, clearSharedRunLogs());
    return;
  }

  if (request.method === "POST" && url.pathname === "/v1/cancel") {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    const body = await readJSON(request);
    validateOptionalISODate(body.requestedAt, "requestedAt");
    validateTextLength(body.message, "message", MAX_PUBLIC_TEXT_CHARS);
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
    state.message = "실행 중단 요청 대기 중";
    state.updatedAt = new Date().toISOString();
    await saveState("cancel:requested", () => {
      setMeta("cancelRequest", JSON.stringify(cancelRequest));
      appendRequestLog(request, {
        action: "동기화 중단 요청",
        status: "accepted",
        message: cancelRequest.message,
      });
    });
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
    commitRelayMutation("cancel:cleared", new Date().toISOString(), clearCancelRequest);
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
    const command = clientCommandFromBody(body);
    if (!COMMAND_KINDS.has(command.kind)) {
      sendJSON(response, 400, { error: "unsupported command kind" });
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
    try {
      await saveState("commands:pending", () => {
        appendRequestLog(request, {
          action: `${displayCommandName(command.kind)} 요청`,
          status: "queued",
          message: "원격 실행 요청을 서버에 기록했습니다.",
        });
      });
    } catch (error) {
      if (isActiveCommandConstraintError(error)) {
        state = loadState();
        sendJSON(response, 409, { error: "already running or pending" });
        return;
      }
      throw error;
    }
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
    const clearTimes = displayLogClearTimes();
    sendJSON(response, 200, commandListResponse(
      filterDisplayCommands(state.commands, clearTimes.command)
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
    const commandID = normalizeUUIDText(commandMatch[1]);
    const current = state.commands.find((item) => item.id === commandID);
    if (!current) {
      sendJSON(response, 404, { error: "command not found" });
      return;
    }
    const command = applyWorkerCommandPatch(current, body);
    upsertCommand(command);
    state.latestCommand = command;
    state.status = normalizeStatus(command.summary || state.status, command.status);
    state.running = command.status === "running";
    state.message = `${displayCommandName(command.kind)} · ${displayStatus(command.status)}`;
    state.updatedAt = new Date().toISOString();
    await saveState(`commands:${command.status || "updated"}`);
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
    const action = clientItemActionFromBody(body, itemActionIdempotencyKey(request, body));
    if (!ITEM_ACTION_KINDS.has(action.action) || !action.itemID || !ITEM_KINDS.has(action.itemKind)) {
      sendJSON(response, 400, { error: "unsupported item action target" });
      return;
    }
    const replayedAction = getItemActionByIdempotencyKey(actionIdempotencyKey(action));
    if (replayedAction) {
      if (!sameItemActionIntent(replayedAction, action)) {
        sendJSON(response, 409, { error: "idempotency key was already used for a different item action" });
        return;
      }
      sendJSON(response, 200, replayedAction);
      return;
    }
    const remainsActive = !isServerDisplayOnlyItemAction(action.action)
      && !isClientCompletedCalendarAction(action);
    const activeItemActions = state.itemActions.filter(itemActionIsActive);
    if (remainsActive && activeItemActions.length >= MAX_ITEM_ACTIONS) {
      sendJSON(response, 409, { error: "too many active item actions; retry after existing work completes" });
      return;
    }
    if (remainsActive && activeItemActions.some((candidate) => (
      candidate.itemID === action.itemID && candidate.itemKind === action.itemKind
    ))) {
      sendJSON(response, 409, { error: "an active action already exists for this item" });
      return;
    }
    const syncPatch = applyItemActionToStoredSyncData(action);
    if (syncPatch.nextStatus) state.status = syncPatch.nextStatus;
    const serverApplied = isServerDisplayOnlyItemAction(action.action) || isClientCompletedCalendarAction(action);
    const serverSnapshotUpdated = serverApplied || syncPatch.changed || itemActionUpdatesServerVisibleState(action.action);
    if (serverApplied) {
      action.status = "completed";
    }
    if (serverApplied && !action.message) {
      action.message = "서버 화면에 바로 반영했습니다. 모든 기기가 최신 상태를 받아옵니다.";
      action.updatedAt = new Date().toISOString();
    } else if (serverSnapshotUpdated && !action.message) {
      action.message = "서버 화면에는 바로 반영했습니다. Mac 앱이 켜지면 실제 앱에도 적용합니다.";
      action.updatedAt = new Date().toISOString();
    }
    upsertItemAction(action);
    state.message = serverApplied
      ? `${displayItemActionName(action.action)} 서버 반영 완료`
      : serverSnapshotUpdated
        ? `${displayItemActionName(action.action)} 서버 화면 반영 완료 · Mac 적용 대기`
      : `${displayItemActionName(action.action)} 요청 대기 중`;
    state.updatedAt = new Date().toISOString();
    try {
      await saveState(serverSnapshotUpdated ? "item-actions:server-state" : "item-actions:pending", () => {
        syncPatch.persist?.();
        appendRequestLog(request, {
          action: displayItemActionName(action.action),
          status: serverSnapshotUpdated ? "updated" : "queued",
          message: action.message || action.itemTitle || action.itemID,
        });
      });
    } catch (error) {
      state = loadState();
      throw error;
    }
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
    const clearTimes = displayLogClearTimes();
    sendJSON(response, 200, itemActionListResponse(
      filterDisplayItemActions(state.itemActions, clearTimes.itemActions)
        .slice()
        .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))
        .slice(0, limit)
    ));
    return;
  }

  const itemActionMatch = url.pathname.match(/^\/v1\/item-actions\/([0-9a-fA-F-]+)$/);
  if (request.method === "GET" && itemActionMatch) {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStalePendingItemActions();
    const actionID = normalizeUUIDText(itemActionMatch[1]);
    const action = state.itemActions.find((item) => item.id === actionID);
    if (!action) {
      sendJSON(response, 404, { error: "item action not found" });
      return;
    }
    sendJSON(response, 200, action);
    return;
  }
  if (request.method === "PUT" && itemActionMatch) {
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    expireStaleCommands();
    expireStalePendingItemActions();
    const body = await readJSON(request);
    const actionID = normalizeUUIDText(itemActionMatch[1]);
    const current = state.itemActions.find((item) => item.id === actionID);
    if (!current) {
      sendJSON(response, 404, { error: "item action not found" });
      return;
    }
    const action = applyWorkerItemActionPatch(current, body);
    upsertItemAction(action);
    state.message = `${displayItemActionName(action.action)} · ${displayStatus(action.status)}`;
    state.updatedAt = new Date().toISOString();
    await saveState(`item-actions:${action.status || "updated"}`);
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
    const action = clientSettingActionFromBody(body);
    if (!action.key) {
      sendJSON(response, 400, { error: "missing setting key" });
      return;
    }
    const duplicateAction = duplicateActiveSettingAction(state.settingActions, action);
    if (duplicateAction) {
      sendJSON(response, 201, duplicateAction);
      return;
    }
    const syncPatch = applySettingActionToStoredSyncData(action);
    const serverSnapshotUpdated = syncPatch.changed || syncPatch.applied;
    action.status = "pending";
    if (serverSnapshotUpdated && !action.message) {
      action.message = syncPatch.changed
        ? "서버 화면에는 바로 반영했습니다. Mac 앱이 켜지면 실제 동기화 설정에도 적용합니다."
        : "서버 화면은 이미 같은 값입니다. Mac 앱이 켜지면 실제 동기화 설정을 다시 확인합니다.";
      action.updatedAt = new Date().toISOString();
    }
    upsertSettingAction(action);
    state.message = serverSnapshotUpdated
      ? `${action.title || action.key} 서버 화면 반영 완료 · Mac 적용 대기`
      : `${action.title || action.key} 설정 변경 요청 대기 중`;
    state.updatedAt = new Date().toISOString();
    try {
      await saveState("setting-actions:pending", () => {
        syncPatch.persist?.();
        appendRequestLog(request, {
          action: `${action.title || action.key} 설정 변경`,
          status: serverSnapshotUpdated ? "updated" : "queued",
          message: serverSnapshotUpdated
            ? (syncPatch.changed
              ? "서버 화면에는 바로 반영했습니다. Mac 앱이 켜지면 실제 동기화 설정에도 적용합니다."
              : "서버 화면은 이미 같은 값입니다. Mac 앱이 켜지면 실제 동기화 설정을 다시 확인합니다.")
            : "설정 변경 요청을 서버에 기록했습니다.",
        });
      });
    } catch (error) {
      state = loadState();
      throw error;
    }
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
    const clearTimes = displayLogClearTimes();
    sendJSON(response, 200, settingActionListResponse(
      filterDisplaySettingActions(state.settingActions, clearTimes.settingActions)
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
    const actionID = normalizeUUIDText(settingActionMatch[1]);
    const current = state.settingActions.find((item) => item.id === actionID);
    if (!current) {
      sendJSON(response, 404, { error: "setting action not found" });
      return;
    }
    const action = applyWorkerSettingActionPatch(current, body);
    upsertSettingAction(action);
    state.message = `${action.title || action.key} · ${displayStatus(action.status)}`;
    state.updatedAt = new Date().toISOString();
    await saveState(`setting-actions:${action.status || "updated"}`);
    sendJSON(response, 200, action);
    return;
  }

  if (request.method === "POST" && url.pathname === "/v1/file-access") {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    const body = await readJSON(request);
    const fileRequest = clientFileAccessFromBody(body);
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
    state.message = `파일 열기 요청 대기 중: ${fileRequest.itemTitle || fileRequest.itemID}`;
    state.updatedAt = new Date().toISOString();
    await saveState("file-access:pending", () => {
      upsertFileAccessRequest(fileRequest);
      appendRequestLog(request, {
        action: "파일 열기 요청",
        status: "queued",
        message: fileRequest.itemTitle || fileRequest.itemID,
      });
    });
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
    const clearTimes = displayLogClearTimes();
    sendJSON(response, 200, fileAccessListResponse(
      filterDisplayFileAccess(loadFileAccessRequests({ limit: MAX_FILE_ACCESS_REQUESTS }), clearTimes.fileAccess).slice(0, limit),
      request
    ));
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

  if (request.method === "DELETE" && url.pathname === "/v1/logs/display") {
    if (!authorized(request, "client")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    const scope = normalizeLogClearScope(url.searchParams.get("scope"));
    if (!scope) {
      sendJSON(response, 400, { error: "invalid log clear scope" });
      return;
    }
    sendJSON(response, 200, clearDisplayLogs(scope));
    return;
  }

  if (request.method === "DELETE" && url.pathname === "/v1/logs") {
    if (!authorized(request, "worker")) {
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }
    const scope = normalizeLogClearScope(url.searchParams.get("scope"));
    if (!scope) {
      sendJSON(response, 400, { error: "invalid log clear scope" });
      return;
    }
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
    const internalLease = db.prepare(`
      SELECT upload_claim, object_key
      FROM file_access_requests
      WHERE id = ?
    `).get(current.id);
    if (internalLease?.object_key && internalLease?.upload_claim) {
      sendJSON(response, 409, { error: "file request is being deleted" });
      return;
    }
    const fileRequest = applyWorkerFileAccessPatch(current, body);
    commitRelayMutation(`file-access:${fileRequest.status}`, fileRequest.updatedAt, () => {
      upsertFileAccessRequest(fileRequest);
    });
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
  if (method === "PUT" && /^\/v1\/commands\/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(pathname)) return "worker";
  if (method === "POST" && pathname === "/v1/item-actions") return "client";
  if (method === "GET" && pathname === "/v1/item-actions/pending") return "worker";
  if (method === "GET" && pathname === "/v1/item-actions/recent") return "client";
  if (method === "GET" && /^\/v1\/item-actions\/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(pathname)) return "client";
  if (method === "PUT" && /^\/v1\/item-actions\/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(pathname)) return "worker";
  if (method === "POST" && pathname === "/v1/setting-actions") return "client";
  if (method === "GET" && pathname === "/v1/setting-actions/pending") return "worker";
  if (method === "GET" && pathname === "/v1/setting-actions/recent") return "client";
  if (method === "PUT" && /^\/v1\/setting-actions\/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(pathname)) return "worker";
  if (method === "POST" && pathname === "/v1/file-access") return "client";
  if (method === "GET" && pathname === "/v1/file-access/pending") return "worker";
  if (method === "GET" && pathname === "/v1/file-access/recent") return "client";
  if (method === "GET" && pathname === "/v1/request-log/recent") return "client";
  if (method === "DELETE" && pathname === "/v1/logs/display") return "client";
  if (method === "DELETE" && pathname === "/v1/logs") return "worker";
  if (method === "PUT" && /^\/v1\/file-access\/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(pathname)) return "worker";
  if (method === "PUT" && /^\/v1\/file-access\/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\/upload$/.test(pathname)) return "worker";
  return null;
}

function commandListResponse(commands) {
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

function fileAccessListResponse(requests, request) {
  return {
    requests: requests.map((fileRequest) => fileAccessResponseItem(fileRequest, request)),
  };
}

function workerInboxResponse(request) {
  const clearTimes = displayLogClearTimes();
  return {
    statusResponse: relayResponse({ audience: "worker" }),
    recentRequestLog: requestLogResponse(20).entries,
    recentFileAccessRequests: fileAccessListResponse(
      filterDisplayFileAccess(loadFileAccessRequests({ limit: 8 }), clearTimes.fileAccess),
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
    sharedSettings: loadSharedSettings(),
  };
}

function parseRealtimeRole(value) {
  const role = String(value || "").trim().toLowerCase();
  return role === "client" || role === "worker" ? role : null;
}

function requestLogResponse(limit = 20) {
  const clearTimes = displayLogClearTimes();
  return {
    entries: filterDisplayRequestLog(
      loadRequestLog(),
      clearTimes.requestLog
    ).slice(0, Math.max(1, Math.min(MAX_REQUEST_LOG_ENTRIES, limit))),
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
    downloadCapability: null,
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
    response.downloadCapability = fileRequest.downloadTicket;
  }
  return response;
}

function relayResponse(options = {}) {
  const status = normalizeStatus(state.status, state.running ? "running" : undefined);
  const exposeAuthDigits = shouldExposeAuthDigitsToAudience(status, options.audience || "client");
  return {
    ok: true,
    message: state.message || "",
    status: exposeAuthDigits ? status : redactAuthDigitsFromStatus(status),
    latestCommand: redactAuthDigitsFromCommand(state.latestCommand || null, exposeAuthDigits),
    running: Boolean(state.running),
    updatedAt: state.updatedAt || null,
    revision: currentRelayRevision(),
    requestNonce: null,
    responseIssuedAtEpochSeconds: null,
    signature: null,
  };
}

function shouldExposeAuthDigitsToAudience(status, audience) {
  if (audience === "worker") return true;
  if (!status.authDigits) return false;
  if (!state.running || status.phase !== "running") return false;
  const reference = Date.parse(state.updatedAt || state.latestCommand?.updatedAt || "");
  if (!Number.isFinite(reference)) return false;
  return Date.now() - reference <= AUTH_DIGITS_PUBLIC_TTL_MS;
}

function redactAuthDigitsFromStatus(status) {
  if (!status?.authDigits) return status;
  return {
    ...status,
    authDigits: null,
    loginRequired: true,
    phaseDetail: status.phaseDetail || "KAIST 인증이 필요합니다.",
  };
}

function redactAuthDigitsFromCommand(command, exposeAuthDigits) {
  if (!command || exposeAuthDigits) return command;
  return {
    ...command,
    summary: redactAuthDigitsFromStatus(command.summary || defaultStatus),
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

class RelayValidationError extends Error {}
class RelayConflictError extends Error {}
class RelayPayloadTooLargeError extends Error {}

function requireObject(value, field = "request body") {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new RelayValidationError(`${field} must be an object`);
  }
  return value;
}

function validateTextLength(value, field, maximum, { required = false } = {}) {
  if (value == null) {
    if (required) throw new RelayValidationError(`${field} is required`);
    return "";
  }
  if (typeof value !== "string") {
    throw new RelayValidationError(`${field} must be a string`);
  }
  const text = value.trim();
  if (required && !text) throw new RelayValidationError(`${field} is required`);
  if (text.length > maximum) throw new RelayValidationError(`${field} is too long`);
  return text;
}

function validateOptionalISODate(value, field) {
  if (value == null || value === "") return null;
  if (typeof value !== "string" || value.length > 64 || !Number.isFinite(Date.parse(value))) {
    throw new RelayValidationError(`${field} must be an ISO date`);
  }
  return value;
}

function requireUUID(value, field) {
  const uuid = normalizeUUIDText(value);
  if (!uuid) throw new RelayValidationError(`${field} must be a UUID`);
  return uuid;
}

function requireEnum(value, field, allowed) {
  const text = validateTextLength(value, field, 64, { required: true });
  if (!allowed.has(text)) throw new RelayValidationError(`unsupported ${field}`);
  return text;
}

function validateStatusUpdateBody(body) {
  requireObject(body);
  validateTextLength(body.message, "message", MAX_PUBLIC_TEXT_CHARS);
  if (body.latestCommand != null) {
    requireObject(body.latestCommand, "latestCommand");
    requireUUID(body.latestCommand.id, "latestCommand.id");
    requireEnum(body.latestCommand.kind, "latestCommand.kind", COMMAND_KINDS);
    requireEnum(body.latestCommand.status, "latestCommand.status", COMMAND_STATUSES);
    validateOptionalISODate(body.latestCommand.createdAt, "latestCommand.createdAt");
    validateOptionalISODate(body.latestCommand.updatedAt, "latestCommand.updatedAt");
  }
}

function clientCommandFromBody(raw) {
  const body = requireObject(raw);
  const now = new Date().toISOString();
  const kind = requireEnum(body.kind, "command kind", COMMAND_KINDS);
  const options = validateCommandOptions(body.options);
  return normalizeCommand({
    id: crypto.randomUUID(),
    kind,
    status: "pending",
    createdAt: now,
    updatedAt: now,
    options,
  }, "pending");
}

function workerCommandFromBody(raw, current = null) {
  const body = requireObject(raw, "latestCommand");
  if (current) return applyWorkerCommandPatch(current, body);
  const now = new Date().toISOString();
  return normalizeCommand({
    id: requireUUID(body.id, "command id"),
    kind: requireEnum(body.kind, "command kind", COMMAND_KINDS),
    status: requireEnum(body.status, "command status", COMMAND_STATUSES),
    createdAt: validateOptionalISODate(body.createdAt, "createdAt") || now,
    updatedAt: now,
    lastExitCode: Number.isInteger(body.lastExitCode) ? body.lastExitCode : null,
    loginRequired: Boolean(body.loginRequired),
    summary: body.summary,
    options: validateCommandOptions(body.options),
  }, body.status);
}

function applyWorkerCommandPatch(current, raw) {
  const body = requireObject(raw);
  assertMatchingImmutable(body.id, current.id, "id", { uuid: true });
  assertMatchingImmutable(body.kind, current.kind, "kind");
  assertMatchingImmutable(body.createdAt, current.createdAt, "createdAt", { date: true });
  const options = validateCommandOptions(body.options);
  if (body.options != null && JSON.stringify(normalizeCommandOptions(options)) !== JSON.stringify(normalizeCommandOptions(current.options))) {
    throw new RelayValidationError("options is server-owned");
  }
  const status = requireEnum(body.status ?? current.status, "command status", COMMAND_STATUSES);
  validateCommandTransition(current.status, status);
  if (body.lastExitCode != null && !Number.isInteger(body.lastExitCode)) {
    throw new RelayValidationError("lastExitCode must be an integer or null");
  }
  return normalizeCommand({
    ...current,
    status,
    updatedAt: new Date().toISOString(),
    lastExitCode: body.lastExitCode ?? current.lastExitCode,
    loginRequired: body.loginRequired ?? current.loginRequired,
    summary: body.summary ?? current.summary,
  }, status);
}

function validateCommandOptions(raw) {
  if (raw == null) return {};
  const options = requireObject(raw, "options");
  for (const key of Object.keys(options)) {
    if (!COMMAND_OPTION_KEYS.has(key)) throw new RelayValidationError(`unsupported command option: ${key}`);
    if (typeof options[key] !== "boolean") throw new RelayValidationError(`${key} must be a boolean`);
  }
  for (const [camel, snake] of [["updateNoticeNotes", "update_notice_notes"], ["dryRun", "dry_run"]]) {
    if (camel in options && snake in options && options[camel] !== options[snake]) {
      throw new RelayValidationError(`${camel} and ${snake} must match`);
    }
  }
  return options;
}

function validateCommandTransition(from, to) {
  if (from === to) return;
  if (!COMMAND_STATUSES.has(from)) throw new RelayValidationError("stored command status is invalid");
  if (!["pending", "running"].includes(from) && ["pending", "running"].includes(to)) {
    throw new RelayValidationError("terminal command cannot become active");
  }
}

function assertMatchingImmutable(value, current, field, options = {}) {
  if (value == null || value === "") return;
  let incoming = value;
  let stored = current;
  if (options.uuid) {
    incoming = requireUUID(value, field);
    stored = requireUUID(current, field);
  } else if (options.date) {
    incoming = validateOptionalISODate(value, field);
    stored = validateOptionalISODate(current, field);
  }
  if (String(incoming) !== String(stored)) {
    throw new RelayValidationError(`${field} is server-owned`);
  }
}

function clientItemActionFromBody(raw, idempotencyKey = "") {
  const body = requireObject(raw);
  const now = new Date().toISOString();
  const action = requireEnum(body.action, "item action", ITEM_ACTION_KINDS);
  const serverDerivedStatus = body.status === "completed"
    && ["calendarCreate", "calendarEdit", "calendarDelete"].includes(action)
    ? "completed"
    : "pending";
  return normalizeItemAction({
    id: normalizeUUIDText(body.id) || crypto.randomUUID(),
    _idempotencyKey: idempotencyKey,
    action,
    itemID: validateTextLength(body.itemID ?? body.itemId, "itemID", MAX_IDENTIFIER_CHARS, { required: true }),
    itemKind: requireEnum(body.itemKind, "itemKind", ITEM_KINDS),
    itemTitle: validateTextLength(body.itemTitle, "itemTitle", MAX_PUBLIC_TEXT_CHARS),
    status: serverDerivedStatus,
    createdAt: now,
    updatedAt: now,
    message: "",
  }, serverDerivedStatus);
}

function itemActionIdempotencyKey(request, body) {
  const headerValue = String(request?.headers?.["idempotency-key"] || "").trim();
  if (headerValue) {
    if (!/^[A-Za-z0-9._:-]{8,128}$/.test(headerValue)) {
      throw new RelayValidationError("Idempotency-Key must be 8-128 safe ASCII characters");
    }
    return `header:${headerValue}`;
  }
  const clientID = normalizeUUIDText(body?.id);
  return clientID ? `item-action:${clientID}` : "";
}

function sameItemActionIntent(lhs, rhs) {
  return lhs.action === rhs.action
    && lhs.itemID === rhs.itemID
    && lhs.itemKind === rhs.itemKind;
}

function applyWorkerItemActionPatch(current, raw) {
  const body = requireObject(raw);
  assertMatchingImmutable(body.id, current.id, "id", { uuid: true });
  assertMatchingImmutable(body.action, current.action, "action");
  assertMatchingImmutable(body.itemID ?? body.itemId, current.itemID, "itemID");
  assertMatchingImmutable(body.itemKind, current.itemKind, "itemKind");
  const status = requireEnum(body.status ?? current.status, "item action status", ACTION_STATUSES);
  return normalizeItemAction({
    ...current,
    _idempotencyKey: actionIdempotencyKey(current),
    status,
    updatedAt: new Date().toISOString(),
    message: validateTextLength(body.message ?? current.message, "message", MAX_PUBLIC_TEXT_CHARS),
  }, status);
}

function clientSettingActionFromBody(raw) {
  const body = requireObject(raw);
  const now = new Date().toISOString();
  const key = validateTextLength(body.key, "setting key", 128, { required: true });
  if (!SYNC_SETTING_KEYS.has(sanitizeSettingKey(key))) throw new RelayValidationError("unsupported setting key");
  return normalizeSettingAction({
    id: crypto.randomUUID(),
    key,
    value: validateTextLength(body.value, "setting value", MAX_PUBLIC_TEXT_CHARS),
    title: validateTextLength(body.title, "setting title", 256),
    status: "pending",
    createdAt: now,
    updatedAt: now,
    message: "",
  }, "pending");
}

function applyWorkerSettingActionPatch(current, raw) {
  const body = requireObject(raw);
  assertMatchingImmutable(body.id, current.id, "id", { uuid: true });
  assertMatchingImmutable(body.key, current.key, "key");
  assertMatchingImmutable(body.value, current.value, "value");
  const status = requireEnum(body.status ?? current.status, "setting action status", ACTION_STATUSES);
  return normalizeSettingAction({
    ...current,
    status,
    updatedAt: new Date().toISOString(),
    message: validateTextLength(body.message ?? current.message, "message", MAX_PUBLIC_TEXT_CHARS),
  }, status);
}

function clientFileAccessFromBody(raw) {
  const body = requireObject(raw);
  const now = new Date().toISOString();
  return normalizeFileAccessRequest({
    id: crypto.randomUUID(),
    itemID: validateTextLength(body.itemID ?? body.itemId, "itemID", MAX_IDENTIFIER_CHARS, { required: true }),
    itemKind: requireEnum(body.itemKind ?? "file", "itemKind", new Set(["file"])),
    itemTitle: validateTextLength(body.itemTitle, "itemTitle", MAX_PUBLIC_TEXT_CHARS),
    status: "pending",
    createdAt: now,
    updatedAt: now,
    message: "",
  }, "pending");
}

function applyWorkerFileAccessPatch(current, raw) {
  const body = requireObject(raw);
  for (const field of ["objectKey", "object_key", "downloadTicket", "download_ticket", "expiresAt", "expires_at", "sizeBytes", "size_bytes", "downloadCount", "download_count", "contentType", "content_type"]) {
    if (Object.prototype.hasOwnProperty.call(body, field)) {
      throw new RelayValidationError(`${field} is server-owned`);
    }
  }
  assertMatchingImmutable(body.id, current.id, "id", { uuid: true });
  assertMatchingImmutable(body.itemID ?? body.itemId, current.itemID, "itemID");
  assertMatchingImmutable(body.itemKind, current.itemKind, "itemKind");
  const status = requireEnum(body.status ?? current.status, "file access status", FILE_ACCESS_STATUSES);
  if (status === "completed" && !current.objectKey) {
    throw new RelayValidationError("completed file access requires the upload endpoint");
  }
  return normalizeFileAccessRequest({
    ...current,
    status,
    updatedAt: new Date().toISOString(),
    message: validateTextLength(body.message ?? current.message, "message", MAX_PUBLIC_TEXT_CHARS),
  }, status);
}

function isValidStoredCommand(raw) {
  return Boolean(
    normalizeUUIDText(raw?.id)
    && COMMAND_KINDS.has(String(raw?.kind || ""))
    && COMMAND_STATUSES.has(String(raw?.status || ""))
    && Number.isFinite(Date.parse(raw?.createdAt || raw?.created_at || ""))
    && Number.isFinite(Date.parse(raw?.updatedAt || raw?.updated_at || ""))
  );
}

function isValidStoredItemAction(raw) {
  return Boolean(
    normalizeUUIDText(raw?.id)
    && ITEM_ACTION_KINDS.has(String(raw?.action || ""))
    && ACTION_STATUSES.has(String(raw?.status || ""))
    && ITEM_KINDS.has(String(raw?.itemKind || raw?.item_kind || ""))
    && String(raw?.itemID || raw?.item_id || "").trim()
    && Number.isFinite(Date.parse(raw?.createdAt || raw?.created_at || ""))
    && Number.isFinite(Date.parse(raw?.updatedAt || raw?.updated_at || ""))
  );
}

function isValidStoredSettingAction(raw) {
  return Boolean(
    normalizeUUIDText(raw?.id)
    && SYNC_SETTING_KEYS.has(sanitizeSettingKey(raw?.key))
    && ACTION_STATUSES.has(String(raw?.status || ""))
    && Number.isFinite(Date.parse(raw?.createdAt || raw?.created_at || ""))
    && Number.isFinite(Date.parse(raw?.updatedAt || raw?.updated_at || ""))
  );
}

function isValidStoredFileAccess(raw) {
  const objectKey = raw?.objectKey || raw?.object_key;
  return Boolean(
    normalizeUUIDText(raw?.id)
    && String(raw?.itemID || raw?.item_id || "").trim()
    && String(raw?.itemKind || raw?.item_kind || "") === "file"
    && FILE_ACCESS_STATUSES.has(String(raw?.status || ""))
    && Number.isFinite(Date.parse(raw?.createdAt || raw?.created_at || ""))
    && Number.isFinite(Date.parse(raw?.updatedAt || raw?.updated_at || ""))
    && (!objectKey || isValidFileObjectKey(objectKey, raw?.id))
  );
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
  const normalized = {
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
  const key = String(raw._idempotencyKey || raw.idempotency_key || "").trim();
  if (key) {
    Object.defineProperty(normalized, "_idempotencyKey", {
      value: key,
      writable: true,
      configurable: true,
      enumerable: false,
    });
  }
  return normalized;
}

function actionIdempotencyKey(action) {
  return String(action?._idempotencyKey || "").trim();
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

function displayLogClearTimes() {
  return {
    command: getMeta("displayCommandLogClearedAt"),
    requestLog: getMeta("displayRequestLogClearedAt"),
    fileAccess: getMeta("displayFileAccessLogClearedAt"),
    itemActions: getMeta("displayItemActionLogClearedAt"),
    settingActions: getMeta("displaySettingActionLogClearedAt"),
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

function filterDisplayItemActions(actions, clearedAt) {
  const clearTime = Date.parse(clearedAt || "") || 0;
  if (clearTime <= 0) {
    return actions;
  }
  return actions.filter((action) => (
    action.status === "pending"
    || action.status === "running"
    || (Date.parse(action.updatedAt) || 0) > clearTime
  ));
}

function filterDisplaySettingActions(actions, clearedAt) {
  const clearTime = Date.parse(clearedAt || "") || 0;
  if (clearTime <= 0) {
    return actions;
  }
  return actions.filter((action) => (
    action.status === "pending"
    || action.status === "running"
    || (Date.parse(action.updatedAt) || 0) > clearTime
  ));
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
  if (loadFileAccessRequests({
    statuses: ["pending", "running"],
    order: "created",
    limit: 1,
  }).length > 0) {
    return true;
  }
  return Boolean(db.prepare("SELECT 1 AS active FROM file_download_reservations LIMIT 1").get());
}

function normalizeLogClearScope(value) {
  const text = String(value || "").trim().toLowerCase();
  if (!text || text === "all") return "all";
  if (["requestlog", "request-log", "request", "server", "serverrequest", "server-request"].includes(text)) {
    return "requestLog";
  }
  if (["command", "commands", "run", "runs", "recent", "recentcommand", "recent-command", "recentcommands", "recent-commands"].includes(text)) {
    return "command";
  }
  if (["fileaccess", "file-access", "file", "files"].includes(text)) {
    return "fileAccess";
  }
  return null;
}

function clearDisplayLogs(scope = "all") {
  const clearedAt = new Date().toISOString();
  const shouldClearAll = scope === "all";
  const shouldClearCommands = shouldClearAll || scope === "command";
  const shouldClearRequestLog = shouldClearAll || scope === "requestLog";
  const shouldClearFileAccess = shouldClearAll || scope === "fileAccess";
  const requestLog = shouldClearRequestLog ? loadRequestLog() : [];
  const fileAccessRows = shouldClearFileAccess
    ? loadFileAccessRequests({ limit: MAX_FILE_ACCESS_REQUESTS })
    : [];
  const result = {
    clearedAt,
    commands: shouldClearCommands
      ? state.commands.filter((command) => command.status !== "pending" && command.status !== "running").length
      : 0,
    itemActions: shouldClearAll
      ? filterDisplayItemActions(state.itemActions, "").filter((action) => action.status !== "pending" && action.status !== "running").length
      : 0,
    settingActions: shouldClearAll
      ? filterDisplaySettingActions(state.settingActions || [], "").filter((action) => action.status !== "pending" && action.status !== "running").length
      : 0,
    fileAccessRequests: shouldClearFileAccess
      ? fileAccessRows.filter((request) => request.status !== "pending" && request.status !== "running").length
      : 0,
    requestLogEntries: requestLog.length,
  };
  commitRelayMutation(`logs-display:${scope}`, clearedAt, () => {
    if (shouldClearCommands) {
      setMeta("displayCommandLogClearedAt", clearedAt);
    }
    if (shouldClearRequestLog) {
      setMeta("displayRequestLogClearedAt", clearedAt);
    }
    if (shouldClearFileAccess) {
      setMeta("displayFileAccessLogClearedAt", clearedAt);
    }
    if (shouldClearAll) {
      setMeta("displayItemActionLogClearedAt", clearedAt);
      setMeta("displaySettingActionLogClearedAt", clearedAt);
    }
  });
  return result;
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
  const deletionCandidates = fileAccessRowsToClear
    .map(claimTerminalFileAccessDeletion)
    .filter(Boolean);
  const deletionResults = [];
  let claimsCommitted = false;
  try {
    for (const candidate of deletionCandidates) {
      if (!candidate.objectKey) {
        deletionResults.push({ ...candidate, deleted: true });
        continue;
      }
      try {
        await delayFileDeletionForTest();
        await fs.unlink(localFileObjectPath(candidate.objectKey, candidate.id));
        deletionResults.push({ ...candidate, deleted: true });
      } catch (error) {
        if (error?.code === "ENOENT") deletionResults.push({ ...candidate, deleted: true });
        else {
          console.error("failed to delete file access object while clearing logs", error);
          deletionResults.push({ ...candidate, deleted: false });
        }
      }
    }

    // File deletion can yield to unrelated requests. Snapshot the current in-memory
    // state only after I/O so a concurrent command/status update is never rolled back.
    const requestLog = shouldClearRequestLog ? loadRequestLog() : [];
    const nextState = {
      ...state,
      commands: state.commands.slice(),
      itemActions: state.itemActions.slice(),
      settingActions: (state.settingActions || []).slice(),
    };
    const result = {
      clearedAt,
      commands: shouldClearCommands
        ? nextState.commands.filter((command) => command.status !== "pending" && command.status !== "running").length
        : 0,
      itemActions: shouldClearAll
        ? nextState.itemActions.filter((action) => action.status !== "pending" && action.status !== "running").length
        : 0,
      settingActions: shouldClearAll
        ? nextState.settingActions.filter((action) => action.status !== "pending" && action.status !== "running").length
        : 0,
      fileAccessRequests: 0,
      requestLogEntries: requestLog.length,
    };
    if (shouldClearCommands) {
      nextState.commands = nextState.commands.filter((command) => command.status === "pending" || command.status === "running");
      nextState.latestCommand = nextState.commands[0] || null;
      nextState.running = nextState.commands.some((command) => command.status === "running")
        || nextState.running && Boolean(nextState.latestCommand);
      nextState.message = "최근 실행 요청 기록을 지웠습니다.";
      nextState.updatedAt = clearedAt;
    }
    if (shouldClearAll) {
      nextState.itemActions = nextState.itemActions.filter((action) => action.status === "pending" || action.status === "running");
      nextState.settingActions = nextState.settingActions.filter((action) => action.status === "pending" || action.status === "running");
      nextState.message = "로그를 지웠습니다.";
      nextState.updatedAt = clearedAt;
    }

    commitRelayMutation(`logs:${scope}`, clearedAt, () => {
      if (shouldClearCommands) {
        db.prepare("DELETE FROM commands WHERE status NOT IN ('pending', 'running')").run();
      }
      if (shouldClearAll) {
        db.prepare("DELETE FROM item_actions WHERE status NOT IN ('pending', 'running')").run();
        setMeta("settingActions", JSON.stringify(nextState.settingActions));
      }
      if (shouldClearFileAccess) {
        for (const candidate of deletionResults) {
          if (candidate.deleted && deleteTerminalFileAccessClaim(candidate)) {
            result.fileAccessRequests += 1;
          } else {
            releaseFileAccessDeletionClaim(candidate);
          }
        }
      }
      if (shouldClearRequestLog) {
        setMeta("requestLog", "[]");
      }
      if (shouldClearCommands || shouldClearAll) {
        writeStateToDatabase(nextState);
      }
    });
    claimsCommitted = true;
    if (shouldClearCommands || shouldClearAll) state = nextState;
    return result;
  } finally {
    if (!claimsCommitted) {
      for (const candidate of deletionCandidates) releaseFileAccessDeletionClaim(candidate);
    }
  }
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
  return "알 수 없음";
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

function validDownloadTicket(value) {
  return /^(?:[A-Za-z0-9_-]{32}|[0-9a-fA-F]{64})$/.test(String(value || "").trim());
}

function downloadCapabilityFromRequest(request) {
  const authorization = String(request?.headers?.authorization || "").trim();
  const match = authorization.match(/^Bearer ([A-Za-z0-9_-]{32}|[0-9a-fA-F]{64})$/);
  return match?.[1] || "";
}

function normalizeStatus(raw, fallbackPhase) {
  const source = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  const status = { ...defaultStatus };
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
    status[key] = boundedInt(source[key], 0, 0, 1_000_000);
  }
  const requestedPhase = String(fallbackPhase || source.phase || "idle");
  status.phase = STATUS_PHASES.has(requestedPhase) ? requestedPhase : "idle";
  status.phaseDetail = sanitizePublicText(source.phaseDetail) || null;
  status.loginRequired = normalizeBoolean(source.loginRequired);
  const authDigits = String(source.authDigits ?? "").trim();
  status.authDigits = status.loginRequired && /^\d{1,3}$/.test(authDigits) ? authDigits : null;
  status.authStatusMessage = sanitizePublicText(source.authStatusMessage) || null;
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
  state.itemActions = boundedItemActions(state.itemActions);
}

function itemActionIsActive(action) {
  return action?.status === "pending" || action?.status === "running";
}

function compareItemActionNewest(lhs, rhs) {
  const timestampDifference = (Date.parse(rhs.updatedAt) || 0) - (Date.parse(lhs.updatedAt) || 0);
  if (timestampDifference !== 0) return timestampDifference;
  return String(rhs.id || "").localeCompare(String(lhs.id || ""));
}

function boundedItemActions(actions) {
  const seen = new Set();
  const unique = actions
    .slice()
    .sort(compareItemActionNewest)
    .filter((action) => {
      const id = String(action?.id || "").toLowerCase();
      if (!id || seen.has(id)) return false;
      action.id = id;
      seen.add(id);
      return true;
    });
  const active = unique.filter(itemActionIsActive);
  const terminal = unique.filter((action) => !itemActionIsActive(action));
  return [...active, ...terminal.slice(0, Math.max(0, MAX_ITEM_ACTIONS - active.length))]
    .sort(compareItemActionNewest);
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

function isActiveCommandConstraintError(error) {
  const message = String(error?.message || error || "").toLowerCase();
  return message.includes("unique")
    && (message.includes("commands_one_active") || message.includes("commands"));
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
  state.latestCommand = cancelled;
  state.status = cancelled.summary;
  state.running = false;
  state.message = `${displayCommandName(cancelled.kind)} · ${displayStatus(cancelled.status)}`;
  state.updatedAt = cancelled.updatedAt;
  await saveState("commands:cancelled", () => {
    clearCancelRequest();
    appendRequestLog(request, {
      action: "원격 실행 요청 취소",
      status: "cancelled",
      message,
    });
  });
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
    const status = String(action.status || "").toLowerCase();
    const pendingStale = status === "pending" && ageMs(action.createdAt, now) > STALE_PENDING_ITEM_ACTION_MS;
    const runningStale = status === "running" && ageMs(action.updatedAt || action.createdAt, now) > STALE_RUNNING_ITEM_ACTION_MS;
    if (pendingStale || runningStale) {
      action.status = "macUnavailable";
      action.updatedAt = new Date().toISOString();
      action.message = runningStale
        ? "Mac 앱이 처리 중 멈춘 것 같습니다. 다시 요청해 주세요."
        : "Mac 앱이 제한 시간 안에 처리하지 않았습니다.";
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
    const status = String(action.status || "").toLowerCase();
    const pendingStale = status === "pending" && ageMs(action.createdAt, now) > STALE_PENDING_SETTING_ACTION_MS;
    const runningStale = status === "running" && ageMs(action.updatedAt || action.createdAt, now) > STALE_RUNNING_SETTING_ACTION_MS;
    if (pendingStale || runningStale) {
      action.status = "macUnavailable";
      action.updatedAt = new Date().toISOString();
      action.message = runningStale
        ? "Mac 앱이 설정 반영 중 멈춘 것 같습니다. 다시 요청해 주세요."
        : "Mac 앱이 제한 시간 안에 처리하지 않았습니다.";
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

function requestRemoteAddress(request) {
  const socketAddress = normalizeRateLimitAddress(request.socket?.remoteAddress);
  if (!TRUSTED_PROXY_SECRET) return socketAddress;

  const suppliedSecret = singleRequestHeader(request, "x-klms-relay-proxy-secret");
  const forwardedAddress = normalizeRateLimitAddress(
    singleRequestHeader(request, "x-klms-relay-client-ip"),
    { allowUnknown: false },
  );
  if (!suppliedSecret || !forwardedAddress) return socketAddress;
  const actual = Buffer.from(suppliedSecret);
  return tokenMatches(actual, TRUSTED_PROXY_SECRET) ? forwardedAddress : socketAddress;
}

function rateLimitedAuthorization(request, role, scope) {
  const isAuthorized = authorized(request, role);
  const identity = isAuthorized
    ? `authorized:${role}`
    : `unauthorized:${requestRemoteAddress(request)}`;
  return {
    authorized: isAuthorized,
    allowed: consumeRequestRateLimit(scope, identity, isAuthorized),
  };
}

function consumeRequestRateLimit(scope, identity, isAuthorized) {
  const key = `${scope}:${identity}`;
  return consumeBoundedRateWindow(
    isAuthorized ? authorizedRequestRateWindows : unauthorizedRequestRateWindows,
    key,
    REQUESTS_PER_MINUTE,
    isAuthorized ? MAX_AUTHORIZED_REQUEST_RATE_WINDOWS : MAX_UNAUTHORIZED_REQUEST_RATE_WINDOWS,
  );
}

function singleRequestHeader(request, name) {
  const value = request.headers[name];
  return typeof value === "string" ? value.trim() : "";
}

function normalizeRateLimitAddress(value, { allowUnknown = true } = {}) {
  const candidate = String(value || "").trim();
  if (candidate && isIP(candidate)) return candidate.toLowerCase();
  return allowUnknown ? "unknown" : "";
}

function consumePublicDownloadIngressRateLimit(request) {
  return consumeBoundedRateWindow(
    publicDownloadIngressRateWindows,
    requestRemoteAddress(request),
    PUBLIC_DOWNLOAD_INGRESS_PER_MINUTE,
    MAX_PUBLIC_DOWNLOAD_INGRESS_WINDOWS,
  );
}

function consumePublicDownloadLinkRateLimit(id) {
  return consumeBoundedRateWindow(
    publicDownloadLinkRateWindows,
    id.toLowerCase(),
    PUBLIC_DOWNLOAD_LINKS_PER_MINUTE,
    MAX_PUBLIC_DOWNLOAD_LINK_WINDOWS,
  );
}

function handleWebSocketUpgrade(request, socket, head) {
  try {
    const url = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);
    if (url.pathname !== "/v1/events") {
      rejectWebSocketUpgrade(socket, 404, "not found");
      return;
    }
    const role = parseRealtimeRole(url.searchParams.get("role"));
    if (!role) {
      rejectWebSocketUpgrade(socket, 400, "role must be client or worker");
      return;
    }
    const access = rateLimitedAuthorization(
      request,
      role === "worker" ? "worker" : "client",
      `${role}-realtime`
    );
    if (!access.allowed) {
      rejectWebSocketUpgrade(socket, 429, "request rate limit exceeded", { "Retry-After": "60" });
      return;
    }
    if (!access.authorized) {
      rejectWebSocketUpgrade(socket, 401, "unauthorized");
      return;
    }
    if (realtimeClients.size >= MAX_REALTIME_CONNECTIONS) {
      rejectWebSocketUpgrade(socket, 429, "too many realtime connections");
      return;
    }
    if (String(request.headers.upgrade || "").toLowerCase() !== "websocket"
        || String(request.headers["sec-websocket-version"] || "") !== "13") {
      rejectWebSocketUpgrade(socket, 426, "websocket upgrade required", { "Sec-WebSocket-Version": "13" });
      return;
    }
    const key = String(request.headers["sec-websocket-key"] || "").trim();
    let keyBytes;
    try {
      keyBytes = Buffer.from(key, "base64");
    } catch {
      keyBytes = Buffer.alloc(0);
    }
    if (keyBytes.length !== 16) {
      rejectWebSocketUpgrade(socket, 400, "invalid websocket key");
      return;
    }
    const accept = crypto.createHash("sha1")
      .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest("base64");
    socket.write([
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      `Sec-WebSocket-Accept: ${accept}`,
      "\r\n",
    ].join("\r\n"));
    const client = {
      socket,
      role,
      request,
      sessionID: crypto.randomUUID(),
      pendingSnapshot: null,
      queuedBroadcast: null,
      queuedManualRequest: null,
      outboundSequence: 0,
      buffer: Buffer.alloc(0),
    };
    realtimeClients.add(client);
    const hello = relayEventEnvelope({
      type: "hello",
      revision: currentRelayRevision(),
      reason: "connected",
      scopes: [],
      delta: {},
      requiresSnapshot: false,
      sentAt: new Date().toISOString(),
      sessionID: client.sessionID,
    });
    socket.write(encodeWebSocketFrame(JSON.stringify(hello)));
    socket.on("data", (chunk) => handleWebSocketData(client, chunk));
    socket.on("close", () => realtimeClients.delete(client));
    socket.on("end", () => realtimeClients.delete(client));
    socket.on("error", () => realtimeClients.delete(client));
    if (head?.length) handleWebSocketData(client, head);
  } catch (error) {
    console.error("websocket upgrade failed", error);
    socket.destroy();
  }
}

function rejectWebSocketUpgrade(socket, status, message, extraHeaders = {}) {
  const labels = { 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 426: "Upgrade Required", 429: "Too Many Requests" };
  const body = JSON.stringify({ error: message });
  const headers = Object.entries(extraHeaders).map(([key, value]) => `${key}: ${value}`);
  socket.end([
    `HTTP/1.1 ${status} ${labels[status] || "Error"}`,
    "Content-Type: application/json; charset=utf-8",
    `Content-Length: ${Buffer.byteLength(body)}`,
    "Connection: close",
    ...headers,
    "",
    body,
  ].join("\r\n"));
}

function handleWebSocketData(client, chunk) {
  client.buffer = Buffer.concat([client.buffer, chunk]);
  while (client.buffer.length >= 2) {
    const first = client.buffer[0];
    const second = client.buffer[1];
    const final = Boolean(first & 0x80);
    const opcode = first & 0x0f;
    const masked = Boolean(second & 0x80);
    let length = second & 0x7f;
    let offset = 2;
    if (!final || !masked) {
      closeWebSocketClient(client, 1002, "invalid frame");
      return;
    }
    if (length === 126) {
      if (client.buffer.length < 4) return;
      length = client.buffer.readUInt16BE(2);
      offset = 4;
    } else if (length === 127) {
      if (client.buffer.length < 10) return;
      const largeLength = client.buffer.readBigUInt64BE(2);
      if (largeLength > BigInt(MAX_REALTIME_MESSAGE_BYTES)) {
        closeWebSocketClient(client, 1009, "message too large");
        return;
      }
      length = Number(largeLength);
      offset = 10;
    }
    if (length > MAX_REALTIME_MESSAGE_BYTES) {
      closeWebSocketClient(client, 1009, "message too large");
      return;
    }
    if (client.buffer.length < offset + 4 + length) return;
    const mask = client.buffer.subarray(offset, offset + 4);
    offset += 4;
    const payload = Buffer.from(client.buffer.subarray(offset, offset + length));
    client.buffer = client.buffer.subarray(offset + length);
    for (let index = 0; index < payload.length; index += 1) payload[index] ^= mask[index % 4];
    if (opcode === 0x8) {
      client.socket.end(encodeWebSocketFrame(payload, 0x8));
      realtimeClients.delete(client);
      return;
    }
    if (opcode === 0x9) {
      client.socket.write(encodeWebSocketFrame(payload, 0xA));
      continue;
    }
    if (opcode !== 0x1) continue;
    const text = payload.toString("utf8");
    let message = null;
    let isPing = text === "ping";
    if (!isPing) {
      try {
        message = JSON.parse(text);
        isPing = message?.type === "ping";
      } catch {
        closeWebSocketClient(client, 1002, "invalid JSON message");
        return;
      }
    }
    if (isPing) {
      client.socket.write(encodeWebSocketFrame(JSON.stringify(relayEventEnvelope({
        type: "pong",
        revision: currentRelayRevision(),
        reason: "heartbeat",
        scopes: [],
        delta: {},
        requiresSnapshot: false,
        sentAt: new Date().toISOString(),
        sessionID: client.sessionID,
      }))));
      continue;
    }
    if (message?.type === "snapshot-ready") {
      handleRealtimeSnapshotReady(client, message);
      continue;
    }
    if (message?.type === "snapshot-request") {
      handleRealtimeSnapshotRequest(client, message);
      continue;
    }
    closeWebSocketClient(client, 1002, "unsupported message");
    return;
  }
}

function handleRealtimeSnapshotRequest(client, message) {
  if (message?.version !== REALTIME_EVENT_VERSION
      || message?.sessionID !== client.sessionID
      || !normalizeUUIDText(message?.requestID)
      || !Number.isSafeInteger(message?.revision)
      || message.revision < 0) {
    closeWebSocketClient(client, 1002, "invalid snapshot request");
    return;
  }
  const scopes = normalizedRealtimeScopes(message.scopes, { allowEmpty: false });
  if (!scopes) {
    closeWebSocketClient(client, 1002, "invalid snapshot scopes");
    return;
  }
  const revision = currentRelayRevision();
  if (revision < message.revision) {
    closeWebSocketClient(client, 1002, "snapshot revision moved backwards");
    return;
  }
  const request = {
    scopes,
    requestID: message.requestID,
    requestedRevision: message.revision,
    sequence: ++client.outboundSequence,
  };
  if (client.pendingSnapshot) {
    if (client.queuedManualRequest) {
      closeWebSocketClient(client, 1013, "snapshot request queue capacity exceeded");
      return;
    }
    client.queuedManualRequest = request;
    return;
  }
  startRealtimeManualSnapshot(client, request);
}

function handleRealtimeSnapshotReady(client, message) {
  const pending = client.pendingSnapshot;
  if (!pending
      || message?.version !== REALTIME_EVENT_VERSION
      || message?.sessionID !== client.sessionID
      || message?.streamID !== pending.streamID
      || message?.revision !== pending.revision
      || message?.reservedFrames !== pending.reservedFrames
      || message?.reservedWireBytes !== pending.reservedWireBytes) {
    closeWebSocketClient(client, 1002, "snapshot ready mismatch");
    return;
  }
  client.pendingSnapshot = null;
  for (const frameText of pending.dataFrames) {
    if (!client.socket.writable || client.socket.destroyed) return;
    if (client.socket.writableLength + Buffer.byteLength(frameText) > MAX_REALTIME_SNAPSHOT_BYTES) {
      closeWebSocketClient(client, 1013, "snapshot queue capacity exceeded");
      return;
    }
    client.socket.write(encodeWebSocketFrame(frameText));
  }
  drainRealtimeSnapshotQueue(client);
}

function closeWebSocketClient(client, code, reason) {
  client.pendingSnapshot = null;
  client.queuedBroadcast = null;
  client.queuedManualRequest = null;
  const reasonBytes = Buffer.from(String(reason || "").slice(0, 120));
  const payload = Buffer.alloc(2 + reasonBytes.length);
  payload.writeUInt16BE(code, 0);
  reasonBytes.copy(payload, 2);
  try {
    client.socket.end(encodeWebSocketFrame(payload, 0x8));
  } catch {
    client.socket.destroy();
  }
  realtimeClients.delete(client);
}

function encodeWebSocketFrame(value, opcode = 0x1) {
  const payload = Buffer.isBuffer(value) ? value : Buffer.from(String(value));
  if (payload.length < 126) {
    return Buffer.concat([Buffer.from([0x80 | opcode, payload.length]), payload]);
  }
  if (payload.length <= 0xffff) {
    const header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(payload.length, 2);
    return Buffer.concat([header, payload]);
  }
  const header = Buffer.alloc(10);
  header[0] = 0x80 | opcode;
  header[1] = 127;
  header.writeBigUInt64BE(BigInt(payload.length), 2);
  return Buffer.concat([header, payload]);
}

function tokenMatches(actual, expectedToken) {
  const expected = Buffer.from(expectedToken);
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
}

async function readJSON(request) {
  const contentLength = Number.parseInt(String(request.headers["content-length"] || "0"), 10);
  if (Number.isFinite(contentLength) && contentLength > MAX_BODY_BYTES) {
    throw new RelayPayloadTooLargeError(`request body exceeds ${MAX_BODY_BYTES} bytes`);
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      throw new RelayPayloadTooLargeError(`request body exceeds ${MAX_BODY_BYTES} bytes`);
    }
    chunks.push(chunk);
  }
  if (chunks.length === 0) {
    return {};
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new RelayValidationError("request body must be valid JSON");
  }
}

async function readRawBody(request, maxBytes) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxBytes) {
      throw new RelayPayloadTooLargeError(`request body exceeds ${maxBytes} bytes`);
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

function sendRateLimitResponse(response) {
  const body = JSON.stringify({ error: "request rate limit exceeded" });
  response.writeHead(429, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Retry-After": "60",
  });
  response.end(body);
}

function initDatabase() {
  const commandKindsSQL = [...COMMAND_KINDS]
    .map((kind) => `'${kind.replaceAll("'", "''")}'`)
    .join(", ");
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
    UPDATE commands
      SET status = 'macUnavailable',
          updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
      WHERE status IN ('pending', 'running')
        AND (
          length(id) <> 36
          OR substr(id, 9, 1) <> '-'
          OR substr(id, 14, 1) <> '-'
          OR substr(id, 19, 1) <> '-'
          OR substr(id, 24, 1) <> '-'
          OR length(replace(id, '-', '')) <> 32
          OR lower(replace(id, '-', '')) GLOB '*[^0-9a-f]*'
          OR kind NOT IN (${commandKindsSQL})
          OR length(created_at) <> 24
          OR substr(created_at, 5, 1) <> '-'
          OR substr(created_at, 8, 1) <> '-'
          OR substr(created_at, 11, 1) <> 'T'
          OR substr(created_at, 14, 1) <> ':'
          OR substr(created_at, 17, 1) <> ':'
          OR substr(created_at, 20, 1) <> '.'
          OR substr(created_at, 24, 1) <> 'Z'
          OR (
            substr(created_at, 1, 4) || substr(created_at, 6, 2) || substr(created_at, 9, 2)
            || substr(created_at, 12, 2) || substr(created_at, 15, 2) || substr(created_at, 18, 2)
            || substr(created_at, 21, 3)
          ) GLOB '*[^0-9]*'
          OR julianday(created_at) IS NULL
          OR length(updated_at) <> 24
          OR substr(updated_at, 5, 1) <> '-'
          OR substr(updated_at, 8, 1) <> '-'
          OR substr(updated_at, 11, 1) <> 'T'
          OR substr(updated_at, 14, 1) <> ':'
          OR substr(updated_at, 17, 1) <> ':'
          OR substr(updated_at, 20, 1) <> '.'
          OR substr(updated_at, 24, 1) <> 'Z'
          OR (
            substr(updated_at, 1, 4) || substr(updated_at, 6, 2) || substr(updated_at, 9, 2)
            || substr(updated_at, 12, 2) || substr(updated_at, 15, 2) || substr(updated_at, 18, 2)
            || substr(updated_at, 21, 3)
          ) GLOB '*[^0-9]*'
          OR julianday(updated_at) IS NULL
        );
    UPDATE commands
      SET status = 'macUnavailable', updated_at = datetime('now')
      WHERE status IN ('pending', 'running')
        AND id NOT IN (
          SELECT id FROM commands
          WHERE status IN ('pending', 'running')
          ORDER BY updated_at DESC
          LIMIT 1
        );
    CREATE UNIQUE INDEX IF NOT EXISTS commands_one_active_idx
      ON commands((1))
      WHERE status IN ('pending', 'running');
    CREATE TABLE IF NOT EXISTS item_actions (
      id TEXT PRIMARY KEY,
      idempotency_key TEXT,
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
      download_count INTEGER NOT NULL DEFAULT 0,
      upload_claim TEXT,
      pending_object_key TEXT,
      reserved_upload_bytes INTEGER NOT NULL DEFAULT 0,
      reserved_upload_quota_key TEXT
    );
    CREATE INDEX IF NOT EXISTS file_access_requests_status_created_at_idx
      ON file_access_requests(status, created_at ASC);
    CREATE INDEX IF NOT EXISTS file_access_requests_updated_at_idx
      ON file_access_requests(updated_at DESC);
    CREATE TABLE IF NOT EXISTS file_download_reservations (
      token TEXT PRIMARY KEY,
      request_id TEXT NOT NULL,
      quota_key TEXT NOT NULL,
      log_id TEXT NOT NULL,
      log_created_at TEXT NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY(request_id) REFERENCES file_access_requests(id) ON DELETE RESTRICT
    );
    CREATE INDEX IF NOT EXISTS file_download_reservations_request_idx
      ON file_download_reservations(request_id);
    CREATE INDEX IF NOT EXISTS file_download_reservations_created_idx
      ON file_download_reservations(created_at);
  `);
  addColumnIfMissing("commands", "options_json", "TEXT NOT NULL DEFAULT '{}'");
  addColumnIfMissing("file_access_requests", "upload_claim", "TEXT");
  addColumnIfMissing("file_access_requests", "pending_object_key", "TEXT");
  addColumnIfMissing("file_access_requests", "reserved_upload_bytes", "INTEGER NOT NULL DEFAULT 0");
  addColumnIfMissing("file_access_requests", "reserved_upload_quota_key", "TEXT");
  addColumnIfMissing("item_actions", "idempotency_key", "TEXT");
  db.exec(`
    CREATE UNIQUE INDEX IF NOT EXISTS item_actions_idempotency_key_idx
      ON item_actions(idempotency_key)
      WHERE idempotency_key IS NOT NULL;
  `);
}

function addColumnIfMissing(table, column, definition) {
  const columns = new Set(db.prepare(`PRAGMA table_info(${table})`).all().map((row) => row.name));
  if (!columns.has(column)) db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`);
}

function loadState() {
  const commands = deduplicateByID(db.prepare(`
    SELECT id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json, options_json
    FROM commands
    ORDER BY updated_at DESC
    LIMIT ?
  `).all(MAX_COMMANDS * 2).map(rowToCommand).filter(Boolean), MAX_COMMANDS);
  const storedLatestCommand = parseJSON(getMeta("latestCommand"), null);
  const latestCommand = storedLatestCommand && isValidStoredCommand(storedLatestCommand)
    ? normalizeCommand(storedLatestCommand, storedLatestCommand.status || "pending")
    : commands[0] || null;
  const itemActions = boundedItemActions(db.prepare(`
    SELECT id, idempotency_key, action, item_id, item_kind, item_title, status, created_at, updated_at, message
    FROM item_actions
    ORDER BY CASE WHEN status IN ('pending', 'running') THEN 0 ELSE 1 END,
             updated_at DESC,
             id DESC
    LIMIT ?
  `).all(MAX_ITEM_ACTIONS * 2).map(rowToItemAction).filter(Boolean));
  const storedSettingActions = parseJSON(getMeta("settingActions"), []);
  return {
    status: normalizeStatus(parseJSON(getMeta("status"), defaultStatus)),
    latestCommand,
    commands,
    itemActions,
    settingActions: deduplicateByID(
      (Array.isArray(storedSettingActions) ? storedSettingActions : [])
        .filter(isValidStoredSettingAction)
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
      if (!item) return false;
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

function writeStateToDatabase(stateToPersist = state) {
    stateToPersist.itemActions = boundedItemActions(stateToPersist.itemActions || []);
    setMeta("status", JSON.stringify(normalizeStatus(stateToPersist.status || defaultStatus)));
    setMeta("latestCommand", JSON.stringify(stateToPersist.latestCommand || null));
    setMeta("running", stateToPersist.running ? "true" : "false");
    setMeta("message", String(stateToPersist.message || ""));
    setMeta("updatedAt", String(stateToPersist.updatedAt || new Date().toISOString()));
    db.prepare("DELETE FROM commands").run();
    const insertCommand = db.prepare(`
      INSERT INTO commands (
        id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json, options_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    for (const command of stateToPersist.commands.slice(0, MAX_COMMANDS)) {
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
        id, idempotency_key, action, item_id, item_kind, item_title, status, created_at, updated_at, message
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    for (const action of stateToPersist.itemActions) {
      insertItemAction.run(
        action.id,
        actionIdempotencyKey(action) || null,
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
    setMeta("settingActions", JSON.stringify((stateToPersist.settingActions || []).slice(0, MAX_SETTING_ACTIONS)));
}

function commitRelayMutation(reason = "updated", updatedAt = new Date().toISOString(), mutation = () => undefined) {
  let event;
  let result;
  db.exec("BEGIN IMMEDIATE");
  try {
    result = mutation();
    event = recordRelayEvent(reason, updatedAt);
    db.exec("COMMIT");
  } catch (error) {
    if (db.isTransaction) db.exec("ROLLBACK");
    throw error;
  }
  broadcastRelayEvent(event);
  return { event, result };
}

function saveState(reason = "state", mutation = null) {
  return commitRelayMutation(reason, state.updatedAt, () => {
    if (mutation) mutation();
    writeStateToDatabase(state);
  }).event;
}

function touchRelayEvent(reason = "updated", updatedAt = new Date().toISOString()) {
  return commitRelayMutation(reason, updatedAt).event;
}

function recordRelayEvent(reason = "updated", updatedAt = new Date().toISOString()) {
  const revision = currentRelayRevision() + 1;
  const sentAt = sanitizePublicText(updatedAt) || new Date().toISOString();
  const normalizedReason = sanitizePublicText(reason) || "updated";
  const event = relayEventEnvelope({
    type: "changed",
    revision,
    reason: normalizedReason,
    scopes: relayScopesForReason(normalizedReason),
    delta: {},
    requiresSnapshot: relayEventRequiresSnapshot(normalizedReason),
    sentAt,
  });
  setMeta("relayRevision", String(revision));
  setMeta("relayEventUpdatedAt", sentAt);
  setMeta("relayEventReason", normalizedReason);
  setMeta("relayEventEnvelope", JSON.stringify(event));
  return event;
}

function currentRelayRevision() {
  const revision = Number.parseInt(getMeta("relayRevision") || "0", 10);
  return Number.isSafeInteger(revision) && revision >= 0 ? revision : 0;
}

function relayEventEnvelope({ type, revision, reason, scopes = [], delta = {}, requiresSnapshot = false, sentAt, sessionID }) {
  const event = {
    version: REALTIME_EVENT_VERSION,
    type,
    revision,
    eventID: crypto.randomUUID(),
    reason,
    scopes: scopes.filter((scope) => REALTIME_SCOPES.has(scope)),
    delta: delta && typeof delta === "object" && !Array.isArray(delta) ? delta : {},
    requiresSnapshot: Boolean(requiresSnapshot),
    sentAt: sentAt || new Date().toISOString(),
    updatedAt: sentAt || new Date().toISOString(),
  };
  if (sessionID) event.sessionID = sessionID;
  return event;
}

function relayScopesForReason(reason) {
  if (reason === "sync-data") return ["status", "syncData", "runLogs"];
  if (reason.startsWith("sync-data:")) return ["syncData", "runLogs"];
  if (reason.startsWith("commands:")) return ["status", "commands", "requestLog"];
  if (reason.startsWith("item-actions:")) return ["status", "syncData", "itemActions", "requestLog"];
  if (reason.startsWith("setting-actions:")) return ["status", "syncData", "settingActions", "requestLog"];
  if (reason === "shared-settings") return ["sharedSettings", "syncData", "requestLog"];
  if (reason.startsWith("file-access:")) return ["fileAccess", "requestLog"];
  if (reason.startsWith("logs")) return ["commands", "itemActions", "settingActions", "fileAccess", "requestLog", "runLogs"];
  if (reason.startsWith("cancel:")) return ["status", "commands", "cancel", "requestLog"];
  return ["status"];
}

function relayEventRequiresSnapshot(reason) {
  return false;
}

function broadcastRelayEvent(event) {
  if (!event) return;
  for (const client of realtimeClients) {
    if (client.socket.destroyed || !client.socket.writable) {
      realtimeClients.delete(client);
      continue;
    }
    const clientEvent = { ...event, sessionID: client.sessionID, requiresSnapshot: false };
    if (client.pendingSnapshot) {
      queueRealtimeBroadcast(client, clientEvent);
    } else {
      startRealtimeBroadcastSnapshot(client, clientEvent);
    }
  }
}

function normalizedRealtimeScopes(value, { allowEmpty = true } = {}) {
  if (!Array.isArray(value)) return null;
  const requested = new Set(value);
  if ([...requested].some((scope) => !REALTIME_SCOPES.has(scope))) return null;
  const scopes = [...REALTIME_SCOPES].filter((scope) => requested.has(scope));
  return scopes.length > 0 || allowEmpty ? scopes : null;
}

function startRealtimeBroadcastSnapshot(client, event) {
  try {
    const clientEvent = {
      ...event,
      revision: currentRelayRevision(),
      sessionID: client.sessionID,
      requiresSnapshot: false,
    };
    const prepared = prepareRealtimeSnapshot(client, clientEvent);
    client.pendingSnapshot = prepared;
    client.socket.write(encodeWebSocketFrame(JSON.stringify(clientEvent)));
    client.socket.write(encodeWebSocketFrame(prepared.beginFrame));
  } catch (error) {
    const closeCode = error?.closeCode === 1009 ? 1009 : error?.closeCode === 1013 ? 1013 : 1002;
    closeWebSocketClient(client, closeCode, error?.message || "snapshot preparation failed");
  }
}

function startRealtimeManualSnapshot(client, request) {
  const revision = currentRelayRevision();
  if (revision < request.requestedRevision) {
    closeWebSocketClient(client, 1002, "snapshot revision moved backwards");
    return;
  }
  const event = relayEventEnvelope({
    type: "changed",
    revision,
    reason: "manual-refresh",
    scopes: request.scopes,
    delta: {},
    requiresSnapshot: false,
    sentAt: new Date().toISOString(),
    sessionID: client.sessionID,
  });
  try {
    const prepared = prepareRealtimeSnapshot(client, event, { requestID: request.requestID });
    client.pendingSnapshot = prepared;
    client.socket.write(encodeWebSocketFrame(prepared.beginFrame));
  } catch (error) {
    const closeCode = error?.closeCode === 1009 ? 1009 : error?.closeCode === 1013 ? 1013 : 1002;
    closeWebSocketClient(client, closeCode, error?.message || "snapshot preparation failed");
  }
}

function queueRealtimeBroadcast(client, event) {
  const scopes = normalizedRealtimeScopes(event.scopes, { allowEmpty: false });
  if (!scopes) {
    closeWebSocketClient(client, 1002, "invalid snapshot event");
    return;
  }
  if (!client.queuedBroadcast) {
    client.queuedBroadcast = {
      event: { ...event, scopes },
      sequence: ++client.outboundSequence,
      count: 1,
    };
    return;
  }
  const mergedScopes = normalizedRealtimeScopes([
    ...client.queuedBroadcast.event.scopes,
    ...scopes,
  ], { allowEmpty: false });
  client.queuedBroadcast.event = {
    ...event,
    reason: "coalesced",
    scopes: mergedScopes,
  };
  client.queuedBroadcast.count += 1;
}

function drainRealtimeSnapshotQueue(client) {
  if (client.pendingSnapshot || !client.socket.writable || client.socket.destroyed) return;
  const broadcast = client.queuedBroadcast;
  const manual = client.queuedManualRequest;
  if (manual && (!broadcast || manual.sequence < broadcast.sequence)) {
    client.queuedManualRequest = null;
    startRealtimeManualSnapshot(client, manual);
    return;
  }
  if (broadcast) {
    client.queuedBroadcast = null;
    startRealtimeBroadcastSnapshot(client, broadcast.event);
    return;
  }
  if (manual) {
    client.queuedManualRequest = null;
    startRealtimeManualSnapshot(client, manual);
  }
}

function prepareRealtimeSnapshot(client, event, { requestID = null } = {}) {
  const scopes = normalizedRealtimeScopes(event.scopes, { allowEmpty: false });
  if (!scopes || event.requiresSnapshot) throw realtimeSnapshotError(1002, "invalid snapshot event");
  const payload = realtimeSnapshotPayload(client, {
    revision: event.revision,
    scopes,
    requestID,
  });
  return encodeRealtimeSnapshot({
    sessionID: client.sessionID,
    revision: event.revision,
    scopes,
    requestID,
    payload,
  });
}

function realtimeSnapshotPayload(client, { revision, scopes, requestID }) {
  const payload = {
    version: REALTIME_EVENT_VERSION,
    revision,
    scopes,
    requestID,
  };
  if (client.role === "worker") {
    payload.workerInbox = workerInboxResponse(client.request);
    if (scopes.includes("syncData") || scopes.includes("runLogs") || scopes.includes("sharedSettings")) {
      payload.syncData = syncDataResponse({ limit: MAX_SYNC_ITEMS });
    }
    return payload;
  }

  const clearTimes = displayLogClearTimes();
  if (scopes.includes("status")) payload.status = relayResponse({ audience: "client" });
  if (scopes.includes("commands")) {
    payload.commands = commandListResponse(
      filterDisplayCommands(state.commands, clearTimes.command)
        .slice()
        .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))
        .slice(0, 8)
    );
  }
  if (scopes.includes("syncData") || scopes.includes("runLogs")) {
    payload.syncData = syncDataResponse({ limit: MAX_SYNC_ITEMS });
  }
  if (scopes.includes("itemActions")) {
    payload.itemActions = itemActionListResponse(
      filterDisplayItemActions(state.itemActions, clearTimes.itemActions)
        .slice()
        .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))
        .slice(0, 10)
    );
  }
  if (scopes.includes("settingActions")) {
    payload.settingActions = settingActionListResponse(
      filterDisplaySettingActions(state.settingActions || [], clearTimes.settingActions)
        .slice()
        .sort((lhs, rhs) => Date.parse(rhs.updatedAt) - Date.parse(lhs.updatedAt))
        .slice(0, 10)
    );
  }
  if (scopes.includes("fileAccess")) {
    payload.fileAccess = fileAccessListResponse(
      filterDisplayFileAccess(
        loadFileAccessRequests({ limit: MAX_FILE_ACCESS_REQUESTS }),
        clearTimes.fileAccess
      ).slice(0, 20),
      client.request
    );
  }
  if (scopes.includes("requestLog")) payload.requestLog = requestLogResponse(20);
  if (scopes.includes("sharedSettings")) payload.sharedSettings = sharedSettingsResponse();
  return payload;
}

function encodeRealtimeSnapshot({ sessionID, revision, scopes, requestID, payload }) {
  if (!normalizeUUIDText(sessionID) || !Number.isSafeInteger(revision) || revision < 0) {
    throw realtimeSnapshotError(1002, "invalid snapshot binding");
  }
  const payloadBytes = Buffer.from(JSON.stringify(payload), "utf8");
  if (payloadBytes.length > MAX_REALTIME_SNAPSHOT_BYTES) {
    throw realtimeSnapshotError(1009, "snapshot payload too large");
  }
  const chunks = [];
  for (let offset = 0; offset < payloadBytes.length || (offset === 0 && chunks.length === 0); offset += REALTIME_SNAPSHOT_CHUNK_BYTES) {
    chunks.push(payloadBytes.subarray(offset, Math.min(payloadBytes.length, offset + REALTIME_SNAPSHOT_CHUNK_BYTES)));
  }
  if (chunks.length > MAX_REALTIME_SNAPSHOT_CHUNKS) {
    throw realtimeSnapshotError(1009, "too many snapshot chunks");
  }
  const streamID = crypto.randomUUID();
  const payloadSHA256 = crypto.createHash("sha256").update(payloadBytes).digest("hex");
  const totalPayloadBytes = fixedWidthHex(payloadBytes.length);
  const reservedFrames = chunks.length + 2;
  const base = {
    version: REALTIME_EVENT_VERSION,
    sessionID,
    streamID,
    revision,
    scopes,
    requestID,
    chunkCount: chunks.length,
    totalPayloadBytes,
    reservedFrames,
    reservedWireBytes: "0000000000000000",
    payloadSHA256,
  };
  const frameObjects = [
    { ...base, type: "snapshot-begin", index: -1, payloadBytes: fixedWidthHex(0) },
    ...chunks.map((chunk, index) => ({
      ...base,
      type: "snapshot-chunk",
      index,
      payloadBytes: fixedWidthHex(chunk.length),
      payload: chunk.toString("base64"),
    })),
    { ...base, type: "snapshot-end", index: chunks.length, payloadBytes: fixedWidthHex(0) },
  ];
  let frameTexts = frameObjects.map((frame) => JSON.stringify(frame));
  const reservedWireBytes = fixedWidthHex(frameTexts.reduce((sum, frame) => sum + Buffer.byteLength(frame), 0));
  for (const frame of frameObjects) frame.reservedWireBytes = reservedWireBytes;
  frameTexts = frameObjects.map((frame) => JSON.stringify(frame));
  const exactWireBytes = frameTexts.reduce((sum, frame) => sum + Buffer.byteLength(frame), 0);
  if (fixedWidthHex(exactWireBytes) !== reservedWireBytes) {
    throw realtimeSnapshotError(1002, "snapshot byte reservation changed");
  }
  if (exactWireBytes > MAX_REALTIME_SNAPSHOT_BYTES) {
    throw realtimeSnapshotError(1013, "snapshot wire reservation unavailable");
  }
  if (frameTexts.some((frame) => Buffer.byteLength(frame) > MAX_REALTIME_FRAME_BYTES)) {
    throw realtimeSnapshotError(1009, "snapshot frame too large");
  }
  return {
    streamID,
    revision,
    scopes,
    requestID,
    reservedFrames,
    reservedWireBytes,
    beginFrame: frameTexts[0],
    dataFrames: frameTexts.slice(1),
  };
}

function fixedWidthHex(value) {
  if (!Number.isSafeInteger(value) || value < 0) throw realtimeSnapshotError(1002, "invalid snapshot byte count");
  return value.toString(16).padStart(16, "0");
}

function realtimeSnapshotError(closeCode, message) {
  const error = new Error(message);
  error.closeCode = closeCode;
  return error;
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
  if (!isValidStoredCommand({
    id: row.id,
    kind: row.kind,
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  })) return null;
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
  if (!isValidStoredItemAction({
    id: row.id,
    action: row.action,
    itemID: row.item_id,
    itemKind: row.item_kind,
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  })) return null;
  return normalizeItemAction({
    id: row.id,
    _idempotencyKey: row.idempotency_key,
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

function getItemActionByIdempotencyKey(key) {
  if (!key) return null;
  const row = db.prepare(`
    SELECT id, idempotency_key, action, item_id, item_kind, item_title, status, created_at, updated_at, message
    FROM item_actions
    WHERE idempotency_key = ?
  `).get(key);
  return row ? rowToItemAction(row) : null;
}

function rowToFileAccessRequest(row) {
  if (!isValidStoredFileAccess({
    id: row.id,
    itemID: row.item_id,
    itemKind: row.item_kind,
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    objectKey: row.object_key,
  })) return null;
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
  return deduplicateByID(rows.map(rowToFileAccessRequest).filter(Boolean), limit);
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

function prepareFileAccessUpload(id, objectKey, reservedBytes, limits) {
  const claim = crypto.randomUUID();
  db.exec("BEGIN IMMEDIATE");
  try {
    const current = db.prepare(`
      SELECT status, object_key, upload_claim, pending_object_key,
             reserved_upload_bytes, reserved_upload_quota_key
      FROM file_access_requests
      WHERE id = ?
    `).get(normalizeUUIDText(id));
    if (!current || current.object_key || current.upload_claim || current.pending_object_key
        || Number(current.reserved_upload_bytes || 0) !== 0 || current.reserved_upload_quota_key
        || !["pending", "running"].includes(current.status)) {
      db.exec("ROLLBACK");
      return { ok: false, status: 409 };
    }
    const quota = loadFileAccessQuota();
    if (quota.uploadCount + 1 > limits.dailyUploads
        || quota.uploadBytes + reservedBytes > limits.dailyUploadBytes) {
      db.exec("ROLLBACK");
      return { ok: false, status: 429 };
    }
    const claimed = db.prepare(`
      UPDATE file_access_requests
      SET upload_claim = ?, pending_object_key = ?, reserved_upload_bytes = ?,
          reserved_upload_quota_key = ?
      WHERE id = ?
        AND object_key IS NULL
        AND upload_claim IS NULL
        AND pending_object_key IS NULL
        AND reserved_upload_bytes = 0
        AND reserved_upload_quota_key IS NULL
        AND status IN ('pending', 'running')
    `).run(claim, objectKey, reservedBytes, quota.key, normalizeUUIDText(id));
    if (claimed.changes !== 1) {
      db.exec("ROLLBACK");
      return { ok: false, status: 409 };
    }
    saveFileAccessQuota({
      ...quota,
      uploadCount: quota.uploadCount + 1,
      uploadBytes: quota.uploadBytes + reservedBytes,
    });
    db.exec("COMMIT");
    activeFileUploadClaims.add(claim);
    return { ok: true, claim };
  } catch (error) {
    if (db.isTransaction) db.exec("ROLLBACK");
    throw error;
  }
}

function releasePreparedFileAccessUpload(id, claim) {
  db.exec("BEGIN IMMEDIATE");
  try {
    const row = db.prepare(`
      SELECT reserved_upload_bytes, reserved_upload_quota_key
      FROM file_access_requests
      WHERE id = ? AND upload_claim = ? AND object_key IS NULL
    `).get(normalizeUUIDText(id), claim);
    if (!row) {
      db.exec("ROLLBACK");
      return false;
    }
    const quota = loadFileAccessQuotaForKey(row.reserved_upload_quota_key);
    saveFileAccessQuota({
      ...quota,
      uploadCount: Math.max(0, quota.uploadCount - 1),
      uploadBytes: Math.max(0, quota.uploadBytes - Number(row.reserved_upload_bytes || 0)),
    });
    db.prepare(`
      UPDATE file_access_requests
      SET upload_claim = NULL, pending_object_key = NULL, reserved_upload_bytes = 0,
          reserved_upload_quota_key = NULL
      WHERE id = ? AND upload_claim = ? AND object_key IS NULL
    `).run(normalizeUUIDText(id), claim);
    db.exec("COMMIT");
    activeFileUploadClaims.delete(claim);
    return true;
  } catch (error) {
    if (db.isTransaction) db.exec("ROLLBACK");
    throw error;
  }
}

function finalizeFileAccessUpload(id, claim, updated) {
  const result = db.prepare(`
    UPDATE file_access_requests
    SET status = ?, updated_at = ?, message = ?, object_key = ?, download_ticket = ?,
        expires_at = ?, content_type = ?, size_bytes = ?, download_count = 0,
        upload_claim = NULL, pending_object_key = NULL, reserved_upload_bytes = 0,
        reserved_upload_quota_key = NULL
    WHERE id = ? AND upload_claim = ? AND object_key IS NULL AND pending_object_key = ?
      AND status IN ('pending', 'running')
  `).run(
    updated.status,
    updated.updatedAt,
    updated.message,
    updated.objectKey,
    updated.downloadTicket,
    updated.expiresAt,
    updated.contentType,
    updated.sizeBytes,
    normalizeUUIDText(id),
    claim,
    updated.objectKey
  );
  if (result.changes === 1) activeFileUploadClaims.delete(claim);
  return result.changes === 1;
}

function claimTerminalFileAccessDeletion(fileRequest) {
  const claim = crypto.randomUUID();
  const result = db.prepare(`
    UPDATE file_access_requests
    SET upload_claim = ?
    WHERE id = ?
      AND status NOT IN ('pending', 'running')
      AND object_key IS ?
      AND updated_at = ?
      AND upload_claim IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM file_download_reservations WHERE request_id = file_access_requests.id
      )
  `).run(
    claim,
    normalizeUUIDText(fileRequest.id),
    fileRequest.objectKey || null,
    fileRequest.updatedAt
  );
  if (result.changes !== 1) return null;
  return {
    id: normalizeUUIDText(fileRequest.id),
    status: fileRequest.status,
    objectKey: fileRequest.objectKey || null,
    updatedAt: fileRequest.updatedAt,
    claim,
  };
}

function claimExpiredFileAccessDeletion(row, expiresBefore) {
  const claim = crypto.randomUUID();
  const result = db.prepare(`
    UPDATE file_access_requests
    SET upload_claim = ?
    WHERE id = ?
      AND status = ?
      AND object_key IS ?
      AND updated_at = ?
      AND expires_at IS NOT NULL
      AND expires_at <= ?
      AND upload_claim IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM file_download_reservations WHERE request_id = file_access_requests.id
      )
  `).run(
    claim,
    normalizeUUIDText(row.id),
    row.status,
    row.object_key || null,
    row.updated_at,
    expiresBefore
  );
  if (result.changes !== 1) return null;
  return {
    id: normalizeUUIDText(row.id),
    status: row.status,
    objectKey: row.object_key || null,
    updatedAt: row.updated_at,
    expiresBefore,
    claim,
  };
}

function releaseFileAccessDeletionClaim(candidate) {
  db.prepare(`
    UPDATE file_access_requests
    SET upload_claim = NULL
    WHERE id = ? AND upload_claim = ?
  `).run(candidate.id, candidate.claim);
}

function deleteTerminalFileAccessClaim(candidate) {
  return db.prepare(`
    DELETE FROM file_access_requests
    WHERE id = ?
      AND upload_claim = ?
      AND status NOT IN ('pending', 'running')
      AND object_key IS ?
      AND updated_at = ?
  `).run(candidate.id, candidate.claim, candidate.objectKey, candidate.updatedAt).changes === 1;
}

function deleteExpiredFileAccessClaim(candidate) {
  return db.prepare(`
    DELETE FROM file_access_requests
    WHERE id = ?
      AND upload_claim = ?
      AND status = ?
      AND object_key IS ?
      AND updated_at = ?
      AND expires_at IS NOT NULL
      AND expires_at <= ?
  `).run(
    candidate.id,
    candidate.claim,
    candidate.status,
    candidate.objectKey,
    candidate.updatedAt,
    candidate.expiresBefore
  ).changes === 1;
}

function trimFileAccessRequests() {
  db.prepare(`
    DELETE FROM file_access_requests
    WHERE object_key IS NULL
      AND upload_claim IS NULL
      AND pending_object_key IS NULL
      AND reserved_upload_bytes = 0
      AND reserved_upload_quota_key IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM file_download_reservations WHERE request_id = file_access_requests.id
      )
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
  const updates = [];
  for (const fileRequest of rows) {
    const status = String(fileRequest.status || "").toLowerCase();
    if (status === "pending" && ageMs(fileRequest.createdAt, now) <= STALE_PENDING_FILE_ACCESS_MS) {
      continue;
    }
    if (status === "running" && ageMs(fileRequest.updatedAt || fileRequest.createdAt, now) <= STALE_RUNNING_FILE_ACCESS_MS) {
      continue;
    }
    updates.push({
      ...fileRequest,
      status: "macUnavailable",
      updatedAt: new Date().toISOString(),
      message: "Mac 앱이 제한 시간 안에 파일을 준비하지 않았습니다.",
    });
  }
  if (updates.length > 0) {
    const updatedAt = updates.reduce(
      (latest, item) => Date.parse(item.updatedAt) > Date.parse(latest) ? item.updatedAt : latest,
      updates[0].updatedAt
    );
    commitRelayMutation("file-access:macUnavailable", updatedAt, () => {
      for (const update of updates) upsertFileAccessRequest(update);
    });
  }
}

async function recoverInterruptedFileUploads({
  recoverDeletionClaims = false,
  sweepUnreferencedObjects = false,
} = {}) {
  const interrupted = db.prepare(`
    SELECT id, upload_claim, pending_object_key, reserved_upload_bytes, reserved_upload_quota_key
    FROM file_access_requests
    WHERE object_key IS NULL
      AND pending_object_key IS NOT NULL
      AND upload_claim IS NOT NULL
  `).all();
  for (const row of interrupted) {
    if (activeFileUploadClaims.has(row.upload_claim)) continue;
    let removed = false;
    if (!isValidFileObjectKey(row.pending_object_key, row.id)) {
      // An invalid tombstone cannot name a safe path under FILE_DIR. It is safe
      // to release the reservation because this relay never writes invalid keys.
      removed = true;
    } else {
      try {
        await fs.unlink(localFileObjectPath(row.pending_object_key, row.id));
        removed = true;
      } catch (error) {
        removed = error?.code === "ENOENT";
        if (!removed) console.error("failed to remove interrupted upload object", error);
      }
    }
    if (removed) releasePreparedFileAccessUpload(row.id, row.upload_claim);
  }
  if (recoverDeletionClaims) {
    const claims = db.prepare(`
      SELECT id, object_key, upload_claim
      FROM file_access_requests
      WHERE pending_object_key IS NULL AND upload_claim IS NOT NULL
    `).all();
    for (const row of claims) {
      if (!row.object_key) {
        db.prepare(`
          UPDATE file_access_requests
          SET upload_claim = NULL, reserved_upload_bytes = 0, reserved_upload_quota_key = NULL
          WHERE id = ? AND upload_claim = ? AND object_key IS NULL
        `).run(row.id, row.upload_claim);
        continue;
      }
      let objectMissing = !isValidFileObjectKey(row.object_key, row.id);
      if (!objectMissing) {
        try {
          await fs.stat(localFileObjectPath(row.object_key, row.id));
        } catch (error) {
          if (error?.code !== "ENOENT") throw error;
          objectMissing = true;
        }
      }
      if (objectMissing) {
        db.prepare(`
          DELETE FROM file_access_requests
          WHERE id = ? AND upload_claim = ? AND object_key = ?
        `).run(row.id, row.upload_claim, row.object_key);
      } else {
        db.prepare(`
          UPDATE file_access_requests
          SET upload_claim = NULL, reserved_upload_bytes = 0, reserved_upload_quota_key = NULL
          WHERE id = ? AND upload_claim = ? AND object_key = ?
        `).run(row.id, row.upload_claim, row.object_key);
      }
    }
  }
  // The unreferenced-object scan snapshots the database before walking the
  // filesystem. Run it only before listen(), when no upload can create a new
  // referenced object after that snapshot.
  if (sweepUnreferencedObjects) await cleanupUnreferencedFileObjects();
}

async function cleanupUnreferencedFileObjects() {
  const storageRoot = path.join(FILE_DIR, "file-access");
  let requestDirectories;
  try {
    requestDirectories = await fs.readdir(storageRoot, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  const referenced = new Set();
  for (const row of db.prepare(`
    SELECT object_key, pending_object_key
    FROM file_access_requests
    WHERE object_key IS NOT NULL OR pending_object_key IS NOT NULL
  `).all()) {
    if (row.object_key) referenced.add(row.object_key);
    if (row.pending_object_key) referenced.add(row.pending_object_key);
  }
  for (const requestDirectory of requestDirectories) {
    if (!requestDirectory.isDirectory() || !normalizeUUIDText(requestDirectory.name)) continue;
    const directoryPath = path.join(storageRoot, requestDirectory.name);
    let objects;
    try {
      objects = await fs.readdir(directoryPath, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const object of objects) {
      if (!object.isFile()) continue;
      const objectKey = `file-access/${requestDirectory.name}/${object.name}`;
      if (!isValidFileObjectKey(objectKey, requestDirectory.name) || referenced.has(objectKey)) continue;
      await fs.unlink(localFileObjectPath(objectKey, requestDirectory.name)).catch((error) => {
        if (error?.code !== "ENOENT") console.error("failed to remove unreferenced file object", error);
      });
    }
    await fs.rmdir(directoryPath).catch(() => {});
  }
}

async function cleanupExpiredFileAccess() {
  const nowISO = new Date().toISOString();
  const rows = db.prepare(`
    SELECT id, status, object_key, updated_at
    FROM file_access_requests
    WHERE expires_at IS NOT NULL
      AND expires_at <= ?
  `).all(nowISO);
  const candidates = rows
    .map((row) => claimExpiredFileAccessDeletion(row, nowISO))
    .filter(Boolean);
  const deletionResults = [];
  let claimsCommitted = false;
  try {
    for (const candidate of candidates) {
      if (!candidate.objectKey) {
        deletionResults.push({ ...candidate, deleted: true });
        continue;
      }
      try {
        await delayFileDeletionForTest();
        await fs.unlink(localFileObjectPath(candidate.objectKey, candidate.id));
        deletionResults.push({ ...candidate, deleted: true });
      } catch (error) {
        if (error?.code === "ENOENT") deletionResults.push({ ...candidate, deleted: true });
        else {
          console.error("failed to delete expired file object", error);
          deletionResults.push({ ...candidate, deleted: false });
        }
      }
    }
    const successful = deletionResults.filter((candidate) => candidate.deleted);
    if (successful.length > 0) {
      commitRelayMutation("file-access:expired", nowISO, () => {
        for (const candidate of deletionResults) {
          if (candidate.deleted && deleteExpiredFileAccessClaim(candidate)) continue;
          releaseFileAccessDeletionClaim(candidate);
        }
      });
    } else {
      for (const candidate of deletionResults) releaseFileAccessDeletionClaim(candidate);
    }
    claimsCommitted = true;
  } finally {
    if (!claimsCommitted) {
      for (const candidate of candidates) releaseFileAccessDeletionClaim(candidate);
    }
  }
}

function scheduleExpiredFileAccessCleanup() {
  if (expiredFileCleanupPromise) return expiredFileCleanupPromise;
  expiredFileCleanupPromise = new Promise((resolve) => setImmediate(resolve))
    .then(() => cleanupExpiredFileAccess())
    .catch((error) => {
      console.error("expired file cleanup failed", error);
    })
    .finally(() => {
      expiredFileCleanupPromise = null;
    });
  return expiredFileCleanupPromise;
}

function delayFileDeletionForTest() {
  if (TEST_FILE_DELETE_DELAY_MS <= 0) return Promise.resolve();
  return new Promise((resolve) => setTimeout(resolve, TEST_FILE_DELETE_DELAY_MS));
}

function delayFileReadForTest() {
  if (TEST_FILE_READ_DELAY_MS <= 0) return Promise.resolve();
  return new Promise((resolve) => setTimeout(resolve, TEST_FILE_READ_DELAY_MS));
}

async function uploadFileAccess(response, request, id) {
  const current = getFileAccessRequest(id);
  if (!current) {
    sendJSON(response, 404, { error: "file request not found" });
    return;
  }
  if (current.objectKey || current.status === "completed") {
    sendJSON(response, 409, { error: "file request already has an uploaded object" });
    return;
  }
  const limits = fileAccessLimits();
  const contentLengthText = String(request.headers["content-length"] || "").trim();
  if (!/^[1-9][0-9]*$/.test(contentLengthText)) {
    sendJSON(response, 411, { error: "Content-Length is required for quota reservation" });
    return;
  }
  const contentLength = Number.parseInt(contentLengthText, 10);
  if (!Number.isSafeInteger(contentLength) || contentLength > limits.maxUploadBytes) {
    sendJSON(response, 413, { error: `file too large; limit is ${limits.maxUploadBytes} bytes` });
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
  const objectPath = localFileObjectPath(objectKey, current.id);
  const prepared = prepareFileAccessUpload(current.id, objectKey, contentLength, limits);
  if (!prepared.ok && prepared.status === 429) {
    sendJSON(response, 429, { error: "daily file upload quota reached" });
    return;
  }
  if (!prepared.ok) {
    sendJSON(response, 409, { error: "file upload already claimed or completed" });
    return;
  }
  const claim = prepared.claim;
  let body = null;
  let updated = null;
  let finalized = false;
  try {
    body = await readRawBody(request, limits.maxUploadBytes);
    if (body.length !== contentLength) {
      throw new RelayValidationError("request body length does not match Content-Length");
    }
    await fs.mkdir(path.dirname(objectPath), { recursive: true });
    await fs.writeFile(objectPath, body, { flag: "wx" });
    updated = {
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
    commitRelayMutation("file-access:completed", updated.updatedAt, () => {
      if (!finalizeFileAccessUpload(current.id, claim, updated)) {
        throw new RelayConflictError("file upload claim expired or request became terminal");
      }
      appendRequestLog(request, {
        action: "파일 업로드 완료",
        status: "completed",
        message: filename,
        source: "Mac",
      });
    });
    finalized = true;
  } catch (error) {
    let removed = false;
    try {
      await fs.unlink(objectPath);
      removed = true;
    } catch (deleteError) {
      removed = deleteError?.code === "ENOENT";
      if (!removed) console.error("failed to remove incomplete upload object", deleteError);
    }
    if (!finalized && removed) releasePreparedFileAccessUpload(current.id, claim);
    if (!removed) scheduleExpiredFileAccessCleanup();
    throw error;
  } finally {
    activeFileUploadClaims.delete(claim);
  }
  sendJSON(response, 200, fileAccessResponseItem(updated, request));
}

async function downloadFileAccess(request, response, url, id) {
  const wantsPreview = url.searchParams.has("preview") && !url.searchParams.has("download");
  const wantsRawPreview = wantsPreview && url.searchParams.has("raw");
  const ticket = downloadCapabilityFromRequest(request);
  if (TEST_TRACK_PUBLIC_DOWNLOAD_LOOKUPS) {
    setMeta("testPublicDownloadLookupCount", Number(getMeta("testPublicDownloadLookupCount") || 0) + 1);
  }
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
  if (!consumePublicDownloadLinkRateLimit(id)) {
    sendRateLimitResponse(response);
    return;
  }
  if (fileRequest.expiresAt && Date.parse(fileRequest.expiresAt) <= Date.now()) {
    scheduleExpiredFileAccessCleanup();
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
    if (!wantsRawPreview) {
      sendFileAccessPreviewPage(response, url, {
        fileRequest,
        preview,
        status: 200,
        title: "KLMS 파일 미리보기",
        message: "미리보기 화면입니다. 확대/축소와 페이지 이동을 사용할 수 있습니다.",
      });
      return;
    }
    const pendingLog = fileDownloadRequestLog(fileRequest, {
      preview: true,
      status: "running",
    });
    const reservation = reserveFileDownload(fileRequest.id, limits, {
      reason: "file-access:preview-reserved",
      requestLog: pendingLog,
    });
    if (!reservation.ok) {
      sendFileAccessDownloadPage(response, url, {
        fileRequest,
        status: reservation.httpStatus || 429,
        title: reservation.httpStatus === 409 ? "파일을 정리 중입니다" : "다운로드 한도에 도달했습니다",
        message: reservation.error,
      });
      return;
    }
    let data;
    try {
      recordTestFileObjectRead();
      await delayFileReadForTest();
      data = await fs.readFile(localFileObjectPath(fileRequest.objectKey, fileRequest.id));
    } catch (error) {
      releaseFileDownloadReservation(fileRequest.id, reservation.token, {
        requestLog: {
          ...pendingLog,
          status: "failed",
          message: error?.code === "ENOENT" ? "임시 저장소에서 파일을 찾지 못했습니다." : "임시 저장소 파일 읽기에 실패했습니다.",
        },
      });
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
    let finalization;
    try {
      finalization = finalizeFileDownloadReservation(fileRequest.id, reservation.token, {
        reason: "file-access:previewed",
        requestLog: {
          ...pendingLog,
          status: "completed",
        },
      });
    } catch (error) {
      try {
        releaseFileDownloadReservation(fileRequest.id, reservation.token, {
          requestLog: {
            ...pendingLog,
            status: "failed",
            message: "파일 미리보기 완료 기록에 실패했습니다.",
          },
        });
      } catch (releaseError) {
        console.error("failed to release preview reservation after finalization error", releaseError);
      }
      throw error;
    }
    if (!finalization.settled) {
      throw new RelayConflictError("file download reservation expired before preview delivery");
    }
    sendLocalFileObject(response, fileRequest, data, { disposition: "inline", preview });
    return;
  }
  if (url.searchParams.has("page")) {
    sendFileAccessDownloadPage(response, url, {
      fileRequest,
      status: 200,
      title: "KLMS 파일 다운로드",
      message: "Mac이 준비한 임시 파일입니다. 앱에서 안전하게 다운로드하세요.",
      canDownload: true,
      previewMaxBytes: limits.previewMaxBytes,
      textPreviewMaxBytes: limits.textPreviewMaxBytes,
    });
    return;
  }
  const pendingLog = fileDownloadRequestLog(fileRequest, {
    preview: false,
    status: "running",
  });
  const reservation = reserveFileDownload(fileRequest.id, limits, {
    reason: "file-access:download-reserved",
    requestLog: pendingLog,
  });
  if (!reservation.ok) {
    sendFileAccessDownloadPage(response, url, {
      fileRequest,
      status: reservation.httpStatus || 429,
      title: reservation.httpStatus === 409 ? "파일을 정리 중입니다" : "다운로드 한도에 도달했습니다",
      message: reservation.error,
    });
    return;
  }
  let data;
  try {
    recordTestFileObjectRead();
    await delayFileReadForTest();
    data = await fs.readFile(localFileObjectPath(fileRequest.objectKey, fileRequest.id));
  } catch (error) {
    releaseFileDownloadReservation(fileRequest.id, reservation.token, {
      requestLog: {
        ...pendingLog,
        status: "failed",
        message: error?.code === "ENOENT" ? "임시 저장소에서 파일을 찾지 못했습니다." : "임시 저장소 파일 읽기에 실패했습니다.",
      },
    });
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
  let finalization;
  try {
    finalization = finalizeFileDownloadReservation(fileRequest.id, reservation.token, {
      reason: "file-access:downloaded",
      requestLog: {
        ...pendingLog,
        status: "completed",
      },
    });
  } catch (error) {
    try {
      releaseFileDownloadReservation(fileRequest.id, reservation.token, {
        requestLog: {
          ...pendingLog,
          status: "failed",
          message: "파일 다운로드 완료 기록에 실패했습니다.",
        },
      });
    } catch (releaseError) {
      console.error("failed to release download reservation after finalization error", releaseError);
    }
    throw error;
  }
  if (!finalization.settled) {
    throw new RelayConflictError("file download reservation expired before delivery");
  }
  sendLocalFileObject(response, fileRequest, data, { disposition: "attachment" });
}

function sendFileAccessDownloadPage(response, url, {
  fileRequest = null,
  status = 200,
  title = "KLMS 파일 다운로드",
  message = "",
  canDownload = false,
  previewMaxBytes = DEFAULT_FILE_PREVIEW_MAX_BYTES,
  textPreviewMaxBytes = DEFAULT_TEXT_FILE_PREVIEW_MAX_BYTES,
}) {
  const scriptNonce = contentSecurityNonce();
  const downloadURL = canDownload ? downloadActionURL(url) : "";
  const preview = canDownload ? filePreviewDetails(fileRequest, previewMaxBytes, textPreviewMaxBytes) : { available: false, kind: "", label: "", message: "" };
  const previewURL = preview.available ? previewActionURL(url) : "";
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
  <script nonce="${scriptNonce}">
    for (const el of document.querySelectorAll("[data-expires]")) {
      const d = new Date(el.dataset.expires);
      if (!Number.isNaN(d.getTime())) el.textContent = "만료 " + d.toLocaleString("ko-KR", { dateStyle: "medium", timeStyle: "short" });
    }
  </script>
</body>
</html>`;
  response.writeHead(status, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
    "Content-Security-Policy": `default-src 'none'; img-src 'self'; media-src 'self'; frame-src 'self'; connect-src 'self'; script-src 'nonce-${scriptNonce}'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'`,
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Resource-Policy": "same-origin",
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
  next.searchParams.delete("raw");
  return next.toString();
}

function rawPreviewActionURL(url) {
  const next = new URL(url.toString());
  next.searchParams.set("preview", "1");
  next.searchParams.set("raw", "1");
  next.searchParams.delete("download");
  return next.toString();
}

function sendLocalFileObject(response, fileRequest, data, { disposition = "attachment", preview = null } = {}) {
  const headers = {
    "Content-Type": effectiveFileContentType(fileRequest, { disposition, preview }),
    "Content-Disposition": contentDisposition(fileRequest.itemTitle || "KLMS file", disposition),
    "Content-Length": String(data.length),
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "Cross-Origin-Resource-Policy": "same-origin",
  };
  if (disposition === "inline") {
    headers["Content-Security-Policy"] = "sandbox; default-src 'none'; frame-ancestors 'self'";
  }
  response.writeHead(200, headers);
  response.end(data);
}

function filePreviewActionMarkup(preview, previewURL) {
  if (preview.available) {
    const url = escapeHTML(previewURL);
    return `<a class="button" href="${url}">미리보기</a>`;
  }
  return `<span class="button disabled" aria-disabled="true">미리보기 불가</span>`;
}

function sendFileAccessPreviewPage(response, url, {
  fileRequest,
  preview,
  status = 200,
  title = "KLMS 파일 미리보기",
  message = "",
}) {
  const scriptNonce = contentSecurityNonce();
  const rawURL = rawPreviewActionURL(url);
  const backURL = previewBackURL(url);
  const downloadURL = downloadActionURL(url);
  const filename = fileRequest?.itemTitle || "KLMS 파일";
  const sizeText = formatBytes(fileRequest?.sizeBytes);
  const expiresText = fileRequest?.expiresAt || "";
  const downloadCount = Number.isFinite(Number(fileRequest?.downloadCount)) ? Number(fileRequest.downloadCount) : 0;
  const viewerMarkup = filePreviewViewerMarkup(preview, rawURL);
  const isPDFPreview = preview?.kind === "pdf";
  const pageControlsMarkup = isPDFPreview ? "" : `
        <div class="tool-group">
          <button type="button" data-action="prev">이전</button>
          <button type="button" data-action="next">다음</button>
        </div>`;
  const zoomControlsMarkup = isPDFPreview ? "" : `
        <div class="tool-group">
          <button type="button" data-action="zoom-out">축소</button>
          <button type="button" data-action="fit">맞춤</button>
          <button type="button" data-action="zoom-in">확대</button>
        </div>`;
  const previewStatusText = isPDFPreview ? "브라우저 PDF 뷰어" : "1 / 1 · 100%";
  const previewNote = isPDFPreview
    ? "브라우저의 내장 PDF 도구로 쪽 이동과 확대/축소를 조절할 수 있습니다."
    : "텍스트와 이미지는 위 도구막대로 페이지 이동과 확대/축소를 조절할 수 있습니다.";
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
    .pdf-stage { height: min(74vh, 760px); background: #334155; }
    .pdf-stage iframe { width: 100%; height: 100%; border: 0; background: white; }
    .image-stage { height: min(74vh, 760px); overflow: auto; display: grid; place-items: start center; padding: 18px; background: #0f172a; }
    .image-stage img { max-width: 100%; transform-origin: top center; transition: transform .12s ease; border-radius: 8px; background: white; box-shadow: 0 16px 40px rgba(0,0,0,.28); }
    .text-stage { height: min(74vh, 760px); overflow: auto; background: #fff; color: #111827; }
    .text-page { min-height: 100%; margin: 0; padding: 20px; white-space: pre-wrap; word-break: break-word; font: 15px/1.6 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
    .media-stage { min-height: min(74vh, 760px); display: grid; place-items: center; padding: 24px; background: rgba(15,23,42,.08); }
    .media-stage video, .media-stage audio { width: min(100%, 920px); }
    .empty { padding: 24px; color: var(--muted); }
    .note { padding: 12px 18px 18px; color: var(--muted); font-size: 12px; }
    @media (prefers-color-scheme: dark) { :root { --ink: #e5e7eb; --muted: #a3aebf; --panel: rgba(15,23,42,.86); --line: rgba(148,163,184,.22); --surface: rgba(15,23,42,.72); } body { background: radial-gradient(circle at 20% 0%, #1e3a8a 0, transparent 32%), linear-gradient(135deg, #020617, #111827 65%, #0f172a); } .chip { background: rgba(148,163,184,.16); color: #cbd5e1; } .toolbar { background: rgba(15,23,42,.92); } .tool-group { background: rgba(15,23,42,.74); } .text-stage { background: #111827; color: #e5e7eb; } }
    @media (max-width: 700px) { main { width: 100%; padding: 0; } .shell { border-radius: 0; min-height: 100vh; } .top { padding: 14px; } .toolbar { gap: 7px; padding: 10px; } .tool-group { flex: 1 1 auto; } button, .button { flex: 1 1 auto; padding: 0 9px; } .status { width: 100%; margin-left: 0; text-align: center; } .viewer, .pdf-stage, .image-stage, .text-stage { height: calc(100vh - 270px); min-height: 420px; } }
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
${pageControlsMarkup}
${zoomControlsMarkup}
        <a class="button primary" href="${escapeHTML(downloadURL)}">다운로드</a>
        <div class="status" data-status>${escapeHTML(previewStatusText)}</div>
      </div>
      <div class="viewer">${viewerMarkup}</div>
      <div class="note">${escapeHTML(previewNote)}</div>
    </section>
  </main>
  <script nonce="${scriptNonce}">
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
      const max = Math.max(1, pages.length);
      status.textContent = page + " / " + max + " · " + Math.round(zoom * 100) + "%";
    };
    const boundedPage = (value) => Math.min(Math.max(1, value), Math.max(1, pages.length));
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
    } else if (kind === "pdf") {
      const resource = document.querySelector("[data-pdf-preview]");
      if (resource) resource.addEventListener("load", bumpUsage, { once: true });
    } else {
      pages = [""];
      render();
      const resource = document.querySelector("[data-image-preview], video, audio");
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
  response.writeHead(status, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
    "Content-Security-Policy": `default-src 'none'; img-src 'self'; media-src 'self'; frame-src 'self'; connect-src 'self'; script-src 'nonce-${scriptNonce}'; worker-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'`,
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Resource-Policy": "same-origin",
  });
  response.end(html);
}

function previewBackURL(url) {
  const next = new URL(url.toString());
  next.searchParams.delete("preview");
  next.searchParams.delete("raw");
  next.searchParams.delete("download");
  return next.toString();
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
    return `<div class="pdf-stage"><iframe data-pdf-preview src="${url}" title="PDF 미리보기"></iframe></div>`;
  }
  return `<div class="empty">이 파일은 웹 미리보기를 지원하지 않습니다. 다운로드해서 확인해 주세요.</div>`;
}

function normalizeSyncItem(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  const kind = String(raw.kind || "").trim();
  if (!ITEM_KINDS.has(kind)) {
    return null;
  }
  const id = String(raw.id || "").trim().slice(0, MAX_IDENTIFIER_CHARS) || crypto.randomUUID();
  const now = new Date().toISOString();
  const rawAcademicYear = raw.academicYear;
  const numericAcademicYear = Number(rawAcademicYear);
  const academicYear = rawAcademicYear === null
    || rawAcademicYear === undefined
    || String(rawAcademicYear).trim() === ""
    ? null
    : (Number.isFinite(numericAcademicYear) && numericAcademicYear >= 2000 && numericAcademicYear <= 2099
      ? numericAcademicYear
      : null);
  return {
    id,
    kind,
    course: sanitizePublicText(raw.course),
    academicTerm: sanitizePublicText(raw.academicTerm),
    academicYear,
    academicSemester: sanitizePublicText(raw.academicSemester),
    title: sanitizePublicText(raw.title),
    timestamp: sanitizePublicText(raw.timestamp),
    status: sanitizePublicText(raw.status),
    detail: sanitizePublicText(raw.detail),
    attachmentCount: boundedInt(raw.attachmentCount, 0, 0, 1_000_000),
    updatedAt: normalizedLogTimestamp(raw.updatedAt, now),
    isRead: normalizeBoolean(raw.isRead),
    isImportant: normalizeBoolean(raw.isImportant),
    isHidden: normalizeBoolean(raw.isHidden),
  };
}

function normalizeTermCatalog(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  const selectedYear = Number.isFinite(Number(raw.selected_year ?? raw.selectedYear))
    ? Number(raw.selected_year ?? raw.selectedYear)
    : null;
  const years = Array.isArray(raw.years) ? raw.years : [];
  const semesters = Array.isArray(raw.semesters) ? raw.semesters : [];
  const terms = Array.isArray(raw.terms) ? raw.terms : [];
  const courses = Array.isArray(raw.courses) ? raw.courses : [];
  return {
    version: boundedInt(raw.version, 1, 1, 100),
    generated_at: sanitizePublicText(raw.generated_at ?? raw.generatedAt),
    selected_year: selectedYear,
    selected_semester_code: sanitizePublicText(raw.selected_semester_code ?? raw.selectedSemesterCode),
    selected_semester: sanitizePublicText(raw.selected_semester ?? raw.selectedSemester),
    years: years.slice(0, 30).map((item) => ({
      year: boundedInt(item?.year, 0, 2000, 2099),
      label: sanitizePublicText(item?.label),
      selected: normalizeBoolean(item?.selected),
    })).filter((item) => item.year > 0),
    semesters: semesters.slice(0, 12).map((item) => ({
      code: sanitizePublicText(item?.code),
      label: sanitizePublicText(item?.label),
      display_name: sanitizePublicText(item?.display_name ?? item?.displayName),
      selected: normalizeBoolean(item?.selected),
    })).filter((item) => item.display_name || item.label || item.code),
    terms: terms.slice(0, 120).map((item) => ({
      year: boundedInt(item?.year, 0, 2000, 2099),
      semester_code: sanitizePublicText(item?.semester_code ?? item?.semesterCode),
      semester: sanitizePublicText(item?.semester),
      display_name: sanitizePublicText(item?.display_name ?? item?.displayName),
      selected: normalizeBoolean(item?.selected),
    })).filter((item) => item.year > 0 && item.semester),
    courses: courses.slice(0, 300).map((item) => ({
      id: sanitizePublicText(item?.id),
      code: sanitizePublicText(item?.code),
      title: sanitizePublicText(item?.title),
      url: "",
      year: Number.isFinite(Number(item?.year)) ? Number(item.year) : null,
      semester_code: sanitizePublicText(item?.semester_code ?? item?.semesterCode),
      semester: sanitizePublicText(item?.semester),
      term: sanitizePublicText(item?.term),
    })).filter((item) => item.title || item.code),
  };
}

function applyTermCatalogToSyncItems(inputItems, termCatalog) {
  const catalog = normalizeTermCatalog(termCatalog);
  const selectedYear = Number.isFinite(Number(catalog?.selected_year)) ? Number(catalog.selected_year) : null;
  const selectedSemester = sanitizePublicText(catalog?.selected_semester);
  const selectedTerm = selectedYear && selectedSemester
    ? { year: selectedYear, semester: selectedSemester }
    : null;
  const selectedCourseKeys = new Set();
  for (const course of catalog?.courses || []) {
    for (const value of [course.title, course.code]) {
      const key = normalizeCourseKey(value);
      if (key) selectedCourseKeys.add(key);
    }
  }
  const resolvedItems = inputItems
    .map(normalizeSyncItem)
    .filter(Boolean)
    .map((item) => {
      if (selectedTerm && courseKeyMatchesAny(item.course, selectedCourseKeys)) {
        return syncItemWithAcademicTerm(item, selectedTerm);
      }
      const inferred = inferAcademicTermForSyncItem(item, selectedYear);
      if (inferred) {
        return syncItemWithAcademicTerm(item, inferred);
      }
      if (selectedTerm
          && item.academicYear === selectedTerm.year
          && item.academicSemester === selectedTerm.semester
          && selectedCourseKeys.size > 0) {
        return syncItemWithAcademicTerm(item, null);
      }
      return item;
    });
  return fillMissingTermsFromCourseMajority(resolvedItems);
}

function fillMissingTermsFromCourseMajority(items) {
  const countsByCourse = new Map();
  for (const item of items) {
    const courseKey = normalizeCourseKey(item.course);
    if (!courseKey || !item.academicYear || !item.academicSemester) continue;
    const termKey = `${item.academicYear}\u001f${item.academicSemester}`;
    const counts = countsByCourse.get(courseKey) || new Map();
    counts.set(termKey, (counts.get(termKey) || 0) + 1);
    countsByCourse.set(courseKey, counts);
  }
  const majorityByCourse = new Map();
  for (const [courseKey, counts] of countsByCourse.entries()) {
    const ranked = [...counts.entries()].sort((lhs, rhs) => rhs[1] - lhs[1] || lhs[0].localeCompare(rhs[0], "ko"));
    const [termKey] = ranked[0] || [];
    if (!termKey) continue;
    const [yearText, semester] = termKey.split("\u001f");
    const year = Number(yearText);
    if (Number.isFinite(year) && semester) {
      majorityByCourse.set(courseKey, { year, semester });
    }
  }
  return items.map((item) => {
    if (item.academicYear && item.academicSemester) return item;
    const term = majorityByCourse.get(normalizeCourseKey(item.course));
    return term ? syncItemWithAcademicTerm(item, term) : item;
  });
}

function syncItemWithAcademicTerm(item, term) {
  if (!term) {
    return {
      ...item,
      academicTerm: "",
      academicYear: null,
      academicSemester: "",
    };
  }
  return {
    ...item,
    academicTerm: `${term.year}년 ${term.semester}`,
    academicYear: term.year,
    academicSemester: term.semester,
  };
}

function inferAcademicTermForSyncItem(item, fallbackYear) {
  const texts = [item.course, item.title, item.timestamp, item.status, item.detail]
    .map((value) => String(value || "").trim())
    .filter(Boolean);
  for (const text of texts) {
    const explicit = explicitAcademicTerm(text);
    if (explicit) return explicit;
  }
  for (const text of texts) {
    const yearMonth = firstYearMonth(text);
    if (yearMonth) return termFromYearMonth(yearMonth.year, yearMonth.month);
    const month = firstMonthWithoutYear(text);
    if (month && fallbackYear) return termFromYearMonth(fallbackYear, month);
  }
  return null;
}

function explicitAcademicTerm(text) {
  const normalized = String(text || "").replace(/[_/-]/g, " ");
  const rules = [
    [/(20\d{2}).{0,18}(spring|spr|봄|1\s*학기|1st\s*semester|first\s*semester)/i, "봄학기"],
    [/(20\d{2}).{0,18}(summer|sum|여름|하계|summer\s*semester)/i, "여름학기"],
    [/(20\d{2}).{0,18}(fall|autumn|가을|2\s*학기|2nd\s*semester|second\s*semester)/i, "가을학기"],
    [/(20\d{2}).{0,18}(winter|win|겨울|동계|winter\s*semester)/i, "겨울학기"],
    [/(spring|spr|봄|1\s*학기|1st\s*semester|first\s*semester).{0,18}(20\d{2})/i, "봄학기", 2],
    [/(summer|sum|여름|하계|summer\s*semester).{0,18}(20\d{2})/i, "여름학기", 2],
    [/(fall|autumn|가을|2\s*학기|2nd\s*semester|second\s*semester).{0,18}(20\d{2})/i, "가을학기", 2],
    [/(winter|win|겨울|동계|winter\s*semester).{0,18}(20\d{2})/i, "겨울학기", 2],
  ];
  for (const [regex, semester, yearIndex = 1] of rules) {
    const match = normalized.match(regex);
    const year = match ? Number(match[yearIndex]) : NaN;
    if (Number.isFinite(year)) return { year, semester };
  }
  return null;
}

function firstYearMonth(text) {
  const patterns = [
    /(20\d{2})\s*년\s*(1[0-2]|0?[1-9])\s*월/,
    /(20\d{2})[-./_](1[0-2]|0?[1-9])[-./_]\d{1,2}/,
    /(20\d{2})[-./_](1[0-2]|0?[1-9])\b/,
  ];
  for (const regex of patterns) {
    const match = String(text || "").match(regex);
    if (match) return { year: Number(match[1]), month: Number(match[2]) };
  }
  return null;
}

function firstMonthWithoutYear(text) {
  const match = String(text || "").match(/\b(1[0-2]|0?[1-9])(?:\s*월|[-./]\d{1,2}\b)/);
  return match ? Number(match[1]) : null;
}

function termFromYearMonth(year, month) {
  if (!Number.isFinite(year) || !Number.isFinite(month) || year < 2000 || year > 2099 || month < 1 || month > 12) {
    return null;
  }
  if (month >= 3 && month <= 6) return { year, semester: "봄학기" };
  if (month >= 7 && month <= 8) return { year, semester: "여름학기" };
  if (month >= 9) return { year, semester: "가을학기" };
  return { year: year - 1, semester: "겨울학기" };
}

function courseKeyMatchesAny(course, keys) {
  const needle = normalizeCourseKey(course);
  if (!needle) return false;
  for (const key of keys) {
    if (needle === key) return true;
    if (Math.min(needle.length, key.length) >= 4 && (needle.startsWith(key) || key.startsWith(needle))) {
      return true;
    }
  }
  return false;
}

function normalizeCourseKey(value) {
  return String(value || "")
    .normalize("NFKD")
    .toLowerCase()
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/\s+/g, "")
    .trim();
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
  const runLogsClearedAt = getMeta("syncDataRunLogsClearedAt");
  const runLogs = normalizeRunLogs(extras.runLogs, runLogsClearedAt);
  const normalizedTermCatalog = normalizeTermCatalog(extras.termCatalog);
  const termItems = applyTermCatalogToSyncItems(items, normalizedTermCatalog);
  const itemOverlay = applyItemActionsToSyncDataSnapshot(
    termItems,
    extras.calendarChanges || [],
    state.itemActions || [],
    now
  );
  const settings = applySettingActionsToSettings(
    extras.settings || [],
    state.settingActions || [],
    now
  );
  const nextStatus = statusWithStoredSyncData(state.status, itemOverlay.items, itemOverlay.calendarChanges);
  commitRelayMutation("sync-data", now, () => {
    db.prepare("DELETE FROM sync_items").run();
    const insertItem = db.prepare(`
      INSERT INTO sync_items (
        id, kind, course, title, timestamp, status, detail, attachment_count, updated_at, payload_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    for (const item of itemOverlay.items.slice(0, MAX_SYNC_ITEMS)) {
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
    setMeta("syncDataCalendarChanges", JSON.stringify(itemOverlay.calendarChanges));
    setMeta("syncDataTermCatalog", JSON.stringify(normalizedTermCatalog || null));
    setMeta("syncDataSettings", JSON.stringify(settings));
    setMeta("syncDataRunLogs", JSON.stringify(runLogs));
    setMeta("syncDataVerifySummary", JSON.stringify(extras.verifySummary || null));
    setMeta("syncDataGeneratedAt", String(generatedAt || now));
    setMeta("syncDataUpdatedAt", now);
    setMeta("status", JSON.stringify(nextStatus));
    setMeta("updatedAt", now);
  });
  state.status = nextStatus;
  state.updatedAt = now;
}

function applyItemActionsToSyncDataSnapshot(inputItems, inputCalendarChanges, actions, now) {
  let items = inputItems.map(normalizeSyncItem).filter(Boolean).slice(0, MAX_SYNC_ITEMS);
  let calendarChanges = normalizeCalendarChanges(inputCalendarChanges || []);
  for (const action of replayableServerActions(actions)) {
    const updatedAt = action.updatedAt || now;
    const itemPatch = mutateSyncItemsForItemAction(items, action, updatedAt);
    items = itemPatch.items;
    const calendarPatch = mutateCalendarChangesForItemAction(calendarChanges, action);
    calendarChanges = calendarPatch.calendarChanges;
  }
  return { items: items.sort(compareSyncItems), calendarChanges };
}

function replayableServerActions(actions) {
  return (Array.isArray(actions) ? actions : [])
    .filter((action) => {
      const status = String(action?.status || "").toLowerCase();
      return ["pending", "running", "completed"].includes(status);
    })
    .slice()
    .sort((lhs, rhs) => {
      const createdDelta = Date.parse(lhs.createdAt || "") - Date.parse(rhs.createdAt || "");
      if (Number.isFinite(createdDelta) && createdDelta !== 0) {
        return createdDelta;
      }
      return String(lhs.id || "").localeCompare(String(rhs.id || ""));
    });
}

function applySettingActionToStoredSyncData(action) {
  const settings = normalizeSettings(parseJSON(getMeta("syncDataSettings"), []));
  const next = applySettingActionsToSettings(settings, [action], action.updatedAt || new Date().toISOString());
  if (JSON.stringify(settings) === JSON.stringify(next)) {
    return { changed: false, applied: Boolean(action.key) };
  }
  return {
    changed: true,
    applied: true,
    persist() {
      setMeta("syncDataSettings", JSON.stringify(next));
      setMeta("syncDataUpdatedAt", action.updatedAt || new Date().toISOString());
    },
  };
}

function applySettingActionsToSettings(inputSettings, actions, now) {
  let settings = normalizeSettings(inputSettings);
  for (const action of replayableServerActions(actions)) {
    if (!action.key) {
      continue;
    }
    const index = settings.findIndex((setting) => setting.key === action.key);
    const previous = index >= 0 ? settings[index] : {};
    if (index >= 0 && String(previous.value ?? "") === String(action.value ?? "")) {
      continue;
    }
    const next = normalizeSettings([{
      ...previous,
      key: action.key,
      title: action.title || previous.title || action.key,
      value: action.value,
      valueKind: previous.valueKind || "text",
      options: previous.options || [],
      editable: previous.editable ?? true,
      updatedAt: action.updatedAt || now,
    }])[0];
    if (!next) {
      continue;
    }
    if (index >= 0) {
      settings[index] = next;
    } else {
      settings.push(next);
    }
  }
  return settings
    .slice()
    .sort((lhs, rhs) => String(lhs.key || "").localeCompare(String(rhs.key || "")));
}

function duplicateActiveSettingAction(actions, action) {
  return (Array.isArray(actions) ? actions : []).find((candidate) => {
    const status = String(candidate?.status || "").toLowerCase();
    return ["pending", "running"].includes(status)
      && String(candidate?.key || "") === String(action?.key || "")
      && String(candidate?.value ?? "") === String(action?.value ?? "");
  });
}

function applyItemActionToStoredSyncData(action) {
  const now = new Date().toISOString();
  let items = loadAllStoredSyncItems();
  let calendarChanges = normalizeCalendarChanges(parseJSON(getMeta("syncDataCalendarChanges"), []));

  const itemPatch = mutateSyncItemsForItemAction(items, action, now);
  items = itemPatch.items;

  const calendarPatch = mutateCalendarChangesForItemAction(calendarChanges, action);
  calendarChanges = calendarPatch.calendarChanges;

  const changed = itemPatch.changed || calendarPatch.changed;
  if (!changed) {
    return { changed: false };
  }

  return {
    changed: true,
    nextStatus: statusWithStoredSyncData(state.status, items, calendarChanges),
    persist() {
      saveStoredSyncDataPatch({
        items,
        calendarChanges,
        itemChanged: itemPatch.changed,
        calendarChanged: calendarPatch.changed,
        updatedAt: now,
      });
    },
  };
}

function loadAllStoredSyncItems() {
  return db.prepare(`
    SELECT payload_json
    FROM sync_items
  `).all()
    .map((row) => normalizeSyncItem(parseJSON(row.payload_json, null)))
    .filter(Boolean)
    .sort(compareSyncItems);
}

function saveStoredSyncDataPatch({ items, calendarChanges, itemChanged, calendarChanged, updatedAt }) {
  if (itemChanged) {
      db.prepare("DELETE FROM sync_items").run();
      const insertItem = db.prepare(`
        INSERT INTO sync_items (
          id, kind, course, title, timestamp, status, detail, attachment_count, updated_at, payload_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `);
      for (const item of items.slice(0, MAX_SYNC_ITEMS)) {
        const normalized = normalizeSyncItem({ ...item, updatedAt: item.updatedAt || updatedAt });
        if (!normalized) {
          continue;
        }
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
  }
  if (calendarChanged) {
    setMeta("syncDataCalendarChanges", JSON.stringify(calendarChanges));
  }
  setMeta("syncDataUpdatedAt", updatedAt);
}

function mutateSyncItemsForItemAction(inputItems, action, now) {
  let items = inputItems.map((item) => ({ ...item }));
  let changed = false;
  const markChanged = (nextItems) => {
    items = nextItems.map(normalizeSyncItem).filter(Boolean).slice(0, MAX_SYNC_ITEMS);
    changed = true;
  };
  const updateTarget = (mutator) => {
    const index = items.findIndex((item) => item.id === action.itemID);
    if (index < 0) {
      return;
    }
    const previous = JSON.stringify(items[index]);
    const next = normalizeSyncItem(mutator({ ...items[index], updatedAt: now }));
    if (!next) {
      return;
    }
    if (JSON.stringify(next) !== previous) {
      items[index] = next;
      changed = true;
    }
  };

  switch (action.action) {
    case "mailDashboardAdd": {
      const item = normalizeSyncItem(parseJSON(action.message, null)) || normalizeSyncItem({
        id: action.itemID,
        kind: action.itemKind,
        title: action.itemTitle,
        status: "메일 반영",
        updatedAt: now,
      });
      if (item) {
        const nextItem = normalizeSyncItem({ ...item, id: action.itemID || item.id, updatedAt: now, isHidden: false });
        markChanged([nextItem, ...items.filter((existing) => existing.id !== nextItem.id)]);
      }
      break;
    }
    case "mailDashboardRemove":
      if (items.some((item) => item.id === action.itemID)) {
        markChanged(items.filter((item) => item.id !== action.itemID));
      }
      break;
    case "assignmentComplete":
      updateTarget((item) => ({ ...item, kind: "completedAssignment", status: "완료", isHidden: false }));
      break;
    case "assignmentRestore":
    case "assignmentUnhide":
      updateTarget((item) => ({ ...item, kind: item.kind === "completedAssignment" ? "assignment" : item.kind, status: "", isHidden: false }));
      break;
    case "assignmentHide":
      updateTarget((item) => ({ ...item, status: "숨김", isHidden: true }));
      break;
    case "examPromote":
      updateTarget((item) => ({ ...item, kind: "exam", status: "시험", isHidden: false }));
      break;
    case "examIgnore":
      updateTarget((item) => ({ ...item, status: "시험 아님", isHidden: true }));
      break;
    case "examRestore":
      updateTarget((item) => ({ ...item, status: "", isHidden: false }));
      break;
    case "noticeRead":
      updateTarget((item) => ({ ...item, isRead: true }));
      break;
    case "noticeUnread":
      updateTarget((item) => ({ ...item, isRead: false }));
      break;
    case "noticeImportant":
      updateTarget((item) => ({ ...item, isImportant: true }));
      break;
    case "noticeUnimportant":
      updateTarget((item) => ({ ...item, isImportant: false }));
      break;
    case "noticeHide":
      updateTarget((item) => ({ ...item, isHidden: true }));
      break;
    case "noticeUnhide":
      updateTarget((item) => ({ ...item, isHidden: false }));
      break;
    case "fileHide":
      updateTarget((item) => ({ ...item, isHidden: true }));
      break;
    case "fileUnhide":
      updateTarget((item) => ({ ...item, isHidden: false }));
      break;
    case "fileTrash":
      updateTarget((item) => ({ ...item, status: "휴지통", isHidden: true }));
      break;
    default:
      break;
  }

  return { items: items.sort(compareSyncItems), changed };
}

function isServerDisplayOnlyItemAction(action) {
  return [
    "assignmentComplete",
    "assignmentRestore",
    "assignmentHide",
    "assignmentUnhide",
    "examPromote",
    "examIgnore",
    "examRestore",
    "noticeRead",
    "noticeUnread",
    "noticeImportant",
    "noticeUnimportant",
    "noticeHide",
    "noticeUnhide",
    "fileHide",
    "fileUnhide",
    "mailDashboardAdd",
    "mailDashboardRemove",
  ].includes(String(action || ""));
}

function isClientCompletedCalendarAction(action) {
  return action
    && String(action.status || "") === "completed"
    && ["calendarCreate", "calendarEdit", "calendarDelete"].includes(String(action.action || ""));
}

function itemActionUpdatesServerVisibleState(action) {
  return isServerDisplayOnlyItemAction(action) || [
    "fileTrash",
    "calendarApply",
    "calendarCreate",
    "calendarEdit",
    "calendarDelete",
    "calendarOpen",
  ].includes(String(action || ""));
}

function mutateCalendarChangesForItemAction(inputChanges, action) {
  if (!["calendarApply", "calendarCreate", "calendarEdit", "calendarDelete"].includes(action.action)) {
    return { calendarChanges: inputChanges, changed: false };
  }
  const calendarChanges = inputChanges.filter((change) => !calendarChangeMatchesItemAction(change, action));
  return {
    calendarChanges,
    changed: calendarChanges.length !== inputChanges.length,
  };
}

function calendarChangeMatchesItemAction(change, action) {
  const itemID = String(action.itemID || "");
  if (!itemID) {
    return false;
  }
  if (String(change.identifier || "") === itemID) {
    return true;
  }
  return calendarChangeStableID(change) === itemID;
}

function calendarChangeStableID(change) {
  const normalized = normalizeCalendarChanges([change])[0] || {};
  return [
    normalized.action,
    normalized.calendar,
    normalized.bucket,
    normalized.identifier,
    normalized.title,
    normalized.start_at,
    normalized.due_at,
    normalized.raw,
  ].map((part) => String(part || "")).join("|");
}

function statusWithStoredSyncData(rawStatus, items, calendarChanges) {
  const status = normalizeStatus(rawStatus || defaultStatus);
  const visibleCalendarChanges = calendarChanges.filter(isUserVisibleCalendarChange);
  const visible = items.filter((item) => !item.isHidden);
  const notices = visible.filter((item) => item.kind === "notice");
  const files = visible.filter((item) => item.kind === "file");
  status.assignments = visible.filter((item) => item.kind === "assignment").length;
  status.exams = visible.filter((item) => item.kind === "exam").length;
  status.helpDesk = visible.filter((item) => item.kind === "helpDesk").length;
  status.notices = notices.length;
  status.noticeNew = notices.filter((item) => !item.isRead).length;
  status.noticeIgnored = items.filter((item) => item.kind === "notice" && item.isHidden).length;
  status.fileTotal = files.length;
  status.newFiles = Math.min(status.newFiles, status.fileTotal);
  status.calendarCreated = visibleCalendarChanges.filter((change) => change.action === "created" || change.action === "mail").length;
  status.calendarUpdated = visibleCalendarChanges.filter((change) => change.action === "updated").length;
  status.calendarDeleted = 0;
  return status;
}

function isUserVisibleCalendarChange(change) {
  const action = String(change?.action || "").trim().toLowerCase();
  if (action === "deleted") {
    return false;
  }
  if (action === "updated") {
    const meaningfulChanges = Array.isArray(change?.changes) ? change.changes : [];
    if (meaningfulChanges.length === 0) {
      return true;
    }
    return meaningfulChanges
      .map((value) => String(value || "").trim().toLowerCase())
      .filter(Boolean)
      .some((value) => !["메모", "memo", "note", "notes"].includes(value));
  }
  return true;
}

function compareSyncItems(lhs, rhs) {
  const lhsMode = syncItemSortMode(lhs);
  const rhsMode = syncItemSortMode(rhs);
  const lhsTimestamp = syncItemTimestampEpoch(lhs);
  const rhsTimestamp = syncItemTimestampEpoch(rhs);
  const bothUpcoming = lhsMode === "upcoming" && rhsMode === "upcoming";
  const bothRecent = lhsMode === "recent" && rhsMode === "recent";
  if ((bothUpcoming || bothRecent) && Number.isFinite(lhsTimestamp) && Number.isFinite(rhsTimestamp) && lhsTimestamp !== rhsTimestamp) {
    return bothUpcoming ? lhsTimestamp - rhsTimestamp : rhsTimestamp - lhsTimestamp;
  }
  if ((bothUpcoming || bothRecent) && (Number.isFinite(lhsTimestamp) || Number.isFinite(rhsTimestamp))) {
    return Number.isFinite(lhsTimestamp) ? -1 : 1;
  }
  if (lhsMode !== rhsMode) {
    const priorityDelta = syncItemKindPriority(lhs) - syncItemKindPriority(rhs);
    if (priorityDelta !== 0) {
      return priorityDelta;
    }
  }
  const bothFiles = String(lhs.kind || "") === "file" && String(rhs.kind || "") === "file";
  if (!bothFiles) {
    const updatedDelta = Date.parse(rhs.updatedAt || "") - Date.parse(lhs.updatedAt || "");
    if (Number.isFinite(updatedDelta) && updatedDelta !== 0) {
      return updatedDelta;
    }
    const timestampDelta = String(rhs.timestamp || "").localeCompare(String(lhs.timestamp || ""));
    if (timestampDelta !== 0) {
      return timestampDelta;
    }
  }
  const courseDelta = String(lhs.course || "").localeCompare(String(rhs.course || ""), "ko");
  if (courseDelta !== 0) {
    return courseDelta;
  }
  return String(lhs.title || "").localeCompare(String(rhs.title || ""), "ko");
}

function syncItemSortMode(item) {
  switch (String(item?.kind || "")) {
    case "assignment":
    case "assignmentCandidate":
    case "completedAssignment":
    case "exam":
    case "examCandidate":
    case "helpDesk":
      return "upcoming";
    case "notice":
    case "file":
      return "recent";
    default:
      return "updated";
  }
}

function syncItemKindPriority(item) {
  switch (String(item?.kind || "")) {
    case "assignment":
      return 10;
    case "assignmentCandidate":
      return 11;
    case "exam":
      return 20;
    case "examCandidate":
      return 21;
    case "helpDesk":
      return 30;
    case "notice":
      return 40;
    case "file":
      return 50;
    case "completedAssignment":
      return 60;
    default:
      return 90;
  }
}

function syncItemTimestampEpoch(item) {
  return dashboardTimestampEpoch(item?.timestamp);
}

function dashboardTimestampEpoch(value) {
  const text = String(value || "").trim();
  if (!text) return Number.NaN;
  const dashMatch = text
    .replace(/\bKST\b/g, "")
    .trim()
    .match(/^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2})(?::(\d{1,2}))?)?/);
  if (dashMatch) {
    return seoulEpoch(
      Number(dashMatch[1]),
      Number(dashMatch[2]),
      Number(dashMatch[3]),
      Number(dashMatch[4] || 0),
      Number(dashMatch[5] || 0)
    );
  }
  const koreanMatch = text.match(/(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일(?:.*?(오전|오후)\s*(\d{1,2})(?::(\d{1,2}))?)?/);
  if (koreanMatch) {
    let hour = Number(koreanMatch[5] || 0);
    const marker = koreanMatch[4] || "";
    if (marker === "오후" && hour < 12) hour += 12;
    if (marker === "오전" && hour === 12) hour = 0;
    return seoulEpoch(
      Number(koreanMatch[1]),
      Number(koreanMatch[2]),
      Number(koreanMatch[3]),
      hour,
      Number(koreanMatch[6] || 0)
    );
  }
  if (text.includes("T")) {
    const parsed = Date.parse(text);
    if (Number.isFinite(parsed)) return Math.floor(parsed / 1000);
  }
  return Number.NaN;
}

function seoulEpoch(year, month, day, hour, minute) {
  if (![year, month, day, hour, minute].every(Number.isFinite)) return Number.NaN;
  return Math.floor(Date.UTC(year, month - 1, day, hour - 9, minute, 0) / 1000);
}

function syncDataResponse({ kind = "", limit = 250 } = {}) {
  const trimmedKind = String(kind || "").trim();
  const rows = trimmedKind
    ? db.prepare(`
        SELECT payload_json
        FROM sync_items
        WHERE kind = ?
      `).all(trimmedKind)
    : db.prepare(`
        SELECT payload_json
        FROM sync_items
      `).all();
  const dryRunReports = parseJSON(getMeta("syncDataDryRunReports"), []);
  const calendarChanges = parseJSON(getMeta("syncDataCalendarChanges"), []);
  const termCatalog = parseJSON(getMeta("syncDataTermCatalog"), null);
  const normalizedTermCatalog = normalizeTermCatalog(termCatalog);
  const visibleCalendarChanges = normalizeCalendarChanges(calendarChanges).filter(isUserVisibleCalendarChange);
  const settings = parseJSON(getMeta("syncDataSettings"), []);
  const sharedSettings = loadSharedSettings();
  const runLogs = parseJSON(getMeta("syncDataRunLogs"), []);
  const verifySummary = parseJSON(getMeta("syncDataVerifySummary"), null);
  const runLogsClearedAt = getMeta("syncDataRunLogsClearedAt");
  return {
    revision: currentRelayRevision(),
    generatedAt: getMeta("syncDataGeneratedAt") || "",
    updatedAt: getMeta("syncDataUpdatedAt") || "",
    items: applyTermCatalogToSyncItems(
      rows.map((row) => parseJSON(row.payload_json, null)),
      normalizedTermCatalog
    ).sort(compareSyncItems).slice(0, limit),
    dryRunReports: normalizeDryRunReports(dryRunReports),
    calendarChanges: visibleCalendarChanges,
    termCatalog: normalizedTermCatalog,
    settings: normalizeSettings(settings),
    sharedSettings,
    runLogs: normalizeRunLogs(runLogs, runLogsClearedAt),
    verifySummary: normalizeVerifySummary(verifySummary),
  };
}

function sharedSettingsResponse() {
  return {
    settings: loadSharedSettings(),
  };
}

function loadSharedSettings() {
  return normalizedSharedSettings(normalizeSettings(parseJSON(getMeta("sharedSettings"), [])));
}

function updateSharedSetting(key, body, request) {
  const setting = normalizeSharedSettingInput(key, body);
  if (!setting) {
    return null;
  }
  const current = loadSharedSettings();
  const next = normalizedSharedSettings([
    ...current.filter((item) => item.key !== setting.key),
    setting,
  ]);
  commitRelayMutation("shared-settings", setting.updatedAt, () => {
    setMeta("sharedSettings", JSON.stringify(next));
    setMeta("updatedAt", setting.updatedAt);
    appendRequestLog(request, {
      action: `${setting.title} 변경`,
      status: "updated",
      message: "서버 공유 설정을 바로 저장했습니다.",
    });
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

function clearSharedRunLogs() {
  const clearedAt = new Date().toISOString();
  const previous = normalizeRunLogs(parseJSON(getMeta("syncDataRunLogs"), []));
  commitRelayMutation("sync-data:run-logs-clear", clearedAt, () => {
    setMeta("syncDataRunLogs", "[]");
    setMeta("syncDataRunLogsClearedAt", clearedAt);
    setMeta("syncDataUpdatedAt", clearedAt);
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
  })).filter((setting) => SYNC_SETTING_KEYS.has(setting.key));
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
      const startedAt = normalizedLogTimestamp(log?.startedAt || log?.started_at, now);
      const finishedAt = normalizedLogTimestamp(log?.finishedAt || log?.finished_at, startedAt);
      const updatedAt = normalizedLogTimestamp(log?.updatedAt || log?.updated_at, finishedAt);
      const finishedTime = Date.parse(finishedAt) || Date.parse(updatedAt) || 0;
      if (clearedTime > 0 && finishedTime <= clearedTime) {
        return null;
      }
      const command = sanitizePublicText(log?.command);
      if (!RUN_LOG_COMMAND_TITLES.has(command)) return null;
      const exitCode = boundedInt(log?.exitCode ?? log?.exit_code, 0, -999, 999);
      const wasCancelled = normalizeBoolean(log?.wasCancelled ?? log?.was_cancelled);
      return {
        id: normalizeUUIDText(log?.id) || crypto.randomUUID(),
        command,
        commandTitle: RUN_LOG_COMMAND_TITLES.get(command),
        status: wasCancelled ? "중단됨" : (exitCode === 0 ? "성공" : `실패 ${exitCode}`),
        startedAt,
        finishedAt,
        updatedAt,
        duration: sanitizePublicText(log?.duration),
        exitCode,
        dryRun: normalizeBoolean(log?.dryRun ?? log?.dry_run),
        wasCancelled,
        needsAttention: !wasCancelled && exitCode !== 0,
        outputTail: sanitizeLogText(log?.outputTail || log?.output_tail),
      };
    })
    .filter(Boolean)
    .sort((lhs, rhs) => Date.parse(rhs.finishedAt) - Date.parse(lhs.finishedAt))
    .slice(0, MAX_SHARED_RUN_LOGS);
}

function normalizedLogTimestamp(value, fallback) {
  const text = String(value || "").trim();
  return text.length <= 64 && Number.isFinite(Date.parse(text)) ? text : fallback;
}

function sanitizePublicText(value) {
  const text = String(value || "").trim();
  if (!text) {
    return "";
  }
  if (looksPrivateText(text)) {
    return "";
  }
  return sanitizeLogText(text).replace(/\s+/g, " ").slice(0, MAX_PUBLIC_TEXT_CHARS);
}

function sanitizeLogText(value) {
  return redactPublicLogText(value, { maximumUTF8Bytes: MAX_SHARED_RUN_LOG_CHARS });
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
  return loadFileAccessQuotaForKey(quotaKeyForToday());
}

function loadFileAccessQuotaForKey(value) {
  const key = /^fileAccessQuota:\d{4}-\d{2}-\d{2}$/.test(String(value || ""))
    ? String(value)
    : quotaKeyForToday();
  const raw = parseJSON(getMeta(key), {});
  return {
    key,
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

function reserveFileDownload(id, limits, { reason = "file-access:download-reserved", requestLog = null } = {}) {
  db.exec("BEGIN IMMEDIATE");
  try {
    const normalizedID = normalizeUUIDText(id);
    const internalLease = db.prepare(`
      SELECT status, upload_claim
      FROM file_access_requests
      WHERE id = ?
    `).get(normalizedID);
    if (internalLease?.upload_claim) {
      db.exec("ROLLBACK");
      return {
        ok: false,
        httpStatus: 409,
        error: "파일 링크를 정리 중이거나 더 이상 사용할 수 없습니다.",
      };
    }
    const current = getFileAccessRequest(id);
    if (!current || current.status !== "completed") {
      db.exec("ROLLBACK");
      return {
        ok: false,
        httpStatus: 409,
        error: "파일 링크를 정리 중이거나 더 이상 사용할 수 없습니다.",
      };
    }
    if (Number(current.downloadCount || 0) >= limits.downloadsPerLink) {
      db.exec("ROLLBACK");
      return { ok: false, error: "이 링크의 다운로드 가능 횟수를 초과했습니다." };
    }
    const quota = loadFileAccessQuota();
    if (quota.downloadCount >= limits.dailyDownloads) {
      db.exec("ROLLBACK");
      return { ok: false, error: "오늘의 파일 다운로드 한도에 도달했습니다." };
    }
    const updatedAt = new Date().toISOString();
    const token = crypto.randomUUID();
    const normalizedLog = requestLog ? normalizeRequestLogEntry(null, requestLog) : null;
    const reservation = db.prepare(`
      UPDATE file_access_requests
      SET download_count = download_count + 1, updated_at = ?
      WHERE id = ? AND status = 'completed' AND upload_claim IS NULL
    `).run(updatedAt, current.id);
    if (reservation.changes !== 1) {
      db.exec("ROLLBACK");
      return {
        ok: false,
        httpStatus: 409,
        error: "파일 링크를 정리 중이거나 더 이상 사용할 수 없습니다.",
      };
    }
    saveFileAccessQuota({ ...quota, downloadCount: quota.downloadCount + 1 });
    db.prepare(`
      INSERT INTO file_download_reservations(
        token, request_id, quota_key, log_id, log_created_at, created_at
      ) VALUES (?, ?, ?, ?, ?, ?)
    `).run(
      token,
      normalizedID,
      quota.key,
      normalizedLog?.id || crypto.randomUUID(),
      normalizedLog?.createdAt || updatedAt,
      updatedAt
    );
    if (normalizedLog) appendRequestLog(null, normalizedLog);
    db.exec("COMMIT");
    return {
      ok: true,
      token,
      quotaKey: quota.key,
      updatedAt,
      downloadCount: Number(current.downloadCount || 0) + 1,
      revision: currentRelayRevision(),
    };
  } catch (error) {
    if (db.isTransaction) db.exec("ROLLBACK");
    throw error;
  }
}

function finalizeFileDownloadReservation(id, token, {
  reason = "file-access:downloaded",
  requestLog = null,
  notify = true,
} = {}) {
  let event = null;
  db.exec("BEGIN IMMEDIATE");
  try {
    const normalizedID = normalizeUUIDText(id);
    const reservation = db.prepare(`
      SELECT token, request_id, log_id, log_created_at
      FROM file_download_reservations
      WHERE token = ? AND request_id = ?
    `).get(normalizeUUIDText(token), normalizedID);
    if (!reservation) {
      db.exec("ROLLBACK");
      return { ok: true, settled: false, alreadySettled: true };
    }
    const deleted = db.prepare(`
      DELETE FROM file_download_reservations
      WHERE token = ? AND request_id = ?
    `).run(reservation.token, normalizedID);
    if (deleted.changes !== 1) {
      db.exec("ROLLBACK");
      return { ok: true, settled: false, alreadySettled: true };
    }
    if (requestLog) {
      appendRequestLog(null, {
        ...requestLog,
        id: reservation.log_id,
        createdAt: reservation.log_created_at,
      });
    }
    const updatedAt = new Date().toISOString();
    event = recordRelayEvent(reason, updatedAt);
    db.exec("COMMIT");
    if (notify) broadcastRelayEvent(event);
    return { ok: true, settled: true, revision: event.revision };
  } catch (error) {
    if (db.isTransaction) db.exec("ROLLBACK");
    throw error;
  }
}

function releaseFileDownloadReservation(id, token, {
  reason = "file-access:download-failed",
  requestLog = null,
  notify = true,
} = {}) {
  let event = null;
  db.exec("BEGIN IMMEDIATE");
  try {
    const normalizedID = normalizeUUIDText(id);
    const reservation = db.prepare(`
      SELECT token, request_id, quota_key, log_id, log_created_at
      FROM file_download_reservations
      WHERE token = ? AND request_id = ?
    `).get(normalizeUUIDText(token), normalizedID);
    if (!reservation) {
      db.exec("ROLLBACK");
      return { ok: true, released: false, alreadySettled: true };
    }
    const deleted = db.prepare(`
      DELETE FROM file_download_reservations
      WHERE token = ? AND request_id = ?
    `).run(reservation.token, normalizedID);
    if (deleted.changes !== 1) {
      db.exec("ROLLBACK");
      return { ok: true, released: false, alreadySettled: true };
    }
    db.prepare(`
      UPDATE file_access_requests
      SET download_count = MAX(0, download_count - 1)
      WHERE id = ?
    `).run(normalizedID);
    const quota = loadFileAccessQuotaForKey(reservation.quota_key);
    saveFileAccessQuota({
      ...quota,
      downloadCount: Math.max(0, quota.downloadCount - 1),
    });
    if (requestLog) {
      appendRequestLog(null, {
        ...requestLog,
        id: reservation.log_id,
        createdAt: reservation.log_created_at,
      });
    }
    const updatedAt = new Date().toISOString();
    event = recordRelayEvent(reason, updatedAt);
    db.exec("COMMIT");
    if (notify) broadcastRelayEvent(event);
    return { ok: true, released: true, revision: event.revision };
  } catch (error) {
    if (db.isTransaction) db.exec("ROLLBACK");
    throw error;
  }
}

function recoverStaleFileDownloadReservations({ notify = true } = {}) {
  const staleBefore = new Date(Date.now() - FILE_DOWNLOAD_RESERVATION_LEASE_MS).toISOString();
  const reservations = db.prepare(`
    SELECT token, request_id, log_id
    FROM file_download_reservations
    WHERE created_at <= ?
    ORDER BY created_at ASC
    LIMIT ?
  `).all(staleBefore, MAX_FILE_ACCESS_REQUESTS);
  let released = 0;
  for (const reservation of reservations) {
    const currentLog = loadRequestLog().find((entry) => entry.id === reservation.log_id);
    const result = releaseFileDownloadReservation(reservation.request_id, reservation.token, {
      reason: "file-access:download-reservation-expired",
      requestLog: currentLog ? {
        ...currentLog,
        status: "failed",
        message: "파일 읽기가 완료되지 않아 다운로드 예약을 복구했습니다.",
      } : null,
      notify,
    });
    if (result.released) released += 1;
  }
  return released;
}

function fileDownloadRequestLog(fileRequest, { preview = false, status = "running" } = {}) {
  return {
    id: crypto.randomUUID(),
    action: preview ? "파일 미리보기" : "파일 다운로드",
    status,
    message: fileRequest.itemTitle || "파일",
    method: "GET",
    path: preview ? "/v1/file-access/:id/download?preview" : "/v1/file-access/:id/download",
    source: "웹",
    createdAt: new Date().toISOString(),
  };
}

function recordTestFileObjectRead() {
  if (!TEST_TRACK_FILE_OBJECT_READS) return;
  const current = Number.parseInt(getMeta("testFileObjectReadCount") || "0", 10);
  setMeta("testFileObjectReadCount", String(Number.isSafeInteger(current) ? current + 1 : 1));
}

function randomToken() {
  return crypto.randomBytes(24).toString("base64url");
}

function downloadURLFor(fileRequest, request) {
  const url = PUBLIC_URL
    ? new URL(PUBLIC_URL)
    : new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);
  const basePath = PUBLIC_URL ? url.pathname.replace(/\/+$/, "") : "";
  url.pathname = `${basePath}/v1/file-access/${fileRequest.id}/download`;
  url.search = "";
  url.hash = "";
  return url.toString();
}

function localFileObjectPath(objectKey, expectedRequestID = "") {
  const key = String(objectKey || "");
  if (!isValidFileObjectKey(key, expectedRequestID)) {
    throw new RelayValidationError("invalid file object key");
  }
  const root = path.resolve(FILE_DIR);
  const resolved = path.resolve(root, ...key.split("/"));
  if (!resolved.startsWith(`${root}${path.sep}`)) {
    throw new RelayValidationError("file object path escapes storage root");
  }
  return resolved;
}

function isValidFileObjectKey(objectKey, expectedRequestID = "") {
  const key = String(objectKey || "");
  if (!key || key.length > 512 || key.includes("\\") || key.includes("\0")) return false;
  const segments = key.split("/");
  if (segments.length !== 3 || segments.some((segment) => !segment || segment === "." || segment === "..")) return false;
  const [prefix, requestID, objectName] = segments;
  if (prefix !== "file-access" || !normalizeUUIDText(requestID)) return false;
  if (expectedRequestID && requestID !== normalizeUUIDText(expectedRequestID)) return false;
  const objectMatch = objectName.match(/^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})-(.+)$/i);
  const objectID = objectMatch?.[1] || "";
  const filename = objectMatch?.[2] || "";
  return Boolean(normalizeUUIDText(objectID) && filename && filename.length <= 160 && !/[\u0000-\u001F/]/.test(filename));
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
  if (contentType === "image/svg+xml" || extension === "svg") {
    preview = { available: true, kind: "text", label: "텍스트", contentType: "text/plain; charset=utf-8", message: "" };
  } else if (contentType === "application/pdf") {
    preview = { available: true, kind: "pdf", label: "PDF", contentType, message: "" };
  } else if (SAFE_INLINE_IMAGE_CONTENT_TYPES.has(contentType)) {
    preview = { available: true, kind: "image", label: "이미지", contentType, message: "" };
  } else if (SAFE_INLINE_AUDIO_CONTENT_TYPES.has(contentType)) {
    preview = { available: true, kind: "audio", label: "오디오", contentType, message: "" };
  } else if (SAFE_INLINE_VIDEO_CONTENT_TYPES.has(contentType)) {
    preview = { available: true, kind: "video", label: "동영상", contentType, message: "" };
  } else if (
    contentType.startsWith("text/")
    || ["txt", "md", "markdown", "csv", "tsv", "json", "xml", "log"].includes(extension)
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

function contentSecurityNonce() {
  return crypto.randomBytes(18).toString("base64");
}

function encodeRFC5987ValueChars(value) {
  return encodeURIComponent(value)
    .replace(/['()]/g, escape)
    .replace(/\*/g, "%2A")
    .replace(/%(?:7C|60|5E)/g, unescape);
}

function loadCancelRequest() {
  return normalizeCancelRequest(parseJSON(getMeta("cancelRequest"), {}));
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
    case "calendarCreate":
      return "캘린더 일정 등록";
    case "calendarEdit":
      return "캘린더 내용 수정";
    case "calendarDelete":
      return "캘린더 일정 삭제";
    case "calendarOpen":
      return "캘린더에서 열기";
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

function expandHome(value) {
  if (value === "~") {
    return os.homedir();
  }
  if (value.startsWith("~/")) {
    return path.join(os.homedir(), value.slice(2));
  }
  return value;
}

function normalizePublicRelayURL(value) {
  const text = String(value || "").trim();
  if (!text) return "";
  let url;
  try {
    url = new URL(text);
  } catch {
    throw new Error("KLMS_RELAY_PUBLIC_URL must be an absolute URL");
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new Error("KLMS_RELAY_PUBLIC_URL cannot contain credentials, query, or fragment");
  }
  if (url.protocol !== "https:" && !(url.protocol === "http:" && isLoopbackHostname(url.hostname))) {
    throw new Error("KLMS_RELAY_PUBLIC_URL must use HTTPS except for loopback development");
  }
  url.pathname = url.pathname.replace(/\/+$/, "");
  return url.toString().replace(/\/$/, "");
}

function isLoopbackHostname(value) {
  const host = String(value || "").trim().replace(/^\[|\]$/g, "").toLowerCase();
  return host === "localhost" || host === "127.0.0.1" || host === "::1";
}

function relayReadiness() {
  const checks = { database: false, schema: false, realtime: false };
  try {
    db.prepare("SELECT 1 AS ok").get();
    checks.database = true;
    const tables = new Set(db.prepare(`
      SELECT name FROM sqlite_master WHERE type = 'table'
    `).all().map((row) => row.name));
    const indexes = new Set(db.prepare(`
      SELECT name FROM sqlite_master WHERE type = 'index'
    `).all().map((row) => row.name));
    const fileColumns = new Set(db.prepare("PRAGMA table_info(file_access_requests)").all().map((row) => row.name));
    const actionColumns = new Set(db.prepare("PRAGMA table_info(item_actions)").all().map((row) => row.name));
    const revision = getMeta("relayRevision");
    checks.schema = [
      "meta", "commands", "item_actions", "sync_items", "file_access_requests", "file_download_reservations",
    ].every((name) => tables.has(name))
      && ["upload_claim", "pending_object_key", "reserved_upload_bytes", "reserved_upload_quota_key"].every((name) => fileColumns.has(name))
      && actionColumns.has("idempotency_key")
      && ["commands_one_active_idx", "item_actions_idempotency_key_idx"].every((name) => indexes.has(name))
      && /^(0|[1-9][0-9]*)$/.test(String(revision || "0"));
    checks.realtime = server.listening && server.listenerCount("upgrade") > 0;
  } catch {
    // Readiness intentionally returns only component state, never DB details.
  }
  return {
    ok: Object.values(checks).every(Boolean),
    service: "klms-relay",
    checks,
  };
}

async function createVerifiedDatabaseBackup(sourcePath, destinationPath) {
  await fs.mkdir(path.dirname(destinationPath), { recursive: true, mode: 0o700 });
  await fs.chmod(path.dirname(destinationPath), 0o700);
  try {
    await fs.lstat(destinationPath);
    throw new Error(`backup destination already exists: ${destinationPath}`);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  const temporaryPath = path.join(
    path.dirname(destinationPath),
    `.${path.basename(destinationPath)}.tmp-${process.pid}-${crypto.randomUUID()}`
  );
  const source = new DatabaseSync(sourcePath, { readOnly: true });
  let copiedRevision = "0";
  try {
    await backupDatabase(source, temporaryPath);
    await fs.chmod(temporaryPath, 0o600);
    const verification = await verifyDatabaseBackup(temporaryPath);
    copiedRevision = verification.revision;
    try {
      // The sibling hard-link atomically publishes a fully verified file and,
      // unlike rename(2), cannot replace a destination created concurrently.
      await fs.link(temporaryPath, destinationPath);
    } catch (error) {
      if (error?.code === "EEXIST") {
        throw new Error(`backup destination already exists: ${destinationPath}`);
      }
      throw error;
    }
    const stat = await fs.stat(destinationPath);
    console.log(JSON.stringify({ ok: true, backupPath: destinationPath, bytes: stat.size, revision: copiedRevision }));
  } finally {
    source.close();
    await fs.rm(temporaryPath, { force: true }).catch(() => {});
  }
}

async function verifyDatabaseBackup(databasePath) {
  const copied = new DatabaseSync(databasePath, { readOnly: true });
  try {
    const check = copied.prepare("PRAGMA quick_check").get();
    if (String(check?.quick_check || "").toLowerCase() !== "ok") {
      throw new Error("backup quick_check failed");
    }
    const requiredTables = new Set(copied.prepare(`
      SELECT name FROM sqlite_master WHERE type = 'table'
    `).all().map((row) => row.name));
    for (const table of ["meta", "commands", "item_actions", "sync_items", "file_access_requests"]) {
      if (!requiredTables.has(table)) throw new Error(`backup is missing required table: ${table}`);
    }
    const revision = String(
      copied.prepare("SELECT value FROM meta WHERE key = 'relayRevision'").get()?.value ?? "0"
    );
    const numericRevision = Number(revision);
    if (!/^(0|[1-9][0-9]*)$/.test(revision) || !Number.isSafeInteger(numericRevision) || numericRevision < 0) {
      throw new Error(`backup relayRevision is invalid: ${revision}`);
    }
    return { ok: true, backupPath: databasePath, revision };
  } finally {
    copied.close();
  }
}

async function pruneDatabaseBackups(directoryPath, retentionDays) {
  await fs.mkdir(directoryPath, { recursive: true, mode: 0o700 });
  await fs.chmod(directoryPath, 0o700);
  const cutoff = Date.now() - retentionDays * 24 * 60 * 60 * 1000;
  const removed = [];
  for (const entry of await fs.readdir(directoryPath, { withFileTypes: true })) {
    if (!entry.isFile() || !/^(?:klms-sync-relay\.sqlite-|pre-restore-).+\.backup$/.test(entry.name)) continue;
    const candidatePath = path.join(directoryPath, entry.name);
    const stat = await fs.stat(candidatePath);
    if (stat.mtimeMs >= cutoff) continue;
    await fs.unlink(candidatePath);
    removed.push(entry.name);
  }
  return { ok: true, directory: directoryPath, retentionDays, removed };
}
