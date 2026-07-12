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
`task.abandonment/v1`, `task.required-checks/v1`, `task.harvest/v1`, `task.cleanup/v1`,
`task.writer-conflicts/v1`, `task.writer-claims/v1`, `policy.authorization/v1`,
`task.writer-handoff/v1`, `policy.applied-effect-recovery/v1`, `policy.authority/v1`,
`policy.context-set/v1`, `policy.intent/v1`, `workspace.authority/v1`,
`workspace.doctor/v1`, and `knowledge.applicability/v1`. Supported records add the workspace
and policy-authority, authorization/action-intent/applied-effect provenance,
completion/abandonment revision, acceptance,
stable and timestamped external-probe, writer-ledger/claim/effect-owner, doctor,
cleanup-plan/journal, and frozen action-ID contracts defined below.

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

## V2 task start and resume

```text
workbench task start ID [slug] [--parent N] --format json
workbench task resume ID [--parent N] --format json
```

`slug`, when supplied, is the existing validated task slug. When omitted, start preserves the
v1 fallback unchanged: it retrieves the authoritative issue title and applies the existing
issue-title slug derivation before creating the branch. Failure to retrieve or derive a valid
slug blocks start. `resume` reads the recorded identity and never accepts a replacement slug.

For `workbench-task/v2`, `start` creates only the workbench task branch, task workspace,
identity metadata, claim observation, and empty task-state skeleton. It does not accept
context/work-ref flags, attach a `role: work` codebase, create a nested codebase worktree, or
register/lazily seal a context-policy set. Callers use the existing atomic `task refs set`
command after start; this keeps one portable reference mutation contract instead of a second
partial start-time form.

`resume` recreates or selects only the v2 task workspace and reads existing state. It never
infers or auto-attaches a missing work repository, and it never advances a pending writer
operation. Recovery remains an explicit retry of the matching `task add-repo`. Existing
attached repositories may be reported, but a missing nested worktree is a recovery state, not
an instruction for resume to create one.

Both commands return this exact shape:

```json
{
  "contract_version": "workbench-task-start/v2",
  "task_contract": "workbench-task/v2",
  "task_claim_id": "task__example__42-20260711T030000Z-1234",
  "branch": "task/42-example",
  "workspace_authority_descriptor_digest": "sha256:abababababababababababababababababababababababababababababababab",
  "context_ref": null,
  "work_ref": null,
  "context_policy_sealed": false,
  "work_owners": [],
  "changed": true
}
```

`start` returns `changed: true`; an already materialized `resume` returns `changed: false`.
The v2 sequence is skeleton, optional `refs set`, owner registration/seal for a non-null
context or canonical lazy empty seal at the first explicit governed mutation while still
null, then explicit `add-repo --role work`. `add-repo --role reference` does not seal the
context. Legacy `workbench-task/v1` start/resume keeps its existing auto-attach behavior and
does not emit this v2 contract.

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

`work_ref` mutation keeps the authoritative active-task inventory check and then acquires a
per-value remote Git reservation as the final compare-and-set. A competing valid reservation
is reported as the same duplicate-work failure. An unreadable, malformed, or unwritable
reservation reports `work-ref-reservation-unavailable`; a value already written locally but
whose stale reservation could not be lease-released reports
`work-ref-reservation-release-unreconciled`. Repeating the same set/clear operation is the
recovery path and converges all reservations owned by that task claim.

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
      "workspace_authority_descriptor_digest": "sha256:abababababababababababababababababababababababababababababababab",
      "context_ref": "toolbox:product/acme",
      "work_ref": "toolbox:scenario/SCN-001",
      "work_owners": ["shared-api"]
    }
  ],
  "writer_conflicts": [
    {
      "owner": "shared-api",
      "claims": [
        {
          "source": "ledger-v2",
          "claim_id": "wc-a",
          "operation_id": "wop-a",
          "task_claim_id": "claim-a",
          "owner": "shared-api",
          "branch": "task/41-a",
          "context_policy_set_digest": "sha256:6666666666666666666666666666666666666666666666666666666666666666",
          "source_revision": null,
          "pr_head_revision": null,
          "lifecycle_digest": null
        },
        {
          "source": "legacy-v1",
          "claim_id": "legacy-v1-7777777777777777777777777777777777777777777777777777777777777777",
          "operation_id": null,
          "task_claim_id": "legacy-claim-b",
          "owner": "shared-api",
          "branch": "task/40-legacy",
          "context_policy_set_digest": null,
          "source_revision": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "pr_head_revision": "cccccccccccccccccccccccccccccccccccccccc",
          "lifecycle_digest": "sha256:8888888888888888888888888888888888888888888888888888888888888888"
        }
      ]
    }
  ],
  "writer_integrity_blockers": []
}
```

Task and owner arrays are sorted; claims are sorted by source, claim ID, then branch. A
conflict exists when two current claims name the same owner. Current claims are the union of
active v2 coordination-ledger rows and the deterministic active-v1 pseudo-claims below, never
the ledger alone. Orphan, mismatch, unreadable legacy source, or malformed operation state is
reported in `writer_integrity_blockers` and makes status exit `1` after emitting the complete
diagnostic JSON. A conflict remains visible when policy permits it; status is read-only and
grants no write authority.

### Active v1 writer projection

At each resolution the kernel reads `.workbench/authority.json` and `codebases.yaml` from the
same protected-default OID used for workspace policy. The closed home set is the descriptor's
`workspace_home` plus every exact codebase home in the registry. `codebases.yaml` uses only
the existing canonical subset: blank lines and full-line `#` comments are ignored; every data
line is `HOME: CANONICAL_GIT_URL`, split on its first colon and trimmed of surrounding ASCII
space. `HOME` matches `[A-Za-z0-9][A-Za-z0-9._-]*`, is not purely numeric, and is unique;
canonical origins are nonempty and unique. Invalid YAML features, duplicates, aliases, or
noncanonical origins are `legacy-writer-source-unavailable`.

The home-set digest is SHA-256 over these exact LF-terminated rows sorted by home:

```text
workbench-legacy-home-set/v1
home<TAB>HOME<TAB>CANONICAL_ORIGIN_URL
```

The trusted hosting adapter exhausts every pagination cursor for authoritative
`workbench-task-lifecycle:v1` streams in every home; a partial page set is unavailable, never
an empty result. At each resolve it also compares the current descriptor/registry with every
protected-default home-set snapshot reachable since the v2 bootstrap commit. Every removed
home is exhaustively queried. A home with a non-cleaned v1 claim returns
`legacy-home-in-use` until restored or cleaned; only a provably fully cleaned home may remain
absent. Inability to read history/snapshot or exhaust a removed home returns
`legacy-writer-source-unavailable`. The same comparison runs before accepting a registry
removal. Changing the canonical origin for an existing `HOME` is exactly removal of the old
`(HOME, origin)` pair plus addition of the new pair. The adapter must exhaust the old origin
and prove zero non-cleaned v1 claims; querying only the replacement origin cannot authorize
the change.

A v1 claim is potentially active from its first claim fact until an authoritative
`task-cleaned` fact for the same claim; a completed, abandoned, or submitted but non-cleaned
task remains potentially active. Reducing its authoritative history, `task-submitted` selects
that PR until a later `task-active` invalidates the submission; later verified, completed, or
abandoned facts retain the current submission source until cleanup. The reduced source chooses
one procedure:

1. With no current submission, the kernel fetches the recorded task branch from the
   canonical workspace origin, pins its advertised OID, and reads
   `<OID>:task/index.md`. That branch tip is `source_revision` and `pr_head_revision` is null.
2. With one current submitted PR number, the trusted hosting adapter validates that PR
   against home, branch, issue, and claim, obtains its exact current immutable head OID, and
   traverses the fetched head's first-parent chain newest to oldest. The first tree containing
   one canonical `task/index.md` whose claim, issue, home, parent, and branch equal lifecycle
   identity and whose repo entries parse canonically is the index snapshot. Its commit OID is
   `source_revision`; the PR head OID is `pr_head_revision`. Role rows are projected from that
   snapshot, not from the PR head tree. First-parent order is total, so the first match is the
   newest unique snapshot.

The adapter must prove a complete, unique lifecycle-to-PR mapping and the entire traversed
first-parent ancestry. No matching snapshot, multiple eligible PRs or identities, missing
ancestry objects, a noncanonical index, or a PR/head mismatch is
`legacy-writer-source-unavailable`. Branch deletion after submission does not hide the claim:
the PR head and reachable index snapshot remain authoritative. Local worktrees and cached
status are never source facts.

Each entry produces this exact pseudo-claim field set: `source: "legacy-v1"`, `claim_id`,
`operation_id: null`, `task_claim_id`, `owner`, `branch`,
`context_policy_set_digest: null`, `source_revision` (branch tip or index-snapshot OID),
`pr_head_revision` (submitted PR head or null), and `lifecycle_digest`. Each authoritative
marker first hashes its complete exact comment bytes as
`sha256:<64-lowercase-hex>`; those digests are sorted lexicographically and serialized as:

```text
workbench-legacy-lifecycle-set/v1
fact<TAB>MARKER_SHA256
```

SHA-256 over those LF-terminated bytes is `lifecycle_digest`. Its claim ID is
`legacy-v1-<64-lowercase-hex>`, where the hex is SHA-256 over these exact LF-terminated rows:

```text
workbench-legacy-writer-identity/v1
task_claim_id<TAB>TASK_CLAIM_ID
owner<TAB>OWNER
branch<TAB>BRANCH
```

An adapter must prove a complete lifecycle inventory, branch/PR identity, task metadata parse,
ancestry, and role inventory. Missing, unreadable, ambiguous, or corrupt input returns
`legacy-writer-source-unavailable` at exit `1`; the kernel must not assume an empty legacy
set. A pre-submission task branch deleted before its authoritative `task-cleaned` fact is
unavailable and fail-closed, not an absent writer; a submitted task continues through its PR
source procedure. A later authoritative v1 `task-cleaned` fact removes the pseudo-claim
dynamically. V1
engines never need to write a v2 ledger row. Bootstrap/migration may seed or cache projections
for performance, but every v2 decision always joins and revalidates the authoritative sources.

### Enforced writer claim

The named mutation point is repository attachment, before creating a nested branch/worktree
or writing the `role: work` repo record:

```text
workbench task add-repo NAME [--ref BASE] [--role work|reference] \
  [--action-instance-id ID] [--authorization-file FILE] --format json
```

`role: reference` never claims a writer. `role: work` uses one append-only ledger on the
fixed ref `refs/heads/workbench-coordination/writer-claims` at the pinned canonical workspace
origin. V2 start/resume never calls this operation implicitly; repository attachment is always
an explicit `add-repo`. The ref tree contains exactly `writer-claims.tsv` with this
LF-terminated schema:

