ALTER TABLE file_access_requests ADD COLUMN upload_claim TEXT;
ALTER TABLE file_access_quota ADD COLUMN daily_download_limit INTEGER NOT NULL DEFAULT 100;
ALTER TABLE file_access_quota ADD COLUMN link_download_limit INTEGER NOT NULL DEFAULT 3;

DROP TRIGGER IF EXISTS file_access_download_quota_guard;
CREATE TRIGGER file_access_download_quota_guard
BEFORE UPDATE OF download_count ON file_access_requests
WHEN NEW.download_count = OLD.download_count + 1
BEGIN
  SELECT RAISE(ABORT, 'file download link quota reached')
  WHERE OLD.download_count >= COALESCE((
    SELECT link_download_limit
    FROM file_access_quota
    WHERE quota_date = substr(NEW.updated_at, 1, 10)
  ), 0);

  UPDATE file_access_quota
  SET download_count = download_count + 1,
      updated_at = NEW.updated_at
  WHERE quota_date = substr(NEW.updated_at, 1, 10)
    AND download_count < daily_download_limit;

  SELECT RAISE(ABORT, 'daily file download quota reached')
  WHERE changes() <> 1;
END;
