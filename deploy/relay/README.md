# KLMS Sync Relay Deployment

이 배포 템플릿은 Windows/iPhone이 같은 네트워크 밖에서도 Mac에 동기화 요청을 보낼 수 있게 하는 HTTPS 릴레이 서버다.

구조:

```text
Windows/iPhone -> https://sync.example.com -> Caddy HTTPS/WebSocket -> relay + SQLite -> `/v1/events` revision push -> Mac 앱 -> KLMS 동기화
```

Mac이 실제 KLMS, Notes, Calendar, Reminders 작업을 실행한다. 서버는 실행 요청, 요약 숫자, sanitized 항목 목록만 저장한다.

서버 데이터 변경은 인증된 `/v1/events` WebSocket으로 즉시 전달한다. interval polling이나 long polling은 사용하지 않으며, 재연결 또는 revision gap 때만 HTTP snapshot을 한 번 읽어 누락 상태를 reconcile한다.

## 방식 1: VPS + Caddy

1. DNS에서 `sync.example.com` 같은 서브도메인을 VPS IP로 연결한다.
2. VPS에 Docker와 Docker Compose를 설치한다.
3. 이 repo를 VPS에 복사하거나 clone한다.
4. 환경 파일을 만든다.

```sh
cd deploy/relay
./init_env.sh sync.example.com
```

출력된 토큰을 저장해 둔다. iPhone/Windows에는 클라이언트 토큰을 넣고, Mac 앱에는 Mac worker 토큰을 넣는다.

5. 서버를 실행한다.

```sh
./deploy.sh
```

6. 확인한다.

```sh
./status.sh
```

Docker가 없다면 Ubuntu VPS에서 먼저 실행한다.

```sh
./bootstrap_ubuntu.sh
```

## 앱 연결값

iPhone/Windows에는 아래 값을 넣는다.

```text
서버 주소: https://sync.example.com
클라이언트 토큰: <KLMS_RELAY_CLIENT_TOKEN>
```

서브패스로 분리하고 싶으면 Caddyfile이 `/relay/*`도 지원하므로 아래 주소도 된다.

```text
서버 주소: https://sync.example.com/relay
클라이언트 토큰: <KLMS_RELAY_CLIENT_TOKEN>
```

Mac 앱에는 같은 서버 주소와 `<KLMS_RELAY_WORKER_TOKEN>`을 입력한다.

## Mac 쪽 조건

- Mac 앱에서 `서버 릴레이 사용`을 켠다.
- 서버 주소와 Mac worker 토큰을 입력한다.
- Mac 앱이 켜져 있어야 Windows/iPhone 요청을 가져가 실행한다.
- Mac이 잠자기 상태면 요청은 서버 DB에 남고, Mac이 깨어난 뒤 처리된다.

## 보안 원칙

- 외부 공개 주소는 HTTPS만 쓴다.
- `KLMS_RELAY_PUBLIC_URL`은 앱에 돌려주는 일회성 파일 링크의 기준 주소다. 프록시 헤더를 신뢰하지 않으므로 Caddy/Tunnel의 실제 HTTPS 주소를 정확히 넣는다.
- relay는 Caddy가 덮어쓴 `X-KLMS-Relay-Client-IP`를 내부 32바이트 proxy secret이 일치할 때만 신뢰한다. 외부 요청이 임의의 전달 헤더를 보내도 rate limit identity를 위조할 수 없다.
- Mac의 로컬 포트를 인터넷에 직접 열지 않는다.
- 토큰을 바꾸면 클라이언트 앱에는 새 클라이언트 토큰을, Mac 앱에는 새 worker 토큰을 다시 입력한다.
- SQLite DB는 Docker volume `relay-data`에 저장된다.
- 배포·상태·백업·복원 스크립트는 credential env의 symlink를 거부하고 현재 사용자 소유인지 확인한 뒤 권한을 `0600`으로 고정한다.
- 항목 작업 재시도는 body UUID 또는 `Idempotency-Key`를 재사용한다. 동일 key의 같은 요청은 한 번만 반영되고 다른 의도 재사용은 409다.
- 파일 업로드는 body 수신 전에 quota와 object tombstone을 SQLite transaction으로 예약한다. 실패·중단 시 파일 삭제를 확인한 뒤 quota를 반환하고, 주기 정리는 tombstone과 알려지지 않은 orphan 파일을 회수한다.

## 업데이트

repo를 갱신한 뒤:

```sh
cd deploy/relay
./deploy.sh
```

DB volume은 유지된다.

DB 백업:

```sh
./backup_db.sh
```

