const commands = [
  { kind: "fullSync", label: "전체 동기화", icon: "refresh-cw" },
  { kind: "filesSync", label: "파일 동기화", icon: "folder-sync" },
  { kind: "coreSync", label: "과제/시험", icon: "list-checks" },
  { kind: "noticeSync", label: "공지 메모", icon: "notebook-tabs" },
  { kind: "report", label: "요약 갱신", icon: "chart-no-axes-combined" },
  { kind: "doctor", label: "진단", icon: "stethoscope" }
];

const iconClassByName = Object.freeze({
  "chart-no-axes-combined": "icon-chart-no-axes-combined",
  "folder-sync": "icon-folder-sync",
  "list-checks": "icon-list-checks",
  "notebook-tabs": "icon-notebook-tabs",
  "refresh-cw": "icon-refresh-cw",
  square: "icon-square",
  stethoscope: "icon-stethoscope"
});

const dashboardKinds = [
  { key: "all", label: "전체", get: (_status, items) => visibleItems(items).length },
  { key: "assignment", label: "과제", get: (status) => status.assignments },
  { key: "exam", label: "시험", get: (status) => status.exams },
  { key: "notice", label: "공지", get: (status) => status.notices },
  { key: "file", label: "파일", get: (status) => status.fileTotal },
  { key: "newFiles", label: "새 파일", get: (status) => status.newFiles },
  { key: "quarantine", label: "격리", get: (status) => status.quarantine },
  { key: "calendar", label: "캘린더", get: (status) => calendarChangeTotal(status) },
  { key: "hidden", label: "보관함", get: (_status, items) => items.filter((item) => item.isHidden).length }
];

const defaultStatus = {
  assignments: 0,
  exams: 0,
  helpDesk: 0,
  notices: 0,
  noticeNew: 0,
  noticeUpdated: 0,
  noticeIgnored: 0,
  fileTotal: 0,
  newFiles: 0,
  quarantine: 0,
  filePruned: 0,
  fileArchivePruned: 0,
  calendarCreated: 0,
  calendarUpdated: 0,
  calendarDeleted: 0,
  phase: "idle",
  phaseDetail: null,
  loginRequired: false,
  authDigits: null,
  authStatusMessage: null
};

const state = {
  configured: false,
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
  itemRenderLimit: 120,
  sort: "recent",
  query: "",
  relayRevision: 0,
  socketConnected: false,
  connectionPhase: "unconfigured",
  connectionMessage: "",
  connectionGeneration: 0,
  configRevision: 0,
  busy: false
};

const refreshScopes = {
  full: { commands: true, syncData: true, itemActions: true, settingActions: true, fileAccess: true, requestLog: true, sharedSettings: true },
  state: { commands: true, syncData: false, itemActions: false, settingActions: false, fileAccess: false, requestLog: true, sharedSettings: false },
  syncData: { commands: false, syncData: true, itemActions: false, settingActions: false, fileAccess: false, requestLog: false, sharedSettings: false },
  fileAccess: { commands: false, syncData: false, itemActions: false, settingActions: false, fileAccess: true, requestLog: true, sharedSettings: false },
  itemActions: { commands: false, syncData: false, itemActions: true, settingActions: false, fileAccess: false, requestLog: true, sharedSettings: false },
  settingActions: { commands: false, syncData: false, itemActions: false, settingActions: true, fileAccess: false, requestLog: true, sharedSettings: false },
  requestLog: { commands: false, syncData: false, itemActions: false, settingActions: false, fileAccess: false, requestLog: true, sharedSettings: false },
  settings: { commands: false, syncData: false, itemActions: false, settingActions: true, fileAccess: false, requestLog: true, sharedSettings: true },
  displayLogs: { commands: true, syncData: true, itemActions: true, settingActions: true, fileAccess: true, requestLog: true, sharedSettings: false }
};

const $ = (id) => document.getElementById(id);
const INITIAL_ITEM_RENDER_LIMIT = 120;
const ITEM_RENDER_INCREMENT = 120;
const REALTIME_BATCH_DELAY_MS = 100;
const REALTIME_RETRY_MIN_MS = 250;
const REALTIME_RETRY_MAX_MS = 2_000;
let searchRenderTimer = null;
let realtimeFlushTimer = null;
let realtimeRefreshRunning = false;
let realtimeRefreshGeneration = 0;
let realtimeRetryDelay = REALTIME_RETRY_MIN_MS;
let pendingRealtimeScope = null;
let pendingRealtimeRevision = 0;
let pendingRealtimeAuthoritativeSnapshot = false;
let pendingRealtimeRevisionEpoch = 0;
let relayObservedRevision = 0;
let relayRevisionEpoch = 0;
let refreshApplyOperationSequence = 0;
let latestRefreshApplyOperationID = 0;
const relayEndpointApplyVersions = new Map();
let settingMutationSequence = 0;
const settingMutationVersions = new Map();
const pendingSettingValues = new Map();
const settingMutationQueue = window.KLMSRelayState.createKeyedSerialMutationQueue();
const settingCommittedBaselines = new Map();
const settingAuthoritativeObservationVersions = new Map();
let settingAuthoritativeObservationSequence = 0;
const pendingCommandOverlays = new Map();
const pendingItemActionOverlays = new Map();
const pendingFileAccessOverlays = new Map();
let cancelSubmittingCommandID = "";
let cancelRequestedCommandID = "";
let sidebarReturnFocus = null;
let viewportResizeTimer = null;
const fullRenderScope = {
  header: true,
  primarySync: true,
  commands: true,
  dashboard: true,
  verify: true,
  items: true,
  detail: true,
  history: true
};
const frameRenderScheduler = window.KLMSRelayState.createFrameRenderScheduler(
  (callback) => window.requestAnimationFrame(callback),
  (scope) => renderScope(scope)
);

document.addEventListener("DOMContentLoaded", async () => {
  bindEvents();
  bindRealtimeEvents();
  renderAll();
  await loadConfig();
  if (state.configured) {
    await refreshAll({ quiet: true, auto: true, realtime: true });
  }
});

function bindEvents() {
  $("saveConnectionButton").addEventListener("click", saveConnection);
  $("checkConnectionButton").addEventListener("click", checkConnection);
  $("clearConnectionButton").addEventListener("click", clearConnection);
  $("pasteClipboardButton").addEventListener("click", pasteConnectionFromClipboard);
  $("parseConnectionButton").addEventListener("click", parseConnectionText);
  $("refreshButton").addEventListener("click", () => refreshAll());
  $("primarySyncButton").addEventListener("click", () => runOrCancelCommand("fullSync"));
  $("updateNoticeNotes")?.addEventListener("change", (event) => {
    updateSharedSetting("KLMS_UPDATE_NOTICE_NOTES", event.target.checked ? "1" : "0")
      .catch(showError);
  });
  $("copyStateButton").addEventListener("click", copyState);
  $("searchInput").addEventListener("input", (event) => {
    state.query = event.target.value;
    state.itemRenderLimit = INITIAL_ITEM_RENDER_LIMIT;
    window.clearTimeout(searchRenderTimer);
    searchRenderTimer = window.setTimeout(() => {
      renderItems();
    }, 90);
  });
  $("sortSelect").addEventListener("change", (event) => {
    state.sort = event.target.value;
    state.itemRenderLimit = INITIAL_ITEM_RENDER_LIMIT;
    renderItems();
  });
  $("sidebarToggleButton").addEventListener("click", (event) => {
    const opening = !document.body.classList.contains("sidebar-open");
    if (opening) sidebarReturnFocus = event.currentTarget;
    setSidebarOpen(opening, opening ? "commands" : "");
  });
  $("sidebarBackdrop").addEventListener("click", () => setSidebarOpen(false));
  document.querySelectorAll("[data-sidebar-target]").forEach((button) => {
    button.addEventListener("click", () => {
      sidebarReturnFocus = button;
      setSidebarOpen(true, button.dataset.sidebarTarget);
    });
  });
  window.addEventListener("resize", () => {
    document.body.classList.add("viewport-resizing");
    window.clearTimeout(viewportResizeTimer);
    viewportResizeTimer = window.setTimeout(() => {
      document.body.classList.remove("viewport-resizing");
      viewportResizeTimer = null;
    }, 200);
    setSidebarOpen(document.body.classList.contains("sidebar-open"));
  });
  window.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && document.body.classList.contains("sidebar-open")) {
      event.preventDefault();
      setSidebarOpen(false);
      return;
    }
    trapSidebarFocus(event);
  });
  setSidebarOpen(false);
}

function bindRealtimeEvents() {
  window.klmsWindows.onRelayEvent((event) => handleRelayEvent(event));
  window.klmsWindows.onRelaySocketState((socketState) => handleRelaySocketState(socketState));
}

async function loadConfig() {
  try {
    const config = await window.klmsWindows.loadConfig();
    $("relayURL").value = config.relayURL || "";
    $("relayToken").placeholder = config.hasToken ? "저장됨" : "처음 연결하거나 바꿀 때만 입력";
    state.configured = Boolean(config.relayURL && config.hasToken);
    state.configRevision = normalizedConfigRevision(config.configRevision) ?? 0;
    setConnectionPhase(state.configured ? "connecting" : "unconfigured");
    if (state.configured) {
      startRealtimeRefresh();
    } else {
      stopRealtimeRefresh();
    }
    renderAll();
  } catch (error) {
    showError(error);
  }
}

async function saveConnection(options = {}) {
  try {
    setBusy(true);
    const config = await window.klmsWindows.saveConfig({
      relayURL: $("relayURL").value,
      token: $("relayToken").value
    });
    $("relayToken").value = "";
    $("connectionPaste").value = "";
    $("relayToken").placeholder = config.hasToken ? "저장됨" : "처음 연결하거나 바꿀 때만 입력";
    state.configured = Boolean(config.relayURL && config.hasToken);
    state.configRevision = normalizedConfigRevision(config.configRevision) ?? state.configRevision;
    state.connectionGeneration += 1;
    resetRemoteRelayState();
    setConnectionPhase("connecting");
    renderAll();
    startRealtimeRefresh();
    if (!options.quiet) {
      toast("서버 연결 정보를 저장했습니다.");
    }
    if (options.refresh !== false) {
      await refreshAll({ quiet: true, reconcile: true });
    }
    return true;
  } catch (error) {
    showError(error);
    return false;
  } finally {
    setBusy(false);
  }
}

async function checkConnection() {
  const saved = await saveConnection({ quiet: true, refresh: false });
  if (saved) {
    await refreshAll({ check: true });
  }
}

async function clearConnection() {
  try {
    setBusy(true);
    const config = await window.klmsWindows.clearConfig();
    $("relayURL").value = config.relayURL || "";
    $("relayToken").value = "";
    $("relayToken").placeholder = "처음 연결하거나 바꿀 때만 입력";
    $("connectionPaste").value = "";
    state.configured = false;
    state.configRevision = normalizedConfigRevision(config.configRevision) ?? state.configRevision;
    state.connectionGeneration += 1;
    resetRemoteRelayState();
    stopRealtimeRefresh();
    setConnectionPhase("unconfigured");
    renderAll();
    toast("Windows 앱의 서버 연결 정보를 지웠습니다.");
  } catch (error) {
    showError(error);
  } finally {
    setBusy(false);
  }
}

function resetRemoteRelayState() {
  window.KLMSRelayState.resetRemoteState(state, defaultStatus);
  state.connectionMessage = "";
  state.itemRenderLimit = INITIAL_ITEM_RENDER_LIMIT;
  realtimeRefreshGeneration += 1;
  realtimeRefreshRunning = false;
  realtimeRetryDelay = REALTIME_RETRY_MIN_MS;
  pendingRealtimeScope = null;
  pendingRealtimeRevision = 0;
  pendingRealtimeAuthoritativeSnapshot = false;
  pendingRealtimeRevisionEpoch = 0;
  relayObservedRevision = 0;
  relayRevisionEpoch += 1;
  latestRefreshApplyOperationID = ++refreshApplyOperationSequence;
  invalidateRelayEndpointApplies();
  settingMutationVersions.clear();
  pendingSettingValues.clear();
  settingMutationQueue.clear();
  settingCommittedBaselines.clear();
  settingAuthoritativeObservationVersions.clear();
  pendingCommandOverlays.clear();
  pendingItemActionOverlays.clear();
  pendingFileAccessOverlays.clear();
  cancelSubmittingCommandID = "";
  cancelRequestedCommandID = "";
  if (realtimeFlushTimer) {
    window.clearTimeout(realtimeFlushTimer);
    realtimeFlushTimer = null;
  }
  applySharedSettings([]);
  const noticeSettingControl = $("updateNoticeNotes");
  if (noticeSettingControl) noticeSettingControl.disabled = false;
}

function beginRelayEndpointApply(endpoint) {
  const version = (relayEndpointApplyVersions.get(endpoint) || 0) + 1;
  relayEndpointApplyVersions.set(endpoint, version);
  return version;
}

function relayEndpointApplyIsCurrent(endpoint, version) {
  return relayEndpointApplyVersions.get(endpoint) === version;
}

function invalidateRelayEndpointApplies() {
  for (const endpoint of [
    "status",
    "commands",
    "syncData",
    "itemActions",
    "settingActions",
    "fileAccess",
    "requestLog",
    "sharedSettings"
  ]) {
    beginRelayEndpointApply(endpoint);
  }
}

function setSidebarOpen(isOpen, target = "") {
  const wasOpen = document.body.classList.contains("sidebar-open");
  const shouldOpen = Boolean(isOpen) && window.innerWidth < 1040;
  const compactClosed = window.innerWidth < 720 && !shouldOpen;
  document.body.classList.toggle("sidebar-open", shouldOpen);
  $("sidebarToggleButton")?.setAttribute("aria-expanded", shouldOpen ? "true" : "false");
  $("sidebarBackdrop")?.classList.toggle("hidden", !shouldOpen);
  const sidebar = $("appSidebar");
  const content = document.querySelector(".content");
  if (sidebar) {
    sidebar.inert = compactClosed;
    sidebar.setAttribute("aria-hidden", compactClosed ? "true" : "false");
  }
  if (content) {
    content.inert = shouldOpen;
    content.setAttribute("aria-hidden", shouldOpen ? "true" : "false");
  }
  if (shouldOpen && target) {
    window.requestAnimationFrame(() => {
      const panel = document.querySelector(`.${target}-panel`);
      panel?.scrollIntoView({ block: "start" });
      panel?.querySelector("button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])")
        ?.focus({ preventScroll: true });
    });
  } else if (wasOpen && !shouldOpen) {
    const returnFocus = sidebarReturnFocus;
    sidebarReturnFocus = null;
    window.requestAnimationFrame(() => {
      const focusTarget = returnFocus?.getClientRects().length ? returnFocus : $("primarySyncButton");
      focusTarget?.focus({ preventScroll: true });
    });
  }
}

