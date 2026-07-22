const http = require("node:http");
const { createHash, randomUUID } = require("node:crypto");
const { WebSocket, WebSocketServer } = require("ws");

const TEST_TOKEN = "klms-windows-e2e-token";
const REALTIME_SCOPES = [
  "status", "syncData", "commands", "itemActions", "settingActions", "sharedSettings",
  "runLogs", "fileAccess", "requestLog", "cancel"
];
const MAX_REALTIME_FRAME_BYTES = 64 * 1024;
const MAX_REALTIME_SNAPSHOT_BYTES = 8 * 1024 * 1024;
const MAX_REALTIME_SNAPSHOT_CHUNKS = 254;
const REALTIME_SNAPSHOT_CHUNK_BYTES = 43 * 1024;

class FakeRelay {
  constructor() {
    this.revision = 0;
    this.requests = [];
    this.upgrades = [];
    this.clients = new Set();
    this.realtimeEvents = [];
    this.sharedSettings = [];
    this.itemActions = [];
    this.settingActions = [];
    this.fileAccessRequests = [];
    this.requestLog = [];
    this.runLogs = [];
    this.appliedItemActions = [];
    this.commands = [];
    this.latestCommand = null;
    this.running = false;
    this.message = "E2E relay ready";
    this.cancelRequests = [];
    this.appliedSharedSettingMutations = [];
    this.rejectedSharedSettingValues = new Set();
    this.abortedSharedSettingMutations = 0;
    this.nextSharedSettingMutationGate = null;
    this.pendingSharedSettingMutationGates = new Set();
    this.nextSyncDataGate = null;
    this.nextCommandMutationGate = null;
    this.nextRequestLogGate = null;
    this.nextSnapshotDeliveryGate = null;
    this.nextCommandsSnapshot = null;
    this.nextStatusSnapshot = null;
    this.performanceFixture = null;
    this.status = {
      assignments: 1,
      exams: 0,
      notices: 0,
      fileTotal: 0,
      newFiles: 0,
      quarantine: 0,
      phase: "idle"
    };
    this.items = [relayItem("stable-assignment", "선택 유지 과제", "2026-07-13T09:00:00+09:00")];
    this.server = http.createServer((request, response) => {
      this.handleRequest(request, response).catch((error) => {
        if (!response.destroyed && !response.headersSent) {
          writeJSON(response, 500, { error: error?.message || "fake relay request failed" });
        }
      });
    });
    this.webSockets = new WebSocketServer({ noServer: true });
    this.server.on("upgrade", (request, socket, head) => this.handleUpgrade(request, socket, head));
    this.webSockets.on("connection", (socket) => this.handleWebSocket(socket));
  }

  static async start() {
    const relay = new FakeRelay();
    await new Promise((resolve, reject) => {
      relay.server.once("error", reject);
      relay.server.listen(0, "127.0.0.1", () => {
        relay.server.off("error", reject);
        resolve();
      });
    });
    return relay;
  }

  get url() {
    const address = this.server.address();
    return `http://127.0.0.1:${address.port}`;
  }

  get requestCount() {
    return this.requests.length;
  }

  seedPerformanceItems(count = 2_000) {
    const fixture = createPerformanceFixture(count);
    this.items = fixture.items.map((item) => ({ ...item }));
    this.status = { ...fixture.status };
    this.performanceFixture = { ...fixture.metadata };
    this.message = `E2E relay ready with ${count} items`;
    return { ...this.performanceFixture };
  }

  publishItemUpdate(id, patch = {}) {
    const itemIndex = this.items.findIndex((item) => item.id === id);
    if (itemIndex < 0) {
      throw new Error(`missing fake relay item: ${id}`);
    }
    this.items[itemIndex] = { ...this.items[itemIndex], ...patch, id };
    this.status = summarizePerformanceItems(this.items, this.status);
    return this.publishEvent("sync-data:item-updated", ["status", "syncData"]);
  }

  publishChanged() {
    this.status = { ...this.status, assignments: this.status.assignments + 1 };
    this.items = [
      ...this.items,
      relayItem("realtime-assignment", "실시간 갱신 과제", "2026-07-13T10:00:00+09:00")
    ];
    return this.publishEvent("sync-data:updated", ["status", "syncData"]);
  }

