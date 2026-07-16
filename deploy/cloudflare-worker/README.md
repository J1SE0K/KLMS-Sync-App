# KLMS Sync Cloudflare Relay

Cloudflare Workers + D1 + R2로 KLMS Sync 서버 릴레이를 운영하는 배포판이다.
Mac/iPhone/Windows 앱은 기존 서버 릴레이 API를 그대로 쓰기 때문에, 배포 후 서버 주소와 클라이언트/worker 토큰만 바꾸면 된다.

구조:

```text
iPhone/iPad/Windows/Mac 앱 -> Cloudflare Worker HTTPS API/WebSocket -> D1 DB -> Mac worker -> KLMS 동기화
iPhone/iPad/Windows 파일 열기 요청 -> Mac worker -> R2 임시 업로드 -> 만료 링크 다운로드
```

서버에는 sanitized 상태와 항목만 저장한다.

- 저장함: 실행 요청, phase, exit code, 로그인 필요 여부, KAIST 인증 번호, 요약 숫자, sanitized 과제/시험/공지/파일 목록, 파일 열기 요청/만료 시간
- 임시 저장함: 사용자가 파일 열기를 요청한 파일 원본만 R2에 10분 저장
- 저장하지 않음: 원본 로그, KLMS URL, `config.env`, 인증 상태 파일, 로컬 절대 경로, 요청하지 않은 다운로드 파일 본문

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
- `file-access/` R2 orphan fallback lifecycle(1일) 확인/생성
- ignored `wrangler.local.toml` 생성 후 `database_id` 적용
- 클라이언트/worker 릴레이 토큰 생성 및 Cloudflare secret 등록
- D1 migration 적용
- Worker 배포
- `/readyz` schema·D1·R2·WebSocket·mutation coordinator 준비 확인

토큰은 로컬의 `.relay-client-token`, `.relay-worker-token`에 저장된다. 이 파일들은 git에 올리지 않는다.

Codex 안에서는 `wrangler login` 브라우저 인증이 non-interactive로 막힐 수 있어서, Cloudflare API token 방식이 가장 안정적이다.

1. Cloudflare Dashboard > My Profile > API Tokens > Create Token으로 간다.
2. 권장 template은 `Edit Cloudflare Workers`다.
3. D1/R2 생성까지 자동화하려면 `Account > D1 > Edit`, `Account > R2 > Edit` 권한도 포함한다.
4. 생성된 token을 `deploy/cloudflare-worker/.cloudflare.env`에 저장한다.

```sh
cp .cloudflare.env.example .cloudflare.env
# .cloudflare.env의 CLOUDFLARE_API_TOKEN 수정
chmod 600 .cloudflare.env
npm run setup
```

설정 스크립트는 credential 파일이 현재 사용자 소유인지 확인하고 `0600`으로 고정한 뒤에만
읽는다. 생성되는 `.relay-client-token`, `.relay-worker-token`, `wrangler.local.toml`도 `0600`이다.

수동으로 하려면 아래 순서를 따르면 된다.

```sh
cd deploy/cloudflare-worker
npm install
npx wrangler login
test -f wrangler.local.toml || cp wrangler.toml wrangler.local.toml
```

`wrangler.local.toml`이 이미 있으면 덮어쓰지 않는다. 기존 파일을 덮으면 붙여 넣은 `database_id`가 placeholder로 돌아갈 수 있다.

## 2. D1 DB 생성

```sh
npx wrangler d1 create klms-sync-relay
```

출력에 나오는 `database_id`를 ignored `wrangler.local.toml`의 `database_id`에 넣는다.
tracked 기본 파일인 `wrangler.toml`에는 실제 Cloudflare 리소스 ID를 넣지 않는다.

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
printf "%s" "$CLIENT_TOKEN" | npx wrangler --config wrangler.local.toml secret put RELAY_CLIENT_TOKEN
printf "%s" "$WORKER_TOKEN" | npx wrangler --config wrangler.local.toml secret put RELAY_WORKER_TOKEN
```

수동 입력 프롬프트를 쓰는 경우에도 secret 이름은 `RELAY_CLIENT_TOKEN`, `RELAY_WORKER_TOKEN`이다.

## 4. DB migration 적용

```sh
npx wrangler --config wrangler.local.toml d1 migrations apply klms-sync-relay --remote
```

모든 migration을 Worker 배포 전에 적용해야 한다. 운영 DB는 먼저 권한을 제한한 로컬 파일로 export한다.

```sh
mkdir -p backups && chmod 700 backups
npx wrangler --config wrangler.local.toml d1 export klms-sync-relay --remote \
  --output "backups/klms-sync-relay-$(date -u +%Y%m%dT%H%M%SZ).sql"
