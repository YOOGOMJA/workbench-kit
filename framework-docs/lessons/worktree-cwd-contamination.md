## 실패: 워크트리 task 중 메인으로 cd한 뒤 상대경로로 작업
- 시도한 것: 워크트리(`.worktrees/task__N`)에서 task를 진행하다가 `gh issue
  create`를 위해 메인 워크스페이스로 `cd`했고, 그 cwd가 유지된 채 상대경로
  `cat >> docs/log.md`와 `git add -A && git commit`을 실행했다.
- 무엇이 망했나: 상대경로 쓰기가 **메인 워크스페이스의** 파일을 건드렸고,
  cwd 기반 git이 **main 브랜치에 잘못된 커밋**을 만들었다(로그 2줄). push 전이라
  `git reset --hard`로 복구했지만, 그대로 진행했으면 오염이 main에 섞였다.
- 제약(왜): `cd`는 셸 cwd를 persist시키고, 상대경로·cwd 기반 git 명령은 *현재
  트리/HEAD*를 대상으로 한다. 워크트리와 메인은 같은 repo의 **다른 작업트리·
  다른 HEAD**라, cwd가 어디냐에 따라 같은 명령이 다른 브랜치를 건드린다.
- 회피·우회:
  - 워크트리 task 작업 중에는 **cwd를 옮기지 않는다.** 파일은 **절대경로**로,
    git은 **`git -C <워크트리>`**로 트리를 명시한다.
  - `gh`는 cwd의 repo를 자동 감지하므로 `cd` 없이 워크트리 cwd에서 바로 실행한다.
  - 부득이 `cd`했다면 직후 `pwd`·`git branch --show-current`로 위치를 확인한 뒤
    다음 명령을 낸다.
- 출처: workbench#19 / 2026-06-12 (발견 경로 #8 dogfooding)
- 관계:
- 참조: [[workbench-knowledge-ecosystem]]
