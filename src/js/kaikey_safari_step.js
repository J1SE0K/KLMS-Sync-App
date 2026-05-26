#!/usr/bin/osascript -l JavaScript

ObjC.import("Foundation");

function run(argv) {
  const options = parseOptions(argv);
  const targetUrl = options.url || "https://klms.kaist.ac.kr/my/";
  const displayName = options["display-name"] || "";
  const maxSeconds = Math.max(0, Number(options["max-seconds"] || "0"));
  const pollMs = Math.max(75, Math.min(1000, Number(options["poll-ms"] || "150")));
  const backgroundWindowEnabled = safariBackgroundWindowEnabled();
  const reuseExistingWindowEnabled = safariReuseExistingWindowEnabled();
  if (!displayName) {
    return JSON.stringify({ status: "error", error: "missing-display-name" });
  }

  const safari = Application("/Applications/Safari.app");
  const frontmostApp = frontmostApplicationName();
  if (!safeBoolean(() => safari.running())) {
    safari.launch();
  }
  restoreFrontmostApplication(frontmostApp);

  const windowRef = resolveWindow(safari, backgroundWindowEnabled, reuseExistingWindowEnabled);
  if (!windowRef) {
    return JSON.stringify({ status: "error", error: "no-safari-window" });
  }
  if (backgroundWindowEnabled) {
    prepareBackgroundWindow(windowRef);
    restoreFrontmostApplication(frontmostApp);
  }

  const tab = resolveTab(windowRef);
  if (!tab) {
    return JSON.stringify({ status: "error", error: "no-safari-tab" });
  }

  if (maxSeconds > 0) {
    return JSON.stringify(advanceUntilTerminal(windowRef, tab, targetUrl, displayName, maxSeconds, pollMs, options));
  }
  return JSON.stringify(advanceOneStep(windowRef, tab, targetUrl, displayName, options));
}

function advanceUntilTerminal(windowRef, tab, targetUrl, displayName, maxSeconds, pollMs, options) {
  const deadline = Date.now() + maxSeconds * 1000;
  let lastPayload = { status: "waiting" };

  while (Date.now() < deadline) {
    const payload = advanceOneStep(windowRef, tab, targetUrl, displayName, options);
    if (safariBackgroundWindowEnabled()) {
      prepareBackgroundWindow(windowRef);
    }
    lastPayload = payload;
    if (isTerminalStatus(payload.status)) {
      return payload;
    }
    delay(pollMs / 1000);
  }

  lastPayload.timeout = true;
  return lastPayload;
}

function isTerminalStatus(status) {
  return status === "authenticated" || status === "twofactor_digits" || status === "error";
}