  publishAssignment(id, title) {
    const timestamp = new Date(Date.UTC(2026, 6, 13, 2, this.items.length)).toISOString();
    this.items = [
      ...this.items.filter((item) => item.id !== id),
      relayItem(id, title, timestamp)
    ];
    this.status = {
      ...this.status,
      assignments: this.items.filter((item) => item.kind === "assignment").length
    };
    return this.publishEvent("sync-data:updated", ["status", "syncData"]);
  }

  publishEvent(reason, scopes) {
    this.revision += 1;
    const normalizedScopes = normalizeRealtimeScopes(scopes);
    if (!normalizedScopes) throw new Error("invalid realtime scopes");
    for (const client of this.clients) {
      if (client.readyState !== WebSocket.OPEN) continue;
      const event = {
        version: 1,
        type: "changed",
        revision: this.revision,
        reason,
        scopes: normalizedScopes,
        requiresSnapshot: false,
        sessionID: client.klmsSessionID
      };
      if (client.klmsPendingSnapshot) {
        const existing = client.klmsQueuedBroadcast;
        client.klmsQueuedBroadcast = {
          ...event,
          reason: existing ? "coalesced" : event.reason,
          scopes: normalizeRealtimeScopes([...new Set([...(existing?.scopes || []), ...normalizedScopes])])
        };
      } else {
        this.startBroadcastSnapshot(client, event);
      }
    }
    return this.revision;
  }

  prepareSnapshot(client, scopes, requestID = null) {
    return encodeRealtimeSnapshot({
      sessionID: client.klmsSessionID,
      revision: this.revision,
      scopes,
      requestID,
      payload: this.snapshotPayload(scopes, requestID)
    });
  }

  startBroadcastSnapshot(client, event) {
    const scopes = normalizeRealtimeScopes(event.scopes);
    const currentEvent = {
      ...event,
      revision: this.revision,
      scopes,
      sessionID: client.klmsSessionID,
      requiresSnapshot: false
    };
    const prepared = this.prepareSnapshot(client, scopes);
    client.klmsPendingSnapshot = prepared;
    this.realtimeEvents.push({ ...currentEvent });
    client.send(JSON.stringify(currentEvent));
    client.send(prepared.beginFrame);
  }

  drainSnapshotQueue(client) {
    if (client.klmsPendingSnapshot || client.readyState !== WebSocket.OPEN) return;
    if (client.klmsQueuedBroadcast) {
      const event = client.klmsQueuedBroadcast;
      client.klmsQueuedBroadcast = null;
      this.startBroadcastSnapshot(client, event);
      return;
    }
    if (client.klmsQueuedManualRequest) {
      const request = client.klmsQueuedManualRequest;
      client.klmsQueuedManualRequest = null;
      const prepared = this.prepareSnapshot(client, request.scopes, request.requestID);
      client.klmsPendingSnapshot = prepared;
      client.send(prepared.beginFrame);
    }
  }

  snapshotPayload(scopes, requestID) {
    const payload = {
      version: 1,
      revision: this.revision,
      scopes,
      requestID
    };
    if (scopes.includes("status")) {
      payload.status = {
        ok: true,
        revision: this.revision,
        status: { ...this.status },
        latestCommand: this.latestCommand,
        running: this.running,
        message: this.message
      };
    }
    if (scopes.includes("commands")) payload.commands = { commands: this.commands.slice(0, 8) };
    if (scopes.includes("syncData") || scopes.includes("runLogs")) {
      payload.syncData = {
        revision: this.revision,
        items: this.items.map((item) => ({ ...item })),
        calendarChanges: [],
        verifySummary: null,
        runLogs: this.runLogs.map((log) => ({ ...log })),
        sharedSettings: this.sharedSettings.map((setting) => ({ ...setting }))
      };
    }
    if (scopes.includes("itemActions")) payload.itemActions = { actions: this.itemActions.slice(0, 10) };
    if (scopes.includes("settingActions")) payload.settingActions = { actions: this.settingActions.slice(0, 10) };
    if (scopes.includes("fileAccess")) payload.fileAccess = { requests: this.fileAccessRequests.slice(0, 20) };
    if (scopes.includes("requestLog")) payload.requestLog = { entries: this.requestLog.slice(0, 20) };
    if (scopes.includes("sharedSettings")) payload.sharedSettings = { settings: this.sharedSettings };
    return payload;
  }

