#!/bin/sh

set -eu

docker compose ps

if [ -f .env ]; then
  . ./.env
  printf '\n%s\n' "Health:"
  curl -fsS "https://$KLMS_RELAY_DOMAIN/healthz" || true
  printf '\n'
fi

printf '\n%s\n' "Recent relay logs:"
docker compose logs --tail 80 relay