```text
workbench-writer-claims/v1
claim<TAB>OPERATION_ID<TAB>CLAIM_ID<TAB>TASK_CLAIM_ID<TAB>OWNER<TAB>BRANCH<TAB>EXPECTED_PATH<TAB>CODEBASE_ORIGIN_URL<TAB>CONTEXT_POLICY_SET_DIGEST<TAB>ACTION_INSTANCE_ID_OR_null<TAB>POLICY_MANIFEST_DIGEST_OR_null<TAB>INTENT_DIGEST_OR_null<TAB>AUTHORIZATION_REF_OR_null<TAB>active|released
effect-owner<TAB>EVENT_ID<TAB>OPERATION_ID<TAB>CLAIM_ID<TAB>DEVICE_ID<TAB>CLONE_ID<TAB>acquired|released
```

Rows form one append-only set. Canonical serialization groups every `claim` row first, sorted
by owner, task claim, operation ID, claim ID, then state (`active` before `released`), followed
by every `effect-owner` row sorted by operation ID, claim ID, then event ID. An operation/claim
pair has exactly one active claim row and at most one later released row; release repeats every
other field. `EXPECTED_PATH` is the
normalized workspace-relative `task/codebases/<NAME>` path, and `CODEBASE_ORIGIN_URL` is the
canonical repository origin. Action, manifest, and intent fields are all null only when the
joined writer set had no conflict at publication. Authorization is also null then and may
remain null for a conflict allowed by standing policy. These fields preserve the claim-time
binding; later re-resolution may replace the final task-local consumption binding without
rewriting this append-only row.
A claim is current only when its active row has no release. Rows are never removed or
rewritten. The canonical file is reserialized from the union after each append. The row
carries enough task, path, branch, origin, context, and claim-time authorization identity to
reconstruct lost local bookkeeping and re-resolve current policy. A malformed file or
non-fast-forward history outside this protocol is `writer-lock-unavailable`.

Effect-owner event IDs are nonempty printable ASCII, unique within an operation/claim, and
lexicographically monotonic in that sequence's creation order; a retry reuses its prepared ID.
Reducing each operation/claim sequence in event-ID order starts with no owner: `acquired`
is valid only while its claim is active and no owner exists; `released` must name the exact
current device/clone and clears it. A claim `released` row is valid only after current effect
owner is null, and no later acquisition is valid. Any other sequence is malformed. `device_id` is a stable trusted-platform device
identifier; `clone_id` is a UUID stored in the workspace common Git directory outside every
task branch. Acquisition and release use the same parent-OID CAS loop as claims.

The fixed ref is infrastructure, never a task branch; task branch discovery and cleanup must
exclude it by exact ref name.

Before remote mutation, the kernel atomically persists this exact task-local object in tracked
disposable bookkeeping:

```json
{
  "contract_version": "workbench-writer-operation/v1",
  "operation_id": "wop_01J00000000000000000000000",
  "claim_id": "wc_01J00000000000000000000000",
  "task_claim_id": "task__example__42-20260711T030000Z-1234",
  "owner": "shared-api",
  "branch": "task/42-example",
  "expected_path": "task/codebases/shared-api",
  "codebase_origin_url": "https://github.com/example/shared-api.git",
  "context_policy_set_digest": "sha256:6666666666666666666666666666666666666666666666666666666666666666",
  "device_id": "device:trusted-platform/macbook-01",
  "clone_id": "123e4567-e89b-12d3-a456-426614174000",
  "action_instance_id": "act_01J00000000000000000000000",
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
        "decision": "allow"
      }
    ]
  },
  "authorization_ref": "conversation:message/msg-123",
  "effect_owner_state": "none",
  "worktree_ownership": "none",
  "repo_record_ownership": "none",
  "worktree_set_digest": null,
  "compensation_target": null,
  "compensation_reason": null,
  "compensation_next_step": null,
  "coordination_ref": "refs/heads/workbench-coordination/writer-claims",
  "coordination_oid": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "stage": "prepared"
}
```

Those fields and order are exact. `coordination_oid`, `action_instance_id`, `intent_digest`,
`policy_manifest`, and `authorization_ref` may be null. Action/intent/manifest are all null or
all non-null; authorization may be null under standing allow. The manifest
and intent are the exact `workbench-policy-manifest/v1` object and
`workbench-action-intent/v1` digest bound to the action. Effect-owner state is
`none`, `acquired`, or `released`. Ownership is exactly
`none`, `created`, or `adopted`; `created`/`adopted` is valid only with the matching proof
below. `worktree_set_digest` is null until create intent. Compensation target is null,
`reserved`, or `released`; reason is null, `ask`, `deny`, `authorization-deny`, `handoff`,
`creation-failure`, or `cleanup`; next step is null, `record`, `worktree`, `effect-owner`,
`claim`, or `finish`. Stable operation and claim IDs are reused by every retry.
`device_id` and `clone_id` identify the clone bound to this operation. With zero effect-owner
events ever, they may be rebound once only by the exact reconstruction exception below. From
the first owner event onward they are immutable to automatic recovery; only the explicit
source-led handoff protocol may transfer them. `effect_owner_state: "acquired"` must match that
exact remote owner.

Stage is exactly `prepared`, `authorization-pending`, `cancelled`, `remote-claimed`,
`effect-owner-acquired`, `worktree-create-pending`, `worktree-ready`,
`record-create-pending`, `record-ready`, `compensation-pending`, `handoff-ready`, `consumed`,
`release-pending`, or `released`. The object is excluded from task-content and outcome digests.
Every stage/compensation cursor is written by atomic replace before its CAS or local effect.

Every kernel-created worktree writes an untracked per-worktree Git-dir ownership marker with
exact fields `contract_version: "workbench-writer-worktree-owner/v1"`, `operation_id`,
`claim_id`, `task_claim_id`, `expected_path`, `branch`, and `codebase_origin_url`. The marker
is outside the checked-out tree. A worktree is operation-owned only when marker, remote row,
path, branch, common Git directory, and origin all match. An exact matching marker from a
prior attempt is `adopted`; absence/mismatch is external or ambiguous and is never removed.
A repo record is operation-owned only when its content writer row carries the same operation,
claim, task, owner, branch, path, and origin; an exact prior row may be adopted.

Before `git worktree add`, the current effect owner serializes the complete porcelain-observed
worktree set as sorted LF rows and stores its digest with `worktree-create-pending`:

```text
workbench-worktree-set/v1
worktree<TAB>ABSOLUTE_PATH<TAB>BRANCH_OR_null<TAB>COMMON_GIT_DIR<TAB>CANONICAL_ORIGIN_URL
```

The snapshot must prove expected path and branch absent. After a crash between add and marker,
only that same current device/clone may adopt one exact path/branch/common-dir/origin created
from the absent snapshot and write the marker. A different effect owner never assumes the
snapshot still proves absence and never adopts or removes that worktree.

Public operation inspection and no-effect cancellation are:

```text
workbench task writer-operation show --id ID --format json
workbench task writer-operation cancel --id ID --format json
workbench task writer-operation handoff --id ID --format json
```

`show` returns the strict operation with `changed: false`. `cancel` is valid only for
`prepared` or `authorization-pending` with no remote claim, effect owner, worktree, repo row,
or content writer row; it atomically writes terminal `cancelled`. Abandon cleanup performs the
same no-effect cancellation without requiring a remote row. Other cancellation attempts are
`writer-recovery-blocked`.

The claim algorithm is exact:

1. Reconcile any local operation and matching remote rows before minting an ID. Validate the
   prospective context set: an unsealed null context performs the canonical lazy empty seal;
   an unsealed non-null context blocks. Fetch the fixed ref and record its OID or null, parse
   the ledger, and join the current authoritative legacy-v1 projection.
2. Mint or reuse stable operation/claim IDs and derive `workbench-writer-conflict/v1` from the
   prospective row plus every current v2/legacy claim for the owner. A conflict resolves
   `task.concurrent-write` over all available sealed v2 context sets. A conflict containing
   `legacy-v1` always requires an explicit matching action-instance authorization even when
   every present policy says `allow`, because v1 supplies no sealed owner policy. With no
   conflict, action, manifest, and intent fields are null.
3. Persist `prepared`. Revalidate the exact action binding before remote mutation. Unresolved
   `ask` persists `authorization-pending`, returns exit `3`, and creates no remote/local/content
   effect; retry with the exact authorization revalidates and may continue. Policy or explicit
   authorization deny persists terminal `cancelled`, returns exit `4`, and likewise creates no
   effect. A no-conflict or authorized allow continues.
4. Refetch both ledger and legacy projection, recompute binding, and persist any replacement
   before creating a commit whose sole parent is the observed ledger OID (or no parent for
   initial creation) and whose tree adds the exact active claim row. Push normally or with exact
   `--force-with-lease=<ref>:<observed-oid>` compare-and-swap. Initial creation compares
   against an absent ref. CAS failure refetches and restarts from step 1; changed conflict or
   policy binding supersedes the old action and authorization before retry.
5. After push success, refetch the remote ref and verify the exact claim, persist
   `remote-claimed`, then immediately re-fetch the closed home set, joined writers, all policy
   sources, authority, and exact writer-request intent. Persist any replacement
   action/manifest/intent before continuing.
6. Before any worktree or record effect, CAS-acquire the effect owner for this operation/claim
   and persist `effect-owner-acquired`. A current different device/clone blocks. Cross-device
   automatic reconstruction/rebind is permitted only under the zero-history/zero-effect
   exception below; after acquisition, another clone needs explicit source-side handoff.
7. Immediately before each worktree create/adopt, repeat full revalidation and persist any
   replacement binding. Capture the absent worktree-set digest, persist
   `worktree-create-pending`, then create or marker-proven adopt. Verify and persist
   `worktree-ready` plus ownership.
8. Immediately before each repo-record create/adopt, repeat full revalidation and persist any
   replacement binding. Persist `record-create-pending`, create/adopt only the exact
   operation-owned `role: work` row, verify remote claim/worktree/record, then persist
   `record-ready` plus ownership. Its applied provenance columns remain null until the final
   gate; `record-ready` with a null tuple is a recoverable writer prefix, not an applied
   concurrent-write primary.
9. After the record exists and immediately before normal consumption, repeat full revalidation
   once more. Persist any replacement action/manifest/intent before obtaining newly required
   authorization. Atomically write and refetch the task-content writer row with the complete
   applied provenance tuple, then let the common reducer mark the private action and operation
   `consumed`. A crash after the row but before either status write recovers from that row
   without current pre-state/policy derivation. No-conflict operations have null provenance,
   skip action consumption, and still reach `consumed`.

The remote commit OID is the serialization token. It is not a local-write fencing token, and
no expiry or process-local lease grants authority. Before an active row is published, policy
`ask` or `deny` publishes no claim. A changed legacy projection or ledger row supersedes the
binding just like changed policy.

At each post-publication gate, unresolved `ask` chooses compensation target `reserved`; policy
or authorization deny chooses target `released`. Before deleting anything the current effect
owner persists `compensation-pending` with exact reason and next step. Reverse steps are
`record -> worktree -> effect-owner -> claim -> finish`. Each step is idempotent: verify the
current cursor, remove/release only the exact owned effect, verify the result, then atomically
advance `compensation_next_step`. A crash resumes that exact prefix instead of being treated as
a generic mismatch.

