---
name: generate-workbench
description: >-
  Second step after interview-for-personalizing. Takes a target repo location or git URL and a .persona/ draft, then scaffolds a minimal workbench (persona-composed AGENTS.md + AGENTS.overlay.md + codebases.yaml + empty docs/) and discards .persona/. The engine (skills+utils) comes from the installed plugin, so the generated repo stays minimal. Use this whenever the user is ready to create their workbench repo from a persona, or asks to generate/scaffold a workbench.
---

# generate-workbench

Bootstrap step 2. Turn a `.persona/` draft into a real, minimal workbench repo.

The mechanical part — laying the scaffold and composing `AGENTS.md` from the framework
core + the persona overlay — is deterministic and identical every time, so it lives in
a bundled script: **`scripts/compose.sh`**. Your job in this skill is the *judgment*
around it: get the target repo, locate the framework core, run the script, then clean
up and hand off. Don't re-derive the scaffolding by hand — call the script.

## Input = `.persona/` (the contract from interview)

- `.persona/overlay.md` — filled `AGENTS.overlay.md` (the 7 persona cells)
- `.persona/meta.yaml` — `repo: owner/name` *or* `path: …`, plus `language:`
- `.persona/codebases.yaml` — (optional) initial work targets

If `.persona/` is absent, run `interview-for-personalizing` first — don't invent a persona.

## Procedure

1. **Obtain the target repo** from `.persona/meta.yaml`.
   - `repo: owner/name` → create it if needed (`gh repo create owner/name --private`),
     then clone, or use an existing local clone. Confirm with the user before creating
     anything remote — repo creation is outward-facing.
   - `path: …` → use that local directory (init git if empty).

2. **Locate the framework core.** `compose.sh` needs the engine plugin's
   `AGENTS.core.md`. It ships in the **`workbench` plugin** (sibling of this one). Find
   it at the workbench plugin's root (e.g., `${CLAUDE_PLUGIN_ROOT}/../workbench/AGENTS.core.md`
   when installed side-by-side, or wherever the `workbench` plugin is installed). If you
   can't resolve it, ask the user where the `workbench` plugin lives rather than guessing.

3. **Run the compose script:**
   ```bash
   "$SKILL_DIR/scripts/compose.sh" \
     --persona  <.persona dir> \
     --core     <workbench plugin>/AGENTS.core.md \
     --scaffold <this plugin>/../../scaffold   # the bootstrap plugin bundles scaffold/ at its root via the marketplace; use the kit's scaffold/ \
     --out      <target repo>
   ```
   It lays `templates/ .github/ docs/(empty) codebases.yaml`, writes `AGENTS.overlay.md`
   from the persona, and composes `AGENTS.md` = core + overlay (inline). It does **not**
   copy the engine — that's the plugin's job.

   The script **self-checks**: it rejects an empty/half-filled `.persona/` up front, and
   after composing it asserts post-conditions (AGENTS.md has both core+overlay markers,
   overlay/docs/codebases present, engine *not* copied, CLAUDE.md symlink) — failing
   loudly. So you don't eyeball the result; if `compose.sh` exits 0, the workbench is
   well-formed. If it exits non-zero, read the `FAIL` lines and fix the input.

4. **Discard `.persona/`** — it's temporary scratch; its content now lives in the repo.

5. **Commit and hand off.** Make the initial commit (in the user's output language per
   the persona), then point the user to their first task: `workbench:task-start <issue>`
   (engine plugin). Remind them the `workbench` plugin must be installed/enabled for the
   engine commands to work.

## Output (what the user gets — minimal by design)

```
my-workbench/
  AGENTS.md          composed: framework core + your persona (do not edit directly)
  AGENTS.overlay.md  your rules — edit here, then recompose
  codebases.yaml     your targets (or empty template)
  docs/              empty knowledge skeleton (index + empty anchor tables + log)
  templates/  .github/   profile defaults you can tune
```

No `utils/`, `skills/`, or `bin/` — the engine is the installed `workbench` plugin.
That's the whole point: your repo carries only *your* stuff.

## Boundaries

- Don't copy the engine into the user repo — keep it minimal; the plugin provides it.
- Don't create remote repos without confirming (outward-facing).
- Recompose (re-run from edited `AGENTS.overlay.md`) is how rules change later, and how
  framework upgrades flow in (the script re-reads the plugin's new core).
