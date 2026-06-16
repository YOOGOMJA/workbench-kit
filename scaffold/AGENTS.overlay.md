# Workbench Schema — Persona Overlay

> **This file is your rules — edit it freely.**
> Framework upgrades never touch it. What lives here is *taste* — surface conventions
> a different team would reasonably set differently (machine-enforced rules live in
> `AGENTS.core.md`). After editing, recompose `AGENTS.md`.
>
> The values below are the **default profile**.
> `workbench-kit:interview-for-personalizing` drafts these from an interview, and
> `generate-workbench` bakes them in.

## Language

- Language for **operational output** — prose, commits, issue/PR bodies, your
  `docs/` content, and the composed `AGENTS.md` prose: **English** _(set to ko / ja / …)_
- This governs only what the workbench **produces**. The framework itself (skills,
  `AGENTS.core.md`) stays English. **Filenames and identifiers stay stable** regardless.

## slug style

- lowercase kebab-case, **2–4 words**, keep only the essence of the issue title.
  _(e.g., `fix-auth-redirect`. word count / separator to taste.)_

## Required issue elements

- **Background · Goal · Done criteria · Out of scope (this time)**.
- Canonical form: `.github/ISSUE_TEMPLATE/task.md` _(change elements there.)_
- A codebase issue defers to that repo's own template.

## PR body skeleton

- Skeleton: **Background · Goal · Verification · Notes · References** (drop empty sections).
- AI-authored PRs put a callout (`>`) at the top naming the authoring agent/model.
- Canonical form: `.github/PULL_REQUEST_TEMPLATE.md`.

## Label policy

- **priority only (P0–P3)** — the agent proposes, **the human confirms**. Not
  auto-assigned (cross-issue judgment).
- No type/area labels until they earn discriminating power and a consumer.
  _(varies per team — change the scheme here.)_

## harvest entry fields

- The field format of decision/lesson/runbook entries is defined by `templates/*.tmpl.md`.
  _(change fields there — structure (anchor, typed-edge) is fixed by core.)_

## Human-gate toggles

- Ask after PR (merge vs clean up): **on**
- Ask after cleanup (ticket disposition): **on**
- Ask before increment absorption: **on**
  _(gate *existence* is enforced by core; where to stop and ask is taste.)_

## Glossary words (optional)

- Map core concepts to your own words here.
  _(but identifiers used by utils — `task/`, `docs/`, op vocab — are immutable.)_
