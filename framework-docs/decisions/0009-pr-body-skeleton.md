## 결정: PR 본문의 표기·골격의 거처
- 상태: 채택
- 선택: PR 본문 규칙을 3층으로 둔다 — **규칙 정본** `AGENTS.md`(에이전트 중립) · **실행 표면** `.github/PULL_REQUEST_TEMPLATE.md`(GitHub 네이티브, 누구나) · **보강** `skills/task-submit/SKILL.md` PR 산문 단계(`--body-file` 우회 경로). 골격은 5섹션(배경·목표·검증·특이사항·참고 자료), 체크리스트지 의무 아님(빈 섹션 삭제). AI 작성 PR은 맨 위 callout(`>`)으로 작성 에이전트·모델을 표기하며, 문구는 특정 에이전트에 하드코딩하지 않는 placeholder다.
- 맥락: AI가 만든 PR임을 본문에 명시하는 규칙이 없었다(PR#15에서 일회성으로 붙임). PR 본문은 두 경로로 생성된다 — `/task-submit`은 `--body-file`로 GitHub 템플릿을 우회하고, ad-hoc·웹 경로는 템플릿이 채운다. 두 경로는 겹치지 않으므로 골격을 한 곳에만 두면 한쪽이 빈다.
- 이유: 템플릿은 GitHub 네이티브라 에이전트·사람 무관하게 잡히는 유일한 중립 표면이다. 규칙 자체의 정본은 `AGENTS.md`(모든 에이전트가 읽음)에 두고, 템플릿은 그 기본값, 스킬은 Claude 경로 보강 — 정본→표면→보강의 단일 방향. callout placeholder는 Codex 등 다른 에이전트가 자기 신원을 채워 같은 양식을 쓰게 한다(에이전트 중립).
- 기각한 대안: ① `AGENTS.md`에만(템플릿 없이) — ad-hoc·웹 PR이 골격을 못 받음. ② 템플릿에만 — `--body-file` 우회하는 task-submit 경로가 빔, 규칙 정본이 GitHub 설정 파일에 묻힘. ③ callout에 `Claude Code` 하드코딩 — Codex·사람 작성 시 거짓 표기. ④ 6섹션(확인하려는 것/확인한 것 분리) — 대부분 PR에서 두 칸이 중언부언, `검증` 한 칸으로 통합.
- 출처: workbench#17 / PR#21 / 2026-06-12
- 관계:
  - extends [[0003-templates-top-level]]
- 참조: [[0003-templates-top-level]]
