# KLMS Sync Windows 개발 인수인계

이 문서는 Windows 11 실기에서 KLMS Sync companion을 이어 개발하고 릴리스할 때 따르는 단일 시작점이다. 기능 요구사항은 [Windows 구현 가이드](./windows-implementation-guide.md), 시각·반응형 기준은 [Windows UI/UX 기준](./windows-ui-ux-design.md), 서버 계약은 [서버 릴레이 문서](./server-relay.md)를 기준으로 한다.

## 역할과 금지선

- Windows 앱은 KLMS를 직접 수집하지 않는다. sanitized 서버 상태를 읽고 원격 실행, 항목 처리, 임시 파일 링크 요청만 보낸다.
- KLMS 수집과 Notes, Calendar, Reminders, `course_files` 반영은 Mac worker만 담당한다.
- 실시간 변경은 인증된 `/v1/events` WebSocket으로 받는다. HTTP는 최초 snapshot, revision gap 복구, WebSocket이 알린 scope 조회, 사용자 명시 동작에만 사용한다. 주기 polling과 long polling을 추가하지 않는다.
- Windows에는 client token만 둔다. worker token, KLMS 인증 상태, `config.env`, raw KLMS URL, 원본 로그, 개인 메일 본문, Mac 절대 경로를 요청하거나 저장하지 않는다.
- 토큰은 Electron main process의 `safeStorage`로만 영구 저장한다. 안전 저장소가 없으면 세션에서만 사용하고 평문 fallback을 만들지 않는다.
- relay API를 바꾸지 않는 Windows 작업은 Mac/iOS 소스를 수정하지 않는다. 계약 변경이 필요하면 relay 구현, 양쪽 backend 테스트, [서버 릴레이 문서](./server-relay.md)를 같은 변경에 포함한다.

## Windows PC 시작 절차

Windows 11, Git, Node.js 22.x를 준비한다. 실제 URL과 토큰은 로컬 앱에만 입력하고 저장소 파일이나 터미널 캡처에 넣지 않는다.

```powershell
git clone https://github.com/J1SE0K/KLMS-Sync-App.git
cd KLMS-Sync-App
git fetch origin
git switch main
git pull --ff-only
git status --short
git rev-parse HEAD
git switch -c windows/hardening-and-qa

cd apps\KLMSyncWindows
node --version
npm --version
npm audit --package-lock-only --audit-level=high
npm ci
npm audit --audit-level=high
npm run check
npm test
npm run test:e2e
npm run dist:win
```

작업 시작 시 `git status --short`는 비어 있어야 한다. `npm ci` 뒤 생긴 `node_modules`, `dist`, 테스트 캡처는 커밋하지 않는다. x64 설치 파일이 먼저 통과한 뒤 Windows on ARM이 필요할 때만 `npm run dist:win:arm64`를 실행한다.

## 2026-08-09 보안 기준선

현재 lockfile은 `npm audit --audit-level=high`에서 transitive `brace-expansion`, `fast-uri`, `js-yaml`, `undici` HIGH와 `tar` MODERATE가 보고된다. 최신 감사 결과가 항상 우선이며, Windows 작업의 첫 단계는 HIGH/CRITICAL을 0으로 만드는 것이다.

- 먼저 `electron`, `electron-builder`, `@playwright/test`의 호환 가능한 최신 버전과 상위 의존성 해결 상태를 확인한다.
- direct dependency와 lockfile을 함께 갱신하고 전체 diff를 검토한다.
- `npm audit fix --force`, CI의 `continue-on-error`, audit 수준 하향, 근거 없는 override/ignore로 녹색을 만들지 않는다.
- 불가피한 예외는 실제 실행 경로와 공격 가능성을 증명한 문서, 만료일, 책임자, 후속 업데이트 계획이 있어야 한다. 개인용 앱이라는 이유만으로 HIGH를 허용하지 않는다.
- 의존성 변경 뒤 syntax, unit, Electron E2E, installer 설치·실행을 모두 다시 확인한다.

