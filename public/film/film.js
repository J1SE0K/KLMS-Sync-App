/* Deterministic film renderer.
   filmLoad() fetches script.json, ../story.json and timings.json (optional).
   filmRender(t) paints the exact frame at time t seconds. Nothing animates on its own,
   so a frame grabber can step through the film and stay perfectly in sync with narration. */
(function () {
  "use strict";

  const stage = () => document.getElementById("stage");
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const ease = (p) => 1 - Math.pow(1 - clamp(p, 0, 1), 3);
  const easeInOut = (p) => (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2);

  const el = (tag, cls, text) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined && text !== null) n.textContent = text;
    return n;
  };

  const state = { scenes: [], total: 0, script: null, story: null };

  // reveal: fade + rise, driven purely by t
  function reveal(node, t, start, dur, rise) {
    const p = ease((t - start) / (dur || 0.55));
    node.style.opacity = String(clamp(p, 0, 1));
    node.style.transform = `translateY(${(1 - clamp(p, 0, 1)) * (rise === undefined ? 22 : rise)}px)`;
  }

  function fade(node, t, start, dur) {
    node.style.opacity = String(clamp(ease((t - start) / (dur || 0.5)), 0, 1));
  }

  // scene-level cross fade so cuts do not flicker
  function sceneAlpha(local, dur) {
    const inP = clamp(local / 0.45, 0, 1);
    const outP = clamp((dur - local) / 0.45, 0, 1);
    return Math.min(inP, outP);
  }

  function fmtDate(iso) {
    if (!iso) return "";
    const [y, m, d] = iso.slice(0, 10).split("-");
    return `${y}.${m}.${d}`;
  }

  // ---------------------------------------------------------------- builders
  function buildCommitRain(spec) {
    const root = el("div", "scene dark");
    const rain = el("div", "rain");
    const col = el("div", "rain-col");
    const lines = [];
    for (let i = 0; i < 60; i++) {
      const src = spec.lines[i % spec.lines.length];
      const line = el("div", "rain-line", src);
      col.appendChild(line);
      lines.push(line);
    }
    rain.appendChild(col);
    root.appendChild(rain);
    root.appendChild(el("div", "rain-veil"));
    const count = el("div", "rain-count");
    const num = el("span", null, "0");
    count.appendChild(num);
    const cap = el("small", null, "commits");
    count.appendChild(cap);
    root.appendChild(count);
    return {
      root,
      paint(local, dur) {
        root.style.opacity = String(sceneAlpha(local, dur));
        const speed = 118;
        const y = -((local * speed) % (lines.length * 45));
        col.style.transform = `translateY(${y}px)`;
        lines.forEach((n, i) => {
          const hot = Math.floor(local * 3.1) % lines.length === i;
          n.className = "rain-line" + (hot ? " hot" : "");
        });
        const cs = dur * 0.42;
        const p = easeInOut(clamp((local - cs) / 1.5, 0, 1));
        num.textContent = String(Math.round(p * 1184));
        count.style.opacity = String(clamp((local - cs) / 0.4, 0, 1));
        const s = 0.86 + 0.14 * p;
        count.style.transform = `translate(-50%, -50%) scale(${s})`;
        rain.style.opacity = String(1 - 0.55 * p);
      },
    };
  }

  function buildQuestion(spec) {
    const root = el("div", "scene dark");
    const wrap = el("div", "center");
    const big = el("div", "big", spec.big);
    const rule = el("div", "rule");
    const small = el("div", "small", spec.small);
    wrap.append(big, rule, small);
    root.appendChild(wrap);
    return {
      root,
      paint(local, dur) {
        root.style.opacity = String(sceneAlpha(local, dur));
        reveal(big, local, 0.15, 0.7, 26);
        fade(rule, local, 0.75, 0.5);
        reveal(small, local, 1.0, 0.7, 18);
      },
    };
  }

  function buildTitle(spec) {
    const root = el("div", "scene paper");
    const wrap = el("div", "center");
    const big = el("div", "big", spec.big);
    const rule = el("div", "rule");
    const small = el("div", "small", spec.small);
    const meta = el("div", "meta", spec.meta);
    wrap.append(big, rule, small, meta);
    root.appendChild(wrap);
    return {
      root,
      paint(local, dur) {
        root.style.opacity = String(sceneAlpha(local, dur));
        reveal(big, local, 0.1, 0.8, 30);
        fade(rule, local, 0.8, 0.5);
        reveal(small, local, 1.0, 0.6, 16);
        fade(meta, local, 1.5, 0.6);
      },
    };
  }

  function buildChapter(spec, story) {
    const ep = (story.episodes || []).find((e) => e.order === spec.episode) || {};
    const root = el("div", "scene paper");
    const ch = el("div", "chapter");
    const ghost = el("div", "ghost", String(spec.episode).padStart(2, "0"));
    const eyebrow = el("div", "ch-eyebrow", `EPISODE ${spec.episode} / 8   ·   ${fmtDate(ep.started_at)} — ${fmtDate(ep.ended_at)}   ·   commit ${ep.commit_count || 0}개`);
    const title = el("div", "ch-title", ep.title || "");
    const rows = el("div", "ch-rows");
    const mk = (k, v, mono) => {
      const r = el("div", "row");
      r.append(el("div", "row-k", k), el("div", "row-v" + (mono ? " mono" : ""), v));
      rows.appendChild(r);
      return r;
    };
    const r1 = mk("문제", spec.problem);
    const r2 = mk("변경", spec.change, true);
    const r3 = mk("남은 것", spec.result);
    const foot = el("div", "ch-foot");
    foot.appendChild(el("span", "foot-label", "근거"));
    const hashes = spec.evidence.map((h) => {
      const n = el("span", "hash", h);
      foot.appendChild(n);
      return n;
    });
    const tl = el("div", "timeline");
    const fill = el("div", "timeline-fill");
    tl.appendChild(fill);
    let counter = null, counterNum = null;
    if (spec.counter) {
      counter = el("div", "counter");
      counterNum = el("span", null, "0");
      counter.appendChild(counterNum);
      counter.appendChild(el("small", null, spec.counter.label));
    }
    ch.append(ghost, eyebrow, title, rows, foot);
    root.append(ch, tl);
    if (counter) root.appendChild(counter);
    return {
      root,
      paint(local, dur) {
        root.style.opacity = String(sceneAlpha(local, dur));
        fade(ghost, local, 0.0, 1.2);
        reveal(eyebrow, local, 0.12, 0.5, 14);
        reveal(title, local, 0.3, 0.7, 26);
        reveal(r1, local, 1.15, 0.55, 18);
        reveal(r2, local, 1.75, 0.55, 18);
        reveal(r3, local, 2.35, 0.55, 18);
        hashes.forEach((h, i) => reveal(h, local, 3.0 + i * 0.22, 0.45, 10));
        fade(foot.firstChild, local, 3.0, 0.4);
        const base = (spec.episode - 1) / 8;
        const grow = easeInOut(clamp(local / Math.max(dur - 0.4, 0.1), 0, 1)) / 8;
        fill.style.width = `${(base + grow) * 100}%`;
        if (counter) {
          const p = easeInOut(clamp((local - 1.1) / Math.max(dur - 2.2, 0.5), 0, 1));
          counterNum.textContent = String(Math.round(spec.counter.from + (spec.counter.to - spec.counter.from) * p));
          fade(counter, local, 1.1, 0.5);
        }
      },
    };
  }

  function buildEvidence(spec) {
    const root = el("div", "scene paper");
    const wrap = el("div", "ev-wrap");
    const head = el("div", "ev-head", "모든 문장에는 등급이 있다");
    wrap.appendChild(head);
    const rows = spec.rows.map((r) => {
      const row = el("div", "ev-row");
      row.appendChild(el("span", `badge b-${r.status}`, r.status));
      const num = el("div", "ev-count", "0");
      row.appendChild(num);
      row.appendChild(el("div", "ev-label", r.label));
      wrap.appendChild(row);
      return { row, num, target: r.count };
    });
    root.appendChild(wrap);
    return {
      root,
      paint(local, dur) {
        root.style.opacity = String(sceneAlpha(local, dur));
        reveal(head, local, 0.1, 0.6, 20);
        rows.forEach((r, i) => {
          const s = 0.7 + i * 0.75;
          reveal(r.row, local, s, 0.55, 20);
          const p = easeInOut(clamp((local - s - 0.15) / 0.9, 0, 1));
          r.num.textContent = String(Math.round(r.target * p));
        });
      },
    };
  }

  function buildInferred(spec) {
    const root = el("div", "scene paper");
    const wrap = el("div", "inf-wrap");
    const badge = el("span", "badge b-inferred", "inferred · 추정");
    badge.style.alignSelf = "flex-start";
    const claim = el("div", "inf-claim", spec.claim);
    const limit = el("div", "inf-limit", spec.limitation);
    wrap.append(badge, claim, limit);
    root.appendChild(wrap);
    return {
      root,
      paint(local, dur) {
        root.style.opacity = String(sceneAlpha(local, dur));
        reveal(badge, local, 0.1, 0.5, 14);
        reveal(claim, local, 0.5, 0.7, 24);
        reveal(limit, local, 1.6, 0.7, 24);
      },
    };
  }

  function buildClosing(spec) {
    const root = el("div", "scene paper");
    const wrap = el("div", "center");
    const big = el("div", "big big-sm", spec.big);
    const rule = el("div", "rule");
    const meta = el("div", "meta", spec.meta);
    wrap.append(big, rule, meta);
    root.appendChild(wrap);
    const credit = el("div", "credit", spec.credit);
    root.appendChild(credit);
    return {
      root,
      paint(local, dur) {
        root.style.opacity = String(sceneAlpha(local, dur));
        reveal(big, local, 0.15, 0.9, 26);
        fade(rule, local, 1.1, 0.5);
        fade(meta, local, 1.4, 0.6);
        fade(credit, local, 2.0, 0.8);
      },
    };
  }

  const BUILDERS = {
    "commit-rain": buildCommitRain,
    question: buildQuestion,
    title: buildTitle,
    chapter: buildChapter,
    evidence: buildEvidence,
    inferred: buildInferred,
    closing: buildClosing,
  };

  // ---------------------------------------------------------------- public
  async function filmLoad() {
    const [script, story] = await Promise.all([
      fetch("script.json").then((r) => r.json()),
      fetch("../story.json").then((r) => r.json()),
    ]);
    let timings = null;
    try {
      const r = await fetch("timings.json");
      if (r.ok) timings = await r.json();
    } catch (e) { /* narration not generated yet */ }

    state.script = script;
    state.story = story;
    const host = stage();
    host.replaceChildren();

    let cursor = 0;
    state.scenes = script.scenes.map((spec) => {
      const build = BUILDERS[spec.kind];
      const scene = build(spec, story);
      scene.root.style.opacity = "0";
      host.appendChild(scene.root);
      const narrated = timings && timings[spec.id] ? timings[spec.id] : estimate(spec.narration);
      const dur = narrated + (spec.hold || 0.8);
      const entry = { id: spec.id, start: cursor, dur, scene };
      cursor += dur;
      return entry;
    });
    state.total = cursor;
    document.body.dataset.total = String(cursor);
    return { total: cursor, scenes: state.scenes.map((s) => ({ id: s.id, start: s.start, dur: s.dur })) };
  }

  // rough fallback: Korean narration reads at ~5.2 characters per second
  function estimate(text) {
    return Math.max(2.2, (text || "").length / 5.2);
  }

  function filmRender(t) {
    for (const entry of state.scenes) {
      const local = t - entry.start;
      const active = local >= -0.001 && local < entry.dur;
      entry.scene.root.style.display = active ? "block" : "none";
      if (active) entry.scene.paint(local, entry.dur);
    }
  }

  window.filmLoad = filmLoad;
  window.filmRender = filmRender;
  window.filmTotal = () => state.total;
})();
