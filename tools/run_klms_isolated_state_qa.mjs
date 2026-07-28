#!/usr/bin/env node

import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const evidenceArgument = process.argv[2];
if (!evidenceArgument) {
  console.error("usage: tools/run_klms_isolated_state_qa.mjs <private-evidence-directory>");
  process.exit(64);
}

const evidenceDirectory = path.resolve(evidenceArgument);
const requireClean = process.env.KLMS_ISOLATED_QA_REQUIRE_CLEAN !== "0";
const latencySampleCount = 30;
const latencyP95LimitMilliseconds = 1_000;
const runNonce = `${process.pid}-${crypto.randomBytes(4).toString("hex")}`;
const displayNonce = crypto.randomBytes(4).toString("hex").match(/.{1,2}/g).join("-");
const qaRoot = path.join("/private/tmp", `klms-isolated-qa-${runNonce}`);
const qaAppPath = path.join(evidenceDirectory, "KLMS Sync Isolated QA.app");
const probePath = path.join(evidenceDirectory, "probe-klms-mac-realtime");
const eventLogPath = path.join(qaRoot, "isolated-qa-events.jsonl");
const copiedEventLogPath = path.join(evidenceDirectory, "isolated-qa-events.jsonl");
const reportPath = path.join(evidenceDirectory, "isolated-runtime-report.json");
const scratchPath = path.join(evidenceDirectory, "swift-build");
const relayDatabasePath = path.join(qaRoot, "relay.sqlite3");
const relayFilesPath = path.join(qaRoot, "relay-files");
const clientToken = crypto.randomBytes(32).toString("hex");
const workerToken = crypto.randomBytes(32).toString("hex");
const childProcesses = new Set();

let appProcess = null;
let relay = null;
let bundleIdentifier = "";
let appLaunchCount = 0;
let report = null;

