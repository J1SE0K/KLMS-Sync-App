# KLMS Sync Cloudflare Relay

Cloudflare Workers + D1로 KLMS Sync 서버 릴레이를 운영하는 배포판이다.
Mac/iPhone/Windows 앱은 기존 서버 릴레이 API를 그대로 쓰기 때문에, 배포 후 서버 주소와 클라이언트/worker 토큰만 바꾸면 된다.

구조:

```text
iPhone/Windows/Mac 앱 -> Cloudflare Worker HTTPS API -> D1 DB -> Mac 앱 polling -> KLMS 동기화
```

서버에는 sanitized 상태와 항목만 저장한다.

- 저장함: 실행 요청, phase, exit code, 로그인 필요 여부, KAIST 인증 번호, 요약 숫자, sanitized 과제/시험/공지/파일 목록
- 저장하지 않음: 원본 로그, KLMS URL, `config.env`, Kaikey state, 로컬 절대 경로, 다운로드 파일 본문

## 1. Cloudflare 로그인

한 번에 자동 설정하려면 아래 명령을 쓴다.

```sh
cd deploy/cloudflare-worker
npm run setup
```

이 스크립트가 자동으로 처리한다.

- `npm install`
- Cloudflare 로그인 확인
- D1 DB 생성/조회
- `wrangler.toml`의 `database_id` 적용
- 클라이언트/worker 릴레이 토큰 생성 및 Cloudflare secret 등록
- D1 migration 적용
- Worker 배포
- `/healthz` 연결 확인

토큰은 로컬의 `.relay-client-token`, `.relay-worker-token`에 저장된다. 이 파일들은 git에 올리지 않는다.

Codex 안에서는 `wrangler login` 브라우저 인증이 non-interactive로 막힐 수 있어서, Cloudflare API token 방식이 가장 안정적이다.

1. Cloudflare Dashboard > My Profile > API Tokens > Create Token으로 간다.
2. 권장 template은 `Edit Cloudflare Workers`다.
3. D1 DB 생성까지 자동화하려면 `Account > D1 > Edit` 권한도 포함한다.
4. 생성된 token을 `deploy/cloudflare-worker/.cloudflare.env`에 저장한다.

```sh
cp .cloudflare.env.example .cloudflare.env
# .cloudflare.env의 CLOUDFLARE_API_TOKEN 수정
npm run setup
```

수동으로 하려면 아래 순서를 따르면 된다.

```sh
cd deploy/cloudflare-worker
npm install
npx wrangler login
```

## 2. D1 DB 생성

```sh
npx wrangler d1 create klms-sync-relay
```

출력에 나오는 `database_id`를 `wrangler.toml`의 `database_id`에 넣는다.

```toml
[[d1_databases]]
binding = "RELAY_DB"
database_name = "klms-sync-relay"
database_id = "여기에-붙여넣기"
```

## 3. 토큰 설정

토큰을 두 개 만든다. 클라이언트 토큰은 iPhone/Windows/Web 요청용이고, worker 토큰은 Mac 앱이 요청을 처리하고 상태를 올릴 때만 쓴다.

```sh
CLIENT_TOKEN="$(openssl rand -hex 32)"
WORKER_TOKEN="$(openssl rand -hex 32)"
```

Worker secret에 저장한다.

```sh
printf "%s" "$CLIENT_TOKEN" | npx wrangler secret put RELAY_CLIENT_TOKEN
printf "%s" "$WORKER_TOKEN" | npx wrangler secret put RELAY_WORKER_TOKEN
```

수동 입력 프롬프트를 쓰는 경우에도 secret 이름은 `RELAY_CLIENT_TOKEN`, `RELAY_WORKER_TOKEN`이다.

## 4. DB migration 적용

```sh
npx wrangler d1 migrations apply klms-sync-relay --remote
```

## 5. 배포

```sh
npx wrangler deploy
```

배포 후 주소는 보통 아래 형태다.

```text
https://klms-sync-relay.<cloudflare-account>.workers.dev
```

상태 확인:

```sh
curl -fsS https://klms-sync-relay.<cloudflare-account>.workers.dev/healthz
```

앱 연결값:

```text
서버 주소: https://klms-sync-relay.<cloudflare-account>.workers.dev
클라이언트 토큰: <RELAY_CLIENT_TOKEN>
```

Mac 앱에는 같은 서버 주소와 `<RELAY_WORKER_TOKEN>`을 입력한다.

## 로컬 테스트

로컬 D1에 migration을 적용하고 Worker를 띄운다.

```sh
cp .dev.vars.example .dev.vars
# .dev.vars의 RELAY_CLIENT_TOKEN, RELAY_WORKER_TOKEN 수정
npx wrangler d1 migrations apply klms-sync-relay --local
npx wrangler dev
```

다른 터미널에서 확인한다.

```sh
curl -fsS http://127.0.0.1:8787/healthz
curl -fsS -H "Authorization: Bearer <RELAY_CLIENT_TOKEN>" http://127.0.0.1:8787/v1/status
```

## 앱에서 쓰는 API

기존 Node/SQLite 릴레이와 동일하다.

- `GET /healthz`
- 클라이언트/worker: `GET /v1/status`, `POST /v1/commands`, `GET /v1/commands/recent?limit=8`, `GET /v1/sync-data?kind=exam&limit=50`, `POST /v1/item-actions`, `GET /v1/item-actions/recent?limit=10`
- worker 전용: `POST /v1/status`, `GET /v1/commands/pending`, `PUT /v1/commands/:id`, `POST /v1/sync-data`, `GET /v1/item-actions/pending`, `PUT /v1/item-actions/:id`

## 무료 티어에 맞춘 내부 저장 방식

명령과 항목 처리 요청은 D1 row로 저장한다.
과제/시험/공지/파일 목록은 매 동기화마다 수백~수천 row를 쓰지 않도록, sanitized JSON payload 하나로 저장한다.
그래서 Mac이 목록을 다시 올릴 때 D1 write 사용량이 크게 늘지 않는다.

## 서브패스

앱 서버 주소를 `https://example.com/relay`로 쓰고 싶으면 Worker route를 그 경로에 붙이면 된다.
Worker는 기본적으로 `/relay/v1/status`와 `/relay/healthz`도 인식한다.
다른 prefix를 쓰려면 Worker 환경 변수 `RELAY_PATH_PREFIX`를 설정한다.
