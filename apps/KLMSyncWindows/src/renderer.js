const syncCommands = [
  { kind: "fullSync", label: "전체", iconClass: "icon-sync", tone: "blue" },
  { kind: "coreSync", label: "과제/시험", iconClass: "icon-check", tone: "green" },
  { kind: "noticeSync", label: "공지", iconClass: "icon-notice", tone: "purple" },
  { kind: "filesSync", label: "파일", iconClass: "icon-file", tone: "orange" }
];

const diagnosticCommands = [
  { kind: "verify", label: "상태 검사", iconClass: "icon-check", tone: "green" },
  { kind: "doctor", label: "권한/환경 진단", iconClass: "icon-alert", tone: "red" },
  { kind: "report", label: "요약 갱신", iconClass: "icon-report", tone: "blue" },
  { kind: "v2BuildState", label: "상태 파일 재생성", iconClass: "icon-sync", tone: "purple" }
];

const unknownSemesterLabel = "학기 미확인";

const fileSortOptions = [
  { key: "course", label: "과목" },
  { key: "kind", label: "종류" },
  { key: "name", label: "파일명" },
  { key: "path", label: "경로" },
  { key: "recent", label: "최근" }
];

const fileDetailOptions = [
  { key: "files", label: "파일 목록" },
  { key: "newFiles", label: "새 파일" },
  { key: "quarantine", label: "격리" },
  { key: "pruned", label: "삭제 예정" }
];

const noticeCategoryOptions = [
  { key: "all", label: "전체" },
  { key: "important", label: "중요" },
  { key: "fresh", label: "새 공지" },
  { key: "unread", label: "읽지 않음" },
  { key: "archived", label: "확인함" },
  { key: "hidden", label: "숨김" }
];

const dashboardKinds = [
  { key: "all", label: "전체", get: (_status, items) => visibleItems(items).length },
  { key: "assignment", label: "과제", get: (status) => status.assignments },
  { key: "completedAssignment", label: "완료 기록", get: (_status, items) => countItems(items, "completedAssignment") },
  { key: "assignmentCandidate", label: "과제 후보", get: (_status, items) => countItems(items, "assignmentCandidate") },
  { key: "exam", label: "시험", get: (status) => status.exams },
  { key: "examCandidate", label: "시험 후보", get: (_status, items) => countItems(items, "examCandidate") },
  { key: "helpDesk", label: "헬프데스크", get: (status, items) => status.helpDesk || countItems(items, "helpDesk") },
  { key: "notice", label: "공지", get: (status) => status.notices },
  { key: "file", label: "파일", get: (status) => status.fileTotal },
  { key: "newFiles", label: "새 파일", get: (status) => status.newFiles },
  { key: "quarantine", label: "격리", get: (status) => status.quarantine },
  { key: "pruned", label: "삭제된 파일", get: (status) => fileCleanupTotal(status) },
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
  recentCommands: [],
  recentActions: [],
  recentFileAccess: [],
  selectedSection: "dashboard",
  selectedKind: "all",
  selectedItemId: "",
  sort: "recent",
  fileSort: "course",
  selectedFileDetail: "files",
  noticeCategory: "all",
  query: "",
  selectedYear: "all",
  selectedSemester: "all",
  selectedCourse: "all",
  showHidden: false,
  newOnly: false,
  recentOnly: false,
  theme: "light",
  busy: false
};

const $ = (id) => document.getElementById(id);
const trackedReportCommandIDsKey = "klms-tracked-report-command-ids";
let refreshTimer = null;
let trackedReportCommandIDs = loadTrackedReportCommandIDs();

document.addEventListener("DOMContentLoaded", async () => {
  initTheme();
  bindEvents();
  renderCommands();
  renderAll();
  await loadConfig();
  if (state.configured) {
    await refreshAll({ quiet: true, auto: true });
  }
});

function bindEvents() {
  $("saveConnectionButton").addEventListener("click", saveConnection);
  $("checkConnectionButton").addEventListener("click", checkConnection);
  $("clearConnectionButton").addEventListener("click", clearConnection);
  $("pasteClipboardButton").addEventListener("click", pasteConnectionFromClipboard);
  $("parseConnectionButton").addEventListener("click", parseConnectionText);
  $("refreshButton").addEventListener("click", () => refreshAll());
  $("copyStateButton").addEventListener("click", copyState);
  $("themeToggleButton").addEventListener("click", toggleTheme);
  $("verifyFromIntegrationButton").addEventListener("click", () => createCommand("verify"));
  $("footerRefreshButton").addEventListener("click", () => refreshAll());
  $("footerResetButton").addEventListener("click", resetDisplayState);
  $("footerSettingsButton").addEventListener("click", () => setSection("settings"));
  document.querySelectorAll(".section-tab").forEach((button) => {
    button.addEventListener("click", () => setSection(button.dataset.section));
  });
  $("yearSelect").addEventListener("change", (event) => {
    state.selectedYear = event.target.value;
    state.selectedItemId = "";
    renderFilters();
    renderDashboard();
    renderItems();
    renderDetail();
  });
  $("semesterSelect").addEventListener("change", (event) => {
    state.selectedSemester = event.target.value;
    state.selectedItemId = "";
    renderFilters();
    renderDashboard();
    renderItems();
    renderDetail();
  });
  $("courseSelect").addEventListener("change", (event) => {
    state.selectedCourse = event.target.value;
    state.selectedItemId = "";
    renderFilters();
    renderDashboard();
    renderItems();
    renderDetail();
  });
  $("newOnlyToggle").addEventListener("change", (event) => {
    state.newOnly = event.target.checked;
    state.selectedItemId = "";
    renderFilters();
    renderItems();
    renderDetail();
  });
  $("recentOnlyToggle").addEventListener("change", (event) => {
    state.recentOnly = event.target.checked;
    state.selectedItemId = "";
    renderFilters();
    renderItems();
    renderDetail();
  });
  $("showHiddenToggle").addEventListener("change", (event) => {
    state.showHidden = event.target.checked;
    state.selectedItemId = "";
    renderFilters();
    renderDashboard();
    renderItems();
    renderDetail();
  });
  $("resetFiltersButton").addEventListener("click", resetFilters);
  $("searchInput").addEventListener("input", (event) => {
    state.query = event.target.value;
    renderFilters();
    renderItems();
  });
  $("sortSelect").addEventListener("change", (event) => {
    state.sort = event.target.value;
    renderItems();
  });
}

function initTheme() {
  const theme = document.documentElement.dataset.theme === "dark" ? "dark" : "light";
  applyTheme(theme, { persist: false });
}

function toggleTheme() {
  applyTheme(state.theme === "dark" ? "light" : "dark");
}

function applyTheme(theme, options = {}) {
  state.theme = theme === "dark" ? "dark" : "light";
  document.documentElement.dataset.theme = state.theme;
  const button = $("themeToggleButton");
  if (button) {
    button.textContent = state.theme === "dark" ? "라이트모드" : "다크모드";
    button.setAttribute("aria-pressed", String(state.theme === "dark"));
  }
  if (options.persist !== false) {
    try {
      localStorage.setItem("klms-theme", state.theme);
    } catch {
      // Theme persistence is optional; the UI still updates without it.
    }
  }
}

async function loadConfig() {
  try {
    const config = await window.klmsWindows.loadConfig();
    $("relayURL").value = config.relayURL || "";
    $("relayToken").placeholder = config.hasToken ? `저장됨 (${config.tokenPreview})` : "처음 연결하거나 바꿀 때만 입력";
    state.configured = Boolean(config.relayURL && config.hasToken);
    updateConnectionState(state.configured ? "저장됨" : "대기", state.configured ? "ok" : "muted");
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
    $("relayToken").placeholder = config.hasToken ? `저장됨 (${config.tokenPreview})` : "처음 연결하거나 바꿀 때만 입력";
    state.configured = Boolean(config.relayURL && config.hasToken);
    updateConnectionState("저장됨", "ok");
    if (!options.quiet) {
      toast("서버 연결 정보를 저장했습니다.");
    }
    if (options.refresh !== false) {
      await refreshAll({ quiet: true });
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
    state.status = { ...defaultStatus };
    state.latestCommand = null;
    state.running = false;
    state.message = "";
    state.items = [];
    state.recentCommands = [];
    state.recentActions = [];
    state.recentFileAccess = [];
    state.selectedSection = "settings";
    state.selectedKind = "all";
    state.selectedItemId = "";
    state.noticeCategory = "all";
    state.selectedYear = "all";
    state.selectedSemester = "all";
    state.selectedCourse = "all";
    state.showHidden = false;
    state.newOnly = false;
    state.recentOnly = false;
    state.query = "";
    $("searchInput").value = "";
    stopAutoRefresh();
    updateConnectionState("대기", "muted");
    renderAll();
    toast("Windows 앱의 서버 연결 정보를 지웠습니다.");
  } catch (error) {
    showError(error);
  } finally {
    setBusy(false);
  }
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
    stopAutoRefresh();
    return;
  }
  if (options.auto && state.busy) {
    scheduleAutoRefresh(2000);
    return;
  }
  try {
    if (!options.auto) {
      setBusy(true);
      updateConnectionState("확인 중", "muted");
    }
    await window.klmsWindows.relayRequest({ path: "/healthz" });
    const [statusResponse, commandResponse, syncData, actionResponse, fileAccessResponse] = await Promise.all([
      window.klmsWindows.relayRequest({ path: "/v1/status" }),
      window.klmsWindows.relayRequest({ path: "/v1/commands/recent?limit=8" }),
      window.klmsWindows.relayRequest({ path: "/v1/sync-data?limit=2000" }),
      window.klmsWindows.relayRequest({ path: "/v1/item-actions/recent?limit=10" }),
      window.klmsWindows.relayRequest({ path: "/v1/file-access/recent?limit=20" })
    ]);
    applyStatus(statusResponse);
    state.recentCommands = commandResponse.commands || [];
    handleReportNotificationUpdates(state.recentCommands);
    state.items = syncData.items || [];
    state.recentActions = actionResponse.actions || [];
    state.recentFileAccess = fileAccessResponse.requests || [];
    updateConnectionState("연결됨", "ok");
    if (options.check) {
      toast("서버 릴레이와 연결됐습니다.");
    }
    renderAll();
  } catch (error) {
    updateConnectionState("실패", "fail");
    if (!options.quiet) {
      showError(error);
    }
  } finally {
    if (!options.auto) {
      setBusy(false);
    }
    scheduleAutoRefresh();
  }
}

