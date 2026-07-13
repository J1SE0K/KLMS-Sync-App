# KLMS Sync 안전성·WebSocket 실시간·반응형 개선 설계

- 작성일: 2026-07-13
- 상태: 사용자 승인 완료, 구현 전 최종 문서 검토 대기
- 기준 브랜치: `main`
- 기준 커밋: `a782378`

## 1. 요약

현재 KLMS Sync의 화면 디자인, 정보 구조, 카드, 탭, 색상과 주요 조작 방식은 유지한다. 이번 작업은 다음 세 축을 한 번에 완성한다.

1. 리뷰에서 확인한 데이터 손실, relay 보안·동시성, stale state 문제를 모두 수정한다.
2. Mac, iPhone/iPad, Windows가 relay 변경을 주기적 polling 없이 WebSocket으로 즉시 반영한다.
3. 현재 화면이 실제 container 폭에 맞춰 `compact / medium / wide`로 즉시 재배치되게 한다.

대규모 도메인 재작성이나 완전한 event sourcing은 하지 않는다. 기존 구조를 유지하면서 테스트 가능한 작은 정책 경계를 추가하는 수술식 개선을 사용한다.

## 2. 목표와 완료 기준

### 2.1 안전성

- 인증은 됐지만 불완전하거나 파싱할 수 없는 KLMS 응답은 authoritative state가 될 수 없다.
- 불완전 수집에서는 이전 state, Reminders, Calendar, Notes와 파일을 그대로 보존한다.
- `--dry-run`은 Calendar, Reminders, Notes, 파일, desired hash와 persistent state를 변경하지 않는다.
- 파일 교체는 임시 파일 준비와 검증 후 원자적으로 수행한다.
- 파일 갱신 실패가 하나라도 있으면 prune을 실행하지 않고 전체 명령은 실패한다.
- core와 notice가 공유하는 공지 상태는 하나의 공통 lock 아래에서만 commit 또는 rollback한다.
- relay 입력, 파일 경로, active command, quota, object lifecycle과 backup은 서버 측 불변식으로 보호한다.

### 2.2 실시간성

- 로컬 사용자 액션은 100ms 이내 낙관적으로 화면에 반영한다.
- 정상 WebSocket 연결에서 서버 commit부터 최종 화면 render까지 보통 1초 이내, SLO는 2초 이내다.
- 서버 데이터 갱신을 위한 interval polling 또는 long-poll을 사용하지 않는다.
- 연결이 끊기면 오프라인 상태를 즉시 표시하고, 재연결 후 revision gap을 자동 복구한다.
- Mac의 로컬 runtime/state/cache 변경은 FSEvents로 감지한다.
- 대시보드, 목록, 상세, 실행 상태, 로그, 설정, 파일 요청과 변경 내역이 같은 revision 흐름으로 갱신된다.

### 2.3 반응형 화면

- wide 구간에서는 현재 화면의 정보 구조와 시각적 배치를 유지한다.
- 창 크기를 바꾸면 250ms 이내에 새 layout으로 재배치된다.
- 수평 overflow, 겹치는 요소와 viewport 밖 action button이 없어야 한다.
- resize 전후에 현재 탭, 선택 항목, 스크롤 가능한 데이터와 실행 상태를 보존한다.
- iPad Stage Manager와 Mac/Windows의 연속 window resize를 실제 container 폭으로 처리한다.

### 2.4 전체 검증

- 리뷰 finding마다 실패 재현과 수정 후 회귀 테스트가 있어야 한다.
- Python, Swift, Node relay, Cloudflare Worker, Windows Electron과 iOS simulator 검증이 모두 통과해야 한다.
- 실제 Safari, Calendar, Reminders와 Notes를 쓰는 검증은 개인정보가 없는 private Mac release gate에서 수행한다.

## 3. 범위 밖

- 현재 팔레트, 카드 스타일, 탭 이름과 정보 계층을 새로 디자인하지 않는다.
- KLMS scraping을 서버로 이전하지 않는다. Safari와 macOS 기본 앱 연동은 계속 Mac이 담당한다.
- relay에 원본 KLMS URL, 절대 로컬 경로, 인증 상태나 private 로그를 올리지 않는다.
- 전체 상태를 영구 event log로 재생하는 완전한 event-sourced architecture는 도입하지 않는다.
- 실제 사용자의 Calendar, Reminders 또는 Notes를 공개 CI에서 변경하지 않는다.

