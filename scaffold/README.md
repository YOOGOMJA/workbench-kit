# scaffold/

`workbench-kit:generate-workbench`가 **사용자 repo에 까는 최소 골격**의 원본.
엔진(skills+utils+bin)은 설치된 `workbench` 플러그인이 대므로 여기엔 없다.

| 항목 | 역할 |
|---|---|
| `AGENTS.overlay.md` | persona 기본값 — interview가 재생성, 사용자가 편집 |
| `templates/` | harvest entry·task-AGENTS 형식 (profile, 사용자 편집) |
| `.github/` | 이슈 4요소·PR 골격 (profile) |
| `docs/` | 빈 knowledge 골격 (index + 빈 anchor 표 + log) — empty-start |
| `codebases.yaml` | 빈 대상 매니페스트 |

생성 시 `AGENTS.md` = 플러그인의 `AGENTS.core.md` + 이 `AGENTS.overlay.md` 합성.
(합성기는 generate-workbench가 제공 — 빌드 예정.)