try {
  await preparePrivateDirectory(evidenceDirectory);
  await preparePrivateDirectory(qaRoot);
  const candidate = (await runCapture("/usr/bin/git", ["-C", repoRoot, "rev-parse", "HEAD"])).trim();
  if (!/^[0-9a-f]{40}$/.test(candidate)) {
    throw new Error("unable to resolve exact candidate commit");
  }
  const worktreeStatus = await runCapture(
    "/usr/bin/git",
    ["-C", repoRoot, "status", "--porcelain", "--untracked-files=all"],
  );
  if (requireClean && worktreeStatus.trim()) {
    throw new Error("isolated runtime QA requires a clean worktree");
  }

  bundleIdentifier = `com.local.KLMSync.QA.r${candidate.slice(0, 8)}.${runNonce.replaceAll("-", ".")}`;
  const appName = `KLMS Sync QA ${candidate.slice(0, 8)}`;
  await runLogged(
    path.join(repoRoot, "tools", "build_klms_mac_app.sh"),
    [],
    {
      environment: {
        APP_NAME: appName,
        BUNDLE_ID: bundleIdentifier,
        OUTPUT_APP: qaAppPath,
        SWIFT_SCRATCH_PATH: scratchPath,
        KLMS_PAYLOAD_REQUIRE_CLEAN: requireClean ? "1" : "0",
      },
      logPath: path.join(evidenceDirectory, "app-build.log"),
      timeoutMilliseconds: 1_800_000,
    },
  );
  await runLogged(
    "/usr/bin/xcrun",
    [
      "swiftc",
      path.join(repoRoot, "tools", "probe_klms_mac_realtime.swift"),
      "-framework",
      "AppKit",
      "-framework",
      "ApplicationServices",
      "-o",
      probePath,
    ],
    {
      logPath: path.join(evidenceDirectory, "probe-build.log"),
      timeoutMilliseconds: 120_000,
    },
  );
  await fsp.chmod(probePath, 0o700);

  const port = await reserveLoopbackPort();
  const relayURL = `http://127.0.0.1:${port}`;
  relay = await startRelay({ port, responseDelayMilliseconds: 0, sequence: 1 });

  const pollingResponse = await fetch(`${relayURL}/v1/events/poll`);
  if (pollingResponse.status !== 410) {
    throw new Error(`legacy event polling must stay removed; received ${pollingResponse.status}`);
  }

  appProcess = await launchApp(relayURL);
  await waitForQAEvent("profile-initialized", 1, 15_000);
  await waitForQAEvent("websocket-connected", 1, 15_000);
  await waitForQAEvent("permission-request-recorded", 1, 15_000);
  await probeVisibleText({
    title: "동적 계획법 연습 문제 제출",
    commitEpochMilliseconds: Date.now(),
    workspace: "tasks",
    timeoutSeconds: 12,
  });

  const initialTitle = `격리 초기 항목 ${displayNonce}`;
  const initialCommit = await publishSyncData(relayURL, initialTitle);
  await probeVisibleText({
    title: initialTitle,
    commitEpochMilliseconds: initialCommit.commitEpochMilliseconds,
    timeoutSeconds: 6,
  });

  const latencySamples = [];
  for (let index = 0; index < latencySampleCount; index += 1) {
    const title = `실시간 반영 ${String(index + 1).padStart(2, "0")} ${displayNonce}`;
    const commit = await publishSyncData(relayURL, title);
    const observation = await probeVisibleText({
      title,
      commitEpochMilliseconds: commit.commitEpochMilliseconds,
      timeoutSeconds: 5,
    });
    latencySamples.push(observation.elapsedMs);
  }
  const latencySummary = summarizeLatency(latencySamples);
  if (latencySummary.p95Ms > latencyP95LimitMilliseconds) {
    throw new Error(
      `WebSocket commit-to-visible p95 ${latencySummary.p95Ms.toFixed(1)}ms exceeds ${latencyP95LimitMilliseconds}ms`,
    );
  }

  const offlineCountBefore = (await readQAEvents()).filter((item) => item.event === "websocket-offline").length;
  const connectedCountBefore = (await readQAEvents()).filter((item) => item.event === "websocket-connected").length;
  const lastAppliedRevisionBeforeDisconnect = (await readQAEvents())
    .filter((item) => item.event === "snapshot-applied" && Number.isSafeInteger(item.revision))
    .at(-1)?.revision;
  if (!Number.isSafeInteger(lastAppliedRevisionBeforeDisconnect)) {
    throw new Error("missing applied revision before reconnect test");
  }
  await stopRelay();
  await waitForQAEvent("websocket-offline", offlineCountBefore + 3, 12_000);
  relay = await startRelay({ port, responseDelayMilliseconds: 0, sequence: 2 });
  await publishSyncData(relayURL, `revision gap 1 ${displayNonce}`);
  await publishSyncData(relayURL, `revision gap 2 ${displayNonce}`);
  const gapTitle = `revision gap latest ${displayNonce}`;
  const gapCommit = await publishSyncData(relayURL, gapTitle);
  const reconnectEvent = await waitForQAEvent(
    "websocket-connected",
    connectedCountBefore + 1,
    15_000,
  );
  if (!Number.isSafeInteger(reconnectEvent.revision)
      || reconnectEvent.revision <= lastAppliedRevisionBeforeDisconnect + 1) {
    throw new Error("reconnect did not observe the intended multi-revision gap");
  }
  await probeVisibleText({
    title: gapTitle,
    commitEpochMilliseconds: gapCommit.commitEpochMilliseconds,
    timeoutSeconds: 10,
  });

  const staleOldTitle = `지연된 예전 응답 ${displayNonce}`;
  const staleOldCommit = await publishSyncData(relayURL, staleOldTitle);
  await probeVisibleText({
    title: staleOldTitle,
    commitEpochMilliseconds: staleOldCommit.commitEpochMilliseconds,
    timeoutSeconds: 6,
  });
  await terminateApp();
  await stopRelay();

  relay = await startRelay({ port, responseDelayMilliseconds: 1_200, sequence: 3 });
  const profileCountBeforeRelaunch = (await readQAEvents()).filter(
    (item) => item.event === "profile-initialized",
  ).length;
  const connectedCountBeforeRelaunch = (await readQAEvents()).filter(
    (item) => item.event === "websocket-connected",
  ).length;
  appProcess = await launchApp(relayURL);
  await waitForQAEvent("profile-initialized", profileCountBeforeRelaunch + 1, 15_000);
  await waitForQAEvent("websocket-connected", connectedCountBeforeRelaunch + 1, 15_000);
  const capturedResponse = await relay.waitForTestEvent(
    (item) => item.testEvent === "sync-data-response-captured",
    15_000,
  );

  const staleNewTitle = `최신 응답 유지 ${displayNonce}`;
  const staleNewCommit = await publishSyncData(relayURL, staleNewTitle);
  if (!Number.isSafeInteger(capturedResponse.revision)
      || capturedResponse.revision < staleOldCommit.revision
      || capturedResponse.revision >= staleNewCommit.revision) {
    throw new Error("delayed response did not capture a revision older than the WebSocket update");
  }
  await probeVisibleText({
    title: staleNewTitle,
    commitEpochMilliseconds: staleNewCommit.commitEpochMilliseconds,
    workspace: "tasks",
    timeoutSeconds: 10,
  });
  await sleep(1_500);
  await probeVisibleText({
    title: staleNewTitle,
    commitEpochMilliseconds: staleNewCommit.commitEpochMilliseconds,
    timeoutSeconds: 6,
  });

  const qaEvents = await readQAEvents();
  const permissionRequestCount = qaEvents.filter(
    (item) => item.event === "permission-request-recorded",
  ).length;
  if (permissionRequestCount !== 1) {
    throw new Error(`automatic permission request must be recorded once; observed ${permissionRequestCount}`);
  }
  const gapRecoveryEvents = qaEvents.filter((item) => item.event === "revision-gap-recovered");
  const offlineEvents = qaEvents.filter((item) => item.event === "websocket-offline");
  const connectedEvents = qaEvents.filter((item) => item.event === "websocket-connected");
  if (offlineEvents.length < 3 || connectedEvents.length < 2) {
    throw new Error("reconnect evidence is incomplete");
  }

  report = {
    schemaVersion: 1,
    status: "pass",
    candidate,
    candidateClean: !worktreeStatus.trim(),
    generatedAt: new Date().toISOString(),
    bundleIdentifier,
    isolation: {
      productionBundleUsed: false,
      productionPreferencesModified: false,
      productionPermissionDatabaseModified: false,
      temporaryRootRemovedAfterRun: true,
    },
    polling: {
      endpointStatus: pollingResponse.status,
      removed: true,
    },
    webSocketCommitToVisible: {
      surface: "macOS Accessibility tree",
      thresholdMs: latencyP95LimitMilliseconds,
      ...latencySummary,
    },
    reconnect: {
      offlineEventCount: offlineEvents.length,
      connectedEventCount: connectedEvents.length,
      revisionBeforeDisconnect: lastAppliedRevisionBeforeDisconnect,
      reconnectRevision: reconnectEvent.revision,
      missedRevisionCount: reconnectEvent.revision - lastAppliedRevisionBeforeDisconnect - 1,
      snapshotGapRecoveryEventCount: gapRecoveryEvents.length,
      latestRevisionVisible: true,
    },
    staleResponse: {
      capturedOldRevision: capturedResponse.revision,
      latestRevision: staleNewCommit.revision,
      latestTitleRemainedVisibleAfterDelayedResponse: true,
    },
    permissionOnboarding: {
      appLaunchCount,
      automaticRequestRecordCount: permissionRequestCount,
      requestedOnce: permissionRequestCount === 1,
    },
  };
  await writePrivateJSON(reportPath, report);
  console.log(
    `isolated-runtime-qa status=pass samples=${latencySummary.sampleCount} p95_ms=${latencySummary.p95Ms.toFixed(1)} reconnect=pass stale_response=pass permission_once=pass`,
  );
} catch (error) {
  report = {
    schemaVersion: 1,
    status: "fail",
    generatedAt: new Date().toISOString(),
    reason: error instanceof Error ? error.message : String(error),
  };
  await preparePrivateDirectory(evidenceDirectory).catch(() => {});
  await writePrivateJSON(reportPath, report).catch(() => {});
  console.error(`isolated-runtime-qa status=fail reason=${report.reason}`);
  process.exitCode = 1;
} finally {
  await terminateApp().catch(() => {});
  await stopRelay().catch(() => {});
  if (bundleIdentifier) {
    await runCapture("/usr/bin/defaults", ["delete", bundleIdentifier]).catch(() => {});
  }
  await copyQAEventLog().catch(() => {});
  await fsp.rm(qaRoot, { recursive: true, force: true }).catch(() => {});
  if (report?.status === "pass") {
    await fsp.rm(qaAppPath, { recursive: true, force: true }).catch(() => {});
    await fsp.rm(scratchPath, { recursive: true, force: true }).catch(() => {});
    await fsp.rm(probePath, { force: true }).catch(() => {});
  }
  for (const child of childProcesses) {
    await stopChild(child).catch(() => {});
  }
}

