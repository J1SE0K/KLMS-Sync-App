# KLMS Sync 엄격한 100점 이중 게이트 설계

- 작성일: 2026-07-15
- 상태: 사용자 설계 승인 완료, 현재 실행에는 역사적 설계 근거로 사용
- 적용 대상: KLMS Sync Mac, iPhone, iPad, Windows, Cloudflare relay, 자체 호스팅 relay. 평가할 source candidate는 5절의 immutable identity로 고정한다.
- 성격: 기존 세부 설계를 연결하고 최종 100점 판정을 통제하는 상위 품질 계약

현재 후보의 실제 실행 명령, 허용 skip, 증거 상태와 점수 판정은
`docs/quality-gate-inventory.json` 및 그 inventory에 결합된 exact-SHA receipt가 우선한다.
이 문서는 설계 의도와 근거를 보존하지만 현재 inventory 또는 receipt를 덮어쓰지 않는다.

## 1. 목적

KLMS Sync를 한 명의 사용자가 Mac, iPhone, iPad, Windows에서 매일 안심하고 쓰는 개인용 멀티디바이스 작업대로 완성한다. 100점은 기능 수나 평균 점수로 계산하지 않는다. 제품 코드와 자동 검증이 완전한 **제품 게이트**와 실제 장치·네트워크·서비스에서 동작이 증명된 **실환경 게이트**를 모두 통과해야만 최종 100점이다.

이 설계는 다음 원칙을 고정한다.

- 미실행, 판정 불가, 오래된 결과와 간접 증거는 통과가 아니다.
- P0, P1, P2 또는 열린 보안 finding 하나라도 있으면 100점이 아니다.
- 외부 KLMS 및 Apple 앱 쓰기는 명시적 사용자 승인 없이 실행하지 않는다.
- 현재 Paper Graphite 디자인과 정보 구조를 유지한다.
- 알려진 결함만 덮는 패치와 전면 재작성 대신, 위험순 수직 슬라이스로 근본 원인과 증거를 함께 닫는다.

## 2. 기존 설계와의 관계

이 문서는 다음 문서를 구현 참고 자료로 사용한다.

- `2026-07-14-klms-sync-personal-a-plus-quality-design.md`
- `2026-07-14-klms-sync-a-option-responsive-recovery-design.md`
- `2026-07-13-klms-sync-safety-realtime-responsive-design.md`
- `2026-07-14-relay-download-reservation-restore-design.md`
- `2026-07-14-klms-safe-cleanup-resource-optimization-design.md`

이 문서만 최종 PASS/FAIL의 규범 원본이다. 기존 문서는 `gate-index.json`에서 gate ID로 명시적으로 채택한 조항만 필수이며, 나머지는 비규범 구현 참고 자료다. 현재 fresh review에서 반증된 과거 점수와 증거 주장은 재사용하지 않는다.

Paper Graphite의 기준 token, 화면, viewport, artifact SHA-256과 source identity는 첫 UI 변경 전에 `docs/superpowers/specs/baselines/2026-07-15-paper-graphite.json`에 고정한다. baseline은 canonical 현재 앱을 fixture 데이터로 캡처하고 개인 데이터를 포함하지 않는다. 이 artifact가 없거나 candidate와 연결되지 않으면 시각 gate는 `INCONCLUSIVE`다.

### 2.1 확정 UI 결정

- `전체 동기화`는 전역 header로 옮기지 않고 기존 동기화 섹션 안에 한 번만 둔다.
- 다열에서는 현재 배치를 유지한다. 실제 workspace가 한 열이 되면 버튼 하나가 아니라 동기화 섹션 전체가 첫 번째다.
- Mac sidebar는 현재 승인 상태인 세 단계로 고정한다.
  - `windowContentWidth >= 1200pt`: 185pt full sidebar
  - `760pt <= windowContentWidth < 1200pt`: 65pt icon rail
  - `windowContentWidth < 760pt`: 숨김
- `windowContentWidth` 759.5, 760, 1199.5, 1200pt를 고정 fractional boundary 회귀로 실행한다.
- `windowContentWidth`는 Mac window content view가 해당 layout pass에서 받은 가용 폭이고, `workspaceContentWidth`는 sidebar/rail을 제외한 workspace container의 실제 가용 폭이다.
- Mac workspace는 `workspaceContentWidth < 900pt`이면 one-column이고 `workspaceContentWidth >= 900pt`이면 multi-column이다.
- 모든 matrix case에서 accessibility tree의 `전체 동기화` action은 정확히 하나이며 동기화 섹션의 후손이어야 한다. one-column이면 동기화 섹션이 첫 top-level section이고 multi-column이면 Paper Graphite baseline 순서를 유지한다.
- 각 sidebar와 one/multi-column breakpoint를 20회 왕복할 때 crossing당 mode change는 1회이고 500ms 안의 재진동, WebSocket session ID 변화, selection·focus 유실은 각각 0회여야 한다.
- sidebar 단계 전환 때 workspace 폭이 수학적으로 단조 증가해야 한다는 이전 조건은 폐기한다. 전환 전후 모두 콘텐츠 이탈과 잘린 action은 0건이어야 하며, transition 안정성은 위의 crossing당 mode change·500ms 재진동·session·selection·focus 수치로만 판정한다.
- 창 네 변과 네 모서리의 내부 resize hit area는 12pt를 유지한다.
- 로그 전체 지우기는 compact destructive action으로 유지하고 최소 44pt hit target과 확인 단계를 제공한다.
- iPhone은 compact navigation, iPad regular width는 sidebar/list/detail 작업대를 사용한다.
- Paper Graphite의 light/dark semantic color, typography, spacing, radius와 시각 계층을 유지한다.

