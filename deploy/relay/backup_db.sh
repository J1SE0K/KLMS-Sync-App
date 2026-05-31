#!/bin/sh

set -eu

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_PATH="/data/klms-sync-relay.sqlite-$STAMP.backup"

docker compose exec -T relay sh -lc "cp /data/klms-sync-relay.sqlite '$BACKUP_PATH' && ls -lh '$BACKUP_PATH'"
