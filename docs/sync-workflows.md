# Sync Workflows

## 준비

1. `examples/config.env.example`를 `config.env`로 복사한다.
2. Safari에서 `https://klms.kaist.ac.kr/my/`에 로그인한다.
3. 첫 실행 때 macOS 자동화 권한을 허용한다.

```sh
cp examples/config.env.example config.env
./sync_klms_core.sh
```

## 실행 흐름

| 명령 | 흐름 |
| --- | --- |
| `./sync_klms_core.sh` | dashboard/course/detail 수집 후 Reminders, Calendar, 과제 메모 갱신 |
| `./sync_klms_notice.sh` | Notice 게시판 수집 후 native Notes 공지 메모 렌더 |
| `./refresh_course_files.sh` | 파일 manifest 생성, 다운로드, `course_files` prune, 로컬 staging 정리 |
| `./run_all.sh` | `core -> notice` 직렬 실행 |
| `./run_all_full.sh` | `core -> notice -> files` 직렬 실행 |

자동 sync entrypoint는 성공 후 `runtime/tmp`를 정리한다. 실패한 실행의 tmp는 디버깅을 위해 보존한다. `KLMS_RUNTIME_TMP_CLEANUP_ENABLED=0`으로 끄거나 `KLMS_RUNTIME_TMP_MAX_AGE_HOURS`로 보존 시간을 바꿀 수 있다.

각 entrypoint는 작업별 lock을 쓴다. 기본 경로는 `~/Library/Application Support/KLMSNotesSync/runtime/automation/{core,notice,files,all}.lock`이고, 쓰기 불가 환경에서는 repo 내부 fallback lock으로 내려간다.

## 모드와 캐시

`SYNC_MODE`와 `FILE_REFRESH_MODE`는 각각 `quick`, `full`, `auto`를 지원한다.

| 모드 | 의미 |
| --- | --- |
| `full` | 대상 URL을 전부 다시 읽는다 |
| `quick` | 새 URL, stale URL, 항상 확인해야 하는 URL 위주로 읽고 나머지는 cache를 재사용 |
| `auto` | cache coverage와 마지막 full 시각을 참고해 quick/full을 선택 |

기본값은 최소 탐색을 우선한다.

- `SYNC_MINIMAL_EXPLORATION_ENABLED=1`
- `FILE_MINIMAL_EXPLORATION_ENABLED=1`
- `FILE_TIMESTAMP_GATED_SEED_REFRESH_ENABLED=1`
- `FETCH_AUTO_FULL_MIN_COVERAGE=0.2`
- `FETCH_AUTO_REQUIRE_LAST_FULL=0`
- `FETCH_AUTO_FULL_ON_TTL_EXPIRE=0`

파일 sync는 파일 seed URL 목록이 unchanged이고 기존 manifest가 `course_files`와 맞으면 seed 상세 페이지의 TTL을 `FILE_SEED_UNCHANGED_COURSE_STALE_SECONDS`까지 늘린다. 이때도 resource/assignment index URL은 `FILE_ALWAYS_FETCH_MIN_INTERVAL_SECONDS` 주기로 확인하므로, KLMS에서 같은 이름 파일이 교체되어 timestamp가 바뀌면 해당 파일만 다시 받는다.

`KLMS_SAFARI_BACKGROUND_WINDOW_ENABLED=1`이면 Safari는 쿠키 세션과 `do JavaScript`를 위해 최소한의 탭만 만들고, 동기화용 창은 최소화한 상태로 사용한다. 로그인 보조도 같은 창에서 인증 번호만 긁어오므로 Safari가 전면에 떠 있을 필요가 없다.
`KLMS_LOGIN_STATUS_REUSE_SECONDS=900`이면 최근 로그인 preflight 성공 후 15분 안의 후속 실행은 dashboard 재확인을 생략한다. Safari 탭이 명확히 로그인 화면이면 이 cache를 쓰지 않고 로그인 보조로 넘어간다.

Safari 수집은 `FETCH_MIN_WAIT_SECONDS`, `FETCH_STABLE_POLLS`를 써서 DOM이 빨리 안정화되면 고정 대기 시간을 끝까지 쓰지 않고 다음 페이지로 넘어간다.
Safari XHR batch 상한은 20개라 fetch backend도 기본 batch를 20개로 맞춰, 대상 URL이 늘어도 페이지 이동 반복으로 떨어지지 않게 한다. 필요하면 `KLMS_FETCH_SAFARI_BATCH_SIZE`로 조정한다.

## 로그인 보조와 Kaikey

세 entrypoint는 실행 전에 공통 로그인 preflight를 거친다. Safari의 현재 KLMS 탭이 로그인 페이지면 로그인 보조가 켜져 있을 때 SSO 버튼 클릭, KAIST ID 제출, 2FA 번호 표시까지 자동으로 진행한다. 휴대폰에서 같은 번호를 선택해 승인이 끝나면 dashboard를 다시 확인하고 동기화를 이어간다.