function scheduleAutoRefresh(delay = nextRefreshDelay()) {
  stopAutoRefresh();
  if (!state.configured) {
    return;
  }
  refreshTimer = window.setTimeout(() => {
    refreshAll({ quiet: true, auto: true });
  }, delay);
}

function stopAutoRefresh() {
  if (refreshTimer) {
    window.clearTimeout(refreshTimer);
    refreshTimer = null;
  }
}

function nextRefreshDelay() {
  const phase = state.running ? "running" : state.status.phase || "idle";
  return isInFlightStatus(phase)
    || isInFlightStatus(state.latestCommand?.status)
    || state.recentFileAccess.some((request) => isInFlightStatus(request.status))
    || state.status.authDigits
    ? 2000
    : 10000;
}

function applyStatus(payload) {
  state.status = { ...defaultStatus, ...(payload.status || {}) };
  state.latestCommand = payload.latestCommand || null;
  state.running = Boolean(payload.running);
  state.message = payload.message || "";
}

async function createCommand(kind) {
  try {
    setBusy(true);
    const command = await window.klmsWindows.relayRequest({
      path: "/v1/commands",
      method: "POST",
      body: { kind }
    });
    trackReportNotificationIfNeeded(command);
    toast(`${commandLabel(kind)} 요청을 보냈습니다.`);
    await refreshAll({ quiet: true });
  } catch (error) {
    showError(error);
  } finally {
    setBusy(false);
  }
}

async function createItemAction(action, item) {
  try {
    setBusy(true);
    await window.klmsWindows.relayRequest({
      path: "/v1/item-actions",
      method: "POST",
      body: {
        action,
        itemID: item.id,
        itemKind: item.kind,
        itemTitle: item.title
      }
    });
    applyOptimisticItemAction(action, item);
    toast(`${actionLabel(action)} 요청을 보냈습니다.`);
    await refreshAll({ quiet: true });
  } catch (error) {
    showError(error);
  } finally {
    setBusy(false);
  }
}

