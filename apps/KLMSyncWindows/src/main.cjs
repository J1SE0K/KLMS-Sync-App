const { app, BrowserWindow, clipboard, ipcMain, nativeTheme, safeStorage, shell } = require("electron");
const fs = require("node:fs/promises");
const crypto = require("node:crypto");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const WebSocket = require("ws");
const {
  configWithoutLegacyPlaintextToken,
  normalizeEndpoint,
  normalizeRelayDownloadURL,
  normalizeRelayURL,
  validateDownloadCapability,
  validateRelayURL
} = require("./relay-security.cjs");
const {
  createConfigBoundMutationRegistry,
  isValidRelayHello,
  isMutationMethod,
  jitteredReconnectDelay,
  mutationConfigRevisionMatches,
  normalizedConfigRevision
} = require("./relay-state.js");
const {
  RelaySnapshotAssembler,
  createSnapshotRequest,
  snapshotFrameType
} = require("./realtime-snapshot.cjs");

const REQUEST_TIMEOUT_MS = 30_000;
const SOCKET_RECONNECT_MIN_MS = 250;
const SOCKET_RECONNECT_MAX_MS = 2_000;
const SOCKET_HEARTBEAT_MS = 20_000;
const SOCKET_STALE_MS = 45_000;
const MAX_CLIPBOARD_CREDENTIAL_TEXT_LENGTH = 200_000;
const MAX_RELAY_FILE_DOWNLOAD_BYTES = 25 * 1024 * 1024;
const FILE_DOWNLOAD_TIMEOUT_MS = 5 * 60 * 1000;
const APP_ENTRY_PATH = path.join(__dirname, "index.html");
const APP_ENTRY_URL = pathToFileURL(APP_ENTRY_PATH).toString();

let mainWindow;
let relaySocket = null;
let relaySocketGeneration = 0;
let relaySocketReconnectTimer = null;
let relaySocketHeartbeatTimer = null;
let relaySocketHelloTimer = null;
let relaySocketReconnectDelay = SOCKET_RECONNECT_MIN_MS;
let relaySocketLastMessageAt = 0;
let relaySocketLastRevision = 0;
let relaySocketClientGeneration = 0;
let relaySocketSessionID = "";
let relaySnapshotAssembler = new RelaySnapshotAssembler();
const relaySnapshotRequests = new Map();
let relayConfigRevision = 0;
let configMutationTail = Promise.resolve();
const activeMutationRequests = createConfigBoundMutationRegistry();

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1180,
    height: 820,
    minWidth: 640,
    minHeight: 680,
    title: "KLMS Sync",
    backgroundColor: nativeTheme.shouldUseDarkColors ? "#111310" : "#f7f7f4",
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      allowRunningInsecureContent: false,
      preload: path.join(__dirname, "preload.cjs")
    }
  });

  mainWindow.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  mainWindow.webContents.on("will-navigate", (event, targetURL) => {
    if (targetURL !== APP_ENTRY_URL) event.preventDefault();
  });
  mainWindow.webContents.on("will-redirect", (event, targetURL) => {
    if (targetURL !== APP_ENTRY_URL) event.preventDefault();
  });
  mainWindow.webContents.session.setPermissionCheckHandler(() => false);
  mainWindow.webContents.session.setPermissionRequestHandler((_webContents, _permission, callback) => callback(false));
  mainWindow.loadFile(APP_ENTRY_PATH);
  mainWindow.on("closed", () => {
    stopRelayEventSocket();
    mainWindow = null;
  });
}

