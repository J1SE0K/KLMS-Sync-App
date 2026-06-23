import assert from "node:assert/strict";
import worker from "../src/worker.mjs";

const clientToken = "test-client-token";
const workerToken = "test-worker-token";
let env;

async function runSmoke() {
  env = {
    RELAY_CLIENT_TOKEN: clientToken,
    RELAY_WORKER_TOKEN: workerToken,
    RELAY_DB: new FakeD1(),
    RELAY_FILES: new FakeR2(),
  };

  await expectJSON("/healthz", { ok: true, storage: "cloudflare-d1", configured: true }, { auth: false });

  {
    const response = await request("/v1/status", { auth: false });
    assert.equal(response.status, 401);
  }

  {
    const payload = await expectJSON("/v1/status");
    assert.equal(payload.ok, true);
    assert.equal(payload.status.phase, "idle");
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

  let createdCommand = await expectJSON("/v1/commands", {
    kind: "fullSync",
    options: { updateNoticeNotes: false, dryRun: true },
    status: "pending",
    summary: { assignments: 3, phase: "pending" },
  }, { method: "POST", status: 201 });
  assert.equal(createdCommand.kind, "fullSync");
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
        detail: "/Users/example/private 12345 주소",
        attachmentCount: 1,
        updatedAt: "2026-05-31T00:00:01Z",
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
        command: "full",
        commandTitle: "전체 동기화",
        status: "성공",
        startedAt: "2026-05-31T00:00:00Z",
        finishedAt: "2026-05-31T00:00:05Z",
        updatedAt: "2026-05-31T00:00:05Z",
        duration: "5초",
        exitCode: 0,
        dryRun: false,
        wasCancelled: false,
        needsAttention: false,
        outputTail: "KAIST 인증 번호: 57\n/Users/example/Library/Application Support/KLMSNotesSync/course_files/과목 폴더/자료.pdf\n/var/folders/qz/private temp/file\nhttps://klms.kaist.ac.kr/mod/courseboard/article.php?id=123\n정상 완료",
      },
    ],
  }, { method: "POST", role: "worker" });

  {
    const event = await expectJSON("/v1/events/poll?role=client&waitSeconds=0");
    assert.equal(event.type, "changed");
    assert.equal(event.reason, "sync-data");
    assert.ok(Date.parse(event.updatedAt) > 0);
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
    assert.match(payload.runLogs[0].outputTail, /KAIST 인증 번호: --/);
    assert.match(payload.runLogs[0].outputTail, /\[KLMS URL\]/);
    assert.doesNotMatch(payload.runLogs[0].outputTail, /57/);
    assert.doesNotMatch(payload.runLogs[0].outputTail, /\/Users/);
    assert.doesNotMatch(payload.runLogs[0].outputTail, /Application Support/);
    assert.doesNotMatch(payload.runLogs[0].outputTail, /과목 폴더/);
    assert.doesNotMatch(payload.runLogs[0].outputTail, /\/var\/folders/);
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
    const event = await expectJSON("/v1/events/poll?role=client&waitSeconds=0");
    assert.equal(event.reason, "shared-settings");
  }

  {
    const clearRunLogs = await expectJSON("/v1/sync-data/run-logs", undefined, { method: "DELETE" });
    assert.equal(clearRunLogs.runLogs, 1);
    const event = await expectJSON("/v1/events/poll?role=client&waitSeconds=0");
    assert.equal(event.type, "changed");
    assert.equal(event.reason, "sync-data:run-logs-clear");
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
    assert.equal(afterNewPost.runLogs[0].commandTitle, "파일");
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

  const settingAction = await expectJSON("/v1/setting-actions", {
    key: "FILE_REFRESH_MODE",
    title: "파일 탐색 모드",
    value: "quick",
  }, { method: "POST", status: 201 });
  assert.equal(settingAction.status, "pending");
  assert.match(settingAction.message, /서버 화면에는 바로 반영/);
  {
    const payload = await expectJSON("/v1/sync-data?limit=10");
    assert.equal(payload.settings.find((setting) => setting.key === "FILE_REFRESH_MODE")?.value, "quick");
  }

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
    assert.equal(activeClearBody.fileAccessRequests, 0);
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

  await expectJSON(`/v1/item-actions/${action.id}`, {
    ...action,
    status: "completed",
    updatedAt: new Date().toISOString(),
    message: "done",
  }, { method: "PUT", role: "worker" });

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
    const wrongTicketResponse = await worker.fetch(new Request(wrongTicketURL.toString()), env);
    assert.equal(wrongTicketResponse.status, 401);
    const wrongTicketHTML = await wrongTicketResponse.text();
    assert.match(wrongTicketHTML, /권한이 없는 링크입니다/);
    assert.doesNotMatch(wrongTicketHTML, /기말 정리.txt/);
    assert.doesNotMatch(wrongTicketHTML, /data-download-count=/);

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
    const previewPageHTML = await previewPageResponse.text();
    assert.match(previewPageHTML, /PDF 쪽 이동과 확대\/축소는 파일 안쪽의 PDF 뷰어 도구막대/);
    assert.doesNotMatch(previewPageHTML, /data-action="zoom-in"/);
    assert.doesNotMatch(previewPageHTML, /data-action="next"/);
    assert.doesNotMatch(previewPageHTML, /#page=1&amp;zoom=100/);
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

    const fileAccessClear = await expectJSON("/v1/logs?scope=fileAccess", undefined, { method: "DELETE", role: "worker" });
    assert.ok(fileAccessClear.fileAccessRequests > 0);
    assert.equal(fileAccessClear.requestLogEntries, 0);
    const fileRequestsAfterFileAccessClear = await expectJSON("/v1/file-access/recent");
    assert.equal(fileRequestsAfterFileAccessClear.requests.length, 0);

    const clear = await expectJSON("/v1/logs", undefined, { method: "DELETE", role: "worker" });
    assert.equal(clear.commands, 0);
    assert.ok(clear.itemActions > 0);
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
      action: "hide",
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

  console.log("cloudflare worker smoke ok");
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

function request(path, { method = "GET", body, rawBody, headers: extraHeaders = {}, auth = true, role = "client" } = {}) {
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
  }), env);
}

