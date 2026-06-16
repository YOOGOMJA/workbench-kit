# Codex 어댑터 (.codex-plugin)

workbench-kit은 **단일 도구중립 코어 + per-tool 어댑터**로 Claude Code와 Codex를
동시 지원한다(설계 근거: 프레임워크 결정 0021 / framework-docs).

## Codex에서 이미 동작하는 것

Codex는 추가 패키징 없이도 **repo-local 발견**으로 코어를 인식한다:

- `.agents/skills → ../skills` 심링크 → Codex가 cwd→repo root로 스캔(공식 확인).
- `AGENTS.md`(core+overlay 합성) → Codex가 루트→하위로 읽음.
- `SKILL.md` 포맷은 Codex·Claude Code 공통이라 같은 `skills/`가 양쪽에서 발견됨.

즉 이 repo를 clone해 Codex로 열면 스킬·지침이 그대로 인식된다.

## 빌드 검증점 (단정 금지 — 실제 Codex 버전으로 확인)

1. **마켓플레이스/배포 매니페스트 포맷** — Codex의 plugin 매니페스트 파일명·스키마는
   공식 문서서 미확정(NOT STATED). user-global 배포 시 확정 필요.
2. **user-global 설치 경로** — 공식 `~/.agents/skills` vs 실제 사례 `~/.codex/skills`.
   repo-local은 `.agents/skills`로 확정.
3. **CLI-on-PATH** — Codex엔 Claude Code의 `bin/` 자동 PATH 같은 메커니즘이 없음.
   `workbench` CLI 제공 방안: skill `scripts/` 번들 vs 1회 `export PATH=$PWD/bin:$PATH`.
   (현재 코어는 `bin/workbench`로 CC에서 검증됨.)

이 디렉토리는 위 검증이 끝나면 Codex 배포 매니페스트로 채운다.
