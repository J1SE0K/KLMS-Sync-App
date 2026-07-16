import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";

const cwd = path.resolve(import.meta.dirname, "..");
const wrangler = path.join(cwd, "node_modules", "wrangler", "bin", "wrangler.js");
const persistTo = await fs.mkdtemp(path.join(os.tmpdir(), "klms-d1-integration-"));
const port = await availablePort();
const baseURL = `http://127.0.0.1:${port}`;
const clientToken = "integration-client-token-0123456789abcdef0123456789abcdef";
const workerToken = "integration-worker-token-fedcba9876543210fedcba9876543210";
let dev = null;
let devOutput = "";

try {
  const legacyMigrationsDir = path.join(persistTo, "legacy-migrations");
  const legacyConfigPath = path.join(persistTo, "legacy-wrangler.toml");
  await fs.mkdir(legacyMigrationsDir, { recursive: true });
  const legacyMigrationNames = (await fs.readdir(path.join(cwd, "migrations")))
    .filter((name) => /^000[1-6]_.*\.sql$/.test(name))
    .sort();
  assert.equal(legacyMigrationNames.length, 6);
  await Promise.all(legacyMigrationNames.map((name) => (
    fs.copyFile(path.join(cwd, "migrations", name), path.join(legacyMigrationsDir, name))
  )));
  const legacyConfig = (await fs.readFile(path.join(cwd, "wrangler.toml"), "utf8"))
    .replace('main = "src/worker.mjs"', `main = ${JSON.stringify(path.join(cwd, "src/worker.mjs"))}`)
    .replace('migrations_dir = "migrations"', `migrations_dir = ${JSON.stringify(legacyMigrationsDir)}`);
  await fs.writeFile(legacyConfigPath, legacyConfig, "utf8");

  const legacyMigration = await runProcess(process.execPath, [
    wrangler,
    "--config", legacyConfigPath,
    "d1", "migrations", "apply", "klms-sync-relay",
    "--local",
    "--persist-to", persistTo,
  ]);
  assert.equal(legacyMigration.code, 0, legacyMigration.output);
  assert.match(legacyMigration.output, /0006_file_upload_claim_lease\.sql/);

  const validTimestamp = "2026-07-14T00:00:00.000Z";
  assert.equal(Number.isFinite(Date.parse("12:34:56")), false);
  assert.equal(Number.isFinite(Date.parse("now")), false);
  assert.equal(Number.isFinite(Date.parse("2460000.5")), false);
  const malformedCommandIDs = {
    uuid: "not-a-command-uuid",
    kind: crypto.randomUUID(),
    timestamp: crypto.randomUUID(),
    timeOnlyCreated: crypto.randomUUID(),
    keywordUpdated: crypto.randomUUID(),
    julianCreated: crypto.randomUUID(),
  };
  const seedMalformedCommands = await runProcess(process.execPath, [
    wrangler,
    "--config", legacyConfigPath,
    "d1", "execute", "klms-sync-relay",
    "--local",
    "--persist-to", persistTo,
    "--command", `
      DROP INDEX commands_one_active_idx;
      INSERT INTO commands(id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json, options_json)
      VALUES
        ('${malformedCommandIDs.uuid}', 'fullSync', 'pending', '${validTimestamp}', '${validTimestamp}', NULL, 0, '{}', '{}'),
        ('${malformedCommandIDs.kind}', 'invalidLegacyKind', 'running', '${validTimestamp}', '${validTimestamp}', NULL, 0, '{}', '{}'),
        ('${malformedCommandIDs.timestamp}', 'verify', 'pending', 'not-a-timestamp', '${validTimestamp}', NULL, 0, '{}', '{}'),
        ('${malformedCommandIDs.timeOnlyCreated}', 'doctor', 'running', '12:34:56', '${validTimestamp}', NULL, 0, '{}', '{}'),
        ('${malformedCommandIDs.keywordUpdated}', 'report', 'pending', '${validTimestamp}', 'now', NULL, 0, '{}', '{}'),
        ('${malformedCommandIDs.julianCreated}', 'coreSync', 'running', '2460000.5', '${validTimestamp}', NULL, 0, '{}', '{}');
    `,
  ]);
  assert.equal(seedMalformedCommands.code, 0, seedMalformedCommands.output);

  const sqliteAcceptedNonCanonicalTimes = await runProcess(process.execPath, [
    wrangler,
    "--config", legacyConfigPath,
    "d1", "execute", "klms-sync-relay",
    "--local",
    "--persist-to", persistTo,
    "--json",
    "--command", `
      SELECT
        julianday('12:34:56') IS NOT NULL AS time_only_is_parseable,
        julianday('now') IS NOT NULL AS now_is_parseable,
        julianday('2460000.5') IS NOT NULL AS julian_is_parseable;
    `,
  ]);
  assert.equal(sqliteAcceptedNonCanonicalTimes.code, 0, sqliteAcceptedNonCanonicalTimes.output);
  const sqliteTimeProbe = JSON.parse(sqliteAcceptedNonCanonicalTimes.output)[0].results[0];
  assert.equal(sqliteTimeProbe.time_only_is_parseable, 1);
  assert.equal(sqliteTimeProbe.now_is_parseable, 1);
  assert.equal(sqliteTimeProbe.julian_is_parseable, 1);

  const migration = await runProcess(process.execPath, [
    wrangler,
    "d1", "migrations", "apply", "klms-sync-relay",
    "--local",
    "--persist-to", persistTo,
  ]);
  assert.equal(migration.code, 0, migration.output);
  assert.match(migration.output, /0007_sanitize_active_commands\.sql/);
  assert.match(migration.output, /0008_relay_a_plus_integrity\.sql/);
  assert.match(migration.output, /0009_file_download_reservations\.sql/);

  const sanitizedCommands = await runProcess(process.execPath, [
    wrangler,
    "d1", "execute", "klms-sync-relay",
    "--local",
    "--persist-to", persistTo,
    "--json",
    "--command", `
      SELECT id, status, updated_at, julianday(updated_at) IS NOT NULL AS updated_at_is_valid
      FROM commands
      WHERE id IN (
        '${malformedCommandIDs.uuid}',
        '${malformedCommandIDs.kind}',
        '${malformedCommandIDs.timestamp}',
        '${malformedCommandIDs.timeOnlyCreated}',
        '${malformedCommandIDs.keywordUpdated}',
        '${malformedCommandIDs.julianCreated}'
      )
      ORDER BY id;
    `,
  ]);
  assert.equal(sanitizedCommands.code, 0, sanitizedCommands.output);
  const sanitizedRows = JSON.parse(sanitizedCommands.output)[0].results;
  assert.equal(sanitizedRows.length, 6);
  assert.equal(sanitizedRows.every((row) => row.status === "macUnavailable"), true);
  assert.equal(sanitizedRows.every((row) => row.updated_at_is_valid === 1), true);

  dev = spawnDev();
  await waitForServer();

  assert.equal((await jsonRequest("/healthz")).configured, true, "Wrangler must bind the mutation coordinator");
  assert.equal((await jsonRequest("/v1/status")).revision, 0);
  const recoveredPendingCommands = await jsonRequest("/v1/commands/pending", { role: "worker" });
  assert.equal(
    Object.values(malformedCommandIDs).some((id) => recoveredPendingCommands.commands.some((command) => command.id === id)),
    false,
    "malformed active rows must be terminalized before load and remain absent from the active API",
  );
  const recoveredCommands = await jsonRequest("/v1/commands/recent?limit=100");
  const updatedOnlyCommand = recoveredCommands.commands.find((command) => command.id === malformedCommandIDs.keywordUpdated);
  assert.equal(updatedOnlyCommand?.status, "macUnavailable");
  const stillMalformedCommandIDs = Object.values(malformedCommandIDs)
    .filter((id) => id !== malformedCommandIDs.keywordUpdated);
  assert.equal(
    stillMalformedCommandIDs.some((id) => recoveredCommands.commands.some((command) => command.id === id)),
    false,
    "rows whose forensic identity or creation timestamp remains malformed must be absent from recent commands",
  );
  assert.equal((await rawWebSocketUpgrade("/v1/events?role=invalid", clientToken)).status, 400);
  assert.equal((await rawWebSocketUpgrade("/v1/events", clientToken)).status, 400);
  assert.equal((await rawWebSocketUpgrade("/v1/events?role=client", "wrong-token")).status, 401);

  const socket = await rawWebSocketUpgrade("/v1/events?role=client", clientToken);
  assert.equal(socket.status, 101);
  const hello = await socket.next();
  assert.equal(hello.type, "hello");
  assert.equal(hello.revision, 0);

  const commandResponses = await Promise.all(Array.from({ length: 20 }, (_, index) => (
    request("/v1/commands", {
      method: "POST",
      body: { kind: index % 2 ? "verify" : "doctor" },
    })
  )));
  assert.equal(
    commandResponses.filter((response) => response.status === 201).length,
    1,
    "a valid command must acquire the active slot after malformed legacy rows are sanitized",
  );
  assert.equal(commandResponses.filter((response) => response.status === 409).length, 19);
  const command = await commandResponses.find((response) => response.status === 201).json();
  const commandEvent = await socket.next();
  assert.equal(commandEvent.reason, "commands:pending");
  assert.equal(commandEvent.revision, 1);
  assert.equal(commandEvent.requiresSnapshot, false);
  await jsonRequest(`/v1/commands/${command.id}`, {
    method: "PUT",
    role: "worker",
    body: { ...command, status: "completed" },
  });
  assert.equal((await socket.next()).revision, 2);

  const firstFile = await createFileRequest("integration-link-quota");
  assert.equal((await socket.next()).revision, 3);
  const firstUpload = await uploadWithContention(firstFile.id);
  assert.equal((await socket.next()).revision, 4);
  const firstStatuses = await downloadMany(firstUpload.downloadURL, 50);
  assert.equal(firstStatuses.filter((status) => status === 200).length, 7);
  assert.equal(firstStatuses.filter((status) => status === 429).length, 43);
  await consumeEvents(socket, 7, 11);

  const secondFile = await createFileRequest("integration-daily-quota");
  assert.equal((await socket.next()).revision, 12);
  const secondUpload = await uploadWithContention(secondFile.id);
  assert.equal((await socket.next()).revision, 13);
  const secondStatuses = await downloadMany(secondUpload.downloadURL, 50);
  assert.equal(secondStatuses.filter((status) => status === 200).length, 5);
  assert.equal(secondStatuses.filter((status) => status === 429).length, 45);
  await consumeEvents(socket, 5, 18);

  const finalStatus = await jsonRequest("/v1/status");
  assert.equal(finalStatus.revision, 18, "failed contenders and quota rejects must not allocate revisions");

  const freshLeaseRequest = await createFileRequest("integration-fresh-upload-lease");
  assert.equal((await socket.next()).revision, 19);
  const staleLeaseRequest = await createFileRequest("integration-stale-upload-lease");
  assert.equal((await socket.next()).revision, 20);
  socket.close();

  await stopDev();
  const seedLeases = await runProcess(process.execPath, [
    wrangler,
    "d1", "execute", "klms-sync-relay",
    "--local",
    "--persist-to", persistTo,
    "--command", `
      UPDATE file_access_requests
      SET upload_claim = 'live-worker-claim',
          upload_claimed_at = '2999-01-01T00:00:00.000Z'
      WHERE id = '${freshLeaseRequest.id}' AND object_key IS NULL;
      UPDATE file_access_requests
      SET upload_claim = 'orphaned-worker-claim',
          upload_claimed_at = '2000-01-01T00:00:00.000Z'
      WHERE id = '${staleLeaseRequest.id}' AND object_key IS NULL;
    `,
  ]);
  assert.equal(seedLeases.code, 0, seedLeases.output);

  dev = spawnDev();
  await waitForServer();
  assert.equal((await jsonRequest("/v1/status")).revision, 20, "seeding/restarting internal leases must not allocate a revision");
  const beforeRecovery = await jsonRequest("/v1/file-access/recent");
  assert.equal(beforeRecovery.requests.find((item) => item.id === freshLeaseRequest.id)?.updatedAt, freshLeaseRequest.updatedAt);
  assert.equal(beforeRecovery.requests.find((item) => item.id === staleLeaseRequest.id)?.updatedAt, staleLeaseRequest.updatedAt);

  const freshLeaseUpload = await request(`/v1/file-access/${freshLeaseRequest.id}/upload`, {
    method: "PUT",
    role: "worker",
    rawBody: "must-not-steal",
    headers: { "Content-Type": "text/plain", "Content-Length": "14" },
  });
  assert.equal(freshLeaseUpload.status, 409, "a live lease must survive a Worker restart");
  assert.equal((await jsonRequest("/v1/status")).revision, 20);

  const recoveredUpload = await request(`/v1/file-access/${staleLeaseRequest.id}/upload`, {
    method: "PUT",
    role: "worker",
    rawBody: "recovered-after-crash",
    headers: { "Content-Type": "text/plain", "Content-Length": "21" },
  });
  assert.equal(recoveredUpload.status, 200, await recoveredUpload.text());
  assert.equal((await jsonRequest("/v1/status")).revision, 21, "only the finalized recovered upload allocates a revision");

  const concurrencySocket = await rawWebSocketUpgrade("/v1/events?role=client", clientToken);
  const concurrencyHello = await concurrencySocket.next();
  assert.equal(concurrencyHello.revision, 21);
  const baselineLog = await jsonRequest("/v1/request-log/recent?limit=100");
  const baselineLogIDs = new Set(baselineLog.entries.map((entry) => entry.id));
  const concurrentCount = 20;
  const noticeItems = Array.from({ length: concurrentCount }, (_, index) => ({
    id: `concurrent-notice-${String(index).padStart(2, "0")}`,
    kind: "notice",
    course: "Concurrency",
    title: `Concurrent notice ${index}`,
    timestamp: new Date(Date.now() + index * 1_000).toISOString(),
    isImportant: false,
  }));
  const seededSync = await jsonRequest("/v1/sync-data", {
    method: "POST",
    role: "worker",
    body: { generatedAt: new Date().toISOString(), items: noticeItems, settings: [] },
  });
  assert.equal(seededSync.revision, 22);
  const syncEvent = await concurrencySocket.next();
  assert.equal(syncEvent.revision, 22);
  assert.equal(syncEvent.reason, "sync-data");

  const concurrentSettingKeys = [
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
  ];
  const settingResponses = await Promise.all(Array.from({ length: concurrentCount }, (_, index) => (
    request("/v1/setting-actions", {
      method: "POST",
      body: {
        key: concurrentSettingKeys[index],
        title: `Concurrent setting ${index}`,
        value: `value-${index}`,
      },
    })
  )));
  assert.equal(settingResponses.filter((response) => response.status === 201).length, concurrentCount);
  const settingActions = await Promise.all(settingResponses.map((response) => response.json()));
  await consumeSequentialEvents(concurrencySocket, concurrentCount, 22, "setting-actions:pending");

  const itemResponses = await Promise.all(noticeItems.map((item) => (
    request("/v1/item-actions", {
      method: "POST",
      body: {
        action: "noticeImportant",
        itemID: item.id,
        itemKind: "notice",
        itemTitle: item.title,
      },
    })
  )));
  assert.equal(itemResponses.filter((response) => response.status === 201).length, concurrentCount);
  const itemActions = await Promise.all(itemResponses.map((response) => response.json()));
  await consumeSequentialEvents(concurrencySocket, concurrentCount, 42, "item-actions:server-state");

  const pendingSettings = await jsonRequest("/v1/setting-actions/pending", { role: "worker" });
  assert.equal(settingActions.every((action) => pendingSettings.actions.some((stored) => stored.id === action.id)), true);
  const recentItems = await jsonRequest("/v1/item-actions/recent?limit=50");
  assert.equal(itemActions.every((action) => recentItems.actions.some((stored) => stored.id === action.id)), true);
  const concurrentSnapshot = await jsonRequest("/v1/sync-data?limit=100");
  assert.equal(
    settingActions.every((action) => concurrentSnapshot.settings.some((setting) => setting.key === action.key && setting.value === action.value)),
    true,
    "parallel setting mutations must all survive in syncDataSettings"
  );
  assert.equal(
    noticeItems.every((item) => concurrentSnapshot.items.some((stored) => stored.id === item.id && stored.isImportant === true)),
    true,
    "parallel item mutations must all survive in syncDataItems"
  );
  const concurrentLog = await jsonRequest("/v1/request-log/recent?limit=100");
  const addedLogEntries = concurrentLog.entries.filter((entry) => !baselineLogIDs.has(entry.id));
  assert.equal(addedLogEntries.length, concurrentCount * 2, "each parallel setting/item action must retain its request log entry");
  assert.equal((await jsonRequest("/v1/status")).revision, 62, "each serialized mutation must allocate exactly one monotonic revision");
  concurrencySocket.close();

  const stalledRequest = await createFileRequest("integration-stalled-upload");
  assert.equal((await jsonRequest("/v1/status")).revision, 63);
  const [quotaBeforeStall = { upload_count: 0, upload_bytes: 0 }] = await localD1Rows(`
    SELECT upload_count, upload_bytes
    FROM file_access_quota
    ORDER BY quota_date DESC
    LIMIT 1;
  `);
  const stalledBytes = 8 * 1024 * 1024;
  const stalledUpload = startStalledUpload(stalledRequest.id, stalledBytes);
  await delay(250);
  const [reservedStall] = await localD1Rows(`
    SELECT f.pending_object_key, f.reserved_upload_bytes, f.reserved_upload_quota_date,
           q.upload_count, q.upload_bytes
    FROM file_access_requests AS f
    JOIN file_access_quota AS q ON q.quota_date = f.reserved_upload_quota_date
    WHERE f.id = '${stalledRequest.id}';
  `);
  assert.match(reservedStall.pending_object_key, new RegExp(`^file-access/${stalledRequest.id}/`));
  assert.equal(reservedStall.reserved_upload_bytes, stalledBytes);
  assert.equal(reservedStall.upload_count, quotaBeforeStall.upload_count + 1);
  assert.equal(reservedStall.upload_bytes, quotaBeforeStall.upload_bytes + stalledBytes);
  const [responsiveStatus, responsiveSync, responsiveCommand] = await Promise.all([
    timed(() => jsonRequest("/v1/status")),
    timed(() => jsonRequest("/v1/sync-data", {
      method: "POST",
      role: "worker",
      body: { generatedAt: new Date().toISOString(), items: [], settings: [] },
    })),
    timed(() => jsonRequest("/v1/commands", {
      method: "POST",
      expectedStatus: 201,
      body: { kind: "doctor" },
    })),
  ]);
  for (const operation of [responsiveStatus, responsiveSync, responsiveCommand]) {
    assert.ok(operation.elapsedMs < 2_000, `stalled upload blocked a coordinated request for ${operation.elapsedMs}ms`);
  }
  assert.equal(responsiveStatus.value.revision, 63);
  assert.equal(responsiveSync.value.revision, 64);
  assert.equal(responsiveCommand.value.status, "pending");
  const completedWhileStalled = await timed(() => jsonRequest(`/v1/commands/${responsiveCommand.value.id}`, {
    method: "PUT",
    role: "worker",
    body: { ...responsiveCommand.value, status: "completed" },
  }));
  assert.ok(completedWhileStalled.elapsedMs < 2_000, `command completion took ${completedWhileStalled.elapsedMs}ms`);
  stalledUpload.finish();
  const stalledUploadResponse = await stalledUpload.response;
  assert.equal(stalledUploadResponse.status, 200, stalledUploadResponse.body);
  const [finalizedStall] = await localD1Rows(`
    SELECT pending_object_key, reserved_upload_bytes, reserved_upload_quota_date
    FROM file_access_requests
    WHERE id = '${stalledRequest.id}';
  `);
  assert.equal(finalizedStall.pending_object_key, null);
  assert.equal(finalizedStall.reserved_upload_bytes, 0);
  assert.equal(finalizedStall.reserved_upload_quota_date, null);
  assert.equal((await jsonRequest("/v1/status")).revision, 67);
  const duplicateStalledUpload = await request(`/v1/file-access/${stalledRequest.id}/upload`, {
    method: "PUT",
    role: "worker",
    rawBody: "duplicate",
    headers: { "Content-Type": "text/plain", "Content-Length": "9" },
  });
  assert.equal(duplicateStalledUpload.status, 409);

  const terminalRaceRequest = await createFileRequest("integration-upload-terminal-race");
  const terminalRaceUpload = startStalledUpload(terminalRaceRequest.id, 2 * 1024 * 1024);
  await delay(250);
  await jsonRequest(`/v1/file-access/${terminalRaceRequest.id}`, {
    method: "PUT",
    role: "worker",
    body: {
      id: terminalRaceRequest.id,
      itemID: terminalRaceRequest.itemID,
      itemKind: terminalRaceRequest.itemKind,
      status: "failed",
      message: "worker rejected while upload body was still arriving",
    },
  });
  terminalRaceUpload.finish();
  const terminalRaceResponse = await terminalRaceUpload.response;
  assert.equal(terminalRaceResponse.status, 409, "finalize must not resurrect a terminal file request");
  const terminalRaceRecent = await jsonRequest("/v1/file-access/recent?limit=100");
  const terminalRaceStored = terminalRaceRecent.requests.find((item) => item.id === terminalRaceRequest.id);
  assert.equal(terminalRaceStored?.status, "failed");
  assert.equal(terminalRaceStored?.downloadURL, null);
  assert.equal((await jsonRequest("/v1/status")).revision, 69);

  const abortedRequest = await createFileRequest("integration-aborted-upload");
  const abortedUpload = startStalledUpload(abortedRequest.id, 2 * 1024 * 1024);
  await delay(250);
  await abortedUpload.abort();
  const retryAfterAbort = await retryUploadUntilReleased(abortedRequest.id);
  assert.equal(retryAfterAbort.status, 200, retryAfterAbort.body);
  assert.equal((await jsonRequest("/v1/status")).revision, 71, "aborted body reads must release their claim without a revision");

  const idempotentActionID = crypto.randomUUID();
  const idempotentActionBody = {
    id: idempotentActionID,
    action: "calendarVerify",
    itemID: "integration-idempotency-target",
    itemKind: "calendar",
    itemTitle: "Integration idempotency target",
  };
  const idempotentResponses = await Promise.all(Array.from({ length: 20 }, () => (
    request("/v1/item-actions", { method: "POST", body: idempotentActionBody })
  )));
  assert.equal(idempotentResponses.filter((response) => response.status === 201).length, 1);
  assert.equal(idempotentResponses.filter((response) => response.status === 200).length, 19);
  const idempotentActions = await Promise.all(idempotentResponses.map((response) => response.json()));
  assert.equal(idempotentActions.every((action) => action.id === idempotentActionID), true);
  assert.equal((await jsonRequest("/v1/status")).revision, 72, "idempotent replays must allocate one revision total");
  const idempotencyConflict = await request("/v1/item-actions", {
    method: "POST",
    body: { ...idempotentActionBody, action: "calendarOpen" },
  });
  assert.equal(idempotencyConflict.status, 409);
  assert.equal((await jsonRequest("/v1/status")).revision, 72);

  await stopDev();
  dev = spawnDev({ requestsPerMinute: 2 });
  await waitForServer();
  assert.equal((await request("/readyz", { role: "worker" })).status, 200);
  assert.equal((await request("/readyz", { role: "worker" })).status, 200);
  await stopDev();
  dev = spawnDev({ requestsPerMinute: 2 });
  await waitForServer();
  assert.equal(
    (await request("/readyz", { role: "worker" })).status,
    429,
    "the durable rate window must survive Worker and Durable Object restart",
  );
  console.log("cloudflare local D1 integration ok");
} finally {
  await stopDev();
  await fs.rm(persistTo, { recursive: true, force: true });
}

