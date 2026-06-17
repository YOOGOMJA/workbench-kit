<p align="center">
  <img src="assets/workbench-kit.png" width="160" alt="workbench-kit" />
</p>

<h1 align="center">workbench-kit</h1>

<p align="center">
  <em>레포 새로 파고 AGENTS.md 쓰는 데 지친 메타몽들의 작업대.</em>
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-early%20stage-orange" alt="status" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="license" /></a>
  <img src="https://img.shields.io/github/last-commit/YOOGOMJA/workbench-kit" alt="last commit" />
  <img src="https://img.shields.io/badge/PRs-welcome-brightgreen" alt="PRs welcome" />
</p>

---

새 아이디어마다 레포를 새로 팝니다. AGENTS.md를 또 씁니다. 어디서 시작할지부터
막힙니다. 뭐든 될 수 있는 메타몽이라, 매번 아무것도 아닌 채로 시작하니까요.

그 셋업, 작업대에 맡기세요. 뭐든 올려놓고 일하면, 끝났을 때 쓸 만한 한 조각만
남고 나머지는 치워집니다. 새 레포가 필요해도 그냥 또 하나의 작업입니다.

> 🚧 **초기 단계.** 프레임워크는 동작하지만 API와 문서는 아직 다듬는 중입니다.
> 거친 부분이 있으니 [알려진 한계](#상태--알려진-한계)를 읽어 주세요.

<p align="center">
  <img src="demo/workbench-engine.gif" width="900" alt="실제 에이전트가 /workbench:task-start 로 스킬을 로드하고 배관·docs-query preflight·요약·커밋까지 수행" />
  <br/>
  <em>실제 Claude Code 에이전트가 <code>/workbench:task-start</code>로 task 수명주기를 구동 (오프라인 데모).</em>
</p>

## 무엇을 얻나

workbench-kit은 함께 동작하는 두 플러그인의 **마켓플레이스**입니다. 둘 다 설치하세요.

| 플러그인 | 역할 | 이걸로… |
|---|---|---|
| **`workbench`** | **엔진.** 워크트리/task 격리, 점진적 지식 수확, 스킬 기반 task 수명주기. | 일상 작업을 굴립니다 — task 시작·제출, 남길 것 수확. |
| **`workbench-kit`** | **부트스트랩.** 당신의 컨벤션을 인터뷰한 뒤, 개인화된 최소 워크벤치 레포를 생성. | *새* 워크벤치를 취향에 맞춰 한 번 세팅합니다. |

**도구 중립적**입니다 — 같은 `skills/` 소스가 Claude Code와 Codex 양쪽에 설치됩니다.
"Bring your own rules" — 메커니즘은 고정, 당신의 컨벤션은 자유입니다.

## 설치

**Claude Code**

```
/plugin marketplace add YOOGOMJA/workbench-kit
/plugin install workbench@workbench-kit
/plugin install workbench-kit@workbench-kit
```

**Codex**

```
codex plugin marketplace add https://github.com/YOOGOMJA/workbench-kit
codex plugin add workbench
codex plugin add workbench-kit
```

요구사항: Claude Code **또는** Codex, `git`(워크트리 지원), 이슈·PR 배관용 `gh` CLI.

## 빠르게 시작하기

**1. 워크벤치 만들기 (한 번).** 부트스트랩 플러그인이 짧은 인터뷰를 거쳐,
당신의 컨벤션에 맞춘 최소 레포를 생성합니다:

```
/workbench-kit:interview-for-personalizing   # 당신의 persona를 끌어냄
/workbench-kit:generate-workbench            # 레포를 생성하고 초안은 버림
```

<p align="center">
  <img src="demo/workbench-kit-bootstrap.gif" width="820" alt="실제 에이전트가 인터뷰 후 generate-workbench로 최소 워크벤치 레포를 합성" />
</p>

생성물은 **의도적으로 최소**입니다 — 당신 것만. 엔진(skills·`utils/`·`bin/`)은
설치된 플러그인에 남고 복사되지 않습니다:

```
my-workbench/
├── AGENTS.md          # 합성본: 프레임워크 core + 당신의 persona (직접 편집 금지)
├── CLAUDE.md          # 동일 내용 (Claude Code가 읽음); 재합성 시 함께 갱신
├── AGENTS.overlay.md  # 당신의 규칙 — 여기서 편집 후 재합성
├── codebases.yaml     # 작업 대상 repo
├── docs/              # 지식 위키, 빈 채로 시작해 작업하며 채워짐
│   ├── decisions/  lessons/  runbooks/   # 앵커 표 ("이미 정했나?")
│   └── index.md  log.md
├── templates/         # harvest 항목 + task-AGENTS 형식 (당신이 조정)
├── .github/           # 이슈(4요소) + PR 템플릿
└── .claude/settings.json  # 폴더 신뢰 시 workbench 엔진 플러그인 자동 활성 (수동 설치 불필요)
```

생성된 repo를 Claude Code에서 열고 폴더를 신뢰하면 마켓플레이스가 등록되고 `workbench`
엔진 플러그인이 자동 활성됩니다. (Codex는 마켓플레이스를 한 번 추가 — Install 참고.)

**2. 새 워크벤치 안에서 작업하기.** 엔진 플러그인이 task 수명주기를 굴립니다 —
각 task는 자기 브랜치·워크트리에 살고, 정제된 증분만 `main`에 남습니다:

```
/workbench:task-start <issue>     # 브랜치 + 워크트리 + task/ 작업 공간
# … 작업 …
/workbench:task-submit            # task/ 정리, squash PR 생성
/workbench:task-done <issue>      # 머지 후 작업 공간 정리
```

그 밖의 진입점: `/workbench:ticket-incubate`(아이디어 → 이슈),
`/workbench:task-status` · `/workbench:task-tickets`(읽기 전용 현황),
지식 위키용 `docs-query` · `docs-ingest` · `docs-lint` 스킬.

## 어떻게 동작하나

- **작업은 휘발, 지식은 축적.** 모든 일은 task 브랜치에서 일어나고, 끝나면 `task/`를
  정리한 뒤 **squash 머지**합니다. `main`엔 정제된 증분 하나만 남고, 탐색 과정은
  치워집니다.
- **두 레이어.** *판단*(무엇을 추출할지, 산문)은 에이전트가, *배관*(git 상태 전이)은
  `utils/`가 합니다. 에이전트의 진입점은 항상 스킬입니다.
- **`AGENTS.core` + `AGENTS.overlay` → `AGENTS.md`.** 프레임워크 코어는 고정·영어이며
  (업그레이드가 덮어씀), 당신의 persona — 언어, slug 스타일, 이슈·PR 형태, 라벨,
  게이트 — 는 overlay에 둡니다. 부트스트랩이 둘을 합성합니다.

배경과 설계 이유는
[`framework-docs/workbench-knowledge-ecosystem.ko.md`](framework-docs/workbench-knowledge-ecosystem.ko.md)에,
개별 설계 결정은 [`framework-docs/decisions/`](framework-docs/decisions/) 아래 ADR로
기록되어 있습니다.

## 레포 구조

```
plugins/
  workbench/        엔진 — skills, utils/, bin/workbench, tests/
  workbench-kit/    부트스트랩 — interview + generate-workbench 스킬,
                    그리고 사용자 레포에 까는 scaffold/ (AGENTS.core.md 포함)
framework-docs/     설계 결정·교훈·런북·종합
scripts/            릴리스 툴링 (bump / version-sync / release)
tests/              frontmatter · install-model · CI 검사
AGENTS.md           레포/개발 가이드 (kit 자체를 개발할 때)
```

scaffold는 부트스트랩 플러그인 **안에** 있어 마켓플레이스 설치 시 함께 패키징됩니다;
엔진은 `${CLAUDE_PLUGIN_ROOT}`로 읽습니다.

## 상태 & 알려진 한계

- **초기 단계**, 첫 릴리스(`0.1.0`) 진행 중. [CHANGELOG.md](CHANGELOG.md) 참고.
- **번역 진행 중.** 프레임워크 표면(이 README, `AGENTS.core`, scaffold, 부트스트랩
  스킬)과 모든 스킬 *설명*은 영어입니다. 엔진 스킬 *본문*과 `framework-docs/`는 아직
  한국어이며, 점진적으로 번역됩니다.

## 문서

- [CHANGELOG.md](CHANGELOG.md) — 릴리스별 변경 내역
- [RELEASING.md](RELEASING.md) — 릴리스 컷 방법 (메인테이너용)
- [framework-docs/](framework-docs/) — 설계 결정·교훈·런북

## 기여

PR 환영합니다. 동작에 영향을 주는 변경은 [CHANGELOG.md](CHANGELOG.md)의
`## [Unreleased]` 아래에 한 줄을 추가합니다. CI는 frontmatter 린트, 매니페스트 파싱,
버전 sync, ShellCheck, 수명주기/compose 스모크 테스트를 돌립니다 —
[`.github/workflows/ci.yml`](.github/workflows/ci.yml) 참고.

## 라이선스

[MIT](LICENSE).
