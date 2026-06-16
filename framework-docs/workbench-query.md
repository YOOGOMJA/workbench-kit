# Workbench Query

Workbench Query는 `docs/` 위키에 대한 질문-응답 연산이다. 에이전트는
`docs/index.md`에서 시작해 관련 페이지를 읽고, 현재 질문이나 task에 필요한
답을 합성한다. 재사용 가치가 있는 답이나 발견은 채팅에만 두지 않고 위키 후보로
남겨 다음 작업에서 다시 쓸 수 있게 한다.

## 위치

Workbench의 `docs/`는 Karpathy LLM Wiki 패턴의 위키 레이어다. Query는
Ingest/Lint와 함께 이 레이어를 유지하는 기본 연산이다.

- **Query**: 질문을 기준으로 위키를 읽고 답을 합성한다.
- **Ingest**: task에서 살아남을 지식을 위키에 반영한다.
- **Lint**: 위키의 모순·낡음·고아·깨진 참조를 점검한다.

Query는 docs 구조를 새로 설계하지 않는다. 현재 `docs/index.md`와 관련 페이지를
읽어 작업 컨텍스트에 필요한 선행 지식을 가져온다. 페이지 유형, typed edges,
provenance, 멱등 적재의 세부 결정은 decisions/의 앵커 표를 통해 확인한다.

## 일반 Query

입력:

- 사용자의 질문 또는 task 이슈 원문
- `docs/index.md`
- 관련 `docs/` 페이지

출력:

- 질문에 대한 합성 답변
- 링크 가능한 근거 페이지
- 재사용 가치가 있는 발견의 위키 후보 기록

규칙:

- 항상 `docs/index.md`에서 시작한다.
- 관련 페이지가 있으면 읽고 답에 반영한다.
- 관련 페이지가 없으면 없다고 명시한다.
- 좋은 답이나 비교, 결정, 작업 방식 발견은 `task/docs/` 또는 `task/log.md`에
  후보로 남기고, 실제 `docs/` 반영은 `/task-submit`에서 판단한다.

## task-start preflight query

새 task를 시작할 때는 이슈 원문을 질문으로 삼아 Query를 실행한다.

`task/index.md`에는 다음 내용을 남긴다:

- 확인한 문서
- 관련 내용
- 이번 task에 주는 제약 또는 힌트
- 관련 선행 문서가 없으면 "관련 선행 문서 없음"

이 절차의 목표는 이미 쌓인 지식을 작업 시작 컨텍스트로 끌어오는 것이다.

## 관련 결정

- docs 페이지 유형의 카빙 기준: [[0005-types-carved-by-consumption]]
- typed edge·provenance 표기: [[0006-typed-edge-notation]]
- 멱등 적재: [[0007-idempotent-ingest]]
