---
name: portfolio-run
description: Use when choosing and continuing ready work across multiple toolbox products while preserving one primary scenario per task.
---

# Portfolio Run

Advance products serially through deterministic plans. Portfolio selection does
not create a multi-scenario task.

## Loop

1. Run `toolbox workbench check`; keep `profile.language` for operational prose.
2. Run `toolbox portfolio run-plan`. Report `skipped_products` with their exact
   blocker codes and refs.
3. Invoke `product-run` for exactly one selected `scenario_ref`. Never combine a
   selected scenario with `remaining_candidates` in one task.
4. If that product reaches a policy, evidence, acceptance, or human gate, record
   the exact task blocker. Continue only when the product can be left without
   claiming completion or acceptance.
5. Choose the first `remaining_candidates` entry whose product was not attempted
   in this session, validate it with `toolbox product run-plan <product-id>
   --scenario <scenario-id>`, and invoke `product-run` again.
6. Re-evaluate with `toolbox portfolio run-plan` after any persisted scenario or
   product transition. Stop when no ready candidate remains or a portfolio-wide
   integrity failure occurs.

## Boundaries

- Keep refs, state values, and reason codes in canonical English; explain them in
  `profile.language`.
- Do not convert an unresolved human or policy gate into a completed scenario.
- Do not schedule parallel writers, auto-merge PRs, or deploy production.
