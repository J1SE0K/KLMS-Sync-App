const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { _electron: electron, expect, test } = require("@playwright/test");
const { FakeRelay, TEST_TOKEN } = require("./fake-relay.cjs");

const appRoot = path.resolve(__dirname, "../..");
const electronEntry = path.join(__dirname, "electron-entry.cjs");
const testedWidths = [640, 719, 720, 1039, 1040];

let electronApp;
let page;
let relay;
let replacementRelay;
let testProfile;
const pageErrors = [];

test.beforeAll(async () => {
  relay = await FakeRelay.start();
  replacementRelay = await FakeRelay.start();
  replacementRelay.sharedSettings = [{
    key: "KLMS_UPDATE_NOTICE_NOTES",
    title: "공지 메모 업데이트",
    value: "1",
    valueKind: "bool",
    options: [],
    editable: true
  }];
  testProfile = await fs.mkdtemp(path.join(os.tmpdir(), "klms-windows-e2e-"));
  electronApp = await electron.launch({
    args: [electronEntry, "--disable-gpu"],
    cwd: appRoot,
    env: {
      ...process.env,
      KLMS_E2E_USER_DATA_DIR: testProfile,
      ELECTRON_DISABLE_SECURITY_WARNINGS: "true"
    }
  });
  page = await electronApp.firstWindow();
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await page.waitForLoadState("domcontentloaded");
  await resizeElectronContent(1_040, 700);
});

test.afterAll(async () => {
  await electronApp?.close();
  await relay?.close();
  await replacementRelay?.close();
  if (testProfile) {
    await fs.rm(testProfile, { recursive: true, force: true });
  }
});

test("an unconfigured profile never presents itself as connected", async () => {
  await expect(page.locator("#connectionState")).toHaveText("연결 필요");
  await expect(page.locator("#phaseLabel")).toHaveText("연결 필요");
  await expect(page.locator("#statusTitle")).toHaveText("서버 연결이 필요합니다");
  await expect(page.locator("#statusSubtitle")).toContainText("relay URL과 클라이언트 토큰");
  await expect(page.locator("#attentionBanner")).toHaveAttribute("role", "alert");
  await expect(page.locator("#toast")).toHaveAttribute("aria-live", "polite");
  await expect(page.getByLabel("항목 검색")).toHaveCount(1);
  await page.emulateMedia({ colorScheme: "dark" });
  expect(await page.evaluate(() => (
    getComputedStyle(document.documentElement).getPropertyValue("--panel").trim()
  ))).toBe("#1a1d19");
  await page.emulateMedia({ colorScheme: "light" });
  expect(await page.evaluate(() => (
    getComputedStyle(document.documentElement).getPropertyValue("--panel").trim()
  ))).toBe("#ffffff");
});

test("pasted credentials leave the clipboard only when it is still unchanged", async () => {
  const credentialText = `서버 URL: ${relay.url}\n클라이언트 토큰: ${TEST_TOKEN}`;
  await electronApp.evaluate(
    ({ clipboard }, value) => clipboard.writeText(value, "clipboard"),
    credentialText
  );

  await page.locator("#pasteClipboardButton").click();

  await expect(page.locator("#relayURL")).toHaveValue(relay.url);
  await expect(page.locator("#relayToken")).toHaveValue(TEST_TOKEN);
  await expect(page.locator("#connectionPaste")).toHaveValue(credentialText);
  expect(
    await electronApp.evaluate(({ clipboard }) => clipboard.readText("clipboard"))
  ).toBe("");

  const newerClipboardText = "newer-user-value";
  await electronApp.evaluate(
    ({ clipboard }, value) => clipboard.writeText(value, "clipboard"),
    newerClipboardText
  );
  expect(
    await page.evaluate(
      (value) => window.klmsWindows.clearClipboardTextIfUnchanged(value),
      credentialText
    )
  ).toEqual({ cleared: false });
  expect(
    await electronApp.evaluate(({ clipboard }) => clipboard.readText("clipboard"))
  ).toBe(newerClipboardText);

  await page.locator("#relayURL").fill("");
  await page.locator("#relayToken").fill("");
  await page.locator("#connectionPaste").fill("");
  const oversizedCredentialText = `${credentialText}\n${"X".repeat(200_001)}`;
  await electronApp.evaluate(
    ({ clipboard }, value) => clipboard.writeText(value, "clipboard"),
    oversizedCredentialText
  );
  await page.locator("#pasteClipboardButton").click();
  await expect(page.locator("#toast")).toContainText("200,000자 이하");
  await expect(page.locator("#relayURL")).toHaveValue("");
  await expect(page.locator("#relayToken")).toHaveValue("");
  await expect(page.locator("#connectionPaste")).toHaveValue("");
  expect(await electronApp.evaluate(({ clipboard }) => clipboard.readText("clipboard").length))
    .toBe(oversizedCredentialText.length);

  const directPaste = await page.locator("#connectionPaste").evaluate((element, value) => {
    const transfer = new DataTransfer();
    transfer.setData("text/plain", value);
    const event = new ClipboardEvent("paste", {
      bubbles: true,
      cancelable: true,
      clipboardData: transfer
    });
    return {
      allowed: element.dispatchEvent(event),
      value: element.value
    };
  }, oversizedCredentialText);
  expect(directPaste).toEqual({ allowed: false, value: "" });
  await electronApp.evaluate(({ clipboard }) => clipboard.clear("clipboard"));
});

test("replacement-token cleanup clears the credential that was actually consumed", async () => {
  const staleToken = ["stale", "client", "token", "value"].join("-");
  const staleConnectionText = `서버 URL: ${relay.url}\n클라이언트 토큰: ${staleToken}`;
  await electronApp.evaluate(
    ({ clipboard }, value) => clipboard.writeText(value, "clipboard"),
    TEST_TOKEN
  );

  expect(await page.evaluate(
    ({ pastedConnectionText, tokenDraft }) => (
      clearConsumedCredentialClipboardText(pastedConnectionText, tokenDraft)
    ),
    { pastedConnectionText: staleConnectionText, tokenDraft: TEST_TOKEN }
  )).toBe(true);
  expect(await electronApp.evaluate(({ clipboard }) => clipboard.readText("clipboard"))).toBe("");
});

