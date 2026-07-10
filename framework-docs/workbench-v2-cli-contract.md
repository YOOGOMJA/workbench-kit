# Workbench v2 Public CLI Contract

Status: normative companion to [[workbench-v2-governance]]. Implementations may add human
display formats, but capability packs and tests consume only the versioned machine forms
defined here.

## Common command behavior

### Task selection

Commands under `workbench task` operate on the task workspace containing the current
directory unless an existing command explicitly accepts a task ID. V2 mutations require
`task_contract: workbench-task/v2` in `task/index.md`. A missing `task_contract` always
means `workbench-task/v1`, even when the enclosing workspace uses `workbench/v2`.

### Machine output

- A stable machine command requires `--format json`, except
  `workbench policy resolve --format decision`.
- JSON output is one UTF-8, minified JSON object followed by LF. Pretty examples below do
  not make object-member ordering semantic.
- Arrays that represent sets are sorted by their stable ID for deterministic fixtures.
- Optional record fields are present with JSON `null`; they are not omitted.
- Every versioned JSON input object has unique member names at every nesting level. A parser
  must detect duplicates before converting pairs to a map; duplicate keys are invalid even
  when their values are equal and exit at `2` with no stdout.
- Successful machine commands write no stderr. Diagnostics never share stdout with a JSON
  object except for the defined policy or blocker results below.
- Caller-owned record mutations are atomic. Policy resolution deliberately persists a
  `pending` or `denied` action instance. Git and GitHub side effects use the explicit
  reconciliation behavior documented by their command; no command reports a partial effect
  as success.

### Exit status

| Exit | Meaning | Stdout |
|---|---|---|
| `0` | Query succeeded, mutation succeeded, or policy resolved `allow` | Defined JSON object or decision token |
| `1` | State/integrity/external failure, stale binding, replay, or computed blockers | Defined blocker JSON when computation completed; otherwise empty |
| `2` | Usage error, invalid argument, unsupported format, or malformed versioned input | Empty |
| `3` | Policy resolved `ask` | Policy JSON or `ask` token |
| `4` | Policy or explicit authorization resolved `deny` | Policy JSON or `deny` token |

When exit `1` has no JSON, stderr contains one or more deterministic diagnostics. Exit `3`
or `4` is a resolved policy result, so it writes the requested policy output and no stderr.
No failure emits partial JSON.

## Workspace and profile discovery

### Contract discovery

```text
workbench contract show --format json
```

The exact `workbench-contract/v1` shape is defined in
[[workbench-v2-governance]]. The reviewed v1 shape also includes:

```json
{
  "profile": {
    "contract_version": "workbench-profile/v1",
    "language": "ko",
    "source": "workspace"
  },
  "supported": {
    "task_contracts": {
      "read": ["workbench-task/v1", "workbench-task/v2"],
      "write": ["workbench-task/v2"]
    },
    "profile_contracts": ["workbench-profile/v1"]
  }
}
```

Capabilities add `task.contract/v2`, `profile.language/v1`,
`task.required-checks/v1`, `task.harvest/v1`, `task.writer-conflicts/v1`,
`policy.authorization/v1`, and `knowledge.applicability/v1`. Supported records add
`authorization_contracts: ["workbench-authorization/v1"]`.

### Profile language

```text
workbench profile show --format json
```

Output is exactly:

```json
{
  "contract_version": "workbench-profile/v1",
  "language": "ko",
  "source": "workspace"
}
```

The tracked caller file `.workbench/profile.conf` has this grammar:

```text
schema=workbench-profile/v1
language=ko
```

Blank lines and lines beginning with `#` are ignored. `schema` and `language` each occur
exactly once; unknown or duplicate keys are invalid. `language` is a well-formed ASCII BCP
47 tag. A v2 workspace reads the file and reports `source: "workspace"`. An implicit v1
workspace without the file reports `language: null` and `source: "unavailable"`. The
engine and packs never parse `AGENTS.md` for language.

## Task references

### Show

```text
workbench task refs show --format json
```

### Set or clear