chmod 600 backups/klms-sync-relay-*.sql
npx wrangler --config wrangler.local.toml d1 migrations apply klms-sync-relay --remote
```

`0006_file_upload_claim_lease.sql`은
Worker 중단 뒤 남은 파일 업로드·삭제 claim을 15분 후 안전하게 회수하며, 이 내부 lease는
화면에 표시되는 `updated_at`이나 relay revision/event를 변경하지 않는다.
`0007_sanitize_active_commands.sql`은 예전 DB에 남은 잘못된 UUID·명령 종류·timestamp의
활성 명령을 `macUnavailable`로 종료해, 유효한 새 명령이 unique active slot에 막히지 않게 한다.
`0008_relay_a_plus_integrity.sql`은 항목 작업 idempotency key와 파일 업로드 tombstone·예약 quota를
추가한다. 이 migration이 적용되기 전에는 새 Worker가 `/readyz`에서 503을 반환하므로 트래픽을
받기 전에 migration → deploy → `/readyz` 순서로 진행한다.

`0009_file_download_reservations.sql`은 다운로드 quota를 R2 조회 전에 원자 예약하고 실패 시 정확히
되돌리기 위한 멱등 reservation lease를 추가한다. 기존 DB에는 Worker 배포 전에 이 migration을 먼저
적용하며, 이전 backup을 복원한 경우에도 전체 migration 적용 후 `/readyz`가 200인지 확인한다.

## 5. 배포

```sh
npx wrangler --config wrangler.local.toml deploy
```

배포 후 주소는 보통 아래 형태다.

```text
https://klms-sync-relay.<cloudflare-account>.workers.dev
```

상태 확인:

```sh
printf '%s\n' "Authorization: Bearer $WORKER_TOKEN" \
  | curl -fsS --header @- https://klms-sync-relay.<cloudflare-account>.workers.dev/readyz
```

앱 연결값:

```text
서버 주소: https://klms-sync-relay.<cloudflare-account>.workers.dev
클라이언트 토큰: <RELAY_CLIENT_TOKEN>
```

Mac 앱에는 같은 서버 주소와 `<RELAY_WORKER_TOKEN>`을 입력한다.

## 파일 열기 링크

iPhone/iPad/Windows에서 파일 항목의 `파일 열기`를 누르면 서버에는 파일 열기 요청만 저장된다.
Mac 앱은 인증된 `/v1/events` WebSocket에서 revision이 포함된 변경 이벤트를 즉시 받는다. interval polling이나 long polling은 사용하지 않는다. 연결이 끊겼다가 복구되거나 revision gap이 감지된 경우에만 최신 snapshot을 한 번 가져와 reconcile한다. 요청을 받으면 로컬 `course_files` 원본을 찾고, 해당 파일 하나만 R2에 임시 업로드한다.
서버는 짧게 만료되는 다운로드 URL을 내려준다.

- 기본 만료 시간: 5분
- 만료 후 처리: R2 object 삭제, D1의 파일 열기 요청 record 삭제
- 업로드 실패 후 처리: body 수신 전에 D1이 quota와 object key tombstone을 원자적으로 예약하고,
  R2 삭제가 확인된 뒤에만 예약 quota를 반환한다. Worker가 중단되면 cron이 15분 지난 tombstone을 재처리한다.
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

앱 정리 작업이 장시간 중단되는 재해 상황의 마지막 방어선으로 `file-access/` prefix에 1일 R2
lifecycle을 추가한다. 앱의 5분 TTL/cron 정리가 1차 수단이고 lifecycle은 orphan fallback이다.

```sh
npx wrangler --config wrangler.local.toml r2 bucket lifecycle add \
  klms-sync-file-relay klms-file-relay-fallback file-access/ \
  --expire-days 1 --abort-multipart-days 1 --force
