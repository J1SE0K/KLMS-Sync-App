# Neukbao Visual Diagram (KLMS-Sync-App prototype)

KLMS-Sync-App 저장소의 구조와 파일 사이 관계를 공간적으로 보여 주는 독립 프로토타입이다.
Storytelling, Development Episode, 타임라인 재생과는 무관하며, 이 디렉터리만으로 실행된다.

연구 질문: Visual Diagram을 쓰면 처음 보는 개발자가 파일 트리와 README만 볼 때보다
KLMS-Sync-App의 주요 구성요소와 관계를 더 빨리 파악할 수 있는가?

## 구성

```text
experiments/neukbao-visual-diagram/
├── README.md               # 이 문서
├── PRESENTATION.md         # 발표용 정리 (문제, 방식, 기획, 계획, 60초 데모)
├── analyze.py              # tracked 소스 → public/graph.json (표준 라이브러리만 사용)
├── component-map.json      # 상위 component 분류 규칙과 L0/L1 격자 위치
├── tests/test_analyze.py   # 분석기 unit test + 실제 저장소 무결성 검사
├── docs/screenshot-*.png   # Playwright로 찍은 대표 화면 (네 가지 뷰 + 다크)
└── public/
    ├── index.html          # viewer (vanilla HTML/CSS/JS/SVG, 외부 CDN 없음)
    ├── app.js
    ├── styles.css
    └── graph.json          # analyze.py 산출물
```

## 실행

```sh
cd experiments/neukbao-visual-diagram

# 1. 분석: 저장소 root를 입력받아 graph.json 생성
python3 analyze.py --repo ../.. --output public/graph.json

# 2. 테스트
python3 -B -m unittest discover -s tests -v

# 3. viewer
python3 -m http.server 4173 -d public
# http://127.0.0.1:4173/
```

Windows에서는 `python3` 대신 `python`을 쓰고, 한글 콘솔 출력이 깨지면 `PYTHONIOENCODING=utf-8`을 붙인다.
API key, 외부 LLM, 외부 서버는 필요 없다. viewer는 `fetch("./graph.json")`만 하므로 정적 서버가 필요하다.

## 분석기가 하는 일

입력은 `git ls-files` 결과뿐이다. ignored/untracked 파일, `config.env`, `runtime/`, `course_files/`, 인증 상태, 사용자 로그는 열지 않는다.
tracked 파일이라도 `config.env`, `.env`, `*.cookies`, `session*.json`, `kaikey*`, `manual_assignment_overrides.json`, `runtime/`, `course_files/` 패턴은 추가로 제외한다 (`.example` 접미사는 허용).

1. tracked file tree와 확장자·shebang 기반 언어 (JXA와 Node를 구분)
2. `component-map.json` 규칙으로 파일을 상위 component에 분류. 규칙은 위에서 아래로 첫 매칭 우선이며, 마지막 `**` 규칙은 안전망이다. 매칭 안 된 파일이 있으면 `Uncategorized` component가 생기고 경고를 낸다.
3. 관계 추출. 모든 edge에 `evidence[{path, reason}]`와 `confidence`가 붙는다.

| 관계 | 추출 근거 | confidence |
| --- | --- | --- |
| root wrapper → `bin/` | `exec /bin/zsh "$SCRIPT_DIR/bin/x.sh"` | high |
| shell `source` | `COMMON_SH="$SCRIPT_DIR/…"` 뒤 `source "$COMMON_SH"`, 또는 같은 줄 `source` | high |
| shell → `$KLMS_{JS,PYTHON,SWIFT,SH}_DIR/파일` | 변수 정의는 `src/sh/klms_common.sh`에서 확인. 같은 줄에서 실행하면 high, 인자/변수로만 넘기면 medium | high / medium |
| shell → `$SCRIPT_DIR/파일` | 같은 줄에 exec/zsh/osascript/python3/swift/node가 있으면 high, 없으면 medium |
| shell `./x.sh` | cwd가 저장소 루트라는 가정 | medium |
| shell `python3 -m pkg.mod` | `src/python` 기준 모듈 경로 해석 | medium |
| Python `import` / `from . import` | 상대·절대 import를 `src/python`, `tools`, `tests` 기준으로 해석 | high |
| Python `PROJECT_DIR / "src" / "python" / "x.py"` | 테스트가 subprocess로 실행하는 대상 | high |
| JS `require()` / `import from` (상대 경로, 여러 줄 import 포함) | 파일 존재 확인 | high |
| JS `` `${scriptDir}/src/...` ``, `path.join(__dirname, "x")` | 파일 존재 확인 | high |
| Swift `Package.swift` target → `Sources/<name>` 디렉터리, target 의존성 | Package.swift 파싱 | high |
| Swift `import KLMSShared` / `@testable import` | Package.swift target 이름과 대조 | high |
| `EnginePayloadAllowlist.txt` 항목 | 앱 EnginePayload에 주입되는 파일 | high (packages) |
| `package.json` main/scripts, `wrangler.toml` main, Dockerfile COPY | 파일 존재 확인 | high (packages/invokes) |
| GitHub Actions workflow의 `tools/...` 경로 | 문자열 경로 | medium |
| 클라이언트 ↔ 서버 `communicates` | `"/v1/..."` 경로 문자열을 서버 파일(`http.createServer`, Worker `fetch(request)`)과 공유. 3개 이상이면 medium, 1~2개면 low. 두 서버(Node relay, Cloudflare Worker) 모두에 선이 생기며 배포 형태에 따라 하나만 실제로 쓰인다 | medium / low |
| 코드 안 저장소 상대 경로 문자열 (`src/js/x.js` 등) | 경로 문자열만. 대상이 실행 파일(.sh/.py/.js/.mjs/.cjs/.swift)이면 invokes medium, 아니면(.json/.md/.txt 등) packages low로 기록해 실행을 주장하지 않는다 | medium / low |
| 파일 이름만 문자열로 등장 (`"sync_klms_core.sh"`) | 이름 유일성, 또는 root 파일 우선 | low |
| 테스트 파일 이름 ↔ 모듈 이름 (`test_doctor.py` ↔ `doctor.py`) | 이름만 대응. 실제 import가 있으면 그 edge가 우선 | low |