test("WebSocket changes render immediately and responsive resize preserves selection without polling", async () => {
  await page.locator("#relayURL").fill(relay.url);
  await page.locator("#relayToken").fill(TEST_TOKEN);
  await page.locator("#connectionPaste").fill(`서버 URL: ${relay.url}\n클라이언트 토큰: ${TEST_TOKEN}`);
  await page.locator("#saveConnectionButton").click();

  await expect(page.locator("#connectionState")).toHaveText("실시간 연결됨");
  await expect(page.locator("#relayToken")).toHaveAttribute("placeholder", "저장됨");
  await expect(page.locator("#connectionPaste")).toHaveValue("");
  const rendererConfig = await page.evaluate(() => window.klmsWindows.loadConfig());
  expect(rendererConfig.hasToken).toBe(true);
  expect(rendererConfig).not.toHaveProperty("token");
  expect(rendererConfig).not.toHaveProperty("tokenPreview");
  expect(JSON.stringify(rendererConfig)).not.toContain(TEST_TOKEN.slice(0, 6));
  expect(JSON.stringify(rendererConfig)).not.toContain(TEST_TOKEN.slice(-8));
  await expect(page.locator("#primarySyncButton")).toBeVisible();
  await expect(page.locator(".commands-panel #primarySyncButton")).toHaveCount(1);
  await expect(page.locator(".topbar #primarySyncButton")).toHaveCount(0);
  await expect(page.locator("#commandButtons")).not.toContainText("전체 동기화");
  const initialSyncPanelLayout = await readSyncPanelLayout();
  expect(initialSyncPanelLayout.primaryCount).toBe(1);
  expect(initialSyncPanelLayout.primaryInsideCommands).toBe(true);
  expect(initialSyncPanelLayout.topbarContainsPrimary).toBe(false);
  expect(initialSyncPanelLayout.connectionTop).toBeLessThan(initialSyncPanelLayout.commandsTop);
  expect(Math.abs(initialSyncPanelLayout.primaryWidth - initialSyncPanelLayout.commandsContentWidth)).toBeLessThanOrEqual(1);
  expect(await page.evaluate(() => Boolean(
    document.querySelector("#attentionBanner").compareDocumentPosition(document.querySelector(".topbar"))
      & Node.DOCUMENT_POSITION_FOLLOWING
  ))).toBe(true);
  const stableRow = page.locator("#itemList .item-row", { hasText: "선택 유지 과제" });
  await expect(stableRow).toBeVisible();
  await stableRow.click();
  await expect(page.locator("#itemDetail .detail-header h2")).toHaveText("선택 유지 과제");

  const originalStatus = { ...relay.status };
  const originalMessage = relay.message;
  relay.status = {
    ...relay.status,
    assignments: "</strong><img src=x onerror=globalThis.__klmsXSS=true>",
    phase: "<img src=x onerror=globalThis.__klmsXSS=true>",
    authDigits: "12<img>"
  };
  relay.message = "<img src=x onerror=globalThis.__klmsXSS=true>";
  await page.locator("#refreshButton").click();
  await expect.poll(() => page.evaluate(() => state.status.assignments)).toBe(0);
  expect(await page.locator("img").count()).toBe(0);
  expect(await page.evaluate(() => globalThis.__klmsXSS)).toBeUndefined();
  relay.status = originalStatus;
  relay.message = originalMessage;
  await page.locator("#refreshButton").click();
  await expect(page.locator("#dashboardCards .metric-card", { hasText: "과제" }).locator("strong")).toHaveText("1");

  for (const width of testedWidths) {
    await resizeElectronContent(width, 700);
    const layout = await readLayoutState();
    expect(layout.innerWidth).toBe(width);
    expect(layout.documentScrollWidth, `document overflow at ${width}px`).toBeLessThanOrEqual(width);
    expect(layout.bodyScrollWidth, `body overflow at ${width}px`).toBeLessThanOrEqual(width);
    expect(layout.contentWithinViewport, `content rect overflow at ${width}px`).toBe(true);
    expect(layout.workspaceChildrenWithinViewport, `workspace child overflow at ${width}px`).toBe(true);

    if (width >= 1040) {
      expect(layout.shellDisplay).toBe("grid");
      expect(layout.shellColumnCount).toBe(2);
      expect(layout.workspaceColumnCount).toBe(2);
      expect(layout.workspaceIsStacked).toBe(false);
      expect(layout.sidebarRailDisplay).toBe("none");
      const wideSyncPanelLayout = await readSyncPanelLayout();
      expect(wideSyncPanelLayout.connectionTop).toBeLessThan(wideSyncPanelLayout.commandsTop);
      expect(Math.abs(wideSyncPanelLayout.primaryWidth - wideSyncPanelLayout.commandsContentWidth)).toBeLessThanOrEqual(1);
      const wideConnectionActions = await readConnectionActionLayout();
      expect(wideConnectionActions.checkLineCount).toBe(1);
      expect(wideConnectionActions.clearLineCount).toBe(1);
      expect(wideConnectionActions.checkWhiteSpace).toBe("nowrap");
      expect(wideConnectionActions.clearWhiteSpace).toBe("nowrap");
      expect(wideConnectionActions.panelShadow).toBe("none");
    } else if (width >= 720) {
      expect(layout.shellDisplay).toBe("grid");
      expect(layout.shellColumnCount).toBe(2);
      expect(layout.workspaceColumnCount).toBe(1);
      expect(layout.workspaceIsStacked).toBe(true);
      expect(layout.sidebarRailDisplay).toBe("grid");
    } else {
      expect(layout.shellDisplay).toBe("block");
      expect(layout.workspaceColumnCount).toBe(1);
      expect(layout.workspaceIsStacked).toBe(true);
      expect(layout.sidebarToggleDisplay).not.toBe("none");
    }

    await expect(page.locator("#itemList .item-row.active")).toContainText("선택 유지 과제");
    await expect(page.locator("#itemDetail .detail-header h2")).toHaveText("선택 유지 과제");
  }
  await expect(page.locator("#toast")).toBeHidden({ timeout: 4_000 });
  await captureStableScreenshot("windows-wide-1040-light-connected");

  await resizeElectronContent(720, 700);
  expect(await page.locator(".sidebar-rail [data-sidebar-target]").evaluateAll((buttons) => (
    buttons.map((button) => button.dataset.sidebarTarget)
  ))).toEqual(["commands", "connection"]);
  const commandsRailButton = page.locator('[data-sidebar-target="commands"]');
  await commandsRailButton.click();
  await expect(page.locator("body")).toHaveClass(/sidebar-open/);
  await expect.poll(() => page.evaluate(() => (
    document.querySelector(".commands-panel")?.contains(document.activeElement)
  ))).toBe(true);
  const narrowRailSyncPanelLayout = await readSyncPanelLayout();
  expect(narrowRailSyncPanelLayout.commandsTop).toBeLessThan(narrowRailSyncPanelLayout.connectionTop);
  expect(Math.abs(narrowRailSyncPanelLayout.primaryWidth - narrowRailSyncPanelLayout.commandsContentWidth)).toBeLessThanOrEqual(1);
  await captureStableScreenshot("windows-medium-720-light-command-drawer-icons");
  await page.keyboard.press("Escape");
  await expect(page.locator("body")).not.toHaveClass(/sidebar-open/);
  await expect(commandsRailButton).toBeFocused();

  await resizeElectronContent(1039, 700);
  await commandsRailButton.click();
  await expect(page.locator("body")).toHaveClass(/sidebar-open/);
  expect(await page.evaluate(() => document.querySelector(".content")?.inert)).toBe(true);
  const mediumSyncPanelLayout = await readSyncPanelLayout();
  expect(mediumSyncPanelLayout.commandsTop).toBeLessThan(mediumSyncPanelLayout.connectionTop);
  expect(Math.abs(mediumSyncPanelLayout.primaryWidth - mediumSyncPanelLayout.commandsContentWidth)).toBeLessThanOrEqual(1);
  for (let index = 0; index < 24; index += 1) {
    await page.keyboard.press("Tab");
    expect(await page.evaluate(() => (
      document.querySelector("#appSidebar")?.contains(document.activeElement)
    )), `drawer focus escaped after ${index + 1} Tab presses`).toBe(true);
  }
  await page.keyboard.press("Escape");
  await expect(commandsRailButton).toBeFocused();
  expect(await page.evaluate(() => document.querySelector(".content")?.inert)).toBe(false);

  await resizeElectronContent(640, 700);
  const sidebarToggleButton = page.locator("#sidebarToggleButton");
  await sidebarToggleButton.click();
  await expect(page.locator("body")).toHaveClass(/sidebar-open/);
  await expect.poll(() => page.evaluate(() => (
    document.querySelector(".commands-panel")?.contains(document.activeElement)
  ))).toBe(true);
  const compactSyncPanelLayout = await readSyncPanelLayout();
  expect(compactSyncPanelLayout.commandsTop).toBeLessThan(compactSyncPanelLayout.connectionTop);
  expect(Math.abs(compactSyncPanelLayout.primaryWidth - compactSyncPanelLayout.commandsContentWidth)).toBeLessThanOrEqual(1);
  await page.keyboard.press("Escape");
  await expect(page.locator("body")).not.toHaveClass(/sidebar-open/);
  await expect(sidebarToggleButton).toBeFocused();
  await resizeElectronContent(1040, 700);

  const focusedCommandButton = page.locator('[data-focus-key="command:filesSync"]');
  await focusedCommandButton.focus();
  await expect(focusedCommandButton).toBeFocused();
  const requestsBeforeRealtimeUpdate = relay.requestCount;
  const changedAt = Date.now();
  const targetRevision = relay.publishChanged();
  await expect(page.locator("#itemList")).toContainText("실시간 갱신 과제", { timeout: 2_000 });
  expect(Date.now() - changedAt).toBeLessThan(2_000);
  await expect(page.locator("#connectionState")).toHaveText("실시간 연결됨");
  await expect(page.locator("#itemList .item-row.active")).toContainText("선택 유지 과제");
  await expect(page.locator("#itemDetail .detail-header h2")).toHaveText("선택 유지 과제");
  await expect(page.locator("#dashboardCards .metric-card", { hasText: "과제" }).locator("strong")).toHaveText("2");
  await expect(page.locator('[data-focus-key="command:filesSync"]')).toBeFocused();

  expect(targetRevision).toBe(1);
  expect(relay.upgrades).toHaveLength(1);
  expect(relay.upgrades[0]).toMatch(/^\/v1\/events\?role=client&sinceRevision=0$/);
  expect(relay.requestCount).toBe(requestsBeforeRealtimeUpdate);
  expect(relay.requests.some((request) => /events\/poll|waitSeconds/i.test(request.path))).toBe(false);

  expect(relay.restoreLowerRevision()).toBe(0);
  await expect(page.locator("#itemList")).toContainText("복원된 서버 과제", { timeout: 3_000 });
  await expect(page.locator("#itemList")).not.toContainText("실시간 갱신 과제");
  await expect(page.locator("#itemList .item-row.active")).toContainText("선택 유지 과제");
  await expect.poll(() => relay.upgrades.length, { timeout: 3_000 }).toBe(2);
  expect(relay.upgrades[1]).toMatch(/^\/v1\/events\?role=client&sinceRevision=1$/);

  const postRestoreChangedAt = Date.now();
  expect(relay.publishChanged()).toBe(1);
  await expect(page.locator("#itemList")).toContainText("실시간 갱신 과제", { timeout: 2_000 });
  expect(Date.now() - postRestoreChangedAt).toBeLessThan(2_000);
  await expect(page.locator("#dashboardCards .metric-card", { hasText: "과제" }).locator("strong")).toHaveText("3");

  const burstLatencies = [];
  for (let index = 0; index < 20; index += 1) {
    const itemID = `burst-assignment-${index}`;
    const startedAt = Date.now();
    relay.publishAssignment(itemID, `실시간 버스트 과제 ${index + 1}`);
    await expect.poll(() => page.evaluate((id) => (
      state.items.some((item) => item.id === id)
    ), itemID), {
      timeout: 2_000,
      intervals: [10, 20, 40, 80]
    }).toBe(true);
    burstLatencies.push(Date.now() - startedAt);
  }
  const sortedBurstLatencies = [...burstLatencies].sort((lhs, rhs) => lhs - rhs);
  const burstP95 = sortedBurstLatencies[Math.ceil(sortedBurstLatencies.length * 0.95) - 1];
  expect(burstP95, `20-event local WebSocket p95 was ${burstP95}ms`).toBeLessThan(1_000);

  const coalescedRequestBaseline = relay.requestCount;
  const coalescedEventBaseline = relay.realtimeEvents.length;
  const delayedCoalescedSnapshot = relay.delayNextSnapshotDelivery();
  let coalescedTargetRevision = 0;
  for (let index = 0; index < 8; index += 1) {
    coalescedTargetRevision = relay.publishAssignment(
      `coalesced-assignment-${index}`,
      `합쳐진 실시간 과제 ${index + 1}`
    );
  }
  await delayedCoalescedSnapshot.started;
  delayedCoalescedSnapshot.release();
  await expect(page.locator("#itemList")).toContainText("합쳐진 실시간 과제 8", { timeout: 2_000 });
  await expect.poll(() => page.evaluate(() => state.relayRevision)).toBe(coalescedTargetRevision);
  expect(relay.realtimeEvents.slice(coalescedEventBaseline)).toHaveLength(2);
  expect(relay.realtimeEvents.at(-1).reason).toBe("coalesced");
  expect(relay.requestCount).toBe(coalescedRequestBaseline);

  await writeStableArtifact("windows-realtime-burst-metrics.json", JSON.stringify({
    eventCount: burstLatencies.length,
    p95Milliseconds: burstP95,
    thresholdMilliseconds: 1_000,
    latenciesMilliseconds: burstLatencies,
    coalescedInputEventCount: 8,
    coalescedOutputStreamCount: 2,
    transport: "bounded WebSocket snapshot stream",
    pollingObserved: false
  }, null, 2));

  await waitForStableRequestCount(relay);
  const delayedSnapshot = relay.delayNextSnapshotDelivery();
  relay.itemActions = [{
    id: "slow-sync-independent-action",
    action: "assignmentComplete",
    itemID: "stable-assignment",
    itemKind: "assignment",
    itemTitle: "느린 sync-data와 독립된 항목 처리",
    message: "sync-data 응답 전 표시",
    status: "pending",
    createdAt: "2026-07-13T16:20:00.000Z",
    updatedAt: "2026-07-13T16:20:00.000Z"
  }];
  relay.publishEvent("item-actions:updated", ["syncData", "itemActions"]);
  await delayedSnapshot.started;
  await expect(page.locator("#historyList")).not.toContainText("느린 sync-data와 독립된 항목 처리");
  delayedSnapshot.release();
  await expect(page.locator("#historyList")).toContainText("느린 sync-data와 독립된 항목 처리", { timeout: 2_000 });
  const crossBatchCommand = relay.publishCommand("running");
  await expect(page.locator("#phaseLabel")).toHaveText("실행 중", { timeout: 2_000 });
  await expect(page.locator("#primarySyncButton")).toContainText("전체 동기화 중단");
  expect(await page.evaluate(() => state.latestCommand?.id)).toBe(crossBatchCommand.id);
  relay.markLatestCommand("cancelled");
  await expect(page.locator("#phaseLabel")).toHaveText("취소됨", { timeout: 2_000 });
  await expect(page.locator("#primarySyncButton")).toContainText("전체 동기화");
  await expect(page.locator("#primarySyncButton")).toBeEnabled();
  const idleBaseline = await waitForStableRequestCount(relay);
  await page.waitForTimeout(1_100);
  expect(relay.requestCount, "idle UI issued an interval or long-poll HTTP request").toBe(idleBaseline);

  const delayedCommand = relay.delayNextCommandResponse();
  const commandIDBeforeDelayedPost = relay.latestCommand?.id;
  await page.locator("#primarySyncButton").click();
  await delayedCommand.started;
  await expect(page.locator("#primarySyncButton")).toContainText("전체 동기화 요청 전송 중");
  await expect(page.locator("#primarySyncButton")).toBeDisabled();
  expect(relay.cancelRequests).toHaveLength(0);
  expect(relay.latestCommand?.id).toBe(commandIDBeforeDelayedPost);
  delayedCommand.release();
  await expect(page.locator("#primarySyncButton")).toContainText("전체 동기화 중단");
  expect(relay.latestCommand?.id).toMatch(/^[0-9a-f]{8}-[0-9a-f-]{27}$/i);
  expect(relay.latestCommand?.id).not.toBe(commandIDBeforeDelayedPost);

  relay.itemActions = [{
    id: "slow-log-independent-action",
    action: "assignmentComplete",
    itemID: "stable-assignment",
    itemKind: "assignment",
    itemTitle: "느린 로그와 독립된 항목 처리",
    message: "request-log 응답 전 표시",
    status: "pending",
    createdAt: "2026-07-13T16:30:00.000Z",
    updatedAt: "2026-07-13T16:30:00.000Z"
  }];
  relay.markLatestCommand("running", ["itemActions", "requestLog"]);
  await expect(page.locator("#phaseLabel")).toHaveText("실행 중");
  await expect(page.locator("#primarySyncButton")).toContainText("전체 동기화 중단");
  await expect(page.locator("#statusSubtitle")).toContainText("fullSync running");
  await expect(page.locator("#historyList")).toContainText("느린 로그와 독립된 항목 처리");
  await page.evaluate(() => pendingCommandOverlays.clear());
  relay.markLatestCommand("cancelled");
  await expect(page.locator("#phaseLabel")).toHaveText("취소됨");
  await expect(page.locator("#primarySyncButton")).toContainText("전체 동기화");
  await expect(page.locator("#primarySyncButton")).toBeEnabled();
  await page.waitForTimeout(150);
  await expect(page.locator("#primarySyncButton")).not.toContainText("중단");
  await expect(page.locator("#statusSubtitle")).not.toContainText("요청 대기 중");

  await page.locator("#primarySyncButton").click();
  await expect(page.locator("#primarySyncButton")).toContainText("전체 동기화 중단");
  expect(relay.latestCommand?.id).toMatch(/^[0-9a-f]{8}-[0-9a-f-]{27}$/i);
  relay.markLatestCommand("running");
  await expect(page.locator("#phaseLabel")).toHaveText("실행 중");
  await page.evaluate(() => pendingCommandOverlays.clear());
  relay.markLatestCommand("cancelled");
  await expect(page.locator("#phaseLabel")).toHaveText("취소됨");
  await expect(page.locator("#primarySyncButton")).toContainText("전체 동기화");
  await expect(page.locator("#primarySyncButton")).toBeEnabled();

  await page.locator("#primarySyncButton").click();
  await expect(page.locator("#primarySyncButton")).toContainText("전체 동기화 중단");
  expect(relay.latestCommand?.id).toMatch(/^[0-9a-f]{8}-[0-9a-f-]{27}$/i);
  const serverCommandID = relay.latestCommand.id;
  relay.markLatestCommand("running");
  await expect(page.locator("#phaseLabel")).toHaveText("실행 중");
  await page.locator("#primarySyncButton").click();
  await expect.poll(() => relay.cancelRequests.length).toBe(1);
  expect(relay.cancelRequests[0].commandID).toBe(serverCommandID);
  expect(relay.cancelRequests[0].commandID).not.toMatch(/^optimistic-command-/);
  await expect(page.locator("#primarySyncButton")).toContainText("전체 동기화 중단 요청됨");
  await expect(page.locator("#primarySyncButton")).toBeDisabled();
  relay.markLatestCommand("cancelled");
  await expect(page.locator("#primarySyncButton")).toContainText("전체 동기화");
  await expect(page.locator("#primarySyncButton")).toBeEnabled();
  expect(pageErrors).toEqual([]);
});

