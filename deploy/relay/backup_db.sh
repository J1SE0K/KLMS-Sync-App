#!/bin/sh

set -eu

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${KLMS_RELAY_BACKUP_DIR:-/data/backups}"
RETENTION_DAYS="${KLMS_RELAY_BACKUP_RETENTION_DAYS:-14}"
BACKUP_PATH="$BACKUP_DIR/klms-sync-relay.sqlite-$STAMP.backup"

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
    secure_env_file .env.proxy
    docker compose --env-file .env.tunnel -f docker-compose.cloudflared.yml "$@"
  else
    secure_env_file .env
    docker compose "$@"
  fi
}

case "$RETENTION_DAYS" in
  ''|*[!0-9]*)
    printf '%s\n' "KLMS_RELAY_BACKUP_RETENTION_DAYS must be a positive integer." >&2
    exit 64
    ;;
esac
if [ "$RETENTION_DAYS" -lt 1 ] || [ "$RETENTION_DAYS" -gt 3650 ]; then
  printf '%s\n' "KLMS_RELAY_BACKUP_RETENTION_DAYS must be between 1 and 3650." >&2
  exit 64
fi

compose exec -T relay \
  node /app/tools/klms_relay_server.mjs --backup "$BACKUP_PATH"
compose exec -T relay \
  node /app/tools/klms_relay_server.mjs --verify-backup "$BACKUP_PATH"
compose exec -T relay \
  node /app/tools/klms_relay_server.mjs --prune-backups "$BACKUP_DIR" "$RETENTION_DAYS"
compose exec -T relay ls -lh "$BACKUP_PATH"
