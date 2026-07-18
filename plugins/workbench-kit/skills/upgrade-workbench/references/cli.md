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

For an explicit embedded-engine removal request, add both
`--remove-embedded-engine` and `--removal-approval-file "$REMOVAL"` to dry-run.
Removal is available only when the bundled equivalence receipt verifies every owned
legacy node and the installed engine manifest. Unknown revisions and byte drift remain
fail-closed with `plugin-equivalence-unavailable` or an embedded-engine blocker.

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
