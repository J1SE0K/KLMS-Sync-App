/* Development Storytelling UI. Vanilla JS, no external dependencies.
   Reads story.json (curated episodes + auto episodes + evidence excerpts) and commits.json (per-commit metadata). */
(function () {
  "use strict";

  const $ = (sel, root) => (root || document).querySelector(sel);
  const el = (tag, attrs, children) => {
    const node = document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (v === null || v === undefined || v === false) continue;
        if (k === "class") node.className = v;
        else if (k === "text") node.textContent = v;
        else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
        else node.setAttribute(k, v === true ? "" : v);
      }
    }
    for (const c of children || []) {
      if (c === null || c === undefined) continue;
      node.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    }
    return node;
  };

  const STATUS_LABEL = { observed: "observed · 직접 확인", supported: "supported · 기록+diff", inferred: "inferred · 추정" };
  const CONF_LABEL = { high: "confidence high", medium: "confidence medium", low: "confidence low" };
  const TYPE_LABEL = {
    introduction: "도입", extension: "확장", migration: "이전", repair: "수정", refactor: "구조 정리",
    security: "보안", test: "검증", release: "release",
  };

  const state = {
    story: null,
    commitsByHash: new Map(),
    index: 0,
    playing: false,
    timer: null,
    tickTimer: null,
    tickStart: 0,
    interval: 10000,
    scrubbing: false,
    lastFocus: null,
    reducedMotion: window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches,
  };

  const fmtDate = (iso) => (iso ? iso.slice(0, 10) : "—");
  const fmtDateTime = (iso) => (iso ? iso.replace("T", " ").slice(0, 16) : "—");
  const short = (h) => (h || "").slice(0, 7);
  const commitOf = (h) => state.commitsByHash.get(h) || null;
  const githubUrl = (h) => {
    const repo = state.story.source.repository;
    return repo && repo.includes("/") ? `https://github.com/${repo}/commit/${h}` : null;
  };

  // ------------------------------------------------------------------ loading
  async function load() {
    const [storyRes, commitsRes] = await Promise.all([fetch("story.json"), fetch("commits.json")]);
    if (!storyRes.ok) throw new Error(`story.json ${storyRes.status}`);
    const story = await storyRes.json();
    let commits = { commits: [] };
    if (commitsRes.ok) commits = await commitsRes.json();
    for (const c of commits.commits) state.commitsByHash.set(c.hash, c);
    state.story = story;
  }

  // ------------------------------------------------------------------ header + arc
  function renderHeader() {
    const s = state.story;
    $("#story-title").textContent = s.title;
    document.title = s.title;
    $("#source-repo").textContent = s.source.repository + (s.source.branch ? ` (${s.source.branch})` : "");
    const headCode = $("#source-head");
    headCode.textContent = s.source.head_commit;
    headCode.title = `git -C <repo> show ${s.source.head_commit}`;
    $("#source-count").textContent = `${s.stats.commit_count} (first-parent ${s.stats.first_parent_count}, merge ${s.stats.merge_count})`;
    $("#source-span").textContent = `${fmtDate(s.stats.first_commit_at)} ~ ${fmtDate(s.stats.last_commit_at)}`;
    const cur = s.curation;
    $("#source-curation").textContent = cur.override_applied
      ? `자동 ${cur.auto_episode_count}개 → 큐레이션 ${cur.curated_episode_count}개 (${cur.override_path})`
      : `자동 clustering ${cur.auto_episode_count}개 (override 없음)`;
    $("#arc-summary").textContent = s.arc_summary;
    const points = $("#arc-points");
    points.replaceChildren(...(s.arc_points || []).map((p, i) => el("li", {
      class: "arc-point", tabindex: "0", role: "button", "aria-label": `Episode ${i + 1}로 이동: ${p}`,
      onclick: () => goTo(i, true), onkeydown: (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); goTo(i, true); } },
    }, [p])));
    if (!s.arc_points || !s.arc_points.length) points.hidden = true;
  }

  // ------------------------------------------------------------------ timeline
  function renderTrack() {
    const eps = state.story.episodes;
    const track = $("#track");
    track.replaceChildren(...eps.map((ep, i) => el("button", {
      type: "button", class: "track-item", role: "listitem", "data-index": i,
      "aria-current": i === state.index ? "true" : null, "aria-label": `Episode ${ep.order}: ${ep.title}`,
      onclick: () => goTo(i, true),
    }, [
      el("span", { class: "t-order", text: `Episode ${ep.order} · ${ep.commit_count} commits` }),
      el("span", { class: "t-title", text: ep.title }),
      el("span", { class: "t-dates", text: `${fmtDate(ep.started_at)} → ${fmtDate(ep.ended_at)}` }),
    ])));
    const scrub = $("#scrubber");
    scrub.max = String(eps.length);
    scrub.value = String(state.index + 1);
    scrub.setAttribute("aria-valuetext", `Episode ${state.index + 1}: ${eps[state.index].title}`);
    $("#position").textContent = `${state.index + 1} / ${eps.length}`;
    $("#btn-prev").disabled = state.index === 0;
    $("#btn-next").disabled = state.index === eps.length - 1;
    const current = track.querySelector('[aria-current="true"]');
    if (current && current.scrollIntoView && !state.scrubbing) current.scrollIntoView({ block: "nearest", inline: "nearest", behavior: state.reducedMotion ? "auto" : "smooth" });
  }

  function statusBadge(status) {
    return el("span", { class: `status status-${status}`, text: STATUS_LABEL[status] || status });
  }
  function confBadge(conf) {
    return el("span", { class: `pill pill-conf conf-${conf}`, text: CONF_LABEL[conf] || conf });
  }

  function commitChip(hash, opts) {
    const c = commitOf(hash);
    const label = short(hash);
    return el("button", {
      type: "button", class: "chip", title: c ? c.subject : hash,
      "aria-label": `commit ${label} 근거 열기${c ? ": " + c.subject : ""}`,
      onclick: () => openDrawer({ commitIds: [hash], claim: opts && opts.claim, episode: opts && opts.episode, files: opts && opts.files }),
    }, [label]);
  }

  // ------------------------------------------------------------------ episode card
  function renderEpisode() {
    const ep = state.story.episodes[state.index];
    const panel = $("#episode-panel");
    $("#episode-heading").textContent = `Episode ${ep.order} / ${state.story.episodes.length}`;
    const kinds = Object.entries(ep.stats.commit_kinds || {}).sort((a, b) => b[1] - a[1]).slice(0, 5)
      .map(([k, n]) => `${k} ${n}`).join(" · ");

    panel.replaceChildren(
      el("header", { class: "ep-head" }, [
        el("h3", { text: ep.title }),
        el("div", { class: "ep-meta" }, [
          el("span", { text: `${fmtDateTime(ep.started_at)} → ${fmtDateTime(ep.ended_at)}` }),
          el("span", { class: "pill", text: `commit ${ep.commit_count}개` }),
          el("span", { class: "pill", text: `+${ep.stats.additions} / −${ep.stats.deletions} · 파일 ${ep.stats.files_changed}개` }),
          confBadge(ep.confidence),
          ...ep.change_type.map((t) => el("span", { class: "pill pill-type", text: TYPE_LABEL[t] || t })),
          el("span", { class: "pill", text: ep.source === "override" ? "수동 큐레이션" : ep.source === "auto+patched" ? "자동+패치" : "자동 생성" }),
        ]),
        el("p", { class: "ep-summary", text: ep.summary }),
      ]),
      el("div", { class: "ep-grid" }, [
        block("1. 당시의 문제 또는 맥락", [el("p", { text: ep.problem_or_context })]),
        block("2. 무엇이 변경됐는가", [el("p", { text: ep.what_changed })]),
        block("3. 현재 코드에 남은 결과", [el("p", { text: ep.result })]),
        block("주요 변경 영역", [
          el("div", { class: "areas" }, ep.areas.map((a) => el("code", { text: a }))),
          el("p", { class: "hint", text: kinds ? `commit 유형: ${kinds}` : "" }),
          el("p", { class: "hint", text: "자주 바뀐 파일:" }),
          el("ul", {}, (ep.stats.top_files || []).slice(0, 4).map((f) => el("li", {}, [el("code", { text: f.path }), ` (${f.commits}회)`]))),
        ]),
      ]),
      block("4. 근거 commit과 claim", [
        el("ol", { class: "claims" }, ep.claims.map((claim) => renderClaim(claim, ep))),
        el("div", { class: "claim-actions" }, [
          el("button", { type: "button", class: "btn", onclick: () => openDrawer({ commitIds: ep.commit_ids, episode: ep, title: `Episode ${ep.order} 전체 commit (${ep.commit_count})` }) }, ["이 Episode의 commit 전체 보기"]),
          el("span", { class: "hint", text: `${short(ep.start_commit)} … ${short(ep.end_commit)}` }),
        ]),
      ]),
      el("div", { class: "unknowns" }, [
        el("h4", { text: "5. 확인할 수 없는 정보" }),
        el("ul", {}, (ep.unknowns || []).map((u) => el("li", { text: u }))),
      ]),
    );
    renderListCurrent();
  }

  function block(title, children) {
    return el("section", { class: "ep-block" }, [el("h4", { text: title }), ...children]);
  }

  function renderClaim(claim, ep, idPrefix) {
    return el("li", { class: "claim", id: `${idPrefix || "claim"}-${claim.id}` }, [
      el("div", { class: "claim-head" }, [statusBadge(claim.status), confBadge(claim.confidence), el("span", { class: "hint", text: claim.id })]),
      el("p", { class: "claim-text", text: claim.text }),
      el("div", { class: "claim-actions" }, [
        el("span", { class: "hint", text: "근거:" }),
        ...claim.evidence_commit_ids.map((h) => commitChip(h, { claim, episode: ep, files: claim.evidence_files })),
        claim.evidence_commit_ids.length > 1
          ? el("button", { type: "button", class: "chip", onclick: () => openDrawer({ commitIds: claim.evidence_commit_ids, claim, episode: ep, files: claim.evidence_files }) }, ["모두 열기"])
          : null,
      ]),
      claim.evidence_files && claim.evidence_files.length
        ? el("p", { class: "claim-limit" }, ["파일: ", ...claim.evidence_files.flatMap((f, i) => [i ? ", " : "", el("code", { text: f })])])
        : null,
      claim.limitations ? el("p", { class: "claim-limit", text: `한계: ${claim.limitations}` }) : null,
    ]);
  }

  // ------------------------------------------------------------------ static list + auto list
  function renderList() {
    const list = $("#episode-list");
    list.replaceChildren(...state.story.episodes.map((ep, i) => el("li", { class: "list-item", "data-index": i }, [
      el("div", { class: "ep-meta" }, [
        el("span", { text: `Episode ${ep.order}` }),
        el("span", { text: `${fmtDate(ep.started_at)} → ${fmtDate(ep.ended_at)}` }),
        el("span", { class: "pill", text: `commit ${ep.commit_count}개` }),
        confBadge(ep.confidence),
        ...ep.change_type.map((t) => el("span", { class: "pill pill-type", text: TYPE_LABEL[t] || t })),
      ]),
      el("h3", { text: ep.title }),
      el("p", { text: ep.summary }),
      el("details", {}, [
        el("summary", { text: `문제·변경·결과·claim ${ep.claims.length}개 펼치기` }),
        el("p", {}, [el("b", { text: "문제/맥락. " }), ep.problem_or_context]),
        el("p", {}, [el("b", { text: "변경. " }), ep.what_changed]),
        el("p", {}, [el("b", { text: "결과. " }), ep.result]),
        el("ol", { class: "claims" }, ep.claims.map((c) => renderClaim(c, ep, "list-claim"))),
        el("p", {}, [el("b", { text: "확인 불가. " }), (ep.unknowns || []).join(" ")]),
      ]),
      el("button", { type: "button", class: "btn", onclick: () => goTo(i, true, true) }, ["이 Episode 열기"]),
    ])));
    renderListCurrent();

    const auto = state.story.auto_episodes || [];
    const cl = state.story.clustering || {};
    $("#auto-hint").textContent = `${auto.length}개 구간. 가중치 path ${cl.weights && cl.weights.path_overlap}, message ${cl.weights && cl.weights.message_tokens}, subsystem ${cl.weights && cl.weights.subsystem}, type ${cl.weights && cl.weights.commit_type}, time ${cl.weights && cl.weights.temporal}; threshold ${cl.threshold}. ${cl.note || ""}`;
    $("#auto-list").replaceChildren(...auto.map((a) => el("li", {}, [
      el("b", { text: `${a.title}` }),
      ` · ${fmtDate(a.started_at)}→${fmtDate(a.ended_at)} · ${a.commit_count} commits · ${short(a.start_commit)}…${short(a.end_commit)}`,
      a.boundary_reasons && a.boundary_reasons.length ? ` · boundary: ${a.boundary_reasons.join(", ")}` : "",
    ])));
  }

  function renderListCurrent() {
    document.querySelectorAll(".list-item").forEach((li) => {
      li.setAttribute("aria-current", Number(li.dataset.index) === state.index ? "true" : "false");
    });
  }

  // ------------------------------------------------------------------ navigation / playback
  function goTo(i, focus, scrollToPanel) {
    const n = state.story.episodes.length;
    state.index = Math.max(0, Math.min(n - 1, i));
    renderTrack();
    renderEpisode();
    if (state.playing) restartTick();
    if (focus) $("#episode-panel").focus({ preventScroll: !scrollToPanel });
    if (scrollToPanel) $("#episode-panel").scrollIntoView({ behavior: state.reducedMotion ? "auto" : "smooth", block: "start" });
  }

  function setPlaying(on) {
    state.playing = on;
    const btn = $("#btn-play");
    btn.textContent = on ? "⏸ 정지" : "▶ 재생";
    btn.setAttribute("aria-pressed", on ? "true" : "false");
    if (on) restartTick();
    else stopTick();
  }

  function restartTick() {
    stopTick();
    state.tickStart = performance.now();
    state.timer = setTimeout(() => {
      if (state.index >= state.story.episodes.length - 1) { setPlaying(false); setProgress(1); return; }
      goTo(state.index + 1, false);
    }, state.interval);
    if (state.reducedMotion) { setProgress(0); return; }
    const tick = () => {
      const p = Math.min(1, (performance.now() - state.tickStart) / state.interval);
      setProgress(p);
      if (state.playing) state.tickTimer = requestAnimationFrame(tick);
    };
    state.tickTimer = requestAnimationFrame(tick);
  }

  function stopTick() {
    if (state.timer) clearTimeout(state.timer);
    if (state.tickTimer) cancelAnimationFrame(state.tickTimer);
    state.timer = null;
    state.tickTimer = null;
    setProgress(0);
  }

  function setProgress(p) {
    $("#progress-fill").style.width = `${Math.round(p * 100)}%`;
  }

  // ------------------------------------------------------------------ evidence drawer
  function openDrawer(opts) {
    if (state.playing) setPlaying(false);
    const drawer = $("#drawer");
    const body = $("#drawer-body");
    const title = opts.title || (opts.claim ? `claim ${opts.claim.id} 근거` : `commit 근거`);
    $("#drawer-title").textContent = title;
    body.replaceChildren();
    if (opts.claim) {
      body.appendChild(el("div", { class: "ev-why" }, [
        el("div", { class: "claim-head" }, [statusBadge(opts.claim.status), confBadge(opts.claim.confidence)]),
        el("p", { text: opts.claim.text }),
        opts.claim.evidence_reason ? el("p", {}, [el("b", { text: "연결 이유. " }), opts.claim.evidence_reason]) : null,
        opts.claim.limitations ? el("p", {}, [el("b", { text: "한계. " }), opts.claim.limitations]) : null,
      ]));
    }
    const ids = opts.commitIds || [];
    const limit = 40;
    ids.slice(0, limit).forEach((h) => body.appendChild(renderCommitEvidence(h, opts)));
    if (ids.length > limit) body.appendChild(el("p", { class: "hint", text: `… ${ids.length - limit}개 commit 더 있음. 전체 목록은 commits.json 또는 git log를 확인.` }));
    drawer.setAttribute("aria-hidden", "false");
    drawer.inert = false;
    $("#drawer-backdrop").hidden = false;
    state.lastFocus = document.activeElement;
    for (const region of document.querySelectorAll("header.masthead, main.layout, footer.footer, .skip-link")) region.inert = true;
    $("#drawer-close").focus();
  }

  function isDrawerOpen() {
    return $("#drawer").getAttribute("aria-hidden") === "false";
  }

  function closeDrawer() {
    const drawer = $("#drawer");
    drawer.setAttribute("aria-hidden", "true");
    drawer.inert = true;
    $("#drawer-backdrop").hidden = true;
    for (const region of document.querySelectorAll("header.masthead, main.layout, footer.footer, .skip-link")) region.inert = false;
    $("#drawer-body").replaceChildren();
    const target = state.lastFocus && document.contains(state.lastFocus) ? state.lastFocus : $("#episode-panel");
    if (target && target.focus) target.focus({ preventScroll: true });
    state.lastFocus = null;
  }

  function renderCommitEvidence(hash, opts) {
    const c = commitOf(hash);
    const hl = new Set(opts.files || []);
    const excerpts = (state.story.evidence_excerpts || {})[hash] || {};
    const repoPathHint = "<repo>";
    if (!c) {
      return el("section", { class: "ev-commit" }, [el("h3", { text: short(hash) }), el("p", { class: "empty", text: "commits.json에 이 commit 메타데이터가 없다." })]);
    }
    const gh = githubUrl(hash);
    const files = c.files || [];
    const sortedFiles = [...files].sort((a, b) => (hl.has(b.path) - hl.has(a.path)) || ((b.additions + b.deletions) - (a.additions + a.deletions)));
    return el("section", { class: "ev-commit" }, [
      el("h3", { text: c.subject }),
      el("dl", { class: "ev-meta" }, [
        el("dt", { text: "hash" }), el("dd", {}, [el("code", { text: c.hash })]),
        el("dt", { text: "일시" }), el("dd", { text: c.authored_at }),
        el("dt", { text: "author" }), el("dd", { text: c.author }),
        el("dt", { text: "변경" }), el("dd", { text: `${files.length} files · +${c.additions} / −${c.deletions}${c.is_merge ? " · merge" : ""}${c.tags && c.tags.length ? " · tag " + c.tags.join(", ") : ""}` }),
        c.reverts_commit ? el("dt", { text: "revert" }) : null, c.reverts_commit ? el("dd", {}, [el("code", { text: short(c.reverts_commit) }), ` "${c.reverts_subject}"`]) : null,
        c.merged_by ? el("dt", { text: "merged by" }) : null, c.merged_by ? el("dd", {}, [el("code", { text: short(c.merged_by) })]) : null,
        c.cc_type ? el("dt", { text: "type" }) : null, c.cc_type ? el("dd", { text: `${c.cc_type}${c.cc_scope ? "(" + c.cc_scope + ")" : ""}` }) : null,
      ]),
      c.body ? el("pre", { class: "cmd", text: c.body }) : null,
      opts.claim ? el("div", { class: "ev-why" }, [
        el("b", { text: "이 commit이 claim과 연결된 이유. " }),
        opts.claim.evidence_reason || "claim의 evidence_commit_ids에 명시됐다.",
        hl.size ? ` 강조된 파일이 claim의 evidence_files다.` : "",
      ]) : null,
      el("h4", { text: `changed files (${files.length})` }),
      el("ul", { class: "files" }, sortedFiles.map((f) => el("li", {}, [
        el("span", { class: "st", text: f.status }),
        el("span", { class: `path${hl.has(f.path) ? " hl" : ""}`, text: f.old_path ? `${f.old_path} → ${f.path}` : f.path }),
        el("span", { class: "nums" }, [el("span", { class: "add", text: f.binary ? "bin" : `+${f.additions}` }), " ", el("span", { class: "del", text: f.binary ? "" : `−${f.deletions}` })]),
      ]))),
      ...Object.entries(excerpts).map(([path, ex]) => el("div", {}, [
        el("h4", {}, ["diff excerpt · ", el("code", { text: path }), ex.truncated ? ` (앞 ${ex.lines.length}줄 / 전체 ${ex.total_lines}줄)` : ""]),
        el("pre", { class: "diff" }, ex.lines.length ? ex.lines.flatMap((l) => [el("span", { class: l.startsWith("+") ? "ln-add" : l.startsWith("-") ? "ln-del" : l.startsWith("@@") ? "ln-hunk" : "", text: l }), "\n"]) : [ex.error || "(excerpt 없음)"]),
      ])),
      el("h4", { text: "raw diff 확인" }),
      el("pre", { class: "cmd", text: `git -C ${repoPathHint} show ${c.hash}` }),
      gh ? el("p", {}, [el("a", { href: gh, target: "_blank", rel: "noopener", text: gh })]) : null,
    ]);
  }

  // ------------------------------------------------------------------ wiring
  function bind() {
    $("#btn-prev").addEventListener("click", () => goTo(state.index - 1, true));
    $("#btn-next").addEventListener("click", () => goTo(state.index + 1, true));
    $("#btn-play").addEventListener("click", () => setPlaying(!state.playing));
    $("#btn-list").addEventListener("click", () => {
      if (state.playing) setPlaying(false);
      $("#list-section").scrollIntoView({ behavior: state.reducedMotion ? "auto" : "smooth" });
      $("#list-heading").setAttribute("tabindex", "-1");
      $("#list-heading").focus();
    });
    $("#scrubber").addEventListener("input", (e) => { state.scrubbing = true; goTo(Number(e.target.value) - 1, false); state.scrubbing = false; });
    $("#scrubber").addEventListener("change", () => renderTrack());
    $("#interval").addEventListener("change", (e) => { state.interval = Number(e.target.value); if (state.playing) restartTick(); });
    $("#drawer-close").addEventListener("click", closeDrawer);
    $("#drawer-backdrop").addEventListener("click", closeDrawer);
    document.addEventListener("keydown", (e) => {
      const tag = (e.target.tagName || "").toLowerCase();
      const inputType = tag === "input" ? (e.target.getAttribute("type") || "text").toLowerCase() : "";
      const editing = tag === "select" || tag === "textarea" || (tag === "input" && inputType !== "range");
      if (e.key === "Escape") {
        if (isDrawerOpen()) { closeDrawer(); return; }
        if (state.playing) setPlaying(false);
        $("#btn-list").click();
        return;
      }
      if (isDrawerOpen() || editing) return;
      if (e.key === "ArrowLeft") { e.preventDefault(); goTo(state.index - 1, true); }
      else if (e.key === "ArrowRight") { e.preventDefault(); goTo(state.index + 1, true); }
      else if (e.key === " " && tag !== "button" && tag !== "input" && tag !== "select" && tag !== "a" && tag !== "summary") { e.preventDefault(); setPlaying(!state.playing); }
    });
    window.addEventListener("hashchange", applyHash);
  }

  function applyHash() {
    const m = /^#episode-(\d+)$/.exec(location.hash);
    if (m) goTo(Number(m[1]) - 1, false);
  }

  async function main() {
    $("#drawer").inert = true;
    try {
      await load();
    } catch (err) {
      console.error(err);
      $("#episode-panel").appendChild($("#tpl-empty").content.cloneNode(true));
      $("#story-title").textContent = "story.json 을 불러올 수 없음";
      return;
    }
    if (!state.story.episodes || !state.story.episodes.length) {
      $("#episode-panel").textContent = "Episode가 없다.";
      return;
    }
    renderHeader();
    bind();
    renderList();
    applyHash();
    renderTrack();
    renderEpisode();
  }

  main();
})();
