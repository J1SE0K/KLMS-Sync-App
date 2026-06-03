import assert from "node:assert/strict";
import worker from "../src/worker.mjs";

const clientToken = "test-client-token";
const workerToken = "test-worker-token";
let env;

async function runSmoke() {
  env = {
    RELAY_CLIENT_TOKEN: clientToken,
    RELAY_WORKER_TOKEN: workerToken,
    RELAY_DB: new FakeD1(),
    RELAY_FILES: new FakeR2(),
  };

  await expectJSON("/healthz", { ok: true, storage: "cloudflare-d1", configured: true }, { auth: false });

  {
    const response = await request("/v1/status", { auth: false });
    assert.equal(response.status, 401);
  }

  {
    const payload = await expectJSON("/v1/status");
    assert.equal(payload.ok, true);
    assert.equal(payload.status.phase, "idle");
  }

  {
    const response = await request("/v1/status", { method: "POST", body: { phase: "running" }, role: "client" });
    assert.equal(response.status, 401);
  }

  {
    const response = await request("/v1/commands/pending", { role: "client" });
    assert.equal(response.status, 401);
  }

  await expectJSON("/v1/status", {
    status: { assignments: 1, phase: "idle" },
    running: false,
    message: "worker status",
  }, { method: "POST", role: "worker" });

  const createdCommand = await expectJSON("/v1/commands", {
    kind: "fullSync",
    status: "pending",
    summary: { assignments: 3, phase: "pending" },
  }, { method: "POST", status: 201 });
  assert.equal(createdCommand.kind, "fullSync");
  assert.equal(createdCommand.status, "pending");

  {
    const payload = await expectJSON("/v1/commands/pending", undefined, { role: "worker" });
    assert.equal(payload.commands.length, 1);
    assert.equal(payload.commands[0].id, createdCommand.id);
  }

  await expectJSON(`/v1/commands/${createdCommand.id}`, {
    ...createdCommand,
    status: "completed",
    updatedAt: new Date().toISOString(),
    summary: { assignments: 3, phase: "completed" },
  }, { method: "PUT", role: "worker" });

  await expectJSON("/v1/sync-data", {
    generatedAt: "2026-05-31T00:00:00Z",
    items: [
      {
        id: "exam-1",
        kind: "exam",
        course: "영미 단편소설",
        title: "기말고사",
        timestamp: "2026-06-12 10:00",
        status: "예정",
        detail: "범위: 전체",
        attachmentCount: 0,
        updatedAt: "2026-05-31T00:00:00Z",
      },
      {
        id: "notice-1",
        kind: "notice",
        course: "데이터베이스",
        title: "공지",
        timestamp: "2026-05-31 09:00",
        status: "새 공지",
        detail: "",
        attachmentCount: 1,
        updatedAt: "2026-05-31T00:00:01Z",
      },
    ],
  }, { method: "POST", role: "worker" });

  {
    const payload = await expectJSON("/v1/sync-data?kind=exam&limit=10");
    assert.equal(payload.items.length, 1);
    assert.equal(payload.items[0].id, "exam-1");
  }

  const action = await expectJSON("/v1/item-actions", {
    action: "noticeRead",
    itemID: "notice-1",
    itemKind: "notice",
    itemTitle: "공지",
  }, { method: "POST", status: 201 });
  assert.equal(action.status, "pending");

  {
    const payload = await expectJSON("/relay/v1/item-actions/pending", undefined, { role: "worker" });
    assert.equal(payload.actions.length, 1);
    assert.equal(payload.actions[0].itemID, "notice-1");
  }

  const fileRequest = await expectJSON("/v1/file-access", {
    itemID: "file-1",
    itemKind: "file",
    itemTitle: "기말 정리.pdf",
  }, { method: "POST", status: 201 });
  assert.equal(fileRequest.status, "pending");

  {
    const payload = await expectJSON("/v1/file-access/pending", undefined, { role: "worker" });
    assert.equal(payload.requests.length, 1);
    assert.equal(payload.requests[0].itemID, "file-1");
  }

  const uploadResponse = await request(`/v1/file-access/${fileRequest.id}/upload`, {
    method: "PUT",
    role: "worker",
    rawBody: "hello file",
    headers: {
      "Content-Type": "text/plain",
      "Content-Length": "10",
      "X-KLMS-Filename": encodeURIComponent("기말 정리.pdf"),
    },
  });
  assert.equal(uploadResponse.status, 200);
  const uploaded = await uploadResponse.json();
  assert.equal(uploaded.status, "completed");
  assert.match(uploaded.downloadURL, /\/v1\/file-access\/.+\/download\?ticket=/);

  {
    const downloadResponse = await worker.fetch(new Request(uploaded.downloadURL), env);
    assert.equal(downloadResponse.status, 200);
    assert.equal(await downloadResponse.text(), "hello file");
  }
  {
    await worker.fetch(new Request(uploaded.downloadURL), env);
    await worker.fetch(new Request(uploaded.downloadURL), env);
    const blockedResponse = await worker.fetch(new Request(uploaded.downloadURL), env);
    assert.equal(blockedResponse.status, 429);
  }

  console.log("cloudflare worker smoke ok");
}

