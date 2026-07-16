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
  if (!isExactKlmsHttpsUrl(targetUrl)) {
    return JSON.stringify({ status: "error", error: "invalid-klms-url" });
  }

  const safari = Application("/Applications/Safari.app");
  const frontmostApp = safariRestoreFrontmostEnabled() ? frontmostApplicationName() : "";
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
  let submittedLogin = false;

  while (Date.now() < deadline) {
    const payload = advanceOneStep(windowRef, tab, targetUrl, displayName, options);
    if (payload.status === "login_submitted") {
      submittedLogin = true;
    }
    if (safariBackgroundWindowEnabled()) {
      prepareBackgroundWindow(windowRef);
    }
    lastPayload = Object.assign({}, payload, { submittedLogin });
    if (isTerminalStatus(payload.status)) {
      return lastPayload;
    }
    delay(pollMs / 1000);
  }

  lastPayload.timeout = true;
  return lastPayload;
}

function isTerminalStatus(status) {
  return (
    status === "authenticated" ||
    status === "twofactor_digits" ||
    status === "twofactor_pending" ||
    status === "error"
  );
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

  if (looksLikeAuthenticatedKlmsUrl(urlLower)) {
    const page = readKlmsPageLoadState(tab);
    if (page.loaded) {
      return { status: "authenticated", url: page.href || url, title: page.title || readTitle(tab) };
    }
    return {
      status: "waiting",
      reason: "klms-page-loading",
      url,
      title: page.title || readTitle(tab)
    };
  }

  if (looksLikeKlmsLoginUrl(urlLower)) {
    const fallbackUrl = kaistSsoLoginUrl(targetUrl);
    const result = runPageScript(tab, `
(() => {
  const fallbackUrl = ${JSON.stringify(fallbackUrl)};
  const links = Array.from(document.querySelectorAll("a[href]"));
  const link =
    links.find((anchor) =>
      String(anchor.href || "").includes("sso.kaist.ac.kr/auth/kaist/user/login/view")
    ) || document.querySelector("div.login > a[href]");
  const href = link && link.href && !String(link.href).endsWith("#") ? String(link.href) : fallbackUrl;
  if (!href) {
    return JSON.stringify({ ok: false, reason: "missing-login-target" });
  }
  window.location.assign(href);
  return JSON.stringify({ ok: true, method: link ? "page-link" : "fallback-url" });
})();
`);
    const payload = parseJson(result);
    if (!payload.ok) {
      tab.url = fallbackUrl;
      if (safariBackgroundWindowEnabled()) {
        prepareBackgroundWindow(windowRef);
      }
      return {
        status: "klms_redirect_clicked",
        reason: payload.reason || "fallback-direct-sso",
        method: "fallback-url",
        url,
        targetUrl: fallbackUrl
      };
    }
    return {
      status: "klms_redirect_clicked",
      reason: payload.reason || "",
      method: payload.method || "",
      url
    };
  }

  if (urlLower.includes("sso.kaist.ac.kr/auth/kaist/user/login/view")) {
    const result = runPageScript(tab, `
(() => {
  const displayName = ${JSON.stringify(displayName)};
  const submittedAt = Number(document.body?.dataset.klmsLoginAssistMfaSubmittedAt || "0");
  const submittedName = String(document.body?.dataset.klmsLoginAssistMfaSubmittedName || "");
  if (submittedName === displayName && Date.now() - submittedAt < 1600) {
    return JSON.stringify({ ok: false, reason: "login-submit-cooling-down" });
  }
  const inputSelectors = [
    "#login_id_mfa",
    "input[name='login_id_mfa']",
    "input[name='login_id']",
    "input[name='user_id']",
    "input[name='userid']",
    "input[type='text']",
    "input:not([type])"
  ];
  const input = inputSelectors.map((selector) => document.querySelector(selector)).find(Boolean);
  if (!input) return JSON.stringify({ ok: false, reason: "missing-input" });
  const proto = Object.getPrototypeOf(input);
  const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
  if (setter) setter.call(input, displayName);
  else input.value = displayName;
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
  const markSubmitted = (method) => {
    if (document.body) {
      document.body.dataset.klmsLoginAssistMfaSubmittedAt = String(Date.now());
      document.body.dataset.klmsLoginAssistMfaSubmittedName = displayName;
    }
    return JSON.stringify({ ok: true, method });
  };
  if (typeof window.loginProcMfa === "function") {
    window.loginProcMfa();
    return markSubmitted("loginProcMfa");
  }
  const buttonSelectors = [
    "a.btn_login",
    "button.btn_login",
    "input.btn_login",
    "button[type='submit']",
    "input[type='submit']",
    "a[onclick*='loginProcMfa']",
    "button[onclick*='loginProcMfa']",
    "[role='button']"
  ];
  let button = buttonSelectors.map((selector) => document.querySelector(selector)).find(Boolean);
  if (!button) {
    const clickables = Array.from(document.querySelectorAll("a, button, input[type='button'], input[type='submit'], [role='button']"));
    button = clickables.find((candidate) => {
      const text = [
        candidate.textContent || "",
        candidate.value || "",
        candidate.getAttribute("aria-label") || "",
        candidate.getAttribute("title") || ""
      ].join(" ").trim().toLowerCase();
      return text.includes("로그인") || text.includes("login") || text.includes("sign in");
    });
  }
  if (button) {
    if (button.disabled || button.getAttribute("aria-disabled") === "true") {
      return JSON.stringify({ ok: false, reason: "login-action-disabled" });
    }
    button.click();
    return markSubmitted("button");
  }
  const form = input.form || document.querySelector("form");
  if (form) {
    if (typeof form.requestSubmit === "function") {
      form.requestSubmit();
      return markSubmitted("form.requestSubmit");
    }
    if (typeof form.submit === "function") {
      form.submit();
      return markSubmitted("form.submit");
    }
  }
  input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", bubbles: true }));
  input.dispatchEvent(new KeyboardEvent("keyup", { key: "Enter", code: "Enter", bubbles: true }));
  return markSubmitted("enter-key");
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
    if (String(options["check-authenticated"] || "") === "1") {
      return checkAuthenticatedWithoutLeavingTwofactor(windowRef, targetUrl, url, options);
    }

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
  const normalizeDigits = (value) => String(value || "").replace(/[^0-9]/g, "");
  const exactTwoDigits = (value) => {
    const digits = normalizeDigits(value);
    return /^\\d{2}$/.test(digits) ? digits : "";
  };
  const extractTwofactorDigits = () => {
    const scopedSelectors = [
      ".auth_number .nember_wrap",
      ".auth_number .number_wrap",
      ".auth_number",
      "[class*='auth'][class*='number']",
      "[class*='number'][class*='wrap']"
    ];
    const scopedNodes = Array.from(document.querySelectorAll(scopedSelectors.join(",")));
    for (const node of scopedNodes) {
      const spanDigits = Array.from(node.querySelectorAll("span"))
        .map((span) => (span.textContent || "").trim())
        .filter((text) => /^\\d$/.test(text))
        .join("");
      if (/^\\d{2}$/.test(spanDigits)) {
        return { ok: true, digits: spanDigits, method: "span-digits" };
      }
      const directTextDigits = exactTwoDigits(node.textContent);
      if (directTextDigits) {
        return { ok: true, digits: directTextDigits, method: "node-text" };
      }
      const ariaDigits = exactTwoDigits(node.getAttribute("aria-label") || node.getAttribute("title"));
      if (ariaDigits) {
        return { ok: true, digits: ariaDigits, method: "node-aria" };
      }
    }
    const screenReaderNodes = Array.from(document.querySelectorAll(".auth_number .sr-only, .sr-only, [aria-live]"));
    for (const node of screenReaderNodes) {
      const digits = exactTwoDigits(node.textContent || node.getAttribute("aria-label"));
      if (digits) {
        return { ok: true, digits, method: "screen-reader" };
      }
    }
    const bodyText = String(document.body?.innerText || "").replace(/\\s+/g, " ");
    const authTextMatch = bodyText.match(/(?:인증\\s*번호|auth(?:entication)?\\s*(?:number|code))\\D*(\\d)\\D*(\\d)/i);
    if (authTextMatch) {
      return { ok: true, digits: authTextMatch[1] + authTextMatch[2], method: "body-auth-text" };
    }
    return {
      ok: false,
      reason: "digits-not-ready",
      title: document.title || "",
      url: location.href || "",
      readyState: document.readyState || ""
    };
  };
  return JSON.stringify(extractTwofactorDigits());
})();
`);
    const payload = parseJson(result);
    return {
      status: payload.ok ? "twofactor_digits" : "waiting",
      digits: payload.digits || "",
      reason: payload.reason || "",
      method: payload.method || "",
      title: payload.title || "",
      url
    };
  }

  return { status: "waiting", url };
}

