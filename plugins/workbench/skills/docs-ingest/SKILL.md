---
name: docs-ingest
description: >-
  Use to weave task harvest (decisions/lessons/runbooks/researches) into the workbench docs/ wiki. Called by task-submit, or whenever knowledge that should survive the task needs to land in docs/.
---

# docs-ingest

Ingest 연산 — task에서 살아남을 지식을 `docs/`에 짜 넣는다.

> **승인 범위**: `task-submit`이 이 스킬을 호출할 때는 이미 사람의 흡수 승인을
> 거친 후다 — 호출자가 **승인된 후보 범위**를 지정하면 그 범위로 한정해 적재하고,
> 범위 밖 항목은 건드리지 않는다. 범위 지정이 없는 ad-hoc 단독 호출이면 아래
> 절차대로 전체를 평가한다.

AGENTS.md의 추출 기준과 docs/ 위키 규칙을 따른다. 절차:

1. **task harvest 읽기**: `task/docs/decisions/`, `task/docs/lessons/`,
   `task/docs/runbooks/`를 읽는다. 내구성 있는 조사 결과라면
   `task/docs/researches/`와 `task/WHITE_PAPER.md`도 읽는다.
   - **휘발 문서(`task/docs/plans/`·`researches/`)에 묻힌 재사용 결정·교훈도
     끌어낸다.** 이것들은 cleanup으로 사라지므로, 적재는 반드시 cleanup
     *이전*에 끝낸다 — 안 그러면 결정이 휘발 스펙과 함께 죽는다.

2. **추출 평가** (판단): AGENTS.md 추출 기준에 따라 각 항목을 분류한다.
   - 올린다: 재사용 가능한 결정, 패턴·방법, 실패의 교훈, 반복 루틴
   - 버린다: task 고유 맥락(진행 상황, 코드 리뷰 코멘트), codebase에
     귀속될 내용, 원본에서 재도출 가능한 것
   - **승인 범위가 주어진 경우**(task-submit 호출): 여기서 새로 평가해 범위를
     넓히지 않는다. 사람이 승인한 후보 목록을 그대로 따르고, 범위 밖 항목은
     올리지 않는다. 평가는 이미 task-submit의 보고·승인에서 끝났다.

3. **weave-not-pile** (쌓기 전에 짠다): 신규 페이지를 만들기 전에
   기존 페이지와 겹치는지 확인하고, 겹치면 기존 페이지를 갱신한다.
   - Ingest는 entry를 *새로 저술하지 않는다*. author가 `templates/`의 형식
     명세대로 써둔 entry 구조를 *보존*하고, **index 행을 파생**한다 —
     템플릿 상단 `index row 매핑` 주석(필드→컬럼)을 따른다.
   - **멱등 (같은 주제는 한 칸)**: 적재 전 각 항목의 앵커로 그 폴더의
     `index.md`를 먼저 조회한다 — **있으면 그 entry를 in-place 갱신**(새 파일을
     만들지 않는다), 없으면 생성. index 행은 앵커 기준 정렬해 추가 순서
     artifact를 없앤다. 같은 `출처:`의 동일 내용 재적재는 no-op이다(다시 쌓지
     않는다). 멱등은 *구조*(앵커 집합·엣지·행)에 한한다 — 문장 표현은 달라져도 된다.
   - **decisions·lessons**: `docs/decisions/` 또는 `docs/lessons/`에
     entry page를 생성하거나 기존 page를 갱신한다. 그 폴더의 `index.md`
     앵커 표에 행을 추가한다(주제/접근 = 앵커, 선택·상태·"무엇이 망했나"는
     entry 필드에서 파생).
   - **supersede(대체)**: 새 결정·교훈이 기존 것을 대체하는 경우,
     옛 page 상태를 `대체됨`으로 표기하고 옛 index 행을 Archive 섹션으로
     이동한다. 절대 delete하지 않는다 — 이력은 보존된다. 동시에 새 entry A의
     `관계:`에 `supersedes [[옛-page]]`를 추가한다. 옛 page의 `대체됨` 표기는
     역방향, 새 entry의 `supersedes` 엣지는 순방향 — 같은 사실의 양면이다.
   - **provenance**: 각 entry 승격 시 `출처:`(task#N / PR#M / 날짜)를 채운다.
   - **모순 발견 시**: 새 지식이 기존 페이지와 *대체가 아니라 충돌*하면,
     양쪽 entry의 `관계:`에 `contradicts [[상대]]`를 단다. 어느 쪽도 지우지
     않는다 — 충돌을 표면에 남긴다.

4. **runbooks**: `docs/runbooks/`에 page를 생성하거나 기존 page를 갱신한다.
   `docs/runbooks/index.md` 앵커 표에 행을 추가(또는 갱신)한다.

5. **durable 영역 synthesis**: `task/docs/researches/` 또는
   `task/WHITE_PAPER.md`에서 내구성 있는 이해가 나왔다면, 관련 주제로
   `docs/`에 평면 토픽 페이지를 생성하거나 기존 토픽 페이지를 갱신한다.
   토픽 페이지는 특정 task를 넘어 적용될 때만 만든다.

6. **index·교차링크 동기화**: 페이지를 추가하거나 이동하면 그 폴더의
   `index.md`를 **같은 커밋**에서 갱신한다. `docs/index.md`에도 새 폴더나
   항목이 생겼다면 반영한다. 관련 페이지는 `[[파일명]]`으로 교차링크한다.

7. **local lint**: 이번에 건드린 영역을 점검한다.
   - 중복: 같은 주제를 다루는 페이지가 둘 이상인지
   - 고아: index.md에 없는 페이지, index.md에 있으나 파일이 없는 항목
   - 깨진 링크: `[[파일명]]` 참조 대상이 실제로 존재하는지
   - 이상이 있으면 고치고, 이상이 없으면 넘어간다.

8. **docs/log.md append**: 작업한 각 파일에 대해 한 줄씩 기록한다.
   형식: `## [YYYY-MM-DD HH:MM:SS] extract · <action> <path> | <요약>`
   (`action` ∈ `create` / `update` / `delete`)
