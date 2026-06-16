---
name: generate-workbench
description: interview-for-personalizing 다음 단계 — 대상 repo 위치나 git URL을 받아 최소 워크벤치(persona 합성 AGENTS.md + codebases.yaml + 빈 docs/)를 scaffold하고, 임시 `.persona/` 초안을 구워 넣은 뒤 폐기한다.
---

# generate-workbench (초안 — 스텁)

> 부트스트랩 2단계. 엔진(skills+utils)은 설치된 플러그인이 대므로, 생성되는
> 사용자 repo는 **최소**다 — persona + 대상 + 지식만.

## 입력 = `.persona/` (interview가 남긴 계약)

- `.persona/overlay.md` — 채워진 AGENTS.overlay.md (persona 7칸)
- `.persona/codebases.yaml` — (선택) 초기 작업 대상
- `.persona/meta.yaml` — 대상 repo 위치/URL 선호, 언어

`.persona/`가 없으면 `interview-for-personalizing`을 먼저 권한다.

## 만드는 것 (사용자 repo)

```
my-workbench/
  AGENTS.md          ← AGENTS.core(플러그인) + .persona 합성 결과
  codebases.yaml     ← 빈 템플릿(또는 persona가 정한 초기 대상)
  docs/              ← 빈 knowledge 골격 (index + 빈 anchor 표 + log)
  .agents/skills, .claude/skills  ← (선택) 도구별 발견 — 플러그인 미설치 폴백용
```

엔진(`utils/`·`skills/`)은 **복사하지 않는다** — 플러그인이 제공(`bin/workbench`가
PATH로). 그래서 repo가 최소로 유지된다.

## 절차

1. `.persona/meta.yaml`로 대상 repo 확보(위치/URL, 필요시 `gh repo create`).
2. `AGENTS.core.md`(플러그인) + `.persona/overlay.md` → 사용자 repo `AGENTS.md` 합성.
   `.persona/overlay.md`는 그대로 `AGENTS.overlay.md`로 둔다.
3. `.persona/codebases.yaml`(또는 빈 템플릿) → `codebases.yaml`, 빈 `docs/` 골격 생성.
4. `.persona/` 폐기(임시 scratch).
5. 첫 운영(`workbench:task-start`) 안내.

> TODO(빌드): 합성(compose) 구현, Codex/CC별 발견 경로 처리(repo-local vs 플러그인),
> CLI-PATH 제공 안내(프레임워크 결정 0021 검증점).