## 4. 아키텍처

기존 코드에 다음 네 경계를 추가한다.

### 4.1 `SyncSafetyGate`

KLMS 수집 결과가 side effect와 persistent state에 도달하기 전에 완전성, 로그인 상태와 parse 결과를 검증한다. 검증된 staged state만 commit할 수 있다.

책임:

- 요청 URL과 실제 수집 URL의 coverage 확인
- 모든 destructive input group의 `requireAll` 확인
- login page, 빈 HTML과 parser error 차단
- dry-run side effect 차단
- 파일 원자 교체 결과와 prune 허용 여부 결정
- 이전 정상 state 보존

### 4.2 `RelayIntegrity`

Node relay와 Cloudflare Worker가 동일한 서버 측 불변식을 적용한다.

책임:

- command/action/status/UUID/date/string 길이 schema 검증
- 서버 소유 필드 보호
- local file object path containment
- active command 단일성
- 원자적 quota 예약
- object 생성·교체·만료 삭제 보상 처리
- WAL-safe backup
- commit 이후 revision 발행

### 4.3 `LiveStateCoordinator`

Mac, iOS와 Windows는 각 UI 프레임워크에 맞는 coordinator를 두되 같은 상태 전이 규약을 사용한다. 대형 View와 기존 모델을 교체하지 않고, relay session과 render 경계를 coordinator로 모은다.

책임:

- WebSocket lifecycle과 connection generation
- event revision 순서 검증과 gap 복구
- dirty scope 및 event burst 병합
- snapshot과 delta의 원자적 적용
- 낙관적 local action과 실패 rollback
- 연결 변경 시 remote-owned state 전체 초기화
- 한 revision당 한 번의 화면 render

테스트 가능한 순수 정책은 Swift Shared와 독립 JavaScript module로 추출한다.

- `RemoteCommandCompletionStatus`
- `RelaySessionState.reset()`
- `RelayEventApplyDecision`
- `RelayDirtyScopeAccumulator`
- `AdaptiveLayoutPolicy`

### 4.4 `AdaptiveLayoutPolicy`

size class나 최초 window 크기가 아니라 현재 container width를 입력으로 받아 layout mode를 반환한다.

```text
compact: width < 720
medium:  720 <= width < 1040
wide:    width >= 1040
```

Swift point와 CSS pixel의 의미는 플랫폼별로 다르지만 mode 경계와 전환 동작은 동일하게 유지한다. Mac과 Windows shell의 최소 지원 폭은 640으로 둔다.

## 5. 코어 동기화 안전 설계

### 5.1 수집 completeness와 dashboard parse

`src/js/sync_klms_notes.js`에서 state 생성에 사용하는 dashboard, course, all-week, detail과 supplemental fetch에 다음 조건을 적용한다.

- 요청 URL 전체가 결과의 `requestedUrl` 집합에 존재해야 한다.
- 각 input group은 login page가 없어야 한다.
- 재사용 cache도 같은 coverage 검사를 통과해야 한다.
- state에 영향을 주는 fetch는 `requireAll: true`여야 한다.

`src/python/klms_sync_v2/cli.py`는 dashboard 파일 없음, 빈 HTML, 로그인 페이지와 `parse_dashboard_page().status != "ok"`를 빈 성공 state로 바꾸지 않는다. error status를 출력하고 이전 state 파일을 유지한다.

검증에 실패하면 Calendar/Reminders bridge, state commit과 desired hash write를 호출하지 않는다.

### 5.2 진짜 dry-run

Calendar sync 조건에 명시적으로 `!dryRun`을 적용한다. dry-run에서는 다음을 모두 금지한다.

- EventKit 실행
- Reminders/Notes 실행
- persistent state 이동
- Calendar/Reminders desired hash write
- 파일 다운로드·교체·prune

dry-run report는 실제로 건너뛴 side effect만 기록한다.

### 5.3 파일 원자 교체와 실패 전파

기존 destination을 먼저 지우지 않는다.

