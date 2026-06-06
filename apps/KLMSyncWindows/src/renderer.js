const commands = [
  { kind: "fullSync", label: "전체 동기화", icon: "↻" },
  { kind: "coreSync", label: "과제/시험", icon: "✓" },
  { kind: "noticeSync", label: "공지 메모", icon: "⌑" },
  { kind: "filesSync", label: "파일 동기화", icon: "□" },
  { kind: "report", label: "요약 갱신", icon: "↺" },
  { kind: "doctor", label: "진단", icon: "!" }
];

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
  recentCommands: [],
  recentActions: [],
  recentFileAccess: [],
  selectedKind: "all",
  selectedItemId: "",
  sort: "recent",
  query: "",
  relayEventSince: "",
  busy: false
};

const $ = (id) => document.getElementById(id);
let refreshTimer = null;
let realtimeLoopID = 0;

document.addEventListener("DOMContentLoaded", async () => {
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
  $("searchInput").addEventListener("input", (event) => {
    state.query = event.target.value;
    renderItems();
  });
  $("sortSelect").addEventListener("change", (event) => {
    state.sort = event.target.value;
    renderItems();
  });
}

async function loadConfig() {
  try {
    const config = await window.klmsWindows.loadConfig();
    $("relayURL").value = config.relayURL || "";
    $("relayToken").placeholder = config.hasToken ? `저장됨 (${config.tokenPreview})` : "처음 연결하거나 바꿀 때만 입력";
    state.configured = Boolean(config.relayURL && config.hasToken);
    updateConnectionState(state.configured ? "저장됨" : "대기", state.configured ? "ok" : "muted");
    if (state.configured) {
      startRealtimeRefresh();
    } else {
      stopRealtimeRefresh();
    }
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
    startRealtimeRefresh();
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
    state.calendarChanges = [];
    state.recentCommands = [];
    state.recentActions = [];
    state.selectedKind = "all";
    state.selectedItemId = "";
    state.relayEventSince = "";
    stopRealtimeRefresh();
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
  const url = text.match(/https:\/\/[^\s"'<>]+/i)?.[0] || "";
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
    state.items = syncData.items || [];
    state.calendarChanges = syncData.calendarChanges || [];
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

function startRealtimeRefresh() {
  if (!state.configured) {
    stopRealtimeRefresh();
    return;
  }
  const loopID = ++realtimeLoopID;
  runRealtimeRefreshLoop(loopID);
}

function stopRealtimeRefresh() {
  realtimeLoopID += 1;
}

async function runRealtimeRefreshLoop(loopID) {
  while (loopID === realtimeLoopID && state.configured) {
    try {
      const event = await window.klmsWindows.waitForRelayEvent({ since: state.relayEventSince });
      if (loopID !== realtimeLoopID || !state.configured) {
        return;
      }
      if (event?.updatedAt) {
        state.relayEventSince = event.updatedAt;
      }
      updateConnectionState("실시간 연결됨", "ok");
      await refreshAll({ quiet: true, auto: true, realtime: true });
    } catch (error) {
      if (loopID !== realtimeLoopID || !state.configured) {
        return;
      }
      updateConnectionState("실시간 재연결 중", "warn");
      await delay(2000);
    }
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
  if (payload.updatedAt && isNewerTimestamp(payload.updatedAt, state.relayEventSince)) {
    state.relayEventSince = payload.updatedAt;
  }
}

function delay(milliseconds) {
  return new Promise((resolve) => window.setTimeout(resolve, milliseconds));
}

function isNewerTimestamp(candidate, current) {
  const candidateEpoch = Date.parse(candidate || "");
  const currentEpoch = Date.parse(current || "");
  if (!Number.isFinite(candidateEpoch)) {
    return false;
  }
  if (!Number.isFinite(currentEpoch)) {
    return true;
  }
  return candidateEpoch > currentEpoch;
}

async function createCommand(kind) {
  try {
    setBusy(true);
    await window.klmsWindows.relayRequest({
      path: "/v1/commands",
      method: "POST",
      body: {
        kind,
        options: {
          updateNoticeNotes: $("updateNoticeNotes")?.checked !== false
        }
      }
    });
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
    const message = itemActionMessage(action, item);
    if (message === null) {
      return;
    }
    setBusy(true);
    await window.klmsWindows.relayRequest({
      path: "/v1/item-actions",
      method: "POST",
      body: {
        action,
        itemID: item.id,
        itemKind: item.kind,
        itemTitle: item.title,
        message
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

function itemActionMessage(action, item) {
  if (action !== "calendarEdit") {
    return "";
  }
  const title = window.prompt("캘린더 제목", item.title || "");
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
  const location = window.prompt("장소 (비워 두면 변경하지 않음)", item.location || "");
  if (location === null) {
    return null;
  }
  if (![title, startAt, dueAt, location].some((value) => String(value || "").trim())) {
    showError(new Error("수정할 캘린더 내용이 없습니다."));
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
  renderDashboard();
  renderItems();
  renderDetail();
  renderHistory();
}

function renderCommands() {
  $("commandButtons").replaceChildren(...commands.map((command) => {
    const button = document.createElement("button");
    button.className = "secondary";
    button.textContent = `${command.icon} ${command.label}`;
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
  $("statusSubtitle").textContent = state.message || runningPhaseDetail() || latestCommandText() || "대기 중인 서버 요청이 없습니다.";

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

function renderDetail() {
  const item = currentItems().find((candidate) => candidate.id === state.selectedItemId);
  if (!item) {
    $("itemDetail").className = "empty-detail";
    $("itemDetail").innerHTML = "<h2>항목을 선택하세요</h2><p>대시보드 카드나 왼쪽 목록을 누르면 상세와 처리 버튼이 표시됩니다.</p>";
    return;
  }
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
      ${fieldHTML("첨부", item.attachmentCount > 0 ? `${item.attachmentCount}개` : "")}
      ${fieldHTML("서버 갱신", item.updatedAt)}
      ${fieldHTML("세부 내용", item.detail, true)}
      ${fieldHTML("식별자", item.id, true)}
    </div>
    <div class="action-section">
      <h3>항목 처리</h3>
      <div class="action-grid" id="detailActions"></div>
    </div>
    ${item.kind === "file" ? `
      <div class="action-section">
        <h3>파일 열기</h3>
        ${fileAccess ? `<p class="hint"><strong>${escapeHTML(commandStatusLabel(fileAccess.status))}</strong> · ${escapeHTML(fileAccessDescription(fileAccess))}</p>` : `<p class="hint">Mac이 보관 중인 course_files 원본을 임시 서버 링크로 준비할 수 있습니다.</p>`}
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
    row.innerHTML = `<div><strong>${escapeHTML(request.itemTitle || "파일")}</strong><div class="meta">${escapeHTML([request.updatedAt || request.createdAt, fileAccessDescription(request)].filter(Boolean).join(" · "))}</div></div><span class="status-pill ${commandStatusClass(request.status)}">${escapeHTML(commandStatusLabel(request.status))}</span>`;
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
        { title: "내용 수정", action: "calendarEdit" }
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
  return "서버 릴레이 연결됨";
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
    calendarEdit: "캘린더 내용 수정",
    calendarDelete: "KLMS 기준 반영"
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
