#!/usr/bin/osascript -l JavaScript

ObjC.import("Foundation");

function run(argv) {
  if (argv.length < 1) {
    throw new Error(
      "Usage: osascript -l JavaScript fetch_pages_with_safari.js [--wait=6] [--out=/tmp/pages.json] [--url-file=/tmp/urls.txt] <url1> [<url2> ...]"
    );
  }

  const waitArg = argv.find((arg) => arg.startsWith("--wait="));
  const minWaitArg = argv.find((arg) => arg.startsWith("--min-wait="));
  const stablePollsArg = argv.find((arg) => arg.startsWith("--stable-polls="));
  const outArg = argv.find((arg) => arg.startsWith("--out="));
  const urlFileArg = argv.find((arg) => arg.startsWith("--url-file="));
  const strategyArg = argv.find((arg) => arg.startsWith("--strategy="));
  const waitSeconds = waitArg ? Number(waitArg.replace("--wait=", "")) : 6;
  const minWaitSeconds = minWaitArg ? Number(minWaitArg.replace("--min-wait=", "")) : 1.5;
  const stablePolls = stablePollsArg ? Number(stablePollsArg.replace("--stable-polls=", "")) : 2;
  const outPath = outArg ? outArg.replace("--out=", "") : "";
  const strategy = strategyArg ? strategyArg.replace("--strategy=", "") : "auto";
  const backgroundWindowEnabled = safariBackgroundWindowEnabled();
  const reuseExistingWindowEnabled = envFlag("KLMS_SAFARI_REUSE_EXISTING_WINDOW_ENABLED", "1");
  const inlineUrls = argv.filter(
    (arg) =>
      !arg.startsWith("--wait=") &&
      !arg.startsWith("--min-wait=") &&
      !arg.startsWith("--stable-polls=") &&
      !arg.startsWith("--out=") &&
      !arg.startsWith("--strategy=") &&
      !arg.startsWith("--url-file=")
  );
  const fileUrls = urlFileArg ? readUrlLines(urlFileArg.replace("--url-file=", "")) : [];
  const urls = [...fileUrls, ...inlineUrls];

  if (!Number.isFinite(waitSeconds) || waitSeconds <= 0) {
    throw new Error(`Invalid wait seconds: ${waitArg}`);
  }
  if (!Number.isFinite(minWaitSeconds) || minWaitSeconds < 0 || minWaitSeconds > waitSeconds) {
    throw new Error(`Invalid min wait seconds: ${minWaitArg}`);
  }
  if (!Number.isFinite(stablePolls) || stablePolls < 1) {
    throw new Error(`Invalid stable polls: ${stablePollsArg}`);
  }
  if (!["auto", "navigation", "xhr"].includes(strategy)) {
    throw new Error(`Invalid fetch strategy: ${strategy}`);
  }

  if (urls.length === 0) {
    throw new Error("At least one URL is required.");
  }

  const safari = Application("/Applications/Safari.app");
  const safariWasRunning = safeValue(() => safari.running()) === true;
  const frontmostApp = safariRestoreFrontmostEnabled() ? frontmostApplicationName() : "";
  if (!safariWasRunning) {
    safari.launch();
    delay(1);
  }
  restoreFrontmostApplication(frontmostApp);

  const results = [];
  const windowRef = resolveFetchWindow(safari, backgroundWindowEnabled, reuseExistingWindowEnabled);
  if (!windowRef) {
    throw new Error("Failed to resolve a Safari window for page fetch.");
  }
  if (backgroundWindowEnabled) {
    prepareBackgroundWindow(windowRef);
    restoreFrontmostApplication(frontmostApp);
  }
  const tab = resolveFetchTab(windowRef);
  if (!tab) {
    throw new Error("Failed to resolve a Safari tab for page fetch.");
  }

  let usedBatchXHR = false;
  if (shouldUseXHRBatch(tab, urls, strategy)) {
    try {
      const pages = fetchPagesViaXHRBatch(tab, urls);
      pages.forEach((page, index) => {
        page.requestedUrl = urls[index];
        results.push(page);
      });
      usedBatchXHR = true;
    } catch (error) {
      if (strategy === "xhr") {
        throw error;
      }
    }
  }

  if (!usedBatchXHR) {
    for (let i = 0; i < urls.length; i += 1) {
      const targetUrl = urls[i];
      try {
        const page = fetchPage(windowRef, tab, targetUrl, {
          waitSeconds,
          minWaitSeconds,
          stablePolls,
          strategy,
        });
        page.requestedUrl = targetUrl;
        results.push(page);
      } catch (error) {
        throw new Error(`Safari fetch failed for ${i + 1}/${urls.length} ${targetUrl}: ${error}`);
      }
    }
  }

  const payload = JSON.stringify(results);
  if (outPath) {
    writeText(outPath, payload);
    return `Wrote ${results.length} page(s) to ${outPath}`;
  }
  return payload;
}