async function preparePrivateDirectory(directory) {
  await fsp.mkdir(directory, { recursive: true, mode: 0o700 });
  await fsp.chmod(directory, 0o700);
  const metadata = await fsp.lstat(directory);
  if (!metadata.isDirectory() || metadata.isSymbolicLink() || metadata.uid !== process.getuid()) {
    throw new Error(`invalid private directory: ${directory}`);
  }
  if ((metadata.mode & 0o077) !== 0) {
    throw new Error(`private directory permissions are too broad: ${directory}`);
  }
}

async function writePrivateJSON(destination, payload) {
  const temporary = `${destination}.tmp-${process.pid}`;
  await fsp.writeFile(temporary, `${JSON.stringify(payload, null, 2)}\n`, { mode: 0o600 });
  await fsp.rename(temporary, destination);
  await fsp.chmod(destination, 0o600);
}

async function copyQAEventLog() {
  try {
    await fsp.copyFile(eventLogPath, copiedEventLogPath);
    await fsp.chmod(copiedEventLogPath, 0o600);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

async function runCapture(executable, argv, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, argv, {
      cwd: options.workingDirectory ?? repoRoot,
      env: { ...process.env, ...(options.environment ?? {}) },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    child.once("exit", (status, signal) => {
      if (status === 0) {
        resolve(stdout);
      } else {
        reject(new Error(
          `${path.basename(executable)} failed (${status ?? signal ?? "unknown"}): ${stderr.trim()}`,
        ));
      }
    });
  });
}

async function runLogged(executable, argv, options = {}) {
  const logStream = fs.createWriteStream(options.logPath, { flags: "w", mode: 0o600 });
  return new Promise((resolve, reject) => {
    const child = spawn(executable, argv, {
      cwd: options.workingDirectory ?? repoRoot,
      env: { ...process.env, ...(options.environment ?? {}) },
      stdio: ["ignore", "pipe", "pipe"],
    });
    childProcesses.add(child);
    const timeout = setTimeout(() => {
      stopChild(child).catch(() => {});
      reject(new Error(`${path.basename(executable)} timed out`));
    }, options.timeoutMilliseconds ?? 120_000);
    const write = (chunk, destination) => {
      logStream.write(chunk);
      destination.write(chunk);
    };
    child.stdout.on("data", (chunk) => write(chunk, process.stdout));
    child.stderr.on("data", (chunk) => write(chunk, process.stderr));
    child.once("error", (error) => {
      clearTimeout(timeout);
      childProcesses.delete(child);
      logStream.end();
      reject(error);
    });
    child.once("exit", (status, signal) => {
      clearTimeout(timeout);
      childProcesses.delete(child);
      logStream.end();
      if (status === 0) {
        resolve();
      } else {
        reject(new Error(`${path.basename(executable)} failed (${status ?? signal ?? "unknown"})`));
      }
    });
  });
}

async function reserveLoopbackPort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      server.close((error) => {
        if (error) reject(error);
        else if (port > 0) resolve(port);
        else reject(new Error("failed to reserve a loopback port"));
      });
    });
  });
}