  markLatestCommand(status, extraScopes = []) {
    if (!this.latestCommand) throw new Error("no command to update");
    const updated = {
      ...this.latestCommand,
      status,
      updatedAt: new Date().toISOString(),
      summary: { ...(this.latestCommand.summary || this.status), phase: status }
    };
    this.commands = this.commands.map((command) => command.id === updated.id ? updated : command);
    this.latestCommand = updated;
    this.running = status === "running";
    this.status = { ...this.status, phase: status };
    this.message = `${updated.kind} ${status}`;
    this.publishEvent(`commands:${status}`, ["status", "commands", ...extraScopes]);
    return updated;
  }

  publishCommand(status = "running", extraScopes = []) {
    const now = new Date().toISOString();
    const command = {
      id: randomUUID(),
      kind: "fullSync",
      status,
      options: {},
      summary: { ...this.status, phase: status },
      createdAt: now,
      updatedAt: now
    };
    this.commands = [command, ...this.commands.filter((candidate) => candidate.id !== command.id)];
    this.latestCommand = command;
    this.running = status === "running";
    this.status = { ...this.status, phase: status };
    this.message = `${command.kind} ${status}`;
    this.publishEvent(`commands:${status}`, ["status", "commands", ...extraScopes]);
    return command;
  }

  restoreLowerRevision() {
    this.revision = 0;
    this.status = { ...this.status, assignments: 2 };
    this.items = [
      relayItem("stable-assignment", "선택 유지 과제", "2026-07-13T09:00:00+09:00"),
      relayItem("restored-assignment", "복원된 서버 과제", "2026-07-13T09:30:00+09:00")
    ];
    for (const client of this.clients) {
      client.terminate();
    }
    return this.revision;
  }

  delayNextSharedSettingMutation() {
    if (this.nextSharedSettingMutationGate) {
      throw new Error("a shared-setting mutation is already delayed");
    }
    let markStarted;
    let release;
    const started = new Promise((resolve) => { markStarted = resolve; });
    const waiting = new Promise((resolve) => { release = resolve; });
    const gate = { started, waiting, markStarted, release };
    this.nextSharedSettingMutationGate = gate;
    return { started, release };
  }

  delayNextSyncDataResponse() {
    if (this.nextSyncDataGate) {
      throw new Error("a sync-data response is already delayed");
    }
    let markStarted;
    let release;
    const started = new Promise((resolve) => { markStarted = resolve; });
    const waiting = new Promise((resolve) => { release = resolve; });
    this.nextSyncDataGate = { started, waiting, markStarted, release };
    return { started, release };
  }

  delayNextCommandResponse() {
    if (this.nextCommandMutationGate) {
      throw new Error("a command mutation is already delayed");
    }
    let markStarted;
    let release;
    const started = new Promise((resolve) => { markStarted = resolve; });
    const waiting = new Promise((resolve) => { release = resolve; });
    this.nextCommandMutationGate = { started, waiting, markStarted, release };
    return { started, release };
  }

  delayNextRequestLogResponse() {
    if (this.nextRequestLogGate) {
      throw new Error("a request-log response is already delayed");
    }
    let markStarted;
    let release;
    const started = new Promise((resolve) => { markStarted = resolve; });
    const waiting = new Promise((resolve) => { release = resolve; });
    this.nextRequestLogGate = { started, waiting, markStarted, release };
    return { started, release };
  }

  delayNextSnapshotDelivery() {
    if (this.nextSnapshotDeliveryGate) {
      throw new Error("a realtime snapshot delivery is already delayed");
    }
    let markStarted;
    let release;
    const started = new Promise((resolve) => { markStarted = resolve; });
    const waiting = new Promise((resolve) => { release = resolve; });
    this.nextSnapshotDeliveryGate = { started, waiting, markStarted, release };
    return { started, release };
  }

  snapshotCommandsForNextResponse() {
    this.nextCommandsSnapshot = this.commands.map((command) => ({
      ...command,
      summary: command.summary ? { ...command.summary } : command.summary
    }));
  }