function shouldUseXHRBatch(tab, urls, strategy) {
  return (
    strategy !== "navigation" &&
    urls.length > 1 &&
    urls.length <= 20 &&
    urls.every((url) => canUseXHR(tab, url))
  );
}

function fetchPage(windowRef, tab, targetUrl, options) {
  const strategy = options.strategy || "auto";
  if (strategy !== "navigation" && canUseXHR(tab, targetUrl)) {
    try {
      return fetchPageViaXHR(tab, targetUrl);
    } catch (error) {
      if (strategy === "xhr") {
        throw error;
      }
    }
  }

  navigateFetchTab(windowRef, tab, targetUrl);
  return waitForPage(tab, options.waitSeconds, options.minWaitSeconds, options.stablePolls);
}

function canUseXHR(tab, targetUrl) {
  const currentUrl = safeString(() => tab.url()).toLowerCase();
  const requestedUrl = String(targetUrl || "").toLowerCase();
  return (
    currentUrl.includes("klms.kaist.ac.kr") &&
    requestedUrl.startsWith("https://klms.kaist.ac.kr/")
  );
}

function fetchPagesViaXHRBatch(tab, urls) {
  const script = `
(() => {
  const targetUrls = ${JSON.stringify(urls.map((url) => String(url || "")))};
  function titleFromHtml(html) {
    try {
      const doc = document.implementation.createHTMLDocument("");
      doc.documentElement.innerHTML = html || "";
      return doc.title || "";
    } catch (error) {
      const match = String(html || "").match(/<title[^>]*>([\\s\\S]*?)<\\/title>/i);
      return match ? match[1].replace(/\\s+/g, " ").trim() : "";
    }
  }
  const results = [];
  for (let i = 0; i < targetUrls.length; i += 1) {
    const targetUrl = targetUrls[i];
    try {
      const xhr = new XMLHttpRequest();
      xhr.open("GET", targetUrl, false);
      xhr.send(null);
      const html = xhr.responseText || "";
      results.push({
        url: xhr.responseURL || targetUrl,
        title: titleFromHtml(html),
        status: xhr.status || 0,
        html
      });
    } catch (error) {
      results.push({
        url: "",
        title: "",
        status: 0,
        html: "",
        error: String(error)
      });
    }
  }
  return JSON.stringify(results);
})();
`;
  const raw = safeString(() => Application("/Applications/Safari.app").doJavaScript(script, { in: tab }));
  if (!raw) {
    throw new Error("Empty batch XHR response");
  }
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (_error) {
    throw new Error(`Invalid batch XHR response: ${raw.slice(0, 200)}`);
  }
  if (!Array.isArray(payload) || payload.length !== urls.length) {
    throw new Error(`Unexpected batch XHR page count: ${Array.isArray(payload) ? payload.length : "invalid"}`);
  }
  return payload.map((page, index) => {
    if (!page || !page.html || Number(page.status || 0) <= 0) {
      throw new Error(
        `Batch XHR fetch failed for ${urls[index]}: ${(page && (page.error || page.status)) || "empty"}`
      );
    }
    return {
      url: String(page.url || urls[index]),
      title: String(page.title || ""),
      html: String(page.html || ""),
    };
  });
}

