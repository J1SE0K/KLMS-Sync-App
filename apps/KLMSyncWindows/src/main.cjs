const { app, BrowserWindow, clipboard, ipcMain, nativeTheme, safeStorage, shell } = require("electron");
const fs = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const WebSocket = require("ws");
const {
  normalizeEndpoint,
  normalizeExternalURL,
  normalizeRelayURL,
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

const REQUEST_TIMEOUT_MS = 30_000;
const SOCKET_RECONNECT_MIN_MS = 250;
const SOCKET_RECONNECT_MAX_MS = 2_000;
const SOCKET_HEARTBEAT_MS = 20_000;
const SOCKET_STALE_MS = 45_000;
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
  ipcMain.handle("config:load", async () => loadConfigForRenderer());
  ipcMain.handle("config:save", async (_event, config) => serializeConfigMutation(async () => {
    const saved = await saveConfigFromRenderer(config || {});
    activateRelayConfigRevision(storedConfigRevision(saved));
    return configForRenderer(saved);
  }));
  ipcMain.handle("config:clear", async () => serializeConfigMutation(async () => {
    const nextRevision = relayConfigRevision + 1;
    await clearConfig();
    activateRelayConfigRevision(nextRevision);
    return configForRenderer({ configRevision: nextRevision });
  }));
  ipcMain.handle("clipboard:readText", async () => clipboard.readText("clipboard"));
  ipcMain.handle("clipboard:writeText", async (_event, value) => {
    const text = typeof value === "string" ? value.slice(0, 200_000) : "";
    clipboard.writeText(text, "clipboard");
    return { written: true };
  });
  ipcMain.handle("relay:request", async (_event, request) => relayRequest(request || {}));
  ipcMain.handle("relay:socketStart", async (_event, request) => startRelayEventSocket(request || {}));
  ipcMain.handle("relay:socketStop", async () => stopRelayEventSocket());
  ipcMain.handle("shell:openExternal", async (_event, target) => {
    const safeTarget = normalizeExternalURL(target);
    await shell.openExternal(safeTarget);
    return { opened: true };
  });
}

function configPath() {
  return path.join(app.getPath("userData"), "config.json");
}

async function readConfigFile() {
  try {
    const raw = await fs.readFile(configPath(), "utf8");
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch (error) {
    if (error.code === "ENOENT") {
      return {};
    }
    throw error;
  }
}

async function writeConfigFile(config) {
  await fs.mkdir(path.dirname(configPath()), { recursive: true });
  await fs.writeFile(configPath(), `${JSON.stringify(config, null, 2)}\n`, "utf8");
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
      handshakeTimeout: REQUEST_TIMEOUT_MS
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
        acceptedHello = true;
        stopRelaySocketHelloTimer();
        relaySocketReconnectDelay = SOCKET_RECONNECT_MIN_MS;
        sendToRenderer("relay:socketState", { state: "connected", connectionGeneration: clientGeneration });
        startRelaySocketHeartbeat(socket, generation);
      } else if (!event || typeof event !== "object" || Array.isArray(event)) {
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

function staleRelayConfigError() {
  const error = new Error("서버 연결 정보가 변경되어 이전 연결의 요청을 취소했습니다.");
  error.code = "STALE_RELAY_CONFIG";
  return error;
}
