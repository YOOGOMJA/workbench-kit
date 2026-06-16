---
name: task-start
description: >-
  Use when the user asks to start a task, pick up an issue, or begin a new attempt, or hands over an issue number to start work.
---

# task 시작

사용: `/task-start <ID> [slug]` (ID 예: `42` 또는 `my-app#42`)

AGENTS.md의 규칙을 따른다. 절차:

1. **배관 실행**: `workbench task start <ID>`
   - 이슈 제목 조회가 실패하면 이슈 내용을 보고 slug를 직접 지어 재시도한다
     (`workbench task start <ID> <slug>`)
   - 배관은 `task-claimed` lifecycle event를 남기고, scaffold commit을 즉시 push한
     뒤 `task-active` event를 남긴다. 이 덕분에 다른 기기에서 바로 resume 가능하다.
2. 생성된 작업 공간(`.worktrees/task__...`)으로 이동한다.
3. **이슈 원문 확인** (판단): `task/WHITE_PAPER.md`를 읽는다. 없으면
   `gh issue view`로 조회한다. 이슈 조회가 끝내 불가능하면 (인증 실패 등)
   사용자에게 이슈 내용을 직접 물어본다. 빈 요약으로 진행하지 않는다.
4. **Query 선행 조회** (판단): `/docs-query` 스킬을 호출한다. 이슈 원문을
   질문으로 삼아 task-start preflight 모드로 실행한다. 결과는
   `task/index.md`의 선행조회 섹션에 기록된다.
5. **이슈 요약 작성** (판단): 이슈 원문과 Query 결과를 바탕으로
   `task/index.md`의 본문에 채운다 —
   - 이 task의 목적 (한 문단)
   - 완료 조건 (이슈에서 도출)
   - 선행 조회: `/docs-query`가 기록한 내용 (확인한 문서, 관련 내용,
     이번 task에 주는 제약/힌트; 관련 문서가 없으면 "관련 선행 문서 없음")
   - 첫 접근 방향 (있다면)
   - frontmatter와 repos 블록은 스크립트 영역이므로 형식을 건드리지 않는다.
6. `task/status.md`를 현재 상태로 덮어쓴다.
7. 요약·status 변경을 커밋하고 push한다. scaffold는 이미 배관이 push했지만,
   선행조회와 목적 요약은 이 단계에서 동기화된다.
8. 사용자에게 보고: task ID, 작업 공간 경로, 요약한 목적, 선행 조회 결과,
   다음에 할 일 제안.