async function expectJSON(path, body, options = {}) {
  const response = await request(path, { ...options, body });
  assert.equal(response.status, options.status || 200);
  return response.json();
}

function request(path, { method = "GET", body, rawBody, headers: extraHeaders = {}, auth = true, role = "client" } = {}) {
  const headers = new Headers({ Accept: "application/json" });
  for (const [key, value] of Object.entries(extraHeaders)) {
    headers.set(key, value);
  }
  if (auth) {
    headers.set("Authorization", `Bearer ${role === "worker" ? workerToken : clientToken}`);
  }
  if (body != null && method !== "GET") {
    headers.set("Content-Type", "application/json");
  }
  return worker.fetch(new Request(`https://relay.example${path}`, {
    method,
    headers,
    body: rawBody != null ? rawBody : body != null && method !== "GET" ? JSON.stringify(body) : undefined,
  }), env);
}

class FakeD1 {
  constructor() {
    this.meta = new Map();
    this.commands = new Map();
    this.itemActions = new Map();
    this.fileAccessRequests = new Map();
  }

  async exec() {
    return { count: 0, duration: 0 };
  }

  prepare(sql) {
    return new FakeStatement(this, sql);
  }

  async batch(statements) {
    const results = [];
    for (const statement of statements) {
      results.push(await statement.run());
    }
    return results;
  }
}

class FakeStatement {
  constructor(db, sql, args = []) {
    this.db = db;
    this.sql = sql.replace(/\s+/g, " ").trim();
    this.args = args;
  }

  bind(...args) {
    return new FakeStatement(this.db, this.sql, args);
  }

  async first() {
    if (this.sql.startsWith("SELECT value FROM meta")) {
      const value = this.db.meta.get(this.args[0]);
      return value == null ? null : { value };
    }
    if (this.sql.includes("FROM file_access_requests")) {
      return this.db.fileAccessRequests.get(this.args[0]) || null;
    }
    throw new Error(`Unsupported first SQL: ${this.sql}`);
  }

  async all() {
    if (this.sql.includes("FROM commands")) {
      return { results: sortedRows(this.db.commands, this.args[0] || 200) };
    }
    if (this.sql.includes("FROM item_actions")) {
      return { results: sortedRows(this.db.itemActions, this.args[0] || 400) };
    }
    if (this.sql.includes("FROM file_access_requests")) {
      if (this.sql.includes("WHERE status IN")) {
        const limit = this.args.at(-1) || 100;
        const statuses = new Set(this.args.slice(0, -1));
        return { results: sortedRows(this.db.fileAccessRequests, limit).filter((row) => statuses.has(row.status)) };
      }
      if (this.sql.includes("expires_at IS NOT NULL")) {
        const cutoff = this.args[0];
        return {
          results: Array.from(this.db.fileAccessRequests.values())
            .filter((row) => row.expires_at && row.expires_at <= cutoff),
        };
      }
      return { results: sortedRows(this.db.fileAccessRequests, this.args[0] || 100) };
    }
    throw new Error(`Unsupported all SQL: ${this.sql}`);
  }

