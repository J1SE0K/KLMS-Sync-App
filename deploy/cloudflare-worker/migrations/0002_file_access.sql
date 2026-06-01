CREATE TABLE IF NOT EXISTS file_access_requests (
  id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL,
  item_kind TEXT NOT NULL DEFAULT 'file',
  item_title TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  message TEXT NOT NULL DEFAULT '',
  object_key TEXT,
  download_ticket TEXT,
  expires_at TEXT,
  content_type TEXT,
  size_bytes INTEGER,
  download_count INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS file_access_status_created_at_idx
  ON file_access_requests(status, created_at ASC);

CREATE INDEX IF NOT EXISTS file_access_updated_at_idx
  ON file_access_requests(updated_at DESC);

CREATE INDEX IF NOT EXISTS file_access_expires_at_idx
  ON file_access_requests(expires_at ASC);