class FakeD1 {
  constructor() {
    this.meta = new Map();
    this.commands = new Map();
    this.itemActions = new Map();
    this.fileAccessRequests = new Map();
  }

  async exec() {
    return { count: 0, duration: 0 };
  }

  prepare(sql) {
    return new FakeStatement(this, sql);
  }

  async batch(statements) {
    const results = [];
    for (const statement of statements) {
      results.push(await statement.run());
    }
    return results;
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
    if (this.sql.includes("FROM file_access_requests")) {
      return this.db.fileAccessRequests.get(this.args[0]) || null;
    }
    throw new Error(`Unsupported first SQL: ${this.sql}`);
  }

  async all() {
    if (this.sql.includes("FROM commands")) {
      return { results: sortedRows(this.db.commands, this.args[0] || 200) };
    }
    if (this.sql.includes("FROM item_actions")) {
      return { results: sortedRows(this.db.itemActions, this.args[0] || 400) };
    }
    if (this.sql.includes("FROM file_access_requests")) {
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
    if (this.sql.startsWith("INSERT INTO meta")) {
      this.db.meta.set(this.args[0], String(this.args[1]));
      return { success: true };
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
      return { success: true };
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
        action,
        itemID,
        itemKind,
        itemTitle,
        status,
        createdAt,
        updatedAt,
        message,
      ] = this.args;
      this.db.itemActions.set(id, {
        id,
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
      if (this.sql.includes("status NOT IN")) {
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
      });
      return { success: true };
    }
    if (this.sql.startsWith("DELETE FROM file_access_requests")) {
      if (this.sql.includes("expires_at IS NOT NULL")) {
        const cutoff = this.args[0];
        for (const [id, row] of this.db.fileAccessRequests.entries()) {
          if (row.expires_at && row.expires_at <= cutoff) {
            this.db.fileAccessRequests.delete(id);
          }
        }
      } else if (this.sql.includes("status NOT IN")) {
        deleteTerminalRows(this.db.fileAccessRequests);
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
  }

  async put(key, body, options = {}) {
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

function deleteTerminalRows(map) {
  for (const [id, row] of map.entries()) {
    if (row.status !== "pending" && row.status !== "running") {
      map.delete(id);
    }
  }
}

await runSmoke();
