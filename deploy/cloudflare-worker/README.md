# KLMS Sync Cloudflare Relay

Cloudflare Workers + D1 + R2로 KLMS Sync 서버 릴레이를 운영하는 배포판이다.
Mac/iPhone/Windows 앱은 기존 서버 릴레이 API를 그대로 쓰기 때문에, 배포 후 서버 주소와 클라이언트/worker 토큰만 바꾸면 된다.

구조:

```text
iPhone/Windows/Mac 앱 -> Cloudflare Worker HTTPS API -> D1 DB -> Mac 앱 polling -> KLMS 동기화
iPhone/Windows 파일 열기 요청 -> Mac 앱 -> R2 임시 업로드 -> 만료 링크 다운로드
```

서버에는 sanitized 상태와 항목만 저장한다.

- 저장함: 실행 요청, phase, exit code, 로그인 필요 여부, KAIST 인증 번호, 요약 숫자, sanitized 과제/시험/공지/파일 목록, 파일 열기 요청/만료 시간
- 임시 저장함: 사용자가 파일 열기를 요청한 파일 원본만 R2에 10분 저장
- 저장하지 않음: 원본 로그, KLMS URL, `config.env`, Kaikey state, 로컬 절대 경로, 요청하지 않은 다운로드 파일 본문

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
- R2 임시 파일 버킷 생성/조회
- `wrangler.toml`의 `database_id` 적용
- 클라이언트/worker 릴레이 토큰 생성 및 Cloudflare secret 등록
- D1 migration 적용
- Worker 배포
- `/healthz` 연결 확인

토큰은 로컬의 `.relay-client-token`, `.relay-worker-token`에 저장된다. 이 파일들은 git에 올리지 않는다.

Codex 안에서는 `wrangler login` 브라우저 인증이 non-interactive로 막힐 수 있어서, Cloudflare API token 방식이 가장 안정적이다.

1. Cloudflare Dashboard > My Profile > API Tokens > Create Token으로 간다.
2. 권장 template은 `Edit Cloudflare Workers`다.
3. D1/R2 생성까지 자동화하려면 `Account > D1 > Edit`, `Account > R2 > Edit` 권한도 포함한다.
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

## 파일 열기 링크

iPhone/Windows에서 파일 항목의 `파일 열기`를 누르면 서버에는 파일 열기 요청만 저장된다.
Mac 앱이 polling으로 요청을 받아 로컬 `course_files` 원본을 찾고, 해당 파일 하나만 R2에 임시 업로드한다.
서버는 짧게 만료되는 다운로드 URL을 내려준다.

- 기본 만료 시간: 5분
- 만료 후 처리: R2 object 삭제, D1의 파일 열기 요청 record 삭제
- 필요한 저장소: `RELAY_FILES` R2 binding
- 파일 원본이 Mac 로컬 `course_files`에 없으면 요청은 실패한다. 이 경우 먼저 파일 동기화를 실행해야 한다.

기본 비용 방어선:

```toml
[vars]
FILE_RELAY_MAX_UPLOAD_BYTES = "26214400"       # 파일 1개 최대 25MB
FILE_RELAY_DAILY_UPLOADS = "20"                # 하루 업로드 20회
FILE_RELAY_DAILY_UPLOAD_BYTES = "262144000"    # 하루 업로드 총량 250MB
FILE_RELAY_DAILY_DOWNLOADS = "100"             # 하루 다운로드 100회
FILE_RELAY_DOWNLOADS_PER_LINK = "3"            # 링크 1개당 다운로드 3회
FILE_RELAY_TTL_SECONDS = "300"                 # 링크 5분 만료
FILE_RELAY_MAX_PENDING_REQUESTS = "20"         # 대기 중 파일 요청 20개
```

Cloudflare R2 무료 구간보다 훨씬 낮게 잡은 앱 자체 제한이다.
Cloudflare 자체 billing hard cap은 별도로 보장되지 않으므로, Dashboard의 billing 알림도 같이 켜두는 게 좋다.

수동으로 R2 bucket을 만들려면:

```sh
npx wrangler r2 bucket create klms-sync-file-relay
```

`wrangler.toml`에는 아래 binding이 필요하다.

```toml
[[r2_buckets]]
binding = "RELAY_FILES"
bucket_name = "klms-sync-file-relay"
```

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
- 파일 열기: 클라이언트 `POST /v1/file-access`, `GET /v1/file-access/recent`; worker `GET /v1/file-access/pending`, `PUT /v1/file-access/:id`, `PUT /v1/file-access/:id/upload`
- worker 전용: `POST /v1/status`, `GET /v1/commands/pending`, `PUT /v1/commands/:id`, `POST /v1/sync-data`, `GET /v1/item-actions/pending`, `PUT /v1/item-actions/:id`

## 무료 티어에 맞춘 내부 저장 방식

명령과 항목 처리 요청은 D1 row로 저장한다.
과제/시험/공지/파일 목록은 매 동기화마다 수백~수천 row를 쓰지 않도록, sanitized JSON payload 하나로 저장한다.
그래서 Mac이 목록을 다시 올릴 때 D1 write 사용량이 크게 늘지 않는다.

## 서브패스

앱 서버 주소를 `https://example.com/relay`로 쓰고 싶으면 Worker route를 그 경로에 붙이면 된다.
Worker는 기본적으로 `/relay/v1/status`와 `/relay/healthz`도 인식한다.
다른 prefix를 쓰려면 Worker 환경 변수 `RELAY_PATH_PREFIX`를 설정한다.
