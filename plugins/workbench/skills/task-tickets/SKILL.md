---
name: task-tickets
description: >-
  Use to scan open workbench tickets joined with task branches and lifecycle events into unstarted / claim-attempted / in-progress / awaiting-PR / cleaned-up states. Read-only.
---

# task 티켓 현황

사용: `/task-tickets` — read-only. 어떤 후속 행동도 실행하지 않는다(제안만).

절차:

1. **배관 실행**: `workbench task tickets`
   - 빈 줄 구분 레코드를 issue별로 파싱한다. 필드:
     `issue title issue_state url branch branch_local branch_remote pr lifecycle_event
     lifecycle_claim_id lifecycle_branch lifecycle_pr`.
   - 이 배관은 `gh issue list`, `gh issue view`, `gh pr list`, git ref 조회만 한다.
     issue comment/close/label 변경은 하지 않는다.

2. **분류**:
   - 종결성 있는 lifecycle event가 branch 사실보다 우선한다. 특히
     `task-cleaned`는 origin branch가 남아 있어도 **task 정리됨**으로 분류한다.
   - **미착수**: `branch`와 `lifecycle_event`가 모두 비어 있음.
   - **착수 시도/확인 필요**: 최신 event가 `task-claimed` 또는
     `task-claim-conflict`이고 `branch_remote`가 `no`.
   - **진행 중**: `branch_remote=yes`이고 PR이 없음.
   - **PR 대기**: `pr`가 있거나 최신 event가 `task-submitted`.
   - **task 정리됨**: 최신 event가 `task-cleaned`. issue close 여부와 별개다.

3. **어긋남 진단**:
   - `task-claimed`만 있고 branch가 없으면 중간 실패 또는 다른 기기 작업 가능성.
   - `task-cleaned`인데 issue가 open이면 티켓 처분을 사람이 아직 결정하지 않은 상태.
   - branch와 lifecycle branch가 다르면 과거 시도 event가 섞였을 수 있음.

4. **렌더**:
   - 표 컬럼: 티켓 | 파생 상태 | branch | PR | lifecycle | 비고.
   - 비어 있는 분류도 "(없음)"으로 명시한다.
   - 마지막 한 줄 요약: `미착수 N · 착수 시도 N · 진행 N · PR 대기 N · 정리됨 N`.

5. **read-only 엄수**:
   - `/task-start`, `/task-done`, issue close, label 변경, comment 작성은 제안만 한다.