  snapshotStatusForNextResponse() {
    this.nextStatusSnapshot = {
      ok: true,
      revision: this.revision,
      status: { ...this.status },
      latestCommand: this.latestCommand ? {
        ...this.latestCommand,
        summary: this.latestCommand.summary ? { ...this.latestCommand.summary } : this.latestCommand.summary
      } : null,
      running: this.running,
      message: this.message
    };
  }

  async close() {
    this.nextSharedSettingMutationGate?.release();
    this.nextSyncDataGate?.release();
    this.nextCommandMutationGate?.release();
    this.nextRequestLogGate?.release();
    this.nextSnapshotDeliveryGate?.release();
    for (const gate of this.pendingSharedSettingMutationGates) {
      gate.release();
    }
    for (const client of this.clients) {
      client.terminate();
    }
    this.clients.clear();
    await new Promise((resolve) => this.webSockets.close(() => resolve()));
    await new Promise((resolve) => {
      this.server.close(() => resolve());
      this.server.closeAllConnections?.();
    });
  }

  async handleRequest(request, response) {
    const url = new URL(request.url || "/", this.url);
    this.requests.push({ method: request.method || "GET", path: `${url.pathname}${url.search}` });

    if (url.pathname !== "/healthz" && request.headers.authorization !== `Bearer ${TEST_TOKEN}`) {
      writeJSON(response, 401, { error: "unauthorized" });
      return;
    }

    if (request.method === "PUT" && url.pathname.startsWith("/v1/shared-settings/")) {
      await this.handleSharedSettingMutation(request, response, url);
      return;
    }
    if (request.method === "POST" && url.pathname === "/v1/item-actions") {
      await this.handleItemActionMutation(request, response);
      return;
    }
    if (request.method === "POST" && url.pathname === "/v1/commands") {
      await this.handleCommandMutation(request, response);
      return;
    }
    if (request.method === "POST" && url.pathname === "/v1/cancel") {
      await this.handleCancelMutation(request, response);
      return;
    }

    switch (url.pathname) {
      case "/healthz":
        writeJSON(response, 200, { ok: true });
        return;
      case "/v1/status":
        writeJSON(response, 200, this.nextStatusSnapshot || {
          ok: true,
          revision: this.revision,
          status: this.status,
          latestCommand: this.latestCommand,
          running: this.running,
          message: this.message
        });
        this.nextStatusSnapshot = null;
        return;
      case "/v1/commands/recent":
        writeJSON(response, 200, {
          commands: this.nextCommandsSnapshot || this.commands
        });
        this.nextCommandsSnapshot = null;
        return;
      case "/v1/sync-data":
        {
          const payload = {
            revision: this.revision,
            items: this.items.map((item) => ({ ...item })),
            calendarChanges: [],
            verifySummary: null,
            runLogs: this.runLogs.map((log) => ({ ...log })),
            sharedSettings: this.sharedSettings.map((setting) => ({ ...setting }))
          };
        if (this.nextSyncDataGate) {
          const gate = this.nextSyncDataGate;
          this.nextSyncDataGate = null;
          gate.markStarted();
          await gate.waiting;
          if (response.destroyed) return;
        }
        writeJSON(response, 200, payload);
        return;
        }
      case "/v1/item-actions/recent":
        writeJSON(response, 200, { actions: this.itemActions });
        return;
      case "/v1/setting-actions/recent":
        writeJSON(response, 200, { actions: this.settingActions });
        return;
      case "/v1/file-access/recent":
        writeJSON(response, 200, { requests: this.fileAccessRequests });
        return;
      case "/v1/request-log/recent":
        if (this.nextRequestLogGate) {
          const gate = this.nextRequestLogGate;
          this.nextRequestLogGate = null;
          gate.markStarted();
          await gate.waiting;
          if (response.destroyed) return;
        }
        writeJSON(response, 200, { entries: this.requestLog });
        return;
      case "/v1/shared-settings":
        writeJSON(response, 200, { settings: this.sharedSettings });
        return;
      default:
        writeJSON(response, 404, { error: `unexpected test route: ${url.pathname}` });
    }
  }

