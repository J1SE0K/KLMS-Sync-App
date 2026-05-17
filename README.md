# KAIST KLMS Sync

Safari에 로그인된 KAIST KLMS 세션을 재사용해서 과제, 시험 일정, 공지, 첨부파일을 macOS 기본 앱과 로컬 폴더로 정리하는 개인용 도구다.

주요 기능은 세 가지다.

1. `KLMS 동기화`: 과제/시험 상태를 읽어 Reminders, Calendar를 갱신
2. `공지 정리`: `Notice` 게시판 글을 `KLMS 공지`, `KLMS 확인한 공지` 메모로 정리
3. `파일 정리`: 첨부파일을 과목별 `course_files` 폴더로 수집/정리

이 프로젝트는 KAIST 또는 KLMS의 공식 도구가 아니다. 개인 Safari 세션, macOS 자동화 권한, Apple Reminders/Calendar/Notes 권한을 사용하므로 본인 계정에서만 실행해야 한다.

## 빠른 시작

```sh
cp examples/config.env.example config.env
./sync_klms_core.sh
```

필수 준비:

- Safari에서 `https://klms.kaist.ac.kr/my/`에 로그인되어 있어야 한다.
- 첫 실행 때 macOS가 Safari / Reminders / Calendar / Notes 자동화 권한을 물으면 허용한다.
- 실제 설정, 인증 state, 수업 파일은 커밋하지 않는다. 자세한 공개 전 점검은 [publication-checklist.md](./docs/publication-checklist.md)를 따른다.

## macOS 앱

SwiftUI 메뉴바 앱은 [apps/KLMSync](./apps/KLMSync)에 있다. 앱은 기존 sync 엔진을 `~/Library/Application Support/KLMSNotesSync`에 설치하고, 동기화 실행, dry-run preview, 상태/로그 표시, 설정 편집, LaunchAgent 자동 실행 관리를 맡는다.

```sh
cd apps/KLMSync
swift test --scratch-path /private/tmp/klmsync-swiftpm-build --jobs 1
swift run --scratch-path /private/tmp/klmsync-swiftpm-build KLMSMac
```

로컬 `.app` 번들은 레포 루트에서 아래 명령으로 만든다.

```sh
tools/build_klms_mac_app.sh
```

빌드 결과는 기본적으로 `~/Applications/KLMS Sync.app`에 생성된다. 이 번들은 현재 레포의 엔진 코드를 앱 리소스 `EnginePayload`로 포함하고, 실행 시 설치본의 `config.env`, `manual_assignment_overrides.json`, `runtime/`, `course_files/`, `kaikey_state.json`은 덮어쓰지 않는다. `Documents`/iCloud-backed 폴더 안에서는 macOS File Provider 메타데이터 때문에 ad-hoc codesign이 실패할 수 있어 앱 번들은 사용자 Applications 폴더에 둔다. 다른 위치가 필요하면 `DIST_DIR=/path/to/output tools/build_klms_mac_app.sh`처럼 지정한다.

iPhone companion 타깃은 같은 package의 `KLMSiOS`에 있고, CloudKit private database를 통한 원격 실행 요청/상태 표시 골격만 둔다. 실제 KLMS scraping과 macOS 앱 연동은 Mac 앱이 담당한다.

## 실행 파일

루트에는 사용자가 직접 실행하는 wrapper만 둔다. 실제 구현은 [bin](./bin) 아래에 있다.

| 명령 | 용도 |
| --- | --- |
| `./sync_klms_core.sh` | 과제, 시험, Reminders, Calendar 동기화 |
| `./sync_klms_notice.sh` | 공지 메모만 갱신 |
| `./refresh_course_files.sh` | 첨부파일 manifest 생성, 다운로드, prune |
| `./run_all.sh` | `core + notice` 직렬 실행 |
| `./run_all_full.sh` | `core + notice + files` 직렬 실행 |
| `./run_all_parallel.sh` | 로그인 preflight 뒤 세 작업 병렬 실행 |
| `./sync_klms_all.sh` | 대화형/generic sync wrapper |
| `./verify_sync_state.sh` | 공지, 파일, 캘린더 상태 검증 |
| `./doctor.sh` | 실행 환경, 권한, cache/file 상태 점검 |
| `./sync_report.sh` | 마지막 실행 결과와 병목 요약 |
| `./process_klms_assignments.sh` | 최신 동기화 상태로 로컬 과제 브리프/체크리스트 생성 |
| `./install_launch_agent.sh` | 자동 실행용 LaunchAgent 설치 |
| `./kaikey_setup.sh` | Kaikey 기기키 등록 |
| `./kaikey_auto_login.sh` | Safari SSO 로그인 보조 및 2FA 번호 표시 |
| `./kaikey_approve_number.sh` | 수동 2자리 번호 승인 helper |