테스트 파일(`tests/`, `*Tests.swift`, `*.test.cjs`, `*.spec.js`, `tools/smoke_*` 등)에서 나가는 invokes/imports/packages는 `tests` 타입으로 기록한다. 테스트 보조 파일이 서버 경로를 흉내 내는 경우의 `communicates`는 low로 남긴다.
실행 파일이 아닌 대상(.html/.json/.md/.txt 등)으로는 어떤 추출기에서 나왔든 `invokes`를 만들지 않고 `packages`(로드/참조)로 기록하며, 이 경우 source가 테스트 파일이어도 `tests`로 바꾸지 않는다 (fixture를 읽는 것은 검증이 아니다).
확인되지 않은 관계는 만들지 않는다. 관계가 없는 파일은 연결선 없이 `contains`만 가진다.

4. `git log --name-only`로 파일별 변경 커밋 수와 마지막 변경 시각. 디렉터리/컴포넌트 값은 하위 파일의 합계다. rename 이전 이력은 따라가지 않는다.
5. component 수준 edge는 파일 edge를 `(type, source component, target component)`로 합치고 `member_edge_ids`, `confidence_breakdown`, 대표 evidence를 남긴다.

`meta`에는 `repository`, `source_commit`(40자), `source_branch`, `worktree_dirty`, `generated_at`, `tracked_file_count`, node/edge 수, 언어 분포가 들어간다.

## Viewer

같은 `graph.json`을 네 가지 형태로 보여 준다. 상단 탭으로 전환하며, 선택한 node/edge와 필터는 탭을 바꿔도 유지된다.

| 탭 | 답하는 질문 | 강점 |
| --- | --- | --- |
| **관계도** (기본) | 무엇이 무엇을 부르는가 | 실행 흐름의 방향과 경로를 눈으로 따라간다 |
| **행렬** | 누가 누구를 쓰는가 | 선이 겹치지 않아 전체 결합도를 한 판에 본다 |
| **면적** | 코드가 어디에 몰려 있는가 | 크기와 변경 강도를 비율로 비교한다 |
| **방사형** | 전체 트리가 어떻게 생겼는가 | 상위 4겹의 계층 비율을 한 화면에 담는다 (그 아래는 조각을 열어서 본다) |

### 관계도 (3단계 확대)

- **Level 0 System overview**: 14개 component를 3행 격자로 배치. row 0 사용자 앱·릴레이, row 1 동기화 엔진 실행 흐름(왼쪽에서 오른쪽), row 2 지원 계층. invokes/imports/communicates 중 high·medium만 그린다.
- **Level 1 Components**: 모든 component 관계를 타입별 선 스타일과 `type ×N` 라벨로 표시.
- **Level 2 Files**: 선택한 component의 디렉터리/파일 구조를 중첩 박스로 그리고, 오른쪽에 연결된 외부 component stub를 둔다. 파일 수준 edge를 (source, target, type)로 묶어 그린다.

### 행렬 (component × component)

- 행 = 출발(source), 열 = 대상(target). 대각선은 자기 자신이라 비운다.
- 칸 숫자 = 그 방향의 원본 파일 관계 수, 칸 색 진하기 = 같은 값의 로그 스케일, 칸 아래 색 띠 = 관계 종류(여러 종류면 나눠서 표시).
- 칸을 누르면 그 칸에 들어 있는 관계 목록과 대표 근거가 나오고, 각 관계의 `근거` 버튼으로 원본 edge 상세로 넘어간다.
- 행/열 머리글을 누르면 해당 component가 선택된다. 마우스를 칸에 올리면 행과 열이 함께 강조된다.

