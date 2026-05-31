# KLMS Sync 서버 릴레이

서버 릴레이는 iPhone이 집 밖에 있을 때 Mac 앱에 실행 요청을 전달하고, Mac이 정리한 동기화 요약 데이터를 DB에 저장하는 작은 HTTPS API다.

구조:

```text
iPhone/Windows/Web -> HTTPS 서버 릴레이 + SQLite DB -> Mac 앱 polling -> KLMS 동기화 실행
```

서버에는 다음만 저장한다.

- 실행 요청 종류: 전체, 과제/시험, 공지, 파일, 진단, 요약 갱신
- sanitized 요약 숫자: 과제/시험/공지/파일/캘린더 변경 수
- sanitized 항목 목록: 과목명, 제목, 표시 시각, 상태, 첨부 개수
- 실행 phase, 마지막 exit code, 로그인 필요 여부, KAIST 인증 번호

서버에는 원본 로그, KLMS URL, `config.env`, Kaikey state, 절대 파일 경로를 저장하지 않는다. 항목 ID도 원본 URL을 그대로 올리지 않고 앱에서 해시한 값만 보낸다.

## 실행

토큰을 먼저 만든다.

```sh
openssl rand -hex 32
```

로컬에서 서버를 실행한다.

```sh
KLMS_RELAY_TOKEN='위에서 만든 토큰' \
KLMS_RELAY_HOST=127.0.0.1 \
KLMS_RELAY_PORT=18484 \
tools/klms_relay_server.mjs
```

기본 DB 파일은 `~/.local/state/klms-sync-relay.sqlite`다. 위치를 바꾸려면:

```sh
KLMS_RELAY_DB=/path/to/klms-sync-relay.sqlite tools/klms_relay_server.mjs
```

## Mac에서 자동 실행

Mac을 서버 worker로 쓸 때는 LaunchAgent로 릴레이 서버를 켜 둔다. 토큰이 없으면 설치 스크립트가 자동으로 만든다.

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

서버 주소와 토큰 출력:

```sh
tools/install_klms_relay_agent.sh print-config
```

해제:

```sh
tools/install_klms_relay_agent.sh uninstall
```

DB와 토큰 파일은 해제해도 지우지 않는다.

## 공개 HTTPS

iPhone에서 외부 접속하려면 서버 주소는 HTTPS여야 한다. 권장 방식은 서버를 `127.0.0.1:18484`로만 띄우고 Caddy, nginx, Cloudflare Tunnel 같은 앞단에서 HTTPS를 종료하는 것이다.

Mac 포트를 인터넷에 직접 열지 않는다.

## 앱 연결

Mac 앱:

1. 설정을 연다.
2. iPhone 섹션에서 `서버 릴레이 사용`을 켠다.
3. HTTPS 서버 주소와 토큰을 입력한다.
4. `서버 연결 정보 복사`를 누른다.

iPhone 앱:

1. `연결` 탭을 연다.
2. `서버 릴레이`에서 붙여넣기를 누른다.
3. `서버 연결 확인`을 누른다.
4. `실행` 탭에서 원하는 동기화를 요청한다.

Windows 앱:

1. `apps/KLMSyncWindows`에서 앱을 실행한다.
2. Mac 앱에서 복사한 서버 연결 정보를 붙여넣는다.
3. `붙여넣기 읽기`, `저장`, `연결 확인`을 누른다.
4. 대시보드에서 항목을 열고 읽음/중요/숨김 같은 항목 처리를 요청한다.

Mac 앱은 켜져 있어야 하며, 서버 요청을 polling해서 한 번에 하나씩 실행한다.

Mac 앱은 상태를 올릴 때 과제, 시험, 공지, 파일 목록도 같이 `/v1/sync-data`에 올린다. iPhone 앱은 서버 연결이 설정되어 있으면 상태 화면에서 이 목록을 읽어 보여준다.

## API

모든 `/v1/*` 요청은 `Authorization: Bearer <token>` 헤더가 필요하다.

- `GET /healthz`: 서버 상태 확인. 인증 없음.
- `GET /v1/status`: 현재 sanitized 상태와 최근 요청.
- `POST /v1/status`: Mac 앱이 sanitized 상태를 게시.
- `POST /v1/commands`: iPhone 앱이 실행 요청 생성.
- `GET /v1/commands/pending`: Mac 앱이 대기 요청 조회.
- `GET /v1/commands/recent?limit=8`: 최근 요청 조회.
- `PUT /v1/commands/:id`: Mac 앱이 실행 상태 갱신.
- `POST /v1/sync-data`: Mac 앱이 sanitized 과제/시험/공지/파일 목록 게시.
- `GET /v1/sync-data?kind=exam&limit=50`: iPhone/Windows/Web 클라이언트가 목록 조회.
- `POST /v1/item-actions`: iPhone/Windows/Web 클라이언트가 항목 처리 요청 생성.
- `GET /v1/item-actions/recent?limit=10`: 최근 항목 처리 요청 조회.

`kind` 값은 현재 `assignment`, `completedAssignment`, `assignmentCandidate`, `exam`, `examCandidate`, `helpDesk`, `notice`, `file`을 쓴다.
