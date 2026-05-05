#!/usr/bin/osascript -l JavaScript

ObjC.import("Foundation");
const currentApp = Application.currentApplication();
currentApp.includeStandardAdditions = true;

function run(argv) {
  console.log("step: start");
  const options = parseArgs(argv);
  console.log("step: parsed-args");
  if (!options.manifestPath || !options.outputRoot || !options.basePage) {
    throw new Error(
      "Usage: download_klms_files_xhr_simple.js --manifest=/path/to/manifest.json --output-root=/path --base-page=https://klms.kaist.ac.kr/mod/courseboard/view.php?id=... [--download-log=/path/to/log.json]"
    );
  }

  const manifestPath = standardizePath(options.manifestPath);
  const outputRoot = standardizePath(options.outputRoot);
  const basePage = String(options.basePage);
  console.log("step: standardized-paths");
  const downloadLogPath = standardizePath(
    options.downloadLogPath || joinPath(directoryName(outputRoot), "download_log.json")
  );

  const manifest = readJson(manifestPath);
  console.log("step: read-manifest");
  if (!Array.isArray(manifest)) {
    throw new Error(`Manifest must be a JSON array: ${manifestPath}`);
  }

  console.log("step: ensure-output-root");
  ensureDir(outputRoot);
  console.log("step: ensure-log-dir");
  ensureDir(directoryName(downloadLogPath));
  console.log("step: ensured-dirs");

  const safari = Application("/Applications/Safari.app");
  safari.launch();
  safari.activate();
  console.log("step: safari-launched");
  safari.make({ new: "document", withProperties: { url: basePage } });
  delay(1);
  console.log("step: safari-opened");

  const windowRef = waitForFrontWindow(safari, 10);
  if (!windowRef) {
    throw new Error("Safari front window is unavailable.");
  }
  const tab = waitForCurrentTab(windowRef, 10);
  if (!tab) {
    throw new Error("Safari current tab is unavailable.");
  }
  delay(2);

  const results = [];

  manifest.forEach((entry, index) => {
    const destinationPath = standardizePath(
      String(
        entry.absolute_path ||
          joinPath(outputRoot, String(entry.relative_path || entry.filename || `file-${index + 1}`))
      )
    );

    try {
      ensureDir(directoryName(destinationPath));

      if (fileExists(destinationPath)) {
        results.push({
          index: index + 1,
          url: String(entry.url || ""),
          destination_path: destinationPath,
          bytes: fileSize(destinationPath),
          filename: baseName(destinationPath),
          skipped_existing: true,
        });
        return;
      }

      const payload = downloadInTab(safari, tab, String(entry.url || ""));
      if (!payload || payload.status < 200 || payload.status >= 300) {
        throw new Error(`status=${payload ? payload.status : "unknown"}`);
      }
      if (String(payload.responseUrl || "").includes("/login/")) {
        throw new Error("redirected-to-login");
      }
      if (!payload.base64) {
        throw new Error("empty-body");
      }

      writeBase64File(destinationPath, payload.base64);
      results.push({
        index: index + 1,
        url: String(entry.url || ""),
        destination_path: destinationPath,
        bytes: fileSize(destinationPath),
        filename: baseName(destinationPath),
        content_type: String(payload.contentType || ""),
        response_url: String(payload.responseUrl || ""),
      });
    } catch (error) {
      results.push({
        index: index + 1,
        url: String(entry.url || ""),
        destination_path: destinationPath,
        filename: baseName(destinationPath),
        error: String(error),
      });
    }
  });

  const payload = {
    manifestPath,
    outputRoot,
    downloadLogPath,
    fileCount: results.length,
    results,
  };
  writeJson(downloadLogPath, payload);
  return JSON.stringify(payload, null, 2);
}

function parseArgs(argv) {
  const options = {};
  argv.forEach((arg) => {
    if (arg.startsWith("--manifest=")) {
      options.manifestPath = arg.slice("--manifest=".length);
      return;
    }
    if (arg.startsWith("--output-root=")) {
      options.outputRoot = arg.slice("--output-root=".length);
      return;
    }
    if (arg.startsWith("--base-page=")) {
      options.basePage = arg.slice("--base-page=".length);
      return;
    }
    if (arg.startsWith("--download-log=")) {
      options.downloadLogPath = arg.slice("--download-log=".length);
      return;
    }
  });
  return options;
}

function waitForFrontWindow(safari, timeoutSeconds) {
  const deadline = Date.now() + timeoutSeconds * 1000;
  while (Date.now() < deadline) {
    const windows = safari.windows();
    if (Array.isArray(windows) && windows.length > 0) {
      return windows[0];
    }
    delay(0.5);
  }
  return null;
}

