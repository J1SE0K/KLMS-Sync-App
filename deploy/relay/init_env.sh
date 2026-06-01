#!/bin/sh

set -eu

usage() {
  printf '%s\n' "Usage: $0 <relay-domain>"
  printf '%s\n' "Example: $0 sync.example.com"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
  usage >&2
  exit 64
fi

if [ -f .env ] && [ "${FORCE:-0}" != "1" ]; then
  printf '%s\n' ".env already exists. Set FORCE=1 to overwrite." >&2
  exit 73
fi

new_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
  fi
}

CLIENT_TOKEN="$(new_token)"
WORKER_TOKEN="$(new_token)"

cat > .env <<EOF
KLMS_RELAY_DOMAIN=$DOMAIN
KLMS_RELAY_CLIENT_TOKEN=$CLIENT_TOKEN
KLMS_RELAY_WORKER_TOKEN=$WORKER_TOKEN
EOF

chmod 600 .env

printf '%s\n' "Created .env"
printf '%s\n' "서버 주소: https://$DOMAIN"
printf '%s\n' "클라이언트 토큰: $CLIENT_TOKEN"
printf '%s\n' "Mac worker 토큰: $WORKER_TOKEN"