test("switching relay aborts an in-flight config-bound setting mutation", async () => {
  await page.locator("#relayURL").fill(relay.url);
  await page.locator("#relayToken").fill(TEST_TOKEN);
  await page.locator("#saveConnectionButton").click();
  await expect.poll(() => relay.upgrades.length, { timeout: 3_000 }).toBeGreaterThanOrEqual(3);
  await expect(page.locator("#updateNoticeNotes")).toBeChecked();

  relay.appliedSharedSettingMutations = [];
  relay.abortedSharedSettingMutations = 0;
  const delayedMutation = relay.delayNextSharedSettingMutation();
  const oldConfigRevision = await page.evaluate(async () => {
    const config = await window.klmsWindows.loadConfig();
    return config.configRevision;
  });

  await page.locator("#updateNoticeNotes").uncheck();
  await delayedMutation.started;
  await page.locator("#relayURL").fill(replacementRelay.url);
  await page.locator("#relayToken").fill(TEST_TOKEN);
  await page.locator("#saveConnectionButton").click();

  await expect.poll(() => relay.abortedSharedSettingMutations, { timeout: 3_000 }).toBe(1);
  await expect.poll(() => replacementRelay.upgrades.length, { timeout: 3_000 }).toBeGreaterThanOrEqual(1);
  await expect.poll(async () => page.evaluate(async () => {
    const config = await window.klmsWindows.loadConfig();
    return config.configRevision;
  })).toBeGreaterThan(oldConfigRevision);

  delayedMutation.release();
  await page.waitForTimeout(100);
  expect(relay.appliedSharedSettingMutations).toEqual([]);
  expect(replacementRelay.appliedSharedSettingMutations).toEqual([]);
  expect(replacementRelay.requests.some((request) => (
    request.method === "PUT" && request.path.startsWith("/v1/shared-settings/")
  ))).toBe(false);
  await expect(page.locator("#updateNoticeNotes")).toBeChecked();
  await expect(page.locator("#connectionState")).toHaveText("실시간 연결됨");
  expect(pageErrors).toEqual([]);
});