function trapSidebarFocus(event) {
  if (event.key !== "Tab" || !document.body.classList.contains("sidebar-open")) return;
  const sidebar = $("appSidebar");
  const focusable = sidebarFocusableElements();
  if (!sidebar || focusable.length === 0) return;
  const activeElement = document.activeElement;
  const first = focusable[0];
  const last = focusable[focusable.length - 1];
  if (event.shiftKey && (activeElement === first || !sidebar.contains(activeElement))) {
    event.preventDefault();
    last.focus({ preventScroll: true });
  } else if (!event.shiftKey && (activeElement === last || !sidebar.contains(activeElement))) {
    event.preventDefault();
    first.focus({ preventScroll: true });
  }
}

function sidebarFocusableElements() {
  const sidebar = $("appSidebar");
  if (!sidebar) return [];
  return Array.from(sidebar.querySelectorAll(
    "button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), a[href], [tabindex]:not([tabindex='-1'])"
  )).filter((element) => element.getClientRects().length > 0 && !element.inert);
}

async function pasteConnectionFromClipboard() {
  try {
    const text = await window.klmsWindows.readClipboardText();
    $("connectionPaste").value = text || "";
    parseConnectionText();
  } catch (error) {
    showError(error);
  }
}

function parseConnectionText() {
  const text = $("connectionPaste").value;
  const parsed = parseConnectionInfo(text);
  if (parsed.url) {
    $("relayURL").value = parsed.url;
  }
  if (parsed.token) {
    $("relayToken").value = parsed.token;
  }
  toast(parsed.url && parsed.token ? "연결 정보를 읽었습니다." : "주소나 클라이언트 토큰을 찾지 못했습니다.");
}

