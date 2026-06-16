# Workbench 스키마 — Framework Core

> **이 파일은 프레임워크(workbench-kit)의 고정 코어다 — 직접 편집하지 마라.**
> 프레임워크 업그레이드가 이 파일을 덮어쓴다. 당신의 규칙은 `AGENTS.overlay.md`에
> 둔다. 운영용 정본은 둘을 합성한 `AGENTS.md`이며, 합성은 부트스트랩
> (`workbench-kit:generate-workbench`)이 수행한다.
>
> 여기 담긴 것은 **기계가 읽거나 강제하는 규칙 + harvest·wiki·lifecycle 메커니즘**
> 뿐이다(경계 기준은 프레임워크 결정 "persona vs framework 규칙 경계" 참고).

## 핵심 원칙

- **작업은 휘발, 지식은 축적.** task의 모든 과정은 task 브랜치에서 일어나고,
  마지막에 task/를 cleanup한 뒤 **squash 머지**된다. main 이력에는 정제된
  증분 커밋 하나만 남는다. (squash는 취향이 아니라 이 모델의 구조다.)
- **두 레이어.** 판단(무엇을 추출할지, 산문 작성)은 에이전트가, 배관(git 상태
  전이)은 `utils/` 스크립트가 한다.
  - **에이전트의 진입점은 항상 스킬**이다(`workbench:task-start` 등). 스크립트
    직접 호출은 스킬 절차 안에서만 한다.
  - **스크립트는 산문을 짓지 않는다.** PR 제목·본문 등 독자가 읽을 글은
    판단 레이어가 작성해 입력으로 넘긴다.
  - `workbench task`가 issue에 쓰는 lifecycle comment는 고정 marker schema의 machine
    event다 — 티켓 처분·상태 분류·독자용 산문은 스킬/사람 게이트의 몫이다.
- **진실의 원천은 기록, 이름은 기본값.** 브랜치/디렉토리 이름을 역파싱하지
  말고 `task/index.md`의 기록을 읽는다.

## 용어집 (개념 — 고정)

| 용어 | 뜻 |
|---|---|
| **task** | 하나의 이슈에서 시작하는 작업 단위. 브랜치 + 작업 공간 + task/ 폴더 |
| **task 작업 공간** | `.worktrees/` 하위의 워크트리 하나. task가 사는 곳 |
| **codebase** | 작업 대상 외부 프로젝트. clone 캐시 `.codebases/`, 작업 사본 `task/codebases/` |
| **증분** | task에서 살아남아 main에 머지되는 것 |
| **cleanup** | submit 직전 task/ 추적 파일을 지우는 커밋 |
| **home** | 이슈가 사는 곳. 불변이며 브랜치 이름에 들어간다 |
| **우산 이슈** | 여러 repo에 걸치는 작업을 위해 만드는 이슈 |
| **점 규칙** | 점(.)으로 시작하는 디렉토리는 인프라 — 그 안에서 직접 작업하지 않는다 |

> 개념은 고정이나 *부르는 단어*는 persona다 — 단, `utils`가 쓰는 식별자
> (`task/`, `docs/`, op 어휘 등)는 바꿀 수 없다.

## 이름 규칙 (구조 — 고정, 스타일은 overlay)

| 대상 | 규칙 |
|---|---|
| task ID | workbench 이슈 `42`, codebase 이슈 `repo#42` |
| workbench 브랜치 | `task/[home/][parent/]<issue>-<slug>` |
| task 작업 공간 | 브랜치명의 `/` → `__` 치환, `.worktrees/` 하위 |
| codebase 브랜치 | 기본 `task/[parent/]<issue>-<slug>`, repo 자체 컨벤션 우선 |
| codebase 작업 사본 | `task/codebases/<repo-name>/` |

- 세그먼트 해석: 순수 숫자 = 이슈 번호, 비숫자 = home. repo 이름은 순수 숫자 불가.
- **slug 스타일**(단어 수·케이스·언어)은 persona → `AGENTS.overlay.md` 참조.

## task/ 메타 파일 규칙 (고정 — `workbench task check`가 강제)

