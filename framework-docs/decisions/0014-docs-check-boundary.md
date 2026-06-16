## 결정: 기계 docs 검증의 거처
- 상태: 채택
- 선택: 의미 판단을 포함하는 `docs-lint`는 스킬로 유지하고, 결정적으로 판정
  가능한 docs 링크 무결성 검사는 read-only 배관 `utils/docs check`로 둔다.
  명령 이름은 `lint`가 아니라 `check`로 좁힌다.
- 맥락: docs 정합성에는 깨진 링크처럼 기계가 안정적으로 판정할 수 있는 부분과,
  모순·supersede 의미·provenance·템플릿 conformance·로그 그루밍처럼 에이전트
  판단이 필요한 부분이 섞여 있다. 이 둘을 모두 `lint`라는 이름 아래 넣으면
  명령의 책임과 스킬의 책임이 흐려진다.
- 이유: `check`는 exit code와 `ERROR path:line ...` 출력으로 사실만 말하는
  배관이고, `docs-lint`는 그 사실을 바탕으로 고아 페이지·의도적 미래 링크·
  의미 충돌·정리 방식을 판단한다. 두 레이어 원칙과 0004의 훅 없는 판단 경계를
  유지하면서도 반복 수동 검색은 줄일 수 있다.
- 기각한 대안: ① `utils/docs lint`로 넓은 이름을 사용 → 의미 판단까지 자동화한
  것처럼 보이고 스킬과 책임이 섞임. ② 템플릿 필드·provenance·로그 그루밍까지
  v1에 포함 → 범위가 커지고 오탐 위험이 커짐. ③ `utils/task check`에 합치기 →
  #12의 더 큰 기계 불변식 작업과 결합돼 docs 링크 무결성 개선을 작게 닫기 어려움.
- 출처: workbench#25 / 2026-06-13
- 관계:
  - extends [[0002-operations-as-skills]]
  - extends [[0004-guard-without-hooks]]
- 참조: [[0007-idempotent-ingest]] · [[0012-append-only-log-union-merge]]
