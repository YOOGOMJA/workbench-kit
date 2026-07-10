# Decision: Workbench v2 governance uses generic public contracts

- **Status:** Accepted
- **Choice:** Evolve workbench through a versioned, domain-neutral governance contract.
  Separate distribution responsibility (`kernel / capability pack / profile`) from
  caller-data lifetime (`task work / living state / knowledge`). Make multi-deliverable
  completion, revision-bound evidence, `allow | ask | deny` policy resolution, generic
  namespaced references, replay-safe action instances, task-level contract selection, exact
  public CLI/JSON records, a sealed harvest ledger, governed cleanup, repeatable context
  policy provenance, and capability discovery kernel contracts. Keep product semantics in
  an optional pack.
- **Context:** V1 isolates task work and accumulates knowledge, but it treats a workbench
  increment pull request as the normal delivery path and describes human gates only in
  prose. It has no durable category for current intent and no supported way for an optional
  plugin to discover compatibility. Building toolbox against that surface would require it
  to parse `AGENTS.md`, import engine internals, or create a parallel lifecycle.
- **Rationale:** Generic contracts preserve one source of truth for task safety while
  allowing many domain packs. Orthogonal axes resolve the category error in the prior
  single-axis model: knowledge describes reusable learning, while living state directs
  future execution. Structured discovery and fail-closed policy defaults reduce inference
  at exactly the boundaries where an AI agent is most likely to guess incorrectly.
- **AI considerations:** Framework keys and identifiers remain English across Claude Code,
  Codex, and future adapters. A model receives structured facts for authorization,
  compatibility, deliverables, and evidence, while human reviewers receive rationale and
  Mermaid diagrams. Unknown actions default to `ask`, unsupported capabilities block
  mutation, authorization is bound to action/task/target/revision, and verification is tied
  to immutable revisions.
- **Rejected alternatives:**
  1. Put product, portfolio, scenario, design, and TDD semantics in the kernel. This would
     burden every non-product workbench and collapse the generic engine/domain boundary.
  2. Let toolbox own its own policy, evidence, completion, and cleanup lifecycle. This would
     create competing sources of truth and allow a pack to bypass kernel safety.
  3. Use plugin SemVer or parse `AGENTS.md` as compatibility detection. Package versions do
     not identify caller state, and prose is not a stable machine contract.
  4. Store pack state in its installation directory or use implicit lifecycle hooks. Bundle
     state is not caller-owned, and hooks hide orchestration from both agents and reviewers.
  5. Keep prompting at every gate. This prevents standing authorization and low-intervention
     operation; policy evaluation retains the gate without requiring every result to be
     `ask`.
  6. Treat a workspace v2 marker as proof that every active task is v2. This would silently
     apply new completion and cleanup rules to legacy tasks after workspace migration.
  7. Accept an opaque authorization reference without binding fields or consumption. That
     reference could be replayed for a different target or revision.
  8. Include task branch HEAD in an action revision while storing pending action state on the
     same branch. Bookkeeping commits would invalidate their own authorization binding.
  9. Treat harvest disposition as prose. Completion could not distinguish an unfinished
     assessment from an explicit zero-candidate result.
  10. Accept one anonymous context policy file. Atomic multi-context work could omit a more
      restrictive participant without leaving provenance.
- **Compatibility:** The kernel reads implicit `workbench/v1` workspaces and v1 lifecycle
  markers. New v2 workspaces carry `.workbench/schema` and a machine-readable profile;
  only tasks declaring `task_contract: workbench-task/v2` use v2 mutation rules. A missing
  task contract is always v1, so active tasks can finish without forced conversion.
  Workspace, task, lifecycle, profile, policy, evidence, pack, and domain schemas are
  versioned separately from plugin SemVer. Migration is a governed task and pull request,
  not an install-time rewrite.
- **Source:** workbench-kit#25 / 2026-07-11
- **Relations:**
  - extends [[0015-task-lifecycle-events]]
  - extends [[0016-mechanical-invariant-enforcement]]
  - supersedes [[0018-separation-architecture]]
  - preserves historical workbench ADRs
    [0019](https://github.com/YOOGOMJA/workbench/blob/main/docs/decisions/0019-framework-distribution-cli-first.md)
    through
    [0023](https://github.com/YOOGOMJA/workbench/blob/main/docs/decisions/0023-kit-english-persona-language.md)
- **Reference:** [[workbench-v2-governance]] [[workbench-v2-cli-contract]]