### 면적 (treemap)

- 사각형 넓이 = 파일 수 또는 커밋 수(상단 `크기 기준`으로 전환), 색 진하기 = 커밋 수.
- 더블클릭 또는 Enter로 component에서 디렉터리, 파일까지 내려가고 Esc로 올라온다. breadcrumb에 현재 위치가 남는다.
- squarified 알고리즘이라 같은 데이터면 같은 배치가 나온다.

### 방사형 (sunburst)

- 가운데가 현재 기준, 바깥으로 갈수록 하위 계층. 각도 = 파일 수(또는 커밋 수) 비율, 최대 4겹.
- 한 화면에 전부 담기지 않는다. 4겹 밖이거나 각이 0.012 rad보다 얇은 조각은 그리지 않고, 상태 줄에 몇 개를 왜 안 그렸는지 밝힌다. 저장소 전체 기준으로는 303개를 그리고 253개가 4겹 밖이라 조각을 열어야 보인다.
- 더블클릭/Enter로 그 조각을 가운데로 내리고 Esc로 올라온다. 면적 뷰와 위치(breadcrumb)를 공유한다.
- node 클릭: 이름, 역할, 경로, 언어, 크기, 하위, 연결(타입·방향·confidence·근거 버튼), Git 변경 횟수(로그 스케일 막대), 마지막 변경, 생성 근거.
- edge 클릭: 관계 종류, source/target, confidence(합쳐진 경우 분포), 추출 파일과 이유, 원본 파일 관계 목록.
### 네 뷰가 공유하는 것

- 검색(`/` 키로 포커스), 언어·관계 종류(contains 제외, 포함 관계는 트리 자체라 토글하지 않음)·confidence 필터, legend, commit 표시, 변경 강도, breadcrumb, Overview 복귀.
- 오른쪽 상세 패널. node를 고르면 이름·역할·경로·언어·하위·연결·커밋 수·마지막 변경·생성 근거가, edge나 행렬 칸을 고르면 관계 종류·source/target·confidence·추출 파일과 이유가 나온다.
- 상세 패널의 경로 링크를 누르면 지금 보고 있는 뷰에 맞게 이동한다. 관계도에서는 해당 파일의 L2로, 면적/방사형에서는 그 위치로 내려가고, 행렬에서 파일을 고르면 관계도로 넘어간다.
- 키보드: SVG 포커스 후 방향키 이동(`aria-activedescendant`로 현재 요소 지정, 상태 줄에 라벨 낭독), Enter 선택/확대, Space 선택, Esc 상위, `+`/`-`/`0` zoom. 행렬의 칸과 면적/방사형의 조각도 같은 방식으로 순회한다. 모든 정보는 hover 없이 상세 패널에 나온다.
- `prefers-reduced-motion`이면 transition 제거. `prefers-color-scheme: dark`와 `forced-colors` 대응. node 위치는 `component-map.json`의 고정 격자와 결정적 packing으로 계산해서 필터·선택 때 흔들리지 않는다.
- 색상은 DESIGN.md의 Paper Graphite 팔레트를 그대로 썼다. 관계는 색뿐 아니라 선 종류(실선/대시/점선/이중선)와 라벨로도 구분한다.

## 검증 결과 (2026-09-03, source commit `8b94ca0a207e851797478b206c8f31e0c85d629c`)