async function createFileAccess(item) {
  if (item.kind !== "file") {
    showError(new Error("파일 항목만 열기 링크를 요청할 수 있습니다."));
    return;
  }
  try {
    setBusy(true);
    await window.klmsWindows.relayRequest({
      path: "/v1/file-access",
      method: "POST",
      body: {
        itemID: item.id,
        itemKind: item.kind,
        itemTitle: item.title
      }
    });
    toast("Mac에 파일 열기 링크를 요청했습니다.");
    await refreshAll({ quiet: true });
  } catch (error) {
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
  renderHeader();
  renderQuickStatus();
  renderNextAction();
  renderIntegration();
  renderSections();
  renderFilters();
  renderDashboard();
  renderItems();
  renderDetail();
  renderPreview();
  renderFilesPanel();
  renderDiagnostics();
  renderLoginPanel();
  renderAppDiagnostics();
  renderCommandOutputPanels();
  renderSettingsMirror();
  renderHistory();
}

function setSection(section) {
  state.selectedSection = section || "dashboard";
  renderSections();
}

function renderSections() {
  document.querySelectorAll(".section-tab").forEach((button) => {
    button.classList.toggle("active", button.dataset.section === state.selectedSection);
  });
  document.querySelectorAll(".app-section").forEach((section) => {
    section.classList.toggle("active", section.id === `${state.selectedSection}Section`);
  });
}

function renderCommands() {
  $("commandButtons").replaceChildren(...syncCommands.map((command) => {
    const button = document.createElement("button");
    button.className = `command-button tone-${command.tone}`;
    button.innerHTML = `<span class="command-icon ${escapeHTML(command.iconClass)}" aria-hidden="true"></span><span>${escapeHTML(command.label)}</span>`;
    button.addEventListener("click", () => createCommand(command.kind));
    return button;
  }));
}

function renderHeader() {
  const phase = state.running ? "running" : state.status.phase || "idle";
  const inFlight = isInFlightStatus(phase) || isInFlightStatus(state.latestCommand?.status);
  const terminal = isTerminalStatus(phase) || isTerminalStatus(state.latestCommand?.status);
  $("phaseLabel").textContent = phaseLabel(phase);
  $("statusTitle").textContent = statusTitle();
  $("statusSubtitle").textContent = state.message || latestCommandText() || "대기 중인 서버 요청이 없습니다.";

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

function renderQuickStatus() {
  const phase = state.running ? "running" : state.status.phase || "idle";
  const chips = [
    {
      label: state.configured ? "릴레이 연결 저장됨" : "릴레이 연결 필요",
      klass: state.configured ? "ok" : "muted"
    },
    {
      label: state.running ? "Mac 실행 중" : latestRunChipText(),
      klass: state.running ? "warn" : latestRunChipClass()
    },
    {
      label: `공지 새 ${state.status.noticeNew} · 수정 ${state.status.noticeUpdated}`,
      klass: (state.status.noticeNew + state.status.noticeUpdated) > 0 ? "blue" : "muted"
    },
    {
      label: `파일 새 ${state.status.newFiles} · 정리 ${fileCleanupTotal(state.status)}`,
      klass: (state.status.newFiles + fileCleanupTotal(state.status)) > 0 ? "green" : "muted"
    },
    {
      label: `캘린더 변경 ${calendarChangeTotal(state.status)}`,
      klass: calendarChangeTotal(state.status) > 0 ? "purple" : "muted"
    }
  ];
  if (state.status.loginRequired || state.status.authDigits) {
    chips.unshift({
      label: state.status.authDigits ? `KAIST 인증 ${state.status.authDigits}` : "KLMS 로그인 필요",
      klass: "warn"
    });
  }
  $("quickStatusStrip").replaceChildren(...chips.map((chip) => {
    const element = document.createElement("span");
    element.className = `quick-chip ${chip.klass}`;
    element.textContent = chip.label;
    return element;
  }));
}

function renderNextAction() {
  const panel = $("nextActionPanel");
  const action = nextAction();
  panel.className = `next-action-panel ${action.tone}`;
  panel.innerHTML = `
    <div>
      <strong>${escapeHTML(action.title)}</strong>
      <p>${escapeHTML(action.detail)}</p>
    </div>
    <button class="${action.secondary ? "secondary" : ""}" id="nextActionButton">${escapeHTML(action.button)}</button>
  `;
  $("nextActionButton").addEventListener("click", action.run);
}

function nextAction() {
  if (!state.configured) {
    return {
      tone: "warn",
      title: "서버 릴레이 연결 필요",
      detail: "Mac 앱 설정에서 복사한 서버 주소와 토큰을 설정에 붙여넣어야 Windows에서 같은 상태를 볼 수 있습니다.",
      button: "설정 열기",
      run: () => setSection("settings")
    };
  }
  if (state.status.authDigits) {
    return {
      tone: "warn",
      title: `KAIST 인증 번호 ${state.status.authDigits}`,
      detail: "Mac에서 Safari/Kaikey 인증을 완료하면 Windows 대시보드가 자동으로 최신 상태를 받습니다.",
      button: "상태 갱신",
      run: () => refreshAll()
    };
  }
  if (state.status.loginRequired) {
    return {
      tone: "warn",
      title: "KLMS 로그인이 필요합니다",
      detail: "Mac 앱에서 Safari 로그인을 확인해야 실제 동기화가 계속됩니다.",
      button: "진단 요청",
      run: () => createCommand("doctor")
    };
  }
  if (state.latestCommand?.status === "failed" || state.latestCommand?.status === "macUnavailable") {
    return {
      tone: "fail",
      title: `${commandLabel(state.latestCommand.kind)} ${commandStatusLabel(state.latestCommand.status)}`,
      detail: state.message || "Mac 앱 상태, 서버 토큰, 자동 실행 상태를 확인해야 합니다.",
      button: "진단 보기",
      run: () => setSection("logs")
    };
  }
  if (state.running || state.latestCommand?.status === "running") {
    return {
      tone: "info",
      title: "Mac에서 동기화 실행 중",
      detail: state.message || latestCommandText() || "요청을 처리하는 동안 항목 목록이 갱신될 수 있습니다.",
      button: "새로고침",
      run: () => refreshAll()
    };
  }
  return {
    tone: "ok",
    title: "원격 실행 준비됨",
    detail: `현재 표시 항목 ${visibleItems(state.items).length}개 · 최근 요청 ${state.recentCommands.length}개`,
    button: "전체 동기화",
    run: () => createCommand("fullSync")
  };
}

function renderIntegration() {
  const cards = integrationStatuses().map((status) => {
    const element = document.createElement("div");
    element.className = `integration-card ${status.health}`;
    element.innerHTML = `
      <div class="integration-top">
        <strong>${escapeHTML(status.title)}</strong>
        <span>${escapeHTML(status.label)}</span>
      </div>
      <div class="integration-value">${escapeHTML(status.value)}</div>
      <p>${escapeHTML(status.detail)}</p>
    `;
    return element;
  });
  $("integrationCards").replaceChildren(...cards);
}

function integrationStatuses() {
  const commandStatus = state.latestCommand?.status || state.status.phase || "idle";
  return [
    {
      title: "서버 릴레이",
      label: state.configured ? "정상" : "미설정",
      value: state.configured ? "연결 정보 저장됨" : "설정 필요",
      detail: state.configured ? "Cloudflare/VPS 릴레이를 통해 Mac과 Windows가 같은 서버 DB를 봅니다." : "설정 탭에서 서버 주소와 토큰을 저장하세요.",
      health: state.configured ? "ok" : "unknown"
    },
    {
      title: "Mac 실행기",
      label: commandStatusLabel(commandStatus),
      value: state.running ? "실행 중" : latestRunChipText(),
      detail: "실제 KLMS scraping, Notes, Calendar, Reminders 반영은 Mac 앱이 처리합니다.",
      health: state.running ? "running" : commandStatusClass(commandStatus)
    },
    {
      title: "메모",
      label: state.status.noticeNew + state.status.noticeUpdated > 0 ? "변경 있음" : "대기",
      value: `공지 ${state.status.notices}개`,
      detail: `새 공지 ${state.status.noticeNew} · 수정 ${state.status.noticeUpdated} · 무시 ${state.status.noticeIgnored}`,
      health: state.status.noticeNew + state.status.noticeUpdated > 0 ? "warn" : "unknown"
    },
    {
      title: "캘린더",
      label: calendarChangeTotal(state.status) > 0 ? "변경 있음" : "대기",
      value: `변경 ${calendarChangeTotal(state.status)}개`,
      detail: `생성 ${state.status.calendarCreated} · 수정 ${state.status.calendarUpdated} · 삭제 ${state.status.calendarDeleted}`,
      health: calendarChangeTotal(state.status) > 0 ? "ok" : "unknown"
    },
    {
      title: "미리 알림",
      label: state.status.assignments > 0 ? "항목 있음" : "대기",
      value: `과제 ${state.status.assignments}개`,
      detail: `완료 기록 ${countItems(state.items, "completedAssignment")} · 과제 후보 ${countItems(state.items, "assignmentCandidate")}`,
      health: state.status.assignments > 0 ? "ok" : "unknown"
    },
    {
      title: "파일",
      label: state.status.quarantine > 0 ? "확인 필요" : "대기",
      value: `파일 ${state.status.fileTotal}개`,
      detail: `새 파일 ${state.status.newFiles} · 격리 ${state.status.quarantine} · 정리 ${fileCleanupTotal(state.status)}`,
      health: state.status.quarantine > 0 ? "warn" : "ok"
    }
  ];
}

function renderFilters() {
  const years = yearOptions();
  renderSelectOptions(
    $("yearSelect"),
    [{ value: "all", label: "전체 년도" }, ...years.map((year) => ({ value: year, label: `${year}년` }))],
    state.selectedYear
  );
  const semesters = semesterOptions();
  renderSelectOptions(
    $("semesterSelect"),
    [{ value: "all", label: "전체 학기" }, ...semesters.map((semester) => ({ value: semester, label: semester }))],
    state.selectedSemester
  );
  const courses = courseOptions();
  renderSelectOptions(
    $("courseSelect"),
    [{ value: "all", label: "전체 과목" }, ...courses.map((course) => ({ value: course, label: course }))],
    state.selectedCourse
  );
  $("yearSelect").disabled = years.length === 0;
  $("semesterSelect").disabled = semesters.length === 0;
  $("courseSelect").disabled = courses.length === 0;
  $("newOnlyToggle").checked = state.newOnly;
  $("recentOnlyToggle").checked = state.recentOnly;
  $("showHiddenToggle").checked = state.showHidden;
  $("resetFiltersButton").hidden = !hasActiveFilters();
}

function renderSelectOptions(select, options, selectedValue) {
  const values = new Set(options.map((option) => option.value));
  const selected = values.has(selectedValue) ? selectedValue : "all";
  if (selected !== selectedValue) {
    if (select.id === "yearSelect") {
      state.selectedYear = selected;
    } else if (select.id === "semesterSelect") {
      state.selectedSemester = selected;
    } else if (select.id === "courseSelect") {
      state.selectedCourse = selected;
    }
  }
  select.replaceChildren(...options.map((option) => {
    const element = document.createElement("option");
    element.value = option.value;
    element.textContent = option.label;
    element.selected = option.value === selected;
    return element;
  }));
}

function resetFilters() {
  state.query = "";
  state.selectedYear = "all";
  state.selectedSemester = "all";
  state.selectedCourse = "all";
  state.noticeCategory = "all";
  state.showHidden = false;
  state.newOnly = false;
  state.recentOnly = false;
  state.selectedItemId = "";
  $("searchInput").value = "";
  renderFilters();
  renderDashboard();
  renderItems();
  renderDetail();
}

function resetDisplayState() {
  state.status = { ...defaultStatus };
  state.latestCommand = null;
  state.running = false;
  state.message = "";
  state.items = [];
  state.recentCommands = [];
  state.recentActions = [];
  state.selectedKind = "all";
  state.selectedItemId = "";
  state.noticeCategory = "all";
  resetFilters();
  renderAll();
  toast("화면 표시 상태를 초기화했습니다.");
}

function courseOptions() {
  return [...new Set(state.items
    .filter(matchesSelectedTerm)
    .map(normalizedCourseName)
    .filter(Boolean))]
    .sort((lhs, rhs) => lhs.localeCompare(rhs, "ko"));
}

function yearOptions() {
  return [...new Set(state.items.map(itemTermParts).map((term) => term.year).filter(Boolean))]
    .sort((lhs, rhs) => rhs.localeCompare(lhs, "ko"));
}

function semesterOptions() {
  const terms = state.items
    .filter(matchesSelectedYear)
    .map(itemTermParts)
  const known = [...new Set(terms.map((term) => term.semester).filter(Boolean))]
    .sort(compareSemesterLabels);
  return terms.some(isUnknownTerm) ? [...known, unknownSemesterLabel] : known;
}

function matchesSelectedYear(item) {
  const term = itemTermParts(item);
  return state.selectedYear === "all" || term.year === state.selectedYear;
}

function matchesSelectedSemester(item) {
  if (state.selectedSemester === "all") {
    return true;
  }
  const term = itemTermParts(item);
  if (state.selectedSemester === unknownSemesterLabel) {
    return isUnknownTerm(term);
  }
  return term.semester === state.selectedSemester;
}

function matchesSelectedTerm(item) {
  return matchesSelectedYear(item) && matchesSelectedSemester(item);
}

function isUnknownTerm(term) {
  return !term.year || !term.semester;
}

function normalizedCourseName(item) {
  return String(item.course || "").trim();
}

function latestRunChipText() {
  if (!state.latestCommand) {
    return "첫 실행 전";
  }
  return `${commandLabel(state.latestCommand.kind)} ${commandStatusLabel(state.latestCommand.status)}`;
}

function latestRunChipClass() {
  return commandStatusClass(state.latestCommand?.status);
}

function renderDashboard() {
  const cards = dashboardKinds
    .filter((card) => card.key === "all" || card.get(state.status, state.items) > 0)
    .map((card) => {
      const button = document.createElement("button");
      button.className = `metric-card ${state.selectedKind === card.key ? "active" : ""}`;
      button.innerHTML = `<span>${card.label}</span><strong>${card.get(state.status, state.items)}</strong><span>${cardDetail(card.key)}</span>`;
      button.addEventListener("click", () => {
        state.selectedKind = card.key;
        state.selectedItemId = filteredItems()[0]?.id || "";
        renderDashboard();
        renderItems();
        renderDetail();
      });
      return button;
    });
  $("dashboardCards").replaceChildren(...cards);
}

function renderItems() {
  renderNoticeCategoryControls();
  const items = filteredItems();
  $("listTitle").textContent = kindTitle(state.selectedKind);
  $("listCount").textContent = `${items.length}개`;
  if (!items.length) {
    $("itemList").innerHTML = `<div class="empty-list">표시할 항목이 없습니다.</div>`;
    return;
  }
  $("itemList").replaceChildren(...items.map((item) => {
    const button = document.createElement("button");
    button.className = `item-row ${state.selectedItemId === item.id ? "active" : ""}`;
    button.innerHTML = `
      <div class="badges">${badgesHTML(item)}</div>
      <div class="title">${escapeHTML(item.title || "제목 없음")}</div>
      <div class="meta">${escapeHTML(itemMeta(item))}</div>
    `;
    button.addEventListener("click", () => {
      state.selectedItemId = item.id;
      renderItems();
      renderDetail();
    });
    return button;
  }));
}

function renderNoticeCategoryControls() {
  const container = $("noticeCategoryControls");
  if (!container) {
    return;
  }
  if (state.selectedKind !== "notice") {
    container.classList.add("hidden");
    return;
  }
  if (!noticeCategoryOptions.some((option) => option.key === state.noticeCategory)) {
    state.noticeCategory = "all";
  }
  const counts = noticeCategoryCounts();
  container.classList.remove("hidden");
  container.innerHTML = `
    <div class="segmented-controls" aria-label="공지 분류">
      ${noticeCategoryOptions.map((option) => `
        <button class="${option.key === state.noticeCategory ? "active" : ""}" data-notice-category="${escapeHTML(option.key)}">
          ${escapeHTML(option.label)} ${counts[option.key] || 0}
        </button>
      `).join("")}
    </div>
  `;
  container.querySelectorAll("[data-notice-category]").forEach((button) => {
    button.addEventListener("click", () => {
      state.noticeCategory = button.dataset.noticeCategory;
      state.selectedItemId = "";
      renderFilters();
      renderItems();
      renderDetail();
    });
  });
}

function renderDetail() {
  const item = currentItems().find((candidate) => candidate.id === state.selectedItemId);
  if (!item) {
    $("itemDetail").className = "empty-detail";
    $("itemDetail").innerHTML = "<h2>항목을 선택하세요</h2><p>왼쪽 목록에서 상세와 처리 버튼을 확인합니다.</p>";
    return;
  }
  const url = itemURL(item);
  const pathText = itemPath(item);
  const fileAccess = item.kind === "file" ? latestFileAccess(item) : null;
  $("itemDetail").className = "detail-card";
  $("itemDetail").innerHTML = `
    <div class="detail-header">
      <div class="detail-badges">${badgesHTML(item)}</div>
      <h2>${escapeHTML(item.title || "제목 없음")}</h2>
      <div class="detail-meta">${escapeHTML(itemMeta(item))}</div>
    </div>
    <div class="field-grid">
      ${fieldHTML("종류", kindTitle(item.kind))}
      ${fieldHTML("상태", item.status)}
      ${fieldHTML("시간", item.timestamp)}
      ${fieldHTML("과목", item.course)}
      ${fieldHTML("학기", itemTermLabel(item))}
      ${fieldHTML("첨부", item.attachmentCount > 0 ? `${item.attachmentCount}개` : "")}
      ${fieldHTML("서버 갱신", item.updatedAt)}
      ${fieldHTML("경로", pathText, true)}
      ${fieldHTML("URL", url, true)}
      ${fieldHTML("세부 내용", item.detail, true)}
      ${fieldHTML("식별자", item.id, true)}
    </div>
    <div class="action-section">
      <h3>열기/복사</h3>
      <div class="action-grid" id="detailUtilityActions"></div>
    </div>
    <div class="action-section">
      <h3>항목 처리</h3>
      <div class="action-grid" id="detailActions"></div>
    </div>
    ${item.kind === "file" ? `
      <div class="action-section">
        <h3>파일 열기</h3>
        ${fileAccess ? `<p class="hint"><strong>${escapeHTML(fileAccessStatusLabel(fileAccess.status))}</strong> · ${escapeHTML(fileAccessDescription(fileAccess))}</p>` : `<p class="hint">Mac이 보관 중인 course_files 원본을 임시 서버 링크로 준비할 수 있습니다.</p>`}
        <div class="action-grid">
          ${fileAccess && isDownloadAvailable(fileAccess) ? `<button id="openFileAccessButton">다운로드 열기</button>` : ""}
          <button class="secondary" id="requestFileAccessButton" ${fileAccess && isInFlightStatus(fileAccess.status) ? "disabled" : ""}>Mac에 파일 링크 요청</button>
        </div>
      </div>
    ` : ""}
    <div class="action-section">
      <h3>관련 동기화</h3>
      <button id="detailSyncButton">${commandLabel(relevantCommand(item.kind))} 요청</button>
      ${item.kind === "file" ? `<p class="hint">Windows는 KLMS에 직접 로그인하지 않습니다. 파일 열기 요청을 보내면 Mac이 로컬 파일 원본을 임시 업로드하고, 만료된 링크와 서버 기록은 자동 정리됩니다.</p>` : ""}
    </div>
  `;
  $("detailSyncButton").addEventListener("click", () => createCommand(relevantCommand(item.kind)));
  renderDetailUtilities(item, url);
  if (item.kind === "file") {
    const requestButton = $("requestFileAccessButton");
    if (requestButton) {
      requestButton.addEventListener("click", () => createFileAccess(item));
    }
    const openButton = $("openFileAccessButton");
    if (openButton && fileAccess?.downloadURL) {
      openButton.addEventListener("click", () => window.klmsWindows.openExternal(fileAccess.downloadURL));
    }
  }
  renderDetailActions(item);
}

function renderDetailUtilities(item, url) {
  const container = $("detailUtilityActions");
  if (!container) {
    return;
  }
  const actions = [
    url ? { title: "KLMS 열기", run: () => window.klmsWindows.openExternal(url) } : null,
    { title: "상세 복사", run: () => copyItemDetail(item) }
  ].filter(Boolean);
  container.replaceChildren(...actions.map((action) => {
    const button = document.createElement("button");
    button.className = "secondary";
    button.textContent = action.title;
    button.addEventListener("click", action.run);
    return button;
  }));
}

function renderDetailActions(item) {
  const container = $("detailActions");
  if (!container) {
    return;
  }
  const actions = detailActions(item);
  if (!actions.length) {
    container.innerHTML = `<div class="hint">처리할 수 있는 액션이 없습니다.</div>`;
    return;
  }
  container.replaceChildren(...actions.map((action) => {
    const button = document.createElement("button");
    button.className = action.toggle ? `toggle-action ${action.on ? "on" : ""}` : "secondary";
    button.innerHTML = action.toggle
      ? `<span><strong>${escapeHTML(action.title)}</strong><span class="sub">${escapeHTML(action.subtitle)}</span></span><span class="switch-pill">${action.on ? "ON" : "OFF"}</span>`
      : escapeHTML(action.title);
    button.addEventListener("click", () => createItemAction(action.action, item));
    return button;
  }));
}

function renderPreview() {
  const items = previewItems();
  $("previewPanel").innerHTML = `
    <section class="section-box">
      <div class="section-heading">
        <h2>미리보기</h2>
        <span class="hint">Mac 앱의 미리보기 섹션처럼 다음 실행에서 확인할 항목을 서버 DB 기준으로 모아봅니다.</span>
      </div>
      <div class="dashboard-grid compact-grid">
        ${previewMetricHTML("과제/시험", state.status.assignments + state.status.exams + state.status.helpDesk, "과제, 시험, 헬프데스크")}
        ${previewMetricHTML("공지 변경", state.status.noticeNew + state.status.noticeUpdated, "새 공지와 수정 공지")}
        ${previewMetricHTML("파일 변경", state.status.newFiles + state.status.quarantine + fileCleanupTotal(state.status), "새 파일, 격리, 정리")}
        ${previewMetricHTML("캘린더 변경", calendarChangeTotal(state.status), "생성, 수정, 삭제")}
      </div>
      <div class="button-row preview-actions">
        <button id="previewReportButton" class="secondary">요약 갱신 요청</button>
        <button id="previewFullSyncButton">전체 동기화 요청</button>
      </div>
    </section>
    <section class="section-box">
      <div class="section-heading">
        <h2>검토할 항목</h2>
        <span class="hint">${items.length}개</span>
      </div>
      <div class="preview-list">${items.length ? items.map(previewRowHTML).join("") : emptyInlineHTML("검토할 항목이 없습니다.")}</div>
    </section>
  `;
  $("previewReportButton").addEventListener("click", () => createCommand("report"));
  $("previewFullSyncButton").addEventListener("click", () => createCommand("fullSync"));
}

function renderFilesPanel() {
  const rawFiles = fileDetailRows("files", { filtered: false });
  const rawNewFiles = fileDetailRows("newFiles", { filtered: false });
  const rawQuarantine = fileDetailRows("quarantine", { filtered: false });
  const rawPruned = fileDetailRows("pruned", { filtered: false });
  const selectedDetail = fileDetailOptions.some((option) => option.key === state.selectedFileDetail)
    ? state.selectedFileDetail
    : "files";
  state.selectedFileDetail = selectedDetail;
  const selectedRows = sortedFileItems(fileDetailRows(selectedDetail, { filtered: true })).slice(0, 120);
  const selectedLabel = fileDetailOptions.find((option) => option.key === selectedDetail)?.label || "파일 목록";
  $("filesPanel").innerHTML = `
    <section class="section-box">
      <div class="section-heading">
        <h2>파일</h2>
        <span class="hint">Mac 파일 섹션처럼 파일 목록, 새 파일, 격리, 삭제 예정 항목을 나눠 봅니다.</span>
      </div>
      <div class="dashboard-grid compact-grid">
        ${fileMetricHTML("파일 목록", state.status.fileTotal || rawFiles.length, "files")}
        ${fileMetricHTML("실제 파일", rawFiles.length, "files")}
        ${fileMetricHTML("새 URL", state.status.newFiles || rawNewFiles.length, "newFiles")}
        ${fileMetricHTML("이동", countFileText(rawFiles, /moved|migrated|이동/i), "files")}
        ${fileMetricHTML("새로 받을 파일", state.status.newFiles || rawNewFiles.length, "newFiles")}
        ${fileMetricHTML("삭제 예정", fileCleanupTotal(state.status) || rawPruned.length, "pruned")}
        ${fileMetricHTML("형식 불일치", countFileText(rawFiles, /type.?mismatch|format|형식|불일치/i), "files")}
      </div>
      <div class="dashboard-grid compact-grid file-secondary-grid">
        ${previewMetricHTML("이미 있음", countFileText(rawFiles, /skipped|existing|이미|존재/i), "Mac 다운로드 결과")}
        ${previewMetricHTML("복원", countFileText(rawFiles.concat(rawPruned), /restored|restore|복원/i), "아카이브/상태 복원")}
        ${previewMetricHTML("재사용", countFileText(rawFiles, /reused|reuse|재사용/i), "기존 로그 파일 재사용")}
        ${fileMetricHTML("새 다운로드", state.status.newFiles || rawNewFiles.length, "newFiles")}
        ${fileMetricHTML("새 파일 보관함", state.status.newFiles || rawNewFiles.length, "newFiles")}
        ${fileMetricHTML("격리됨", state.status.quarantine || rawQuarantine.length, "quarantine")}
      </div>
      <div class="dashboard-grid compact-grid file-secondary-grid">
        ${fileMetricHTML("삭제", state.status.filePruned || rawPruned.length, "pruned")}
        ${previewMetricHTML("새 파일 유지", countFileText(rawPruned, /kept-fresh|유지/i), "정리 제외")}
        ${previewMetricHTML("보존", countFileText(rawPruned, /preserved|preserve|보존/i), "보존 처리")}
        ${previewMetricHTML("복원", countFileText(rawPruned, /restored|restore|복원/i), "정리 중 복원")}
      </div>
      <div class="button-row preview-actions">
        <button id="filesSyncButton">파일 동기화 요청</button>
        <button id="filesReportButton" class="secondary">요약 갱신 요청</button>
      </div>
    </section>
    <section class="section-box">
      <div class="section-heading">
        <h2>${escapeHTML(selectedLabel)}</h2>
        <span class="hint">${selectedRows.length}개 · ${escapeHTML(activeFilterText())}</span>
      </div>
      <div class="file-control-row">
        <div class="segmented-controls" aria-label="파일 세부 항목">
          ${fileDetailOptions.map((option) => `
            <button class="${option.key === selectedDetail ? "active" : ""}" data-file-detail="${escapeHTML(option.key)}">${escapeHTML(option.label)}</button>
          `).join("")}
        </div>
        <div class="sort-controls" aria-label="파일 정렬">
          <span>정렬</span>
          ${fileSortOptions.map((option) => `
            <button class="${option.key === state.fileSort ? "active" : ""}" data-file-sort="${escapeHTML(option.key)}">${escapeHTML(option.label)}</button>
          `).join("")}
        </div>
      </div>
      <div class="preview-list">${selectedRows.length ? selectedRows.map(fileRowHTML).join("") : emptyInlineHTML(fileEmptyText(selectedDetail))}</div>
    </section>
  `;
  $("filesSyncButton").addEventListener("click", () => createCommand("filesSync"));
  $("filesReportButton").addEventListener("click", () => createCommand("report"));
  document.querySelectorAll("[data-file-detail]").forEach((button) => {
    button.addEventListener("click", () => {
      state.selectedFileDetail = button.dataset.fileDetail;
      renderFilesPanel();
    });
  });
  document.querySelectorAll("[data-file-sort]").forEach((button) => {
    button.addEventListener("click", () => {
      state.fileSort = button.dataset.fileSort;
      renderFilesPanel();
    });
  });
}

function renderDiagnostics() {
  $("diagnosticsPanel").innerHTML = `
    <section class="section-box">
      <div class="section-heading">
        <h2>진단 도구</h2>
        <span class="hint">Mac 앱의 상태 검사, 진단, 요약, 상태 재생성을 원격 요청으로 실행합니다.</span>
      </div>
      <div class="diagnostic-grid">
        ${diagnosticCardHTML("서버 연결", state.configured ? "저장됨" : "미설정", state.configured ? "Windows에 릴레이 주소와 토큰이 저장되어 있습니다." : "설정 탭에서 연결 정보를 저장해야 합니다.", state.configured ? "ok" : "warn")}
        ${diagnosticCardHTML("Mac 응답", state.running ? "실행 중" : commandStatusLabel(state.latestCommand?.status), state.message || latestCommandText() || "최근 원격 요청 상태가 없습니다.", state.latestCommand?.status === "failed" ? "fail" : state.running ? "running" : "unknown")}
        ${diagnosticCardHTML("로그인", state.status.loginRequired ? "필요" : state.status.authDigits ? "인증 대기" : "대기", state.status.authStatusMessage || "로그인/인증 상태는 Mac 앱이 KLMS 페이지를 확인해 갱신합니다.", (state.status.loginRequired || state.status.authDigits) ? "warn" : "unknown")}
        ${diagnosticCardHTML("항목 처리", `${state.recentActions.length}개 기록`, "공지 읽음/중요, 과제 완료, 시험 확정, 파일 숨김 요청의 최근 상태입니다.", state.recentActions.some((item) => item.status === "failed") ? "fail" : "ok")}
      </div>
      <div id="diagnosticCommandButtons" class="command-grid diagnostic-command-grid"></div>
      <div class="button-row preview-actions">
        <button id="diagnosticRefreshButton" class="secondary">새로고침</button>
      </div>
    </section>
  `;
  $("diagnosticCommandButtons").replaceChildren(...diagnosticCommands.map((command) => {
    const button = document.createElement("button");
    button.className = `command-button tone-${command.tone}`;
    button.innerHTML = `<span class="command-icon ${escapeHTML(command.iconClass)}" aria-hidden="true"></span><span>${escapeHTML(command.label)}</span>`;
    button.addEventListener("click", () => createCommand(command.kind));
    return button;
  }));
  $("diagnosticRefreshButton").addEventListener("click", () => refreshAll());
}

function renderLoginPanel() {
  const stateLabel = state.status.authDigits
    ? `KAIST 인증 번호 ${state.status.authDigits}`
    : state.status.loginRequired
      ? "KLMS 로그인 필요"
      : "로그인 상태 대기";
  const detail = state.status.authStatusMessage
    || (state.status.authDigits
      ? "Mac에서 Safari/Kaikey 인증을 완료하면 Windows가 다음 상태를 받습니다."
      : state.status.loginRequired
        ? "Mac 앱에서 Safari 로그인을 확인해야 KLMS 동기화가 계속됩니다."
        : "Mac 앱이 KLMS 페이지를 확인하면 로그인 상태가 여기에 표시됩니다.");
  const health = state.status.authDigits || state.status.loginRequired ? "warn" : "unknown";
  $("loginPanel").innerHTML = `
    <section class="section-box">
      <div class="section-heading">
        <h2>로그인</h2>
        <span class="hint">Mac LoginPanel의 원격 상태</span>
      </div>
      <div class="diagnostic-grid">
        ${diagnosticCardHTML("KLMS/Safari", stateLabel, detail, health)}
        ${diagnosticCardHTML("KAIST 인증", state.status.authDigits ? "입력 대기" : "대기", state.status.authDigits ? "인증 번호를 Mac에서 처리해야 합니다." : "추가 인증 요청이 없습니다.", health)}
        ${diagnosticCardHTML("로그인 보조", "Mac 전용", "브라우저 자동화와 계정 저장은 Mac 앱에서 처리하고 Windows는 상태만 표시합니다.", "unknown")}
      </div>
      <div class="button-row preview-actions">
        <button id="loginDoctorButton">진단 요청</button>
        <button id="loginRefreshButton" class="secondary">새로고침</button>
      </div>
    </section>
  `;
  $("loginDoctorButton").addEventListener("click", () => createCommand("doctor"));
  $("loginRefreshButton").addEventListener("click", () => refreshAll());
}

function renderAppDiagnostics() {
  const checks = [
    diagnosticCardHTML("Windows 앱", "정상", "렌더러, 동적 버튼, 섹션 전환을 현재 코드 기준으로 초기화합니다.", "ok"),
    diagnosticCardHTML("릴레이 설정", state.configured ? "저장됨" : "미설정", state.configured ? "서버 주소와 토큰이 저장되어 있습니다." : "설정 탭에서 Mac 앱의 릴레이 정보를 붙여넣으세요.", state.configured ? "ok" : "warn"),
    diagnosticCardHTML("서버 데이터", `${state.items.length}개 항목`, `명령 ${state.recentCommands.length}개 · 항목 처리 ${state.recentActions.length}개`, state.items.length ? "ok" : "unknown"),
    diagnosticCardHTML("표시 필터", activeFilterText(), "년도, 학기, 과목, 새 항목, 최근, 숨김 표시 상태입니다.", hasActiveFilters() ? "running" : "unknown"),
    diagnosticCardHTML("Mac 권한", "원격 진단", "Notes, Calendar, Reminders, Safari, 자동화 권한은 Mac 앱에서 검사합니다.", "unknown")
  ].join("");
  $("appDiagnosticsPanel").innerHTML = `
    <section class="section-box">
      <div class="section-heading">
        <h2>앱 진단</h2>
        <span class="hint">Mac AppDiagnosticsPanel에 해당하는 Windows 점검</span>
      </div>
      <div class="diagnostic-grid">${checks}</div>
      <div class="button-row preview-actions">
        <button id="appDiagnosticsCopyButton" class="secondary">상태 복사</button>
        <button id="appDiagnosticsDoctorButton">진단 요청</button>
      </div>
    </section>
  `;
  $("appDiagnosticsCopyButton").addEventListener("click", copyState);
  $("appDiagnosticsDoctorButton").addEventListener("click", () => createCommand("doctor"));
}

function renderCommandOutputPanels() {
  const html = commandOutputHTML();
  $("dashboardCommandOutput").innerHTML = html;
  $("previewCommandOutput").innerHTML = html;
}

function commandOutputHTML() {
  const latest = state.latestCommand;
  const rows = [
    { label: "최근 명령", value: latest ? commandLabel(latest.kind) : "요청 없음" },
    { label: "명령 상태", value: latest ? commandStatusLabel(latest.status) : "대기" },
    { label: "Mac 실행", value: state.running ? "실행 중" : latestRunChipText() },
    { label: "서버 메시지", value: state.message || latestCommandText() || "표시할 메시지가 없습니다." },
    { label: "최근 갱신", value: latest?.updatedAt || latest?.createdAt || "기록 없음" }
  ];
  return `
    <section class="section-box command-output-panel">
      <div class="section-heading">
        <h2>명령 출력</h2>
        <span class="hint">Mac CommandOutputPanel과 같은 최근 실행 요약</span>
      </div>
      <div class="output-grid">
        ${rows.map((row) => `
          <div class="output-row">
            <span>${escapeHTML(row.label)}</span>
            <strong>${escapeHTML(row.value)}</strong>
          </div>
        `).join("")}
      </div>
    </section>
  `;
}

function renderSettingsMirror() {
  $("settingsMirrorPanel").innerHTML = `
    <section class="section-box">
      <div class="section-heading">
        <h2>Mac 설정 미러</h2>
        <span class="hint">Windows에서 직접 바꿀 수 없는 Mac 전용 설정은 역할과 원격 대응을 보여줍니다.</span>
      </div>
      <div class="settings-mirror-grid">
        ${settingsMirrorHTML("설치", "엔진 위치, 앱 내 엔진 버전, 코드 서명, 엔진 다시 설치", "Windows에서는 표시만 가능하며 실제 설치/서명은 Mac 앱에서 처리합니다.")}
        ${settingsMirrorHTML("로그인", "KAIST 아이디, 로그인 보조, Kaikey 자동, 백그라운드 실행", "로그인 문제는 진단 요청과 상태 배너로 확인합니다.")}
        ${settingsMirrorHTML("실행", "자동 실행, 동기화 주기, Safari 백그라운드 창, 빠른/전체 모드", "Windows는 full/core/notice/files/verify/doctor/report/v2BuildState 원격 요청을 생성합니다.")}
        ${settingsMirrorHTML("iPhone 서버 릴레이", "공유 서버 주소, 토큰, 상태 확인, 원격 요청 큐", "Windows 설정 탭의 서버 릴레이가 이 설정과 같은 역할을 합니다.")}
        ${settingsMirrorHTML("파일", "새 파일 보관함, 격리 폴더, 주차/출처 폴더, 아카이브 보관", "서버가 받은 sanitized 파일 목록과 숨김/복구 요청을 표시합니다.")}
        ${settingsMirrorHTML("공지", "공지 메모명, 확인한 공지 메모명, 읽음/중요 체크리스트", "공지 읽음/중요/숨김 상태를 항목 처리 요청으로 Mac에 보냅니다.")}
        ${settingsMirrorHTML("기타", "백업, 권한 열기, 로그 폴더, 자동화/손쉬운 사용 권한", "Windows에서는 직접 열 수 없고 Mac 진단 요청으로 상태를 확인합니다.")}
      </div>
    </section>
  `;
}

function previewItems() {
  return state.items.filter((item) => {
    if (item.isHidden) {
      return false;
    }
    return ["assignment", "assignmentCandidate", "exam", "examCandidate", "helpDesk", "notice", "file", "quarantine"].includes(item.kind)
      && (isNewItem(item) || isRecentItem(item) || item.kind.includes("Candidate") || item.kind === "quarantine");
  }).slice(0, 80);
}

function previewMetricHTML(label, value, detail) {
  return `<div class="metric-card static"><span>${escapeHTML(label)}</span><strong>${escapeHTML(value)}</strong><span>${escapeHTML(detail)}</span></div>`;
}

function fileMetricHTML(label, value, detail) {
  return `
    <button class="metric-card ${state.selectedFileDetail === detail ? "active" : ""}" data-file-detail="${escapeHTML(detail)}">
      <span>${escapeHTML(label)}</span>
      <strong>${escapeHTML(value)}</strong>
      <span>${escapeHTML(fileDetailOptions.find((option) => option.key === detail)?.label || "")}</span>
    </button>
  `;
}

function previewRowHTML(item) {
  return `
    <div class="preview-row">
      <div class="badges">${badgesHTML(item)}</div>
      <strong>${escapeHTML(item.title || "제목 없음")}</strong>
      <p>${escapeHTML(itemMeta(item))}</p>
    </div>
  `;
}

function fileRowHTML(item) {
  const path = fileSortPathFromItem(item);
  const metadata = [
    itemTermLabel(item),
    item.course,
    item.status || kindTitle(item.kind),
    item.timestamp,
    path && path !== item.title ? path : ""
  ].filter(Boolean).join(" · ");
  return `
    <div class="preview-row file-row">
      <div class="badges">${badgesHTML(item)}</div>
      <strong>${escapeHTML(fileDisplayTitle(item))}</strong>
      <p>${escapeHTML(metadata || "세부 정보 없음")}</p>
      ${item.detail ? `<p>${escapeHTML(item.detail)}</p>` : ""}
    </div>
  `;
}

function fileDetailRows(detail, options = {}) {
  let rows = [];
  if (detail === "newFiles") {
    rows = state.items.filter((item) => item.kind === "file" && isNewFileItem(item));
  } else if (detail === "quarantine") {
    rows = state.items.filter((item) => item.kind === "quarantine");
    if (!rows.length && state.status.quarantine > 0) {
      rows = [syntheticQuarantineItem()];
    }
  } else if (detail === "pruned") {
    rows = prunedItems();
  } else {
    rows = state.items.filter((item) => item.kind === "file");
  }
  return options.filtered ? rows.filter(matchesFilePanelFilters) : rows;
}

function syntheticQuarantineItem() {
  const updatedAt = state.latestCommand?.updatedAt || "";
  return {
    id: "quarantine-summary",
    kind: "quarantine",
    course: "파일 격리",
    title: "격리 파일",
    timestamp: updatedAt,
    status: `${state.status.quarantine}개`,
    detail: "Mac 파일 동기화 결과에 격리 항목이 있습니다.",
    updatedAt
  };
}

function matchesFilePanelFilters(item) {
  if (!hiddenAllowed(item)) {
    return false;
  }
  if (!matchesSelectedYear(item) || !matchesSelectedSemester(item)) {
    return false;
  }
  if (state.selectedCourse !== "all" && normalizedCourseName(item) !== state.selectedCourse) {
    return false;
  }
  if (state.newOnly && !isNewItem(item)) {
    return false;
  }
  if (state.recentOnly && !isRecentItem(item)) {
    return false;
  }
  const query = state.query.trim().toLowerCase();
  if (!query) {
    return true;
  }
  return [item.kind, kindTitle(item.kind), item.course, itemTermLabel(item), item.title, item.status, item.detail, fileSortPathFromItem(item), item.id]
    .join(" ")
    .toLowerCase()
    .includes(query);
}

function sortedFileItems(items) {
  return [...items].sort(compareFileItems);
}

function compareFileItems(lhs, rhs) {
  if (state.fileSort === "recent") {
    const lhsRecent = isNewItem(lhs) || isRecentItem(lhs);
    const rhsRecent = isNewItem(rhs) || isRecentItem(rhs);
    if (lhsRecent !== rhsRecent) {
      return lhsRecent ? -1 : 1;
    }
    return compareTimestamp(rhs.timestamp, lhs.timestamp)
      || compareTimestamp(rhs.updatedAt, lhs.updatedAt)
      || compareText(fileDisplayTitle(lhs), fileDisplayTitle(rhs));
  }
  if (state.fileSort === "kind") {
    return compareText(fileKindLabel(lhs), fileKindLabel(rhs))
      || compareText(lhs.course, rhs.course)
      || compareText(fileDisplayTitle(lhs), fileDisplayTitle(rhs));
  }
  if (state.fileSort === "name") {
    return compareText(fileDisplayTitle(lhs), fileDisplayTitle(rhs))
      || compareText(lhs.course, rhs.course)
      || compareText(fileSortPathFromItem(lhs), fileSortPathFromItem(rhs));
  }
  if (state.fileSort === "path") {
    return compareText(fileSortPathFromItem(lhs), fileSortPathFromItem(rhs))
      || compareText(fileDisplayTitle(lhs), fileDisplayTitle(rhs))
      || compareText(lhs.course, rhs.course);
  }
  return compareText(lhs.course, rhs.course)
    || compareText(fileDisplayTitle(lhs), fileDisplayTitle(rhs))
    || compareText(fileSortPathFromItem(lhs), fileSortPathFromItem(rhs));
}

function isNewFileItem(item) {
  return isNewItem(item) || /new|fresh|download|다운로드|보관함|새 파일/i.test(fileSearchText(item));
}

function fileKindLabel(item) {
  return item.status || kindTitle(item.kind);
}

function fileDisplayTitle(item) {
  const title = String(item.title || "").trim();
  if (title) {
    return title;
  }
  const path = fileSortPathFromItem(item);
  if (!path) {
    return "제목 없음";
  }
  return path.split(/[\\/]/).filter(Boolean).pop() || path;
}

function fileSortPathFromItem(item) {
  return itemPath(item) || String(item.id || "").trim() || String(item.title || "").trim();
}

function fileSearchText(item) {
  return [item.kind, item.course, item.title, item.status, item.detail, item.timestamp, item.updatedAt, fileSortPathFromItem(item), item.id]
    .filter(Boolean)
    .join(" ");
}

function countFileText(items, pattern) {
  return items.filter((item) => pattern.test(fileSearchText(item))).length;
}

function fileEmptyText(detail) {
  if (detail === "newFiles") {
    return "새 파일이 없습니다.";
  }
  if (detail === "quarantine") {
    return "격리 파일이 없습니다.";
  }
  if (detail === "pruned") {
    return "삭제 예정 또는 삭제 기록이 없습니다.";
  }
  return "파일 목록이 없습니다.";
}

function diagnosticCardHTML(title, value, detail, health) {
  return `
    <div class="diagnostic-card ${health}">
      <strong>${escapeHTML(title)}: ${escapeHTML(value || "상태 없음")}</strong>
      <p>${escapeHTML(detail)}</p>
    </div>
  `;
}

function settingsMirrorHTML(title, value, detail) {
  return `
    <div class="settings-mirror-card">
      <strong>${escapeHTML(title)}</strong>
      <p>${escapeHTML(value)}</p>
      <span>${escapeHTML(detail)}</span>
    </div>
  `;
}

function emptyInlineHTML(text) {
  return `<div class="empty-list">${escapeHTML(text)}</div>`;
}

function hasActiveFilters() {
  return state.selectedYear !== "all"
    || state.selectedSemester !== "all"
    || state.selectedCourse !== "all"
    || (state.selectedKind === "notice" && state.noticeCategory !== "all")
    || state.newOnly
    || state.recentOnly
    || state.showHidden
    || Boolean(state.query.trim());
}

function activeFilterText() {
  const filters = [];
  if (state.selectedYear !== "all") {
    filters.push(`${state.selectedYear}년`);
  }
  if (state.selectedSemester !== "all") {
    filters.push(state.selectedSemester);
  }
  if (state.selectedCourse !== "all") {
    filters.push(state.selectedCourse);
  }
  if (state.selectedKind === "notice" && state.noticeCategory !== "all") {
    const category = noticeCategoryOptions.find((option) => option.key === state.noticeCategory);
    filters.push(`공지: ${category?.label || state.noticeCategory}`);
  }
  if (state.newOnly) {
    filters.push("새 항목");
  }
  if (state.recentOnly) {
    filters.push("최근");
  }
  if (state.showHidden) {
    filters.push("숨김 포함");
  }
  if (state.query.trim()) {
    filters.push(`검색: ${state.query.trim()}`);
  }
  return filters.length ? filters.join(" · ") : "필터 없음";
}

function renderHistory() {
  const rows = [];
  if (state.recentCommands.length) {
    rows.push(historySectionTitle("실행 요청"));
  }
  rows.push(...state.recentCommands.map((command) => {
    const row = document.createElement("div");
    row.className = "history-row";
    row.innerHTML = `<div><strong>${escapeHTML(commandLabel(command.kind))}</strong><div class="meta">${escapeHTML(command.updatedAt || command.createdAt || "")}</div></div><span class="status-pill ${commandStatusClass(command.status)}">${escapeHTML(commandStatusLabel(command.status))}</span>`;
    return row;
  }));
  if (state.recentActions.length) {
    rows.push(historySectionTitle("항목 처리"));
  }
  rows.push(...state.recentActions.map((action) => {
    const row = document.createElement("div");
    row.className = "history-row";
    row.innerHTML = `<div><strong>${escapeHTML(actionLabel(action.action))}</strong><div class="meta">${escapeHTML([action.itemTitle, action.updatedAt || action.createdAt, action.message].filter(Boolean).join(" · "))}</div></div><span class="status-pill ${commandStatusClass(action.status)}">${escapeHTML(commandStatusLabel(action.status))}</span>`;
    return row;
  }));
  if (state.recentFileAccess.length) {
    rows.push(historySectionTitle("파일 열기"));
  }
  rows.push(...state.recentFileAccess.map((request) => {
    const row = document.createElement("div");
    row.className = "history-row";
    row.innerHTML = `<div><strong>${escapeHTML(request.itemTitle || "파일")}</strong><div class="meta">${escapeHTML([request.updatedAt || request.createdAt, fileAccessDescription(request)].filter(Boolean).join(" · "))}</div></div><span class="status-pill ${commandStatusClass(request.status)}">${escapeHTML(fileAccessStatusLabel(request.status))}</span>`;
    return row;
  }));
  if (!rows.length) {
    $("historyList").innerHTML = `<div class="empty-list">최근 요청이 없습니다.</div>`;
  } else {
    $("historyList").replaceChildren(...rows);
  }
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
    .filter((item) => matchesDashboardFilters(item))
    .filter(matchesNoticeCategory)
    .filter((item) => {
      if (!query) {
        return true;
      }
      return itemSearchText(item)
        .toLowerCase()
        .includes(query);
    })
    .sort(compareItems);
}

function noticeCategoryCounts() {
  const query = state.query.trim().toLowerCase();
  const counts = Object.fromEntries(noticeCategoryOptions.map((option) => [option.key, 0]));
  state.items
    .filter((item) => item.kind === "notice")
    .filter((item) => matchesDashboardFilters(item))
    .filter((item) => !query || itemSearchText(item).toLowerCase().includes(query))
    .forEach((item) => {
      for (const option of noticeCategoryOptions) {
        if (noticeMatchesCategory(item, option.key)) {
          counts[option.key] += 1;
        }
      }
    });
  return counts;
}

function currentItems() {
  if (state.selectedKind === "calendar") {
    return calendarItems();
  }
  if (state.selectedKind === "pruned") {
    return prunedItems();
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
    return state.showHidden || !item.isHidden;
  }
  if (kind === "assignment") {
    return hiddenAllowed(item) && item.kind === "assignment";
  }
  if (kind === "completedAssignment") {
    return hiddenAllowed(item) && item.kind === "completedAssignment";
  }
  if (kind === "assignmentCandidate") {
    return hiddenAllowed(item) && item.kind === "assignmentCandidate";
  }
  if (kind === "exam") {
    return hiddenAllowed(item) && item.kind === "exam";
  }
  if (kind === "examCandidate") {
    return hiddenAllowed(item) && item.kind === "examCandidate";
  }
  if (kind === "helpDesk") {
    return hiddenAllowed(item) && item.kind === "helpDesk";
  }
  if (kind === "notice") {
    return (hiddenAllowed(item) || state.noticeCategory === "hidden") && item.kind === "notice";
  }
  if (kind === "newFiles") {
    return hiddenAllowed(item) && item.kind === "file" && isNewItem(item);
  }
  if (kind === "quarantine") {
    return hiddenAllowed(item) && item.kind === "quarantine";
  }
  if (kind === "pruned") {
    return item.kind === "pruned";
  }
  if (kind === "calendar") {
    return item.kind === "calendar";
  }
  if (kind === "hidden") {
    return item.isHidden;
  }
  return hiddenAllowed(item) && item.kind === kind;
}

function matchesDashboardFilters(item) {
  if (!matchesSelectedYear(item) || !matchesSelectedSemester(item)) {
    return false;
  }
  if (state.selectedCourse !== "all" && normalizedCourseName(item) !== state.selectedCourse) {
    return false;
  }
  if (state.newOnly && !isNewItem(item)) {
    return false;
  }
  if (state.recentOnly && !isRecentItem(item)) {
    return false;
  }
  return true;
}

function hiddenAllowed(item) {
  return state.showHidden || !item.isHidden;
}

function matchesNoticeCategory(item) {
  if (state.selectedKind !== "notice") {
    return true;
  }
  return noticeMatchesCategory(item, state.noticeCategory);
}

function noticeMatchesCategory(item, category) {
  const hidden = Boolean(item.isHidden);
  const read = Boolean(item.isRead);
  const important = Boolean(item.isImportant);
  const fresh = isNewItem(item);
  switch (category) {
    case "important":
      return important && !hidden;
    case "fresh":
      return fresh && !read && !hidden;
    case "unread":
      return !read && !hidden;
    case "archived":
      return read && !important && !hidden;
    case "hidden":
      return hidden;
    case "all":
    default:
      return !hidden;
  }
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
      title: "삭제된 일정",
      timestamp: updatedAt,
      status: `${state.status.calendarDeleted}개`,
      detail: "최근 동기화에서 더 이상 필요 없어 삭제한 캘린더 일정입니다.",
      updatedAt
    }
  ];
  return rows.filter((item) => Number.parseInt(item.status, 10) > 0);
}

