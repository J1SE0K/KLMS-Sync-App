# Neukbao Visual Diagram · 발표 노트

대상 저장소: `J1SE0K/KLMS-Sync-App` (commit `8b94ca0a`, tracked 442 files)
프로토타입 위치: `experiments/neukbao-visual-diagram/`
성격: Neukbao의 첫 독립 프로토타입. Storytelling(Development Episode, 타임라인 재생)과 분리된 별개 실험.

---

## 1. 다루는 문제점

### 문제 의식

AI 코딩 세션이 만들어 낸 저장소는 한 사람이 처음부터 끝까지 손으로 쓴 저장소보다
"왜 이 파일이 여기 있는가"를 파일 트리만으로 알기 어렵다.
KLMS-Sync-App은 zsh, JXA, Python, Swift, Electron, Cloudflare Worker가 한 저장소에 있고
root wrapper, `bin/`, `src/sh/`, `src/js/`, `src/python/`, `src/swift/`, `apps/`, `deploy/`, `tools/`, `tests/`가
서로를 호출한다. 신규 개발자는 이 관계를 머릿속에서 재구성해야 한다.

### 구체적 문제

- root의 `sync_klms_core.sh`는 6줄짜리 wrapper이고, 실제 구현은 `bin/sync_klms_core.sh` → `src/sh/klms_common.sh` → `src/js/sync_klms_notes.js` → `src/python/fetch_pages_backend.py`로 이어진다. 파일 트리에는 이 사슬이 보이지 않는다.
- macOS 앱은 어떤 shell script를 실행하는가? iPhone/Windows 앱은 어디와 통신하는가? `tools/klms_relay_server.mjs`와 `deploy/cloudflare-worker/src/worker.mjs`는 같은 API를 제공하는가? 답은 5개 이상의 파일을 열어야 나온다.
- `tests/` 36개 Python 테스트가 어느 모듈을 검증하는지, `tools/` 43개 파일 중 무엇이 빌드이고 무엇이 검증인지 이름만으로는 구분되지 않는다.

### Pain point

"이 저장소의 큰 구조를 이해하려면 파일을 몇 개 열어야 하는가"가 너무 크다.
README는 의도를 설명하지만 실제 코드가 README와 같은지 검증해 주지 않는다.

---

## 2. 다루는 방식

### 왜 Visual Diagram인가

구조 이해는 공간적 문제다. "무엇이 무엇을 부르는가"를 목록으로 읽는 것보다
좌표와 선으로 보는 편이 빠르다. 다만 442개 파일을 한 화면에 뿌리면 오히려 잃는다.
그래서 **System → Component → File** 세 단계로 확대하는 구조를 택했다.

### 파일 트리, 일반 dependency graph와 무엇이 다른가

| | 파일 트리 | force-directed dependency graph | Neukbao Visual Diagram |
| --- | --- | --- | --- |
| 단위 | 디렉터리 | 파일 | component → directory → file 3단계 |
| 관계 | 없음 (포함만) | import 한 종류 | contains / invokes / imports / packages / tests / communicates 6종 |
| 근거 | 없음 | 보통 없음 | 모든 edge에 추출 파일과 이유, confidence(high/medium/low) |
| 시간 | 없음 | 없음 | 파일·component별 커밋 수와 마지막 변경 |
| 배치 | 알파벳 | 물리 시뮬레이션(매번 다름) | 고정 격자 + 결정적 packing (필터·선택에 흔들리지 않음) |
| 표현 | 하나 | 하나 | 네 가지(관계도·행렬·면적·방사형)를 같은 데이터로 전환 |
| 문서 의존 | README를 사람이 읽음 | 없음 | 문서는 label 참고용, node/edge는 tracked source에서만 |

핵심 차별점은 **근거와 confidence**다. 이름만 보고 추정한 관계(low)와 코드에서 확인한 관계(high)를 같은 선으로 그리지 않는다.
사용자는 "이 선이 왜 있는가"를 클릭 한 번으로 확인할 수 있다.

---

## 3. 기획

### 입력

- `git ls-files` 결과 (tracked 파일만)
- 각 tracked 텍스트 파일의 내용 (4MB 이하, 코드/설정 확장자만)
- `git log --name-only --format=<hash><ts>` (커밋 수, 마지막 변경)
- `component-map.json` (사람이 관리하는 분류 규칙 14개 + 격자 위치)
- README/DESIGN/docs는 component label과 팔레트를 정할 때만 참고했다.

제외: `config.env`, `runtime/`, `course_files/`, 인증 상태, 로그, ignored/untracked, `~/Library/Application Support` 데이터.

### 분석 단계 (`analyze.py`, 표준 라이브러리만)