  async handleSharedSettingMutation(request, response, url) {
    const body = await readJSONBody(request);
    const gate = this.nextSharedSettingMutationGate;
    this.nextSharedSettingMutationGate = null;
    let disconnected = false;
    const markDisconnected = () => {
      if (!response.writableEnded && !disconnected) {
        disconnected = true;
        this.abortedSharedSettingMutations += 1;
      }
    };
    response.once("close", markDisconnected);
    if (gate) {
      this.pendingSharedSettingMutationGates.add(gate);
      gate.markStarted();
      await gate.waiting;
      this.pendingSharedSettingMutationGates.delete(gate);
    }
    response.off("close", markDisconnected);
    if (disconnected || response.destroyed) {
      return;
    }

    if (this.rejectedSharedSettingValues.has(String(body.value ?? ""))) {
      writeJSON(response, 500, { error: "rejected test setting value" });
      return;
    }

    const key = decodeURIComponent(url.pathname.slice("/v1/shared-settings/".length));
    const setting = {
      key,
      title: typeof body.title === "string" ? body.title : key,
      value: typeof body.value === "string" ? body.value : "",
      valueKind: typeof body.valueKind === "string" ? body.valueKind : "text",
      options: Array.isArray(body.options) ? body.options : [],
      editable: body.editable !== false,
      updatedAt: typeof body.updatedAt === "string" ? body.updatedAt : new Date().toISOString()
    };
    this.sharedSettings = [
      ...this.sharedSettings.filter((candidate) => candidate.key !== key),
      setting
    ];
    this.appliedSharedSettingMutations.push(setting);
    writeJSON(response, 200, setting);
  }

  async handleItemActionMutation(request, response) {
    const body = await readJSONBody(request);
    const action = {
      id: `item-action-${this.appliedItemActions.length + 1}`,
      action: body.action,
      itemID: body.itemID,
      itemKind: body.itemKind,
      itemTitle: body.itemTitle,
      message: body.message || "",
      status: "pending",
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString()
    };
    this.itemActions = [action, ...this.itemActions.filter((candidate) => candidate.id !== action.id)];
    this.appliedItemActions.push(action);
    writeJSON(response, 200, action);
  }

  async handleCommandMutation(request, response) {
    const body = await readJSONBody(request);
    if (this.nextCommandMutationGate) {
      const gate = this.nextCommandMutationGate;
      this.nextCommandMutationGate = null;
      gate.markStarted();
      await gate.waiting;
      if (response.destroyed) return;
    }
    const now = new Date().toISOString();
    const command = {
      id: randomUUID(),
      kind: body.kind,
      status: "pending",
      options: body.options || {},
      summary: { ...this.status, phase: "pending" },
      createdAt: now,
      updatedAt: now
    };
    this.commands = [command, ...this.commands.filter((candidate) => candidate.id !== command.id)];
    this.latestCommand = command;
    this.running = false;
    this.status = { ...this.status, phase: "pending" };
    this.message = `${command.kind} pending`;
    writeJSON(response, 200, command);
    this.publishEvent("commands:created", ["status", "commands"]);
  }

  async handleCancelMutation(request, response) {
    const body = await readJSONBody(request);
    this.cancelRequests.push(body);
    const command = this.commands.find((candidate) => candidate.id === body.commandID);
    if (!command) {
      writeJSON(response, 404, { error: "command not found" });
      return;
    }
    const requestedAt = new Date().toISOString();
    if (command.status === "pending") {
      const cancelled = {
        ...command,
        status: "cancelled",
        updatedAt: requestedAt,
        summary: { ...(command.summary || this.status), phase: "cancelled" }
      };
      this.commands = this.commands.map((candidate) => candidate.id === cancelled.id ? cancelled : candidate);
      this.latestCommand = cancelled;
      this.running = false;
      this.status = { ...this.status, phase: "cancelled" };
      this.message = "fullSync cancelled";
      writeJSON(response, 200, {
        requested: false,
        requestedAt,
        commandID: command.id,
        message: "pending command cancelled"
      });
      this.publishEvent("commands:cancelled", ["status", "commands", "cancel"]);
      return;
    }
    this.message = "cancel requested";
    writeJSON(response, 202, {
      requested: true,
      requestedAt,
      commandID: command.id,
      message: "cancel requested"
    });
    this.publishEvent("cancel:requested", ["status", "commands", "cancel"]);
  }