1. destination과 같은 filesystem의 sibling temporary path에 복사한다.
2. 크기와 필요한 metadata를 검증한다.
3. atomic replace 또는 rename을 실행한다.
4. 실패하면 temporary file만 정리하고 기존 destination을 유지한다.

tracked destination, new-files inbox와 archive 등 기존 파일을 덮는 모든 경로가 같은 helper를 사용한다.

download 결과에 `failed` 또는 `quarantined`가 하나라도 있으면 두 prune 단계 전에 non-zero로 종료한다. 다른 파일의 시도는 계속할 수 있지만 전체 실행을 성공으로 기록하지 않는다.

### 5.4 core/notice 공유 lock

runtime namespace와 작업 cache는 계속 `core`, `notice`로 분리한다. lock 이름만 두 entrypoint에서 `core-notice`로 공유한다. `files`와 `all`까지 하나의 전역 lock으로 합치지 않아 부모-자식 재진입 deadlock을 피한다.

### 5.5 Reminder 완료 override

새 완료 override는 다음 strong key만 저장하고 조회한다.

- assignment URL
- `URL::title`
- `course::title::due`

`course::title` fallback은 writer와 matcher에서 제거한다. 기존 broad key는 inert 상태로 남기며 자동으로 미래 동명 과제를 완료 처리하지 않는다.

## 6. Relay 무결성 설계

### 6.1 입력 schema와 서버 소유 필드

Node와 Cloudflare 구현에 같은 allowlist를 적용한다.

- client POST에서 ID, status, createdAt, updatedAt은 서버가 생성하거나 강제한다.
- command kind, item/setting action kind와 status는 enum allowlist를 통과해야 한다.
- UUID, ISO date, 문자열 길이와 option type을 검증한다.
- worker PUT은 endpoint별 허용 필드만 patch한다.
- command ID/kind/createdAt/options와 file objectKey/ticket/expiry/size/downloadCount는 body로 덮어쓸 수 없다.

Swift inbox decode는 legacy invalid row 하나 때문에 배열 전체가 실패하지 않도록 element별 lossy decode를 사용한다. 서버는 새 invalid row를 거부하고, client는 기존 오염 row를 격리한다.

### 6.2 Node 파일 경로 격리

서버 생성 object key는 고정된 strict pattern을 사용한다. 파일 접근 전에 `path.resolve(FILE_DIR, key)`를 계산하고 결과가 정확히 `FILE_DIR + path.sep` 아래인지 확인한다. `..`, absolute path, 빈 segment와 허용하지 않은 문자를 거부한다.

### 6.3 active command 단일성

D1 migration과 Node SQLite schema에 `pending/running` command가 한 개만 존재하도록 partial unique invariant를 추가한다. check-then-insert만 신뢰하지 않는다. constraint 충돌은 `409`로 반환한다.

### 6.4 원자적 quota

날짜별 quota table을 사용한다.

- upload count/bytes는 conditional update로 먼저 예약한다.
- download daily quota와 per-link count를 모두 원자적으로 예약한 후에만 object를 제공한다.
- 두 번째 예약 실패 시 첫 번째 예약을 반환한다.
- 저장 실패 후 예약 반환에도 실패하면 fail-closed quota 누수로 남기며 한도 초과를 허용하지 않는다.

### 6.5 object lifecycle

- 이미 object가 있는 완료 요청은 재upload로 덮어쓰지 않는다.
- object write 후 DB update가 실패하면 새 object를 보상 삭제한다.
- 만료 cleanup은 object 삭제 성공 또는 `ENOENT`인 row만 제거한다.
- object 삭제 실패 row는 남겨 다음 cleanup에서 다시 시도한다.

### 6.6 WAL-safe backup

raw `cp`를 제거하고 Node 22 `node:sqlite` backup API를 호출하는 helper를 사용한다. backup은 `quick_check`, schema와 마지막 committed revision을 검증한 뒤 성공으로 보고한다.

## 7. WebSocket 실시간 설계

### 7.1 원칙

