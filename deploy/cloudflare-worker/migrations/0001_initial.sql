CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS commands (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  last_exit_code INTEGER,
  login_required INTEGER NOT NULL DEFAULT 0,
  summary_json TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS commands_updated_at_idx
  ON commands(updated_at DESC);

CREATE INDEX IF NOT EXISTS commands_status_created_at_idx
  ON commands(status, created_at ASC);

CREATE TABLE IF NOT EXISTS item_actions (
  id TEXT PRIMARY KEY,
  action TEXT NOT NULL,
  item_id TEXT NOT NULL,
  item_kind TEXT NOT NULL,
  item_title TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  message TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS item_actions_status_created_at_idx
  ON item_actions(status, created_at ASC);

CREATE INDEX IF NOT EXISTS item_actions_updated_at_idx
  ON item_actions(updated_at DESC);
