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

Capabilities add `task.contract/v2`, `profile.language/v1`, `task.acceptance/v1`,
`task.required-checks/v1`, `task.harvest/v1`, `task.cleanup/v1`,
`task.writer-conflicts/v1`, `task.writer-claims/v1`, `policy.authorization/v1`,
`policy.context-set/v1`, and
`knowledge.applicability/v1`. Supported records add the authorization, acceptance, external
probe, writer-claim, and cleanup-journal contract IDs defined below.

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
47 tag. A `workbench/v2` workspace requires this tracked file: missing, unreadable, or
invalid content makes both `profile show` and `contract show` fail closed at exit `1` with
no JSON stdout. Such a workspace never advertises `profile.language/v1` with a null
language. A valid v2 workspace reports `source: "workspace"`. Only an implicit
`workbench/v1` workspace without the file reports `language: null` and
`source: "unavailable"`. The engine and packs never parse `AGENTS.md` for language.

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
After a context-policy registration exists, `context_ref` cannot be changed or cleared;
attempts fail with `policy-context-immutable` at exit `1`. A different governing context
requires a new task. `work_ref` remains editable until the terminal content freeze.

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

### Enforced writer claim

The named mutation point is repository attachment, before creating a nested branch/worktree
or writing the `role: work` repo record:

```text
workbench task add-repo NAME [--ref BASE] [--role work|reference] \
  [--action-instance-id ID] [--authorization-file FILE] --format json
```

`role: reference` never claims a writer. For `role: work`, the kernel re-queries every
non-terminal task using the owner. With no conflict it proceeds normally. With a conflict it
resolves `task.concurrent-write` using the union of sealed context-policy sets from the
prospective and current writer tasks. `task start` or resume paths that auto-attach a work
repo must call this same claim operation; they cannot bypass it.

The final query-and-create section runs under an exclusive, owner-scoped coordination lease
shared by every process and device that can mutate the workbench. The lease has a fencing
token and expiry; the kernel must fail with `writer-lock-unavailable` rather than proceed
when the configured coordination backend cannot provide it. Policy `ask` or `deny` releases
the lease without writer state. An authorized retry acquires a fresh lease, re-queries, and
re-resolves before writing. The writer record is made durable while the lease is held, then
the lease is released. This serialization, not the read-only conflict report, closes the
query/create race; stale fencing tokens cannot write a claim.

The action target is `workbench:codebase/<owner>`. Its revision is SHA-256 over
`workbench-writer-conflict/v1`, owner, and sorted rows of claim ID, branch, and sealed context
set digest. Immediately before consumption the kernel re-queries conflicts and all policy
bytes. A changed writer set or policy manifest supersedes the instance and re-resolves.
`allow` is consumed only after the writer record and nested worktree are created; creation
failure leaves the instance unconsumed. `ask`/`deny` create no writer state.

Success returns:

```json
{
  "contract_version": "workbench-writer-claim/v1",
  "task_contract": "workbench-task/v2",
  "owner": "shared-api",
  "claim_id": "task__example__42-20260711T030000Z-1234",
  "role": "work",
  "conflicts": [
    {
      "claim_id": "claim-a",
      "branch": "task/41-a",
      "context_policy_set_digest": "sha256:6666666666666666666666666666666666666666666666666666666666666666"
    }
  ],
  "changed": true,
  "action_instance_id": "act_01J00000000000000000000000",
  "blockers": []
}
```

An unsealed participant set returns `policy-context-unsealed` at exit `1`. Lease failure
returns `writer-lock-unavailable` at exit `1`. Policy results use the standard `0/3/4` exits.
Repeating an existing identical writer claim is idempotent.

## Terminal content freeze

After `task-completed` or `task-abandoned`, revision-affecting content is immutable. The
kernel rejects refs changes, context-policy registration/seal, deliverable changes or
acceptance, required-check changes, evidence recording, harvest changes, and new writer
claims with blocker `terminal-content-frozen` before any policy resolution.

Commands without their own blocker envelope return:

```json
{
  "contract_version": "workbench-error/v1",
  "operation": "task.deliverable.update",
  "blockers": [
    {
      "code": "terminal-content-frozen",
      "ref": "workbench:task/task__example__42"
    }
  ]
}
```

