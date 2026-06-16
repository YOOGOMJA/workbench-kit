## 결정: append-only 로그의 머지 전략
- 상태: 채택
- 선택: `docs/log.md`·`task/log.md` 같은 append-only 로그를 `.gitattributes`의
  `merge=union`으로 지정한다. 병행 머지 시 git이 양쪽 줄을 자동 합쳐 충돌이
  나지 않는다.
- 맥락: 단일 append-only 로그라 병행 task가 끝부분에 동시 append하면 머지마다
  충돌난다(#19 PR 머지가 #21과 `docs/log.md` 끝에서 실제 충돌, 수동 해소).
- 이유: union은 git 네이티브 머지 드라이버로 줄 단위 양쪽 보존이 정확히
  로그의 append 모델과 맞는다. 격리 repo 검증에서 양쪽 줄 보존·충돌 마커 0 확인.
- 기각한 대안: ① 로그 월별 분할(`docs/log/YYYY-MM.md`) → 같은 달 병행 task는
  여전히 충돌, 구조만 복잡. ② 수동 해소 정책("충돌 시 시간순 합침") → 매 머지
  손이 감, 자동화 0.
- 출처: workbench#24 / 2026-06-12
- 관계:
- 참조: [[workbench-knowledge-ecosystem]]

> 주의(트레이드오프): union은 시간순 정렬·중복 제거를 보장하지 않는다 — 블록
> 순서대로 붙는다. 정렬·중복 정리는 docs-lint(로그 그루밍)가 맡는다.