기본 저장 위치는 Docker volume의 `/data/backups`, 보존 기간은 14일이다. `KLMS_RELAY_BACKUP_RETENTION_DAYS=30 ./backup_db.sh`처럼 바꿀 수 있다. 백업 디렉터리는 `0700`, 파일은 `0600`이며, 실행 중인 WAL 데이터베이스를 SQLite backup API로 복사한 뒤 필수 schema, relay revision, `PRAGMA quick_check`를 모두 검증한다.
`.env.tunnel`이 있으면 백업·복원 스크립트가 Tunnel compose file과 env file을 자동으로 사용한다.

복원은 컨테이너 안의 백업 경로를 지정한다. 복원 직전 안전 백업을 추가로 만들고, relay 중지 이후 교체·시작·`/readyz` 확인 중 어느 명령이 실패하거나 종료 신호를 받아도 안전 백업을 정확히 한 번 복구한 뒤 relay를 다시 시작한다. 안전 백업 생성 전 실패는 DB를 건드리지 않고 기존 relay만 다시 시작한다.

```sh
./restore_db.sh /data/backups/klms-sync-relay.sqlite-20260714T120000Z.backup
```

마이그레이션은 relay 시작 시 additive schema 변경을 적용한다. 업데이트 전 `./backup_db.sh`, 업데이트 후 `printf '%s\n' "Authorization: Bearer $KLMS_RELAY_WORKER_TOKEN" | curl -fsS --header @- https://sync.example.com/readyz` 순서로 확인한다. 이 방식은 토큰을 `curl` 프로세스 인자에 남기지 않는다. `/healthz`는 공개 프로세스 생존만, `/readyz`는 worker token 인증 후 DB schema와 WebSocket upgrade 준비까지 검사한다.
다운로드 reservation table이 없던 이전 backup도 검증·복원할 수 있으며, relay가 시작되면서 해당 table을
additive하게 생성한다. 복원 완료 판정은 새 schema가 반영된 `/readyz` 200 응답까지 포함한다.

## 방식 2: Cloudflare Tunnel

VPS 없이 Mac이나 작은 서버에서 터널로 HTTPS 주소를 만들 수도 있다.

1. Cloudflare Zero Trust에서 Tunnel을 만든다.
2. Public hostname을 만든다.
3. Service는 아래처럼 둔다.

```text
http://proxy:8080
```

4. Tunnel token을 복사한다.
5. relay 앱 토큰, 내부 proxy secret, tunnel token을 서로 다른 권한 `0600` 파일로 만든다.

```sh
cd deploy/relay
cp relay.cloudflare.env.example .env.cloudflare
cp proxy.env.example .env.proxy
cp tunnel.env.example .env.tunnel
openssl rand -hex 32 # client token
openssl rand -hex 32 # worker token
openssl rand -hex 32 # internal proxy secret
chmod 600 .env.cloudflare .env.proxy .env.tunnel
```

`.env.cloudflare`에는 relay 공개 주소와 앱 토큰만 둔다.

```sh
KLMS_RELAY_PUBLIC_URL=https://sync.example.com
KLMS_RELAY_CLIENT_TOKEN=<client openssl 출력값>
KLMS_RELAY_WORKER_TOKEN=<worker openssl 출력값>
```

`.env.proxy`에는 별도로 생성한 내부 proxy secret만 둔다. relay와 Caddy가 같은 값을 읽으며 앱에는 입력하지 않는다.

```sh
KLMS_RELAY_TRUSTED_PROXY_SECRET=<proxy openssl 출력값>
```

`.env.tunnel`에는 Cloudflare tunnel token만 둔다.

```sh
CLOUDFLARE_TUNNEL_TOKEN=<Cloudflare tunnel token>
```

6. 실행한다.

```sh
docker compose --env-file .env.tunnel -f docker-compose.cloudflared.yml up -d --build
```

Compose의 service `env_file`은 `${CLOUDFLARE_TUNNEL_TOKEN}` 보간에 사용되지 않는다. 따라서 Tunnel 방식은 모든 `docker compose` 명령에 `--env-file .env.tunnel`을 포함해야 한다. 예: `docker compose --env-file .env.tunnel -f docker-compose.cloudflared.yml ps`.

7. 앱 연결값은 Cloudflare Public hostname을 쓴다.

```text
서버 주소: https://sync.example.com
클라이언트 토큰: <KLMS_RELAY_CLIENT_TOKEN>
```

Mac 앱에는 같은 서버 주소와 `<KLMS_RELAY_WORKER_TOKEN>`을 넣는다. Cloudflare Tunnel 방식은 포트를 열지 않아도 된다. 다만 터널을 실행하는 Mac/서버가 꺼져 있으면 Windows/iPhone 요청은 처리되지 않는다.
