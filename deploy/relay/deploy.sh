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

new_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
  fi
}

. ./.env
if [ -z "${KLMS_RELAY_TRUSTED_PROXY_SECRET:-}" ]; then
  KLMS_RELAY_TRUSTED_PROXY_SECRET="$(new_token)"
  printf '\n%s\n' "KLMS_RELAY_TRUSTED_PROXY_SECRET=$KLMS_RELAY_TRUSTED_PROXY_SECRET" >> .env
  chmod 600 .env
  printf '%s\n' "Initialized the internal trusted-proxy secret in .env."
elif [ "$(printf '%s' "$KLMS_RELAY_TRUSTED_PROXY_SECRET" | wc -c | tr -d ' ')" -lt 32 ]; then
  printf '%s\n' "KLMS_RELAY_TRUSTED_PROXY_SECRET must be at least 32 bytes." >&2
  exit 78
fi

docker compose up -d --build

printf '%s\n' "Waiting for relay readiness..."
sleep 3

printf '%s\n' "Authorization: Bearer $KLMS_RELAY_WORKER_TOKEN" \
  | curl -fsS --header @- "https://$KLMS_RELAY_DOMAIN/readyz"
printf '\n%s\n' "Relay is ready: https://$KLMS_RELAY_DOMAIN"