app.whenReady().then(() => {
  registerIPC();
  createWindow();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

function registerIPC() {
  registerTrustedIPCHandler("config:load", async () => loadConfigForRenderer());
  registerTrustedIPCHandler("config:save", async (config) => serializeConfigMutation(async () => {
    const saved = await saveConfigFromRenderer(config || {});
    activateRelayConfigRevision(storedConfigRevision(saved));
    return configForRenderer(saved);
  }));
  registerTrustedIPCHandler("config:clear", async () => serializeConfigMutation(async () => {
    const nextRevision = relayConfigRevision + 1;
    await clearConfig();
    activateRelayConfigRevision(nextRevision);
    return configForRenderer({ configRevision: nextRevision });
  }));
  registerTrustedIPCHandler("clipboard:readText", async () => {
    const text = clipboard.readText("clipboard");
    if (text.length > MAX_CLIPBOARD_CREDENTIAL_TEXT_LENGTH) {
      return {
        text: "",
        oversized: true,
        maxLength: MAX_CLIPBOARD_CREDENTIAL_TEXT_LENGTH
      };
    }
    return {
      text,
      oversized: false,
      maxLength: MAX_CLIPBOARD_CREDENTIAL_TEXT_LENGTH
    };
  });
  registerTrustedIPCHandler("clipboard:writeText", async (value) => {
    const text = typeof value === "string"
      ? value.slice(0, MAX_CLIPBOARD_CREDENTIAL_TEXT_LENGTH)
      : "";
    clipboard.writeText(text, "clipboard");
    return { written: true };
  });
  registerTrustedIPCHandler("clipboard:clearTextIfUnchanged", async (value) => {
    if (
      typeof value !== "string"
      || value.length === 0
      || value.length > MAX_CLIPBOARD_CREDENTIAL_TEXT_LENGTH
    ) {
      return { cleared: false };
    }
    if (clipboard.readText("clipboard") !== value) {
      return { cleared: false };
    }
    clipboard.clear("clipboard");
    return { cleared: true };
  });
  registerTrustedIPCHandler("relay:request", async (request) => relayRequest(request || {}));
  registerTrustedIPCHandler("relay:socketStart", async (request) => startRelayEventSocket(request || {}));
  registerTrustedIPCHandler("relay:socketStop", async () => stopRelayEventSocket());
  registerTrustedIPCHandler("relay:snapshotRequest", async (request) => requestRelaySocketSnapshot(request || {}));
  registerTrustedIPCHandler("relay:fileDownload", async (request) => downloadRelayFileAccess(request || {}));
}

function registerTrustedIPCHandler(channel, handler) {
  ipcMain.handle(channel, async (event, ...args) => {
    assertTrustedIPCEvent(event);
    return handler(...args);
  });
}

function assertTrustedIPCEvent(event) {
  if (!mainWindow
      || mainWindow.isDestroyed()
      || event.sender !== mainWindow.webContents
      || event.senderFrame?.url !== APP_ENTRY_URL) {
    throw new Error("허용되지 않은 앱 화면의 요청을 차단했습니다.");
  }
}

function configPath() {
  return path.join(app.getPath("userData"), "config.json");
}

async function readConfigFile() {
  try {
    const raw = await fs.readFile(configPath(), "utf8");
    const parsed = JSON.parse(raw);
    const sanitized = configWithoutLegacyPlaintextToken(parsed);
    if (sanitized.changed) {
      await writeConfigFile(sanitized.config);
    }
    return sanitized.config;
  } catch (error) {
    if (error.code === "ENOENT") {
      return {};
    }
    throw error;
  }
}

async function writeConfigFile(config) {
  const targetPath = configPath();
  await fs.mkdir(path.dirname(targetPath), { recursive: true });
  const temporaryPath = `${targetPath}.tmp-${process.pid}-${Date.now()}`;
  const temporaryHandle = await fs.open(temporaryPath, "wx", 0o600);
  try {
    await temporaryHandle.writeFile(`${JSON.stringify(config, null, 2)}\n`, "utf8");
    await temporaryHandle.sync();
  } finally {
    await temporaryHandle.close();
  }
  try {
    await fs.rename(temporaryPath, targetPath);
  } finally {
    await fs.rm(temporaryPath, { force: true });
  }
}

async function clearConfig() {
  try {
    await fs.rm(configPath(), { force: true });
  } catch (error) {
    if (error.code !== "ENOENT") {
      throw error;
    }
  }
}

async function loadConfigForRenderer() {
  const config = await readConfigFile();
  observeRelayConfigRevision(storedConfigRevision(config));
  return configForRenderer(config);
}

function configForRenderer(config) {
  const token = decodeToken(config);
  return {
    relayURL: typeof config.relayURL === "string" ? config.relayURL : "",
    hasToken: token.length > 0,
    configRevision: Math.max(relayConfigRevision, storedConfigRevision(config))
  };
}

function storedConfigRevision(config) {
  return normalizedConfigRevision(config?.configRevision) ?? 0;
}

function observeRelayConfigRevision(revision) {
  const nextRevision = normalizedConfigRevision(revision) ?? 0;
  if (nextRevision > relayConfigRevision) {
    relayConfigRevision = nextRevision;
    activeMutationRequests.abortStale(relayConfigRevision);
  }
  return relayConfigRevision;
}

function activateRelayConfigRevision(revision) {
  relayConfigRevision = Math.max(relayConfigRevision, normalizedConfigRevision(revision) ?? 0);
  activeMutationRequests.abortStale(relayConfigRevision);
  return relayConfigRevision;
}

function serializeConfigMutation(operation) {
  const result = configMutationTail.then(operation, operation);
  configMutationTail = result.catch(() => {});
  return result;
}

async function saveConfigFromRenderer(input) {
  const relayURL = normalizeRelayURL(String(input.relayURL || ""));
  validateRelayURL(relayURL);
  const token = String(input.token || "").trim();
  const previous = await readConfigFile();
  const canReuseToken = previous.relayURL === relayURL
    && Boolean(previous.tokenEncrypted)
    && Boolean(decodeToken(previous));
  if (!token && !canReuseToken) {
    throw new Error("새 서버에 연결할 클라이언트 토큰을 입력해 주세요.");
  }
  const saved = {
    ...previous,
    relayURL,
    token: token ? encodeToken(token) : previous.token || "",
    tokenEncrypted: token ? true : Boolean(previous.tokenEncrypted),
    configRevision: Math.max(relayConfigRevision, storedConfigRevision(previous)) + 1
  };
  await writeConfigFile(saved);
  return saved;
}

function encodeToken(token) {
  if (!safeStorage.isEncryptionAvailable()) {
    throw new Error("Windows 보안 저장소를 사용할 수 없어 클라이언트 토큰을 저장하지 않았습니다.");
  }
  return safeStorage.encryptString(token).toString("base64");
}

function decodeToken(config) {
  const token = typeof config.token === "string" ? config.token : "";
  if (!token) {
    return "";
  }
  if (config.tokenEncrypted) {
    try {
      return safeStorage.decryptString(Buffer.from(token, "base64"));
    } catch {
      return "";
    }
  }
  return "";
}

async function startRelayEventSocket(request = {}) {
  stopRelayEventSocket({ notify: false });
  const generation = relaySocketGeneration;
  const clientGeneration = Number.isSafeInteger(Number(request.clientGeneration))
    ? Math.max(0, Number(request.clientGeneration))
    : 0;
  relaySocketClientGeneration = clientGeneration;
  relaySocketLastRevision = Number.isSafeInteger(Number(request.sinceRevision))
    ? Math.max(0, Number(request.sinceRevision))
    : 0;
  relaySocketReconnectDelay = SOCKET_RECONNECT_MIN_MS;
  await connectRelayEventSocket(generation, clientGeneration);
  return { started: true, generation, clientGeneration };
}

function requestRelaySocketSnapshot(request = {}) {
  const clientGeneration = Number(request.clientGeneration);
  if (!Number.isSafeInteger(clientGeneration)
      || clientGeneration !== relaySocketClientGeneration
      || !relaySocket
      || relaySocket.readyState !== WebSocket.OPEN
      || !relaySocketSessionID) {
    throw new Error("실시간 연결을 확인한 뒤 다시 시도해 주세요.");
  }
  const requestID = crypto.randomUUID();
  const frame = createSnapshotRequest({
    sessionID: relaySocketSessionID,
    requestID,
    revision: relaySocketLastRevision,
    scopes: Array.isArray(request.scopes) ? request.scopes : []
  });
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      relaySnapshotRequests.delete(requestID);
      reject(new Error("실시간 새로고침 응답 시간이 초과되었습니다."));
    }, REQUEST_TIMEOUT_MS);
    relaySnapshotRequests.set(requestID, { resolve, reject, timeout, clientGeneration });
    try {
      relaySocket.send(JSON.stringify(frame));
    } catch (error) {
      clearTimeout(timeout);
      relaySnapshotRequests.delete(requestID);
      reject(error);
    }
  });
}

