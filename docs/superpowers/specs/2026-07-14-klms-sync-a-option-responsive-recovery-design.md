# KLMS Sync A안 반응형 복구와 100점 검증 설계

- 작성일: 2026-07-14
- 상태: 사용자 A안 승인 완료
- 시각 기준: 현재 Paper Graphite UI와 기존 동기화 섹션 배치
- 안전 경계: 실제 KLMS, Notes, Calendar, Reminders 데이터는 검증 중 변경하지 않음

## 1. 문제와 목표

현재 Mac의 공지, 과제, 파일, 캘린더 화면은 창 전체 폭으로 레이아웃 모드를 고른 뒤 사이드바만큼 본문을 오른쪽으로 미는 구조다. 1039pt에서 1040pt로 창이 1pt 넓어질 때 실제 본문은 약 199pt 좁아지는 비단조 구간이 생기며, 세로 `ScrollView`의 자식도 정확한 가로 폭을 제안받지 못한다. 실제 데이터가 없는 과제 화면도 오른쪽이 잘리므로 데이터 양이 아니라 shell과 가로 제약의 구조적 결함이다.

iPad도 1040pt wide 전환 시 실제 본문이 약 771pt인데 2열 최소 폭은 778pt라 Stage Manager와 분할 화면 경계에서 같은 문제가 생긴다. Windows는 긴 서버 문자열, 확대, 강제 색상에서 내부 요소 containment가 아직 증명되지 않았다.

목표는 A안, 즉 **실제 navigation 열과 정확한 workspace 열을 분리하는 구조**로 세 플랫폼을 고치고, 화면 안의 의미 있는 모든 후손이 가로 경계를 1px/pt라도 벗어나면 실패하도록 검증하는 것이다. 시각 언어와 기능 위치는 유지한다.

## 2. 승인된 A안

### 2.1 Mac shell

- `ZStack + workspace leading padding`을 실제 두 열 `HStack`으로 바꾼다.
- navigation 폭은 wide 264pt, medium 64pt, compact 0pt다.
- workspace는 `windowWidth - navigationWidth`의 정확한 유한 폭을 받는다.
- content layout mode는 창 전체가 아니라 workspace의 실제 content 폭으로 계산한다.
- navigation 전환 breakpoint와 workspace 내부 카드 reflow breakpoint를 분리한다.
- 세로 스크롤 문서에는 viewport의 정확한 폭을 제안한다. `.clipped()`는 결함을 숨기는 수단이 아니라 마지막 안전 가드로만 둔다.

### 2.2 Mac workspace

- 대시보드 wide 배치와 동기화 섹션 소속을 그대로 유지한다.
- 한 열이 되면 버튼 하나가 아니라 동기화 섹션 전체가 첫 번째다.
- 검색, filter, segmented category, 정렬, badge, action bar는 실제 content 폭에 따라 2행 또는 세로 fallback을 선택한다.
- 공지, 과제, 파일, 캘린더, 로그, 진단, 설정의 긴 제목과 경로는 부모 폭을 키우지 않고 줄바꿈 또는 중간 생략한다.
- 가로 스크롤은 추가하지 않는다.

### 2.3 iPhone과 iPad

- sidebar를 뺀 실제 workspace 폭으로 각 2열 화면을 판정한다.
- 파일/공지, 과제, 캘린더는 `ViewThatFits(in: .horizontal)` 또는 동등한 명시적 정책으로 2열이 들어갈 때만 나란히 놓고, 부족하면 목록 다음 상세의 세로 구조로 전환한다.
- 방향 전환, Split View, Stage Manager에서 선택 항목과 요청 identity를 보존한다.
- 핵심 navigation, 동기화, 상태 문구는 semantic Dynamic Type을 사용하고 AX5에서는 버튼과 action group이 세로 fallback을 선택한다.
- compact에서도 주요 기능에 직접 도달할 수 있게 하되, 현재 탭 스타일과 정보 계층을 유지한다.

### 2.4 Windows

