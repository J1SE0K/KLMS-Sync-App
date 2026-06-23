# KLMS Sync 서버 릴레이

서버 릴레이는 모든 companion 앱이 같은 화면 상태를 보게 하는 HTTPS API다. 과제, 시험, 공지, 파일, 읽음/중요/숨김/완료, 메일 분석 항목, 요청 기록은 서버 DB를 원본으로 삼고, Mac 앱은 KLMS 수집과 macOS 앱 반영이 필요할 때만 worker로 동작한다.

구조:

```text
iPhone/iPad/Windows/Web <-> HTTPS 서버 릴레이 + DB <-> Mac worker -> KLMS/Notes/Calendar/Reminders
```

0원 유지가 최우선이면 Cloudflare Workers + D1 배포판을 쓴다.

```text
iPhone/iPad/Windows/Web <-> Cloudflare Worker + D1/R2 <-> Mac worker
```

Cloudflare용 구현은 [deploy/cloudflare-worker](../deploy/cloudflare-worker)에 있다. 기존 앱 API와 같아서 배포 후 서버 주소와 클라이언트/worker 토큰만 바꾸면 된다.

서버에는 다음만 저장한다.

- 실행 요청 종류: 전체, 과제/시험, 공지, 파일, 진단, 요약 갱신
- sanitized 요약 숫자: 과제/시험/공지/파일/캘린더 변경 수
- sanitized 항목 목록: 과목명, 제목, 표시 시각, 상태, 첨부 개수
- 사용자 표시 상태: 읽음, 중요, 숨김, 완료, 메일 분석으로 추가한 항목
- 실행 phase, 마지막 exit code, 로그인 필요 여부, KAIST 인증 번호

서버에는 원본 로그, KLMS URL, `config.env`, Kaikey state, 절대 파일 경로를 저장하지 않는다. 항목 ID도 원본 URL을 그대로 올리지 않고 앱에서 해시한 값만 보낸다. Mac이 꺼져 있어도 앱은 마지막 서버 데이터를 그대로 보여주고, 새 동기화/파일 준비/Notes·Calendar·Reminders 반영만 대기 상태가 된다.

## 실행

토큰을 먼저 두 개 만든다. 클라이언트 토큰은 iPhone/Windows/Web 요청용이고, worker 토큰은 Mac 앱이 요청을 처리하고 상태를 올릴 때만 쓴다.

```sh
CLIENT_TOKEN="$(openssl rand -hex 32)"
WORKER_TOKEN="$(openssl rand -hex 32)"
```

로컬에서 서버를 실행한다.

```sh
KLMS_RELAY_CLIENT_TOKEN="$CLIENT_TOKEN" \
KLMS_RELAY_WORKER_TOKEN="$WORKER_TOKEN" \
KLMS_RELAY_HOST=127.0.0.1 \
KLMS_RELAY_PORT=18484 \
tools/klms_relay_server.mjs
```

기본 DB 파일은 `~/.local/state/klms-sync-relay.sqlite`다. 위치를 바꾸려면:

```sh
KLMS_RELAY_DB=/path/to/klms-sync-relay.sqlite tools/klms_relay_server.mjs
```

## Mac 백그라운드 서비스

Mac을 서버 worker로 쓸 때는 릴레이 서버를 백그라운드 서비스로 켜 둔다. 토큰이 없으면 설치 스크립트가 자동으로 만든다.

```sh
tools/install_klms_relay_agent.sh install
```

설치 위치:

- 환경 파일: `~/Library/Application Support/KLMSNotesSync/runtime/relay/relay.env`
- DB: `~/Library/Application Support/KLMSNotesSync/runtime/relay/klms-sync-relay.sqlite`
- 로그: `~/Library/Application Support/KLMSNotesSync/runtime/logs/relay.stdout.log`, `relay.stderr.log`
- LaunchAgent: `~/Library/LaunchAgents/com.local.klms-sync-relay.plist`

상태 확인:

```sh
tools/install_klms_relay_agent.sh status
```

서버 주소와 마스킹된 토큰 출력:

```sh
tools/install_klms_relay_agent.sh print-config
```

전체 토큰을 다시 봐야 할 때만 명시적으로 출력한다.

```sh
tools/install_klms_relay_agent.sh print-config --show-token
```

해제:

```sh
tools/install_klms_relay_agent.sh uninstall
```

DB와 토큰 파일은 해제해도 지우지 않는다.

## 공개 HTTPS

iPhone에서 외부 접속하려면 서버 주소는 HTTPS여야 한다. 권장 방식은 서버를 `127.0.0.1:18484`로만 띄우고 Caddy, nginx, Cloudflare Tunnel 같은 앞단에서 HTTPS를 종료하는 것이다.

Mac 포트를 인터넷에 직접 열지 않는다.

바로 배포하려면 [deploy/relay](../deploy/relay)를 쓴다. Docker Compose가 `klms_relay_server.mjs`, SQLite volume, Caddy HTTPS reverse proxy를 같이 띄운다.

```sh
cd deploy/relay
cp relay.env.example .env
# .env에 KLMS_RELAY_DOMAIN, KLMS_RELAY_CLIENT_TOKEN, KLMS_RELAY_WORKER_TOKEN 입력
docker compose up -d --build
```

이 경우 클라이언트 앱 연결값은 아래처럼 둔다.

```text
서버 주소: https://sync.example.com
클라이언트 토큰: <KLMS_RELAY_CLIENT_TOKEN>
```

Mac 앱에는 같은 서버 주소와 `<KLMS_RELAY_WORKER_TOKEN>`도 입력한다.

서브패스를 쓰고 싶으면 `https://sync.example.com/relay`도 지원한다.