function rejectRelaySnapshotRequests(message) {
  for (const request of relaySnapshotRequests.values()) {
    clearTimeout(request.timeout);
    request.reject(new Error(message));
  }
  relaySnapshotRequests.clear();
}

function stopRelayEventSocket(options = {}) {
  relaySocketGeneration += 1;
  if (relaySocketReconnectTimer) {
    clearTimeout(relaySocketReconnectTimer);
    relaySocketReconnectTimer = null;
  }
  if (relaySocketHeartbeatTimer) {
    clearInterval(relaySocketHeartbeatTimer);
    relaySocketHeartbeatTimer = null;
  }
  stopRelaySocketHelloTimer();
  const socket = relaySocket;
  relaySocket = null;
  relaySocketSessionID = "";
  relaySnapshotAssembler.discard();
  rejectRelaySnapshotRequests("실시간 연결이 종료되었습니다.");
  if (socket) {
    try {
      socket.close(1000, "client stopped");
    } catch {}
  }
  if (options.notify !== false) {
    sendToRenderer("relay:socketState", {
      state: "stopped",
      connectionGeneration: relaySocketClientGeneration
    });
  }
  return { stopped: true };
}

async function connectRelayEventSocket(generation, clientGeneration) {
  if (generation !== relaySocketGeneration) return;
  let config;
  try {
    config = await readConfigFile();
    if (generation !== relaySocketGeneration || clientGeneration !== relaySocketClientGeneration) return;
    const relayURL = normalizeRelayURL(config.relayURL || "");
    validateRelayURL(relayURL);
    const token = decodeToken(config);
    if (!token) throw new Error("서버 릴레이 토큰이 없습니다.");
    const socketURL = new URL(`${relayURL}/v1/events`);
    socketURL.protocol = socketURL.protocol === "https:" ? "wss:" : "ws:";
    socketURL.searchParams.set("role", "client");
    socketURL.searchParams.set("sinceRevision", String(relaySocketLastRevision));
    sendToRenderer("relay:socketState", { state: "connecting", connectionGeneration: clientGeneration });
    const socket = new WebSocket(socketURL, {
      headers: {
        Authorization: `Bearer ${token}`,
        "X-KLMS-Client": "Windows"
      },
      handshakeTimeout: REQUEST_TIMEOUT_MS,
      maxPayload: 64 * 1024
    });
    relaySocket = socket;
    let acceptedHello = false;
    socket.on("open", () => {
      if (generation !== relaySocketGeneration || relaySocket !== socket) {
        socket.close(1000, "stale connection");
        return;
      }
      relaySocketLastMessageAt = Date.now();
      stopRelaySocketHelloTimer();
      relaySocketHelloTimer = setTimeout(() => {
        if (generation !== relaySocketGeneration || relaySocket !== socket || acceptedHello) return;
        sendToRenderer("relay:socketState", {
          state: "reconnecting",
          message: "서버 hello 응답 시간이 초과되었습니다.",
          connectionGeneration: clientGeneration
        });
        socket.close(1002, "server hello timeout");
      }, REQUEST_TIMEOUT_MS);
    });
    socket.on("message", (raw) => {
      if (generation !== relaySocketGeneration || relaySocket !== socket) return;
      relaySocketLastMessageAt = Date.now();
      let event;
      const type = snapshotFrameType(raw);
      if (acceptedHello && ["snapshot-begin", "snapshot-chunk", "snapshot-end"].includes(type)) {
        try {
          const result = relaySnapshotAssembler.ingest(raw, relaySocketSessionID);
          if (result.action === "ready") {
            socket.send(JSON.stringify(result.frame));
          } else if (result.action === "complete") {
            relaySocketLastRevision = Math.max(relaySocketLastRevision, result.payload.revision);
            const requestID = typeof result.payload.requestID === "string" ? result.payload.requestID : "";
            const pending = relaySnapshotRequests.get(requestID);
            if (pending && pending.clientGeneration === clientGeneration) {
              clearTimeout(pending.timeout);
              relaySnapshotRequests.delete(requestID);
              pending.resolve(result.payload);
            } else {
              sendToRenderer("relay:snapshot", {
                ...result.payload,
                connectionGeneration: clientGeneration
              });
            }
          }
        } catch (error) {
          relaySnapshotAssembler.discard();
          socket.close(error?.closeCode || 1002, String(error?.message || "snapshot protocol error").slice(0, 120));
        }
        return;
      }
      try {
        event = JSON.parse(String(raw));
      } catch {
        if (!acceptedHello) rejectRelaySocketHello(socket, clientGeneration);
        return;
      }
      if (!acceptedHello) {
        if (!isValidRelayHello(event)) {
          rejectRelaySocketHello(socket, clientGeneration);
          return;
        }
        if (typeof event.sessionID !== "string"
            || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(event.sessionID)) {
          rejectRelaySocketHello(socket, clientGeneration);
          return;
        }
        relaySocketSessionID = event.sessionID;
        relaySnapshotAssembler.discard();
        acceptedHello = true;
        stopRelaySocketHelloTimer();
        relaySocketReconnectDelay = SOCKET_RECONNECT_MIN_MS;
        sendToRenderer("relay:socketState", { state: "connected", connectionGeneration: clientGeneration });
        startRelaySocketHeartbeat(socket, generation);
      } else if (!event || typeof event !== "object" || Array.isArray(event)) {
        return;
      }
      if (event.requiresSnapshot === true) {
        socket.close(1002, "legacy snapshot event is not supported");
        return;
      }
      if (Number.isSafeInteger(Number(event?.revision))) {
        const eventRevision = Math.max(0, Number(event.revision));
        relaySocketLastRevision = event.type === "hello" || event.type === "pong"
          ? eventRevision
          : Math.max(relaySocketLastRevision, eventRevision);
      }
      sendToRenderer("relay:event", { ...event, connectionGeneration: clientGeneration });
    });
    socket.on("error", (error) => {
      if (generation !== relaySocketGeneration || relaySocket !== socket) return;
      sendToRenderer("relay:socketState", {
        state: "reconnecting",
        message: error?.message || "WebSocket 연결 오류",
        connectionGeneration: clientGeneration
      });
    });
    socket.on("close", () => {
      if (generation !== relaySocketGeneration || relaySocket !== socket) return;
      relaySocket = null;
      relaySocketSessionID = "";
      relaySnapshotAssembler.discard();
      rejectRelaySnapshotRequests("실시간 연결이 끊어졌습니다.");
      stopRelaySocketHelloTimer();
      stopRelaySocketHeartbeat();
      scheduleRelaySocketReconnect(generation, clientGeneration);
    });
  } catch (error) {
    if (generation !== relaySocketGeneration) return;
    sendToRenderer("relay:socketState", {
      state: "reconnecting",
      message: error?.message || "WebSocket 연결 실패",
      connectionGeneration: clientGeneration
    });
    scheduleRelaySocketReconnect(generation, clientGeneration);
  }
}