function checkAuthenticatedWithoutLeavingTwofactor(windowRef, targetUrl, sourceUrl, options = {}) {
  const frontmostApp = safariRestoreFrontmostEnabled() ? frontmostApplicationName() : "";
  const previousTab = resolveTab(windowRef);
  let checkTab = null;
  let keepCheckTab = false;
  try {
    checkTab = createSafariTab(windowRef, targetUrl);
    if (!checkTab) {
      return twofactorPending(sourceUrl, "no-check-tab");
    }
    prepareBackgroundWindow(windowRef);
    const deadline = Date.now() + authCheckMilliseconds(options);
    let lastUrl = sourceUrl;
    let pendingReason = "phone-approval-pending";
    while (Date.now() < deadline) {
      lastUrl = safeString(() => checkTab.url()) || lastUrl;
      const lower = lastUrl.toLowerCase();
      if (looksLikeAuthenticatedKlmsUrl(lower)) {
        const page = readKlmsPageLoadState(checkTab);
        if (page.loaded) {
          keepCheckTab = true;
          return {
            status: "authenticated",
            method: "dashboard-check-tab",
            url: page.href || lastUrl,
            title: page.title || readTitle(checkTab)
          };
        }
        pendingReason = "dashboard-check-loading";
      }
      if (
        lower.includes("klms.kaist.ac.kr/login/") ||
        lower.includes("ssologin.php") ||
        lower.includes("sso.kaist.ac.kr/auth/kaist/user/login/view")
      ) {
        pendingReason = "dashboard-check-login-required";
      }
      delay(0.1);
    }
    return twofactorPending(sourceUrl, pendingReason);
  } finally {
    if (keepCheckTab && checkTab) {
      try {
        windowRef.currentTab = checkTab;
      } catch (_error) {
        // Safari may already have selected the authenticated tab.
      }
    } else {
      closeTab(checkTab);
    }
    if (!keepCheckTab && previousTab) {
      try {
        windowRef.currentTab = previousTab;
      } catch (_error) {
        // The original 2FA tab may have been closed by Safari after authentication.
      }
    }
    prepareBackgroundWindow(windowRef);
    restoreFrontmostApplication(frontmostApp);
  }
}