function advanceOneStep(windowRef, tab, targetUrl, displayName, options = {}) {
  let url = safeString(() => tab.url());
  if (!looksLikeKaistAuthUrl(url)) {
    tab.url = targetUrl;
    if (safariBackgroundWindowEnabled()) {
      prepareBackgroundWindow(windowRef);
    }
    url = safeString(() => tab.url());
    return { status: "navigated", url };
  }

  const urlLower = url.toLowerCase();

  if (
    urlLower.includes("klms.kaist.ac.kr") &&
    !urlLower.includes("/login/") &&
    !urlLower.includes("ssologin.php")
  ) {
    if (klmsPageLooksAuthenticated(tab)) {
      return { status: "authenticated", url, title: readTitle(tab) };
    }
    tab.url = "https://klms.kaist.ac.kr/login/ssologin.php";
    if (safariBackgroundWindowEnabled()) {
      prepareBackgroundWindow(windowRef);
    }
    return {
      status: "navigated",
      reason: "unverified-klms-page",
      url
    };
  }

  if (urlLower.includes("klms.kaist.ac.kr/login/ssologin.php")) {
    const result = runPageScript(tab, `
(() => {
  const links = Array.from(document.querySelectorAll("a[href]"));
  const link =
    links.find((anchor) =>
      String(anchor.href || "").includes("sso.kaist.ac.kr/auth/kaist/user/login/view")
    ) || document.querySelector("div.login > a[href]");
  if (!link || !link.href || String(link.href).endsWith("#")) {
    return JSON.stringify({ ok: false, reason: "missing-link" });
  }
  window.location.assign(link.href);
  return JSON.stringify({ ok: true });
})();
`);
    const payload = parseJson(result);
    return {
      status: payload.ok ? "klms_redirect_clicked" : "waiting",
      reason: payload.reason || "",
      url
    };
  }

  if (urlLower.includes("sso.kaist.ac.kr/auth/kaist/user/login/view")) {
    const result = runPageScript(tab, `
(() => {
  const displayName = ${JSON.stringify(displayName)};
  const input = document.querySelector("#login_id_mfa");
  if (!input) return JSON.stringify({ ok: false, reason: "missing-input" });
  if (document.body && document.body.dataset.klmsLoginAssistMfaSubmitted === "1") {
    return JSON.stringify({ ok: false, reason: "login-already-submitted" });
  }
  const proto = Object.getPrototypeOf(input);
  const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
  if (setter) setter.call(input, displayName);
  else input.value = displayName;
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
  if (document.body) document.body.dataset.klmsLoginAssistMfaSubmitted = "1";
  if (typeof window.loginProcMfa === "function") {
    window.loginProcMfa();
    return JSON.stringify({ ok: true, method: "loginProcMfa" });
  }
  const button = document.querySelector("a.btn_login");
  if (button) {
    button.click();
    return JSON.stringify({ ok: true, method: "button" });
  }
  return JSON.stringify({ ok: false, reason: "missing-login-action" });
})();
`);
    const payload = parseJson(result);
    return {
      status: payload.ok ? "login_submitted" : "waiting",
      reason: payload.reason || "",
      method: payload.method || "",
      url
    };
  }

  if (urlLower.includes("sso.kaist.ac.kr/auth/twofactor/mfa/login2factor")) {
    if (String(options["refresh-twofactor"] || "") === "1") {
      tab.url = targetUrl;
      if (safariBackgroundWindowEnabled()) {
        prepareBackgroundWindow(windowRef);
      }
      return {
        status: "twofactor_refreshed",
        reason: "",
        method: "restart-login",
        url
      };
    }

    const result = runPageScript(tab, `
(() => {
  const wrap = document.querySelector(".auth_number .nember_wrap");
  if (wrap) {
    const spans = wrap.querySelectorAll("span");
    if (spans.length >= 2) {
      const a = (spans[0].textContent || "").trim();
      const b = (spans[1].textContent || "").trim();
      if (/^\\d$/.test(a) && /^\\d$/.test(b)) {
        return JSON.stringify({ ok: true, digits: a + b });
      }
    }
  }
  const sr = document.querySelector(".auth_number .sr-only");
  if (sr) {
    const text = (sr.textContent || "").trim();
    if (/^\\d{2}$/.test(text)) return JSON.stringify({ ok: true, digits: text });
  }
  return JSON.stringify({ ok: false, reason: "digits-not-ready" });
})();
`);
    const payload = parseJson(result);
    return {
      status: payload.ok ? "twofactor_digits" : "waiting",
      digits: payload.digits || "",
      reason: payload.reason || "",
      url
    };
  }

  return { status: "waiting", url };
}

function readTitle(tab) {
  return safeString(() => tab.name());
}

function klmsPageLooksAuthenticated(tab) {
  const result = runPageScript(tab, `
(() => {
  const html = String(document.documentElement?.innerHTML || "").toLowerCase();
  const text = String(document.body?.innerText || "").toLowerCase();
  const tokens = [
    "logout",
    "로그아웃",
    "세션 연장",
    "/login/logout.php",
    "/course/view.php",
    "main-course-list",
    "list-box",
    "나의 강좌",
    "my courses"
  ];
  return JSON.stringify({ ok: tokens.some((token) => html.includes(token) || text.includes(token)) });
})();
`);
  const payload = parseJson(result);
  return payload.ok === true;
}

function parseOptions(argv) {
  const options = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = String(argv[i]);
    if (!arg.startsWith("--")) continue;
    const eq = arg.indexOf("=");
    if (eq >= 0) {
      options[arg.slice(2, eq)] = arg.slice(eq + 1);
    } else {
      options[arg.slice(2)] = String(argv[i + 1] || "");
      i += 1;
    }
  }
  return options;
}