1. tracked 파일 수집 + private 패턴 2차 필터
2. 확장자·shebang으로 언어 판정 (JXA `#!/usr/bin/osascript` vs Node `#!/usr/bin/env node`)
3. `component-map.json` 규칙 첫 매칭으로 분류. 매칭 실패는 `Uncategorized`로 드러냄
4. 파일별 관계 추출 (shell exec/source/`$KLMS_*_DIR`, Python import, JS require/import, Swift Package target, allowlist, package.json, wrangler, Dockerfile, CI workflow, `/v1/*` 경로 공유)
5. git 통계 집계, 디렉터리·component로 roll-up
6. component 수준 edge 생성 (파일 edge 묶음 + 대표 evidence + confidence 분포)

### 데이터 모델 (`public/graph.json`)

```json
{
  "meta": {"repository", "source_commit", "source_branch", "worktree_dirty", "generated_at", "tracked_file_count", "languages", ...},
  "nodes": [{"id", "label", "kind": "system|component|directory|file", "parent_id", "path", "language",
             "description", "commit_count", "last_changed_at", "evidence": [{"path","reason"}], "file_count", "languages"}],
  "edges": [{"id", "source", "target", "type": "contains|invokes|imports|packages|tests|communicates",
             "confidence": "high|medium|low", "evidence": [{"path","reason"}],
             "level": "structure|file|component", "member_edge_ids", "confidence_breakdown"}]
}
```

실측: node 557, edge 1291 (contains 556, invokes 168, imports 93, packages 179, tests 269, communicates 26). contains 제외 confidence: high 480, medium 92, low 163.

### UI 구조

- 상단: breadcrumb, source commit, tracked 수, 생성일. 그 아래 **뷰 탭 4개**
- 좌측: 레벨 전환, Overview/zoom, 검색, 언어·관계·confidence 필터, legend, 변경 강도 범례
- 중앙 SVG: 선택한 뷰를 그린다
  - **관계도**: L0 격자(14 component, 주요 흐름만) / L1(모든 component 관계, `type ×N` 라벨) / L2(중첩 디렉터리·파일 박스 + 외부 component stub)
  - **행렬**: 14×14. 행=source, 열=target, 숫자=원본 관계 수, 색 진하기=로그 스케일, 아래 띠=관계 종류
  - **면적**: squarified treemap. 넓이=파일 또는 커밋 수, 색=커밋 강도, 더블클릭으로 하위 진입
  - **방사형**: sunburst 4겹. 각도=파일 비율, 가운데가 현재 기준. 4겹 밖은 그리지 않고 개수를 밝힌다
- 우측: node/edge/행렬 칸 상세. hover 없이 모든 정보 노출

한 가지 표현으로는 한 가지 질문밖에 답하지 못한다. 관계도는 방향을 보여 주지만 선이 많아지면 전체 결합도가 안 보이고,
행렬은 결합도를 보여 주지만 경로를 따라갈 수 없다. 면적은 크기를, 방사형은 계층을 보여 준다.
같은 `graph.json`을 네 방식으로 그려서 질문에 맞는 그림을 고르게 했다.

### 설계 원칙

- Paper Graphite (DESIGN.md): warm paper 배경, graphite 액션, 1px 구조선, 상태색은 confidence에만
- 관계는 색 + 선 종류 + 라벨 세 겹으로 구분
- node 위치는 결정적. 필터·선택은 opacity만 바꾼다
- 한글 label은 `word-break: keep-all`, SVG 텍스트는 폭 추정 후 말줄임
- 키보드 완전 접근, `prefers-reduced-motion`, dark scheme, forced-colors
- 근거 없는 선은 그리지 않는다. 문서를 그대로 옮기지 않는다

### 검증 방법

- 분석기 unit test 32개: 합성 저장소(온갖 패턴을 일부러 심음) 22개 + glob/private 규칙 3개 + 실제 저장소 무결성 7개
- 실제 저장소 검사: 모든 file node가 `git ls-files`와 `source_commit`의 트리에 존재, 모든 edge가 존재하는 node 참조, evidence 비어 있지 않음, `source_commit`이 HEAD에서 도달 가능한 실제 커밋, root wrapper 12개 전부 `bin/`으로 위임하는 edge 존재, `Uncategorized` 없음
- Playwright: 콘솔 오류 0, overview → component → file → edge 근거 → 필터 → 키보드 → overview 복귀, 800px 폭 가로 스크롤 없음, dark + reduced motion 렌더

---

## 4. 계획

### 무엇을 먼저 만들었는가

1. 분석기와 데이터 모델 (근거·confidence를 스키마에 강제). 표현을 늘려도 데이터는 그대로 쓴다
2. component-map 규칙 (실제 파일을 확인한 뒤 14개로 확정. `experiments/`는 "Neukbao Experiments"로 분리해 동기화 엔진과 섞이지 않게 했다. "Relay Infrastructure"는 `tools/klms_relay_server.mjs` + `deploy/`, "Integrations"는 `integrations/` + Discord coordinator)
3. 3단계 viewer
4. 테스트와 브라우저 검증

### 다음에 무엇을 개선할 것인가

