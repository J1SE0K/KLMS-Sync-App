import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { consumeBoundedRateWindow } from "../../tools/klms_bounded_rate_window.mjs";
import { redactPublicLogText } from "../../tools/klms_public_log_redactor.mjs";

assertBoundedRateWindowContract(consumeBoundedRateWindow);

const projectRoot = path.resolve(import.meta.dirname, "../..");
const serverPath = path.join(projectRoot, "tools", "klms_relay_server.mjs");
const publicLogRedactionFixture = JSON.parse(await fs.readFile(
  path.join(projectRoot, "tests", "fixtures", "public_log_redaction_cases.json"),
  "utf8",
));
assert.equal(publicLogRedactionFixture.version, 3);
for (const testCase of publicLogRedactionFixture.cases) {
  const output = redactPublicLogText(testCase.input);
  assert.equal(output, testCase.expected, testCase.id);
  assert.equal(redactPublicLogText(output), output, `${testCase.id} must be idempotent`);
}
assert.equal(
  redactPublicLogText("가".repeat(10), { maximumUTF8Bytes: 10 }),
  "...\n가가",
  "public logs must be bounded by UTF-8 bytes without splitting a scalar",
);
assert.equal(
  redactPublicLogText(Array.from({ length: 45 }, (_, index) => `line-${String(index).padStart(2, "0")}`).join("\n"))
    .split("\n").length,
  40,
  "public logs must retain at most the newest 40 lines",
);
const deeplyNestedPublicLog = `${"[".repeat(2_000)}{"token":"deep-secret"}${"]".repeat(2_000)}`;
assert.match(redactPublicLogText(deeplyNestedPublicLog), /\[credential\]/);
assert.doesNotMatch(redactPublicLogText(deeplyNestedPublicLog), /deep-secret/);
const malformedPEMEndFlood = `${"-----END PRIVATE KEY-----\n".repeat(20_000)}tail`;
const malformedPEMEndFloodOutput = redactPublicLogText(malformedPEMEndFlood);
assert.ok(malformedPEMEndFloodOutput.endsWith("tail"));
assert.doesNotMatch(malformedPEMEndFloodOutput, /PRIVATE KEY/i);
const publicLogRedactionCases = publicLogRedactionFixture.cases.filter((testCase) => [
  "nested-json-credential",
  "bare-credential-assignment",
  "quoted-posix-path",
  "json-windows-backslash-path",
  "quoted-url",
  "complete-pem-block",
].includes(testCase.id));
const root = await fs.mkdtemp(path.join(os.tmpdir(), "klms-relay-test-"));
const dbPath = path.join(root, "relay.sqlite");
const fileDir = path.join(root, "files");
const backupPath = path.join(root, "relay.backup.sqlite");
const sentinelPath = path.join(root, "sentinel.txt");
const port = 20_000 + Math.floor(Math.random() * 20_000);
const baseURL = `http://127.0.0.1:${port}`;
const clientToken = "client-test-token-with-enough-entropy";
const workerToken = "worker-test-token-with-enough-entropy";
const proxySecret = "proxy-test-secret-with-enough-entropy";
const MAX_ITEM_ACTION_TEST_HISTORY = 205;
const child = spawn(process.execPath, [serverPath], {
  cwd: projectRoot,
  env: {
    ...process.env,
    KLMS_RELAY_HOST: "127.0.0.1",
    KLMS_RELAY_PORT: String(port),
    KLMS_RELAY_DB: dbPath,
    KLMS_RELAY_FILE_DIR: fileDir,
    KLMS_RELAY_CLIENT_TOKEN: clientToken,
    KLMS_RELAY_WORKER_TOKEN: workerToken,
    NODE_ENV: "test",
    KLMS_RELAY_TEST_FILE_DELETE_DELAY_MS: "300",
    KLMS_RELAY_TEST_FILE_READ_DELAY_MS: "200",
    KLMS_RELAY_TEST_TRACK_FILE_OBJECT_READS: "1",
    KLMS_RELAY_REQUESTS_PER_MINUTE: "6000",
    KLMS_FILE_RELAY_DOWNLOADS_PER_LINK: "1",
    KLMS_FILE_RELAY_DAILY_DOWNLOADS: "2",
  },
  stdio: ["ignore", "pipe", "pipe"],
});
let restartedChild = null;
let publicURLChild = null;

let stderr = "";
child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => { stderr += chunk; });