function parseConnectionInfo(text) {
  const url = text.match(/https?:\/\/[^\s"'<>]+/i)?.[0] || "";
  const token = text.match(/(?:클라이언트\s*토큰|client\s*(?:relay\s*)?token|iphone\s*토큰|windows\s*토큰)\s*[:=]\s*([A-Za-z0-9._-]{12,})/i)?.[1]
    || text.match(/(?:토큰|token)\s*[:=]\s*([A-Za-z0-9._-]{12,})/i)?.[1]
    || text.match(/\b([a-f0-9]{48,128})\b/i)?.[1]
    || "";
  return {
    url: url.replace(/[),.]+$/, ""),
    token
  };
}

async function refreshAll(options = {}) {
  if (!state.configured && !options.check) {
    return false;
  }
  const scope = options.scope || refreshScopes.full;
  if ((options.auto || options.realtime) && (state.busy || realtimeRefreshRunning)) {
    queueRealtimeRefresh(scope, options.targetRevision);
    return false;
  }
  const connectionGeneration = state.connectionGeneration;
  const refreshOperationID = ++refreshApplyOperationSequence;
  latestRefreshApplyOperationID = refreshOperationID;
  const realtimeOperation = options.realtime ? ++realtimeRefreshGeneration : 0;
  if (options.realtime) realtimeRefreshRunning = true;
  const refreshIsCurrent = () => (
    refreshOperationID === latestRefreshApplyOperationID
    && connectionGeneration === state.connectionGeneration
    && state.configured
    && (options.revisionEpoch == null || options.revisionEpoch === relayRevisionEpoch)
  );
  const preserveSupersededRealtimeWork = () => {
    if ((options.auto || options.realtime) && state.configured && connectionGeneration === state.connectionGeneration) {
      queueRealtimeRefresh(scope, options.targetRevision, options.authoritativeSnapshot === true);
    }
  };
  const relayResult = (request) => request.then(
    (payload) => ({ payload, error: null }),
    (error) => ({ payload: null, error })
  );
  const frameRenderedRefresh = Boolean(options.auto || options.realtime);
  let appliedRenderScope = {};
  try {
    if (!options.auto) {
      setBusy(true);
      setConnectionPhase("checking");
    }
    if (!options.auto && !options.realtime) {
      await window.klmsWindows.relayRequest({ path: "/healthz" });
      if (!refreshIsCurrent()) {
        preserveSupersededRealtimeWork();
        return false;
      }
    }
    const endpointApplyVersions = {
      status: beginRelayEndpointApply("status"),
      commands: scope.commands ? beginRelayEndpointApply("commands") : null,
      syncData: scope.syncData ? beginRelayEndpointApply("syncData") : null,
      itemActions: scope.itemActions ? beginRelayEndpointApply("itemActions") : null,
      settingActions: scope.settingActions ? beginRelayEndpointApply("settingActions") : null,
      fileAccess: scope.fileAccess ? beginRelayEndpointApply("fileAccess") : null,
      requestLog: scope.requestLog ? beginRelayEndpointApply("requestLog") : null,
      sharedSettings: scope.sharedSettings ? beginRelayEndpointApply("sharedSettings") : null
    };
    const requests = {
      status: relayResult(window.klmsWindows.relayRequest({ path: "/v1/status" })),
      commands: scope.commands
        ? relayResult(window.klmsWindows.relayRequest({ path: "/v1/commands/recent?limit=8" }))
        : Promise.resolve({ payload: null, error: null }),
      syncData: scope.syncData
        ? relayResult(window.klmsWindows.relayRequest({ path: "/v1/sync-data?limit=2000" }))
        : Promise.resolve({ payload: null, error: null }),
      itemActions: scope.itemActions
        ? relayResult(window.klmsWindows.relayRequest({ path: "/v1/item-actions/recent?limit=10" }))
        : Promise.resolve({ payload: null, error: null }),
      settingActions: scope.settingActions
        ? relayResult(window.klmsWindows.relayRequest({ path: "/v1/setting-actions/recent?limit=10" }))
        : Promise.resolve({ payload: null, error: null }),
      fileAccess: scope.fileAccess
        ? relayResult(window.klmsWindows.relayRequest({ path: "/v1/file-access/recent?limit=20" }))
        : Promise.resolve({ payload: null, error: null }),
      requestLog: scope.requestLog
        ? relayResult(window.klmsWindows.relayRequest({ path: "/v1/request-log/recent?limit=20" }))
        : Promise.resolve({ payload: null, error: null }),
      sharedSettings: scope.sharedSettings
        ? relayResult(window.klmsWindows.relayRequest({ path: "/v1/shared-settings" }))
        : Promise.resolve({ payload: null, error: null })
    };

    const applyResultWhenCurrent = async (endpoint, resultPromise, applyPayload) => {
      const result = await resultPromise;
      const endpointVersion = endpointApplyVersions[endpoint];
      if (!refreshIsCurrent() || (endpointVersion != null && !relayEndpointApplyIsCurrent(endpoint, endpointVersion))) {
        return { ...result, stale: true };
      }
      if (result.payload) {
        applyPayload(result.payload);
        appliedRenderScope = window.KLMSRelayState.mergeBooleanFlags(
          appliedRenderScope,
          renderScopeForEndpoint(endpoint)
        );
        if (frameRenderedRefresh) scheduleRender(appliedRenderScope);
      }
      return { ...result, stale: false };
    };
    let statusResponse = null;
    let syncData = null;
    const statusApplyTask = applyResultWhenCurrent("status", requests.status, (payload) => {
        statusResponse = payload;
        applyStatus(payload);
      });
    const commandApplyTask = applyResultWhenCurrent("commands", requests.commands, (payload) => {
        applyCommandResponse(payload);
      });
    const syncDataApplyTask = applyResultWhenCurrent("syncData", requests.syncData, (payload) => {
        syncData = payload;
        applySyncDataResponse(payload, { applySharedSettings: !scope.sharedSettings });
      });
    const actionApplyTask = applyResultWhenCurrent("itemActions", requests.itemActions, (payload) => {
        state.recentActions = itemActionsOverlayingPending(payload.actions || []);
      });
    const settingActionApplyTask = applyResultWhenCurrent("settingActions", requests.settingActions, (payload) => {
        state.recentSettingActions = payload.actions || [];
      });
    const fileAccessApplyTask = applyResultWhenCurrent("fileAccess", requests.fileAccess, (payload) => {
        state.recentFileAccess = fileAccessRequestsOverlayingPending(payload.requests || []);
      });
    const requestLogApplyTask = applyResultWhenCurrent("requestLog", requests.requestLog, (payload) => {
        state.recentRequestLog = payload.entries || [];
      });
    const sharedSettingsApplyTask = applyResultWhenCurrent("sharedSettings", requests.sharedSettings, (payload) => {
        applySharedSettings(
          Array.isArray(payload) ? payload : payload.settings || [],
          { authoritative: true }
        );
      });
    const [
      statusResult,
      commandResult,
      syncDataResult,
      actionResult,
      settingActionResult,
      fileAccessResult,
      requestLogResult,
      sharedSettingsResult
    ] = await Promise.all([
      statusApplyTask,
      commandApplyTask,
      syncDataApplyTask,
      actionApplyTask,
      settingActionApplyTask,
      fileAccessApplyTask,
      requestLogApplyTask,
      sharedSettingsApplyTask
    ]);
    if ([statusResult, commandResult, syncDataResult, actionResult, settingActionResult, fileAccessResult, requestLogResult, sharedSettingsResult]
      .some((result) => result.stale)) {
      preserveSupersededRealtimeWork();
      return false;
    }
    const failedResult = [commandResult, syncDataResult, actionResult, settingActionResult, fileAccessResult, requestLogResult, sharedSettingsResult]
      .find((result) => result.error);
    if (statusResult.error) throw statusResult.error;
    if (failedResult) throw failedResult.error;

    const responseRevision = highestRelayRevision(statusResponse?.revision, syncData?.revision);
    const targetRevision = normalizedRelayRevision(options.targetRevision);
    const appliedRevision = responseRevision ?? targetRevision;
    if (options.authoritativeSnapshot) {
      state.relayRevision = appliedRevision ?? 0;
    } else if (appliedRevision != null) {
      state.relayRevision = Math.max(state.relayRevision, appliedRevision);
    }
    if (appliedRevision != null) {
      relayObservedRevision = Math.max(relayObservedRevision, appliedRevision);
    }
    setConnectionPhase(state.socketConnected ? "connected" : "reconnecting");
    if (options.check) {
      toast("서버 릴레이와 연결됐습니다.");
    }
    if (frameRenderedRefresh) {
      scheduleRender(window.KLMSRelayState.mergeBooleanFlags(appliedRenderScope, { header: true }));
    } else {
      renderAll();
    }
    return true;
  } catch (error) {
    if (refreshIsCurrent()) {
      state.connectionMessage = error && typeof error.message === "string" ? error.message.slice(0, 500) : "";
      setConnectionPhase("error");
    }
    if (!options.quiet && refreshIsCurrent()) {
      showError(error);
    }
    return false;
  } finally {
    if (options.realtime && realtimeOperation === realtimeRefreshGeneration) {
      realtimeRefreshRunning = false;
    }
    if (!options.auto && refreshOperationID === latestRefreshApplyOperationID) {
      setBusy(false);
    }
    scheduleRealtimeFlush(0);
  }
}

function applySharedSettings(settings, options = {}) {
  const nextSettings = Array.isArray(settings) ? settings.map((setting) => ({ ...setting })) : [];
  if (options.authoritative && pendingSettingValues.size > 0) {
    for (const key of pendingSettingValues.keys()) {
      settingAuthoritativeObservationSequence += 1;
      settingAuthoritativeObservationVersions.set(key, settingAuthoritativeObservationSequence);
      const incomingSetting = nextSettings.find((setting) => setting.key === key) || null;
      const baseline = settingCommittedBaselines.get(key)?.value ?? null;
      if (!incomingSetting || settingIsNotOlderThan(incomingSetting, baseline)) {
        recordSettingCommittedBaseline(key, incomingSetting);
      }
    }
  }
  for (const [key, pendingSetting] of pendingSettingValues) {
    const index = nextSettings.findIndex((setting) => setting.key === key);
    if (index >= 0) {
      nextSettings[index] = { ...nextSettings[index], ...pendingSetting };
    } else {
      nextSettings.push({ ...pendingSetting });
    }
  }
  state.sharedSettings = nextSettings;
  const noticeSetting = state.sharedSettings.find((setting) => setting.key === "KLMS_UPDATE_NOTICE_NOTES");
  const noticeCheckbox = $("updateNoticeNotes");
  if (noticeCheckbox) {
    noticeCheckbox.checked = noticeSetting ? isTruthySettingValue(noticeSetting.value) : true;
  }
}

function beginSettingMutationChain(key, connectionGeneration, configRevision, committedValue) {
  const baseline = settingCommittedBaselines.get(key);
  if (baseline?.connectionGeneration === connectionGeneration && baseline?.configRevision === configRevision) {
    return;
  }
  settingCommittedBaselines.set(key, {
    connectionGeneration,
    configRevision,
    value: committedValue ? { ...committedValue } : null
  });
}

function recordSettingCommittedBaseline(key, value) {
  const baseline = settingCommittedBaselines.get(key);
  if (!baseline) return;
  baseline.value = value ? { ...value } : null;
}

function endSettingMutationChain(key, connectionGeneration, configRevision) {
  const baseline = settingCommittedBaselines.get(key);
  if (baseline?.connectionGeneration === connectionGeneration && baseline?.configRevision === configRevision) {
    settingCommittedBaselines.delete(key);
    settingAuthoritativeObservationVersions.delete(key);
  }
}

function restoreCommittedSharedSetting(key, committedSetting) {
  applySharedSettings([
    ...state.sharedSettings.filter((setting) => setting.key !== key),
    ...(committedSetting ? [{ ...committedSetting }] : [])
  ]);
}

function settingIsNotOlderThan(candidate, baseline) {
  if (!candidate) return false;
  if (!baseline) return true;
  const candidateTimestamp = Date.parse(candidate.updatedAt || "");
  const baselineTimestamp = Date.parse(baseline.updatedAt || "");
  if (Number.isFinite(candidateTimestamp) && Number.isFinite(baselineTimestamp)) {
    return candidateTimestamp >= baselineTimestamp;
  }
  return String(candidate.updatedAt || "") >= String(baseline.updatedAt || "");
}

function settingIsStrictlyNewerThan(candidate, baseline) {
  if (!candidate) return false;
  if (!baseline) return true;
  const candidateTimestamp = Date.parse(candidate.updatedAt || "");
  const baselineTimestamp = Date.parse(baseline.updatedAt || "");
  if (Number.isFinite(candidateTimestamp) && Number.isFinite(baselineTimestamp)) {
    return candidateTimestamp > baselineTimestamp;
  }
  return String(candidate.updatedAt || "") > String(baseline.updatedAt || "");
}

async function updateSharedSetting(key, value) {
  if (!state.configured) {
    toast("서버 연결 후 설정을 저장할 수 있습니다.");
    return;
  }
  const title = key === "KLMS_UPDATE_NOTICE_NOTES" ? "공지 메모 업데이트" : key;
  const valueKind = key === "KLMS_UPDATE_NOTICE_NOTES" ? "bool" : "text";
  const connectionGeneration = state.connectionGeneration;
  const configRevision = state.configRevision;
  const mutationVersion = ++settingMutationSequence;
  settingMutationVersions.set(key, mutationVersion);
  const previousSetting = state.sharedSettings.find((setting) => setting.key === key);
  beginSettingMutationChain(key, connectionGeneration, configRevision, previousSetting);
  const authoritativeObservationVersion = settingAuthoritativeObservationVersions.get(key) || 0;
  const optimisticSetting = {
    key,
    title,
    value,
    valueKind,
    options: [],
    editable: true,
    updatedAt: new Date().toISOString()
  };
  pendingSettingValues.set(key, optimisticSetting);
  const settingControl = key === "KLMS_UPDATE_NOTICE_NOTES" ? $("updateNoticeNotes") : null;
  if (settingControl) settingControl.disabled = true;
  applySharedSettings([
    ...state.sharedSettings.filter((item) => item.key !== key),
    optimisticSetting
  ]);
  renderAll();
  try {
    await settingMutationQueue.enqueue(key, async () => {
      if (!isCurrentConnection(connectionGeneration)
        || state.configRevision !== configRevision
        || settingMutationVersions.get(key) !== mutationVersion) {
        return;
      }
      try {
        const setting = await relayMutationRequest({
          path: `/v1/shared-settings/${encodeURIComponent(key)}`,
          method: "PUT",
          body: optimisticSetting
        }, configRevision);
        if (!isCurrentConnection(connectionGeneration) || state.configRevision !== configRevision) {
          return;
        }
        const committedSetting = settingCommittedBaselines.get(key)?.value ?? null;
        const authoritativeObservationIsUnchanged =
          (settingAuthoritativeObservationVersions.get(key) || 0) === authoritativeObservationVersion;
        const savedWasAccepted = authoritativeObservationIsUnchanged
          || settingIsStrictlyNewerThan(setting, committedSetting);
        if (savedWasAccepted) {
          recordSettingCommittedBaseline(key, setting);
        }
        if (settingMutationVersions.get(key) !== mutationVersion) {
          return;
        }
        pendingSettingValues.delete(key);
        if (savedWasAccepted) {
          applySharedSettings([
            ...state.sharedSettings.filter((item) => item.key !== key),
            setting
          ]);
        } else {
          restoreCommittedSharedSetting(key, committedSetting);
        }
        endSettingMutationChain(key, connectionGeneration, configRevision);
        renderAll();
        toast(`${title} 설정을 저장했습니다.`);
      } catch (error) {
        if (!isCurrentConnection(connectionGeneration)
          || state.configRevision !== configRevision
          || settingMutationVersions.get(key) !== mutationVersion) {
          return;
        }
        const committedSetting = settingCommittedBaselines.get(key)?.value ?? null;
        pendingSettingValues.delete(key);
        restoreCommittedSharedSetting(key, committedSetting);
        endSettingMutationChain(key, connectionGeneration, configRevision);
        renderAll();
        throw error;
      }
    });
  } finally {
    if (settingMutationVersions.get(key) === mutationVersion) {
      settingMutationVersions.delete(key);
      if (settingControl && isCurrentConnection(connectionGeneration)) {
        settingControl.disabled = false;
      }
    }
  }
}

function isTruthySettingValue(value) {
  return ["1", "true", "yes", "y", "on"].includes(String(value || "").trim().toLowerCase());
}

function startRealtimeRefresh() {
  if (!state.configured) {
    stopRealtimeRefresh();
    return;
  }
  const connectionGeneration = state.connectionGeneration;
  setConnectionPhase("connecting");
  window.klmsWindows.startRelayEvents({
    sinceRevision: state.relayRevision,
    clientGeneration: connectionGeneration
  }).catch((error) => {
    if (isCurrentConnection(connectionGeneration)) showError(error);
  });
}

function stopRealtimeRefresh() {
  state.socketConnected = false;
  if (state.configured) setConnectionPhase("offline");
  window.klmsWindows.stopRelayEvents().catch(() => {});
  if (realtimeFlushTimer) {
    window.clearTimeout(realtimeFlushTimer);
    realtimeFlushTimer = null;
  }
  pendingRealtimeScope = null;
  pendingRealtimeRevision = 0;
  pendingRealtimeAuthoritativeSnapshot = false;
  pendingRealtimeRevisionEpoch = relayRevisionEpoch;
}

function handleRelaySocketState(socketState) {
  if (!isCurrentConnectionPayload(socketState)) return;
  const status = String(socketState?.state || "");
  state.connectionMessage = typeof socketState?.message === "string"
    ? socketState.message.slice(0, 500)
    : "";
  state.socketConnected = status === "connected";
  if (status === "connected") {
    setConnectionPhase("connected");
    return;
  }
  setConnectionPhase(status === "stopped" ? "offline" : status === "connecting" ? "connecting" : "reconnecting");
}

function handleRelayEvent(event) {
  if (!event || typeof event !== "object" || !isCurrentConnectionPayload(event)) return;
  const previousObservedRevision = relayObservedRevision;
  const decision = window.KLMSRelayState.eventApplyDecision(relayObservedRevision, event);
  if (decision.action === "ignore") return;
  const eventRevision = normalizedRelayRevision(decision.revision);
  const startsAuthoritativeSnapshot = event.type === "hello"
    || (event.type === "pong" && eventRevision != null && eventRevision < previousObservedRevision);
  if (startsAuthoritativeSnapshot) {
    relayRevisionEpoch += 1;
    relayObservedRevision = eventRevision ?? 0;
  } else if (eventRevision != null) {
    relayObservedRevision = Math.max(relayObservedRevision, eventRevision);
  }
  const scope = decision.action === "reconcile"
    ? refreshScopes.full
    : window.KLMSRelayState.refreshScopeForEvent(event, refreshScopes);
  if ((state.busy || realtimeRefreshRunning) && !startsAuthoritativeSnapshot) {
    void refreshRealtimePreview(scope, relayRevisionEpoch);
  }
  queueRealtimeRefresh(scope, decision.revision, startsAuthoritativeSnapshot);
}

async function refreshRealtimePreview(scope, expectedRevisionEpoch) {
  const connectionGeneration = state.connectionGeneration;
  const previewEndpoint = async (endpoint, path, applyPayload) => {
    const applyVersion = beginRelayEndpointApply(endpoint);
    try {
      const payload = await window.klmsWindows.relayRequest({ path });
      if (!isCurrentConnection(connectionGeneration)
        || expectedRevisionEpoch !== relayRevisionEpoch
        || !relayEndpointApplyIsCurrent(endpoint, applyVersion)) {
        return;
      }
      applyPayload(payload);
      scheduleRender(renderScopeForEndpoint(endpoint));
    } catch {
      // The queued authoritative refresh retains retry and error handling.
    }
  };
  const tasks = [
    previewEndpoint("status", "/v1/status", (payload) => applyStatus(payload))
  ];
  if (scope.commands) {
    tasks.push(previewEndpoint("commands", "/v1/commands/recent?limit=8", (payload) => applyCommandResponse(payload)));
  }
  if (scope.syncData) {
    tasks.push(previewEndpoint("syncData", "/v1/sync-data?limit=2000", (payload) => {
      applySyncDataResponse(payload, { applySharedSettings: !scope.sharedSettings });
    }));
  }
  if (scope.itemActions) {
    tasks.push(previewEndpoint("itemActions", "/v1/item-actions/recent?limit=10", (payload) => {
      state.recentActions = itemActionsOverlayingPending(payload.actions || []);
    }));
  }
  if (scope.settingActions) {
    tasks.push(previewEndpoint("settingActions", "/v1/setting-actions/recent?limit=10", (payload) => {
      state.recentSettingActions = payload.actions || [];
    }));
  }
  if (scope.fileAccess) {
    tasks.push(previewEndpoint("fileAccess", "/v1/file-access/recent?limit=20", (payload) => {
      state.recentFileAccess = fileAccessRequestsOverlayingPending(payload.requests || []);
    }));
  }
  if (scope.requestLog) {
    tasks.push(previewEndpoint("requestLog", "/v1/request-log/recent?limit=20", (payload) => {
      state.recentRequestLog = payload.entries || [];
    }));
  }
  if (scope.sharedSettings) {
    tasks.push(previewEndpoint("sharedSettings", "/v1/shared-settings", (payload) => {
      applySharedSettings(Array.isArray(payload) ? payload : payload.settings || [], { authoritative: true });
    }));
  }
  await Promise.allSettled(tasks);
}

function queueRealtimeRefresh(scope, revision, authoritativeSnapshot = false) {
  const normalizedRevision = normalizedRelayRevision(revision);
  if (authoritativeSnapshot) {
    pendingRealtimeScope = null;
    pendingRealtimeRevision = normalizedRevision ?? 0;
    pendingRealtimeAuthoritativeSnapshot = true;
  }
  pendingRealtimeScope = window.KLMSRelayState.mergeRefreshScopes(pendingRealtimeScope, scope);
  if (normalizedRevision != null && !authoritativeSnapshot) {
    pendingRealtimeRevision = Math.max(pendingRealtimeRevision, normalizedRevision);
  }
  pendingRealtimeRevisionEpoch = relayRevisionEpoch;
  scheduleRealtimeFlush();
}

function scheduleRealtimeFlush(delay = REALTIME_BATCH_DELAY_MS) {
  if (!pendingRealtimeScope || realtimeFlushTimer || state.busy || realtimeRefreshRunning || !state.configured) return;
  realtimeFlushTimer = window.setTimeout(() => {
    realtimeFlushTimer = null;
    flushRealtimeRefresh();
  }, delay);
}

async function flushRealtimeRefresh() {
  if (!pendingRealtimeScope || state.busy || realtimeRefreshRunning || !state.configured) return;
  const scope = pendingRealtimeScope;
  const targetRevision = pendingRealtimeRevision;
  const authoritativeSnapshot = pendingRealtimeAuthoritativeSnapshot;
  const revisionEpoch = pendingRealtimeRevisionEpoch;
  const connectionGeneration = state.connectionGeneration;
  pendingRealtimeScope = null;
  pendingRealtimeRevision = 0;
  pendingRealtimeAuthoritativeSnapshot = false;
  const refreshed = await refreshAll({
    quiet: true,
    auto: true,
    realtime: true,
    scope,
    targetRevision,
    authoritativeSnapshot,
    revisionEpoch
  });
  if (!isCurrentConnection(connectionGeneration)) return;
  if (revisionEpoch !== relayRevisionEpoch) return;
  if (refreshed) {
    realtimeRetryDelay = REALTIME_RETRY_MIN_MS;
    return;
  }
  pendingRealtimeScope = window.KLMSRelayState.mergeRefreshScopes(pendingRealtimeScope, scope);
  if (authoritativeSnapshot) {
    pendingRealtimeRevision = targetRevision;
    pendingRealtimeAuthoritativeSnapshot = true;
  } else if (normalizedRelayRevision(targetRevision) != null) {
    pendingRealtimeRevision = Math.max(pendingRealtimeRevision, targetRevision);
  }
  pendingRealtimeRevisionEpoch = revisionEpoch;
  const retryDelay = realtimeRetryDelay;
  realtimeRetryDelay = Math.min(REALTIME_RETRY_MAX_MS, realtimeRetryDelay * 2);
  scheduleRealtimeFlush(retryDelay);
}

function isCurrentConnection(expectedGeneration) {
  return window.KLMSRelayState.isCurrentConnection(
    expectedGeneration,
    state.connectionGeneration,
    state.configured
  );
}

function isCurrentConnectionPayload(payload) {
  const generation = Number(payload?.connectionGeneration);
  return Number.isSafeInteger(generation) && isCurrentConnection(generation);
}

function normalizedRelayRevision(value) {
  if (value == null || value === "") return null;
  const revision = Number(value);
  return Number.isSafeInteger(revision) && revision >= 0 ? revision : null;
}

function normalizedConfigRevision(value) {
  if (value == null || value === "") return null;
  const revision = Number(value);
  return Number.isSafeInteger(revision) && revision >= 0 ? revision : null;
}

function relayMutationRequest(request, expectedConfigRevision) {
  return window.klmsWindows.relayRequest({
    ...request,
    expectedConfigRevision
  });
}

function highestRelayRevision(...values) {
  const revisions = values
    .map((value) => normalizedRelayRevision(value))
    .filter((value) => value != null);
  return revisions.length > 0 ? Math.max(...revisions) : null;
}

function applyStatus(payload) {
  const normalizedPayload = window.KLMSRelayState.normalizeRelayStatusPayload(payload);
  const previousMessage = state.message;
  const incomingLatestCommand = normalizedPayload.latestCommand
    ? preferredLatestCommand(state.latestCommand, commandOverlayingKnownState(normalizedPayload.latestCommand))
    : null;
  const overlaidCommands = commandsOverlayingPending(
    incomingLatestCommand ? [incomingLatestCommand] : [],
    { confirmsTerminalState: false }
  );
  const pendingCommand = overlaidCommands.find((command) => pendingCommandOverlays.has(command.id));
  const effectiveLatestCommand = overlaidCommands[0] || null;
  const terminalLatestCommand = effectiveLatestCommand && isTerminalStatus(effectiveLatestCommand.status)
    ? effectiveLatestCommand
    : null;
  state.status = {
    ...defaultStatus,
    ...normalizedPayload.status,
    ...(pendingCommand?.summary || {}),
    ...(pendingCommand ? { phase: pendingCommand.status || "pending" } : {}),
    ...(terminalLatestCommand ? { phase: terminalLatestCommand.status } : {})
  };
  state.latestCommand = effectiveLatestCommand;
  state.running = terminalLatestCommand ? false : normalizedPayload.running;
  const preservesOptimisticMessage = pendingCommand && !isServerConfirmedCommand(pendingCommand);
  state.message = preservesOptimisticMessage
    ? previousMessage
    : terminalLatestCommand
      ? terminalCommandMessage(terminalLatestCommand)
      : normalizedPayload.message;
}

function applyCommandResponse(commandResponse) {
  const pendingCommandIDsBeforeRefresh = new Set(pendingCommandOverlays.keys());
  const incomingCommands = Array.isArray(commandResponse?.commands)
    ? commandResponse.commands
      .map((command) => window.KLMSRelayState.normalizeRemoteCommand(command))
      .filter(Boolean)
      .map((command) => commandOverlayingKnownState(command))
    : [];
  const overlaidCommands = commandsOverlayingPending(incomingCommands);
  const preferredLatest = preferredLatestCommand(state.latestCommand, overlaidCommands[0] || null);
  let reconciledCommands = overlaidCommands;
  if (preferredLatest) {
    const preferredIndex = reconciledCommands.findIndex((command) => command.id === preferredLatest.id);
    if (preferredIndex >= 0) {
      reconciledCommands = reconciledCommands.map((command, index) => (
        index === preferredIndex ? preferredLatest : command
      ));
    } else {
      reconciledCommands = [preferredLatest, ...reconciledCommands];
    }
    state.latestCommand = preferredLatest;
  }
  const confirmedTerminalCommand = preferredLatest && isTerminalStatus(preferredLatest.status)
    ? preferredLatest
    : reconciledCommands.find((command) => (
      pendingCommandIDsBeforeRefresh.has(command.id) && isTerminalStatus(command.status)
    ));
  if (confirmedTerminalCommand) {
    state.status = {
      ...defaultStatus,
      ...(confirmedTerminalCommand.summary || {}),
      phase: confirmedTerminalCommand.status
    };
    state.latestCommand = confirmedTerminalCommand;
    state.running = false;
    state.message = terminalCommandMessage(confirmedTerminalCommand);
  }
  state.recentCommands = reconciledCommands;
}

function commandOverlayingKnownState(incomingCommand) {
  if (!incomingCommand) return null;
  const knownCommand = [state.latestCommand, ...state.recentCommands]
    .find((command) => command?.id === incomingCommand.id);
  return preferredCommandState(knownCommand, incomingCommand);
}

function applySyncDataResponse(syncData, options = {}) {
  state.items = itemsOverlayingPendingActions(syncData.items || []);
  state.calendarChanges = syncData.calendarChanges || [];
  state.verifySummary = syncData.verifySummary || null;
  state.runLogs = Array.isArray(syncData.runLogs) ? syncData.runLogs : [];
  if (options.applySharedSettings !== false) {
    applySharedSettings(syncData.sharedSettings || [], { authoritative: true });
  }
}

function commandsOverlayingPending(incomingCommands, options = {}) {
  const confirmsTerminalState = options.confirmsTerminalState !== false;
  const commands = Array.isArray(incomingCommands) ? incomingCommands.map((command) => ({ ...command })) : [];
  for (const [id, pendingCommand] of pendingCommandOverlays) {
    const index = commands.findIndex((command) => command.id === id);
    if (index >= 0) {
      const mergedCommand = preferredCommandState(pendingCommand, commands[index]);
      commands[index] = mergedCommand;
      if (isTerminalStatus(mergedCommand.status) && confirmsTerminalState) {
        pendingCommandOverlays.delete(id);
      } else {
        pendingCommandOverlays.set(id, mergedCommand);
      }
      continue;
    }
    commands.unshift({ ...pendingCommand });
  }
  return commands;
}

function preferredCommandState(current, incoming) {
  if (!current) return { ...incoming };
  if (!incoming) return { ...current };
  const currentTerminal = isTerminalStatus(current.status);
  const incomingTerminal = isTerminalStatus(incoming.status);
  if (currentTerminal !== incomingTerminal) {
    return { ...(currentTerminal ? current : incoming) };
  }
  const currentRank = commandStateRank(current.status);
  const incomingRank = commandStateRank(incoming.status);
  const currentUpdatedAt = Date.parse(current.updatedAt || current.createdAt || "");
  const incomingUpdatedAt = Date.parse(incoming.updatedAt || incoming.createdAt || "");
  if (Number.isFinite(currentUpdatedAt) && Number.isFinite(incomingUpdatedAt) && currentUpdatedAt !== incomingUpdatedAt) {
    return { ...(incomingUpdatedAt > currentUpdatedAt ? incoming : current) };
  }
  return { ...(incomingRank >= currentRank ? incoming : current) };
}

function preferredLatestCommand(current, incoming) {
  if (!current) return incoming ? { ...incoming } : null;
  if (!incoming) return { ...current };
  if (current.id === incoming.id) return preferredCommandState(current, incoming);
  const currentCreatedAt = Date.parse(current.createdAt || current.updatedAt || "");
  const incomingCreatedAt = Date.parse(incoming.createdAt || incoming.updatedAt || "");
  if (Number.isFinite(currentCreatedAt) && Number.isFinite(incomingCreatedAt) && currentCreatedAt !== incomingCreatedAt) {
    return { ...(incomingCreatedAt > currentCreatedAt ? incoming : current) };
  }
  const currentUpdatedAt = Date.parse(current.updatedAt || "");
  const incomingUpdatedAt = Date.parse(incoming.updatedAt || "");
  if (Number.isFinite(currentUpdatedAt) && Number.isFinite(incomingUpdatedAt) && currentUpdatedAt !== incomingUpdatedAt) {
    return { ...(incomingUpdatedAt > currentUpdatedAt ? incoming : current) };
  }
  return { ...incoming };
}

function commandStateRank(status) {
  return {
    pending: 1,
    running: 2,
    completed: 3,
    cancelled: 3,
    failed: 3,
    macUnavailable: 3
  }[status] || 0;
}

function terminalCommandMessage(command) {
  const detail = String(command?.summary?.phaseDetail || "").trim();
  if (detail) return detail;
  return `${commandLabel(command?.kind)} ${commandStatusLabel(command?.status)}`;
}

function itemsOverlayingPendingActions(incomingItems) {
  const items = Array.isArray(incomingItems) ? incomingItems.map((item) => ({ ...item })) : [];
  for (const overlay of pendingItemActionOverlays.values()) {
    if (overlay.appliesToItem === false) continue;
    const item = items.find((candidate) => candidate.id === overlay.itemID);
    if (item) applyItemActionMutation(overlay.action, item);
  }
  return items;
}

function itemActionsOverlayingPending(incomingActions) {
  const actions = Array.isArray(incomingActions) ? incomingActions.map((action) => ({ ...action })) : [];
  for (const [itemID, overlay] of pendingItemActionOverlays) {
    const index = actions.findIndex((action) => action.id === overlay.request.id);
    if (index >= 0) {
      const authoritativeAction = actions[index];
      if (isTerminalStatus(authoritativeAction.status)) {
        pendingItemActionOverlays.delete(itemID);
        if (isFailedMutationStatus(authoritativeAction.status) && overlay.previousItem) {
          restoreItemSnapshot(overlay.previousItem);
        }
      } else {
        pendingItemActionOverlays.set(itemID, { ...overlay, request: authoritativeAction });
      }
      continue;
    }
    actions.unshift({ ...overlay.request });
  }
  return actions;
}

function fileAccessRequestsOverlayingPending(incomingRequests) {
  const requests = Array.isArray(incomingRequests) ? incomingRequests.map((request) => ({ ...request })) : [];
  for (const [id, pendingRequest] of pendingFileAccessOverlays) {
    const index = requests.findIndex((request) => request.id === id);
    if (index >= 0) {
      const authoritativeRequest = requests[index];
      if (isTerminalStatus(authoritativeRequest.status)) {
        pendingFileAccessOverlays.delete(id);
      } else {
        pendingFileAccessOverlays.set(id, authoritativeRequest);
      }
      continue;
    }
    requests.unshift({ ...pendingRequest });
  }
  return requests;
}

function isFailedMutationStatus(status) {
  return ["failed", "macunavailable", "rejected", "error", "cancelled", "canceled"].includes(String(status || "").trim().toLowerCase());
}

function restoreItemSnapshot(previousItem) {
  const index = state.items.findIndex((item) => item.id === previousItem.id);
  if (index >= 0) state.items[index] = { ...previousItem };
}

function activeInFlightCommand() {
  const candidates = [state.latestCommand, ...state.recentCommands].filter(Boolean);
  return candidates.find((command, index) => (
    isInFlightStatus(command.status)
    && candidates.findIndex((candidate) => candidate.id === command.id) === index
  )) || null;
}

function isServerConfirmedCommand(command) {
  return Boolean(command && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(command.id || "")));
}