test("same-key settings serialize and latest failure restores the committed predecessor", async () => {
  replacementRelay.appliedSharedSettingMutations = [];
  replacementRelay.rejectedSharedSettingValues = new Set(["1"]);
  const delayedOlderMutation = replacementRelay.delayNextSharedSettingMutation();
  const putCountBefore = replacementRelay.requests.filter((request) => (
    request.method === "PUT" && request.path.startsWith("/v1/shared-settings/")
  )).length;

  await page.evaluate(() => {
    window.__olderSettingMutation = updateSharedSetting("KLMS_UPDATE_NOTICE_NOTES", "0");
  });
  await delayedOlderMutation.started;
  await page.evaluate(() => {
    window.__latestSettingMutation = updateSharedSetting("KLMS_UPDATE_NOTICE_NOTES", "1");
  });
  await page.waitForTimeout(75);
  expect(replacementRelay.requests.filter((request) => (
    request.method === "PUT" && request.path.startsWith("/v1/shared-settings/")
  )).length - putCountBefore).toBe(1);

  delayedOlderMutation.release();
  await page.evaluate(async () => {
    await Promise.allSettled([
      window.__olderSettingMutation,
      window.__latestSettingMutation
    ]);
  });
  await expect.poll(() => replacementRelay.requests.filter((request) => (
    request.method === "PUT" && request.path.startsWith("/v1/shared-settings/")
  )).length - putCountBefore).toBe(2);
  expect(replacementRelay.appliedSharedSettingMutations.map((setting) => setting.value)).toEqual(["0"]);
  expect(replacementRelay.sharedSettings.find((setting) => setting.key === "KLMS_UPDATE_NOTICE_NOTES")?.value).toBe("0");
  await expect(page.locator("#updateNoticeNotes")).not.toBeChecked();
  replacementRelay.rejectedSharedSettingValues.clear();
  expect(pageErrors).toEqual([]);
});

