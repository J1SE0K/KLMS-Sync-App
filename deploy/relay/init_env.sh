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

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
ENV_PATH="$SCRIPT_DIR/.env"

if [ -f "$ENV_PATH" ] && [ "${FORCE:-0}" != "1" ]; then
  printf '%s\n' "$ENV_PATH already exists. Set FORCE=1 to overwrite." >&2
  exit 73
fi

new_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
  fi
}

display_token() {
  token="$1"
  if [ "${SHOW_TOKEN:-0}" = "1" ]; then
    printf '%s\n' "$token"
    return
  fi
  length="$(printf '%s' "$token" | wc -c | tr -d ' ')"
  if [ "$length" -le 12 ]; then
    printf '%s\n' "저장됨"
    return
  fi
  prefix="$(printf '%s' "$token" | cut -c 1-6)"
  suffix="$(printf '%s' "$token" | rev | cut -c 1-4 | rev)"
  printf '%s\n' "$prefix...$suffix"
}

CLIENT_TOKEN="$(new_token)"
WORKER_TOKEN="$(new_token)"

cat > "$ENV_PATH" <<EOF
KLMS_RELAY_DOMAIN=$DOMAIN
KLMS_RELAY_CLIENT_TOKEN=$CLIENT_TOKEN
KLMS_RELAY_WORKER_TOKEN=$WORKER_TOKEN
EOF

chmod 600 "$ENV_PATH"

printf '%s\n' "Created $ENV_PATH"
printf '%s\n' "서버 URL: https://$DOMAIN"
printf '%s\n' "클라이언트 토큰: $(display_token "$CLIENT_TOKEN")"
printf '%s\n' "Mac worker 토큰: $(display_token "$WORKER_TOKEN")"
if [ "${SHOW_TOKEN:-0}" != "1" ]; then
  printf '%s\n' "전체 토큰은 권한 600의 $ENV_PATH에 저장했습니다. 화면 공유나 로그에 남기지 않도록 기본 출력은 마스킹합니다."
fi
