## 결정: task lifecycle event 경계
- 상태: 채택
- 선택: GitHub issue comment에 남기는 `workbench-task-lifecycle:v1` marker는
  **machine-readable 배관 event**로만 운용한다. `utils/task`는 고정 schema event
  (`task-claimed`, `task-active`, `task-submitted`, `task-cleaned` 등)를 append-only로
  남길 수 있지만, 티켓 처분(issue close), 라벨 변경, 독자용 산문, 상태 분류는
  스킬/사람 게이트가 맡는다.
- 맥락: 다른 로컬에서 task branch가 아직 보이지 않는 구간에는 같은 티켓을 중복
  착수할 수 있다. 단순 `started` 라벨은 기존 라벨 정책과 충돌하고 회수 누락으로
  상태가 부패한다.
- 이유: issue comment event는 중앙에서 관측 가능한 fact라 멀티디바이스 조인에
  유용하다. 하지만 comment는 atomic lock이 아니므로 정본 상태가 아니라
  `claim_id`와 `task_branch`로 상관되는 event log로 제한해야 한다. 최종 판단은
  원격 branch, PR 상태, issue state, lifecycle event를 조회 시 조인해 만든다.
- 기각한 대안: ① `started`/`in-progress` 라벨(라벨 정책 위반, 회수 누락 위험)
  ② issue 본문 체크박스 수정(동시성·충돌·본문 오염) ③ comment를 lock으로 취급
  (원자성 없음, 중복 claim race를 막지 못함).
- 출처: workbench#29 / 2026-06-13
- 관계:
  - extends [[0011-issue-label-policy]]
  - extends [[0013-task-status-query]]
- 참조: [[0004-guard-without-hooks]]
