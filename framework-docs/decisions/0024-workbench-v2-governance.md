# Decision: Workbench v2 governance uses generic public contracts

- **Status:** Accepted
- **Choice:** Evolve workbench through a versioned, domain-neutral governance contract.
  Separate distribution responsibility (`kernel / capability pack / profile`) from
  caller-data lifetime (`task work / living state / knowledge`). Make multi-deliverable
  completion, revision-bound evidence, `allow | ask | deny` policy resolution, generic
  namespaced references, replay-safe action instances, task-level contract selection, exact
  public CLI/JSON records, authority-backed acceptance, terminal content freeze, a sealed
  harvest ledger, externally journaled cleanup, skeleton-only v2 start/resume,
  legacy-aware CAS writer claims with crash-safe operation journals, protected-default
  authority descriptors, declaration-bound pack ownership, per-participant sealed policy
  authority, and capability discovery kernel contracts. Keep product semantics in an optional
  pack.
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
  Mermaid diagrams. Missing known rules default to `ask`, unknown action IDs are
  non-executable, unsupported capabilities block mutation, authorization is bound to
  action/task/target/revision/full authority manifest, legacy writers cannot be silently
  omitted, remote claims are cross-device recoverable, and verification is tied to exact
  evidence subjects and immutable revisions.
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
  11. Let callers provide workspace, task, or context policy paths per action. A caller
      could omit a restrictive source, and absolute paths would make persisted receipts
      non-portable; canonical remote workspace authority and a sealed owner-registered set
      avoid both.
  12. Cache only a policy decision or source-list digest. Approval could survive changed
      source bytes or a newly applicable source; each instance instead stores the complete
      canonical manifest and re-resolves it immediately before consumption.
  13. Let a deliverable set its own `accepted` state. This turns producer assertion into
      owner acceptance; kernel kinds now require an exact external probe, while pack kinds
      require a registered owner assertion and matching authenticated authorization.
  14. Keep terminal task content mutable. Completion evidence and cleanup authorization
      would drift after the recorded outcome; completion and abandonment now freeze every
      revision-affecting fact.
  15. Bind task-level evidence to a digest that includes that evidence. This creates a hash
      cycle; task content is hashed first, then selected evidence is added to the outcome
      revision.
  16. Store cleanup recovery only in the task workspace. The recovery record would vanish
      during the operation it must recover; a prepared journal is persisted in the home
      issue before deletion.
  17. Report concurrent codebase writers without enforcing the mutation point. A race could
      still create a second writer; `task add-repo --role work` now resolves policy before
      creating the worktree and serializes claims on one fixed remote ref through parent-OID
      compare-and-swap commits.
  18. Let a v2 workspace fall back to an unavailable or prose-derived profile. Packs would
      receive ambiguous language state after migration; v2 discovery instead fails closed
      until its tracked machine profile is valid.
  19. Read workspace policy from the current task branch. A task could authorize itself;
      resolution now pins canonical origin/default-ref identity and reads only the freshly
      observed immutable default-branch object.
  20. Materialize absent optional platform/task sources as `ask` rows. This defeats standing
      workspace authorization; absent optional sources are neutral, while a missing action in
      a present valid source remains `ask` and missing required workspace policy is an error.
  21. Collapse atomic participants into one context authority. Different owners would lose
      provenance; every participant now has an independent authority receipt and digest.
  22. Specify an abstract expiring/fenced writer lease. Without one concrete shared backend,
      local processes could disagree; the canonical-origin append-only ledger and Git ref CAS
      are the v1 serialization mechanism.
  23. Claim that packs can register governed action bindings without a public registration
      API. V1 freezes executable IDs to kernel actions; toolbox composes those contracts and
      pack-action registration remains future work.
  24. Combine deliverable weakening, waiver, or rejection in one authorized update or omit
      its reason. Each governed call now has one effect, one action binding, and persisted
      reason fields with explicit later reset semantics.
  25. Let v2 start/resume auto-attach a work repo or seal null context. Product refs could not
      be set before irreversible writer state; v2 now creates only a skeleton and requires
      explicit refs, seal, and add-repo steps while preserving v1 behavior.
  26. Treat the v2 coordination ledger as the complete writer set. Active v1 tasks would be
      invisible; every v2 claim now joins deterministic pseudo-claims from authoritative v1
      lifecycle facts and canonical task-branch role records.
  27. Persist only a remote writer row and reconstruct local effects heuristically. A crash
      could duplicate or prematurely release a worktree; strict operation stages, expanded
      remote identity, exact adoption, and external cleanup recovery now govern retries.
  28. Let a pack assertion select acceptance authority at accept time. The caller could switch
      owners after declaration; pack deliverables now bind one context and authority
      immutably at declaration and repeat them in every record and receipt.
  29. Locate workspace authority through a bootstrap issue comment. Issue discovery is
      ambiguous and separate from policy revision; the protected-default authority descriptor
      and policy are fetched from one immutable OID, with comments only optional audit data.
  30. Treat a no-op dry-run push as proof of writer-ref readiness. It may not prove permission
      or rules; doctor now requires read-only hosting-adapter inspection, reports unsupported
      inspection as unknown/not-ready, and leaves actual CAS as final proof.
- **Compatibility:** The kernel reads implicit `workbench/v1` workspaces and v1 lifecycle
  markers. New v2 workspaces carry `.workbench/schema` and a machine-readable profile;
  only tasks declaring `task_contract: workbench-task/v2` use v2 mutation rules. A missing
  task contract is always v1, so active tasks can finish without forced conversion.
  Workspace, task, lifecycle, profile, policy, authority descriptor, coordination operation,
  evidence, pack, and domain schemas are versioned separately from plugin SemVer. Migration
  is a governed task and pull request, not an install-time rewrite.
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
