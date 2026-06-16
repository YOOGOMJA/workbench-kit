## 결정: 정본 형식 템플릿의 거처
- 상태: 채택
- 선택: harvest entry 형식 명세(`*.tmpl.md`)와 `task-AGENTS.md`를 **최상위 `templates/`**에 둔다.
- 맥락: 템플릿은 소비자(작성·검증·적재)가 읽는 *데이터*지, git 상태를 전이시키는 *스크립트*가 아니다.
- 이유: 두 레이어를 "배관=스크립트(utils/) + 데이터=템플릿(templates/)"로 정직하게 확장. `docs/`(지식)도 `utils/`(배관)도 아닌 별도 레이어가 카테고리상 맞다.
- 기각한 대안: ① `utils/templates/`(utils=배관 원칙을 늘림, 이미 새던 곳) ② `docs/runbooks/`(거긴 harvest 장르 — 시스템 명세를 섞음) ③ docs-ingest 스킬에 임베드(단일 소유, 작성·검증 측이 못 봄).
- 출처: workbench#4 / PR#9 / 2026-06-11
- 참조: [[workbench-knowledge-ecosystem]] · [[0009-pr-body-skeleton]]
