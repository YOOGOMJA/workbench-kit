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
`policy.authority/v1`, `policy.context-set/v1`, `workspace.authority/v1`,
`workspace.doctor/v1`, and `knowledge.applicability/v1`. Supported records add the workspace
and policy-authority, authorization, acceptance, external-probe, writer-ledger/claim,
doctor, cleanup-journal, and frozen action-ID contracts defined below.

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

Before a context-policy set is sealed, `context_ref` may be set or cleared. Changing it
invalidates any unsealed registration, which cannot be reused for the new ref. After seal,
`context_ref` cannot change or clear; attempts fail with `policy-context-immutable` at exit
`1` and a different governing context requires a new task. `work_ref` remains editable until
the terminal content freeze.

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
      "claim_ids": ["wc-a", "wc-b"],
      "task_claim_ids": ["claim-a", "claim-b"],
      "branches": ["task/41-a", "task/42-b"]
    }
  ]
}
```

Task, owner, claim, and branch arrays are sorted. A conflict exists when two current active
coordination-ledger claims name the same registered codebase owner. Status joins those rows
to task metadata and reports orphan or mismatched rows as integrity blockers. A conflict is
reported even when policy allows concurrency. The report is read-only and grants no write
authority.

### Enforced writer claim

The named mutation point is repository attachment, before creating a nested branch/worktree
or writing the `role: work` repo record:

```text
workbench task add-repo NAME [--ref BASE] [--role work|reference] \
  [--action-instance-id ID] [--authorization-file FILE] --format json
