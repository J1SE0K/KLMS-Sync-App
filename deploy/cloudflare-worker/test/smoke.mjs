import assert from "node:assert/strict";
import fs from "node:fs/promises";
import worker, { consumeBoundedRateWindow } from "../src/worker.mjs";
import { redactPublicLogText } from "../../../tools/klms_public_log_redactor.mjs";

const clientToken = "test-client-token-0123456789abcdef0123456789abcdef";
const workerToken = "test-worker-token-fedcba9876543210fedcba9876543210";
const publicLogRedactionFixture = JSON.parse(await fs.readFile(
  new URL("../../../tests/fixtures/public_log_redaction_cases.json", import.meta.url),
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
let env;

async function runSmoke() {
  assertBoundedRateWindowContract(consumeBoundedRateWindow);
  env = {
    RELAY_CLIENT_TOKEN: clientToken,
    RELAY_WORKER_TOKEN: workerToken,
    RELAY_DB: new FakeD1(),
    RELAY_FILES: new FakeR2(),
    RELAY_TEST_LOCAL_COORDINATOR: "1",
    RELAY_REQUESTS_PER_MINUTE: "6000",
    RELAY_PUBLIC_DOWNLOAD_INGRESS_PER_MINUTE: "600",
    RELAY_PUBLIC_DOWNLOAD_LINKS_PER_MINUTE: "600",
  };

  await expectJSON("/healthz", { ok: true, storage: "cloudflare-d1", configured: true }, { auth: false });
  assert.equal((await request("/healthz", { auth: false })).headers.get("Access-Control-Allow-Origin"), null);

  {
    assert.equal((await request("/readyz", { auth: false })).status, 401);
    const missingRealtime = await expectJSON("/readyz", undefined, { role: "worker", status: 503 });
    assert.equal(missingRealtime.ok, false);
    assert.equal(missingRealtime.checks.realtime, false);
    env.RELAY_REALTIME = {
      idFromName: () => "default",
      get: () => ({ fetch: async () => new Response("ok") }),
    };
    const ready = await expectJSON("/readyz", undefined, { role: "worker" });
    assert.equal(ready.ok, true);
    assert.equal(ready.checks.rateLimiter, true);
    env.RELAY_DB.schemaComplete = false;
    const missingSchema = await expectJSON("/readyz", undefined, { role: "worker", status: 503 });
    assert.equal(missingSchema.checks.schema, false);
    env.RELAY_DB.schemaComplete = true;
    delete env.RELAY_REALTIME;
  }

  {
    delete env.RELAY_TEST_LOCAL_COORDINATOR;
    const health = await expectJSON("/healthz", undefined, { auth: false });
    assert.equal(health.configured, false);
    assert.equal((await request("/v1/status")).status, 503, "production must fail closed without the mutation coordinator binding");
    env.RELAY_MUTATIONS = {
      idFromName: () => "global",
      get: () => ({}),
    };
    assert.equal((await request("/healthz", { auth: false })).status, 200);
    assert.equal((await request("/healthz", { auth: false }).then((response) => response.json())).configured, false);
    assert.equal(
      (await request("/readyz", { role: "worker" })).status,
      503,
      "production must fail closed without the durable rate limiter binding",
    );
    delete env.RELAY_MUTATIONS;
    env.RELAY_TEST_LOCAL_COORDINATOR = "1";
  }

  {
    const response = await request("/v1/status", { auth: false });
    assert.equal(response.status, 401);
  }

  {
    env.RELAY_REQUESTS_PER_MINUTE = "2";
    const headers = { "CF-Connecting-IP": "203.0.113.42" };
    const invalidHeaders = {
      ...headers,
      Authorization: "Bearer invalid-token-with-enough-entropy",
    };
    assert.equal((await request("/v1/status", { auth: false, headers: invalidHeaders })).status, 401);
    assert.equal((await request("/v1/status", { auth: false, headers: invalidHeaders })).status, 401);
    assert.equal((await request("/v1/status", { auth: false, headers: invalidHeaders })).status, 429);
    const capacityEnv = { ...env };
    let acceptedNewIdentities = 0;
    let unauthenticatedCapacityRejected = false;
    for (let index = 0; index < 513; index += 1) {
      const response = await request("/v1/status", {
        auth: false,
        environment: capacityEnv,
        headers: {
          Authorization: "Bearer invalid-token-with-enough-entropy",
          "CF-Connecting-IP": `2001:db8::${(index + 1).toString(16)}`,
        },
      });
      if (response.status === 429) {
        unauthenticatedCapacityRejected = true;
        break;
      }
      assert.equal(response.status, 401);
      acceptedNewIdentities += 1;
    }
    assert.equal(unauthenticatedCapacityRejected, true);
    assert.equal(acceptedNewIdentities, 512);
    assert.equal(
      (await request("/v1/status", { environment: capacityEnv })).status,
      200,
      "unauthenticated map exhaustion must not consume reserved authenticated capacity",
    );
    assert.equal((await request("/v1/status", { headers })).status, 200);
    assert.equal((await request("/v1/status", { headers })).status, 200);
    const limited = await request("/v1/status", { headers });
    assert.equal(limited.status, 429);
    assert.equal(limited.headers.get("Retry-After"), "60");
    env.RELAY_REQUESTS_PER_MINUTE = "6000";
  }

  {
    const prepareCount = env.RELAY_DB.prepareCount;
    const malformedID = await request(`/v1/file-access/not-a-uuid/download?ticket=${"a".repeat(64)}`, { auth: false });
    assert.equal(malformedID.status, 404);
    assert.equal(env.RELAY_DB.prepareCount, prepareCount, "malformed download UUID must not touch D1");
    const malformedTicket = await request("/v1/file-access/00000000-0000-4000-8000-000000000001/download?ticket=short", {
      auth: false,
      headers: { "CF-Connecting-IP": "192.0.2.10" },
    });
    assert.equal(malformedTicket.status, 401);
    assert.equal(env.RELAY_DB.prepareCount, prepareCount, "malformed download ticket must not touch D1");
    for (const malformedPath of [
      "/v1/commands/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa-a",
      "/v1/item-actions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa-a",
      "/v1/setting-actions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa-a",
      "/v1/file-access/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa-a",
      "/v1/file-access/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa-a/upload",
    ]) {
      const malformedMutation = await request(malformedPath, {
        method: "PUT",
        role: "worker",
        body: {},
      });
      assert.equal(malformedMutation.status, 404);
      assert.equal(env.RELAY_DB.prepareCount, prepareCount, "malformed mutation UUID must not touch D1");
    }
  }

  {
    const invalidRole = await request("/v1/events?role=invalid", {
      headers: { Upgrade: "websocket" },
    });
    assert.equal(invalidRole.status, 400);
    const missingRole = await request("/v1/events", {
      headers: { Upgrade: "websocket" },
    });
    assert.equal(missingRole.status, 400);
    const unauthorizedRole = await request("/v1/events?role=client", {
      auth: false,
      headers: { Upgrade: "websocket" },
    });
    assert.equal(unauthorizedRole.status, 401);
  }

  {
    const payload = await expectJSON("/v1/status");
    assert.equal(payload.ok, true);
    assert.equal(payload.status.phase, "idle");
    assert.equal(payload.revision, 0);
    const invalidCommand = await request("/v1/commands", {
      method: "POST",
      body: { id: "not-a-uuid", kind: "unknownCommand", status: "running" },
    });
    assert.equal(invalidCommand.status, 400);
    const malformedJSON = await request("/v1/commands", {
      method: "POST",
      rawBody: "{",
    });
    assert.equal(malformedJSON.status, 400);
    assert.equal((await malformedJSON.json()).error, "request body must be valid JSON");
    const oversizedJSON = await request("/v1/commands", {
      method: "POST",
      rawBody: JSON.stringify({ padding: "x".repeat((1024 * 1024) + 1) }),
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
    assert.equal((await expectJSON("/v1/status")).revision, 0);
  }

  {
    const response = await request("/v1/status", { method: "POST", body: { phase: "running" }, role: "client" });
    assert.equal(response.status, 401);
  }

  {
    const response = await request("/v1/commands/pending", { role: "client" });
    assert.equal(response.status, 401);
  }

  await expectJSON("/v1/status", {
    status: { assignments: 1, phase: "idle" },
    running: false,
    message: "worker status",
  }, { method: "POST", role: "worker" });

  {
    const authCommand = {
      id: "00000000-0000-4000-8000-000000000057",
      kind: "fullSync",
      status: "running",
      summary: { phase: "running", authDigits: "57", loginRequired: true },
    };
    await expectJSON("/v1/status", {
      status: { phase: "running", authDigits: "57", loginRequired: true },
      latestCommand: authCommand,
      running: true,
      message: "auth needed",
    }, { method: "POST", role: "worker" });
    const running = await expectJSON("/v1/status");
    assert.equal(running.status.authDigits, "57");
    assert.equal(running.latestCommand.summary.authDigits, "57");

    await expectJSON("/v1/status", {
      status: { phase: "idle", authDigits: "57", loginRequired: false },
      latestCommand: {
        ...authCommand,
        status: "completed",
        summary: { phase: "completed", authDigits: "57", loginRequired: false },
      },
      running: false,
      message: "completed",
    }, { method: "POST", role: "worker" });
    const completed = await expectJSON("/v1/status");
    assert.equal(completed.status.authDigits, null);
    assert.equal(completed.latestCommand.summary.authDigits, null);
  }

  {
    const originalRealtime = env.RELAY_REALTIME;
    let waitUntilCalled = 0;
    let resolveBroadcast;
    let broadcastEnvelope;
    env.RELAY_REALTIME = {
      idFromName: () => "default",
      get: () => ({
        fetch: (_input, init) => new Promise((resolve) => {
          broadcastEnvelope = JSON.parse(init.body);
          resolveBroadcast = () => resolve(new Response("ok"));
        }),
      }),
    };
    const ctx = {
      waitUntil(promise) {
        waitUntilCalled += 1;
        promise.catch(() => {});
      },
    };
    const responsePromise = request("/v1/status", {
      method: "POST",
      role: "worker",
      body: {
        status: { assignments: 1, phase: "idle" },
        running: false,
        message: "nonblocking realtime",
      },
      ctx,
    });
    const response = await Promise.race([
      responsePromise,
      new Promise((resolve) => setTimeout(() => resolve(null), 100)),
    ]);
    assert.ok(response, "status update should not wait for realtime broadcast");
    assert.equal(response.status, 200);
    assert.equal(waitUntilCalled, 1);
    assert.equal(broadcastEnvelope.version, 1);
    assert.equal(broadcastEnvelope.type, "changed");
    assert.ok(broadcastEnvelope.revision > 0);
    assert.equal(broadcastEnvelope.reason, "state");
    assert.deepEqual(broadcastEnvelope.scopes, ["status"]);
    assert.equal(broadcastEnvelope.requiresSnapshot, false);
    resolveBroadcast();
    await responsePromise;
    env.RELAY_REALTIME = originalRealtime;
  }

  const clientOwnedID = "00000000-0000-4000-8000-000000000099";
  let createdCommand = await expectJSON("/v1/commands", {
    id: clientOwnedID,
    kind: "fullSync",
    options: { updateNoticeNotes: false, dryRun: true },
    status: "pending",
    summary: { assignments: 3, phase: "pending" },
  }, { method: "POST", status: 201 });
  assert.equal(createdCommand.kind, "fullSync");
  assert.notEqual(createdCommand.id, clientOwnedID);
  assert.equal(createdCommand.status, "pending");
  assert.equal(createdCommand.options.updateNoticeNotes, false);
  assert.equal(createdCommand.options.dryRun, true);

  {
    const payload = await expectJSON("/v1/commands/pending", undefined, { role: "worker" });
    assert.equal(payload.commands.length, 1);
    assert.equal(payload.commands[0].id, createdCommand.id);
    assert.equal(payload.commands[0].options.updateNoticeNotes, false);
    assert.equal(payload.commands[0].options.dryRun, true);
  }

  {
    const missingCommandCancel = await request("/v1/cancel", {
      method: "POST",
      body: { message: "stop without command" },
    });
    assert.equal(missingCommandCancel.status, 400);

    const cancel = await expectJSON("/v1/cancel", {
      commandID: createdCommand.id,
      message: "stop please",
    }, { method: "POST", status: 200 });
    assert.equal(cancel.requested, false);
    assert.equal(cancel.commandID, null);
    const recentAfterCancel = await expectJSON("/v1/commands/recent");
    assert.equal(recentAfterCancel.latestCommand.id, createdCommand.id);
    assert.equal(recentAfterCancel.latestCommand.status, "cancelled");
    const pendingAfterCancel = await expectJSON("/v1/commands/pending", undefined, { role: "worker" });
    assert.equal(pendingAfterCancel.commands.length, 0);
    const pendingCancel = await expectJSON("/v1/cancel", undefined, { role: "worker" });
    assert.equal(pendingCancel.requested, false);
  }

  createdCommand = await expectJSON("/v1/commands", {
    kind: "fullSync",
    options: { updateNoticeNotes: false, dryRun: true },
    status: "pending",
    summary: { assignments: 3, phase: "pending" },
  }, { method: "POST", status: 201 });

  await expectJSON(`/v1/commands/${createdCommand.id}`, {
    ...createdCommand,
    status: "completed",
    updatedAt: new Date().toISOString(),
    summary: { assignments: 3, phase: "completed" },
  }, { method: "PUT", role: "worker" });

  {
    const responses = await Promise.all([
      request("/v1/commands", { method: "POST", body: { kind: "verify" } }),
      request("/v1/commands", { method: "POST", body: { kind: "doctor" } }),
    ]);
    assert.deepEqual(responses.map((response) => response.status).sort(), [201, 409]);
    const winnerResponse = responses.find((response) => response.status === 201);
    const winner = await winnerResponse.json();
    await expectJSON(`/v1/commands/${winner.id}`, {
      ...winner,
      status: "completed",
    }, { method: "PUT", role: "worker" });
  }

  const originalSyncRealtime = env.RELAY_REALTIME;
  let syncBroadcastEnvelope;
  env.RELAY_REALTIME = {
    idFromName: () => "default",
    get: () => ({
      fetch: (_input, init) => {
        syncBroadcastEnvelope = JSON.parse(init.body);
        return Promise.resolve(new Response("ok"));
      },
    }),
  };
  const syncResponse = await expectJSON("/v1/sync-data", {
    generatedAt: "2026-05-31T00:00:00Z",
    items: [
      {
        id: "exam-1",
        kind: "exam",
        course: "영미 단편소설",
        title: "기말고사",
        timestamp: "2026-06-12 10:00",
        status: "예정",
        detail: "범위: 전체",
        attachmentCount: 0,
        updatedAt: "2026-05-31T00:00:00Z",
      },
      {
        id: "notice-1",
        kind: "notice",
        course: "데이터베이스",
        title: "공지",
        timestamp: "2026-05-31 09:00",
        status: "새 공지",
        detail: "/Users/example/private 12345 주소",
        attachmentCount: 1,
        updatedAt: "2026-05-31T00:00:01Z",
      },
      {
        id: "file-known-term",
        kind: "file",
        course: "영미 단편소설",
        title: "강의자료 1.pdf",
        timestamp: "2026-05-31 09:00",
        status: "folders",
        detail: "",
        attachmentCount: 0,
        updatedAt: "2026-05-31T00:00:02Z",
      },
      {
        id: "file-missing-term",
        kind: "file",
        course: "영미 단편소설",
        title: "강의자료 2.pdf",
        timestamp: "KLMS 페이지에 시각 정보 없음",
        status: "folders",
        detail: "",
        attachmentCount: 0,
        updatedAt: "2026-05-31T00:00:03Z",
      },
    ],
    dryRunReports: [
      {
        scope: "notice",
        status: "ok",
        would_create: 1,
        would_update: 2,
        would_delete: 0,
      },
    ],
    calendarChanges: [
      {
        action: "created",
        calendar: "KLMS 시험",
        bucket: "exam",
        title: "기말고사",
        course: "영미 단편소설",
        start_at: "2026-06-12 10:00",
        location: "서울시 테스트로 123",
        changes: ["시간 생성"],
      },
      {
        action: "deleted",
        calendar: "KLMS 시험",
        bucket: "exam",
        title: "지난 시험",
        course: "영미 단편소설",
        start_at: "2026-03-12 10:00",
        changes: ["삭제"],
      },
    ],
    settings: [
      {
        key: "FILE_REFRESH_MODE",
        title: "파일 탐색 모드",
        value: "auto",
        valueKind: "choice",
        options: ["auto", "quick"],
        editable: true,
      },
    ],
    runLogs: [
      {
        id: "11111111-1111-4111-8111-111111111111",
        command: "fullSync",
        commandTitle: "attacker supplied title",
        status: "attacker supplied status",
        startedAt: "2026-05-31T00:00:00Z",
        finishedAt: "2026-05-31T00:00:05Z",
        updatedAt: "2026-05-31T00:00:05Z",
        duration: "{\"worker_token\":\"synthetic-duration-secret\",\"safe\":\"5초\"}",
        exitCode: 0,
        dryRun: false,
        wasCancelled: false,
        needsAttention: false,
        outputTail: `KAIST 인증 번호: 57\n${publicLogRedactionCases.map((item) => item.input).join("\n")}\n정상 완료`,
      },
    ],
  }, { method: "POST", role: "worker" });
  env.RELAY_REALTIME = originalSyncRealtime;
  assert.equal(syncBroadcastEnvelope.reason, "sync-data");
  assert.equal(syncBroadcastEnvelope.requiresSnapshot, true);
  assert.equal(syncResponse.revision, syncBroadcastEnvelope.revision, "snapshot revision must match its committed event");

  {
    const removedPoll = await request("/v1/events/poll?role=client&waitSeconds=0");
    assert.equal(removedPoll.status, 410);
    const status = await expectJSON("/v1/status");
    assert.ok(status.revision > 0);
  }

  {
    const payload = await expectJSON("/v1/sync-data?kind=exam&limit=10");
    assert.equal(payload.items.length, 1);
    assert.equal(payload.items[0].id, "exam-1");
  }
  {
    const payload = await expectJSON("/v1/sync-data?kind=notice&limit=10");
    assert.equal(payload.items.length, 1);
    assert.equal(payload.items[0].detail, "");
    assert.equal(payload.dryRunReports[0].scope, "notice");
    assert.equal(payload.calendarChanges.length, 1);
    assert.equal(payload.calendarChanges[0].title, "기말고사");
    assert.equal(payload.settings[0].key, "FILE_REFRESH_MODE");
    assert.equal(payload.calendarChanges[0].url, "");
    assert.equal(payload.calendarChanges[0].location, "");
    assert.equal(payload.runLogs.length, 1);
    assert.equal(payload.runLogs[0].commandTitle, "전체 동기화");
    assert.equal(payload.runLogs[0].status, "성공");
    assert.equal(payload.runLogs[0].needsAttention, false);
    assert.doesNotMatch(payload.runLogs[0].duration, /synthetic-duration-secret/);
    assert.match(payload.runLogs[0].duration, /\[credential\]/);
    assert.match(payload.runLogs[0].outputTail, /KAIST 인증 번호: --/);
    assert.match(payload.runLogs[0].outputTail, /\[URL\]/);
    assert.match(payload.runLogs[0].outputTail, /\[credential\]/);
    assert.match(payload.runLogs[0].outputTail, /\[local-path\]/);
    assert.doesNotMatch(payload.runLogs[0].outputTail, /57/);
    assert.doesNotMatch(payload.runLogs[0].outputTail, /\/Users/);
    assert.doesNotMatch(payload.runLogs[0].outputTail, /Application Support/);
    assert.doesNotMatch(payload.runLogs[0].outputTail, /과목 폴더/);
    assert.doesNotMatch(payload.runLogs[0].outputTail, /\/private\/tmp|\/Volumes|\/home|C:\\Users/i);
    assert.doesNotMatch(payload.runLogs[0].outputTail, /synthetic-json-secret|another-secret|query-secret/);
  }
  {
    const payload = await expectJSON("/v1/status");
    assert.equal(payload.status.assignments, 0);
    assert.equal(payload.status.exams, 1);
    assert.equal(payload.status.notices, 1);
    assert.equal(payload.status.fileTotal, 2);
  }
  {
    const payload = await expectJSON("/v1/sync-data?kind=file&limit=10");
    assert.equal(payload.items.length, 2);
    assert.equal(payload.items.find((item) => item.id === "file-missing-term").academicYear, 2026);
    assert.equal(payload.items.find((item) => item.id === "file-missing-term").academicSemester, "봄학기");
  }

  {
    const initial = await expectJSON("/v1/shared-settings");
    assert.equal(initial.settings.find((setting) => setting.key === "KLMS_APPEARANCE_MODE")?.value, "system");
    const updated = await expectJSON("/v1/shared-settings/KLMS_UPDATE_NOTICE_NOTES", {
      value: "0",
    }, { method: "PUT" });
    assert.equal(updated.key, "KLMS_UPDATE_NOTICE_NOTES");
    assert.equal(updated.value, "0");
    const afterUpdate = await expectJSON("/v1/sync-data?limit=10");
    assert.equal(afterUpdate.sharedSettings.find((setting) => setting.key === "KLMS_UPDATE_NOTICE_NOTES")?.value, "0");
    const status = await expectJSON("/v1/status");
    assert.ok(status.revision > 0);
  }

  {
    const clearRunLogs = await expectJSON("/v1/sync-data/run-logs", undefined, { method: "DELETE" });
    assert.equal(clearRunLogs.runLogs, 1);
    const status = await expectJSON("/v1/status");
    assert.ok(status.revision > 0);
    const afterClear = await expectJSON("/v1/sync-data?limit=10");
    assert.equal(afterClear.runLogs.length, 0);
    await expectJSON("/v1/sync-data", {
      generatedAt: "2026-05-31T00:00:00Z",
      items: [
        {
          id: "exam-1",
          kind: "exam",
          course: "영미 단편소설",
          title: "기말고사",
          timestamp: "2026-06-12 10:00",
          status: "예정",
          detail: "범위: 전체",
          attachmentCount: 0,
          updatedAt: "2026-05-31T00:00:00Z",
        },
      ],
      runLogs: [
        {
          id: "22222222-2222-4222-8222-222222222222",
          command: "notice",
          commandTitle: "공지",
          status: "성공",
          startedAt: "2026-05-30T00:00:00Z",
          finishedAt: "2026-05-30T00:00:01Z",
          updatedAt: "2026-05-30T00:00:01Z",
          duration: "1초",
          exitCode: 0,
          outputTail: "지워진 이전 로그",
        },
      ],
    }, { method: "POST", role: "worker" });
    const afterOldPost = await expectJSON("/v1/sync-data?limit=10");
    assert.equal(afterOldPost.runLogs.length, 0);
    const future = new Date(Date.now() + 1000).toISOString();
    await expectJSON("/v1/sync-data", {
      generatedAt: "2026-05-31T00:00:00Z",
      items: afterOldPost.items,
      runLogs: [
        {
          id: "33333333-3333-4333-8333-333333333333",
          command: "files",
          commandTitle: "파일",
          status: "성공",
          startedAt: future,
          finishedAt: future,
          updatedAt: future,
          duration: "1초",
          exitCode: 0,
          outputTail: "새 로그",
        },
      ],
    }, { method: "POST", role: "worker" });
    const afterNewPost = await expectJSON("/v1/sync-data?limit=10");
    assert.equal(afterNewPost.runLogs.length, 1);
    assert.equal(afterNewPost.runLogs[0].commandTitle, "파일 동기화");
  }

  const calendarChangeID = [
    "created",
    "KLMS 시험",
    "exam",
    "",
    "추가 시험",
    "2026-06-18 09:00",
    "2026-06-18 10:00",
    "",
  ].join("|");
  await expectJSON("/v1/sync-data", {
    generatedAt: "2026-05-31T00:00:00Z",
    items: [
      {
        id: "exam-1",
        kind: "exam",
        course: "영미 단편소설",
        title: "기말고사",
        timestamp: "2026-06-12 10:00",
        status: "예정",
        detail: "범위: 전체",
        attachmentCount: 0,
        updatedAt: "2026-05-31T00:00:00Z",
      },
      {
        id: "notice-1",
        kind: "notice",
        course: "데이터베이스",
        title: "공지",
        timestamp: "2026-05-31 09:00",
        status: "새 공지",
        detail: "내용",
        attachmentCount: 1,
        updatedAt: "2026-05-31T00:00:01Z",
        isRead: false,
        isImportant: false,
        isHidden: false,
      },
      {
        id: "assignment-1",
        kind: "assignment",
        course: "알고리즘 개론",
        title: "과제 1",
        timestamp: "2026-06-01 23:59",
        status: "진행 중",
        detail: "",
        attachmentCount: 0,
        updatedAt: "2026-05-31T00:00:02Z",
      },
    ],
    calendarChanges: [
      {
        action: "created",
        calendar: "KLMS 시험",
        bucket: "exam",
        title: "추가 시험",
        start_at: "2026-06-18 09:00",
        due_at: "2026-06-18 10:00",
        changes: ["새 일정"],
      },
    ],
  }, { method: "POST", role: "worker" });

  const action = await expectJSON("/v1/item-actions", {
    action: "noticeRead",
    itemID: "notice-1",
    itemKind: "notice",
    itemTitle: "공지",
  }, { method: "POST", status: 201 });
  assert.equal(action.status, "completed");
  assert.match(action.message, /서버 화면에 바로 반영/);
  {
    const payload = await expectJSON("/v1/sync-data?kind=notice&limit=10");
    assert.equal(payload.items.length, 1);
    assert.equal(payload.items[0].isRead, true);
    const status = await expectJSON("/v1/status");
    assert.equal(status.status.noticeNew, 0);
    assert.equal(status.status.notices, 1);
  }

  {
    const idempotentID = "44444444-4444-4444-8444-444444444444";
    const body = {
      id: idempotentID,
      action: "noticeImportant",
      itemID: "notice-1",
      itemKind: "notice",
      itemTitle: "공지",
    };
    const created = await expectJSON("/v1/item-actions", body, { method: "POST", status: 201 });
    assert.equal(created.id, idempotentID);
    assert.deepEqual(await expectJSON(`/v1/item-actions/${created.id}`), created);
    const revisionAfterCreate = (await expectJSON("/v1/status")).revision;
    const replayed = await expectJSON("/v1/item-actions", body, { method: "POST" });
    assert.equal(replayed.id, created.id);
    assert.equal((await expectJSON("/v1/status")).revision, revisionAfterCreate);
    const conflict = await request("/v1/item-actions", {
      method: "POST",
      body: { ...body, action: "noticeUnread" },
    });
    assert.equal(conflict.status, 409);
    assert.equal((await expectJSON("/v1/status")).revision, revisionAfterCreate);
  }

  const futureAction = await expectJSON("/v1/item-actions", {
    action: "noticeImportant",
    itemID: "notice-future",
    itemKind: "notice",
    itemTitle: "나중에 들어올 공지",
  }, { method: "POST", status: 201 });
  assert.equal(futureAction.status, "completed");
  assert.match(futureAction.message, /서버 화면에 바로 반영/);
  {
    const pendingActions = await expectJSON("/relay/v1/item-actions/pending", undefined, { role: "worker" });
    assert.equal(
      pendingActions.actions.some((pendingAction) => pendingAction.id === futureAction.id),
      false
    );
  }
  await expectJSON("/v1/sync-data", {
    generatedAt: "2026-05-31T00:00:20Z",
    items: [
      {
        id: "notice-future",
        kind: "notice",
        course: "알고리즘",
        title: "나중에 들어올 공지",
        timestamp: "2026-05-31",
        status: "",
        detail: "",
        attachmentCount: 0,
        updatedAt: "2026-05-31T00:00:20Z",
      },
    ],
    calendarChanges: [
      {
        action: "created",
        calendar: "KLMS 시험",
        bucket: "exam",
        title: "추가 시험",
        start_at: "2026-06-18 09:00",
        due_at: "2026-06-18 10:00",
        changes: ["새 일정"],
      },
    ],
  }, { method: "POST", role: "worker" });
  {
    const payload = await expectJSON("/v1/sync-data?kind=notice&limit=10");
    const futureNotice = payload.items.find((item) => item.id === "notice-future");
    assert.ok(futureNotice);
    assert.equal(futureNotice.isImportant, true);
  }

  const calendarAction = await expectJSON("/v1/item-actions", {
    action: "calendarCreate",
    itemID: calendarChangeID,
    itemKind: "calendar",
    itemTitle: "추가 시험",
  }, { method: "POST", status: 201 });
  assert.equal(calendarAction.status, "pending");
  {
    const payload = await expectJSON("/v1/sync-data?limit=10");
    assert.equal(payload.calendarChanges.length, 0);
    const status = await expectJSON("/v1/status");
    assert.equal(status.status.calendarCreated, 0);
  }
  await expectJSON(`/v1/item-actions/${calendarAction.id}`, {
    ...calendarAction,
    status: "completed",
    updatedAt: new Date().toISOString(),
    message: "calendar done",
  }, { method: "PUT", role: "worker" });

  {
    const payload = await expectJSON("/relay/v1/item-actions/pending", undefined, { role: "worker" });
    assert.equal(payload.actions.length, 0);
  }

  await expectJSON("/v1/sync-data", {
    generatedAt: "2026-05-31T00:00:30Z",
    items: [
      {
        id: "exam-1",
        kind: "exam",
        course: "영미 단편소설",
        title: "기말고사",
        timestamp: "2026-06-12 10:00",
        status: "예정",
        detail: "범위: 전체",
        attachmentCount: 0,
        updatedAt: "2026-05-31T00:00:30Z",
      },
    ],
    calendarChanges: [
      {
        action: "created",
        calendar: "KLMS 시험",
        bucket: "exam",
        title: "추가 시험",
        start_at: "2026-06-18 09:00",
        due_at: "2026-06-18 10:00",
        changes: ["새 일정"],
      },
    ],
  }, { method: "POST", role: "worker" });
  const calendarApplyAction = await expectJSON("/v1/item-actions", {
    action: "calendarApply",
    itemID: calendarChangeID,
    itemKind: "calendar",
    itemTitle: "추가 시험",
  }, { method: "POST", status: 201 });
  assert.equal(calendarApplyAction.status, "pending");
  {
    const payload = await expectJSON("/v1/sync-data?limit=10");
    assert.equal(payload.calendarChanges.length, 0);
    const status = await expectJSON("/v1/status");
    assert.equal(status.status.calendarCreated, 0);
    assert.match(status.message, /서버 화면 반영 완료/);
    const requestLog = await expectJSON("/v1/request-log/recent?limit=1");
    assert.equal(requestLog.entries[0].status, "updated");
    assert.match(requestLog.entries[0].message, /Mac 앱이 켜지면 실제 앱에도 적용/);
  }
  await expectJSON(`/v1/item-actions/${calendarApplyAction.id}`, {
    ...calendarApplyAction,
    status: "completed",
    updatedAt: new Date().toISOString(),
    message: "calendar apply done",
  }, { method: "PUT", role: "worker" });

  await expectJSON("/v1/sync-data", {
    generatedAt: "2026-05-31T00:00:45Z",
    items: [
      {
        id: "exam-1",
        kind: "exam",
        course: "영미 단편소설",
        title: "기말고사",
        timestamp: "2026-06-12 10:00",
        status: "예정",
        detail: "범위: 전체",
        attachmentCount: 0,
        updatedAt: "2026-05-31T00:00:45Z",
      },
    ],
    calendarChanges: [
      {
        action: "created",
        calendar: "KLMS 시험",
        bucket: "exam",
        title: "추가 시험",
        start_at: "2026-06-18 09:00",
        due_at: "2026-06-18 10:00",
        changes: ["새 일정"],
      },
    ],
  }, { method: "POST", role: "worker" });
  const directCalendarAction = await expectJSON("/v1/item-actions", {
    action: "calendarCreate",
    itemID: calendarChangeID,
    itemKind: "calendar",
    itemTitle: "추가 시험",
    status: "completed",
    message: "iPhone Calendar에 등록 완료",
  }, { method: "POST", status: 201 });
  assert.equal(directCalendarAction.status, "completed");
  {
    const payload = await expectJSON("/v1/sync-data?limit=10");
    assert.equal(payload.calendarChanges.length, 0);
    const pendingActions = await expectJSON("/relay/v1/item-actions/pending", undefined, { role: "worker" });
    assert.equal(
      pendingActions.actions.some((pendingAction) => pendingAction.id === directCalendarAction.id),
      false
    );
  }

  const settingAction = await expectJSON("/v1/setting-actions", {
    key: "FILE_REFRESH_MODE",
    title: "파일 탐색 모드",
    value: "quick",
  }, { method: "POST", status: 201 });
  assert.equal(settingAction.status, "pending");
  assert.match(settingAction.message, /서버 화면에는 바로 반영/);
  {
    const status = await expectJSON("/v1/status");
    assert.match(status.message, /서버 화면 반영 완료/);
    const requestLog = await expectJSON("/v1/request-log/recent?limit=1");
    assert.equal(requestLog.entries[0].status, "updated");
    assert.match(requestLog.entries[0].message, /서버 화면에는 바로 반영/);
  }
  {
    const payload = await expectJSON("/v1/sync-data?limit=10");
    assert.equal(payload.settings.find((setting) => setting.key === "FILE_REFRESH_MODE")?.value, "quick");
  }
  const noticeCollapseSettingAction = await expectJSON("/v1/setting-actions", {
    key: "NOTICE_COLLAPSE_COURSES",
    title: "공지 과목명 접기",
    value: "1",
  }, { method: "POST", status: 201 });
  assert.equal(noticeCollapseSettingAction.status, "pending");
  assert.match(noticeCollapseSettingAction.message, /서버 화면에는 바로 반영/);
  {
    const payload = await expectJSON("/v1/sync-data?limit=10");
    assert.equal(payload.settings.find((setting) => setting.key === "NOTICE_COLLAPSE_COURSES")?.value, "1");
  }
  await expectJSON(`/v1/setting-actions/${noticeCollapseSettingAction.id}`, {
    ...noticeCollapseSettingAction,
    status: "completed",
    updatedAt: new Date().toISOString(),
    message: "notice collapse done",
  }, { method: "PUT", role: "worker" });

  await expectJSON("/v1/sync-data", {
    generatedAt: "2026-05-31T00:01:00Z",
    items: [
      {
        id: "exam-1",
        kind: "exam",
        course: "영미 단편소설",
        title: "기말고사",
        timestamp: "2026-06-12 10:00",
        status: "예정",
        detail: "범위: 전체",
        attachmentCount: 0,
        updatedAt: "2026-05-31T00:01:00Z",
      },
      {
        id: "notice-1",
        kind: "notice",
        course: "데이터베이스",
        title: "공지",
        timestamp: "2026-05-31 09:00",
        status: "새 공지",
        detail: "내용",
        attachmentCount: 1,
        updatedAt: "2026-05-31T00:01:00Z",
        isRead: false,
        isImportant: false,
        isHidden: false,
      },
    ],
    settings: [
      {
        key: "FILE_REFRESH_MODE",
        title: "파일 탐색 모드",
        value: "auto",
        valueKind: "choice",
        options: ["auto", "quick"],
        editable: true,
      },
    ],
  }, { method: "POST", role: "worker" });
  {
    const payload = await expectJSON("/v1/sync-data?limit=10");
    assert.equal(payload.items.find((item) => item.id === "notice-1")?.isRead, true);
    assert.equal(payload.settings.find((setting) => setting.key === "FILE_REFRESH_MODE")?.value, "quick");
  }
  const noOpSettingAction = await expectJSON("/v1/setting-actions", {
    key: "FILE_REFRESH_MODE",
    title: "파일 탐색 모드",
    value: "quick",
  }, { method: "POST", status: 201 });
  assert.equal(noOpSettingAction.id, settingAction.id);
  assert.equal(noOpSettingAction.status, "pending");

  {
    const payload = await expectJSON("/v1/setting-actions/pending", undefined, { role: "worker" });
    assert.equal(payload.actions.length, 1);
    assert.equal(payload.actions[0].id, settingAction.id);
  }

  await expectJSON(`/v1/setting-actions/${settingAction.id}`, {
    ...settingAction,
    status: "completed",
    updatedAt: new Date().toISOString(),
    message: "saved",
  }, { method: "PUT", role: "worker" });

  const staleRunningAt = new Date(Date.now() - 11 * 60 * 1000).toISOString();
  const staleItemAction = await expectJSON("/v1/item-actions", {
    action: "noticeImportant",
    itemID: "notice-1",
    itemKind: "notice",
    itemTitle: "공지",
  }, { method: "POST", status: 201 });
  await expectJSON(`/v1/item-actions/${staleItemAction.id}`, {
    ...staleItemAction,
    status: "running",
    updatedAt: staleRunningAt,
    message: "processing",
  }, { method: "PUT", role: "worker" });
  env.RELAY_DB.itemActions.get(staleItemAction.id).updated_at = staleRunningAt;
  {
    const pending = await expectJSON("/v1/item-actions/pending", undefined, { role: "worker" });
    assert.equal(pending.actions.some((item) => item.id === staleItemAction.id), false);
    const recent = await expectJSON("/v1/item-actions/recent");
    const expired = recent.actions.find((item) => item.id === staleItemAction.id);
    assert.equal(expired?.status, "macUnavailable");
    assert.match(expired?.message || "", /처리 중 멈춘/);
  }

  const staleSettingAction = await expectJSON("/v1/setting-actions", {
    key: "KLMS_UPDATE_NOTICE_NOTES",
    title: "공지 메모 업데이트",
    value: "0",
  }, { method: "POST", status: 201 });
  await expectJSON(`/v1/setting-actions/${staleSettingAction.id}`, {
    ...staleSettingAction,
    status: "running",
    updatedAt: new Date().toISOString(),
    message: "processing",
  }, { method: "PUT", role: "worker" });
  const storedSettingActions = JSON.parse(env.RELAY_DB.meta.get("settingActions") || "[]");
  const storedStaleSettingAction = storedSettingActions.find((item) => item.id === staleSettingAction.id);
  assert.ok(storedStaleSettingAction);
  storedStaleSettingAction.updatedAt = staleRunningAt;
  env.RELAY_DB.meta.set("settingActions", JSON.stringify(storedSettingActions));
  {
    const pending = await expectJSON("/v1/setting-actions/pending", undefined, { role: "worker" });
    assert.equal(pending.actions.some((item) => item.id === staleSettingAction.id), false);
    const recent = await expectJSON("/v1/setting-actions/recent");
    const expired = recent.actions.find((item) => item.id === staleSettingAction.id);
    assert.equal(expired?.status, "macUnavailable");
    assert.match(expired?.message || "", /설정 반영 중 멈춘/);
  }

  const fileRequest = await expectJSON("/v1/file-access", {
    itemID: "file-1",
    itemKind: "file",
    itemTitle: "기말 정리.txt",
  }, { method: "POST", status: 201 });
  assert.equal(fileRequest.status, "pending");
  {
    const emptyRequest = await expectJSON("/v1/file-access", {
      itemID: "file-empty-upload",
      itemKind: "file",
      itemTitle: "empty.txt",
    }, { method: "POST", status: 201 });
    const revisionBefore = (await expectJSON("/v1/status")).revision;
    const rejected = await request(`/v1/file-access/${emptyRequest.id}/upload`, {
      method: "PUT",
      role: "worker",
      rawBody: "",
      headers: { "Content-Type": "text/plain", "Content-Length": "0" },
    });
    assert.equal(rejected.status, 411);
    assert.equal(env.RELAY_DB.fileAccessRequests.get(emptyRequest.id).updated_at, emptyRequest.updatedAt);
    assert.equal((await expectJSON("/v1/status")).revision, revisionBefore);
    await expectJSON(`/v1/file-access/${emptyRequest.id}`, {
      id: emptyRequest.id,
      itemID: emptyRequest.itemID,
      itemKind: emptyRequest.itemKind,
      status: "failed",
      message: "empty upload rejected",
    }, { method: "PUT", role: "worker" });
  }
  {
    const revisionBefore = (await expectJSON("/v1/status")).revision;
    const objectKeyAttack = await request(`/v1/file-access/${fileRequest.id}`, {
      method: "PUT",
      role: "worker",
      body: { status: "completed", objectKey: "../relay-secret" },
    });
    assert.equal(objectKeyAttack.status, 400);
    assert.equal((await expectJSON("/v1/status")).revision, revisionBefore);
  }
  {
    const concurrentUploadRequest = await expectJSON("/v1/file-access", {
      itemID: "file-concurrent-upload",
      itemKind: "file",
      itemTitle: "claim.txt",
    }, { method: "POST", status: 201 });
    const putsBefore = env.RELAY_FILES.putCount;
    const objectsBefore = env.RELAY_FILES.objects.size;
    const uploadBodies = Array.from({ length: 20 }, (_, index) => `body-${index}`);
    const responses = await Promise.all(uploadBodies.map((body) => (
      request(`/v1/file-access/${concurrentUploadRequest.id}/upload`, {
        method: "PUT",
        role: "worker",
        rawBody: body,
        headers: { "Content-Type": "text/plain", "Content-Length": String(body.length) },
      })
    )));
    assert.equal(responses.filter((response) => response.status === 200).length, 1);
    assert.equal(responses.filter((response) => response.status === 409).length, 19);
    assert.equal(env.RELAY_FILES.putCount - putsBefore, 1);
    assert.equal(env.RELAY_FILES.objects.size - objectsBefore, 1);
  }

  {
    const leasedUploadRequest = await expectJSON("/v1/file-access", {
      itemID: "file-upload-lease",
      itemKind: "file",
      itemTitle: "lease.txt",
    }, { method: "POST", status: 201 });
    let leasedRow = env.RELAY_DB.fileAccessRequests.get(leasedUploadRequest.id);
    const visibleUpdatedAt = leasedRow.updated_at;
    const revisionBefore = (await expectJSON("/v1/status")).revision;
    const putsBefore = env.RELAY_FILES.putCount;
    leasedRow.upload_claim = "fresh-worker-claim";
    leasedRow.upload_claimed_at = new Date().toISOString();
    const freshLeaseResponse = await request(`/v1/file-access/${leasedUploadRequest.id}/upload`, {
      method: "PUT",
      role: "worker",
      rawBody: "fresh-lease-body",
      headers: { "Content-Type": "text/plain", "Content-Length": "16" },
    });
    assert.equal(freshLeaseResponse.status, 409, "a live upload lease must not be stolen");
    assert.equal(env.RELAY_FILES.putCount, putsBefore);
    assert.equal(leasedRow.updated_at, visibleUpdatedAt);
    assert.equal((await expectJSON("/v1/status")).revision, revisionBefore);

    leasedRow = env.RELAY_DB.fileAccessRequests.get(leasedUploadRequest.id);
    leasedRow.upload_claimed_at = new Date(Date.now() - 16 * 60 * 1000).toISOString();
    const previousMaxUploadBytes = env.FILE_RELAY_MAX_UPLOAD_BYTES;
    env.FILE_RELAY_MAX_UPLOAD_BYTES = "8";
    const staleLeaseResponse = await request(`/v1/file-access/${leasedUploadRequest.id}/upload`, {
      method: "PUT",
      role: "worker",
      rawBody: "stale-lease-body",
      headers: { "Content-Type": "text/plain", "Content-Length": "8" },
    });
    if (previousMaxUploadBytes == null) delete env.FILE_RELAY_MAX_UPLOAD_BYTES;
    else env.FILE_RELAY_MAX_UPLOAD_BYTES = previousMaxUploadBytes;
    leasedRow = env.RELAY_DB.fileAccessRequests.get(leasedUploadRequest.id);
    assert.equal(staleLeaseResponse.status, 400, "an expired lease is reclaimed before exact Content-Length validation");
    assert.equal(leasedRow.upload_claim, null);
    assert.equal(leasedRow.upload_claimed_at, null);
    assert.equal(leasedRow.updated_at, visibleUpdatedAt, "internal reclaim/release must not change visible timestamps");
    assert.equal((await expectJSON("/v1/status")).revision, revisionBefore, "internal reclaim/release must not allocate revisions");

    leasedRow.upload_claim = "legacy-claim-without-timestamp";
    leasedRow.upload_claimed_at = null;
    const recovered = await request(`/v1/file-access/${leasedUploadRequest.id}/upload`, {
      method: "PUT",
      role: "worker",
      rawBody: "recovered-body",
      headers: { "Content-Type": "text/plain", "Content-Length": "14" },
    });
    assert.equal(recovered.status, 200, "a legacy claim without a lease timestamp must remain recoverable");
    assert.equal(leasedRow.upload_claim, null);
    assert.equal(leasedRow.upload_claimed_at, null);
    env.RELAY_FILES.objects.delete(leasedRow.object_key);
    env.RELAY_DB.fileAccessRequests.delete(leasedUploadRequest.id);
  }

  {
    const stalePending = await expectJSON("/v1/file-access", {
      itemID: "file-stale-pending",
      itemKind: "file",
      itemTitle: "오래된 대기 요청.txt",
    }, { method: "POST", status: 201 });
    const stalePendingRow = env.RELAY_DB.fileAccessRequests.get(stalePending.id);
    const elevenMinutesAgo = new Date(Date.now() - 11 * 60 * 1000).toISOString();
    stalePendingRow.created_at = elevenMinutesAgo;
    stalePendingRow.updated_at = elevenMinutesAgo;
    await expectJSON("/v1/status");
    const stalePendingAfterExpire = env.RELAY_DB.fileAccessRequests.get(stalePending.id);
    assert.equal(stalePendingAfterExpire.status, "macUnavailable");
    env.RELAY_DB.fileAccessRequests.delete(stalePending.id);

    const activeRunning = await expectJSON("/v1/file-access", {
      itemID: "file-active-running",
      itemKind: "file",
      itemTitle: "업로드 중인 요청.txt",
    }, { method: "POST", status: 201 });
    const activeRunningRow = env.RELAY_DB.fileAccessRequests.get(activeRunning.id);
    activeRunningRow.status = "running";
    activeRunningRow.created_at = elevenMinutesAgo;
    activeRunningRow.updated_at = new Date().toISOString();
    await expectJSON("/v1/status");
    assert.equal(env.RELAY_DB.fileAccessRequests.get(activeRunning.id).status, "running");
    env.RELAY_DB.fileAccessRequests.delete(activeRunning.id);
  }

  {
    const payload = await expectJSON("/v1/file-access/pending", undefined, { role: "worker" });
    assert.equal(payload.requests.length, 1);
    assert.equal(payload.requests[0].itemID, "file-1");
  }
  {
    const unauthorizedInbox = await request("/v1/worker/inbox", { role: "client" });
    assert.equal(unauthorizedInbox.status, 401);

    const inbox = await expectJSON("/v1/worker/inbox", undefined, { role: "worker" });
    assert.equal(inbox.statusResponse.ok, true);
    assert.equal(inbox.pendingFileAccessRequests.length, 1);
    assert.equal(inbox.pendingFileAccessRequests[0].itemID, "file-1");
    assert.equal(inbox.pendingItemActions.length, 0);
    assert.equal(inbox.pendingSettingActions.length, 0);
    assert.equal(inbox.pendingCommands.length, 0);
    assert.equal(inbox.cancelRequest.requested, false);
    assert.equal(inbox.sharedSettings.find((setting) => setting.key === "KLMS_UPDATE_NOTICE_NOTES")?.value, "0");
  }
  const runningCommand = await expectJSON("/v1/commands", {
    kind: "fullSync",
    options: { updateNoticeNotes: false },
    status: "pending",
    summary: { assignments: 3, phase: "pending" },
  }, { method: "POST", status: 201 });
  await expectJSON(`/v1/commands/${runningCommand.id}`, {
    ...runningCommand,
    status: "running",
    updatedAt: new Date().toISOString(),
    summary: { assignments: 3, phase: "running" },
  }, { method: "PUT", role: "worker" });
  const runningCancel = await expectJSON("/v1/cancel", {
    commandID: runningCommand.id,
    message: "running command stop",
  }, { method: "POST", status: 202 });
  assert.equal(runningCancel.requested, true);
  assert.equal(runningCancel.commandID, runningCommand.id);
  {
    const clientClear = await request("/v1/logs", { method: "DELETE" });
    assert.equal(clientClear.status, 401);

    const activeClear = await request("/v1/logs", { method: "DELETE", role: "worker" });
    assert.equal(activeClear.status, 200);
    const activeClearBody = await activeClear.json();
    assert.ok(activeClearBody.commands > 0);
    assert.ok(activeClearBody.itemActions > 0);
    assert.equal(activeClearBody.fileAccessRequests, 2, "all-scope clear removes terminal files while preserving active work");
    assert.equal(env.RELAY_DB.itemActions.has(action.id), false, "all-scope clear removes terminal item actions");
    const pendingAfterActiveClear = await expectJSON("/v1/file-access/pending", undefined, { role: "worker" });
    assert.equal(pendingAfterActiveClear.requests.length, 1);
    const inboxAfterActiveClear = await expectJSON("/v1/worker/inbox", undefined, { role: "worker" });
    assert.equal(inboxAfterActiveClear.cancelRequest.requested, true);
    assert.equal(inboxAfterActiveClear.cancelRequest.commandID, runningCommand.id);
  }
  const workerCancel = await expectJSON("/v1/cancel", undefined, { role: "worker" });
  assert.equal(workerCancel.requested, true);
  assert.equal(workerCancel.commandID, runningCommand.id);
  await expectJSON("/v1/cancel", undefined, { method: "DELETE", role: "worker" });
  await expectJSON(`/v1/commands/${runningCommand.id}`, {
    ...runningCommand,
    status: "cancelled",
    updatedAt: new Date().toISOString(),
    summary: { assignments: 3, phase: "cancelled" },
    message: "cancelled",
  }, { method: "PUT", role: "worker" });

  const clearedActionUpdate = await request(`/v1/item-actions/${action.id}`, {
    method: "PUT",
    role: "worker",
    body: {
    ...action,
    status: "completed",
    updatedAt: new Date().toISOString(),
    message: "done",
    },
  });
  assert.equal(clearedActionUpdate.status, 404);

  const uploadResponse = await request(`/v1/file-access/${fileRequest.id}/upload`, {
    method: "PUT",
    role: "worker",
    rawBody: "hello file",
    headers: {
      "Content-Type": "text/plain",
      "Content-Length": "10",
      "X-KLMS-Filename": encodeURIComponent("기말 정리.txt"),
    },
  });
  assert.equal(uploadResponse.status, 200);
  const uploaded = await uploadResponse.json();
  assert.equal(uploaded.status, "completed");
  assert.match(uploaded.downloadURL, /\/v1\/file-access\/.+\/download\?ticket=/);

  {
    const wrongTicketURL = new URL(uploaded.downloadURL);
    wrongTicketURL.searchParams.set("ticket", "wrong-ticket");
    const wrongTicketResponse = await worker.fetch(new Request(wrongTicketURL.toString(), {
      headers: { "CF-Connecting-IP": "192.0.2.11" },
    }), env);
    assert.equal(wrongTicketResponse.status, 401);
    const wrongTicketHTML = await wrongTicketResponse.text();
    assert.match(wrongTicketHTML, /권한이 없는 링크입니다/);
    assert.doesNotMatch(wrongTicketHTML, /기말 정리.txt/);
    assert.doesNotMatch(wrongTicketHTML, /data-download-count=/);

    env.RELAY_PUBLIC_DOWNLOAD_INGRESS_PER_MINUTE = "2";
    const rateLimitAddress = "198.51.100.77";
    const wellFormedWrongTicketURL = new URL(uploaded.downloadURL);
    wellFormedWrongTicketURL.searchParams.set("ticket", "a".repeat(64));
    const wrongTicketRequest = () => worker.fetch(new Request(wellFormedWrongTicketURL, {
      headers: { "CF-Connecting-IP": rateLimitAddress },
    }), env);
    assert.equal((await wrongTicketRequest()).status, 401);
    assert.equal((await wrongTicketRequest()).status, 401);
    const prepareCountAfterAllowedLookups = env.RELAY_DB.prepareCount;
    for (let attempt = 0; attempt < 25; attempt += 1) {
      assert.equal((await wrongTicketRequest()).status, 429);
    }
    assert.equal(
      env.RELAY_DB.prepareCount,
      prepareCountAfterAllowedLookups,
      "rate-limited fake tickets must not perform D1 work",
    );
    const validTicketResponse = await worker.fetch(new Request(uploaded.downloadURL, {
      headers: { "CF-Connecting-IP": rateLimitAddress },
    }), env);
    assert.equal(
      validTicketResponse.status,
      429,
      "the source ingress budget must protect valid links from an active fake-ticket flood",
    );
    env.RELAY_PUBLIC_DOWNLOAD_INGRESS_PER_MINUTE = "600";

    const unknownTicketURL = new URL(uploaded.downloadURL);
    unknownTicketURL.pathname = "/v1/file-access/00000000-0000-4000-8000-000000000099/download";
    unknownTicketURL.searchParams.set("ticket", "b".repeat(64));
    env.RELAY_PUBLIC_DOWNLOAD_INGRESS_PER_MINUTE = "2";
    const unknownRequest = (forwardedFor) => worker.fetch(new Request(unknownTicketURL, {
      headers: { "X-Forwarded-For": forwardedFor },
    }), env);
    assert.equal((await unknownRequest("203.0.113.1")).status, 404);
    assert.equal((await unknownRequest("203.0.113.2")).status, 404);
    const unknownPrepareCount = env.RELAY_DB.prepareCount;
    assert.equal((await unknownRequest("203.0.113.3")).status, 429);
    assert.equal(env.RELAY_DB.prepareCount, unknownPrepareCount, "X-Forwarded-For must not rotate ingress identity");
    env.RELAY_PUBLIC_DOWNLOAD_INGRESS_PER_MINUTE = "600";

    const linkLimited = await createUploadedFile({
      itemID: "link-rate-limit-file",
      itemTitle: "link-rate-limit.txt",
      body: "link limit",
      contentType: "text/plain",
    });
    env.RELAY_PUBLIC_DOWNLOAD_INGRESS_PER_MINUTE = "10";
    env.RELAY_PUBLIC_DOWNLOAD_LINKS_PER_MINUTE = "2";
    const fakeLinkTicket = new URL(linkLimited.downloadURL);
    fakeLinkTicket.searchParams.set("ticket", "c".repeat(64));
    assert.equal((await worker.fetch(new Request(fakeLinkTicket, {
      headers: { "CF-Connecting-IP": "203.0.113.20" },
    }), env)).status, 401);
    for (const [address, expectedStatus] of [
      ["203.0.113.21", 200],
      ["203.0.113.22", 200],
      ["203.0.113.23", 429],
    ]) {
      assert.equal((await worker.fetch(new Request(linkLimited.downloadURL, {
        headers: { "CF-Connecting-IP": address },
      }), env)).status, expectedStatus);
    }
    env.RELAY_PUBLIC_DOWNLOAD_INGRESS_PER_MINUTE = "600";
    env.RELAY_PUBLIC_DOWNLOAD_LINKS_PER_MINUTE = "600";

    const pageResponse = await worker.fetch(new Request(uploaded.downloadURL), env);
    assert.equal(pageResponse.status, 200);
    const pageHTML = await pageResponse.text();
    assert.match(pageHTML, /KLMS 파일 다운로드/);
    assert.match(pageHTML, />미리보기</);
    assert.match(pageHTML, />파일 다운로드</);
    assert.match(pageHTML, /download=1/);
    assert.match(pageHTML, /preview=1/);
    assert.match(pageHTML, /data-download-count="0"/);
    assert.doesNotMatch(pageHTML, /data-preview-text-url/);

    const previewURL = new URL(uploaded.downloadURL);
    previewURL.searchParams.set("preview", "1");
    const previewResponse = await worker.fetch(new Request(previewURL.toString()), env);
    assert.equal(previewResponse.status, 200);
    assert.match(previewResponse.headers.get("Content-Type"), /^text\/html/);
    const previewHTML = await previewResponse.text();
    assert.match(previewHTML, /KLMS 파일 미리보기/);
    assert.match(previewHTML, /data-action="zoom-in"/);
    assert.match(previewHTML, /data-action="next"/);
    assert.match(previewHTML, /raw=1/);

    const rawPreviewURL = new URL(uploaded.downloadURL);
    rawPreviewURL.searchParams.set("preview", "1");
    rawPreviewURL.searchParams.set("raw", "1");
    const rawPreviewResponse = await worker.fetch(new Request(rawPreviewURL.toString()), env);
    assert.equal(rawPreviewResponse.status, 200);
    assert.match(rawPreviewResponse.headers.get("Content-Disposition"), /^inline;/);
    assert.match(rawPreviewResponse.headers.get("Content-Type"), /^text\/plain/);
    assert.equal(await rawPreviewResponse.text(), "hello file");

    const downloadURL = new URL(uploaded.downloadURL);
    downloadURL.searchParams.set("download", "1");
    const downloadResponse = await worker.fetch(new Request(downloadURL.toString()), env);
    assert.equal(downloadResponse.status, 200);
    assert.equal(await downloadResponse.text(), "hello file");
  }
  {
    const downloadURL = new URL(uploaded.downloadURL);
    downloadURL.searchParams.set("download", "1");
    await worker.fetch(new Request(downloadURL.toString()), env);
    const blockedResponse = await worker.fetch(new Request(downloadURL.toString()), env);
    assert.equal(blockedResponse.status, 429);
  }
  {
    env.FILE_RELAY_DOWNLOADS_PER_LINK = "7";
    const raced = await createUploadedFile({
      itemID: "file-race",
      itemTitle: "race.txt",
      body: "race",
      contentType: "text/plain",
    });
    const racedURL = new URL(raced.downloadURL);
    racedURL.searchParams.set("download", "1");
    const readsBeforeRace = env.RELAY_FILES.getCount;
    const responses = await Promise.all(Array.from(
      { length: 50 },
      () => worker.fetch(new Request(racedURL.toString()), env)
    ));
    assert.equal(responses.filter((response) => response.status === 200).length, 7);
    assert.equal(responses.filter((response) => response.status === 429).length, 43);
    assert.equal(
      env.RELAY_FILES.getCount - readsBeforeRace,
      7,
      "only atomically reserved requests may reach R2"
    );
    delete env.FILE_RELAY_DOWNLOADS_PER_LINK;
  }
  {
    const protectedDownload = await createUploadedFile({
      itemID: "file-active-download-cleanup",
      itemTitle: "active-download.txt",
      body: "active-download",
      contentType: "text/plain",
    });
    const protectedURL = new URL(protectedDownload.downloadURL);
    protectedURL.searchParams.set("download", "1");
    env.RELAY_FILES.getDelayMs = 200;
    const activeDownload = worker.fetch(new Request(protectedURL.toString()), env);
    const reservationDeadline = Date.now() + 1_000;
    while (env.RELAY_DB.fileDownloadReservations.size === 0 && Date.now() < reservationDeadline) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    assert.ok(env.RELAY_DB.fileDownloadReservations.size > 0, "download must hold a cleanup reservation while R2 is reading");
    const clearDuringDownload = await request("/v1/logs?scope=fileAccess", {
      method: "DELETE",
      role: "worker",
    });
    assert.equal(clearDuringDownload.status, 409, "active downloads must block file cleanup");
    assert.equal((await activeDownload).status, 200);
    env.RELAY_FILES.getDelayMs = 0;
    assert.equal(env.RELAY_DB.fileDownloadReservations.size, 0, "successful delivery must finalize the cleanup guard");
  }
  {
    const missing = await createUploadedFile({
      itemID: "file-missing-read",
      itemTitle: "missing-read.txt",
      body: "missing",
      contentType: "text/plain",
    });
    const row = env.RELAY_DB.fileAccessRequests.get(missing.id);
    const quota = env.RELAY_DB.fileAccessQuota.get(new Date().toISOString().slice(0, 10));
    const quotaBefore = quota.download_count;
    const storedObject = env.RELAY_FILES.objects.get(row.object_key);
    env.RELAY_FILES.objects.delete(row.object_key);
    const missingURL = new URL(missing.downloadURL);
    missingURL.searchParams.set("download", "1");
    assert.equal((await worker.fetch(new Request(missingURL.toString()), env)).status, 404);
    assert.equal(row.download_count, 0, "missing R2 objects must release the per-link reservation");
    assert.equal(quota.download_count, quotaBefore, "missing R2 objects must release daily quota");
    assert.equal(env.RELAY_DB.fileDownloadReservations.size, 0);
    env.RELAY_FILES.objects.set(row.object_key, storedObject);
    assert.equal((await worker.fetch(new Request(missingURL.toString()), env)).status, 200);
  }
  {
    const failed = await createUploadedFile({
      itemID: "file-failed-read",
      itemTitle: "failed-read.txt",
      body: "failed",
      contentType: "text/plain",
    });
    const row = env.RELAY_DB.fileAccessRequests.get(failed.id);
    const quota = env.RELAY_DB.fileAccessQuota.get(new Date().toISOString().slice(0, 10));
    const quotaBefore = quota.download_count;
    env.RELAY_FILES.failGets.add(row.object_key);
    const failedURL = new URL(failed.downloadURL);
    failedURL.searchParams.set("download", "1");
    const originalConsoleError = console.error;
    console.error = () => {};
    try {
      assert.equal((await worker.fetch(new Request(failedURL.toString()), env)).status, 500);
    } finally {
      console.error = originalConsoleError;
    }
    assert.equal(row.download_count, 0, "R2 exceptions must release the per-link reservation");
    assert.equal(quota.download_count, quotaBefore, "R2 exceptions must release daily quota");
    assert.equal(env.RELAY_DB.fileDownloadReservations.size, 0);
    env.RELAY_FILES.failGets.delete(row.object_key);
    assert.equal((await worker.fetch(new Request(failedURL.toString()), env)).status, 200);
  }
  {
    const stale = await createUploadedFile({
      itemID: "file-stale-download",
      itemTitle: "stale-download.txt",
      body: "stale",
      contentType: "text/plain",
    });
    const row = env.RELAY_DB.fileAccessRequests.get(stale.id);
    const quotaDate = new Date().toISOString().slice(0, 10);
    const quota = env.RELAY_DB.fileAccessQuota.get(quotaDate);
    const quotaBefore = quota.download_count;
    const oldTimestamp = new Date(Date.now() - 11 * 60 * 1000).toISOString();
    const token = crypto.randomUUID();
    row.download_count += 1;
    quota.download_count += 1;
    env.RELAY_DB.fileDownloadReservations.set(token, {
      token,
      request_id: stale.id,
      quota_date: quotaDate,
      log_id: crypto.randomUUID(),
      log_created_at: oldTimestamp,
      created_at: oldTimestamp,
    });
    await runScheduledCleanup();
    await runScheduledCleanup();
    assert.equal(row.download_count, 0, "stale recovery must release the link exactly once");
    assert.equal(quota.download_count, quotaBefore, "stale recovery must release daily quota exactly once");
    assert.equal(env.RELAY_DB.fileDownloadReservations.size, 0);
  }
  {
    const interrupted = await expectJSON("/v1/file-access", {
      itemID: "file-interrupted-upload-cleanup",
      itemKind: "file",
      itemTitle: "interrupted.bin",
    }, { method: "POST", status: 201 });
    const row = env.RELAY_DB.fileAccessRequests.get(interrupted.id);
    const quotaDate = new Date().toISOString().slice(0, 10);
    const quota = env.RELAY_DB.fileAccessQuota.get(quotaDate);
    const baselineCount = quota.upload_count;
    const baselineBytes = quota.upload_bytes;
    const objectKey = `file-access/${interrupted.id}/55555555-5555-4555-8555-555555555555-interrupted.bin`;
    Object.assign(row, {
      upload_claim: "66666666-6666-4666-8666-666666666666",
      upload_claimed_at: new Date(Date.now() - 16 * 60 * 1000).toISOString(),
      pending_object_key: objectKey,
      reserved_upload_bytes: 11,
      reserved_upload_quota_date: quotaDate,
    });
    quota.upload_count += 1;
    quota.upload_bytes += 11;
    env.RELAY_FILES.objects.set(objectKey, { body: "interrupted", httpMetadata: {} });
    env.RELAY_FILES.failDeletes.add(objectKey);
    const originalConsoleError = console.error;
    console.error = () => {};
    try {
      await runScheduledCleanup();
    } finally {
      console.error = originalConsoleError;
    }
    assert.equal(row.pending_object_key, objectKey, "failed R2 deletion must retain the tombstone");
    assert.equal(quota.upload_count, baselineCount + 1, "failed cleanup must retain reserved quota");
    row.upload_claimed_at = new Date(Date.now() - 16 * 60 * 1000).toISOString();
    env.RELAY_FILES.failDeletes.delete(objectKey);
    await runScheduledCleanup();
    assert.equal(env.RELAY_FILES.objects.has(objectKey), false);
    assert.equal(row.pending_object_key, null);
    assert.equal(row.reserved_upload_bytes, 0);
    assert.equal(quota.upload_count, baselineCount);
    assert.equal(quota.upload_bytes, baselineBytes);
    env.RELAY_DB.fileAccessRequests.delete(interrupted.id);
  }
  {
    const cleanup = await createUploadedFile({
      itemID: "file-cleanup-retry",
      itemTitle: "cleanup.txt",
      body: "cleanup",
      contentType: "text/plain",
    });
    const row = env.RELAY_DB.fileAccessRequests.get(cleanup.id);
    row.expires_at = new Date(Date.now() - 1_000).toISOString();
    env.RELAY_FILES.failDeletes.add(row.object_key);
    const originalConsoleError = console.error;
    console.error = () => {};
    try {
      await runScheduledCleanup();
    } finally {
      console.error = originalConsoleError;
    }
    assert.ok(env.RELAY_DB.fileAccessRequests.has(cleanup.id), "failed object delete must preserve row");
    env.RELAY_FILES.failDeletes.delete(row.object_key);
    await runScheduledCleanup();
    assert.equal(
      env.RELAY_DB.fileAccessRequests.has(cleanup.id),
      false,
      JSON.stringify(env.RELAY_DB.fileAccessRequests.get(cleanup.id) || null)
    );
  }
  {
    const pdf = await createUploadedFile({
      itemID: "file-pdf",
      itemTitle: "강의자료.pdf",
      body: "%PDF-1.4\n",
      contentType: "application/octet-stream",
    });
    const previewPageURL = new URL(pdf.downloadURL);
    previewPageURL.searchParams.set("preview", "1");
    const previewPageResponse = await worker.fetch(new Request(previewPageURL.toString()), env);
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
    assert.match(previewPageHTML, /브라우저의 내장 PDF 도구/);
    assert.match(previewPageHTML, /data-pdf-preview/);
    assert.doesNotMatch(previewPageHTML, /pdfjs-dist|pdfjsLib|getDocument/);
    assert.match(previewPageHTML, /data-status/);

    const previewURL = new URL(pdf.downloadURL);
    previewURL.searchParams.set("preview", "1");
    previewURL.searchParams.set("raw", "1");
    const previewResponse = await worker.fetch(new Request(previewURL.toString()), env);
    assert.equal(previewResponse.status, 200);
    assert.match(previewResponse.headers.get("Content-Type"), /^application\/pdf/);
    assert.match(previewResponse.headers.get("Content-Disposition"), /^inline;/);
  }
  {
    const hostileTitle = '<img src=x onerror="globalThis.__klmsXSS=true">.txt';
    const hostile = await createUploadedFile({
      itemID: "file-hostile-title",
      itemTitle: hostileTitle,
      body: "escaped",
      contentType: "text/plain",
    });
    const pageResponse = await worker.fetch(new Request(hostile.downloadURL), env);
    assert.equal(pageResponse.status, 200);
    const pageHTML = await pageResponse.text();
    assert.match(pageHTML, /&lt;img src=x onerror=&quot;globalThis\.__klmsXSS=true&quot;&gt;\.txt/);
    assert.doesNotMatch(pageHTML, /<img src=x onerror=/);
  }
  {
    const png = await createUploadedFile({
      itemID: "file-png",
      itemTitle: "그림.png",
      body: "not really a png",
      contentType: "application/octet-stream",
    });
    const previewURL = new URL(png.downloadURL);
    previewURL.searchParams.set("preview", "1");
    previewURL.searchParams.set("raw", "1");
    const previewResponse = await worker.fetch(new Request(previewURL.toString()), env);
    assert.equal(previewResponse.status, 200);
    assert.match(previewResponse.headers.get("Content-Type"), /^image\/png/);
    assert.match(previewResponse.headers.get("Content-Disposition"), /^inline;/);
  }
  {
    const largeText = "x".repeat(600 * 1024);
    const large = await createUploadedFile({
      itemID: "file-large-text",
      itemTitle: "큰 로그.txt",
      body: largeText,
      contentType: "text/plain",
    });
    const pageResponse = await worker.fetch(new Request(large.downloadURL), env);
    assert.equal(pageResponse.status, 200);
    const pageHTML = await pageResponse.text();
    assert.match(pageHTML, /미리보기 불가/);
    assert.doesNotMatch(pageHTML, /preview=1/);
    assert.match(pageHTML, /미리보기를 생략/);
  }
  {
    const beforeClearRequestLog = await expectJSON("/v1/request-log/recent");
    assert.ok(beforeClearRequestLog.entries.length > 0);
    const beforeClearFileRequests = await expectJSON("/v1/file-access/recent");
    assert.ok(beforeClearFileRequests.requests.length > 0);

    const commandClear = await expectJSON("/v1/logs?scope=command", undefined, { method: "DELETE", role: "worker" });
    assert.ok(commandClear.commands > 0);
    assert.equal(commandClear.requestLogEntries, 0);
    assert.equal(commandClear.fileAccessRequests, 0);
    const recentCommandsAfterCommandClear = await expectJSON("/v1/commands/recent");
    assert.equal(recentCommandsAfterCommandClear.commands.length, 0);
    assert.equal(recentCommandsAfterCommandClear.latestCommand, null);
    const fileRequestsAfterCommandClear = await expectJSON("/v1/file-access/recent");
    assert.ok(fileRequestsAfterCommandClear.requests.length > 0);

    const requestLogClear = await expectJSON("/v1/logs?scope=requestLog", undefined, { method: "DELETE", role: "worker" });
    assert.ok(requestLogClear.requestLogEntries > 0);
    assert.equal(requestLogClear.fileAccessRequests, 0);
    const requestLogAfterClear = await expectJSON("/v1/request-log/recent");
    assert.equal(requestLogAfterClear.entries.length, 0);
    const fileRequestsAfterRequestLogClear = await expectJSON("/v1/file-access/recent");
    assert.ok(fileRequestsAfterRequestLogClear.requests.length > 0);

    const failedDeleteRow = Array.from(env.RELAY_DB.fileAccessRequests.values())
      .find((row) => row.object_key && row.status === "completed");
    assert.ok(failedDeleteRow);
    env.RELAY_FILES.failDeletes.add(failedDeleteRow.object_key);
    const originalConsoleError = console.error;
    console.error = () => {};
    let fileAccessClear;
    try {
      fileAccessClear = await expectJSON("/v1/logs?scope=fileAccess", undefined, { method: "DELETE", role: "worker" });
    } finally {
      console.error = originalConsoleError;
    }
    assert.ok(fileAccessClear.fileAccessRequests > 0);
    assert.equal(fileAccessClear.requestLogEntries, 0);
    const fileRequestsAfterFileAccessClear = await expectJSON("/v1/file-access/recent");
    assert.equal(fileRequestsAfterFileAccessClear.requests.length, 1);
    assert.equal(fileRequestsAfterFileAccessClear.requests[0].id, failedDeleteRow.id);
    env.RELAY_FILES.failDeletes.delete(failedDeleteRow.object_key);
    const fileAccessRetry = await expectJSON("/v1/logs?scope=fileAccess", undefined, { method: "DELETE", role: "worker" });
    assert.equal(fileAccessRetry.fileAccessRequests, 1);
    assert.equal((await expectJSON("/v1/file-access/recent")).requests.length, 0);

    const clear = await expectJSON("/v1/logs", undefined, { method: "DELETE", role: "worker" });
    assert.equal(clear.commands, 0);
    assert.equal(clear.itemActions, 0);
    assert.equal(clear.fileAccessRequests, 0);
    assert.equal(clear.requestLogEntries, 0);

    const recentCommands = await expectJSON("/v1/commands/recent");
    assert.equal(recentCommands.commands.length, 0);
    assert.equal(recentCommands.latestCommand, null);
    const recentFileRequests = await expectJSON("/v1/file-access/recent");
    assert.equal(recentFileRequests.requests.length, 0);
    const recentRequestLog = await expectJSON("/v1/request-log/recent");
    assert.equal(recentRequestLog.entries.length, 0);
    const syncDataAfterClear = await expectJSON("/v1/sync-data?kind=exam&limit=10");
    assert.equal(syncDataAfterClear.items.length, 1);
  }

  {
    const displayCommand = await expectJSON("/v1/commands", {
      kind: "fullSync",
      status: "pending",
      summary: { assignments: 1, phase: "pending" },
    }, { method: "POST", status: 201 });
    await expectJSON(`/v1/commands/${displayCommand.id}`, {
      ...displayCommand,
      status: "completed",
      updatedAt: new Date().toISOString(),
      summary: { assignments: 1, phase: "completed" },
    }, { method: "PUT", role: "worker" });
    const displayItemAction = await expectJSON("/v1/item-actions", {
      action: "examIgnore",
      itemID: "exam-1",
      itemKind: "exam",
      itemTitle: "기말고사",
    }, { method: "POST", status: 201 });
    await expectJSON(`/v1/item-actions/${displayItemAction.id}`, {
      ...displayItemAction,
      status: "completed",
      updatedAt: new Date().toISOString(),
      message: "hidden",
    }, { method: "PUT", role: "worker" });
    const displaySettingAction = await expectJSON("/v1/setting-actions", {
      key: "FILE_REFRESH_MODE",
      title: "파일 탐색 모드",
      value: "auto",
    }, { method: "POST", status: 201 });
    await expectJSON(`/v1/setting-actions/${displaySettingAction.id}`, {
      ...displaySettingAction,
      status: "completed",
      updatedAt: new Date().toISOString(),
      message: "saved",
    }, { method: "PUT", role: "worker" });
    const beforeDisplayClearCommands = await expectJSON("/v1/commands/recent");
    assert.equal(beforeDisplayClearCommands.commands.length, 1);
    const beforeDisplayClearRequests = await expectJSON("/v1/request-log/recent");
    assert.ok(beforeDisplayClearRequests.entries.length > 0);
    const beforeDisplayClearItemActions = await expectJSON("/v1/item-actions/recent");
    assert.equal(beforeDisplayClearItemActions.actions.length, 1);
    const beforeDisplayClearSettingActions = await expectJSON("/v1/setting-actions/recent");
    assert.equal(beforeDisplayClearSettingActions.actions.length, 1);

    const displayClear = await expectJSON("/v1/logs/display", undefined, { method: "DELETE" });
    assert.equal(displayClear.commands, 1);
    assert.equal(displayClear.itemActions, 1);
    assert.equal(displayClear.settingActions, 1);
    assert.ok(displayClear.requestLogEntries > 0);
    const afterDisplayClearCommands = await expectJSON("/v1/commands/recent");
    assert.equal(afterDisplayClearCommands.commands.length, 0);
    assert.equal(afterDisplayClearCommands.latestCommand, null);
    const afterDisplayClearRequests = await expectJSON("/v1/request-log/recent");
    assert.equal(afterDisplayClearRequests.entries.length, 0);
    const afterDisplayClearItemActions = await expectJSON("/v1/item-actions/recent");
    assert.equal(afterDisplayClearItemActions.actions.length, 0);
    const afterDisplayClearSettingActions = await expectJSON("/v1/setting-actions/recent");
    assert.equal(afterDisplayClearSettingActions.actions.length, 0);
  }

  {
    const slowClearFile = await createUploadedFile({
      itemID: "file-slow-log-clear",
      itemTitle: "slow-clear.txt",
      body: "slow-clear",
      contentType: "text/plain",
    });
    const beforeTypoClear = env.RELAY_DB.fileAccessRequests.size;
    const typoClear = await request("/v1/logs?scope=fileAcess", {
      method: "DELETE",
      role: "worker",
    });
    assert.equal(typoClear.status, 400);
    assert.equal(env.RELAY_DB.fileAccessRequests.size, beforeTypoClear, "invalid clear scope must preserve logs");
    env.RELAY_FILES.deleteDelayMs = 300;
    const clearPromise = request("/v1/logs?scope=all", {
      method: "DELETE",
      role: "worker",
    });
    const claimDeadline = Date.now() + 1_000;
    while (!env.RELAY_DB.fileAccessRequests.get(slowClearFile.id)?.upload_claim && Date.now() < claimDeadline) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    assert.ok(env.RELAY_DB.fileAccessRequests.get(slowClearFile.id)?.upload_claim);
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
    const downloadDuringClear = await worker.fetch(new Request(downloadDuringClearURL), env);
    assert.equal(downloadDuringClear.status, 409);
    const statusStartedAt = Date.now();
    const statusDuringClear = await request("/v1/status");
    const statusElapsedMs = Date.now() - statusStartedAt;
    assert.equal(statusDuringClear.status, 200);
    assert.ok(statusElapsedMs < 200, `status was blocked by slow object deletion for ${statusElapsedMs}ms`);
    const clearResponse = await clearPromise;
    env.RELAY_FILES.deleteDelayMs = 0;
    assert.equal(clearResponse.status, 200);
    assert.equal(env.RELAY_DB.fileAccessRequests.has(slowClearFile.id), false);
  }

  {
    const protectedPending = await expectJSON("/v1/item-actions", {
      action: "calendarVerify",
      itemID: "trim-protected-pending",
      itemKind: "calendar",
      itemTitle: "trim protected pending",
    }, { method: "POST", status: 201 });
    assert.equal(protectedPending.status, "pending");
    for (let index = 0; index < 205; index += 1) {
      await expectJSON("/v1/item-actions", {
        action: "noticeRead",
        itemID: `trim-terminal-${index}`,
        itemKind: "notice",
        itemTitle: `trim terminal ${index}`,
      }, { method: "POST", status: 201 });
    }
    assert.equal((await expectJSON(`/v1/item-actions/${protectedPending.id}`)).status, "pending");
    const pendingAfterTrim = await expectJSON("/v1/item-actions/pending", undefined, { role: "worker" });
    assert.equal(pendingAfterTrim.actions.some((item) => item.id === protectedPending.id), true);
    assert.equal(env.RELAY_DB.itemActions.size, 200);

    const activeToCreate = 200 - pendingAfterTrim.actions.length;
    for (let index = 0; index < activeToCreate; index += 1) {
      await expectJSON("/v1/item-actions", {
        action: "calendarVerify",
        itemID: `active-cap-${index}`,
        itemKind: "calendar",
        itemTitle: `active cap ${index}`,
      }, { method: "POST", status: 201 });
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
    assert.equal((await expectJSON(`/v1/item-actions/${protectedPending.id}`)).status, "pending");
  }

  console.log("cloudflare worker smoke ok");
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

async function createUploadedFile({ itemID, itemTitle, body, contentType }) {
  const fileRequest = await expectJSON("/v1/file-access", {
    itemID,
    itemKind: "file",
    itemTitle,
  }, { method: "POST", status: 201 });
  const uploadResponse = await request(`/v1/file-access/${fileRequest.id}/upload`, {
    method: "PUT",
    role: "worker",
    rawBody: body,
    headers: {
      "Content-Type": contentType,
      "Content-Length": String(Buffer.byteLength(body)),
      "X-KLMS-Filename": encodeURIComponent(itemTitle),
    },
  });
  assert.equal(uploadResponse.status, 200);
  return uploadResponse.json();
}

async function expectJSON(path, body, options = {}) {
  const response = await request(path, { ...options, body });
  assert.equal(response.status, options.status || 200);
  return response.json();
}

async function runScheduledCleanup() {
  let scheduled = null;
  await worker.scheduled({}, env, {
    waitUntil(promise) {
      scheduled = promise;
    },
  });
  assert.ok(scheduled);
  await scheduled;
}

function request(path, {
  method = "GET",
  body,
  rawBody,
  headers: extraHeaders = {},
  auth = true,
  role = "client",
  ctx,
  environment = env,
} = {}) {
  const headers = new Headers({ Accept: "application/json" });
  for (const [key, value] of Object.entries(extraHeaders)) {
    headers.set(key, value);
  }
  if (auth) {
    headers.set("Authorization", `Bearer ${role === "worker" ? workerToken : clientToken}`);
  }
  if (body != null && method !== "GET") {
    headers.set("Content-Type", "application/json");
  }
  return worker.fetch(new Request(`https://relay.example${path}`, {
    method,
    headers,
    body: rawBody != null ? rawBody : body != null && method !== "GET" ? JSON.stringify(body) : undefined,
  }), environment, ctx);
}

class FakeD1 {
  constructor() {
    this.meta = new Map();
    this.commands = new Map();
    this.itemActions = new Map();
    this.fileAccessRequests = new Map();
    this.fileAccessQuota = new Map();
    this.fileDownloadReservations = new Map();
    this.lastChanges = 0;
    this.batchTail = Promise.resolve();
    this.schemaComplete = true;
    this.prepareCount = 0;
  }

  async exec() {
    return { count: 0, duration: 0 };
  }

  prepare(sql) {
    this.prepareCount += 1;
    return new FakeStatement(this, sql);
  }

  async batch(statements) {
    let release;
    const previous = this.batchTail;
    this.batchTail = new Promise((resolve) => { release = resolve; });
    await previous;
    const snapshot = {
      meta: structuredClone(this.meta),
      commands: structuredClone(this.commands),
      itemActions: structuredClone(this.itemActions),
      fileAccessRequests: structuredClone(this.fileAccessRequests),
      fileAccessQuota: structuredClone(this.fileAccessQuota),
      fileDownloadReservations: structuredClone(this.fileDownloadReservations),
    };
    try {
      const results = [];
      for (const statement of statements) {
        const result = await statement.run();
        this.lastChanges = Number(result?.meta?.changes || 0);
        results.push(result);
      }
      return results;
    } catch (error) {
      Object.assign(this, snapshot);
      throw error;
    } finally {
      release();
    }
  }
}

class FakeStatement {
  constructor(db, sql, args = []) {
    this.db = db;
    this.sql = sql.replace(/\s+/g, " ").trim();
    this.args = args;
  }

  bind(...args) {
    return new FakeStatement(this.db, this.sql, args);
  }

  async first() {
    if (this.sql.startsWith("SELECT value FROM meta")) {
      const value = this.db.meta.get(this.args[0]);
      return value == null ? null : { value };
    }
    if (this.sql.includes("FROM item_actions") && this.sql.includes("WHERE idempotency_key = ?")) {
      return Array.from(this.db.itemActions.values()).find((row) => row.idempotency_key === this.args[0]) || null;
    }
    if (this.sql.startsWith("SELECT token") && this.sql.includes("FROM file_download_reservations")) {
      if (this.sql.includes("WHERE token = ?")) {
        const row = this.db.fileDownloadReservations.get(this.args[0]);
        return row && (!this.args[1] || row.request_id === this.args[1]) ? row : null;
      }
      return this.db.fileDownloadReservations.values().next().value || null;
    }
    if (this.sql.includes("FROM file_access_requests")) {
      return this.db.fileAccessRequests.get(this.args[0]) || null;
    }
    if (this.sql.includes("FROM file_access_quota")) {
      return this.db.fileAccessQuota.get(this.args[0]) || null;
    }
    throw new Error(`Unsupported first SQL: ${this.sql}`);
  }

  async all() {
    if (this.sql.includes("FROM sqlite_master")) {
      if (this.sql.includes("type = 'index'")) {
        return { results: ["commands_one_active_idx", "item_actions_idempotency_key_idx"].map((name) => ({ name })) };
      }
      const tables = [
        "meta", "commands", "item_actions", "file_access_requests", "file_access_quota",
        "file_download_reservations",
      ];
      return { results: (this.db.schemaComplete ? tables : tables.filter((name) => name !== "file_access_quota")).map((name) => ({ name })) };
    }
    if (this.sql.startsWith("PRAGMA table_info(file_access_requests)")) {
      return { results: ["upload_claim", "upload_claimed_at", "pending_object_key", "reserved_upload_bytes", "reserved_upload_quota_date"].map((name) => ({ name })) };
    }
    if (this.sql.startsWith("PRAGMA table_info(item_actions)")) {
      return { results: [{ name: "idempotency_key" }] };
    }
    if (this.sql.startsWith("SELECT") && this.sql.includes("FROM commands")) {
      return { results: sortedRows(this.db.commands, this.args[0] || 200) };
    }
    if (this.sql.startsWith("SELECT") && this.sql.includes("FROM item_actions")) {
      return { results: sortedItemActionRows(this.db.itemActions, this.args[0] || 400) };
    }
    if (this.sql.startsWith("SELECT token") && this.sql.includes("FROM file_download_reservations")) {
      const [staleBefore, limit] = this.args;
      return {
        results: Array.from(this.db.fileDownloadReservations.values())
          .filter((row) => !staleBefore || row.created_at <= staleBefore)
          .sort((lhs, rhs) => lhs.created_at.localeCompare(rhs.created_at))
          .slice(0, limit || 100),
      };
    }
    if (this.sql.includes("FROM file_access_requests")) {
      if (this.sql.includes("WHERE id IN")) {
        const ids = new Set(this.args);
        return {
          results: Array.from(this.db.fileAccessRequests.values()).filter((row) => ids.has(row.id)),
        };
      }
      if (this.sql.includes("ORDER BY upload_claimed_at ASC")) {
        const [staleBefore, limit] = this.args;
        return {
          results: Array.from(this.db.fileAccessRequests.values())
            .filter((row) => (
              !row.object_key
              && row.pending_object_key
              && Number(row.reserved_upload_bytes || 0) > 0
              && row.reserved_upload_quota_date
              && (!row.upload_claimed_at || row.upload_claimed_at <= staleBefore)
            ))
            .slice(0, limit),
        };
      }
      if (this.sql.includes("WHERE status IN")) {
        const limit = this.args.at(-1) || 100;
        const statuses = new Set(this.args.slice(0, -1));
        return {
          results: Array.from(this.db.fileAccessRequests.values())
            .filter((row) => statuses.has(row.status))
            .sort((lhs, rhs) => Date.parse(rhs.updated_at) - Date.parse(lhs.updated_at))
            .slice(0, limit),
        };
      }
      if (this.sql.includes("expires_at IS NOT NULL")) {
        const cutoff = this.args[0];
        return {
          results: Array.from(this.db.fileAccessRequests.values())
            .filter((row) => row.expires_at && row.expires_at <= cutoff),
        };
      }
      return { results: sortedRows(this.db.fileAccessRequests, this.args[0] || 100) };
    }
    throw new Error(`Unsupported all SQL: ${this.sql}`);
  }

  async run() {
    if (this.sql.startsWith("SELECT key, value FROM meta")) {
      return {
        success: true,
        meta: { changes: 0 },
        results: Array.from(this.db.meta, ([key, value]) => ({ key, value })),
      };
    }
    if (this.sql.startsWith("SELECT") && this.sql.includes("FROM commands")) {
      return { success: true, meta: { changes: 0 }, results: sortedRows(this.db.commands, this.args[0] || 200) };
    }
    if (this.sql.startsWith("SELECT") && this.sql.includes("FROM item_actions")) {
      return { success: true, meta: { changes: 0 }, results: sortedItemActionRows(this.db.itemActions, this.args[0] || 400) };
    }
    if (this.sql.startsWith("INSERT INTO meta") && this.sql.includes("relay-integrity-guard")) {
      if (this.db.lastChanges !== 1) throw new Error("NOT NULL constraint failed: meta.value");
      return { success: true, meta: { changes: 0 } };
    }
    if (this.sql.startsWith("INSERT INTO meta") && this.sql.includes("relayRevision")) {
      const next = Number(this.db.meta.get("relayRevision") || 0) + 1;
      this.db.meta.set("relayRevision", String(next));
      return { success: true, meta: { changes: 1 }, results: [{ value: String(next) }] };
    }
    if (this.sql.startsWith("INSERT INTO meta")) {
      this.db.meta.set(this.args[0], String(this.args[1]));
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("INSERT INTO commands")) {
      const [
        id,
        kind,
        status,
        createdAt,
        updatedAt,
        lastExitCode,
        loginRequired,
        summaryJSON,
        optionsJSON,
      ] = this.args;
      if (["pending", "running"].includes(status)) {
        const active = Array.from(this.db.commands.values()).find((row) => row.id !== id && ["pending", "running"].includes(row.status));
        if (active) throw new Error("UNIQUE constraint failed: commands_one_active_idx");
      }
      this.db.commands.set(id, {
        id,
        kind,
        status,
        created_at: createdAt,
        updated_at: updatedAt,
        last_exit_code: lastExitCode,
        login_required: loginRequired,
        summary_json: summaryJSON,
        options_json: optionsJSON,
      });
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("DELETE FROM commands")) {
      if (this.sql.includes("status NOT IN")) {
        deleteTerminalRows(this.db.commands);
      } else if (this.args.length === 0) {
        this.db.commands.clear();
      } else {
        trimRows(this.db.commands, this.args[0]);
      }
      return { success: true };
    }
    if (this.sql.startsWith("INSERT INTO item_actions")) {
      const [
        id,
        idempotencyKey,
        action,
        itemID,
        itemKind,
        itemTitle,
        status,
        createdAt,
        updatedAt,
        message,
      ] = this.args;
      const duplicate = Array.from(this.db.itemActions.values()).find(
        (row) => row.id !== id && idempotencyKey && row.idempotency_key === idempotencyKey
      );
      if (duplicate) throw new Error("UNIQUE constraint failed: item_actions.idempotency_key");
      this.db.itemActions.set(id, {
        id,
        idempotency_key: idempotencyKey,
        action,
        item_id: itemID,
        item_kind: itemKind,
        item_title: itemTitle,
        status,
        created_at: createdAt,
        updated_at: updatedAt,
        message,
      });
      return { success: true };
    }
    if (this.sql.startsWith("DELETE FROM item_actions")) {
      if (this.sql.includes("id NOT IN")) {
        trimItemActionRows(this.db.itemActions, this.args[0]);
      } else if (this.sql.includes("status NOT IN")) {
        deleteTerminalRows(this.db.itemActions);
      } else if (this.args.length === 0) {
        this.db.itemActions.clear();
      } else {
        trimRows(this.db.itemActions, this.args[0]);
      }
      return { success: true };
    }
    if (this.sql.startsWith("INSERT INTO file_access_requests")) {
      const [
        id,
        itemID,
        itemKind,
        itemTitle,
        status,
        createdAt,
        updatedAt,
        message,
        objectKey,
        downloadTicket,
        expiresAt,
        contentType,
        sizeBytes,
        downloadCount,
      ] = this.args;
      this.db.fileAccessRequests.set(id, {
        id,
        item_id: itemID,
        item_kind: itemKind,
        item_title: itemTitle,
        status,
        created_at: createdAt,
        updated_at: updatedAt,
        message,
        object_key: objectKey,
        download_ticket: downloadTicket,
        expires_at: expiresAt,
        content_type: contentType,
        size_bytes: sizeBytes,
        download_count: downloadCount,
        upload_claim: null,
        upload_claimed_at: null,
        pending_object_key: null,
        reserved_upload_bytes: 0,
        reserved_upload_quota_date: null,
      });
      return { success: true };
    }
    if (this.sql.startsWith("INSERT INTO file_download_reservations")) {
      const [token, requestID, quotaDate, logID, logCreatedAt, createdAt] = this.args;
      if (this.db.fileDownloadReservations.has(token)) {
        throw new Error("UNIQUE constraint failed: file_download_reservations.token");
      }
      if (!this.db.fileAccessRequests.has(requestID)) {
        throw new Error("FOREIGN KEY constraint failed");
      }
      this.db.fileDownloadReservations.set(token, {
        token,
        request_id: requestID,
        quota_date: quotaDate,
        log_id: logID,
        log_created_at: logCreatedAt,
        created_at: createdAt,
      });
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("DELETE FROM file_download_reservations")) {
      const row = this.db.fileDownloadReservations.get(this.args[0]);
      if (!row || (this.args[1] && row.request_id !== this.args[1])) {
        return { success: true, meta: { changes: 0 } };
      }
      this.db.fileDownloadReservations.delete(this.args[0]);
      return { success: true, meta: { changes: 1 } };
    }
    if (
      this.sql.startsWith("UPDATE file_access_requests")
      && this.sql.includes("SET upload_claim = ?")
      && this.sql.includes("upload_claimed_at = ?, pending_object_key = ?")
    ) {
      const [claim, claimedAt, pendingObjectKey, reservedBytes, quotaDate, id, staleBefore] = this.args;
      const row = this.db.fileAccessRequests.get(id);
      const leaseIsAvailable = !row?.upload_claim
        || !row?.upload_claimed_at
        || row.upload_claimed_at <= staleBefore;
      if (
        !row
        || row.object_key
        || row.pending_object_key
        || Number(row.reserved_upload_bytes || 0) !== 0
        || row.reserved_upload_quota_date
        || !leaseIsAvailable
        || !["pending", "running"].includes(row.status)
      ) return { success: true, meta: { changes: 0 } };
      Object.assign(row, {
        upload_claim: claim,
        upload_claimed_at: claimedAt,
        pending_object_key: pendingObjectKey,
        reserved_upload_bytes: Number(reservedBytes),
        reserved_upload_quota_date: quotaDate,
      });
      return { success: true, meta: { changes: 1 } };
    }
    if (
      this.sql.startsWith("UPDATE file_access_requests")
      && this.sql.includes("SET upload_claim = ?")
      && this.sql.includes("AND upload_claim IS ?")
      && this.sql.includes("pending_object_key = ?")
    ) {
      const [claim, claimedAt, id, previousClaim, pendingObjectKey, reservedBytes, quotaDate, staleBefore] = this.args;
      const row = this.db.fileAccessRequests.get(id);
      if (
        !row
        || row.object_key
        || row.upload_claim !== previousClaim
        || row.pending_object_key !== pendingObjectKey
        || Number(row.reserved_upload_bytes || 0) !== Number(reservedBytes)
        || row.reserved_upload_quota_date !== quotaDate
        || (row.upload_claimed_at && row.upload_claimed_at > staleBefore)
      ) return { success: true, meta: { changes: 0 } };
      row.upload_claim = claim;
      row.upload_claimed_at = claimedAt;
      return { success: true, meta: { changes: 1 } };
    }
    if (
      this.sql.startsWith("UPDATE file_access_requests")
      && this.sql.includes("SET upload_claim = ?")
      && this.sql.includes("expires_at IS NOT NULL")
    ) {
      const [claim, claimedAt, id, status, objectKey, updatedAt, expiresBefore, staleBefore] = this.args;
      const row = this.db.fileAccessRequests.get(id);
      const leaseIsAvailable = !row?.upload_claim
        || !row?.upload_claimed_at
        || row.upload_claimed_at <= staleBefore;
      if (
        !row
        || row.status !== status
        || row.object_key !== objectKey
        || row.updated_at !== updatedAt
        || !row.expires_at
        || row.expires_at > expiresBefore
        || (this.sql.includes("file_download_reservations") && hasDownloadReservation(this.db, id))
        || !leaseIsAvailable
      ) return { success: true, meta: { changes: 0 } };
      row.upload_claim = claim;
      row.upload_claimed_at = claimedAt;
      return { success: true, meta: { changes: 1 } };
    }
    if (
      this.sql.startsWith("UPDATE file_access_requests")
      && this.sql.includes("SET upload_claim = ?")
      && this.sql.includes("status NOT IN")
    ) {
      const [claim, claimedAt, id, objectKey, updatedAt, staleBefore] = this.args;
      const row = this.db.fileAccessRequests.get(id);
      const leaseIsAvailable = !row?.upload_claim
        || !row?.upload_claimed_at
        || row.upload_claimed_at <= staleBefore;
      if (
        !row
        || ["pending", "running"].includes(row.status)
        || row.object_key !== objectKey
        || row.updated_at !== updatedAt
        || (this.sql.includes("file_download_reservations") && hasDownloadReservation(this.db, id))
        || !leaseIsAvailable
      ) return { success: true, meta: { changes: 0 } };
      row.upload_claim = claim;
      row.upload_claimed_at = claimedAt;
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("UPDATE file_access_requests") && this.sql.includes("SET upload_claim = ?")) {
      const [claim, claimedAt, id, staleBefore] = this.args;
      const row = this.db.fileAccessRequests.get(id);
      const leaseIsAvailable = !row?.upload_claim
        || !row?.upload_claimed_at
        || row.upload_claimed_at <= staleBefore;
      if (!row || row.object_key || !leaseIsAvailable || !["pending", "running"].includes(row.status)) {
        return { success: true, meta: { changes: 0 } };
      }
      row.upload_claim = claim;
      row.upload_claimed_at = claimedAt;
      return { success: true, meta: { changes: 1 } };
    }
    if (
      this.sql.startsWith("UPDATE file_access_requests")
      && this.sql.includes("SET upload_claim = NULL")
      && this.sql.includes("pending_object_key = NULL")
    ) {
      const [id, claim, pendingObjectKey, reservedBytes, quotaDate] = this.args;
      const row = this.db.fileAccessRequests.get(id);
      if (
        !row
        || row.upload_claim !== claim
        || row.object_key
        || row.pending_object_key !== pendingObjectKey
        || Number(row.reserved_upload_bytes || 0) !== Number(reservedBytes)
        || row.reserved_upload_quota_date !== quotaDate
      ) return { success: true, meta: { changes: 0 } };
      Object.assign(row, {
        upload_claim: null,
        upload_claimed_at: null,
        pending_object_key: null,
        reserved_upload_bytes: 0,
        reserved_upload_quota_date: null,
      });
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("UPDATE file_access_requests") && this.sql.includes("SET upload_claim = NULL")) {
      const [id, claim] = this.args;
      const row = this.db.fileAccessRequests.get(id);
      if (
        !row
        || row.upload_claim !== claim
        || (this.sql.includes("object_key IS NULL") && row.object_key)
      ) return { success: true, meta: { changes: 0 } };
      row.upload_claim = null;
      row.upload_claimed_at = null;
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("UPDATE file_access_requests") && this.sql.includes("download_ticket = ?")) {
      const [
        status, updatedAt, message, objectKey, ticket, expiresAt, contentType, sizeBytes,
        id, claim, pendingObjectKey, reservedBytes, quotaDate,
      ] = this.args;
      const row = this.db.fileAccessRequests.get(id);
      if (
        !row
        || row.object_key
        || row.upload_claim !== claim
        || row.pending_object_key !== pendingObjectKey
        || Number(row.reserved_upload_bytes || 0) !== Number(reservedBytes)
        || row.reserved_upload_quota_date !== quotaDate
        || !["pending", "running"].includes(row.status)
      ) return { success: true, meta: { changes: 0 } };
      Object.assign(row, {
        status,
        updated_at: updatedAt,
        message,
        object_key: objectKey,
        download_ticket: ticket,
        expires_at: expiresAt,
        content_type: contentType,
        size_bytes: sizeBytes,
        download_count: 0,
        upload_claim: null,
        upload_claimed_at: null,
        pending_object_key: null,
        reserved_upload_bytes: 0,
        reserved_upload_quota_date: null,
      });
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("UPDATE file_access_requests") && this.sql.includes("download_count = download_count + 1")) {
      const [updatedAt, id] = this.args;
      const row = this.db.fileAccessRequests.get(id);
      if (!row || row.status !== "completed" || (this.sql.includes("upload_claim IS NULL") && row.upload_claim)) {
        return { success: true, meta: { changes: 0 } };
      }
      const quotaDate = String(updatedAt).slice(0, 10);
      const quota = this.db.fileAccessQuota.get(quotaDate);
      if (!quota || Number(row.download_count || 0) >= Number(quota.link_download_limit || 0)) {
        throw new Error("file download link quota reached");
      }
      if (!quota || quota.download_count >= quota.daily_download_limit) {
        throw new Error("daily file download quota reached");
      }
      row.download_count = Number(row.download_count || 0) + 1;
      row.updated_at = updatedAt;
      quota.download_count += 1;
      quota.updated_at = updatedAt;
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("UPDATE file_access_requests") && this.sql.includes("download_count = MAX")) {
      const row = this.db.fileAccessRequests.get(this.args[0]);
      if (!row) return { success: true, meta: { changes: 0 } };
      row.download_count = Math.max(0, Number(row.download_count || 0) - 1);
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("INSERT INTO file_access_quota")) {
      const quotaDate = this.args[0];
      if (!this.db.fileAccessQuota.has(quotaDate)) {
        if (this.args.length >= 6) {
          this.db.fileAccessQuota.set(quotaDate, {
            quota_date: quotaDate,
            upload_count: Number(this.args[1] || 0),
            upload_bytes: Number(this.args[2] || 0),
            download_count: Number(this.args[3] || 0),
            updated_at: this.args[4],
            daily_download_limit: Number(this.args[5] || 100),
            link_download_limit: 3,
          });
        } else {
          this.db.fileAccessQuota.set(quotaDate, {
            quota_date: quotaDate,
            upload_count: 0,
            upload_bytes: 0,
            download_count: 0,
            updated_at: this.args[1],
            daily_download_limit: Number(this.args[2] || 100),
            link_download_limit: Number(this.args[3] || 3),
          });
        }
      } else if (this.args.length >= 6) {
        const row = this.db.fileAccessQuota.get(quotaDate);
        row.upload_count = Number(this.args[1] || 0);
        row.upload_bytes = Number(this.args[2] || 0);
        row.download_count = Number(this.args[3] || 0);
        row.updated_at = this.args[4];
        row.daily_download_limit = Number(this.args[5] || 100);
      } else if (this.args.length >= 4) {
        const row = this.db.fileAccessQuota.get(quotaDate);
        row.daily_download_limit = Number(this.args[2] || 100);
        row.link_download_limit = Number(this.args[3] || 3);
      }
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("UPDATE file_access_quota") && this.sql.includes("upload_count = upload_count +")) {
      const [uploadCount, uploadBytes, downloadCount, updatedAt, quotaDate, uploadCheck, uploadLimit, bytesCheck, bytesLimit, downloadCheck, downloadLimit] = this.args;
      const row = this.db.fileAccessQuota.get(quotaDate);
      if (!row
          || row.upload_count + Number(uploadCheck) > Number(uploadLimit)
          || row.upload_bytes + Number(bytesCheck) > Number(bytesLimit)
          || row.download_count + Number(downloadCheck) > Number(downloadLimit)) {
        return { success: true, meta: { changes: 0 } };
      }
      row.upload_count += Number(uploadCount);
      row.upload_bytes += Number(uploadBytes);
      row.download_count += Number(downloadCount);
      row.updated_at = updatedAt;
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("UPDATE file_access_quota") && this.sql.includes("download_count = download_count + 1")) {
      const [updatedAt, quotaDate, limit] = this.args;
      const row = this.db.fileAccessQuota.get(quotaDate);
      if (!row || row.download_count >= Number(limit)) return { success: true, meta: { changes: 0 } };
      row.download_count += 1;
      row.updated_at = updatedAt;
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("UPDATE file_access_quota") && this.sql.includes("upload_count = MAX")) {
      const [uploadCount, uploadBytes, downloadCount, updatedAt, quotaDate] = this.args;
      const row = this.db.fileAccessQuota.get(quotaDate);
      if (!row) return { success: true, meta: { changes: 0 } };
      row.upload_count = Math.max(0, row.upload_count - Number(uploadCount));
      row.upload_bytes = Math.max(0, row.upload_bytes - Number(uploadBytes));
      row.download_count = Math.max(0, row.download_count - Number(downloadCount));
      row.updated_at = updatedAt;
      return { success: true, meta: { changes: 1 } };
    }
    if (this.sql.startsWith("DELETE FROM file_access_requests")) {
      if (this.sql.includes("upload_claim = ?")) {
        const expiredDeletion = this.sql.includes("expires_at IS NOT NULL");
        const [id, claim, statusOrObjectKey, objectKeyOrUpdatedAt, updatedAtOrExpiresBefore, expiresBefore] = this.args;
        const status = expiredDeletion ? statusOrObjectKey : null;
        const objectKey = expiredDeletion ? objectKeyOrUpdatedAt : statusOrObjectKey;
        const updatedAt = expiredDeletion ? updatedAtOrExpiresBefore : objectKeyOrUpdatedAt;
        const row = this.db.fileAccessRequests.get(id);
        if (
          !row
          || row.upload_claim !== claim
          || (expiredDeletion ? row.status !== status : ["pending", "running"].includes(row.status))
          || row.object_key !== objectKey
          || row.updated_at !== updatedAt
          || (expiredDeletion && (!row.expires_at || row.expires_at > expiresBefore))
          || (this.sql.includes("file_download_reservations") && hasDownloadReservation(this.db, id))
        ) return { success: true, meta: { changes: 0 } };
        this.db.fileAccessRequests.delete(id);
        return { success: true, meta: { changes: 1 } };
      }
      if (this.sql === "DELETE FROM file_access_requests WHERE id = ?") {
        const changed = this.db.fileAccessRequests.delete(this.args[0]) ? 1 : 0;
        return { success: true, meta: { changes: changed } };
      }
      if (this.sql.includes("expires_at IS NOT NULL")) {
        const cutoff = this.args[0];
        for (const [id, row] of this.db.fileAccessRequests.entries()) {
          if (row.expires_at && row.expires_at <= cutoff) {
            this.db.fileAccessRequests.delete(id);
          }
        }
      } else if (this.sql.includes("status NOT IN")) {
        for (const [id, row] of this.db.fileAccessRequests.entries()) {
          if (!["pending", "running"].includes(row.status) && !hasDownloadReservation(this.db, id)) {
            this.db.fileAccessRequests.delete(id);
          }
        }
      } else if (this.args.length === 0) {
        this.db.fileAccessRequests.clear();
      } else {
        trimRows(this.db.fileAccessRequests, this.args[0]);
      }
      return { success: true };
    }
    throw new Error(`Unsupported run SQL: ${this.sql}`);
  }
}

class FakeR2 {
  constructor() {
    this.objects = new Map();
    this.failDeletes = new Set();
    this.failGets = new Set();
    this.putCount = 0;
    this.getCount = 0;
    this.getDelayMs = 0;
    this.deleteDelayMs = 0;
  }

  async put(key, body, options = {}) {
    this.putCount += 1;
    const text = typeof body === "string"
      ? body
      : body instanceof ReadableStream
        ? await new Response(body).text()
        : body instanceof ArrayBuffer
          ? new TextDecoder().decode(body)
          : String(body || "");
    this.objects.set(key, {
      body: text,
      httpMetadata: options.httpMetadata || {},
    });
  }

  async get(key) {
    this.getCount += 1;
    if (this.getDelayMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, this.getDelayMs));
    }
    if (this.failGets.has(key)) throw new Error("injected get failure");
    const object = this.objects.get(key);
    if (!object) {
      return null;
    }
    return {
      body: object.body,
      httpMetadata: object.httpMetadata,
    };
  }

  async delete(key) {
    if (this.deleteDelayMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, this.deleteDelayMs));
    }
    if (this.failDeletes.has(key)) throw new Error("injected delete failure");
    this.objects.delete(key);
  }
}

function sortedRows(map, limit) {
  return Array.from(map.values())
    .sort((lhs, rhs) => Date.parse(rhs.updated_at) - Date.parse(lhs.updated_at))
    .slice(0, limit);
}

function trimRows(map, limit) {
  const keep = new Set(sortedRows(map, limit).map((row) => row.id));
  for (const id of map.keys()) {
    if (!keep.has(id)) {
      map.delete(id);
    }
  }
}

function sortedItemActionRows(map, limit) {
  return Array.from(map.values())
    .sort((lhs, rhs) => {
      const lhsActive = ["pending", "running"].includes(lhs.status);
      const rhsActive = ["pending", "running"].includes(rhs.status);
      if (lhsActive !== rhsActive) return lhsActive ? -1 : 1;
      const timestampDifference = Date.parse(rhs.updated_at) - Date.parse(lhs.updated_at);
      if (timestampDifference !== 0) return timestampDifference;
      return String(rhs.id).localeCompare(String(lhs.id));
    })
    .slice(0, limit);
}

function trimItemActionRows(map, limit) {
  const active = sortedItemActionRows(map, map.size).filter((row) => ["pending", "running"].includes(row.status));
  const terminal = sortedItemActionRows(map, map.size).filter((row) => !["pending", "running"].includes(row.status));
  const keep = new Set([
    ...active,
    ...terminal.slice(0, Math.max(0, limit - active.length)),
  ].map((row) => row.id));
  for (const id of map.keys()) {
    if (!keep.has(id)) map.delete(id);
  }
}

function deleteTerminalRows(map) {
  for (const [id, row] of map.entries()) {
    if (row.status !== "pending" && row.status !== "running") {
      map.delete(id);
    }
  }
}

function hasDownloadReservation(db, requestID) {
  return Array.from(db.fileDownloadReservations.values()).some((reservation) => reservation.request_id === requestID);
}

await runSmoke();
