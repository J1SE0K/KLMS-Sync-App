(function exposeRelayState(root, factory) {
  const api = factory();
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
  if (root) {
    root.KLMSRelayState = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function createRelayStateAPI() {
  const knownScopes = [
    "commands",
    "syncData",
    "itemActions",
    "settingActions",
    "fileAccess",
    "requestLog",
    "sharedSettings"
  ];
  const statusCountFields = [
    "assignments", "exams", "helpDesk", "notices", "noticeNew", "noticeUpdated",
    "noticeIgnored", "fileTotal", "newFiles", "quarantine", "filePruned",
    "fileArchivePruned", "calendarCreated", "calendarUpdated", "calendarDeleted"
  ];
  const commandKinds = new Set(["fullSync", "filesSync", "coreSync", "noticeSync", "report", "doctor"]);
  const commandStatuses = new Set(["pending", "running", "completed", "cancelled", "failed", "macUnavailable"]);
  const phases = new Set(["idle", ...commandStatuses]);

  function emptyRefreshScope() {
    return Object.fromEntries(knownScopes.map((key) => [key, false]));
  }

  function fullRefreshScope() {
    return Object.fromEntries(knownScopes.map((key) => [key, true]));
  }

  function mergeRefreshScopes(...scopes) {
    const merged = emptyRefreshScope();
    for (const scope of scopes) {
      if (!scope || typeof scope !== "object") continue;
      for (const key of knownScopes) {
        merged[key] = merged[key] || scope[key] === true;
      }
    }
    return merged;
  }

  function mergeBooleanFlags(...scopes) {
    const merged = {};
    for (const scope of scopes) {
      if (!isPlainObject(scope)) continue;
      for (const [key, enabled] of Object.entries(scope)) {
        if (enabled === true) merged[key] = true;
      }
    }
    return merged;
  }

  function createFrameRenderScheduler(requestFrame, render) {
    if (typeof requestFrame !== "function" || typeof render !== "function") {
      throw new TypeError("requestFrame and render must be functions");
    }
    let scheduled = false;
    let pending = {};
    const flush = () => {
      if (!scheduled && Object.keys(pending).length === 0) return;
      scheduled = false;
      const scope = pending;
      pending = {};
      render(scope);
    };
    return {
      schedule(scope) {
        pending = mergeBooleanFlags(pending, scope);
        if (scheduled) return;
        scheduled = true;
        requestFrame(flush);
      },
      flush,
      get scheduled() {
        return scheduled;
      }
    };
  }

  function normalizeRelayStatusPayload(payload) {
    const source = isPlainObject(payload) ? payload : {};
    return {
      ok: source.ok === true,
      revision: normalizedRevision(source.revision),
      status: normalizeStatusFields(source.status),
      latestCommand: normalizeRemoteCommand(source.latestCommand),
      running: source.running === true,
      message: boundedString(source.message, 2_000)
    };
  }

  function normalizeRemoteCommand(command) {
    if (!isPlainObject(command)) return null;
    const id = boundedString(command.id, 128);
    const kind = boundedString(command.kind, 32);
    const status = boundedString(command.status, 32);
    if (!id || !commandKinds.has(kind) || !commandStatuses.has(status)) return null;
    return {
      id,
      kind,
      status,
      options: isPlainObject(command.options) ? { ...command.options } : {},
      summary: normalizeStatusFields(command.summary),
      message: boundedString(command.message, 2_000),
      createdAt: boundedString(command.createdAt, 128),
      updatedAt: boundedString(command.updatedAt, 128)
    };
  }

  function normalizeStatusFields(status) {
    if (!isPlainObject(status)) return {};
    const normalized = {};
    for (const field of statusCountFields) {
      if (!(field in status)) continue;
      const value = status[field];
      normalized[field] = Number.isSafeInteger(value) && value >= 0 ? value : 0;
    }
    const phase = boundedString(status.phase, 32);
    if (phases.has(phase)) normalized.phase = phase;
    if ("phaseDetail" in status) normalized.phaseDetail = nullableBoundedString(status.phaseDetail, 500);
    if ("loginRequired" in status) normalized.loginRequired = status.loginRequired === true;
    if ("authDigits" in status) {
      const digits = boundedString(status.authDigits, 12);
      normalized.authDigits = /^\d{4,8}$/.test(digits) ? digits : null;
    }
    if ("authStatusMessage" in status) {
      normalized.authStatusMessage = nullableBoundedString(status.authStatusMessage, 500);
    }
    return normalized;
  }

  function boundedString(value, maxLength) {
    return typeof value === "string" ? value.slice(0, maxLength) : "";
  }

  function nullableBoundedString(value, maxLength) {
    const normalized = boundedString(value, maxLength).trim();
    return normalized || null;
  }

  function isPlainObject(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    const prototype = Object.getPrototypeOf(value);
    return prototype === Object.prototype || prototype === null;
  }

  function refreshScopeForEvent(event, presets) {
    const declaredScopes = Array.isArray(event?.scopes) ? event.scopes : [];
    if (declaredScopes.length > 0) {
      const scope = emptyRefreshScope();
      let hasUnknownScope = false;
      for (const declared of declaredScopes) {
        switch (String(declared || "")) {
          case "status":
          case "commands":
          case "cancel":
            scope.commands = true;
            break;
          case "syncData":
          case "runLogs":
            scope.syncData = true;
            break;
          case "itemActions":
            scope.itemActions = true;
            break;
          case "settingActions":
            scope.settingActions = true;
            break;
          case "requestLog":
            scope.requestLog = true;
            break;
          case "fileAccess":
            scope.fileAccess = true;
            break;
          case "sharedSettings":
            scope.sharedSettings = true;
            break;
          default:
            hasUnknownScope = true;
            break;
        }
      }
      if (hasUnknownScope) return fullRefreshScope();
      return scope;
    }

    const reason = String(event?.reason || "").trim();
    if (reason === "state" || reason === "updated" || reason.startsWith("commands:") || reason.startsWith("cancel:")) {
      return presets.state;
    }
    if (reason === "sync-data" || reason.startsWith("sync-data:")) {
      return presets.syncData;
    }
    if (reason === "shared-settings" || reason.startsWith("shared-settings:")) {
      return presets.settings;
    }
    if (reason.startsWith("file-access:")) {
      return presets.fileAccess;
    }
    if (reason.startsWith("item-actions:")) {
      return presets.itemActions;
    }
    if (reason.startsWith("setting-actions:")) return presets.settingActions || presets.settings;
    if (reason.startsWith("logs-display:") || reason.startsWith("logs:")) {
      if (reason.includes("fileAccess") || reason.includes("file-access")) return presets.fileAccess;
      if (reason.includes("requestLog") || reason.includes("request-log")) return presets.requestLog || presets.displayLogs;
      if (reason.includes("settingAction") || reason.includes("setting-action")) return presets.settingActions || presets.displayLogs;
      if (reason.includes("itemAction") || reason.includes("item-action")) return presets.itemActions;
      if (reason.includes("runLog") || reason.includes("run-log")) return presets.syncData;
      if (reason.includes("command")) return presets.state;
      return presets.displayLogs;
    }
    return presets.full;
  }

  function eventApplyDecision(lastRevision, event) {
    const type = String(event?.type || "");
    if (event?.version != null && Number(event.version) !== 1) {
      return { action: "reconcile", revision: normalizedRevision(event?.revision) };
    }
    if (type === "ping") {
      return { action: "ignore", revision: normalizedRevision(event?.revision) };
    }
    if (!["hello", "changed", "pong"].includes(type)) {
      return { action: "reconcile", revision: normalizedRevision(event?.revision) };
    }
    const revision = Number(event?.revision);
    if (!Number.isSafeInteger(revision) || revision < 0) {
      return { action: event?.type === "hello" || event?.type === "pong" ? "reconcile" : "apply", revision: null };
    }
    if (type === "hello") {
      return { action: "reconcile", revision };
    }
    if (type === "pong") {
      return {
        action: revision === Number(lastRevision || 0) ? "ignore" : "reconcile",
        revision
      };
    }
    if (revision <= Number(lastRevision || 0)) {
      return { action: "ignore", revision };
    }
    if (event?.requiresSnapshot === true || revision > Number(lastRevision || 0) + 1) {
      return { action: "reconcile", revision };
    }
    return { action: "apply", revision };
  }

  function normalizedRevision(value) {
    if (value == null || value === "") return null;
    const revision = Number(value);
    return Number.isSafeInteger(revision) && revision >= 0 ? revision : null;
  }

  function isCurrentConnection(expectedGeneration, currentGeneration, configured = true) {
    return Boolean(configured) && Number(expectedGeneration) === Number(currentGeneration);
  }

  function normalizedConfigRevision(value) {
    if (value == null || value === "") return null;
    const revision = Number(value);
    return Number.isSafeInteger(revision) && revision >= 0 ? revision : null;
  }

  function isMutationMethod(method) {
    return !["GET", "HEAD", "OPTIONS"].includes(String(method || "GET").trim().toUpperCase());
  }

  function mutationConfigRevisionMatches(method, expectedRevision, currentRevision, storedRevision) {
    if (!isMutationMethod(method)) return true;
    const expected = normalizedConfigRevision(expectedRevision);
    const current = normalizedConfigRevision(currentRevision);
    const stored = normalizedConfigRevision(storedRevision);
    return expected != null && expected === current && expected === stored;
  }

  function createConfigBoundMutationRegistry() {
    const entries = new Set();
    return {
      track(controller, configRevision) {
        const entry = { controller, configRevision: normalizedConfigRevision(configRevision) };
        entries.add(entry);
        return () => entries.delete(entry);
      },
      abortStale(currentRevision) {
        const current = normalizedConfigRevision(currentRevision);
        let aborted = 0;
        for (const entry of entries) {
          if (entry.configRevision === current) continue;
          entries.delete(entry);
          if (!entry.controller.signal.aborted) {
            entry.controller.abort();
            aborted += 1;
          }
        }
        return aborted;
      },
      get size() {
        return entries.size;
      }
    };
  }

  function createKeyedSerialMutationQueue() {
    const tails = new Map();
    let nextID = 0;
    return {
      enqueue(key, operation) {
        nextID += 1;
        const operationID = nextID;
        const predecessor = tails.get(key)?.promise || Promise.resolve();
        const promise = predecessor
          .catch(() => {})
          .then(() => operation());
        tails.set(key, { id: operationID, promise });
        return promise.finally(() => {
          if (tails.get(key)?.id === operationID) {
            tails.delete(key);
          }
        });
      },
      clear() {
        tails.clear();
      },
      has(key) {
        return tails.has(key);
      }
    };
  }

  function jitteredReconnectDelay(baseDelay, random = Math.random) {
    const base = Math.min(2_000, Math.max(250, Number(baseDelay) || 250));
    const spread = Math.min(100, Math.floor(base * 0.1));
    const sample = Math.min(1, Math.max(0, Number(random()) || 0));
    const offset = Math.round((sample * 2 - 1) * spread);
    return Math.min(2_000, Math.max(250, base + offset));
  }

  function isValidRelayHello(event) {
    return isPlainObject(event)
      && event.type === "hello"
      && event.version === 1
      && Number.isSafeInteger(event.revision)
      && event.revision >= 0;
  }

  function setControlBusy(control, busy) {
    if (!control || !control.dataset) return;
    if (busy) {
      if (!control.disabled) {
        control.dataset.busyDisabled = "true";
        control.disabled = true;
      }
      return;
    }
    if (control.dataset.busyDisabled === "true") {
      control.disabled = false;
      delete control.dataset.busyDisabled;
    }
  }

  function resetRemoteState(target, defaultStatus) {
    Object.assign(target, {
      status: { ...defaultStatus },
      latestCommand: null,
      running: false,
      message: "",
      items: [],
      calendarChanges: [],
      verifySummary: null,
      sharedSettings: [],
      recentCommands: [],
      recentActions: [],
      recentSettingActions: [],
      recentFileAccess: [],
      recentRequestLog: [],
      runLogs: [],
      selectedKind: "all",
      selectedItemId: "",
      relayRevision: 0,
      socketConnected: false,
      connectionMessage: ""
    });
    return target;
  }

  return {
    createConfigBoundMutationRegistry,
    createFrameRenderScheduler,
    createKeyedSerialMutationQueue,
    emptyRefreshScope,
    eventApplyDecision,
    fullRefreshScope,
    isCurrentConnection,
    isMutationMethod,
    isValidRelayHello,
    jitteredReconnectDelay,
    mergeRefreshScopes,
    mergeBooleanFlags,
    mutationConfigRevisionMatches,
    normalizedConfigRevision,
    normalizeRelayStatusPayload,
    normalizeRemoteCommand,
    refreshScopeForEvent,
    resetRemoteState,
    setControlBusy
  };
});
