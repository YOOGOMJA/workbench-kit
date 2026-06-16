---
name: interview-for-personalizing
description: >-
  First step of bootstrapping a new workbench. Through a divergence-first, gap-based interview, draw out the user's persona (language, slug style, required issue elements, PR skeleton, label scheme, harvest fields, gate toggles) and draft it into a temporary .persona/ scratch. Trigger when the user wants to create or personalize a workbench. Precedes generate-workbench; together they are the bootstrap flow.
---

# interview-for-personalizing

Bootstrap step 1. **Draw out the persona and draft it into a temporary `.persona/`.**
The next step, `generate-workbench`, reads `.persona/`, bakes it into the user's repo,
then discards it.

> What is persona? Only *taste* the machine does not enforce. The mechanism
> (disposable/accumulate, task meta rules, log format, docs wiki structure, …) is
> framework-fixed (`AGENTS.core.md`), so **don't ask about it.** Ask only persona cells.

## `.persona/` schema (the contract with generate)

The interview output is **temporary** (dot rule — infra scratch; generate consumes
then deletes it):

```
.persona/
  overlay.md       # filled AGENTS.overlay.md (7 cells below) — generate uses as-is
  codebases.yaml   # (optional) initial work targets — may be empty
  meta.yaml        # repo location/URL preference, language — generate uses to place/shape
```

`overlay.md` has the **same sections** as the default `scaffold/AGENTS.overlay.md` —
show that file as the starting point and let the user override only what they want.

## persona cells (= what to ask)

| Cell | What to ask | Default (scaffold) |
|---|---|---|
| language | language of operational output (prose, commits, issue/PR, your docs) | English |
| slug style | word count, case, separator | lowercase kebab, 2–4 words |
| required issue elements | what to enforce in a ticket | Background·Goal·Done·Out-of-scope |
| PR skeleton | PR body sections, AI callout | 5 sections + callout |
| label scheme | priority system, type/area use | priority only, human-confirmed |
| harvest fields | decision/lesson/runbook format | templates default |
| gate toggles | where to stop and ask | PR / cleanup / absorption all on |

> **language** governs only operational output. The framework (skills, AGENTS.core)
> stays English; filenames/identifiers stay stable. Capture the user's choice here
> (e.g., `ko`, `ja`); default is English.

## Flow (reuses the ticket-incubate interview discipline)

1. **Diverge — explore together.** Learn how the user works (tools, taste). Don't
   interrogate the 7 cells up front. Show the default profile
   (`scaffold/AGENTS.overlay.md`) and ask "this is the default — good as-is?"

2. **Transition signal.** When the conversation lets you draft 2+ cells, or the user
   signals "let's build it / wrap up," move to the gap interview.

3. **Gap interview — empty cells only, one at a time.** Don't re-ask cells already
   surfaced; just confirm. Skip cells the default covers. One question at a time.

4. **Draft `.persona/`.** Write the filled cells to `.persona/overlay.md`, any initial
   targets to `.persona/codebases.yaml`, and repo location/language preference to
   `.persona/meta.yaml`.

5. **Hand off to generate.** When the persona is full, move to `generate-workbench` —
   don't dig further. Details can be refined after the workbench exists.

## Boundaries

- Don't ask about the mechanism (core) — only taste (overlay).
- Interview output goes only to the disposable `.persona/` — no user repo is created
  yet (that's generate).
- Leaving mid-way is fine — re-invoke to resume from defaults.