### 2.2 “권한 요청 한 번”의 정의

- 각 TCC 권한은 시스템 상태가 `.notDetermined`일 때 자동 요청을 최대 한 번 시작한다.
- 요청 시작 사실은 `await` 전에 기록해 중복 task와 재진입이 두 번째 prompt를 만들지 못하게 한다.
- 거절·제한 이후 앱이 자동으로 다시 prompt하지 않는다.
- 사용자가 설정 화면에서 명시적으로 누른 복구 action만 System Settings 이동을 제공한다.
- Notification, Calendar, Reminders, Accessibility와 Automation의 대상 앱마다 독립 상태를 유지한다.
- 단위 테스트 통과만으로 완료하지 않고 실제 Mac TCC 흐름에서 한 번만 표시되는 것을 확인한다.

### 2.3 “앱은 하나”의 정의

- Mac 정식 설치본은 `~/Applications/KLMS Sync.app` 하나다.
- LaunchServices와 bundle identifier inventory에서 사용자 실행 대상으로 등록된 같은 앱은 canonical 경로 하나뿐이어야 하고, 실행 중인 canonical executable process도 하나 이하여야 한다. 저장소 build output, Xcode DerivedData, Trash와 명시적 backup은 설치본으로 계산하지 않는다.
- 최신 release candidate를 canonical 경로에 설치하고 launch 후 bundle version, executable hash와 source commit을 확인한다.
- 중복 앱 정리는 앱 bundle만 대상으로 하며 사용자 데이터, KLMS 상태, Keychain과 설정 디렉터리는 건드리지 않는다.
- iOS/iPadOS와 Windows 앱은 서로 다른 플랫폼 제품이므로 “Mac 앱 하나” 조건의 중복으로 계산하지 않는다.

## 3. 2026-07-15 기준선

fresh review에서 Python 287/287, Swift 243/243, Windows unit 24/24와 Electron E2E 8/8, 자체 relay, restore fault 7/7, Cloudflare smoke·local D1 integration은 통과했다. Mac의 8개 workspace, 5개 settings 화면, 640/900/1200pt와 주요 breakpoint도 중앙 배치한 실제 설치 앱에서 통과했다.

이 결과는 2026-07-15 기준선과 결함 재현 근거다. 일부 fresh artifact가 임시 경로에 있으므로 최종 release 점수 근거로 승격하지 않고, 동일 candidate의 durable evidence로 다시 생성한다.

그러나 다음 항목이 100점을 차단한다.

### 3.1 재현된 P1/P2

- P1: iPad AX5에서 보조 동기화 action의 실제 hit target이 34.75pt로 최소 44pt 계약을 위반한다.
- P2: iPhone과 iPad의 2,000-item 검색 경로에서 `Invalid frame dimension (negative or non-finite)` runtime warning이 재현된다.
- P2: 인증 없는 Cloudflare `/readyz`와 잘못된 file-download 요청이 반복적인 D1 조회를 유발해 가용성·비용 증폭 경로가 된다.

현행 결함 cap을 적용하면 fresh P1이 닫히기 전 최종 점수 상한은 79점이다.

### 3.2 기능·동시성·성능 차단

- iOS는 status endpoint만 성공하면 다른 endpoint가 실패해도 “최신 상태를 불러왔습니다”라고 표시할 수 있다.
- iOS mail dashboard의 배열 전체 rollback은 겹친 요청 중 이미 성공한 다른 변경을 지울 수 있다.
- Mac은 재귀 파일 열거, JSON I/O와 일부 외부 프로세스 대기를 MainActor에서 수행한다.
- 기존 `CourseFiles` 하위 디렉터리의 create/modify/delete는 FSEvent가 와도 root marker가 같으면 reload가 생략될 수 있다.
- iOS 2,000-item projection은 큰 ObservableObject와 MainActor에 집중되어 있다.
- Windows 설정은 destination에 직접 쓰므로 중단·부분 쓰기 때 설정 파일이 손상될 수 있다.
- 자체 relay migration은 예상한 duplicate-column 외의 `ALTER TABLE` 오류까지 삼킬 수 있다.
- 핵심 행동 일부가 source-text assertion으로만 보호되어 잘못된 분기가 실행되지 않은 채 테스트를 통과할 수 있다.

### 3.3 보안 차단

