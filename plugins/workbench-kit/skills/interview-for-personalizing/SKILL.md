---
name: interview-for-personalizing
description: >-
  새 워크벤치를 부트스트랩하는 첫 단계. 발산·결손 기반 인터뷰로 사용자의 persona(언어, slug 스타일, 이슈 필수 요소, PR 골격, 라벨 스킴, harvest 필드, 게이트 토글)를 캐내 임시 .persona/ 에 초안으로 적는다. 워크벤치를 새로 만들고 싶다거나 개인화하고 싶다고 할 때 발동. generate-workbench의 앞단이며, 그 둘이 부트스트랩 흐름이다.
---

# interview-for-personalizing

부트스트랩 1단계. **persona를 캐내 임시 `.persona/`에 초안으로 적는다.**
다음 단계 `generate-workbench`가 이 `.persona/`를 읽어 사용자 repo에 구워 넣고 버린다.

> 무엇이 persona인가 = 기계가 강제하지 않는 *취향*뿐이다. 메커니즘(휘발/축적·
> task 메타 규율·log 형식·docs 위키 구조 등)은 프레임워크 고정(`AGENTS.core.md`)이라
> **묻지 않는다.** persona 칸만 묻는다.

## `.persona/` 스키마 (generate와의 계약)

인터뷰 산출물은 **임시**다(점 규칙 — 인프라 scratch, generate가 소비 후 폐기):

```
.persona/
  overlay.md       # 채워진 AGENTS.overlay.md (아래 7칸) — generate가 그대로 사용
  codebases.yaml   # (선택) 초기 작업 대상 — 비어 있어도 됨
  meta.yaml        # repo 위치/URL 선호, 언어 — generate가 어디에·어떻게 깔지 결정
```

`overlay.md`는 프레임워크 기본 `scaffold/AGENTS.overlay.md`와 **같은 7개 섹션**을
가진다 — 그 파일을 시작점으로 띄워 보여주고, 사용자가 바꾸고 싶은 것만 덮어쓴다.

## persona 7칸 (= 물을 것)

| 칸 | 묻는 것 | 기본값(scaffold) |
|---|---|---|
| 언어 | 산문·커밋·이슈/PR 언어 | 한국어 |
| slug 스타일 | 단어 수·케이스·구분자 | 소문자 케밥 2~4단어 |
| 이슈 필수 요소 | 티켓에 강제할 항목 | 배경·목표·완료·비범위 |
| PR 골격 | PR 본문 섹션, AI callout 표기 | 5섹션 + callout |
| 라벨 스킴 | priority 체계, type/area 사용 | priority만, 사람 확정 |
| harvest 필드 | decision/lesson/runbook 형식 | templates 기본 |
| 게이트 토글 | 어디서 멈춰 물을지 | PR후·정리후·증분흡수 켬 |

## 흐름 (ticket-incubate의 인터뷰 규율 재사용)

1. **발산 — 같이 굴린다.** 사용자가 어떤 작업·도구·취향으로 일하는지 듣는다.
   처음부터 7칸을 캐묻지 않는다. 기본 프로파일(scaffold/AGENTS.overlay.md)을
   "이게 기본인데, 이대로 좋아요?"로 띄워 반응을 본다.

2. **전환 신호.** 대화에서 7칸 중 2개 이상을 초안으로 적을 수 있거나, 사용자가
   "이대로 만들자/정리하자" 신호를 보내면 결손 인터뷰로.

3. **결손 인터뷰 — 빈 칸만, 하나씩.** 대화에서 이미 드러난 칸은 다시 묻지 않고
   확인만. 기본값으로 충분한 칸은 건너뛴다. 한 번에 한 질문.

4. **`.persona/` 초안 작성.** 채워진 7칸을 `.persona/overlay.md`로, 초기 대상이
   있으면 `.persona/codebases.yaml`로, repo 위치/언어 선호를 `.persona/meta.yaml`로.

5. **generate 권유.** persona가 다 차면 `generate-workbench`로 넘긴다 — 더
   파고들지 않는다. 세부는 워크벤치가 생긴 뒤 다듬으면 된다.

## 경계

- 메커니즘(core)을 묻지 않는다 — 취향(overlay)만.
- 인터뷰 결과는 휘발 `.persona/`에만 — 아직 사용자 repo를 만들지 않는다(그건 generate).
- 중간 이탈해도 정리할 것 없음 — 다시 부르면 기본값에서 재개.