- 서버 유래 제목, URL, 파일명, 메타데이터와 history에 `min-width: 0`과 안전한 임의 지점 줄바꿈을 적용한다.
- 좁은 화면에서 항목 선택 시 아래 상세가 실제 viewport에 나타나도록 focus/scroll을 보존한다.
- 선택 상태는 forced-colors에서도 `Highlight`/`HighlightText`로 구분한다.
- 텍스트 기호 아이콘은 프로젝트에 포함한 검증된 실제 icon asset/library로 교체한다.
- 100%뿐 아니라 125, 150, 200, 400% 확대에서도 모든 기능과 focus 순서를 유지한다.

## 3. 실시간 상태와 기능 계약

- WebSocket의 유효한 hello 이후에만 연결됨으로 표시한다.
- dashboard, 목록, 상세, 로그, 설정, 파일 요청과 실행 상태는 같은 revision/generation 규약으로 반영한다.
- relay 데이터 갱신용 주기적 polling은 0회다. bootstrap, revision gap 복구, 파일 전송만 one-shot HTTP를 허용한다.
- 로컬 입력은 100ms 안에 feedback을 보이고, 정상 로컬/개인 네트워크의 server commit → 열린 companion render p95는 1초 이하다.
- stale HTTP/WS 결과는 현재 session을 되돌리지 못한다.
- resize나 size-class 변경은 WebSocket session, 선택, filter, 실행 identity를 초기화하지 않는다.

## 4. 결정론적 100점 채점표

각 항목은 연결된 증거가 모두 통과하면 배점 전부, 일부만 통과하면 명시된 하위 항목 점수만, 미실행·판정 불가·실패는 0점이다. 정성적 반올림이나 체감 가산점은 없다.

| 영역 | 배점 | 필수 증거 |
| --- | ---: | --- |
| 기능·데이터 무결성 | 20 | core/notice/files, dry-run, cancellation, idempotency, override, 모든 화면 action의 unit/integration 회귀 |
| 반응형 UI·시각 완성도 | 20 | Mac/iOS/Windows 전체 화면·상태 matrix, 모든 의미 있는 후손 containment, 동일 viewport 전후 비교 |
| UX·접근성 | 15 | keyboard/focus, 의미 있는 label·live region, hit target, Dynamic Type AX5, contrast/forced-colors |
| WebSocket·레이턴시·성능 | 15 | polling 0, revision/generation 테스트, p95 latency, render count, ETTrace/SwiftUI 및 Windows 2,000개 fixture |
| 보안·개인정보 | 15 | 입력 schema, XSS/CSP/navigation, transport, path containment, secret/log redaction, dependency/security 검사 |
| 신뢰성·운영 복구 | 10 | atomic quota/object lifecycle, readiness/migration, SQLite backup·restore, 장애·재연결 회귀 |
| 테스트·릴리스 증거 | 5 | 전체 suite, build/package/install, diff/syntax 검사, evidence index와 미해결 finding 0 |
| **합계** | **100** | 모든 필수 gate 통과 |

### 4.1 결함 cap

평균 점수가 심각한 결함을 가리지 못하게 최종 점수에 다음 cap을 적용한다.

- 미해결 P0 하나 이상: 최대 39점
- 미해결 P1 하나 이상: 최대 79점
- 미해결 P2 하나 이상: 최대 89점
- 필수 matrix 또는 성능·보안 증거 미실행: 최대 94점
- 실제 사용자 외부 데이터 mutation이 필요한 검사는 별도 private release gate로 표시하며 자동으로 실행하지 않는다.

따라서 현재 확인된 Mac/iPad 구조적 overflow P1이 남아 있는 동안 전체 점수는 어떤 부분 점수 합계와 무관하게 79점을 넘을 수 없다. 최종 100점은 모든 P0/P1/P2가 닫히고 모든 비파괴 필수 증거가 생성된 경우에만 선언한다.

## 5. 필수 검증 matrix

### 5.1 Mac

