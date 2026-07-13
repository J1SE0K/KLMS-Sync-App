# KLMS Sync 개인용 A+ 품질 설계

## 목적

KLMS Sync를 한 명의 사용자가 Mac, iPhone, iPad, Windows에서 매일 안심하고 쓰는 개인용 멀티디바이스 작업대로 완성한다. 평균 점수나 기능 수로 결함을 가리지 않는다. 보안, 데이터 무결성, 기능, 실시간성, 접근성, 반응형 UI, 성능, 운영 복구의 모든 필수 게이트를 통과해야 A+로 판정한다.

## 제품 약속

- Mac은 Safari의 사용자 KLMS 세션을 재사용해 scraping과 Notes, Calendar, Reminders, 로컬 파일 작업을 수행하는 유일한 worker다.
- iPhone, iPad, Windows는 relay의 sanitized 상태를 읽고 실행, 중단, 항목 수정, 임시 파일 요청을 보내는 companion이다.
- Mac이 꺼져 있어도 마지막으로 확인된 서버 상태는 볼 수 있지만, 새 작업을 실제로 처리한 것처럼 표시하지 않는다.
- 불완전한 수집, 인증 실패, 네트워크 단절, 앱 종료, 중복 요청은 기존의 정상 데이터를 훼손하지 않는다.
- 현재의 Paper Graphite 디자인, 정보 구조, 전체 동기화 버튼의 섹션 소속을 유지한다.

## 범위

### 포함

- 기존 리뷰에서 확인한 P1/P2 보안, 무결성, 동시성, 실시간 상태, 접근성, 반응형 UI, 성능, 운영 문제
- Mac, iPhone, iPad, Windows의 공통 상태 의미와 플랫폼별 네이티브 상호작용
- Cloudflare Worker와 자체 호스팅 relay의 개인용 배포 안전성
- 회귀 테스트, UI 매트릭스, 성능 계측, 장애 복구 검증

### 제외

- 여러 사용자 계정, 조직, 역할, 결제, 공개 SaaS 운영
- KLMS 자동 제출, 퀴즈·시험 풀이, 사용자의 승인 없는 외부 쓰기
- 전면 시각 재설계, 새로운 전역 실행 버튼, 기존 작업 흐름과 무관한 기능

## 품질 게이트 1: 보안과 개인정보

### 전송 보안

- Windows에서 평문 HTTP/WS는 `localhost`, `127.0.0.1`, `[::1]`에만 허용한다.
- 사설 IP와 `.local`을 포함한 다른 주소는 HTTPS/WSS가 아니면 저장·연결을 거부한다.
- 자체 호스팅 다운로드 URL은 검증된 `KLMS_RELAY_PUBLIC_URL`을 우선 사용한다. public URL이 없으면 직접 연결의 실제 scheme과 host만 사용하고, 신뢰 경계가 불명확한 forwarded header는 사용하지 않는다.

### renderer 경계

- relay 응답은 renderer state에 넣기 전에 숫자, boolean, enum, UUID, 배열 길이와 문자열 길이를 검증한다.
- network/storage 값은 `innerHTML`로 렌더하지 않는다. 구조는 DOM node로 만들고 텍스트는 `textContent`로 넣는다.
- Electron 문서에 엄격한 CSP를 적용하고 inline/eval script를 허용하지 않는다.
- main process는 외부 navigation과 새 창을 기본 거부하고, `openExternal`은 HTTPS allowlist를 다시 검증한다.

### 비밀과 로그

- Cloudflare와 Tunnel env 파일은 0600, secret 디렉터리는 0700으로 생성한다.
- dependency 설치는 관리자 token을 environment에 load하기 전에 끝낸다.
- relay와 tunnel의 env 파일을 분리해 각 process에 필요한 secret만 전달한다.
- status, setting, log 저장 경계는 allowlist를 사용하고 token, cookie, 인증 번호, 홈 경로, KLMS raw URL을 저장하지 않는다.

## 품질 게이트 2: 데이터 무결성과 실행 상태

### 단일 실행 소유권

- local 실행과 remote command는 같은 run coordinator를 통해 claim한다.
- claim에 실패한 remote command는 `.running`으로 먼저 기록하지 않고 pending을 유지하거나 명시적 busy 결과로 종료한다.
- file, setting, item action 완료가 별도의 실제 실행을 `running:false`로 덮지 않는다. publish할 running 상태는 coordinator의 현재 소유권에서 계산한다.

### 취소

