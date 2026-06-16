## 결정: 이슈 라벨 정책
- 상태: 채택
- 선택: 이슈 라벨은 **priority(P0~P3)만** 의미 있게 운용한다. priority는 에이전트가 **제안만** 하고 사람이 확정한다(자동 부여 금지). type(enhancement 등)·area 라벨은 달지 않는다.
- 맥락: 세션 8개·이슈 16개 관측 결과 워크벤치 작업은 거의 전부 워크벤치 자체 인프라(enhancement)였고, 이슈를 꺼내 쓰는 질의는 일관되게 "다음에 뭘 할까"(우선순위·순서 트리아지)였다. 영역으로 필터링하는 소비는 관측되지 않았다.
- 이유: [[0005-types-carved-by-consumption]]("소비가 유형을 정당화한다")를 라벨에도 적용. priority만 실제 소비 질의에 봉사하므로 그것만 유지한다. priority는 "지금 다른 모든 이슈 대비 얼마나 급한가"라는 cross-issue 판단이라 에이전트가 자동 부여하면 거의 틀린다 → 제안·사람 확정. type은 전부 enhancement로 수렴해 변별력 0. area는 아직 소비자가 없어 지금 만들면 premature taxonomy.
- 기각한 대안: ① type 라벨 자동 부여(변별력 없는데 노이즈만) ② area 분류 선도입(소비자 없는 분류 — 0005 위반) ③ priority 에이전트 자동 부여(cross-issue 맥락 없어 오판).
- 출처: workbench#14 / 2026-06-12
- 관계:
  - extends [[0005-types-carved-by-consumption]]
- 참조: [[0010-issue-template-location]] · [[0015-task-lifecycle-events]]