Allowed operations are read-only show/list/status queries, same-outcome idempotent
reconciliation, cleanup policy and journal reconciliation, and existing status/log
bookkeeping excluded from the content manifest. A post-terminal `verify` may compute a
report but emits no new `task-verified` event. Result changes require a new task; there is no
reopen mutation in v2.

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
  [--state declared|submitted|waived|rejected] \
  [--action-instance-id ID] [--authorization-file FILE] \
  --format json
```

At least one update field is required. `external_ref` remains optional in every state. A
revision is optional while state is `declared`; `submitted` and `accepted` require a
non-null immutable revision. Changing a revision returns the deliverable to `declared` or
`submitted` and makes prior evidence stale. An `accepted`
revision is not silently replaced. Transitions to `waived` or `rejected`, or weakening a
required deliverable, are governed actions bound to that deliverable and current revision;
the updated record stores the consumed action instance and authorization reference.
`update --state accepted` is invalid; only an acceptance receipt can create that state.

### Accept

```text
workbench task deliverable accept --id ID \
  [--owner-acceptance-file FILE] \
  [--action-instance-id ID] [--authorization-file FILE] --format json
workbench task deliverable acceptance list --format json
```

Kernel-owned kinds are exactly `codebase-pr` and `workbench-increment`. They require a
registered GitHub owner, a canonical HTTPS pull-request `external_ref`, and a non-null
revision. The kernel queries the referenced PR and creates a
`workbench-probe/github-pr/v1` observation only when state is merged and `headRefOid` exactly
equals the deliverable revision. Repository/PR mismatch, an unmerged PR, or revision mismatch
blocks acceptance. The resulting receipt has `authority_type: "kernel-probe"`; no caller
can supply or override it.

The strict probe object is:

```json
{
  "contract_version": "workbench-probe/github-pr/v1",
  "repository": "example/web-app",
  "pull_request": 12,
  "external_ref": "https://github.com/example/web-app/pull/12",
  "state": "merged",
  "head_revision": "0123456789abcdef",
  "merge_revision": "fedcba9876543210",
  "observed_at": "2026-07-11T03:20:00Z"
}
```

`authority_digest` is SHA-256 over the exact minified, key-ordered JSON plus LF. The probe
receipt is valid only while repository, PR number, external ref, merged state, and head
revision all match the deliverable.

A namespaced pack-owned kind rejects kernel probing and requires
`--owner-acceptance-file`. That strict `workbench-owner-acceptance/v1` input repeats
deliverable ID, owner, kind, and revision and identifies the owner authority. Acceptance is
governed action `task.deliverable.accept`; required policies include the pack owner context,
and the action/authorization binding rules still apply. A pack cannot accept an unversioned
deliverable or one owned by a different authority.

The file is an owner assertion, not authorization by itself. The kind namespace must equal
the task context namespace, its `authority_ref` must equal the immutable authority ref in
that sealed context registration, and its `actor` and `accepted_at` must equal action
authorization `actor` and `authorized_at`. Pack-owned acceptance therefore always requires
an explicit `workbench-authorization/v1`; standing `allow` alone cannot accept it. The
trusted platform or human-gate adapter authenticates that the actor controls the registered
authority as it does for every human approval.
An arbitrary caller-authored assertion, an assertion from another registered owner, or an
assertion without the matching authenticated authorization fails before state mutation.

The strict owner input is:

```json
{
  "contract_version": "workbench-owner-acceptance/v1",
  "acceptance_id": "acc-artifact-1",
  "deliverable_id": "release-artifact",
  "owner": "release-pack",
  "kind": "toolbox:artifact/release",
  "revision": "sha256:7777777777777777777777777777777777777777777777777777777777777777",
  "authority_ref": "toolbox:authority/product-owner",
  "actor": "release-owner@example.com",
  "accepted_at": "2026-07-11T03:20:00Z"
}
```

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
    "state": "submitted",
    "acceptance_ref": null,
    "governance_action_instance_id": null,
    "authorization_ref": null
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

Successful acceptance returns the updated deliverable plus this append-only receipt:

```json
{
  "contract_version": "workbench-deliverable-acceptance/v1",
  "task_contract": "workbench-task/v2",
  "changed": true,
  "deliverable": {
    "deliverable_id": "web-pr",
    "owner": "web-app",
    "kind": "codebase-pr",
    "required": true,
    "external_ref": "https://github.com/example/web-app/pull/12",
    "revision": "0123456789abcdef",
    "state": "accepted",
    "acceptance_ref": "workbench:acceptance/acc-web-pr-1",
    "governance_action_instance_id": null,
    "authorization_ref": null
  },
  "acceptance": {
    "contract_version": "workbench-acceptance/v1",
    "acceptance_id": "acc-web-pr-1",
    "deliverable_id": "web-pr",
    "owner": "web-app",
    "kind": "codebase-pr",
    "revision": "0123456789abcdef",
    "authority_type": "kernel-probe",
    "authority_contract": "workbench-probe/github-pr/v1",
    "authority_ref": "https://github.com/example/web-app/pull/12",
    "authority_digest": "sha256:5555555555555555555555555555555555555555555555555555555555555555",
    "actor": null,
    "action_instance_id": null,
    "accepted_at": "2026-07-11T03:20:00Z"
  }
}
```

The owner-acceptance input has exact fields `contract_version`, `acceptance_id`,
`deliverable_id`, `owner`, `kind`, `revision`, `authority_ref`, `actor`, and `accepted_at`.
Its receipt uses `authority_type: "owner-authorization"`,
`authority_contract: "workbench-owner-acceptance/v1"`, SHA-256 of the strict input as
`authority_digest`, and the consumed action instance ID. That digest serializes the input in
the listed field order as minified UTF-8 JSON plus LF. The receipt's `authority_ref` is
the matched owner registration ref, `actor` is the authorization actor, and `accepted_at`
is the authorization timestamp. The exact `workbench-acceptance/v1` fields are
`contract_version`, `acceptance_id`, `deliverable_id`, `owner`, `kind`, `revision`,
`authority_type`, `authority_contract`, `authority_ref`, `authority_digest`, `actor`,
`action_instance_id`, and `accepted_at`; kernel probes use `actor: null`.
`acceptance list` returns a `workbench-acceptances/v1` object with exact fields
`contract_version` and `acceptances`; the latter is the receipt array and is empty when no
receipt exists. Duplicate acceptance IDs or conflicting receipts fail.

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
    "subject_ref": "workbench:deliverable/web-pr",
    "state": "required",
    "action_instance_id": null,
    "authorization_ref": null
  }
}
```