- 취소 intent는 Boolean 전역 값이 아니라 run identity에 귀속한다.
- relay URL/token 변경과 WebSocket session reset은 active run의 취소 intent를 지우지 않는다.
- 실행 전, 실행 중, 원격 취소가 모두 terminal `.cancelled`로 수렴한다.

### 멱등성

- command뿐 아니라 item action도 client-generated idempotency key를 받는다.
- relay는 같은 client/key의 active 또는 terminal 결과를 재사용한다.
- `fileTrash`, `calendarCreate`, setting mutation과 같은 side effect는 retry나 여러 companion의 동시 클릭에도 한 번만 실행된다.

### override

- assignment 완료 override의 canonical key는 stable URL/ID와 deadline을 사용한다.
- legacy `course::title`은 migration 입력으로만 읽고, 새 항목과 매칭하는 broad fallback으로 사용하지 않는다.

## 품질 게이트 3: WebSocket과 실시간 데이터 흐름

### 연결 상태

- socket `resume/open`은 `connecting`이다.
- protocol version과 role을 확인한 유효한 hello를 받은 뒤에만 `connected`로 표시한다.
- reconnect backoff는 유효한 hello 뒤에만 초기화한다.
- 인증 실패는 빠른 무한 재연결 대신 제한된 backoff와 사용자가 이해할 수 있는 오류 상태로 표시한다.

### 이벤트 처리

- event revision과 connection/session generation을 함께 검사해 오래된 HTTP/WS 결과가 현재 state를 되돌리지 못하게 한다.
- reason별 dirty scope를 합치고 한 batch에서 endpoint별 최신 요청 하나만 유지한다.
- Windows는 한 animation frame에 한 번만 render를 schedule하고 dirty panel만 갱신한다.
- iOS는 endpoint 결과를 한 transaction으로 적용하고 단순 timestamp publish로 전체 화면을 invalidation하지 않는다.

### 체감 목표

- 로컬 tap/클릭의 optimistic feedback: 100ms 이내
- 정상 네트워크에서 relay event가 열린 companion에 보이는 시간: p95 1초 이내
- WebSocket heartbeat 외 주기적 dashboard polling: 0
- 이벤트 한 건당 Windows full render: 0, 필요한 panel render만 1회

## 품질 게이트 4: UI와 UX

### 공통 원칙

- Paper Graphite light/dark token과 현재 radius, spacing, typography 계층을 사용한다.
- `전체 동기화`는 기존 동기화 섹션 안에 한 번만 존재한다.
- 다열 화면은 기존 배치를 유지하고, 한 열에서는 동기화 섹션 전체가 첫 번째다.
- 대기, 연결 중, 연결됨, 인증 필요, 실행 중, 취소 중, 실패, 오프라인, 미설정 상태는 문구와 색이 서로 모순되지 않는다.

### Mac

- 12pt 내부 리사이즈 hit area와 네 변·네 모서리 cursor를 유지한다.
- compact header와 첫 콘텐츠 사이의 불필요한 수직 공백을 줄인다.
- 설정은 자주 쓰는 연결·동기화 그룹을 먼저 보여주고 고급 운영 항목의 시각적 중첩을 줄인다.

### iPhone/iPad

- iPhone은 compact tab, iPad regular width는 sidebar를 사용한다.
- 방향과 size class가 바뀌어도 선택 섹션, scope, filter, active request identity를 보존한다.
- iPad는 넓은 공간을 2열 작업대로 쓰되 텍스트 줄 길이와 카드 최대 폭을 제한한다.

### Windows

- 연결 미설정 상태에서 연결됨 문구를 표시하지 않는다.
- 좁은 rail의 버튼 문구는 자연스럽게 줄바꿈하거나 짧은 label로 유지한다.
- light/dark mode를 Mac/iOS와 같은 semantic token으로 제공한다.

## 품질 게이트 5: 접근성

- 모든 작은 상태 텍스트는 WCAG AA 4.5:1 이상, 큰 텍스트는 3:1 이상을 만족한다.
- 색만으로 성공, 경고, 오류, 선택 상태를 전달하지 않는다.
- iOS interactive hit target은 최소 44×44pt다.
- iOS 핵심 navigation, sync, status 문구는 Dynamic Type semantic style을 사용하고 accessibility-extra-extra-extra-large에서도 잘리거나 겹치지 않는다.
- Mac의 UI test marker는 test launch에서만 노출하고 production VoiceOver tree에는 넣지 않는다.
- Windows의 status, alert, toast는 적절한 `role`과 `aria-live`를 사용한다.
- WebSocket render 뒤에도 keyboard focus와 selection을 stable ID로 유지한다.

## 품질 게이트 6: 성능과 레이턴시

### iOS