function authCheckMilliseconds(options = {}) {
  const seconds = Number(options["auth-check-seconds"] || envValue("KLMS_LOGIN_ASSIST_AUTH_CHECK_SECONDS") || "1.2");
  const bounded = Math.max(0.2, Math.min(3, Number.isFinite(seconds) ? seconds : 1.2));
  return bounded * 1000;
}

function twofactorPending(url, reason) {
  return {
    status: "twofactor_pending",
    reason: reason || "phone-approval-pending",
    method: "dashboard-check-tab",
    url
  };
}

function readTitle(tab) {
  return safeString(() => tab.name());
}

function looksLikeAuthenticatedKlmsUrl(url) {
  const lower = String(url || "").toLowerCase();
  return (
    isExactKlmsHttpsUrl(lower) &&
    !lower.includes("/login/") &&
    !lower.includes("ssologin.php")
  );
}

function looksLikeKlmsLoginUrl(url) {
  const lower = String(url || "").toLowerCase();
  return isExactKlmsHttpsUrl(lower) && lower.includes("/login/");
}

function isExactKlmsHttpsUrl(url) {
  return /^https:\/\/klms\.kaist\.ac\.kr(?::443)?(?:[/?#]|$)/i.test(String(url || "").trim());
}

function isExactKaistSsoHttpsUrl(url) {
  return /^https:\/\/sso\.kaist\.ac\.kr(?::443)?(?:[/?#]|$)/i.test(String(url || "").trim());
}

function kaistSsoLoginUrl(targetUrl) {
  const redirectUrl = String(targetUrl || "https://klms.kaist.ac.kr/my/");
  return [
    "https://sso.kaist.ac.kr/auth/kaist/user/login/view",
    "?agt_id=kaist-prod-klms",
    `&agt_url=${encodeURIComponent("https://klms.kaist.ac.kr")}`,
    `&add_param_url=${encodeURIComponent(redirectUrl)}`
  ].join("");
}

function readKlmsPageLoadState(tab) {
  const result = runPageScript(tab, `
(() => {
  const href = String(window.location?.href || "");
  const title = String(document.title || "");
  const readyState = String(document.readyState || "");
  const bodyTextLength = document.body && document.body.innerText ? document.body.innerText.length : 0;
  return JSON.stringify({ href, title, readyState, bodyTextLength });
})();
`);
  const payload = parseJson(result);
  const readyState = String(payload.readyState || "");
  const title = String(payload.title || "");
  const bodyTextLength = Number(payload.bodyTextLength || 0);
  const loaded =
    looksLikeAuthenticatedKlmsUrl(payload.href) &&
    (readyState === "interactive" || readyState === "complete") &&
    (title.trim().length > 0 || bodyTextLength > 0);
  return Object.assign({}, payload, { loaded });
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
    const authWindow = findReusableAuthWindow(windows, backgroundWindowEnabled);
    if (authWindow) {
      return authWindow;
    }
    if (!backgroundWindowEnabled && windows.length > 0) return windows[0];
  }
  return createSafariWindow(safari, backgroundWindowEnabled);
}

function findReusableAuthWindow(windows, backgroundWindowEnabled) {
  for (let i = 0; i < windows.length; i += 1) {
    const windowRef = windows[i];
    const currentTab = safeValue(() => windowRef.currentTab());
    const currentUrl = safeString(() => currentTab.url());
    if (looksLikeKaistAuthUrl(currentUrl)) {
      if (backgroundWindowEnabled) {
        prepareBackgroundWindow(windowRef);
      }
      return windowRef;
    }
  }

  for (let i = 0; i < windows.length; i += 1) {
    const windowRef = windows[i];
    const tabs = safeList(() => windowRef.tabs());
    for (let j = 0; j < tabs.length; j += 1) {
      const tab = tabs[j];
      const url = safeString(() => tab.url());
      if (!looksLikeKaistAuthUrl(url)) {
        continue;
      }
      try {
        windowRef.currentTab = tab;
      } catch (_error) {
        // Safari may refuse to select a tab while a window is transitioning.
      }
      if (backgroundWindowEnabled) {
        prepareBackgroundWindow(windowRef);
      }
      return windowRef;
    }
  }

  return null;
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

function createSafariTab(windowRef, targetUrl) {
  if (!windowRef) {
    return null;
  }
  const safari = Application("/Applications/Safari.app");
  try {
    const tab = safari.Tab({ url: targetUrl });
    windowRef.tabs.push(tab);
    windowRef.currentTab = tab;
    delay(0.1);
    return safeValue(() => windowRef.currentTab()) || tab;
  } catch (_error) {
    try {
      const tab = safari.Tab();
      windowRef.tabs.push(tab);
      windowRef.currentTab = tab;
      tab.url = targetUrl;
      delay(0.1);
      return safeValue(() => windowRef.currentTab()) || tab;
    } catch (_fallbackError) {
      return null;
    }
  }
}

function looksLikeKaistAuthUrl(url) {
  return isExactKlmsHttpsUrl(url) || isExactKaistSsoHttpsUrl(url);
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
  if (isBackgroundWindow(windowRef)) {
    return;
  }
  if (safariBackgroundWindowMode() !== "minimize") {
    return;
  }
  try {
    windowRef.miniaturized = true;
  } catch (_error) {
    // Login assist can still scrape the page if minimizing is unavailable.
  }
}

function closeTab(tab) {
  if (!tab) {
    return;
  }
  try {
    tab.close();
  } catch (_error) {
    // The temporary auth-check tab may already be gone after a redirect.
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

function safariBackgroundWindowMode() {
  const configured = envValue("KLMS_SAFARI_BACKGROUND_WINDOW_MODE").trim().toLowerCase();
  if (configured === "offscreen") {
    return "minimize";
  }
  if (["minimize", "none"].includes(configured)) {
    return configured;
  }
  return "minimize";
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
  if (!safariRestoreFrontmostEnabled()) {
    return;
  }
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
  return envFlag("KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED", "1") && safariBackgroundWindowMode() !== "none";
}

function safariReuseExistingWindowEnabled() {
  return envFlag("KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED", "1");
}

function safariNonIntrusiveModeEnabled() {
  return envFlag("KLMS_APP_NON_INTRUSIVE_SAFARI", "0") || envFlag("KLMS_APP_RUN", "0");
}

function safariRestoreFrontmostEnabled() {
  const configured = envValue("KLMS_SAFARI_RESTORE_FRONTMOST_ENABLED");
  if (configured) {
    return envFlag("KLMS_SAFARI_RESTORE_FRONTMOST_ENABLED", "1");
  }
  return !safariNonIntrusiveModeEnabled();
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
