const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const relayState = require("../src/relay-state.js");
const appRoot = path.resolve(__dirname, "..");

test("coalesces realtime refresh scopes without dropping a busy-window event", () => {
  const merged = relayState.mergeRefreshScopes(
    { commands: true, syncData: false, itemActions: false, fileAccess: false, sharedSettings: false },
    { commands: false, syncData: true, itemActions: true, fileAccess: false, sharedSettings: true }
  );
  assert.deepEqual(merged, {
    commands: true,
    syncData: true,
    itemActions: true,
    settingActions: false,
    fileAccess: false,
    requestLog: false,
    sharedSettings: true
  });
});

test("coalesces dirty render panels into one animation frame", () => {
  const frames = [];
  const renders = [];
  const scheduler = relayState.createFrameRenderScheduler(
    (callback) => frames.push(callback),
    (scope) => renders.push(scope)
  );
  scheduler.schedule({ header: true, history: false });
  scheduler.schedule({ history: true });
  scheduler.schedule({ dashboard: true, header: true });
  assert.equal(frames.length, 1);
  assert.equal(renders.length, 0);
  frames.shift()();
  assert.deepEqual(renders, [{ header: true, history: true, dashboard: true }]);
  assert.equal(scheduler.scheduled, false);
});

test("normalizes a malicious relay status before renderer state", () => {
  const normalized = relayState.normalizeRelayStatusPayload({
    ok: "yes",
    revision: "7",
    running: 1,
    message: "<img src=x onerror=globalThis.pwned=true>",
    status: {
      assignments: "</strong><img src=x onerror=alert(1)>",
      exams: "3",
      notices: 4,
      phase: "<script>alert(1)</script>",
      loginRequired: "true",
      authDigits: "12<img>",
      authStatusMessage: { html: "<img>" },
      unexpected: "not retained"
    },
    latestCommand: {
      id: "bad",
      kind: "<img>",
      status: "running"
    }
  });
  assert.deepEqual(normalized.status, {
    assignments: 0,
    exams: 0,
    notices: 4,
    loginRequired: false,
    authDigits: null,
    authStatusMessage: null
  });
  assert.equal(normalized.ok, false);
  assert.equal(normalized.revision, 7);
  assert.equal(normalized.running, false);
  assert.equal(normalized.latestCommand, null);
  assert.equal(normalized.message, "<img src=x onerror=globalThis.pwned=true>");
});

test("accepts the relay protocol's one-to-three-digit authentication code", () => {
  for (const authDigits of ["7", "57", "123"]) {
    const normalized = relayState.normalizeRelayStatusPayload({ status: { authDigits } });
    assert.equal(normalized.status.authDigits, authDigits);
  }
  for (const authDigits of ["", "1234", "12x"]) {
    const normalized = relayState.normalizeRelayStatusPayload({ status: { authDigits } });
    assert.equal(normalized.status.authDigits, null);
  }
});

test("retains every command kind supported by the relay protocol", () => {
  for (const kind of ["verify", "v2BuildState"]) {
    const normalized = relayState.normalizeRelayStatusPayload({
      latestCommand: { id: `command-${kind}`, kind, status: "pending" }
    });
    assert.equal(normalized.latestCommand?.kind, kind);
  }
});

test("revision gaps and snapshot requests force reconciliation", () => {
  assert.deepEqual(relayState.eventApplyDecision(7, { type: "changed", revision: 8 }), {
    action: "apply",
    revision: 8
  });
  assert.deepEqual(relayState.eventApplyDecision(7, { type: "changed", revision: 9 }), {
    action: "reconcile",
    revision: 9
  });
  assert.equal(relayState.eventApplyDecision(7, {
    type: "changed",
    revision: 8,
    requiresSnapshot: true
  }).action, "reconcile");
  assert.equal(relayState.eventApplyDecision(7, { type: "changed", revision: 7 }).action, "ignore");
});

test("hello and changed pong revisions recover after an authoritative relay rollback", () => {
  assert.deepEqual(relayState.eventApplyDecision(12, { type: "hello", revision: 12 }), {
    action: "reconcile",
    revision: 12
  });
  assert.deepEqual(relayState.eventApplyDecision(12, { type: "hello", revision: 3 }), {
    action: "reconcile",
    revision: 3
  });
  assert.deepEqual(relayState.eventApplyDecision(12, { type: "hello" }), {
    action: "reconcile",
    revision: null
  });
  assert.deepEqual(relayState.eventApplyDecision(12, { type: "pong", revision: 3 }), {
    action: "reconcile",
    revision: 3
  });
  assert.equal(relayState.eventApplyDecision(12, { type: "pong", revision: 12 }).action, "ignore");
  assert.equal(relayState.eventApplyDecision(3, { type: "changed", revision: 4 }).action, "apply");
});

