CREATE TABLE IF NOT EXISTS file_download_reservations (
  token TEXT PRIMARY KEY,
  request_id TEXT NOT NULL,
  quota_date TEXT NOT NULL,
  log_id TEXT NOT NULL,
  log_created_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY(request_id) REFERENCES file_access_requests(id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS file_download_reservations_request_idx
  ON file_download_reservations(request_id);

CREATE INDEX IF NOT EXISTS file_download_reservations_created_idx
  ON file_download_reservations(created_at);