function prunedItems() {
  const updatedAt = state.latestCommand?.updatedAt || "";
  return [
    {
      id: "pruned-active",
      kind: "pruned",
      course: "파일 정리",
      title: "삭제된 파일",
      timestamp: updatedAt,
      status: `${state.status.filePruned}개`,
      detail: "최근 파일 동기화에서 더 이상 추적하지 않아 정리된 파일입니다.",
      updatedAt
    },
    {
      id: "pruned-archive",
      kind: "pruned",
      course: "파일 정리",
      title: "아카이브 정리",
      timestamp: updatedAt,
      status: `${state.status.fileArchivePruned}개`,
      detail: "최근 파일 동기화에서 정리된 아카이브 항목입니다.",
      updatedAt
    }
  ].filter((item) => Number.parseInt(item.status, 10) > 0);
}

function countItems(items, kind) {
  return items.filter((item) => item.kind === kind && !item.isHidden).length;
}

function isNewItem(item) {
  return /new|fresh|새|신규|updated|수정/i.test(`${item.status} ${item.detail}`);
}

function isRecentItem(item) {
  const dates = [item.updatedAt, item.timestamp]
    .map((value) => Date.parse(String(value || "")))
    .filter(Number.isFinite);
  if (!dates.length) {
    return isNewItem(item);
  }
  const newest = Math.max(...dates);
  return Date.now() - newest <= 14 * 24 * 60 * 60 * 1000;
}

