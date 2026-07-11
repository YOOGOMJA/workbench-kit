---
name: design-system
description: Use when a product scenario needs UI states, tokens, components, interaction rules, responsive behavior, or accessibility decisions.
---

# Design System

Evolve the owning codebase for one scenario. Explain decisions in
`profile.language`; keep token, component, state, and reference identifiers in
canonical English.

## Procedure

1. Confirm the selected scenario and owning codebase from the public run plan.
2. Inventory the owning codebase's existing tokens, existing components,
   framework conventions, assets, and accessibility tests before proposing
   changes. Reuse compatible primitives.
3. Model the scenario's loading, empty, error, and success states plus relevant
   permission, offline, recovery, and destructive-action states.
4. Specify responsive constraints, keyboard and focus behavior, semantic roles,
   contrast, motion preferences, and readable error feedback.
5. Add only the tokens, primitives, components, stories, screenshots, and tests
   required by the scenario. Store implementation artifacts and design records
   in the owning codebase, not in the toolbox plugin or product metadata.
6. Update the scenario's `designRefs` through `toolbox scenario apply`, then
   verify every acceptance state against the implementation.

## Boundaries

- Do not create a universal component library or a parallel design system.
- Do not perform decorative redesign unrelated to the scenario outcome.
- Do not replace established codebase conventions without recording why they
  cannot satisfy the required state.
