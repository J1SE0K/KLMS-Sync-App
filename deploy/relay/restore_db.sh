#!/bin/sh

set -eu

BACKUP_PATH="${1:-}"
DB_PATH="/data/klms-sync-relay.sqlite"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SAFETY_PATH="/data/backups/pre-restore-$STAMP.backup"
READINESS_ATTEMPTS="${KLMS_RELAY_RESTORE_READINESS_ATTEMPTS:-30}"
READINESS_DELAY_SECONDS="${KLMS_RELAY_RESTORE_READINESS_DELAY_SECONDS:-1}"
RESTORE_COMMITTED=0
RELAY_STOPPED=0
SAFETY_READY=0
RECOVERY_RUNNING=0
CANDIDATE_STARTED=0

secure_env_file() {
  file="$1"
  [ -f "$file" ] || return 0
  if [ -L "$file" ]; then
    printf '%s\n' "Refusing symlinked credential file: $file" >&2
    exit 77
  fi
  owner="$(stat -c %u "$file" 2>/dev/null || stat -f %u "$file")"
  if [ "$owner" != "$(id -u)" ]; then
    printf '%s\n' "Credential file must be owned by the current user: $file" >&2
    exit 77
  fi
  chmod 600 "$file"
}

compose() {
  if [ -f .env.tunnel ]; then
    secure_env_file .env.tunnel
    secure_env_file .env.cloudflare
    docker compose --env-file .env.tunnel -f docker-compose.cloudflared.yml "$@"
  else
    secure_env_file .env
    docker compose "$@"
  fi
}

restore_safety_database() {
  compose run --rm --no-deps relay node -e '
const fs = require("node:fs");
const source = process.argv[1];
const destination = process.argv[2];
fs.copyFileSync(source, `${destination}.restore`);
fs.chmodSync(`${destination}.restore`, 0o600);
for (const suffix of ["-wal", "-shm"]) fs.rmSync(`${destination}${suffix}`, { force: true });
fs.renameSync(`${destination}.restore`, destination);
' "$SAFETY_PATH" "$DB_PATH"
}

recover_on_exit() {
  original_status="$1"
  trap - 0 HUP INT TERM
  if [ "$RESTORE_COMMITTED" -eq 1 ] || [ "$RELAY_STOPPED" -eq 0 ]; then
    exit "$original_status"
  fi
  if [ "$RECOVERY_RUNNING" -eq 1 ]; then
    exit "$original_status"
  fi
  RECOVERY_RUNNING=1
  set +e
  recovery_failed=0
  if [ "$CANDIDATE_STARTED" -eq 1 ]; then
    compose stop relay || recovery_failed=1
    CANDIDATE_STARTED=0
  fi
  if [ "$SAFETY_READY" -eq 1 ]; then
    printf '%s\n' "Restore failed; rolling back to $SAFETY_PATH" >&2
    restore_safety_database || recovery_failed=1
  else
    printf '%s\n' "Restore failed before the safety backup completed; restarting the original relay" >&2
  fi
  compose up -d --force-recreate relay || recovery_failed=1
  if [ "$recovery_failed" -ne 0 ]; then
    printf '%s\n' "Restore recovery could not fully restore and restart the relay" >&2
  fi
  if [ "$original_status" -eq 0 ]; then
    original_status=1
  fi
  exit "$original_status"
}

case "$BACKUP_PATH" in
  /data/backups/*.backup) ;;
  *)
    printf '%s\n' "Usage: $0 /data/backups/<verified-backup>.backup" >&2
    exit 64
    ;;
esac

case "$READINESS_ATTEMPTS" in
  ''|*[!0-9]*)
    printf '%s\n' "KLMS_RELAY_RESTORE_READINESS_ATTEMPTS must be a positive integer" >&2
    exit 64
    ;;
esac
if [ "$READINESS_ATTEMPTS" -lt 1 ]; then
  printf '%s\n' "KLMS_RELAY_RESTORE_READINESS_ATTEMPTS must be a positive integer" >&2
  exit 64
fi
case "$READINESS_DELAY_SECONDS" in
  ''|*[!0-9]*)
    printf '%s\n' "KLMS_RELAY_RESTORE_READINESS_DELAY_SECONDS must be a non-negative integer" >&2
    exit 64
    ;;
esac

compose run --rm --no-deps relay \
  node /app/tools/klms_relay_server.mjs --verify-backup "$BACKUP_PATH"

trap 'recover_on_exit $?' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Mark the relay as requiring recovery before issuing the stop. A partially
# successful stop must still flow through the EXIT trap and restart service.
RELAY_STOPPED=1
compose stop relay

compose run --rm --no-deps relay \
  node /app/tools/klms_relay_server.mjs --backup "$SAFETY_PATH"
SAFETY_READY=1
compose run --rm --no-deps relay node -e '
const fs = require("node:fs");
const source = process.argv[1];
const destination = process.argv[2];
fs.copyFileSync(source, `${destination}.restore`);
fs.chmodSync(`${destination}.restore`, 0o600);
for (const suffix of ["-wal", "-shm"]) fs.rmSync(`${destination}${suffix}`, { force: true });
fs.renameSync(`${destination}.restore`, destination);
' "$BACKUP_PATH" "$DB_PATH"

CANDIDATE_STARTED=1
compose up -d --force-recreate relay
attempt=0
while [ "$attempt" -lt "$READINESS_ATTEMPTS" ]; do
  if compose exec -T relay node -e \
    "fetch('http://127.0.0.1:18484/readyz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"; then
    RESTORE_COMMITTED=1
    RELAY_STOPPED=0
    CANDIDATE_STARTED=0
    trap - 0 HUP INT TERM
    printf '%s\n' "Restore verified and relay ready: $BACKUP_PATH"
    exit 0
  fi
  attempt=$((attempt + 1))
  if [ "$attempt" -lt "$READINESS_ATTEMPTS" ] && [ "$READINESS_DELAY_SECONDS" -gt 0 ]; then
    sleep "$READINESS_DELAY_SECONDS"
  fi
done

exit 1
