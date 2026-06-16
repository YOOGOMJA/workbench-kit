## 결정: docs 연산의 형태
- 상태: 채택
- 선택: docs 위키의 세 연산(Query / Ingest / Lint)을 **독립 스킬**(`docs-query`·`docs-ingest`·`docs-lint`)로 만들고, 워크플로우 스킬(task-start/submit)이 호출한다.
- 맥락: 연산은 재사용 가능한 절차이고 여러 워크플로우가 같은 단위를 부른다.
- 이유: 모놀리식 task-* 스킬에 인라인하면 중복·드리프트가 생긴다. 스킬로 추출하면 단일 정본 + 독립 호출이 된다.
- 기각한 대안: AGENTS.md 산문 규칙으로만 기술 → 절차가 호출 단위가 못 되고 워크플로우마다 재서술됨.
- 출처: workbench#4 / PR#9 / 2026-06-11
- 참조: [[workbench-knowledge-ecosystem]]
