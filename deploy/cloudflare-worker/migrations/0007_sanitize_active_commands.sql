-- Invalid active rows are excluded by the application loader, but still occupy
-- the partial unique-index slot and can permanently reject every new command.
-- Preserve the malformed payload for forensics while making it terminal.
UPDATE commands
SET status = 'macUnavailable',
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE status IN ('pending', 'running')
  AND (
    length(id) <> 36
    OR substr(id, 9, 1) <> '-'
    OR substr(id, 14, 1) <> '-'
    OR substr(id, 19, 1) <> '-'
    OR substr(id, 24, 1) <> '-'
    OR length(replace(id, '-', '')) <> 32
    OR lower(replace(id, '-', '')) GLOB '*[^0-9a-f]*'
    OR kind NOT IN (
      'fullSync', 'coreSync', 'noticeSync', 'filesSync',
      'verify', 'doctor', 'report', 'v2BuildState'
    )
    OR length(created_at) <> 24
    OR substr(created_at, 5, 1) <> '-'
    OR substr(created_at, 8, 1) <> '-'
    OR substr(created_at, 11, 1) <> 'T'
    OR substr(created_at, 14, 1) <> ':'
    OR substr(created_at, 17, 1) <> ':'
    OR substr(created_at, 20, 1) <> '.'
    OR substr(created_at, 24, 1) <> 'Z'
    OR (
      substr(created_at, 1, 4) || substr(created_at, 6, 2) || substr(created_at, 9, 2)
      || substr(created_at, 12, 2) || substr(created_at, 15, 2) || substr(created_at, 18, 2)
      || substr(created_at, 21, 3)
    ) GLOB '*[^0-9]*'
    OR julianday(created_at) IS NULL
    OR length(updated_at) <> 24
    OR substr(updated_at, 5, 1) <> '-'
    OR substr(updated_at, 8, 1) <> '-'
    OR substr(updated_at, 11, 1) <> 'T'
    OR substr(updated_at, 14, 1) <> ':'
    OR substr(updated_at, 17, 1) <> ':'
    OR substr(updated_at, 20, 1) <> '.'
    OR substr(updated_at, 24, 1) <> 'Z'
    OR (
      substr(updated_at, 1, 4) || substr(updated_at, 6, 2) || substr(updated_at, 9, 2)
      || substr(updated_at, 12, 2) || substr(updated_at, 15, 2) || substr(updated_at, 18, 2)
      || substr(updated_at, 21, 3)
    ) GLOB '*[^0-9]*'
    OR julianday(updated_at) IS NULL
  );

CREATE UNIQUE INDEX IF NOT EXISTS commands_one_active_idx
  ON commands((1))
  WHERE status IN ('pending', 'running');