```text
workbench task refs set \
  [--context-ref REF | --clear-context-ref] \
  [--work-ref REF | --clear-work-ref] \
  --format json
```

At least one set/clear option is required. A set and clear option for the same field are
mutually exclusive. The output shape for both commands is:

```json
{
  "contract_version": "workbench-task-refs/v1",
  "task_contract": "workbench-task/v2",
  "context_ref": "toolbox:product/acme",
  "work_ref": "toolbox:scenario/SCN-001",
  "changed": false
}
```

`show` always reports `changed: false`; `set` reports whether stored values changed. A
duplicate active `work_ref` is an integrity failure at exit `1`. Reference grammar and the
kernel/domain interpretation boundary are defined in [[workbench-v2-governance]].

## Writer-conflict reporting

```text
workbench task status --format json
```

The v2 machine form contains at least these exact fields:

```json
{
  "contract_version": "workbench-task-status/v2",
  "tasks": [
    {
      "claim_id": "task__example__42-20260711T030000Z-1234",
      "task_contract": "workbench-task/v2",
      "branch": "task/42-example",
      "context_ref": "toolbox:product/acme",
      "work_ref": "toolbox:scenario/SCN-001",
      "work_owners": ["shared-api"]
    }
  ],
  "writer_conflicts": [
    {
      "owner": "shared-api",
      "task_claim_ids": ["claim-a", "claim-b"],
      "branches": ["task/41-a", "task/42-b"]
    }
  ]
}
```

Task, owner, claim, and branch arrays are sorted. A conflict exists when two non-terminal
tasks declare the same registered codebase as `role: work`. It is reported even when policy
allows concurrency. The report is read-only and is not a lock.

## Deliverables

### Declare

```text
workbench task deliverable declare \
  --id ID --owner OWNER --kind KIND \
  [--required true|false] [--external-ref REF] [--revision REV] \
  --format json
```

### Update

```text
workbench task deliverable update \
  --id ID \
  [--required true|false] [--external-ref REF] [--revision REV] \
  [--state declared|submitted|accepted|waived|rejected] \
  [--action-instance-id ID] [--authorization-file FILE] \
  --format json
```

At least one update field is required. `external_ref` remains optional in every state. A
revision is optional while state is `declared`; `submitted` and `accepted` require a
non-null immutable revision. Changing a revision returns the deliverable to `declared` or
`submitted` and makes prior evidence stale. An `accepted`
revision is not silently replaced. Transitions to `waived` or `rejected`, or weakening a
required deliverable, are governed actions bound to that deliverable and current revision.

### List

```text
workbench task deliverable list --format json
```

A mutation returns:

```json
{
  "contract_version": "workbench-deliverables/v1",
  "task_contract": "workbench-task/v2",
  "changed": true,
  "deliverable": {
    "deliverable_id": "web-pr",
    "owner": "web-app",
    "kind": "codebase-pr",
    "required": true,
    "external_ref": "https://github.com/example/web-app/pull/12",
    "revision": "0123456789abcdef",
    "state": "submitted"
  }
}
```

`list` returns:

```json
{
  "contract_version": "workbench-deliverables/v1",
  "task_contract": "workbench-task/v2",
  "deliverables": []
}
```

The record fields and state meanings are normative. Repeating `declare` with an identical
record is idempotent and reports `changed: false`; the same ID with different data fails.

## Required checks

Completion can only evaluate checks that are declared separately from evidence.

### Declare

```text
workbench task required-check declare \
  --id ID --owner OWNER [--deliverable-id ID] --format json
```

### Waive

```text
workbench task required-check waive \
  --id ID [--action-instance-id ID] [--authorization-file FILE] --format json
```

Waiving a required check is a governed action. It preserves the record for audit instead of
deleting it.

### List

```text
workbench task required-check list --format json
```

Mutation output is:

```json
{
  "contract_version": "workbench-required-checks/v1",
  "task_contract": "workbench-task/v2",
  "changed": true,
  "required_check": {
    "check_id": "web-test",
    "owner": "web-app",
    "deliverable_id": "web-pr",
    "state": "required",
    "authorization_ref": null
  }
}
```

