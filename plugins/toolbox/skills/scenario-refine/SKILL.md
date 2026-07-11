---
name: scenario-refine
description: Use when product intent is vague, a scenario lacks testable outcomes, or draft work must be assessed for readiness.
---

# Scenario Refine

Turn one user outcome into a bounded scenario. Preserve framework fields and
refs in English; write reader-facing artifacts in `profile.language`.

## Procedure

1. Run `toolbox workbench check`, then inspect the product and existing scenario
   through public toolbox commands.
2. Describe the triggering situation and observable user states, including
   loading, empty, error, success, permission, and recovery states when relevant.
3. Write independently verifiable acceptance criteria. Identify dependency refs,
   design refs, and explicit non-goals. Put narrative discovery and non-goals in
   the owning codebase's product artifact; reference that artifact from the
   scenario rather than adding private schema fields.
4. Examine value risk, usability risk, and feasibility risk. Record the riskiest
   assumption and the smallest evidence needed to resolve it.
5. Keep status `draft` while any critical risk, dependency, observable state, or
   acceptance criterion is unresolved. Move `draft` to `ready` only after this
   review; readiness is not an implementation estimate.
6. Write a strict `toolbox-scenario/v1` document to a temporary path and apply it
   only with `toolbox scenario apply --product <product-id> --file <file>`.
   Re-run product status and report the result.

Do not implement code, alter priority without product judgment, or edit living
state directly.
