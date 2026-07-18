---
name: upgrade-workbench
description: >-
  Use when an existing generated, embedded-engine, staged, or current workbench must be diagnosed, upgraded, migrated, or have its embedded engine removed.
---

# Upgrade Workbench

Run a governed migration with the bundled `workbench-kit` CLI. Keep diagnosis,
human authorization, apply, and PR merge as separate decisions.

Read [the CLI reference](references/cli.md) when selecting route-specific flags,
interpreting exit status, or preparing external evidence and journal paths.

## Preconditions

- Work only in a dedicated migration task workspace containing `task/index.md`.
- Resolve the workspace and every input/output path to absolute paths.
- Require the workspace parent to be owned by the current user, not writable by
  group or other users, and on the same filesystem as every mutable worktree and
  Git-admin directory. Shared sticky parents such as `/tmp` fail closed; place the
  task workspace under a private parent before retrying.
- Keep plans, approvals, results, and optional journals outside the workspace.
- Use `workbench-kit` from `PATH`; in Claude Code, fall back to
  `${CLAUDE_PLUGIN_ROOT}/bin/workbench-kit`.
- Never create, edit, repair, or infer authority, reviewed-overlay, equivalence,
  or removal approval receipts. A human or trusted adapter must supply them.
- Do not install or enable `toolbox`; product adoption is a separate task.

## Procedure

1. **Diagnose with a read-only dry-run.** Create an external `0600` plan file,
   then run the route-specific dry-run from the CLI reference. If classification is
   blocked, unrecognized, or indeterminate, report its exact blocker and stop. For
   `malformed`, continue only when every blocker is exactly
   `generator-composition-invalid` at `AGENTS.md` and a human-supplied reviewed-overlay
   receipt is available; run the documented reviewed-overlay recovery dry-run without
   editing workspace evidence. All other `malformed` classifications stop.

2. **Review before writing.** Summarize `classification_before`, target,
   `actionable`, blockers, embedded-engine before/after, operations, preserved paths,
   active v1 tasks, and bound input digests. Show the plan path and ask the human for
   explicit apply approval. Never rewrite the frozen plan.

3. **Apply only after approval.** Create an external `0600` result file and apply
   the exact plan with the same route inputs. Reuse an explicit journal directory on
   retries. Do not add `--remove-embedded-engine` during apply; the plan already binds
   that request. Bundled equivalence covers only the exact source revision and node
   manifest named by its receipt; any absent receipt or byte drift stops on
   `plugin-equivalence-unavailable` or an embedded-engine verification blocker.

4. **Verify and submit.** Require a `completed` transaction, the expected target
   classification, unchanged preserved paths, and unchanged active v1 task facts.
   Commit through the workspace task lifecycle, then use `task-submit` to open the
   migration PR. Retain external inputs, plan, result, and journal until resolution.

5. **Keep merge and cleanup human-owned.** Ask before merge. After the protected
   default branch is updated, diagnose again. Only valid v2 governance plus doctor
   readiness is `already-current`; ask again before task cleanup.

## Failure Rules

- A stale plan, source, or input requires a new dry-run and human review.
- A `rolled-back` result is terminal evidence: report blockers and retain it.
- A `public-adapter-restore-failed` ref under `.workbench-kit-quarantine-*`
  is retained external evidence. Report its canonical path and never delete it
  automatically, even when it appears empty.
- Preserve unsafe, corrupt, aliased, or foreign journal/temp state. Never delete or
  rewrite transaction evidence manually.
