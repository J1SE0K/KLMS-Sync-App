# KLMS-Sync-App Development Storytelling — 발표 원고

Neukbao 프로토타입 2. 분석 대상: `J1SE0K/KLMS-Sync-App`, HEAD `67e2f63e12ccf9808949cd8a7290e30d6ab30416`, commit 1184개 (2026-05-06 ~ 2026-08-27).

---

## 1. 다루는 문제점

### 문제 의식

저장소를 처음 여는 개발자가 알고 싶은 것은 "무슨 순서로, 왜 이렇게 됐는가"다. 그런데 Git이 주는 것은 저장 단위인 commit의 나열이다.
commit은 개발자가 이해하기 좋은 사건 단위가 아니다.

### 구체적 문제 (KLMS-Sync-App 기준)

- commit이 1184개다. `git log`를 열면 어디부터 읽어야 할지 알 수 없다.
- 6월 14일부터 24일까지 열흘 동안 718개 commit이 있다. 전체의 60%가 "responsive", "immediate", "cache", "defer" 같은 subject를 반복한다. 한 줄씩 읽으면 큰 그림이 보이지 않는다.
- 하나의 기능이 여러 commit에 걸쳐 있다. 예를 들어 원격 제어 채널은 CloudKit entitlement(5/25) → 로컬 Wi-Fi 서버(5/26) → SQLite relay(5/31) → Cloudflare Worker(6/1) → WebSocket(6/7)로 다섯 번 바뀌었다. commit 목록에서 이 흐름을 재조립하는 것은 읽는 사람의 몫이다.
- 현재 README는 완성된 구조만 설명한다. macOS 앱이 CLI보다 11일 뒤에 생겼다는 사실, Kaikey 자동 로그인이 7월 3일 삭제됐다는 사실은 README에 없다.
- fix, style, perf, security, docs가 시간순으로 섞여 있다. 7월 13~17일은 설계 문서 9개 → fail-safe → CI → security 스캐너 순서인데, 목록만으로는 캠페인이라는 것을 알기 어렵다.
- tag 0개, PR 0개, issue 0개, commit body가 있는 commit 2개. 저장소가 주는 서사 단서가 거의 없다.

### Pain point

"commit message를 하나씩 읽어도 프로젝트의 큰 개발 흐름을 머릿속에서 다시 조립해야 한다."

---

## 2. 다루는 방식

### 왜 Storytelling인가

사람은 사건의 연쇄로 기억한다. "문제가 있었고, 이렇게 바꿨고, 그 결과 지금 이렇게 남았다"는 구조가 commit 목록보다 빨리 읽힌다.
단, 이야기는 과장되기 쉽다. 그래서 이 프로토타입은 **모든 문장에 Git 근거를 붙이고, 근거 등급을 눈에 보이게** 만든다.

### Git log / commit 목록과 무엇이 다른가

| Git log | Development Storytelling |
| --- | --- |
| 1184개 commit을 시간 역순으로 | 8개 Episode를 시간순으로 |
| subject 한 줄 | 문제/맥락 → 변경 → 현재 남은 결과 → 근거 → 확인 불가 정보 |
| 근거 등급 없음 | observed / supported / inferred 라벨 + confidence |
| 의도는 독자가 추측 | 의도는 "추정"으로만 표기, 한계 명시 |
| diff는 별도 명령 | evidence drawer에서 hash, 파일, diff excerpt, `git show` 명령 즉시 확인 |

### 왜 commit이 아닌 Episode인가

Episode는 "특정 기능·구조·플랫폼·문제를 도입·확장·수정·안정화한, 시간적으로 연속된 개발 사건"이다.
KLMS-Sync-App에서 "팔레트 실험 끝에 정리된 Paper Graphite 디자인"은 commit 80개다. 이 80개를 하나씩 읽는 것과
"이틀 동안 palette를 30번 넘게 바꾼 뒤 spec 문서와 함께 P4/D1 테마가 적용됐고, 그 값이 지금 DESIGN.md에 남아 있다"를 읽는 것은 다르다.

---

## 3. 기획

### 입력

- 저장소 root와 ref (기본 HEAD). `git` 명령만 사용.
- 읽지 않는 것: untracked/ignored 파일, `config.env`, `runtime/`, 사용자 로그, 인증 상태, 개인 KLMS 데이터, Application Support.
- API key, 외부 LLM 없음. Python 표준 라이브러리 + vanilla HTML/CSS/JS.

### Git 분석 과정

`git log --reverse --date-order --diff-merges=first-parent --numstat -M --name-status`로 commit별 hash, parent, author,
timestamp, subject, body, merge 여부, changed file(status, +/-), rename 후보, top-level scope, conventional commit prefix, tag,
first-parent 순서를 수집한다. `Revert "X"`는 X와 연결하고, merge commit은 side-branch commit에 `merged_by`를 붙인다.
출력마다 `source.head_commit`을 기록한다.

### Episode 생성 과정

1. **자동 clustering** — 인접 commit만 병합하는 결정적 알고리즘.
   `score = 0.40·path + 0.25·message + 0.15·subsystem + 0.10·type + 0.10·time`, threshold 0.35 (MVP 초기값, 연구 확정치 아님).
   강한 boundary: 7일 이상 간격, tag, merge, 새 플랫폼 디렉터리(`apps/`, `deploy/`, `integrations/`, `vendor/`) 최초 등장, 대규모 packaging 변경.
   결과: 61개 구간.
2. **수동 큐레이션** — `story.override.json`으로 구간을 합치거나 나누고, 제목·서사·claim을 쓴다.
   결과: 8개 Episode, 1184개 commit 전부 포함.
