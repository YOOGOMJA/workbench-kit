<p align="center">
  <img src="assets/workbench-kit.png" width="160" alt="workbench-kit" />
</p>

<h1 align="center">workbench-kit</h1>

<p align="center">
  에이전트 워크벤치를 위한 도구중립 프레임워크.<br/>
  <em>작업은 휘발하고, 지식은 축적된다. 규칙은 당신이 채운다.</em>
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.ko.md">한국어</a>
</p>

---

## 이게 뭔가요?

**workbench-kit**은 에이전트 "워크벤치"의 재사용 가능한 메커니즘입니다 —
AI 코딩 에이전트가 main 이력을 더럽히지 않고 실제 작업을 하게 하는 방식이죠.

- **작업은 휘발, 지식은 축적.** 모든 task는 자기 브랜치·작업 공간에서 일어나고,
  마지막에 정제된 증분 하나로 squash 머지됩니다.
- **두 레이어.** 판단은 에이전트가, 배관(git 상태 전이)은 스크립트가 합니다.
- **규칙은 당신이.** 프레임워크는 *메커니즘*만 배포합니다 — 이름 규칙·정책·
  지식 베이스는 사용자가 채웁니다.

## 세 레이어

| 레이어 | 담는 것 |
|--------|---------|
| **framework** | 고정 메커니즘: worktree/task/codebases, 증분, 스킬 |
| **profile** | 당신의 규칙·데이터: 이름 규칙, 템플릿, 매니페스트 |
| **knowledge** | 작업이 남기는 것: 결정·교훈·런북 |

## 상태

🚧 초기 / 설계 단계. 추출 전에 분리 아키텍처를 ADR로 확정하는 중입니다.
구조는 바뀔 수 있어요.

## 라이선스

미정