- 모든 8개 workspace: 640, 719, 720, 900, 1039, 1040, 1080, 1200, 1400pt
- 설정의 모든 탭: 640, 900, 1200pt
- 640...1400pt 정수 폭에서 workspace 폭이 비단조 감소하지 않음. 1039→1040 전환을 별도 고정 회귀로 둠
- 기본/긴 데이터/빈 데이터/오류/실행 중/확장 action 상태
- `workspace-content-root-*`의 의미 있는 모든 보이는 접근성 후손이 viewport `minX/maxX ±1pt` 안에 있음

### 5.2 iPhone/iPad

- 폭: 320, 375, 390, 430, 719, 720, 834, 1024, 1039, 1040, 1047, 1048, 1366pt
- iPhone 양 방향, iPad 양 방향, Split View/Stage Manager에 대응하는 window size
- Dynamic Type 기본, XL, AX3, AX5; light/dark; Increase Contrast
- dashboard와 파일, 공지, 과제, 시험, 헬프데스크, 캘린더, 로그, 설정 전체
- interactive hit target 최소 44×44pt와 보이는 후손 frame containment

### 5.3 Windows

- 폭 640, 719, 720, 1039, 1040, 1180, 1440px; 높이 680, 768, 1080px
- zoom 100, 125, 150, 200, 400%; light/dark; forced-colors; reduced-motion
- 전체 category/action/drawer/log/history와 키보드 전용 흐름
- 2,000자 공백 없는 Latin, Hangul, URL, underscore fixture
- document와 모든 의미 있는 보이는 후손 containment, stable focus, screenshot regression

## 6. 리뷰 도구와 증거

- Product Design audit: 실제 설치 앱의 동일 viewport 전후 screenshot을 나란히 비교하고 시각 결함을 판정
- Computer Use: 실제 Mac 앱의 현재 데이터와 조작 흐름을 비파괴 방식으로 확인
- SwiftUI UI patterns/refactor/performance audit: layout proposal, Observation, identity, body 비용을 코드와 trace로 판정
- iOS debugger: Simulator build/install/launch, XCUITest, screenshot, log를 확인
- iOS simulator browser: 명시한 Simulator frame을 브라우저에서 실제 렌더 증거로 확인
- ETTrace: 한 번에 하나의 고정 flow를 symbolicated trace로 측정
- memgraph/leaks: 동일 flow 종료 뒤 app-owned leak과 ownership path를 검사
- Playwright/Electron E2E: Windows responsive, zoom, keyboard, forced-colors, WebSocket event 흐름을 검증
- Security best practices와 기존 공격 회귀: JavaScript frontend/Node relay/Python CLI에서 적용 가능한 guidance와 실제 trust boundary를 검사
- 전체 unit/integration/build/package 도구: 기능, relay, backup/restore와 릴리스 artifact를 검증

무관한 플러그인을 실행 횟수나 점수를 늘리기 위해 사용하지 않는다. 각 도구는 판정 가능한 gate와 산출물을 가져야 한다.

## 7. 구현 순서

1. exact workspace width 정책과 P1 overflow 회귀를 먼저 추가한다.
2. Mac shell/workspace를 A안으로 바꾸고 실제 데이터 화면 전체를 다시 비교한다.
3. iOS/iPad 2열 fallback, Dynamic Type, 전체 섹션 UI test를 추가한다.
4. Windows 긴 데이터, zoom, forced-colors, focus와 실제 icon을 수정한다.
5. 실시간/성능/메모리/보안/운영 matrix를 실행하고 발견된 결함을 우선순위 순서로 닫는다.
6. 전체 suite와 패키지를 다시 만들고 evidence index와 최종 점수를 계산한다.

## 8. 완료 조건

- 현재 Paper Graphite 시각 언어와 전체 동기화의 섹션 소속이 유지된다.
- Mac, iPhone, iPad, Windows 모든 필수 화면에서 수평 overflow와 잘린 action이 없다.
- 기능, 보안, 실시간, 성능, 접근성, 복구 gate에 미해결 P0/P1/P2가 없다.
- 모든 비파괴 필수 matrix와 전체 suite가 통과한다.
- 실제 사용자 데이터에 쓰지 않고도 생성 가능한 검증 evidence가 경로와 명령까지 기록된다.
- 위 조건을 모두 만족할 때만 100/100으로 보고한다.