function spawnDev({ requestsPerMinute = 6_000 } = {}) {
  devOutput = "";
  const child = spawn(process.execPath, [
    wrangler,
    "dev",
    "--port", String(port),
    "--persist-to", persistTo,
    "--var", `RELAY_CLIENT_TOKEN:${clientToken}`,
    "--var", `RELAY_WORKER_TOKEN:${workerToken}`,
    "--var", `RELAY_REQUESTS_PER_MINUTE:${requestsPerMinute}`,
    "--var", "FILE_RELAY_DOWNLOADS_PER_LINK:7",
    "--var", "FILE_RELAY_DAILY_DOWNLOADS:12",
  ], {
    cwd,
    env: { ...process.env, CI: "1", NO_COLOR: "1" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  for (const stream of [child.stdout, child.stderr]) {
    stream.setEncoding("utf8");
    stream.on("data", (chunk) => { devOutput += chunk; });
  }
  return child;
}

async function stopDev() {
  if (!dev) return;
  const child = dev;
  child.kill("SIGTERM");
  await Promise.race([onceExit(child), new Promise((resolve) => setTimeout(resolve, 2_000))]);
  if (child.exitCode == null && child.signalCode == null) {
    child.kill("SIGKILL");
    await onceExit(child);
  }
  if (dev === child) dev = null;
}

async function createFileRequest(itemID) {
  return jsonRequest("/v1/file-access", {
    method: "POST",
    expectedStatus: 201,
    body: { itemID, itemKind: "file", itemTitle: `${itemID}.txt` },
  });
}

async function uploadWithContention(id) {
  const responses = await Promise.all(Array.from({ length: 20 }, (_, index) => {
    const body = `content-${index}`;
    return request(`/v1/file-access/${id}/upload`, {
      method: "PUT",
      role: "worker",
      rawBody: body,
      headers: {
        "Content-Type": "text/plain",
        "Content-Length": String(Buffer.byteLength(body)),
      },
    });
  }));
  assert.equal(responses.filter((response) => response.status === 200).length, 1);
  assert.equal(responses.filter((response) => response.status === 409).length, 19);
  return responses.find((response) => response.status === 200).json();
}

async function downloadMany(downloadURL, count) {
  const url = new URL(downloadURL);
  url.searchParams.set("download", "1");
  const responses = await Promise.all(Array.from({ length: count }, () => fetch(url)));
  return responses.map((response) => response.status);
}

async function consumeEvents(socket, count, finalRevision) {
  let lastRevision = 0;
  for (let index = 0; index < count; index += 1) {
    const event = await socket.next();
    assert.equal(event.reason, "file-access:downloaded");
    assert.equal(event.requiresSnapshot, false);
    assert.ok(event.revision > lastRevision);
    lastRevision = event.revision;
  }
  assert.equal(lastRevision, finalRevision);
}

async function consumeSequentialEvents(socket, count, startRevision, reason) {
  for (let index = 1; index <= count; index += 1) {
    const event = await socket.next();
    assert.equal(event.reason, reason);
    assert.equal(event.requiresSnapshot, false);
    assert.equal(event.revision, startRevision + index, "serialized events must have no revision gaps or duplicates");
  }
}

function startStalledUpload(id, totalBytes = 8 * 1024 * 1024) {
  let requestHandle;
  const response = new Promise((resolve, reject) => {
    requestHandle = http.request(`${baseURL}/v1/file-access/${id}/upload`, {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${workerToken}`,
        "Content-Type": "application/octet-stream",
        "Content-Length": String(totalBytes),
        "X-KLMS-Filename": encodeURIComponent("stalled.bin"),
      },
    }, (incoming) => {
      const chunks = [];
      incoming.on("data", (chunk) => chunks.push(chunk));
      incoming.on("end", () => resolve({
        status: incoming.statusCode || 0,
        body: Buffer.concat(chunks).toString("utf8"),
      }));
    });
    requestHandle.once("error", reject);
    requestHandle.write(Buffer.from([0x61]));
  });
  return {
    response,
    finish() {
      requestHandle.end(Buffer.alloc(totalBytes - 1, 0x61));
    },
    abort() {
      requestHandle.destroy(new Error("intentional stalled upload abort"));
      return response.catch(() => null);
    },
  };
}

async function retryUploadUntilReleased(id) {
  const deadline = Date.now() + 3_000;
  while (Date.now() < deadline) {
    const body = "retry-after-abort";
    const response = await request(`/v1/file-access/${id}/upload`, {
      method: "PUT",
      role: "worker",
      rawBody: body,
      headers: { "Content-Type": "text/plain", "Content-Length": String(Buffer.byteLength(body)) },
    });
    const responseBody = await response.text();
    if (response.status !== 409) return { status: response.status, body: responseBody };
    await delay(50);
  }
  return { status: 409, body: "upload claim was not released after abort" };
}

async function timed(operation) {
  const startedAt = performance.now();
  const value = await operation();
  return { value, elapsedMs: performance.now() - startedAt };
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function request(route, { method = "GET", role = "client", body, rawBody, headers = {} } = {}) {
  const requestHeaders = new Headers(headers);
  requestHeaders.set("Authorization", `Bearer ${role === "worker" ? workerToken : clientToken}`);
  if (body != null) requestHeaders.set("Content-Type", "application/json");
  return fetch(`${baseURL}${route}`, {
    method,
    headers: requestHeaders,
    body: rawBody ?? (body != null ? JSON.stringify(body) : undefined),
  });
}

async function jsonRequest(route, options = {}) {
  const response = await request(route, options);
  const text = await response.text();
  assert.equal(response.status, options.expectedStatus || 200, text);
  return JSON.parse(text);
}

async function waitForServer() {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    if (dev.exitCode != null) throw new Error(`wrangler exited early\n${devOutput}`);
    try {
      const response = await fetch(`${baseURL}/healthz`);
      if (response.ok) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`wrangler did not start\n${devOutput}`);
}

async function availablePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const selected = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return selected;
}

function rawWebSocketUpgrade(route, token) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: "127.0.0.1", port });
    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error("websocket upgrade timeout"));
    }, 3_000);
    let handshake = Buffer.alloc(0);
    const onError = (error) => {
      clearTimeout(timeout);
      reject(error);
    };
    const onData = (chunk) => {
      handshake = Buffer.concat([handshake, chunk]);
      const boundary = handshake.indexOf("\r\n\r\n");
      if (boundary < 0) return;
      clearTimeout(timeout);
      socket.off("error", onError);
      socket.off("data", onData);
      const head = handshake.subarray(0, boundary).toString("utf8");
      const status = Number.parseInt(head.split("\r\n", 1)[0].split(" ")[1] || "0", 10);
      if (status !== 101) {
        socket.destroy();
        resolve({ status });
        return;
      }
      const queue = webSocketJSONQueue(socket, handshake.subarray(boundary + 4));
      resolve({ status, next: queue.next, close: () => socket.destroy() });
    };
    socket.once("error", onError);
    socket.on("data", onData);
    socket.once("connect", () => {
      socket.write([
        `GET ${route} HTTP/1.1`,
        `Host: 127.0.0.1:${port}`,
        "Connection: Upgrade",
        "Upgrade: websocket",
        "Sec-WebSocket-Version: 13",
        `Sec-WebSocket-Key: ${crypto.randomBytes(16).toString("base64")}`,
        `Authorization: Bearer ${token}`,
        "",
        "",
      ].join("\r\n"));
    });
  });
}

function webSocketJSONQueue(socket, initialData) {
  const queued = [];
  const waiters = [];
  let buffer = Buffer.from(initialData);
  let failure = null;
  const fail = (error) => {
    failure = error;
    while (waiters.length) waiters.shift().reject(error);
  };
  const drain = () => {
    while (buffer.length >= 2) {
      const opcode = buffer[0] & 0x0f;
      let length = buffer[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (buffer.length < 4) return;
        length = buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (buffer.length < 10) return;
        length = Number(buffer.readBigUInt64BE(2));
        offset = 10;
      }
      if (buffer.length < offset + length) return;
      const payload = buffer.subarray(offset, offset + length);
      buffer = buffer.subarray(offset + length);
      if (opcode === 0x8) return fail(new Error("websocket closed"));
      if (opcode !== 0x1) continue;
      const value = JSON.parse(payload.toString("utf8"));
      const waiter = waiters.shift();
      if (waiter) waiter.resolve(value);
      else queued.push(value);
    }
  };
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    try { drain(); } catch (error) { fail(error); }
  });
  socket.on("error", fail);
  drain();
  return {
    next() {
      if (failure) return Promise.reject(failure);
      if (queued.length) return Promise.resolve(queued.shift());
      return new Promise((resolve, reject) => {
        const waiter = { resolve, reject };
        waiters.push(waiter);
        const timeout = setTimeout(() => {
          const index = waiters.indexOf(waiter);
          if (index >= 0) {
            waiters.splice(index, 1);
            reject(new Error("websocket event timeout"));
          }
        }, 5_000);
        timeout.unref();
      });
    },
  };
}

function runProcess(command, args) {
  const child = spawn(command, args, {
    cwd,
    env: { ...process.env, CI: "1", NO_COLOR: "1" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  for (const stream of [child.stdout, child.stderr]) {
    stream.setEncoding("utf8");
    stream.on("data", (chunk) => { output += chunk; });
  }
  return new Promise((resolve) => child.once("exit", (code) => resolve({ code, output })));
}

async function localD1Rows(command) {
  const result = await runProcess(process.execPath, [
    wrangler,
    "d1", "execute", "klms-sync-relay",
    "--local",
    "--persist-to", persistTo,
    "--json",
    "--command", command,
  ]);
  assert.equal(result.code, 0, result.output);
  return JSON.parse(result.output)[0]?.results || [];
}

function onceExit(child) {
  if (child.exitCode != null || child.signalCode != null) return Promise.resolve(child.exitCode);
  return new Promise((resolve) => child.once("exit", resolve));
}
