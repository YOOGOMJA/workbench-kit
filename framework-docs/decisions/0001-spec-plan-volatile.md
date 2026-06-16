## 결정: 스펙·플랜의 거처
- 상태: 채택
- 선택: 설계 스펙·구현 플랜은 `task/docs/plans/`에 두는 **휘발 자산**이다. 워크벤치 `docs/`는 plans/도 superpowers/도 갖지 않는다.
- 맥락: 워크벤치 docs/는 지식 레이어지 작업장이 아니다. 모든 작업은 task 워크트리 안에서 일어난다.
- 이유: 스펙·플랜은 *작업 맥락*이라 cleanup으로 사라지는 게 맞다. 설계의 durable 산물은 스펙이 아니라 그 결과물 — AGENTS.md 규칙 + synthesis 페이지다.
- 기각한 대안: docs/superpowers/specs/에 스펙을 1급 자산으로 보존 → 작업장과 지식 레이어가 섞이고, 재도출 가능한 과정 기록이 main을 오염시킴.
- 출처: workbench#4 / PR#9 / 2026-06-11
- 참조: [[workbench-knowledge-ecosystem]]
