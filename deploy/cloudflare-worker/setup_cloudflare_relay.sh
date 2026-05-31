#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

WORKER_NAME="${KLMS_CLOUDFLARE_WORKER_NAME:-klms-sync-relay}"
DB_NAME="${KLMS_CLOUDFLARE_D1_NAME:-klms-sync-relay}"
TOKEN_FILE="${KLMS_CLOUDFLARE_TOKEN_FILE:-$SCRIPT_DIR/.relay-token}"
WRANGLER_TOML="$SCRIPT_DIR/wrangler.toml"
CLOUDFLARE_ENV_FILE="${KLMS_CLOUDFLARE_ENV_FILE:-$SCRIPT_DIR/.cloudflare.env}"
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
WORKERS_DEV_SUBDOMAIN="${KLMS_CLOUDFLARE_WORKERS_DEV_SUBDOMAIN:-}"

if [[ -f "$CLOUDFLARE_ENV_FILE" ]]; then
  set -a
  source "$CLOUDFLARE_ENV_FILE"
  set +a
fi

need_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    print -u2 -- "Missing required command: $1"
    exit 69
  fi
}

current_database_id() {
  sed -n 's/^[[:space:]]*database_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$WRANGLER_TOML" | tail -n 1
}

set_database_id() {
  local database_id="$1"
  DATABASE_ID="$database_id" node <<'NODE'
const fs = require("fs");
const path = "wrangler.toml";
const databaseID = process.env.DATABASE_ID;
const text = fs.readFileSync(path, "utf8");
const next = text.replace(
  /database_id\s*=\s*"[^"]*"/,
  `database_id = "${databaseID}"`
);
if (text === next) {
  throw new Error("Could not update database_id in wrangler.toml");
}
fs.writeFileSync(path, next);
NODE
}

wrangler_json_field() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8");
const key = process.argv[1];
const starts = [input.indexOf("["), input.indexOf("{")].filter((index) => index >= 0);
if (starts.length === 0) process.exit(0);
const start = Math.min(...starts);
let parsed;
try {
  parsed = JSON.parse(input.slice(start));
} catch {
  process.exit(0);
}
const value = Array.isArray(parsed)
  ? parsed.find((item) => item && item.name === process.env.DB_NAME)?.[key]
  : parsed?.[key];
if (value) process.stdout.write(String(value));
' "$1"
}

ensure_dependencies() {
  need_command node
  need_command npm
  need_command openssl
  need_command curl
  if [[ ! -x "$SCRIPT_DIR/node_modules/.bin/wrangler" ]]; then
    print -- "wrangler 설치 중..."
    npm install
  fi
}

ensure_login() {
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    print -u2 -- "Codex 자동 배포에는 CLOUDFLARE_API_TOKEN이 필요해."
    print -u2 -- "Cloudflare Dashboard > My Profile > API Tokens > Create Token에서 token을 만들고,"
    print -u2 -- "deploy/cloudflare-worker/.cloudflare.env에 아래처럼 저장한 뒤 다시 실행해줘."
    print -u2 -- ""
    print -u2 -- "CLOUDFLARE_API_TOKEN=여기에_붙여넣기"
    print -u2 -- ""
    print -u2 -- "권장 template: Edit Cloudflare Workers"
    print -u2 -- "D1 DB 생성까지 자동화하려면 Account > D1 > Edit 권한도 포함해야 해."
    exit 78
  fi
  if npx wrangler whoami >/dev/null 2>&1; then
    return
  fi
  print -- "Cloudflare API token 확인 중..."
  npx wrangler whoami >/dev/null
}

ensure_account_id() {
  if [[ -n "$ACCOUNT_ID" ]]; then
    return
  fi
  local whoami_output
  whoami_output="$(npx wrangler whoami)"
  ACCOUNT_ID="$(print -r -- "$whoami_output" | sed -n 's/.*│[[:space:]]*\([0-9a-f]\{32\}\)[[:space:]]*│.*/\1/p' | head -n 1)"
  if [[ -z "$ACCOUNT_ID" ]]; then
    ACCOUNT_ID="$(print -r -- "$whoami_output" | sed -n 's/.*Account ID[^0-9a-f]*\([0-9a-f]\{32\}\).*/\1/p' | head -n 1)"
  fi
  if [[ -z "$ACCOUNT_ID" ]]; then
    print -u2 -- "Cloudflare account id를 찾지 못했어. .cloudflare.env에 CLOUDFLARE_ACCOUNT_ID=...를 추가해줘."
    exit 70
  fi
  print -- "Cloudflare account 확인됨: $ACCOUNT_ID"
}

cloudflare_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local url="https://api.cloudflare.com/client/v4${path}"
  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" "$url" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$body"
  else
    curl -fsS -X "$method" "$url" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json"
  fi
}

json_result_field() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8");
const key = process.argv[1];
let parsed;
try {
  parsed = JSON.parse(input);
} catch {
  process.exit(0);
}
const value = parsed?.result?.[key] ?? parsed?.[key];
if (value != null) process.stdout.write(String(value));
' "$1"
}