test("relay events map to the smallest complete HTTP reconciliation scope", () => {
  const presets = {
    full: relayState.fullRefreshScope(),
    state: { commands: true },
    syncData: { syncData: true },
    settings: { settingActions: true, requestLog: true, sharedSettings: true },
    fileAccess: { fileAccess: true },
    itemActions: { itemActions: true },
    settingActions: { settingActions: true },
    requestLog: { requestLog: true },
    displayLogs: { commands: true, itemActions: true, settingActions: true, fileAccess: true, requestLog: true }
  };
  assert.deepEqual(
    relayState.refreshScopeForEvent({ scopes: ["syncData", "sharedSettings"] }, presets),
    {
      commands: false,
      syncData: true,
      itemActions: false,
      settingActions: false,
      fileAccess: false,
      requestLog: false,
      sharedSettings: true
    }
  );
  assert.deepEqual(
    relayState.refreshScopeForEvent({ scopes: ["requestLog"] }, presets),
    {
      commands: false,
      syncData: false,
      itemActions: false,
      settingActions: false,
      fileAccess: false,
      requestLog: true,
      sharedSettings: false
    }
  );
  assert.deepEqual(
    relayState.refreshScopeForEvent({
      scopes: ["status", "syncData", "commands", "itemActions", "settingActions", "sharedSettings", "runLogs", "fileAccess", "requestLog", "cancel"]
    }, presets),
    relayState.fullRefreshScope()
  );
  assert.deepEqual(
    relayState.refreshScopeForEvent({ scopes: ["syncData", "futureScope"] }, presets),
    relayState.fullRefreshScope(),
    "An unknown declared scope must force a forward-compatible full reconciliation."
  );
});

test("unknown protocol versions reconcile and connection generations reject stale work", () => {
  assert.deepEqual(relayState.eventApplyDecision(5, {
    version: 2,
    type: "changed",
    revision: 6
  }), { action: "reconcile", revision: 6 });
  assert.equal(relayState.eventApplyDecision(5, {
    version: 1,
    type: "ping",
    revision: 6
  }).action, "ignore");
  assert.equal(relayState.isCurrentConnection(3, 3, true), true);
  assert.equal(relayState.isCurrentConnection(2, 3, true), false);
  assert.equal(relayState.isCurrentConnection(3, 3, false), false);
});

test("relay mutations require the renderer-captured config revision and abort on replacement", () => {
  assert.equal(relayState.mutationConfigRevisionMatches("GET", null, 4, 9), true);
  assert.equal(relayState.mutationConfigRevisionMatches("PUT", 4, 4, 4), true);
  assert.equal(relayState.mutationConfigRevisionMatches("POST", null, 4, 4), false);
  assert.equal(relayState.mutationConfigRevisionMatches("DELETE", 3, 4, 4), false);
  assert.equal(relayState.mutationConfigRevisionMatches("PATCH", 4, 4, 5), false);

  const registry = relayState.createConfigBoundMutationRegistry();
  const oldController = new AbortController();
  const currentController = new AbortController();
  const releaseOld = registry.track(oldController, 4);
  const releaseCurrent = registry.track(currentController, 5);
  assert.equal(registry.size, 2);
  assert.equal(registry.abortStale(5), 1);
  assert.equal(oldController.signal.aborted, true);
  assert.equal(currentController.signal.aborted, false);
  assert.equal(registry.size, 1);
  releaseOld();
  releaseCurrent();
  assert.equal(registry.size, 0);
});

