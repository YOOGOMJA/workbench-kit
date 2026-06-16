## 결정: 멱등 적재 (idempotent ingest)
- 상태: 채택
- 선택: docs-ingest를 구조적으로 멱등하게 한다 — identity key=(장르, 앵커), lookup-then-write(있으면 in-place 갱신), 결정적 순서(앵커 정렬), 같은 출처 no-op. docs-lint가 같은 앵커 중복을 병합. 멱등은 구조에 한하고 산문은 자유.
- 맥락: 같은 harvest 재적재가 중복 칸·다른 문장을 만들어 가드를 흐렸다.
- 이유: 앵커는 이미 소비 표면의 유일 키라 identity로 자연. 산문 byte 결정성은 LLM상 불가능·불필요 — 안정적이어야 하는 건 구조다.
- 기각한 대안: ① claim-레벨 인용 dedup(무겁고 #6 범위 밖, [[0006]] 휴면) ② 기계적 강제(#12로 분리) ③ 산문 결정성 추구(불가능).
- 출처: workbench#6 / 2026-06-12
- 관계:
  - extends [[0006-typed-edge-notation]]
- 참조: [[workbench-knowledge-ecosystem]]