List output replaces `changed` and `required_check` with `required_checks: []`. A waived
record has `state: "waived"`, the consumed action instance ID, and the authorization source
reference that permitted it.
When `--deliverable-id` is present, `subject_ref` is
`workbench:deliverable/<deliverable_id>` and owner must equal the deliverable owner. Without
it, `deliverable_id` is null and subject is `workbench:task/<claim_id>`.

## Verification evidence

### Record

```text
workbench task evidence record \
  --id ID --owner OWNER --subject-ref REF --subject-revision REV --check-id ID \
  --result passed|failed --source local|ci \
  [--command COMMAND] [--url URL] \
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
    "owner": "web-app",
    "subject_ref": "workbench:deliverable/web-pr",
    "subject_revision": "0123456789abcdef",
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
read time and is always present. Recording evidence requires an existing required check with
the same `check_id`, owner, and subject ref; mismatches fail. Current subject revision is
exactly the deliverable revision for a deliverable subject, or the current
`workbench-task-content/v1` digest for a task subject. A null deliverable revision has no
current evidence. `stale` is false only when `subject_revision` equals that current revision;
evidence for another revision cannot satisfy the check.

## Policy resolution and authorization

### Canonical policy sources

Governed mutations accept no policy-source override flags. Workspace policy is always the
tracked `.workbench/policy.conf` in the caller worktree. Task policy is always
`task/.workbench/policy.conf` when present. Platform policy is injected only by the trusted
harness adapter, never a caller argument. Context sources come only from the sealed task set
below. A read-only diagnostic tool may inspect explicit files, but its output cannot create,
authorize, or consume an action instance.

### Sealed context-policy set

A namespace owner validates its opaque participant semantics and produces one strict
registration input before any governed mutation:

```text
workbench task policy-context register \
  --registration-file FILE [--action-instance-id ID] [--authorization-file FILE] \
  --format json