- public readiness와 malformed capability 요청이 storage work 전에 차단되지 않는다.
- manifest·cleanup·upload 경로의 canonical containment와 symlink 방어가 모든 소비자에 일관되게 적용되지 않는다.
- 영향받는 구형 PDF.js가 남아 있고 eval 비활성화가 명시적이지 않다.
- 수동으로 짧은 token을 설정할 수 있고 인증 실패 throttle과 WebSocket connection cap이 없다.
- dashboard 및 downloader의 KLMS URL 검증이 exact HTTPS origin 계약보다 느슨하다.
- Cloudflare API가 wildcard CORS를 허용한다.
- Electron privileged IPC가 sender frame과 application URL을 확인하지 않는다.
- relay가 반환한 download URL을 configured relay origin에 묶지 않는다.
- capability ticket이 URL query에 포함된다.
- GitHub Actions가 mutable tag를 사용하고 artifact redaction이 일반적인 token·cookie·password·device identifier를 모두 덮지 않는다.

### 3.4 실환경 증거 차단

- 물리 iPhone과 iPad의 signed Release 실행
- 실제 Windows 11 설치·실행·업데이트·제거
- 배포된 Cloudflare와 자체 relay의 WAN loss·latency·offline·backend별 recovery
- VoiceOver, Switch Control, keyboard-only 전체 흐름
- 실제 TCC 권한 1회 동작
- 성공한 memgraph/leak 분석
- 8시간 soak
- 사용자 승인 하의 실 KLMS read flow와 전용 Notes·Calendar·Reminders canary side effect
- exact clean commit과 동일한 signed/notarized release artifact

## 4. 선택한 접근

### 4.1 채택: 이중 게이트 + 위험순 수직 슬라이스

각 슬라이스는 `회귀 테스트 → 최소 근본 수정 → 자동 검증 → matching surface 수동 QA → 증거 보존 → 독립 리뷰` 순서로 닫는다. 다음 슬라이스는 이전 슬라이스의 P0/P1/P2가 닫힌 뒤 진행한다.

제품 게이트와 실환경 게이트를 분리하되 최종 판정에서는 논리곱으로 결합한다. 두 게이트는 각각 PASS/FAIL/INCONCLUSIVE로 판정하고, 둘 다 PASS일 때만 아래 가중 점수를 최종 100으로 확정한다.

### 4.2 기각한 접근

- **알려진 결함만 패치:** 빠르지만 새로 발견된 동시성·경계·증거 문제를 반복해서 놓친다.
- **플랫폼별 전면 재작성:** 구조적 부채는 줄일 수 있으나 대규모 회귀와 현재 디자인 훼손 위험이 크다.

필요한 seam만 추출하고 거대한 파일 전체를 한 번에 재작성하지 않는다.

## 5. release candidate와 증거 정체성

모든 최종 증거는 하나의 immutable release candidate에 묶는다.

- candidate는 clean Git commit SHA로 식별한다.
- 테스트, 앱 bundle, Windows installer, iOS archive, relay image와 evidence manifest가 같은 SHA를 기록한다.
- working tree가 dirty하거나 산출물의 source SHA가 다르면 release gate를 시작하지 않는다.
- 빌드 산출물마다 SHA-256, bundle/package version, signing identity, build configuration과 toolchain version을 기록한다.
- 재검증 중 코드가 바뀌면 이전 증거는 참고 자료로만 남기고 새 candidate에서 필요한 gate를 다시 실행한다.

증거 package는 임시 `/tmp`에만 남기지 않는다. 기본 private durable root는 mode 0700의 `~/Library/Application Support/KLMS Sync/ReviewEvidence/<candidate-sha>/`다. 민감 정보가 없는 summary와 manifest는 저장소 문서로 보존할 수 있고, 개인 데이터가 보이는 화면·로그·물리 장치 식별자는 private root에만 보관한다. 외부 공유용 산출물에는 원문 token, cookie, auth header, 홈 경로, 이메일, device identifier와 KLMS 개인 제목이 없어야 한다.

### 5.1 규범 inventory와 추적성

구현 시작 전에 candidate와 함께 `docs/quality-gates/` 아래에 다음 규범 inventory를 고정한다. 아래 파일명은 모두 이 디렉터리에 상대적이다.

- `gate-index.json`: 이 문서에서 PASS/FAIL/INCONCLUSIVE에 영향을 주는 모든 규범 문장에 stable gate ID를 부여하고 leaf 또는 aggregate로 분류한다. 각 leaf에는 expected observation, platform/environment, 실행 protocol, artifact와 scorecard row ID를 기록하고, aggregate에는 구성 gate ID와 Boolean 식을 기록한다.
- `required-tests.json`: suite, target, exact command, filter, minimum discovered count와 allowed skip count를 기록한다. 필수 gate의 allowed skip은 0이다.
- `coverage-baseline.json`: 언어별 tool/version, include/exclude path, critical module path·symbol과 line/branch numerator·denominator를 기록한다.
- `findings.json`: scanner, code review, runtime QA와 수동 접근성 finding의 source, severity, status, disposition과 closure evidence를 기록한다.
- `security-policy.json`: route·credential·storage·WAF의 승인 수치와 expected configuration을 기록한다.
- `performance-protocol.json`: metric별 대상, marker, Release build, warm-up, sample, percentile와 soak 계산법을 기록한다.