function itemSearchText(item) {
  return [item.kind, item.course, itemTermLabel(item), item.title, item.timestamp, item.status, item.detail, itemURL(item), itemPath(item)]
    .join(" ");
}

function itemTermLabel(item) {
  const explicit = item.academicTerm?.displayName || item.academicTerm || item.term || item.semester || "";
  if (explicit) {
    return String(explicit);
  }
  const haystack = [item.course, item.title, item.timestamp, item.detail, itemPath(item)].join(" ");
  const match = haystack.match(/\b(20\d{2})\s*[-_/ ]?\s*(spring|fall|summer|winter|봄|가을|여름|겨울|1학기|2학기)\b/i);
  if (!match) {
    const inferred = inferAcademicTermFromDates([item.timestamp, item.updatedAt]);
    return inferred ? `${inferred.year}년 ${inferred.semester}` : "";
  }
  return `${match[1]}년 ${normalizeSemesterLabel(match[2])}`;
}

function itemTermParts(item) {
  const label = itemTermLabel(item);
  const haystack = [label, item.course, item.title, item.timestamp, item.detail, itemPath(item)].join(" ");
  const year = haystack.match(/\b(20\d{2})\b/)?.[1] || "";
  const semester = normalizeSemesterLabel(
    haystack.match(/(봄학기|가을학기|여름학기|겨울학기|1학기|2학기|spring|fall|summer|winter|봄|가을|여름|겨울)/i)?.[1] || ""
  );
  return { year, semester };
}