ensure_workers_dev_subdomain() {
  local response existing
  response="$(cloudflare_api GET "/accounts/${ACCOUNT_ID}/workers/subdomain" 2>/dev/null || true)"
  existing="$(print -r -- "$response" | json_result_field subdomain)"
  if [[ -n "$existing" && "$existing" != "null" ]]; then
    WORKERS_DEV_SUBDOMAIN="$existing"
    print -- "workers.dev 서브도메인 확인됨: ${WORKERS_DEV_SUBDOMAIN}.workers.dev"
    return
  fi
  if [[ -n "$WORKERS_DEV_SUBDOMAIN" ]]; then
    print -- "workers.dev 서브도메인 API 조회는 못 했지만 설정값을 사용함: ${WORKERS_DEV_SUBDOMAIN}.workers.dev"
  else
    print -- "workers.dev 서브도메인 API 조회는 못 했어. 대시보드에 등록되어 있으면 배포 단계에서 계속 진행돼."
  fi
}

ensure_database() {
  local database_id
  database_id="$(current_database_id)"
  if [[ -n "$database_id" && "$database_id" != "REPLACE_WITH_D1_DATABASE_ID" ]]; then
    print -- "D1 DB 설정 확인됨: $database_id"
    return
  fi

  print -- "D1 DB 생성/조회 중: $DB_NAME"
  local list_json
  list_json="$(DB_NAME="$DB_NAME" npx wrangler d1 list --json 2>/dev/null || true)"
  if [[ -n "$list_json" ]]; then
    database_id="$(print -r -- "$list_json" | DB_NAME="$DB_NAME" wrangler_json_field uuid)"
    if [[ -z "$database_id" ]]; then
      database_id="$(print -r -- "$list_json" | DB_NAME="$DB_NAME" wrangler_json_field id)"
    fi
  fi

  if [[ -z "$database_id" ]]; then
    local create_output
    create_output="$(npx wrangler d1 create "$DB_NAME")"
    print -r -- "$create_output"
    database_id="$(print -r -- "$create_output" | sed -n 's/.*database_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | tail -n 1)"
  fi

  if [[ -z "$database_id" ]]; then
    print -u2 -- "D1 database_id를 자동으로 찾지 못했어. wrangler 출력의 database_id를 wrangler.toml에 넣고 다시 실행해줘."
    exit 70
  fi

  set_database_id "$database_id"
  print -- "wrangler.toml database_id 적용됨: $database_id"
}

ensure_token() {
  local token="${RELAY_TOKEN:-}"
  if [[ -z "$token" && -f "$TOKEN_FILE" ]]; then
    token="$(tr -d '\n\r[:space:]' < "$TOKEN_FILE")"
  fi
  if [[ -z "$token" ]]; then
    token="$(openssl rand -hex 32)"
    umask 077
    print -r -- "$token" > "$TOKEN_FILE"
    print -- "새 토큰 생성됨: $TOKEN_FILE"
  else
    umask 077
    print -r -- "$token" > "$TOKEN_FILE"
    print -- "기존 토큰 사용: $TOKEN_FILE"
  fi

  print -- "Cloudflare secret RELAY_TOKEN 적용 중..."
  printf "%s" "$token" | npx wrangler secret put RELAY_TOKEN
}

deploy_worker() {
  print -- "D1 migration 적용 중..."
  npx wrangler d1 migrations apply "$DB_NAME" --remote

  print -- "Worker 배포 중..."
  local deploy_log
  deploy_log="$(mktemp "${TMPDIR:-/tmp}/klms-cloudflare-deploy.XXXXXX")"
  npx wrangler deploy | tee "$deploy_log"

  local worker_url
  worker_url="$(sed -n 's/.*\(https:\/\/[^[:space:]]*workers.dev\).*/\1/p' "$deploy_log" | tail -n 1)"
  if [[ -z "$worker_url" ]]; then
    worker_url="https://${WORKER_NAME}.$(npx wrangler whoami 2>/dev/null | sed -n 's/.*Account ID: //p' | head -n 1).workers.dev"
  fi
  print -r -- "$worker_url" > "$SCRIPT_DIR/.worker-url"

  if command -v curl >/dev/null 2>&1 && [[ "$worker_url" == https://* ]]; then
    print -- "healthz 확인 중..."
    curl --tlsv1.2 -fsS "$worker_url/healthz"
    print
  fi

  print
  print -- "배포 완료."
  print -- "서버 주소: $worker_url"
  print -- "토큰 파일: $TOKEN_FILE"
  print
  print -- "이 값을 Mac/iPhone/Windows 앱의 서버 릴레이 설정에 똑같이 넣으면 돼."
}

ensure_dependencies
ensure_login
ensure_account_id
ensure_workers_dev_subdomain
ensure_database
ensure_token
deploy_worker
