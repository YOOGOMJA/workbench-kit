# Workbench Schema — Framework Core

> **This file is the fixed framework core (workbench-kit) — do not edit it directly.**
> Framework upgrades overwrite this file. Put your own rules in `AGENTS.overlay.md`.
> The operative source of truth is the composed `AGENTS.md`; composition is done by
> the bootstrap (`workbench-kit:generate-workbench`).
>
> Only rules that a script reads/enforces, plus the harvest/wiki/lifecycle mechanism,
> live here (see the framework decision "persona vs framework rule boundary").
>
> **Language**: this framework content is English. The language of *operational
> output* (prose, commits, issue/PR bodies, your `docs/`, the composed `AGENTS.md`
> prose) follows `AGENTS.overlay.md`'s `language`. Filenames and identifiers stay
> stable regardless.

## Core principles

- **Work is disposable, knowledge accumulates.** All of a task happens on its task
  branch; at the end `task/` is cleaned up and the branch is **squash-merged**, so
  main history keeps one refined increment commit. (Squash is structural, not taste.)
- **Two layers.** Judgment (what to extract, prose) is the agent's; plumbing (git
  state transitions) is `utils/`'s.
  - **The agent's entry point is always a skill** (`workbench:task-start`, etc.).
    Call scripts directly only from within a skill procedure.
  - **Scripts never write prose.** Reader-facing text (PR titles/bodies) is authored
    by the judgment layer and passed in.
  - The lifecycle comment `utils/task` writes to an issue is a fixed-schema machine
    event — ticket disposition, status classification, and reader prose stay with
    skills / human gates.
- **The record is the source of truth; names are defaults.** Don't reverse-parse
  branch/dir names — read `task/index.md`.

## Glossary (concepts — fixed)

| Term | Meaning |
|---|---|
| **task** | A unit of work started from one issue. Lives as branch + workspace + `task/`. |
| **task workspace** | One worktree under `.worktrees/`, where a task lives. |
| **codebase** | A target external project. Clone cache `.codebases/`, working copy `task/codebases/`. |
| **increment** | What survives a task and merges to main. |
| **cleanup** | The commit that deletes tracked `task/` files just before submit. |
| **home** | Where an issue lives. Immutable; part of the branch name. |
| **umbrella issue** | An issue spanning multiple repos from the start. |
| **dot rule** | Dot-prefixed dirs are infrastructure — don't work inside them. |

> Concepts are fixed; the *words* are persona. But identifiers used by `utils`
> (`task/`, `docs/`, op vocabulary) cannot be renamed.

## Naming (structure fixed; style in overlay)

| Target | Rule |
|---|---|
| task ID | workbench issue `42`, codebase issue `repo#42` |
| workbench branch | `task/[home/][parent/]<issue>-<slug>` |
| task workspace | branch name with `/` → `__`, under `.worktrees/` |
| codebase branch | default `task/[parent/]<issue>-<slug>`, repo's own convention wins |
| codebase working copy | `task/codebases/<repo-name>/` |

- Segment parsing: pure digits = issue number, non-digit = home. Repo names can't be pure digits.
- **slug style** (word count, case, language) is persona → see `AGENTS.overlay.md`.

## task/ meta-file rules (fixed — enforced by `workbench task check`)

| File | Nature | Update |
|---|---|---|
| `WHITE_PAPER.md` | foundation, immutable (issue original preserved) | **immutable** |
| `index.md` | identity (frontmatter) + purpose + repos | on repo change |
| `status.md` | current snapshot | **full overwrite** (every time you pause) |
| `log.md` | work history | **append only** |
| `AGENTS.md` | how to work inside the task (standalone) | instantiated by task-start |
| `docs/researches/`,`docs/plans/` | disposable | create·update·delete |
| `docs/decisions/`,`docs/lessons/` | harvest | immut+supersede |
| `docs/runbooks/` | harvest | living-edit |

- log entry format (fixed): `## [YYYY-MM-DD HH:MM:SS] <op> · <action> <path> | <summary>`
  (op: plan·research·decide·lesson·code·review / action: create·update·delete)
- **Change → `workbench task commit <op> <action> [path] -m …`** (log+commit+push atomic).
- **Pause → overwrite status + push** (multi-device handoff).
- `task/codebases/` is gitignored. Code syncs via each codebase branch's push.

## Extraction criteria (submit judgment)

Worth promoting: reusable decisions · patterns and methods · failure lessons ·
framework improvements. Not promoted: task-local context (disposable) · what belongs
in the codebase's own docs (its PR) · what's re-derivable.

## docs/ wiki rules (fixed)

```
docs/  index.md  log.md
  decisions/ index.md(anchor table: topic|choice|status|→page)  NNNN-<slug>.md
  lessons/   index.md(approach|line|→page)  <slug>.md
  runbooks/  index.md(task|line|→page)  <slug>.md
  <synthesis>.md
```

- Three operations: **Query** (docs→task) · **Ingest** (task→docs) · **Lint** — independent skills.
- entry format follows `templates/*.tmpl.md` (field content is persona).
- **typed edge**: a `relation:` field with `<type> [[target]]`. Closed vocab —
  `supersedes`·`contradicts`·`extends`·`response-to`.
- **provenance**: each entry carries its source.
- **idempotent**: identity = (genre, anchor). Ingest = lookup-then-update (no dup rows). Structure only.
- On add/move a page, update `index.md` in the same commit.
- docs changes append to `docs/log.md` (op: extract·lint·edit).
- `*/log.md` merge via `.gitattributes merge=union`.

## Workflow and commands (fixed)

| Stage | Entry point | Plumbing |
|---|---|---|
| ideate | `workbench:ticket-incubate` | `gh issue create` |
| start | `workbench:task-start <ID>` | `workbench task start`, `add-repo` |
| status | `workbench:task-status` / `task-tickets` | `workbench task status`/`tickets` (read-only) |
| record | (every change) | `workbench task commit …` |
| check | (anytime) | `workbench task check` (silent when clean) |
| submit | `workbench:task-submit` | `workbench task submit` |
| done | `workbench:task-done <ID>` | `workbench task done` |

- **Merge is squash-only** (enforced by repo setting). Plain merge leaves intermediate commits on main.
- **Human gates (existence is fixed)**: after PR ("merge vs clean up"), after cleanup
  ("ticket disposition"), and increment absorption — **always ask the human**. Scripts
  don't touch tickets. (Which gates to keep is a persona toggle → overlay.)
- Issue body format, PR body skeleton, and label policy are persona → see
  `AGENTS.overlay.md` and `.github/` templates.