For target `reserved`, `claim` is skipped and `finish` clears compensation fields and returns
to `remote-claimed` with the active claim as reservation, exit `3`. For target `released`,
after record/worktree absence and effect-owner release are verified, the operation atomically
persists stage `release-pending` with cursor `claim`. Only that stage/cursor may CAS-append the
claim release. It refetch-verifies the release, advances the cursor to `finish`, then persists
`released`, exit `4`. A `compensation-pending` operation never performs the claim CAS directly.
When no effect owner or local effect exists, ask remains `remote-claimed`; deny may enter
`release-pending` and release the claim directly. Terminal `cancelled` is used only before
remote publication.

| Revalidation result | Exact local transition | Remote claim | Exit |
|---|---|---|---|
| `allow`, same binding | Continue next effect | active | `0` after consume |
| `ask`, no local effect | stay `remote-claimed` | active reservation | `3` |
| `ask`, owned local effects | `compensation-pending(reserved)` prefix -> `remote-claimed` | active reservation | `3` |
| policy or authorization `deny` | `compensation-pending(released)` -> verify prior steps -> `release-pending(next=claim)` -> claim CAS -> verified `released` | released | `4` |
| compensation/ownership ambiguity | keep exact compensation cursor and emit `writer-recovery-blocked` | active | `1` |

Authority, integrity, ownership, or ambiguity failure during revalidation or compensation
keeps the active remote claim and exact cursor, returns `writer-recovery-blocked`, and never
releases around a possible orphan. An external or unmarked worktree is never operation-owned
and never removed.

Retry and cross-device adoption are fail-closed. If the new clone has no authoritative local
journal, exactly one active remote row matches current task claim/owner/branch, no effect-owner
event has ever existed, and exhaustive inspection proves no local worktree, repo record, or
task-content writer effect, the kernel may reconstruct. It atomically writes/rebinds the strict
operation with the new device/clone **before** owner acquisition, re-resolves current
authority/policy, and continues. Any existing owner history or possible effect forbids this
exception; it does not abandon or release the row merely because bookkeeping was not pushed.
Multiple
matches are `writer-recovery-ambiguous`. An exact generated worktree or exact repo record is
adopted only by its current effect owner. A current owner on another device/clone, wrong
path/branch/origin, ambiguous checkout, external worktree, mismatched record, or possible orphan
returns `writer-recovery-blocked` and leaves the remote claim active.

A recoverable creation failure uses `compensation-pending` target `released`; it never jumps
directly to claim release or performs claim CAS before `release-pending/claim`. A crash after
the repo record but before consumption resumes from the record cursor, revalidates, and either
consumes or compensates. Remote failure leaves the active row/cursor visible and returns
`writer-lock-unavailable`.

`handoff` is source-led and valid only for a reconciled `consumed` operation whose executing
clone is current effect owner. It persists `compensation_target: "reserved"`, reason
`handoff`, and cursor `worktree`; leaves the exact content repo row; removes and verifies the
owned local worktree; advances to `effect-owner`; CAS-releases it; then persists
`handoff-ready` with cursor `finish` and claim active. Another device may explicitly acquire
effect owner and rematerialize the worktree, clear handoff fields, and return to `consumed`;
v1 has no forced takeover. If the source owner is unavailable, the claim stays active and
recovery blocks.

Cleanup may release a claim only when its executing clone is current effect owner and removes
then releases those effects, or when the ledger proves effect owner already released and the
operation is `handoff-ready`. Device B cannot release while device A is current. The external
cleanup journal records every effect-owner acquisition/release event used during cleanup.

The action target is `workbench:codebase/<owner>`. Its revision is the canonical
`workbench-writer-conflict/v1` digest below, computed from joined current rows plus the
prospective claim and the authoritative legacy projection. A changed writer set or policy
manifest supersedes the instance and re-resolves. `allow` is consumed only after remote claim,
worktree, and repo-record verification all succeed.

Success returns:

```json
{
  "contract_version": "workbench-writer-claim/v1",
  "task_contract": "workbench-task/v2",
  "owner": "shared-api",
  "claim_id": "wc_01J00000000000000000000000",
  "operation_id": "wop_01J00000000000000000000000",
  "task_claim_id": "task__example__42-20260711T030000Z-1234",
  "role": "work",
  "conflicts": [
    {
      "source": "legacy-v1",
      "claim_id": "legacy-v1-7777777777777777777777777777777777777777777777777777777777777777",
      "task_claim_id": "task__example__41-20260710T030000Z-1234",
      "owner": "shared-api",
      "branch": "task/41-a",
      "context_policy_set_digest": null
    }
  ],
  "changed": true,
  "coordination_ref": "refs/heads/workbench-coordination/writer-claims",
  "coordination_revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "action_instance_id": "act_01J00000000000000000000000",
  "intent_digest": "sha256:7777777777777777777777777777777777777777777777777777777777777777",
  "policy_manifest_digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
  "authorization_ref": "conversation:message/msg-123",
  "worktree_ownership": "created",
  "repo_record_ownership": "created",
  "operation_stage": "consumed",
  "blockers": []
}
```

An unsealed non-null participant set returns `policy-context-unsealed` at exit `1`; an
unsealed null context first performs the canonical lazy empty seal. Remote authority, ledger,
legacy projection, CAS-reconciliation, or write-readiness failure exits `1`. Policy results
use standard `0/3/4` exits except that a legacy conflict cannot use standing allow. Repeating
an existing consumed operation with its exact remote claim, worktree, and repo record is
idempotent.

`workbench doctor --format json` checks the pinned origin identity, protected default-ref
identity/readability, strict descriptor and coordination-ledger parse, authoritative legacy
inventory readability, and ref-specific push permission/rules through a trusted hosting
adapter. It never pushes an OID, creates a temporary ref, or performs another mutation.
When the adapter cannot prove both create/update permission and applicable branch/ref rules,
permission is `unknown`, readiness is false, and doctor exits `1`. Actual writer CAS remains
the final proof even after a positive diagnostic.

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
    "descriptor_digest": "sha256:abababababababababababababababababababababababababababababababab",
    "ref": "refs/heads/workbench-coordination/writer-claims",
    "revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "readable": true,
    "legacy_inventory_readable": true,
    "push_permission": "allowed",
    "permission_source": "github:repository/example/workbench",
    "push_ready": true,
    "blocker": null
  }
}
```

`push_permission` is exactly `allowed`, `denied`, or `unknown`; only `allowed` can set
`push_ready: true`. Any failed field sets `ready: false`, uses `unknown` when permission
cannot be inspected, leaves other unavailable values null, and sets blocker
`{"code":"writer-lock-unavailable","ref":"refs/heads/workbench-coordination/writer-claims"}`.
Doctor never mutates the coordination ref.

## Terminal content freeze

After `task-completed` or `task-abandoned`, revision-affecting content is immutable. The
kernel rejects refs changes, context-policy registration/seal, deliverable changes or
acceptance, required-check changes, evidence recording, harvest changes, and new writer
claims with blocker `terminal-content-frozen` before any policy resolution.

Existing writer-operation and cleanup reconciliation remains permitted bookkeeping. After
abandonment it may inspect, compensate, and release an existing claim only through the
documented cleanup path; no new claim, worktree create/adopt, or repo-record create/adopt is
allowed outside cleanup. Completion cannot enter terminal freeze until writer reconciliation
is already satisfied.

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
  [--owner-context-ref REF --acceptance-authority-ref REF] \
  [--required true|false] [--external-ref REF] [--revision REV] \
  --format json
```

Kernel-owned kinds `codebase-pr` and `workbench-increment` reject both owner-binding flags and
store `owner_context_ref: null` and `acceptance_authority_ref: null`; their registered
repository owner remains authoritative. Every namespaced pack kind requires both flags. At
declaration, the task context-policy set must already be sealed. `owner_context_ref` must
resolve exactly one participant, `acceptance_authority_ref` must independently resolve exactly
one participant, and both lookups must identify the same row; zero, multiple, or different
matches return `acceptance-authority-mismatch`. The pack adapter additionally validates
owner/kind semantics. The two values are immutable identity, not acceptance-time caller input.

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
intent digest, policy-manifest digest, and authorization ref. Repeating the exact resulting
governed record is idempotent.

Changing a revision makes prior evidence stale. From `accepted`, `waived`, or `rejected`, a
revision change must explicitly select `declared` or `submitted` in the same non-governed
call; that reset clears `acceptance_ref` and all governance fields but never deletes old
append-only acceptance receipts. Setting state to `declared` or `submitted` without a
revision change performs the same reset. Restoring `required: true` is allowed only in
`declared` or `submitted` and clears a prior weaken governance record. A new valid acceptance
also clears governance fields and sets a new acceptance ref. Other ordinary field changes do
not silently clear an active weaken reason. Reset, revision, state, required, and external-ref
changes never alter owner bindings. A different pack context or acceptance authority requires
a new deliverable ID.

### Accept

```text
workbench task deliverable accept --id ID \
  [--owner-acceptance-file FILE] \
  [--action-instance-id ID] [--authorization-file FILE] --format json
workbench task deliverable acceptance list --format json
```

Kernel-owned kinds are exactly `codebase-pr` and `workbench-increment`. They require a
registered GitHub owner, a canonical HTTPS pull-request `external_ref`, and a non-null
revision. The command branches on this stored kind before any action/request derivation or
policy resolution and rejects `--owner-acceptance-file`, `--action-instance-id`, and
`--authorization-file` at exit `2`. Kernel acceptance is deterministic but ungoverned. The
kernel queries the referenced PR and creates a
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

`authority_digest` in the acceptance receipt is SHA-256 over that exact minified, key-ordered
observation JSON plus LF. The time-independent probe subject is a second strict object:

```json
{
  "contract_version": "workbench-probe/github-pr-subject/v1",
  "repository": "example/web-app",
  "pull_request": 12,
  "external_ref": "https://github.com/example/web-app/pull/12",
  "state": "merged",
  "head_revision": "0123456789abcdef",
  "merge_revision": "fedcba9876543210"
}
```

Its listed-order minified JSON plus LF yields the stable `subject_authority_digest` stored in
the kernel receipt; it is not an action intent. The kernel mints `acceptance_id` once before
its first probe and persists it in the private ungoverned acceptance-attempt record; every
retry reuses that ID. A changed immutable subject replaces only that ungoverned attempt, while
a fresh observation of the same subject does not. The receipt remains valid only while
repository, PR number, external ref, merged state, head revision, and merge revision match the
deliverable and stored subject.

Kernel acceptance appends/refetch-verifies its receipt before updating the deliverable pointer,
but it never enters the governed applied-effect reducer. Its receipt has
`action_instance_id: null`, `intent_digest: null`, `policy_manifest_digest: null`, and
`authorization_ref: null`; the stable subject/observation prove owner acceptance, not policy
authorization. Retry repairs a missing pointer from the exact ungoverned receipt.

