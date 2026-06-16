## 결정: 이슈 4요소 정본의 거처
- 상태: 채택
- 선택: 티켓 4요소(배경·목표·완료 기준·이번에 하지 않을 것) 형식 정본을 **`.github/ISSUE_TEMPLATE/task.md`**에 둔다. 최상위 `templates/`가 아니다.
- 맥락: 이슈 템플릿은 GitHub 플랫폼이 **직접 소비**한다 — 웹 UI의 "New issue"가 이 파일을 읽어 본문을 프리필한다. `/ticket-incubate`·task-done 후속 티켓 등 에이전트 경로도 같은 파일을 참조한다.
- 이유: [[0003-templates-top-level]]는 "정본 형식 템플릿은 `templates/`"라 정했지만, 그 근거는 *소비자(작성·검증·적재)가 읽는 데이터*라는 것이었다. 이슈 템플릿의 1급 소비자는 GitHub 플랫폼 자신이고, 그 소비처는 `.github/ISSUE_TEMPLATE/`로 규약이 고정돼 있다. [[0005-types-carved-by-consumption]]("소비가 카빙")를 따르면 거처는 소비처를 따라간다 — 0003을 뒤집는 게 아니라 플랫폼 소비 템플릿으로 확장한다.
- 기각한 대안: ① `templates/issue.tmpl.md`(0003 일관성은 좋으나 GitHub 웹 UI가 못 읽어 프리필 안 됨 — 사람이 직접 만들 때 틀이 안 깔림) ② yml issue form(필드 필수화는 되나 에이전트가 읽고 따르기·gh CLI 본문 작성 경로와 어긋남, md가 단순).
- 출처: workbench#14 / 2026-06-12
- 관계:
  - extends [[0003-templates-top-level]]
- 참조: [[0005-types-carved-by-consumption]]