workbench task policy-context seal \
  [--action-instance-id ID] [--authorization-file FILE] --format json
workbench task policy-context show --format json
```

The `workbench-context-policy-registration/v1` JSON input has exact fields
`contract_version`, `registration_id`, `task_claim_id`, `task_context_ref`, `participants`,
`authority_ref`, `actor`, and `registered_at`. Each participant has `context_ref` and a
workspace-relative `policy_ref`. Absolute paths, `..`, duplicate contexts, and paths that
resolve outside the caller worktree are invalid. Registration digest serialization uses the
listed top-level field order, participants sorted by context ref, participant key order
`context_ref`, `policy_ref`, minified UTF-8 JSON, and final LF.

Registration is governed action `task.policy-context.register`, using only trusted platform,
canonical workspace, and canonical task policy. Seal is action `task.policy-context.seal`
and additionally evaluates every proposed participant policy. The registered participants
must exactly equal the owner input; a non-null task `context_ref` cannot register or seal an
empty set. A null context may explicitly register an empty set. Once sealed, the set is
immutable for that task; changing participants requires a new task.

For any registration, the file is an owner assertion and register requires explicit
`workbench-authorization/v1`; standing `allow` alone is insufficient. For a non-null task
context, the trusted platform authenticates that the authorization actor controls the
context namespace and attests that the participant list is complete. Assertion `actor` and
`registered_at` must equal authorization `actor` and `authorized_at`, while
`task_claim_id` and `task_context_ref` must exactly equal current task records. A direct
caller therefore cannot self-register a smaller participant set. The workspace authority
performs the same attestation for a null-context empty set.

All three commands return:

```json
{
  "contract_version": "workbench-context-policy-set/v1",
  "task_contract": "workbench-task/v2",
  "task_claim_id": "task__example__42-20260711T030000Z-1234",
  "task_context_ref": "toolbox:product/acme-api",
  "sealed": true,
  "changed": false,
  "digest": "sha256:8888888888888888888888888888888888888888888888888888888888888888",
  "registration_ref": "workbench:context-registration/ctxreg-1",
  "registration_digest": "sha256:9999999999999999999999999999999999999999999999999999999999999999",
  "authority_ref": "toolbox:authority/product-owner",
  "action_instance_id": "act_01J00000000000000000000000",
  "participants": [
    {
      "context_ref": "toolbox:product/acme-api",
      "policy_ref": "products/acme-api/policy.conf"
    }
  ]
}
```

Participants are sorted by context ref and stored in task content. `registration_ref` is
`workbench:context-registration/<registration_id>` and `authority_ref` is copied from the
strict owner registration. `registration_digest` is SHA-256 over the strict minified,
key-ordered registration JSON plus LF. `show` reports `changed: false` and the sealing action
ID, or null registration, authority, digest, and action fields before registration/seal. Every
governed mutation requires the set to be sealed and derives all context sources from it;
caller flags cannot subtract or replace participants. Atomic work registers every
participant. `task.concurrent-write` uses the union of sealed sets from the prospective task
and all current writer tasks. Missing, unsealed, unreadable, or owner-mismatched sets block
with `policy-context-unsealed` or resolve `ask`, never `allow`.

The set digest is SHA-256 over these exact LF-terminated rows:

```text
workbench-context-policy-set/v1
task_claim_id<TAB>TASK_CLAIM_ID
task_context_ref<TAB>CONTEXT_REF_OR_null
registration_ref<TAB>REGISTRATION_REF_OR_null
registration_digest<TAB>REGISTRATION_DIGEST_OR_null
authority_ref<TAB>AUTHORITY_REF_OR_null
participant<TAB>CONTEXT_REF<TAB>POLICY_REF
```

Participant rows are sorted by context ref. Policy file bytes are not part of this
structural set digest; they are bound separately by every action policy manifest and re-read
before consumption.

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

### Canonical policy-source manifest

The resolver reads each source and builds this LF-terminated, TAB-separated manifest:

```text
workbench-policy-manifest/v1
source<TAB>LAYER<TAB>CONTEXT_REF_OR_null<TAB>POLICY_REF_OR_null<TAB>POLICY_DIGEST_OR_null<TAB>DECISION
```

Rows are sorted by layer authority (`platform`, `workspace`, `context`, `task`), then context
ref and policy ref. Workspace/task/context `POLICY_REF` values use canonical
workspace-relative paths; the platform uses an opaque harness reference.
`POLICY_DIGEST` is SHA-256 over the exact source bytes. A missing required source uses null
reference/digest and decision `ask`. `policy_manifest_digest` is SHA-256 over the exact
manifest bytes.

The source inventory is closed: it contains exactly one platform slot, one workspace slot,
one task slot, and one context row for every participant in the action's required context
set. Register has no context rows; seal uses its proposed registered set; ordinary task
actions use the sealed task set; concurrent write uses the sealed-set union. An absent
platform, workspace, or task file remains as its null row; a missing context participant
file is an integrity blocker because the sealed registration named it. The JSON projection
stores every row with exact fields `layer`, `context_ref`, `policy_ref`, `policy_digest`, and
`decision`; no unlisted source can affect resolution without changing the manifest.

The kernel-defined action IDs in this contract are:

| Action ID | Governed operation |
|---|---|
| `task.complete` | Adopt the task outcome |
| `task.abandon` | Record terminal non-adoption |
| `task.deliverable.accept` | Accept a pack-owned deliverable through its owner authority |
| `task.deliverable.waive` | Waive a required deliverable |
| `task.deliverable.reject` | Reject a declared deliverable |
| `task.deliverable.weaken` | Change `required` from true to false |
| `task.required-check.waive` | Waive a required check |
| `task.harvest.dispose` | Record the disposition of one harvest candidate |
| `task.policy-context.register` | Register the owner-validated context participant set |
| `task.policy-context.seal` | Activate and freeze that participant set |
| `task.concurrent-write` | Proceed while a writer conflict is reported |
| `task.cleanup` | Remove a terminal v2 task workspace |

`task.policy-context.register` and pack-owned `task.deliverable.accept` have a mandatory
owner-authority gate in addition to the policy lattice. A policy `deny` still returns exit
`4`; otherwise the command returns `ask` at exit `3` until the exact authenticated
authorization is supplied, even when every policy source says `allow`. This requirement is
kernel-derived from action and deliverable kind and cannot be relaxed by caller input.

### Canonical per-action binding

| Action | `target_ref` | `revision` binding | Required context policy set |
|---|---|---|---|
| `task.complete` | `work_ref`, else `workbench:task/<claim_id>` | current `workbench-task-revision/v1` digest | complete sealed task context-policy set |
| `task.abandon` | `work_ref`, else `workbench:task/<claim_id>` | current `workbench-task-revision/v1` digest, with pending/null facts encoded | complete sealed task context-policy set |
| `task.deliverable.accept` | `workbench:deliverable/<deliverable_id>` | non-null deliverable revision | complete sealed task context-policy set, including owner context |
| `task.deliverable.waive` | `workbench:deliverable/<deliverable_id>` | deliverable-record digest | complete sealed task context-policy set |
| `task.deliverable.reject` | `workbench:deliverable/<deliverable_id>` | deliverable-record digest | complete sealed task context-policy set |
| `task.deliverable.weaken` | `workbench:deliverable/<deliverable_id>` | deliverable-record digest | complete sealed task context-policy set |
| `task.required-check.waive` | `workbench:required-check/<check_id>` | required-check-record digest | complete sealed task context-policy set |
| `task.harvest.dispose` | `workbench:harvest/<candidate_id>` | harvest-candidate-record digest before disposition | complete sealed task context-policy set |
| `task.policy-context.register` | `workbench:task/<claim_id>` | strict registration-input digest | trusted platform plus canonical workspace/task policies |
| `task.policy-context.seal` | `workbench:task/<claim_id>` | registered-set digest | platform/workspace/task plus every proposed participant |
| `task.concurrent-write` | `workbench:codebase/<owner>` | writer-conflict-set digest | union of sealed sets for prospective and current writers |
| `task.cleanup` | `workbench:task/<claim_id>` | immutable terminal outcome revision | frozen sealed set recorded by terminal action |

A record digest is SHA-256 over a contract line, its exact current row from the task-content
manifest, and final LF. The contract lines are `workbench-deliverable-record/v1`,
`workbench-required-check-record/v1`, and `workbench-harvest-candidate-record/v1` for their
respective rows. A deliverable with `revision: null` therefore binds its full record digest
for waive/reject/weaken; null is never used as the action revision. Acceptance cannot occur
with a null deliverable revision.

The writer-conflict-set digest is SHA-256 over this exact LF-terminated manifest; writer
rows include the prospective claim and are sorted by claim ID, then branch:

```text
workbench-writer-conflict/v1
owner<TAB>OWNER
writer<TAB>CLAIM_ID<TAB>BRANCH<TAB>CONTEXT_POLICY_SET_DIGEST
```

All record, conflict, target, revision, and context derivations are recomputed inside the
coordination lease immediately before policy consumption.

Pack action IDs use the pack namespace and never reuse a kernel ID with different meaning.
Governed deliverable and required-check commands use the same first-call, pending, retry,
and consumption behavior defined below for completion and abandonment.

### Resolve

```text
workbench policy resolve \
  --action-id ID --task-claim-id ID --target-ref REF --revision REV \
  [--action-instance-id ID] [--authorization-file FILE] \
  --format json|decision