A namespaced pack-owned kind rejects kernel probing and requires
`--owner-acceptance-file`. That strict `workbench-owner-acceptance/v1` input repeats
deliverable ID, owner, kind, immutable owner context, immutable acceptance authority, and
revision. Acceptance is governed action `task.deliverable.accept`; required policies include
the bound owner context, and the action/authorization binding rules still apply. A pack cannot
accept an unversioned deliverable or one owned by a different authority.

The file is an owner assertion, not authorization by itself. Its two owner bindings must equal
the stored deliverable values. The kernel resolves only the sealed participant matching both
stored values; no acceptance flag or assertion can select a different participant. Assertion
`actor` and `accepted_at` equal action authorization `actor` and `authorized_at`, and the
trusted adapter authenticates that actor against the matching participant receipt's
`authority_identity`. Pack-owned acceptance therefore always requires explicit
`workbench-authorization/v1`; standing `allow` alone cannot accept it.

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
  "owner_context_ref": "toolbox:product/acme-api",
  "acceptance_authority_ref": "toolbox:policy/acme-api",
  "revision": "sha256:7777777777777777777777777777777777777777777777777777777777777777",
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
    "owner_context_ref": null,
    "acceptance_authority_ref": null,
    "required": true,
    "external_ref": "https://github.com/example/web-app/pull/12",
    "revision": "0123456789abcdef",
    "state": "submitted",
    "acceptance_ref": null,
    "governance_action": null,
    "reason_code": null,
    "reason_ref": null,
    "governance_action_instance_id": null,
    "governance_intent_digest": null,
    "governance_policy_manifest_digest": null,
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
    "owner_context_ref": "toolbox:product/acme-api",
    "acceptance_authority_ref": "toolbox:policy/acme-api",
    "required": true,
    "external_ref": null,
    "revision": null,
    "state": "waived",
    "acceptance_ref": null,
    "governance_action": "task.deliverable.waive",
    "reason_code": "owner-deferred",
    "reason_ref": "conversation:message/msg-456",
    "governance_action_instance_id": "act_01J00000000000000000000001",
    "governance_intent_digest": "sha256:7777777777777777777777777777777777777777777777777777777777777777",
    "governance_policy_manifest_digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
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

The exact deliverable field order is `deliverable_id`, `owner`, `kind`, `owner_context_ref`,
`acceptance_authority_ref`, `required`, `external_ref`, `revision`, `state`, `acceptance_ref`,
`governance_action`, `reason_code`, `reason_ref`, `governance_action_instance_id`,
`governance_intent_digest`, `governance_policy_manifest_digest`, and `authorization_ref`. The
state meanings are normative.
Repeating `declare` with an identical record is idempotent and reports `changed: false`; the
same ID with different data fails.

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
    "owner_context_ref": null,
    "acceptance_authority_ref": null,
    "required": true,
    "external_ref": "https://github.com/example/web-app/pull/12",
    "revision": "0123456789abcdef",
    "state": "accepted",
    "acceptance_ref": "workbench:acceptance/acc-web-pr-1",
    "governance_action": null,
    "reason_code": null,
    "reason_ref": null,
    "governance_action_instance_id": null,
    "governance_intent_digest": null,
    "governance_policy_manifest_digest": null,
    "authorization_ref": null
  },
  "acceptance": {
    "contract_version": "workbench-acceptance/v1",
    "acceptance_id": "acc-web-pr-1",
    "deliverable_id": "web-pr",
    "owner": "web-app",
    "kind": "codebase-pr",
    "owner_context_ref": null,
    "acceptance_authority_ref": null,
    "revision": "0123456789abcdef",
    "authority_type": "kernel-probe",
    "authority_contract": "workbench-probe/github-pr/v1",
    "authority_ref": "https://github.com/example/web-app/pull/12",
    "authority_digest": "sha256:5555555555555555555555555555555555555555555555555555555555555555",
    "subject_authority_digest": "sha256:6666666666666666666666666666666666666666666666666666666666666666",
    "actor": null,
    "action_instance_id": null,
    "intent_digest": null,
    "policy_manifest_digest": null,
    "authorization_ref": null,
    "accepted_at": "2026-07-11T03:20:00Z"
  }
}
```

For a pack-owned kind, the receipt embedded in the same envelope instead has this provenance:

```json
{
  "contract_version": "workbench-acceptance/v1",
  "acceptance_id": "acc-artifact-1",
  "deliverable_id": "release-artifact",
  "owner": "release-pack",
  "kind": "toolbox:artifact/release",
  "owner_context_ref": "toolbox:product/acme-api",
  "acceptance_authority_ref": "toolbox:policy/acme-api",
  "revision": "sha256:7777777777777777777777777777777777777777777777777777777777777777",
  "authority_type": "owner-authorization",
  "authority_contract": "workbench-owner-acceptance/v1",
  "authority_ref": "toolbox:policy/acme-api",
  "authority_digest": "sha256:8888888888888888888888888888888888888888888888888888888888888888",
  "subject_authority_digest": "sha256:8888888888888888888888888888888888888888888888888888888888888888",
  "actor": "release-owner@example.com",
  "action_instance_id": "act_01J00000000000000000000002",
  "intent_digest": "sha256:9999999999999999999999999999999999999999999999999999999999999999",
  "policy_manifest_digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
  "authorization_ref": "conversation:message/msg-accept",
  "accepted_at": "2026-07-11T03:20:00Z"
}
```

The owner-acceptance input has exact fields `contract_version`, `acceptance_id`,
`deliverable_id`, `owner`, `kind`, `owner_context_ref`, `acceptance_authority_ref`, `revision`,
`actor`, and `accepted_at`.
Its receipt uses `authority_type: "owner-authorization"`,
`authority_contract: "workbench-owner-acceptance/v1"`, and SHA-256 of the strict input as both
`authority_digest` and `subject_authority_digest`. That digest serializes the input in
the listed field order as minified UTF-8 JSON plus LF. The receipt copies both immutable owner
bindings; its `authority_ref` is derived from `acceptance_authority_ref`, never from a caller
choice. `actor` is the authorization actor and `accepted_at` is the authorization timestamp;
the receipt also stores the pending action's exact intent, policy-manifest digest, and
authorization ref before the deliverable pointer is written.
The exact `workbench-acceptance/v1` fields are `contract_version`, `acceptance_id`,
`deliverable_id`, `owner`, `kind`, `owner_context_ref`, `acceptance_authority_ref`, `revision`,
`authority_type`, `authority_contract`, `authority_ref`, `authority_digest`,
`subject_authority_digest`, `actor`, `action_instance_id`, `intent_digest`,
`policy_manifest_digest`, `authorization_ref`, and `accepted_at`. Pack owner receipts require
non-null action/intent/policy/authorization provenance. Kernel probes use null owner bindings,
`actor: null`, and null action/intent/policy/authorization provenance.
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
  --id ID --reason-code CODE [--reason-ref REF] \
  [--action-instance-id ID] [--authorization-file FILE] --format json
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
    "reason_code": null,
    "reason_ref": null,
    "action_instance_id": null,
    "intent_digest": null,
    "policy_manifest_digest": null,
    "authorization_ref": null
  }
}
```

List output replaces `changed` and `required_check` with `required_checks: []`. A waived
record has `state: "waived"`, the exact reason code/reference, consumed action instance ID,
intent digest, policy-manifest digest, and authorization source reference that permitted it.
The reason code is a required stable machine identifier; `reason_ref` is optional prose provenance.
The exact required-check field order is `check_id`, `owner`, `deliverable_id`, `subject_ref`,
`state`, `reason_code`, `reason_ref`, `action_instance_id`, `intent_digest`,
`policy_manifest_digest`, and `authorization_ref`.
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

The authoritative locator is `.workbench/authority.json` on the protected workspace default
ref. It is created by the accepted bootstrap or migration pull request and has these exact
fields and order:

```json
{
  "contract_version": "workbench-workspace-authority/v1",
  "authority_identity": "github:example/workbench",
  "origin_url": "https://github.com/example/workbench.git",
  "default_ref": "refs/heads/main",
  "workspace_home": "workbench",
  "hosting_adapter": "github",
  "hosting_ref": "github:repository/example/workbench"
}
```

`hosting_adapter` and `hosting_ref` are nullable only as a pair; when present they are
nonempty printable ASCII and identify a trusted adapter plus its canonical repository
handle. `workspace_home` follows the canonical home grammar and is immutable with authority
identity, origin, and default ref. A null pair is valid only when the trusted platform can
infer the same adapter from the authenticated origin; if it cannot inspect ref
permission/rules, doctor reports unknown and not ready. The descriptor digest is SHA-256 over
the exact listed-order minified UTF-8 JSON plus LF. GitHub origins are canonical HTTPS with a
`.git` suffix. Descriptor identity, origin, and
default ref are immutable for a v2 workspace; changing any of them requires a separately
approved migration, and an active task treats a different descriptor digest as
`policy-authority-mismatch`.

The initial bootstrap trust root is the canonical origin/default-ref pair explicitly approved
by the user or returned by an authenticated hosting-repository selection. Bootstrap uses that
one-time root only to fetch and verify the accepted bootstrap/migration commit; the commit
must add `.workbench/authority.json`, `.workbench/policy.conf`, profile, and v2 marker together.
The descriptor must self-identify the same origin/ref, and the hosting adapter must establish
repository identity and protection from direct task-actor writes. A task branch, issue
comment, local prose file, or unverified remote name is never a trust root. Optional issue
audit comments may repeat the descriptor digest, but are non-authoritative and cannot locate
or override it.

Every v2 task claim stores `workspace_authority_descriptor_digest` in task identity metadata
and its `task-claimed` lifecycle observation. This is audit binding, not a cached locator:
`workbench doctor`, every resolution, and every pre-consumption check still re-observe the
protected default. Missing/unreadable descriptors, unavailable authentication/protection, or
an unresolvable canonical origin block at exit `1` with `policy-authority-unavailable`;
different descriptor bytes, remote identity, or default symbolic ref block with
`policy-authority-mismatch`.

