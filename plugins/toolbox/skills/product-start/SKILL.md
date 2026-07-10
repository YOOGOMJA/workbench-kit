---
name: product-start
description: Use when adopting the optional toolbox pack for a new product or initializing durable product state in a compatible workbench.
---

# Product Start

Initialize one product contract without starting implementation or inventing a
parallel lifecycle. Keep judgment in this skill and state transitions in the
deterministic toolbox CLI.

## Inputs

Derive reversible details from existing context. Ask only when a wrong assumption
would materially change the product mandate.

- `id`: stable lowercase kebab-case product identifier
- `name`: reader-facing product name
- `objective`: concise current outcome, not an implementation plan
- `language`: the exact `.profile.language` returned by `toolbox workbench check`
  under the required `profile.language/v1` capability

Keep schema IDs, commands, state values, filenames, and references such as
`toolbox:product/<id>` in canonical English. Write reader-facing values in the
operational language.

## Procedure

1. Work inside the caller's governed task workspace. Do not initialize state in
   the installed plugin directory or directly on an ungoverned main checkout.
2. Run `toolbox workbench check`, retain its JSON output, and use
   `.profile.language` as the product language. The adapter consumes the profile
   object defined by the public workbench contract. If it reports a legacy,
   unavailable profile, or unsupported contract, stop before mutation and report
   that a workbench-kit migration is required. Do not perform migration as part
   of product adoption.
3. Inspect existing state with `toolbox portfolio inspect`. If the requested ID
   exists, validate and report it instead of overwriting it.
4. Initialize exactly once:

   ```bash
   toolbox product init \
     --id <id> \
     --name <name> \
     --language <language> \
     --objective <objective>
   ```

5. Run `toolbox product check <id>`, then read the normalized result with
   `toolbox product inspect <id>`.
6. Record the created `toolbox:product/<id>` reference in the task's product-facing
   deliverable or follow-up plan when the public workbench task contract supports
   that operation.

## Boundaries

- Do not write `products/` files directly; use the CLI so compatibility and
  caller-isolation checks run before mutation.
- Do not infer language from the conversation or parse `AGENTS.md`; use only the
  public `profile.language/v1` contract.
- Do not create scenarios, choose backlog priority, implement code, deploy, or
  migrate the workbench in this skill.
- Do not turn current product intent into reusable workbench knowledge. Product
  state is living state; only cross-project decisions, lessons, and runbooks are
  harvest candidates.
