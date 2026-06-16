## 결정: typed edge·provenance 표기
- 상태: 채택
- 선택: entry에 `관계: <유형> [[대상]]`(닫힌 4종, 능동 supersedes·contradicts·extends / 휴면 response-to)과 `출처:`(페이지 레벨)를 둔다. 무유형 `[[ref]]`는 see-also로 유지.
- 맥락: 무유형 wikilink만으로 대체·모순을 추적할 수 없었다.
- 이유: supersedes·contradicts는 뒤집힌 결론을 피하게 하고, extends는 기존 결정 위에 쌓인 후속 결정을 Query에서 함께 보게 한다. response-to는 아직 소비처가 없으므로 표기는 받되 휴면으로 둔다. 정본은 templates 한 곳, 검증은 docs-lint(훅 없이).
- 기각한 대안: ① frontmatter 엣지(entry에 frontmatter 없음) ② 전 링크 유형 강제(YAGNI) ③ claim-레벨 provenance(무거움, #6).
- 출처: workbench#5 / 2026-06-12
- 관계:
  - extends [[0005-types-carved-by-consumption]]
- 참조: [[workbench-knowledge-ecosystem]]