Before every resolution and immediately before consumption, the kernel runs the equivalent
of `git ls-remote --symref <descriptor-origin-url> HEAD <descriptor-default-ref>`. It requires
`HEAD` to name the descriptor ref and that ref to advertise one exact OID, fetches that OID
without updating a caller branch, revalidates repository identity/protection, and reads both
`<OID>:.workbench/authority.json`, `<OID>:.workbench/policy.conf`, and
`<OID>:codebases.yaml` from the same immutable object. Descriptor digest must equal the
task-claim audit binding; legacy resolution uses the canonical registry from that object.
Remote/authentication/fetch failure returns `policy-authority-unavailable`. A valid authority
revision without the file returns `policy-source-missing`; malformed policy returns
`policy-source-invalid`. The observed OID, source digest, pinned identity/ref, and authority
descriptor digest are bound into the action manifest. Existing tasks therefore see the current
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
  "registration_action_instance_id": "act_01J00000000000000000000000",
  "registration_intent_digest": "sha256:7777777777777777777777777777777777777777777777777777777777777777",
  "registration_policy_manifest_digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
  "registration_authorization_ref": "conversation:message/msg-register",
  "seal_action_instance_id": "act_01J00000000000000000000001",
  "seal_intent_digest": "sha256:8888888888888888888888888888888888888888888888888888888888888888",
  "seal_policy_manifest_digest": "sha256:5555555555555555555555555555555555555555555555555555555555555555",
  "seal_authorization_ref": "conversation:message/msg-seal",
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
`changed: false`; before registration/lazy seal its digest, registration refs, action IDs,
intent/policy-manifest digests, and authorization refs are null with empty participants and null
task policy. Register returns `sealed: false` and persists its applied provenance tuple; seal
returns `sealed: true` and adds the corresponding seal tuple. Lazy null-context seal returns
`sealed: true` with both tuples null. Every governed mutation
derives all context and task sources from the complete sealed set; caller
flags cannot subtract or replace them. `task.concurrent-write` uses the union of sealed sets
from the prospective task and every active v2 writer; legacy-v1 pseudo-claims contribute no
context source and instead activate the mandatory explicit authorization gate.

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
consumption, and also bound with current authority receipts/descriptors in every action
manifest.

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
`AUTHORITY_RECEIPT_DIGEST` is the canonical receipt or workspace authority-descriptor digest.
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

`task.policy-context.register`, pack-owned `task.deliverable.accept`, and
`task.concurrent-write` when any conflict source is `legacy-v1` have a mandatory explicit
authorization gate in addition to the policy lattice. A policy `deny` still returns exit `4`;
otherwise the command returns `ask` at exit `3` until the exact authenticated authorization
is supplied, even when every policy source says `allow`. This requirement is kernel-derived
from action/bound owner/conflict facts and cannot be relaxed by caller input.
Resolving `task.deliverable.accept` against a kernel-owned kind is invalid at exit `2` and
mints no instance; deterministic kernel acceptance never enters the action registry path.

### Canonical action intent and per-action binding

Authorization binds both the observed subject and the exact requested effect. Every governed
action derives this LF-terminated manifest and stores its SHA-256 as `intent_digest`:

```text
workbench-action-intent/v1
action_id<TAB>ACTION_ID
task_claim_id<TAB>TASK_CLAIM_ID
target_ref<TAB>TARGET_REF
subject_revision<TAB>REVISION
payload_contract<TAB>PAYLOAD_CONTRACT
payload_digest<TAB>PAYLOAD_DIGEST
```

`revision` in action and authorization objects is the same `subject_revision`; it continues
to identify the exact pre-effect subject. `payload_digest` is SHA-256 over the exact canonical
payload named by `payload_contract`. Consequently the same target and revision cannot reuse an
approval for a different transition, reason, disposition, assertion, writer request, or
cleanup plan.

| Action | `target_ref` | `revision` subject binding | Exact payload | Required context policy set |
|---|---|---|---|---|
| `task.complete` | `work_ref`, else `workbench:task/<claim_id>` | current `workbench-task-revision/v1` digest | `workbench-task-complete-intent/v1` | complete sealed task context-policy set |
| `task.abandon` | `work_ref`, else `workbench:task/<claim_id>` | current `workbench-task-abandonment-revision/v1` digest | `workbench-task-abandon-intent/v1` including exact reason | complete sealed task context-policy set |
| `task.deliverable.accept` (pack only) | `workbench:deliverable/<deliverable_id>` | pack-owned deliverable-record digest with non-null revision and immutable owner bindings | `workbench-deliverable-accept-intent/v1` | complete sealed task set plus the one participant bound at declaration |
| `task.deliverable.waive` | `workbench:deliverable/<deliverable_id>` | current deliverable-record digest | `workbench-deliverable-transition-intent/v1`, transition `waive` | complete sealed task context-policy set |
| `task.deliverable.reject` | `workbench:deliverable/<deliverable_id>` | current deliverable-record digest | `workbench-deliverable-transition-intent/v1`, transition `reject` | complete sealed task context-policy set |
| `task.deliverable.weaken` | `workbench:deliverable/<deliverable_id>` | current deliverable-record digest | `workbench-deliverable-transition-intent/v1`, transition `weaken` | complete sealed task context-policy set |
| `task.required-check.waive` | `workbench:required-check/<check_id>` | current required-check-record digest | `workbench-required-check-waive-intent/v1` | complete sealed task context-policy set |
| `task.harvest.dispose` | `workbench:harvest/<candidate_id>` | current pending harvest-candidate-record digest | `workbench-harvest-disposition-intent/v1` | complete sealed task context-policy set |
| `task.policy-context.register` | `workbench:task/<claim_id>` | strict registration-input digest | exact `workbench-context-policy-registration/v1` canonical JSON | required workspace plus optional trusted platform; no proposed context/task source |
| `task.policy-context.seal` | `workbench:task/<claim_id>` | registered-set digest | exact `workbench-context-policy-set/v1` canonical manifest | required workspace, optional platform, every proposed participant, and optional proposed task policy |
| `task.concurrent-write` | `workbench:codebase/<owner>` | writer-conflict-set digest including authoritative legacy projections | `workbench-writer-request/v1` | union of available sealed v2 sets; any legacy-v1 row additionally forces explicit authorization |
| `task.cleanup` | `workbench:task/<claim_id>` | immutable terminal outcome revision | `workbench-task-cleanup-intent/v1` including exact removal-plan digest | frozen sealed set recorded by terminal action |

The exact action-specific LF payloads are:

```text
workbench-task-complete-intent/v1
outcome<TAB>completed
completion_snapshot<TAB>TASK_REVISION

workbench-task-abandon-intent/v1
outcome<TAB>abandoned
abandonment_revision<TAB>ABANDONMENT_REVISION
reason_code<TAB>REASON_CODE
reason_ref<TAB>REASON_REF_OR_null

workbench-deliverable-transition-intent/v1
deliverable_id<TAB>DELIVERABLE_ID
record_revision<TAB>DELIVERABLE_RECORD_REVISION
transition<TAB>waive|reject|weaken
from_required<TAB>BOOLEAN
to_required<TAB>BOOLEAN
from_state<TAB>STATE
to_state<TAB>STATE
reason_code<TAB>REASON_CODE
reason_ref<TAB>REASON_REF_OR_null

workbench-deliverable-accept-intent/v1
deliverable_id<TAB>DELIVERABLE_ID
record_revision<TAB>DELIVERABLE_RECORD_REVISION
acceptance_id<TAB>ACCEPTANCE_ID
deliverable_revision<TAB>DELIVERABLE_REVISION
owner_context_ref<TAB>OWNER_CONTEXT_REF
acceptance_authority_ref<TAB>ACCEPTANCE_AUTHORITY_REF
owner_assertion_digest<TAB>OWNER_ASSERTION_DIGEST
actor<TAB>ACTOR
accepted_at<TAB>RFC3339_UTC

workbench-required-check-waive-intent/v1
check_id<TAB>CHECK_ID
record_revision<TAB>REQUIRED_CHECK_RECORD_REVISION
transition<TAB>required-to-waived
reason_code<TAB>REASON_CODE
reason_ref<TAB>REASON_REF_OR_null

workbench-harvest-disposition-intent/v1
candidate_id<TAB>CANDIDATE_ID
record_revision<TAB>PENDING_CANDIDATE_RECORD_REVISION
decision<TAB>absorb|codebase|follow-up|discard
target_ref<TAB>TARGET_REF_OR_null
reason_code<TAB>REASON_CODE
reason_ref<TAB>REASON_REF_OR_null

workbench-writer-request/v1
operation_id<TAB>OPERATION_ID
claim_id<TAB>CLAIM_ID
owner<TAB>OWNER
branch<TAB>BRANCH
expected_path<TAB>EXPECTED_PATH
codebase_origin_url<TAB>CANONICAL_ORIGIN_URL
context_policy_set_digest<TAB>CONTEXT_POLICY_SET_DIGEST
conflict_revision<TAB>WRITER_CONFLICT_REVISION

workbench-task-cleanup-intent/v1
terminal_revision<TAB>TERMINAL_REVISION
removal_plan_digest<TAB>REMOVAL_PLAN_DIGEST
```

For completion, the task revision is the deterministic content-plus-selected-evidence
snapshot already defined by `workbench-task-revision/v1`. Pack acceptance's
`owner_assertion_digest` binds acceptance ID, immutable owner bindings, deliverable revision,
actor, and timestamp. Deterministic kernel PR acceptance is ungoverned and never creates this
intent. Its stable subject and timestamped observation remain acceptance evidence, not policy
payload. Register and seal use their
already-defined strict canonical inputs directly as payloads; concurrent write binds both the
complete conflict pre-state and the exact prospective writer row. Cleanup's removal-plan
manifest is defined under governed cleanup.

A record digest is SHA-256 over a contract line, its exact current row from the task-content
manifest, and final LF. The contract lines are `workbench-deliverable-record/v1`,
`workbench-required-check-record/v1`, and `workbench-harvest-candidate-record/v1` for their
respective rows. A deliverable with `revision: null` therefore binds its full record digest
for waive/reject/weaken; null is never used as the action revision. Acceptance cannot occur
with a null deliverable revision.

The writer-conflict-set digest is SHA-256 over this exact LF-terminated manifest; writer rows
include the prospective v2 claim and every current ledger/legacy claim and are sorted by
source, claim ID, then branch:

```text
workbench-writer-conflict/v1
owner<TAB>OWNER
legacy_home_set<TAB>HOME_SET_DIGEST
writer<TAB>SOURCE<TAB>CLAIM_ID<TAB>OPERATION_ID_OR_null<TAB>TASK_CLAIM_ID<TAB>BRANCH<TAB>CONTEXT_POLICY_SET_DIGEST_OR_null<TAB>SOURCE_REVISION_OR_null<TAB>PR_HEAD_REVISION_OR_null<TAB>LIFECYCLE_DIGEST_OR_null
```

`SOURCE` is `ledger-v2` or `legacy-v1`; the prospective row uses `ledger-v2` so publishing
it does not change its own digest. V2 source/PR-head/lifecycle revisions are null. Legacy rows
have null operation/context digest, the canonical branch-tip or index-snapshot OID as source
revision, the submitted PR head when applicable, and the authoritative lifecycle digest. The
closed home-set digest is always present, even with no
legacy claim. Thus a home registry, v1 branch, or cleanup fact change supersedes a pending
authorization without creating an action/coordination-OID hash cycle.

### Applied-effect reducer

Every governed command runs one common applied-effect reducer **before** deriving a current
request, pre-state revision, context set, or policy decision. The reducer uses the supplied
action instance when present. Without one, it joins the command's stable target identifiers
only to non-consumed instances and provenance not already frozen as consumed; historical
consumed provenance does not shadow a legitimate later first call. It never mints a replacement
while a possible unreconciled applied effect exists.