async function startRelay({ port, responseDelayMilliseconds, sequence }) {
  const logPath = path.join(evidenceDirectory, `relay-${sequence}.log`);
  const logStream = fs.createWriteStream(logPath, { flags: "w", mode: 0o600 });
  const child = spawn(process.execPath, [path.join(repoRoot, "tools", "klms_relay_server.mjs")], {
    cwd: repoRoot,
    env: {
      ...process.env,
      NODE_ENV: "test",
      KLMS_RELAY_HOST: "127.0.0.1",
      KLMS_RELAY_PORT: String(port),
      KLMS_RELAY_CLIENT_TOKEN: clientToken,
      KLMS_RELAY_WORKER_TOKEN: workerToken,
      KLMS_RELAY_DB: relayDatabasePath,
      KLMS_RELAY_FILE_DIR: relayFilesPath,
      KLMS_RELAY_REQUESTS_PER_MINUTE: "6000",
      KLMS_RELAY_TEST_SYNC_DATA_RESPONSE_DELAY_MS: String(responseDelayMilliseconds),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  childProcesses.add(child);
  const testEvents = [];
  const waiters = new Set();
  let stdoutBuffer = "";
  const consumeLines = (chunk) => {
    stdoutBuffer += chunk.toString("utf8");
    while (stdoutBuffer.includes("\n")) {
      const newline = stdoutBuffer.indexOf("\n");
      const line = stdoutBuffer.slice(0, newline).trim();
      stdoutBuffer = stdoutBuffer.slice(newline + 1);
      if (!line) continue;
      try {
        const event = JSON.parse(line);
        if (event && typeof event === "object" && event.testEvent) {
          testEvents.push(event);
          for (const waiter of waiters) waiter();
        }
      } catch {
        continue;
      }
    }
  };
  child.stdout.on("data", (chunk) => {
    logStream.write(chunk);
    consumeLines(chunk);
  });
  child.stderr.on("data", (chunk) => logStream.write(chunk));
  child.once("exit", () => {
    childProcesses.delete(child);
    logStream.end();
    for (const waiter of waiters) waiter();
  });
  child.once("error", () => {
    for (const waiter of waiters) waiter();
  });
  const instance = {
    child,
    waitForTestEvent(predicate, timeoutMilliseconds) {
      return waitUntil(
        () => testEvents.find(predicate),
        timeoutMilliseconds,
        waiters,
        "relay test event",
      );
    },
  };
  await waitForHTTP(`http://127.0.0.1:${port}/healthz`, child, 10_000);
  return instance;
}

async function stopRelay() {
  if (!relay) return;
  const current = relay;
  relay = null;
  await stopChild(current.child);
}

async function launchApp(relayURL) {
  const executable = path.join(qaAppPath, "Contents", "MacOS", "KLMSMac");
  const logPath = path.join(evidenceDirectory, `app-launch-${appLaunchCount + 1}.log`);
  await fsp.writeFile(logPath, "", { mode: 0o600 });
  const launchEnvironment = {
    KLMS_MAC_ISOLATED_QA: "1",
    KLMS_MAC_ISOLATED_QA_BUNDLE_ID: bundleIdentifier,
    KLMS_MAC_ISOLATED_QA_ROOT: qaRoot,
    KLMS_MAC_ISOLATED_QA_RELAY_URL: relayURL,
    KLMS_MAC_ISOLATED_QA_CLIENT_TOKEN: clientToken,
    KLMS_MAC_ISOLATED_QA_WORKER_TOKEN: workerToken,
  };
  const argv = [
    "-n",
    "--stdout",
    logPath,
    "--stderr",
    logPath,
  ];
  for (const [key, value] of Object.entries(launchEnvironment)) {
    argv.push("--env", `${key}=${value}`);
  }
  argv.push(qaAppPath);
  await runCapture("/usr/bin/open", argv, { workingDirectory: qaRoot });
  appLaunchCount += 1;
  const pid = await waitUntil(
    async () => findExactAppPID(executable),
    10_000,
    null,
    "isolated app process",
  );
  return { pid };
}

async function terminateApp() {
  if (!appProcess) return;
  const current = appProcess;
  appProcess = null;
  if (isPIDAlive(current.pid)) {
    await stopAppPID(current.pid);
  }
  await waitUntil(
    () => !isPIDAlive(current.pid) ? true : null,
    10_000,
    null,
    "isolated app termination",
  ).catch(async () => {
    await stopAppPID(current.pid);
  });
}

async function publishSyncData(relayURL, title) {
  const now = new Date().toISOString();
  const response = await fetch(`${relayURL}/v1/sync-data`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${workerToken}`,
      "Content-Type": "application/json",
      "X-KLMS-Client": "KLMS Sync Isolated QA",
    },
    body: JSON.stringify({
      generatedAt: now,
      items: [{
        id: `mail-qa-${crypto.createHash("sha256").update(title).digest("hex")}`,
        kind: "assignment",
        course: "격리 QA",
        academicTerm: "2030 가을학기",
        academicYear: 2030,
        academicSemester: "가을학기",
        title,
        timestamp: "2030-03-13T12:00:00+09:00",
        status: "메일에서 감지",
        detail: "격리된 메일 WebSocket 실시간 반영 검증 항목",
        attachmentCount: 0,
        updatedAt: now,
        isRead: false,
        isImportant: false,
        isHidden: false,
      }],
    }),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || !Number.isSafeInteger(body.revision)) {
    throw new Error(`sync-data publish failed with status ${response.status}`);
  }
  const commitEpochMilliseconds = Date.parse(body.updatedAt);
  if (!Number.isFinite(commitEpochMilliseconds)) {
    throw new Error("sync-data response omitted its commit timestamp");
  }
  return {
    revision: body.revision,
    commitEpochMilliseconds,
  };
}

async function probeVisibleText({
  title,
  commitEpochMilliseconds,
  workspace = null,
  timeoutSeconds,
}) {
  if (!appProcess?.pid || !isPIDAlive(appProcess.pid)) {
    throw new Error("isolated app is not running for accessibility probe");
  }
  const argv = [
    "--pid",
    String(appProcess.pid),
    "--expected",
    title,
    "--started-at-ms",
    String(commitEpochMilliseconds),
    "--timeout",
    String(timeoutSeconds),
  ];
  if (workspace) {
    argv.push("--navigate", workspace);
  }
  return runProbe(argv);
}

async function runProbe(argv) {
  const output = await runCapture(probePath, argv, {
    workingDirectory: evidenceDirectory,
  });
  const line = output.trim().split("\n").at(-1);
  const payload = JSON.parse(line || "{}");
  if (payload.ok !== true) {
    throw new Error("isolated accessibility probe returned an invalid result");
  }
  return payload;
}

async function readQAEvents() {
  let contents;
  try {
    contents = await fsp.readFile(eventLogPath, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw error;
  }
  return contents
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter((item) => item && typeof item.event === "string");
}

async function waitForQAEvent(event, minimumCount, timeoutMilliseconds) {
  return waitUntil(
    async () => {
      const matches = (await readQAEvents()).filter((item) => item.event === event);
      return matches.length >= minimumCount ? matches.at(-1) : null;
    },
    timeoutMilliseconds,
    null,
    `isolated QA event ${event}`,
  );
}

function summarizeLatency(samples) {
  const sorted = samples.slice().sort((left, right) => left - right);
  return {
    sampleCount: sorted.length,
    p50Ms: percentile(sorted, 0.50),
    p95Ms: percentile(sorted, 0.95),
    maxMs: sorted.at(-1),
  };
}

function percentile(sorted, fraction) {
  const index = Math.max(0, Math.ceil(sorted.length * fraction) - 1);
  return sorted[index];
}

async function waitForHTTP(url, child, timeoutMilliseconds) {
  return waitUntil(
    async () => {
      if (!isChildRunning(child)) {
        throw new Error(`relay exited before readiness with status ${child.exitCode ?? child.signalCode}`);
      }
      try {
        const response = await fetch(url);
        return response.ok ? true : null;
      } catch {
        return null;
      }
    },
    timeoutMilliseconds,
    null,
    "relay readiness",
  );
}

async function waitUntil(check, timeoutMilliseconds, wakeSet, description) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    const result = await check();
    if (result) return result;
    if (wakeSet) {
      await new Promise((resolve) => {
        const timeout = setTimeout(() => {
          wakeSet.delete(wake);
          resolve();
        }, 50);
        const wake = () => {
          clearTimeout(timeout);
          wakeSet.delete(wake);
          resolve();
        };
        wakeSet.add(wake);
      });
    } else {
      await sleep(50);
    }
  }
  throw new Error(`timed out waiting for ${description}`);
}

async function stopChild(child) {
  if (!isChildRunning(child)) return;
  child.kill("SIGTERM");
  const exited = await Promise.race([
    new Promise((resolve) => child.once("exit", () => resolve(true))),
    sleep(2_000).then(() => false),
  ]);
  if (!exited && isChildRunning(child)) {
    child.kill("SIGKILL");
    await new Promise((resolve) => child.once("exit", resolve));
  }
}

async function findExactAppPID(executable) {
  const output = await runCapture("/bin/ps", ["-axo", "pid=,command="]);
  for (const line of output.split("\n")) {
    const match = line.match(/^\s*(\d+)\s+(.+)$/);
    if (!match) continue;
    const command = match[2].trim();
    if (command === executable || command.startsWith(`${executable} `)) {
      const pid = Number.parseInt(match[1], 10);
      if (Number.isSafeInteger(pid) && pid > 0) return pid;
    }
  }
  return null;
}

function isPIDAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

async function stopAppPID(pid) {
  if (!isPIDAlive(pid)) return;
  try {
    process.kill(pid, "SIGTERM");
  } catch {
    return;
  }
  const exited = await waitUntil(
    () => !isPIDAlive(pid) ? true : null,
    2_000,
    null,
    "isolated app SIGTERM",
  ).catch(() => false);
  if (!exited && isPIDAlive(pid)) {
    process.kill(pid, "SIGKILL");
  }
}

function isChildRunning(child) {
  return Boolean(child) && child.exitCode === null && child.signalCode === null;
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
