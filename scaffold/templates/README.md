# templates

워크벤치 정본 doc **형식 명세**다 — machinery(데이터 레이어)이지 harvest(task 산물)가 아니다.
그래서 `docs/`(지식)도 `utils/`(배관 스크립트)도 아닌 별도 최상위 레이어에 둔다.

## 소비자 (DRY 단일 출처)

- **작성**: `task/AGENTS.md`가 `@../templates/<genre>.tmpl.md`로 지연참조(점진적 공개).
- **검증**: `docs-lint`가 entry 페이지가 이 형식을 따르는지 점검.
- **적재**: `docs-ingest`가 필드→index 컬럼 매핑(파일 상단 주석)에 참조. ingest는 entry를
  *저술*하지 않고 author가 쓴 구조를 *보존*하며 index 행을 *파생*한다.

## 파일

- `decision.tmpl.md` · `lesson.tmpl.md` · `runbook.tmpl.md` — harvest entry 형식 명세.
  각 파일 상단 주석에 `docs/<genre>/index.md` 앵커 표 컬럼과의 매핑이 고정돼 있다.
- `task-AGENTS.md` — task 안 in-task 룰셋 정본. `workbench task` 스캐폴드가 인스턴스화한다.

## 범위 밖 (템플릿 불필요 — 의도적)

- `WHITE_PAPER.md` — immutable 원문 보존, 형식 강제 안 함.
- synthesis(평면 토픽) 페이지 — topic-driven 자유 형식.

## 후속 (미결)

`workbench task`의 inline heredoc 시드(index/status/log/genre-index)는 아직 스크립트 안에 있다.
단일 정책("모든 정본 doc 템플릿은 templates/에 파일로 산다")으로 통합하는 것은 후속 task로 둔다.