function rejectRelaySocketHello(socket, clientGeneration) {
  stopRelaySocketHelloTimer();
  sendToRenderer("relay:socketState", {
    state: "reconnecting",
    message: "서버가 올바른 WebSocket hello를 보내지 않았습니다.",
    connectionGeneration: clientGeneration
  });
  socket.close(1002, "invalid server hello");
}

function stopRelaySocketHelloTimer() {
  if (relaySocketHelloTimer) {
    clearTimeout(relaySocketHelloTimer);
    relaySocketHelloTimer = null;
  }
}

function startRelaySocketHeartbeat(socket, generation) {
  stopRelaySocketHeartbeat();
  relaySocketHeartbeatTimer = setInterval(() => {
    if (generation !== relaySocketGeneration || relaySocket !== socket) return;
    if (Date.now() - relaySocketLastMessageAt > SOCKET_STALE_MS) {
      socket.terminate();
      return;
    }
    if (socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify({ type: "ping", revision: relaySocketLastRevision }));
    }
  }, SOCKET_HEARTBEAT_MS);
}

function stopRelaySocketHeartbeat() {
  if (relaySocketHeartbeatTimer) {
    clearInterval(relaySocketHeartbeatTimer);
    relaySocketHeartbeatTimer = null;
  }
}

