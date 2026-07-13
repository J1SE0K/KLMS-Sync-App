# KLMS Sync 개인용 A+ 구현 계획

설계 기준: `docs/superpowers/specs/2026-07-14-klms-sync-personal-a-plus-quality-design.md`

## 작업 원칙

- 기존 dirty worktree를 보존하고 관련 파일만 최소 diff로 수정한다.
- 실제 KLMS, Notes, Calendar, Reminders 쓰기는 실행하지 않는다.
- 보안·무결성 수정은 먼저 회귀 테스트를 추가하고 targeted test를 통과시킨다.
- 플랫폼별 작업은 파일 소유권을 분리해 병렬 수행한다.
- 각 단계가 끝날 때 전체 회귀 테스트를 다시 실행한다.

## 1. Windows 안전성과 실시간 렌더

소유 파일:

- `apps/KLMSyncWindows/src/relay-security.cjs`
- `apps/KLMSyncWindows/src/main.cjs`
- `apps/KLMSyncWindows/src/preload.cjs`
- `apps/KLMSyncWindows/src/index.html`
- `apps/KLMSyncWindows/src/renderer.js`
- `apps/KLMSyncWindows/src/styles.css`
- `apps/KLMSyncWindows/test/*`

작업:

1. HTTP를 exact loopback에만 허용하고 private/.local remote는 HTTPS로 제한한다.
2. relay status schema를 normalize하고 network 값을 HTML sink로 보내지 않는다.
3. CSP, navigation, window-open, external URL allowlist를 적용한다.
4. 연결 미설정/연결 중/연결됨 문구를 실제 socket state에서 계산한다.
5. WebSocket endpoint 적용을 한 frame에 batch하고 dirty panel만 render한다.
6. keyed DOM update 또는 stable focus restore로 keyboard focus를 보존한다.
7. status/banner/toast ARIA live와 form label을 보강한다.
8. semantic dark theme와 고대비 상태 foreground token을 추가한다.
9. wide/1040/1039/640px의 동기화 섹션 순서와 줄바꿈을 검증한다.

검증:

- `npm run check`
- `npm test`
- Windows realtime E2E
- malformed status XSS, unconfigured title, focus-after-event, private HTTP 거부 테스트

## 2. Relay 보안·무결성·운영

소유 파일:

- `deploy/cloudflare-worker/src/worker.mjs`
- `deploy/cloudflare-worker/migrations/*`
- `deploy/cloudflare-worker/setup_cloudflare_relay.sh`
- `deploy/cloudflare-worker/test/*`
- `tools/klms_relay_server.mjs`
- `deploy/relay/*`
- 관련 문서

작업:

1. 검증된 public URL 기반 HTTPS download URL을 생성한다.
2. Cloudflare upload claim 시 daily count/bytes를 원자 예약하고 reconcile한다.
3. item action idempotency key와 atomic get-or-create를 Cloudflare/self-host에 추가한다.
4. object write 전 claim/tombstone을 기록하고 orphan sweep/lifecycle 백스톱을 둔다.
5. self-host download를 quota 예약 뒤 streaming한다.
6. readiness에서 D1 schema, realtime binding을 검사하고 실패 시 503을 반환한다.
7. migration을 expand/deploy/contract 호환 순서로 문서화하고 테스트한다.
8. admin/tunnel env를 0600으로 만들고 dependency install 전에 token load를 금지한다.
9. relay/tunnel secret을 분리하고 Compose `--env-file` 경로를 바로잡는다.
10. backup destination, retention, permission, restore verification을 추가한다.
11. server storage sanitizer를 status/settings/log allowlist로 바꾼다.

검증:

- Cloudflare smoke/local D1 integration
- 자체 호스팅 relay integration
- quota exhaustion before PUT, duplicate item action, orphan cleanup, readiness failure, HTTPS ticket 테스트

## 3. Mac 실행 무결성

소유 파일:

- `apps/KLMSync/Sources/KLMSMac/KLMSMacModel.swift`
- `apps/KLMSync/Sources/KLMSShared/DashboardDataModels.swift`
- `apps/KLMSync/Sources/KLMSShared/StateModels.swift`
- `apps/KLMSync/Sources/KLMSShared/LiveStatePolicies.swift`
- 관련 Swift tests

작업:

1. pre-launch cancellation을 run identity에 귀속하고 relay reset과 분리한다.
2. local/remote command claim을 단일 coordinator policy로 직렬화한다.
3. remote command를 `.running`으로 바꾸기 전에 claim을 확정한다.
4. file/settings/item 완료 status가 실제 active run을 idle로 덮지 않게 한다.
5. Mac WebSocket은 유효한 hello 뒤 connected/backoff reset을 수행한다.
6. Swift legacy `course::title` broad override 적용을 제거하고 migration만 지원한다.

검증:

- connection-reset-during-cancel
- local-run-starts-during-inbox-await
- worker-side-action-during-local-run
- invalid-token/delayed-hello
- same-title-different-deadline assignment
- Swift package 전체 테스트

## 4. iPhone/iPad 실시간성·접근성·성능

소유 파일:

- `apps/KLMSync/Sources/KLMSiOS/KLMSiOSApp.swift`
- iOS 관련 shared tests와 XCUITests

작업:

1. 유효한 WebSocket hello 뒤 connected/backoff reset을 수행한다.
2. 검색 debounce와 structured cancellation을 추가하고 detached stale result를 차단한다.
3. revision 변화의 중복 list rebuild 경로를 하나로 합친다.
4. sync-data normalize/signature/sort/lookup을 MainActor 밖에서 계산한다.
5. endpoint apply와 observation boundary를 좁혀 관계없는 body invalidation을 줄인다.
6. 30–34pt icon control을 최소 44pt로 확대한다.
7. 고정 9–12pt 핵심 문구를 semantic Dynamic Type style로 바꾼다.
8. status foreground 대비를 AA 이상으로 분리한다.
9. iPhone/iPad 방향·size class 전환에서 선택과 request identity를 보존한다.

검증:

- Swift package tests
- iPhone/iPad adaptive XCUITest matrix
- Dynamic Type AX5/light/dark/Increase Contrast screenshot
- SwiftUI View Updates, Time Profiler, Animation Hitches
- 2,000개 fixture 검색과 WebSocket burst 계측

## 5. Mac UI/UX·접근성

소유 파일:

- `apps/KLMSync/Sources/KLMSMac/MenuBarRootView.swift`
- `apps/KLMSync/Sources/KLMSMac/SettingsView.swift`
- Mac UI/accessibility smoke tools와 tests

작업:

1. production VoiceOver tree에서 1×1 test marker를 제거하거나 test launch로 gate한다.
2. compact header와 첫 콘텐츠 사이의 수직 공백을 줄인다.
3. 설정의 중첩 surface를 줄이고 핵심/고급 계층을 분명히 한다.
4. warning/success/error status foreground 대비를 AA 이상으로 조정한다.
5. 기존 12pt resize hit area와 동기화 섹션 순서를 유지한다.

검증:

- Mac wide/medium/compact screenshot
- VoiceOver accessibility tree
- resize smoke
- workspace navigation smoke

## 6. 전체 품질 게이트

1. Python 282+ tests, Swift 220+ tests, Windows unit/E2E, relay integrations를 모두 통과한다.
2. `git diff --check`, shell syntax, Node syntax, Xcode build를 통과한다.
3. 기존 승인 screenshot과 변경 후 동일 viewport/state를 비교한다.
4. P0/P1/P2 재리뷰에서 actionable finding이 없어야 한다.
5. 실제 사용자 데이터 mutation 없이 검증했음을 기록한다.