```

`role: reference` never claims a writer. `role: work` uses one append-only ledger on the
fixed ref `refs/heads/workbench-coordination/writer-claims` at the pinned canonical workspace
origin. `task start` or resume paths that auto-attach a work repo must call this same claim
operation; they cannot bypass it. The ref tree contains exactly `writer-claims.tsv` with this
LF-terminated schema:

```text
workbench-writer-claims/v1
claim<TAB>CLAIM_ID<TAB>OWNER<TAB>TASK_CLAIM_ID<TAB>BRANCH<TAB>CONTEXT_POLICY_SET_DIGEST<TAB>active|released
```

Rows form an append-only set and are sorted by owner, claim ID, then state (`active` before
`released`). A claim ID has exactly one active row and at most one later released row; the
release repeats every other field. A claim is current only when its active row has no release
row. Rows are never removed or rewritten. The canonical file is reserialized from the union
after each append. A malformed file or non-fast-forward history outside this protocol is
`writer-lock-unavailable`.

The fixed ref is infrastructure, never a task branch; task branch discovery and cleanup must
exclude it by exact ref name.

The claim algorithm is exact:

1. Fetch the fixed ref from the pinned origin and record its OID, or null when it does not
   exist; parse the immutable commit's ledger.
2. Mint and persist one stable writer claim ID in disposable task bookkeeping before any
   remote write, add the prospective row in memory, derive current conflicts from active
   rows, and resolve `task.concurrent-write` over the union of their sealed context sets.
   Retries reuse that ID. With no conflict, no concurrent-write action is needed.
3. Immediately before mutation, refetch the observed OID, rederive conflicts and policy,
   create a commit whose sole parent is that OID (or no parent for initial creation), and
   whose tree contains the canonical ledger plus the new active row.
4. Push normally as a fast-forward or with exact
   `--force-with-lease=<ref>:<observed-oid>` compare-and-swap. Initial creation compares
   against an absent ref. CAS failure refetches and restarts from step 1; changed conflict or
   policy binding supersedes the old action and authorization before retry.
5. After push success, refetch the remote ref and verify that the exact claim is current in
   the fetched ledger. Only then create the nested worktree and task repo record. Local
   creation failure appends a matching release through the same CAS loop and does not consume
   the action.

The remote commit OID is the serialization token. It is not a local-write fencing token, and
no expiry or process-local lease grants authority. Before an active row is published, policy
`ask` or `deny` publishes no claim. Cleanup appends the matching `released` row through the
same CAS loop; this is cleanup reconciliation and does not alter the frozen task-content
writer row.

Retry first reconciles the persisted claim ID. A current remote active row with no local
repo record revalidates policy/authority and resumes verification plus local creation; it is
not treated as completed. If fresh policy or authority no longer permits that persisted
claim, the kernel appends its release through the CAS loop before returning the policy result;
a failed release is marked pending and returns `writer-lock-unavailable`. A matching released
row cannot reactivate, so a later attempt mints a new claim ID and action binding. If local
creation failed, bookkeeping likewise marks release pending and every retry completes the CAS
release before any new claim. Remote failure may leave the active row visible and returns
`writer-lock-unavailable`; it never reports local writer success. This same reconciliation
handles a crash after push and before verification.

The action target is `workbench:codebase/<owner>`. Its revision is the canonical
`workbench-writer-conflict/v1` digest below, computed from active remote rows plus the
prospective claim. A changed ledger or policy manifest supersedes the instance and
re-resolves. `allow` is consumed only after remote claim verification, writer record, and
nested worktree creation all succeed.

Success returns:

```json
{
  "contract_version": "workbench-writer-claim/v1",
  "task_contract": "workbench-task/v2",
  "owner": "shared-api",
  "claim_id": "wc_01J00000000000000000000000",
  "task_claim_id": "task__example__42-20260711T030000Z-1234",
  "role": "work",
  "conflicts": [
    {
      "claim_id": "wc_existing",
      "task_claim_id": "task__example__41-20260710T030000Z-1234",
      "branch": "task/41-a",
      "context_policy_set_digest": "sha256:6666666666666666666666666666666666666666666666666666666666666666"
    }
  ],
  "changed": true,
  "coordination_ref": "refs/heads/workbench-coordination/writer-claims",
  "coordination_revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "action_instance_id": "act_01J00000000000000000000000",
  "blockers": []
}
```

An unsealed non-null participant set returns `policy-context-unsealed` at exit `1`; an
unsealed null context first performs the canonical lazy empty seal. Remote authority, ledger,
CAS-reconciliation, or write-readiness failure returns `writer-lock-unavailable` at exit `1`.
Policy results use standard `0/3/4` exits. Repeating an existing verified active claim with
its matching local repo record is idempotent.

`workbench doctor --format json` checks the pinned origin identity, protected default-ref
identity/readability, strict coordination-ledger parse, and non-destructive push readiness.
For an existing coordination ref it performs an exact no-op dry-run push of the observed
OID; for an absent ref the hosting adapter must confirm create-ref permission without
creating it. It exits `1` when not ready and includes:

```json
{
  "contract_version": "workbench-doctor/v1",
  "ready": true,
  "writer_coordination": {
    "authority_identity": "github:example/workbench",
    "origin_url": "https://github.com/example/workbench.git",
    "default_ref": "refs/heads/main",
    "default_ref_revision": "1111111111111111111111111111111111111111",
    "default_ref_protected": true,
    "ref": "refs/heads/workbench-coordination/writer-claims",
    "revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "readable": true,
    "push_ready": true,
    "blocker": null
  }
}
```

Any failed field sets `ready: false`, leaves unavailable values null, and sets blocker
`{"code":"writer-lock-unavailable","ref":"refs/heads/workbench-coordination/writer-claims"}`.
Doctor never mutates the coordination ref.

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
  [--reason-code CODE] [--reason-ref REF] \
  [--action-instance-id ID] [--authorization-file FILE] \
  --format json
```

At least one update field is required. `external_ref` remains optional in every state.
`submitted` and `accepted` require a non-null revision; `declared`, `waived`, and `rejected`
may have `revision: null`. `update --state accepted` is invalid; only an acceptance receipt
can create that state, and acceptance requires current state `submitted`.

Exactly three update effects are governed: `required: true -> false`
(`task.deliverable.weaken`), state to `waived`, and state to `rejected`. A call may select at
most one. A governed call contains only its one effect plus required `--reason-code`, optional
`--reason-ref`, and action/authorization flags; combining it with another required/state,
revision, or external-ref mutation is invalid at exit `2`. This preserves one action and one
authorization binding. The updated record stores action ID, reason, consumed action instance,
and authorization ref. Repeating the exact resulting governed record is idempotent.