test("manual refresh uses the WebSocket snapshot without an HTTP round trip", async () => {
  await expect(page.locator("#connectionState")).toHaveText("실시간 연결됨");
  replacementRelay.items = [
    ...replacementRelay.items.filter((item) => item.id !== "race-winner-assignment"),
    {
      ...replacementRelay.items[0],
      id: "race-winner-assignment",
      title: "최신 수동 갱신 과제",
      timestamp: "2026-07-13T11:00:00+09:00",
      updatedAt: "2026-07-13T11:00:00+09:00"
    }
  ];
  replacementRelay.status = {
    ...replacementRelay.status,
    assignments: replacementRelay.items.filter((item) => item.kind === "assignment").length
  };
  replacementRelay.revision += 1;

  const requestCountBeforeRefresh = replacementRelay.requestCount;
  await page.locator("#refreshButton").click();
  await expect(page.locator("#itemList")).toContainText("최신 수동 갱신 과제");
  await expect(page.locator("#dashboardCards .metric-card", { hasText: "과제" }).locator("strong"))
    .toHaveText(String(replacementRelay.status.assignments));

  await expect.poll(() => replacementRelay.requestCount).toBe(requestCountBeforeRefresh);
  expect(pageErrors).toEqual([]);
});

test("a realtime snapshot cannot roll back an optimistic item action", async () => {
  replacementRelay.itemActions = [];
  replacementRelay.appliedItemActions = [];
  const stableItem = replacementRelay.items.find((item) => item.id === "stable-assignment");
  await expect(page.locator("#itemList")).toContainText("선택 유지 과제");
  await page.locator("#itemList .item-row", { hasText: "선택 유지 과제" }).click();

  await page.evaluate((item) => {
    window.__itemActionMutation = createItemAction("assignmentComplete", item);
  }, stableItem);
  await expect.poll(() => replacementRelay.appliedItemActions.length).toBe(1);
  await page.evaluate(async () => window.__itemActionMutation);
  await expect(page.locator("#itemDetail")).toContainText("완료 요청됨");

  const snapshotRevision = replacementRelay.publishEvent("item-actions:updated", ["syncData", "itemActions"]);
  await expect.poll(() => page.evaluate(() => state.relayRevision)).toBe(snapshotRevision);
  await expect(page.locator("#itemDetail")).toContainText("완료 요청됨");
  await expect(page.locator("#itemList .item-row.active")).toContainText("선택 유지 과제");
  expect(pageErrors).toEqual([]);
});