function commandActionState(kind) {
  const activeCommand = activeInFlightCommand();
  if (cancelRequestedCommandID && (!activeCommand || activeCommand.id !== cancelRequestedCommandID)) {
    cancelRequestedCommandID = "";
  }

  if (!state.configured) {
    return { mode: "create", disabled: true, label: commandLabel(kind), command: null };
  }
  if (!activeCommand) {
    return {
      mode: "create",
      disabled: Boolean(state.running),
      label: state.running ? `${commandLabel(kind)} · 다른 동기화 실행 중` : commandLabel(kind),
      command: null
    };
  }
  if (activeCommand.kind !== kind) {
    return {
      mode: "blocked",
      disabled: true,
      label: commandLabel(kind),
      command: activeCommand
    };
  }
  if (!isServerConfirmedCommand(activeCommand)) {
    return {
      mode: "submitting",
      disabled: true,
      label: `${commandLabel(kind)} 요청 전송 중`,
      command: activeCommand
    };
  }
  if (cancelSubmittingCommandID === activeCommand.id) {
    return {
      mode: "cancelling",
      disabled: true,
      label: `${commandLabel(kind)} 중단 요청 중`,
      command: activeCommand
    };
  }
  if (cancelRequestedCommandID === activeCommand.id) {
    return {
      mode: "cancelRequested",
      disabled: true,
      label: `${commandLabel(kind)} 중단 요청됨`,
      command: activeCommand
    };
  }
  return {
    mode: "cancel",
    disabled: false,
    label: `${commandLabel(kind)} 중단`,
    command: activeCommand
  };
}

function configureCommandButton(button, command, options = {}) {
  const action = commandActionState(command.kind);
  const icon = action.mode === "cancel" || action.mode === "cancelling" || action.mode === "cancelRequested" ? "square" : command.icon;
  const requestSuffix = options.requestSuffix && action.mode === "create" ? " 요청" : "";
  const label = `${action.label}${requestSuffix}`;
  delete button.dataset.busyDisabled;
  button.replaceChildren(commandIconElement(icon), textElement("span", label, "button-label"));
  button.disabled = action.disabled;
  button.dataset.commandKind = command.kind;
  button.dataset.commandAction = action.mode;
  button.setAttribute("aria-label", action.label);
  button.classList.toggle("cancel", action.mode === "cancel");
  return action;
}

function commandIconElement(iconName) {
  const icon = document.createElement("span");
  icon.className = `icon ${iconClassByName[iconName] || iconClassByName["refresh-cw"]}`;
  icon.setAttribute("aria-hidden", "true");
  return icon;
}

async function runOrCancelCommand(kind) {
  const action = commandActionState(kind);
  if (action.disabled) return;
  if (action.mode === "cancel" && action.command) {
    await cancelCommand(action.command);
    return;
  }
  if (action.mode === "create") {
    await createCommand(kind);
  }
}

async function cancelCommand(command) {
  if (!state.configured) {
    toast("서버 연결 후 실행을 중단할 수 있습니다.");
    return;
  }
  if (!isServerConfirmedCommand(command)) {
    toast("서버가 실행 요청을 확정한 뒤 중단할 수 있습니다.");
    return;
  }
  const connectionGeneration = state.connectionGeneration;
  const configRevision = state.configRevision;
  const previousMessage = state.message;
  try {
    cancelSubmittingCommandID = command.id;
    setBusy(true);
    state.message = `${commandLabel(command.kind)} 중단 요청 전송 중`;
    renderAll();
    const cancelRequest = await relayMutationRequest({
      path: "/v1/cancel",
      method: "POST",
      body: {
        commandID: command.id,
        message: "Windows에서 사용자가 실행 중단을 요청했습니다."
      }
    }, configRevision);
    if (!isCurrentConnection(connectionGeneration)) return;
    cancelSubmittingCommandID = "";
    if (cancelRequest?.requested === false) {
      const cancellationDetail = typeof cancelRequest.message === "string"
        ? cancelRequest.message.slice(0, 500)
        : "실행 요청을 취소했습니다.";
      const cancelledCommand = {
        ...command,
        status: "cancelled",
        updatedAt: new Date().toISOString(),
        summary: {
          ...(command.summary || state.status),
          phase: "cancelled",
          phaseDetail: cancellationDetail
        }
      };
      pendingCommandOverlays.delete(command.id);
      state.latestCommand = cancelledCommand;
      state.recentCommands = [
        cancelledCommand,
        ...state.recentCommands.filter((candidate) => candidate.id !== command.id)
      ].slice(0, 8);
      state.status = { ...state.status, ...(cancelledCommand.summary || {}), phase: "cancelled" };
      state.running = false;
      state.message = `${commandLabel(command.kind)} 요청을 취소했습니다.`;
      cancelRequestedCommandID = "";
    } else {
      cancelRequestedCommandID = command.id;
      state.message = `${commandLabel(command.kind)} 중단 요청 대기 중`;
    }
    renderAll();
    toast(`${commandLabel(command.kind)} 중단을 요청했습니다.`);
  } catch (error) {
    if (!isCurrentConnection(connectionGeneration)) return;
    cancelSubmittingCommandID = "";
    cancelRequestedCommandID = "";
    state.message = previousMessage;
    renderAll();
    showError(error);
  } finally {
    if (isCurrentConnection(connectionGeneration)) {
      cancelSubmittingCommandID = "";
      setBusy(false);
    }
  }
}