## 레포 구조

```text
.
├── bin/          # 루트 wrapper가 호출하는 실제 shell entrypoint 구현
├── apps/         # SwiftUI macOS 메뉴바 앱과 iPhone companion package
├── docs/         # 사용법, 동작 정책, 공개 전 점검 문서
├── examples/     # 공개 가능한 설정/override 예시
├── legacy/       # 호환 wrapper와 수동 디버깅용 보조 스크립트
├── src/
│   ├── js/       # Safari/JXA 자동화, Reminders/Notes runner, Kaikey CLI
│   ├── python/   # KLMS HTML 파서, fetch backend, 파일 manifest/prune 도구
│   ├── sh/       # 공통 shell helper, launchd worker, tmp cleanup
│   └── swift/    # Calendar 동기화/검증, QR decode, native Notes renderer
└── tests/        # manifest, 파일 정리, 공지 렌더, 캘린더 정책 테스트
```

상세 구조와 설치본 배치는 [repository-layout.md](./docs/repository-layout.md)에 정리한다.

## 과제 작업 브리프

이 기능은 자동 동기화에 포함되지 않는다. 사용자가 직접 실행할 때만 최신 `runtime/state/state.json`을 읽어서 `runtime/assignment_work/` 아래에 과제별 작업 파일을 만든다.

```sh
./process_klms_assignments.sh
```

번호 목록에서 과제를 고르려면 아래처럼 실행한다.

```sh
./process_klms_assignments.sh --select
```

각 과제 폴더에는 `assignment.json`, `brief.md`, `checklist.md`, `draft_template.md`, `codex_prompt.md`, `codex_result.json`, `status.json`이 생긴다. `ASSIGNMENT_GENERATION_PROVIDER=codex`이면 로컬 Codex CLI를 호출하고, 실패하거나 `deterministic`으로 설정하면 규칙 기반 템플릿으로 폴백한다.

이 기능은 작성 보조용이다. KLMS 제출 페이지를 열거나, 제출물을 자동 완성하거나, 퀴즈/시험 답안을 풀이하지 않는다. 특정 과제만 다시 만들려면 아래처럼 실행한다.

```sh
./process_klms_assignments.sh --assignment-url="https://klms.kaist.ac.kr/..." --force
```

## 상세 문서

- [docs/README.md](./docs/README.md): 상세 문서 목차
- [sync-workflows.md](./docs/sync-workflows.md): 실행 모드, 로그인 보조/Kaikey, 자동 실행, 검증 절차
- [feature-behavior.md](./docs/feature-behavior.md): 공지 메모, 파일 정리, Reminders/Calendar/Notes 동작 정책
- [repository-layout.md](./docs/repository-layout.md): 폴더 구조, wrapper/implementation 경계, ignored runtime 데이터
- [publication-checklist.md](./docs/publication-checklist.md): 공개 레포로 push하기 전 보안/검증 체크리스트

## 검증

```sh
python3 -B -m unittest discover -s tests
zsh -n *.sh bin/*.sh src/sh/*.sh
node --check src/js/kaikey_cli.mjs
node --check src/js/sync_klms_notes.js
node --check src/js/download_klms_files.js
node --check legacy/export_panopto_transcripts.js
```

실제 상태 검증은 아래 한 번으로 공지 렌더 누락, 파일 manifest 누락, 캘린더 개수를 함께 확인한다.

```sh
./verify_sync_state.sh
./verify_sync_state.sh --json
./doctor.sh
./sync_report.sh
```

## 보안

퍼블릭 레포에는 `config.env`, `manual_assignment_overrides.json`, `kaikey_state.json`, `runtime/`, `course_files/`, QR 스크린샷, 쿠키, 다운로드 파일을 올리지 않는다. 이 레포에는 예시 설정과 코드만 보관하고, 실제 인증 상태와 수업 데이터는 `.gitignore` 대상 또는 `~/Library/Application Support/KLMSNotesSync` 아래에 둔다.

Kaikey 자동 인증을 켜면 Mac에 저장되는 기기키가 KAIST MFA 등록 기기처럼 동작한다. `kaikey_state.json` 유출이 의심되면 즉시 KAIST 인증 기기 등록을 해제/재등록하고, 기존 state 파일은 폐기한다. iPhone에서 Mac 승인을 호출할 때도 공개 HTTP endpoint를 만들지 말고 SSH, 로컬 네트워크, VPN처럼 접근 제어가 있는 경로만 사용한다.

라이선스는 [MIT](./LICENSE)이며, Kaikey 프로토콜 구현에서 참고한 외부 코드 고지는 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)에 둔다.
