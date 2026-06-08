# Repository Layout

이 문서는 레포를 처음 보는 사람이 파일 위치와 책임 범위를 빠르게 파악할 수 있도록 유지한다.

## Top-Level Files

루트에는 사용자가 직접 실행하거나 GitHub에서 바로 확인해야 하는 파일만 둔다.

| 경로 | 역할 |
| --- | --- |
| `README.md` | 빠른 시작, entrypoint 요약, 상세 문서 링크 |
| `LICENSE`, `SECURITY.md`, `THIRD_PARTY_NOTICES.md` | 공개 레포 기본 문서 |
| `install_launch_agent.sh` | 자동 실행용 설치 entrypoint |
| `sync_klms_core.sh` 등 root `.sh` | 사용자용 wrapper. 실제 구현은 `bin/`에 위임 |

root wrapper는 아래 형태를 유지한다.

```sh
#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec /bin/zsh "$SCRIPT_DIR/bin/<script>.sh" "$@"
```

이 구조 덕분에 기존 사용자는 루트 명령을 그대로 쓰고, 내부 구현 파일은 `bin/` 아래에서 정리할 수 있다.

## Source Directories

| 경로 | 역할 |
| --- | --- |
| `apps/KLMSync/` | SwiftUI macOS 메뉴바 앱, iPhone/iPad companion, 공유 앱 모델/테스트 |
| `bin/` | 루트 wrapper가 호출하는 실제 shell entrypoint |
| `src/sh/` | 공통 shell helper, launchd worker, runtime cleanup |
| `src/js/` | Safari/JXA 자동화, Notes/Reminders runner, Kaikey CLI |
| `src/python/` | KLMS HTML 파서, 증분 fetch backend, 파일 manifest/prune |
| `src/swift/` | Calendar 동기화/검증, QR decode, native Notes renderer |
| `tests/` | 파서, manifest, 파일 정리, 공지 렌더, shell entrypoint 테스트 |
| `examples/` | 공개 가능한 설정과 manual override 예시 |
| `docs/` | 상세 운영 문서와 공개 전 체크리스트 |
| `tools/` | 로컬 앱 번들 빌드 같은 개발/배포 보조 스크립트 |

## Runtime And Private Data

아래 경로는 로컬 실행 산출물이므로 tracked source가 아니다.

| 경로 | 내용 |
| --- | --- |
| `config.env` | 개인 실행 설정 |
| `manual_assignment_overrides.json` | 과제/시험 수동 override |
| `runtime/` | cache, state, logs, tmp, telemetry |
| `course_files/` | 레포에서 예전 CLI 실행으로 생길 수 있는 로컬 파일 정리본. 앱 기준 canonical 위치는 `~/Library/Application Support/KLMSNotesSync/course_files` |
| `course_transcripts/`, `course_videos/` | 강의 자료 수집 산출물 |
| `~/Library/Application Support/KLMSNotesSync` | LaunchAgent 설치본, 인증 state, 자동 실행 runtime |

앱과 자동 실행의 파일 정리본은 `~/Library/Application Support/KLMSNotesSync/course_files` 하나를 canonical로 쓴다.
레포 안의 `course_files/`는 이전 source checkout 실행 산출물이라 앱 데이터가 정상이라면 정리해도 된다.

`runtime/cache/*/stage_timings.json`에는 stage별 소요 시간과 병목 후보가 남는다. 레포에서 실행한
`verify_sync_state.sh`, `doctor.sh`, `sync_report.sh`는 기본적으로 앱 설치본 runtime을 확인한다.
레포 내부 runtime을 보려면 `--source`를 붙인다.

## Installed Copy

`install_launch_agent.sh`는 root wrapper, `bin/`, `src/`, `examples/` 일부와 launchd worker를 `~/Library/Application Support/KLMSNotesSync`로 복사한다. 자동 실행은 Documents 폴더 보호와 작업 디렉터리 변동을 피하기 위해 이 설치본을 기준으로 돈다.

`tools/build_klms_mac_app.sh`는 기본적으로 `~/Applications/KLMS Sync.app`을 만들고 현재 레포의 code payload를 앱 리소스에 주입한다. `DIST_DIR`로 다른 출력 위치를 지정할 수 있지만, `Documents`/iCloud-backed 폴더는 File Provider 메타데이터 때문에 codesign이 실패할 수 있다. 앱 installer도 같은 설치본 위치를 쓰며 `config.env`, `manual_assignment_overrides.json`, `runtime/`, `course_files/`, `kaikey_state.json`은 덮어쓰지 않는다.

설정을 바꾸거나 entrypoint 구현을 수정한 뒤 자동 실행에도 반영하려면 다시 실행한다.

```sh
./install_launch_agent.sh
```
