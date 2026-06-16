---
name: task-status
description: >-
  Use to see local and remote task status at a glance and diagnose drift (unpushed, stale status, missed cleanup). When you want to know where everything stands before starting or submitting, or after a multi-device handoff.
---

# task 현황

사용: `/task-status` — read-only. 어떤 후속 행동도 실행하지 않는다(제안만).
AGENTS.md의 "진실의 원천은 기록" 원칙을 따른다. 절차:

1. **배관 실행**: `workbench task status`
   - 첫 줄 `remote_source: live|cached` 를 읽는다. `cached` 면 오프라인이라
     원격 판정이 낡았을 수 있다 — 보고 끝에 "⚠️ 오프라인(원격 캐시 기준)"을
     덧붙인다.
   - 이어지는 빈 줄 구분 레코드를 task별로 파싱한다. 필드:
     `branch issue local remote pr ahead behind last_commit status_line
     commits_after_status`.

2. **3분류** (판단): 각 task를 아래로 나눈다. 데이터 출처별 나열이 아니라
   판단 후 분류다.
   - **진행 중 — 로컬에 있음**: `local=yes`. 표 컬럼 — task | 단계 |
     마지막 status 인용 | 마지막 활동(상대 표기) | 동기화.
   - **원격에만 있음 — resume 가능**: `local=no` 이고 `remote=yes`.
     `/task-start`(없으면)·resume 후보. 비어 있어도 "(없음)"으로 명시한다 —
     "다른 기기에 떠 있는 것 없음"도 정보다.
   - **정리 필요 — 머지됐는데 잔재**: `pr` 가 MERGED 인데 `local=yes` 또는
     `remote=yes`(작업 공간이나 origin 브랜치가 남음). → `/task-done <N>` 제안.
   - 위 어디에도 안 드는 것(`pr=MERGED`, `local=no`, `remote=no`)은 **완료**다.
     개별 나열하지 말고 끝에 한 줄로 접는다 — "완료 N건 (낡은 추적 ref 잔재 —
     `git fetch --prune origin` 로 정리)".

3. **어긋남 진단** (사실 판정만, ⚠️ 로 표시 — 임계값·방치 경고는 넣지 않는다):
   - `ahead>0` → 이 기기에만 있는 미push 커밋 N개. 핸드오프 시 충돌 위험.
   - `local=yes` 이고 `remote=no` → 한 번도 push 안 됨. 다른 기기에서 못 본다.
   - `commits_after_status>0` → status.md 갱신 이후 커밋 N개. status가 낡았을
     수 있음 → 재진입 전 `task/log.md` 확인 권장.
   - `status_line` 이 비고 `local=yes` → status.md 없음/미작성. 재진입 시
     log.md부터.

4. **렌더** (순수 마크다운 — 에이전트 중립, 특정 하네스 UI에 의존하지 않는다):
   - 시각은 상대 표기 기본(`방금`·`3시간 전`·`1일 전`). 정확한 타임스탬프는
     status 인용 옆 괄호에만.
   - `status_line` 에서 `상태: ` 접두는 떼고 핵심만 인용한다.
   - 어긋남은 표 아래 `>` 콜아웃으로 모은다.
   - 마지막 한 줄 요약: `활성 N · 원격 전용 N · 정리 대기 N`.

5. **read-only 엄수**: `/task-done`·resume·`git fetch --prune` 는 **제안 문구로만**
   쓴다. 이 스킬은 실행하지 않는다. 사용자가 따로 지시하면 그때 해당 절차로 간다.

## 출력 형식 (예)

```
## task 현황

### 진행 중 — 로컬에 있음
| task | 단계 | 마지막 status | 마지막 활동 | 동기화 |
|---|---|---|---|---|
| #11 task-status | 선행조회 완료 | "선행조회 완료" (06-12) | 방금 | ✅ push됨 |
| #14 ticket-incubate | eval 대기 | "eval 루프 대기" (06-12) | 3시간 전 | ⚠️ 미push 2 |

### 원격에만 있음 — resume 가능
(없음)

### 정리 필요 — 머지됐는데 잔재
(없음)

> ⚠️ #14 — 미push 커밋 2개. 이 기기에만 있음, 핸드오프 시 충돌 위험.
> ⚠️ #14 — status.md 갱신 이후 커밋 3개. status 낡았을 수 있음 → 재진입 전 log.md 확인.

완료 6건 (낡은 추적 ref 잔재 — `git fetch --prune origin` 로 정리).

활성 2 · 원격 전용 0 · 정리 대기 0
```
