## 결정: 증분 흡수 승인 게이트의 위치
- 상태: 채택
- 선택: task 산출물을 main(`docs/`·`AGENTS.md`·`skills/`)에 흡수하기 전,
  `/task-submit`이 후보를 세 버킷(흡수 추천/비추천/후속 티켓 이관)으로 보고하고
  사람의 승인을 받는다. 게이트는 **호출자 레이어(task-submit)**에 두고,
  피호출자(`docs-ingest`)에는 승인된 후보 범위만 전달한다. 보고는 특정 하네스
  도구가 아니라 순수 마크다운 표로 한다(에이전트 중립).
- 맥락: docs-ingest를 호출하면 곧바로 docs/에 weave돼, 무엇을 흡수·폐기·이관할지
  사람이 정하기 전에 main에 살아남을 문서가 수정됐다(발견 경로 #3).
- 이유: 흡수는 비가역에 준하는 판단이라 사람의 몫이다. 게이트를 공용 연산
  (docs-ingest)에 박으면 ad-hoc 단독 호출까지 게이트가 걸려 과해진다 — 흡수
  결정의 자리인 task-submit에 두는 게 책임 분리상 맞다. 승인 범위 전달로
  docs-ingest의 재평가 중복도 닫는다.
- 기각한 대안: ① docs-ingest를 plan(dry)·weave 2페이즈로 분리 → 멀쩡한 공용
  스킬을 크게 뜯고 단독 호출 경로를 복잡하게 함, 이슈 scope 초과. ② 게이트를
  docs-ingest에 박기 → ad-hoc 호출까지 게이트, 과함. ③ AskUserQuestion 등
  하네스 도구로 보고 → codex/gemini에서 깨짐.
- 출처: workbench#8 / 2026-06-12
- 관계:
  - extends [[0004-guard-without-hooks]]
- 참조: [[workbench-knowledge-ecosystem]]