List output replaces `changed` and `required_check` with `required_checks: []`. A waived
record has `state: "waived"` and the authorization source reference that permitted it.

## Verification evidence

### Record

```text
workbench task evidence record \
  --id ID --owner OWNER --revision REV --check-id ID \
  --result passed|failed --source local|ci \
  [--deliverable-id ID] [--command COMMAND] [--url URL] \
  --format json
```

Evidence is append-only. Repeating an identical ID and record is idempotent; conflicting
content under an existing ID fails.

### List

```text
workbench task evidence list --format json
```

Mutation output is:

```json
{
  "contract_version": "workbench-evidence/v1",
  "task_contract": "workbench-task/v2",
  "changed": true,
  "evidence": {
    "evidence_id": "ev-web-test-1",
    "deliverable_id": "web-pr",
    "owner": "web-app",
    "revision": "0123456789abcdef",
    "check_id": "web-test",
    "command": "npm test",
    "result": "passed",
    "recorded_at": "2026-07-11T03:00:00Z",
    "source": "local",
    "url": null,
    "stale": false
  }
}
```

List output replaces `changed` and `evidence` with `evidence: []`. `stale` is derived at
read time and is always present. Evidence must have a revision even when its deliverable is
still declared; evidence with a different revision cannot satisfy its required check.

## Policy resolution and authorization

### Policy source grammar

A `workbench-policy/v1` source is UTF-8 key/value text:

```text
schema=workbench-policy/v1
action.task.complete=ask
action.task.abandon=ask
```

Blank lines and `#` comments are ignored. `schema` occurs once. Action keys are unique;
values are `allow`, `ask`, or `deny`. Unknown keys, duplicates, and malformed lines are
invalid. An absent action resolves to `ask`.

The kernel-defined action IDs in this contract are:

| Action ID | Governed operation |
|---|---|
| `task.complete` | Adopt the task outcome |
| `task.abandon` | Record terminal non-adoption |
| `task.deliverable.waive` | Waive a required deliverable |
| `task.deliverable.reject` | Reject a declared deliverable |
| `task.deliverable.weaken` | Change `required` from true to false |
| `task.required-check.waive` | Waive a required check |
| `task.harvest.dispose` | Record the disposition of one harvest candidate |
| `task.concurrent-write` | Proceed while a writer conflict is reported |
| `task.cleanup` | Remove a terminal v2 task workspace |

Pack action IDs use the pack namespace and never reuse a kernel ID with different meaning.
Governed deliverable and required-check commands use the same first-call, pending, retry,
and consumption behavior defined below for completion and abandonment.

### Resolve

```text
workbench policy resolve \
  --action-id ID --task-claim-id ID --target-ref REF --revision REV \
  [--platform FILE] [--workspace FILE] [--context CONTEXT_REF=FILE]... [--task FILE] \
  [--action-instance-id ID] [--authorization-file FILE] \
  --format json|decision
```

Without `--action-instance-id`, the kernel mints and persists a unique action instance.
With an instance ID, all binding arguments are recomputed and must match the stored
instance exactly.

JSON output is:

```json
{
  "contract_version": "workbench-policy/v1",
  "action_instance": {
    "id": "act_01J00000000000000000000000",
    "action_id": "task.complete",
    "task_claim_id": "task__example__42-20260711T030000Z-1234",
    "target_ref": "toolbox:scenario/SCN-001",
    "revision": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "status": "pending"
  },
  "decision": "ask",
  "sources": [
    {
      "layer": "workspace",
      "context_ref": null,
      "policy_ref": "file:/absolute/workbench/.workbench/policy.conf",
      "policy_digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
      "decision": "allow"
    },
    {
      "layer": "context",
      "context_ref": "toolbox:product/acme-web",
      "policy_ref": "file:/absolute/workbench/products/acme-web/policy.conf",
      "policy_digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
      "decision": "allow"
    },
    {
      "layer": "context",
      "context_ref": "toolbox:product/acme-api",
      "policy_ref": "file:/absolute/workbench/products/acme-api/policy.conf",
      "policy_digest": "sha256:3333333333333333333333333333333333333333333333333333333333333333",
      "decision": "ask"
    }
  ],
  "authorization_ref": null
}
```

