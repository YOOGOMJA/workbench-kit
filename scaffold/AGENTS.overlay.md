# Workbench 스키마 — Persona Overlay

> **이 파일이 당신의 규칙이다 — 자유롭게 편집하라.**
> 프레임워크 업그레이드는 이 파일을 건드리지 않는다. 여기 담긴 것은 *취향* —
> 다른 팀이라면 다르게 정할 표면 관례뿐이다(기계가 강제하는 규칙은 `AGENTS.core.md`).
> 편집 후 `AGENTS.md`를 재합성한다.
>
> 아래 값은 **기본 프로파일**이다. `workbench-kit:interview-for-personalizing`이
> 인터뷰로 이 값들의 초안을 만들고, `generate-workbench`가 여기에 구워 넣는다.

## 언어

- 산문·문서·커밋·이슈/PR 본문 언어: **한국어** _(편집: en / ja / …)_

## slug 스타일

- 소문자 케밥케이스, **2~4 단어**. 이슈 제목에서 핵심만 남긴다.
  _(예: `fix-auth-redirect`. 단어 수·구분자 취향껏.)_

## 이슈 필수 요소

- **배경 · 목표 · 완료 기준 · 이번에 하지 않을 것** (4요소).
- 정본 형식: `.github/ISSUE_TEMPLATE/task.md` _(요소를 바꾸려면 그 파일을 편집.)_
- codebase 이슈는 그 repo 자체 템플릿 우선.

## PR 본문 골격

- 골격: **배경 · 목표 · 검증 · 특이 사항 · 참고 자료** (빈 섹션은 지운다).
- AI 에이전트 작성 PR은 맨 위에 callout(`>`)으로 작성 에이전트·모델 표기.
- 정본 형식: `.github/PULL_REQUEST_TEMPLATE.md`.

## 라벨 정책

- **priority(P0~P3)만**, 에이전트는 제안·**사람이 확정**. cross-issue 판단이라
  자동 부여하지 않는다.
- type·area 라벨은 변별력·소비자가 생기기 전엔 달지 않는다.
  _(팀마다 다름 — 라벨 체계를 바꾸려면 여기서.)_

## harvest entry 필드

- decision·lesson·runbook entry의 필드 형식은 `templates/*.tmpl.md`가 정본.
  _(필드를 바꾸려면 그 템플릿을 편집 — 구조(앵커·typed-edge)는 core가 고정.)_

## 사람 게이트 토글

- PR 후 처분 묻기: **켬**
- 정리 후 티켓 처분 묻기: **켬**
- 증분 흡수 승인 묻기: **켬**
  _(게이트의 *존재*는 core가 강제하나, 어디서 멈춰 물을지는 취향.)_

## 용어집 단어 (선택)

- core의 개념을 다른 단어로 부르고 싶으면 여기에 매핑.
  _(단, utils가 쓰는 식별자 `task/`·`docs/`·op 어휘는 불변.)_
