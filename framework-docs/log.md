# Log

docs/ 변경의 append-only 이력. 항목 형식:
`## [YYYY-MM-DD HH:MM:SS] <op> · <action> <path> | <요약>`
(op: extract · lint · edit / action: create · update · delete)
(2026-06-10 항목들은 마이그레이션 이전 구형식이다.)

## [2026-06-10] init | workbench

저장소 초기화. 설계 스펙 기반 스캐폴드 생성.

## [2026-06-10] edit | 설계 스펙 (에이전트 중립화)

스키마를 AGENTS.md 정본 + CLAUDE.md 심링크로, 절차서를 Agent Skills(SKILL.md)
정본 `skills/` + 도구별 심링크로 전환. 결정 기록 3행 추가, index에 스펙 등재.

## [2026-06-10] extract | workbench Query

#3에서 정의한 Karpathy식 Query 계약을 `docs/workbench-query.md`로 승격했다.
`task-start` preflight query의 입력·출력·기록 규칙과 #4/#5/#6로 넘긴 경계를
정리했다.

## [2026-06-11 23:18:00] edit · update index.md | Specs 섹션 제거 — 설계 스펙을 task로 이관(스펙=휘발 자산)

## [2026-06-11 02:59:26] extract · create decisions/index.md, lessons/index.md, runbooks/index.md | harvest 구조 신설

## [2026-06-11 03:11:12] extract · create docs/workbench-knowledge-ecosystem.md | 설계의 durable synthesis

## [2026-06-11 06:49:56] lint · update log.md | 헤더 형식 설명을 2축 신형식으로 정정 (구조 리뷰 반영)

## [2026-06-11 07:10:01] extract · create decisions/0001-0005 | 설계 핵심 결정 5건 materialize (cleanup 전 보존)

## [2026-06-11 07:14:10] edit · update workbench-knowledge-ecosystem.md, task-AGENTS.md | 자평 반영: 세 레이어(templates) 추가, 죽은 runbook 참조 제거

## [2026-06-11 07:16:27] extract · create runbooks/team-design-review.md, lessons/subagent-pin-canonical-vocab.md | 이 task 실경험 harvest (빈 소비 표면 채움)

## [2026-06-12 22:08:45] extract · create docs/decisions/0006-typed-edge-notation.md | 표기법 결정 적재

## [2026-06-12 22:09:56] lint · update decisions/000[1-5], lessons/*, runbooks/* | 기존 entry에 출처: backfill (신규 conformance 규칙 정합)

## [2026-06-12 22:29:12] extract · create decisions/0007-idempotent-ingest.md | 멱등 결정 적재

## [2026-06-12 23:05:00] extract · create docs/decisions/0008-incremental-absorption-gate.md | 흡수 게이트 위치 ADR 승격 (task#8, extends 0004)
## [2026-06-12 23:05:00] extract · update docs/decisions/index.md | 0008 행 추가

## [2026-06-12 23:14:12] edit · update workbench-query.md | 죽은 위키 링크를 채택된 결정 페이지 참조로 교체
## [2026-06-12 23:01:25] extract · create docs/decisions/0009-pr-body-skeleton.md | PR 본문 표기·골격의 거처 결정 (3층·5섹션·중립 callout), extends 0003
## [2026-06-12 23:01:25] extract · update docs/decisions/index.md | 0009 앵커 행 추가
## [2026-06-12 23:01:25] extract · update docs/decisions/0003-templates-top-level.md | 0009 see-also 역링크
## [2026-06-12 23:30:00] extract · create docs/lessons/worktree-cwd-contamination.md | 워크트리 cwd 오염 교훈 승격 (task#19, 발견 #8)
## [2026-06-12 23:30:00] extract · update docs/lessons/index.md | worktree-cwd-contamination 행 추가
## [2026-06-12 23:58:00] extract · create docs/decisions/0010-append-only-log-union-merge.md | 로그 union 머지 결정 승격 (task#24)
## [2026-06-12 23:58:00] extract · update docs/decisions/index.md | 0010 행 추가
## [2026-06-12 23:11:00] extract · create docs/decisions/0010-issue-template-location.md | 이슈 4요소 정본 거처 ADR (extends 0003), workbench#14
## [2026-06-12 23:11:00] extract · create docs/decisions/0011-issue-label-policy.md | 이슈 라벨 정책 ADR (extends 0005), workbench#14
## [2026-06-12 23:11:00] extract · update docs/decisions/index.md | 0010·0011 앵커 행 추가
## [2026-06-12 23:23:16] extract · create docs/decisions/0013-task-status-query.md | task 현황 조회 거처·형식 결정 (두 레이어·ls-remote·read-only), extends 0004
## [2026-06-12 23:23:16] extract · update docs/decisions/index.md | 0013 앵커 행 추가
## [2026-06-12 23:23:16] extract · update docs/decisions/0004-guard-without-hooks.md | 0013 see-also 역링크
## [2026-06-13 00:21:15] extract · create docs/decisions/0016-mechanical-invariant-enforcement.md | 기계적 불변식 강제 방식 결정 승격 (task#12, extends 0004·0012)
## [2026-06-13 00:21:15] extract · update docs/decisions/index.md | 0016 앵커 행 추가
## [2026-06-13 00:21:15] extract · update docs/decisions/0004-guard-without-hooks.md | 0016 see-also 역링크
## [2026-06-13 00:21:15] extract · update docs/index.md | 최신 decision 링크 갱신
## [2026-06-13 00:19:51] extract · create docs/decisions/0015-task-lifecycle-events.md | task lifecycle event 경계 결정 승격 (machine event, extends 0011·0013)
## [2026-06-13 00:19:51] extract · update docs/decisions/index.md | 0015 앵커 행 추가
## [2026-06-13 00:19:51] extract · update docs/decisions/0011-issue-label-policy.md | 0015 see-also 역링크
## [2026-06-13 00:19:51] extract · update docs/decisions/0013-task-status-query.md | 0015 see-also 역링크
## [2026-06-13 00:00:26] extract · create docs/decisions/0014-docs-check-boundary.md | 기계 docs 검증의 거처 결정 승격 (check vs lint 경계), extends 0002·0004
## [2026-06-13 00:00:26] extract · update docs/decisions/index.md | 0014 앵커 행 추가
## [2026-06-13 00:56:08] extract · create docs/runbooks/autonomous-session-loop.md | 자율주행 세션 루프 runbook 추가
## [2026-06-13 00:56:08] extract · update docs/runbooks/index.md | 자율주행 세션 루프 앵커 행 추가
## [2026-06-13 00:56:08] extract · update docs/index.md | 최신 runbook 링크 갱신
## [2026-06-13 00:56:08] edit · update AGENTS.md | extends 능동화와 자율주행 루프 포인터 반영
## [2026-06-13 00:57:19] lint · update docs/decisions/0006-typed-edge-notation.md | extends 능동화 반영
## [2026-06-13 00:57:19] lint · update docs/decisions/index.md | typed edge 선택 요약 정합화
## [2026-06-13 12:15:18] lint · update skills/docs-query/SKILL.md | extends 표면화를 outgoing/incoming 양방향으로 정정
## [2026-06-13 12:15:18] lint · update docs/runbooks/autonomous-session-loop.md | 자동 진행 가능 범위를 제출 전 준비로 제한
