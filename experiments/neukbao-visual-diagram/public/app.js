/* Neukbao Visual Diagram viewer — vanilla JS + SVG, no dependencies. */
(function () {
  "use strict";

  const SVG_NS = "http://www.w3.org/2000/svg";
  const EDGE_TYPES = ["contains", "invokes", "imports", "packages", "tests", "communicates"];
  const EDGE_STYLE = {
    contains: { label: "contains", desc: "디렉터리/컴포넌트가 하위를 포함", dash: "" },
    invokes: { label: "invokes", desc: "스크립트 실행·exec·subprocess 호출", dash: "" },
    imports: { label: "imports", desc: "import / require / source", dash: "dashed" },
    packages: { label: "packages", desc: "패키지/번들/allowlist에 포함", dash: "dotted" },
    tests: { label: "tests", desc: "테스트가 대상 모듈을 검증", dash: "double" },
    communicates: { label: "communicates", desc: "HTTP/WebSocket 경로 공유", dash: "" },
  };
  const CONFIDENCES = ["high", "medium", "low"];
  const KIND_LABEL = { system: "System", component: "Component", directory: "Directory", file: "File" };

  const TILE_W = 236, TILE_H = 118, GAP_X = 96, GAP_Y = 120;
  const FILE_W = 236, FILE_H = 30, DIR_PAD = 12, DIR_HEAD = 30, ITEM_GAP = 6, COL_GAP = 14;
  const STUB_W = 210, STUB_H = 50, STUB_GAP = 14;

  const state = {
    graph: null,
    nodes: new Map(),
    children: new Map(),
    edgesBySource: new Map(),
    edgesByTarget: new Map(),
    edgesById: new Map(),
    viewMode: "graph", // graph | matrix | treemap | sunburst
    level: 0,
    focusComponent: null, // component node id in L2
    drillFocus: "system", // treemap / sunburst focus node id
    sizeMetric: "files", // files | commits
    selected: null, // {kind:'node'|'edge', id}
    keyboardFocus: null, // node id
    filters: { languages: new Set(), edgeTypes: new Set(EDGE_TYPES.filter((t) => t !== "contains")), confidences: new Set(CONFIDENCES) },
    allLanguages: [],
    layoutCache: new Map(),
    view: { x: 0, y: 0, k: 1 },
    visibleNodeIds: [],
    positions: new Map(), // node id -> {x,y,w,h}
    cells: new Map(), // matrix cell id -> selection record
    matrixBands: null, // {row, col} crosshair rects of the current matrix render
  };

  const $ = (sel) => document.querySelector(sel);
  const svg = $("#svg");
  const viewport = $("#viewport");
  const edgesLayer = $("#edges-layer");
  const nodesLayer = $("#nodes-layer");
  const labelsLayer = $("#labels-layer");

  // ------------------------------------------------------------------ utils
  function el(tag, attrs, children) {
    const node = document.createElementNS(SVG_NS, tag);
    if (attrs) for (const [k, v] of Object.entries(attrs)) if (v !== undefined && v !== null) node.setAttribute(k, v);
    if (children) for (const c of children) node.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    return node;
  }
  function h(tag, attrs, children) {
    const node = document.createElement(tag);
    if (attrs) for (const [k, v] of Object.entries(attrs)) {
      if (k === "class") node.className = v;
      else if (k === "text") node.textContent = v;
      else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
      else if (v !== undefined && v !== null && v !== false) node.setAttribute(k, v === true ? "" : v);
    }
    if (children) for (const c of children) if (c !== null && c !== undefined) node.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    return node;
  }
  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }
  function fmtDate(iso) {
    if (!iso) return "—";
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return iso;
    return d.toISOString().slice(0, 10);
  }
  function relDate(iso) {
    if (!iso) return "";
    const days = Math.round((Date.now() - new Date(iso).getTime()) / 86400000);
    if (days < 1) return "오늘";
    if (days < 30) return `${days}일 전`;
    if (days < 365) return `${Math.round(days / 30)}개월 전`;
    return `${(days / 365).toFixed(1)}년 전`;
  }
  function truncate(text, max) {
    if (!text) return "";
    return text.length > max ? text.slice(0, max - 1) + "…" : text;
  }
  function textWidth(text, size) {
    let w = 0;
    for (const ch of text) w += /[ᄀ-ᇿ㄰-㆏가-힯一-鿿]/.test(ch) ? size * 0.98 : size * 0.58;
    return w;
  }
  function fitText(text, size, maxWidth) {
    if (textWidth(text, size) <= maxWidth) return text;
    let out = text;
    while (out.length > 1 && textWidth(out + "…", size) > maxWidth) out = out.slice(0, -1);
    return out + "…";
  }
  function componentOf(nodeId) {
    const node = state.nodes.get(nodeId);
    if (!node) return null;
    if (node.kind === "component") return node.id;
    if (node.component_id) return `component:${node.component_id}`;
    return null;
  }
  function intensity(count, max) {
    if (!count || !max) return 0;
    return Math.min(1, Math.log1p(count) / Math.log1p(max));
  }

  // ------------------------------------------------------------------ load
  async function load() {
    const res = await fetch("./graph.json", { cache: "no-store" });
    if (!res.ok) throw new Error(`graph.json ${res.status}`);
    const graph = await res.json();
    state.graph = graph;
    for (const n of graph.nodes) state.nodes.set(n.id, n);
    for (const n of graph.nodes) {
      if (n.parent_id) {
        if (!state.children.has(n.parent_id)) state.children.set(n.parent_id, []);
        state.children.get(n.parent_id).push(n.id);
      }
    }
    for (const list of state.children.values()) {
      list.sort((a, b) => {
        const na = state.nodes.get(a), nb = state.nodes.get(b);
        if (na.kind !== nb.kind) return na.kind === "directory" ? -1 : 1;
        return na.label.localeCompare(nb.label);
      });
    }
    for (const e of graph.edges) {
      state.edgesById.set(e.id, e);
      if (!state.edgesBySource.has(e.source)) state.edgesBySource.set(e.source, []);
      if (!state.edgesByTarget.has(e.target)) state.edgesByTarget.set(e.target, []);
      state.edgesBySource.get(e.source).push(e);
      state.edgesByTarget.get(e.target).push(e);
    }
    state.allLanguages = Object.keys(graph.meta.languages || {});
    state.filters.languages = new Set(state.allLanguages);
    state.maxFileCommits = Math.max(1, ...graph.nodes.filter((n) => n.kind === "file").map((n) => n.commit_count || 0));
    state.maxComponentCommits = Math.max(1, ...graph.nodes.filter((n) => n.kind === "component").map((n) => n.commit_count || 0));
    renderMeta();
    renderFilters();
    renderLegend();
    render();
    fitView();
  }

  function renderMeta() {
    const m = state.graph.meta;
    $("#repo-title").textContent = m.repository_name || "repository";
    const commitEl = $("#meta-commit");
    commitEl.textContent = m.source_commit.slice(0, 12);
    commitEl.title = `${m.source_commit} (${m.source_branch})`;
    if (m.worktree_dirty) {
      commitEl.insertAdjacentElement("afterend", h("span", { class: "dirty", title: "분석 당시 worktree에 커밋되지 않은 변경이 있었다", text: " dirty" }));
    }
    $("#meta-files").textContent = `${m.tracked_file_count} files`;
    $("#meta-generated").textContent = fmtDate(m.generated_at);
  }

  // ------------------------------------------------------------------ filters / legend
  function renderFilters() {
    const langBox = $("#language-filter");
    clear(langBox);
    const langs = state.graph.meta.languages || {};
    for (const [lang, count] of Object.entries(langs)) {
      langBox.appendChild(checkbox(lang, `${lang}`, count, state.filters.languages.has(lang), (on) => {
        if (on) state.filters.languages.add(lang); else state.filters.languages.delete(lang);
        render();
      }));
    }
    const typeBox = $("#edge-type-filter");
    clear(typeBox);
    const typeCounts = {};
    for (const e of state.graph.edges) typeCounts[e.type] = (typeCounts[e.type] || 0) + 1;
    for (const t of EDGE_TYPES) {
      if (t === "contains") continue; // containment is the tree itself, not a toggleable line
      const sw = h("span", { class: `swatch swatch--${EDGE_STYLE[t].dash}`, style: `border-color: var(--edge-${t})` });
      typeBox.appendChild(checkbox(`type-${t}`, t, typeCounts[t] || 0, state.filters.edgeTypes.has(t), (on) => {
        if (on) state.filters.edgeTypes.add(t); else state.filters.edgeTypes.delete(t);
        render();
      }, sw));
    }
    const confBox = $("#confidence-filter");
    clear(confBox);
    const confCounts = {};
    for (const e of state.graph.edges) if (e.type !== "contains") confCounts[e.confidence] = (confCounts[e.confidence] || 0) + 1;
    for (const c of CONFIDENCES) {
      confBox.appendChild(checkbox(`conf-${c}`, c, confCounts[c] || 0, state.filters.confidences.has(c), (on) => {
        if (on) state.filters.confidences.add(c); else state.filters.confidences.delete(c);
        render();
      }));
    }
  }
  function checkbox(id, label, count, checked, onChange, swatch) {
    const input = h("input", { type: "checkbox", id: `f-${id.replace(/[^\w-]/g, "_")}` });
    input.checked = checked;
    input.addEventListener("change", () => onChange(input.checked));
    return h("label", { for: input.id }, [input, swatch || null, h("span", { text: label }), h("span", { class: "count", text: String(count) })]);
  }
  function renderLegend() {
    const ul = $("#legend");
    clear(ul);
    for (const t of EDGE_TYPES) {
      ul.appendChild(h("li", null, [
        h("span", { class: `line line--${EDGE_STYLE[t].dash}`, style: `border-color: var(--edge-${t})` }),
        h("span", null, [h("strong", { text: t }), " ", h("span", { class: "help", text: EDGE_STYLE[t].desc })]),
      ]));
    }
    ul.appendChild(h("li", null, [h("span", { class: "pill pill--high", text: "high" }), h("span", { class: "help", text: "파일 내용에서 직접 확인" })]));
    ul.appendChild(h("li", null, [h("span", { class: "pill pill--medium", text: "medium" }), h("span", { class: "help", text: "경로 문자열/공유 패턴에서 추정" })]));
    ul.appendChild(h("li", null, [h("span", { class: "pill pill--low", text: "low" }), h("span", { class: "help", text: "이름만 일치" })]));
  }

  // ------------------------------------------------------------------ layout
  function componentNodes() {
    return (state.children.get("system") || []).map((id) => state.nodes.get(id));
  }
  function componentGridLayout() {
    if (state.layoutCache.has("L1")) return state.layoutCache.get("L1");
    const comps = componentNodes();
    const pos = new Map();
    const used = new Set();
    let maxCol = 0, maxRow = 0;
    for (const c of comps) {
      const l = c.layout || {};
      let col = Number.isInteger(l.col) ? l.col : 0, row = Number.isInteger(l.row) ? l.row : 0;
      while (used.has(`${col},${row}`)) col += 1;
      used.add(`${col},${row}`);
      pos.set(c.id, { col, row });
      maxCol = Math.max(maxCol, col); maxRow = Math.max(maxRow, row);
    }
    const positions = new Map();
    for (const [id, { col, row }] of pos) {
      positions.set(id, { x: 60 + col * (TILE_W + GAP_X), y: 80 + row * (TILE_H + GAP_Y), w: TILE_W, h: TILE_H, row });
    }
    const layout = { positions, width: 60 * 2 + (maxCol + 1) * TILE_W + maxCol * GAP_X, height: 80 * 2 + (maxRow + 1) * TILE_H + maxRow * GAP_Y };
    state.layoutCache.set("L1", layout);
    return layout;
  }

  function measure(nodeId) {
    const node = state.nodes.get(nodeId);
    if (node.kind === "file") return { w: FILE_W, h: FILE_H };
    const kids = state.children.get(nodeId) || [];
    const sizes = kids.map((k) => ({ id: k, ...measure(k) }));
    // column packing: keep columns under a target height
    const tallest = Math.max(FILE_H, ...sizes.map((s) => s.h));
    const total = sizes.reduce((a, s) => a + s.h + ITEM_GAP, 0);
    const targetCols = Math.max(1, Math.min(4, Math.ceil(total / 520)));
    const targetH = Math.max(tallest, Math.ceil(total / targetCols));
    const cols = [[]];
    let colH = 0;
    for (const s of sizes) {
      if (colH > 0 && colH + s.h > targetH) { cols.push([]); colH = 0; }
      cols[cols.length - 1].push(s);
      colH += s.h + ITEM_GAP;
    }
    const colWidths = cols.map((c) => Math.max(FILE_W, ...c.map((s) => s.w)));
    const colHeights = cols.map((c) => c.reduce((a, s) => a + s.h + ITEM_GAP, -ITEM_GAP));
    const w = DIR_PAD * 2 + colWidths.reduce((a, b) => a + b, 0) + COL_GAP * (cols.length - 1);
    const hgt = DIR_HEAD + DIR_PAD + Math.max(0, ...colHeights);
    return { w, h: hgt, cols, colWidths };
  }
  function place(nodeId, x, y, positions) {
    const node = state.nodes.get(nodeId);
    const m = measure(nodeId);
    positions.set(nodeId, { x, y, w: m.w, h: m.h });
    if (node.kind === "file") return;
    let cx = x + DIR_PAD;
    m.cols.forEach((col, i) => {
      let cy = y + DIR_HEAD;
      for (const s of col) {
        place(s.id, cx, cy, positions);
        cy += s.h + ITEM_GAP;
      }
      cx += m.colWidths[i] + COL_GAP;
    });
  }
  function componentDetailLayout(componentId) {
    const key = `L2:${componentId}`;
    if (state.layoutCache.has(key)) return state.layoutCache.get(key);
    const positions = new Map();
    place(componentId, 60, 80, positions);
    const main = positions.get(componentId);
    // external component stubs on the right, ordered by number of file-level edges
    const counts = new Map();
    for (const e of state.graph.edges) {
      if (e.level !== "file" || e.type === "contains") continue;
      const sc = componentOf(e.source), tc = componentOf(e.target);
      if (sc === componentId && tc && tc !== componentId) counts.set(tc, (counts.get(tc) || 0) + 1);
      if (tc === componentId && sc && sc !== componentId) counts.set(sc, (counts.get(sc) || 0) + 1);
    }
    const stubs = [...counts.entries()].sort((a, b) => b[1] - a[1]).map(([id]) => id);
    const stubX = main.x + main.w + 160;
    let sy = main.y;
    for (const id of stubs) {
      positions.set(id, { x: stubX, y: sy, w: STUB_W, h: STUB_H, stub: true });
      sy += STUB_H + STUB_GAP;
    }
    const layout = { positions, stubs, width: stubX + STUB_W + 60, height: Math.max(main.y + main.h, sy) + 60 };
    state.layoutCache.set(key, layout);
    return layout;
  }

  // ------------------------------------------------------------------ geometry
  function center(p) { return { x: p.x + p.w / 2, y: p.y + p.h / 2 }; }
  function boundaryPoint(p, toward) {
    const c = center(p);
    const dx = toward.x - c.x, dy = toward.y - c.y;
    if (dx === 0 && dy === 0) return c;
    const hw = p.w / 2, hh = p.h / 2;
    const sx = Math.abs(dx) > 0 ? hw / Math.abs(dx) : Infinity;
    const sy = Math.abs(dy) > 0 ? hh / Math.abs(dy) : Infinity;
    const s = Math.min(sx, sy);
    return { x: c.x + dx * s, y: c.y + dy * s };
  }
  function edgePath(a, b, offset) {
    const ca = center(a), cb = center(b);
    const pa = boundaryPoint(a, cb), pb = boundaryPoint(b, ca);
    const dx = pb.x - pa.x, dy = pb.y - pa.y;
    const len = Math.hypot(dx, dy) || 1;
    const nx = -dy / len, ny = dx / len;
    const o = offset || 0;
    const mx = (pa.x + pb.x) / 2 + nx * o, my = (pa.y + pb.y) / 2 + ny * o;
    const bend = Math.min(60, len * 0.25);
    const c1x = pa.x + dx * 0.3 + nx * (o + bend * 0.3), c1y = pa.y + dy * 0.3 + ny * (o + bend * 0.3);
    const c2x = pb.x - dx * 0.3 + nx * (o + bend * 0.3), c2y = pb.y - dy * 0.3 + ny * (o + bend * 0.3);
    return { d: `M${pa.x},${pa.y} C${c1x},${c1y} ${c2x},${c2y} ${pb.x},${pb.y}`, mid: { x: mx, y: my } };
  }

  // ------------------------------------------------------------------ edge visibility
  function edgeVisible(e) {
    if (!state.filters.edgeTypes.has(e.type)) return false;
    if (e.type !== "contains" && !state.filters.confidences.has(e.confidence)) return false;
    return true;
  }
  function nodeMatchesLanguage(node) {
    if (state.filters.languages.size === state.allLanguages.length) return true;
    if (node.kind === "file") return node.language ? state.filters.languages.has(node.language) : false;
    const langs = node.languages || {};
    return Object.keys(langs).some((l) => state.filters.languages.has(l));
  }

  // ------------------------------------------------------------------ render
  function render() {
    clear(edgesLayer); clear(nodesLayer); clear(labelsLayer);
    svg.removeAttribute("aria-activedescendant");
    state.positions = new Map();
    state.visibleNodeIds = [];
    state.matrixBands = null;
    if (state.viewMode === "matrix") renderMatrix();
    else if (state.viewMode === "treemap") renderTreemap();
    else if (state.viewMode === "sunburst") renderSunburst();
    else if (state.level <= 1) renderComponentLevel();
    else renderFileLevel();
    updateChrome();
    applySelectionClasses();
    if (state.keyboardFocus && state.visibleNodeIds.includes(state.keyboardFocus) && document.activeElement === svg) setActiveDescendant(state.keyboardFocus);
  }
  function setActiveDescendant(id) {
    const g = nodesLayer.querySelector(`.node[data-id="${CSS.escape(id)}"]`);
    if (!g) { svg.removeAttribute("aria-activedescendant"); return null; }
    if (!g.id) g.id = "node-" + id.replace(/[^\w-]+/g, "_");
    svg.setAttribute("aria-activedescendant", g.id);
    return g;
  }

  function renderComponentLevel() {
    const layout = componentGridLayout();
    const comps = componentNodes();
    // system frame
    const frame = el("rect", { x: 20, y: -10, width: layout.width - 40, height: layout.height - 10, class: "system-frame", rx: 14, "pointer-events": "none" });
    nodesLayer.appendChild(frame);
    const sys = state.nodes.get("system");
    const sysLabel = el("g", { class: "node node--system", "data-id": "system", tabindex: -1, role: "button", "aria-label": `${sys.label} 시스템` });
    sysLabel.appendChild(el("rect", { x: 32, y: 0, width: 360, height: 40, class: "node__box" }));
    sysLabel.appendChild(el("text", { x: 44, y: 18, class: "node__badge" }, ["System"]));
    sysLabel.appendChild(el("text", { x: 44, y: 33, class: "node__label" }, [fitText(`${sys.label} · ${state.graph.meta.tracked_file_count} tracked files`, 13, 340)]));
    sysLabel.addEventListener("click", () => select({ kind: "node", id: "system" }));
    nodesLayer.appendChild(sysLabel);
    state.positions.set("system", { x: 32, y: 0, w: 360, h: 40 });
    state.visibleNodeIds.push("system");

    const ROW_CAPTIONS = ["사용자 앱 · 원격 릴레이", "동기화 엔진 (왼쪽에서 오른쪽으로 실행 흐름)", "지원 계층 · 빌드 · 검증 · 문서"];
    ROW_CAPTIONS.forEach((caption, row) => {
      if (![...layout.positions.values()].some((p) => p.row === row)) return;
      labelsLayer.appendChild(el("text", { x: 60, y: 80 + row * (TILE_H + GAP_Y) - 14, class: "section-title" }, [caption]));
    });
    for (const c of comps) {
      const p = layout.positions.get(c.id);
      state.positions.set(c.id, p);
      state.visibleNodeIds.push(c.id);
      nodesLayer.appendChild(componentTile(c, p, false));
    }
    if (state.level === 1) renderComponentEdges(layout);
    else renderOverviewEdges(layout);
  }

  function componentTile(c, p, stub) {
    const g = el("g", { class: `node node--component${stub ? " node--stub" : ""}${nodeMatchesLanguage(c) ? "" : " node--dimmed"}`, "data-id": c.id, tabindex: -1, role: "button",
      "aria-label": `${c.label}, 파일 ${c.file_count}개, 커밋 ${c.commit_count}회` });
    g.appendChild(el("rect", { x: p.x, y: p.y, width: p.w, height: p.h, class: "node__box" }));
    const t = intensity(c.commit_count, state.maxComponentCommits);
    g.appendChild(el("rect", { x: p.x, y: p.y, width: 5, height: p.h, class: "node__intensity", opacity: 0.15 + t * 0.85, rx: 0 }));
    g.appendChild(el("text", { x: p.x + 16, y: p.y + 18, class: "node__badge" }, [stub ? "component (external)" : "component"]));
    if (!stub) g.appendChild(el("text", { x: p.x + 16, y: p.y + 40, class: "node__label" }, [fitText(c.label, 13, p.w - 30)]));
    if (!stub) {
      const langs = Object.entries(c.languages || {}).slice(0, 3).map(([l, n]) => `${l} ${n}`).join(" · ");
      g.appendChild(el("text", { x: p.x + 16, y: p.y + 60, class: "node__sub" }, [fitText(truncate(c.description, 80), 11, p.w - 30)]));
      g.appendChild(el("text", { x: p.x + 16, y: p.y + 80, class: "node__lang" }, [fitText(langs, 10, p.w - 30)]));
      g.appendChild(el("text", { x: p.x + 16, y: p.y + 100, class: "node__mono" }, [`${c.file_count} files · ${c.commit_count} commits · ${relDate(c.last_changed_at)}`]));
    } else {
      g.appendChild(el("text", { x: p.x + 16, y: p.y + 36, class: "node__label" }, [fitText(c.label, 12, p.w - 30)]));
    }
    g.addEventListener("click", () => select({ kind: "node", id: c.id }));
    return g;
  }

  function componentEdges() {
    return state.graph.edges.filter((e) => e.level === "component");
  }
  function renderOverviewEdges(layout) {
    // L0: only the strongest structural flow — invokes/imports/communicates, high+medium
    const edges = componentEdges().filter((e) => ["invokes", "imports", "communicates"].includes(e.type) && e.confidence !== "low" && edgeVisible(e));
    drawEdgeSet(edges, layout.positions, { labels: false });
  }
  function renderComponentEdges(layout) {
    const edges = componentEdges().filter(edgeVisible);
    drawEdgeSet(edges, layout.positions, { labels: true });
  }

  function drawEdgeSet(edges, positions, opts) {
    // group parallel edges between same pair for offsets
    const pairIndex = new Map();
    for (const e of edges) {
      const key = [e.source, e.target].sort().join("|");
      if (!pairIndex.has(key)) pairIndex.set(key, []);
      pairIndex.get(key).push(e);
    }
    for (const list of pairIndex.values()) {
      list.forEach((e, i) => {
        const a = positions.get(e.source), b = positions.get(e.target);
        if (!a || !b) return;
        const offset = (i - (list.length - 1) / 2) * 14;
        const reversed = e.source > e.target;
        const path = edgePath(a, b, reversed ? -offset : offset);
        const g = el("g", { class: "edge-group", "data-id": e.id });
        g.appendChild(el("path", { d: path.d, class: "edge-hit" }));
        g.appendChild(el("path", { d: path.d, class: `edge edge--${e.type} edge--${e.confidence}`, "marker-end": "url(#arrow)", "data-id": e.id }));
        g.addEventListener("click", (ev) => { ev.stopPropagation(); select({ kind: "edge", id: e.id }); });
        edgesLayer.appendChild(g);
        if (opts.labels) {
          const text = e.member_edge_count ? `${e.type} ×${e.member_edge_count}` : e.type;
          const w = textWidth(text, 10) + 8;
          const lg = el("g", { class: "edge-label", "data-id": e.id });
          lg.appendChild(el("rect", { x: path.mid.x - w / 2, y: path.mid.y - 8, width: w, height: 15, rx: 3, class: "edge__label-bg" }));
          lg.appendChild(el("text", { x: path.mid.x, y: path.mid.y + 3, class: "edge__label", "text-anchor": "middle" }, [text]));
          labelsLayer.appendChild(lg);
        }
      });
    }
  }

  function renderFileLevel() {
    const compId = state.focusComponent;
    const comp = state.nodes.get(compId);
    const layout = componentDetailLayout(compId);
    for (const [id, p] of layout.positions) state.positions.set(id, p);
    // draw focused component box + nested dirs/files
    drawTree(compId, layout.positions, true);
    for (const stubId of layout.stubs) {
      const c = state.nodes.get(stubId);
      const p = layout.positions.get(stubId);
      nodesLayer.appendChild(componentTile(c, p, true));
      state.visibleNodeIds.push(stubId);
    }
    // edges: file-level edges with at least one endpoint in this component (excluding contains)
    const inside = new Set([...layout.positions.keys()].filter((id) => componentOf(id) === compId));
    const edges = [];
    for (const e of state.graph.edges) {
      if (e.level === "component" || e.type === "contains" || !edgeVisible(e)) continue;
      const sIn = inside.has(e.source), tIn = inside.has(e.target);
      if (!sIn && !tIn) continue;
      edges.push(e);
    }
    const pairIndex = new Map();
    for (const e of edges) {
      const s = state.positions.has(e.source) ? e.source : componentOf(e.source);
      const t = state.positions.has(e.target) ? e.target : componentOf(e.target);
      if (!s || !t || s === t) continue;
      const key = `${s}|${t}|${e.type}`;
      if (!pairIndex.has(key)) pairIndex.set(key, { s, t, type: e.type, edges: [] });
      pairIndex.get(key).edges.push(e);
    }
    const pairGroups = new Map();
    for (const grp of pairIndex.values()) {
      const key = [grp.s, grp.t].sort().join("|");
      if (!pairGroups.has(key)) pairGroups.set(key, []);
      pairGroups.get(key).push(grp);
    }
    for (const grp of pairIndex.values()) {
      const a = state.positions.get(grp.s), b = state.positions.get(grp.t);
      if (!a || !b) continue;
      const siblings = pairGroups.get([grp.s, grp.t].sort().join("|"));
      const idx = siblings.indexOf(grp);
      const offset = (idx - (siblings.length - 1) / 2) * 14 * (grp.s > grp.t ? -1 : 1);
      const best = grp.edges.reduce((acc, e) => (CONFIDENCES.indexOf(e.confidence) < CONFIDENCES.indexOf(acc.confidence) ? e : acc), grp.edges[0]);
      const path = edgePath(a, b, offset);
      const g = el("g", { class: "edge-group", "data-id": best.id });
      g.appendChild(el("path", { d: path.d, class: "edge-hit" }));
      g.appendChild(el("path", { d: path.d, class: `edge edge--${grp.type} edge--${best.confidence}`, "marker-end": "url(#arrow)", "data-id": best.id, "data-members": grp.edges.map((e) => e.id).join(" ") }));
      g.addEventListener("click", (ev) => { ev.stopPropagation(); select({ kind: "edge", id: best.id, members: grp.edges.map((e) => e.id) }); });
      edgesLayer.appendChild(g);
    }
    $("#canvas-status").textContent = `${comp.label}: 파일 ${comp.file_count}개, 표시 중인 관계 ${pairIndex.size}개 (원본 edge ${edges.length}개)`;
  }

  function drawTree(nodeId, positions, isRoot) {
    const node = state.nodes.get(nodeId);
    const p = positions.get(nodeId);
    state.visibleNodeIds.push(nodeId);
    const dimmed = !nodeMatchesLanguage(node);
    if (node.kind === "file") {
      const g = el("g", { class: `node node--file${dimmed ? " node--dimmed" : ""}`, "data-id": nodeId, tabindex: -1, role: "button", "aria-label": `${node.path}, ${node.language || ""}, 커밋 ${node.commit_count}회` });
      g.appendChild(el("rect", { x: p.x, y: p.y, width: p.w, height: p.h, class: "node__box" }));
      const t = intensity(node.commit_count, state.maxFileCommits);
      g.appendChild(el("rect", { x: p.x, y: p.y, width: 4, height: p.h, class: "node__intensity", opacity: 0.15 + t * 0.85 }));
      g.appendChild(el("text", { x: p.x + 12, y: p.y + 19, class: "node__label" }, [fitText(node.label, 12, p.w - 90)]));
      g.appendChild(el("text", { x: p.x + p.w - 8, y: p.y + 19, class: "node__lang", "text-anchor": "end" }, [fitText(`${node.language || ""} · ${node.commit_count}`, 10, 76)]));
      g.addEventListener("click", (ev) => { ev.stopPropagation(); select({ kind: "node", id: nodeId }); });
      nodesLayer.appendChild(g);
      return;
    }
    const g = el("g", { class: `node node--${node.kind}${dimmed ? " node--dimmed" : ""}`, "data-id": nodeId, tabindex: -1, role: "button", "aria-label": `${node.label}, 파일 ${node.file_count}개` });
    g.appendChild(el("rect", { x: p.x, y: p.y, width: p.w, height: p.h, class: "node__box" }));
    g.appendChild(el("text", { x: p.x + 12, y: p.y + 19, class: isRoot ? "node__label" : "node__mono" }, [fitText(isRoot ? `${node.label} · ${node.file_count} files · ${node.commit_count} commits` : `${node.path}/ (${node.file_count})`, isRoot ? 13 : 11, p.w - 24)]));
    g.addEventListener("click", (ev) => { ev.stopPropagation(); select({ kind: "node", id: nodeId }); });
    nodesLayer.appendChild(g);
    for (const kid of state.children.get(nodeId) || []) drawTree(kid, positions, false);
  }

  // ------------------------------------------------------------------ selection / detail
  function select(sel) {
    state.selected = sel;
    if (sel && sel.kind === "node") state.keyboardFocus = sel.id;
    applySelectionClasses();
    renderDetail();
  }
  function applySelectionClasses() {
    let sel = state.selected;
    // Selecting the focused component in L2 highlights nothing in particular: treat as "no dim".
    const focusedComponentSelected = sel && sel.kind === "node" && ((state.level === 2 && sel.id === state.focusComponent) || sel.id === "system");
    if (focusedComponentSelected) sel = null;
    const related = new Set();
    let selectedEdges = new Set();
    if (sel && sel.kind === "node") {
      related.add(sel.id);
      const selIsComponent = sel.id.startsWith("component:");
      for (const e of state.graph.edges) {
        if (e.type === "contains") continue;
        if (selIsComponent && state.level === 2) {
          // In L2 the stub stands for a component: relate the files inside the focused component that touch it.
          if (e.level !== "file") continue;
          if (componentOf(e.source) === sel.id && componentOf(e.target) === state.focusComponent) related.add(e.target);
          if (componentOf(e.target) === sel.id && componentOf(e.source) === state.focusComponent) related.add(e.source);
          continue;
        }
        if (e.source === sel.id) related.add(e.target);
        if (e.target === sel.id) related.add(e.source);
      }
    } else if (sel && sel.kind === "edge") {
      selectedEdges = new Set([sel.id, ...(sel.members || [])]);
      const e = state.edgesById.get(sel.id);
      if (e) { related.add(e.source); related.add(e.target); }
      const drawn = [...edgesLayer.querySelectorAll("path.edge")].some((p) => {
        const id = p.getAttribute("data-id");
        const members = (p.getAttribute("data-members") || "").split(" ");
        return selectedEdges.has(id) || members.some((m) => selectedEdges.has(m));
      });
      if (!drawn) { sel = null; related.clear(); selectedEdges = new Set(); } // edge not drawn here: highlight nothing rather than dim all
    }
    for (const g of nodesLayer.querySelectorAll(".node")) {
      const id = g.getAttribute("data-id");
      const selNode = state.selected && (state.selected.kind === "node" || state.selected.kind === "cell");
      const isSelected = !!(selNode && state.selected.id === id);
      const isRelated = related.has(id) && !(sel && sel.kind === "node" && sel.id === id);
      const isFocused = state.keyboardFocus === id && document.activeElement === svg;
      g.classList.toggle("node--selected", isSelected);
      g.classList.toggle("node--related", isRelated);
      g.classList.toggle("node--focus", isFocused);
      // The alternate views draw their own shapes, not .node__box, so mark them directly.
      for (const shape of g.querySelectorAll(".mx-cell, .tm-tile, .sb-arc, .sb-center")) {
        shape.classList.toggle("mx-cell--selected", isSelected && shape.classList.contains("mx-cell"));
        shape.classList.toggle("tm-tile--selected", isSelected && shape.classList.contains("tm-tile"));
        shape.classList.toggle("sb-arc--selected", isSelected && (shape.classList.contains("sb-arc") || shape.classList.contains("sb-center")));
        shape.classList.toggle("shape--related", isRelated);
        shape.classList.toggle("shape--focus", isFocused);
      }
    }
    for (const path of edgesLayer.querySelectorAll("path.edge")) {
      const id = path.getAttribute("data-id");
      const members = (path.getAttribute("data-members") || "").split(" ").filter(Boolean);
      const isSel = selectedEdges.has(id) || members.some((m) => selectedEdges.has(m));
      path.classList.toggle("edge--selected", isSel);
      path.setAttribute("marker-end", isSel ? "url(#arrow-selected)" : "url(#arrow)");
      if (isSel) edgesLayer.appendChild(path.parentNode); // raise selected edge above the rest
      let dim = false;
      if (sel && sel.kind === "node") {
        const selIsComponent = sel.id.startsWith("component:");
        const touchesId = (e) => e && (selIsComponent
          ? (componentOf(e.source) === sel.id || componentOf(e.target) === sel.id)
          : (e.source === sel.id || e.target === sel.id));
        const e = state.edgesById.get(id);
        const touches = touchesId(e) || members.some((m) => touchesId(state.edgesById.get(m)));
        dim = !touches;
      } else if (sel && sel.kind === "edge") dim = !isSel;
      path.classList.toggle("edge--dimmed", dim);
    }
    for (const lg of labelsLayer.querySelectorAll(".edge-label")) {
      const id = lg.getAttribute("data-id");
      let dim = false;
      if (sel && sel.kind === "node") { const e = state.edgesById.get(id); dim = !(e && (e.source === sel.id || e.target === sel.id)); }
      else if (sel && sel.kind === "edge") dim = !selectedEdges.has(id);
      lg.style.opacity = dim ? "0.25" : "1";
    }
  }

  function renderDetail() {
    const empty = $("#detail-empty"), body = $("#detail-body");
    clear(body);
    const sel = state.selected;
    if (!sel) { empty.hidden = false; body.hidden = true; return; }
    empty.hidden = true; body.hidden = false;
    if (sel.kind === "node") renderNodeDetail(state.nodes.get(sel.id), body);
    else if (sel.kind === "cell") renderCellDetail(sel, body);
    else renderEdgeDetail(state.edgesById.get(sel.id), sel.members || [], body);
  }

  function nodeLink(id, labelOverride) {
    const n = state.nodes.get(id);
    if (!n) return h("span", { text: id });
    const label = labelOverride || (n.kind === "file" || n.kind === "directory" ? n.path + (n.kind === "directory" ? "/" : "") : n.label);
    return h("button", { class: "link-btn", type: "button", text: label, onclick: () => navigateTo(id) });
  }
  function edgeLink(e) {
    const s = state.nodes.get(e.source), t = state.nodes.get(e.target);
    const sl = s ? (s.path || s.label) : e.source, tl = t ? (t.path || t.label) : e.target;
    return h("button", { class: "link-btn", type: "button", text: `${sl} → ${tl}`, onclick: () => navigateToEdge(e) });
  }

  function renderNodeDetail(n, body) {
    body.appendChild(h("div", { class: "detail__kind", text: KIND_LABEL[n.kind] || n.kind }));
    body.appendChild(h("div", { class: "detail__title", text: n.label }));
    if (n.path) body.appendChild(h("div", { class: "detail__path", text: n.path + (n.kind === "directory" ? "/" : "") }));
    body.appendChild(h("p", { text: n.description || "" }));

    const dl = h("dl");
    const row = (k, v) => { dl.appendChild(h("dt", { text: k })); dl.appendChild(typeof v === "string" ? h("dd", { text: v }) : h("dd", null, [v])); };
    if (n.language) row("언어", n.language);
    if (n.languages && Object.keys(n.languages).length) row("언어 구성", Object.entries(n.languages).map(([l, c]) => `${l} ${c}`).join(", "));
    if (n.kind !== "file") row("파일 수", String(n.file_count ?? 0));
    if (n.size_bytes != null) row("크기", `${n.size_bytes.toLocaleString()} B`);
    const max = n.kind === "file" ? state.maxFileCommits : state.maxComponentCommits;
    const bar = h("div", { class: "intensity-bar", title: `${n.commit_count} commits` }, [h("i", { style: `width:${Math.round(intensity(n.commit_count, max) * 100)}%` })]);
    row("Git 변경", h("div", null, [h("div", { text: `${n.commit_count}회${n.kind === "file" ? "" : " (하위 파일 합계)"}` }), bar]));
    row("마지막 변경", `${fmtDate(n.last_changed_at)} ${n.last_changed_at ? `(${relDate(n.last_changed_at)})` : ""}`);
    if (n.kind !== "system") {
      const parentId = n.parent_id;
      if (parentId) row("상위", nodeLink(parentId));
    }
    if (n.external_dependencies) {
      for (const [k, list] of Object.entries(n.external_dependencies)) row(k, list.join(", "));
    }
    body.appendChild(dl);

    if (n.kind === "component" && !(state.level === 2 && state.focusComponent === n.id)) {
      body.appendChild(h("button", { class: "btn btn--primary", type: "button", text: "이 component의 파일 구조 열기 (L2)", onclick: () => openComponent(n.id) }));
    } else if (n.kind === "system" && state.level !== 1) {
      body.appendChild(h("button", { class: "btn btn--primary", type: "button", text: "component 관계 보기 (L1)", onclick: () => setLevel(1) }));
    }

    // children
    const kids = state.children.get(n.id) || [];
    if (kids.length) {
      body.appendChild(h("h3", { text: `하위 (${kids.length})` }));
      const ul = h("ul");
      for (const k of kids.slice(0, 40)) {
        const kn = state.nodes.get(k);
        ul.appendChild(h("li", null, [nodeLink(k, kn.kind === "directory" ? kn.label : kn.label), " ", h("span", { class: "help", text: kn.kind === "file" ? `${kn.language || ""} · ${kn.commit_count}` : `${kn.file_count} files` })]));
      }
      if (kids.length > 40) ul.appendChild(h("li", { class: "more", text: `… 외 ${kids.length - 40}개` }));
      body.appendChild(ul);
    }

    // connections
    const out = (state.edgesBySource.get(n.id) || []).filter((e) => e.type !== "contains");
    const inc = (state.edgesByTarget.get(n.id) || []).filter((e) => e.type !== "contains");
    if (n.kind === "component" || n.kind === "system") {
      const compEdges = [...out, ...inc].filter((e) => e.level === "component");
      const distinctPeers = new Set(compEdges.map((e) => (e.source === n.id ? e.target : e.source)));
      body.appendChild(h("h3", { text: `연결된 component ${distinctPeers.size}개 · 관계 ${compEdges.length}개` }));
      const ul = h("ul");
      for (const e of compEdges.sort((a, b) => (b.member_edge_count || 0) - (a.member_edge_count || 0))) {
        const other = e.source === n.id ? e.target : e.source;
        const dir = e.source === n.id ? "→" : "←";
        ul.appendChild(h("li", { class: "edge-row" }, [
          h("span", { class: `type type--${e.type}`, text: e.type }),
          h("span", null, [dir, " ", nodeLink(other), " ", h("span", { class: "pill pill--" + e.confidence, text: e.confidence }), " ", h("span", { class: "help", text: `×${e.member_edge_count || 1}` }), " ", h("button", { class: "link-btn", type: "button", text: "근거", onclick: () => navigateToEdge(e) })]),
        ]));
      }
      body.appendChild(ul);
    } else {
      const fileEdges = [...out.map((e) => ({ e, dir: "→", other: e.target })), ...inc.map((e) => ({ e, dir: "←", other: e.source }))].filter(({ e }) => e.level !== "component");
      body.appendChild(h("h3", { text: `연결 (${fileEdges.length})` }));
      const ul = h("ul");
      const compSummary = new Map();
      for (const { e, dir, other } of fileEdges) {
        const oc = componentOf(other);
        if (oc && oc !== componentOf(n.id)) compSummary.set(oc, (compSummary.get(oc) || 0) + 1);
        ul.appendChild(h("li", { class: "edge-row" }, [
          h("span", { class: `type type--${e.type}`, text: e.type }),
          h("span", null, [dir, " ", nodeLink(other), " ", h("span", { class: "pill pill--" + e.confidence, text: e.confidence }), " ", h("button", { class: "link-btn", type: "button", text: "근거", onclick: () => navigateToEdge(e) })]),
        ]));
      }
      if (compSummary.size) {
        body.appendChild(h("p", { class: "help" }, ["연결된 component: ", ...[...compSummary.entries()].flatMap(([c, k], i) => [i ? ", " : "", nodeLink(c), ` (${k})`])]));
      }
      body.appendChild(ul);
    }

    body.appendChild(h("h3", { text: "이 node의 생성 근거" }));
    body.appendChild(evidenceList(n.evidence || []));
  }

  function renderEdgeDetail(e, members, body) {
    if (!e) return;
    body.appendChild(h("div", { class: "detail__kind", text: `Edge · ${e.level || "file"}` }));
    body.appendChild(h("div", { class: "detail__title" }, [h("span", { class: `type type--${e.type}`, text: e.type }), " ", h("span", { class: "pill pill--" + e.confidence, text: e.confidence })]));
    body.appendChild(h("p", { class: "help", text: EDGE_STYLE[e.type]?.desc || "" }));
    const dl = h("dl");
    dl.appendChild(h("dt", { text: "source" })); dl.appendChild(h("dd", null, [nodeLink(e.source)]));
    dl.appendChild(h("dt", { text: "target" })); dl.appendChild(h("dd", null, [nodeLink(e.target)]));
    dl.appendChild(h("dt", { text: "confidence" })); dl.appendChild(h("dd", { text: e.confidence + (e.confidence_breakdown ? ` (${Object.entries(e.confidence_breakdown).map(([k, v]) => `${k} ${v}`).join(", ")})` : "") }));
    if (e.member_edge_count) { dl.appendChild(h("dt", { text: "원본 edge" })); dl.appendChild(h("dd", { text: `${e.member_edge_count}개 파일 관계를 합침` })); }
    body.appendChild(dl);
    body.appendChild(h("h3", { text: "관계를 추출한 파일과 이유" }));
    body.appendChild(evidenceList(e.evidence || []));
    const memberIds = e.member_edge_ids || members;
    if (memberIds && memberIds.length) {
      body.appendChild(h("h3", { text: `원본 파일 관계 (${memberIds.length})` }));
      const ul = h("ul");
      for (const id of memberIds.slice(0, 60)) {
        const me = state.edgesById.get(id);
        if (!me) continue;
        ul.appendChild(h("li", null, [h("span", { class: "pill pill--" + me.confidence, text: me.confidence }), " ", edgeLink(me)]));
      }
      if (memberIds.length > 60) ul.appendChild(h("li", { class: "more", text: `… 외 ${memberIds.length - 60}개` }));
      body.appendChild(ul);
    }
  }

  function evidenceList(evidence) {
    const ul = h("ul", { class: "evidence" });
    if (!evidence.length) ul.appendChild(h("li", { class: "help", text: "근거 없음" }));
    for (const ev of evidence.slice(0, 30)) {
      const fileId = `file:${ev.path}`;
      const pathEl = state.nodes.has(fileId) ? h("button", { class: "link-btn ev-path", type: "button", text: ev.path, onclick: () => navigateTo(fileId) }) : h("span", { class: "ev-path", text: ev.path });
      ul.appendChild(h("li", null, [pathEl, h("span", { text: ev.reason })]));
    }
    if (evidence.length > 30) ul.appendChild(h("li", { class: "more", text: `… 외 ${evidence.length - 30}개` }));
    return ul;
  }

  // ------------------------------------------------------------------ navigation
  function setLevel(level) {
    state.viewMode = "graph";
    state.level = level;
    if (level < 2) state.focusComponent = null;
    render();
    fitView();
  }
  function openComponent(id) {
    const n = state.nodes.get(id);
    if (!n || n.kind !== "component") return;
    state.viewMode = "graph";
    state.focusComponent = id;
    state.level = 2;
    render();
    fitView();
    select({ kind: "node", id });
  }
  function navigateTo(id) {
    const n = state.nodes.get(id);
    if (!n) return;
    if (state.viewMode === "treemap" || state.viewMode === "sunburst") {
      const parent = n.kind === "file" ? n.parent_id : id;
      setDrillFocus(n.kind === "file" ? parent : id);
      select({ kind: "node", id });
      return;
    }
    let leavingMatrix = false;
    if (state.viewMode === "matrix") {
      if (n.kind === "component") { select({ kind: "node", id }); return; }
      // A file or directory is not drawn in the matrix, so we have to leave it.
      // setLevel / openComponent below switch the mode and render; never write
      // state.viewMode here, or a path that skips them would strand the canvas.
      leavingMatrix = true;
      if (state.selected && state.selected.kind === "cell") state.selected = null;
    }
    if (n.kind === "system") { setLevel(0); select({ kind: "node", id }); return; }
    if (n.kind === "component") {
      if (leavingMatrix || (state.level === 2 && state.focusComponent !== id)) openComponent(id);
      else if (state.level < 1) { setLevel(1); }
      select({ kind: "node", id });
      if (state.level === 2 && state.focusComponent === id) return;
      centerOn(id);
      return;
    }
    const comp = componentOf(id);
    if (leavingMatrix || state.focusComponent !== comp || state.level !== 2) openComponent(comp);
    select({ kind: "node", id });
    centerOn(id);
  }
  function navigateToEdge(e) {
    if (state.viewMode !== "graph") setViewMode("graph");
    const sc = componentOf(e.source), tc = componentOf(e.target);
    if (e.level === "component") { if (state.level !== 1) setLevel(1); select({ kind: "edge", id: e.id }); centerOnEdge(e); return; }
    if (e.level === "structure") {
      const comp = state.focusComponent === tc ? tc : sc;
      if (state.level !== 2 || state.focusComponent !== comp) openComponent(comp);
      select({ kind: "edge", id: e.id });
      return;
    }
    const target = state.focusComponent === tc ? tc : sc;
    if (state.level !== 2 || state.focusComponent !== target) openComponent(target);
    select({ kind: "edge", id: e.id });
  }
  function goUp() {
    if (state.viewMode === "treemap" || state.viewMode === "sunburst") {
      if (state.selected) { select(null); return; }
      const cur = state.nodes.get(state.drillFocus);
      if (cur && cur.parent_id) { setDrillFocus(cur.parent_id); return; }
      return;
    }
    if (state.viewMode === "matrix") { select(null); return; }
    if (state.selected && state.selected.kind === "edge") { select(null); return; }
    if (state.level === 2) { const c = state.focusComponent; setLevel(1); select({ kind: "node", id: c }); return; }
    if (state.level === 1) { setLevel(0); select(null); return; }
    select(null);
  }

  function updateChrome() {
    for (const b of document.querySelectorAll(".viewtab")) {
      const on = b.dataset.view === state.viewMode;
      b.setAttribute("aria-selected", String(on));
      b.tabIndex = on ? 0 : -1; // roving tabindex: Tab enters the tablist once
    }
    const graphMode = state.viewMode === "graph";
    $("#level-switch").hidden = !graphMode;
    $("#metric-wrap").hidden = !(state.viewMode === "treemap" || state.viewMode === "sunburst");
    for (const b of document.querySelectorAll(".chip[data-level]")) {
      const lv = Number(b.dataset.level);
      b.setAttribute("aria-pressed", String(graphMode && lv === state.level));
      if (lv === 2) b.disabled = !state.focusComponent;
    }
    const bc = $("#breadcrumb");
    clear(bc);
    if (state.viewMode === "treemap" || state.viewMode === "sunburst") {
      const chain = [];
      for (let id = state.drillFocus; id; id = state.nodes.get(id).parent_id) chain.unshift(id);
      for (const id of chain) {
        const n = state.nodes.get(id);
        bc.appendChild(h("button", { class: "crumb", type: "button", text: n.kind === "system" ? "System" : n.label, onclick: () => setDrillFocus(id) }));
      }
    } else if (state.viewMode === "matrix") {
      bc.appendChild(h("button", { class: "crumb crumb--root", type: "button", text: "관계 행렬" }));
    } else {
      bc.appendChild(h("button", { class: "crumb crumb--root", type: "button", text: "System overview", onclick: () => setLevel(0) }));
      if (state.level >= 1) bc.appendChild(h("button", { class: "crumb", type: "button", text: "Components", onclick: () => setLevel(1) }));
      if (state.level === 2) bc.appendChild(h("button", { class: "crumb", type: "button", text: state.nodes.get(state.focusComponent).label }));
    }
    bc.lastChild.setAttribute("aria-current", "page");
    if (graphMode && state.level < 2) {
      const comps = componentNodes().length;
      const shown = edgesLayer.querySelectorAll("path.edge").length;
      $("#canvas-status").textContent = state.level === 0
        ? `Level 0 · component ${comps}개 · 주요 흐름 ${shown}개 (invokes/imports/communicates, high·medium)`
        : `Level 1 · component ${comps}개 · component 관계 ${shown}개`;
    }
  }

  // ------------------------------------------------------------------ shared helpers for the alternate views
  function setViewMode(mode) {
    if (state.viewMode === mode) return;
    state.viewMode = mode;
    state.keyboardFocus = null;
    // A matrix cell has no meaning outside the matrix; an edge is only drawn in the graph view.
    if (state.selected && state.selected.kind === "cell" && mode !== "matrix") state.selected = null;
    if (state.selected && state.selected.kind === "edge" && mode !== "graph") state.selected = null;
    render();
    fitView();
    renderDetail();
  }
  function setDrillFocus(id) {
    const n = state.nodes.get(id);
    if (!n || n.kind === "file") return;
    state.drillFocus = id;
    render();
    fitView();
  }
  function metricValue(node) {
    if (state.sizeMetric === "commits") return Math.max(node.commit_count || 0, node.kind === "file" ? 1 : 0);
    return node.kind === "file" ? 1 : (node.file_count || 0);
  }
  function metricLabel() { return state.sizeMetric === "commits" ? "커밋" : "파일"; }
  function maxFor(kind) { return kind === "file" ? state.maxFileCommits : state.maxComponentCommits; }
  function tint(node) {
    const t = intensity(node.commit_count, maxFor(node.kind));
    return { t, fill: `color-mix(in srgb, var(--graphite) ${Math.round(12 + t * 55)}%, var(--panel))`, text: t > 0.55 ? "var(--bg)" : "var(--text)" };
  }
  function activate(id, deep) {
    if (id && id.startsWith("cell:")) { const c = state.cells.get(id); if (c) select(c); return; }
    const n = state.nodes.get(id);
    if (!n) return;
    if (state.viewMode === "treemap" || state.viewMode === "sunburst") {
      if (deep && n.kind !== "file" && id !== state.drillFocus) { setDrillFocus(id); select({ kind: "node", id }); return; }
      select({ kind: "node", id });
      return;
    }
    if (deep && state.selected && state.selected.kind === "node" && state.selected.id === id && n.kind === "component") { openComponent(id); return; }
    if (deep && n.kind === "system") { setLevel(1); return; }
    select({ kind: "node", id });
  }

  // ------------------------------------------------------------------ matrix view
  function matrixOrder() {
    return componentNodes().slice().sort((a, b) => {
      const la = a.layout || {}, lb = b.layout || {};
      return (la.row ?? 9) - (lb.row ?? 9) || (la.col ?? 9) - (lb.col ?? 9) || a.label.localeCompare(b.label);
    });
  }
  function renderMatrix() {
    const comps = matrixOrder();
    const n = comps.length;
    const CELL = 40, LEFT = 190, TOP = 150;
    state.cells = new Map();
    state.matrixBands = null;
    const pairs = new Map();
    let maxCount = 1;
    for (const e of componentEdges()) {
      if (!edgeVisible(e)) continue;
      const key = `${e.source}|${e.target}`;
      if (!pairs.has(key)) pairs.set(key, []);
      pairs.get(key).push(e);
    }
    for (const list of pairs.values()) maxCount = Math.max(maxCount, list.reduce((a, e) => a + (e.member_edge_count || 1), 0));

    labelsLayer.appendChild(el("text", { x: LEFT, y: 30, class: "mx-axis" }, ["열 = 대상 (target)"]));
    labelsLayer.appendChild(el("text", { x: 20, y: TOP - 12, class: "mx-axis" }, ["행 = 출발 (source)"]));
    const bandRow = el("rect", { x: LEFT, y: 0, width: n * CELL, height: CELL, class: "mx-band", id: "mx-band-row" });
    const bandCol = el("rect", { x: 0, y: TOP, width: CELL, height: n * CELL, class: "mx-band", id: "mx-band-col" });
    nodesLayer.appendChild(bandRow); nodesLayer.appendChild(bandCol);
    const clearBands = () => { bandRow.classList.remove("mx-band--on"); bandCol.classList.remove("mx-band--on"); };
    const hover = (r, c) => {
      bandRow.setAttribute("y", TOP + r * CELL); bandRow.setAttribute("x", 0); bandRow.setAttribute("width", LEFT + n * CELL);
      bandCol.setAttribute("x", LEFT + c * CELL); bandCol.setAttribute("y", 0); bandCol.setAttribute("height", TOP + n * CELL);
      bandRow.classList.toggle("mx-band--on", r >= 0); bandCol.classList.toggle("mx-band--on", c >= 0);
    };
    state.matrixBands = { row: bandRow, col: bandCol };

    comps.forEach((c, i) => {
      const dim = !nodeMatchesLanguage(c);
      const g = el("g", { class: `node node--component${dim ? " node--dimmed" : ""}`, "data-id": c.id, tabindex: -1, role: "button",
        "aria-label": `${c.label} 행과 열, 파일 ${c.file_count}개, 커밋 ${c.commit_count}회` });
      g.appendChild(el("rect", { x: 0, y: TOP + i * CELL, width: LEFT - 6, height: CELL, class: "mx-cell mx-headbox", fill: "transparent" }));
      g.appendChild(el("text", { x: LEFT - 10, y: TOP + i * CELL + CELL / 2 + 4, class: "mx-head", "text-anchor": "end" }, [fitText(c.label, 12, LEFT - 20)]));
      g.appendChild(el("rect", { x: LEFT + i * CELL, y: 0, width: CELL, height: TOP - 6, class: "mx-cell mx-headbox", fill: "transparent" }));
      const tx = LEFT + i * CELL + CELL / 2 + 4, ty = TOP - 10;
      g.appendChild(el("text", { x: tx, y: ty, class: "mx-head", transform: `rotate(-60 ${tx} ${ty})` }, [fitText(c.label, 12, TOP - 24)]));
      g.addEventListener("click", () => select({ kind: "node", id: c.id }));
      nodesLayer.appendChild(g);
      state.positions.set(c.id, { x: LEFT - 10, y: TOP + i * CELL, w: CELL, h: CELL });
      state.visibleNodeIds.push(c.id);
    });

    comps.forEach((src, r) => comps.forEach((dst, c) => {
      const x = LEFT + c * CELL, y = TOP + r * CELL;
      if (r === c) { nodesLayer.appendChild(el("rect", { x, y, width: CELL, height: CELL, class: "mx-cell mx-cell--self" })); return; }
      const list = pairs.get(`${src.id}|${dst.id}`) || [];
      if (!list.length) { nodesLayer.appendChild(el("rect", { x, y, width: CELL, height: CELL, class: "mx-cell mx-cell--empty" })); return; }
      const count = list.reduce((a, e) => a + (e.member_edge_count || 1), 0);
      const t = Math.log1p(count) / Math.log1p(maxCount);
      const id = `cell:${src.id}->${dst.id}`;
      state.cells.set(id, { kind: "cell", id, source: src.id, target: dst.id, edges: list.map((e) => e.id) });
      const g = el("g", { class: "node node--cell", "data-id": id, tabindex: -1, role: "button",
        "aria-label": `${src.label}에서 ${dst.label}로, ${list.map((e) => `${e.type} ${e.member_edge_count || 1}개`).join(", ")}` });
      g.appendChild(el("rect", { x, y, width: CELL, height: CELL, class: "mx-cell", fill: `color-mix(in srgb, var(--graphite) ${Math.round(8 + t * 62)}%, var(--panel))` }));
      const tw = CELL / list.length;
      list.forEach((e, k) => g.appendChild(el("rect", { x: x + k * tw, y: y + CELL - 4, width: tw, height: 4, class: "mx-type", fill: `var(--edge-${e.type})` })));
      g.appendChild(el("text", { x: x + CELL / 2, y: y + CELL / 2 + 1, class: `mx-count${t > 0.55 ? " mx-count--strong" : ""}`, "text-anchor": "middle" }, [String(count)]));
      g.addEventListener("click", (ev) => { ev.stopPropagation(); select(state.cells.get(id)); });
      g.addEventListener("pointerenter", () => hover(r, c));
      g.addEventListener("pointerleave", clearBands);
      nodesLayer.appendChild(g);
      state.positions.set(id, { x, y, w: CELL, h: CELL });
      state.visibleNodeIds.push(id);
    }));

    setBounds(0, 0, LEFT + n * CELL + 30, TOP + n * CELL + 30);
    const filled = state.cells.size;
    $("#canvas-status").textContent = `관계 행렬 · component ${n}개 · 관계가 있는 칸 ${filled}개 / ${n * (n - 1)}칸. 숫자는 원본 파일 관계 수, 아래 색 띠는 관계 종류.`;
  }

  function renderCellDetail(cell, body) {
    const src = state.nodes.get(cell.source), dst = state.nodes.get(cell.target);
    body.appendChild(h("div", { class: "detail__kind", text: "Matrix cell" }));
    body.appendChild(h("div", { class: "detail__title", text: `${src.label} → ${dst.label}` }));
    const dl = h("dl");
    dl.appendChild(h("dt", { text: "source" })); dl.appendChild(h("dd", null, [nodeLink(cell.source)]));
    dl.appendChild(h("dt", { text: "target" })); dl.appendChild(h("dd", null, [nodeLink(cell.target)]));
    body.appendChild(dl);
    body.appendChild(h("h3", { text: `이 칸의 관계 (${cell.edges.length})` }));
    const ul = h("ul");
    for (const id of cell.edges) {
      const e = state.edgesById.get(id);
      if (!e) continue;
      ul.appendChild(h("li", { class: "edge-row" }, [
        h("span", { class: `type type--${e.type}`, text: e.type }),
        h("span", null, [h("span", { class: "pill pill--" + e.confidence, text: e.confidence }), " ", h("span", { class: "help", text: `원본 ${e.member_edge_count || 1}개` }), " ",
          h("button", { class: "link-btn", type: "button", text: "근거", onclick: () => select({ kind: "edge", id: e.id }) })]),
      ]));
    }
    body.appendChild(ul);
    const first = state.edgesById.get(cell.edges[0]);
    if (first) { body.appendChild(h("h3", { text: "대표 근거" })); body.appendChild(evidenceList(first.evidence || [])); }
  }

  // ------------------------------------------------------------------ treemap view
  function worstRatio(row, sum, side, scale) {
    const area = sum * scale;
    let max = 0, min = Infinity;
    for (const it of row) { const a = it.value * scale; max = Math.max(max, a); min = Math.min(min, a); }
    return Math.max((side * side * max) / (area * area), (area * area) / (side * side * min));
  }
  function squarify(items, rect, out) {
    const queue = items.filter((i) => i.value > 0).sort((a, b) => b.value - a.value);
    let { x, y, w, h } = rect;
    while (queue.length) {
      const total = queue.reduce((a, c) => a + c.value, 0);
      const scale = (w * h) / (total || 1);
      const side = Math.min(w, h);
      const row = [];
      let sum = 0, best = Infinity;
      while (queue.length) {
        const next = queue[0];
        const ratio = worstRatio(row.concat(next), sum + next.value, side, scale);
        if (row.length && ratio > best) break;
        row.push(queue.shift()); sum += next.value; best = ratio;
      }
      const area = sum * scale;
      if (w >= h) {
        const rw = area / h;
        let cy = y;
        for (const it of row) { const ih = (it.value * scale) / rw; out.push({ id: it.id, x, y: cy, w: rw, h: ih }); cy += ih; }
        x += rw; w -= rw;
      } else {
        const rh = area / w;
        let cx = x;
        for (const it of row) { const iw = (it.value * scale) / rh; out.push({ id: it.id, x: cx, y, w: iw, h: rh }); cx += iw; }
        y += rh; h -= rh;
      }
      if (w < 0.5 || h < 0.5) break;
    }
  }
  function renderTreemap() {
    const focus = state.nodes.get(state.drillFocus) || state.nodes.get("system");
    const kids = (state.children.get(focus.id) || []).map((id) => state.nodes.get(id));
    const items = kids.map((n) => ({ id: n.id, value: metricValue(n) })).filter((i) => i.value > 0);
    const W = 1080, H = 660, X = 40, Y = 60;
    const out = [];
    squarify(items, { x: X, y: Y, w: W, h: H }, out);
    labelsLayer.appendChild(el("text", { x: X, y: Y - 22, class: "section-title" }, [
      `${focus.kind === "system" ? focus.label : focus.path || focus.label} · ${metricLabel()} 기준 면적 · 색 진하기 = 커밋 수`,
    ]));
    for (const t of out) {
      const node = state.nodes.get(t.id);
      const dim = !nodeMatchesLanguage(node);
      const { fill, text } = tint(node);
      const g = el("g", { class: `node node--tile${dim ? " node--dimmed" : ""}`, "data-id": t.id, tabindex: -1, role: "button",
        "aria-label": `${node.label}, ${metricLabel()} ${metricValue(node)}, 커밋 ${node.commit_count}회` });
      g.appendChild(el("rect", { x: t.x, y: t.y, width: t.w, height: t.h, class: "tm-tile", fill, rx: 3 }));
      if (t.w > 62 && t.h > 26) {
        g.appendChild(el("text", { x: t.x + 8, y: t.y + 18, class: "tm-label", fill: text }, [fitText(node.label, 12, t.w - 16)]));
        if (t.h > 42) g.appendChild(el("text", { x: t.x + 8, y: t.y + 33, class: "tm-sub", fill: text, opacity: .8 }, [fitText(`${node.kind === "file" ? "파일" : `${node.file_count}개 파일`} · ${node.commit_count} 커밋`, 10, t.w - 16)]));
      }
      g.addEventListener("click", (ev) => { ev.stopPropagation(); select({ kind: "node", id: t.id }); });
      g.addEventListener("dblclick", (ev) => { ev.stopPropagation(); if (node.kind !== "file") setDrillFocus(t.id); });
      nodesLayer.appendChild(g);
      state.positions.set(t.id, t);
      state.visibleNodeIds.push(t.id);
    }
    setBounds(X - 20, Y - 44, W + 40, H + 64);
    const zeroValued = kids.filter((k) => metricValue(k) === 0).length;
    const tooSmall = kids.length - out.length - zeroValued;
    const why = [];
    if (zeroValued) why.push(`${metricLabel()} 0이라 ${zeroValued}개`);
    if (tooSmall > 0) why.push(`너무 얇아 ${tooSmall}개`);
    $("#canvas-status").textContent = `면적 뷰 · ${focus.kind === "system" ? "전체" : focus.label} 아래 ${out.length}개`
      + (why.length ? ` (안 그림: ${why.join(", ")})` : "")
      + ` · 더블클릭/Enter로 내려가고 Esc로 올라온다`;
  }

  // ------------------------------------------------------------------ sunburst view
  function arcPath(cx, cy, r0, r1, a0, a1) {
    const large = a1 - a0 > Math.PI ? 1 : 0;
    const pt = (r, a) => `${(cx + r * Math.cos(a)).toFixed(2)},${(cy + r * Math.sin(a)).toFixed(2)}`;
    if (a1 - a0 >= Math.PI * 2 - 1e-6) {
      return `M${pt(r1, 0)} A${r1},${r1} 0 1 1 ${pt(r1, Math.PI)} A${r1},${r1} 0 1 1 ${pt(r1, 0)} M${pt(r0, 0)} A${r0},${r0} 0 1 0 ${pt(r0, Math.PI)} A${r0},${r0} 0 1 0 ${pt(r0, 0)} Z`;
    }
    return `M${pt(r1, a0)} A${r1},${r1} 0 ${large} 1 ${pt(r1, a1)} L${pt(r0, a1)} A${r0},${r0} 0 ${large} 0 ${pt(r0, a0)} Z`;
  }
  function renderSunburst() {
    const focus = state.nodes.get(state.drillFocus) || state.nodes.get("system");
    const CX = 560, CY = 420, R0 = 90, RING = 78, MAX_RING = 4;
    const MIN_ANGLE = 0.012;
    let drawn = 0, omitted = 0, cappedByDepth = 0;

    const centerG = el("g", { class: "node node--center", "data-id": focus.id, tabindex: -1, role: "button",
      "aria-label": `${focus.label}, ${metricLabel()} ${metricValue(focus)}, 가운데. 상위로 올라가려면 Esc` });
    centerG.appendChild(el("circle", { cx: CX, cy: CY, r: R0 - 6, class: "sb-center" }));
    centerG.appendChild(el("text", { x: CX, y: CY - 4, class: "sb-title", "text-anchor": "middle" }, [fitText(focus.kind === "system" ? focus.label : focus.label, 12, R0 * 1.6)]));
    centerG.appendChild(el("text", { x: CX, y: CY + 12, class: "sb-sub", "text-anchor": "middle" }, [`${metricValue(focus)} ${metricLabel()}`]));
    centerG.addEventListener("click", () => select({ kind: "node", id: focus.id }));
    centerG.addEventListener("dblclick", () => { if (focus.parent_id) setDrillFocus(focus.parent_id); });
    nodesLayer.appendChild(centerG);
    state.positions.set(focus.id, { x: CX - R0, y: CY - R0, w: R0 * 2, h: R0 * 2 });
    state.visibleNodeIds.push(focus.id);

    const countDescendants = (nodeId) => {
      let total = 0;
      for (const kid of state.children.get(nodeId) || []) total += 1 + countDescendants(kid);
      return total;
    };
    const walk = (nodeId, depth, a0, a1) => {
      if (depth > MAX_RING) { cappedByDepth += countDescendants(nodeId); return; }
      const kids = (state.children.get(nodeId) || []).map((id) => state.nodes.get(id)).filter((n) => metricValue(n) > 0);
      const total = kids.reduce((a, n) => a + metricValue(n), 0);
      if (!total) return;
      let a = a0;
      for (const kid of kids) {
        const span = ((a1 - a0) * metricValue(kid)) / total;
        const b = a + span;
        if (span < MIN_ANGLE) { omitted += 1 + countDescendants(kid.id); a = b; continue; }
        const r0 = R0 + (depth - 1) * RING, r1 = r0 + RING - 3;
        const { fill, text } = tint(kid);
        const dim = !nodeMatchesLanguage(kid);
        const g = el("g", { class: `node node--arc${dim ? " node--dimmed" : ""}`, "data-id": kid.id, tabindex: -1, role: "button",
          "aria-label": `${kid.path || kid.label}, ${KIND_LABEL[kid.kind]}, ${metricLabel()} ${metricValue(kid)}, 커밋 ${kid.commit_count}회` });
        g.appendChild(el("path", { d: arcPath(CX, CY, r0, r1, a, b), class: "sb-arc", fill }));
        const mid = (a + b) / 2, rm = (r0 + r1) / 2;
        if (span > 0.09) {
          const deg = (mid * 180) / Math.PI;
          const flip = deg > 90 && deg < 270;
          const lx = CX + rm * Math.cos(mid), ly = CY + rm * Math.sin(mid);
          g.appendChild(el("text", {
            x: lx, y: ly + 3, class: "sb-label", fill: text, "text-anchor": "middle",
            transform: `rotate(${flip ? deg + 180 : deg} ${lx} ${ly})`,
          }, [fitText(kid.label, 10, Math.min(RING - 14, span * rm * 1.1))]));
        }
        g.addEventListener("click", (ev) => { ev.stopPropagation(); select({ kind: "node", id: kid.id }); });
        g.addEventListener("dblclick", (ev) => { ev.stopPropagation(); if (kid.kind !== "file") setDrillFocus(kid.id); });
        nodesLayer.appendChild(g);
        state.positions.set(kid.id, { x: CX + rm * Math.cos(mid) - 8, y: CY + rm * Math.sin(mid) - 8, w: 16, h: 16 });
        state.visibleNodeIds.push(kid.id);
        drawn += 1;
        walk(kid.id, depth + 1, a, b);
        a = b;
      }
    };
    walk(focus.id, 1, -Math.PI / 2, Math.PI * 1.5);
    const R = R0 + MAX_RING * RING + 16;
    setBounds(CX - R, CY - R, R * 2, R * 2);
    const hidden = omitted + cappedByDepth;
    const why = [];
    if (cappedByDepth) why.push(`${MAX_RING}겹 밖 ${cappedByDepth}개`);
    if (omitted) why.push(`각이 얇아 ${omitted}개`);
    $("#canvas-status").textContent = `방사형 뷰 · ${focus.kind === "system" ? "전체" : focus.label} 기준 ${drawn}개 표시`
      + (hidden ? `, 안 그린 것 ${hidden}개 (${why.join(", ")}) — 더 보려면 조각을 열어라` : "")
      + ` · 각도 = ${metricLabel()} 비율 · 더블클릭/Enter로 내려간다`;
  }

  // ------------------------------------------------------------------ view transform
  function applyView(animate) {
    viewport.classList.toggle("viewport--animate", !!animate);
    viewport.setAttribute("transform", `translate(${state.view.x},${state.view.y}) scale(${state.view.k})`);
  }
  function setBounds(x, y, w, h) { state.positions.set("__bounds__", { x, y, w, h }); }
  function contentBounds() {
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const p of state.positions.values()) {
      minX = Math.min(minX, p.x); minY = Math.min(minY, p.y);
      maxX = Math.max(maxX, p.x + p.w); maxY = Math.max(maxY, p.y + p.h);
    }
    if (!Number.isFinite(minX)) return { x: 0, y: 0, w: 800, h: 600 };
    return { x: minX - 30, y: minY - 30, w: maxX - minX + 60, h: maxY - minY + 60 };
  }
  function fitView() {
    const rect = svg.getBoundingClientRect();
    const b = contentBounds();
    const k = Math.min(rect.width / b.w, rect.height / b.h, 1.4);
    state.view = { k, x: (rect.width - b.w * k) / 2 - b.x * k, y: (rect.height - b.h * k) / 2 - b.y * k };
    applyView(true);
  }
  function zoomBy(factor, cx, cy) {
    const rect = svg.getBoundingClientRect();
    const px = cx ?? rect.width / 2, py = cy ?? rect.height / 2;
    const k = Math.max(0.15, Math.min(4, state.view.k * factor));
    state.view.x = px - (px - state.view.x) * (k / state.view.k);
    state.view.y = py - (py - state.view.y) * (k / state.view.k);
    state.view.k = k;
    applyView();
  }
  function centerOnEdge(e) {
    const a = state.positions.get(e.source), b = state.positions.get(e.target);
    if (!a || !b) return;
    const rect = svg.getBoundingClientRect();
    const ca = center(a), cb = center(b);
    state.view.x = rect.width / 2 - ((ca.x + cb.x) / 2) * state.view.k;
    state.view.y = rect.height / 2 - ((ca.y + cb.y) / 2) * state.view.k;
    applyView(true);
  }
  function centerOn(id) {
    const p = state.positions.get(id);
    if (!p) return;
    const rect = svg.getBoundingClientRect();
    const c = center(p);
    state.view.x = rect.width / 2 - c.x * state.view.k;
    state.view.y = rect.height / 2 - c.y * state.view.k;
    applyView(true);
  }

  // ------------------------------------------------------------------ interactions
  function wireCanvas() {
    let panning = null;
    let suppressClick = false;
    svg.addEventListener("pointerdown", (ev) => {
      if (ev.button !== 0) return;
      panning = { id: ev.pointerId, sx: ev.clientX, sy: ev.clientY, ox: state.view.x, oy: state.view.y, moved: false };
    });
    svg.addEventListener("pointermove", (ev) => {
      if (!panning) return;
      const dx = ev.clientX - panning.sx, dy = ev.clientY - panning.sy;
      if (!panning.moved && Math.hypot(dx, dy) > 3) {
        panning.moved = true;
        svg.classList.add("is-panning");
        try { svg.setPointerCapture(panning.id); } catch (_) { /* ignore */ }
      }
      if (panning.moved) { state.view.x = panning.ox + dx; state.view.y = panning.oy + dy; applyView(); }
    });
    const endPan = () => {
      if (!panning) return;
      suppressClick = panning.moved;
      panning = null;
      svg.classList.remove("is-panning");
    };
    svg.addEventListener("pointerup", endPan);
    svg.addEventListener("pointercancel", endPan);
    svg.addEventListener("click", (ev) => {
      if (suppressClick) { suppressClick = false; return; }
      if (ev.target === svg) select(null);
    });
    svg.addEventListener("wheel", (ev) => {
      ev.preventDefault();
      const rect = svg.getBoundingClientRect();
      zoomBy(ev.deltaY < 0 ? 1.12 : 1 / 1.12, ev.clientX - rect.left, ev.clientY - rect.top);
    }, { passive: false });
    svg.addEventListener("dblclick", (ev) => {
      if (state.viewMode !== "graph") return;
      const g = ev.target.closest && ev.target.closest(".node");
      if (!g) return;
      const id = g.getAttribute("data-id");
      const n = state.nodes.get(id);
      if (n.kind === "component") openComponent(id);
      else if (n.kind === "system") setLevel(1);
    });
    svg.addEventListener("pointerleave", () => {
      if (!state.matrixBands) return;
      state.matrixBands.row.classList.remove("mx-band--on");
      state.matrixBands.col.classList.remove("mx-band--on");
    });
    svg.addEventListener("keydown", onKey);
    svg.addEventListener("focus", () => {
      if (!state.visibleNodeIds.includes(state.keyboardFocus)) state.keyboardFocus = state.visibleNodeIds[0] || null;
      applySelectionClasses();
      if (state.keyboardFocus) announce(state.keyboardFocus);
    });
    svg.addEventListener("blur", applySelectionClasses);
    window.addEventListener("resize", () => { /* keep view; user can press fit */ });
  }

  function onKey(ev) {
    const ids = state.visibleNodeIds;
    if (!ids.length) return;
    let idx = ids.indexOf(state.keyboardFocus);
    if (idx < 0) idx = 0;
    const focusNode = (i) => { state.keyboardFocus = ids[(i + ids.length) % ids.length]; applySelectionClasses(); centerOn(state.keyboardFocus); announce(state.keyboardFocus); };
    switch (ev.key) {
      case "ArrowRight": case "ArrowDown": ev.preventDefault(); focusNode(idx + 1); break;
      case "ArrowLeft": case "ArrowUp": ev.preventDefault(); focusNode(idx - 1); break;
      case "Home": ev.preventDefault(); focusNode(0); break;
      case "End": ev.preventDefault(); focusNode(ids.length - 1); break;
      case "Enter": {
        ev.preventDefault();
        const id = state.keyboardFocus || ids[0];
        activate(id, true);
        break;
      }
      case " ": ev.preventDefault(); if (state.keyboardFocus) activate(state.keyboardFocus, false); break;
      case "Escape": ev.preventDefault(); goUp(); break;
      case "+": case "=": zoomBy(1.2); break;
      case "-": case "_": zoomBy(1 / 1.2); break;
      case "0": fitView(); break;
      default: return;
    }
  }
  function announce(id) {
    const g = setActiveDescendant(id);
    if (g) { $("#canvas-status").textContent = g.getAttribute("aria-label"); return; }
    const n = state.nodes.get(id);
    if (n) $("#canvas-status").textContent = `포커스: ${n.path || n.label} (${KIND_LABEL[n.kind]})`;
  }

  function wireSidebar() {
    document.addEventListener("click", (ev) => {
      const btn = ev.target.closest && ev.target.closest("[data-action]");
      if (!btn) return;
      switch (btn.dataset.action) {
        case "overview": setLevel(0); select(null); break;
        case "zoom-in": zoomBy(1.25); break;
        case "zoom-out": zoomBy(1 / 1.25); break;
        case "zoom-fit": fitView(); break;
      }
    });
    const tabs = [...document.querySelectorAll(".viewtab")];
    tabs.forEach((tab, i) => {
      tab.addEventListener("click", () => setViewMode(tab.dataset.view));
      tab.addEventListener("keydown", (ev) => {
        const step = ev.key === "ArrowRight" ? 1 : ev.key === "ArrowLeft" ? -1 : ev.key === "Home" ? -i : ev.key === "End" ? tabs.length - 1 - i : 0;
        if (!step && ev.key !== "Home") return;
        ev.preventDefault();
        const next = tabs[(i + step + tabs.length) % tabs.length];
        next.focus();
        setViewMode(next.dataset.view);
      });
    });
    $("#metric").addEventListener("change", (ev) => { state.sizeMetric = ev.target.value; render(); fitView(); });
    for (const chip of document.querySelectorAll(".chip[data-level]")) {
      chip.addEventListener("click", () => {
        const lv = Number(chip.dataset.level);
        if (lv === 2) { if (state.focusComponent) openComponent(state.focusComponent); return; }
        setLevel(lv);
      });
    }
    const search = $("#search");
    const results = $("#search-results");
    let hits = [];
    const runSearch = () => {
      const q = search.value.trim().toLowerCase();
      clear(results);
      hits = [];
      if (q.length < 2) return;
      const rank = { component: 0, file: 1, directory: 2, system: 3 };
      const score = (n) => {
        const label = n.label.toLowerCase();
        if (label === q) return 0;
        if (label.startsWith(q)) return 1;
        if (label.includes(q)) return 2;
        return 3; // matched only via path/description
      };
      for (const n of state.graph.nodes) {
        const hay = `${n.label} ${n.path || ""} ${n.kind === "component" ? n.description : ""}`.toLowerCase();
        if (hay.includes(q)) hits.push(n);
      }
      const totalHits = hits.length;
      hits.sort((a, b) => score(a) - score(b) || rank[a.kind] - rank[b.kind] || a.label.localeCompare(b.label));
      hits = hits.slice(0, 40);
      for (const n of hits) {
        const li = h("li");
        li.appendChild(h("button", { type: "button", onclick: () => navigateTo(n.id) }, [
          h("span", { class: "r-kind", text: KIND_LABEL[n.kind] }),
          h("span", { class: "r-label", text: n.label }),
          n.path ? h("span", { class: "r-path", text: n.path }) : null,
        ]));
        results.appendChild(li);
      }
      if (!hits.length) results.appendChild(h("li", { class: "help", text: "일치하는 node 없음" }));
      else if (totalHits > hits.length) results.appendChild(h("li", { class: "help", text: `${totalHits}개 중 ${hits.length}개 표시. 더 구체적으로 입력` }));
    };
    search.addEventListener("input", runSearch);
    search.addEventListener("keydown", (ev) => { if (ev.key === "Enter" && hits.length) navigateTo(hits[0].id); });
  }

  document.addEventListener("keydown", (ev) => {
    if (ev.key === "/" && document.activeElement !== $("#search") && !/input|textarea/i.test(document.activeElement.tagName)) { ev.preventDefault(); $("#search").focus(); }
  });

  wireCanvas();
  wireSidebar();
  load().catch((err) => {
    $("#canvas-status").textContent = `graph.json을 불러오지 못했다: ${err.message}. analyze.py를 먼저 실행하고 정적 서버로 열어야 한다.`;
    console.error(err);
  });

  window.__neukbao = { state, render, navigateTo };
})();