| 항목 | 결과 |
| --- | --- |
| `python analyze.py --repo ../.. --output public/graph.json` | 1.5초, tracked 442, node 557 (system 1 / component 14 / directory 100 / file 442), edge 1291 |
| edge 타입 분포 | contains 556, invokes 168, imports 93, packages 179, tests 269, communicates 26 |
| confidence 분포 (contains 제외) | high 480, medium 92, low 163 |
| `python -B -m unittest discover -s tests` | 32 tests OK (synthetic repo 22, pattern/private 3, real repo 7) |
| 존재하지 않는 파일 참조 | 없음 (`RealRepositoryTests.test_all_file_nodes_are_tracked`, `test_all_edges_reference_existing_nodes`) |
| `source_commit` | 생성 당시 HEAD와 일치. 테스트가 보장하는 것은 **출처**이지 **최신성**이 아니다. `test_source_commit_is_a_real_ancestor_of_head`는 그 값이 HEAD에서 도달 가능한 진짜 커밋인지, `test_every_file_node_exists_in_the_recorded_commit`은 그 커밋의 트리와 graph.json의 파일 집합이 양방향으로 일치하는지 본다. 즉 오래된 graph.json도 자기 커밋과 아귀가 맞으면 통과한다. 커밋이 쌓이면 뒤처지므로 **발표 전에 `analyze.py`를 다시 실행해 HEAD로 맞춘다** |
| private/ignored 데이터 | file node 442개 전부 `git ls-files`에 있고 private 패턴에 걸리는 것 없음 |
| 브라우저 콘솔 | 오류 0 (Playwright, Chromium 1600×1000) |
| 흐름 (관계도) | overview → L1 → component 클릭 → L2 → 파일 클릭 → 근거 버튼 → edge 상세 → 필터 on/off → 키보드 이동/Esc → Overview 복귀 확인 |
| 흐름 (행렬) | 탭 전환 → 관계가 있는 칸 52개 / 182칸 → 칸 클릭 → 관계 목록과 대표 근거 → `근거`로 edge 상세 확인 |
| 흐름 (면적) | 탭 전환 → component 14개 → 크기 기준 파일↔커밋 전환 → 더블클릭으로 하위 진입 → Esc 복귀 확인 |
| 흐름 (방사형) | 탭 전환 → 전체 기준 303개 조각과 "안 그린 것 253개 (4겹 밖 253개)" 안내 → 키보드 이동/Enter로 하위 진입 → breadcrumb 갱신 확인 |
| 800px 폭 | 가로 스크롤 없음 |
| dark + reduced motion | 렌더 확인 (`docs/screenshot-dark-reduced-motion.png`) |

스크린샷: `docs/screenshot-l0-overview.png`, `docs/screenshot-l1-components.png`, `docs/screenshot-l2-file.png`, `docs/screenshot-l2-edge-detail.png`, `docs/screenshot-matrix.png`, `docs/screenshot-treemap.png`, `docs/screenshot-sunburst.png`, `docs/screenshot-dark-reduced-motion.png`.

발견한 component (14): User Entry Points, Shell Orchestration, KLMS Web Access, Parsing and File Pipeline, Native macOS Integration, Apple Applications, Windows Companion, Relay Infrastructure, Integrations, Tests and Verification, Build and Distribution, Vendored Dependencies, Documentation and Examples, Neukbao Experiments (`experiments/` 아래 독립 프로토타입, 이 디렉터리와 storytelling 프로토타입 포함).
"Uncategorized"는 생성되지 않았다.

## 한계

- 정규식 기반 정적 분석이다. 동적으로 조립되는 경로(`"$KLMS_JS_DIR/${name}.js"`)는 놓친다. 스크립트 경로를 다른 스크립트의 인자로 넘기는 경우(예: `bin/refresh_course_files.sh`가 `download_klms_files.js` 경로를 `run_download_files_step.sh`에 전달)는 medium으로 기록되며 실제 실행 주체는 구분하지 않는다.
- `communicates`는 `/v1/...` 경로 문자열 교집합으로 추정하므로 medium 이상 올리지 않는다. 클라이언트마다 Node relay와 Cloudflare Worker 양쪽에 선이 생기는데 실제 배포에서는 하나만 쓰인다. Windows 앱의 `fake-relay.cjs`는 테스트 파일이라 서버로 취급하지 않는다.
- `commit_count`는 파일을 건드린 커밋 수의 단순 합계다. rename 추적, 저자, 시간대별 변화는 없다 (Storytelling 범위).
- `graph.json`은 한 커밋의 스냅샷이다. 테스트는 그 커밋과의 정합성만 보고 최신성은 보지 않으므로, 저장소가 앞서 나간 뒤에도 초록으로 통과한다. 화면 상단의 commit 값이 지금 HEAD와 다르면 다시 생성해야 한다.
- 언어 필터는 node를 흐리게만 하고 edge를 제거하지 않는다.
- L2에서 파일이 70개 이상인 component(Tests and Verification 95개, Apple Applications 74개)는 박스가 커져 zoom이 필요하다.
- 행렬은 component 단위만 다룬다. 파일 단위 행렬은 442×442이라 만들지 않았다.
- 면적/방사형의 크기 기준은 파일 수와 커밋 수 둘뿐이다. 코드 줄 수는 tracked 파일을 전부 읽어야 해서 넣지 않았다.
- 방사형은 4겹까지만 그린다. 저장소 전체를 기준으로 하면 303개를 그리고 253개가 4겹 밖이라 화면에 없다. 크기 기준을 커밋 수로 바꾸면 얇은 조각까지 더해져 443개가 빠진다. 상태 줄이 그 수와 이유를 밝히며, 전부 보려면 조각을 눌러 내려가야 한다.
- Swift 파일 사이의 타입 참조(같은 target 안)는 분석하지 않는다. target 단위만 다룬다.
- `docs/` 안 문서가 다른 파일을 언급하는 관계는 만들지 않았다 (문서를 근거로 쓰지 않는다는 원칙).