async function createCommand(kind) {
  if (!state.configured) {
    toast("서버 연결 후 실행을 요청할 수 있습니다.");
    return;
  }
  if (activeInFlightCommand() || state.running) {
    toast("진행 중인 동기화를 먼저 완료하거나 중단해 주세요.");
    return;
  }
  const connectionGeneration = state.connectionGeneration;
  const configRevision = state.configRevision;
  const previous = {
    status: { ...state.status },
    latestCommand: state.latestCommand,
    running: state.running,
    message: state.message,
    recentCommands: state.recentCommands.slice()
  };
  const optimisticID = `optimistic-command-${Date.now()}`;
  const optimisticCommand = {
    id: optimisticID,
    kind,
    status: "pending",
    summary: { ...state.status, phase: "pending" },
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString()
  };
  try {
    setBusy(true);
    state.latestCommand = optimisticCommand;
    state.status = { ...state.status, phase: "pending" };
    state.running = false;
    state.message = `${commandLabel(kind)} 요청 전송 중`;
    pendingCommandOverlays.set(optimisticID, optimisticCommand);
    state.recentCommands = [optimisticCommand, ...state.recentCommands].slice(0, 8);
    renderAll();
    const commandResponse = await relayMutationRequest({
      path: "/v1/commands",
      method: "POST",
      body: {
        kind,
        options: {
          updateNoticeNotes: $("updateNoticeNotes")?.checked !== false
        }
      }
    }, configRevision);
    if (!isCurrentConnection(connectionGeneration)) return;
    const command = window.KLMSRelayState.normalizeRemoteCommand(commandResponse);
    if (!command) throw new Error("서버가 올바르지 않은 실행 요청 상태를 반환했습니다.");
    pendingCommandOverlays.delete(optimisticID);
    pendingCommandOverlays.set(command.id, command);
    state.latestCommand = command;
    state.status = { ...state.status, ...(command.summary || {}), phase: command.status || "pending" };
    state.message = `${commandLabel(kind)} 요청 대기 중`;
    state.recentCommands = [command, ...state.recentCommands.filter((item) => item.id !== optimisticID && item.id !== command.id)].slice(0, 8);
    renderAll();
    toast(`${commandLabel(kind)} 요청을 보냈습니다.`);
  } catch (error) {
    if (!isCurrentConnection(connectionGeneration)) return;
    pendingCommandOverlays.delete(optimisticID);
    state.status = previous.status;
    state.latestCommand = previous.latestCommand;
    state.running = previous.running;
    state.message = previous.message;
    state.recentCommands = previous.recentCommands;
    renderAll();
    showError(error);
  } finally {
    setBusy(false);
  }
}

async function createItemAction(action, item) {
  if (!state.configured) {
    toast("서버 연결 후 항목을 처리할 수 있습니다.");
    return;
  }
  const connectionGeneration = state.connectionGeneration;
  const configRevision = state.configRevision;
  let previousItem = null;
  let itemIndex = -1;
  let previousActions = null;
  try {
    const message = itemActionMessage(action, item);
    if (message === null) {
      return;
    }
    setBusy(true);
    itemIndex = state.items.findIndex((candidate) => candidate.id === item.id);
    previousItem = itemIndex >= 0 ? { ...state.items[itemIndex] } : null;
    previousActions = state.recentActions.slice();
    const optimisticID = `optimistic-action-${Date.now()}`;
    const optimisticAction = {
      id: optimisticID,
      action,
      itemID: item.id,
      itemKind: item.kind,
      itemTitle: item.title,
      message,
      status: "pending",
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString()
    };
    pendingItemActionOverlays.set(item.id, {
      itemID: item.id,
      action,
      request: optimisticAction,
      previousItem
    });
    applyOptimisticItemAction(action, item);
    state.recentActions = [optimisticAction, ...state.recentActions].slice(0, 10);
    renderAll();
    const savedAction = await relayMutationRequest({
      path: "/v1/item-actions",
      method: "POST",
      body: {
        action,
        itemID: item.id,
        itemKind: item.kind,
        itemTitle: item.title,
        message
      }
    }, configRevision);
    if (!isCurrentConnection(connectionGeneration)) return;
    const savedActionFailed = isFailedMutationStatus(savedAction.status);
    pendingItemActionOverlays.set(item.id, {
      itemID: item.id,
      action,
      request: savedAction,
      previousItem,
      appliesToItem: !savedActionFailed
    });
    if (savedActionFailed) {
      if (previousItem) restoreItemSnapshot(previousItem);
    } else {
      applyOptimisticItemAction(action, item);
    }
    state.recentActions = [savedAction, ...state.recentActions.filter((candidate) => candidate.id !== optimisticID && candidate.id !== savedAction.id)].slice(0, 10);
    renderAll();
    toast(`${actionLabel(action)} 요청을 보냈습니다.`);
  } catch (error) {
    if (!isCurrentConnection(connectionGeneration)) return;
    pendingItemActionOverlays.delete(item.id);
    if (previousItem) restoreItemSnapshot(previousItem);
    if (previousActions) state.recentActions = previousActions;
    renderAll();
    showError(error);
  } finally {
    setBusy(false);
  }
}

function itemActionMessage(action, item) {
  if (action === "calendarDelete") {
    return "";
  }
  if (action !== "calendarEdit" && action !== "calendarCreate") {
    return "";
  }
  const isCreate = action === "calendarCreate";
  const title = window.prompt(isCreate ? "등록할 캘린더 제목" : "수정할 캘린더 제목", item.title || "");
  if (title === null) {
    return null;
  }
  const startAt = window.prompt("시작 시간 (예: 2026-06-17 13:00)", item.startAt || "");
  if (startAt === null) {
    return null;
  }
  const dueAt = window.prompt("종료 시간 (예: 2026-06-17 16:00)", item.dueAt || "");
  if (dueAt === null) {
    return null;
  }
  const location = window.prompt(isCreate ? "장소" : "장소 (비워 두면 변경하지 않음)", item.location || "");
  if (location === null) {
    return null;
  }
  if (!isCreate && ![title, startAt, dueAt, location].some((value) => String(value || "").trim())) {
    showError(new Error("수정할 캘린더 내용이 없습니다."));
    return null;
  }
  if (isCreate && !String(title || "").trim()) {
    showError(new Error("등록할 캘린더 제목이 필요합니다."));
    return null;
  }
  if (isCreate && !String(startAt || "").trim()) {
    showError(new Error("등록할 캘린더 시작 시간이 필요합니다."));
    return null;
  }
  return JSON.stringify({
    title,
    start_at: startAt,
    due_at: dueAt,
    location
  });
}

async function createFileAccess(item) {
  if (!state.configured) {
    toast("서버 연결 후 파일 링크를 요청할 수 있습니다.");
    return;
  }
  if (item.kind !== "file") {
    showError(new Error("파일 항목만 열기 링크를 요청할 수 있습니다."));
    return;
  }
  const previousRequests = state.recentFileAccess.slice();
  const optimisticID = `optimistic-file-${Date.now()}`;
  const connectionGeneration = state.connectionGeneration;
  const configRevision = state.configRevision;
  try {
    setBusy(true);
    const optimisticRequest = {
      id: optimisticID,
      itemID: item.id,
      itemKind: item.kind,
      itemTitle: item.title,
      status: "pending",
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString()
    };
    pendingFileAccessOverlays.set(optimisticID, optimisticRequest);
    state.recentFileAccess = [optimisticRequest, ...state.recentFileAccess].slice(0, 20);
    renderAll();
    const request = await relayMutationRequest({
      path: "/v1/file-access",
      method: "POST",
      body: {
        itemID: item.id,
        itemKind: item.kind,
        itemTitle: item.title
      }
    }, configRevision);
    if (!isCurrentConnection(connectionGeneration)) return;
    pendingFileAccessOverlays.delete(optimisticID);
    pendingFileAccessOverlays.set(request.id, request);
    state.recentFileAccess = [request, ...state.recentFileAccess.filter((candidate) => candidate.id !== optimisticID && candidate.id !== request.id)].slice(0, 20);
    renderAll();
    toast("Mac에 파일 열기 링크를 요청했습니다.");
  } catch (error) {
    if (!isCurrentConnection(connectionGeneration)) return;
    pendingFileAccessOverlays.delete(optimisticID);
    state.recentFileAccess = previousRequests;
    renderAll();
    showError(error);
  } finally {
    setBusy(false);
  }
}

function applyOptimisticItemAction(action, item) {
  const target = state.items.find((candidate) => candidate.id === item.id);
  if (!target) {
    return;
  }
  applyItemActionMutation(action, target);
}

function applyItemActionMutation(action, target) {
  switch (action) {
    case "noticeRead":
      target.isRead = true;
      break;
    case "noticeUnread":
      target.isRead = false;
      break;
    case "noticeImportant":
      target.isImportant = true;
      break;
    case "noticeUnimportant":
      target.isImportant = false;
      break;
    case "noticeHide":
    case "assignmentHide":
    case "fileHide":
      target.isHidden = true;
      break;
    case "noticeUnhide":
    case "assignmentUnhide":
    case "fileUnhide":
      target.isHidden = false;
      break;
    case "assignmentComplete":
      target.kind = "completedAssignment";
      target.status = "완료 요청됨";
      break;
    case "assignmentRestore":
      target.kind = "assignment";
      target.status = "복구 요청됨";
      break;
    case "examPromote":
      target.kind = "exam";
      target.status = "시험 확정 요청됨";
      break;
    case "examIgnore":
      target.isHidden = true;
      target.status = "시험 아님 요청됨";
      break;
    case "examRestore":
      target.kind = "exam";
      target.isHidden = false;
      target.status = "시험 복구 요청됨";
      break;
  }
}

function renderAll() {
  renderScope(fullRenderScope);
}

function scheduleRender(scope) {
  frameRenderScheduler.schedule(scope);
}

function renderScope(scope = fullRenderScope) {
  preserveKeyboardFocus(() => {
    if (scope.header) renderHeader();
    if (scope.primarySync) renderPrimarySyncAction();
    if (scope.commands) renderCommands();
    if (scope.dashboard) renderDashboard();
    if (scope.verify) renderVerifySummary();
    if (scope.items) renderItems();
    if (scope.detail) renderDetail();
    if (scope.history) renderHistory();
    updateBusyControls();
  });
}

function renderScopeForEndpoint(endpoint) {
  return {
    status: { header: true, primarySync: true, commands: true, dashboard: true },
    commands: { header: true, primarySync: true, commands: true, dashboard: true, history: true },
    syncData: { dashboard: true, verify: true, items: true, detail: true, history: true },
    itemActions: { items: true, detail: true, history: true },
    settingActions: { history: true },
    fileAccess: { detail: true, history: true },
    requestLog: { history: true },
    sharedSettings: {}
  }[endpoint] || fullRenderScope;
}

function preserveKeyboardFocus(operation) {
  const active = document.activeElement;
  const snapshot = active && active !== document.body
    ? {
        element: active,
        id: active.id || "",
        key: active.dataset?.focusKey || "",
        selectionStart: typeof active.selectionStart === "number" ? active.selectionStart : null,
        selectionEnd: typeof active.selectionEnd === "number" ? active.selectionEnd : null
      }
    : null;
  operation();
  if (!snapshot || (snapshot.element.isConnected && document.activeElement === snapshot.element)) return;
  const target = snapshot.id
    ? document.getElementById(snapshot.id)
    : snapshot.key
      ? document.querySelector(`[data-focus-key="${CSS.escape(snapshot.key)}"]`)
      : null;
  if (!target || target.disabled || target.inert || target.getClientRects().length === 0) return;
  target.focus({ preventScroll: true });
  if (snapshot.selectionStart != null && typeof target.setSelectionRange === "function") {
    target.setSelectionRange(snapshot.selectionStart, snapshot.selectionEnd ?? snapshot.selectionStart);
  }
}

function renderPrimarySyncAction() {
  const button = $("primarySyncButton");
  if (!button) return;
  const command = commands.find((candidate) => candidate.kind === "fullSync");
  configureCommandButton(button, command);
  button.classList.add("primary-sync-action");
}

function renderCommands() {
  $("commandButtons").replaceChildren(...commands.filter((command) => command.kind !== "fullSync").map((command) => {
    const button = document.createElement("button");
    button.className = "secondary";
    button.dataset.focusKey = `command:${command.kind}`;
    configureCommandButton(button, command);
    button.addEventListener("click", () => runOrCancelCommand(command.kind));
    return button;
  }));
}

function renderHeader() {
  const phase = state.running ? "running" : state.status.phase || "idle";
  const connectionOnlyPhase = !state.latestCommand && !state.running && [
    "unconfigured", "connecting", "reconnecting", "offline", "error", "checking"
  ].includes(state.connectionPhase);
  const inFlight = isInFlightStatus(phase) || isInFlightStatus(state.latestCommand?.status);
  const terminal = isTerminalStatus(phase) || isTerminalStatus(state.latestCommand?.status);
  $("phaseLabel").textContent = phaseLabel(connectionOnlyPhase ? state.connectionPhase : phase);
  $("statusTitle").textContent = statusTitle();
  const subtitle = statusSubtitle();
  const subtitleElement = $("statusSubtitle");
  const disclosure = $("statusMessageDisclosure");
  subtitleElement.textContent = subtitle;
  subtitleElement.setAttribute("aria-label", subtitle);
  subtitleElement.title = subtitle;
  $("statusFullMessage").textContent = subtitle;
  window.requestAnimationFrame(() => {
    if (subtitleElement.getAttribute("aria-label") !== subtitle) return;
    const isTruncated = subtitleElement.scrollHeight > subtitleElement.clientHeight + 1;
    disclosure.classList.toggle("hidden", !isTruncated);
    if (!isTruncated) disclosure.open = false;
  });

  const banner = $("attentionBanner");
  banner.className = "attention hidden";
  if (state.status.authDigits && !terminal) {
    banner.textContent = `KAIST 인증 번호: ${state.status.authDigits}`;
    banner.classList.add("warn");
    banner.classList.remove("hidden");
  } else if (state.status.loginRequired && !terminal) {
    banner.textContent = "KLMS 로그인이 필요합니다. Mac에서 Safari 로그인을 확인해 주세요.";
    banner.classList.add("warn");
    banner.classList.remove("hidden");
  } else if (state.status.authStatusMessage && inFlight) {
    banner.textContent = state.status.authStatusMessage;
    banner.classList.add("success");
    banner.classList.remove("hidden");
  }
}

function renderDashboard() {
  const cards = dashboardKinds
    .filter((card) => card.key === "all" || card.get(state.status, state.items) > 0)
    .map((card) => {
      const button = document.createElement("button");
      button.className = `metric-card ${state.selectedKind === card.key ? "active" : ""}`;
      button.dataset.focusKey = `dashboard:${card.key}`;
      button.setAttribute("aria-pressed", state.selectedKind === card.key ? "true" : "false");
      button.append(
        textElement("span", card.label),
        textElement("strong", card.get(state.status, state.items)),
        textElement("span", cardDetail(card.key))
      );
      button.addEventListener("click", () => {
        state.selectedKind = card.key;
        state.itemRenderLimit = INITIAL_ITEM_RENDER_LIMIT;
        state.selectedItemId = filteredItems()[0]?.id || "";
        renderDashboard();
        renderItems();
        renderDetail();
      });
      return button;
    });
  $("dashboardCards").replaceChildren(...cards);
}