VPS 없이 Cloudflare Tunnel을 쓸 수도 있다.

```sh
cd deploy/relay
cp relay.cloudflare.env.example .env.cloudflare
# .env.cloudflare에 KLMS_RELAY_CLIENT_TOKEN, KLMS_RELAY_WORKER_TOKEN, CLOUDFLARE_TUNNEL_TOKEN 입력
docker compose -f docker-compose.cloudflared.yml up -d --build
```

Cloudflare Public hostname의 서비스 대상은 `http://relay:18484`로 둔다.

## 앱 연결

Mac 앱:

1. 설정을 연다.
2. `서버 릴레이` 설정을 펼치고 `서버 릴레이 사용`을 켠다.
3. HTTPS 서버 주소, 클라이언트 토큰, Mac worker 토큰을 입력한다.
4. `서버 연결 정보 복사`를 누른다.

iPhone/iPad 앱:

1. `설정` 탭을 연다.
2. `서버 릴레이`를 펼친다.
3. Mac 앱에서 복사한 서버 연결 정보를 붙여넣는다.
4. `서버 연결 확인`을 누른다.
5. `대시보드`에서 원하는 동기화나 항목 작업을 요청한다.

Windows 앱:

1. `apps/KLMSyncWindows`에서 앱을 실행한다.
2. Mac 앱에서 복사한 서버 연결 정보를 붙여넣는다.
3. `붙여넣기 읽기`, `저장`, `연결 확인`을 누른다.
4. 대시보드에서 항목을 열고 읽음/중요/숨김 같은 항목 처리를 요청한다.

Mac 앱은 KLMS 수집이나 macOS 앱 반영이 필요할 때 켜져 있어야 한다. 서버 요청은 WebSocket 실시간 이벤트로 받고 놓친 이벤트는 짧은 fallback 확인으로 보강한다. Mac은 한 번에 하나씩 실행한다. Windows와 iPhone/iPad는 Mac과 같은 네트워크에 있을 필요가 없다. 대신 모든 앱이 같은 HTTPS 서버 릴레이 주소를 쓰고, Windows/iPhone/iPad는 클라이언트 토큰, Mac은 worker 토큰을 사용해야 한다.

Mac 앱은 상태를 올릴 때 과제, 시험, 공지, 파일 목록도 같이 `/v1/sync-data`에 올린다. 서버는 클라이언트가 이미 누른 읽음/중요/숨김/완료/메일 분석 항목을 새 목록 위에 다시 적용하므로, Mac이 오래된 KLMS 결과를 다시 올려도 앱 화면이 되돌아가지 않는다. iPhone/iPad/Windows/Mac 화면은 이 `/v1/sync-data`를 기준으로 표시한다.

## API

모든 `/v1/*` 요청은 `Authorization: Bearer <token>` 헤더가 필요하다. 클라이언트 토큰은 요청 생성/조회만 가능하고, worker 토큰은 Mac 앱 전용으로 상태 게시와 대기 요청 처리를 수행한다.

- `GET /healthz`: 서버 상태 확인. 인증 없음.
- `GET /v1/status`: 클라이언트/worker. 현재 sanitized 상태와 최근 요청.
- `POST /v1/status`: worker 전용. Mac 앱이 sanitized 상태를 게시.
- `POST /v1/commands`: 클라이언트/worker. iPhone/Windows/Web이 실행 요청 생성.
- `GET /v1/commands/pending`: worker 전용. Mac 앱이 대기 요청 조회.
- `GET /v1/commands/recent?limit=8`: 클라이언트/worker. 최근 요청 조회.
- `PUT /v1/commands/:id`: worker 전용. Mac 앱이 실행 상태 갱신.
- `POST /v1/sync-data`: worker 전용. Mac 앱이 sanitized 과제/시험/공지/파일 목록 게시.
- `GET /v1/sync-data?kind=exam&limit=50`: 클라이언트/worker. iPhone/Windows/Web 클라이언트가 목록 조회.
- `GET /v1/shared-settings`: 클라이언트/worker. Mac을 기다리지 않아도 되는 앱 공통 설정 조회.
- `PUT /v1/shared-settings/:key`: 클라이언트/worker. 허용된 앱 공통 설정만 서버에 바로 저장. 현재 `KLMS_APPEARANCE_MODE`, `KLMS_UPDATE_NOTICE_NOTES`를 지원.
- `POST /v1/item-actions`: 클라이언트/worker. iPhone/Windows/Web 클라이언트가 항목 처리 요청 생성. 서버 화면에는 즉시 반영되고, Mac worker가 나중에 Notes/Calendar/Reminders/로컬 상태에 반영한다.
- `GET /v1/item-actions/recent?limit=10`: 클라이언트/worker. 최근 항목 처리 요청 조회.
- `GET /v1/item-actions/pending`: worker 전용. Mac 앱이 대기 항목 처리 요청 조회.
- `PUT /v1/item-actions/:id`: worker 전용. Mac 앱이 항목 처리 상태 갱신.
- `POST /v1/setting-actions`: 클라이언트/worker. Mac 로컬 `config.env`에 반영해야 하는 설정 변경 요청 생성. 서버 설정 목록에는 즉시 반영되고, Mac worker가 나중에 설치본 설정 파일에 저장한다.
- `GET /v1/setting-actions/pending`: worker 전용. Mac 앱이 대기 설정 변경 요청 조회.
- `PUT /v1/setting-actions/:id`: worker 전용. Mac 앱이 설정 변경 처리 상태 갱신.

`kind` 값은 현재 `assignment`, `completedAssignment`, `assignmentCandidate`, `exam`, `examCandidate`, `helpDesk`, `notice`, `file`을 쓴다.
