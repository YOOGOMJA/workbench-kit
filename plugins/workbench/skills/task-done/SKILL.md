---
name: task-done
description: >-
  Use when the user asks to clean up or discard a task, or to clear the workspace after a PR is merged.
---

# task 정리

사용: `/task-done <ID>` (ID 예: `42` 또는 `my-app#42`)

절차:

1. **상태 확인**: 해당 task의 PR이 머지됐는지 확인한다 (`gh pr list/view`).
   - 머지 전이거나 PR이 없으면(작업 폐기) 멈춘다 — 정리는 되돌릴 수 없다.
     잃게 될 것(push 안 된 커밋·브랜치, task 기록)을 나열해 보여주고
     **명시적 확인을 받은 뒤에만** 진행한다.
   - "묻지 말고 치워줘" 같은 정리 요청 자체는 이 확인이 아니다 — 사용자는
     무엇이 사라지는지 모른 채 말했을 수 있다.
   - 예외: 스캐폴드 외 아무 작업 내용이 없음을 검증한 경우(잃을 것이 0)에는
     그 사실을 보고하고 진행해도 된다.
2. **배관 실행**: `workbench task done <ID>`
   - 커밋 안 된 변경 때문에 실패하면, 무엇이 남아 있는지 보여주고 폐기해도
     되는지 물은 뒤에만 `--force`를 쓴다.
   - 정리가 성공하면 `task-cleaned` lifecycle event를 남긴다. 이 event는 issue
     close가 아니며, 아래 티켓 처분 게이트를 대체하지 않는다.
3. **사람 게이트 — 티켓 처분**: 반드시 묻는다 —
   "이슈(티켓)를 어떻게 할까요? (a) 닫기 (b) 열어두기 (c) 후속 이슈를 만들고 닫기"
   - 답에 따라 `gh issue close` / 유지 / `gh issue create` + close를 수행한다.
   - codebase 이슈면 해당 repo에서, workbench 이슈면 workbench에서.

   이 질문은 어떤 경우에도 생략하지 않는다:
   - 사용자가 "알아서 해줘"라고 했어도 — 티켓 처분은 비가역적이고 소유자
     판단의 영역이다
   - 정리 요청에 티켓 닫기가 포함됐다고 추정하지 않는다
4. origin에 남은 task 브랜치 처리도 함께 묻는다 (보존=아카이브 / 삭제).
5. 정리 결과를 보고한다.