function normalizeSemesterLabel(value) {
  const normalized = String(value || "").trim().toLowerCase();
  if (!normalized) {
    return "";
  }
  if (["spring", "봄", "봄학기", "1학기"].includes(normalized)) {
    return "봄학기";
  }
  if (["fall", "autumn", "가을", "가을학기", "2학기"].includes(normalized)) {
    return "가을학기";
  }
  if (["summer", "여름", "여름학기"].includes(normalized)) {
    return "여름학기";
  }
  if (["winter", "겨울", "겨울학기"].includes(normalized)) {
    return "겨울학기";
  }
  return value;
}

function compareSemesterLabels(lhs, rhs) {
  const order = new Map([
    ["봄학기", 0],
    ["여름학기", 1],
    ["가을학기", 2],
    ["겨울학기", 3]
  ]);
  return (order.get(lhs) ?? 99) - (order.get(rhs) ?? 99) || lhs.localeCompare(rhs, "ko");
}

function inferAcademicTermFromDates(values) {
  for (const value of values) {
    const parsed = parseLooseDate(value);
    if (!parsed) {
      continue;
    }
    if (parsed.month >= 3 && parsed.month <= 8) {
      return { year: String(parsed.year), semester: "봄학기" };
    }
    if (parsed.month >= 9 && parsed.month <= 12) {
      return { year: String(parsed.year), semester: "가을학기" };
    }
    if (parsed.month >= 1 && parsed.month <= 2) {
      return { year: String(parsed.year - 1), semester: "가을학기" };
    }
  }
  return null;
}

