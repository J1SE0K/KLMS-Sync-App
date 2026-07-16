#!/bin/sh

set -eu

if [ ! -f .env ]; then
  printf '%s\n' "Missing .env. Run: ./init_env.sh sync.example.com" >&2
  exit 78
fi
if [ -L .env ]; then
  printf '%s\n' "Refusing symlinked credential file: .env" >&2
  exit 77
fi
env_owner="$(stat -c %u .env 2>/dev/null || stat -f %u .env)"
if [ "$env_owner" != "$(id -u)" ]; then
  printf '%s\n' "Credential file must be owned by the current user: .env" >&2
  exit 77
fi
chmod 600 .env

docker compose up -d --build

printf '%s\n' "Waiting for relay readiness..."
sleep 3

. ./.env
printf '%s\n' "Authorization: Bearer $KLMS_RELAY_WORKER_TOKEN" \
  | curl -fsS --header @- "https://$KLMS_RELAY_DOMAIN/readyz"
printf '\n%s\n' "Relay is ready: https://$KLMS_RELAY_DOMAIN"