모든 leaf gate ID는 한 개 이상의 required test 또는 수동 protocol과 evidence artifact에 연결되고 정확히 하나의 `DATA`, `UI`, `UX`, `PERF`, `SEC`, `REL`, `RELEASE` scorecard row ID에 속해야 한다. 각 행의 gate ID 집합은 실행 전에 `gate-index.json` hash로 고정한다. gate ID가 없는 규범 문장, 규범 문장으로 역추적되지 않는 gate, 누락·중복·알 수 없는 row ID, 누락 artifact, discovered test count 감소, 허용되지 않은 skip과 오래된 candidate evidence는 `INCONCLUSIVE`다. Aggregate gate는 점수를 중복 산정하지 않지만 최종 PASS에는 모두 PASS여야 한다.

severity는 다음처럼 판정한다.

- P0: credential compromise, RCE, 승인 범위 밖 side effect 또는 비가역 사용자 데이터 손상
- P1: 안전한 workaround가 없는 core-flow·데이터 무결성·접근성 blocker
- P2: 지원 환경에서 재현되는 material defect이지만 안전한 workaround가 있는 문제
- P3: 낮은 영향의 보안 hardening/advisory 또는 경미한 제품 결함

## 6. 제품 게이트

### 6.1 슬라이스 A: 보안과 destructive boundary

#### public edge와 abuse resistance

- public `/healthz`는 process liveness만 반환하며 D1, R2, SQLite와 filesystem을 조회하지 않는다.
- schema와 binding을 확인하는 `/readyz`는 admin/readiness credential로 보호한다.
- route, UUID, capability 형식과 body size를 storage 접근 전에 검증한다.
- malformed unauthenticated 요청은 database query 0회로 종료한다.
- self-host maintenance는 인증 전 request path에서 실행하지 않고 독립 schedule 또는 인증 뒤 bounded task로 이동한다.
- Cloudflare WAF와 애플리케이션 양쪽에 `security-policy.json`의 route별 rate-limit key, window, burst와 sustained limit을 두고 excess traffic은 429로 종료한다.
- WebSocket 인증 실패와 동시 connection 수도 `security-policy.json`의 수치로 제한한다.

#### URL·파일·capability 경계

- KLMS URL은 모든 parser와 consumer에서 `https`, exact host `klms.kaist.ac.kr`, credential 없음, 기본 port만 허용한다.
- relay download URL은 `security-policy.json`에 기록한 configured relay의 exact scheme, host, port와 anchored path pattern에 묶는다.
- download credential은 query string에 넣지 않는다. native client의 authenticated fetch 또는 일회성 header capability를 사용한다.
- manifest의 serialized absolute path는 신뢰하지 않는다.
- source, destination, trash와 upload 후보는 canonical path와 허용 root를 비교하고 `..`, absolute input, backslash, NUL과 symlink escape를 거부한다.
- destructive move, write, upload는 no-follow semantics와 0700 directory, 0600 file mode를 사용한다.

#### client·dependency·supply chain

- PDF.js는 구현 시점의 maintained patched version으로 올리고 integrity를 고정하며 `isEvalSupported: false`를 명시한다.
- client/worker/readiness token은 최소 32 random bytes이고 역할별로 다르며 rotation과 폐기를 지원한다.
- native client만 사용하는 API에서 wildcard CORS를 제거한다. browser origin이 필요한 route만 exact allowlist와 `Vary: Origin`을 사용한다.
- 모든 privileged Electron IPC handler는 canonical main window의 main frame과 exact app URL을 확인한다.
- GitHub Actions는 reviewed full commit SHA로 고정하고 checkout credential persistence를 끈다.
- 공통 redactor가 authorization, bearer, token, cookie, password, secret, device identifier와 개인 경로를 처리하며 synthetic canary로 검증한다.
- `security-policy.json`은 route별 body-byte cap과 path pattern, rate-limit key/window/burst/sustained limit, WebSocket failed-auth limit와 concurrent cap, scheduled maintenance max items/duration, exact CORS origin, TLS minimum, WAF policy ID, filesystem mode와 Keychain/safeStorage expected protection을 반드시 가진다.
- `security-policy.json`의 모든 수치는 gate 실행 전에 사용자와 security review lane이 명시적으로 승인한다. 승인자, 시각, 근거와 file SHA-256을 manifest에 기록하고 candidate에 동결한다. 승인 누락 또는 승인 후 변경은 `INCONCLUSIVE`다.

#### 합격 조건

- 인증 없는 malformed 요청의 storage query 0회
- 승인 burst의 2배를 5개 연속 window에 전송하는 abuse 부하에서 excess 429, quota exhaustion 0건과 정상 client의 6.3절 latency budget 보존
- path traversal·symlink·off-origin·active-scheme fixture 전부 거부
- 보안 P0~P3와 미해결 dependency advisory 0건
- Semgrep, Gitleaks, detect-secrets, Trivy, Bandit, ShellCheck, Syft, Grype, OSV-Scanner와 pip-audit 결과가 모두 clean이거나 각 finding의 명시적 false-positive adjudication 완료
- 배포용 TLS, WAF, logging, ACL, Keychain/safeStorage와 signing/notarization 설정을 코드·package 수준에서 검사하고 실환경 확인 항목으로 연결