test("long server data stays contained through 640px, browser zoom, keyboard selection and forced colors", async () => {
  const longTitle = `LONG_TITLE_${"A".repeat(1_989)}`;
  const longPath = `/download/${"path_segment_".repeat(166)}`;
  const longStatus = `LONG_STATUS_${"진행".repeat(700)}`;
  const timestamp = "2026-07-14T02:00:00.000Z";
  replacementRelay.items = [
    {
      id: "long-content-assignment",
      kind: "assignment",
      course: `LONG_COURSE_${"과목".repeat(700)}`,
      title: longTitle,
      timestamp,
      status: longStatus,
      detail: longPath,
      updatedAt: timestamp,
      isHidden: false,
      attachmentCount: 0
    },
    ...replacementRelay.items.filter((item) => item.id !== "long-content-assignment")
  ];
  replacementRelay.status = {
    ...replacementRelay.status,
    assignments: replacementRelay.items.filter((item) => item.kind === "assignment").length
  };
  replacementRelay.message = `LONG_MESSAGE_${"M".repeat(1_987)}`;
  replacementRelay.runLogs = [{
    command: "report",
    commandTitle: longTitle,
    status: "completed",
    outputTail: longPath,
    duration: "1초",
    finishedAt: timestamp
  }];
  replacementRelay.itemActions = [{
    id: "long-item-action",
    action: "assignmentComplete",
    itemID: "long-content-assignment",
    itemKind: "assignment",
    itemTitle: longTitle,
    message: longPath,
    status: "completed",
    createdAt: timestamp,
    updatedAt: timestamp
  }];
  replacementRelay.requestLog = [{
    id: "long-request-log",
    source: "windows",
    action: longTitle,
    method: "GET",
    path: longPath,
    status: "completed",
    message: longTitle,
    createdAt: timestamp
  }];

  replacementRelay.publishEvent("long-content:updated", ["status", "syncData", "itemActions", "requestLog"]);
  const longRow = page.locator('[data-focus-key="item:long-content-assignment"]');
  await expect(longRow).toBeVisible({ timeout: 3_000 });
  await expect(page.locator("#statusSubtitle")).toContainText("LONG_MESSAGE_");
  await expect(page.locator("#statusSubtitle")).toHaveAttribute("aria-label", replacementRelay.message);
  expect(await page.locator("#statusSubtitle").evaluate((element) => Array.from(element.textContent).length))
    .toBeLessThanOrEqual(161);
  await expect(page.locator("#statusSubtitle")).toHaveText(/…$/);
  const statusDisclosure = page.locator("#statusMessageDisclosure");
  await expect(statusDisclosure).toBeVisible();
  await statusDisclosure.locator("summary").focus();
  await page.keyboard.press("Enter");
  await expect(statusDisclosure).toHaveAttribute("open", "");
  await expect(page.locator("#statusFullMessage")).toHaveText(replacementRelay.message);
  await page.keyboard.press("Enter");
  await expect(statusDisclosure).not.toHaveAttribute("open", "");
  await page.locator("#copyStateButton").click();
  const copiedState = await electronApp.evaluate(({ clipboard }) => clipboard.readText());
  expect(copiedState).toContain(replacementRelay.message);

  await setElectronZoomFactor(1);
  await resizeElectronContent(640, 900);
  await longRow.scrollIntoViewIfNeeded();
  await longRow.focus();
  await page.keyboard.press("Enter");
  await expect(longRow).toBeFocused();
  const detailTitle = page.locator("#itemDetail .detail-header h2");
  const detailDisclosure = page.locator('[data-testid="detail-overflow-disclosure"]');
  await expect(detailTitle).toHaveText(longTitle);
  await expect(detailTitle).toHaveAttribute("title", longTitle);
  await expect(detailTitle).toHaveAttribute("aria-label", longTitle);
  await expect(detailDisclosure).toBeVisible();
  await expect.poll(() => page.evaluate(() => {
    const rect = document.querySelector(".detail-pane")?.getBoundingClientRect();
    return Boolean(rect && rect.top < window.innerHeight && rect.bottom > 0);
  })).toBe(true);
  await expect.poll(() => page.evaluate(() => {
    const rect = document.querySelector(".field-grid .field")?.getBoundingClientRect();
    return Boolean(rect && rect.top < window.innerHeight && rect.bottom > 0);
  })).toBe(true);
  const boundedDetailGeometry = await page.evaluate(() => {
    const headerRect = document.querySelector(".detail-header").getBoundingClientRect();
    const titleRect = document.querySelector(".detail-header h2").getBoundingClientRect();
    const metaRect = document.querySelector(".detail-meta").getBoundingClientRect();
    const fieldRect = document.querySelector(".field-grid .field").getBoundingClientRect();
    const fieldGridRect = document.querySelector(".field-grid").getBoundingClientRect();
    return {
      headerHeight: headerRect.height,
      titleHeight: titleRect.height,
      metaHeight: metaRect.height,
      fieldGap: fieldRect.top - headerRect.bottom,
      fieldGridHeight: fieldGridRect.height,
      firstFieldTop: fieldRect.top,
      viewportHeight: window.innerHeight
    };
  });
  expect(boundedDetailGeometry.headerHeight).toBeLessThan(360);
  expect(boundedDetailGeometry.titleHeight).toBeLessThan(150);
  expect(boundedDetailGeometry.metaHeight).toBeLessThan(80);
  expect(boundedDetailGeometry.fieldGap).toBeLessThanOrEqual(16);
  expect(boundedDetailGeometry.fieldGridHeight).toBeLessThan(760);
  expect(boundedDetailGeometry.firstFieldTop).toBeLessThan(boundedDetailGeometry.viewportHeight);
  const statusFieldValue = page.locator(".field", { hasText: "상태" }).locator(".field-value").first();
  await expect(statusFieldValue).toHaveAttribute("title", longStatus);
  await expect(statusFieldValue).toHaveAttribute("aria-label", `상태: ${longStatus}`);
  await assertNoHorizontalOverflow("640px long-content layout");
  await expect(page.locator("#toast")).toBeHidden({ timeout: 4_000 });
  await captureStableScreenshot("windows-narrow-640-light-long-data");

  const disclosureSummary = detailDisclosure.locator("summary");
  await disclosureSummary.focus();
  await page.keyboard.press("Enter");
  await expect(detailDisclosure).toHaveAttribute("open", "");
  await expect(detailDisclosure.locator(".detail-overflow-copy")).toContainText(longTitle);
  const expandedCopyGeometry = await detailDisclosure.locator(".detail-overflow-copy").evaluate((element) => ({
    clientHeight: element.clientHeight,
    scrollHeight: element.scrollHeight
  }));
  expect(expandedCopyGeometry.clientHeight).toBeLessThanOrEqual(420);
  expect(expandedCopyGeometry.scrollHeight).toBeGreaterThan(expandedCopyGeometry.clientHeight);
  await page.keyboard.press("Enter");
  await expect(detailDisclosure).not.toHaveAttribute("open", "");
  await page.keyboard.press("Tab");
  expect(await page.evaluate(() => (
    document.querySelector(".detail-pane")?.contains(document.activeElement)
      && document.activeElement?.tagName === "BUTTON"
  ))).toBe(true);
  await page.locator("#detailSyncButton").scrollIntoViewIfNeeded();
  await expect(page.locator("#detailSyncButton")).toBeVisible();

  await setElectronZoomFactor(1);
  await resizeElectronContent(1280, 900);
  for (const factor of [1.25, 1.5, 2, 4]) {
    await setElectronZoomFactor(factor);
    await assertNoHorizontalOverflow(`${Math.round(factor * 100)}% zoom`);
    const viewportGeometry = await page.evaluate(() => {
      const contentRect = document.querySelector(".content").getBoundingClientRect();
      const sidebar = document.querySelector("#appSidebar");
      const sidebarRect = sidebar.getBoundingClientRect();
      return {
        innerWidth: window.innerWidth,
        contentLeft: contentRect.left,
        sidebarRight: sidebarRect.right,
        sidebarHidden: sidebar.getAttribute("aria-hidden") === "true"
      };
    });
    if (viewportGeometry.innerWidth < 720) {
      expect(Math.abs(viewportGeometry.contentLeft)).toBeLessThanOrEqual(1);
      expect(viewportGeometry.sidebarHidden).toBe(true);
      expect(viewportGeometry.sidebarRight).toBeLessThanOrEqual(1);
    }
    await expect(page.locator('[data-focus-key="item:long-content-assignment"].active')).toHaveCount(1);
    await expect(page.locator("#itemDetail .detail-header h2")).toHaveText(longTitle);
    const statusGeometry = await page.evaluate(() => {
      const content = document.querySelector(".content");
      const contentStyle = getComputedStyle(content);
      const contentRect = content.getBoundingClientRect();
      const region = document.querySelector("#syncStatusRegion").getBoundingClientRect();
      const subtitle = document.querySelector("#statusSubtitle").getBoundingClientRect();
      return {
        innerWidth: window.innerWidth,
        innerHeight: window.innerHeight,
        devicePixelRatio: window.devicePixelRatio,
        contentInnerRight: contentRect.right - Number.parseFloat(contentStyle.paddingRight),
        regionRight: region.right,
        regionWidth: region.width,
        regionPaddingRight: getComputedStyle(document.querySelector("#syncStatusRegion")).paddingRight,
        subtitleRight: subtitle.right,
        subtitleWidth: subtitle.width,
        subtitleScrollWidth: document.querySelector("#statusSubtitle").scrollWidth,
        subtitleClientWidth: document.querySelector("#statusSubtitle").clientWidth,
        subtitleLineClamp: getComputedStyle(document.querySelector("#statusSubtitle")).webkitLineClamp,
        viewportRight: document.documentElement.clientWidth
      };
    });
    expect(statusGeometry.regionRight).toBeLessThanOrEqual(statusGeometry.viewportRight + 0.5);
    expect(statusGeometry.regionRight).toBeLessThanOrEqual(statusGeometry.contentInnerRight + 0.5);
    expect(statusGeometry.subtitleRight).toBeLessThanOrEqual(statusGeometry.regionRight + 0.5);
    if (factor >= 2) {
      expect(statusGeometry.contentInnerRight - statusGeometry.subtitleRight).toBeGreaterThanOrEqual(9.5);
    }
    if (factor === 2) {
      await page.evaluate(() => window.scrollTo({ top: 0, left: 0, behavior: "auto" }));
      await expect.poll(() => page.evaluate(() => window.scrollY)).toBe(0);
      const edgeInk = await countViewportEdgeInkInElement("#statusSubtitle", 4);
      await writeStableArtifact("windows-zoom-200-status-geometry.json", JSON.stringify({
        statusGeometry,
        edgeInk
      }, null, 2));
      expect(edgeInk.differentPixels).toBe(0);
      await captureStableScreenshot("windows-zoom-200-light-long-data");
    }
  }
  await page.evaluate(() => window.scrollTo({ top: 0, left: 0, behavior: "auto" }));
  await captureStableScreenshot("windows-zoom-400-light-long-data");

  await setElectronZoomFactor(1);
  await resizeElectronContent(640, 900);
  await page.emulateMedia({ colorScheme: "light", forcedColors: "active" });
  await expect(page.locator("#dashboardCards .metric-card.active")).toBeVisible();
  const forcedColorState = await page.evaluate(() => {
    const metric = getComputedStyle(document.querySelector("#dashboardCards .metric-card.active"));
    const row = getComputedStyle(document.querySelector("#itemList .item-row.active"));
    const badge = getComputedStyle(document.querySelector("#itemList .item-row.active .badge"));
    const menuButton = getComputedStyle(document.querySelector("#sidebarToggleButton"));
    const menuIcon = getComputedStyle(document.querySelector("#sidebarToggleButton .icon"));
    const refreshButton = getComputedStyle(document.querySelector("#refreshButton"));
    const systemColorProbe = document.createElement("span");
    systemColorProbe.style.cssText = "forced-color-adjust:none;color:CanvasText;background:Canvas";
    document.body.append(systemColorProbe);
    const systemColors = getComputedStyle(systemColorProbe);
    const systemCanvas = systemColors.backgroundColor;
    const systemCanvasText = systemColors.color;
    systemColorProbe.remove();
    return {
      metricAdjustment: metric.forcedColorAdjust,
      rowAdjustment: row.forcedColorAdjust,
      metricBackground: metric.backgroundColor,
      metricColor: metric.color,
      rowBackground: row.backgroundColor,
      rowColor: row.color,
      badgeAdjustment: badge.forcedColorAdjust,
      badgeBackground: badge.backgroundColor,
      badgeColor: badge.color,
      badgeBorderStyle: badge.borderStyle,
      badgeBorderWidth: badge.borderWidth,
      systemCanvas,
      systemCanvasText,
      menuBorderStyle: menuButton.borderStyle,
      menuBorderWidth: menuButton.borderWidth,
      menuIconAdjustment: menuIcon.forcedColorAdjust,
      menuIconColor: menuIcon.backgroundColor,
      refreshBorderStyle: refreshButton.borderStyle,
      refreshBorderWidth: refreshButton.borderWidth
    };
  });
  expect(forcedColorState.metricAdjustment).toBe("none");
  expect(forcedColorState.rowAdjustment).toBe("none");
  expect(forcedColorState.metricBackground).toBe(forcedColorState.rowBackground);
  expect(forcedColorState.metricColor).toBe(forcedColorState.rowColor);
  expect(forcedColorState.metricBackground).not.toBe(forcedColorState.metricColor);
  expect(forcedColorState.badgeAdjustment).toBe("none");
  expect(forcedColorState.badgeBackground).toBe(forcedColorState.systemCanvas);
  expect(forcedColorState.badgeColor).toBe(forcedColorState.systemCanvasText);
  expect(forcedColorState.badgeBorderStyle).toBe("solid");
  expect(forcedColorState.badgeBorderWidth).not.toBe("0px");
  expect(forcedColorState.menuBorderStyle).toBe("solid");
  expect(forcedColorState.menuBorderWidth).not.toBe("0px");
  expect(forcedColorState.menuIconAdjustment).toBe("none");
  expect(forcedColorState.menuIconColor).not.toBe("rgba(0, 0, 0, 0)");
  expect(forcedColorState.refreshBorderStyle).toBe("solid");
  expect(forcedColorState.refreshBorderWidth).not.toBe("0px");
  await assertNoHorizontalOverflow("forced-colors layout");
  await captureStableScreenshot("windows-narrow-640-forced-colors-selected");
  await page.emulateMedia({ colorScheme: "light", forcedColors: "none" });
  expect(pageErrors).toEqual([]);
});