function scheduleRelaySocketReconnect(generation, clientGeneration) {
  if (generation !== relaySocketGeneration
    || clientGeneration !== relaySocketClientGeneration
    || relaySocketReconnectTimer) return;
  const delay = jitteredReconnectDelay(relaySocketReconnectDelay);
  sendToRenderer("relay:socketState", {
    state: "reconnecting",
    retryInMs: delay,
    connectionGeneration: clientGeneration
  });
  relaySocketReconnectTimer = setTimeout(() => {
    relaySocketReconnectTimer = null;
    connectRelayEventSocket(generation, clientGeneration);
  }, delay);
  relaySocketReconnectDelay = Math.min(SOCKET_RECONNECT_MAX_MS, relaySocketReconnectDelay * 2);
}

function sendToRenderer(channel, payload) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, payload);
  }
}

async function relayRequest(request) {
  const method = String(request.method || "GET").trim().toUpperCase() || "GET";
  const expectedConfigRevision = normalizedConfigRevision(request.expectedConfigRevision);
  if (!mutationConfigRevisionMatches(
    method,
    expectedConfigRevision,
    relayConfigRevision,
    relayConfigRevision
  )) {
    throw staleRelayConfigError();
  }

  const config = await readConfigFile();
  const configRevision = storedConfigRevision(config);
  if (!mutationConfigRevisionMatches(
    method,
    expectedConfigRevision,
    relayConfigRevision,
    configRevision
  )) {
    throw staleRelayConfigError();
  }
  const relayURL = normalizeRelayURL(config.relayURL || "");
  validateRelayURL(relayURL);
  const token = decodeToken(config);
  if (!token && request.path !== "/healthz") {
    throw new Error("서버 릴레이 토큰이 없습니다.");
  }

  const endpoint = normalizeEndpoint(request.path || "/v1/status");
  const controller = new AbortController();
  const releaseMutation = isMutationMethod(method)
    ? activeMutationRequests.track(controller, expectedConfigRevision)
    : () => {};
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    if (!mutationConfigRevisionMatches(
      method,
      expectedConfigRevision,
      relayConfigRevision,
      configRevision
    )) {
      throw staleRelayConfigError();
    }
    const headers = {
      Accept: "application/json",
      "X-KLMS-Client": "Windows"
    };
    if (endpoint !== "/healthz") {
      headers.Authorization = `Bearer ${token}`;
    }
    if (request.body != null) {
      headers["Content-Type"] = "application/json";
    }
    const response = await fetch(`${relayURL}${endpoint}`, {
      method,
      headers,
      body: request.body == null ? undefined : JSON.stringify(request.body),
      signal: controller.signal
    });
    const text = await response.text();
    let payload = null;
    if (text.trim()) {
      try {
        payload = JSON.parse(text);
      } catch {
        payload = { raw: text };
      }
    }
    if (!response.ok) {
      const message = response.status === 401
        ? "서버 인증 실패: 서버 URL과 클라이언트 토큰이 최신 값인지 확인해 주세요."
        : payload && payload.error ? payload.error : `서버 요청 실패 (${response.status})`;
      const error = new Error(message);
      error.status = response.status;
      throw error;
    }
    return payload;
  } catch (error) {
    if (controller.signal.aborted
      && isMutationMethod(method)
      && !mutationConfigRevisionMatches(
        method,
        expectedConfigRevision,
        relayConfigRevision,
        configRevision
      )) {
      throw staleRelayConfigError();
    }
    throw error;
  } finally {
    clearTimeout(timeout);
    releaseMutation();
  }
}