function waitForCurrentTab(windowRef, timeoutSeconds) {
  const deadline = Date.now() + timeoutSeconds * 1000;
  while (Date.now() < deadline) {
    try {
      const tab = windowRef.currentTab();
      if (tab) {
        return tab;
      }
    } catch (_error) {
      // retry
    }
    delay(0.5);
  }
  return null;
}

function downloadInTab(safari, tab, targetUrl) {
  const script = `
    (function() {
      const targetUrl = ${JSON.stringify(targetUrl)};
      function binaryStringToBase64(raw) {
        let binary = '';
        const chunk = 0x8000;
        for (let i = 0; i < raw.length; i += chunk) {
          const end = Math.min(i + chunk, raw.length);
          let segment = '';
          for (let j = i; j < end; j += 1) {
            segment += String.fromCharCode(raw.charCodeAt(j) & 0xff);
          }
          binary += segment;
        }
        return btoa(binary);
      }
      try {
        const xhr = new XMLHttpRequest();
        xhr.open('GET', targetUrl, false);
        xhr.overrideMimeType('text/plain; charset=x-user-defined');
        xhr.send(null);
        const raw = xhr.responseText || '';
        return JSON.stringify({
          status: xhr.status || 0,
          responseUrl: xhr.responseURL || '',
          contentType: xhr.getResponseHeader('Content-Type') || '',
          contentDisposition: xhr.getResponseHeader('Content-Disposition') || '',
          byteLength: raw.length,
          base64: raw.length ? binaryStringToBase64(raw) : ''
        });
      } catch (error) {
        return JSON.stringify({
          status: 0,
          responseUrl: '',
          contentType: '',
          contentDisposition: '',
          byteLength: 0,
          base64: '',
          error: String(error)
        });
      }
    })();
  `;

  const raw = safeString(() => safari.doJavaScript(script, { in: tab }));
  if (!raw) {
    throw new Error(`Empty JS response for ${targetUrl}`);
  }
  try {
    return JSON.parse(raw);
  } catch (_error) {
    throw new Error(`Invalid JSON response for ${targetUrl}: ${raw.slice(0, 200)}`);
  }
}

function readJson(path) {
  return JSON.parse(readText(path));
}

function writeJson(path, payload) {
  writeText(path, JSON.stringify(payload, null, 2));
}

function readText(path) {
  const error = Ref();
  const text = $.NSString.stringWithContentsOfFileEncodingError($(path), $.NSUTF8StringEncoding, error);
  if (text == null) {
    throw new Error(`Failed to read ${path}: ${ObjC.unwrap(error[0].localizedDescription)}`);
  }
  return ObjC.unwrap(text);
}

function writeText(path, text) {
  ensureDir(directoryName(path));
  const error = Ref();
  const ok = $(String(text)).writeToFileAtomicallyEncodingError($(path), true, $.NSUTF8StringEncoding, error);
  if (!ok) {
    throw new Error(`Failed to write ${path}: ${ObjC.unwrap(error[0].localizedDescription)}`);
  }
}

function writeBase64File(path, base64Text) {
  const decoded = $.NSData.alloc.initWithBase64EncodedStringOptions($(base64Text), 0);
  if (decoded == null) {
    throw new Error(`Failed to decode base64 for ${path}`);
  }
  ensureDir(directoryName(path));
  const error = Ref();
  const ok = decoded.writeToFileOptionsError($(path), 0, error);
  if (!ok) {
    throw new Error(`Failed to write ${path}: ${ObjC.unwrap(error[0].localizedDescription)}`);
  }
}

function ensureDir(path) {
  currentApp.doShellScript(`mkdir -p ${shellQuote(path)}`);
}

function fileExists(path) {
  return $.NSFileManager.defaultManager.fileExistsAtPath($(path));
}

function fileSize(path) {
  const attrs = $.NSFileManager.defaultManager.attributesOfItemAtPathError($(path), null);
  return Number(ObjC.unwrap(attrs.objectForKey("NSFileSize")) || 0);
}

function standardizePath(path) {
  return ObjC.unwrap($(String(path)).stringByStandardizingPath);
}

function joinPath() {
  const parts = Array.from(arguments).filter(Boolean);
  return standardizePath(parts.join("/"));
}

function directoryName(path) {
  return ObjC.unwrap($(path).stringByDeletingLastPathComponent);
}

function baseName(path) {
  return ObjC.unwrap($(path).lastPathComponent);
}

function safeString(getter) {
  try {
    const value = getter();
    return value == null ? "" : String(value);
  } catch (_error) {
    return "";
  }
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\"'\"'`)}'`;
}