Changing a revision makes prior evidence stale. From `accepted`, `waived`, or `rejected`, a
revision change must explicitly select `declared` or `submitted` in the same non-governed
call; that reset clears `acceptance_ref` and all governance fields but never deletes old
append-only acceptance receipts. Setting state to `declared` or `submitted` without a
revision change performs the same reset. Restoring `required: true` is allowed only in
`declared` or `submitted` and clears a prior weaken governance record. A new valid acceptance
also clears governance fields and sets a new acceptance ref. Other ordinary field changes do
not silently clear an active weaken reason.

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

The file is an owner assertion, not authorization by itself. The kernel finds participants
whose context namespace equals the deliverable kind namespace and whose sealed
`authority_ref` equals the assertion. Exactly one must match; zero or multiple matches return
`acceptance-authority-mismatch`. Assertion `actor` and `accepted_at` equal action
authorization `actor` and `authorized_at`, and the trusted adapter authenticates that actor
against the matching participant receipt's `authority_identity`. Pack-owned acceptance
therefore always requires explicit `workbench-authorization/v1`; standing `allow` alone
cannot accept it.

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
  "authority_ref": "toolbox:policy/acme-api",
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
    "governance_action": null,
    "reason_code": null,
    "reason_ref": null,
    "governance_action_instance_id": null,
    "authorization_ref": null
  }
}
```

A governed waiver uses the same envelope and persists the exact reason and binding:

```json
{
  "contract_version": "workbench-deliverables/v1",
  "task_contract": "workbench-task/v2",
  "changed": true,
  "deliverable": {
    "deliverable_id": "optional-report",
    "owner": "reporting",
    "kind": "toolbox:artifact/report",
    "required": true,
    "external_ref": null,
    "revision": null,
    "state": "waived",
    "acceptance_ref": null,
    "governance_action": "task.deliverable.waive",
    "reason_code": "owner-deferred",
    "reason_ref": "conversation:message/msg-456",
    "governance_action_instance_id": "act_01J00000000000000000000001",
    "authorization_ref": "conversation:message/msg-456"
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
    "governance_action": null,
    "reason_code": null,
    "reason_ref": null,
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
the listed field order as minified UTF-8 JSON plus LF. The receipt's `authority_ref` is the
matched participant authority ref, `actor` is the authorization actor, and `accepted_at` is
the authorization timestamp. The exact `workbench-acceptance/v1` fields are
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

Governed mutations accept no policy-source override flags. Workspace policy is required and
is read only from the current immutable Git object on the trusted workspace origin/default
ref. The caller worktree and task branch copy of `.workbench/policy.conf` are never policy
inputs. Platform policy is optional and comes only from a trusted harness adapter. Context
and optional task policy come only from the sealed task set below. Absent optional platform
or task policy is neutral and produces no manifest row. A read-only diagnostic may inspect
explicit files, but its output cannot create, authorize, or consume an action instance.

### Workspace policy authority

At v2 bootstrap or task claim, a trusted adapter pins workspace authority identity in an
append-only issue fact outside the task branch:

```html
<!-- workbench-workspace-authority:v1
{"contract_version":"workbench-workspace-authority/v1","task_claim_id":"task__example__42-20260711T030000Z-1234","authority_identity":"github:example/workbench","origin_url":"https://github.com/example/workbench.git","default_ref":"refs/heads/main","actor":"workbench","claimed_at":"2026-07-11T03:00:00Z"}
-->
```

The JSON fields and order shown are exact; authority-fact digest is SHA-256 over that
minified UTF-8 JSON plus LF. The adapter authenticates the marker against the task issue home
and normalizes GitHub origins to canonical HTTPS with a `.git` suffix. It must also verify
that the default ref is protected from direct writes by the task actor; unverifiable or
unprotected authority is `policy-authority-unavailable`. The
`authority_identity`, `origin_url`, and `default_ref` are immutable for the task. Missing,
conflicting, or unauthenticated authority facts block at exit `1` with
`policy-authority-unavailable`; a different remote identity or default symbolic ref blocks
with `policy-authority-mismatch`.

Bootstrap writes the same marker to the accepted migration/bootstrap issue with
`task_claim_id: null`. Each v2 task claim writes a task-specific copy whose three authority
identity fields must equal that bootstrap fact. `workbench doctor` uses the bootstrap fact;
task policy resolution uses the matching task fact. A mismatch between them is
`policy-authority-mismatch`, never a fallback to local Git configuration.

Before every resolution and immediately before consumption, the kernel runs the equivalent
of `git ls-remote --symref <pinned-origin-url> HEAD <pinned-default-ref>`. It requires `HEAD`
to name the pinned ref and that ref to advertise one exact OID, fetches that OID without
updating a caller branch, revalidates protection through the trusted hosting adapter, and
reads `<OID>:.workbench/policy.conf` from the object database.
Remote/authentication/fetch failure returns `policy-authority-unavailable`. A valid authority
revision without the file returns `policy-source-missing`; malformed policy returns
`policy-source-invalid`. The observed OID, source digest, pinned identity/ref, and authority
fact digest are bound into the action manifest. Existing tasks therefore see the current
protected default revision: a newly restrictive workspace policy supersedes every older
pending instance and authorization.

Platform adapters and context owners use this strict authority receipt:

```json
{
  "contract_version": "workbench-policy-authority-receipt/v1",
  "authority_identity": "toolbox:authority/product-owner",
  "authority_ref": "toolbox:policy/acme-api",
  "authority_revision": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "policy_ref": "products/acme-api/policy.conf",
  "policy_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "actor": "product-owner@example.com",
  "issued_at": "2026-07-11T03:00:00Z",
  "source_ref": "toolbox:approval/policy-acme-api-v3"
}
```

Those nine fields are exact. Receipt digest serialization uses the shown order, minified
UTF-8 JSON, and final LF. The trusted platform authenticates `actor` and `source_ref`, and
the authority adapter must retrieve immutable bytes at `authority_revision` whose ref and
digest exactly match the receipt. `policy_digest` is `sha256:<64 lowercase hex>`;
`authority_revision` is a 40/64-character lowercase Git OID or the same prefixed SHA-256
form; `issued_at` is RFC 3339 UTC. Authority identity/ref, actor, and source ref are nonempty
printable ASCII without TAB/LF and must resolve through a registered trusted adapter.
Caller-supplied receipt text alone is never authority.

### Sealed context-policy set

A non-null context owner validates participant semantics and produces one strict registration
before any governed mutation:

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
`task_policy`, `actor`, and `registered_at`, in that order. Each participant has exactly
`context_ref`, `policy_ref`, `policy_digest`, `authority_ref`, and `authority_receipt`.
`authority_receipt` is the exact `workbench-policy-authority-receipt/v1` object above.
Different participants may and normally do name different authority identities and refs.

`policy_ref` is workspace-relative; absolute paths, `..`, duplicate contexts, symlink
escapes, and paths resolving outside the caller worktree are invalid. Participant
`policy_digest`, `authority_ref`, and `policy_ref` must equal the nested receipt fields.
`task_policy` is either null or an object with exactly `policy_ref`, `policy_digest`,
`authority_ref`, and `authority_receipt`; its ref is exactly
`task/.workbench/policy.conf`. Registration digest serialization uses the top-level field
order above, participants sorted by context ref, participant and task-policy field order just
listed, canonical receipt serialization, minified UTF-8 JSON, and final LF.

Registration is governed action `task.policy-context.register`, using only trusted platform
and canonical workspace policy. Register always requires explicit
`workbench-authorization/v1`; standing `allow` is insufficient. The trusted platform
authenticates that the authorization actor controls the task context namespace and attests
that the participant list is complete. Assertion `actor` and `registered_at` equal
authorization `actor` and `authorized_at`; task claim and context refs equal current task
records. Each participant receipt is independently authenticated against its named owner.

Seal is action `task.policy-context.seal` and evaluates every proposed participant plus a
present task policy. A non-null task context cannot register or seal an empty participant
set. A present task policy must have an owner-authenticated receipt at registration; it is an
additional lattice layer and can tighten but never relax workspace, platform, or participant
results. Its absence is neutral. Before seal and on every later resolution, participant and
task-policy current bytes must equal their sealed digests and authority receipts. Missing or
different bytes return `policy-source-tampered` at exit `1`; the kernel never treats the
changed bytes as a new permissive source or mints a replacement action. Updating any sealed
participant or task policy requires a new task.

A task whose `context_ref` is null does not prompt or accept a registration file. It remains
unsealed so `refs set --context-ref ...` can bind a product context after `task start`. Only
when the first governed mutation begins, or `policy-context seal` is explicitly called, and
the ref is still null does the kernel lazily create and seal an empty set with
`participants: []`, `task_policy: null`, registration ID `auto-null`, actor `workbench`, and
that operation's timestamp. Its registration ref is
`workbench:context-registration/auto-null/<task_claim_id>`; registration and set action IDs
are null. After this lazy seal, context is immutable and a different context requires a new
task.

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
  "action_instance_id": "act_01J00000000000000000000000",
  "participants": [
    {
      "context_ref": "toolbox:product/acme-api",
      "policy_ref": "products/acme-api/policy.conf",
      "policy_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "authority_ref": "toolbox:policy/acme-api",
      "authority_receipt": {
        "contract_version": "workbench-policy-authority-receipt/v1",
        "authority_identity": "toolbox:authority/product-owner",
        "authority_ref": "toolbox:policy/acme-api",
        "authority_revision": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "policy_ref": "products/acme-api/policy.conf",
        "policy_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "actor": "product-owner@example.com",
        "issued_at": "2026-07-11T03:00:00Z",
        "source_ref": "toolbox:approval/policy-acme-api-v3"
      }
    }
  ],
  "task_policy": null
}
```

When present, `task_policy` has this exact shape (the nested receipt still has its nine exact
fields):

```json
{
  "policy_ref": "task/.workbench/policy.conf",
  "policy_digest": "sha256:1212121212121212121212121212121212121212121212121212121212121212",
  "authority_ref": "toolbox:task-policy/SCN-001",
  "authority_receipt": {
    "contract_version": "workbench-policy-authority-receipt/v1",
    "authority_identity": "toolbox:authority/product-owner",
    "authority_ref": "toolbox:task-policy/SCN-001",
    "authority_revision": "sha256:3434343434343434343434343434343434343434343434343434343434343434",
    "policy_ref": "task/.workbench/policy.conf",
    "policy_digest": "sha256:1212121212121212121212121212121212121212121212121212121212121212",
    "actor": "product-owner@example.com",
    "issued_at": "2026-07-11T03:00:00Z",
    "source_ref": "conversation:message/msg-task-policy"
  }
}
```

Participants are sorted by context ref and stored in task content. `registration_ref` is
`workbench:context-registration/<registration_id>` for an owner registration.
`registration_digest` is SHA-256 over its canonical registration JSON. `show` reports
`changed: false`; before registration/lazy seal its digest, registration refs, and action ID
are null with empty participants and null task policy. Register returns `sealed: false` and
its consumed action ID; seal returns `sealed: true` and its consumed action ID. Lazy
null-context seal returns `sealed: true` with a null action ID. Every governed mutation
derives all context and task sources from the complete sealed set; caller
flags cannot subtract or replace them. `task.concurrent-write` uses the union of sealed sets
from the prospective task and every active writer.

The set digest is SHA-256 over these exact LF-terminated rows:

```text
workbench-context-policy-set/v1
task_claim_id<TAB>TASK_CLAIM_ID
task_context_ref<TAB>CONTEXT_REF_OR_null
registration_ref<TAB>REGISTRATION_REF_OR_null
registration_digest<TAB>REGISTRATION_DIGEST_OR_null
participant<TAB>CONTEXT_REF<TAB>POLICY_REF<TAB>POLICY_DIGEST<TAB>AUTHORITY_IDENTITY<TAB>AUTHORITY_REF<TAB>AUTHORITY_REVISION<TAB>AUTHORITY_RECEIPT_DIGEST
task_policy<TAB>POLICY_REF<TAB>POLICY_DIGEST<TAB>AUTHORITY_IDENTITY<TAB>AUTHORITY_REF<TAB>AUTHORITY_REVISION<TAB>AUTHORITY_RECEIPT_DIGEST
```

Participant rows are sorted by context ref. The `task_policy` row is omitted when absent.
Authority fields come from each canonical receipt; there is no singleton set authority.
Policy bytes are represented by pinned digests, rechecked before every resolution and
consumption, and also bound with current authority facts in every action manifest.

### Policy source grammar

A `workbench-policy/v1` source is UTF-8 key/value text:

```text
schema=workbench-policy/v1
action.task.complete=ask
action.task.abandon=ask
```

Blank lines and `#` comments are ignored. `schema` occurs once. Action keys are unique;
values are `allow`, `ask`, or `deny`. Only frozen kernel action IDs below are valid action
keys; unknown/namespaced keys, duplicates, and malformed lines are invalid. An absent known
action in a valid present source contributes `ask`.

### Canonical policy-source manifest

The resolver reads each source and builds this LF-terminated, TAB-separated manifest:

```text
workbench-policy-manifest/v1
source<TAB>LAYER<TAB>CONTEXT_REF_OR_null<TAB>POLICY_REF<TAB>POLICY_DIGEST<TAB>AUTHORITY_IDENTITY<TAB>AUTHORITY_REF<TAB>AUTHORITY_REVISION<TAB>AUTHORITY_RECEIPT_DIGEST<TAB>DECISION
```

Rows are sorted by layer authority (`platform`, `workspace`, `context`, `task`), then context
ref, authority identity, and policy ref. `POLICY_DIGEST` is SHA-256 over exact source bytes.
`AUTHORITY_RECEIPT_DIGEST` is the canonical receipt or workspace authority-fact digest.
`policy_manifest_digest` is SHA-256 over the exact manifest bytes.

The inventory contains exactly one required workspace row, zero or one trusted platform
row, one context row for every participant in the action's required set, and zero or one
sealed task-policy row. Register has no context/task rows; seal uses its proposed participant
and task-policy bindings; ordinary actions use the sealed set; concurrent write uses the
sealed-set union. Absent optional platform or task policy is neutral and has no row. A valid
present source without the known action key contributes `ask`. Missing workspace policy is
`policy-source-missing`; a configured authority that cannot be read is
`policy-authority-unavailable`; changed sealed context/task bytes are
`policy-source-tampered`. These exit `1` before an action instance is minted.

The JSON projection stores each row with exact fields `layer`, `context_ref`, `policy_ref`,
`policy_digest`, `authority_identity`, `authority_ref`, `authority_revision`,
`authority_receipt_digest`, and `decision`. Workspace authority revision is the freshly
observed protected-default OID. Context and task revisions remain those in their sealed
receipts. Platform fields come only from its trusted adapter receipt. No caller-supplied
source path or null placeholder can affect resolution.

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

This table is the complete executable action registry for v1. Unknown and namespaced action
IDs are not policy `ask`; `workbench policy resolve` rejects them as `unsupported-action` at
exit `2`, with no action instance or stdout. Public pack-action registration and binding are
reserved for a future contract version. Capability packs, including toolbox, compose only
these kernel actions through refs, deliverables, required checks, evidence, harvest,
completion, abandonment, concurrency, and cleanup.

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
| `task.deliverable.accept` | `workbench:deliverable/<deliverable_id>` | non-null deliverable revision | complete sealed task set; pack acceptance resolves exactly one matching participant authority |
| `task.deliverable.waive` | `workbench:deliverable/<deliverable_id>` | deliverable-record digest | complete sealed task context-policy set |
| `task.deliverable.reject` | `workbench:deliverable/<deliverable_id>` | deliverable-record digest | complete sealed task context-policy set |
| `task.deliverable.weaken` | `workbench:deliverable/<deliverable_id>` | deliverable-record digest | complete sealed task context-policy set |
| `task.required-check.waive` | `workbench:required-check/<check_id>` | required-check-record digest | complete sealed task context-policy set |
| `task.harvest.dispose` | `workbench:harvest/<candidate_id>` | harvest-candidate-record digest before disposition | complete sealed task context-policy set |
| `task.policy-context.register` | `workbench:task/<claim_id>` | strict registration-input digest | required workspace plus optional trusted platform; no proposed context/task source |
| `task.policy-context.seal` | `workbench:task/<claim_id>` | registered-set digest | required workspace, optional platform, every proposed participant, and optional proposed task policy |
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
writer<TAB>CLAIM_ID<TAB>TASK_CLAIM_ID<TAB>BRANCH<TAB>CONTEXT_POLICY_SET_DIGEST
```

All record, target, revision, and context derivations are recomputed immediately before
policy consumption. Concurrent-write conflict derivation is additionally recomputed inside
the canonical ledger CAS loop below. Governed deliverable and required-check commands use
the same first-call, pending, retry, and consumption behavior defined below for completion
and abandonment.

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
Only the frozen kernel registry above is executable. A governed mutation invokes derivation
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
          "layer": "workspace",
          "context_ref": null,
          "policy_ref": ".workbench/policy.conf",
          "policy_digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
          "authority_identity": "github:example/workbench",
          "authority_ref": "refs/heads/main",
          "authority_revision": "1111111111111111111111111111111111111111",
          "authority_receipt_digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
          "decision": "allow"
        },
        {
          "layer": "context",
          "context_ref": "toolbox:product/acme-api",
          "policy_ref": "products/acme-api/policy.conf",
          "policy_digest": "sha256:3333333333333333333333333333333333333333333333333333333333333333",
          "authority_identity": "toolbox:authority/api-owner",
          "authority_ref": "toolbox:policy/acme-api",
          "authority_revision": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "authority_receipt_digest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
          "decision": "ask"
        },
        {
          "layer": "context",
          "context_ref": "toolbox:product/acme-web",
          "policy_ref": "products/acme-web/policy.conf",
          "policy_digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
          "authority_identity": "toolbox:authority/web-owner",
          "authority_ref": "toolbox:policy/acme-web",
          "authority_revision": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
          "authority_receipt_digest": "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
          "decision": "allow"
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

Resolution reads every participant and optional task policy in the action's required set
from the binding table and applies `deny > ask > allow` across present sources. Manifest rows
preserve exact authority and content provenance. Platform, workspace, and task rows use
`context_ref: null`. Sources are sorted by layer authority, then context ref, authority
identity, and policy ref. The context owner validates completeness before registration;
after sealing the kernel makes per-call omission impossible.

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
context set, revalidates its authority receipts, re-observes the pinned workspace default
ref/OID, reopens every present source, and recomputes every digest and decision. It never
trusts a cached decision or a task-branch workspace policy copy. A changed protected
workspace revision or trusted platform receipt supersedes the old instance and
authorization, then resolves a replacement against the new full manifest. New `deny`
returns exit `4`; new `ask` returns exit `3`; new standing `allow` may continue unless the
action has the mandatory owner-authority gate, which needs a new matching authorization.
A sealed context or task-policy byte/receipt mismatch instead returns
`policy-source-tampered` at exit `1` and mints no replacement. Thus neither a newly
restrictive workspace source nor a caller-edited sealed source can be bypassed between
approval and consumption.

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
policy_context_set<TAB>SEALED<TAB>SET_DIGEST_OR_null<TAB>REGISTRATION_REF_OR_null<TAB>REGISTRATION_DIGEST_OR_null
policy_context<TAB>CONTEXT_REF<TAB>POLICY_REF<TAB>POLICY_DIGEST<TAB>AUTHORITY_IDENTITY<TAB>AUTHORITY_REF<TAB>AUTHORITY_REVISION<TAB>AUTHORITY_RECEIPT_DIGEST
task_policy<TAB>POLICY_REF<TAB>POLICY_DIGEST<TAB>AUTHORITY_IDENTITY<TAB>AUTHORITY_REF<TAB>AUTHORITY_REVISION<TAB>AUTHORITY_RECEIPT_DIGEST
writer_claim<TAB>CLAIM_ID<TAB>OWNER<TAB>TASK_CLAIM_ID<TAB>BRANCH<TAB>CONTEXT_POLICY_SET_DIGEST
deliverable<TAB>ID<TAB>OWNER<TAB>KIND<TAB>REQUIRED<TAB>EXTERNAL_REF_OR_null<TAB>REVISION_OR_null<TAB>STATE<TAB>ACCEPTANCE_REF_OR_null<TAB>GOVERNANCE_ACTION_OR_null<TAB>REASON_CODE_OR_null<TAB>REASON_REF_OR_null<TAB>GOVERNANCE_ACTION_INSTANCE_OR_null<TAB>AUTHORIZATION_REF_OR_null
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

Policy context rows are sorted by context ref; the task-policy row is omitted when absent.
Writer claims are sorted by owner and claim ID. Deliverable, acceptance, required-check,
harvest, and evidence rows are sorted by stable ID. Selected evidence is greatest
`recorded_at`, with lexicographically greatest `evidence_id` as the tie-breaker. Contract
values must not contain TAB or LF. SHA-256 over the exact UTF-8 bytes is represented as
`sha256:<lowercase-hex>`.

Action, policy, status, log, and other task-bookkeeping records are never inputs. A durable
workbench increment is declared as a deliverable with its own revision and acceptance
receipt. A `writer_claim` row exists only for each `role: work` repository attachment.
Changing refs, a writer claim, deliverable or acceptance, required-check state, harvest
ledger, or selected evidence changes the relevant digest; storing an unrelated pending
action instance cannot. A later coordination-ledger release leaves the frozen writer row and
task-content digest unchanged.

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
failed current evidence, a required non-waived deliverable that is not accepted at a
non-null revision, and unresolved required records produce `verified: false`, JSON stdout,
and exit `1`. An accepted deliverable must
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
revalidates the frozen participant/task bindings, re-observes current workspace and trusted
platform authority, and resolves the resulting manifest immediately before consumption.

The durable recovery journal is stored in the task home's GitHub issue comments, outside the
local task workspace, using this marker before any deletion:

```html
<!-- workbench-task-cleanup:v1
{"contract_version":"workbench-task-cleanup-journal/v1","journal_id":"cleanup-task__workbench-kit__25","stage":"prepared","task_id":"workbench-kit#25","claim_id":"task__workbench-kit__25-20260711T030000Z-1234","branch":"task/25-example","revision":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","action_instance_id":"act_01J00000000000000000000000","policy_manifest":{"contract_version":"workbench-policy-manifest/v1","digest":"sha256:4444444444444444444444444444444444444444444444444444444444444444","sources":[{"layer":"workspace","context_ref":null,"policy_ref":".workbench/policy.conf","policy_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","authority_identity":"github:example/workbench","authority_ref":"refs/heads/main","authority_revision":"1111111111111111111111111111111111111111","authority_receipt_digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","decision":"allow"}]},"authorization_ref":"conversation:message/msg-123","removal_plan":{"release_writer_claims":["wc_01J00000000000000000000000"],"codebase_worktrees":["web-app"],"task_workspace":true,"local_branch":true},"at":"2026-07-11T03:30:00Z"}
-->
```

The kernel writes `stage: "prepared"` only after final policy resolution; that durable
receipt consumes the action instance. If the comment cannot be written, it returns
`cleanup-journal-unavailable` and deletes nothing. It then appends `released` events for all
active writer claim IDs through the canonical coordination-ref CAS loop before removing
planned nested worktrees, the task workspace, and local branch. Release changes remote
coordination state, not the frozen task-content writer rows. CAS failure returns
`writer-lock-unavailable` and is resumed from the prepared journal without deleting local
work. Cleanup never closes the issue, changes labels, deletes the remote task branch, or
deletes coordination history. Finally it appends the same journal shape with
`stage: "completed"` and emits `task-cleaned`.

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
  "released_writer_claims": ["wc_01J00000000000000000000000"],
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
`4`. Retry first reads the issue journal: `prepared` resumes only missing writer-claim
releases and removal steps and does not reauthorize the already consumed action; `completed`
reconciles a missing `task-cleaned` lifecycle marker; a prior lifecycle marker is idempotent with
`changed: false`. Failures use `cleanup-journal-unavailable`,
`cleanup-reconciliation-failed`, `writer-lock-unavailable`, or `lifecycle-write-failed`.
The external prepared receipt is the recovery and consumption source after task-local action
storage disappears.

Legacy `workbench-task/v1` tasks retain the existing `done ID [--parent N] [--force]`
behavior and do not accept the v2 JSON contract by implication.

## Public versus private data

The JSON objects, semantics, command names, flags, and exit statuses in this page are public.
On-disk storage beneath disposable task state is private unless explicitly named above.
Capability packs call commands and must not read or mutate private record files.