test("an encrypted dashboard cache renders immediately after an offline cold restart", async () => {
  const cacheRelay = await FakeRelay.start();
  const cacheProfile = await fs.mkdtemp(path.join(os.tmpdir(), "klms-windows-cache-e2e-"));
  let cacheApp;
  let offlineApp;
  try {
    cacheApp = await electron.launch({
      args: [electronEntry, "--disable-gpu"],
      cwd: appRoot,
      env: {
        ...process.env,
        KLMS_E2E_USER_DATA_DIR: cacheProfile,
        ELECTRON_DISABLE_SECURITY_WARNINGS: "true"
      }
    });
    const cachePage = await cacheApp.firstWindow();
    await cachePage.waitForLoadState("domcontentloaded");
    await cachePage.locator("#relayURL").fill(cacheRelay.url);
    await cachePage.locator("#relayToken").fill(TEST_TOKEN);
    await cachePage.locator("#saveConnectionButton").click();
    await expect(cachePage.locator("#itemList")).toContainText("선택 유지 과제");

    const cachePath = path.join(cacheProfile, "dashboard-cache.bin");
    await expect.poll(async () => {
      try {
        return (await fs.stat(cachePath)).size;
      } catch {
        return 0;
      }
    }).toBeGreaterThan(0);
    const encryptedCache = await fs.readFile(cachePath);
    expect(encryptedCache.byteLength).toBeLessThanOrEqual(16 * 1024 * 1024);
    expect(encryptedCache.toString("utf8")).not.toContain(TEST_TOKEN);
    expect(encryptedCache.toString("utf8")).not.toContain("선택 유지 과제");

    await cacheApp.close();
    cacheApp = null;
    await cacheRelay.close();

    const coldLaunchStartedAt = Date.now();
    offlineApp = await electron.launch({
      args: [electronEntry, "--disable-gpu"],
      cwd: appRoot,
      env: {
        ...process.env,
        KLMS_E2E_USER_DATA_DIR: cacheProfile,
        ELECTRON_DISABLE_SECURITY_WARNINGS: "true"
      }
    });
    const offlinePage = await offlineApp.firstWindow();
    await offlinePage.waitForLoadState("domcontentloaded");
    await expect(offlinePage.locator("#itemList")).toContainText("선택 유지 과제", { timeout: 2_000 });
    await expect(offlinePage.locator("#dashboardCards .metric-card", { hasText: "과제" }).locator("strong"))
      .toHaveText("1");
    expect(Date.now() - coldLaunchStartedAt).toBeLessThan(2_000);
  } finally {
    await offlineApp?.close();
    await cacheApp?.close();
    await cacheRelay.close();
    await fs.rm(cacheProfile, { recursive: true, force: true });
  }
});

async function resizeElectronContent(width, height) {
  await electronApp.evaluate(({ BrowserWindow }, size) => {
    const window = BrowserWindow.getAllWindows()[0];
    window.setContentSize(size.width, size.height, false);
  }, { width, height });
  await expect.poll(() => page.evaluate(() => window.innerWidth), { timeout: 3_000 }).toBe(width);
  await page.waitForTimeout(50);
}

async function setElectronZoomFactor(factor) {
  await electronApp.evaluate(({ BrowserWindow }, targetFactor) => {
    BrowserWindow.getAllWindows()[0].webContents.setZoomFactor(targetFactor);
  }, factor);
  await expect.poll(() => electronApp.evaluate(({ BrowserWindow }) => (
    BrowserWindow.getAllWindows()[0].webContents.getZoomFactor()
  ))).toBeCloseTo(factor, 5);
  await page.waitForTimeout(75);
}

async function captureStableScreenshot(name) {
  const screenshotDirectory = path.join(appRoot, "output", "playwright");
  await fs.mkdir(screenshotDirectory, { recursive: true });
  const screenshotPath = path.join(screenshotDirectory, `${name}.png`);
  const base64 = await electronApp.evaluate(async ({ BrowserWindow }) => {
    const image = await BrowserWindow.getAllWindows()[0].webContents.capturePage();
    return image.toPNG().toString("base64");
  });
  await fs.writeFile(screenshotPath, Buffer.from(base64, "base64"));
  await test.info().attach(name, {
    path: screenshotPath,
    contentType: "image/png"
  });
}