### 6.2 슬라이스 B: 상태 정확성과 원자성

- iOS relay endpoint 결과는 endpoint별 typed success/failure를 보존한다.
- 일부 endpoint가 실패하면 성공 banner를 금지하고 실패 panel을 stale로 표시하되 성공한 panel은 유지한다.
- 오류를 `nil`이나 빈 배열로 축약하지 않는다.
- optimistic action은 item ID와 operation ID별 overlay로 관리한다.
- 한 요청의 실패는 해당 overlay만 되돌리고, 겹친 성공 변경은 보존한다.
- Windows config는 mode-restricted sibling temp에 쓰고 flush·atomic replace 후 parent directory를 동기화한다.
- relay migration은 schema 선확인 또는 정확한 duplicate error만 허용한다. busy, readonly, I/O, disk-full은 startup failure다.
- source-text assertion은 fake transport/store와 실제 행동 테스트로 교체한다. source inspection은 보조 guard로만 남긴다.

#### 합격 조건

- 모든 endpoint별 500, timeout, malformed, empty-authoritative fixture에서 문구·stale state·return value가 일치
- 역순 완료와 일부 실패를 포함한 optimistic concurrency 테스트에서 성공 변경 유실 0건
- Windows kill·short-write fault에서 이전 config 또는 새 config만 관찰되고 손상 JSON 0건
- migration legacy/idempotent/busy/readonly/disk-full fault 결과가 계약과 일치

### 6.3 슬라이스 C: 실시간성과 성능

- FSEvent callback은 변경 경로를 보존한다.
- `CourseFiles` 하위 event는 root mtime과 무관하게 bounded partial reload 또는 강제 snapshot reload를 수행한다.
- Mac 파일 열거, JSON decode, backup lookup와 외부 진단 process 대기는 별도 I/O actor에서 수행한다.
- MainActor는 immutable 결과를 한 번 게시하고 화면 상태만 갱신한다.
- iOS는 normalize, signature, sort, lookup과 action projection을 Sendable background pipeline에서 계산한다.
- 화면별 immutable snapshot과 좁은 observation boundary를 사용해 관계없는 view invalidation을 줄인다.
- Cloudflare global promise tail은 mutation ordering에만 사용한다. read path의 head-of-line blocking 여부를 fault latency로 검증한다.
- dashboard 데이터용 scheduled HTTP polling은 0회다. bootstrap, revision gap 복구와 파일 전송만 one-shot HTTP를 허용한다.
- dashboard, 과제, 공지, 파일, 캘린더, 로그, 설정, command, item action, file request와 status의 모든 authoritative mutation은 revision/generation 계약으로 열린 화면에 반영한다.
- authoritative empty array와 삭제 event도 stale row를 제거하며, endpoint별 실패는 다른 성공 endpoint의 최신 데이터를 되돌리지 않는다.

#### 성능 budget

- tap/click 후 로컬 visual feedback p95: 100ms 이하
- local/private network commit → visible p95: 250ms 이하
- 정상 배포 WAN commit → visible p95: 1초 이하
- Windows 20-event burst visible p95: 250ms 이하, polling 0, full document render 0
- iOS 2,000-item projection p95: 150ms 이하, MainActor publish p95: 16ms 이하
- Mac navigation readiness: 5회 평균 100ms 이하, 단일 최악 250ms 이하
- 10,000-file FSEvent 처리 중 main-thread hang 100ms 이상 0회

`performance-protocol.json`은 metric별 시작·종료 marker, 적용 device·relay, Release build, warm-up, event type, sample count와 percentile 방식을 고정한다. p95는 적용 가능한 조합별 warm-up 이후 최소 500개 표본의 nearest-rank 값이다. local-only metric은 relay 차원 없이 대상 device별 500개 표본을 사용한다. 정상 WAN은 impairment를 주입하지 않은 상태이며 실제 RTT와 loss를 artifact에 기록한다. 평균값이나 단일 성공 샘플로 p95 gate를 대체하지 않는다.

### 6.4 슬라이스 D: UI·UX·접근성

- iPad AX5 보조 동기화 action과 모든 interactive control은 실제 frame 44×44pt 이상이다.
- iOS search focus, keyboard 표시, section 전환과 복귀에서 runtime layout warning 0건이다.
- dashboard scope picker를 포함한 모든 iOS hit target은 44pt 이상이다.
- Dynamic Type 기본, XL, AX3, AX5에서 action이 잘리거나 겹치지 않고 부족한 폭에서는 세로 fallback을 사용한다.
- Mac, iPhone, iPad, Windows의 모든 실제 화면은 긴 데이터, 빈 상태, 오류, 실행 중, offline과 reconnect 상태에서 viewport를 벗어나지 않는다.
- WebSocket update와 resize 뒤에도 selection, scroll, keyboard focus, active request identity를 보존한다.
- Windows zoom 100, 125, 150, 200, 400%, forced-colors, reduced-motion과 keyboard-only flow를 통과한다.
- 플랫폼 문서가 약속한 tab, log clear와 diagnostics 기능은 실제 구현과 일치한다. Mac worker 전용 기능은 capability matrix에서 명시하고 companion이 지원하는 것처럼 문서화하지 않는다.
- permission-once 계약과 Mac 앱 한 개 계약을 실제 설치 환경에서 검증한다.