  handleUpgrade(request, socket, head) {
    const url = new URL(request.url || "/", this.url);
    this.upgrades.push(`${url.pathname}${url.search}`);
    if (url.pathname !== "/v1/events" || request.headers.authorization !== `Bearer ${TEST_TOKEN}`) {
      socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    this.webSockets.handleUpgrade(request, socket, head, (webSocket) => {
      this.webSockets.emit("connection", webSocket, request);
    });
  }

  handleWebSocket(socket) {
    socket.klmsSessionID = randomUUID();
    socket.klmsPendingSnapshot = null;
    socket.klmsQueuedBroadcast = null;
    socket.klmsQueuedManualRequest = null;
    this.clients.add(socket);
    socket.on("close", () => {
      socket.klmsPendingSnapshot = null;
      socket.klmsQueuedBroadcast = null;
      socket.klmsQueuedManualRequest = null;
      this.clients.delete(socket);
    });
    socket.on("message", async (raw) => {
      let message;
      try {
        message = JSON.parse(String(raw));
      } catch {
        socket.close(1002, "invalid message");
        return;
      }
      if (message?.type === "ping" && socket.readyState === WebSocket.OPEN) {
        socket.send(JSON.stringify({ version: 1, type: "pong", revision: this.revision }));
        return;
      }
      if (message?.type === "snapshot-ready") {
        const pending = socket.klmsPendingSnapshot;
        if (!pending
            || message.version !== 1
            || message.sessionID !== socket.klmsSessionID
            || message.streamID !== pending.streamID
            || message.revision !== pending.revision
            || message.reservedFrames !== pending.reservedFrames
            || message.reservedWireBytes !== pending.reservedWireBytes) {
          socket.close(1002, "snapshot ready mismatch");
          return;
        }
        if (this.nextSnapshotDeliveryGate) {
          const gate = this.nextSnapshotDeliveryGate;
          this.nextSnapshotDeliveryGate = null;
          gate.markStarted();
          await gate.waiting;
          if (socket.readyState !== WebSocket.OPEN || socket.klmsPendingSnapshot !== pending) return;
        }
        socket.klmsPendingSnapshot = null;
        for (const frame of pending.dataFrames) socket.send(frame);
        this.drainSnapshotQueue(socket);
        return;
      }
      if (message?.type === "snapshot-request") {
        const scopes = normalizeRealtimeScopes(message.scopes);
        if (message.version !== 1
            || message.sessionID !== socket.klmsSessionID
            || !isUUID(message.requestID)
            || !Number.isSafeInteger(message.revision)
            || message.revision < 0
            || !scopes) {
          socket.close(1002, "invalid snapshot request");
          return;
        }
        if (socket.klmsPendingSnapshot) {
          if (socket.klmsQueuedManualRequest) {
            socket.close(1013, "snapshot request queue capacity exceeded");
            return;
          }
          socket.klmsQueuedManualRequest = { scopes, requestID: message.requestID };
        } else {
          const prepared = this.prepareSnapshot(socket, scopes, message.requestID);
          socket.klmsPendingSnapshot = prepared;
          socket.send(prepared.beginFrame);
        }
        return;
      }
      socket.close(1002, "unsupported message");
    });
    socket.send(JSON.stringify({
      version: 1,
      type: "hello",
      revision: this.revision,
      reason: "connected",
      scopes: ["status", "syncData"],
      requiresSnapshot: false,
      sessionID: socket.klmsSessionID
    }));
  }
}

function normalizeRealtimeScopes(value) {
  if (!Array.isArray(value) || value.length === 0 || new Set(value).size !== value.length) return null;
  const requested = new Set(value);
  if ([...requested].some((scope) => !REALTIME_SCOPES.includes(scope))) return null;
  return REALTIME_SCOPES.filter((scope) => requested.has(scope));
}

function encodeRealtimeSnapshot({ sessionID, revision, scopes, requestID, payload }) {
  if (!isUUID(sessionID) || !Number.isSafeInteger(revision) || revision < 0) {
    throw new Error("invalid snapshot binding");
  }
  const payloadBuffer = Buffer.from(JSON.stringify(payload), "utf8");
  if (payloadBuffer.length > MAX_REALTIME_SNAPSHOT_BYTES) throw new Error("snapshot payload too large");
  const chunks = [];
  for (let offset = 0; offset < payloadBuffer.length || chunks.length === 0; offset += REALTIME_SNAPSHOT_CHUNK_BYTES) {
    chunks.push(payloadBuffer.subarray(offset, Math.min(payloadBuffer.length, offset + REALTIME_SNAPSHOT_CHUNK_BYTES)));
  }
  if (chunks.length > MAX_REALTIME_SNAPSHOT_CHUNKS) throw new Error("too many snapshot chunks");
  const base = {
    version: 1,
    sessionID,
    streamID: randomUUID(),
    revision,
    scopes,
    requestID,
    chunkCount: chunks.length,
    totalPayloadBytes: fixedWidthHex(payloadBuffer.length),
    reservedFrames: chunks.length + 2,
    reservedWireBytes: "0000000000000000",
    payloadSHA256: createHash("sha256").update(payloadBuffer).digest("hex")
  };
  const frames = [
    { ...base, type: "snapshot-begin", index: -1, payloadBytes: fixedWidthHex(0) },
    ...chunks.map((chunk, index) => ({
      ...base,
      type: "snapshot-chunk",
      index,
      payloadBytes: fixedWidthHex(chunk.length),
      payload: chunk.toString("base64")
    })),
    { ...base, type: "snapshot-end", index: chunks.length, payloadBytes: fixedWidthHex(0) }
  ];
  let texts = frames.map((frame) => JSON.stringify(frame));
  const reservedWireBytes = fixedWidthHex(texts.reduce((total, frame) => total + Buffer.byteLength(frame), 0));
  for (const frame of frames) frame.reservedWireBytes = reservedWireBytes;
  texts = frames.map((frame) => JSON.stringify(frame));
  const wireBytes = texts.reduce((total, frame) => total + Buffer.byteLength(frame), 0);
  if (fixedWidthHex(wireBytes) !== reservedWireBytes
      || wireBytes > MAX_REALTIME_SNAPSHOT_BYTES
      || texts.some((frame) => Buffer.byteLength(frame) > MAX_REALTIME_FRAME_BYTES)) {
    throw new Error("invalid snapshot reservation");
  }
  return {
    streamID: base.streamID,
    revision,
    reservedFrames: base.reservedFrames,
    reservedWireBytes,
    beginFrame: texts[0],
    dataFrames: texts.slice(1)
  };
}

function fixedWidthHex(value) {
  return value.toString(16).padStart(16, "0");
}

function isUUID(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(value || ""));
}

