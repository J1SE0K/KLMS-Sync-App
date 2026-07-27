# KLMS Sync Apple 릴리스 마감 설계

## 목표

Windows 구현은 별도 handoff 범위로 유지한다. 이 작업은 macOS, iPhone, iPad,
공통 동기화 엔진과 릴리스 증거에서 남은 P1/P2를 닫고, 정확한 후보 커밋으로
최신 Mac 앱 하나만 설치한 뒤 `main`을 원격에 게시한다.

다음 원칙은 작업 전체에 적용한다.

- 실제 KLMS 데이터, 기존 앱 로그, 기존 TCC 권한과 Keychain 연결 정보는 테스트
  입력으로 사용하거나 초기화하지 않는다.
- 권한, 로그 삭제, 긴 공지·과제와 WebSocket 상태 전이는 별도 QA 앱/프로필,
  안전한 샘플 데이터와 격리된 로컬 relay에서 검증한다.
- 실패한 검사나 실행하지 못한 외부 검사는 통과로 기록하지 않는다.
- Windows 소스와 lockfile은 수정하지 않는다.

## 작업 묶음

### 1. 보안 증거 무결성

`verify_security_reports.mjs`는 Semgrep의 top-level 오류뿐 아니라
`time.fixpoint_timeouts`도 비어 있어야 통과한다. verifier 테스트는 정상 보고서,
top-level 오류, fixpoint timeout을 각각 구분해 검증한다.

`prune_backup_retention.py`의 `0700`은 권한을 약화하지 않고 명시적인 false-positive
adjudication으로 기록한다. 새 Semgrep 결과의 finding 수와 정규화 좌표 digest를
후보 소스에서 다시 계산해 정책에 고정한다.

Windows 개발 의존성 결과는 Apple 통과로 위장하지 않는다. Apple/common 보안
검사는 별도 결과로 남기고 저장소 전체 보안 결과에는 Windows 차단을 그대로 표시한다.

### 2. 데이터 일관성 회귀

iOS 연결 저장은 저장 완료 뒤에도 해당 generation이 최신인지 확인한 요청만
in-memory URL/token을 commit한다. 먼저 시작한 저장을 지연한 상태에서 두 번째
저장을 시작하는 결정적 동시성 테스트를 추가하고, Keychain에 남은 값과 모델의
최종 값이 모두 두 번째 요청인지 확인한다.

Calendar dry-run은 source 문자열 검사가 아니라 실행 가능한 side-effect seam을
통해 검증한다. fake Calendar bridge와 hash writer를 주입한 테스트에서 dry-run의
bridge 호출, desired-hash 쓰기와 state commit이 모두 0회임을 확인한다. 정상
실행 테스트도 함께 두어 테스트가 항상 0회만 기대하는 오류를 막는다.

### 3. 격리된 Mac·iOS 상태 전이 증거

후보 앱과 같은 소스에서 별도 QA 프로필을 만들고 다음 시나리오를 실행한다.

- 인증된 로컬 WebSocket relay 변경 전/후 대시보드가 polling 없이 갱신되고
  commit-to-visible p95가 1초 이내인지 측정한다.
- QA bundle의 최초 권한 실행과 두 번째 실행을 비교해 두 번째 실행에서 동일
  요청이 반복되지 않음을 기록한다. production bundle의 TCC는 건드리지 않는다.
- populated 샘플 로그에서 전체 지우기, 확인, 삭제 완료를 순서대로 기록한다.
- 긴 한글·Unicode 공지와 과제 상세, 작업 메뉴와 액션을 640/900/1200pt에서
  열고 가로 이탈이 없는지 확인한다.
- 모든 좁은 단일 열 화면을 최하단까지 스크롤해 마지막 컨트롤의 도달성과
  44pt hit target을 확인한다.
- iPhone/iPad에서 회전, Dynamic Type, 다크 모드, 키보드 탐색, VoiceOver용
  접근성 트리, WebSocket 재연결과 최신 revision 보존을 확인한다.
- 격리 relay를 중단·재시작하고 지연·손실을 주입해 offline 표시, backoff,
  gap recovery와 stale-response 차단을 검증한다.

각 증거에는 후보 SHA, 앱 provenance, 실행 명령, 시작·종료 시각, 환경, 원시
결과 digest를 넣는다. 개인 제목, token, cookie와 기기 식별자는 저장하지 않는다.

## 검증 순서

각 변경은 실패하는 회귀 테스트, 최소 수정, focused test, 전체 test 순서로
진행한다. 코드 변경 뒤에는 다음을 정확한 후보 SHA에서 실행한다.

1. Python/core 전체 테스트
2. Swift package 전체 테스트
3. self-hosted와 Cloudflare relay 테스트
4. Apple/common 보안 검사와 scanner verifier
5. Mac payload/provenance/runtime 검사
6. iPhone/iPad 시뮬레이터 전체 matrix
7. 격리된 상태 전이·접근성·네트워크·지속 실행 검사
8. fresh 전체 화면 캡처에 대한 독립 기능/시각 검토

물리 iPhone/iPad, 실제 WAN과 8시간 soak는 해당 장치·외부 환경이 실제로
제공된 경우에만 `pass`로 기록한다. 제공되지 않으면 `INCONCLUSIVE`로 남기며
100점을 선언하지 않는다.

## 완료 조건

- Windows를 제외한 새 P0/P1/P2가 0건이다.
- 자동 게이트와 격리 상태 전이 검사가 모두 통과한다.
- Mac 앱은 canonical 위치에 정확히 하나만 있고 후보 SHA·source tree·서명이
  일치하며 프로세스도 하나만 실행된다.
- fresh 증거에 대한 독립 기능·보안·시각 검토가 승인된다.
- 물리 장치·실제 WAN·8시간 soak가 제공되면 외부 증거까지 포함한 receipt를
  생성한다. 제공되지 않으면 Apple 제품 완료와 외부 인증 미완료를 구분한다.
- 검증된 커밋을 `origin/main`에 push하고 원격 SHA를 다시 확인한다.
