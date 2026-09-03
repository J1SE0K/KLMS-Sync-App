# Neukbao Storytelling Prototype — KLMS-Sync-App Development Storytelling

Neukbao 프로젝트의 두 번째 독립 프로토타입이다. KLMS-Sync-App의 Git history를 commit 목록으로 나열하는 대신,
이해 가능한 **Development Episode**와 **근거(claim/evidence) 모델**로 재구성해 보여준다.

이 디렉터리는 저장소의 다른 코드와 완전히 분리돼 있다. Visual Diagram 프로토타입과 코드를 공유하지 않으며,
dependency graph·architecture map·semantic zoom graph를 구현하지 않는다.

연구 질문:

> Development Storytelling을 사용하면 처음 보는 개발자가 Git log를 직접 읽을 때보다
> KLMS-Sync-App의 주요 개발 단계와 변화 이유를 빠르게 이해할 수 있는가?

## 구성

```
experiments/neukbao-storytelling/
├── README.md               ← 이 문서
├── PRESENTATION.md         ← 발표용 원고
├── build_story.py          ← Git history → commits.json + story.json (표준 라이브러리만 사용)
├── story.override.json     ← 발표용 수동 큐레이션 (8개 Episode)
├── tests/test_build_story.py
├── docs/screenshots/       ← 브라우저 검증 스크린샷
└── public/
    ├── index.html, app.js, styles.css   ← 정적 웹 UI (외부 CDN 없음)
    ├── commits.json                     ← 분석된 commit 1184개
    └── story.json                       ← Episode, claim, evidence excerpt
```

## 실행

```sh
cd experiments/neukbao-storytelling

# 1. Git history 분석 → JSON 생성 (story.override.json이 있으면 자동 적용)
python3 build_story.py \
  --repo ../.. \
  --ref HEAD \
  --commits-output public/commits.json \
  --story-output public/story.json

# override 없이 자동 clustering 결과만 보려면
python3 build_story.py --repo ../.. --no-override \
  --commits-output public/commits.json --story-output public/story.json

# 2. 테스트
python3 -B -m unittest discover -s tests -v

# 3. 정적 서버
python3 -m http.server 4174 -d public
# → http://127.0.0.1:4174/
```

요구사항: Python 3.10 이상, `git` 명령. Node, npm, API key, 외부 LLM 모두 필요 없다.

## build_story.py가 하는 일

### 1. Git extraction (읽기 전용)

`git log --reverse --date-order --diff-merges=first-parent --numstat -M` 과 `--name-status`로 다음을 수집한다.

- full/short hash, parent hash, author, authored/committed timestamp, subject, body
- merge 여부, merge된 side-branch commit의 `merged_by`
- changed file(status A/M/D/R, additions/deletions, binary 여부), rename 후보
- top-level scope(`apps/KLMSync`, `src/python` 등), subsystem(`apple-app`, `relay`, `sync-engine` 등)
- conventional commit prefix(`feat`, `fix`, `style(ios)` …)와 동사 기반 정규화 type
- tag, first-parent 순서, `Revert "..."` 관계, 새 top-level 디렉터리 최초 등장, 대규모 packaging 변경

입력은 **Git object에 기록된 데이터만** 쓴다. working tree, untracked/ignored 파일, `config.env`, `runtime/`,
사용자 로그, 인증 상태, Application Support 데이터는 읽지 않는다. `evidence_excerpts`는 `git show <hash> -- <path>`의
앞 40줄이며, 역시 commit된 내용만 포함된다.

모든 출력에 `source.head_commit`(분석 시점의 HEAD)이 기록된다.

### 2. 자동 Episode 추출 (deterministic chronological clustering)

인접한 commit만 병합하는 결정적 clustering이다. 이전 cluster의 최근 8개 commit과 다음 commit 사이 유사도를 계산한다.

```
score = 0.40 × path overlap        (파일 경로, 없으면 2단계 디렉터리 overlap × 0.6)
      + 0.25 × message token overlap (subject에서 stopword 제거)
      + 0.15 × subsystem similarity
      + 0.10 × commit type similarity
      + 0.10 × temporal proximity   (1시간 이내 1.0, 48시간 이상 0.0)
threshold = 0.35
```

