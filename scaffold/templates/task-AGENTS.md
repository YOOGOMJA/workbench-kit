# AGENTS.md

이 task 안에서 일하는 법. 독립 문서다(루트 AGENTS.md를 상속하지 않는다).

---

## 기록 규칙

모든 기록은 고정 형식·순서를 따르며, AI가 작성·관리한다.

1. **파일 변경 → `workbench task commit <op> <action> [path] -m "<subject>"`**
   log append·commit·push를 한 동작으로 한다(이중 기입 제거).
   op ∈ plan·research·decide·lesson·code·review, action ∈ create·update·delete.
   커밋 subject는 컨벤션대로, 이슈 ref `(#N)`는 자동 주입된다.

2. **세션 멈춤 → `status.md` 전체 덮어쓰기 + push**
   멀티디바이스 핸드오프 지점 — push가 없으면 다른 기기에서 볼 수 없다.

3. **문서 참고 시 → 참조 링크**
   사용처에 `[[파일명]]` 형태로 provenance 씨앗을 남긴다.

4. **docs 폴더에 페이지 추가 → 그 폴더 index.md 같은 커밋에서 갱신**
   index.md는 앵커 표(소비 표면)이므로 항상 최신 상태여야 한다.

---

## 장르별 규율

| 문서 | 규율 | 합법 action |
|------|------|-------------|
| `WHITE_PAPER.md` | immutable — 원문 보존 | 읽기만 |
| `index.md` | overwrite — 신원·목적·완료 | create, update |
| `status.md` | overwrite — 상태 스냅샷 | create, update |
| `log.md` | append-only | append |
| `docs/decisions/` | immut+supersede | create, update(상태) — delete 없음 |
| `docs/lessons/` | immut+supersede | create, update(상태) — delete 없음 |
| `docs/runbooks/` | living-edit | create, update |
| `docs/researches/`, `docs/plans/` | volatile — 휘발 | create, update, delete |

---

## 제안·계획 전 가드

- **결정 전** → `docs/decisions/index.md` 앵커 표 스캔 (이미 정했나?)
- **접근 전** → `docs/lessons/index.md` 앵커 표 스캔 (이미 망했나?)
- **실행계획 전** → `docs/runbooks/index.md` 앵커 표 확인

히트 시: 선행 결정을 따르거나, 새 ADR로 명시적 supersede한다.

---

## harvest 항목 형식 — 쓸 때 연다

harvest 항목을 쓸 때는 정본 형식 명세를 따른다(점진적 공개).
필드 순서·앵커·index 매핑이 명세에 고정돼 있다.

- 결정(ADR) 작성 시 → @../templates/decision.tmpl.md
- 실패 교훈 작성 시 → @../templates/lesson.tmpl.md
- 루틴 작성 시 → @../templates/runbook.tmpl.md

## 상황별 — 필요할 때 따른다

`docs-query` preflight가 이 task에 맞는 `docs/runbooks/` 참조를 *실재하는
것만* 아래에 추가한다(점진적 공개). 비어 있으면 해당 runbook이 아직 없다는
뜻 — 추측하지 말고 docs-query로 확인한다.

<!-- preflight가 채운다. 예) `- codebase 작업 시 → @../docs/runbooks/<있는-페이지>.md` -->
(아직 없음)