- 동적 경로(`"$DIR/${name}.js"`)와 함수 인자로 넘기는 스크립트 이름 추적
- Swift target 내부 타입 참조, Python 함수 수준 호출
- L2에서 파일 90개 이상인 component의 자동 접기/펼치기
- 두 뷰를 좌우로 동시에 놓는 분할 화면 (지금은 탭 전환)
- 행렬의 행·열 정렬 기준 전환 (지금은 파이프라인 순서 고정)
- component-map 없이도 첫 분류를 제안하는 휴리스틱 (디렉터리 + 언어 + 호출 방향)
- 사용자 실험: 파일 트리+README 그룹 vs Visual Diagram 그룹에게 같은 질문("iPhone 앱은 어떤 파일과 통신하는가")을 주고 시간·정확도 비교
- VS Code 확장(Neukbao) 패널로 이식. graph.json 스키마는 그대로 쓴다

### Storytelling과 독립적인 이유

- 질문이 다르다. Storytelling은 "어떻게 여기까지 왔는가"(시간), Visual Diagram은 "지금 무엇이 어디에 있는가"(공간)
- 입력이 다르다. 여기는 현재 HEAD의 tracked source와 커밋 수뿐이다. 세션 로그, 에피소드, 재생 타임라인을 읽지 않는다
- 실패 모드가 다르다. 이 프로토타입은 잘못된 선을 그리지 않는 것이 목표이고, 그래서 confidence를 데이터에 박았다
- 그래서 하나가 실패해도 다른 하나는 살아남는다. 나중에 Storytelling이 "이 component가 언제 생겼는가"를 묻고 싶으면 이 graph.json의 node id를 그대로 참조하면 된다

---

## 5. 60초 데모 시나리오

```sh
cd experiments/neukbao-visual-diagram
python3 analyze.py --repo ../.. --output public/graph.json
python3 -m http.server 4173 -d public
```

| 시간 | 행동 | 보이는 것 | 말할 것 |
| --- | --- | --- | --- |
| 0–10s | 브라우저에서 열기 | L0: 14개 component 격자, 상단에 commit `8b94ca0a`, 442 files | "이 화면은 저장소의 tracked 파일 442개를 14개 덩어리로 나눈 것이다. 문서가 아니라 코드에서 뽑았다." |
| 10–20s | row 1을 손으로 짚기 | User Entry Points → Shell Orchestration → KLMS Web Access → Parsing → Native macOS 순서의 화살표 | "root 스크립트에서 시작해 Safari, Python, Reminders/Calendar까지 실행이 왼쪽에서 오른쪽으로 흐른다." |
| 20–30s | `Shell Orchestration` 클릭 | 우측 패널: 파일 16개, 커밋 86, 연결된 component 6개(관계 9개)와 confidence | "이 component가 무엇과 연결되는지, 각 연결이 얼마나 확실한지 바로 나온다." |
| 30–40s | "파일 구조 열기 (L2)" | `bin/` 12개, `src/sh/` 4개 박스, 오른쪽에 외부 component stub 6개 | "이제 파일 수준이다. 왼쪽 막대가 진할수록 자주 바뀐 파일." |
| 40–50s | `sync_klms_core.sh` 클릭 → 연결 목록의 "근거" 클릭 | edge 상세: `imports high`, `COMMON_SH="$SCRIPT_DIR/src/sh/klms_common.sh"` 뒤에 `source "$COMMON_SH"` | "이 선은 왜 있는가? 실제 코드 줄이 근거로 붙어 있다. 이름만 보고 추정한 관계는 low로 따로 표시된다." |
| 50–60s | 상단 `행렬` 탭 → 이어서 `면적` 탭 | 14×14 행렬에서 Tests와 Build 행이 가장 짙고, 면적 뷰에서 Tests 95파일 / Apple 74파일 블록이 가장 크다 | "같은 데이터를 형태만 바꿔 본다. 행렬은 결합도를, 면적은 무게를 보여 준다. 파일 트리와 README로는 어느 쪽도 안 나온다." |

예비 질문 대응:
- "confidence는 어떻게 정했나" → README 표. 코드에서 직접 확인이면 high, 경로 문자열·인자 전달·경로 3개 이상 공유면 medium, 이름만·경로 1~2개 공유·비실행 파일 경로 문자열이면 low.
- "왜 force graph가 아닌가" → 위치가 매번 바뀌면 공간 기억이 쌓이지 않는다. 격자는 고정이고 필터는 opacity만 바꾼다. treemap도 squarified라 같은 데이터면 같은 배치가 나온다.
- "왜 뷰가 네 개인가" → 하나로는 한 질문만 답한다. 방향은 관계도, 결합도는 행렬, 무게는 면적, 계층은 방사형이 답한다.
- "Storytelling은?" → 별개 실험. 이 graph.json의 node id를 나중에 시간축 데이터가 참조할 수 있게만 열어 뒀다.