Every governed post-effect record carries the exact applied provenance tuple, under the
action-specific field names shown in its schema:

```text
workbench-applied-action-provenance/v1
action_instance_id<TAB>ACTION_INSTANCE_ID
intent_digest<TAB>INTENT_DIGEST
policy_manifest_digest<TAB>POLICY_MANIFEST_DIGEST
authorization_ref<TAB>AUTHORIZATION_REF_OR_null
```

The manifest digest must equal the stored action's exact policy manifest. Authorization ref
is the validated authorization's source ref, or null only where standing allow was sufficient.
Actions with a mandatory explicit gate require a non-null matching authorization. The durable
sources and secondary projections are frozen as follows:

| Governed action | Primary durable applied-effect provenance | Secondary projection/postcondition |
|---|---|---|
| pack-only `task.deliverable.accept` | append-only owner-authorization `workbench-acceptance/v1` receipt | deliverable state `accepted` and exact `acceptance_ref` pointer |
| `task.deliverable.waive`, `reject`, `weaken` | governed deliverable row | exact requested state/required transition and reason |
| `task.required-check.waive` | waived required-check row | exact reason and subject retained |
| `task.harvest.dispose` | disposed candidate record | exact decision, target-or-null, and reason |
| `task.policy-context.register` | registered context-set record and registration digest | exact registration ref; unsealed until a valid later seal |
| `task.policy-context.seal` | sealed context-set record | exact registered participant/task-policy set |
| `task.concurrent-write` | task-content writer row plus matching writer operation | exact operation-owned worktree/record and `consumed` operation stage |
| `task.complete`, `task.abandon` | terminal outcome record | matching lifecycle event; abandonment also retains reason/removal-plan digest |
| `task.cleanup` | external `prepared` cleanup journal | exact journal-prefix retirement and final `task-cleaned` projection |

Reduction is exact and ordered:

1. Collect every primary and secondary record for the supplied/stored instance. A secondary
   record without its required primary, more than one candidate primary/composite-primary set,
   duplicate append-only receipt, incompatible or forked prefix, or another action/intent using
   the same instance is `action-effect-unreconciled` at exit `1`.
2. Load the stored strict action request, recompute its intent, and compare action, task,
   target, subject revision, intent digest, policy-manifest digest, and authorization
   provenance. Verify that the primary record's postcondition is exactly the requested payload.
   Missing private request state is unreconciled; the current pre-state is never substituted.
   The sole exception is cleanup after task deletion: its strict external journal contains the
   terminal revision, complete removal plan, intent, policy manifest, and authorization needed
   to reconstruct the request.
3. On one exact primary, reconcile only missing derived pointers, lifecycle observations, and
   private action status. A causally later valid successor, such as a consumed deliverable
   reset/revision or a sealed context set retaining its registration provenance, is never
   reverted to the earlier postcondition. Cleanup may additionally resume only the exact
   externally committed removal-plan prefix. This recovery path does **not** derive current
   pre-state and does not re-resolve current policy because the authorized effect is already
   durable.
4. Atomically mark the private action `consumed` with the digest of its verified primary
   provenance after required projections agree. A recovery that wrote a missing
   projection/status reports the command's normal success with `changed: true`. An instance
   already consumed with that frozen provenance returns `changed: false` without current
   pre-state or policy derivation; later legitimate post-consumption reset does not replay it.
5. A mismatch, duplicate, partial incompatible effect, missing required provenance, or
   intent/action collision never clears a record and never creates a new action or effect.
   Only when no applied provenance exists does the normal pre-state/request/policy path begin.

The canonical blocker is `{"code":"action-effect-unreconciled","ref":"<action_instance_id>"}`;
when no unique instance can be named, `ref` is the governed target ref.

Pack acceptance has a fixed multi-record crash order. After normal owner assertion and
authorization checks, append and refetch-verify the strict acceptance receipt first; that
receipt contains the complete applied provenance tuple and is the recovery journal. Only then
set and refetch the deliverable state/pointer, then commit the reducer's consumed status. A
receipt without its pointer is repaired by the reducer; a pointer without its receipt is
unreconciled.
Any mutation that would reset, replace, or clear a post-effect record must run this reducer
first and cannot erase provenance while its action is not reconciled as consumed.

On the normal path, all record, target, revision, and context derivations are recomputed
immediately before policy consumption. Concurrent-write conflict derivation is additionally
recomputed inside the canonical ledger CAS loop below. Governed deliverable and required-check
commands use the same first-call, pending, retry, and consumption behavior defined below for
completion and abandonment.

### Resolve

Direct resolution uses one strict request file so requested-effect fields are not inferred
from an opaque digest:

```json
{
  "contract_version": "workbench-action-request/v1",
  "action_id": "task.complete",
  "task_claim_id": "task__example__42-20260711T030000Z-1234",
  "target_ref": "toolbox:scenario/SCN-001",
  "revision": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "payload_contract": "workbench-task-complete-intent/v1",
  "payload": "workbench-task-complete-intent/v1\noutcome\tcompleted\ncompletion_snapshot\tsha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
}
```

Those seven fields and order are exact. `payload` is a JSON string containing the exact
canonical payload bytes, including its final LF; registration JSON is likewise carried as its
canonical minified JSON plus LF. The kernel parses the named payload grammar, recomputes its
digest and generic intent, and independently re-derives every state-backed field. A caller
cannot authorize an arbitrary digest or omit a transition/reason field.

```text
workbench policy resolve \
  --request-file FILE --intent-digest DIGEST \
  [--action-instance-id ID] [--authorization-file FILE] \
  --format json|decision
```

Without `--action-instance-id`, the kernel mints and persists a unique action instance.
With an instance ID, the request and all binding arguments are recomputed and must match the
stored instance exactly. For a kernel action, even the first call derives `target_ref`,
`revision`, intent payload, intent digest, and context set from current state; request values
and `--intent-digest` are assertions and a mismatch fails.
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

The exact action-instance field order is `id`, `action_id`, `task_claim_id`, `target_ref`,
`revision`, `intent_digest`, `policy_manifest`, and `status`. `status` is `pending`,
`authorized`, `consumed`, `denied`, or `superseded`.
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
  "intent_digest": "sha256:7777777777777777777777777777777777777777777777777777777777777777",
  "policy_manifest_digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
  "decision": "allow",
  "actor": "human@example.com",
  "authorized_at": "2026-07-11T03:01:00Z",
  "source_ref": "conversation:message/msg-123"
}
```

The exact authorization field order is `contract_version`, `authorization_id`,
`action_instance_id`, `action_id`, `task_claim_id`, `target_ref`, `revision`, `intent_digest`,
`policy_manifest_digest`, `decision`, `actor`, `authorized_at`, and `source_ref`. The decision
is `allow` or `deny`; `ask` is not an authorization. Every binding field must
match the stored action instance, including `intent_digest` and `policy_manifest_digest`.
`authorization_id` is unique within the task and may be attached to only one instance. A
used authorization or an instance with a different action, task claim, target, revision,
intent, or policy manifest is rejected at exit `1`.

When the reducer found no applied provenance and normal execution reaches its final gate, the
command re-derives its required
context set, revalidates its authority receipts, re-observes the descriptor-pinned workspace
default ref/OID, reopens the descriptor and every present source, and recomputes every digest
and decision. It also re-derives the exact action payload and intent digest. A payload change
supersedes the old instance and rejects its authorization even when target and subject
revision are unchanged. It never
trusts a cached decision or a task-branch workspace policy copy. A changed protected
workspace revision or trusted platform receipt supersedes the old instance and
authorization, then resolves a replacement against the new full manifest. New `deny`
returns exit `4`; new `ask` returns exit `3`; new standing `allow` may continue unless the
action has the mandatory owner-authority gate, which needs a new matching authorization.
A sealed context or task-policy byte/receipt mismatch instead returns
`policy-source-tampered` at exit `1` and mints no replacement. Thus neither a newly
restrictive workspace source nor a caller-edited sealed source can be bypassed between
approval and consumption.

The kernel persists the exact strict action request plus action status in tracked, disposable
task state. The storage path is private, but the record survives session handoff when the task
state is committed. Normal execution writes the action-specific primary post-effect record
before marking the private instance consumed. Missing secondary projections are then handled
by the applied-effect reducer; they are not grounds to repeat policy or the primary effect.
Cleanup is the documented exception to private status durability: its externally durable
`prepared` journal is the committed mutation and consumption source because task-local action
storage is about to be deleted. A failed precondition before any primary provenance leaves the instance
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
workspace_authority_descriptor<TAB>DESCRIPTOR_DIGEST
context_ref<TAB>REF_OR_null
work_ref<TAB>REF_OR_null
policy_context_set<TAB>BOOLEAN<TAB>SET_DIGEST_OR_null<TAB>REGISTRATION_REF_OR_null<TAB>REGISTRATION_DIGEST_OR_null<TAB>REGISTRATION_ACTION_INSTANCE_OR_null<TAB>REGISTRATION_INTENT_DIGEST_OR_null<TAB>REGISTRATION_POLICY_MANIFEST_DIGEST_OR_null<TAB>REGISTRATION_AUTHORIZATION_REF_OR_null<TAB>SEAL_ACTION_INSTANCE_OR_null<TAB>SEAL_INTENT_DIGEST_OR_null<TAB>SEAL_POLICY_MANIFEST_DIGEST_OR_null<TAB>SEAL_AUTHORIZATION_REF_OR_null
policy_context<TAB>CONTEXT_REF<TAB>POLICY_REF<TAB>POLICY_DIGEST<TAB>AUTHORITY_IDENTITY<TAB>AUTHORITY_REF<TAB>AUTHORITY_REVISION<TAB>AUTHORITY_RECEIPT_DIGEST
task_policy<TAB>POLICY_REF<TAB>POLICY_DIGEST<TAB>AUTHORITY_IDENTITY<TAB>AUTHORITY_REF<TAB>AUTHORITY_REVISION<TAB>AUTHORITY_RECEIPT_DIGEST
writer_claim<TAB>OPERATION_ID<TAB>CLAIM_ID<TAB>OWNER<TAB>TASK_CLAIM_ID<TAB>BRANCH<TAB>EXPECTED_PATH<TAB>CODEBASE_ORIGIN_URL<TAB>CONTEXT_POLICY_SET_DIGEST<TAB>ACTION_INSTANCE_OR_null<TAB>POLICY_MANIFEST_DIGEST_OR_null<TAB>INTENT_DIGEST_OR_null<TAB>AUTHORIZATION_REF_OR_null
deliverable<TAB>ID<TAB>OWNER<TAB>KIND<TAB>OWNER_CONTEXT_REF_OR_null<TAB>ACCEPTANCE_AUTHORITY_REF_OR_null<TAB>BOOLEAN<TAB>EXTERNAL_REF_OR_null<TAB>REVISION_OR_null<TAB>STATE<TAB>ACCEPTANCE_REF_OR_null<TAB>GOVERNANCE_ACTION_OR_null<TAB>REASON_CODE_OR_null<TAB>REASON_REF_OR_null<TAB>GOVERNANCE_ACTION_INSTANCE_OR_null<TAB>GOVERNANCE_INTENT_DIGEST_OR_null<TAB>GOVERNANCE_POLICY_MANIFEST_DIGEST_OR_null<TAB>AUTHORIZATION_REF_OR_null
acceptance<TAB>ID<TAB>DELIVERABLE_ID<TAB>OWNER<TAB>KIND<TAB>OWNER_CONTEXT_REF_OR_null<TAB>ACCEPTANCE_AUTHORITY_REF_OR_null<TAB>REVISION<TAB>AUTHORITY_TYPE<TAB>AUTHORITY_CONTRACT<TAB>AUTHORITY_REF<TAB>AUTHORITY_DIGEST<TAB>SUBJECT_AUTHORITY_DIGEST<TAB>ACTOR_OR_null<TAB>ACTION_INSTANCE_OR_null<TAB>INTENT_DIGEST_OR_null<TAB>POLICY_MANIFEST_DIGEST_OR_null<TAB>AUTHORIZATION_REF_OR_null<TAB>ACCEPTED_AT
required_check<TAB>ID<TAB>OWNER<TAB>SUBJECT_REF<TAB>STATE<TAB>REASON_CODE_OR_null<TAB>REASON_REF_OR_null<TAB>ACTION_INSTANCE_OR_null<TAB>INTENT_DIGEST_OR_null<TAB>POLICY_MANIFEST_DIGEST_OR_null<TAB>AUTHORIZATION_REF_OR_null
harvest<TAB>BOOLEAN
harvest_candidate<TAB>ID<TAB>KIND<TAB>SOURCE_REF<TAB>STATE<TAB>DECISION_OR_null<TAB>TARGET_REF_OR_null<TAB>REASON_CODE_OR_null<TAB>REASON_REF_OR_null<TAB>ACTION_INSTANCE_OR_null<TAB>INTENT_DIGEST_OR_null<TAB>POLICY_MANIFEST_DIGEST_OR_null<TAB>AUTHORIZATION_REF_OR_null
```

