# Upgrade CLI Reference

The public command is:

```text
workbench-kit --workspace ABS_ROOT upgrade-workbench MODE ROUTE_INPUTS --format json
```

`ABS_ROOT` must be a dedicated migration task workspace. Python 3.9+, Git, and a
compatible public `workbench` kernel command are required. Only JSON output is
supported.

## Dry-Run Routes

**Implicit v1 (`implicit-v1`)** (`generated-minimal` or verified
`embedded-legacy`):

```bash
workbench-kit --workspace "$ROOT" upgrade-workbench --dry-run \
  --language "$LANGUAGE" --authority-approval-file "$AUTHORITY" \
  --format json > "$PLAN"
```

Add `--reviewed-overlay-file "$REVIEW"` only when a human-provided reviewed
overlay receipt is required.

**Staged v2 (`staged-v2`)** (`migration-staged`): omit `--language`, retain the
authority approval, and supply `--reviewed-overlay-file` only when the frozen route
requires it.

```bash
workbench-kit --workspace "$ROOT" upgrade-workbench --dry-run \
  --authority-approval-file "$AUTHORITY" --format json > "$PLAN"
```

**Current v2 (`current-v2`)** (`already-current`): language, authority, and
reviewed-overlay flags are forbidden.

```bash
workbench-kit --workspace "$ROOT" upgrade-workbench --dry-run \
  --format json > "$PLAN"
```

An explicit embedded-engine removal uses two dry-runs because the approval must bind the
exact removal basis:

1. Run the route-specific dry-run with `--remove-embedded-engine` but without `--removal-approval-file`.
   A removable engine exits `1` with the
   `removal-approval-required` blocker and emits `removal_plan_basis_digest`.
2. Give that blocked candidate plan to a human or trusted adapter. It must independently
   review the exact nodes and write an external `0600` receipt conforming to
   `schemas/removal-approval.schema.json`, with `approved_plan_basis_digest` equal to the
   candidate value. The upgrade skill and agent never create or infer this receipt.
3. Repeat the same dry-run with both `--remove-embedded-engine` and
   `--removal-approval-file "$REMOVAL"`; save this unblocked output as the canonical plan.

Removal is available only when the bundled equivalence receipt verifies every owned legacy
node and the installed engine manifest. Unknown revisions and byte drift remain fail-closed
with `plugin-equivalence-unavailable` or an embedded-engine blocker.

## Apply

Apply the canonical plan file with the same route inputs and receipts:

```bash
workbench-kit --workspace "$ROOT" upgrade-workbench --apply \
  --plan-file "$PLAN" ROUTE_INPUTS --format json > "$RESULT"
```

Pass the same `--removal-approval-file` when the plan binds removal, but omit
`--remove-embedded-engine`. `--journal-dir ABS_DIR` is optional; create it as an
owned safe directory outside the workspace and reuse it on every retry.

## External Files

Plan, approval, review, removal, and result files must be absolute and outside the
workspace. Inputs must be owned regular files with one link and no group/world write
permission. Use `mktemp`, then `chmod 600`. An explicit journal root must already
exist, must not alias or contain the workspace, and should be mode `0700`.

## Results

- `0`: plan/result has no blockers.
- `1`: structured blockers or an operational safety failure.
- `2`: invalid command or flag combination.

Dry-run emits a canonical plan and does not mutate the workspace. Apply accepts only
that external canonical plan. Completed or rolled-back terminal journals replay as
no-ops; stale inputs require a new dry-run and human approval.