수동 승인만 쓰려면 아래 설정을 둔다.

```sh
KLMS_LOGIN_ASSIST_ENABLED="1"
KLMS_LOGIN_ASSIST_EARLY_ENABLED="1"
KLMS_LOGIN_ASSIST_MODE="manual-digits"
KLMS_LOGIN_ASSIST_ALLOW_NONINTERACTIVE="1"
KLMS_LOGIN_ASSIST_NOTIFY_DIGITS_ENABLED="1"
KLMS_SSO_LOGIN_ID="your-kaist-id"
KAIKEY_AUTO_LOGIN_ENABLED="0"
KAIKEY_AUTO_APPROVE_ENABLED="0"
KAIKEY_MANUAL_APPROVAL_TIMEOUT_SECONDS="300"
KAIKEY_AUTO_LOGIN_POLL_SECONDS="0.2"
KAIKEY_SAFARI_STEP_TIMEOUT_SECONDS="12"
KAIKEY_SAFARI_STEP_POLL_MS="75"
KLMS_LOGIN_ASSIST_TWOFACTOR_REFRESH_SECONDS="150"
```

이 설정에서는 Mac이 인증 기기처럼 동작하지 않는다. Safari 2FA 화면에 표시된 값을 터미널에 `KAIST 인증 번호: NN` 형태로 보여주고, 사용자가 휴대폰 KAIST 인증 화면에서 같은 번호를 선택할 때까지 기다린다. `KLMS_LOGIN_ASSIST_EARLY_ENABLED=1`이면 KLMS 탭 상태가 애매할 때 dashboard preflight를 기다리지 않고 먼저 SSO 화면으로 진행해 번호를 더 빨리 보여준다. 번호가 오래 유지되면 `시간 연장`을 눌러 새 인증 요청을 만든다. `KLMS_LOGIN_ASSIST_NOTIFY_DIGITS_ENABLED=1`이면 LaunchAgent 같은 비대화 실행에서도 번호 알림을 띄운다. `KAIKEY_LOGIN_ASSIST_ENABLED`는 기존 설정 호환용이고 새 설정은 `KLMS_LOGIN_ASSIST_ENABLED`를 우선한다.

Mac 자동 인증을 쓰려면 처음 한 번 QR 스크린샷으로 로컬 기기를 등록한다.

```sh
KLMS_LOGIN_ASSIST_MODE="kaikey-auto"
./kaikey_setup.sh --qr-image /path/to/qr-screenshot.png
node ./src/js/kaikey_cli.mjs status
```

기본 기기키 저장 위치는 `~/Library/Application Support/KLMSNotesSync/kaikey_state.json`이고 권한은 `0600`으로 맞춘다. 경로를 바꾸려면 `KAIKEY_STATE_PATH`를 설정한다.

iPhone에서 Mac 승인을 호출할 때는 공개 HTTP endpoint를 만들지 말고 SSH, 로컬 네트워크, VPN처럼 접근 제어가 있는 경로만 사용한다.

```sh
cd ~/Library/Application\ Support/KLMSNotesSync
./kaikey_approve_number.sh "$SHORTCUT_INPUT"
```

## 검증과 병목 확인

실제 상태 검증:

```sh
./verify_sync_state.sh
./verify_sync_state.sh --json
./doctor.sh
./sync_report.sh
```

이 세 검증성 명령은 레포 checkout에서 실행해도 기본적으로 앱 설치본
`~/Library/Application Support/KLMSNotesSync`의 runtime을 본다. 레포 내부 `runtime/`을 비교해야 할 때만
`--source`를 붙이고, 임의 data root는 `--data-dir=/path/to/KLMSNotesSync`로 지정한다.

이 검증은 다음을 함께 확인한다.

- `notice_digest.json`의 공지 URL이 Notes render state에 반영됐는지
- file manifest의 `absolute_path`가 실제 파일로 존재하는지
- state의 시험/헬프데스크 수와 Apple Calendar의 `[KLMS 시험]`, `[KLMS 헬프데스크]` 이벤트 수가 맞는지
- 예전 `KLMS 과제`, `KLMS 알림` 캘린더가 남아 있는지

병목 후보는 `runtime/cache/{core,notice,files}/stage_timings.json`의 `slowest_stages`, `slowest_events`를 본다. `SYNC_COMMAND_TIMING_ENABLED=1`이면 하위 명령의 시작/종료/소요 시간도 `events`에 남는다.

변경 예정 사항만 보고 싶으면 각 entrypoint에 `--dry-run`을 붙인다. dry-run은 side effect를 건너뛰고 `runtime/cache/<scope>/dry_run_report.json`에 요약을 남긴다.