`status` is `pending`, `authorized`, `consumed`, or `denied`. `--format decision` prints
only `allow`, `ask`, or `deny` plus LF and uses the same exit status.

`--context` is repeatable. It splits on the first `=`; duplicate context refs are invalid.
An atomic multi-context caller supplies one source for every participant named by its
pack-owned cross-context record. Resolution evaluates every source and applies
`deny > ask > allow` across the complete set. `sources` preserves provenance with the
context ref, absolute `file:` policy reference, and SHA-256 of the exact policy bytes.
Platform, workspace, and task sources use `context_ref: null`. Sources are sorted by layer
authority, then context ref. Omitting a known participant is a pack validation error and
must not be treated as implicit `allow`.

### Authorization input

`--authorization-file` accepts exactly one `workbench-authorization/v1` JSON object:

```json
{
  "contract_version": "workbench-authorization/v1",
  "authorization_id": "auth_01J00000000000000000000000",
  "action_instance_id": "act_01J00000000000000000000000",
  "action_id": "task.complete",
  "task_claim_id": "task__example__42-20260711T030000Z-1234",
  "target_ref": "toolbox:scenario/SCN-001",
  "revision": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "decision": "allow",
  "actor": "human@example.com",
  "authorized_at": "2026-07-11T03:01:00Z",
  "source_ref": "conversation:message/msg-123"
}
```

The decision is `allow` or `deny`; `ask` is not an authorization. Every binding field must
match the stored action instance. `authorization_id` is unique within the task and may be
attached to only one instance. A used authorization or an instance with a different action,
task claim, target, or revision is rejected at exit `1`.

The kernel persists action status in tracked, disposable task state. The storage path is
private, but the record survives session handoff when the task state is committed. A
governed mutation marks an authorized instance `consumed` only after the mutation and its
lifecycle observation succeed. A failed precondition leaves the instance reusable only for
the identical binding. Action, log, status, and other disposable bookkeeping records are
excluded structurally from the task revision digest, so persisting a pending instance cannot
change its own binding.

The binding prevents accidental or cross-target replay; authenticity of `actor` and
`source_ref` remains the responsibility of the higher-authority platform or human-gate
adapter.

In a resolution object, `authorization_ref` equals the validated authorization input's
`source_ref`; it is null for standing `allow`, unresolved `ask`, and policy `deny`. An
authorization ID may be retried only with its same, unconsumed action instance.

## Task revision set

Verification and governed outcomes bind to a revision-set digest, not only the workbench
branch SHA. The kernel creates an LF-terminated, TAB-separated content manifest:

```text
workbench-task-revision/v1
task_contract<TAB>workbench-task/v2
context_ref<TAB>REF_OR_null
work_ref<TAB>REF_OR_null
deliverable<TAB>ID<TAB>OWNER<TAB>KIND<TAB>REQUIRED<TAB>EXTERNAL_REF_OR_null<TAB>REVISION_OR_null<TAB>STATE
required_check<TAB>ID<TAB>OWNER<TAB>DELIVERABLE_OR_null<TAB>STATE
evidence<TAB>CHECK_ID<TAB>EVIDENCE_ID_OR_null<TAB>REVISION_OR_null<TAB>RESULT_OR_null<TAB>STALE
harvest<TAB>SEALED
harvest_candidate<TAB>ID<TAB>KIND<TAB>SOURCE_REF<TAB>STATE<TAB>DECISION_OR_null<TAB>TARGET_REF_OR_null<TAB>REASON_CODE_OR_null
```