- 서버 데이터 변경에는 scheduled polling과 long-poll을 사용하지 않는다.
- Cloudflare는 기존 Durable Object WebSocket room을 확장한다.
- 자체 호스팅 Node relay에도 동일한 WebSocket endpoint를 추가한다.
- DB transaction이 성공한 뒤에만 event를 broadcast한다.
- WebSocket ping/pong은 연결 생존과 revision 확인용이며 데이터 polling이 아니다.
- 초기 bootstrap, revision gap recovery와 파일 전송에만 one-shot HTTP를 사용한다.

### 7.2 event envelope

```json
{
  "version": 1,
  "type": "changed",
  "revision": 42,
  "eventID": "server-generated-uuid",
  "reason": "sync-data",
  "scopes": ["status", "syncData", "runLogs"],
  "delta": {},
  "requiresSnapshot": false,
  "sentAt": "2026-07-13T12:00:00Z"
}
```

- `revision`은 relay 내에서 단조 증가한다.
- mutation과 새 revision 할당은 같은 SQLite transaction 또는 D1 atomic batch에서 commit되어 중복되거나 뒤로 가는 revision이 생기지 않게 한다.
- 작은 sanitized 변경은 `delta`로 직접 보낸다.
- 큰 sync snapshot은 `requiresSnapshot=true`로 알리고 client가 즉시 해당 snapshot을 한 번 가져온다.
- private URL, local path, 원본 로그와 인증 정보는 delta에 포함하지 않는다.

### 7.3 연결과 gap 복구

1. client는 WebSocket을 먼저 열고 수신 event를 임시 buffer에 담는다.
2. server `hello`는 현재 revision을 전달한다.
3. client는 bootstrap snapshot과 해당 snapshot revision을 한 번 읽는다.
4. snapshot을 원자 적용한 뒤 그보다 큰 buffered event를 순서대로 적용한다.
5. revision이 하나 이상 건너뛰면 현재 화면에 stale 상태를 표시하고 최신 snapshot을 한 번 reconcile한다.

재연결은 jitter가 있는 `250ms → 500ms → 1s → 2s` backoff를 사용한다. 연결이 끊긴 동안은 온라인처럼 표시하지 않는다. 재연결 성공 시 동일한 bootstrap/gap 절차를 수행한다.

broadcast가 누락된 예외 경로는 WebSocket heartbeat의 current revision 비교로 감지한다. 이는 HTTP polling이 아니며, gap이 있을 때만 one-shot snapshot recovery를 실행한다.

### 7.4 event 적용

각 client는 다음 값을 가진다.

- `connectionGeneration`
- `lastAppliedRevision`
- `bufferedEvents`
- `dirtyScopes`
- `renderScheduled`

규칙:

- 이미 적용한 revision은 무시한다.
- connection generation이 다른 async 응답은 폐기한다.
- busy 중 event를 버리지 않고 revision 순서로 buffer한다.
- 50~150ms 안에 몰린 compatible scope는 합친다.
- 한 batch를 state에 원자 적용하고 render를 한 번만 실행한다.
- local action은 즉시 낙관적으로 반영하고 server reject 시 rollback과 오류를 표시한다.

### 7.5 플랫폼 적용

Mac:

- 기존 WebSocket path를 coordinator로 통합한다.
- server fallback polling과 idle local polling을 제거한다.
- local runtime/state/cache는 FSEvents + 150ms debounce로 다시 읽는다.
- watcher start와 app activation 시 현재 snapshot을 한 번 bootstrap한다.

iOS/iPadOS:

- WebSocket 연결·재연결 직후 bootstrap/gap reconciliation을 실행한다.
- 빈 command/log 배열도 authoritative하게 적용해 stale row를 제거한다.
- foreground 전환은 connection 상태 확인과 필요 시 reconnect만 수행한다.

Windows:

- 25초 long-poll을 제거하고 persistent WebSocket을 사용한다.
- `state.busy`여도 event를 consume한 뒤 버리지 않고 dirty queue에 저장한다.
- optimistic action 직후 즉시 render한다.

## 8. Remote 상태 초기화와 취소

relay URL 또는 token이 바뀌거나 연결 정보가 지워지면 다음 remote-owned state를 한 transaction처럼 초기화한다.

- status, latest command와 running flag
- dashboard/sync items, calendar, verify summary
- commands, item/setting actions와 request/file access logs
- shared settings와 run logs
- pending cancel, timestamps, revision/cursor와 selection
- in-flight refresh/reconnect task와 derived presentation cache

