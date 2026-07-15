-- Repair legacy duplicate active commands before installing the invariant.
UPDATE commands
SET status = 'macUnavailable', updated_at = datetime('now')
WHERE status IN ('pending', 'running')
  AND id NOT IN (
    SELECT id
    FROM commands
    WHERE status IN ('pending', 'running')
    ORDER BY updated_at DESC
    LIMIT 1
  );

CREATE UNIQUE INDEX IF NOT EXISTS commands_one_active_idx
  ON commands((1))
  WHERE status IN ('pending', 'running');

CREATE TABLE IF NOT EXISTS file_access_quota (
  quota_date TEXT PRIMARY KEY,
  upload_count INTEGER NOT NULL DEFAULT 0 CHECK(upload_count >= 0),
  upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK(upload_bytes >= 0),
  download_count INTEGER NOT NULL DEFAULT 0 CHECK(download_count >= 0),
  updated_at TEXT NOT NULL
);

INSERT INTO meta(key, value)
VALUES('relayRevision', '0')
ON CONFLICT(key) DO NOTHING;
