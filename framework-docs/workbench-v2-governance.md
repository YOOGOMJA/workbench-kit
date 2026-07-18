# Workbench v2 Governance Contract

Status: accepted design contract for workbench v2. Implementation is tracked by
[workbench-kit #26](https://github.com/YOOGOMJA/workbench-kit/issues/26) and migration by
[workbench-kit #27](https://github.com/YOOGOMJA/workbench-kit/issues/27). A consumer must
probe the running engine; this document alone does not imply that a capability is installed.

This document is normative for the public boundary shared by the workbench kernel,
bootstrap and migration tooling, and optional capability packs. Product, portfolio, and
scenario semantics remain outside the kernel.

## Design goals

1. Keep the generated workbench model: each issue executes in an isolated task workspace,
   durable results land in their owning repositories, selected knowledge is accumulated,
   and disposable task state is cleaned afterward.
2. Let one task deliver changes to zero or more codebases without requiring an empty
   workbench pull request.
3. Evaluate standing authorization deterministically without turning every gate into a
   prompt or removing the gate.
4. Give optional packs a stable public API and compatibility probe instead of prose parsing,
   internal imports, or implicit hooks.
5. Preserve v1 tasks and lifecycle observations while migration occurs incrementally.
6. Support compound engineering without mixing current product intent into reusable
   workbench knowledge.

## Canonical vocabulary

The following English identifiers are stable across tools and output languages.

| Term | Meaning |
|---|---|
| kernel | The generic `workbench` engine, public CLI, lifecycle, and invariants |
| capability pack | An optional plugin that composes public kernel contracts for a domain |
| profile | Caller-owned policy values, conventions, language, and document formats |
| task | One independently governed execution unit, rooted in one issue |
| deliverable | A declared result owned by a repository or another explicit target |
| evidence | A check result bound to an immutable revision |
| living state | Mutable intent that directs later work and survives task cleanup |
| knowledge | Reusable decisions, lessons, and runbooks accumulated across tasks |
| completion | Acceptance of every required outcome under current evidence and policy |
| abandonment | A terminal decision not to adopt the task's intended result |
| cleanup | Authenticated retirement of task workspaces into non-deleting quarantine, followed by local-branch release |

Translations may be shown to a person, but stored keys, schema IDs, lifecycle values,
capability IDs, and command names stay in English.

## Two independent axes

The v1 `framework / profile / knowledge` model mixed responsibility with data lifetime.
V2 makes those dimensions explicit and independent.

```mermaid
flowchart LR
    subgraph Responsibility[Distribution and responsibility]
        K[Kernel]
        C[Capability pack]
        P[Profile]
    end

    subgraph Lifetime[Caller-owned data lifetime]
        T[Disposable task work]
        S[Living operational state]
        N[Accumulated knowledge]
    end

    K --> T
    K --> S
    K --> N
    C --> T
    C --> S
    C --> N
    P --> T
    P --> S
    P --> N
```

The responsibility axis answers who ships a rule and who interprets it. The lifetime axis
answers how caller-owned data evolves:

- **Disposable task work** includes plans, research, status, logs, temporary codebase
  worktrees, and execution evidence that is not itself a durable product artifact.
- **Living state** includes current intent, priorities, scenarios, quality constraints, and
  authorization scoped to a workspace or domain. It is edited over time, not harvested as
  an immutable lesson.
- **Accumulated knowledge** includes reusable decisions, failed approaches, and runbooks.
  It is queried by later tasks and is not a backlog or current product status store.

Plugin bundles contain executable framework content only. They never own caller runtime
state in any lifetime category.

## Task contract

### Identity and generic references

Existing task identity remains rooted in the issue and recorded in `task/index.md`.
Every new v2 task records `task_contract: workbench-task/v2` and the exact
`workspace_authority_descriptor_digest` in that file. A missing task-contract field means
`workbench-task/v1` regardless of the enclosing workspace schema. This task-level
discriminator lets an active legacy task finish after its workbench migrates.

V2 adds two optional, opaque references:

- `context_ref`: the longer-lived context under which the task is governed.
- `work_ref`: the work item that the task advances.

The shared syntax is:

```text
<namespace>:<kind>/<id>
```

`namespace` and `kind` match `[a-z][a-z0-9-]*`. `id` is one or more ASCII letters,
digits, dots, underscores, or hyphens. Examples are `toolbox:product/acme` and
`toolbox:scenario/SCN-001`. The kernel validates syntax, stores the exact value, detects
duplicate active `work_ref` values, and reports the references. Only the namespace owner
interprets the value. Missing references have no product meaning and remain valid.

Active-task inventory is the semantic preflight for `work_ref` uniqueness, but it is not the
serialization point. Every non-null value owns one Git reservation at
`refs/heads/workbench-coordination/work-refs/<sha256(work_ref)>`. The ref is created by a
non-force push of a deterministic root commit whose exact `work-ref.json` binds the value,
task claim, task branch, and workspace-authority descriptor. Concurrent setters may both
pass inventory; the remote ref creation still selects exactly one winner. An existing
malformed or differently bound reservation fails closed and is never overwritten.

The per-value ref does not serialize two different values selected concurrently by the same
claim. Each claim therefore also owns an append-only selection chain at
`refs/heads/workbench-coordination/work-ref-selections/<sha256(claim_id)>`. Its exact
`workbench-work-ref-selection/v1` commit binds claim, branch, descriptor, nullable selected
value, matching reservation ref/OID, and previous selection OID. Changing or clearing a value
uses one required atomic Git push guarded by exact leases to advance that selection, create or
retain the chosen reservation, and delete every obsolete reservation owned by the claim. Only
the winning transaction updates local task metadata. Within one clone, a secure claim-scoped
process lock covers selection reconciliation, remote transition, local metadata publication,
and a final authoritative selection check, so an older process cannot overwrite a newer local
winner. Across clones, a lost response or interrupted local write is repaired from the
selection chain. Any failed atomic push re-observes the requested reservation so a competing
owner remains a duplicate-work failure even when this claim already had a prior selection.
Malformed history or a remote without atomic-push support fails closed.

A terminal task retains its selection and reservation until cleanup has durably published an
authenticated quarantine receipt for the task workspace. Cleanup then atomically releases the
selection and every reservation bound to that claim and branch before deleting the local
branch. This ordering lets a cleanup retry finish after the active workspace path is gone
without making the work item concurrently reusable before every user byte is preserved in
quarantine. Tasks created before this coordination contract remain readable; their
current value and first selection are materialized lazily on the next matching `refs set`,
while authoritative inventory continues to protect them during migration.

### Work-item and multi-context boundary

One task has one primary work item, represented by at most one `work_ref`, and zero or more
deliverables. The task owns one independent lifecycle, policy evaluation, verification set,
terminal outcome, and cleanup event. Workbench-wide or portfolio-wide state never replaces
these per-task facts.

Independent work in different products uses separate tasks even when one agent runs them in
the same session. One product work item may still produce several repository deliverables.
V2 start is deliberately skeleton-only and v2 resume never auto-attaches a missing work repo
or advances writer recovery. V1 start/resume compatibility is unchanged. The supported product
setup order is:

```mermaid
flowchart TD
    S[V2 task start: skeleton only] --> R[Optional task refs set]
    R --> C{Context ref}
    C -->|non-null| O[Owner register and seal]
    C -->|still null| L[Lazy empty seal at first explicit governed mutation]
    O --> A[Explicit add-repo role work]
    L --> A
    A --> W[Product work and deliverables]
    X[V2 resume] --> S2[Restore task workspace only]
    S2 --> A2[Explicit add-repo retry for recovery]
```

The kernel reports simultaneous `role: work` writers as `writer_conflicts`. Current writers
are always the union of active v2 rows on fixed canonical-origin ref
`refs/heads/workbench-coordination/writer-claims` and deterministic pseudo-claims derived from
authoritative non-cleaned v1 lifecycle facts plus canonical `task/index.md` role entries.
Active v1 tasks use the pinned branch tip; submitted tasks survive branch deletion by binding
the trusted PR head and the newest matching canonical index snapshot on its first-parent chain.
The closed home inventory comes from descriptor `workspace_home` plus same-OID
`codebases.yaml`; adapters exhaust every home's pagination, and an in-use legacy home cannot
be removed. Replacing a home's origin is removal of the old pair and requires proof that the
old origin has no non-cleaned v1 claim. Missing registry, pagination, branch/PR ancestry, or
legacy input fails closed. A legacy conflict always requires explicit
`task.concurrent-write` authorization because v1 has no sealed context policy; a later v1
`task-cleaned` fact dynamically retires its pseudo-claim.

Each explicit v2 add-repo first persists a strict `workbench-writer-operation/v1` journal.
Unresolved pre-publication ask has `authorization-pending` and no effects; deny/cancel becomes
terminal `cancelled`. Parent-OID CAS commits then serialize remote claims and append-only
effect-owner events. Only the current trusted device/clone owner may create, adopt, compensate,
or remove local effects. Every stage and compensation cursor is durable before its effect.
Cross-device journal rebind is allowed only when the new clone has no authoritative local
journal, exactly one active claim matches, owner history is empty, and exhaustive inspection
proves zero worktree/record/content effects. The reconstructed binding is persisted before
acquisition. From the first owner event onward only source-led handoff may transfer the
immutable device/clone binding.
The full joined set, policy, and exact writer intent are revalidated after publication, before
every local worktree/record create or adopt, and after the record before consume. Ask performs
cursor-based reverse compensation and keeps the claim reserved; policy or authorization deny
verifies record/worktree/owner release, persists `release-pending(next=claim)`, then performs
the claim CAS and verifies release. External or ambiguous effects are never removed. Recovery
is automatic across devices only before any effect-owner event; later movement requires an
explicit source-led handoff that releases ownership without releasing the claim. Cleanup carries
operation/claim IDs and every effect-owner transition in its external journal and verifies
releases before deleting the task workspace without changing frozen task content. `workbench doctor`
checks descriptor, legacy inventory, ledger, and hosting-adapter ref permissions read-only;
unknown permission is not ready, and actual CAS remains final proof.

A cross-product initiative normally uses an umbrella work item with independent child tasks.
Each child can verify, complete, abandon, and clean without pretending that every repository
merged atomically. A single atomic multi-context task is reserved for a result whose partial
adoption is invalid. It still has one primary `work_ref`; its singular `context_ref` points
to a pack-owned cross-context record that enumerates participants. All participating context
policies apply and the most restrictive result wins. Every atomic deliverable is required,
and the pack must define rollback because the kernel does not provide cross-repository
transactions.

The namespace owner registers the complete context-policy participant set through a strict
owner input. Every participant carries its own policy ref/digest and authenticated authority
receipt, so atomic work may preserve different owners instead of collapsing them into one
authority. An optional task policy is pinned and owner-authorized in the same set and may
only tighten. Registration requires explicit context-owner authorization; standing `allow`
is insufficient. A non-null context cannot seal an empty participant set. A null context
remains settable after task start; if still null at the first governed mutation or explicit
seal, it is lazily auto-registered/sealed with an empty set and no prompt. Context becomes
immutable only after seal. Every later governed mutation uses the whole set. Changed
participant/task bytes block as `policy-source-tampered`; callers cannot replace, omit, or
re-authorize them per action.

### Deliverables

A task declares zero or more deliverables. Each deliverable has, at minimum:

| Field | Contract |
|---|---|
| `deliverable_id` | Stable and unique within the task |
| `owner` | Registered repository or explicit owning target |
| `kind` | Kernel-defined kind or a namespaced pack kind |
| `owner_context_ref` | Immutable sealed participant context for a pack kind; null for kernel kinds |
| `acceptance_authority_ref` | Immutable participant authority for a pack kind; null for kernel kinds |
| `required` | Boolean; defaults to `true` |
| `external_ref` | Optional pull request, artifact, or other delivery reference |
| `revision` | Exact revision identifier; required for `submitted`/`accepted`, optional otherwise |
| `state` | `declared`, `submitted`, `accepted`, `waived`, or `rejected` |
| `acceptance_ref` | Append-only authority receipt required for `accepted` |
| `governance_action` | Waive, reject, or weaken action ID; otherwise null |
| `reason_code`, `reason_ref` | Required stable reason and optional prose reference for a governed change |
| `governance_action_instance_id` | Consumed action for waiver, rejection, or weakening; otherwise null |
| `governance_intent_digest` | Exact authorized transition/reason digest; otherwise null |
| `governance_policy_manifest_digest` | Exact policy manifest applied to the governed effect; otherwise null |
| `authorization_ref` | Matching authorization provenance, or null for standing allow |

The kernel understands the mechanics of its own kinds, such as a codebase pull request or
a workbench increment. It does not infer product semantics from a deliverable. A required
deliverable can be `waived` only through a governed action with a recorded reason. An open
or unmerged pull request is `submitted`, not `accepted`. A task with no workbench increment
must not create an empty workbench pull request merely to reach completion.

`submitted` and `accepted` require a non-null revision; `declared`, `waived`, and `rejected`
may remain null. One update can weaken, waive, or reject, never combine those governed
effects, and must persist its reason and one action/intent/policy/authorization binding. A later explicit
reset to `declared`/`submitted` clears current governance/acceptance fields but retains
append-only receipts; a changed revision makes prior evidence stale. Owner context and
acceptance authority never change on reset or revision update; a different owner binding uses
a new ID. Required checks are
declared independently from evidence, so completion distinguishes "no check was required"
from "required evidence is missing". Exact commands and reset rules are in
[[workbench-v2-cli-contract]].

No caller can set `accepted` directly. Kernel-owned pull-request kinds branch before policy
resolution and use a deterministic merged-PR probe whose repository and head revision match.
Their timestamp-free subject and timestamped observation create an ungoverned receipt whose
action/intent/policy/authorization fields are all null. Pack-owned kinds require a strict owner
assertion plus explicit `task.deliverable.accept` authorization. Their append-only receipt is
the applied-effect recovery journal and is written before the deliverable pointer. Declaration first
binds an exact owner context and acceptance authority that resolve one sealed participant;
the assertion repeats those stored values and cannot select another authority. Its independent
receipt authenticates the actor. Standing `allow` alone is insufficient. Both paths create
`workbench-acceptance/v1` receipts in the task content revision, but only pack receipts carry
the complete action/intent/policy/authorization provenance tuple. Required-check waiver
likewise requires a reason code, optional reason ref, and complete applied provenance.

### Verification evidence

Evidence is an observation, not a claim inferred from prose. The public
`workbench-evidence/v1` record uses these fields:

| Field | Contract |
|---|---|
| `evidence_id` | Stable and unique within the task |
| `owner` | Registered repository or explicit target |
| `subject_ref` | Exact deliverable or task subject checked |
| `subject_revision` | Immutable deliverable revision or task-content digest checked |
| `check_id` | Stable identifier for the required check |
| `command` | Optional exact local command |
| `result` | `passed` or `failed` |
| `recorded_at` | RFC 3339 timestamp |
| `source` | `local` or `ci` |
| `url` | Optional independently inspectable remote evidence |

Evidence owner and subject must exactly match its required-check record. Deliverable checks
bind to the deliverable revision; task-level checks bind to the evidence-free
`workbench-task-content/v1` digest. A new revision or content digest makes older evidence
stale without creating a self-referential hash. A summary such as "tests passed" without
the exact subject revision cannot satisfy completion.

### Lifecycle facts

Lifecycle comments remain append-only, centrally observable facts. They are neither locks
nor the sole source of truth. Current state is derived by joining task metadata, branches,
deliverables, pull requests, evidence, policies, issue state, and lifecycle observations.

```mermaid
stateDiagram-v2
    [*] --> Claimed: v2 skeleton only
    Claimed --> Active: explicit configured work begins
    Active --> Verified
    Active --> Submitted: pull request opened before remote checks
    Verified --> Active: governed result changes
    Verified --> Submitted: optional workbench increment
    Submitted --> Active: review change
    Submitted --> Verified: remote checks pass
    Verified --> Completed: all completion predicates hold
    Claimed --> Abandoned: result will not be adopted
    Active --> Abandoned: result will not be adopted
    Verified --> Abandoned: verified result will not be adopted
    Submitted --> Abandoned: result will not be adopted
    Completed --> Cleaned
    Abandoned --> Cleaned
```

The exact event IDs are `task-claimed`, `task-claim-conflict`, `task-active`,
`task-verified`, `task-submitted`, `task-completed`, `task-abandoned`, and `task-cleaned`.
A writer correlates them with `claim_id` and branch.
After publishing `task-claimed`, start keeps a process-exit compensation guard until the task
branch is durably pushed. Any worktree, scaffold, commit, or push failure publishes the matching
`task-claim-conflict`, so a failed concurrent start cannot remain a second live claim. The guard
is installed before publication. If the host persists `task-claimed` but its response is lost,
start reduces a fresh trusted lifecycle observation for that exact claim and publishes or
confirms the matching conflict before returning failure.

The canonical v2 marker is UTF-8 JSON inside a versioned HTML comment:

```html
<!-- workbench-task-lifecycle:v2
{"task_contract":"workbench-task/v2","event":"task-completed","claim_id":"task__example__42-20260711T030000Z-1234","issue":42,"home":null,"branch":"task/42-example","workspace_authority_descriptor_digest":"sha256:abababababababababababababababababababababababababababababababab","pr":null,"revision":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","action_instance_id":"act_01J00000000000000000000000","intent_digest":"sha256:7777777777777777777777777777777777777777777777777777777777777777","actor":"human@example.com","tool":"workbench","at":"2026-07-11T03:02:00Z"}
-->
```

The opening line, one minified JSON line, and closing line are exact. Keys are serialized in
the shown order. Strings use RFC 8259 escaping. The descriptor digest is required and equals
the digest stored by `task-claimed`; every later event repeats it. Missing `home`, `pr`,
`revision`, `action_instance_id`, and `intent_digest` values are JSON `null`, never `-`, an
empty string, or an omitted key.
`issue` and `pr` are JSON integers when present; `at` is RFC 3339 UTC. `task-verified`
requires the verified `workbench-task-revision/v1` digest. Completion uses that completion
revision; abandonment uses `workbench-task-abandonment-revision/v1`. Both terminal outcomes
require revision, action instance, and matching intent digest. A human-readable comment line may follow the
marker but is not part of the contract.

| Event | `pr` | `revision` | `action_instance_id` | `intent_digest` |
|---|---|---|---|---|
| `task-claimed`, `task-claim-conflict`, `task-active` | null | null | null | null |
| `task-verified` | null | required | null | null |
| `task-submitted` | required | required | null | null |
| `task-completed`, `task-abandoned` | null or related workbench PR | required | required | required |
| `task-cleaned` | null | terminal revision | cleanup action instance | cleanup intent |

V1 key/value markers remain readable and are never rewritten. Detailed deliverable,
evidence, and policy facts remain available through public CLI records instead of being
duplicated into the comment. Marker details remain machine facts; issue disposition, labels,
and explanatory prose remain outside the marker.

The meanings are distinct:

- `task-verified` says the required checks passed for named revisions at that time. It can
  become stale and the task can return to active work.
- `task-submitted` says a workbench increment pull request exists. It is optional and is not
  completion.
- `task-completed` is a terminal adoption outcome. Later external rollback is a new fact or
  task; history is not rewritten.
- `task-abandoned` is a terminal non-adoption outcome. It is not completion or failure
  disguised as cleanup.
- `task-cleaned` says local task resources were removed after a terminal outcome. It says
  nothing about whether the outcome was completion or abandonment.

### Completion predicate

A v2 task is complete only when all applicable conditions hold:

1. Every required deliverable is `accepted` or has a policy-authorized `waived` outcome.
2. Every required verification check has passing, current evidence for its exact
   deliverable-revision or task-content subject. No failed required check remains current.
3. A declared codebase pull request is merged or otherwise accepted by its owning target;
   merely opening the pull request is insufficient.
4. If the task contains a workbench increment, its normal submit and acceptance path is
   satisfied. If it contains none, no workbench pull request is required.
5. The `workbench-harvest/v1` inventory is sealed and every candidate has a recorded
   disposition. A sealed empty inventory explicitly means no candidates. Product-specific
   current state is not mislabeled as workbench knowledge to satisfy this condition.
6. No applicable policy resolves to `deny`, and no required action remains unresolved at
   `ask`.
7. Every task-local writer operation and remote task claim is reconciled: consumed operations
   have exact active claim/content-row/worktree matches; handoff-ready operations have exact
   active claim/content rows with released owner and no worktree; released operations have no
   live writer effect. Pending, duplicate, unmatched, or blocked writer state prevents completion.

Abandonment is a different terminal predicate. It derives
`workbench-task-abandonment-revision/v1` from content, explicit nullable/pending deliverable
facts, the joined writer/effect-owner/cursor snapshot, exact reason, and canonical cleanup-plan
digest. It does not borrow the completion revision, which may be null while writers are
incomplete. It requires a non-terminal task, parseable and unambiguous inputs, sealed context
policy, a reason code, and authorized `task.abandon`. It deliberately does not require
accepted deliverables, passing evidence, harvest disposition, or completed writer operations;
claiming those would misstate non-adoption as completion. It freezes new writer effects and
delegates exact compensation and release of existing operations to cleanup.

Cleanup is never a completion predicate. Cleanup before completion or
abandonment is invalid for v2 tasks. Existing v1 force-cleanup behavior remains a legacy
compatibility path until migration policy removes it in a future major contract. V2 cleanup
is the governed `task.cleanup` action and has its own terminal-revision plus exact
`workbench-task-removal-plan/v1` intent binding, blockers, and
retry semantics in [[workbench-v2-cli-contract]]. It first fsyncs a clone-local 256-bit arm
secret and publishes only its immutable-journal-bound commitment in the `prepared` cleanup
journal. The owning clone
uses atomic no-replace renames to move the complete task workspace plus every linked-worktree
admin record into a private git-common-relative quarantine. A strict no-follow inode/tree
authentication covers tracked, untracked, ignored, private-action, nested-codebase, and Git
admin bytes. The resulting fsynced receipt discloses the committed secret and binds its complete
public body with a domain-separated proof digest. It is published externally as `quarantined` before
any writer claim, effect owner, work-reference reservation, or task branch is released.
Retries then reconcile every intended/verified effect-owner event through verified CAS
release, `completed`, and `task-cleaned`. A crash rolls the local quarantine transaction
forward; it never restores over an occupied path. The journal reducer requires a `prepared`
genesis and rejects a forged receipt, so a different clone cannot promote `prepared` by copying
public runtime IDs. Cleanup does not physically delete
the quarantine; retention or garbage collection is a separate future operation. Release does
not mutate frozen task content.

Completion and abandonment both freeze every revision-affecting fact. Refs, context set,
deliverables and acceptance, required checks, evidence, harvest, and writer claims reject
mutation with `terminal-content-frozen`. Only read-only queries, same-outcome reconciliation,
existing writer-operation/cleanup reconciliation, durable cleanup-journal reconciliation, and
bookkeeping excluded from the content revision remain available. Completion cannot freeze
until writers are reconciled. Abandonment may freeze unresolved existing operations, but only
cleanup may compensate/release them; it permits no new claim or local writer effect.
Coordination-ledger release is cleanup bookkeeping, not a task-content change. Result changes
require a new task.

## Policy contract

Every judgment-governed externally consequential or irreversible action has a stable action ID
and must be resolved before execution. A deterministic kernel-owned PR acceptance is the
documented exception: it branches before policy and is authorized only by its exact owner
probe contract. The canonical policy decisions are:

| Decision | Meaning |
|---|---|
| `allow` | Standing authorization permits this action instance |
| `ask` | Explicit human authorization is required before execution |
| `deny` | Execution is prohibited; the agent must find a non-prohibited alternative or stop |

Policy resolution uses the safety lattice `deny > ask > allow`. Applicable layers are
evaluated in this order of authority:

1. platform and harness safety policy;
2. workspace policy;
3. every sealed referenced-context policy;
4. an optional sealed task policy.

A lower-authority layer may tighten but never relax a higher-authority result. Workspace
policy is required. Absent optional platform/task policy is neutral and contributes no row;
a valid present source missing a known action contributes `ask`. The v1 executable registry
is exactly the frozen kernel action table in [[workbench-v2-cli-contract]]. Unknown or
namespaced action IDs are `unsupported-action`, not executable `ask`; pack action
registration is reserved for a future contract. An agent must not infer authorization from
previous similar actions, prose, silence, or a successful dry run.
Context registration, pack acceptance, and concurrent write against any legacy-v1
pseudo-claim require explicit instance authorization even under standing `allow`.

```mermaid
flowchart TD
    A[Governed action] --> P[Collect applicable policies]
    P --> D{Any deny?}
    D -->|yes| X[Deny and record]
    D -->|no| Q{Any ask or missing known rule?}
    Q -->|yes| H[Ask for this action instance]
    Q -->|no| L[Allow and execute]
    H --> R{Human decision}
    R -->|approved| L
    R -->|rejected| X
```

Human approval resolves that action instance; it does not silently rewrite standing
policy. Policy evaluation records the action ID, applicable policy sources, result, and
authorization reference without asking shell plumbing to invent explanatory prose.

Every governed command first runs the common applied-effect reducer before deriving current
pre-state or policy. Exact durable action/intent/policy/authorization provenance is the
consumption point. The reducer validates the stored request against the effect postcondition,
repairs only missing pointers/lifecycle/private status (or a committed cleanup-plan prefix),
and never re-resolves policy for an effect that already happened. Duplicate, incompatible
partial, mismatched, or colliding provenance blocks as `action-effect-unreconciled`; only zero
unreconciled provenance enters ordinary policy resolution. Historical consumed provenance does
not shadow a later valid first call, and reconciliation never reverts a causally later valid
reset or successor state. Pack acceptance writes its strict receipt before its deliverable
pointer, terminal actions write outcome before lifecycle, concurrent write uses content row
plus operation, and cleanup uses the external prepared journal.

V2 bootstrap/migration writes the fixed protected-default `.workbench/authority.json`
descriptor (`workbench-workspace-authority/v1`) beside profile, schema marker, and required
policy in one accepted commit. The descriptor supplies canonical `workspace_home`; the same
OID's `codebases.yaml` supplies every exact codebase home. The one-time trust root is an
explicitly approved canonical
origin/default ref or authenticated hosting-repository selection; issue comments and task
branches are non-authoritative. Each task claim records the descriptor digest for audit.
Remote/descriptor unavailability is `policy-authority-unavailable`; a changed descriptor,
identity, or ref is `policy-authority-mismatch`; a valid current authority revision missing
required workspace policy is `policy-source-missing`.

The kernel derives `workbench-action-intent/v1` from `action_id`, `task_claim_id`, target,
pre-effect subject revision, payload contract, and exact payload digest. It then mints a unique
action instance bound to that intent digest and the full canonical policy-source manifest. An
authorization repeats both intent and manifest digests with every other binding field. Every
kernel action has one frozen payload schema covering its exact transition, reason, disposition,
pack-owner assertion, context input/set, writer request, or cleanup plan. The sealed task
context-policy set makes participant omission impossible for a direct caller. Immediately
before normal-path consumption, the kernel re-observes the descriptor origin/default ref with
`ls-remote --symref`, fetches its current OID, reads `.workbench/authority.json` and
`.workbench/policy.conf` plus `codebases.yaml` from that same immutable object, validates the
task claim's descriptor digest, closed legacy home set, every sealed participant/task receipt
and digest, re-derives the exact action payload, and re-resolves strictest policy. The
task-branch workspace copy is ignored. A
changed protected
workspace revision supersedes old authorization; changed sealed context/task bytes fail as
`policy-source-tampered` without a replacement. These rules prevent approval for one task,
target, revision, requested effect, policy set, or authority revision from authorizing another. The trusted
platform remains responsible for authenticating approving actors and authority receipts.

The public `workbench-policy/v1` resolution object is:

```json
{
  "contract_version": "workbench-policy/v1",
  "action_instance": {
    "id": "act_01J00000000000000000000000",
    "action_id": "task.complete",
    "task_claim_id": "task__example__42-20260711T030000Z-1234",
    "target_ref": "toolbox:scenario/SCN-001",
    "revision": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "intent_digest": "sha256:7777777777777777777777777777777777777777777777777777777777777777",
    "policy_manifest": {
      "contract_version": "workbench-policy-manifest/v1",
      "digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
      "sources": [
        {
          "layer": "workspace",
          "context_ref": null,
          "policy_ref": ".workbench/policy.conf",
          "policy_digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
          "authority_identity": "github:example/workbench",
          "authority_ref": "refs/heads/main",
          "authority_revision": "1111111111111111111111111111111111111111",
          "authority_receipt_digest": "sha256:abababababababababababababababababababababababababababababababab",
          "decision": "ask"
        }
      ]
    },
    "status": "pending"
  },
  "decision": "ask",
  "authorization_ref": null
}
```

`policy_manifest.sources[].layer` is one of `platform`, `workspace`, `context`, or `task`.
Each present row binds policy ref/digest plus authority identity/ref/revision/receipt digest;
there are no null placeholders for absent optional sources. Context rows also keep their
context ref. `authorization_ref` is null until an explicit matching authorization is
recorded. Exact authority descriptor, registration, manifest serialization, blockers, binding,
and re-resolution rules are in [[workbench-v2-cli-contract]].

## Public capability discovery

Capability packs must not parse `AGENTS.md`, inspect plugin internals, or guess compatibility
from a package version. They call this read-only command before mutation:

```text
workbench contract show --format json
```

Stdout is exactly one JSON document with `contract_version` equal to
`workbench-contract/v1`. Diagnostics go to stderr. Running outside a workbench, reading an
invalid schema marker, or requesting an unsupported format exits nonzero and emits no
partial JSON.

The canonical v1 shape is:

```json
{
  "contract_version": "workbench-contract/v1",
  "engine": {
    "name": "workbench",
    "version": "0.2.0"
  },
  "workspace": {
    "root": "/absolute/caller/workbench",
    "schema": "workbench/v2",
    "source": "marker"
  },
  "profile": {
    "contract_version": "workbench-profile/v1",
    "language": "ko",
    "source": "workspace"
  },
  "supported": {
    "workspace_schemas": {
      "read": ["workbench/v1", "workbench/v2"],
      "write": ["workbench/v2"]
    },
    "task_contracts": {
      "read": ["workbench-task/v1", "workbench-task/v2"],
      "write": ["workbench-task/v2"]
    },
    "task_start_contracts": ["workbench-task-start/v2"],
    "lifecycle_markers": {
      "read": ["workbench-task-lifecycle:v1", "workbench-task-lifecycle:v2"],
      "write": ["workbench-task-lifecycle:v2"]
    },
    "profile_contracts": ["workbench-profile/v1"],
    "workspace_authority_contracts": ["workbench-workspace-authority/v1"],
    "policy_contracts": ["workbench-policy/v1"],
    "policy_manifest_contracts": ["workbench-policy-manifest/v1"],
    "policy_authority_receipt_contracts": ["workbench-policy-authority-receipt/v1"],
    "context_policy_contracts": ["workbench-context-policy-registration/v1", "workbench-context-policy-set/v1"],
    "authorization_contracts": ["workbench-authorization/v1"],
    "applied_effect_contracts": ["workbench-applied-action-provenance/v1"],
    "action_intent_contracts": [
      "workbench-action-request/v1",
      "workbench-action-intent/v1",
      "workbench-task-complete-intent/v1",
      "workbench-task-abandon-intent/v1",
      "workbench-deliverable-transition-intent/v1",
      "workbench-deliverable-accept-intent/v1",
      "workbench-required-check-waive-intent/v1",
      "workbench-harvest-disposition-intent/v1",
      "workbench-context-policy-registration/v1",
      "workbench-context-policy-set/v1",
      "workbench-writer-request/v1",
      "workbench-task-cleanup-intent/v1"
    ],
    "task_revision_contracts": [
      "workbench-task-content/v1",
      "workbench-task-revision/v1",
      "workbench-task-abandonment-revision/v1"
    ],
    "acceptance_contracts": [
      "workbench-acceptance/v1",
      "workbench-acceptances/v1",
      "workbench-deliverable-acceptance/v1",
      "workbench-owner-acceptance/v1"
    ],
    "external_probe_contracts": ["workbench-probe/github-pr-subject/v1", "workbench-probe/github-pr/v1"],
    "cleanup_journal_contracts": ["workbench-task-removal-plan/v1", "workbench-task-cleanup-journal/v1", "workbench-task-quarantine-authority/v1", "workbench-task-quarantine-receipt/v1"],
    "doctor_contracts": ["workbench-doctor/v1"],
    "evidence_contracts": ["workbench-evidence/v1"],
    "writer_claim_contracts": [
      "workbench-legacy-home-set/v1",
      "workbench-legacy-lifecycle-set/v1",
      "workbench-legacy-writer-identity/v1",
      "workbench-effect-owner-snapshot/v1",
      "workbench-writer-conflict/v1",
      "workbench-writer-claim/v1",
      "workbench-writer-claim-snapshot/v1",
      "workbench-writer-claims/v1",
      "workbench-writer-operation/v1",
      "workbench-writer-worktree-owner/v1",
      "workbench-worktree-set/v1",
      "workbench-writer-abandonment-snapshot/v1"
    ],
    "capability_pack_contracts": ["workbench-capability-pack/v1"],
    "action_ids": [
      "task.abandon",
      "task.cleanup",
      "task.complete",
      "task.concurrent-write",
      "task.deliverable.accept",
      "task.deliverable.reject",
      "task.deliverable.waive",
      "task.deliverable.weaken",
      "task.harvest.dispose",
      "task.policy-context.register",
      "task.policy-context.seal",
      "task.required-check.waive"
    ]
  },
  "capabilities": [
    "knowledge.applicability/v1",
    "policy.authority/v1",
    "policy.authorization/v1",
    "policy.applied-effect-recovery/v1",
    "policy.context-set/v1",
    "policy.intent/v1",
    "policy.resolve/v1",
    "profile.language/v1",
    "task.acceptance/v1",
    "task.abandonment/v1",
    "task.cleanup/v1",
    "task.completion/v1",
    "task.contract/v2",
    "task.deliverables/v1",
    "task.evidence/v1",
    "task.harvest/v1",
    "task.lifecycle/v2",
    "task.legacy-writer-projection/v1",
    "task.refs/v1",
    "task.required-checks/v1",
    "task.start/v2",
    "task.writer-claims/v1",
    "task.writer-conflicts/v1",
    "task.writer-handoff/v1",
    "task.writer-recovery/v1",
    "task.writer-reconciliation/v1",
    "workspace.authority/v1",
    "workspace.doctor/v1",
    "workspace.schema/v1"
  ]
}
```

`workspace.root` is the absolute caller workbench root. `workspace.source` is `marker` when
the tracked `.workbench/schema` file exists and `implicit` when its absence maps to legacy
`workbench/v1`. The marker contains exactly one schema ID line; a new v2 workbench writes:

```text
workbench/v2
```

Supported arrays are sets. Consumers must not depend on member or array order and must
ignore unknown object fields and capability IDs. They must require every capability they
use and reject an unavailable contract before mutation. A producer may add optional fields
or capability IDs within `workbench-contract/v1`; changing or removing defined field
semantics requires a new discovery contract version.

`supported.action_ids` is different: it is the complete executable v1 registry, not an open
extension point. An action absent from that array cannot be resolved or executed. Runtime
writer-ref readiness is reported by `workbench doctor`; advertising the capability does not
turn an unreadable or unwritable coordination ref into authority.

`workspace_authority_contracts` identifies the protected-default descriptor contract, not an
issue marker. `task.start/v2` means skeleton-only start/resume. Writer-claim support is
complete only when legacy projection, writer recovery, and terminal reconciliation
capabilities are also advertised; the ledger contract alone is insufficient.
`policy.applied-effect-recovery/v1` means every governed command reduces durable provenance
before current request/policy derivation and supports blocker `action-effect-unreconciled`.
`task.acceptance/v1` covers both ungoverned deterministic kernel probes and governed pack
owner assertions; `task.deliverable.accept` in `supported.action_ids` is pack-only.

Only workspace schemas listed under `supported.workspace_schemas.write` may receive v2
mutations without migration. A v2 engine can read an implicit v1 workspace and run legacy
flows, but a capability pack requiring v2 state must stop with an actionable migration
message.

`profile` is the same public object returned by `workbench profile show --format json`.
V2 requires a valid tracked `.workbench/profile.conf`. If it is missing, unreadable, or
invalid, discovery fails closed and emits no partial contract; it never advertises
`profile.language/v1` with `language: null`. Only an implicit v1 workspace without a machine
profile reports `language: null` and `source: "unavailable"`. The engine does not parse
`AGENTS.md`. The exact file grammar and CLI behavior are in [[workbench-v2-cli-contract]].

## Capability-pack contract

The public pack contract ID is `workbench-capability-pack/v1`. A conforming pack:

1. calls only documented `workbench` CLI contracts for generic lifecycle state;
2. checks `workbench contract show --format json` and all required capability IDs before
   mutation;
3. stores runtime state in the caller workbench or an explicitly owning codebase, never in
   the installed plugin bundle;
4. owns domain validation for its namespaced references and state, while the kernel remains
   domain-neutral;
5. uses explicit skill orchestration instead of implicit lifecycle hooks;
6. does not source private engine shell files, import undocumented internals, patch generated
   core files, or infer facts from narrative documents;
7. reads `profile.language/v1` and emits reader-facing prose in that language while
   preserving canonical English identifiers; if language is unavailable, it asks or uses an
   explicitly pack-owned default and never parses `AGENTS.md`;
8. leaves the generated workbench empty of pack state until the user invokes the pack's
   initialization workflow;
9. declares namespaced deliverables with immutable owner context and acceptance authority
   bindings and cannot redirect those bindings during acceptance.

A pack may ship its own deterministic CLI and schemas. Those schemas are independently
versioned and declare their required workbench capabilities; plugin SemVer alone is not a
state-schema version. In v1 a pack cannot register or execute a new governed action ID; it
composes the frozen kernel registry. Toolbox product semantics therefore use generic refs,
deliverables, required checks, evidence, harvest, completion/abandonment, concurrency, and
cleanup rather than a parallel policy action namespace. Public pack-action registration is
reserved for a future contract version.

## Compound knowledge contract

The compound loop is:

```mermaid
flowchart LR
    Q[Query applicable knowledge] --> W[Execute task]
    W --> V[Verify against evidence]
    V --> H[Harvest reusable finding]
    H --> A[Record applicability and provenance]
    A --> Q
```

Knowledge is promoted by reuse value, not by volume. The following ownership rules apply:

| Finding | Durable owner |
|---|---|
| Task-only exploration, status, or implementation plan | None; removed at cleanup |
| Current product intent, scenario, or design state | Owning codebase or pack living state |
| Product-specific architecture or operating rule | Owning codebase |
| Cross-task decision, failed approach, or runbook | Workbench `docs/` |
| Framework behavior useful to every installation | A workbench-kit change candidate |

Each task maintains a `workbench-harvest/v1` ledger. Skills declare candidates and their
judgment-driven dispositions; plumbing stores facts without inventing prose. The inventory
must be sealed, including an explicitly empty inventory, and every candidate disposed before
completion. Exact commands and disposition records are in [[workbench-v2-cli-contract]].

A reusable finding records enough context to avoid unsafe cargo-cult reuse: scope,
applicability, known exclusions, provenance to task and delivered revision, last verification,
and confidence. A first observation is `provisional`; independent successful reuse may make
it `confirmed`. Confidence never broadens scope or overrides an exclusion. The kernel may
transport these facts, but agents decide whether a finding is reusable and whether new
evidence changes its applicability.

The optional machine mapping is `workbench-knowledge-applicability/v1`, embedded after the
existing entry template fields so decisions, lessons, and runbooks keep their current
human-readable shape:

```html
<!-- workbench-knowledge-applicability:v1
{"contract_version":"workbench-knowledge-applicability/v1","scope":{"kind":"context","ref":"toolbox:product/acme"},"applies_when":["OIDC browser sign-in"],"does_not_apply_when":["machine-to-machine credentials"],"evidence":[{"task_ref":"workbench:task/task__acme__42","deliverable_ref":"toolbox:deliverable/auth-pr","revision":"0123456789abcdef"}],"last_verified":"2026-07-11T03:00:00Z","confidence":"provisional"}
-->
```

`scope.kind` is `workspace`, `context`, or `codebase`; `scope.ref` is null only for workspace
scope. Conditions are arrays of concise prose in the caller's profile language. Evidence
contains exact task, deliverable, and immutable revision references. `last_verified` is RFC
3339 or null. `confidence` is `provisional` or `confirmed`.

The existing template `Source` field remains the human-readable provenance summary and
`Relations` remains the typed-edge surface. The embedded record is additional structured
applicability, not a replacement. Absence means applicability is unspecified, not universal.
Existing entries need no bulk migration; Query treats them conservatively until a later task
adds evidence.

## Backward compatibility

Workbench v2 follows these rules:

- The engine reads v1 `task/index.md` files without `context_ref`, `work_ref`, deliverables,
  or evidence. Missing `task_contract` means `workbench-task/v1`, even inside a v2 workspace;
  missing other fields mean unknown or undeclared, never implicitly satisfied.
- The engine reads `workbench-task-lifecycle:v1` observations and does not rewrite them.
- Active v1 tasks may resume, submit, and clean using v1 behavior. They are not forced to
  convert mid-task; their start/resume auto-attach behavior is unchanged.
- V2 start/resume is skeleton-only and never auto-attaches a missing work repository. Every
  v2 writer mutation dynamically joins active v1 pseudo-claims; old v1 engines are not
  required to understand or write the v2 coordination ledger.
- New v2 events are written only where the workspace schema and engine capabilities allow
  them and the task declares `workbench-task/v2`. V1-only readers may ignore unknown v2
  observations.
- V2 governed mutations require the protected-default `.workbench/authority.json` descriptor
  and current required policy from the same immutable OID. There is no issue-fact or task
  worktree fallback.
- Adding an optional discovery field or a new capability is backward compatible. Removing
  a field, changing defined semantics, or making optional state mandatory requires a new
  contract or workspace schema version.
- Plugin releases use SemVer, while workspace, lifecycle, policy, evidence, pack, and
  domain-state schemas retain their independent version IDs.

## Migration ownership

Migration remains an ordinary governed task, not an in-place bootstrap side effect.

```mermaid
flowchart TD
    D[Kernel doctor and read-only diagnosis] --> M[Bootstrap migration plan]
    M --> T[Migration task workspace]
    T --> P[Migration pull request]
    P --> V[Compatibility verification]
    V --> G{Policy or human gate}
    G -->|accepted| U[Write authority descriptor, policy, profile, and v2 marker]
    G -->|not accepted| R[Keep v1 workspace unchanged]
    U --> O[Optional pack adoption in a separate workflow]
```

- The **kernel** detects the caller schema, exposes compatibility facts, reads supported v1
  state, and refuses unsafe writes.
- **workbench-kit bootstrap/migration** diagnoses generated-minimal and embedded-legacy
  workbenches, preserves user overlays and accumulated knowledge, and writes the schema
  marker, valid `.workbench/profile.conf`, required `.workbench/policy.conf`, and exact
  `.workbench/authority.json` in the same accepted pull request. The generation/migration
  implementation tracked by G2 takes an explicitly approved canonical origin/default ref or
  authenticated hosting selection as the one-time trust root, verifies protection, makes the
  descriptor self-identify that root, and does not expose v2 until all four files are valid on
  the protected default branch. Doctor must prove descriptor/legacy readability and
  hosting-adapter coordination-ref permission; unsupported permission inspection is not
  ready. Migration does not add `task_contract` to active legacy tasks; only newly created v2
  tasks receive it. Migration preserves every registered home with a non-cleaned v1 claim;
  removal returns `legacy-home-in-use`. G2 may seed only a disposable projection cache, never
  a correctness source.
- A **capability pack** adopts or migrates only its own domain state after the generic
  workbench contract is compatible. Installing a pack never implies adoption.
- The **user or resolved policy** controls merge, destructive cleanup, production effects,
  and other governed actions.

Migration must be idempotent. Re-running diagnosis against an already-current workspace
reports no required mutation. Removing v1 read compatibility requires a future major
contract and an explicit deprecation window.

## AI-oriented constraints

The contract is optimized for reliable agent operation without making human review opaque:

- machine consumers receive versioned structured facts; people receive rationale and
  diagrams;
- unknown values fail closed and unknown action IDs are non-executable, so a model cannot
  turn uncertainty into authorization;
- workspace descriptor and policy come from one pinned remote authority object, never a
  task-editable or issue-selected copy;
- v2 start leaves refs and context choice open until explicit configuration, while legacy
  writer projection and operation journals prevent an agent from assuming an empty writer set
  or guessing through crash recovery;
- pack acceptance authority is declaration-bound, so generated assertions cannot redirect
  ownership at acceptance time;
- evidence is revision-bound, so stale success language cannot satisfy completion;
- stable English identifiers avoid translation drift across Claude Code, Codex, and future
  adapters;
- domain-neutral refs let packs compose the kernel without teaching core product concepts;
- rejected alternatives are retained so later agents do not recreate parallel lifecycles or
  put runtime state in plugin bundles.

## Decision lineage

This contract:

- extends [[0015-task-lifecycle-events]] by adding v2 observations while preserving the
  machine-fact boundary;
- extends [[0016-mechanical-invariant-enforcement]] by placing policy, deliverable,
  evidence, compatibility, and completion facts behind public CLI plumbing;
- supersedes the single-axis interpretation in [[0018-separation-architecture]],
  while preserving its valid ownership distinction as the responsibility axis;
- preserves the distribution, empty-start, persona-boundary, cross-tool, and language
  decisions in historical workbench ADRs
  [0019](https://github.com/YOOGOMJA/workbench/blob/main/docs/decisions/0019-framework-distribution-cli-first.md),
  [0020](https://github.com/YOOGOMJA/workbench/blob/main/docs/decisions/0020-user-docs-empty-start.md),
  [0021](https://github.com/YOOGOMJA/workbench/blob/main/docs/decisions/0021-persona-framework-rule-boundary.md),
  [0022](https://github.com/YOOGOMJA/workbench/blob/main/docs/decisions/0022-cross-tool-claude-codex-distribution.md),
  and
  [0023](https://github.com/YOOGOMJA/workbench/blob/main/docs/decisions/0023-kit-english-persona-language.md).

The architectural choice and rejected alternatives are recorded in
[[0024-workbench-v2-governance]]. Exact commands, record schemas, and exit behavior are in
[[workbench-v2-cli-contract]].
