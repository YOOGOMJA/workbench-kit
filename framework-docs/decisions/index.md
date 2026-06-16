# Decisions

워크벤치의 재사용 가능한 결정 카탈로그 = 앵커 표(소비 표면).
새 task는 결정 직전 이 표를 주제로 스캔한다("이미 정했나?").
항목 추가/대체 시 이 표를 갱신한다.

| 주제(앵커) | 선택 | 상태 | 페이지 |
|---|---|---|---|
| 스펙·플랜의 거처 | task/docs/plans/ 휘발, docs/엔 plans·superpowers 없음 | 채택 | [0001](0001-spec-plan-volatile.md) |
| docs 연산의 형태 | Query/Ingest/Lint를 독립 스킬로, 워크플로우가 호출 | 채택 | [0002](0002-operations-as-skills.md) |
| 정본 형식 템플릿의 거처 | 최상위 templates/ (utils 아님) | 채택 | [0003](0003-templates-top-level.md) |
| 작업 중 가드의 강제 방식 | 훅 없이, 세 체크포인트 + 에이전트 판단 | 채택 | [0004](0004-guard-without-hooks.md) |
| docs 페이지 유형의 카빙 기준 | 소비가 카빙 — 결정·실패 1급, 모델 제거 | 채택 | [0005](0005-types-carved-by-consumption.md) |
| typed edge·provenance 표기 | 관계:/출처: 필드, 닫힌 4종(능동 supersedes·contradicts·extends) | 채택 | [0006](0006-typed-edge-notation.md) |
| 멱등 적재 | identity=(장르,앵커), lookup-then-write, 구조만 멱등 | 채택 | [0007](0007-idempotent-ingest.md) |
| 증분 흡수 승인 게이트의 위치 | 게이트는 task-submit, docs-ingest엔 승인 범위만 전달 | 채택 | [0008](0008-incremental-absorption-gate.md) |
| PR 본문의 표기·골격의 거처 | AGENTS.md(정본)+템플릿(표면)+SKILL(보강) 3층, 5섹션, AI callout placeholder | 채택 | [0009](0009-pr-body-skeleton.md) |
| 이슈 4요소 정본의 거처 | `.github/ISSUE_TEMPLATE/task.md` (플랫폼 직접 소비) | 채택 | [0010](0010-issue-template-location.md) |
| 이슈 라벨 정책 | priority만, 에이전트 제안·사람 확정, type·area 안 닮 | 채택 | [0011](0011-issue-label-policy.md) |
| append-only 로그의 머지 전략 | docs/log.md·task/log.md를 .gitattributes merge=union | 채택 | [0012](0012-append-only-log-union-merge.md) |
| task 현황 조회의 거처·형식 | 배관=사실필드 / 스킬=3분류+진단, read-only, 원격은 ls-remote | 채택 | [0013](0013-task-status-query.md) |
| 기계 docs 검증의 거처 | `docs-lint`는 판단 스킬, 링크 무결성은 `utils/docs check` | 채택 | [0014](0014-docs-check-boundary.md) |
| task lifecycle event 경계 | issue comment marker는 배관 fact, 티켓 처분·분류는 스킬/사람 게이트 | 채택 | [0015](0015-task-lifecycle-events.md) |
| 기계적 불변식의 강제 방식 | 인지적 가드는 에이전트 판단, 기계적 불변식은 utils/task commit/check | 채택 | [0016](0016-mechanical-invariant-enforcement.md) |

## Archive (대체됨)

| 주제 | 선택 | 대체 → |
|---|---|---|