function createPerformanceFixture(count) {
  if (!Number.isSafeInteger(count) || count < 200) {
    throw new Error("performance fixture count must be an integer of at least 200");
  }
  const kindCycle = [
    "assignment",
    "assignment",
    "completedAssignment",
    "assignmentCandidate",
    "exam",
    "examCandidate",
    "notice",
    "notice",
    "file",
    "file",
    "helpDesk",
    "quarantine"
  ];
  const courses = [
    "전산학 특강",
    "자료구조",
    "운영체제",
    "확률과 통계",
    "기계학습",
    "인간-컴퓨터 상호작용",
    "분산시스템",
    "소프트웨어 공학"
  ];
  const searchIndex = Math.floor(count * 0.47);
  const focusIndex = count - 40;
  const searchQuery = "KLMS_PERF_NEEDLE_2000";
  const searchItemID = "perf-search-target";
  const focusItemID = "perf-scroll-focus";
  const focusInitialTitle = "성능 스크롤 포커스 항목 · 초기";
  const focusUpdatedTitle = "성능 스크롤 포커스 항목 · 실시간";
  const baseTimestamp = Date.UTC(2026, 2, 2, 0, 0, 0);
  const items = Array.from({ length: count }, (_, index) => {
    const kind = kindCycle[index % kindCycle.length];
    const course = courses[index % courses.length];
    const timestamp = new Date(baseTimestamp + index * 60_000).toISOString();
    const paddedIndex = String(index + 1).padStart(4, "0");
    const item = {
      id: `perf-${kind}-${paddedIndex}`,
      kind,
      course,
      title: `${performanceKindTitle(kind)} ${paddedIndex} · ${course}`,
      timestamp,
      status: performanceKindStatus(kind, index),
      detail: `${course} ${performanceKindTitle(kind)}의 대규모 목록 렌더링 및 검색 검증 항목`,
      updatedAt: new Date(baseTimestamp + index * 60_000 + 15_000).toISOString(),
      isHidden: index % 43 === 0,
      attachmentCount: ["notice", "file"].includes(kind) ? index % 4 : 0
    };
    if (kind === "notice") {
      item.isRead = index % 3 !== 0;
      item.isImportant = index % 11 === 0;
    }
    if (index === searchIndex) {
      Object.assign(item, {
        id: searchItemID,
        kind: "notice",
        title: `검색 성능 고유 공지 ${searchQuery}`,
        status: "안 읽음",
        detail: "초기 120행 밖에서 2,000개 전체 필터링을 검증하는 고유 공지",
        isHidden: false,
        isRead: false,
        isImportant: true
      });
    }
    if (index === focusIndex) {
      Object.assign(item, {
        id: focusItemID,
        kind: "assignment",
        title: focusInitialTitle,
        status: "진행 중",
        detail: "스크롤 위치와 키보드 포커스 보존을 검증하는 최신 과제",
        isHidden: false
      });
    }
    return item;
  });
  const status = summarizePerformanceItems(items);
  const distribution = items.reduce((counts, item) => {
    counts[item.kind] = (counts[item.kind] || 0) + 1;
    return counts;
  }, {});
  return {
    items,
    status,
    metadata: {
      itemCount: items.length,
      visibleItemCount: items.filter((item) => !item.isHidden).length,
      distribution,
      searchItemID,
      searchQuery,
      searchTitle: items[searchIndex].title,
      searchIndex,
      focusItemID,
      focusInitialTitle,
      focusUpdatedTitle,
      focusIndex
    }
  };
}