function fetchPageViaXHR(tab, targetUrl) {
  const script = `
(() => {
  const targetUrl = ${JSON.stringify(String(targetUrl || ""))};
  function titleFromHtml(html) {
    try {
      const doc = document.implementation.createHTMLDocument("");
      doc.documentElement.innerHTML = html || "";
      return doc.title || "";
    } catch (error) {
      const match = String(html || "").match(/<title[^>]*>([\\s\\S]*?)<\\/title>/i);
      return match ? match[1].replace(/\\s+/g, " ").trim() : "";
    }
  }
  try {
    const xhr = new XMLHttpRequest();
    xhr.open("GET", targetUrl, false);
    xhr.send(null);
    const html = xhr.responseText || "";
    return JSON.stringify({
      url: xhr.responseURL || targetUrl,
      title: titleFromHtml(html),
      status: xhr.status || 0,
      html
    });
  } catch (error) {
    return JSON.stringify({
      url: "",
      title: "",
      status: 0,
      html: "",
      error: String(error)
    });
  }
})();
`;
  const raw = safeString(() => Application("/Applications/Safari.app").doJavaScript(script, { in: tab }));
  if (!raw) {
    throw new Error(`Empty XHR response for ${targetUrl}`);
  }
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (_error) {
    throw new Error(`Invalid XHR response for ${targetUrl}: ${raw.slice(0, 200)}`);
  }
  if (!payload.html || Number(payload.status || 0) <= 0) {
    throw new Error(`XHR fetch failed for ${targetUrl}: ${payload.error || payload.status || "empty"}`);
  }
  return {
    url: String(payload.url || targetUrl),
    title: String(payload.title || ""),
    html: String(payload.html || ""),
  };
}

function waitForPage(tab, waitSeconds, minWaitSeconds, stablePolls) {
  const deadline = Date.now() + waitSeconds * 1000;
  const minWaitDeadline = Date.now() + minWaitSeconds * 1000;
  let stableCount = 0;
  let lastSignature = "";
  let latest = {
    url: "",
    title: "",
    html: "",
  };

  while (Date.now() < deadline) {
    delay(0.5);
    latest = readTab(tab);

    const signature = `${latest.url}\n${latest.title}\n${latest.html.length}`;
    if (latest.html && signature === lastSignature) {
      stableCount += 1;
    } else {
      stableCount = 0;
      lastSignature = signature;
    }

    if (Date.now() >= minWaitDeadline && latest.html && latest.url && stableCount >= stablePolls) {
      return latest;
    }
  }

  return latest;
}

function readTab(tab) {
  return {
    url: safeString(() => tab.url()),
    title: safeString(() => tab.name()),
    html: safeString(() => tab.source()),
  };
}

function resolveFetchWindow(safari, backgroundWindowEnabled, reuseExistingWindowEnabled) {
  if (reuseExistingWindowEnabled) {
    const reusableWindow = findReusableKlmsWindow(safari, backgroundWindowEnabled);
    if (reusableWindow) {
      return reusableWindow;
    }
  }
  return openFetchWindow(safari, backgroundWindowEnabled);
}

function findReusableKlmsWindow(safari, backgroundWindowEnabled) {
  const klmsWindows = safeList(() => safari.windows()).filter((windowRef) => {
    const tab = safeValue(() => windowRef.currentTab());
    const url = safeString(() => tab.url()).toLowerCase();
    return url.includes("klms.kaist.ac.kr");
  });
  if (backgroundWindowEnabled) {
    return klmsWindows.find((windowRef) => isBackgroundWindow(windowRef)) || null;
  }
  return klmsWindows[0] || null;
}