#### 반응형 matrix

- Mac: 640, 720, 759, 760, 900, 1039, 1040, 1199, 1200, 1400pt
- iPhone/iPad: 320, 375, 390, 430, 719, 720, 834, 1024, 1039, 1040, 1047, 1048, 1366pt에 대응하는 device, orientation, Split View와 Stage Manager 상태
- Windows: 640, 719, 720, 1039, 1040, 1180, 1440px와 680, 768, 1080px 높이
- 각 matrix는 light/dark, 기본/긴/빈/오류/실행 중 상태와 의미 있는 모든 보이는 후손 containment를 검사한다.
- 각 Mac matrix는 `전체 동기화`의 유일성, 동기화 섹션 소속과 one/multi-column top-level 순서를 함께 assert한다.

### 6.5 슬라이스 E: CI·테스트·release readiness

- Python, Swift, Windows unit/E2E, Cloudflare smoke/local D1, self-host relay와 restore fault를 CI에서 실행한다.
- iPhone과 iPad 각각 전체 UI test set을 실행하며 log clear, large dataset, search focus와 AX5를 선택 목록에서 빠뜨리지 않는다.
- xcresult, runtime warning, screenshot, metrics와 test count를 같은 evidence package에 보존한다.
- 추출된 pure critical module인 run/revision state machine, path/URL validator, quota/reservation policy, rollback policy와 permission policy는 branch coverage 100%를 요구한다.
- 전체 repository coverage는 baseline을 기록하고 감소를 금지한다. generated/vendor code는 분모에서 제외한다.
- package/install smoke는 Mac canonical app, signed iOS archive와 Windows installer를 대상으로 한다.
- release package에는 source tree, test fixture, review evidence, build cache와 개발용 dependency를 포함하지 않는다.
- unused code와 asset은 compiler/reference 검색과 행동 회귀로 미사용이 증명된 경우에만 제거한다. 사용자 데이터와 재생성 불가능한 evidence는 cleanup 대상이 아니다.
- `git diff --check`, shell/Node syntax, dependency audit, build와 test 중 하나라도 nonzero이면 candidate는 실패다.

## 7. 실환경 게이트

제품 게이트를 통과한 동일 candidate만 실환경 게이트에 들어간다.

이 설계의 승인은 실환경 mutation 실행 권한이 아니다. canonical 앱 교체·중복 bundle 제거, 물리 장치 설치·update·uninstall, TCC reset·권한 prompt, 배포 relay rollout·restart·fault·abuse load와 실 KLMS·Apple canary 직전에 대상, 예상 side effect·비용·downtime와 rollback을 제시하고 사용자의 명시적 승인을 받는다. manifest에서 disposable로 확인된 VM과 격리 local relay fixture만 이 추가 승인 없이 실행할 수 있다.

### 7.1 물리 장치와 설치

- 실제 iPhone과 iPad에 signed Release를 설치한다.
- 양 방향, light/dark, AX5, Increase Contrast, 2,000-item fixture, cold/warm launch와 reconnect를 실행한다.
- 실제 또는 깨끗한 Windows 11 VM에서 installer 설치, first launch, WebSocket 연결, keyboard/zoom, update, uninstall과 재설치를 검증한다.
- Mac은 canonical 경로의 앱 하나만 남기고 version/hash/SHA를 확인한다.

### 7.2 실제 네트워크와 relay recovery

- 배포된 Cloudflare와 자체 relay 각각에서 정상 WAN, 100/300/800ms 왕복 지연, 1/5/20% packet loss, 60초 offline과 invalid auth를 실행한다.
- Cloudflare는 deployed-version rollout/rollback과 injected handler·storage outage를 사용한다. self-host는 process kill/restart와 readiness recovery를 사용한다.
- reconnect 중 오래된 HTTP/WS 응답이 최신 revision을 되돌리지 않아야 한다.
- polling은 0이며 정상 WAN p95 1초 budget을 지킨다.
- WAF/rate limit, TLS, CORS, readiness 보호와 log redaction을 synthetic credential로 검증한다.
- 두 relay 사이의 자동 cross-relay failover는 승인된 RPO/RTO와 state-transfer 설계가 없으므로 범위 밖이다. 이 문서의 reliability 항목은 backend별 rollout·restart·outage recovery만 뜻한다.
- 각 backend/fault 조합을 독립적으로 5회 실행한다. fault 제거 또는 rollback 완료 marker부터 60초 이내에 authenticated readiness와 최신 authoritative revision 표시가 모두 복구되어야 한다. acknowledged mutation loss, 중복 side effect, stale revision rollback과 수동 data repair는 각각 0건이어야 한다.

### 7.3 실제 접근성

- VoiceOver, Switch Control과 physical keyboard-only로 dashboard 확인, 전체 동기화 진입, 항목 탐색, 검색, 실행·취소, 로그 확인, 설정 복구 흐름을 완주한다.
- focus order, label, value, hint, live announcement와 destructive confirmation을 기록한다.
- 실제 TCC prompt가 권한별 한 번만 나타나고 거절 후 자동 반복되지 않는지 확인한다.