SHA-256 over those bytes is the `workbench-task-content/v1` revision. The outcome manifest
then binds selected evidence without a cycle:

```text
workbench-task-revision/v1
content_revision<TAB>SHA256_CONTENT_REVISION
evidence<TAB>CHECK_ID<TAB>SUBJECT_REF<TAB>SUBJECT_REVISION<TAB>EVIDENCE_ID_OR_null<TAB>RESULT_OR_null<TAB>BOOLEAN
```

Abandonment does not reuse a possibly nonexistent completion revision. It derives the current
writer snapshot first:

```text
workbench-writer-abandonment-snapshot/v1
operation<TAB>OPERATION_ID<TAB>CLAIM_ID<TAB>STAGE<TAB>ACTION_INSTANCE_OR_null<TAB>POLICY_MANIFEST_DIGEST_OR_null<TAB>INTENT_DIGEST_OR_null<TAB>AUTHORIZATION_REF_OR_null<TAB>REMOTE_CLAIM_STATE<TAB>REMOTE_CLAIM_DIGEST_OR_null<TAB>EFFECT_OWNER_EVENT_ID_OR_null<TAB>EFFECT_OWNER_HISTORY_DIGEST_OR_null<TAB>EFFECT_OWNER_DEVICE_OR_null<TAB>EFFECT_OWNER_CLONE_OR_null<TAB>WORKTREE_OWNERSHIP<TAB>REPO_RECORD_OWNERSHIP<TAB>WORKTREE_SET_DIGEST_OR_null<TAB>COMPENSATION_TARGET_OR_null<TAB>COMPENSATION_REASON_OR_null<TAB>COMPENSATION_NEXT_STEP_OR_null
```

There is one row for every current non-cancelled operation, sorted by operation and claim ID.
`REMOTE_CLAIM_STATE` is `absent`, `active`, or `released`; current effect owner is reduced from
the remote event ledger. `REMOTE_CLAIM_DIGEST` is SHA-256 over the contract line
`workbench-writer-claim-snapshot/v1`, then every exact matching canonical claim row in state
order, each LF-terminated; it is null only for `absent`. `EFFECT_OWNER_EVENT_ID` is the latest
reduced event or null when none has ever existed. `EFFECT_OWNER_HISTORY_DIGEST` is SHA-256 over
`workbench-effect-owner-snapshot/v1` plus every exact matching event row in event-ID order,
each LF-terminated; it is null only when the event ID is null. The snapshot includes no private path, but
its authorization, ownership, and cursor facts must equal the strict local operation and
remote ledger. Any malformed, ambiguous, or
unjoinable fact is `writer-claim-unreconciled`, and abandonment cannot mint an action.
For a released compensation prefix, `stage: release-pending` with next `claim` is the only
valid pre-CAS snapshot; `compensation-pending` with next `claim` and a released remote row is
malformed.

The abandonment action revision is SHA-256 over:

```text
workbench-task-abandonment-revision/v1
content_revision<TAB>SHA256_CONTENT_REVISION
writer_snapshot<TAB>SHA256_WRITER_ABANDONMENT_SNAPSHOT
removal_plan<TAB>SHA256_REMOVAL_PLAN
reason_code<TAB>REASON_CODE
reason_ref<TAB>REASON_REF_OR_null
deliverable<TAB>ID<TAB>BOOLEAN<TAB>STATE<TAB>REVISION_OR_null
```

Deliverable rows are sorted by ID and repeat `required`, state, and nullable revision, so
pending and null outcomes are explicit rather than being mistaken for completion. The cleanup
plan is the exact canonical plan defined under governed cleanup. A reason, writer event,
operation cursor, deliverable fact, or removal-plan change supersedes the pending abandonment
instance and its authorization. This revision is the terminal revision recorded for an
abandoned task; `workbench-task-revision/v1` remains the completion-only revision.

For every canonical TAB-separated manifest in this contract, `<TAB>` is one byte `0x09`,
each row ends in one LF byte `0x0a`, and no value contains TAB or LF. `BOOLEAN` serializes
exactly lowercase ASCII `true` or `false`; JSON spelling, `1|0`, uppercase, and empty values
are invalid. Every `_OR_null` uses the literal lowercase ASCII token `null`. Digests consume
these exact UTF-8 bytes including the final LF.

Policy context rows are sorted by context ref; the task-policy row is omitted when absent.
Writer claims are sorted by owner, operation ID, and claim ID. Deliverable, acceptance,
required-check, harvest, and evidence rows are sorted by stable ID. Selected evidence is greatest
`recorded_at`, with lexicographically greatest `evidence_id` as the tie-breaker. Contract
values must not contain TAB or LF. SHA-256 over the exact UTF-8 bytes is represented as
`sha256:<lowercase-hex>`.

Action, policy, status, log, `workbench-writer-operation/v1`, and other task-bookkeeping
records are never inputs. A durable
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
  --reason-code CODE [--reason-ref REF] [--target-ref REF] \
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
        "reason_ref": "conversation:message/msg-123",
        "action_instance_id": "act_01J00000000000000000000000",
        "intent_digest": "sha256:7777777777777777777777777777777777777777777777777777777777777777",
        "policy_manifest_digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
        "authorization_ref": "conversation:message/msg-123"
      }
    }
  ]
}
```

`show` always reports `changed: false`; mutations report whether the ledger changed.
Candidates are sorted by ID. A pending candidate has `state: "pending"` and
`disposition: null`. A disposition stores the exact optional reason reference and consumed
intent digest. Its exact field order is `decision`, `target_ref`, `reason_code`, `reason_ref`,
`action_instance_id`, `intent_digest`, `policy_manifest_digest`, and `authorization_ref`.
Repeating an identical declaration or disposition is idempotent;
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
  "writer_operations": [
    {
      "operation_id": "wop_01J00000000000000000000000",
      "claim_id": "wc_01J00000000000000000000000",
      "owner": "web-app",
      "stage": "consumed",
      "remote_claim": "active",
      "writer_row": "matched",
      "worktree": "matched",
      "satisfied": true
    }
  ],
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

A computed blocker has shape `{"code":"stale-evidence","ref":"web-test"}`. Before deriving
the task revision, verify joins every current task-local `workbench-writer-operation/v1`, every
active remote ledger row with this `task_claim_id`, every task-content writer row, and current
worktree ownership fact. One exact `consumed` operation with matching active remote claim,
content row, and worktree is satisfied. One exact `released` operation with a verified released
remote row, no live worktree, and no content writer row is satisfied. Rows are matched by
operation/claim/task/owner/branch/path/origin.

One exact `handoff-ready` operation is also satisfied when its active claim and content writer
row match, effect-owner reduction is released/null, and no local worktree exists. Delivery does
not require rematerialization on a receiver; a receiver is needed only to resume code work.
One exact `cancelled` operation with no remote claim, effect-owner event, worktree, repo row,
or content writer row is also satisfied. Any `prepared`, `authorization-pending`,
`remote-claimed`, `effect-owner-acquired`, `worktree-create-pending`, `worktree-ready`,
`record-create-pending`, `record-ready`, `compensation-pending`, or
`release-pending` operation produces `writer-operation-incomplete`. An unmatched or duplicate
active remote row, local/remote identity mismatch, consumed or handoff-ready operation without
its exact postcondition, or recovery blocker produces `writer-claim-unreconciled`. In either case `revision` is null,
`verified` is false, and task revision hashing does not begin. Missing or
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
`harvest-undisposed`, `writer-operation-incomplete`, `writer-claim-unreconciled`,
`terminal-outcome-conflict`, `terminal-content-frozen`, `action-binding-stale`, and
`action-effect-unreconciled`. Packs may
add namespaced blocker codes; consumers ignore unknown
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

Completion first runs the common applied-effect reducer. An exact terminal outcome primary
repairs only its missing `task-completed` lifecycle projection/private status and does not run
current writer or policy checks. With no applied provenance, completion repeats the exact
writer join above before computing a revision and all other non-policy blockers. It cannot mint
an action instance or activate terminal freeze while a writer blocker exists. If blockers
exist, it returns the outcome report at exit `1` with `action_instance_id: null`. Otherwise it
resolves policy, repeats writer reconciliation, rechecks the revision digest, atomically writes
the terminal outcome primary, then projects lifecycle through the reducer.

### Abandon

```text
workbench task abandon \
  --reason-code CODE [--reason-ref REF] \
  [--action-instance-id ID] [--authorization-file FILE] --format json
