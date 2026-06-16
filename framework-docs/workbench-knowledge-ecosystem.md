# Workbench 지식 생태계

`docs/` 위키가 어떤 구조로 이루어지고, 어떻게 소비·생산·정돈되는지를 다루는
큰 그림 페이지. 세부 연산 절차는 스킬에 위임한다.

## 2×2 틀 + 이음새

|              | 구성 (정적·명사)     | 라이프사이클 (동적·동사)    |
|--------------|----------------------|-----------------------------|
| **task**     | ① task/ 폴더 + 장르  | ② task 마이크로 사이클      |
| **workbench**| ③ docs/ 위키 레이아웃| ④ 세 연산 (Query/Ingest/Lint)|

①③은 구조, ②④는 흐름. 둘을 잇는 **이음새**가 first-class다:

- **Query** — docs/ → task (인바운드): 시작 task가 선행 지식을 가져온다.
- **Ingest** — task → docs/ (아웃바운드): 제출 task가 수확물을 위키에 짜 넣는다.

## task 안의 두 운명

task/ 안의 내용은 운명이 둘로 갈린다:

1. **휘발 작업 맥락** — status, log, plans, researches. cleanup으로 사라지는 게 맞다.
2. **harvest(수확)** — decisions/lessons/runbooks의 살아남을 것. cleanup 전에 docs/로 ingest되어 남는다.

장르별 규율:

| 장르 | task/docs/ | workbench docs/ |
|------|-----------|-----------------|
| researches/, plans/ | 휘발(volatile) | 없음 |
| decisions/ | staging → harvest | 영구(immut+supersede) |
| lessons/ | staging → harvest | 영구(immut+supersede) |
| runbooks/ | staging → harvest | living-edit |
| synthesis/topic | 없음 | cross-task 큰그림 |

workbench는 **작업장이 아니라 지식 레이어**다. 모든 작업은 task 워크트리 안에서만
일어나며, `docs/`에 plans/도 superpowers/도 없다.

## 세 레이어

- **`docs/`** — 지식(harvest + synthesis). task가 채운다.
- **`utils/`** — 배관 스크립트(git 상태 전이).
- **`templates/`** — 형식 명세(데이터). harvest entry 형식(`*.tmpl.md`)과
  `task-AGENTS.md` 정본이 산다. 작성(task/AGENTS.md 지연참조)·검증(`docs-lint`)·
  적재(`docs-ingest` index 파생)가 모두 이 단일 출처를 참조한다.

## harvest 폴더와 앵커 표

```
docs/
  decisions/
    index.md   # 앵커 표 — 주제 | 선택 한줄 | 상태 | →page
    NNNN-<slug>.md
  lessons/
    index.md   # 앵커 표 — 접근 | 한줄 | →page
    <slug>.md
  runbooks/
    index.md   # 앵커 표 — 작업 | 한줄 | →page
    <slug>.md
```

각 폴더의 `index.md`가 **소비 표면**이다. 개별 페이지는 전체 맥락을 보존하고,
index는 빠른 스캔을 위한 앵커 표로 유지된다.

## 소비 모델

| 페이지 유형 | 소비 메커니즘 | 시점 |
|-------------|---------------|------|
| decisions/ | 가드: index 앵커 스캔 → 히트 시 따르거나 명시적 supersede | decide 직전 |
| lessons/ | 가드: index 앵커 스캔 → 회피 또는 제약 우회 | 접근 직전 |
| runbooks/ | task/AGENTS.md `@`지연참조 (점진적 공개) | 해당 작업 시 |
| synthesis | [[workbench-query]] preflight 읽기 | task-start |

**가드는 세 체크포인트에 걸린다**: task-start(preflight) / 작업 중(log decide 이벤트 트리거) /
task-submit(Ingest 백스톱). 훅 불필요 — 가드는 이미 의무화된 이벤트 흐름에 올라타며,
에이전트 판단으로 닫힌다. 하네스 의존 0.

## 세 연산

| 연산 | 방향 | 스킬 | 시점 |
|------|------|------|------|
| **Query** | docs/ → task (읽기) | `/docs-query` | task-start + 작업 중 ad-hoc |
| **Ingest** | task → docs/ (짜 넣기) | `/docs-ingest` | task-submit |
| **Lint** | docs/ 내부 (그루밍) | `/docs-lint` | 유지보수 task + Ingest 중 기회적 |

**이음새 계약 — 셋이 맞물린다**:
- Ingest는 쌓지 않고 짠다(weave-not-pile): 기존 갱신 우선, 중복·고아 없이, supersede 적용.
- Lint는 주기 그루밍: 모순·고아·깨진 상호참조·supersede 누적을 정리해 index를 스캔 가능하게 유지.
- Query는 발견을 보장받는다: Ingest가 깨끗이 넣고 Lint가 정돈해야 Query가 관련 선행 지식을 반드시 찾는다.

세 연산의 계약이 맞물려 workbench 라이프사이클이 닫힌다.

## 관련

- [[workbench-query]] — Query 연산 상세