### 7.4 실 KLMS와 Apple 앱 canary

- 실 KLMS 검증은 read flow와 사용자가 직접 시작한 sync만 대상으로 하고 과제 제출·시험·퀴즈 동작을 포함하지 않는다.
- Notes는 전용 folder, Calendar는 전용 calendar, Reminders는 전용 list를 사용한다.
- canary 이름은 run UUID를 포함하고 create, update, delete, retry, cancellation과 rollback을 검증한다.
- 모든 Apple mutation은 audit log에 기록하고 destination ID가 run-UUID allowlist 안에 있어야 한다.
- 대상 folder/calendar/list의 비-canary 항목은 user-controlled field를 정규화·정렬해 pre/post hash하며, 제외한 OS-generated metadata를 manifest에 기록한다.
- KLMS trace는 승인된 read endpoint만 허용하고 mutation request 0회를 요구한다. 항목을 완전히 열거할 수 없으면 `INCONCLUSIVE`, 예상 밖 write는 `FAIL`이다.
- 이 단계는 설계 승인으로 자동 허가되지 않는다. 실행 직전에 대상과 예상 side effect를 제시하고 사용자의 명시적 승인을 받는다.

### 7.5 메모리와 8시간 soak

- 대표 flow 후 성공한 memgraph/leak capture를 얻고 app-owned persistent retain cycle을 분석한다.
- Cloudflare와 self-host relay에 대해 각각 독립된 8시간 동안 reconnect, snapshot apply, file request와 비파괴 sync fixture를 반복한다.
- crash, deadlock, data-integrity drift, polling과 unbounded queue가 0건이어야 한다.
- 30분 warm-up 뒤 60초마다 측정한다. baseline은 30~40분 median, final은 마지막 10분 median, 증가율은 30~480분 ordinary-least-squares slope다.
- 각 대상 process에서 RSS final은 baseline의 120% 이하, 증가율은 시간당 1MB 이하로 유지한다.
- file descriptor와 handle의 종료 시 net 증가가 각각 5개 이하여야 한다.
- idle CPU median은 1% 이하여야 한다.
- leak 결과의 definite leak은 0건이고 teardown 후 설명되지 않은 app-owned persistent retain cycle도 0건이어야 한다.
- 모든 queue는 `performance-protocol.json`의 numeric cap과 high-water telemetry를 가지며 종료 시 baseline depth로 돌아와야 한다.

## 8. 오류 처리와 rollback

- 수집 불완전, 인증 실패, partial endpoint failure, migration failure와 evidence 수집 실패를 성공이나 빈 상태로 축소하지 않는다.
- destructive side effect는 authoritative input, canonical containment와 idempotency precondition을 통과한 뒤에만 실행한다.
- 한 슬라이스의 실패는 해당 변경과 해당 evidence만 무효화하며 기존 사용자 데이터와 이미 통과한 독립 기능을 되돌리지 않는다.
- release install 실패 시 이전 canonical app bundle을 복구할 수 있는 verified backup을 유지한다.
- 실환경 canary cleanup 실패는 성공으로 보고하지 않고 canary 식별자와 안전한 수동 복구 절차를 남긴다.
- scanner, physical device 또는 external environment가 unavailable이면 `INCONCLUSIVE`이며 점수를 부여하지 않는다.

## 9. 점수와 cap

| Row ID | 영역 | 배점 | 100점 필수 조건 |
| --- | --- | ---: | --- |
| `DATA` | 기능·데이터 무결성 | 20 | 모든 fail-closed, atomicity, concurrency, rollback, 실제 canary gate 통과 |
| `UI` | 반응형 UI·시각 완성도 | 20 | 전체 platform/state matrix와 matched-state visual review 통과 |
| `UX` | UX·접근성 | 15 | 44pt, Dynamic Type, keyboard, VoiceOver, Switch Control, permission-once 통과 |
| `PERF` | WebSocket·레이턴시·성능 | 15 | polling 0, revision/generation, latency budget, profiler, memgraph, soak 통과 |
| `SEC` | 보안·개인정보 | 15 | P0~P3 0, scanner·배포 edge·secret·signing evidence 통과 |
| `REL` | 신뢰성·운영 복구 | 10 | backup/restore, migration, quota, WAN failure와 backend별 recovery 통과 |
| `RELEASE` | 테스트·릴리스 증거 | 5 | exact clean SHA, 전체 CI, 설치물과 self-contained evidence 통과 |
|  | **합계** | **100** | 제품 게이트와 실환경 게이트 모두 PASS |

결함 cap은 다음과 같다.

- 미해결 P0: 최대 39점
- 미해결 P1: 최대 79점
- 미해결 P2: 최대 89점
- 필수 증거 미실행 또는 INCONCLUSIVE: 최대 94점
- 보안 P3 또는 알려진 advisory가 열려 있으면 보안 영역 만점과 최종 100점 금지