[기준 CI 실행](https://github.com/J1SE0K/KLMS-Sync-App/actions/runs/30761687714)에서는 Apple job과 relay 자체 테스트는 통과했지만 Windows audit가 먼저 실패해 Windows E2E와 installer 빌드가 건너뛰어졌다. 따라서 과거 Mac/iOS 결과를 Windows 완료 증거로 재사용하지 않는다.

## 구현 순서

1. **의존성 보안**: HIGH/CRITICAL 0, lockfile 재현성, Electron/Playwright 호환성을 먼저 닫는다.
2. **기능 parity**: [구현 체크리스트](./windows-implementation-guide.md#구현-체크리스트)를 항목별로 구현하고 기존 stable ID, revision, generation, cancel UUID 규칙을 유지한다.
3. **반응형·접근성**: [UI/UX 체크리스트](./windows-ui-ux-design.md#구현-체크리스트)를 실제 Windows 창, 키보드, 고대비 모드에서 확인한다.
4. **실시간·성능**: WebSocket burst를 한 animation frame에 합치고 필요한 panel만 갱신한다. 선택, 포커스, 스크롤, 진행 중 명령 identity를 보존한다.
5. **패키징**: NSIS x64 설치·업데이트·제거·재설치를 먼저 검증하고, 필요할 때 arm64를 별도 검증한다.
6. **실환경 연결**: Mac worker와 같은 HTTPS/WSS relay에 연결해 원격 실행, 취소, 항목 변경, 파일 링크, 재연결 복구를 확인한다.

## 필수 실기 QA 매트릭스

- 창 너비 `640, 719, 720, 1039, 1040, 1180, 1440px`, 높이 `680, 768, 1080px`
- Windows 배율/앱 zoom `100, 125, 150, 200, 400%`
- 라이트, 다크, forced-colors, reduced-motion
- 마우스, 키보드 전용 이동, visible focus, `aria-live` 상태 알림
- 빈 상태, 긴 한국어/영문/이모지, 2,000개 목록, offline, reconnect, delayed response, revision gap
- 20-event WebSocket burst의 commit-to-visible p95 `250ms` 이하, 주기 polling 0, 이벤트당 전체 document render 0
- 전체 동기화와 개별 동기화의 실행·중단, 중복 요청 차단, 확정 UUID 이전 취소 차단
- 파일 미리보기/다운로드 quota, 만료, 실패, 재요청
- relay 변경 후 대시보드·목록·로그·설정이 새로고침 없이 즉시 일치
- NSIS 신규 설치, 기존 버전 위 업데이트, 제거, 재설치 후 앱이 하나만 존재

## 완료 게이트

아래가 모두 충족되기 전에는 Windows 완료 또는 A+로 표시하지 않는다.

```powershell
cd apps\KLMSyncWindows
npm ci
npm audit --audit-level=high
npm run check
npm test
npm run test:e2e
npm run dist:win
```

- `npm audit`: HIGH 0, CRITICAL 0
- syntax와 unit test: 실패 0
- Electron E2E: 실패 0, polling 0, responsive/WebSocket 시나리오 통과
- GitHub의 `Relay and Windows client tests`, `Windows Electron responsive WebSocket E2E` job 모두 green
- 실제 Windows 11에서 설치·첫 실행·연결·업데이트·제거·재설치 통과
- 생성된 installer와 검증 보고서에 동일한 full commit SHA 기록
- 실제 토큰, URL, 개인 경로, raw 로그가 diff·로그·artifact에 없음
- 완료 시 작업 브랜치를 push하고 PR에서 lockfile, 보안 감사, 테스트, 실기 증거를 함께 검토

개인 PC에만 설치하는 unsigned 개발 빌드는 실기 확인에 사용할 수 있지만, 다른 PC에 배포하는 릴리스는 Windows 코드 서명과 SmartScreen 경로를 별도 완료해야 한다.

## 결과 보고 형식

Windows 작업을 넘길 때 아래 항목을 한 번에 남긴다.

```text
candidate=<40자 commit SHA>
windows-version=<Windows 11 build>
architecture=<x64|arm64>
node=<version>
npm-audit=high:0 critical:0
unit=<pass count>/<total>
e2e=<pass count>/<total>
websocket-p95-ms=<value>
polling=0
installer-sha256=<64자 SHA-256>
install-update-uninstall-reinstall=PASS
open-p0=0 open-p1=0 open-p2=0
```

스크린샷과 `xcresult`에 해당하는 대용량 Windows 테스트 산출물은 검토가 끝나면 정리하고, sanitized 텍스트 요약과 hash manifest만 보존한다.
