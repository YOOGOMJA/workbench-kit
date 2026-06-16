## 루틴: 자율주행 세션 루프
- 언제 쓰나: 에이전트가 workbench task를 이어서 고르고 수행하고 저장하는 과정을 여러 차례 반복할 때. 특히 멀티디바이스 handoff 뒤, 열린 티켓을 훑은 뒤, 또는 한 task를 제출할지 계속할지 판단할 때.
- 단계:
  1. 현재 상태를 읽는다. `/task-status`로 task branch 상태를 보고, `/task-tickets`로 열린 티켓과 lifecycle fact를 본다. 두 명령은 read-only라 후속 행동은 제안까지만 한다.
  2. 다음 행동을 고른다. 진행 중 task가 있으면 `task/status.md`와 `task/log.md`를 먼저 읽고, 원격 전용 task는 resume 후보로 둔다. 미착수 티켓은 priority 라벨을 참고하되 자동 부여·변경하지 않는다.
  3. 새 task를 시작하거나 기존 task를 재개한다. 새 task는 `/task-start <ID>`로 시작하고, 시작 preflight에서 `/docs-query`가 기존 결정·교훈을 확인한다. 기존 task는 `task/status.md`를 첫 진입점으로 삼고 필요하면 `task/log.md`로 실제 이력을 확인한다.
  4. 작업을 수행한다. 파일 변경은 작은 단위로 만들고, 커밋은 `utils/task commit <op> <action> [path] -m ...`로 남겨 `task/log.md` append, commit, push를 한 동작으로 맞춘다.
  5. 검증한다. 변경 내용 자체의 테스트나 검사를 먼저 실행하고, task 작업 공간에서는 `utils/task check`를 실행한다. docs 링크·`[[wikilink]]` 무결성이 관련되면 `utils/docs check`도 실행한다.
  6. checkpoint를 만든다. 멈추거나 handoff하기 전에 `task/status.md`를 현재 상태로 덮어쓰고 `utils/task commit ... task/status.md -m ...`로 push한다. status에는 완료한 것, 다음 작업, 열린 질문을 남긴다.
  7. 다음 단계를 판단한다. 계속 진행할 수 있으면 4단계로 돌아가고, 증분이 제출 가능한 상태면 `/task-submit`으로 간다. 사람 게이트가 나오면 자동 진행하지 않고 멈춘다.
- 주의:
  - 배관은 사실만 만들고 산문·분류·흡수 판단은 스킬/에이전트가 한다. `utils/task status`, `utils/task tickets`, `utils/task check`, `utils/docs check`는 이 경계를 넘기지 않는다.
  - `workbench-task-lifecycle:v1` issue comment는 machine-readable fact다. 티켓 close, label 변경, 상태 분류, 독자용 설명을 대신하지 않는다.
  - `task/log.md`는 추적 파일이고 union merge 대상이다. 로그를 파생물로 취급하거나 commit trailer만으로 대체하지 않는다.
  - 자동 진행 가능: read-only 사실 조회, 파일 수정, deterministic 검증, `utils/task commit`을 통한 checkpoint/push, PR 본문 초안·검증 결과·흡수 후보 정리 같은 제출 전 준비.
  - 사람 게이트: 증분 흡수 승인, PR 머지 여부, task 정리 시점, 티켓 close/유지/후속 결정, priority 라벨 판단, 기존 decision의 supersede/contradict 확정.
  - hook이나 도구별 adapter에는 판단을 넣지 않는다. 필요하면 공통 `utils/` 명령을 호출하는 얇은 연결만 둔다.
- 출처: task#33 / 2026-06-13
- 관계:
  - extends [[0004-guard-without-hooks]]
  - extends [[0013-task-status-query]]
  - extends [[0015-task-lifecycle-events]]
  - extends [[0016-mechanical-invariant-enforcement]]
- 참조: [[0012-append-only-log-union-merge]] · [[0014-docs-check-boundary]] · [[workbench-query]]
