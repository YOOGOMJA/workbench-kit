---
name: generate-workbench
description: >-
  Second step after interview-for-personalizing. Takes a target repo location or git URL, scaffolds a minimal workbench (persona-composed AGENTS.md + codebases.yaml + empty docs/), bakes in the temporary .persona/ draft, then discards it. The engine (skills+utils) comes from the installed plugin, so the generated repo stays minimal.
---

# generate-workbench (draft — stub)

> Bootstrap step 2. The engine (skills+utils) is provided by the installed plugin,
> so the generated user repo is **minimal** — persona + targets + knowledge only.

## Input = `.persona/` (the contract left by interview)

- `.persona/overlay.md` — filled AGENTS.overlay.md (the 7 persona cells)
- `.persona/codebases.yaml` — (optional) initial work targets
- `.persona/meta.yaml` — target repo location/URL preference, language

If `.persona/` is absent, suggest running `interview-for-personalizing` first.

## What it creates (user repo)

```
my-workbench/
  AGENTS.md          ← AGENTS.core (plugin) + .persona/overlay.md, composed
  AGENTS.overlay.md  ← .persona/overlay.md, as-is (editable later)
  codebases.yaml     ← .persona/codebases.yaml or empty template
  docs/              ← empty knowledge skeleton (index + empty anchor tables + log)
```

The engine (`utils/`·`skills/`) is **not copied** — the plugin provides it
(`workbench` on PATH via `bin/`). That keeps the repo minimal.

## Procedure

1. Use `.persona/meta.yaml` to obtain the target repo (location/URL; `gh repo create` if needed).
2. Compose user-repo `AGENTS.md` from plugin `AGENTS.core.md` + `.persona/overlay.md`;
   keep `.persona/overlay.md` as `AGENTS.overlay.md`.
3. `.persona/codebases.yaml` (or empty template) → `codebases.yaml`; create empty `docs/` skeleton.
   Skeleton/operational prose follows the persona `language`.
4. Discard `.persona/` (temporary scratch).
5. Point the user to first operation (`workbench:task-start`).

> TODO(build): implement compose; per-tool discovery (repo-local vs plugin);
> CLI-on-PATH guidance (framework decision 0021 verification points).