```

Without `--action-instance-id`, the kernel mints and persists a unique action instance.
With an instance ID, all binding arguments are recomputed and must match the stored
instance exactly. For a kernel action, even the first call derives `target_ref`, `revision`,
and context set from the action table; caller values are assertions and a mismatch fails.
Pack actions must have a registered binding rule with the same three outputs before this
generic resolver can mint an instance. A governed mutation invokes this derivation
internally, so calling `policy resolve` cannot substitute a weaker binding.

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
    "policy_manifest": {
      "contract_version": "workbench-policy-manifest/v1",
      "digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
      "sources": [
        {
          "layer": "platform",
          "context_ref": null,
          "policy_ref": "platform:harness/default",
          "policy_digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
          "decision": "allow"
        },
        {
          "layer": "workspace",
          "context_ref": null,
          "policy_ref": ".workbench/policy.conf",
          "policy_digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
          "decision": "allow"
        },
        {
          "layer": "context",
          "context_ref": "toolbox:product/acme-api",
          "policy_ref": "products/acme-api/policy.conf",
          "policy_digest": "sha256:3333333333333333333333333333333333333333333333333333333333333333",
          "decision": "ask"
        },
        {
          "layer": "context",
          "context_ref": "toolbox:product/acme-web",
          "policy_ref": "products/acme-web/policy.conf",
          "policy_digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
          "decision": "allow"
        },
        {
          "layer": "task",
          "context_ref": null,
          "policy_ref": null,
          "policy_digest": null,
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

`status` is `pending`, `authorized`, `consumed`, `denied`, or `superseded`.
`--format decision` prints only `allow`, `ask`, or `deny` plus LF and uses the same exit
status.

Resolution reads every participant in the action's required context set from the binding
table and applies `deny > ask > allow` across the complete set.
`policy_manifest.sources` preserves provenance
with the context ref, portable canonical policy reference, and SHA-256 of the exact policy
bytes. Platform, workspace, and task sources use `context_ref: null`. Sources are sorted by
layer authority, then context ref and policy ref. The pack validates the opaque participant
list before registration; after registration the kernel makes per-call omission impossible.

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
  "policy_manifest_digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
  "decision": "allow",
  "actor": "human@example.com",
  "authorized_at": "2026-07-11T03:01:00Z",
  "source_ref": "conversation:message/msg-123"
}
```