function renderVerifySummary() {
  const panel = $("verifySummaryPanel");
  const summary = state.verifySummary;
  if (!panel || !summary) {
    panel?.classList.add("hidden");
    return;
  }
  const checks = Array.isArray(summary.checks) ? summary.checks : [];
  const issueChecks = checks.filter((check) => isIssueStatus(check.status));
  const okCount = checks.filter((check) => String(check.status || "").trim().toLowerCase() === "ok").length;
  panel.classList.remove("hidden");
  const headingText = document.createElement("div");
  headingText.append(
    textElement("h2", "상태 검사 해설"),
    textElement(
      "p",
      issueChecks.length
        ? `확인 필요 ${issueChecks.length}개 · 정상 ${okCount}개`
        : `상태 ${localizedStatus(summary.status)} · 정상 ${okCount}개`,
      "hint"
    )
  );
  const heading = document.createElement("div");
  heading.className = "panel-heading";
  heading.append(
    headingText,
    statusPill(issueChecks.length ? "확인 필요" : "정상", issueChecks.length ? "warn" : "ok")
  );
  const visibleChecks = issueChecks.length
    ? issueChecks.map((check) => verifyCheckElement(check))
    : [textElement("p", "메모, 파일, 캘린더, 미리 알림 검사에서 설명이 필요한 실패 항목이 없습니다.", "hint")];
  const details = document.createElement("details");
  details.className = "verify-details";
  details.append(textElement("summary", `전체 상태 검사 항목 ${checks.length}개`));
  const checkList = document.createElement("div");
  checkList.className = "verify-check-list";
  checkList.append(...checks.map((check) => verifyCheckElement(check, true)));
  details.append(checkList);
  panel.replaceChildren(heading, ...visibleChecks, details);
}

function verifyCheckElement(check, compact = false) {
  const info = verifyCheckDiagnostic(check);
  const status = String(check.status || "").trim().toLowerCase();
  const tone = ["fail", "failed", "error"].includes(status) ? "fail" : (["warn", "warning"].includes(status) ? "warn" : "ok");
  const article = document.createElement("article");
  article.className = `verify-check ${tone}${compact ? " compact" : ""}`;
  const title = document.createElement("div");
  title.className = "verify-check-title";
  title.append(textElement("strong", `${info.title} · ${localizedStatus(check.status)}`));
  if (check.detail) title.append(textElement("code", check.detail));
  article.append(title);
  if (!compact) {
    article.append(textElement("p", info.explanation), textElement("p", info.nextAction, "hint"));
  }
  return article;
}

function renderItems() {
  const items = filteredItems();
  const visibleItems = items.slice(0, state.itemRenderLimit);
  $("listTitle").textContent = kindTitle(state.selectedKind);
  $("listCount").textContent = `${items.length}개`;
  if (!items.length) {
    $("itemList").replaceChildren(textElement("div", "표시할 항목이 없습니다.", "empty-list"));
    return;
  }
  const rows = visibleItems.map((item) => {
    const button = document.createElement("button");
    button.className = `item-row ${state.selectedItemId === item.id ? "active" : ""}`;
    button.dataset.focusKey = `item:${item.id}`;
    button.setAttribute("aria-current", state.selectedItemId === item.id ? "true" : "false");
    button.title = item.title || "제목 없음";
    const badges = document.createElement("div");
    badges.className = "badges";
    badges.append(...badgeElements(item));
    button.append(
      badges,
      textElement("div", item.title || "제목 없음", "title"),
      textElement("div", itemMeta(item), "meta")
    );
    button.addEventListener("click", () => {
      state.selectedItemId = item.id;
      preserveKeyboardFocus(() => {
        renderItems();
        renderDetail();
      });
      revealSelectedDetailWhenStacked();
    });
    return button;
  });
  if (items.length > visibleItems.length) {
    const moreButton = document.createElement("button");
    moreButton.className = "item-row show-more-row";
    moreButton.dataset.focusKey = "items:more";
    moreButton.append(
      textElement("div", "더 보기", "title"),
      textElement("div", `${items.length - visibleItems.length}개 남음`, "meta")
    );
    moreButton.addEventListener("click", () => {
      state.itemRenderLimit += ITEM_RENDER_INCREMENT;
      renderItems();
    });
    rows.push(moreButton);
  }
  $("itemList").replaceChildren(...rows);
}

function renderDetail() {
  const item = currentItems().find((candidate) => candidate.id === state.selectedItemId);
  const detail = $("itemDetail");
  if (!item) {
    detail.className = "empty-detail";
    detail.replaceChildren(
      textElement("h2", "항목을 선택하세요"),
      textElement("p", "대시보드 카드나 왼쪽 목록을 누르면 상세와 처리 버튼이 표시됩니다.")
    );
    return;
  }
  const fileAccess = item.kind === "file" ? latestFileAccess(item) : null;
  detail.className = "detail-card";
  const header = document.createElement("div");
  header.className = "detail-header";
  const badges = document.createElement("div");
  badges.className = "detail-badges";
  badges.append(...badgeElements(item));
  const itemTitle = item.title || "제목 없음";
  const itemMetaText = itemMeta(item);
  const title = textElement("h2", itemTitle);
  title.title = itemTitle;
  title.setAttribute("aria-label", itemTitle);
  const meta = textElement("div", itemMetaText, "detail-meta");
  meta.title = itemMetaText;
  header.append(badges, title, meta);
  if (itemTitle.length > 160 || itemMetaText.length > 240) {
    header.append(detailOverflowDisclosure(itemTitle, itemMetaText));
  }

  const fields = document.createElement("div");
  fields.className = "field-grid";
  fields.append(...[
    fieldElement("종류", kindTitle(item.kind)),
    fieldElement("상태", item.status),
    fieldElement("시간", item.timestamp),
    fieldElement("과목", item.course),
    fieldElement("첨부", item.attachmentCount > 0 ? `${item.attachmentCount}개` : ""),
    fieldElement("서버 갱신", item.updatedAt),
    fieldElement("세부 내용", item.detail, true),
    fieldElement("식별자", item.id, true)
  ].filter(Boolean));

  const itemActionSection = document.createElement("div");
  itemActionSection.className = "action-section";
  const detailActions = document.createElement("div");
  detailActions.id = "detailActions";
  detailActions.className = "action-grid";
  itemActionSection.append(textElement("h3", "항목 처리"), detailActions);

  const sections = [header, fields, itemActionSection];
  if (item.kind === "file") {
    const fileSection = document.createElement("div");
    fileSection.className = "action-section";
    fileSection.append(textElement("h3", "파일 열기"));
    if (fileAccess) {
      const description = document.createElement("p");
      description.className = "hint";
      description.append(
        textElement("strong", commandStatusLabel(fileAccess.status)),
        document.createTextNode(` · ${fileAccessDescription(fileAccess)}`)
      );
      fileSection.append(description);
    } else {
      fileSection.append(textElement("p", "Mac이 보관 중인 course_files 원본을 임시 서버 링크로 준비할 수 있습니다.", "hint"));
    }
    const fileActions = document.createElement("div");
    fileActions.className = "action-grid";
    if (fileAccess && isDownloadAvailable(fileAccess)) {
      const openButton = textElement("button", "다운로드 열기");
      openButton.id = "openFileAccessButton";
      openButton.dataset.focusKey = `file-open:${item.id}`;
      fileActions.append(openButton);
    }
    const requestButton = textElement("button", "Mac에 파일 링크 요청", "secondary");
    requestButton.id = "requestFileAccessButton";
    requestButton.dataset.focusKey = `file-request:${item.id}`;
    requestButton.disabled = Boolean(fileAccess && isInFlightStatus(fileAccess.status));
    fileActions.append(requestButton);
    fileSection.append(fileActions);
    sections.push(fileSection);
  }

  const syncSection = document.createElement("div");
  syncSection.className = "action-section";
  const detailSyncButton = document.createElement("button");
  detailSyncButton.id = "detailSyncButton";
  detailSyncButton.dataset.focusKey = `detail-sync:${item.id}`;
  syncSection.append(textElement("h3", "관련 동기화"), detailSyncButton);
  if (item.kind === "file") {
    syncSection.append(textElement(
      "p",
      "Windows는 KLMS에 직접 로그인하지 않습니다. 파일 열기 요청을 보내면 Mac이 로컬 파일 원본을 임시 업로드하고, 만료된 링크와 서버 기록은 자동 정리됩니다.",
      "hint"
    ));
  }
  sections.push(syncSection);
  detail.replaceChildren(...sections);
  const detailCommandKind = relevantCommand(item.kind);
  const detailCommand = commands.find((candidate) => candidate.kind === detailCommandKind) || {
    kind: detailCommandKind,
    label: commandLabel(detailCommandKind),
    icon: "refresh-cw"
  };
  configureCommandButton($("detailSyncButton"), detailCommand, { requestSuffix: true });
  $("detailSyncButton").addEventListener("click", () => runOrCancelCommand(detailCommandKind));
  if (item.kind === "file") {
    const requestButton = $("requestFileAccessButton");
    if (requestButton) {
      requestButton.addEventListener("click", () => createFileAccess(item));
    }
    const openButton = $("openFileAccessButton");
    if (openButton && fileAccess?.downloadURL) {
      openButton.addEventListener("click", () => {
        window.klmsWindows.openExternal(fileAccess.downloadURL).catch(showError);
      });
    }
  }
  renderDetailActions(item);
}

function renderDetailActions(item) {
  const container = $("detailActions");
  if (!container) {
    return;
  }
  const actions = detailActions(item);
  if (!actions.length) {
    container.replaceChildren(textElement("div", "처리할 수 있는 액션이 없습니다.", "hint"));
    return;
  }
  container.replaceChildren(...actions.map((action) => {
    const button = document.createElement("button");
    button.className = action.toggle ? `toggle-action ${action.on ? "on" : ""}` : "secondary";
    button.dataset.focusKey = `item-action:${item.id}:${action.action}`;
    if (action.toggle) {
      const copy = document.createElement("span");
      copy.append(textElement("strong", action.title), textElement("span", action.subtitle, "sub"));
      button.append(copy, textElement("span", action.on ? "ON" : "OFF", "switch-pill"));
      button.setAttribute("aria-pressed", action.on ? "true" : "false");
    } else {
      button.textContent = action.title;
    }
    button.addEventListener("click", () => createItemAction(action.action, item));
    return button;
  }));
}

function detailOverflowDisclosure(title, meta) {
  const disclosure = document.createElement("details");
  disclosure.className = "detail-overflow-disclosure";
  disclosure.dataset.testid = "detail-overflow-disclosure";
  disclosure.append(textElement("summary", "전체 제목·정보 보기"));

  const copy = document.createElement("div");
  copy.className = "detail-overflow-copy";
  for (const [label, value] of [["제목", title], ["정보", meta]]) {
    const section = document.createElement("div");
    section.className = "detail-overflow-section";
    section.append(textElement("strong", label), textElement("div", value));
    copy.append(section);
  }
  disclosure.append(copy);
  return disclosure;
}

function renderHistory() {
  const rows = [];
  if (state.runLogs.length) {
    rows.push(historySectionTitle("동기화 단계"));
  }
  rows.push(...state.runLogs.map((log) => {
    const status = runLogStatus(log);
    const details = log.outputTail ? document.createElement("details") : null;
    if (details) {
      details.className = "history-details";
      details.append(textElement("summary", "로그 일부 보기"), textElement("pre", log.outputTail));
    }
    return historyRow(
      log.commandTitle || commandLabel(log.command) || "동기화",
      [log.finishedAt || log.updatedAt, log.duration, log.dryRun ? "미리보기" : ""].filter(Boolean).join(" · "),
      activityStatusLabel(status),
      activityStatusClass(status),
      details
    );
  }));
  if (state.recentCommands.length) {
    rows.push(historySectionTitle("실행 요청"));
  }
  rows.push(...state.recentCommands.map((command) => {
    return historyRow(
      commandLabel(command.kind),
      command.updatedAt || command.createdAt || "",
      commandStatusLabel(command.status),
      commandStatusClass(command.status)
    );
  }));
  if (state.recentActions.length) {
    rows.push(historySectionTitle("항목 처리"));
  }
  rows.push(...state.recentActions.map((action) => {
    return historyRow(
      actionLabel(action.action),
      [action.itemTitle, action.updatedAt || action.createdAt, action.message].filter(Boolean).join(" · "),
      commandStatusLabel(action.status),
      commandStatusClass(action.status)
    );
  }));
  if (state.recentSettingActions.length) {
    rows.push(historySectionTitle("설정 변경"));
  }
  rows.push(...state.recentSettingActions.map((action) => {
    return historyRow(
      action.title || action.key || "설정 변경",
      [action.updatedAt || action.createdAt, action.message].filter(Boolean).join(" · "),
      activityStatusLabel(action.status),
      activityStatusClass(action.status)
    );
  }));
  if (state.recentRequestLog.length) {
    rows.push(historySectionTitle("서버 요청"));
  }
  rows.push(...state.recentRequestLog.map((entry) => {
    return historyRow(
      entry.action || entry.path || "서버 요청",
      [entry.source, [entry.method, entry.path].filter(Boolean).join(" "), entry.createdAt, entry.message].filter(Boolean).join(" · "),
      activityStatusLabel(entry.status),
      activityStatusClass(entry.status)
    );
  }));
  if (state.recentFileAccess.length) {
    rows.push(historySectionTitle("파일 열기"));
  }
  rows.push(...state.recentFileAccess.map((request) => {
    return historyRow(
      request.itemTitle || "파일",
      [request.updatedAt || request.createdAt, fileAccessDescription(request)].filter(Boolean).join(" · "),
      commandStatusLabel(request.status),
      commandStatusClass(request.status)
    );
  }));
  if (!rows.length) {
    $("historyList").replaceChildren(textElement("div", "최근 요청과 로그가 없습니다.", "empty-list"));
  } else {
    $("historyList").replaceChildren(...rows);
  }
}

function historyRow(title, meta, statusText, tone, extra = null) {
  const row = document.createElement("div");
  row.className = "history-row";
  const copy = document.createElement("div");
  copy.title = [title, meta].filter(Boolean).join("\n");
  copy.append(textElement("strong", title), textElement("div", meta, "meta"));
  if (extra) copy.append(extra);
  row.append(copy, statusPill(statusText, tone));
  return row;
}

function runLogStatus(log) {
  if (log.wasCancelled) return "cancelled";
  const exitCode = Number(log.exitCode);
  if (log.needsAttention || (Number.isFinite(exitCode) && exitCode !== 0)) return "failed";
  return log.status || "completed";
}

