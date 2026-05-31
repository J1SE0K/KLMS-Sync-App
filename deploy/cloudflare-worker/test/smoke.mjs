import assert from "node:assert/strict";
import worker from "../src/worker.mjs";

const token = "test-token";
let env;

async function runSmoke() {
  env = {
    RELAY_TOKEN: token,
    RELAY_DB: new FakeD1(),
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

  const createdCommand = await expectJSON("/v1/commands", {
    kind: "fullSync",
    status: "pending",
    summary: { assignments: 3, phase: "pending" },
  }, { method: "POST", status: 201 });
  assert.equal(createdCommand.kind, "fullSync");
  assert.equal(createdCommand.status, "pending");

  {
    const payload = await expectJSON("/v1/commands/pending");
    assert.equal(payload.commands.length, 1);
    assert.equal(payload.commands[0].id, createdCommand.id);
  }

  await expectJSON(`/v1/commands/${createdCommand.id}`, {
    ...createdCommand,
    status: "completed",
    updatedAt: new Date().toISOString(),
    summary: { assignments: 3, phase: "completed" },
  }, { method: "PUT" });

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
  }, { method: "POST" });

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
    const payload = await expectJSON("/relay/v1/item-actions/pending");
    assert.equal(payload.actions.length, 1);
    assert.equal(payload.actions[0].itemID, "notice-1");
  }

  console.log("cloudflare worker smoke ok");
}

async function expectJSON(path, body, options = {}) {
  const response = await request(path, { ...options, body });
  assert.equal(response.status, options.status || 200);
  return response.json();
}

function request(path, { method = "GET", body, auth = true } = {}) {
  const headers = new Headers({ Accept: "application/json" });
  if (auth) {
    headers.set("Authorization", `Bearer ${token}`);
  }
  if (body != null && method !== "GET") {
    headers.set("Content-Type", "application/json");
  }
  return worker.fetch(new Request(`https://relay.example${path}`, {
    method,
    headers,
    body: body != null && method !== "GET" ? JSON.stringify(body) : undefined,
  }), env);
}

class FakeD1 {
  constructor() {
    this.meta = new Map();
    this.commands = new Map();
    this.itemActions = new Map();
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
    throw new Error(`Unsupported first SQL: ${this.sql}`);
  }

  async all() {
    if (this.sql.includes("FROM commands")) {
      return { results: sortedRows(this.db.commands, this.args[0] || 200) };
    }
    if (this.sql.includes("FROM item_actions")) {
      return { results: sortedRows(this.db.itemActions, this.args[0] || 400) };
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
    throw new Error(`Unsupported run SQL: ${this.sql}`);
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
