# KLMS Sync Windows 개발 인수인계

## 기준

- 인수인계 브랜치: `windows-handoff-2026-07-27`
- 분기 기준: `8b789231dfc65dcffcf96ea05e9bf5629a778ccc`
- 개발 환경: 실제 Windows 11
- Node.js: 저장소 CI와 같은 22 버전
- Windows 앱은 KLMS를 직접 수집하지 않고 HTTPS relay의 정제된 데이터만 사용한다.
- Windows 검증이 모두 통과하기 전에는 이 브랜치를 `main`에 병합하지 않는다.

실제 relay URL, 토큰, 인증 정보, 사용자 파일 경로와 KLMS 원본 URL은 코드, 테스트 fixture, 로그, screenshot에 넣지 않는다.

## 현재 보존된 구현

다음 변경은 브랜치에 그대로 보존한다.

- Electron `safeStorage`로 암호화한 대시보드 시작 캐시
- relay URL과 client token 조합에 귀속된 cache binding
- 손상·미래 시각·허용 크기 초과 캐시의 fail-closed 폐기
- 연결 정보 변경·삭제 시 이전 캐시 삭제
- 임시 파일 쓰기, flush, rename을 이용한 교체
- 앱 시작 시 저장된 대시보드를 먼저 표시하고 WebSocket/HTTP snapshot으로 재검증
- 현재 설정 revision과 일치하는 renderer만 캐시를 갱신

관련 파일:

- `apps/KLMSyncWindows/src/dashboard-cache.cjs`
- `apps/KLMSyncWindows/src/main.cjs`
- `apps/KLMSyncWindows/src/preload.cjs`
- `apps/KLMSyncWindows/src/renderer.js`
- `apps/KLMSyncWindows/test/dashboard-cache.test.cjs`
- `apps/KLMSyncWindows/test/e2e/windows-realtime.spec.js`

## 시작 명령

PowerShell에서 저장소 루트 기준으로 실행한다.

```powershell
git fetch origin
git switch windows-handoff-2026-07-27
Set-Location apps/KLMSyncWindows
npm ci
npm run check
npm test
npm run test:e2e
npm run dist:win
```

테스트를 통과시키기 위해 assertion, 접근성 검사, 보안 저장소 검사 또는 viewport 범위를 삭제하거나 완화하지 않는다.

## 알려진 실패

2026-07-22 macOS Electron 사전 검증 결과:

- `npm test`: 38/38 통과
- `npm run test:e2e`: 10/11 통과
- 실패 시나리오:
  `long server data stays contained through 640px, browser zoom, keyboard selection and forced colors`
- 실패 지점:
  200% 확대 상태의 `countViewportEdgeInkInElement("#statusSubtitle", 4)`
- 관측값:
  `differentPixels` 예상 0, 실제 3024

이 결과만으로 실제 Windows 렌더링 결함인지 macOS Electron의 문자 rasterization 차이인지 결정하지 않는다. Windows 11에서 같은 시나리오를 먼저 재현하고 다음 증거를 함께 확인한다.

1. `documentElement.scrollWidth <= clientWidth`
2. 상태 영역과 subtitle의 bounding rectangle이 viewport와 content 안에 포함되는지
3. 200% 확대 screenshot에서 글자·focus ring·경계선이 실제로 잘리는지
4. 100%, 125%, 150%, 200%, 400% 확대 전환 후 선택·focus가 유지되는지

실제 잘림이면 production CSS와 레이아웃을 수정한다. 화면은 정상인데 edge-ink 측정만 실패하면 Windows의 동일 폰트·배율에서 안정적인 기준을 증명한 뒤 측정 방법을 고친다. 단순 허용 오차 증가로 실패를 숨기지 않는다.

## 2026-07-27 보안 차단 항목

최신 OSV 데이터베이스 검사는 `electron-builder@26.15.3`의 개발 전용 간접 의존성에서 다음 HIGH 1종과 MODERATE 1종을 발견했다.

- `brace-expansion` 1.1.16, 2.1.2, 5.0.7:
  `GHSA-mh99-v99m-4gvg` 메모리 고갈 DoS. 수정 버전은 5.0.8 이상이다.
- `tar` 7.5.20:
  `GHSA-r292-9mhp-454m` 긴 경로 archive 처리 중 stack-overflow DoS. 수정 버전은 7.5.21 이상이다.

두 패키지는 앱 런타임 의존성이 아니라 Windows 빌드 도구 경로에 있지만, installer 생성과 CI도 신뢰 경계이므로 무시하거나 보안 예외로 숨기지 않는다. Windows 11에서 다음 순서로 처리한다.

1. `electron-builder`와 하위 빌드 도구의 최신 호환 버전을 먼저 확인한다.
2. 상위 패키지 업데이트만으로 해결되지 않으면 npm `overrides`를 사용하되, 서로 다른 `brace-expansion` 메이저 버전을 하나로 강제하기 전에 `npm ci`, 전체 테스트와 installer 생성으로 호환성을 증명한다.
3. 아래 명령으로 취약 버전이 남지 않았는지 확인한다.

```powershell
npm ls brace-expansion tar --all
npm audit --audit-level=moderate
osv-scanner scan source -r .
```

4. 이어서 `npm run check`, `npm test`, `npm run test:e2e`, `npm run dist:win`을 모두 다시 실행한다.

아래에 적은 알려진 취약 버전이 모두 사라지고 MODERATE/HIGH/CRITICAL 결과가 0이 되기 전에는 브랜치를 `main`에 병합하지 않는다.

## Windows 11 완료 조건

다음 항목이 모두 통과해야 Windows 작업을 완료로 본다.

- `npm run check`, `npm test`, `npm run test:e2e` 전부 성공
- `npm audit --audit-level=moderate`와 OSV 검사에서 MODERATE/HIGH/CRITICAL 0건
- `npm run dist:win`으로 x64 installer 생성
- 새 설치 후 첫 실행 성공
- 유효한 암호화 캐시가 있으면 네트워크 응답 전 대시보드가 즉시 표시됨
- relay URL 또는 token이 바뀌면 이전 계정 캐시가 표시되지 않음
- 손상·과대·미래 시각 캐시가 표시되지 않고 안전하게 삭제됨
- 오프라인 시작 후 재연결하면 WebSocket 이벤트와 authoritative snapshot으로 최신 상태가 반영됨
- 주기 polling 없음
- 640px 및 100/125/150/200/400% 확대에서 수평 overflow와 잘린 동작 버튼 없음
- keyboard-only 탐색, focus 표시, forced colors, reduced motion 통과
- 설치, 기존 버전 위 업데이트, 제거, 재설치 통과
- 제거 시 사용자 선택 없이 다른 KLMS 데이터나 Mac/iOS 상태를 삭제하지 않음
- 로그와 screenshot에 token, 개인 경로, KLMS URL, 사용자 데이터가 남지 않음

## 병합 전 제출할 증거

- 전체 명령의 종료 코드와 테스트 개수
- 실제 Windows 11 버전과 Electron/Node 버전
- 640px 및 확대율별 안전한 fixture screenshot
- WebSocket 변경 반영 latency와 polling 0 증거
- installer 설치·업데이트·제거·재설치 결과
- 발견된 결함과 수정 커밋
- 최종 브랜치 전체 SHA