function activityStatusLabel(status) {
  const normalized = String(status || "").trim().toLowerCase();
  return {
    accepted: "기록됨",
    ok: "완료",
    success: "완료",
    created: "생성됨",
    updated: "갱신됨",
    stable: "변경 없음",
    unchanged: "변경 없음",
    noop: "변경 없음",
    "stable-noop": "변경 없음",
    deleted: "삭제됨",
    removed: "삭제됨",
    cleared: "삭제됨",
    queued: "대기 중",
    pending: "대기 중",
    running: "처리 중",
    completed: "완료",
    cancelled: "취소됨",
    canceled: "취소됨",
    macunavailable: "Mac 응답 없음",
    mac_unavailable: "Mac 응답 없음",
    failed: "실패",
    rejected: "실패",
    error: "실패"
  }[normalized] || status || "기록됨";
}

function activityStatusClass(status) {
  const normalized = String(status || "").trim().toLowerCase();
  if (["accepted", "ok", "success", "created", "updated", "stable", "unchanged", "noop", "stable-noop", "completed", "cancelled", "canceled", "deleted", "removed", "cleared"].includes(normalized)) return "ok";
  if (["queued", "pending", "running"].includes(normalized)) return "warn";
  if (["failed", "rejected", "error", "macunavailable", "mac_unavailable"].includes(normalized)) return "fail";
  return "muted";
}

function historySectionTitle(title) {
  const element = document.createElement("div");
  element.className = "history-section-title";
  element.textContent = title;
  return element;
}

function filteredItems() {
  const query = state.query.trim().toLowerCase();
  return currentItems()
    .filter((item) => matchesKind(item, state.selectedKind))
    .filter((item) => {
      if (!query) {
        return true;
      }
      return [item.kind, item.course, item.title, item.timestamp, item.status, item.detail]
        .join(" ")
        .toLowerCase()
        .includes(query);
    })
    .sort(compareItems);
}

function currentItems() {
  if (state.selectedKind === "calendar") {
    return calendarItems();
  }
  return state.items;
}

function latestFileAccess(item) {
  return state.recentFileAccess
    .filter((request) => request.itemID === item.id)
    .sort((lhs, rhs) => compareTimestamp(rhs.updatedAt, lhs.updatedAt) || compareTimestamp(rhs.createdAt, lhs.createdAt))[0] || null;
}

function isDownloadAvailable(request) {
  if (!request || request.status !== "completed" || !request.downloadURL) {
    return false;
  }
  if (!request.expiresAt) {
    return true;
  }
  return Date.parse(request.expiresAt) > Date.now();
}

function fileAccessDescription(request) {
  const parts = [];
  if (request.expiresAt && isDownloadAvailable(request)) {
    parts.push(`만료 ${new Date(request.expiresAt).toLocaleTimeString("ko-KR", { hour: "2-digit", minute: "2-digit" })}`);
  }
  if (Number.isFinite(Number(request.sizeBytes)) && Number(request.sizeBytes) > 0) {
    parts.push(formatBytes(Number(request.sizeBytes)));
  }
  if (request.message) {
    parts.push(request.message);
  }
  return parts.join(" · ") || "Mac 처리 상태를 기다리는 중입니다.";
}

function matchesKind(item, kind) {
  if (kind === "all") {
    return !item.isHidden;
  }
  if (kind === "assignment") {
    return !item.isHidden && ["assignment", "completedAssignment", "assignmentCandidate"].includes(item.kind);
  }
  if (kind === "exam") {
    return !item.isHidden && ["exam", "examCandidate"].includes(item.kind);
  }
  if (kind === "newFiles") {
    return !item.isHidden && item.kind === "file" && /new|fresh|새/i.test(`${item.status} ${item.detail}`);
  }
  if (kind === "quarantine") {
    return item.kind === "quarantine";
  }
  if (kind === "calendar") {
    return item.kind === "calendar";
  }
  if (kind === "hidden") {
    return item.isHidden;
  }
  return !item.isHidden && item.kind === kind;
}

function compareItems(lhs, rhs) {
  if (state.sort === "updated") {
    return compareTimestamp(rhs.updatedAt, lhs.updatedAt) || compareTimestamp(rhs.timestamp, lhs.timestamp) || compareText(lhs.title, rhs.title);
  }
  if (state.sort === "course") {
    return compareText(lhs.course, rhs.course) || compareText(lhs.title, rhs.title);
  }
  if (state.sort === "title") {
    return compareText(lhs.title, rhs.title) || compareText(lhs.course, rhs.course);
  }
  if (state.sort === "kind") {
    return compareText(kindTitle(lhs.kind), kindTitle(rhs.kind)) || compareText(lhs.title, rhs.title);
  }
  return compareTimestamp(rhs.timestamp, lhs.timestamp) || compareTimestamp(rhs.updatedAt, lhs.updatedAt) || compareText(lhs.title, rhs.title);
}

function calendarItems() {
  const updatedAt = state.latestCommand?.updatedAt || "";
  if (state.calendarChanges.length) {
    return state.calendarChanges.map((change) => {
      const startAt = change.start_at || change.startAt || "";
      const dueAt = change.due_at || change.dueAt || "";
      return {
        id: calendarChangeID(change),
        kind: "calendar",
        course: change.course || "캘린더",
        title: change.title || "캘린더 변경",
        timestamp: startAt || dueAt || updatedAt,
        status: calendarChangeActionLabel(change.action),
        detail: [change.calendar, change.bucket, (change.changes || []).join(", ")].filter(Boolean).join(" · "),
        updatedAt,
        startAt,
        dueAt,
        location: change.location || ""
      };
    });
  }
  const rows = [
    {
      id: "calendar-created",
      kind: "calendar",
      course: "캘린더",
      title: "생성된 일정",
      timestamp: updatedAt,
      status: `${state.status.calendarCreated}개`,
      detail: "최근 동기화에서 새로 만든 캘린더 일정입니다.",
      updatedAt
    },
    {
      id: "calendar-updated",
      kind: "calendar",
      course: "캘린더",
      title: "수정된 일정",
      timestamp: updatedAt,
      status: `${state.status.calendarUpdated}개`,
      detail: "최근 동기화에서 내용이나 시간이 바뀐 캘린더 일정입니다.",
      updatedAt
    },
    {
      id: "calendar-deleted",
      kind: "calendar",
      course: "캘린더",
      title: "정리된 일정",
      timestamp: updatedAt,
      status: `${state.status.calendarDeleted}개`,
      detail: "최근 동기화에서 더 이상 필요 없어 정리한 캘린더 일정입니다.",
      updatedAt
    }
  ];
  return rows.filter((item) => Number.parseInt(item.status, 10) > 0);
}

function calendarChangeID(change) {
  return [
    change.action || "",
    change.calendar || "",
    change.bucket || "",
    change.identifier || "",
    change.title || "",
    change.start_at || change.startAt || "",
    change.due_at || change.dueAt || "",
    change.raw || ""
  ].join("|");
}

function calendarChangeActionLabel(action) {
  return {
    created: "생성",
    updated: "수정",
    deleted: "정리됨"
  }[action] || action || "변경";
}

function detailActions(item) {
  switch (item.kind) {
    case "notice":
      return [
        {
          title: "읽음",
          subtitle: item.isRead ? "읽음 처리됨" : "읽지 않음",
          action: item.isRead ? "noticeUnread" : "noticeRead",
          toggle: true,
          on: Boolean(item.isRead)
        },
        {
          title: "중요",
          subtitle: item.isImportant ? "중요 공지" : "일반 공지",
          action: item.isImportant ? "noticeUnimportant" : "noticeImportant",
          toggle: true,
          on: Boolean(item.isImportant)
        },
        {
          title: item.isHidden ? "숨김 해제" : "숨김",
          action: item.isHidden ? "noticeUnhide" : "noticeHide"
        }
      ];
    case "assignment":
    case "assignmentCandidate":
      return [
        { title: "완료 처리", action: "assignmentComplete" },
        { title: item.isHidden ? "숨김 해제" : "숨김", action: item.isHidden ? "assignmentUnhide" : "assignmentHide" }
      ];
    case "completedAssignment":
      return [
        { title: "완료 해제", action: "assignmentRestore" },
        { title: item.isHidden ? "숨김 해제" : "숨김", action: item.isHidden ? "assignmentUnhide" : "assignmentHide" }
      ];
    case "examCandidate":
      return [
        { title: "시험으로 확정", action: "examPromote" },
        { title: "시험 아님", action: "examIgnore" }
      ];
    case "exam":
      return item.isHidden
        ? [
            { title: "시험 복구", action: "examRestore" },
            { title: "시험 아님 유지", action: "examIgnore" }
          ]
        : [
            { title: "시험 아님", action: "examIgnore" }
          ];
    case "file":
      return [
        { title: item.isHidden ? "파일 숨김 해제" : "파일 숨김", action: item.isHidden ? "fileUnhide" : "fileHide" }
      ];
    case "calendar":
      return [
        { title: "등록", action: "calendarCreate" },
        { title: "수정", action: "calendarEdit" },
        { title: "삭제", action: "calendarDelete" }
      ];
    default:
      return [];
  }
}

function relevantCommand(kind) {
  if (kind === "notice") {
    return "noticeSync";
  }
  if (kind === "file") {
    return "filesSync";
  }
  if (["assignment", "completedAssignment", "assignmentCandidate", "exam", "examCandidate", "helpDesk"].includes(kind)) {
    return "coreSync";
  }
  return "fullSync";
}

function badgeElements(item) {
  const badges = [kindTitle(item.kind)];
  if (item.kind === "notice") {
    badges.push(item.isRead ? "읽음" : "안 읽음");
    if (item.isImportant) {
      badges.push("중요");
    }
  }
  if (item.isHidden) {
    badges.push("숨김");
  }
  if (item.attachmentCount > 0) {
    badges.push(`첨부 ${item.attachmentCount}`);
  }
  return badges.map((badge) => {
    const klass = badge === "중요" ? "important" : badge === "읽음" ? "read" : badge === "숨김" ? "hidden-badge" : "";
    return textElement("span", badge, `badge${klass ? ` ${klass}` : ""}`);
  });
}

function fieldElement(label, value, wide = false) {
  const display = String(value || "").trim();
  if (!display) return null;
  const field = document.createElement("div");
  field.className = `field${wide ? " wide" : ""}`;
  const fieldValue = textElement("div", display, "field-value");
  fieldValue.title = display;
  fieldValue.setAttribute("aria-label", `${label}: ${display}`);
  field.append(textElement("span", label, "field-label"), fieldValue);
  return field;
}

function textElement(tagName, value, className = "") {
  const element = document.createElement(tagName);
  if (className) element.className = className;
  element.textContent = value == null ? "" : String(value);
  return element;
}

function revealSelectedDetailWhenStacked() {
  window.requestAnimationFrame(() => {
    const listPane = document.querySelector(".list-pane");
    const detailPane = document.querySelector(".detail-pane");
    if (!listPane || !detailPane) return;
    const listRect = listPane.getBoundingClientRect();
    const detailRect = detailPane.getBoundingClientRect();
    if (detailRect.top < listRect.bottom - 1) return;
    detailPane.scrollIntoView({
      behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth",
      block: "start",
      inline: "nearest"
    });
  });
}

function statusPill(value, tone = "muted") {
  return textElement("span", value, `status-pill ${tone}`);
}

function itemMeta(item) {
  return [item.course, item.timestamp, item.status, item.detail].filter(Boolean).join(" · ") || "세부 정보 없음";
}

function cardDetail(key) {
  if (key === "all") {
    return "보관함 제외";
  }
  if (key === "notice") {
    return `새 ${state.status.noticeNew} · 수정 ${state.status.noticeUpdated}`;
  }
  if (key === "calendar") {
    return `생성 ${state.status.calendarCreated} · 수정 ${state.status.calendarUpdated} · 정리 ${state.status.calendarDeleted}`;
  }
  if (key === "file") {
    return `새 ${state.status.newFiles} · 정리 ${fileCleanupTotal(state.status)}`;
  }
  if (key === "quarantine") {
    return "확인 필요";
  }
  if (key === "hidden") {
    return "숨김/무시 보관";
  }
  return "서버 DB 기준";
}

function statusTitle() {
  if (!state.configured || state.connectionPhase === "unconfigured") {
    return "서버 연결이 필요합니다";
  }
  const phase = state.running ? "running" : state.status.phase || "idle";
  if (state.latestCommand && isTerminalStatus(state.latestCommand.status)) {
    return `${commandLabel(state.latestCommand.kind)} · ${commandStatusLabel(state.latestCommand.status)}`;
  }
  if (state.status.authDigits && !isTerminalStatus(phase)) {
    return `KAIST 인증 번호 ${state.status.authDigits}`;
  }
  if (state.running || phase === "running") {
    const detail = runningPhaseDetail();
    return detail ? `Mac에서 ${detail} 진행 중` : "Mac에서 동기화 실행 중";
  }
  if (state.latestCommand) {
    return `${commandLabel(state.latestCommand.kind)} · ${commandStatusLabel(state.latestCommand.status)}`;
  }
  return {
    checking: "서버 연결 확인 중",
    connecting: "서버 릴레이 연결 중",
    reconnecting: "서버 릴레이 재연결 중",
    offline: "서버 릴레이 오프라인",
    error: "서버 릴레이 연결 실패",
    connected: "서버 릴레이 연결됨"
  }[state.connectionPhase] || "서버 상태를 불러오는 중";
}

function statusSubtitle() {
  if (!state.configured || state.connectionPhase === "unconfigured") {
    return "왼쪽 서버 연결에서 relay URL과 클라이언트 토큰을 저장해 주세요.";
  }
  if (state.message || runningPhaseDetail() || latestCommandText()) {
    return state.message || runningPhaseDetail() || latestCommandText();
  }
  if (state.connectionPhase !== "connected" && state.connectionMessage) {
    return state.connectionMessage;
  }
  return {
    checking: "저장된 연결 정보와 서버 응답을 확인하고 있습니다.",
    connecting: "WebSocket 보안 연결을 만드는 중입니다.",
    reconnecting: "연결이 끊겨 자동으로 다시 연결하고 있습니다.",
    offline: "실시간 연결이 중지되었습니다. 연결 정보를 확인해 주세요.",
    error: "서버 URL, HTTPS 설정과 클라이언트 토큰을 확인해 주세요.",
    connected: "대기 중인 서버 요청이 없습니다."
  }[state.connectionPhase] || "서버 상태를 불러오고 있습니다.";
}