function resolveWindow(safari, backgroundWindowEnabled, reuseExistingWindowEnabled) {
  if (reuseExistingWindowEnabled) {
    const windows = safeList(() => safari.windows());
    for (let i = 0; i < windows.length; i += 1) {
      const tab = safeValue(() => windows[i].currentTab());
      const url = safeString(() => tab.url());
      if (looksLikeKaistAuthUrl(url) && (!backgroundWindowEnabled || isBackgroundWindow(windows[i]))) {
        return windows[i];
      }
    }
    if (!backgroundWindowEnabled && windows.length > 0) return windows[0];
  }
  return createSafariWindow(safari, backgroundWindowEnabled);
}

function createSafariWindow(safari, backgroundWindowEnabled) {
  const previousWindowIds = new Set(listWindowIds(safari));
  safari.make({ new: "document" });
  delay(0.2);
  const windowRef = safeList(() => safari.windows()).find(
    (candidate) => !previousWindowIds.has(safeNumber(() => candidate.id(), -1))
  ) || null;
  if (backgroundWindowEnabled) {
    prepareBackgroundWindow(windowRef);
  }
  return windowRef;
}

function resolveTab(windowRef) {
  return safeValue(() => windowRef.currentTab());
}

function looksLikeKaistAuthUrl(url) {
  const lower = String(url || "").toLowerCase();
  return lower.includes("klms.kaist.ac.kr") || lower.includes("sso.kaist.ac.kr");
}

function runPageScript(tab, script) {
  return safeString(() => Application("/Applications/Safari.app").doJavaScript(script, { in: tab }));
}

function parseJson(value) {
  try {
    return JSON.parse(String(value || "{}"));
  } catch (_error) {
    return { ok: false, reason: "invalid-script-response" };
  }
}

function safeString(getter) {
  try {
    const value = getter();
    return value == null ? "" : String(value);
  } catch (_error) {
    return "";
  }
}

function safeValue(getter) {
  try {
    return getter();
  } catch (_error) {
    return null;
  }
}

function safeBoolean(getter) {
  try {
    return Boolean(getter());
  } catch (_error) {
    return false;
  }
}

function safeNumber(getter, fallback) {
  try {
    const value = Number(getter());
    return Number.isFinite(value) ? value : fallback;
  } catch (_error) {
    return fallback;
  }
}

function safeList(getter) {
  try {
    const value = getter();
    return Array.isArray(value) ? value : [];
  } catch (_error) {
    return [];
  }
}

function prepareBackgroundWindow(windowRef) {
  if (!windowRef) {
    return;
  }
  try {
    windowRef.miniaturized = true;
  } catch (_error) {
    // Login assist can still scrape the page if minimizing is unavailable.
  }
}

function isBackgroundWindow(windowRef) {
  const miniaturized = safeValue(() => windowRef.miniaturized());
  if (miniaturized === true) {
    return true;
  }
  const visible = safeValue(() => windowRef.visible());
  return visible === false;
}

function listWindowIds(safari) {
  return safeList(() => safari.windows())
    .map((windowRef) => safeNumber(() => windowRef.id(), null))
    .filter((value) => value != null);
}

function frontmostApplicationName() {
  try {
    const systemEvents = Application("System Events");
    const frontProcesses = systemEvents.applicationProcesses.whose({ frontmost: true })();
    return frontProcesses.length ? String(frontProcesses[0].name()) : "";
  } catch (_error) {
    return "";
  }
}

function restoreFrontmostApplication(appName) {
  if (!appName || appName === "Safari") {
    return;
  }
  try {
    Application(appName).activate();
  } catch (_error) {
    // Leave focus as-is if macOS refuses to restore the previous app.
  }
}

function safariBackgroundWindowEnabled() {
  return envFlag("KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED", "1");
}

function safariReuseExistingWindowEnabled() {
  return envFlag("KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED", "0");
}

function envValue(name) {
  try {
    const value = $.NSProcessInfo.processInfo.environment.objectForKey(name);
    return value ? String(ObjC.unwrap(value)) : "";
  } catch (_error) {
    return "";
  }
}

function envFlag(name, defaultValue) {
  const raw = envValue(name) || String(defaultValue || "");
  return !["0", "false", "no", "off"].includes(raw.trim().toLowerCase());
}
