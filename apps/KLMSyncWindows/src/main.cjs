const { app, BrowserWindow, clipboard, ipcMain, safeStorage, shell } = require("electron");
const fs = require("node:fs/promises");
const path = require("node:path");

const REQUEST_TIMEOUT_MS = 30_000;
const EVENT_POLL_WAIT_SECONDS = 25;

let mainWindow;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1180,
    height: 820,
    minWidth: 980,
    minHeight: 680,
    title: "KLMS Sync",
    backgroundColor: "#f5f7fb",
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, "preload.cjs")
    }
  });

  mainWindow.loadFile(path.join(__dirname, "index.html"));
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
  ipcMain.handle("config:save", async (_event, config) => {
    const saved = await saveConfigFromRenderer(config || {});
    return configForRenderer(saved);
  });
  ipcMain.handle("config:clear", async () => {
    await clearConfig();
    return configForRenderer({});
  });
  ipcMain.handle("clipboard:readText", async () => clipboard.readText("clipboard"));
  ipcMain.handle("relay:request", async (_event, request) => relayRequest(request || {}));
  ipcMain.handle("relay:waitForEvent", async (_event, request) => waitForRelayEvent(request || {}));
  ipcMain.handle("shell:openExternal", async (_event, target) => {
    if (typeof target === "string" && /^https?:\/\//i.test(target)) {
      await shell.openExternal(target);
    }
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
  return configForRenderer(await readConfigFile());
}

function configForRenderer(config) {
  const token = decodeToken(config);
  return {
    relayURL: typeof config.relayURL === "string" ? config.relayURL : "",
    hasToken: token.length > 0,
    tokenPreview: token ? `${token.slice(0, 6)}...${token.slice(-4)}` : ""
  };
}

async function saveConfigFromRenderer(input) {
  const relayURL = normalizeRelayURL(String(input.relayURL || ""));
  validateRelayURL(relayURL);
  const token = String(input.token || "").trim();
  const previous = await readConfigFile();
  if (!token && previous.token && !previous.tokenEncrypted) {
    throw new Error("저장된 클라이언트 토큰이 안전하게 암호화되어 있지 않습니다. 토큰을 다시 입력해 주세요.");
  }
  const saved = {
    ...previous,
    relayURL,
    token: token ? encodeToken(token) : previous.token || "",
    tokenEncrypted: token ? true : Boolean(previous.tokenEncrypted)
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

async function waitForRelayEvent(request) {
  const searchParams = new URLSearchParams({
    role: "client",
    waitSeconds: String(EVENT_POLL_WAIT_SECONDS)
  });
  const since = String(request.since || "").trim();
  if (since) {
    searchParams.set("since", since);
  }
  return relayRequest({ path: `/v1/events/poll?${searchParams.toString()}` });
}

async function relayRequest(request) {
  const config = await readConfigFile();
  const relayURL = normalizeRelayURL(config.relayURL || "");
  validateRelayURL(relayURL);
  const token = decodeToken(config);
  if (!token && request.path !== "/healthz") {
    throw new Error("서버 릴레이 토큰이 없습니다.");
  }

  const endpoint = normalizeEndpoint(request.path || "/v1/status");
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
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
      method: request.method || "GET",
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
  } finally {
    clearTimeout(timeout);
  }
}

function normalizeEndpoint(endpoint) {
  const value = String(endpoint || "").trim();
  if (value === "/healthz") {
    return value;
  }
  if (!value.startsWith("/v1/")) {
    throw new Error("허용되지 않은 서버 경로입니다.");
  }
  return value;
}

function normalizeRelayURL(value) {
  const trimmed = value.trim().replace(/\/+$/, "");
  if (!trimmed) {
    throw new Error("서버 URL을 입력해야 합니다.");
  }
  const url = new URL(trimmed);
  if (url.protocol !== "https:") {
    throw new Error("서버 URL은 공개 HTTPS URL이어야 합니다.");
  }
  return url.toString().replace(/\/+$/, "");
}

function validateRelayURL(value) {
  const url = new URL(value);
  if (url.protocol !== "https:") {
    throw new Error("서버 URL은 공개 HTTPS URL이어야 합니다.");
  }
  if (isPrivateHost(url.hostname)) {
    throw new Error("localhost, .local, 사설 IP는 서버 URL로 사용할 수 없습니다. 공개 HTTPS URL을 입력해 주세요.");
  }
}

function isPrivateHost(hostname) {
  const host = hostname.toLowerCase();
  if (host === "localhost" || host.endsWith(".local")) {
    return true;
  }
  if (host === "127.0.0.1" || host.startsWith("127.")) {
    return true;
  }
  if (host.startsWith("10.")) {
    return true;
  }
  if (host.startsWith("192.168.")) {
    return true;
  }
  const match = /^172\.(\d+)\./.exec(host);
  return Boolean(match && Number(match[1]) >= 16 && Number(match[1]) <= 31);
}