try {
  await waitForServer();
  assert.equal((await fetch(`${baseURL}/readyz`)).status, 401);
  const initialReadiness = await request("/readyz", { role: "worker" });
  assert.equal(initialReadiness.status, 200);
  assert.equal((await initialReadiness.json()).ok, true);
  await fs.writeFile(sentinelPath, "must survive", "utf8");

  {
    const staleID = crypto.randomUUID();
    const staleAt = new Date(Date.now() - (2 * 60 * 60 * 1000)).toISOString();
    const observer = new DatabaseSync(dbPath);
    try {
      observer.prepare(`
        INSERT INTO file_access_requests(
          id, item_id, item_kind, item_title, status, created_at, updated_at, message
        ) VALUES (?, 'unauthorized-maintenance', 'file', 'private', 'pending', ?, ?, '')
      `).run(staleID, staleAt, staleAt);
    } finally {
      observer.close();
    }
    assert.equal((await fetch(`${baseURL}/v1/status`)).status, 401);
    const verifier = new DatabaseSync(dbPath);
    try {
      assert.equal(
        verifier.prepare("SELECT status FROM file_access_requests WHERE id = ?").get(staleID).status,
        "pending",
        "unauthorized requests must not run relay maintenance"
      );
      verifier.prepare("DELETE FROM file_access_requests WHERE id = ?").run(staleID);
    } finally {
      verifier.close();
    }
  }

  assert.equal(
    (await fetch(`${baseURL}/v1/file-access/not-a-uuid/download?ticket=${"a".repeat(64)}`)).status,
    404
  );
  assert.equal(
    (await fetch(`${baseURL}/v1/file-access/00000000-0000-4000-8000-000000000001/download?ticket=short`)).status,
    403
  );

  const initialStatus = await jsonRequest("/v1/status");
  assert.equal(initialStatus.revision, 0);
  assert.equal((await request("/v1/events/poll?role=client&waitSeconds=30")).status, 410);

  const invalid = await request("/v1/commands", {
    method: "POST",
    body: { kind: "notACommand", id: crypto.randomUUID(), status: "running" },
  });
  assert.equal(invalid.status, 400);
  const malformedJSON = await fetch(`${baseURL}/v1/commands`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${clientToken}`,
      "Content-Type": "application/json",
    },
    body: "{",
  });
  assert.equal(malformedJSON.status, 400);
  assert.equal((await malformedJSON.json()).error, "request body must be valid JSON");
  const oversizedJSON = await fetch(`${baseURL}/v1/commands`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${clientToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ padding: "x".repeat((1024 * 1024) + 1) }),
  });
  assert.equal(oversizedJSON.status, 413);
  const invalidOption = await request("/v1/commands", {
    method: "POST",
    body: { kind: "fullSync", options: { updateNoticeNotes: "false" } },
  });
  assert.equal(invalidOption.status, 400);
  const unknownOption = await request("/v1/commands", {
    method: "POST",
    body: { kind: "fullSync", options: { unexpected: true } },
  });
  assert.equal(unknownOption.status, 400);
  assert.equal((await jsonRequest("/v1/status")).revision, 0, "invalid input must not allocate a revision");

  const attackerID = crypto.randomUUID();
  const command = await jsonRequest("/v1/commands", {
    method: "POST",
    expectedStatus: 201,
    body: {
      id: attackerID,
      kind: "fullSync",
      status: "completed",
      createdAt: "2000-01-01T00:00:00Z",
      updatedAt: "2000-01-01T00:00:00Z",
    },
  });
  assert.notEqual(command.id, attackerID);
  assert.equal(command.status, "pending");
  assert.ok(Date.parse(command.createdAt) > Date.parse("2020-01-01T00:00:00Z"));

  const duplicate = await request("/v1/commands", { method: "POST", body: { kind: "verify" } });
  assert.equal(duplicate.status, 409);

  assert.equal((await rawWebSocketUpgrade("/v1/events?role=invalid", clientToken)).status, 400);
  assert.equal((await rawWebSocketUpgrade("/v1/events", clientToken)).status, 400);
  assert.equal((await rawWebSocketUpgrade("/v1/events?role=client", "wrong-token")).status, 401);

  const socket = await rawWebSocketUpgrade("/v1/events?role=client", clientToken);
  assert.equal(socket.status, 101);
  const hello = await socket.next();
  assert.equal(hello.type, "hello");
  assert.equal(hello.version, 1);
  assert.equal(hello.revision, 1);

  const running = await jsonRequest(`/v1/commands/${command.id}`, {
    method: "PUT",
    role: "worker",
    body: { ...command, status: "running", kind: command.kind, createdAt: command.createdAt },
  });
  assert.equal(running.status, "running");
  const changed = await socket.next();
  assert.equal(changed.type, "changed");
  assert.equal(changed.reason, "commands:running");
  assert.equal(changed.revision, hello.revision + 1);
  assert.deepEqual(changed.scopes, ["status", "commands", "requestLog"]);
  assert.equal(changed.requiresSnapshot, false);

  socket.send({ type: "ping" });
  const pong = await socket.next();
  assert.equal(pong.type, "pong");
  assert.equal(pong.revision, changed.revision);
  socket.close();

  await jsonRequest(`/v1/commands/${command.id}`, {
    method: "PUT",
    role: "worker",
    body: { ...running, status: "completed" },
  });

  {
    const realtime = await rawWebSocketUpgrade("/v1/events?role=worker", workerToken);
    const syncHello = await realtime.next();
    const syncResponse = await jsonRequest("/v1/sync-data", {
      method: "POST",
      role: "worker",
      body: {
        generatedAt: new Date().toISOString(),
        items: [],
        runLogs: [{
          id: "88888888-8888-4888-8888-888888888888",
          command: "fullSync",
          commandTitle: "attacker supplied title",
          status: "attacker supplied status",
          startedAt: "2026-07-14T00:00:00.000Z",
          finishedAt: "2026-07-14T00:00:01.000Z",
          updatedAt: "2026-07-14T00:00:01.000Z",
          duration: "{\"worker_token\":\"synthetic-duration-secret\",\"safe\":\"1초\"}",
          exitCode: 7,
          wasCancelled: false,
          needsAttention: false,
          outputTail: `${publicLogRedactionCases.map((item) => item.input).join("\n")}\nsafe failure summary`,
        }],
      },
    });
    const syncChanged = await realtime.next();
    assert.equal(syncChanged.reason, "sync-data");
    assert.equal(syncChanged.requiresSnapshot, true);
    assert.equal(syncChanged.revision, syncHello.revision + 1);
    assert.equal(syncResponse.revision, syncChanged.revision, "snapshot revision must match its committed event");
    assert.equal(syncResponse.runLogs[0].commandTitle, "전체 동기화");
    assert.equal(syncResponse.runLogs[0].status, "실패 7");
    assert.equal(syncResponse.runLogs[0].needsAttention, true);
    assert.doesNotMatch(syncResponse.runLogs[0].duration, /synthetic-duration-secret/);
    assert.match(syncResponse.runLogs[0].duration, /\[credential\]/);
    assert.match(syncResponse.runLogs[0].outputTail, /\[credential\]/);
    assert.match(syncResponse.runLogs[0].outputTail, /\[local-path\]/);
    assert.match(syncResponse.runLogs[0].outputTail, /\[URL\]/);
    assert.doesNotMatch(syncResponse.runLogs[0].outputTail, /synthetic-json-secret|another-secret|query-secret/);
    assert.doesNotMatch(syncResponse.runLogs[0].outputTail, /\/private\/tmp|\/Volumes|\/home|C:\\Users/i);
    assert.match(syncResponse.runLogs[0].outputTail, /safe failure summary/);
    realtime.close();
  }

  {
    const idempotentID = "77777777-7777-4777-8777-777777777777";
    const body = {
      id: idempotentID,
      action: "calendarVerify",
      itemID: "calendar-idempotency-target",
      itemKind: "calendar",
      itemTitle: "Idempotency target",
    };
    const created = await jsonRequest("/v1/item-actions", {
      method: "POST",
      expectedStatus: 201,
      body,
    });
    assert.equal(created.id, idempotentID);
    assert.deepEqual(await jsonRequest(`/v1/item-actions/${created.id}`), created);
    const revisionAfterCreate = (await jsonRequest("/v1/status")).revision;
    const replayed = await jsonRequest("/v1/item-actions", { method: "POST", body });
    assert.equal(replayed.id, created.id);
    assert.equal((await jsonRequest("/v1/status")).revision, revisionAfterCreate);
    const conflict = await request("/v1/item-actions", {
      method: "POST",
      body: { ...body, action: "calendarOpen" },
    });
    assert.equal(conflict.status, 409);
    assert.equal((await jsonRequest("/v1/status")).revision, revisionAfterCreate);
  }

  {
    const responses = await Promise.all(Array.from({ length: 12 }, (_, index) => (
      request("/v1/commands", { method: "POST", body: { kind: index % 2 ? "verify" : "doctor" } })
    )));
    assert.equal(responses.filter((response) => response.status === 201).length, 1);
    assert.equal(responses.filter((response) => response.status === 409).length, 11);
    const winner = await responses.find((response) => response.status === 201).json();
    await jsonRequest(`/v1/commands/${winner.id}`, {
      method: "PUT",
      role: "worker",
      body: { ...winner, status: "completed" },
    });
  }

  const fileRequest = await jsonRequest("/v1/file-access", {
    method: "POST",
    expectedStatus: 201,
    body: { itemID: "file-1", itemKind: "file", itemTitle: "test.txt" },
  });
  const emptyUploadRequest = await jsonRequest("/v1/file-access", {
    method: "POST",
    expectedStatus: 201,
    body: { itemID: "file-empty", itemKind: "file", itemTitle: "empty.txt" },
  });
  const revisionBeforeEmptyUpload = (await jsonRequest("/v1/status")).revision;
  const emptyUpload = await request(`/v1/file-access/${emptyUploadRequest.id}/upload`, {
    method: "PUT",
    role: "worker",
    rawBody: "",
    headers: { "Content-Type": "text/plain", "Content-Length": "0" },
  });
  assert.equal(emptyUpload.status, 411);
  const emptyAfterReject = (await jsonRequest("/v1/file-access/recent")).requests
    .find((item) => item.id === emptyUploadRequest.id);
  assert.equal(emptyAfterReject.updatedAt, emptyUploadRequest.updatedAt, "internal claim must not change visible timestamps");
  assert.equal((await jsonRequest("/v1/status")).revision, revisionBeforeEmptyUpload);
  await jsonRequest(`/v1/file-access/${emptyUploadRequest.id}`, {
    method: "PUT",
    role: "worker",
    body: {
      id: emptyUploadRequest.id,
      itemID: emptyUploadRequest.itemID,
      itemKind: emptyUploadRequest.itemKind,
      status: "failed",
      message: "empty upload rejected",
    },
  });
  const pathAttack = await request(`/v1/file-access/${fileRequest.id}`, {
    method: "PUT",
    role: "worker",
    body: { status: "completed", objectKey: "../sentinel.txt" },
  });
  assert.equal(pathAttack.status, 400);
  assert.equal(await fs.readFile(sentinelPath, "utf8"), "must survive");

  const uploadResponses = await Promise.all(Array.from({ length: 12 }, (_, index) => {
    const body = `body-${String(index).padStart(2, "0")}`;
    return (
    request(`/v1/file-access/${fileRequest.id}/upload`, {
      method: "PUT",
      role: "worker",
      rawBody: body,
      headers: {
        "Content-Type": "text/plain",
        "Content-Length": String(Buffer.byteLength(body)),
        "X-KLMS-Filename": encodeURIComponent("test.txt"),
      },
    })
    );
  }));
  assert.equal(uploadResponses.filter((response) => response.status === 200).length, 1);
  assert.equal(uploadResponses.filter((response) => response.status === 409).length, 11);
  const uploaded = await uploadResponses.find((response) => response.status === 200).json();
  const storedObjects = await fs.readdir(path.join(fileDir, "file-access", fileRequest.id));
  assert.equal(storedObjects.length, 1, "concurrent uploads must create exactly one object");
  const previewPageURL = new URL(uploaded.downloadURL);
  previewPageURL.searchParams.set("preview", "1");
  const previewPageResponse = await fetch(previewPageURL);
  assert.equal(previewPageResponse.status, 200);
  const previewPageCSP = previewPageResponse.headers.get("Content-Security-Policy") || "";
  assert.doesNotMatch(previewPageCSP, /script-src[^;]*'unsafe-inline'/);
  assert.match(previewPageCSP, /frame-ancestors 'none'/);
  assert.equal(previewPageResponse.headers.get("X-Content-Type-Options"), "nosniff");
  assert.equal(previewPageResponse.headers.get("X-Frame-Options"), "DENY");
  assert.equal(previewPageResponse.headers.get("Cross-Origin-Resource-Policy"), "same-origin");
  const previewPageHTML = await previewPageResponse.text();
  const scriptNonce = /<script nonce="([^"]+)"/.exec(previewPageHTML)?.[1] || "";
  assert.ok(scriptNonce);
  assert.ok(previewPageCSP.includes(`script-src 'nonce-${scriptNonce}'`));

  const pdfPreview = await createUploadedFile(
    "file-pdf-preview",
    "lecture.pdf",
    "%PDF-1.4\n",
    "application/pdf"
  );
  const pdfPreviewURL = new URL(pdfPreview.downloadURL);
  pdfPreviewURL.searchParams.set("preview", "1");
  const pdfPreviewResponse = await fetch(pdfPreviewURL);
  assert.equal(pdfPreviewResponse.status, 200);
  const pdfPreviewHTML = await pdfPreviewResponse.text();
  assert.match(pdfPreviewHTML, /브라우저의 내장 PDF 도구/);
  assert.match(pdfPreviewHTML, /data-pdf-preview/);
  assert.doesNotMatch(pdfPreviewHTML, /pdfjs-dist|pdfjsLib|getDocument/);

  const hostileTitle = '<img src=x onerror="globalThis.__klmsXSS=true">.txt';
  const hostilePreview = await createUploadedFile(
    "file-hostile-title",
    hostileTitle,
    "escaped",
    "text/plain"
  );
  const hostilePageResponse = await fetch(hostilePreview.downloadURL);
  assert.equal(hostilePageResponse.status, 200);
  const hostilePageHTML = await hostilePageResponse.text();
  assert.match(hostilePageHTML, /&lt;img src=x onerror=&quot;globalThis\.__klmsXSS=true&quot;&gt;\.txt/);
  assert.doesNotMatch(hostilePageHTML, /<img src=x onerror=/);

  {
    const orphanRequestID = crypto.randomUUID();
    const orphanPath = path.join(
      fileDir,
      "file-access",
      orphanRequestID,
      `${crypto.randomUUID()}-orphan.txt`
    );
    await fs.mkdir(path.dirname(orphanPath), { recursive: true });
    await fs.writeFile(orphanPath, "orphan", "utf8");
    await request("/v1/status");
    await waitForPathRemoval(orphanPath);
  }

  const terminalRaceRequest = await jsonRequest("/v1/file-access", {
    method: "POST",
    expectedStatus: 201,
    body: { itemID: "file-terminal-race", itemKind: "file", itemTitle: "terminal-race.txt" },
  });
  const terminalRaceUpload = startStalledUpload(terminalRaceRequest.id, 2 * 1024 * 1024);
  await waitForUploadClaim(terminalRaceRequest.id);
  {
    const reservationDB = new DatabaseSync(dbPath, { readOnly: true });
    try {
      const reservation = reservationDB.prepare(`
        SELECT pending_object_key, reserved_upload_bytes, reserved_upload_quota_key
        FROM file_access_requests
        WHERE id = ?
      `).get(terminalRaceRequest.id);
      assert.match(reservation.pending_object_key, new RegExp(`^file-access/${terminalRaceRequest.id}/`));
      assert.equal(reservation.reserved_upload_bytes, 2 * 1024 * 1024);
      assert.match(reservation.reserved_upload_quota_key, /^fileAccessQuota:\d{4}-\d{2}-\d{2}$/);
    } finally {
      reservationDB.close();
    }
  }
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
  assert.equal(terminalRaceResponse.status, 409, terminalRaceResponse.body);
  const terminalRaceStored = (await jsonRequest("/v1/file-access/recent?limit=100")).requests
    .find((item) => item.id === terminalRaceRequest.id);
  assert.equal(terminalRaceStored?.status, "failed");
  assert.equal(terminalRaceStored?.downloadURL, null);
  {
    const releasedDB = new DatabaseSync(dbPath, { readOnly: true });
    try {
      const released = releasedDB.prepare(`
        SELECT pending_object_key, reserved_upload_bytes, reserved_upload_quota_key
        FROM file_access_requests
        WHERE id = ?
      `).get(terminalRaceRequest.id);
      assert.equal(released.pending_object_key, null);
      assert.equal(released.reserved_upload_bytes, 0);
      assert.equal(released.reserved_upload_quota_key, null);
    } finally {
      releasedDB.close();
    }
  }

  const downloadURL = new URL(uploaded.downloadURL);
  downloadURL.searchParams.set("download", "1");
  const readsBeforeRace = relayTestFileObjectReadCount();
  const downloads = await Promise.all(Array.from({ length: 12 }, () => fetch(downloadURL)));
  assert.equal(downloads.filter((response) => response.status === 200).length, 1);
  assert.equal(downloads.filter((response) => response.status === 429).length, 11);
  assert.equal(
    relayTestFileObjectReadCount() - readsBeforeRace,
    1,
    "only an atomically reserved request may read the local file object"
  );

  const failedReadFile = await createUploadedFile("file-read-failure", "read-failure.txt", "recoverable-body");
  {
    const failureDB = new DatabaseSync(dbPath);
    let objectPath;
    let quotaKey;
    let quotaBefore;
    try {
      const row = failureDB.prepare(`
        SELECT object_key FROM file_access_requests WHERE id = ?
      `).get(failedReadFile.id);
      objectPath = path.join(fileDir, ...row.object_key.split("/"));
      quotaKey = `fileAccessQuota:${new Date().toISOString().slice(0, 10)}`;
      quotaBefore = JSON.parse(failureDB.prepare("SELECT value FROM meta WHERE key = ?").get(quotaKey)?.value || "{}");
      await fs.unlink(objectPath);
    } finally {
      failureDB.close();
    }
    const failedReadURL = new URL(failedReadFile.downloadURL);
    failedReadURL.searchParams.set("download", "1");
    assert.equal((await fetch(failedReadURL)).status, 404);
    const releasedDB = new DatabaseSync(dbPath, { readOnly: true });
    try {
      const row = releasedDB.prepare(`
        SELECT download_count FROM file_access_requests WHERE id = ?
      `).get(failedReadFile.id);
      const quotaAfter = JSON.parse(releasedDB.prepare("SELECT value FROM meta WHERE key = ?").get(quotaKey)?.value || "{}");
      assert.equal(row.download_count, 0, "failed storage reads must release the per-link reservation");
      assert.equal(quotaAfter.downloadCount, quotaBefore.downloadCount, "failed storage reads must release daily quota");
      assert.equal(
        releasedDB.prepare("SELECT COUNT(*) AS count FROM file_download_reservations WHERE request_id = ?").get(failedReadFile.id).count,
        0,
        "failed storage reads must consume their reservation token"
      );
    } finally {
      releasedDB.close();
    }
    await fs.mkdir(path.dirname(objectPath), { recursive: true });
    await fs.writeFile(objectPath, "recoverable-body", "utf8");
    assert.equal((await fetch(failedReadURL)).status, 200, "released quota must permit a later successful retry");
  }

  const staleReservationFile = await createUploadedFile("file-stale-download", "stale-download.txt", "stale-body");
  {
    const staleDB = new DatabaseSync(dbPath);
    const quotaKey = `fileAccessQuota:${new Date().toISOString().slice(0, 10)}`;
    const token = crypto.randomUUID();
    const logID = crypto.randomUUID();
    let baselineQuota;
    try {
      baselineQuota = JSON.parse(staleDB.prepare("SELECT value FROM meta WHERE key = ?").get(quotaKey)?.value || "{}");
      staleDB.prepare("UPDATE file_access_requests SET download_count = download_count + 1 WHERE id = ?")
        .run(staleReservationFile.id);
      staleDB.prepare(`
        INSERT INTO file_download_reservations(
          token, request_id, quota_key, log_id, log_created_at, created_at
        ) VALUES (?, ?, ?, ?, ?, ?)
      `).run(
        token,
        staleReservationFile.id,
        quotaKey,
        logID,
        new Date(Date.now() - 11 * 60 * 1000).toISOString(),
        new Date(Date.now() - 11 * 60 * 1000).toISOString()
      );
      staleDB.prepare("UPDATE meta SET value = ? WHERE key = ?").run(JSON.stringify({
        ...baselineQuota,
        downloadCount: Number(baselineQuota.downloadCount || 0) + 1,
      }), quotaKey);
    } finally {
      staleDB.close();
    }
    assert.equal((await request("/v1/status")).status, 200);
    assert.equal((await request("/v1/status")).status, 200, "stale recovery must be idempotent");
    const recoveredDB = new DatabaseSync(dbPath, { readOnly: true });
    try {
      assert.equal(
        recoveredDB.prepare("SELECT download_count FROM file_access_requests WHERE id = ?").get(staleReservationFile.id).download_count,
        0
      );
      assert.equal(
        JSON.parse(recoveredDB.prepare("SELECT value FROM meta WHERE key = ?").get(quotaKey)?.value || "{}").downloadCount,
        baselineQuota.downloadCount
      );
      assert.equal(recoveredDB.prepare("SELECT COUNT(*) AS count FROM file_download_reservations").get().count, 0);
    } finally {
      recoveredDB.close();
    }
  }

  const protectedDownloadFile = await createUploadedFile(
    "file-active-download-cleanup",
    "active-download.txt",
    "active-download-body"
  );
  {
    const quotaDB = new DatabaseSync(dbPath);
    try {
      const quotaKey = `fileAccessQuota:${new Date().toISOString().slice(0, 10)}`;
      const quota = JSON.parse(quotaDB.prepare("SELECT value FROM meta WHERE key = ?").get(quotaKey)?.value || "{}");
      quota.downloadCount = 0;
      quotaDB.prepare("UPDATE meta SET value = ? WHERE key = ?").run(JSON.stringify(quota), quotaKey);
    } finally {
      quotaDB.close();
    }
    const activeDownloadURL = new URL(protectedDownloadFile.downloadURL);
    activeDownloadURL.searchParams.set("download", "1");
    const activeDownload = fetch(activeDownloadURL);
    await waitForDownloadReservation(protectedDownloadFile.id);
    const clearDuringDownload = await request("/v1/logs?scope=fileAccess", {
      method: "DELETE",
      role: "worker",
    });
    assert.equal(clearDuringDownload.status, 409, "active downloads must block file cleanup");
    assert.equal((await activeDownload).status, 200);
    const observer = new DatabaseSync(dbPath, { readOnly: true });
    try {
      assert.equal(
        observer.prepare("SELECT COUNT(*) AS count FROM file_download_reservations WHERE request_id = ?")
          .get(protectedDownloadFile.id).count,
        0,
        "successful delivery must finalize the cleanup guard"
      );
    } finally {
      observer.close();
    }
  }

  {
    const clearDB = new DatabaseSync(dbPath);
    try {
      const row = clearDB.prepare("SELECT id, object_key FROM file_access_requests WHERE id = ?").get(fileRequest.id);
      assert.ok(row?.object_key);
      const objectPath = path.join(fileDir, ...row.object_key.split("/"));
      await fs.unlink(objectPath);
      await fs.mkdir(objectPath);
      await jsonRequest("/v1/logs?scope=fileAccess", { method: "DELETE", role: "worker" });
      assert.ok(
        clearDB.prepare("SELECT id FROM file_access_requests WHERE id = ?").get(fileRequest.id),
        "failed object deletion must preserve the database row"
      );
      await fs.rmdir(objectPath);
      await jsonRequest("/v1/logs?scope=fileAccess", { method: "DELETE", role: "worker" });
      assert.equal(clearDB.prepare("SELECT id FROM file_access_requests WHERE id = ?").get(fileRequest.id), undefined);
    } finally {
      clearDB.close();
    }
  }

  const slowClearFile = await createUploadedFile("file-slow-clear", "slow-clear.txt", "slow-clear-body");
  {
    const beforeTypoRevision = (await jsonRequest("/v1/status")).revision;
    const typoClear = await request("/v1/logs?scope=fileAcess", { method: "DELETE", role: "worker" });
    assert.equal(typoClear.status, 400);
    assert.equal((await jsonRequest("/v1/status")).revision, beforeTypoRevision);
    const quotaDB = new DatabaseSync(dbPath);
    try {
      const quotaKey = `fileAccessQuota:${new Date().toISOString().slice(0, 10)}`;
      const quotaRow = quotaDB.prepare("SELECT value FROM meta WHERE key = ?").get(quotaKey);
      const quota = JSON.parse(quotaRow?.value || "{}");
      quota.downloadCount = 0;
      quotaDB.prepare("UPDATE meta SET value = ? WHERE key = ?").run(JSON.stringify(quota), quotaKey);
    } finally {
      quotaDB.close();
    }
    const clearPromise = request("/v1/logs?scope=fileAccess", { method: "DELETE", role: "worker" });
    await waitForUploadClaim(slowClearFile.id);
    const statusStartedAt = Date.now();
    assert.equal((await request("/v1/status")).status, 200);
    const statusElapsedMs = Date.now() - statusStartedAt;
    assert.ok(statusElapsedMs < 200, `status was blocked by slow file deletion for ${statusElapsedMs}ms`);
    const patchDuringClear = await request(`/v1/file-access/${slowClearFile.id}`, {
      method: "PUT",
      role: "worker",
      body: {
        id: slowClearFile.id,
        itemID: slowClearFile.itemID,
        itemKind: slowClearFile.itemKind,
        status: "running",
        message: "must not reactivate while the object is being deleted",
      },
    });
    assert.equal(patchDuringClear.status, 409);
    const downloadDuringClearURL = new URL(slowClearFile.downloadURL);
    downloadDuringClearURL.searchParams.set("download", "1");
    const downloadDuringClear = await fetch(downloadDuringClearURL);
    assert.equal(downloadDuringClear.status, 409);
    const clearResponse = await clearPromise;
    assert.equal(clearResponse.status, 200, await clearResponse.text());
  }

  const slowExpiryFile = await createUploadedFile("file-slow-expiry", "slow-expiry.txt", "slow-expiry-body");
  {
    const expiryDB = new DatabaseSync(dbPath);
    try {
      expiryDB.prepare("UPDATE file_access_requests SET expires_at = ? WHERE id = ?")
        .run(new Date(Date.now() - 1_000).toISOString(), slowExpiryFile.id);
    } finally {
      expiryDB.close();
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
    const firstStatusStartedAt = Date.now();
    assert.equal((await request("/v1/status")).status, 200);
    assert.ok(Date.now() - firstStatusStartedAt < 200, "starting expiry cleanup must not block status");
    await waitForUploadClaim(slowExpiryFile.id);
    const secondStatusStartedAt = Date.now();
    assert.equal((await request("/v1/status")).status, 200);
    assert.ok(Date.now() - secondStatusStartedAt < 200, "running expiry cleanup must not block status");
    await waitForFileRequestRemoval(slowExpiryFile.id);
  }

  const live = new DatabaseSync(dbPath);
  try {
    live.prepare(`
      INSERT INTO commands(id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json, options_json)
      VALUES (?, 'invalidLegacyKind', 'completed', ?, ?, NULL, 0, '{}', '{}')
    `).run(crypto.randomUUID(), new Date().toISOString(), new Date().toISOString());
    const maliciousRowID = crypto.randomUUID();
    live.prepare(`
      INSERT INTO file_access_requests(
        id, item_id, item_kind, item_title, status, created_at, updated_at, message,
        object_key, download_ticket, expires_at, content_type, size_bytes, download_count
      ) VALUES (?, 'legacy-file', 'file', 'legacy', 'completed', ?, ?, '', '../sentinel.txt', 'ticket', ?, 'text/plain', 1, 0)
    `).run(
      maliciousRowID,
      new Date().toISOString(),
      new Date().toISOString(),
      new Date(Date.now() - 1_000).toISOString()
    );
    await jsonRequest("/v1/status");
    assert.equal(await fs.readFile(sentinelPath, "utf8"), "must survive");
    assert.ok(live.prepare("SELECT id FROM file_access_requests WHERE id = ?").get(maliciousRowID), "failed cleanup must preserve row for remediation/retry");
  } finally {
    live.close();
  }

  const paddingDB = new DatabaseSync(dbPath);
  try {
    paddingDB.exec(`
      CREATE TABLE IF NOT EXISTS backup_concurrency_padding (
        id INTEGER PRIMARY KEY,
        payload BLOB NOT NULL
      );
      DELETE FROM backup_concurrency_padding;
      WITH RECURSIVE counter(value) AS (
        SELECT 1
        UNION ALL
        SELECT value + 1 FROM counter WHERE value < 2048
      )
      INSERT INTO backup_concurrency_padding(id, payload)
      SELECT value, zeroblob(32768) FROM counter;
    `);
  } finally {
    paddingDB.close();
  }
  const revisionBeforeBackup = (await jsonRequest("/v1/status")).revision;
  const backup = spawn(process.execPath, [serverPath, "--backup", backupPath], {
    cwd: projectRoot,
    env: { ...process.env, KLMS_RELAY_DB: dbPath },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let concurrentBackupWrites = 0;
  let concurrentWriterError = null;
  const concurrentWriter = (async () => {
    try {
      while (
        concurrentBackupWrites < 25
        && backup.exitCode == null
        && backup.signalCode == null
      ) {
        concurrentBackupWrites += 1;
        await jsonRequest("/v1/status", {
          method: "POST",
          role: "worker",
          body: {
            status: { phase: "idle", assignments: concurrentBackupWrites },
            running: false,
            message: `backup writer ${concurrentBackupWrites}`,
          },
        });
      }
    } catch (error) {
      concurrentWriterError = error;
    }
  })();
  const backupResult = await collectChild(backup);
  await concurrentWriter;
  assert.equal(backupResult.code, 0, backupResult.stderr);
  if (concurrentWriterError) throw concurrentWriterError;
  assert.ok(concurrentBackupWrites > 0, "the relay must commit while the backup process is active");
  const revisionAfterBackup = (await jsonRequest("/v1/status")).revision;
  assert.ok(revisionAfterBackup > revisionBeforeBackup);
  const backupOutput = JSON.parse(backupResult.stdout.trim());
  const backupDB = new DatabaseSync(backupPath, { readOnly: true });
  try {
    assert.equal(backupDB.prepare("PRAGMA quick_check").get().quick_check, "ok");
    const backupRevision = Number(backupDB.prepare("SELECT value FROM meta WHERE key = 'relayRevision'").get().value);
    assert.equal(backupOutput.revision, String(backupRevision));
    assert.ok(backupRevision >= revisionBeforeBackup, "backup snapshot cannot predate the backup start");
    assert.ok(backupRevision <= revisionAfterBackup, "backup snapshot cannot contain a later source revision");
  } finally {
    backupDB.close();
  }
  const existingBackupStat = await fs.stat(backupPath);
  assert.equal(existingBackupStat.mode & 0o777, 0o600, "verified backups must be owner-readable only");
  const verifyBackup = spawn(process.execPath, [serverPath, "--verify-backup", backupPath], {
    cwd: projectRoot,
    env: { ...process.env, KLMS_RELAY_DB: dbPath },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const verifyBackupResult = await collectChild(verifyBackup);
  assert.equal(verifyBackupResult.code, 0, verifyBackupResult.stderr);
  assert.equal(JSON.parse(verifyBackupResult.stdout.trim()).ok, true);

  const oldManagedBackup = path.join(root, "klms-sync-relay.sqlite-20000101T000000Z.backup");
  const unrelatedBackup = path.join(root, "keep-me.backup");
  await fs.copyFile(backupPath, oldManagedBackup);
  await fs.writeFile(unrelatedBackup, "not managed by relay retention", "utf8");
  const oldTime = new Date("2000-01-01T00:00:00.000Z");
  await fs.utimes(oldManagedBackup, oldTime, oldTime);
  await fs.utimes(unrelatedBackup, oldTime, oldTime);
  const pruneBackups = spawn(process.execPath, [serverPath, "--prune-backups", root, "14"], {
    cwd: projectRoot,
    env: { ...process.env, KLMS_RELAY_DB: dbPath },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const pruneBackupsResult = await collectChild(pruneBackups);
  assert.equal(pruneBackupsResult.code, 0, pruneBackupsResult.stderr);
  assert.equal((await fs.stat(root)).mode & 0o777, 0o700);
  await assert.rejects(fs.stat(oldManagedBackup), { code: "ENOENT" });
  assert.equal(await fs.readFile(unrelatedBackup, "utf8"), "not managed by relay retention");
  const duplicateBackup = spawn(process.execPath, [serverPath, "--backup", backupPath], {
    cwd: projectRoot,
    env: { ...process.env, KLMS_RELAY_DB: dbPath },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const duplicateBackupResult = await collectChild(duplicateBackup);
  assert.notEqual(duplicateBackupResult.code, 0);
  assert.match(duplicateBackupResult.stderr, /backup destination already exists/);
  assert.equal((await fs.stat(backupPath)).size, existingBackupStat.size, "existing verified backup must not be replaced");

  const restartRequest = await jsonRequest("/v1/file-access", {
    method: "POST",
    expectedStatus: 201,
    body: { itemID: "file-restart", itemKind: "file", itemTitle: "restart.txt" },
  });
  const interruptedDeletionRequest = await createUploadedFile(
    "file-interrupted-deletion",
    "interrupted-deletion.txt",
    "removed-before-database-finalization"
  );
  child.kill("SIGKILL");
  await onceExit(child);
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
  const crashedDB = new DatabaseSync(dbPath);
  try {
    assert.equal(
      crashedDB.prepare("SELECT COUNT(*) AS count FROM commands WHERE status IN ('pending', 'running')").get().count,
      0,
      "restart fixture requires an empty active-command slot",
    );
    const sqliteTimeProbe = crashedDB.prepare(`
      SELECT
        julianday('12:34:56') IS NOT NULL AS time_only_is_parseable,
        julianday('now') IS NOT NULL AS now_is_parseable,
        julianday('2460000.5') IS NOT NULL AS julian_is_parseable
    `).get();
    assert.equal(sqliteTimeProbe.time_only_is_parseable, 1);
    assert.equal(sqliteTimeProbe.now_is_parseable, 1);
    assert.equal(sqliteTimeProbe.julian_is_parseable, 1);
    crashedDB.exec("DROP INDEX commands_one_active_idx");
    crashedDB.exec("DROP TABLE file_download_reservations");
    crashedDB.prepare(`
      INSERT INTO commands(id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json, options_json)
      VALUES (?, ?, ?, ?, ?, NULL, 0, '{}', '{}')
    `).run(malformedCommandIDs.uuid, "fullSync", "pending", validTimestamp, validTimestamp);
    crashedDB.prepare(`
      INSERT INTO commands(id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json, options_json)
      VALUES (?, ?, ?, ?, ?, NULL, 0, '{}', '{}')
    `).run(malformedCommandIDs.kind, "invalidLegacyKind", "running", validTimestamp, validTimestamp);
    crashedDB.prepare(`
      INSERT INTO commands(id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json, options_json)
      VALUES (?, ?, ?, ?, ?, NULL, 0, '{}', '{}')
    `).run(malformedCommandIDs.timestamp, "verify", "pending", "not-a-timestamp", validTimestamp);
    crashedDB.prepare(`
      INSERT INTO commands(id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json, options_json)
      VALUES (?, ?, ?, ?, ?, NULL, 0, '{}', '{}')
    `).run(malformedCommandIDs.timeOnlyCreated, "doctor", "running", "12:34:56", validTimestamp);
    crashedDB.prepare(`
      INSERT INTO commands(id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json, options_json)
      VALUES (?, ?, ?, ?, ?, NULL, 0, '{}', '{}')
    `).run(malformedCommandIDs.keywordUpdated, "report", "pending", validTimestamp, "now");
    crashedDB.prepare(`
      INSERT INTO commands(id, kind, status, created_at, updated_at, last_exit_code, login_required, summary_json, options_json)
      VALUES (?, ?, ?, ?, ?, NULL, 0, '{}', '{}')
    `).run(malformedCommandIDs.julianCreated, "coreSync", "running", "2460000.5", validTimestamp);
    crashedDB.prepare(`
      UPDATE file_access_requests
      SET upload_claim = 'claim-owned-by-dead-process'
      WHERE id = ? AND object_key IS NULL
    `).run(restartRequest.id);
    const interruptedDeletion = crashedDB.prepare(`
      SELECT object_key FROM file_access_requests WHERE id = ? AND object_key IS NOT NULL
    `).get(interruptedDeletionRequest.id);
    assert.ok(interruptedDeletion?.object_key);
    await fs.unlink(path.join(fileDir, ...interruptedDeletion.object_key.split("/")));
    crashedDB.prepare(`
      UPDATE file_access_requests
      SET upload_claim = 'deletion-owned-by-dead-process'
      WHERE id = ? AND object_key IS NOT NULL
    `).run(interruptedDeletionRequest.id);
  } finally {
    crashedDB.close();
  }
  let restartedStderr = "";
  restartedChild = spawn(process.execPath, [serverPath], {
    cwd: projectRoot,
    env: {
      ...process.env,
      KLMS_RELAY_HOST: "127.0.0.1",
      KLMS_RELAY_PORT: String(port),
      KLMS_RELAY_DB: dbPath,
      KLMS_RELAY_FILE_DIR: fileDir,
      KLMS_RELAY_CLIENT_TOKEN: clientToken,
      KLMS_RELAY_WORKER_TOKEN: workerToken,
      NODE_ENV: "test",
      KLMS_RELAY_TEST_FILE_DELETE_DELAY_MS: "300",
      KLMS_FILE_RELAY_DOWNLOADS_PER_LINK: "1",
      KLMS_FILE_RELAY_DAILY_DOWNLOADS: "2",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  restartedChild.stderr.setEncoding("utf8");
  restartedChild.stderr.on("data", (chunk) => { restartedStderr += chunk; });
  await waitForServerProcess(restartedChild, () => restartedStderr);
  const recoveredDB = new DatabaseSync(dbPath, { readOnly: true });
  try {
    const sanitizedRows = recoveredDB.prepare(`
      SELECT id, status, updated_at, julianday(updated_at) IS NOT NULL AS updated_at_is_valid
      FROM commands
      WHERE id IN (?, ?, ?, ?, ?, ?)
      ORDER BY id
    `).all(
      malformedCommandIDs.uuid,
      malformedCommandIDs.kind,
      malformedCommandIDs.timestamp,
      malformedCommandIDs.timeOnlyCreated,
      malformedCommandIDs.keywordUpdated,
      malformedCommandIDs.julianCreated,
    );
    assert.equal(sanitizedRows.length, 6);
    assert.equal(sanitizedRows.every((row) => row.status === "macUnavailable"), true);
    assert.equal(sanitizedRows.every((row) => row.updated_at_is_valid === 1), true);
    assert.ok(
      recoveredDB.prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'commands_one_active_idx'").get(),
      "startup must restore the one-active-command index after sanitizing malformed rows",
    );
    assert.ok(
      recoveredDB.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'file_download_reservations'").get(),
      "startup must add the download reservation table when restoring an older database",
    );
    assert.equal(
      recoveredDB.prepare("SELECT upload_claim FROM file_access_requests WHERE id = ?").get(restartRequest.id).upload_claim,
      null,
      "startup must recover an upload claim owned by a dead relay process"
    );
    assert.equal(
      recoveredDB.prepare("SELECT id FROM file_access_requests WHERE id = ?").get(interruptedDeletionRequest.id),
      undefined,
      "startup must remove an interrupted deletion row after its file was removed"
    );
  } finally {
    recoveredDB.close();
  }
  const pendingAfterCommandRecovery = await jsonRequest("/v1/commands/pending", { role: "worker" });
  assert.equal(
    Object.values(malformedCommandIDs).some((id) => pendingAfterCommandRecovery.commands.some((command) => command.id === id)),
    false,
    "malformed active command rows must remain absent from the loaded active API state",
  );
  const recentAfterCommandRecovery = await jsonRequest("/v1/commands/recent?limit=100");
  const updatedOnlyCommand = recentAfterCommandRecovery.commands
    .find((command) => command.id === malformedCommandIDs.keywordUpdated);
  assert.equal(updatedOnlyCommand?.status, "macUnavailable");
  const stillMalformedCommandIDs = Object.values(malformedCommandIDs)
    .filter((id) => id !== malformedCommandIDs.keywordUpdated);
  assert.equal(
    stillMalformedCommandIDs.some((id) => recentAfterCommandRecovery.commands.some((command) => command.id === id)),
    false,
    "rows whose forensic identity or creation timestamp remains malformed must be absent from recent commands",
  );
  const commandAfterRecovery = await jsonRequest("/v1/commands", {
    method: "POST",
    expectedStatus: 201,
    body: { kind: "verify" },
  });
  await jsonRequest(`/v1/commands/${commandAfterRecovery.id}`, {
    method: "PUT",
    role: "worker",
    body: { ...commandAfterRecovery, status: "completed" },
  });
  const recoveredUpload = await request(`/v1/file-access/${restartRequest.id}/upload`, {
    method: "PUT",
    role: "worker",
    rawBody: "restart-body",
    headers: {
      "Content-Type": "text/plain",
      "Content-Length": String(Buffer.byteLength("restart-body")),
      "X-KLMS-Filename": encodeURIComponent("restart.txt"),
    },
  });
  assert.equal(
    recoveredUpload.status,
    200,
    `${await recoveredUpload.text()}\n${restartedStderr}`
  );

  {
    const publicPort = await availablePort();
    const publicBaseURL = `http://127.0.0.1:${publicPort}`;
    const publicDBPath = path.join(root, "public-url-relay.sqlite");
    publicURLChild = spawn(process.execPath, [serverPath], {
      cwd: projectRoot,
      env: {
        ...process.env,
        KLMS_RELAY_HOST: "127.0.0.1",
        KLMS_RELAY_PORT: String(publicPort),
        KLMS_RELAY_DB: publicDBPath,
        KLMS_RELAY_FILE_DIR: path.join(root, "public-url-files"),
        KLMS_RELAY_PUBLIC_URL: "https://relay.example.test/relay/",
        KLMS_RELAY_CLIENT_TOKEN: clientToken,
        KLMS_RELAY_WORKER_TOKEN: workerToken,
        NODE_ENV: "test",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let publicStderr = "";
    publicURLChild.stderr.setEncoding("utf8");
    publicURLChild.stderr.on("data", (chunk) => { publicStderr += chunk; });
    await waitForHTTPServer(publicURLChild, publicBaseURL, () => publicStderr);
    const createResponse = await fetch(`${publicBaseURL}/v1/file-access`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${clientToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ itemID: "public-url-file", itemKind: "file", itemTitle: "public.txt" }),
    });
    assert.equal(createResponse.status, 201);
    const publicRequest = await createResponse.json();
    const publicBody = "public-url-body";
    const publicUpload = await fetch(`${publicBaseURL}/v1/file-access/${publicRequest.id}/upload`, {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${workerToken}`,
        "Content-Type": "text/plain",
        "Content-Length": String(Buffer.byteLength(publicBody)),
        "X-KLMS-Filename": encodeURIComponent("public.txt"),
      },
      body: publicBody,
    });
    assert.equal(publicUpload.status, 200, await publicUpload.clone().text());
    const publicResult = await publicUpload.json();
    assert.match(
      publicResult.downloadURL,
      new RegExp(`^https://relay\\.example\\.test/relay/v1/file-access/${publicRequest.id}/download\\?ticket=`)
    );
    publicURLChild.kill("SIGTERM");
    await onceExit(publicURLChild);
    publicURLChild = null;
  }

  {
    const invalidPublicPort = await availablePort();
    const invalidPublicChild = spawn(process.execPath, [serverPath], {
      cwd: projectRoot,
      env: {
        ...process.env,
        KLMS_RELAY_HOST: "0.0.0.0",
        KLMS_RELAY_PORT: String(invalidPublicPort),
        KLMS_RELAY_DB: path.join(root, "invalid-public-url.sqlite"),
        KLMS_RELAY_CLIENT_TOKEN: clientToken,
        KLMS_RELAY_WORKER_TOKEN: workerToken,
        NODE_ENV: "test",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const invalidPublicResult = await collectChild(invalidPublicChild);
    assert.notEqual(invalidPublicResult.code, 0);
    assert.match(invalidPublicResult.stderr, /KLMS_RELAY_PUBLIC_URL is required/);
  }

  {
    const shortTokenPort = await availablePort();
    const shortTokenChild = spawn(process.execPath, [serverPath], {
      cwd: projectRoot,
      env: {
        ...process.env,
        KLMS_RELAY_HOST: "127.0.0.1",
        KLMS_RELAY_PORT: String(shortTokenPort),
        KLMS_RELAY_DB: path.join(root, "short-token.sqlite"),
        KLMS_RELAY_FILE_DIR: path.join(root, "short-token-files"),
        KLMS_RELAY_CLIENT_TOKEN: "short-client-token",
        KLMS_RELAY_WORKER_TOKEN: "short-worker-token",
        NODE_ENV: "test",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const shortTokenResult = await collectChild(shortTokenChild);
    assert.notEqual(shortTokenResult.code, 0);
    assert.match(shortTokenResult.stderr, /at least 32 bytes/);
  }

  {
    const rateLimitPort = await availablePort();
    const rateLimitBaseURL = `http://127.0.0.1:${rateLimitPort}`;
    const rateLimitDBPath = path.join(root, "rate-limit.sqlite");
    const rateLimitChild = spawn(process.execPath, [serverPath], {
      cwd: projectRoot,
      env: {
        ...process.env,
        KLMS_RELAY_HOST: "127.0.0.1",
        KLMS_RELAY_PORT: String(rateLimitPort),
        KLMS_RELAY_DB: rateLimitDBPath,
        KLMS_RELAY_FILE_DIR: path.join(root, "rate-limit-files"),
        KLMS_RELAY_CLIENT_TOKEN: clientToken,
        KLMS_RELAY_WORKER_TOKEN: workerToken,
        KLMS_RELAY_TRUSTED_PROXY_SECRET: proxySecret,
        KLMS_RELAY_REQUESTS_PER_MINUTE: "3",
        KLMS_RELAY_PUBLIC_DOWNLOAD_INGRESS_PER_MINUTE: "3",
        KLMS_RELAY_TEST_TRACK_PUBLIC_DOWNLOAD_LOOKUPS: "1",
        NODE_ENV: "test",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let rateLimitStderr = "";
    rateLimitChild.stderr.setEncoding("utf8");
    rateLimitChild.stderr.on("data", (chunk) => { rateLimitStderr += chunk; });
    try {
      await waitForHTTPServer(rateLimitChild, rateLimitBaseURL, () => rateLimitStderr);
      const headers = { Authorization: `Bearer ${clientToken}` };
      const invalidHeaders = { Authorization: "Bearer invalid-token-with-enough-entropy" };
      assert.equal((await fetch(`${rateLimitBaseURL}/v1/status`, { headers: invalidHeaders })).status, 401);
      assert.equal((await fetch(`${rateLimitBaseURL}/v1/status`, { headers: invalidHeaders })).status, 401);
      assert.equal((await fetch(`${rateLimitBaseURL}/v1/status`, { headers: invalidHeaders })).status, 401);
      assert.equal((await fetch(`${rateLimitBaseURL}/v1/status`, { headers: invalidHeaders })).status, 429);

      for (let index = 0; index < 511; index += 1) {
        const response = await fetch(`${rateLimitBaseURL}/v1/status`, {
          headers: {
            ...invalidHeaders,
            "X-KLMS-Relay-Client-IP": `2001:db8::${(index + 1).toString(16)}`,
            "X-KLMS-Relay-Proxy-Secret": proxySecret,
          },
        });
        assert.equal(response.status, 401);
      }
      assert.equal(
        (await fetch(`${rateLimitBaseURL}/v1/status`, {
          headers: {
            ...invalidHeaders,
            "X-KLMS-Relay-Client-IP": "2001:db8::ffff",
            "X-KLMS-Relay-Proxy-Secret": proxySecret,
          },
        })).status,
        429,
        "unauthenticated identity cardinality must remain bounded",
      );
      assert.equal(
        (await fetch(`${rateLimitBaseURL}/readyz`, {
          headers: { Authorization: `Bearer ${workerToken}` },
        })).status,
        200,
        "unauthenticated map exhaustion must not consume reserved authenticated capacity",
      );

      const fileRequestResponse = await fetch(`${rateLimitBaseURL}/v1/file-access`, {
        method: "POST",
        headers: { ...headers, "Content-Type": "application/json" },
        body: JSON.stringify({
          itemID: "rate-limit-file",
          itemKind: "file",
          itemTitle: "rate-limit.txt",
        }),
      });
      assert.equal(fileRequestResponse.status, 201);
      const fileRequest = await fileRequestResponse.json();
      const uploadResponse = await fetch(`${rateLimitBaseURL}/v1/file-access/${fileRequest.id}/upload`, {
        method: "PUT",
        headers: {
          Authorization: `Bearer ${workerToken}`,
          "Content-Type": "text/plain",
          "Content-Length": "10",
          "X-KLMS-Filename": "rate-limit.txt",
        },
        body: "rate-limit",
      });
      assert.equal(uploadResponse.status, 200);
      const uploaded = await uploadResponse.json();
      const fakeTicketURL = new URL(uploaded.downloadURL);
      fakeTicketURL.searchParams.set("ticket", "a".repeat(64));
      assert.equal((await fetch(fakeTicketURL)).status, 403);
      assert.equal((await fetch(fakeTicketURL)).status, 403);
      assert.equal((await fetch(fakeTicketURL)).status, 403);
      const lookupDB = new DatabaseSync(rateLimitDBPath, { readOnly: true });
      const lookupCount = () => Number(
        lookupDB.prepare("SELECT value FROM meta WHERE key = 'testPublicDownloadLookupCount'").get()?.value || 0,
      );
      assert.equal(lookupCount(), 3);
      for (let attempt = 0; attempt < 25; attempt += 1) {
        assert.equal((await fetch(fakeTicketURL)).status, 429);
      }
      assert.equal(lookupCount(), 3, "rate-limited fake tickets must not perform SQLite lookups");
      assert.equal(
        (await fetch(uploaded.downloadURL)).status,
        429,
        "the source ingress budget must protect valid links from an active fake-ticket flood",
      );
      lookupDB.close();

      assert.equal((await fetch(`${rateLimitBaseURL}/v1/status`, { headers })).status, 200);
      assert.equal((await fetch(`${rateLimitBaseURL}/v1/status`, { headers })).status, 200);
      const limited = await fetch(`${rateLimitBaseURL}/v1/status`, { headers });
      assert.equal(limited.status, 429);
      assert.equal(limited.headers.get("Retry-After"), "60");
    } finally {
      if (rateLimitChild.exitCode == null) {
        rateLimitChild.kill("SIGTERM");
        await onceExit(rateLimitChild);
      }
    }
  }

  {
    const protectedPending = await jsonRequest("/v1/item-actions", {
      method: "POST",
      expectedStatus: 201,
      body: {
        action: "calendarVerify",
        itemID: "trim-protected-pending",
        itemKind: "calendar",
        itemTitle: "trim protected pending",
      },
    });
    assert.equal(protectedPending.status, "pending");
    for (let index = 0; index < MAX_ITEM_ACTION_TEST_HISTORY; index += 1) {
      await jsonRequest("/v1/item-actions", {
        method: "POST",
        expectedStatus: 201,
        body: {
          action: "noticeRead",
          itemID: `trim-terminal-${index}`,
          itemKind: "notice",
          itemTitle: `trim terminal ${index}`,
        },
      });
    }
    assert.equal((await jsonRequest(`/v1/item-actions/${protectedPending.id}`)).status, "pending");
    const pendingAfterTrim = await jsonRequest("/v1/item-actions/pending", { role: "worker" });
    assert.equal(pendingAfterTrim.actions.some((item) => item.id === protectedPending.id), true);
    const itemActionDB = new DatabaseSync(dbPath, { readOnly: true });
    assert.equal(itemActionDB.prepare("SELECT COUNT(*) AS count FROM item_actions").get().count, 200);
    itemActionDB.close();

    const activeToCreate = 200 - pendingAfterTrim.actions.length;
    for (let index = 0; index < activeToCreate; index += 1) {
      const response = await request("/v1/item-actions", {
        method: "POST",
        body: {
          action: "calendarVerify",
          itemID: `active-cap-${index}`,
          itemKind: "calendar",
          itemTitle: `active cap ${index}`,
        },
      });
      assert.equal(response.status, 201);
    }
    const rejected = await request("/v1/item-actions", {
      method: "POST",
      body: {
        action: "calendarVerify",
        itemID: "active-cap-overflow",
        itemKind: "calendar",
        itemTitle: "active cap overflow",
      },
    });
    assert.equal(rejected.status, 409);
    assert.equal((await jsonRequest(`/v1/item-actions/${protectedPending.id}`)).status, "pending");
  }

  {
    const readinessDB = new DatabaseSync(dbPath);
    try {
      readinessDB.exec("DROP TABLE item_actions");
    } finally {
      readinessDB.close();
    }
    const unavailable = await request("/readyz", { role: "worker" });
    assert.equal(unavailable.status, 503);
    assert.equal((await unavailable.json()).ok, false);
  }

  console.log("node relay integration ok");
} finally {
  if (publicURLChild && publicURLChild.exitCode == null) {
    publicURLChild.kill("SIGKILL");
    await onceExit(publicURLChild);
  }
  if (restartedChild && restartedChild.exitCode == null) {
    restartedChild.kill("SIGTERM");
    await Promise.race([onceExit(restartedChild), new Promise((resolve) => setTimeout(resolve, 1_000))]);
    if (restartedChild.exitCode == null) restartedChild.kill("SIGKILL");
  }
  child.kill("SIGTERM");
  await Promise.race([onceExit(child), new Promise((resolve) => setTimeout(resolve, 1_000))]);
  if (child.exitCode == null) child.kill("SIGKILL");
  await fs.rm(root, { recursive: true, force: true });
}

function assertBoundedRateWindowContract(consume) {
  const windows = new Map();
  const now = 1_000;
  for (const key of ["A", "B", "C"]) {
    assert.equal(consume(windows, key, 1, 3, now, 60_000), true);
  }
  assert.equal(windows.size, 3);
  assert.equal(consume(windows, "D", 1, 3, now, 60_000), false);
  assert.deepEqual([...windows.keys()], ["A", "B", "C"]);
  assert.equal(windows.size, 3);
  assert.equal(consume(windows, "D", 1, 3, now + 60_001, 60_000), true);
  assert.deepEqual([...windows.keys()], ["D"]);
  assert.ok(windows.size <= 3);
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

async function createUploadedFile(itemID, itemTitle, rawBody, contentType = "text/plain") {
  const fileRequest = await jsonRequest("/v1/file-access", {
    method: "POST",
    expectedStatus: 201,
    body: { itemID, itemKind: "file", itemTitle },
  });
  const upload = await request(`/v1/file-access/${fileRequest.id}/upload`, {
    method: "PUT",
    role: "worker",
    rawBody,
    headers: {
      "Content-Type": contentType,
      "Content-Length": String(Buffer.byteLength(rawBody)),
      "X-KLMS-Filename": encodeURIComponent(itemTitle),
    },
  });
  assert.equal(upload.status, 200, await upload.clone().text());
  return upload.json();
}

function startStalledUpload(id, totalBytes) {
  let requestHandle;
  const response = new Promise((resolve, reject) => {
    requestHandle = http.request(`${baseURL}/v1/file-access/${id}/upload`, {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${workerToken}`,
        "Content-Type": "text/plain",
        "Content-Length": String(totalBytes),
        "X-KLMS-Filename": encodeURIComponent("terminal-race.txt"),
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
    requestHandle.write(Buffer.from("x"));
  });
  return {
    response,
    finish() {
      requestHandle.end(Buffer.alloc(totalBytes - 1, 0x78));
    },
  };
}

async function waitForUploadClaim(id) {
  const observer = new DatabaseSync(dbPath, { readOnly: true });
  try {
    const deadline = Date.now() + 2_000;
    while (Date.now() < deadline) {
      const row = observer.prepare("SELECT upload_claim FROM file_access_requests WHERE id = ?").get(id);
      if (row?.upload_claim) return;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error("timed out waiting for upload claim");
  } finally {
    observer.close();
  }
}

async function waitForDownloadReservation(id) {
  const observer = new DatabaseSync(dbPath, { readOnly: true });
  try {
    const deadline = Date.now() + 2_000;
    while (Date.now() < deadline) {
      const row = observer.prepare("SELECT token FROM file_download_reservations WHERE request_id = ? LIMIT 1").get(id);
      if (row?.token) return;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error("timed out waiting for download reservation");
  } finally {
    observer.close();
  }
}

function relayTestFileObjectReadCount() {
  const observer = new DatabaseSync(dbPath, { readOnly: true });
  try {
    return Number.parseInt(
      observer.prepare("SELECT value FROM meta WHERE key = 'testFileObjectReadCount'").get()?.value || "0",
      10
    );
  } finally {
    observer.close();
  }
}

async function waitForFileRequestRemoval(id) {
  const observer = new DatabaseSync(dbPath, { readOnly: true });
  try {
    const deadline = Date.now() + 2_000;
    while (Date.now() < deadline) {
      if (!observer.prepare("SELECT id FROM file_access_requests WHERE id = ?").get(id)) return;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error("timed out waiting for expired file removal");
  } finally {
    observer.close();
  }
}

async function waitForPathRemoval(targetPath) {
  const deadline = Date.now() + 2_000;
  while (Date.now() < deadline) {
    try {
      await fs.stat(targetPath);
    } catch (error) {
      if (error?.code === "ENOENT") return;
      throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for orphan cleanup: ${targetPath}`);
}

async function jsonRequest(route, options = {}) {
  const response = await request(route, options);
  const text = await response.text();
  assert.equal(response.status, options.expectedStatus || 200, text);
  return JSON.parse(text);
}

async function waitForServer() {
  return waitForServerProcess(child, () => stderr);
}

async function waitForServerProcess(process, readStderr) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (process.exitCode != null) throw new Error(`relay exited early: ${readStderr()}`);
    try {
      const response = await fetch(`${baseURL}/healthz`);
      if (response.ok) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`relay did not start: ${readStderr()}`);
}

async function waitForHTTPServer(process, url, readStderr) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (process.exitCode != null) throw new Error(`relay exited early: ${readStderr()}`);
    try {
      const response = await fetch(`${url}/healthz`);
      if (response.ok) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`relay did not start: ${readStderr()}`);
}

async function availablePort() {
  const listener = net.createServer();
  await new Promise((resolve, reject) => {
    listener.once("error", reject);
    listener.listen(0, "127.0.0.1", resolve);
  });
  const selected = listener.address().port;
  await new Promise((resolve) => listener.close(resolve));
  return selected;
}

function rawWebSocketUpgrade(route, token) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: "127.0.0.1", port });
    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error("websocket upgrade timeout"));
    }, 2_000);
    timeout.unref();
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
      const queue = rawWebSocketJSONQueue(socket, handshake.subarray(boundary + 4));
      resolve({
        status,
        next: queue.next,
        send(value) {
          const text = typeof value === "string" ? value : JSON.stringify(value);
          socket.write(encodeMaskedWebSocketFrame(text));
        },
        close() {
          socket.destroy();
        },
      });
    };
    socket.once("error", onError);
    socket.on("data", onData);
    socket.once("connect", () => {
      const key = crypto.randomBytes(16).toString("base64");
      socket.write([
        `GET ${route} HTTP/1.1`,
        `Host: 127.0.0.1:${port}`,
        "Connection: Upgrade",
        "Upgrade: websocket",
        "Sec-WebSocket-Version: 13",
        `Sec-WebSocket-Key: ${key}`,
        `Authorization: Bearer ${token}`,
        "",
        "",
      ].join("\r\n"));
    });
  });
}

function rawWebSocketJSONQueue(socket, initialData = Buffer.alloc(0)) {
  const queued = [];
  const waiters = [];
  let failure = null;
  let buffer = Buffer.from(initialData);
  const fail = (error) => {
    failure = error;
    while (waiters.length) waiters.shift().reject(failure);
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
      if (opcode === 0x8) {
        fail(new Error("websocket closed"));
        return;
      }
      if (opcode !== 0x1) continue;
      const value = JSON.parse(payload.toString("utf8"));
      const waiter = waiters.shift();
      if (waiter) waiter.resolve(value);
      else queued.push(value);
    }
  };
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    try {
      drain();
    } catch (error) {
      fail(error);
    }
  });
  socket.on("error", fail);
  socket.on("close", () => {
    if (!failure && waiters.length) fail(new Error("websocket closed"));
  });
  drain();
  return {
    next: () => {
      if (failure) return Promise.reject(failure);
      if (queued.length) return Promise.resolve(queued.shift());
      return new Promise((resolve, reject) => {
        const waiter = { resolve, reject };
        waiters.push(waiter);
        setTimeout(() => {
          const index = waiters.indexOf(waiter);
          if (index >= 0) {
            waiters.splice(index, 1);
            reject(new Error("websocket message timeout"));
          }
        }, 2_000).unref();
      });
    },
  };
}

function encodeMaskedWebSocketFrame(text) {
  const payload = Buffer.from(text, "utf8");
  const mask = crypto.randomBytes(4);
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x81, 0x80 | payload.length]);
  } else {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(payload.length, 2);
  }
  const masked = Buffer.from(payload);
  for (let index = 0; index < masked.length; index += 1) masked[index] ^= mask[index % 4];
  return Buffer.concat([header, mask, masked]);
}

function onceExit(process) {
  if (process.exitCode != null) return Promise.resolve(process.exitCode);
  return new Promise((resolve) => process.once("exit", resolve));
}

function collectChild(process) {
  let stdout = "";
  let childStderr = "";
  process.stdout.setEncoding("utf8");
  process.stderr.setEncoding("utf8");
  process.stdout.on("data", (chunk) => { stdout += chunk; });
  process.stderr.on("data", (chunk) => { childStderr += chunk; });
  return new Promise((resolve) => process.once("exit", (code) => resolve({ code, stdout, stderr: childStderr })));
}
