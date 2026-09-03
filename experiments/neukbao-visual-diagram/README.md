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
├── docs/screenshot-*.png   # Playwright로 찍은 대표 화면
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

- **Level 0 System overview**: 14개 component를 3행 격자로 배치. row 0 사용자 앱·릴레이, row 1 동기화 엔진 실행 흐름(왼쪽에서 오른쪽), row 2 지원 계층. invokes/imports/communicates 중 high·medium만 그린다.
- **Level 1 Components**: 모든 component 관계를 타입별 선 스타일과 `type ×N` 라벨로 표시.
- **Level 2 Files**: 선택한 component의 디렉터리/파일 구조를 중첩 박스로 그리고, 오른쪽에 연결된 외부 component stub를 둔다. 파일 수준 edge를 (source, target, type)로 묶어 그린다.
- node 클릭: 이름, 역할, 경로, 언어, 크기, 하위, 연결(타입·방향·confidence·근거 버튼), Git 변경 횟수(로그 스케일 막대), 마지막 변경, 생성 근거.
- edge 클릭: 관계 종류, source/target, confidence(합쳐진 경우 분포), 추출 파일과 이유, 원본 파일 관계 목록.
- 검색(`/` 키로 포커스), 언어·관계 종류(contains 제외, 포함 관계는 트리 자체라 토글하지 않음)·confidence 필터, legend, commit 표시, 변경 강도 막대, breadcrumb, Overview 복귀.
- 키보드: SVG 포커스 후 방향키 이동(`aria-activedescendant`로 현재 node 지정, 상태 줄에 node 라벨 낭독), Enter 선택/확대, Space 선택, Esc 상위, `+`/`-`/`0` zoom. 모든 정보는 hover 없이 상세 패널에 나온다.
- `prefers-reduced-motion`이면 transition 제거. `prefers-color-scheme: dark`와 `forced-colors` 대응. node 위치는 `component-map.json`의 고정 격자와 결정적 packing으로 계산해서 필터·선택 때 흔들리지 않는다.
- 색상은 DESIGN.md의 Paper Graphite 팔레트를 그대로 썼다. 관계는 색뿐 아니라 선 종류(실선/대시/점선/이중선)와 라벨로도 구분한다.

## 검증 결과 (2026-09-03, source commit `09f546704a712780833e96039ce40ff362eb859e`)

| 항목 | 결과 |
| --- | --- |
| `python analyze.py --repo ../.. --output public/graph.json` | 1.4초, tracked 418, node 528 (system 1 / component 14 / directory 95 / file 418), edge 1216 |
| edge 타입 분포 | contains 527, invokes 163, imports 91, packages 173, tests 239, communicates 23 |
| confidence 분포 (contains 제외) | high 478, medium 68, low 143 |
| `python -B -m unittest discover -s tests` | 31 tests OK (synthetic repo 22, pattern/private 3, real repo 6) |
| 존재하지 않는 파일 참조 | 없음 (`RealRepositoryTests.test_all_file_nodes_are_tracked`, `test_all_edges_reference_existing_nodes`) |
| `source_commit` == `git rev-parse HEAD` | 일치. 불일치면 테스트가 실패한다 (`test_source_commit_matches_head`) |
| private/ignored 데이터 | file node 418개 전부 `git ls-files`에 있고 private 패턴에 걸리는 것 없음 |
| 브라우저 콘솔 | 오류 0 (Playwright, Chromium 1600×1000) |
| 흐름 | overview → L1 → component 클릭 → L2 → 파일 클릭 → 근거 버튼 → edge 상세 → 필터 on/off → 키보드 이동/Esc → Overview 복귀 확인 |
| 800px 폭 | 가로 스크롤 없음 |
| dark + reduced motion | 렌더 확인 (`docs/screenshot-dark-reduced-motion.png`) |

스크린샷: `docs/screenshot-l0-overview.png`, `docs/screenshot-l1-components.png`, `docs/screenshot-l2-file.png`, `docs/screenshot-l2-edge-detail.png`, `docs/screenshot-dark-reduced-motion.png`.

발견한 component (14): User Entry Points, Shell Orchestration, KLMS Web Access, Parsing and File Pipeline, Native macOS Integration, Apple Applications, Windows Companion, Relay Infrastructure, Integrations, Tests and Verification, Build and Distribution, Vendored Dependencies, Documentation and Examples, Neukbao Experiments (`experiments/` 아래 독립 프로토타입, 이 디렉터리 포함).
"Uncategorized"는 생성되지 않았다.

## 한계

- 정규식 기반 정적 분석이다. 동적으로 조립되는 경로(`"$KLMS_JS_DIR/${name}.js"`)는 놓친다. 스크립트 경로를 다른 스크립트의 인자로 넘기는 경우(예: `bin/refresh_course_files.sh`가 `download_klms_files.js` 경로를 `run_download_files_step.sh`에 전달)는 medium으로 기록되며 실제 실행 주체는 구분하지 않는다.
- `communicates`는 `/v1/...` 경로 문자열 교집합으로 추정하므로 medium 이상 올리지 않는다. 클라이언트마다 Node relay와 Cloudflare Worker 양쪽에 선이 생기는데 실제 배포에서는 하나만 쓰인다. Windows 앱의 `fake-relay.cjs`는 테스트 파일이라 서버로 취급하지 않는다.
- `commit_count`는 파일을 건드린 커밋 수의 단순 합계다. rename 추적, 저자, 시간대별 변화는 없다 (Storytelling 범위).
- 언어 필터는 node를 흐리게만 하고 edge를 제거하지 않는다.
- L2에서 파일이 70개 이상인 component(Tests and Verification 95개, Apple Applications 74개)는 박스가 커져 zoom이 필요하다.
- Swift 파일 사이의 타입 참조(같은 target 안)는 분석하지 않는다. target 단위만 다룬다.
- `docs/` 안 문서가 다른 파일을 언급하는 관계는 만들지 않았다 (문서를 근거로 쓰지 않는다는 원칙).
