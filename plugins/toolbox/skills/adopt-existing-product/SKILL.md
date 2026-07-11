---
name: adopt-existing-product
description: Use when bringing an existing codebase, product, or legacy project under optional toolbox governance without rebuilding it.
---

# Adopt Existing Product

Describe findings in `profile.language`; keep schema fields, refs, IDs, and state
values in canonical English.

## Inventory

1. Run `toolbox workbench check`. Stop before mutation unless the caller supports
   the required workspace and profile contracts.
2. Inventory existing repositories, existing documentation, existing tests, the
   existing design system, release process, ownership, active work, and durable
   product terminology. Read repository-local instructions before classifying it.
3. Compare that inventory with toolbox compatibility: stable product ID,
   operational language, repository roles, quality commands, and scenario-sized
   work. Record gaps; do not treat adoption as permission to refactor.

## Register

1. Only after compatibility is established, run `toolbox product init` once.
2. Register each repository with `toolbox product repository set`, preserving its
   real workspace-relative path and `owner`, `work`, or `reference` role.
3. Register each existing executable check through `toolbox product quality check
   set ... --owner <repository-id>`. The owner must be the writable repository
   where the command runs; do not infer it from a check name or invent commands
   that have not run.
4. Sync policy with `toolbox product policy sync`, validate the product, and use
   `scenario-refine` for the first bounded future outcome. Historical work is not
   backfilled as completed scenarios without evidence.

## Boundaries

- Do not rewrite existing code, rename public APIs, replace the existing design
  system, or reorganize repositories merely to adopt toolbox.
- Do not migrate the workbench, create a task, or claim prior delivery evidence.
- Leave incompatible products unchanged and report the smallest follow-up needed.
