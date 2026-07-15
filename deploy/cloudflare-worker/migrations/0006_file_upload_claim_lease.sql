ALTER TABLE file_access_requests ADD COLUMN upload_claimed_at TEXT;

-- Claims created by the previous Worker have no lease timestamp. Treat them as
-- freshly claimed during the rollout so an in-flight upload gets one full lease
-- to finish; a claim left by a crashed Worker becomes reclaimable afterwards.
UPDATE file_access_requests
SET upload_claimed_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE object_key IS NULL
  AND upload_claim IS NOT NULL;

-- A finalized object never needs an upload lease, including malformed legacy
-- rows that retained an internal claim.
UPDATE file_access_requests
SET upload_claim = NULL,
    upload_claimed_at = NULL
WHERE object_key IS NOT NULL
  AND (upload_claim IS NOT NULL OR upload_claimed_at IS NOT NULL);