| 파일 | 성격 | 갱신 |
|---|---|---|
| `WHITE_PAPER.md` | 토대·불변(이슈 원문 보존) | **immutable** |
| `index.md` | 신원(frontmatter)+목적+repos | repo 변경 시 |
| `status.md` | 상태 스냅샷 | **전체 덮어쓰기** (세션 멈출 때마다) |
| `log.md` | 작업 이력 | **append만** |
| `AGENTS.md` | task 안 작업법(독립 문서) | task-start가 인스턴스화 |
| `docs/researches/`,`docs/plans/` | 휘발 | create·update·delete |
| `docs/decisions/`,`docs/lessons/` | harvest | immut+supersede |
| `docs/runbooks/` | harvest | living-edit |

- log 항목 형식(고정): `## [YYYY-MM-DD HH:MM:SS] <op> · <action> <path> | <요약>`
  (op: plan·research·decide·lesson·code·review / action: create·update·delete)
- **변경 → `workbench task commit <op> <action> [path] -m …`** (log+commit+push 원자화).
- **세션 멈춤 → status 덮어쓰기 + push** (멀티디바이스 핸드오프).
- `task/codebases/`는 gitignore. 코드 동기화는 각 codebase 브랜치 push로.

## 추출 기준 (submit 판단)

올릴 가치: 재사용 가능한 결정 · 패턴과 방법 · 실패의 교훈 · 프레임워크 자체 개선.
올리지 않음: task 고유 맥락(휘발) · codebase 자체 문서(그 repo PR로) · 재도출 가능한 것.

## docs/ 위키 규칙 (고정)

```
docs/  index.md  log.md
  decisions/ index.md(앵커 표: 주제|선택|상태|→page)  NNNN-<slug>.md
  lessons/   index.md(접근|한줄|→page)  <slug>.md
  runbooks/  index.md(작업|한줄|→page)  <slug>.md
  <synthesis>.md
```

- 세 연산: **Query**(docs→task) · **Ingest**(task→docs) · **Lint**(그루밍) — 독립 스킬.
- entry 형식은 `templates/*.tmpl.md` 명세를 따른다(필드 내용은 persona).
- **typed edge**: `관계:`에 `<유형> [[대상]]`. 닫힌 어휘 — `supersedes`·`contradicts`·
  `extends`·`response-to`.
- **provenance**: entry는 `출처:`를 단다.
- **멱등**: identity=(장르,앵커). 적재는 앵커 조회 후 갱신(중복 금지). 구조만 멱등.
- 페이지 추가·이동 시 `index.md` 같은 커밋에서 갱신.
- docs 변경은 `docs/log.md`에 append(형식 위와 동일, op: extract·lint·edit).
- `*/log.md`는 `.gitattributes` `merge=union`으로 머지.

## 워크플로우와 명령 (고정)

| 단계 | 진입점 | 배관 |
|---|---|---|
| 발상 | `workbench:ticket-incubate` | `gh issue create` |
| 시작 | `workbench:task-start <ID>` | `workbench task start`, `add-repo` |
| 현황 | `workbench:task-status` / `task-tickets` | `workbench task status`/`tickets` (read-only) |
| 기록 | (변경마다) | `workbench task commit …` |
| 검사 | (언제든) | `workbench task check` (정상 무음) |
| 제출 | `workbench:task-submit` | `workbench task submit` |
| 정리 | `workbench:task-done <ID>` | `workbench task done` |

- **머지는 squash만** (repo 설정으로 강제). 일반 merge는 중간 커밋을 main에 남긴다.
- **사람 게이트(존재는 고정)**: PR 후 "머지 vs 정리", 정리 후 "티켓 처분", 증분
  흡수는 **반드시 사람에게 묻는다.** 스크립트는 티켓을 건드리지 않는다.
  (어느 게이트를 켜는지 토글은 persona → overlay.)
- 이슈 본문 형식·PR 본문 골격·라벨 정책은 persona → `AGENTS.overlay.md` 및
  `.github/` 템플릿 참조.