function parseLooseDate(value) {
  const text = String(value || "");
  if (!text.trim()) {
    return null;
  }
  const explicit = text.match(/\b(20\d{2})\D{0,3}(1[0-2]|0?[1-9])\D{0,3}([0-3]?\d)?/);
  if (explicit) {
    return {
      year: Number.parseInt(explicit[1], 10),
      month: Number.parseInt(explicit[2], 10)
    };
  }
  const date = new Date(text);
  if (!Number.isNaN(date.getTime())) {
    return { year: date.getFullYear(), month: date.getMonth() + 1 };
  }
  return null;
}

function itemURL(item) {
  return String(item.url || item.klmsURL || item.klmsUrl || item.link || "").trim();
}

function itemPath(item) {
  return String(item.path || item.relativePath || item.filePath || "").trim();
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
    default:
      return [];
  }
}

function relevantCommand(kind) {
  if (kind === "notice") {
    return "noticeSync";
  }
  if (["file", "newFiles", "quarantine", "pruned"].includes(kind)) {
    return "filesSync";
  }
  if (["assignment", "completedAssignment", "assignmentCandidate", "exam", "examCandidate", "helpDesk"].includes(kind)) {
    return "coreSync";
  }
  return "fullSync";
}

function badgesHTML(item) {
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
    return `<span class="badge ${klass}">${escapeHTML(badge)}</span>`;
  }).join("");
}

