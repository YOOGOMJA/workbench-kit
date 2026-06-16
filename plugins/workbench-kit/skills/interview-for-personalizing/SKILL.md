---
name: interview-for-personalizing
description: 새 워크벤치를 부트스트랩할 때 사용 — 발산·결손 기반 인터뷰로 사용자의 persona(언어·slug 스타일·이슈 요소·PR 골격·라벨 스킴·게이트 토글)를 캐내 임시 `.persona/` scratch에 초안으로 적는다. generate-workbench의 앞단.
---

# interview-for-personalizing (초안 — 스텁)

> 부트스트랩 1단계. 결과는 임시 `.persona/`(휘발)에 쌓고, generate-workbench가
> 읽어 사용자 repo에 구워 넣은 뒤 버린다.

## 무엇을 묻나 = persona 칸 (프레임워크 결정 "persona vs framework 규칙 경계")

기계가 강제하는 것(core)은 묻지 않는다. 취향만 묻는다:

- **언어** — 산문·커밋·이슈/PR 본문 언어
- **slug 스타일** — 단어 수·케이스·구분자
- **이슈 필수 요소** — 기본 4요소(배경·목표·완료·비범위) 유지/변경
- **PR 본문 골격** — 섹션 구성, AI callout 표기 여부
- **라벨 스킴** — priority 체계, type/area 사용 여부
- **harvest entry 필드** — decision/lesson/runbook 형식 취향
- **사람 게이트 토글** — 어느 게이트에서 멈춰 물을지

## 흐름 (ticket-incubate의 인터뷰 규율 재사용)

1. **발산** — 사용자의 작업 맥락·취향을 같이 굴린다. 처음부터 칸을 캐묻지 않는다.
2. **결손 인터뷰** — 대화에서 안 나온 persona 칸만 하나씩. 채워진 건 확인만.
3. **초안 작성** — 답을 `.persona/`(임시)에 구조화해 적는다.
4. **generate 권유** — 다 차면 `workbench-kit:generate-workbench`로 넘긴다.

> TODO(빌드): `.persona/` 스키마 확정, ticket-incubate 인터뷰 절차 공유/링크,
> 기본 프로파일(AGENTS.overlay.md)을 시작점으로 제시하는 방식.