function summarizePerformanceItems(items, previousStatus = {}) {
  const countKinds = (...kinds) => items.filter((item) => kinds.includes(item.kind) && !item.isHidden).length;
  return {
    ...previousStatus,
    assignments: countKinds("assignment", "assignmentCandidate"),
    exams: countKinds("exam", "examCandidate"),
    helpDesk: countKinds("helpDesk"),
    notices: countKinds("notice"),
    noticeNew: items.filter((item) => item.kind === "notice" && !item.isHidden && !item.isRead).length,
    noticeUpdated: items.filter((item) => item.kind === "notice" && !item.isHidden && item.isImportant).length,
    fileTotal: countKinds("file"),
    newFiles: items.filter((item) => item.kind === "file" && !item.isHidden && /새 파일/.test(item.status)).length,
    quarantine: countKinds("quarantine"),
    phase: "idle"
  };
}

function performanceKindTitle(kind) {
  return {
    assignment: "과제",
    completedAssignment: "완료 과제",
    assignmentCandidate: "과제 후보",
    exam: "시험",
    examCandidate: "시험 후보",
    notice: "공지",
    file: "강의자료",
    helpDesk: "헬프데스크 일정",
    quarantine: "격리 파일"
  }[kind] || "항목";
}

function performanceKindStatus(kind, index) {
  if (kind === "completedAssignment") return "완료";
  if (kind === "exam" || kind === "examCandidate") return "예정";
  if (kind === "notice") return index % 3 === 0 ? "안 읽음" : "읽음";
  if (kind === "file") return index % 5 === 0 ? "새 파일" : "동기화됨";
  if (kind === "quarantine") return "검토 필요";
  return "진행 중";
}

function relayItem(id, title, timestamp) {
  return {
    id,
    kind: "assignment",
    course: "E2E 과목",
    title,
    timestamp,
    status: "진행 중",
    detail: "WebSocket 및 반응형 상태 보존 검증 항목",
    updatedAt: timestamp,
    isHidden: false,
    attachmentCount: 0
  };
}

function writeJSON(response, status, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
    Connection: "close"
  });
  response.end(body);
}

async function readJSONBody(request) {
  const chunks = [];
  for await (const chunk of request) {
    chunks.push(chunk);
  }
  const text = Buffer.concat(chunks).toString("utf8").trim();
  return text ? JSON.parse(text) : {};
}

module.exports = { FakeRelay, TEST_TOKEN, encodeRealtimeSnapshot };