function fieldHTML(label, value, wide = false) {
  const display = String(value || "").trim();
  if (!display) {
    return "";
  }
  return `<div class="field" ${wide ? "style=\"grid-column: 1 / -1\"" : ""}><label>${escapeHTML(label)}</label><div>${escapeHTML(display)}</div></div>`;
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
  if (key === "completedAssignment") {
    return "완료/복구 관리";
  }
  if (key === "assignmentCandidate") {
    return "후보 확인";
  }
  if (key === "examCandidate") {
    return "확정/무시";
  }
  if (key === "helpDesk") {
    return "상담/지원 일정";
  }
  if (key === "calendar") {
    return `생성 ${state.status.calendarCreated} · 수정 ${state.status.calendarUpdated} · 삭제 ${state.status.calendarDeleted}`;
  }
  if (key === "file") {
    return `새 ${state.status.newFiles} · 정리 ${fileCleanupTotal(state.status)}`;
  }
  if (key === "pruned") {
    return `파일 ${state.status.filePruned} · 아카이브 ${state.status.fileArchivePruned}`;
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
  const phase = state.running ? "running" : state.status.phase || "idle";
  if (state.latestCommand && isTerminalStatus(state.latestCommand.status)) {
    return `${commandLabel(state.latestCommand.kind)} · ${commandStatusLabel(state.latestCommand.status)}`;
  }
  if (state.status.authDigits && !isTerminalStatus(phase)) {
    return `KAIST 인증 번호 ${state.status.authDigits}`;
  }
  if (state.running || phase === "running") {
    return "Mac에서 동기화 실행 중";
  }
  if (state.latestCommand) {
    return `${commandLabel(state.latestCommand.kind)} · ${commandStatusLabel(state.latestCommand.status)}`;
  }
  return "서버 릴레이 연결됨";
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
    pruned: "삭제된 파일",
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
    verify: "상태 검사",
    report: "요약 갱신",
    doctor: "권한/환경 진단",
    v2BuildState: "상태 파일 재생성"
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
    fileUnhide: "파일 숨김 해제"
  }[action] || action;
}

function phaseLabel(phase) {
  return {
    idle: "대기",
    pending: "요청 대기",
    running: "실행 중",
    completed: "완료",
    failed: "실패",
    macUnavailable: "Mac 응답 없음"
  }[phase] || phase;
}

function commandStatusLabel(status) {
  return {
    pending: "대기 중",
    running: "실행 중",
    completed: "완료",
    failed: "실패",
    macUnavailable: "Mac 응답 없음"
  }[status] || status || "상태 없음";
}

function fileAccessStatusLabel(status) {
  return {
    pending: "대기 중",
    running: "파일 준비 중",
    completed: "열기 가능",
    failed: "실패",
    macUnavailable: "Mac 응답 없음"
  }[status] || status || "상태 없음";
}

function loadTrackedReportCommandIDs() {
  try {
    return new Set(JSON.parse(localStorage.getItem(trackedReportCommandIDsKey) || "[]"));
  } catch {
    return new Set();
  }
}

function persistTrackedReportCommandIDs() {
  try {
    localStorage.setItem(trackedReportCommandIDsKey, JSON.stringify([...trackedReportCommandIDs]));
  } catch {
    // Desktop notification tracking is best-effort only.
  }
}

function trackReportNotificationIfNeeded(command) {
  if (command?.kind !== "report" || !command.id) {
    return;
  }
  trackedReportCommandIDs.add(command.id);
  persistTrackedReportCommandIDs();
}

function handleReportNotificationUpdates(commands) {
  for (const command of commands) {
    notifyReportRefreshResultIfNeeded(command);
  }
}

function notifyReportRefreshResultIfNeeded(command) {
  if (command?.kind !== "report" || !trackedReportCommandIDs.has(command.id) || !isTerminalStatus(command.status)) {
    return;
  }
  trackedReportCommandIDs.delete(command.id);
  persistTrackedReportCommandIDs();

  const title = command.status === "completed" ? "요약 갱신 완료" : "요약 갱신 실패";
  const summary = command.summary || {};
  const body = command.status === "completed"
    ? `대시보드 요약이 갱신됐습니다. 과제 ${summary.assignments || 0}개 · 시험 ${summary.exams || 0}개 · 새 파일 ${summary.newFiles || 0}개`
    : `Mac 앱에서 요약 갱신이 실패했습니다. ${command.lastExitCode != null ? `종료 코드 ${command.lastExitCode}` : commandStatusLabel(command.status)}`;
  postDesktopNotification(title, body);
}

function postDesktopNotification(title, body) {
  if (!("Notification" in window)) {
    toast(`${title}: ${body}`);
    return;
  }
  if (Notification.permission === "granted") {
    new Notification(title, { body });
    return;
  }
  if (Notification.permission === "denied") {
    toast(`${title}: ${body}`);
    return;
  }
  Notification.requestPermission().then((permission) => {
    if (permission === "granted") {
      new Notification(title, { body });
    } else {
      toast(`${title}: ${body}`);
    }
  }).catch(() => toast(`${title}: ${body}`));
}

function commandStatusClass(status) {
  if (status === "completed") {
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

function updateConnectionState(text, klass) {
  const pill = $("connectionState");
  pill.textContent = text;
  pill.className = `status-pill ${klass || "muted"}`;
}

function setBusy(isBusy) {
  state.busy = isBusy;
  document.querySelectorAll("button").forEach((button) => {
    button.disabled = isBusy;
  });
}

async function copyState() {
  const text = JSON.stringify({
    status: state.status,
    latestCommand: state.latestCommand,
    itemCount: state.items.length
  }, null, 2);
  await navigator.clipboard.writeText(text);
  toast("현재 상태를 복사했습니다.");
}

async function copyItemDetail(item) {
  const text = [
    item.title || "제목 없음",
    item.course ? `과목: ${item.course}` : "",
    item.timestamp ? `시간: ${item.timestamp}` : "",
    item.status ? `상태: ${item.status}` : "",
    item.detail ? `내용: ${item.detail}` : "",
    itemURL(item) ? `URL: ${itemURL(item)}` : "",
    itemPath(item) ? `경로: ${itemPath(item)}` : "",
    `ID: ${item.id}`
  ].filter(Boolean).join("\n");
  await navigator.clipboard.writeText(text);
  toast("항목 상세를 복사했습니다.");
}

function showError(error) {
  const message = error && error.message ? error.message : String(error);
  toast(message);
}

function toast(message) {
  const element = $("toast");
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
  return status === "completed" || status === "failed" || status === "macUnavailable";
}

function escapeHTML(value) {
  return String(value || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}
