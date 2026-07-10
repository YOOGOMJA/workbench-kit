---
name: product-run
description: Use when executing one ready toolbox scenario through a governed workbench task and its codebase deliverables.
---

# Product Run

Execute exactly one primary scenario. The workbench owns task lifecycle,
authorization, evidence, acceptance, harvest, and cleanup.

## Prepare

1. Run `toolbox workbench check`; use `profile.language` for reader-facing prose.
2. Use `docs-query` to find prior decisions, lessons, runbooks, and applicability
   limits for the product and scenario. Do not copy knowledge without checking
   its scope and evidence.
3. Run `toolbox product run-plan <product-id> [--scenario <scenario-id>]`.
   Preserve its single `<product-ref>` and `<scenario-ref>`.
4. Bind the task:

   ```text
   workbench task refs set --context-ref <product-ref> \
     --work-ref <scenario-ref> --format json
   ```

## Govern

1. Run `toolbox product policy sync <product-id>`. Emit the owner assertion with
   `toolbox product context-registration ...` into a temporary file.
2. Call `workbench task policy-context register --registration-file <file>
   --format json`, then `workbench task policy-context seal --format json`.
   Registration requires explicit owner authorization. Stop at an unresolved `ask`
   or `deny`; resume only with authorization for that exact action instance.
3. For each selected repository owner, attach only the required work codebase.
   Declare its output with `workbench task deliverable declare`; use multiple
   deliverables when needed, never multiple primary work refs.
4. Translate every required run-plan check with
   `workbench task required-check declare`. Do not fabricate deliverable state,
   revision, evidence, or acceptance.

## Deliver

Refine missing UX states, use `design-system` where applicable, and execute
`tdd-slice`. Update the scenario through `toolbox scenario apply`, never by
editing living state directly. Submit codebase PRs and record their exact head
revisions. Use `release-review` before requesting task completion.

Stop on failed verification, an unaccepted deliverable, or the human merge
gate. Opening a PR is not acceptance, and this skill never deploys production.