test("per-key mutation queue preserves request order under reversed latency", async () => {
  const queue = relayState.createKeyedSerialMutationQueue();
  const order = [];
  let releaseOlder;
  const olderGate = new Promise((resolve) => { releaseOlder = resolve; });
  const older = queue.enqueue("notice-notes", async () => {
    order.push("older-start");
    await olderGate;
    order.push("older-end");
    return "older";
  });
  await Promise.resolve();
  const latest = queue.enqueue("notice-notes", async () => {
    order.push("latest-start");
    order.push("latest-end");
    return "latest";
  });

  await Promise.resolve();
  assert.deepEqual(order, ["older-start"]);
  releaseOlder();
  assert.equal(await older, "older");
  assert.equal(await latest, "latest");
  assert.deepEqual(order, ["older-start", "older-end", "latest-start", "latest-end"]);
  assert.equal(queue.has("notice-notes"), false);
});

test("reconnect jitter stays bounded around the 250/500/1000/2000ms backoff", () => {
  assert.deepEqual(
    [250, 500, 1_000, 2_000].map((delay) => relayState.jitteredReconnectDelay(delay, () => 0.5)),
    [250, 500, 1_000, 2_000]
  );
  assert.equal(relayState.jitteredReconnectDelay(250, () => 0), 250);
  assert.equal(relayState.jitteredReconnectDelay(250, () => 1), 275);
  assert.equal(relayState.jitteredReconnectDelay(2_000, () => 0), 1_900);
  assert.equal(relayState.jitteredReconnectDelay(2_000, () => 1), 2_000);
});

test("accepts only the versioned first-frame relay hello", () => {
  assert.equal(relayState.isValidRelayHello({ type: "hello", version: 1, revision: 0 }), true);
  assert.equal(relayState.isValidRelayHello({ type: "hello", version: 1, revision: 12 }), true);
  assert.equal(relayState.isValidRelayHello({ type: "changed", version: 1, revision: 0 }), false);
  assert.equal(relayState.isValidRelayHello({ type: "hello", version: 2, revision: 0 }), false);
  assert.equal(relayState.isValidRelayHello({ type: "hello", version: "1", revision: 0 }), false);
  assert.equal(relayState.isValidRelayHello({ type: "hello", version: 1, revision: -1 }), false);
  assert.equal(relayState.isValidRelayHello({ type: "hello", version: 1, revision: "0" }), false);
});

test("busy controls preserve an independently disabled state", () => {
  const normalControl = { disabled: false, dataset: {} };
  relayState.setControlBusy(normalControl, true);
  assert.equal(normalControl.disabled, true);
  relayState.setControlBusy(normalControl, false);
  assert.equal(normalControl.disabled, false);

  const semanticDisabledControl = { disabled: true, dataset: {} };
  relayState.setControlBusy(semanticDisabledControl, true);
  relayState.setControlBusy(semanticDisabledControl, false);
  assert.equal(semanticDisabledControl.disabled, true);
});

test("switching or clearing a relay removes all server-derived state", () => {
  const target = {
    items: [{ id: "old" }],
    recentFileAccess: [{ itemTitle: "private.pdf" }],
    sharedSettings: [{ key: "old" }],
    recentCommands: [{ id: "old-command" }],
    recentActions: [{ id: "old-action" }],
    recentSettingActions: [{ id: "old-setting-action" }],
    recentRequestLog: [{ id: "old-request" }],
    runLogs: [{ id: "old-run" }],
    relayRevision: 99,
    socketConnected: true
  };
  relayState.resetRemoteState(target, { phase: "idle" });
  assert.deepEqual(target.items, []);
  assert.deepEqual(target.recentFileAccess, []);
  assert.deepEqual(target.sharedSettings, []);
  assert.deepEqual(target.recentCommands, []);
  assert.deepEqual(target.recentActions, []);
  assert.deepEqual(target.recentSettingActions, []);
  assert.deepEqual(target.recentRequestLog, []);
  assert.deepEqual(target.runLogs, []);
  assert.equal(target.relayRevision, 0);
  assert.equal(target.socketConnected, false);
});