function openFetchWindow(safari, backgroundWindowEnabled) {
  const frontmostApp = safariRestoreFrontmostEnabled() ? frontmostApplicationName() : "";
  const previousWindowIds = new Set(listWindowIds(safari));
  safari.make({ new: "document" });
  delay(0.5);

  const windows = safeList(() => safari.windows());
  const windowRef =
    windows.find((windowRef) => !previousWindowIds.has(safeNumber(() => windowRef.id(), -1))) ||
    null;
  if (!windowRef) {
    throw new Error("Failed to create a dedicated Safari fetch window.");
  }
  if (windowRef && backgroundWindowEnabled) {
    prepareBackgroundWindow(windowRef);
    restoreFrontmostApplication(frontmostApp);
  }
  return windowRef;
}

function resolveFetchTab(windowRef) {
  return safeValue(() => windowRef.currentTab()) || null;
}

function navigateFetchTab(windowRef, tab, targetUrl) {
  try {
    const frontmostApp = safariRestoreFrontmostEnabled() ? frontmostApplicationName() : "";
    tab.url = targetUrl;
    if (safariBackgroundWindowEnabled()) {
      prepareBackgroundWindow(windowRef);
    }
    restoreFrontmostApplication(frontmostApp);
    waitForTabUrl(tab, targetUrl, 8);
    if (safariBackgroundWindowEnabled()) {
      prepareBackgroundWindow(windowRef);
      restoreFrontmostApplication(frontmostApp);
    }
  } catch (error) {
    throw new Error(`Failed to navigate Safari fetch tab to ${targetUrl}: ${error}`);
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
    // Safari automation can still run if minimizing is unavailable.
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

function safariBackgroundWindowEnabled() {
  return envFlag("KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED", "1") && safariBackgroundWindowMode() !== "none";
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
    // If the previous app cannot be activated, leave Safari state as-is.
  }
}

function waitForTabUrl(tab, expectedUrl, timeoutSeconds) {
  const deadline = Date.now() + timeoutSeconds * 1000;
  while (Date.now() < deadline) {
    const currentUrl = safeString(() => tab.url());
    if (currentUrl === expectedUrl) {
      return true;
    }
    delay(0.25);
  }
  return false;
}

function listWindowIds(safari) {
  return safeList(() => safari.windows())
    .map((windowRef) => safeNumber(() => windowRef.id(), null))
    .filter((windowId) => Number.isFinite(windowId));
}

function safeString(getter) {
  try {
    const value = getter();
    return value == null ? "" : String(value);
  } catch (error) {
    return "";
  }
}

function safeValue(getter) {
  try {
    return getter();
  } catch (error) {
    return null;
  }
}

function safeNumber(getter, fallback) {
  const value = safeValue(getter);
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function safeList(getter) {
  const value = safeValue(getter);
  return Array.isArray(value) ? value : [];
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

function writeText(path, text) {
  const nsPath = $(path).stringByStandardizingPath;
  const nsText = $(text);
  const error = Ref();
  const ok = nsText.writeToFileAtomicallyEncodingError(
    nsPath,
    true,
    $.NSUTF8StringEncoding,
    error
  );
  if (!ok) {
    throw new Error(
      `Failed to write ${path}: ${ObjC.unwrap(error[0].localizedDescription)}`
    );
  }
}

function readUrlLines(path) {
  const nsPath = $(path).stringByStandardizingPath;
  const error = Ref();
  const text = $.NSString.stringWithContentsOfFileEncodingError(
    nsPath,
    $.NSUTF8StringEncoding,
    error
  );
  if (text == null) {
    throw new Error(
      `Failed to read ${path}: ${ObjC.unwrap(error[0].localizedDescription)}`
    );
  }

  return String(ObjC.unwrap(text))
    .split(/\r?\n/)
    .map((line) => String(line).trim())
    .filter(Boolean);
}
