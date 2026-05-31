#!/bin/sh

set -eu

if [ ! -f .env ]; then
  printf '%s\n' "Missing .env. Run: ./init_env.sh sync.example.com" >&2
  exit 78
fi

docker compose up -d --build

printf '%s\n' "Waiting for relay health..."
sleep 3

. ./.env
curl -fsS "https://$KLMS_RELAY_DOMAIN/healthz"
printf '\n%s\n' "Relay is healthy: https://$KLMS_RELAY_DOMAIN"