Deliverable and required-check rows are sorted by ID. Each evidence row is the selected
latest record for one required check and follows required-check order. "Latest" is greatest
`recorded_at`, with lexicographically greatest `evidence_id` as the tie-breaker. Harvest candidates
are sorted by ID. Contract values must not contain TAB or LF. SHA-256 over the exact UTF-8
bytes is represented as
`sha256:<lowercase-hex>`. Action, policy, status, log, and other task-bookkeeping records are
never inputs. A durable workbench increment is declared as a deliverable with its own
revision, so result changes still invalidate the digest without coupling it to metadata
commits. Changing refs, a deliverable, required-check state, selected evidence, or harvest
ledger changes the digest; storing an action instance cannot.

## Harvest ledger

Completion uses a sealed, versioned ledger rather than inferring harvest work from prose.

### Declare a candidate

```text
workbench task harvest candidate declare \
  --id ID --kind decision|lesson|runbook|framework-change --source-ref REF \
  --format json
```

### Record a disposition

```text
workbench task harvest dispose \
  --id ID --decision absorb|codebase|follow-up|discard \
  --reason-code CODE [--target-ref REF] \
  [--action-instance-id ID] [--authorization-file FILE] --format json
```

Disposition uses governed action `task.harvest.dispose`. `target-ref` is required for
`absorb`, `codebase`, and `follow-up`, and must be null for `discard`. The skill or agent
supplies candidate identity, kind, decision, and reason; plumbing does not generate prose or
decide reuse value.

### Seal or show the inventory

```text
workbench task harvest seal --format json
workbench task harvest show --format json
```

`seal` states that candidate discovery is complete. Sealing an empty inventory is the
explicit "no harvest candidates" result. Declaring another candidate after sealing sets
`sealed` back to false. Records are never deleted.

All four commands return the complete ledger:

```json
{
  "contract_version": "workbench-harvest/v1",
  "task_contract": "workbench-task/v2",
  "sealed": true,
  "changed": false,
  "candidates": [
    {
      "candidate_id": "auth-testing-runbook",
      "kind": "runbook",
      "source_ref": "task:document/auth-research",
      "state": "disposed",
      "disposition": {
        "decision": "absorb",
        "target_ref": "workbench:docs/auth-testing",
        "reason_code": "cross-project-reuse",
        "authorization_ref": "conversation:message/msg-123"
      }
    }
  ]
}
```

`show` always reports `changed: false`; mutations report whether the ledger changed.
Candidates are sorted by ID. A pending candidate has `state: "pending"` and
`disposition: null`. Repeating an identical declaration or disposition is idempotent;
conflicting data fails. Completion emits `harvest-unsealed` when the inventory is open and
`harvest-undisposed` for each pending candidate.

## Verify

```text
workbench task verify --format json
```

Output is:

```json
{
  "contract_version": "workbench-verification/v1",
  "task_contract": "workbench-task/v2",
  "revision": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "verified": true,
  "required_checks": [
    {
      "check_id": "web-test",
      "owner": "web-app",
      "deliverable_id": "web-pr",
      "evidence_id": "ev-web-test-1",
      "result": "passed",
      "stale": false
    }
  ],
  "blockers": []
}
```

A computed blocker has shape `{"code":"stale-evidence","ref":"web-test"}`. Missing or
failed current evidence, a required deliverable without a revision, and unresolved required
records produce `verified: false`, JSON stdout, and exit `1`. Success appends
`task-verified` for the computed revision.

Canonical blocker codes are `missing-deliverable-revision`, `unaccepted-deliverable`,
`missing-evidence`, `failed-evidence`, `stale-evidence`, `workbench-increment-unaccepted`,
`harvest-unsealed`, `harvest-undisposed`, `terminal-outcome-conflict`, and
`action-binding-stale`. Packs may add namespaced blocker codes; consumers ignore unknown
codes but still treat them as blockers.

## Complete and abandon

### Complete

```text
workbench task complete \
  [--action-instance-id ID] [--authorization-file FILE] --format json
```

The governed action ID is `task.complete`. Target is the task's `work_ref`, or
`workbench:task/<claim_id>` when no work ref exists. Revision is the current task revision
set digest. On a first call the command internally resolves policy and may mint an action
instance. `allow` continues; `ask` returns the pending policy object at exit `3`; `deny`
returns it at exit `4`. A retry supplies the instance and authorization file.