각 점수표 행은 연결된 필수 gate가 모두 PASS이면 행 전체 배점을 받고, 하나라도 FAIL 또는 INCONCLUSIVE이면 0점이다. fractional 점수는 없다. 표시 점수는 `min(행 배점 합계, 적용되는 가장 낮은 cap)`이다. 숫자와 무관하게 제품 게이트와 실환경 게이트가 모두 PASS이고 합계가 100일 때만 release PASS다.

## 10. 리뷰와 증거 package

각 슬라이스와 최종 candidate의 evidence는 다음 구조를 따른다.

```text
review-evidence-YYYYMMDD-HHMMSS/
  manifest.json
  scorecard.md
  contracts/
    2026-07-15-paper-graphite.json
    gate-index.json
    required-tests.json
    coverage-baseline.json
    findings.json
    security-policy.json
    performance-protocol.json
  approvals/
  commands/
  tests/
  ui/mac/
  ui/ios/
  ui/windows/
  performance/
  security/
  reliability/
  real-devices/
  releases/
  review-work/
```

`manifest.json`은 candidate SHA, dirty 여부, tool versions, OS/device, 명령, 시작·종료 시각, exit code, artifact hash와 redaction 상태를 기록한다. `contracts/`에는 baseline과 모든 규범 inventory의 동결 사본을 보존하고, `approvals/`에는 외부 mutation별 대상·side effect·비용·downtime·rollback·결정 시각을 보존한다. Manifest는 이 파일들의 SHA-256을 기록하며 누락 시 `INCONCLUSIVE`다. Scorecard의 각 점수는 하나 이상의 manifest artifact를 가리킨다. 보존되지 않은 `/tmp` 파일, 다른 SHA의 결과와 수동으로 복사한 숫자는 점수 근거가 아니다.

최종 리뷰는 다음을 모두 실행한다.

- Product Design screenshot-first audit와 matched-state visual comparison
- Mac 실제 앱, iOS debugger/physical device, Windows Playwright·installer hands-on QA
- SwiftUI code-first performance audit, ETTrace/Time Profiler/Animation Hitches와 memgraph
- security-best-practices, SAST, secret, dependency, SBOM, container, DAST와 배포 edge 확인
- LazyCodex `review-work`의 목표, QA, 코드 품질, 보안, context 5개 lane
- runtime failure가 있었던 영역의 `debugging` audit

5개 review lane 중 하나라도 FAIL 또는 INCONCLUSIVE이면 최종 리뷰는 통과하지 않는다.

## 11. 구현 순서

1. baseline, candidate identity, 규범 inventory와 테스트 harness를 고정한다.
2. 슬라이스 A의 public abuse, path/URL, token, CORS, IPC와 supply-chain 경계를 닫는다.
3. 슬라이스 B의 partial failure, optimistic rollback, Windows atomic config와 migration을 닫는다.
4. 슬라이스 C의 nested FSEvent, MainActor I/O, iOS projection과 latency를 닫는다.
5. 슬라이스 D의 iPad AX5, keyboard warning, 전체 반응형·접근성 matrix를 닫는다.
6. 슬라이스 E의 CI, scanner, package/install과 evidence 보존을 닫는다.
7. clean release candidate를 만들고 제품 게이트를 전부 재실행한다.
8. manifest에서 disposable로 확인된 VM과 격리 local relay gate를 실행한다. 그 밖의 canonical 앱 교체, 물리 장치 설치·update·uninstall, TCC reset·권한 prompt와 배포 relay 조작은 각 실행 직전에 7절의 별도 승인을 받은 뒤 실행한다.
9. 실 KLMS·Apple 앱 canary도 7.4절의 별도 승인을 받은 뒤 실행한다.
10. 8시간 soak와 최종 5-lane review를 통과한 뒤 점수를 다시 계산한다.

## 12. 범위 밖

- 다중 사용자·조직·공개 SaaS·결제·관리자 portal
- KLMS 자동 제출, 퀴즈·시험 풀이와 성적 변경
- 현재 Paper Graphite를 대체하는 전면 시각 재설계
- 품질 목표와 관계없는 기능 추가
- generated/vendor code까지 포함한 기계적 repository 전체 100% line coverage

## 13. 완료 판정

다음 조건을 모두 만족할 때만 KLMS Sync를 100/100으로 판정한다.

1. 동일한 clean candidate SHA에서 모든 제품 게이트가 통과한다.
2. P0, P1, P2와 보안 P3가 0건이다.
3. 실제 iPhone, iPad, Windows, Mac, 배포 relay와 보조기술 gate가 통과한다.
4. 실 KLMS와 Apple 앱 canary가 별도 승인된 범위에서 비-canary 데이터를 바꾸지 않고 통과한다.
5. latency, memory, leak와 8시간 soak budget을 통과한다.
6. canonical Mac 앱이 하나이며 설치물과 source SHA가 일치한다.
7. self-contained evidence package의 모든 artifact가 보존되고 redaction 검증을 통과한다.
8. LazyCodex 5개 최종 review lane이 모두 PASS다.
9. unresolved finding, skipped mandatory test와 INCONCLUSIVE evidence가 없다.

이 조건 전에는 “거의 100”, 반올림 100 또는 증거 없는 100을 보고하지 않는다.