The decision is `allow` or `deny`; `ask` is not an authorization. Every binding field must
match the stored action instance, including `policy_manifest_digest`.
`authorization_id` is unique within the task and may be attached to only one instance. A
used authorization or an instance with a different action, task claim, target, revision, or
policy manifest is rejected at exit `1`.

Immediately before consuming any governed action, the command re-derives its required
context set, reopens every manifest source, recomputes every source digest and decision, and
re-resolves the strictest policy. It never trusts the cached decision. If the source set or
manifest digest changed, the old instance becomes `superseded` and its authorization cannot
be reused. The resolver mints a replacement bound to the new full manifest: new `deny`
returns exit `4`, new `ask` returns exit `3`, and new standing `allow` may continue with the
replacement authorized instance unless the action has the mandatory owner-authority gate,
which requires a new matching authorization. Thus a newly restrictive source cannot be
bypassed between approval and consumption.

The kernel persists action status in tracked, disposable task state. The storage path is
private, but the record survives session handoff when the task state is committed. A
governed mutation marks an authorized instance `consumed` only after the mutation and its
required lifecycle observation, if any, succeed. Cleanup is the documented exception: its
externally durable `prepared` journal is the committed mutation and consumption point because
task-local action storage is about to be deleted. A failed precondition leaves the instance
reusable only for the identical binding. Action, log, status, and other disposable
bookkeeping records are excluded structurally from the task revision digest, so persisting a
pending instance cannot change its own binding.