```

The action ID is `task.abandon`; target follows completion, but revision is the independently
computed `workbench-task-abandonment-revision/v1` digest. `reason-code` is a stable machine
identifier supplied by the judgment layer. `reason-ref` may point to the human explanation
without requiring shell plumbing to write it. Both reason values are inside the abandonment
revision and its action intent.

Abandonment does **not** require accepted deliverables, passing evidence, a sealed harvest
ledger, or a workbench increment. It requires a non-terminal v2 task, a parseable current
content and writer-abandonment snapshot, an exact cleanup plan, a sealed context-policy set,
a reason code, and successful policy resolution. Pending and null deliverable facts are
encoded in its dedicated revision binding. Dirty or unpushed work may still block later
cleanup, but it is not misrepresented as a completion
predicate. A valid incomplete writer operation does not block authorized abandonment;
malformed, ambiguous, or unjoinable writer facts do. Abandonment freezes new writer effects,
and governed cleanup must compensate/release every existing operation before deletion.
Like completion, it runs the applied-effect reducer before testing non-terminal state or
deriving its abandonment revision. An exact existing outcome may only reconcile its matching
`task-abandoned` projection; a lifecycle marker without the outcome primary is unreconciled.

Successful outcome output is:

```json
{
  "contract_version": "workbench-task-outcome/v1",
  "task_contract": "workbench-task/v2",
  "outcome": "completed",
  "changed": true,
  "action_instance_id": "act_01J00000000000000000000000",
  "intent_digest": "sha256:7777777777777777777777777777777777777777777777777777777777777777",
  "policy_manifest_digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
  "authorization_ref": "conversation:message/msg-123",
  "revision": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "removal_plan_digest": null,
  "reason_code": null,
  "reason_ref": null,
  "blockers": []
}
```

The exact outcome field order is `contract_version`, `task_contract`, `outcome`, `changed`,
`action_instance_id`, `intent_digest`, `policy_manifest_digest`, `authorization_ref`,
`revision`, `removal_plan_digest`, `reason_code`, `reason_ref`, and `blockers`.

Abandonment changes `outcome` to `abandoned`, sets the reason fields, and stores the exact
non-null cleanup-plan digest already bound by its revision; completion leaves that field null
and cleanup derives its later plan before authorization. A computed
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

For `workbench-task/v2`, `--force` is invalid at exit `2`. After stable task selection, cleanup
first reduces any external journal for the supplied/stored action, even when local task state
has already disappeared. Only when no applied journal exists must the selected task have a
`task-completed` or `task-abandoned` outcome, clean task and nested codebase worktrees, and a
pushed task branch. Preflight blockers are `missing-terminal-outcome`,
`dirty-task-worktree`, `dirty-codebase-worktree`, `unpushed-task-branch`,
`ambiguous-task-selection`, `cleanup-plan-mismatch`, `writer-recovery-blocked`, and
`action-binding-stale`. A current effect owner on another device/clone is
`writer-recovery-blocked`; cleanup never converts elapsed time or source unavailability into
forced takeover.

Cleanup uses action `task.cleanup`, target `workbench:task/<claim_id>`, and the terminal
outcome revision. Its intent additionally binds the canonical removal-plan digest. For an
abandoned task that digest must equal the one frozen in its abandonment revision. Its
first-call, `ask`, `deny`, retry, and authorization behavior is the same as completion.
Preflight blockers are computed before minting. An authorized cleanup
revalidates the frozen participant/task bindings, re-observes current workspace and trusted
platform authority, and resolves the resulting manifest immediately before consumption.

The removal plan is SHA-256 over these exact LF-terminated rows:

```text
workbench-task-removal-plan/v1
task_id<TAB>TASK_ID
claim_id<TAB>TASK_CLAIM_ID
task_branch<TAB>BRANCH
writer_operation<TAB>OPERATION_ID<TAB>CLAIM_ID<TAB>cancel-no-effect|compensate-release|retire-consumed|release-handoff
codebase_worktree<TAB>OPERATION_ID<TAB>CLAIM_ID<TAB>OWNER<TAB>EXPECTED_PATH
task_workspace<TAB>WORKSPACE_RELATIVE_PATH
local_branch<TAB>BRANCH
```

Writer-operation rows are sorted by operation and claim ID. Worktree rows are sorted by
owner, operation, and claim ID and occur only where the exact operation owns or must retire a
planned worktree. There is exactly one task-workspace and one local-branch row. Paths are
normalized relative to the common workbench root and contain no `..`, TAB, or LF. The plan is
deliberately terminal-revision-free so abandonment may include its digest without a hash cycle;
the cleanup action-intent envelope binds both values. The plan is derived before authorization
from the terminal writer snapshot plus current exact owned effects; a different stage prefix
may remove an already completed step but never alter the
frozen operation identity or desired final absence. A changed operation set, identity, path,
branch, or disposition changes the digest and supersedes a pending cleanup authorization.

The durable recovery journal is stored in the task home's GitHub issue comments, outside the
local task workspace, using this marker before any deletion:

```html
<!-- workbench-task-cleanup:v1
{"contract_version":"workbench-task-cleanup-journal/v1","journal_id":"cleanup-task__workbench-kit__25","stage":"prepared","task_id":"workbench-kit#25","claim_id":"task__workbench-kit__25-20260711T030000Z-1234","branch":"task/25-example","revision":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","action_instance_id":"act_01J00000000000000000000000","intent_digest":"sha256:7777777777777777777777777777777777777777777777777777777777777777","policy_manifest":{"contract_version":"workbench-policy-manifest/v1","digest":"sha256:4444444444444444444444444444444444444444444444444444444444444444","sources":[{"layer":"workspace","context_ref":null,"policy_ref":".workbench/policy.conf","policy_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","authority_identity":"github:example/workbench","authority_ref":"refs/heads/main","authority_revision":"1111111111111111111111111111111111111111","authority_receipt_digest":"sha256:abababababababababababababababababababababababababababababababab","decision":"allow"}]},"authorization_ref":"conversation:message/msg-123","removal_plan_digest":"sha256:9999999999999999999999999999999999999999999999999999999999999999","removal_plan":{"writer_operations":[{"operation_id":"wop_01J00000000000000000000000","claim_id":"wc_01J00000000000000000000000","disposition":"retire-consumed"}],"codebase_worktrees":[{"operation_id":"wop_01J00000000000000000000000","claim_id":"wc_01J00000000000000000000000","owner":"web-app","expected_path":"task/codebases/web-app"}],"task_workspace":".worktrees/task__workbench-kit__25","local_branch":"task/25-example"},"effect_owner_events":[],"at":"2026-07-11T03:30:00Z"}
-->
```

The exact top-level key order is shown. `removal_plan` has exact keys
`writer_operations`, `codebase_worktrees`, `task_workspace`, and `local_branch`; operation
objects have `operation_id`, `claim_id`, `disposition`, and worktree objects have
`operation_id`, `claim_id`, `owner`, `expected_path`, in those orders. Arrays use the same
canonical sorting as the manifest. `stage` is `prepared`, `effect-owner-acquired`,
`effect-owner-released`, or `completed`. `effect_owner_events` is a prefix-ordered array of
strict objects with exact fields `event_id`, `operation_id`, `claim_id`, `device_id`,
`clone_id`, `state`, `phase`, and `at`; `state` is `acquired` or `released` and `phase` is
`intended` or `verified`. Before every effect-owner CAS used by cleanup, the kernel appends an
`intended` prefix, then appends the matching `verified` prefix after the ledger event is
observed. Recovery requires every verified prefix to agree exactly with the remote ledger and
never infers an owner transition from missing local state.

Comments with one `journal_id` form an append-only prefix chain: immutable top-level bindings
and removal plan are byte-equal, every later event array strictly extends the prior array, and
timestamps are nondecreasing. The unique longest valid prefix is current. A fork, rewrite,
duplicate non-idempotent prefix, or remote disagreement is `cleanup-reconciliation-failed`.

The kernel writes `stage: "prepared"` only after final policy resolution; that durable
receipt is the applied-effect consumption source. The reducer never reauthorizes it and marks
private status consumed when local state still exists. If the comment cannot be written, it returns
`cleanup-journal-unavailable` and deletes nothing. The plan lists every writer operation and
claim ID. For each pair, cleanup uses the remote row to recover expected path/branch/origin,
removes only the exact planned nested worktree, prunes it, and verifies that no exact or
possible orphan remains. The prepared journal then acts as the external retirement record for
the otherwise frozen task-content repo row; a consumed operation therefore begins cleanup at
the `worktree` cursor and never edits that frozen row. Cleanup appends the matching remote
`released` row only after persisting `release-pending` with next `claim`, then refetches it and
advances finish. All operation releases must be verified before
the task workspace or local task branch is deleted.

Release changes coordination state, not frozen task content. Ambiguous/external worktrees or
CAS failure keep the task workspace and remote claim active and return
`writer-recovery-blocked` or `writer-lock-unavailable`. Cleanup never closes the issue,
changes labels, deletes the remote task branch, or deletes coordination history. Finally it
appends the same journal shape with `stage: "completed"` and emits `task-cleaned`. If a crash
occurs after task deletion but before completion observation, retry reconstructs solely from
the external journal plus remote ledger, finishes any missing release verification, and then
reconciles the lifecycle marker.

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
  "intent_digest": "sha256:7777777777777777777777777777777777777777777777777777777777777777",
  "policy_manifest_digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444",
  "authorization_ref": "conversation:message/msg-123",
  "revision": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "removal_plan_digest": "sha256:9999999999999999999999999999999999999999999999999999999999999999",
  "released_writer_operations": [
    {
      "operation_id": "wop_01J00000000000000000000000",
      "claim_id": "wc_01J00000000000000000000000"
    }
  ],
  "removed": {
    "task_workspace": true,
    "codebase_worktrees": ["web-app"],
    "local_branch": true
  },
  "blockers": []
}
```

The exact cleanup field order is `contract_version`, `task_contract`, `task_id`, `claim_id`,
`branch`, `outcome`, `changed`, `action_instance_id`, `intent_digest`,
`policy_manifest_digest`, `authorization_ref`, `revision`, `removal_plan_digest`,
`released_writer_operations`, `removed`, and `blockers`.
Blocked preflight sets `outcome: null`, `changed: false`, `action_instance_id: null`, and
lists blockers at exit `1`. Policy `ask` and `deny` return the policy object at exit `3` and
`4`. Retry first reads the issue journal: `prepared` resumes only exact worktree retirement,
writer-operation release, verification, and removal steps and does not reauthorize the
already consumed action; `completed` reconciles a missing `task-cleaned` lifecycle marker; a
prior lifecycle marker is idempotent with `changed: false`. Failures use
`cleanup-plan-mismatch`, `cleanup-journal-unavailable`, `cleanup-reconciliation-failed`,
`action-effect-unreconciled`, `writer-recovery-blocked`, `writer-lock-unavailable`, or
`lifecycle-write-failed`. The external
prepared receipt and remote operation row are the recovery and consumption sources after
task-local state disappears.

Legacy `workbench-task/v1` tasks retain the existing `done ID [--parent N] [--force]`
behavior and do not accept the v2 JSON contract by implication.

## Public versus private data

The JSON objects, semantics, command names, flags, and exit statuses in this page are public.
On-disk storage beneath disposable task state is private unless explicitly named above.
Capability packs call commands and must not read or mutate private record files.
