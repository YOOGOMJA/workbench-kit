---
name: interview-for-personalizing
description: >-
  First step of bootstrapping a new workbench. Through a divergence-first, gap-based interview, draw out the user's persona (language, slug style, required issue elements, PR skeleton, label scheme, harvest fields, gate toggles) and draft it into a temporary .persona/ scratch that generate-workbench consumes. Use this whenever the user wants to set up, create, or personalize a workbench, or talks about "their own rules / conventions" for one — even if they don't say the word "interview". Precedes generate-workbench; together they are the bootstrap flow.
---

# interview-for-personalizing

Bootstrap step 1. **Draw out the persona and draft it into a temporary `.persona/`.**
The next step, `generate-workbench`, reads `.persona/`, bakes it into the user's repo,
then discards it.

> What is persona? Only *taste* the machine does not enforce. The mechanism
> (disposable/accumulate, task meta rules, log format, docs wiki structure, …) is
> framework-fixed (`AGENTS.core.md`), so **don't ask about it.** Ask only persona cells.

## Where the defaults come from

This skill runs from the installed `workbench-kit` plugin, *before* a user workbench
exists — so don't look for defaults in the cwd. Read the bundled starting point at
`${CLAUDE_PLUGIN_ROOT}/scaffold/AGENTS.overlay.md` (Codex: the plugin's
`scaffold/AGENTS.overlay.md`). Show it as "here's the default — keep it?" and let the
user override only what they care about.

## persona cells (= what to ask)

| Cell | What to ask | Default |
|---|---|---|
| language | language of operational output (prose, commits, issue/PR, your docs) | English |
| slug style | word count, case, separator | lowercase kebab, 2–4 words |
| required issue elements | what to enforce in a ticket | Background·Goal·Done·Out-of-scope |
| PR skeleton | PR body sections, AI callout | 5 sections + callout |
| label scheme | priority system, type/area use | priority only, human-confirmed |
| harvest fields | decision/lesson/runbook format | templates default |
| gate toggles | where to stop and ask | PR / cleanup / absorption all on |

> **language** governs only operational output. The framework (skills, AGENTS.core)
> stays English; filenames/identifiers stay stable. Default is English; capture the
> user's choice (e.g., `ko`, `ja`).

## Flow

The discipline is the same as ticket-incubate's: **don't interrogate — diverge first,
then ask only what's missing.** Asking all 7 cells up front makes the user feel
processed and produces shallow answers; letting them talk surfaces most cells for free.

1. **Diverge.** Learn how the user works (tools, taste, what their projects are). Show
   the default profile and ask "this is the default — good as-is, or anything off?"

2. **Fast path — all defaults.** If the user says "just use the defaults" (or clearly
   has no strong preferences), skip the interview: copy the defaults into `.persona/`,
   confirm once, and hand off. Don't manufacture questions.

3. **Transition signal.** Otherwise, once you can draft 2+ cells from the conversation,
   or the user signals "let's build it," move to the gap interview.

4. **Gap interview — empty cells only, one at a time.** Don't re-ask cells already
   surfaced; just confirm ("so, Korean for output — right?"). Skip cells the default
   covers. One question per turn.

5. **Confirm.** Show the assembled persona (the 7 cells, defaults + overrides) and get
   an explicit OK before writing — the user should see what they're about to generate
   from, just like ticket-incubate shows the ticket before creating it.

6. **Write `.persona/`** (see schema/examples below), then hand off to
   `generate-workbench`. Don't keep digging — details can be refined after the
   workbench exists.

## `.persona/` schema + examples (the contract with generate)

Output is **temporary** (dot rule — infra scratch; generate consumes then deletes it):

```
.persona/
  overlay.md       # filled AGENTS.overlay.md — same sections as scaffold default
  codebases.yaml   # (optional) initial work targets — may be omitted
  meta.yaml        # where/how generate should place the workbench
```

**`.persona/overlay.md`** — the scaffold default with the user's overrides applied.
Only the changed cells need differ; keep the rest as default. Example (a Korean-output
user who otherwise took defaults):

```markdown
## Language
- Operational output language: **Korean** (ko). Framework stays English; filenames stable.

## slug style
- lowercase kebab, 2–4 words.

## Required issue elements
- Background · Goal · Done criteria · Out of scope.
  ... (remaining sections unchanged from default) ...
```

**`.persona/meta.yaml`** — tells generate where to create the workbench:

```yaml
# exactly one of `repo` or `path`
repo: owner/my-workbench      # create/use this GitHub repo
# path: ~/dev/my-workbench    # or a local path
language: ko                  # mirrors overlay Language (generate reads it directly)
```

**`.persona/codebases.yaml`** (optional) — initial targets, same format as the
framework's `codebases.yaml`:

```yaml
my-app: https://github.com/owner/my-app.git
```

## Boundaries

- Don't ask about the mechanism (core) — only taste (overlay).
- Output goes only to the disposable `.persona/` — no user repo is created yet (that's generate).
- Leaving mid-way is fine — re-invoke to resume from defaults.
