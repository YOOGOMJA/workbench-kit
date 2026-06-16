## 결정: task 현황 조회의 거처·형식
- 상태: 채택
- 선택: task 현황 조회를 두 레이어로 나눈다 — **배관** `utils/task status`는
  task별 **사실 필드만** 구조화 출력(`local`·`remote`·`pr`·`ahead`·`behind`·
  `last_commit`·`status_line`·`commits_after_status`, 빈 줄 구분 레코드),
  **판단** `/task-status` 스킬은 그 출력을 **3분류**(진행중-로컬 / 원격전용-resume
  / 정리필요-머지후잔재) + **어긋남 진단**(미push·status 낡음)으로 조립. 전부
  **read-only** — 후속 행동(`/task-done`·resume·prune)은 제안 문구로만 둔다.
  원격 존재 판정은 **`git ls-remote`(진짜 origin)** 로 하고 로컬 추적 ref는
  쓰지 않는다(오프라인이면 캐시 폴백 + `remote_source: cached` 표기).
- 맥락: task 현황을 알려면 `.worktrees/` 스캔 + `git branch -a` + `gh pr list`
  + status.md 열람을 수동 조인해야 했다. 멀티디바이스 핸드오프 누락·정리 누락·
  재진입 판단이 매번 수작업.
- 이유: 두 레이어 원칙의 인스턴스 — 스크립트는 사실만, 산문·분류는 판단
  레이어. read-only는 "언제든(시작·제출 전·핸드오프 후) 부담 없이 호출"을
  가능케 한다(0004의 사실-판정·강제-없음 철학과 평행). **임계값 규칙은 넣지
  않는다**(방치 N일 경고 등) — 방치인지 숙성인지는 사람 판단, 스킬은 마지막
  활동 시각만 보여준다. 원격 판정에 ls-remote를 쓰는 건 머지 시 origin이
  삭제돼도 **로컬 추적 ref가 낡아 남아** "정리 필요"를 오탐하기 때문 — 진짜
  origin만이 권위다.
- 기각한 대안: ① 단일 스크립트가 분류·산문까지 — 두 레이어 위반, 산문이
  배관에 샘. ② 원격 판정에 `refs/remotes/origin/*`(로컬 추적 ref) — 머지 후
  낡은 ref로 오탐. ③ 정확도 위해 `fetch --prune` 선행 — 로컬 ref를 변경(순수
  read 아님), ls-remote면 ref 손 안 대고 같은 정확도. ④ 방치 임계값 경고 —
  숙성/방치 판단을 스킬이 참칭.
- 출처: workbench#11 / PR#27 / 2026-06-12
- 관계:
  - extends [[0004-guard-without-hooks]]
- 참조: [[0002-operations-as-skills]] · [[0004-guard-without-hooks]] · [[0015-task-lifecycle-events]]