test("Windows client uses WebSocket triggers and responsive layout breakpoints", () => {
  const mainSource = fs.readFileSync(path.join(appRoot, "src/main.cjs"), "utf8");
  const rendererSource = fs.readFileSync(path.join(appRoot, "src/renderer.js"), "utf8");
  const styles = fs.readFileSync(path.join(appRoot, "src/styles.css"), "utf8");
  const indexSource = fs.readFileSync(path.join(appRoot, "src/index.html"), "utf8");
  assert.match(mainSource, /new WebSocket\(/);
  assert.match(mainSource, /\/v1\/events/);
  assert.match(mainSource, /socketURL\.protocol === "https:" \? "wss:" : "ws:"/);
  assert.match(mainSource, /connectionGeneration: clientGeneration/);
  assert.match(mainSource, /activeMutationRequests\.track\(controller, expectedConfigRevision\)/);
  assert.match(mainSource, /activeMutationRequests\.abortStale\(relayConfigRevision\)/);
  assert.match(mainSource, /configRevision: Math\.max\(relayConfigRevision, storedConfigRevision\(config\)\)/);
  assert.match(mainSource, /const delay = jitteredReconnectDelay\(relaySocketReconnectDelay\)/);
  const openHandler = mainSource.match(/socket\.on\("open",[\s\S]*?\n    \}\);/)?.[0] || "";
  const messageHandler = mainSource.match(/socket\.on\("message",[\s\S]*?\n    \}\);/)?.[0] || "";
  assert.doesNotMatch(openHandler, /state: "connected"|startRelaySocketHeartbeat/);
  assert.match(messageHandler, /if \(!isValidRelayHello\(event\)\)/);
  assert.ok(messageHandler.indexOf("isValidRelayHello(event)") < messageHandler.indexOf('state: "connected"'));
  assert.ok(messageHandler.indexOf('state: "connected"') < messageHandler.indexOf("startRelaySocketHeartbeat"));
  assert.match(mainSource, /sandbox:\s*true/);
  assert.match(mainSource, /setWindowOpenHandler\(\(\) => \(\{ action: "deny" \}\)\)/);
  assert.match(mainSource, /webContents\.on\("will-navigate"/);
  assert.match(mainSource, /normalizeExternalURL\(target\)/);
  assert.doesNotMatch(`${mainSource}\n${rendererSource}`, /\/events\/poll/);
  assert.doesNotMatch(rendererSource, /scheduleAutoRefresh|AUTO_REFRESH/);
  assert.match(rendererSource, /REALTIME_RETRY_MAX_MS = 2_000/);
  assert.match(rendererSource, /isCurrentConnectionPayload/);
  assert.match(rendererSource, /relayObservedRevision = eventRevision \?\? 0/);
  assert.match(rendererSource, /options\.authoritativeSnapshot/);
  assert.match(rendererSource, /relayMutationRequest\(request, expectedConfigRevision\)/);
  assert.match(rendererSource, /expectedConfigRevision/);
  assert.match(rendererSource, /settingMutationQueue\.enqueue\(key/);
  assert.match(rendererSource, /const committedSetting = settingCommittedBaselines\.get\(key\)\?\.value/);
  assert.match(rendererSource, /state\.items = itemsOverlayingPendingActions\(syncData\.items \|\| \[\]\)/);
  assert.match(rendererSource, /const overlaidCommands = commandsOverlayingPending/);
  assert.match(rendererSource, /refreshOperationID === latestRefreshApplyOperationID/);
  assert.match(rendererSource, /applyResultWhenCurrent\("status", requests\.status/);
  assert.match(rendererSource, /applyResultWhenCurrent\("commands", requests\.commands/);
  assert.match(rendererSource, /applyResultWhenCurrent\("syncData", requests\.syncData/);
  assert.match(rendererSource, /applyResultWhenCurrent\("requestLog", requests\.requestLog/);
  assert.match(rendererSource, /refreshRealtimePreview\(scope, relayRevisionEpoch\)/);
  assert.match(rendererSource, /relayEndpointApplyIsCurrent\(endpoint, applyVersion\)/);
  assert.match(rendererSource, /preferredCommandState\(pendingCommand, commands\[index\]\)/);
  assert.match(rendererSource, /normalizeRelayStatusPayload\(payload\)/);
  assert.match(rendererSource, /commandOverlayingKnownState\(normalizedPayload\.latestCommand\)/);
  assert.match(rendererSource, /normalizeRemoteCommand\(command\)/);
  assert.match(rendererSource, /\.map\(\(command\) => commandOverlayingKnownState\(command\)\)/);
  assert.match(rendererSource, /if \(currentTerminal !== incomingTerminal\)/);
  assert.match(rendererSource, /preferredLatestCommand\(state\.latestCommand, overlaidCommands\[0\] \|\| null\)/);
  assert.match(rendererSource, /state\.recentCommands = reconciledCommands/);
  assert.match(rendererSource, /state\.message = terminalCommandMessage\(confirmedTerminalCommand\)/);
  assert.match(rendererSource, /renderPrimarySyncAction\(\)/);
  assert.match(rendererSource, /createFrameRenderScheduler/);
  assert.match(rendererSource, /preserveKeyboardFocus/);
  assert.doesNotMatch(rendererSource, /\.innerHTML\s*=|insertAdjacentHTML|\.outerHTML\s*=/);
  assert.match(rendererSource, /command\.kind !== "fullSync"/);
  assert.match(rendererSource, /isServerConfirmedCommand\(command\)/);
  assert.match(rendererSource, /path: "\/v1\/cancel"/);
  assert.match(rendererSource, /commandID: command\.id/);
  assert.match(rendererSource, /renderCommands\(\);/);
  assert.match(rendererSource, /confirmsTerminalState: false/);
  assert.match(rendererSource, /pendingCommandOverlays\.set\(command\.id, command\)/);
  assert.match(rendererSource, /pendingCommandIDsBeforeRefresh\.has\(command\.id\) && isTerminalStatus\(command\.status\)/);
  assert.match(rendererSource, /state\.status = \{[\s\S]*phase: confirmedTerminalCommand\.status/);
  assert.match(rendererSource, /pendingItemActionOverlays\.set\(item\.id, \{/);
  assert.match(rendererSource, /appliesToItem: !savedActionFailed/);
  assert.match(rendererSource, /pendingFileAccessOverlays\.set\(request\.id, request\)/);
  assert.match(rendererSource, /sidebarReturnFocus = event\.currentTarget/);
  assert.match(rendererSource, /setSidebarOpen\(opening, opening \? "commands" : ""\)/);
  assert.match(rendererSource, /panel\?\.querySelector\([\s\S]*?\.focus\(\{ preventScroll: true \}\)/);
  assert.match(rendererSource, /const focusTarget = returnFocus\?\.getClientRects\(\)\.length \? returnFocus : \$\("primarySyncButton"\)/);
  assert.match(rendererSource, /content\.inert = shouldOpen/);
  assert.match(rendererSource, /function trapSidebarFocus\(event\)/);
  assert.match(rendererSource, /state\.recentFileAccess = fileAccessRequestsOverlayingPending/);
  assert.match(rendererSource, /\/v1\/request-log\/recent\?limit=20/);
  assert.match(rendererSource, /\/v1\/setting-actions\/recent\?limit=10/);
  assert.match(rendererSource, /state\.runLogs = Array\.isArray\(syncData\.runLogs\)/);
  assert.match(styles, /@media \(max-width: 1039px\)/);
  assert.match(styles, /@media \(max-width: 719px\)/);
  assert.match(styles, /\.primary-sync-action\s*\{/);
  assert.match(styles, /\.commands-panel > \.primary-sync-action\s*\{[\s\S]*?width:\s*100%;[\s\S]*?min-width:\s*0;/);
  assert.match(styles, /body\.sidebar-open \.sidebar\s*\{[\s\S]*?display:\s*flex;[\s\S]*?flex-direction:\s*column;/);
  assert.match(styles, /body\.sidebar-open \.commands-panel\s*\{\s*order:\s*1;/);
  assert.match(styles, /body\.sidebar-open \.connection-panel\s*\{\s*order:\s*2;/);
  assert.match(styles, /grid-template-columns:\s*minmax\(0, 42%\) minmax\(0, 1fr\)/);
  assert.doesNotMatch(styles, /min-width:\s*920px/);
  assert.match(styles, /prefers-color-scheme:\s*dark/);
  assert.match(indexSource, /Content-Security-Policy/);
  assert.match(indexSource, /require-trusted-types-for 'script'/);

  const commandPanelSource = indexSource.match(/<section class="panel commands-panel">[\s\S]*?<\/section>/)?.[0] || "";
  const topbarSource = indexSource.match(/<header class="topbar">[\s\S]*?<\/header>/)?.[0] || "";
  assert.equal((indexSource.match(/id="primarySyncButton"/g) || []).length, 1);
  assert.match(commandPanelSource, /id="primarySyncButton"/);
  assert.doesNotMatch(topbarSource, /id="primarySyncButton"/);
  assert.ok(commandPanelSource.indexOf("primarySyncButton") < commandPanelSource.indexOf("commandButtons"));
  assert.ok(indexSource.indexOf("connection-panel") < indexSource.indexOf("commands-panel"));
});
