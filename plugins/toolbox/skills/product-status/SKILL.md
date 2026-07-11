---
name: product-status
description: Use when reporting current product progress, scenario readiness, blockers, or the next governed product action.
---

# Product Status

Report derived facts without changing product or task state.

## Procedure

1. Run `toolbox workbench check`. Retain `.profile.language`; stop if the public
   contract or language capability is unavailable.
2. Run `toolbox product status <product-id>`. Treat
   `toolbox-product-status/v1` as the only status source. Do not infer readiness
   from filenames, prose, branches, or a partial scenario list.
3. Report the product state, scenario counts, active scenario, ready candidates,
   blockers, and `next_action`. Keep schema IDs, refs, blocker codes, and state
   values in canonical English. Render reader-facing prose in
   `.profile.language`.
4. When a blocker needs resolution, name its exact `code` and `ref`; do not
   silently reinterpret it as permission to mutate state.

## Boundaries

- This workflow is read-only. Do not call mutation commands, update a task, or
  write product state.
- Do not read `products/` directly. The CLI validates the complete joined state
  before deriving status.
- Do not claim delivery, acceptance, or completion from a ready or active
  scenario.
- `continue-active-scenario` means resume the existing workbench task through
  its lifecycle. It does not authorize a new run plan; product-run rejects a
  product that already has an active scenario.