async function countViewportEdgeInkInElement(selector, edgeWidth) {
  const geometry = await page.evaluate((targetSelector) => {
    const rect = document.querySelector(targetSelector).getBoundingClientRect();
    return {
      top: rect.top,
      bottom: rect.bottom,
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight
    };
  }, selector);
  return electronApp.evaluate(async ({ BrowserWindow }, input) => {
    const image = await BrowserWindow.getAllWindows()[0].webContents.capturePage();
    const size = image.getSize();
    const bitmap = image.toBitmap();
    const scaleX = size.width / input.geometry.innerWidth;
    const scaleY = size.height / input.geometry.innerHeight;
    const startY = Math.max(0, Math.floor(input.geometry.top * scaleY));
    const endY = Math.min(size.height, Math.ceil(input.geometry.bottom * scaleY));
    const edgePixels = Math.max(1, Math.ceil(input.edgeWidth * scaleX));
    const referenceY = Math.max(0, startY - Math.ceil(4 * scaleY));
    const referenceOffset = (referenceY * size.width + size.width - 1) * 4;
    const reference = bitmap.subarray(referenceOffset, referenceOffset + 4);
    let differentPixels = 0;
    for (let y = startY; y < endY; y += 1) {
      for (let x = size.width - edgePixels; x < size.width; x += 1) {
        const offset = (y * size.width + x) * 4;
        if (
          bitmap[offset] !== reference[0]
          || bitmap[offset + 1] !== reference[1]
          || bitmap[offset + 2] !== reference[2]
          || bitmap[offset + 3] !== reference[3]
        ) {
          differentPixels += 1;
        }
      }
    }
    return {
      differentPixels,
      bitmapBytes: bitmap.length,
      imageSize: size,
      scaleFactors: image.getScaleFactors(),
      startY,
      endY,
      edgePixels,
      referenceY
    };
  }, { geometry, edgeWidth });
}

async function writeStableArtifact(name, contents) {
  const artifactDirectory = path.join(appRoot, "output", "playwright");
  await fs.mkdir(artifactDirectory, { recursive: true });
  await fs.writeFile(path.join(artifactDirectory, name), `${contents}\n`, "utf8");
}

async function assertNoHorizontalOverflow(label) {
  const overflow = await page.evaluate(() => {
    const viewportWidth = document.documentElement.clientWidth;
    const ignoredTags = new Set(["INPUT", "SELECT", "TEXTAREA"]);
    const elements = [document.documentElement, document.body, ...document.body.querySelectorAll("*")];
    const describe = (element) => {
      const id = element.id ? `#${element.id}` : "";
      const classes = Array.from(element.classList || []).slice(0, 3).map((name) => `.${name}`).join("");
      return `${element.tagName.toLowerCase()}${id}${classes}`;
    };
    const offenders = [];
    for (const element of elements) {
      if (ignoredTags.has(element.tagName) || element.classList?.contains("sr-only")) continue;
      if (element.closest?.('[aria-hidden="true"]')) continue;
      const style = getComputedStyle(element);
      if (style.display === "none" || style.visibility === "hidden") continue;
      const rect = element.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) continue;
      const outsideViewport = rect.left < -1 || rect.right > viewportWidth + 1;
      const scrollsHorizontally = element.scrollWidth > element.clientWidth + 1;
      if (outsideViewport || scrollsHorizontally) {
        offenders.push({
          element: describe(element),
          clientWidth: element.clientWidth,
          scrollWidth: element.scrollWidth,
          left: Math.round(rect.left * 10) / 10,
          right: Math.round(rect.right * 10) / 10,
          viewportWidth
        });
      }
      if (offenders.length >= 20) break;
    }
    return offenders;
  });
  expect(overflow, `${label}: ${JSON.stringify(overflow, null, 2)}`).toEqual([]);
}

async function readLayoutState() {
  return page.evaluate(() => {
    const shell = document.querySelector(".app-shell");
    const content = document.querySelector(".content");
    const workspace = document.querySelector(".workspace");
    const listPane = document.querySelector(".list-pane");
    const detailPane = document.querySelector(".detail-pane");
    const shellStyle = getComputedStyle(shell);
    const workspaceStyle = getComputedStyle(workspace);
    const listRect = listPane.getBoundingClientRect();
    const detailRect = detailPane.getBoundingClientRect();
    const contentRect = content.getBoundingClientRect();
    const withinViewport = (rect) => rect.left >= -0.5 && rect.right <= window.innerWidth + 0.5;
    const columnCount = (value) => value.split(" ").filter((part) => part && part !== "none").length;
    return {
      innerWidth: window.innerWidth,
      documentScrollWidth: document.documentElement.scrollWidth,
      bodyScrollWidth: document.body.scrollWidth,
      shellDisplay: shellStyle.display,
      shellColumnCount: columnCount(shellStyle.gridTemplateColumns),
      workspaceColumnCount: columnCount(workspaceStyle.gridTemplateColumns),
      workspaceIsStacked: detailRect.top >= listRect.bottom - 1,
      sidebarRailDisplay: getComputedStyle(document.querySelector(".sidebar-rail")).display,
      sidebarToggleDisplay: getComputedStyle(document.querySelector("#sidebarToggleButton")).display,
      contentWithinViewport: withinViewport(contentRect),
      workspaceChildrenWithinViewport: withinViewport(listRect) && withinViewport(detailRect)
    };
  });
}

async function readSyncPanelLayout() {
  return page.evaluate(() => {
    const primaryButtons = Array.from(document.querySelectorAll("#primarySyncButton"));
    const primary = primaryButtons[0];
    const commandsPanel = document.querySelector(".commands-panel");
    const connectionPanel = document.querySelector(".connection-panel");
    const panelStyle = getComputedStyle(commandsPanel);
    const primaryRect = primary.getBoundingClientRect();
    const commandsRect = commandsPanel.getBoundingClientRect();
    const connectionRect = connectionPanel.getBoundingClientRect();
    return {
      primaryCount: primaryButtons.length,
      primaryInsideCommands: commandsPanel.contains(primary),
      topbarContainsPrimary: document.querySelector(".topbar").contains(primary),
      primaryWidth: primaryRect.width,
      commandsContentWidth: commandsPanel.clientWidth
        - Number.parseFloat(panelStyle.paddingLeft)
        - Number.parseFloat(panelStyle.paddingRight),
      commandsTop: commandsRect.top,
      connectionTop: connectionRect.top
    };
  });
}

async function readConnectionActionLayout() {
  return page.evaluate(() => {
    const lineCount = (element) => {
      const range = document.createRange();
      range.selectNodeContents(element);
      return range.getClientRects().length;
    };
    const checkButton = document.querySelector("#checkConnectionButton");
    const clearButton = document.querySelector("#clearConnectionButton");
    const panel = document.querySelector(".connection-panel");
    return {
      checkLineCount: lineCount(checkButton),
      clearLineCount: lineCount(clearButton),
      checkWhiteSpace: getComputedStyle(checkButton).whiteSpace,
      clearWhiteSpace: getComputedStyle(clearButton).whiteSpace,
      panelShadow: getComputedStyle(panel).boxShadow
    };
  });
}

async function waitForStableRequestCount(targetRelay, stableMilliseconds = 350, timeoutMilliseconds = 5_000) {
  const startedAt = Date.now();
  let stableSince = startedAt;
  let previousCount = targetRelay.requestCount;
  while (Date.now() - startedAt < timeoutMilliseconds) {
    await new Promise((resolve) => setTimeout(resolve, 50));
    const currentCount = targetRelay.requestCount;
    if (currentCount !== previousCount) {
      previousCount = currentCount;
      stableSince = Date.now();
    } else if (Date.now() - stableSince >= stableMilliseconds) {
      return currentCount;
    }
  }
  throw new Error("relay HTTP requests did not become idle");
}