The binding prevents accidental or cross-target replay; authenticity of `actor` and
`source_ref` remains the responsibility of the higher-authority platform or human-gate
adapter.

In a resolution object, `authorization_ref` equals the validated authorization input's
`source_ref`; it is null for standing `allow`, unresolved `ask`, and policy `deny`. An
authorization ID may be retried only with its same, unconsumed action instance.

## Task content and outcome revisions

Task-level evidence cannot bind to a digest that includes that same evidence. The kernel
therefore creates two LF-terminated, TAB-separated manifests.

The content manifest is:

```text
workbench-task-content/v1
task_contract<TAB>workbench-task/v2
context_ref<TAB>REF_OR_null
work_ref<TAB>REF_OR_null
policy_context_set<TAB>SEALED<TAB>SET_DIGEST_OR_null<TAB>REGISTRATION_REF_OR_null<TAB>REGISTRATION_DIGEST_OR_null<TAB>AUTHORITY_REF_OR_null
policy_context<TAB>CONTEXT_REF<TAB>POLICY_REF
writer_claim<TAB>OWNER<TAB>BRANCH
deliverable<TAB>ID<TAB>OWNER<TAB>KIND<TAB>REQUIRED<TAB>EXTERNAL_REF_OR_null<TAB>REVISION_OR_null<TAB>STATE<TAB>ACCEPTANCE_REF_OR_null<TAB>GOVERNANCE_ACTION_INSTANCE_OR_null<TAB>AUTHORIZATION_REF_OR_null
acceptance<TAB>ID<TAB>DELIVERABLE_ID<TAB>OWNER<TAB>KIND<TAB>REVISION<TAB>AUTHORITY_TYPE<TAB>AUTHORITY_CONTRACT<TAB>AUTHORITY_REF<TAB>AUTHORITY_DIGEST<TAB>ACTOR_OR_null<TAB>ACTION_INSTANCE_OR_null<TAB>ACCEPTED_AT
required_check<TAB>ID<TAB>OWNER<TAB>SUBJECT_REF<TAB>STATE<TAB>ACTION_INSTANCE_OR_null<TAB>AUTHORIZATION_REF_OR_null
harvest<TAB>SEALED
harvest_candidate<TAB>ID<TAB>KIND<TAB>SOURCE_REF<TAB>STATE<TAB>DECISION_OR_null<TAB>TARGET_REF_OR_null<TAB>REASON_CODE_OR_null<TAB>ACTION_INSTANCE_OR_null<TAB>AUTHORIZATION_REF_OR_null
```

SHA-256 over those bytes is the `workbench-task-content/v1` revision. The outcome manifest
then binds selected evidence without a cycle:

```text
workbench-task-revision/v1
content_revision<TAB>SHA256_CONTENT_REVISION
evidence<TAB>CHECK_ID<TAB>SUBJECT_REF<TAB>SUBJECT_REVISION<TAB>EVIDENCE_ID_OR_null<TAB>RESULT_OR_null<TAB>STALE
```

Writer claims are sorted by owner and branch. Deliverable, acceptance, required-check,
harvest, and evidence rows are sorted by stable ID. Selected evidence is greatest
`recorded_at`, with lexicographically greatest `evidence_id` as the tie-breaker. Contract
values must not contain TAB or LF. SHA-256 over the exact UTF-8 bytes is represented as
`sha256:<lowercase-hex>`.

