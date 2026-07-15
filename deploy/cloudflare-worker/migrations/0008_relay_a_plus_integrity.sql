ALTER TABLE item_actions ADD COLUMN idempotency_key TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS item_actions_idempotency_key_idx
  ON item_actions(idempotency_key)
  WHERE idempotency_key IS NOT NULL;

ALTER TABLE file_access_requests ADD COLUMN pending_object_key TEXT;
ALTER TABLE file_access_requests ADD COLUMN reserved_upload_bytes INTEGER NOT NULL DEFAULT 0;
ALTER TABLE file_access_requests ADD COLUMN reserved_upload_quota_date TEXT;

CREATE INDEX IF NOT EXISTS file_access_pending_object_idx
  ON file_access_requests(pending_object_key)
  WHERE pending_object_key IS NOT NULL;