3. **validation** — 존재하지 않는 hash, Episode 밖 evidence, commit이 바꾸지 않은 파일, 시간 겹침, 한계 없는 inferred claim은 모두 거부한다. 자동 결과와 큐레이션 결과는 `curation` 필드로 구분된다.

### claim / evidence 모델

```
claim = { text, status: observed|supported|inferred, confidence, evidence_commit_ids[], evidence_files[], limitations, evidence_reason }
```

- observed: diff에서 직접 확인 (예: "3921dce는 apps/KLMSync/Package.swift를 추가했다")
- supported: subject/문서 + diff가 함께 뒷받침 (예: "'Harden server relay security'와 worker.mjs의 authorized() 추가가 일치")
- inferred: 관계에서 추론, 한계 필수 (예: "원격 채널을 여러 번 바꿔가며 찾은 것으로 추정된다. 각 전환의 이유는 기록에 없다")

큐레이션 claim 59개 중 observed 38, supported 13, inferred 8.

### UI 구조

제목/source commit → 전체 arc + 8개 arc point → timeline(이전/다음/재생/scrubber/진행 표시) → Episode 카드(문제 → 변경 → 결과 → 영역 → claim/근거 → 확인 불가) → evidence drawer → 전체 목록(정적) → 자동 clustering 결과 패널.
Paper Graphite palette, keep-all 한글 줄바꿈, 키보드 이동, reduced-motion 대응.

### 과장 방지 원칙

- 모든 Episode 문장은 commit/diff/changed file 근거를 가진다. validation이 강제한다.
- 개발자 의도는 "추정된다"로만 쓰고 `limitations`에 무엇을 모르는지 적는다.
- 각 Episode 카드에 "확인할 수 없는 정보" 블록을 둔다.
- README의 현재 설명을 과거 사실로 소급하지 않는다. 결과 문장은 "현재 HEAD에 남아 있다"처럼 파일 경로 존재로만 말한다.

### 검증 방법

build 실행, commits/story 생성, 25개 unit test(fixture repo + 실제 story.json), 정적 서버, headless 브라우저 콘솔 0건,
모든 hash 실존, 시간순 정렬, claim evidence 확인, override 없이 생성, 잘못된 override 거부, private 데이터 미포함. 상세는 README의 검증 표.

---

## 4. 계획

| 단계 | 상태 | 내용 |
| --- | --- | --- |
| Git extraction | 완료 | `collect_commits()` — first-parent 순서, numstat, rename, merge, revert, tag |
| automatic clustering | 완료 (MVP) | `cluster_commits()` — 가중치 초기값, 61 구간 |
| manual curation | 완료 | `story.override.json` — 8 Episode, 59 claim, validation |
| Storytelling UI | 완료 | `public/` — timeline, 카드, drawer, 정적 목록 |
| evidence validation | 완료 | hash 실존, Episode 내 evidence, 파일 실제 변경, inferred 한계 필수 |
| 사용자 평가 | 다음 | 아래 순서 |

사용자 평가 순서(제안):

1. 참가자 두 그룹. A는 `git log --oneline` + GitHub, B는 이 UI.
2. 과제: "macOS 앱은 언제 생겼나", "원격 제어 방식은 몇 번 바뀌었나", "Kaikey 로그인은 왜 없어졌나(모른다고 답해도 됨)", "7월 중순에 무슨 일이 있었나".
3. 측정: 정답률, 소요 시간, "근거를 확인했는가", inferred 항목을 사실로 오해했는지 여부.
4. 결과로 clustering 가중치와 Episode 크기를 조정한다.

---

## 5. 60초 데모 시나리오

`python3 -m http.server 4174 -d public` 후 `http://127.0.0.1:4174/`.

| 초 | 행동 | 화면에서 보이는 것 |
| --- | --- | --- |
| 0–10 | 상단 arc 읽기 | "파일 54개 → macOS 앱 → relay/Windows → Paper Graphite → 718 commit → hardening → 8월 유지보수". source commit `67e2f63`. |
| 10–20 | ▶ 재생 | Episode 1 카드. 진행 바가 10초 간격으로 차오르고 다음 Episode로 넘어간다. |
| 20–30 | ⏸ 정지, → 두 번 | Episode 3 "서버 relay, Windows companion, Cloudflare Worker". "당시의 문제"에 로컬 Wi-Fi 제약, "변경"에 SQLite relay·Electron·Worker. |
| 30–42 | claim ep03-c6의 `27098da` chip 클릭 | drawer: full hash, "Use websocket events for relay updates", 3 files +41/−67, diff excerpt에 `serverRelayPollingTask` 삭제 줄과 `configureServerRelayRealtime()` 추가 줄. `git show 27098da…` 명령. |
| 42–52 | Esc, 같은 카드의 inferred claim ep03-c9 보기 | 갈색 "inferred · 추정" 라벨. "같은 네트워크 제약을 벗어나기 위한 변경으로 추정된다." 한계: "commit message에 동기가 없다. 7월 3일 README diff에서야 로컬 원격을 'fallback'으로 부른다." |
| 52–60 | "전체 Episode 목록" 버튼 | 8개 Episode가 정적 목록으로. 재생 없이도 모든 내용을 읽을 수 있음을 보여주고 마무리. |

---

## 부록: 숫자

- 분석 commit 1184 (first-parent 1180 + side branch 4), merge 1, tag 0, author 2
- 자동 Episode 61 → 큐레이션 8
- claim 59 (observed 38 / supported 13 / inferred 8)
- 월별 commit: 5월 111, 6월 853, 7월 204, 8월 16
- 테스트 25 OK, 브라우저 콘솔 오류 0
