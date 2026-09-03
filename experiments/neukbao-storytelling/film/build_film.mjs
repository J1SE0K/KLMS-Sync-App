/* Render the storytelling film.
 *
 *   node build_film.mjs --probe          only a few sample frames, for checking layout
 *   node build_film.mjs                  full render + narration mux
 *
 * The page exposes filmRender(t), so frames are grabbed deterministically rather than
 * recorded in real time. That keeps the picture exactly in sync with the narration track,
 * which is assembled from the same per-scene durations in timings.json.
 */
import { chromium } from "playwright";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..");
const PORT = Number(process.env.FILM_PORT || 4175);
const FPS = 20;
const PROBE = process.argv.includes("--probe");
const FRAMES = path.join(HERE, "frames");
const OUT = path.join(ROOT, "public", "storytelling-film.mp4");

const FFMPEG = process.env.FFMPEG || findFfmpeg();
function findFfmpeg() {
  const winget = path.join(process.env.LOCALAPPDATA || "", "Microsoft/WinGet/Packages");
  if (fs.existsSync(winget)) {
    for (const pkg of fs.readdirSync(winget)) {
      if (!/ffmpeg/i.test(pkg)) continue;
      const base = path.join(winget, pkg);
      for (const build of fs.readdirSync(base)) {
        const exe = path.join(base, build, "bin", "ffmpeg.exe");
        if (fs.existsSync(exe)) return exe;
      }
    }
  }
  return "ffmpeg";
}
const run = (exe, args) => {
  const r = spawnSync(exe, args, { encoding: "utf8", maxBuffer: 1 << 28 });
  if (r.status !== 0) throw new Error(`${path.basename(exe)} failed: ${(r.stderr || "").split("\n").slice(-6).join("\n")}`);
  return r.stdout;
};

// ------------------------------------------------------------------ serve
const server = spawn("python", ["-m", "http.server", String(PORT), "--bind", "127.0.0.1", "-d", ROOT], { stdio: "ignore" });
const stopServer = () => { try { server.kill(); } catch {} };
process.on("exit", stopServer);
await new Promise((r) => setTimeout(r, 1200));

// ------------------------------------------------------------------ render frames
const browser = await chromium.launch({ args: ["--force-color-profile=srgb", "--font-render-hinting=none"] });
const page = await browser.newPage({ viewport: { width: 1600, height: 900 }, deviceScaleFactor: 1 });
const pageErrors = [];
page.on("pageerror", (e) => pageErrors.push(e.message));

await page.goto(`http://127.0.0.1:${PORT}/film/film.html`, { waitUntil: "networkidle" });
const info = await page.evaluate(() => window.filmReady);
console.log(`film: ${info.total.toFixed(1)}s, ${info.scenes.length} scenes`);
info.scenes.forEach((s) => console.log(`  ${s.id.padEnd(14)} start ${s.start.toFixed(1).padStart(6)}s  dur ${s.dur.toFixed(1)}s`));

fs.rmSync(FRAMES, { recursive: true, force: true });
fs.mkdirSync(FRAMES, { recursive: true });

if (PROBE) {
  const probeDir = path.join(HERE, "probe");
  fs.rmSync(probeDir, { recursive: true, force: true });
  fs.mkdirSync(probeDir, { recursive: true });
  for (const s of info.scenes) {
    const t = s.start + Math.min(s.dur - 0.3, s.dur * 0.72);
    await page.evaluate((tt) => window.filmRender(tt), t);
    await page.screenshot({ path: path.join(probeDir, `${s.id}.jpg`), type: "jpeg", quality: 88 });
  }
  console.log("probe frames:", fs.readdirSync(probeDir).join(", "));
  if (pageErrors.length) console.log("page errors:", pageErrors);
  await browser.close();
  stopServer();
  process.exit(0);
}

const total = info.total;
const frameCount = Math.round(total * FPS);
const started = Date.now();
for (let i = 0; i < frameCount; i++) {
  const t = i / FPS;
  await page.evaluate((tt) => window.filmRender(tt), t);
  await page.screenshot({ path: path.join(FRAMES, String(i).padStart(6, "0") + ".jpg"), type: "jpeg", quality: 92 });
  if (i % 200 === 0 || i === frameCount - 1) {
    const done = i + 1;
    const rate = done / ((Date.now() - started) / 1000);
    console.log(`  frame ${done}/${frameCount}  ${rate.toFixed(1)} fps  eta ${((frameCount - done) / rate).toFixed(0)}s`);
  }
}
if (pageErrors.length) console.log("page errors:", pageErrors);
await browser.close();
stopServer();

// ------------------------------------------------------------------ narration track
const timings = JSON.parse(fs.readFileSync(path.join(HERE, "timings.json"), "utf8"));
const script = JSON.parse(fs.readFileSync(path.join(HERE, "script.json"), "utf8"));
const work = path.join(HERE, "audio");
fs.rmSync(work, { recursive: true, force: true });
fs.mkdirSync(work, { recursive: true });

const parts = [];
for (const scene of script.scenes) {
  const src = path.join(HERE, "narration", `${scene.id}.wav`);
  const dst = path.join(work, `${scene.id}.wav`);
  const hold = scene.hold || 0;
  // pad each narration with its scene hold so the audio length equals the scene length exactly
  run(FFMPEG, ["-y", "-loglevel", "error", "-i", src, "-af", `apad=pad_dur=${hold},aresample=48000`, "-ac", "2", "-c:a", "pcm_s16le", dst]);
  parts.push(dst);
}
const listFile = path.join(work, "concat.txt");
fs.writeFileSync(listFile, parts.map((p) => `file '${p.replace(/\\/g, "/")}'`).join("\n"));
const voice = path.join(work, "narration.wav");
run(FFMPEG, ["-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", listFile, "-c:a", "pcm_s16le", voice]);

// ------------------------------------------------------------------ mux
fs.mkdirSync(path.dirname(OUT), { recursive: true });
run(FFMPEG, [
  "-y", "-loglevel", "error",
  "-framerate", String(FPS), "-i", path.join(FRAMES, "%06d.jpg"),
  "-i", voice,
  "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv420p",
  "-r", "30", "-movflags", "+faststart",
  "-c:a", "aac", "-b:a", "160k",
  "-shortest", OUT,
]);

const probe = run(FFMPEG.replace(/ffmpeg(\.exe)?$/i, (m) => m.replace("ffmpeg", "ffprobe")), [
  "-v", "error", "-show_entries", "format=duration,size", "-of", "default=nw=1", OUT,
]);
console.log("\nwrote", OUT);
console.log(probe.trim());