function runningPhaseDetail() {
  const detail = String(state.status.phaseDetail || "").trim();
  return detail || "";
}

function latestCommandText() {
  if (!state.latestCommand) {
    return "";
  }
  return `${commandLabel(state.latestCommand.kind)} 요청 ${commandStatusLabel(state.latestCommand.status)}`;
}

function kindTitle(kind) {
  return {
    all: "전체 항목",
    assignment: "과제",
    completedAssignment: "완료 과제",
    assignmentCandidate: "과제 후보",
    exam: "시험",
    examCandidate: "시험 후보",
    helpDesk: "헬프데스크",
    notice: "공지",
    file: "파일",
    newFiles: "새 파일",
    quarantine: "격리",
    calendar: "캘린더",
    hidden: "보관함"
  }[kind] || kind;
}

function commandLabel(kind) {
  return {
    fullSync: "전체 동기화",
    coreSync: "과제/시험",
    noticeSync: "공지 메모",
    filesSync: "파일 동기화",
    report: "요약 갱신",
    doctor: "진단"
  }[kind] || kind;
}

function actionLabel(action) {
  return {
    assignmentComplete: "과제 완료",
    assignmentRestore: "과제 복구",
    assignmentHide: "과제 숨김",
    assignmentUnhide: "과제 숨김 해제",
    examPromote: "시험 확정",
    examIgnore: "시험 아님",
    examRestore: "시험 복구",
    noticeRead: "공지 읽음",
    noticeUnread: "공지 읽지 않음",
    noticeImportant: "공지 중요",
    noticeUnimportant: "공지 중요 해제",
    noticeHide: "공지 숨김",
    noticeUnhide: "공지 숨김 해제",
    fileHide: "파일 숨김",
    fileUnhide: "파일 숨김 해제",
    calendarVerify: "캘린더 상태 확인",
    calendarApply: "KLMS 기준 반영",
    calendarCreate: "캘린더 일정 등록",
    calendarEdit: "캘린더 내용 수정",
    calendarDelete: "캘린더 일정 삭제",
    mailDashboardAdd: "메일 항목 반영",
    mailDashboardRemove: "메일 항목 제거"
  }[action] || action;
}

function phaseLabel(phase) {
  return {
    unconfigured: "연결 필요",
    checking: "연결 확인",
    connecting: "연결 중",
    reconnecting: "재연결 중",
    offline: "오프라인",
    error: "연결 실패",
    idle: "대기",
    pending: "요청 대기",
    running: "실행 중",
    completed: "완료",
    cancelled: "취소됨",
    failed: "실패",
    macUnavailable: "Mac 응답 없음"
  }[phase] || phase;
}

function commandStatusLabel(status) {
  return {
    pending: "대기 중",
    running: "실행 중",
    completed: "완료",
    cancelled: "취소됨",
    failed: "실패",
    macUnavailable: "Mac 응답 없음"
  }[status] || status || "상태 없음";
}

function commandStatusClass(status) {
  if (status === "completed" || status === "cancelled") {
    return "ok";
  }
  if (status === "failed" || status === "macUnavailable") {
    return "fail";
  }
  if (status === "pending" || status === "running") {
    return "warn";
  }
  return "muted";
}

function isIssueStatus(status) {
  return ["fail", "failed", "error", "warn", "warning"].includes(String(status || "").trim().toLowerCase());
}

function localizedStatus(status) {
  return {
    ok: "정상",
    fail: "실패",
    failed: "실패",
    error: "오류",
    warn: "주의",
    warning: "주의",
    missing: "없음"
  }[String(status || "").trim().toLowerCase()] || status || "상태 없음";
}

function verifyCheckDiagnostic(check) {
  const name = String(check?.name || "");
  const detail = String(check?.detail || check?.message || "");
  const number = (key) => numericValue(detail, key);
  switch (name) {
    case "manifest_files_exist": {
      const missing = number("missing");
      return {
        title: Number.isFinite(missing) ? `파일 ${missing}개 누락` : "파일 목록 불일치",
        explanation: Number.isFinite(missing)
          ? `파일 목록에는 있는데 Mac 로컬 저장소에서 찾지 못한 파일이 ${missing}개 있다는 뜻입니다.`
          : "파일 목록과 실제 저장된 파일 목록이 서로 맞지 않습니다.",
        nextAction: "파일 동기화를 다시 실행하세요. 그래도 계속 실패하면 파일 탭에서 누락 파일을 확인하고 새 파일/수정 파일만 다시 받으면 됩니다."
      };
    }
    case "notice_render_complete": {
      const missing = number("missing");
      return {
        title: Number.isFinite(missing) ? `공지 메모 ${missing}개 누락` : "공지 메모 반영 불일치",
        explanation: Number.isFinite(missing)
          ? `KLMS에서 읽은 공지 중 Notes 메모에 반영되지 않은 공지가 ${missing}개 있다는 뜻입니다.`
          : "공지 수집 결과와 Notes 메모 렌더 결과가 서로 맞지 않습니다.",
        nextAction: "공지 동기화를 다시 실행하세요. Notes 메모가 열려 있거나 권한이 흔들렸다면 권한/환경 진단도 같이 실행하세요."
      };
    }
    case "notice_exam_detection_covered_by_state":
      return {
        title: "공지 속 시험 감지 상태 확인",
        explanation: "공지 본문에서 시험처럼 보이는 항목을 찾았고, 그 항목이 앱 상태와 캘린더 후보에 반영됐는지 검사합니다.",
        nextAction: "대시보드의 시험 후보를 확인하고, 빠진 항목이 있으면 시험으로 반영한 뒤 과제/시험 동기화를 다시 실행하세요."
      };
    case "notice_assignment_detection_covered_by_state":
      return {
        title: "공지 속 과제 감지 상태 확인",
        explanation: "공지 본문에서 과제처럼 보이는 항목을 찾았고, 그 항목이 앱 상태와 미리 알림 후보에 반영됐는지 검사합니다.",
        nextAction: "대시보드의 과제 후보를 확인하고, 빠진 항목이 있으면 과제로 반영한 뒤 과제/시험 동기화를 다시 실행하세요."
      };
    case "calendar_exam_count_matches_state":
      return countMismatchDiagnostic({
        detail,
        currentKey: "calendar",
        expectedKey: "state",
        titlePrefix: "캘린더 시험",
        explanationName: "Apple Calendar의 시험",
        nextAction: "과제/시험 동기화를 다시 실행한 뒤 상태 검사를 한 번 더 누르세요. 계속 남으면 Calendar 앱의 KLMS 캘린더에서 누락된 시험 일정을 확인하세요."
      });
    case "calendar_result_exam_matches_state":
      return countMismatchDiagnostic({
        detail,
        currentKey: "result",
        expectedKey: "state",
        titlePrefix: "마지막 캘린더 반영에서 시험",
        explanationName: "마지막 캘린더 반영 결과의 시험",
        nextAction: "과제/시험 동기화를 다시 실행한 뒤 상태 검사를 한 번 더 누르세요. 계속 남으면 Mac의 캘린더 권한과 KLMS 캘린더를 확인하세요."
      });
    case "calendar_helpdesk_count_matches_state":
      return countMismatchDiagnostic({
        detail,
        currentKey: "calendar",
        expectedKey: "state",
        titlePrefix: "캘린더 헬프데스크",
        explanationName: "Apple Calendar의 헬프데스크",
        nextAction: "과제/시험 동기화를 다시 실행한 뒤 상태 검사를 한 번 더 누르세요."
      });
    case "calendar_result_helpdesk_matches_state":
      return countMismatchDiagnostic({
        detail,
        currentKey: "result",
        expectedKey: "state",
        titlePrefix: "마지막 캘린더 반영에서 헬프데스크",
        explanationName: "마지막 캘린더 반영 결과의 헬프데스크",
        nextAction: "과제/시험 동기화를 다시 실행한 뒤 상태 검사를 한 번 더 누르세요."
      });
    case "reminders_assignment_count_matches_state":
      return {
        title: "미리 알림 과제 수 불일치",
        explanation: "앱 상태의 과제 수와 Apple Reminders의 과제 미리 알림 수가 다릅니다.",
        nextAction: "과제/시험 동기화를 다시 실행하세요. 직접 체크한 완료 상태는 보존되어야 하므로, 중복 항목이 보이면 미리 알림 목록에서 같은 제목을 확인하세요."
      };
    case "past_exam_items_absent":
      return {
        title: "지난 시험 정리 상태 확인",
        explanation: "지난 시험이 앱 상태나 캘린더에 남아 있는지 확인하는 검사입니다.",
        nextAction: "지난 시험이 남아 있으면 과제/시험 동기화를 다시 실행해서 오래된 시험을 정리하세요."
      };
    case "exam_information_present":
      return {
        title: "시험 세부 정보 확인",
        explanation: "시험 일정에 시간, 범위, 장소 같은 세부 정보가 충분히 들어 있는지 확인하는 검사입니다.",
        nextAction: "시험 상세가 부족하면 해당 시험 항목을 열어 범위/장소를 직접 보강하거나 공지 후보를 다시 확인하세요."
      };
    default:
      return {
        title: `상태 검사 · ${name || "알 수 없음"}`,
        explanation: detail || "상태 검사 항목입니다.",
        nextAction: isIssueStatus(check?.status) ? "원본 로그에서 같은 항목명을 검색하고, 관련 동기화를 다시 실행하세요." : "문제가 없으면 별도 조치가 필요 없습니다."
      };
  }
}

function countMismatchDiagnostic({ detail, currentKey, expectedKey, titlePrefix, explanationName, nextAction }) {
  const current = numericValue(detail, currentKey);
  const expected = numericValue(detail, expectedKey);
  const missing = Number.isFinite(current) && Number.isFinite(expected) ? Math.max(0, expected - current) : NaN;
  return {
    title: Number.isFinite(missing) && missing > 0 ? `${titlePrefix} ${missing}개 누락` : `${titlePrefix} 수 불일치`,
    explanation: Number.isFinite(current) && Number.isFinite(expected)
      ? `앱 상태 파일에는 ${expected}개가 있는데 ${explanationName} 수는 ${current}개입니다. 직접 삭제됐거나 반영 단계가 일부 실패했을 수 있습니다.`
      : "앱 상태와 실제 반영 결과의 수가 다릅니다.",
    nextAction
  };
}

function numericValue(detail, key) {
  const match = String(detail || "").match(new RegExp(`(?:^|[\\s,])${escapeRegExp(key)}=([0-9]+)(?:$|[\\s,])`));
  return match ? Number(match[1]) : NaN;
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function updateConnectionState(text, klass) {
  const pill = $("connectionState");
  pill.textContent = text;
  pill.className = `status-pill ${klass || "muted"}`;
}

function setConnectionPhase(phase) {
  const normalized = ["unconfigured", "checking", "connecting", "connected", "reconnecting", "offline", "error"].includes(phase)
    ? phase
    : "error";
  state.connectionPhase = normalized;
  if (["unconfigured", "checking", "connected"].includes(normalized)) {
    state.connectionMessage = "";
  }
  const presentation = {
    unconfigured: ["연결 필요", "muted"],
    checking: ["연결 확인 중", "muted"],
    connecting: ["실시간 연결 중", "muted"],
    connected: ["실시간 연결됨", "ok"],
    reconnecting: ["실시간 재연결 중", "warn"],
    offline: ["오프라인", "fail"],
    error: ["연결 실패", "fail"]
  }[normalized];
  updateConnectionState(...presentation);
  scheduleRender({ header: true });
}

function setBusy(isBusy) {
  state.busy = isBusy;
  updateBusyControls();
  if (!isBusy) scheduleRealtimeFlush(0);
}

function updateBusyControls() {
  document.querySelectorAll("button:not(#sidebarToggleButton):not(#sidebarBackdrop):not([data-sidebar-target])").forEach((button) => {
    window.KLMSRelayState.setControlBusy(button, state.busy);
  });
}

async function copyState() {
  const text = JSON.stringify({
    status: state.status,
    latestCommand: state.latestCommand,
    itemCount: state.items.length,
    message: statusSubtitle()
  }, null, 2);
  await window.klmsWindows.writeClipboardText(text);
  toast("현재 상태를 복사했습니다.");
}

function showError(error) {
  const message = error && error.message ? error.message : String(error);
  toast(message, { assertive: true });
}

function toast(message, options = {}) {
  const element = $("toast");
  element.setAttribute("role", options.assertive ? "alert" : "status");
  element.setAttribute("aria-live", options.assertive ? "assertive" : "polite");
  element.textContent = message;
  element.classList.remove("hidden");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => element.classList.add("hidden"), 3200);
}

function compareText(lhs, rhs) {
  return String(lhs || "").localeCompare(String(rhs || ""), "ko");
}

function compareTimestamp(lhs, rhs) {
  const lhsScore = timestampScore(lhs);
  const rhsScore = timestampScore(rhs);
  if (lhsScore !== rhsScore) {
    return lhsScore > rhsScore ? 1 : -1;
  }
  return compareText(lhs, rhs);
}

function timestampScore(value) {
  const text = String(value || "").trim();
  if (!text) {
    return Number.NEGATIVE_INFINITY;
  }
  const parsed = Date.parse(text);
  if (Number.isFinite(parsed)) {
    return parsed;
  }
  const numbers = text.match(/\d+/g) || [];
  const compact = numbers
    .map((part, index) => index === 0 ? part.padStart(4, "0") : part.padStart(2, "0"))
    .join("")
    .slice(0, 14);
  const score = Number.parseInt(compact.padEnd(14, "0"), 10);
  return Number.isFinite(score) ? score : Number.NEGATIVE_INFINITY;
}

function visibleItems(items) {
  return items.filter((item) => !item.isHidden);
}

function calendarChangeTotal(status) {
  return Number(status.calendarCreated || 0) + Number(status.calendarUpdated || 0) + Number(status.calendarDeleted || 0);
}

function fileCleanupTotal(status) {
  return Number(status.filePruned || 0) + Number(status.fileArchivePruned || 0);
}

function formatBytes(value) {
  if (!Number.isFinite(value) || value <= 0) {
    return "";
  }
  const units = ["B", "KB", "MB", "GB"];
  let size = value;
  let unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex += 1;
  }
  return `${size.toFixed(unitIndex === 0 ? 0 : 1)} ${units[unitIndex]}`;
}

function isInFlightStatus(status) {
  return status === "pending" || status === "running";
}

function isTerminalStatus(status) {
  return status === "completed" || status === "cancelled" || status === "failed" || status === "macUnavailable";
}
