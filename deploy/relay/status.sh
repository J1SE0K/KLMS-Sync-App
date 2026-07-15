#!/bin/sh

set -eu

if [ -f .env ]; then
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
fi

docker compose ps

if [ -f .env ]; then
  . ./.env
  printf '\n%s\n' "Readiness:"
  curl -fsS "https://$KLMS_RELAY_DOMAIN/readyz" || true
  printf '\n'
fi

printf '\n%s\n' "Recent relay logs:"
docker compose logs --tail 80 relay