**이 가중치와 threshold는 연구적으로 확정된 값이 아니라 MVP 초기값이다.** story.json의 `clustering` 필드에도 같은 사실을 기록한다.

강한 boundary(유사도와 무관하게 새 Episode 시작):

- 7일 이상 시간 간격
- 이전 commit에 tag
- 이전 commit이 merge commit
- `apps/`, `deploy/`, `integrations/`, `vendor/` 아래 새 디렉터리 최초 등장 (새 플랫폼/앱)
- lockfile/Package.swift/pbxproj/vendor를 1000줄 이상 바꾸는 packaging 변경

같은 Episode로 강제 병합:

- merge commit과 그 side-branch commit
- `Revert "X"` commit과 되돌려진 X

크기 1인 cluster는 hard boundary가 없는 인접 cluster 중 더 유사한 쪽에 합쳐진다.

각 자동 Episode에는 diff에서 직접 확인되는 claim(새 파일 추가, 반복 수정 파일, revert)과
subject 토큰·경로 매칭 claim(supported), 반복 fix 추정 claim(inferred)이 자동으로 붙는다.

KLMS-Sync-App HEAD `67e2f63`에서 자동 clustering은 1184개 commit을 **61개 구간**으로 나눈다.
가장 큰 구간은 6월 18~22일의 227개, 가장 작은 구간은 1개다. 이 결과는 UI 하단
"자동 clustering 결과" 패널과 `story.json.auto_episodes`에서 볼 수 있다.

### 3. 수동 큐레이션 (story.override.json)

자동 결과는 발표에 쓰기엔 너무 잘게 쪼개지거나(6월 중순), 큰 전환점을 놓친다(예: 5월 17일 앱 도입 commit이 하나짜리 구간).
`story.override.json`은 다음을 할 수 있다.

| 작업 | 방법 |
| --- | --- |
| Episode 합치기/나누기 | `commit_range: {from, to}` (first-parent 구간, side-branch 자동 포함) 또는 `auto_episode_ids` 또는 `commit_ids` |
| 잘못 포함된 commit 제외 | `exclude_commit_ids` |
| 제목·요약·문제·변경·결과 수정 | 해당 필드 |
| claim 추가 / status·confidence 조정 / evidence 추가 | `claims[]`, 또는 `auto_patches.<auto-id>.claims.<claim-id>` |
| 자동 Episode만 부분 수정 | `auto_patches` |

validation 규칙(위반 시 exit code 2, story.json 미생성):

- 존재하지 않는 commit hash 참조 → 오류. 7자리 이상 prefix는 유일할 때만 허용
- claim의 evidence commit이 그 Episode 밖에 있으면 오류
- `evidence_files`가 evidence commit에서 실제로 바뀐 파일이 아니면 오류
- `observed` claim은 evidence file 필수, `inferred` claim은 `limitations` 필수
- Episode 간 commit 중복, 시간 겹침, 서사 필드 누락, claim 없는 Episode → 오류

`story.json.curation`에 `override_applied`, `auto_episode_count`, `curated_episode_count`,
`uncovered_commit_count`가 기록되어 자동 결과와 큐레이션 결과를 구분할 수 있다.
각 큐레이션 Episode의 `auto_origin.auto_episode_ids`는 어떤 자동 구간과 겹치는지 보여준다.

override는 Git 근거를 벗어나는 문장을 넣을 수 없다. 모든 claim은 commit hash와 파일 경로로 validation을 통과해야 한다.
개발자의 의도는 `inferred` status와 `limitations` 없이는 기록할 수 없다.

### 4. Claim 상태

| status | 의미 | 예 |
| --- | --- | --- |
| `observed` | diff/파일 변경에서 직접 확인 | "3921dce는 apps/KLMSync/Package.swift를 추가했다" |
| `supported` | commit message 또는 문서와 diff가 함께 뒷받침 | "subject 'Harden server relay security'와 worker.mjs의 authorized() 추가가 일치한다" |
| `inferred` | 여러 변경의 관계에서 추론. 반드시 한계 명시 | "원격 채널을 여러 차례 바꿔가며 찾은 것으로 추정된다" |