초기화 전에 connection generation을 증가시켜 이전 relay 응답이 다시 화면을 채우지 못하게 한다.

remote command 최종 상태는 `wasCancelled`를 먼저 검사한다.

```text
wasCancelled → cancelled
else succeeded → completed
else → failed
```

## 9. 반응형 화면 설계

### 9.1 공통 규칙

- wide에서는 현재 디자인과 정보 구조를 유지한다.
- mode 변경은 container width가 threshold를 넘는 즉시 발생한다.
- layout mode는 presentation만 바꾸고 model selection을 새로 만들지 않는다.
- control은 잘리기보다 줄바꿈 또는 stacked fallback을 사용한다.

### 9.2 Mac

- wide: 기존 264pt sidebar와 현재 dashboard/detail 구조 유지
- medium: 64pt icon rail, dashboard command/detail column을 본문 아래로 이동
- compact: sidebar를 toolbar menu로 전환하고 한 열 flow 사용
- window 최소 폭을 640으로 낮추고 fixed child width를 adaptive grid 또는 `ViewThatFits`로 교체

### 9.3 iPhone/iPad

- root가 계산한 `AdaptiveLayoutMode`를 하위 화면에 전달한다.
- `horizontalSizeClass`만으로 2열 layout을 선택하지 않는다.
- 모든 `ViewThatFits`의 마지막 후보는 vertical stack이다.
- split과 tab root가 같은 section/selection binding을 사용해 1040 경계 통과 시 화면이 초기화되지 않게 한다.

### 9.4 Windows

- BrowserWindow와 body의 920/980px hard minimum을 제거하고 최소 지원 폭을 640으로 둔다.
- wide: 기존 320px sidebar 유지
- medium: icon rail과 축소된 grid
- compact: drawer menu, 한 열 workspace, toolbar/action wrap
- CSS media/container query가 resize를 즉시 반영하며 JavaScript resize polling은 사용하지 않는다.

## 10. 오류 처리

- 안전성 gate 실패는 기존 state를 보존하고 명확한 incomplete/error reason을 기록한다.
- dry-run report와 실제 side effect 여부가 다르면 테스트 실패다.
- 파일 교체·quota·object cleanup은 부분 성공을 숨기지 않는다.
- validation failure에는 DB write와 event broadcast가 없어야 한다.
- WebSocket 연결 실패는 online 상태로 위장하지 않는다.
- invalid event나 revision gap은 해당 event를 버리고 snapshot reconciliation으로 전환한다.
- optimistic action rollback 실패는 전체 snapshot을 다시 적용하고 사용자에게 오류를 남긴다.
- 연결 초기화 중 이전 generation의 응답은 조용히 폐기한다.

## 11. 테스트 설계

### 11.1 finding 회귀 테스트

| Finding | 필수 검증 |
| --- | --- |
| 불완전 KLMS 응답 | 이전 state byte 보존, bridge 호출 0회, non-zero |
| dry-run Calendar 변경 | EventKit/Reminders/Notes/file/hash write 0회 |
| 파일 교체 실패 | 기존 파일 내용 보존, temp 정리, prune 0회, non-zero |
| core/notice lock 경쟁 | 작업 cache는 분리, lock은 동일, 최신 notice state 보존 |
| relay path 이탈 | 외부 sentinel read/delete 거부 |
| 동명 Reminder override | 다른 URL/마감의 미래 과제는 open 유지 |
| malformed inbox | 서버 400, mixed legacy array의 valid row는 처리 |
| concurrent active command | 병렬 요청 중 201 한 개, 나머지 409 |
| quota race/orphan | 정확한 성공 수, 삭제 실패 row 보존과 재시도 |
| cancelled → failed | publish/history/status 모두 cancelled |
| 연결 해제 stale state | 모든 remote-owned state와 derived cache 초기화 |
| WAL backup | live WAL commit 포함, `quick_check` 통과 |
| 깨진 문구 테스트 | 실제 `캘린더` 문구와 expectation 일치 |

### 11.2 WebSocket 실시간 테스트

fake relay가 다음 transition을 WebSocket으로 순차 발행한다.

