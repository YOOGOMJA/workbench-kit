---
name: codebase-onboard
description: 외부 git repo를 workbench가 관리하는 codebase로 **온보딩**(등록)할 때 사용. "이 repo를 workbench에서 관리하자/추가하자", "<owner/repo>를 작업 대상으로 등록해줘", "codebases.yaml에 넣고 clone해줘", 또는 이슈 번호 없이 "워크벤치에서 이 프로젝트 다루고 싶다"처럼 *새 codebase를 workbench 관리 대상으로 들이려는* 요청에 발동한다. `codebases.yaml` 매니페스트 등록 → `utils/workbench setup` clone → 검증 → 정책(이름·`role:reference`) 안내를, main 오염 없이 task 브랜치 경유 정본 경로로 오케스트레이션한다. 구분: `/task-start`(이슈 착수)·`utils/task add-repo`(이미 등록된 codebase를 *현재 task에* 워크트리로 붙이기)와 다르다 — 이 스킬은 그 *앞단*, repo를 workbench에 처음 들이는 등록 단계다. 배관(setup·add-repo)은 이미 있으니 새로 만들지 않고 절차만 엮는다.
---

# codebase-onboard

외부 repo를 workbench 관리 codebase로 들이는 진입점. workbench에는 등록 배관
(`utils/workbench setup`, `codebases.yaml`)과 정책(용어집·이름 규칙·gitignore·
`role:reference`)이 이미 있지만 이를 엮는 **에이전트 진입점이 없어** 매번 손으로
했다 — 그 과정에서 main을 오염시키기도 했다. 이 스킬이 그 빈 진입점을 메운다.

배관을 새로 만들지 않는다. 이미 있는 배관을 **정책에 맞는 순서로 호출**하고,
사람이 틀리기 쉬운 지점(repo 이름 오타, main에서 편집, 커밋 경로)을 막는다.

## 선행 — task 안에서 실행한다

`codebases.yaml`은 workbench 루트의 추적 파일이라, 그 변경은 **main에 살아남을
workbench 증분**이다. 따라서 증분 규칙대로 **task 작업 공간 안에서** 편집하고
task 브랜치 → squash PR로 머지해야 한다.

- 이미 적절한 task 안이면 그대로 진행한다.
- task 밖(메인 워크스페이스)이라면, 등록을 담을 이슈·task부터 시작하도록
  **제안하고 거든다** (`/ticket-incubate` → `/task-start`). 등록이 작은 작업이라도
  정본 경로를 건너뛰지 않는 이유는 추적성이다 — "왜 이 repo를 들였나"가
  이슈·PR로 남아야 한다. 사용자가 원하면 거기서 바로 이 절차를 이어간다.

### main 오염 방지 — 이 스킬의 핵심 안전장치

워크트리 task 중 cwd를 메인으로 옮긴 뒤 상대경로·cwd-기반 git을 쓰면 **main
브랜치·메인 트리를 오염**시킨다(실제 발생한 실패 [[worktree-cwd-contamination]]).
그래서:

- **cwd를 옮기지 않는다.** 작업 공간 경로를 변수로 잡고 파일은 **절대경로**로,
  git은 **`git -C <작업공간>`**으로 트리를 명시한다.
- `gh`·`utils/*`는 cwd의 repo를 자동 감지하므로 `cd` 없이 작업 공간 cwd에서
  바로 실행한다.

## 절차

### 1. repo 이름·URL 확정

- 사용자가 준 이름이 **실제 repo와 일치하는지 검증**한다 (`gh repo view
  <owner/repo>`). 흔히 약칭·오타가 있다 — 예: `timetree-extract`가 실제로는
  `timetree-extractor`. 매칭이 하나면 그걸로 확정하되 사용자에게 알린다.
- codebase 이름(매니페스트 key)은 보통 **실제 repo 이름**으로 한다 — clone 디렉토리
  (`.codebases/<name>`)·작업 사본(`task/codebases/<name>`)이 그 이름을 쓴다.
  **순수 숫자는 불가**(이슈 번호와 충돌).
- URL 컨벤션은 **이 workbench의 remote에 맞춘다** (`git -C <ws> remote -v`로
  https냐 ssh냐 확인) — 인증 일관성을 위해.

### 2. codebases.yaml 등록

작업 공간의 `codebases.yaml`에 `<name>: <url>` 한 줄을 **절대경로 편집**으로
추가한다. 형식은 파일 상단 주석 그대로(`<name>: <git-url>`).

### 3. clone — utils/workbench setup

작업 공간에서 `utils/workbench setup`을 실행한다. 매니페스트를 읽어
`.codebases/<name>`으로 clone하고, 이미 있으면 `skip`한다(멱등). `.codebases/`는
gitignore라 커밋 대상이 아니다 — 캐시다.

### 4. 검증

- clone 성공 확인: `.codebases/<name>`이 생기고 `git` repo인지.
- `setup` 재실행이 `skip`으로 떨어지는지(멱등) 가볍게 확인해도 좋다.
- 이로써 `utils/task add-repo <name>`의 전제(`.codebases/<name>` 존재)가 충족된다.

### 5. role 안내 (해당 시)

이 repo를 *수정 대상*이 아니라 *참고용*으로만 쓸 거면, 나중에 task에 붙일 때
`utils/task add-repo <name> --role reference`로 단다(제출·PR 대상에서 제외). 지금
등록 단계에서는 매니페스트에 role을 적지 않는다 — role은 task별 사용 방식이다.

### 6. 기록·커밋

`codebases.yaml` 변경을 `utils/task commit code update codebases.yaml -m "…"`로
기록한다(log append + commit + push 원자화). 산문(커밋 subject)은 판단 레이어가
쓴다. clone 산출물은 gitignore라 자동 제외된다.

이후는 일반 흐름이다 — `/task-submit`으로 PR(증분: `codebases.yaml` 한 줄),
사람 게이트(머지/정리/티켓 처분).

## 경계 — 무엇을 안 하나

- **배관을 바꾸지 않는다.** `utils/workbench setup`·`codebases.yaml` 형식·
  `add-repo`는 그대로 쓴다. 부족하면 별도 티켓.
- **여러 repo 일괄 등록을 한 호출에 몰지 않는다.** 단건씩. 매니페스트는 여러
  줄을 담지만, 온보딩 판단(이름·role·검증)은 repo마다 다르다.
- **task에 워크트리로 붙이는 것**(`add-repo`)은 이 스킬이 아니다 — 등록된
  codebase를 *현재 task가 쓰기 시작*할 때 별도로 한다.

## 예시 — workbench#37

> 출처: workbench#37 / 2026-06. 예시는 역사적·동기 사례다 — 절차의 출처를
> 보여줄 뿐 load-bearing 규칙이 아니다.

`YOOGOMJA/timetree-extractor` 온보딩(이 스킬이 정의되기 전 수동 수행, 동기 사례):

1. 사용자가 "timetree-extract 추가" → `gh repo view`로 실제 이름이
   `timetree-extractor`임을 확인·정정.
2. workbench remote가 https → URL도 https로.
3. `codebases.yaml`에 `timetree-extractor: https://github.com/YOOGOMJA/timetree-extractor.git` 추가.
4. `utils/workbench setup` → `.codebases/timetree-extractor` clone.
5. (당시 진입점이 없어) main에서 먼저 편집 → 오염 → restore 후 task 브랜치에서
   재작업. **이 스킬의 "main 오염 방지"는 그 실패에서 나왔다.**
