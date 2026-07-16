import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const restoreScript = path.resolve(import.meta.dirname, "restore_db.sh");
const backupPath = "/data/backups/verified.backup";

const scenarios = {
  stop: { safety: 0, target: 0, rollback: 0, up: 1, ready: 0 },
  "safety-backup": { safety: 1, target: 0, rollback: 0, up: 1, ready: 0 },
  replacement: { safety: 1, target: 1, rollback: 1, up: 1, ready: 0 },
  signal: { safety: 1, target: 1, rollback: 1, up: 1, ready: 0 },
  startup: { safety: 1, target: 1, rollback: 1, stop: 2, up: 2, ready: 0 },
  readiness: { safety: 1, target: 1, rollback: 1, stop: 2, up: 2, ready: 2 },
  success: { safety: 1, target: 1, rollback: 0, up: 1, ready: 1 },
};

for (const [scenario, expected] of Object.entries(scenarios)) {
  test(`restore recovery: ${scenario}`, async () => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), "klms-restore-test-"));
    const bin = path.join(root, "bin");
    const logPath = path.join(root, "compose.log");
    const upCountPath = path.join(root, "up.count");
    await fs.mkdir(bin, { recursive: true });
    const dockerPath = path.join(bin, "docker");
    await fs.writeFile(dockerPath, `#!/bin/sh
set -eu
previous=""
last=""
for argument in "$@"; do
  previous="$last"
  last="$argument"
done
if [ "$previous" = "${backupPath}" ]; then
  printf '%s\\n' TARGET_REPLACE >> "$MOCK_COMPOSE_LOG"
  if [ "$MOCK_SCENARIO" = replacement ]; then exit 42; fi
  if [ "$MOCK_SCENARIO" = signal ]; then
    kill -TERM "$PPID"
    sleep 0.1
    exit 143
  fi
  exit 0
fi
case "$previous" in
  /data/backups/pre-restore-*.backup)
    printf '%s\\n' ROLLBACK_COPY >> "$MOCK_COMPOSE_LOG"
    exit 0
    ;;
esac
case "$*" in
  *"--verify-backup ${backupPath}"*)
    printf '%s\\n' VERIFY >> "$MOCK_COMPOSE_LOG"
    exit 0
    ;;
  *"--backup /data/backups/pre-restore-"*)
    printf '%s\\n' SAFETY_BACKUP >> "$MOCK_COMPOSE_LOG"
    if [ "$MOCK_SCENARIO" = safety-backup ]; then exit 42; fi
    exit 0
    ;;
  *" stop relay")
    printf '%s\\n' STOP >> "$MOCK_COMPOSE_LOG"
    if [ "$MOCK_SCENARIO" = stop ]; then exit 42; fi
    exit 0
    ;;
  *" up -d --force-recreate relay")
    printf '%s\\n' UP >> "$MOCK_COMPOSE_LOG"
    count=0
    if [ -f "$MOCK_UP_COUNT" ]; then count="$(sed -n '1p' "$MOCK_UP_COUNT")"; fi
    count=$((count + 1))
    printf '%s\\n' "$count" > "$MOCK_UP_COUNT"
    if [ "$MOCK_SCENARIO" = startup ] && [ "$count" -eq 1 ]; then exit 42; fi
    exit 0
    ;;
esac
case "$last" in
  *"fetch('http://127.0.0.1:18484/readyz',"*)
    printf '%s\\n' READY >> "$MOCK_COMPOSE_LOG"
    if [ "$MOCK_SCENARIO" = readiness ]; then exit 1; fi
    exit 0
    ;;
esac
printf '%s\\n' OTHER >> "$MOCK_COMPOSE_LOG"
exit 0
`, { mode: 0o755 });

    const result = await run("sh", [restoreScript, backupPath], {
      cwd: root,
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH || ""}`,
        MOCK_COMPOSE_LOG: logPath,
        MOCK_UP_COUNT: upCountPath,
        MOCK_SCENARIO: scenario,
        KLMS_RELAY_RESTORE_READINESS_ATTEMPTS: "2",
        KLMS_RELAY_RESTORE_READINESS_DELAY_SECONDS: "0",
      },
    });
    const markers = (await fs.readFile(logPath, "utf8")).trim().split("\n").filter(Boolean);
    const count = (value) => markers.filter((marker) => marker === value).length;

    assert.equal(count("VERIFY"), 1);
    assert.equal(count("STOP"), expected.stop ?? 1);
    assert.equal(count("SAFETY_BACKUP"), expected.safety, result.stderr);
    assert.equal(count("TARGET_REPLACE"), expected.target, result.stderr);
    assert.equal(count("ROLLBACK_COPY"), expected.rollback, result.stderr);
    assert.equal(count("UP"), expected.up, result.stderr);
    assert.equal(count("READY"), expected.ready, result.stderr);
    if (expected.rollback === 1 && (scenario === "startup" || scenario === "readiness")) {
      const secondStop = markers.lastIndexOf("STOP");
      assert.ok(secondStop > markers.indexOf("UP"), result.stderr);
      assert.ok(secondStop < markers.indexOf("ROLLBACK_COPY"), result.stderr);
    }
    if (scenario === "success") {
      assert.equal(result.code, 0, result.stderr);
    } else {
      assert.notEqual(result.code, 0);
      assert.match(
        result.stderr,
        expected.rollback === 1 ? /rolling back/ : /before the safety backup completed/,
      );
    }
  });
}

function run(command, args, options) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { ...options, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    child.once("exit", (code) => resolve({ code, stdout, stderr }));
  });
}