Action, policy, status, log, and other task-bookkeeping records are never inputs. A durable
workbench increment is declared as a deliverable with its own revision and acceptance
receipt. A `writer_claim` row exists only for each `role: work` repository attachment.
Changing refs, a writer claim, deliverable or acceptance, required-check state, harvest
ledger, or selected evidence changes the relevant digest; storing an unrelated pending
action instance cannot.

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
        "action_instance_id": "act_01J00000000000000000000000",
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
      "subject_ref": "workbench:deliverable/web-pr",
      "subject_revision": "0123456789abcdef",
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
records produce `verified: false`, JSON stdout, and exit `1`. An accepted deliverable must
reference a receipt whose ID, owner, kind, revision, authority contract, and authority digest
all validate; the state field alone is never sufficient. Success appends `task-verified` for
the computed revision.

Canonical blocker codes are `missing-deliverable-revision`, `unaccepted-deliverable`,
`missing-acceptance-receipt`, `acceptance-authority-mismatch`, `external-not-accepted`,
`missing-evidence`, `evidence-owner-mismatch`, `evidence-subject-mismatch`,
`failed-evidence`, `stale-evidence`, `workbench-increment-unaccepted`, `harvest-unsealed`,
`harvest-undisposed`, `terminal-outcome-conflict`, `terminal-content-frozen`, and
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
digest. On a first call the command internally resolves policy and may mint an action
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

Abandonment does **not** require accepted deliverables, passing evidence, a sealed harvest
ledger, or a workbench increment. It requires a non-terminal v2 task, a parseable current
content/revision snapshot, a sealed context-policy set, a reason code, and successful policy
resolution. Pending and null deliverable facts are encoded in its revision binding. Dirty or
unpushed work may still block later cleanup, but it is not misrepresented as a completion
predicate.

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

Completion emits `task-completed`; abandonment emits `task-abandoned`. Either event activates
the terminal content freeze before the command returns success.

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
re-reads the frozen terminal policy sources immediately before consumption.

The durable recovery journal is stored in the task home's GitHub issue comments, outside the
local task workspace, using this marker before any deletion:

```html
<!-- workbench-task-cleanup:v1
{"contract_version":"workbench-task-cleanup-journal/v1","journal_id":"cleanup-task__workbench-kit__25","stage":"prepared","task_id":"workbench-kit#25","claim_id":"task__workbench-kit__25-20260711T030000Z-1234","branch":"task/25-example","revision":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","action_instance_id":"act_01J00000000000000000000000","policy_manifest":{"contract_version":"workbench-policy-manifest/v1","digest":"sha256:4444444444444444444444444444444444444444444444444444444444444444","sources":[{"layer":"platform","context_ref":null,"policy_ref":"platform:harness/default","policy_digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","decision":"allow"},{"layer":"workspace","context_ref":null,"policy_ref":".workbench/policy.conf","policy_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","decision":"allow"},{"layer":"task","context_ref":null,"policy_ref":null,"policy_digest":null,"decision":"ask"}]},"authorization_ref":"conversation:message/msg-123","removal_plan":{"codebase_worktrees":["web-app"],"task_workspace":true,"local_branch":true},"at":"2026-07-11T03:30:00Z"}
-->
```

The kernel writes `stage: "prepared"` only after final policy resolution; that durable
receipt consumes the action instance. If the comment cannot be written, it returns
`cleanup-journal-unavailable` and deletes nothing. It then removes planned nested worktrees,
the task workspace, and local branch without closing the issue, changing labels, or deleting
the remote branch. Finally it appends the same journal shape with `stage: "completed"` and
emits `task-cleaned`.

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
`4`. Retry first reads the issue journal: `prepared` resumes only missing removal steps and
does not reauthorize the already consumed action; `completed` reconciles a missing
`task-cleaned` lifecycle marker; a prior lifecycle marker is idempotent with
`changed: false`. Failures use `cleanup-journal-unavailable`,
`cleanup-reconciliation-failed`, or `lifecycle-write-failed`. The external prepared receipt
is the recovery and consumption source after task-local action storage disappears.

Legacy `workbench-task/v1` tasks retain the existing `done ID [--parent N] [--force]`
behavior and do not accept the v2 JSON contract by implication.

## Public versus private data

The JSON objects, semantics, command names, flags, and exit statuses in this page are public.
On-disk storage beneath disposable task state is private unless explicitly named above.
Capability packs call commands and must not read or mutate private record files.