  async run() {
    if (this.sql.startsWith("INSERT INTO meta")) {
      this.db.meta.set(this.args[0], String(this.args[1]));
      return { success: true };
    }
    if (this.sql.startsWith("INSERT INTO commands")) {
      const [
        id,
        kind,
        status,
        createdAt,
        updatedAt,
        lastExitCode,
        loginRequired,
        summaryJSON,
      ] = this.args;
      this.db.commands.set(id, {
        id,
        kind,
        status,
        created_at: createdAt,
        updated_at: updatedAt,
        last_exit_code: lastExitCode,
        login_required: loginRequired,
        summary_json: summaryJSON,
      });
      return { success: true };
    }
    if (this.sql.startsWith("DELETE FROM commands")) {
      trimRows(this.db.commands, this.args[0]);
      return { success: true };
    }
    if (this.sql.startsWith("INSERT INTO item_actions")) {
      const [
        id,
        action,
        itemID,
        itemKind,
        itemTitle,
        status,
        createdAt,
        updatedAt,
        message,
      ] = this.args;
      this.db.itemActions.set(id, {
        id,
        action,
        item_id: itemID,
        item_kind: itemKind,
        item_title: itemTitle,
        status,
        created_at: createdAt,
        updated_at: updatedAt,
        message,
      });
      return { success: true };
    }
    if (this.sql.startsWith("DELETE FROM item_actions")) {
      trimRows(this.db.itemActions, this.args[0]);
      return { success: true };
    }
    if (this.sql.startsWith("INSERT INTO file_access_requests")) {
      const [
        id,
        itemID,
        itemKind,
        itemTitle,
        status,
        createdAt,
        updatedAt,
        message,
        objectKey,
        downloadTicket,
        expiresAt,
        contentType,
        sizeBytes,
        downloadCount,
      ] = this.args;
      this.db.fileAccessRequests.set(id, {
        id,
        item_id: itemID,
        item_kind: itemKind,
        item_title: itemTitle,
        status,
        created_at: createdAt,
        updated_at: updatedAt,
        message,
        object_key: objectKey,
        download_ticket: downloadTicket,
        expires_at: expiresAt,
        content_type: contentType,
        size_bytes: sizeBytes,
        download_count: downloadCount,
      });
      return { success: true };
    }
    if (this.sql.startsWith("DELETE FROM file_access_requests")) {
      if (this.sql.includes("expires_at IS NOT NULL")) {
        const cutoff = this.args[0];
        for (const [id, row] of this.db.fileAccessRequests.entries()) {
          if (row.expires_at && row.expires_at <= cutoff) {
            this.db.fileAccessRequests.delete(id);
          }
        }
      } else {
        trimRows(this.db.fileAccessRequests, this.args[0]);
      }
      return { success: true };
    }
    throw new Error(`Unsupported run SQL: ${this.sql}`);
  }
}

class FakeR2 {
  constructor() {
    this.objects = new Map();
  }

  async put(key, body, options = {}) {
    const text = typeof body === "string"
      ? body
      : body instanceof ReadableStream
        ? await new Response(body).text()
        : body instanceof ArrayBuffer
          ? new TextDecoder().decode(body)
          : String(body || "");
    this.objects.set(key, {
      body: text,
      httpMetadata: options.httpMetadata || {},
    });
  }

  async get(key) {
    const object = this.objects.get(key);
    if (!object) {
      return null;
    }
    return {
      body: object.body,
      httpMetadata: object.httpMetadata,
    };
  }

  async delete(key) {
    this.objects.delete(key);
  }
}

function sortedRows(map, limit) {
  return Array.from(map.values())
    .sort((lhs, rhs) => Date.parse(rhs.updated_at) - Date.parse(lhs.updated_at))
    .slice(0, limit);
}

function trimRows(map, limit) {
  const keep = new Set(sortedRows(map, limit).map((row) => row.id));
  for (const id of map.keys()) {
    if (!keep.has(id)) {
      map.delete(id);
    }
  }
}

await runSmoke();