- `idle → running → completed`
- `running → cancelled`
- dashboard count `0 → 1 → 2 → 1`
- item/log/setting/file request 추가, 수정과 삭제
- busy 중 event, 100개 burst와 out-of-order revision
- socket 강제 종료, offline 표시, reconnect와 gap recovery
- empty authoritative list가 stale UI를 제거하는 경우

각 플랫폼에서 수동 refresh 없이 연결된 상태의 최종 render가 2초 안에 완료돼야 한다. interval polling과 long-poll 호출이 없음을 fake server request log로 확인한다.

### 11.3 반응형 테스트

각 breakpoint의 `-1`, 정확한 값, `+1`과 최소·기본·최대 크기를 연속 resize한다.

- Mac accessibility smoke를 window-size matrix로 확장
- iPhone portrait/landscape와 iPad portrait/landscape/Stage Manager width matrix
- Windows Playwright/Electron에서 `scrollWidth <= innerWidth`, element rect와 grid column 검사
- 모든 환경에서 탭, selection, scroll data와 running state 보존

### 11.4 전체 gate

필수 로컬/CI gate:

- Python unittest 전체
- shell `zsh -n` 전체
- JS/MJS/CJS `node --check` 전체
- SwiftPM 전체
- Cloudflare Worker unit/integration과 실제 local D1 concurrency
- Node relay HTTP/WebSocket/path/quota/backup integration
- Windows reducer/DOM/Electron responsive WebSocket E2E
- iPhone/iPad simulator UI matrix

private release gate:

- Mac AX window matrix와 live transition
- 테스트 전용 Calendar/Reminders/Notes 대상 또는 cleanup 가능한 fixture
- 로그인된 Safari/KLMS session readiness
- 실제 iPhone/iPad 연결이 있을 때 device smoke

## 12. CI 설계

`.github/workflows/ci.yml`:

- `core-macos`: Python, shell/JS syntax, Swift
- `relay-linux`: Worker, local D1, Node relay integration와 backup
- `windows-ui`: Windows unit/DOM/Electron responsive WebSocket E2E
- `ios-simulator`: iPhone/iPad layout와 live transition matrix

`.github/workflows/ui-readiness.yml`:

- nightly 또는 release trigger
- GUI session과 접근성 권한이 있는 private/self-hosted Mac
- 실제 Apple app integration과 sanitized readiness artifact

실제 계정, course data, cookie, local path와 원본 로그는 CI artifact에 포함하지 않는다.

## 13. 구현 순서

1. 현재 빨간 문구 테스트를 바로잡고 baseline green 확보
2. completeness, dry-run, 파일 원자 교체, core/notice lock과 Reminder override
3. relay validation/path/active-command/quota/object cleanup/backup
4. cancellation, lossy legacy decode와 remote session reset/generation
5. WebSocket event envelope, revision, Node WebSocket, 세 client coordinator
6. FSEvents local refresh와 scheduled data polling 제거
7. 기존 UI를 유지한 adaptive layout 적용
8. 전체 unit/integration/UI E2E와 CI 구성
9. private readiness gate 실행과 회귀 수정

각 단계는 관련 테스트를 먼저 또는 동시에 추가하고 전체 gate를 green으로 유지한다.

## 14. 완료 정의

다음 조건을 모두 만족해야 작업을 완료로 본다.

- P1/P2 finding 13개가 코드와 회귀 테스트로 해결됨
- 정상 연결에서 모든 server-owned UI data가 WebSocket으로 2초 이내 반영됨
- interval polling과 long-poll이 server data refresh 경로에 남아 있지 않음
- local Mac data가 FSEvents로 반영됨
- compact/medium/wide resize matrix 통과
- 모든 플랫폼에서 연결 변경 후 이전 relay data가 남지 않음
- Python, Swift, relay, Worker, Windows와 iOS simulator gate 통과
- private Mac readiness gate가 통과함. 필요한 GUI 권한·로그인 session·기기가 없어 실행하지 못한 항목이 있으면 구현은 code-complete로만 보고하고, 전체 live 검증 완료를 주장하지 않으며 blocker를 별도로 기록함
- 사용자의 기존 wide 화면 디자인과 주요 작업 흐름이 유지됨