- 검색 입력은 debounce하고, 이전 filter/sort task를 구조적으로 취소한다.
- detached work는 cancellation을 확인하고 최신 generation만 결과를 적용한다.
- 2,000개 sync-data의 normalize, signature, sort, lookup 생성은 MainActor 밖에서 수행하고 결과 적용만 MainActor에서 한다.
- revision 변화에 대한 `.task(id:)`와 `onChange`의 중복 rebuild 경로를 하나로 합친다.
- broad `@Published` 모델은 화면별 derived state 또는 observation boundary로 분리해 관계없는 view invalidation을 줄인다.

### Windows

- WebSocket batch는 dirty state를 모은 뒤 `requestAnimationFrame` 하나로 flush한다.
- list/dashboard node는 stable key로 재사용하고 focus된 element를 교체하지 않는다.
- 최대 2,000개 항목에서 검색, filter, sort가 입력과 scrolling을 막지 않는다.

### Mac

- file watcher와 relay WebSocket은 event-driven을 유지한다.
- active run의 log/status publish는 사용자에게 필요한 빈도로 coalesce하되 취소와 인증 상태는 즉시 전달한다.

## 품질 게이트 7: relay 운영과 복구

- upload claim에서 daily count와 bytes를 원자 예약하고 실제 upload 크기로 reconcile한다.
- object key는 write 전에 claim/tombstone에 기록한다. 실패한 object는 prefix sweep과 R2 lifecycle로 정리한다.
- download는 quota 예약 뒤 streaming하고 실패 시 reservation을 보상한다.
- readiness는 D1 binding, 필수 table/column/index, realtime binding을 검사하고 실패하면 503을 반환한다.
- migration은 구 Worker와 호환되는 expand 단계, 새 Worker deploy, contract 단계로 나눈다.
- backup은 SQLite backup API와 quick check를 사용하고 다른 volume의 명시적 경로, retention, restore 검증을 지원한다.

## 오류 처리

- 수집 불완전, 인증 실패, relay 불일치, migration 실패는 성공이나 빈 상태로 축소하지 않는다.
- destructive side effect는 authoritative input과 precondition을 통과한 뒤에만 실행한다.
- optimistic state는 timeout으로 임의 성공 처리하지 않고 server-confirmed terminal state와 reconcile한다.
- 사용자가 할 수 있는 다음 행동이 있으면 오류 카드에 하나의 명확한 action을 제공한다.
- retry는 idempotency key와 exponential backoff를 사용하고 무한 tight loop를 금지한다.

## 검증 설계

### 자동 테스트

- Python, Swift, Windows unit/E2E, Cloudflare smoke/integration, 자체 호스팅 relay integration을 모두 통과한다.
- cancellation during install, connection reset, local/remote run race, malformed status XSS payload, duplicate item action, quota exhaustion before upload, orphan cleanup, readiness failure를 새 회귀 테스트로 추가한다.
- WebSocket invalid token, delayed hello, reconnect generation, out-of-order endpoint response를 테스트한다.
- iPhone/iPad orientation·size class matrix와 Windows responsive breakpoint를 테스트한다.

### 접근성·시각 검증

- Mac wide/medium/compact와 settings, iPhone portrait/landscape, iPad portrait/landscape, Windows wide/narrow의 기준 screenshot을 비교한다.
- iOS Dynamic Type 기본/AX5, light/dark, Increase Contrast를 확인한다.
- Mac VoiceOver tree와 Windows keyboard-only/ARIA live flow를 확인한다.
- 기존 승인 screenshot을 source visual truth로 사용하고 변경 후 같은 viewport·state로 비교한다.

### 성능 검증

- iOS SwiftUI View Updates, Time Profiler, Animation Hitches에서 WebSocket event당 body evaluation, main-thread time, hitch를 측정한다.
- Windows는 event당 render 횟수, 2,000개 항목 검색 input latency, focus 유지 여부를 측정한다.
- latency budget을 넘으면 평균값으로 통과시키지 않고 원인을 수정한다.

## 완료 판정

A+ 완료는 다음을 모두 만족할 때만 선언한다.

1. 미해결 P0, P1, P2가 없다.
2. 모든 자동 테스트와 UI·접근성 matrix가 통과한다.
3. 보안 공격·경쟁·실패 시나리오의 회귀 테스트가 있다.
4. 성능 budget을 실측으로 통과한다.
5. 기존 디자인 언어와 핵심 작업 흐름에 의도하지 않은 변화가 없다.
6. 실제 KLMS, Calendar, Reminders, Notes 쓰기는 사용자 승인 범위 밖에서 실행하지 않는다.