async function downloadRelayFileAccess(input) {
  const expectedConfigRevision = normalizedConfigRevision(input.expectedConfigRevision);
  const config = await readConfigFile();
  const configRevision = storedConfigRevision(config);
  if (expectedConfigRevision == null
      || expectedConfigRevision !== relayConfigRevision
      || expectedConfigRevision !== configRevision) {
    throw staleRelayConfigError();
  }
  const relayURL = normalizeRelayURL(config.relayURL || "");
  validateRelayURL(relayURL);
  if (!decodeToken(config)) {
    throw new Error("서버 릴레이 토큰이 없습니다.");
  }
  const requestID = String(input.id || "").trim();
  const downloadURL = normalizeRelayDownloadURL(input.downloadURL, relayURL, requestID);
  const capability = validateDownloadCapability(input.downloadCapability);
  const declaredBytes = Number(input.sizeBytes);
  if (Number.isFinite(declaredBytes)
      && (declaredBytes < 0 || declaredBytes > MAX_RELAY_FILE_DOWNLOAD_BYTES)) {
    throw new Error("파일 크기가 앱의 안전 한도를 벗어났습니다.");
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), FILE_DOWNLOAD_TIMEOUT_MS);
  let temporaryPath = "";
  try {
    const response = await fetch(downloadURL, {
      method: "GET",
      headers: {
        Accept: "application/octet-stream",
        Authorization: `Bearer ${capability}`,
        "X-KLMS-Client": "Windows"
      },
      redirect: "error",
      signal: controller.signal
    });
    if (!response.ok || !response.body) {
      throw new Error(`파일 다운로드 실패 (${response.status})`);
    }
    const contentLength = Number(response.headers.get("content-length"));
    if (Number.isFinite(contentLength) && contentLength > MAX_RELAY_FILE_DOWNLOAD_BYTES) {
      throw new Error("파일 크기가 앱의 안전 한도를 벗어났습니다.");
    }

    const directory = path.join(app.getPath("temp"), "KLMS Sync File Access", requestID);
    await fs.mkdir(directory, { recursive: true, mode: 0o700 });
    await fs.chmod(directory, 0o700);
    const filename = safeRelayFilename(input.itemTitle);
    const nonce = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const destinationPath = path.join(directory, `${nonce}-${filename}`);
    temporaryPath = `${destinationPath}.partial`;
    const handle = await fs.open(temporaryPath, "wx", 0o600);
    let receivedBytes = 0;
    try {
      const reader = response.body.getReader();
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        receivedBytes += value.byteLength;
        if (receivedBytes > MAX_RELAY_FILE_DOWNLOAD_BYTES) {
          await reader.cancel();
          throw new Error("파일 크기가 앱의 안전 한도를 벗어났습니다.");
        }
        await handle.write(Buffer.from(value));
      }
      await handle.sync();
    } finally {
      await handle.close();
    }
    await fs.rename(temporaryPath, destinationPath);
    temporaryPath = "";
    const openError = await shell.openPath(destinationPath);
    if (openError) throw new Error(openError);
    return { opened: true, sizeBytes: receivedBytes };
  } finally {
    clearTimeout(timeout);
    if (temporaryPath) await fs.rm(temporaryPath, { force: true });
  }
}

function safeRelayFilename(value) {
  const sanitized = String(value || "KLMS file")
    .replace(/[\\/:*?"<>|\u0000-\u001f\u007f]/g, "_")
    .trim()
    .slice(0, 180);
  return sanitized || "KLMS file";
}

function staleRelayConfigError() {
  const error = new Error("서버 연결 정보가 변경되어 이전 연결의 요청을 취소했습니다.");
  error.code = "STALE_RELAY_CONFIG";
  return error;
}