```

수동으로 R2 bucket을 만들려면:

```sh
npx wrangler --config wrangler.local.toml r2 bucket create klms-sync-file-relay
```

`wrangler.toml` 템플릿과 `wrangler.local.toml`에는 아래 binding이 필요하다.
실제 bucket 이름을 개인용으로 바꿨다면 ignored `wrangler.local.toml`에만 반영한다.

```toml
[[r2_buckets]]
binding = "RELAY_FILES"
bucket_name = "klms-sync-file-relay"

[[durable_objects.bindings]]
name = "RELAY_REALTIME"
class_name = "RelayRealtimeRoom"

[[durable_objects.bindings]]
name = "RELAY_MUTATIONS"
class_name = "RelayMutationCoordinator"
```

`RELAY_MUTATIONS`는 D1/meta/revision을 확정하는 짧은 변경 구간만 단일 named Durable
Object queue에서 직렬화한다. 느린 업로드 body 수신, R2 put/get/delete는 queue 밖에서
실행하고, 앞뒤의 짧은 claim·quota 예약·조건부 finalize/삭제 commit이 대상 record의
`status`·`object_key`·`updated_at`을 다시 확인한다. 따라서 대용량 파일 전송 중에도 상태,
동기화, 명령 API가 전역 queue에 막히지 않는다. binding이 없으면 Worker는 해당 API를
503으로 차단하고 `/healthz`의 `configured`를 `false`로 반환한다. `/healthz`는 process
liveness이고 worker token으로 인증하는 `/readyz`는 token, D1 schema, R2, WebSocket, mutation coordinator를 모두 검사한다. 여러 Worker isolate가
동시에 JSON snapshot을 갱신하면서 설정·항목·요청 로그를 유실하는 것을 막기 위한 필수
binding이다.

## 로컬 테스트

로컬 D1에 migration을 적용하고 Worker를 띄운다.

```sh
cp .dev.vars.example .dev.vars
# .dev.vars의 RELAY_CLIENT_TOKEN, RELAY_WORKER_TOKEN 수정
npx wrangler --config wrangler.local.toml d1 migrations apply klms-sync-relay --local
npx wrangler --config wrangler.local.toml dev
```

다른 터미널에서 확인한다.

```sh
printf '%s\n' "Authorization: Bearer <RELAY_WORKER_TOKEN>" \
  | curl -fsS --header @- http://127.0.0.1:8787/readyz
printf '%s\n' "Authorization: Bearer <RELAY_CLIENT_TOKEN>" \
  | curl -fsS --header @- http://127.0.0.1:8787/v1/status
```

## 앱에서 쓰는 API

기존 Node/SQLite 릴레이와 동일하다.

- `GET /healthz` (공개 liveness), worker token `GET /readyz` (인증된 readiness)
- 클라이언트/worker: `GET /v1/status`, `POST /v1/commands`, `GET /v1/commands/recent?limit=8`, `GET /v1/sync-data?kind=exam&limit=50`, `GET /v1/shared-settings`, `PUT /v1/shared-settings/:key`, `POST /v1/item-actions`, `GET /v1/item-actions/recent?limit=10`
- 파일 열기: 클라이언트 `POST /v1/file-access`, `GET /v1/file-access/recent`; worker `GET /v1/file-access/pending`, `PUT /v1/file-access/:id`, `PUT /v1/file-access/:id/upload`
- worker 전용: `POST /v1/status`, `GET /v1/commands/pending`, `PUT /v1/commands/:id`, `POST /v1/sync-data`, `GET /v1/item-actions/pending`, `PUT /v1/item-actions/:id`

## 무료 티어에 맞춘 내부 저장 방식

명령과 항목 처리 요청은 D1 row로 저장한다.
과제/시험/공지/파일 목록은 매 동기화마다 수백~수천 row를 쓰지 않도록, sanitized JSON payload 하나로 저장한다.
그래서 Mac이 목록을 다시 올릴 때 D1 write 사용량이 크게 늘지 않는다.

## 서브패스

앱 서버 주소를 `https://example.com/relay`로 쓰고 싶으면 Worker route를 그 경로에 붙이면 된다.
Worker는 기본적으로 `/relay/v1/status`, `/relay/healthz`, `/relay/readyz`도 인식한다.
다른 prefix를 쓰려면 Worker 환경 변수 `RELAY_PATH_PREFIX`를 설정한다.