## 큐레이션된 Episode (HEAD 67e2f63, 1184 commits)

| # | 기간 | commits | 제목 |
| --- | --- | --- | --- |
| 1 | 05-06 ~ 05-14 | 37 | root 스크립트 묶음으로 시작한 동기화 엔진과 v2 파이프라인 |
| 2 | 05-17 ~ 05-30 | 65 | macOS 메뉴바 앱과 iPhone companion 도입 |
| 3 | 05-31 ~ 06-12 | 36 | 서버 relay, Windows companion, Cloudflare Worker로 원격 범위 확장 |
| 4 | 06-12 ~ 06-14 | 80 | 팔레트 실험 끝에 정리된 Paper Graphite 디자인 |
| 5 | 06-14 ~ 06-24 | 718 | 열흘 718 commit: 응답성·접근성·companion 동작 대량 반복 |
| 6 | 06-27 ~ 07-09 | 134 | iOS 컨트롤 안정화, 학기 catalog, Kaikey 자동 로그인 제거 |
| 7 | 07-13 ~ 08-03 | 104 | 설계 문서에서 시작한 안전·보안·release hardening 캠페인 |
| 8 | 08-09 ~ 08-27 | 10 | 8월: 유지보수, 외부 기여, 첫 merge commit |

8개 Episode가 1184개 commit 전부를 빠짐없이 덮는다(`uncovered_commit_count: 0`). claim 59개 중 inferred 8개.

## UI

- 상단: 이야기 제목, repository, source commit hash, commit 수, 기간, 생성 방식
- 전체 개발 arc 요약 + 8개 arc point(클릭하면 해당 Episode로 이동)
- Episode timeline: 이전/다음, 재생/정지(간격 6/10/15초), scrubber, 진행 표시, 트랙 카드
- Episode 카드: (1) 문제/맥락 → (2) 변경 → (3) 현재 코드에 남은 결과 → 주요 변경 영역 → (4) claim과 근거 commit → (5) 확인할 수 없는 정보
- claim마다 observed/supported/inferred 색상+라벨, confidence, evidence commit chip, evidence file, 한계
- Evidence drawer: full hash, subject, timestamp, author, +/- 줄 수, changed file 목록(evidence file 강조), diff excerpt(앞 40줄), `git show` 명령, GitHub commit 링크, claim 연결 이유
- 전체 Episode 목록: 재생 없이 모든 내용을 정적으로 읽을 수 있음
- 자동 clustering 결과 패널(61개 구간과 boundary 이유)
- 키보드: ←/→ Episode 이동, Space 재생/정지, Esc 드로어 닫기 또는 목록 복귀
- `prefers-reduced-motion`이면 진행 애니메이션과 transition 제거. `forced-colors` 대응
- Paper Graphite palette(DESIGN.md의 Windows token 값), `word-break: keep-all`로 한글 어절 보존, 긴 경로는 `overflow-wrap: anywhere`

## 검증 결과 (2026-09-03, Windows 11, Python 3.14, git 2.55)

