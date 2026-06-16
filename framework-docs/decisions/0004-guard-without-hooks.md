## 결정: 작업 중 가드의 강제 방식
- 상태: 채택
- 선택: "이미 정했나/망했나" 가드는 **훅 없이** 에이전트 판단으로 닫는다. 세 체크포인트(task-start preflight / 작업 중 log decide 이벤트 / task-submit 백스톱)에 매단다.
- 맥락: 결정은 도구 호출이 아니라 인지 행위라 하네스가 가로챌 수 없다. 훅을 붙여도 매칭은 여전히 에이전트 판단이다.
- 이유: 워크벤치 원칙(하네스 의존 0, 에이전트 중립). 가드는 이미 의무화된 `log decide` 이벤트 흐름에 올라타 훅 독립으로 성립한다. 훅은 미래의 선택적 가속기일 뿐.
- 기각한 대안: PreToolUse/PostToolUse 훅으로 강제 → 특정 하네스에 잠기고, 결정 순간을 정밀 감지 못 함.
- 출처: workbench#4 / PR#9 / 2026-06-11
- 참조: [[workbench-knowledge-ecosystem]] · [[0013-task-status-query]] · [[0016-mechanical-invariant-enforcement]]
