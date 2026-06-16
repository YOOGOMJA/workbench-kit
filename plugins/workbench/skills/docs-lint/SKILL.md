---
name: docs-lint
description: docs/ 위키의 모순·낡음·고아 페이지·깨진 상호참조·supersede 누적을 점검·정리할 때 사용. 유지보수 task나 ingest 중 기회적으로.
---

# docs-lint

Lint 연산 — `docs/` 위키의 정합성과 스캔 가능성을 유지한다.

두 가지 cadence로 실행된다:
- **기회적(local)**: docs-ingest 중 건드린 영역에 한해 즉시 점검.
- **전용(global)**: 유지보수 task에서 위키 전체를 대상으로 점검.

기계적으로 판정 가능한 링크 무결성은 먼저 `workbench docs check`로 확인한다.
이 명령은 read-only 배관이며 `docs/index.md`와 장르 index의 markdown link,
inline code 밖 `[[wikilink]]` 대상 존재만 검사한다. 모순 판단, supersede 의미,
provenance, 템플릿 conformance, 로그 그루밍은 여전히 이 스킬의 판단 영역이다.

AGENTS.md의 docs/ 위키 규칙을 따른다. 절차:

1. **기계 링크 check**: `workbench docs check`를 실행해 깨진 markdown link와
   현재 존재해야 하는 `[[wikilink]]`를 먼저 잡는다. 실패하면 출력의
   `ERROR path:line ...`를 따라 고친 뒤 다시 실행한다.

2. **모순·낡은 주장 점검**: 페이지 간 상충되는 내용, 현재 운영 방식과 맞지
   않는 낡은 주장을 찾아 수정 또는 주석을 단다. 기회적 실행 시 건드린
   페이지와 직접 연결된 영역만 점검한다.

3. **고아·깨진 링크 점검·수정**: 각 폴더의 `index.md`에 없는 고아 페이지,
   `index.md`에는 있으나 파일이 없는 항목, `[[파일명]]` 참조 대상이 실제로
   존재하지 않는 깨진 상호참조를 찾아 고친다. `workbench docs check`가 잡지 않는
   고아 페이지·의도적 미래 링크 여부는 여기서 판단한다.

4. **entry 형식 점검 (conformance)**: `docs/decisions/`·`lessons/`·`runbooks/`의
   각 entry 페이지가 `templates/{decision,lesson,runbook}.tmpl.md`의 필수
   섹션(앵커 제목 + 필드)을 갖췄는지 확인한다. 누락 섹션은 보완하고, 형식
   이탈은 명세에 맞춰 정렬한다. 또 entry의 필드값과 그 폴더 `index.md`
   앵커 행이 템플릿의 `index row 매핑` 주석대로 일치하는지 대조한다(주제/접근/
   작업·선택·상태·무엇이 망했나 등). 기회적 cadence에선 건드린 entry만,
   전용 cadence에선 전체를 점검한다.

   또한 typed edge·출처를 점검한다 — ① `관계:`의 엣지 유형이 닫힌 어휘
   (`supersedes`/`contradicts`/`extends`/`response-to`)에 속하는가 ② `[[대상]]`이
   실재하는가 ③ `supersedes` 엣지가 대상의 `상태: 대체됨`/Archive와 일치하는가
   ④ entry에 `출처:`가 있는가. 이탈은 보완·정렬한다.

   **앵커 dedup**: 같은 장르에서 동일 앵커(주제/접근/작업)를 가진 entry가 둘
   이상이면 하나로 **병합**한다 — 최신/대체 관계는 `상태`·`관계: supersedes`로
   판단한다. 같은 앵커 중복은 멱등 위반이다.

5. **supersede archival**: `docs/decisions/index.md`와
   `docs/lessons/index.md`의 주 표에서 상태가 `대체됨`인 항목을 찾아
   `## Archive (대체됨)` 섹션으로 이동한다. 살아있는 표를 작고 스캔
   가능하게 유지하는 것이 목적이다. 항목을 delete하지 않는다 — 이력은
   보존된다.

6. **synthesis 페이지 병합·분할 판단**: 평면 토픽 페이지 중 같은 주제를
   다루는 페이지가 둘 이상이면 병합하고, 너무 넓어진 페이지는 주제 단위로
   분할한다. 병합·분할 후에는 `docs/index.md`와 교차링크를 갱신한다.

7. **로그 그루밍**: `docs/log.md`는 `merge=union`(→[[0010-append-only-log-union-merge]])
   으로 머지돼 충돌은 안 나지만 시간순 정렬·중복 제거는 보장되지 않는다. 전용
   cadence에서 로그 항목을 타임스탬프 순으로 정렬하고, union이 만든 동일 줄
   중복을 제거한다. 기회적 cadence에선 건너뛴다(머지 직후 전용 lint의 몫).

8. **docs/log.md append**: 변경한 각 항목에 대해 한 줄씩 기록한다.
   형식: `## [YYYY-MM-DD HH:MM:SS] lint · <action> <path> | <요약>`
   (`action` ∈ `create` / `update` / `delete` — 정리의 성격(archive·merge·
   split·고아 제거 등)은 요약에 적는다)