| # | 항목 | 결과 |
| --- | --- | --- |
| 1 | `build_story.py` 실행 | 약 9초, exit 0 |
| 2 | commits.json | 1184 commits, 2.3 MB |
| 3 | story.json | 8 episodes + 61 auto episodes + 89 commit의 diff excerpt, 0.68 MB |
| 4 | `python3 -B -m unittest discover -s tests -v` | 25 tests OK (fixture repo 16 + 실제 story.json 검증 4 + pure 5) |
| 5 | `python3 -m http.server 4174 -d public` | 200 OK |
| 6 | 브라우저 콘솔 (headless Chromium, Playwright) | error/warning/requestfailed 0건 |
| 7 | 모든 episode commit hash가 실제 history에 존재 | test `test_every_commit_hash_exists_and_episodes_are_chronological` 통과 |
| 8 | Episode 시간순 정렬, 겹침 없음 | 같은 테스트 + build 시 validation |
| 9 | 모든 claim에 evidence commit ≥ 1, Episode 안에 있음, evidence file이 실제 diff에 있음 | test `test_every_claim_has_evidence_inside_its_episode` 통과 (큐레이션 59 + 자동 166 claim). 자동 claim도 build 시 `validate_claim`을 통과해야 함 |
| 10 | override 없이 생성 | `--no-override` → 61 auto episodes, exit 0 |
| 11 | 잘못된 override | 존재하지 않는 hash, Episode 밖 evidence, 없는 파일, 겹침, 잘못된 status, claim 없음, inferred without limitations 모두 `OverrideValidationError` → exit 2, story.json 미생성 (테스트 5건) |
| 12 | private/untracked 데이터 | untracked 파일 미접근(git object만 사용). test `test_no_private_paths_leak_into_outputs`가 commits.json의 모든 경로와 excerpt 경로에 `runtime/`, `course_files/`, `config.env`, `kaikey_state.json` 등이 없음을 확인. story.json에 `config.env` 문자열이 몇 건 있으나 모두 tracked README/docs의 diff excerpt 안 인용문 |
| 13 | 저장소 보안 게이트(`tools/security/run_security_evidence.sh`) 영향 | semgrep은 `src tools deploy apps`만 스캔하므로 `experiments/`는 대상 밖. bandit은 `src/python`만. detect-secrets 1.5.0으로 `experiments/` 전체를 스캔한 결과 finding 0건(기대치 26 유지). 브라우저 접근성: 닫힌 drawer는 `visibility:hidden` + `inert`, 열리면 본문이 `inert`로 focus trap |

이 프로토타입의 테스트는 저장소 root CI(`.github/workflows/ci.yml`)에 포함되지 않는다. root CI는 `tests/`만 discover한다. 프로토타입 테스트는 위 명령으로 수동 실행한다.

브라우저 데모 흐름(Playwright 자동화로 확인, `docs/screenshots/`):

1. 전체 arc 확인 → `01-overview.png`
2. 첫 Episode 재생, 진행 바 동작 → `02-playing.png`
3. 다음 Episode / ←→ 키 이동
4. scrubber를 5로 이동 → `03-episode5.png`
5. inferred claim 확인, evidence drawer 열기, commit hash·changed file·diff excerpt 표시 → `04-evidence-drawer.png`
6. Esc로 닫기, 전체 목록 복귀(포커스가 목록 제목으로 이동) → `05-episode-list.png`
7. 390px 폭에서 가로 overflow 없음 → `06-mobile.png`

## 한계

- clustering 가중치는 초기값이며 사용자 평가로 조정하지 않았다. 자동 결과만으로는 6월 중순의 700여 commit이 여러 구간으로 잘게 나뉜다.
- 이 저장소에는 PR, issue, tag가 없어 branch/merge 신호는 8월의 merge commit 하나에만 적용됐다.
- commit body가 있는 commit이 2개뿐이라 message 기반 근거는 subject에 의존한다.
- diff excerpt는 앞 40줄만 담는다. 전체 diff는 `git show <hash>` 또는 GitHub 링크로 봐야 한다.
- 개발자의 의도·논의·사용자 피드백은 Git에 없다. 해당 내용은 모두 `inferred`로 표시하고 한계를 명시했다.
- 두 차례 독립 코드 리뷰(Opus, critical)에서 지적된 사실 오류 8건(예: author 수, +줄 수 표기, 파일 개수)과 잠재 build-abort 2건, drawer 접근성 3건을 수정했다. 남은 지적은 모두 latent(현재 history에서는 발생하지 않는 경우)이거나 스타일 수준이다.
- 선택적 LLM adapter: `build_auto_episode()`가 반환하는 `summary`/`problem_or_context`를 후처리하는 함수를 끼우면 된다.
  단, 출력 문장은 여전히 `claims[].evidence_commit_ids`로 validation을 통과해야 하며 MVP에는 포함하지 않았다.