Completion computes all non-policy blockers before minting an action instance. If blockers
exist, it returns the outcome report at exit `1` with `action_instance_id: null`. Otherwise
it resolves policy, then rechecks the revision digest immediately before mutation.

### Abandon

```text
workbench task abandon \
  --reason-code CODE [--reason-ref REF] \
  [--action-instance-id ID] [--authorization-file FILE] --format json
```

The action ID is `task.abandon`; target and revision follow completion. `reason-code` is a
stable machine identifier supplied by the judgment layer. `reason-ref` may point to the
human explanation without requiring shell plumbing to write it.

Successful outcome output is:

```json
{
  "contract_version": "workbench-task-outcome/v1",
  "task_contract": "workbench-task/v2",
  "outcome": "completed",
  "changed": true,
  "action_instance_id": "act_01J00000000000000000000000",
  "revision": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "reason_code": null,
  "reason_ref": null,
  "blockers": []
}
```

Abandonment changes `outcome` to `abandoned` and sets the reason fields. A computed
precondition failure returns the same shape with `outcome: null`, `changed: false`, and
blocker objects at exit `1`; it does not consume the instance. Repeating an already-recorded
terminal outcome is idempotent with `changed: false`. A conflicting terminal outcome fails.

Completion emits `task-completed`; abandonment emits `task-abandoned`.

## Governed cleanup

```text
workbench task done ID [--parent N] \
  [--action-instance-id ID] [--authorization-file FILE] --format json
```

`ID` is the existing workbench issue number or `codebase#issue`. `--parent` disambiguates a
recorded child-task identity. Selection reads task metadata and lifecycle claim facts; it
does not reverse-parse a branch name. More than one live matching claim without a unique
parent produces blocker `ambiguous-task-selection` at exit `1`.

For `workbench-task/v2`, `--force` is invalid at exit `2`. The selected task must have a
`task-completed` or `task-abandoned` outcome, clean task and nested codebase worktrees, and a
pushed task branch. Preflight blockers are `missing-terminal-outcome`,
`dirty-task-worktree`, `dirty-codebase-worktree`, `unpushed-task-branch`,
`ambiguous-task-selection`, and `action-binding-stale`.

Cleanup uses action `task.cleanup`, target `workbench:task/<claim_id>`, and the terminal
outcome revision. Its first-call, `ask`, `deny`, retry, and authorization behavior is the
same as completion. Preflight blockers are computed before minting. An authorized cleanup
removes nested codebase worktrees, the task workspace, and the local task branch; it does not
close the issue, change labels, or delete the remote branch. It then emits `task-cleaned`
with the cleanup action instance and terminal revision.

Success or a computed blocker returns:

```json
{
  "contract_version": "workbench-task-cleanup/v1",
  "task_contract": "workbench-task/v2",
  "task_id": "workbench-kit#25",
  "claim_id": "task__workbench-kit__25-20260711T030000Z-1234",
  "branch": "task/25-example",
  "outcome": "cleaned",
  "changed": true,
  "action_instance_id": "act_01J00000000000000000000000",
  "revision": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "removed": {
    "task_workspace": true,
    "codebase_worktrees": ["web-app"],
    "local_branch": true
  },
  "blockers": []
}
```

Blocked preflight sets `outcome: null`, `changed: false`, `action_instance_id: null`, and
lists blockers at exit `1`. Policy `ask` and `deny` return the policy object at exit `3` and
`4`. A prior `task-cleaned` marker makes retry idempotent with `changed: false`. If local
removal succeeds but marker delivery fails, the command exits `1` with
`lifecycle-write-failed`; retry with the same action instance and authorization reconciles
the marker without repeating destructive work. The marker is the durable consumption
receipt after task-local action storage disappears.

Legacy `workbench-task/v1` tasks retain the existing `done ID [--parent N] [--force]`
behavior and do not accept the v2 JSON contract by implication.

## Public versus private data

The JSON objects, semantics, command names, flags, and exit statuses in this page are public.
On-disk storage beneath disposable task state is private unless explicitly named above.
Capability packs call commands and must not read or mutate private record files.
