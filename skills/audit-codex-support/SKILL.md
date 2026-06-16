---
name: audit-codex-support
description: >-
  Audit this workbench repository for Codex support issues. Use when a task
  changes or reviews AGENTS.md, README.md, skills/, .agents/skills,
  .claude/skills, .codex/, .worktrees/, .codebases/, .gitignore, slash-command
  wording, skill entrypoints, tool state files, stale docs links, or verification
  commands. Check whether Codex can operate safely and predictably in workbench,
  including guidance clarity, repo-local skill discovery, search noise, and
  explicit manual judgment boundaries.
---

# Audit Codex Support

Audit whether this workbench repo gives Codex enough durable, discoverable guidance to work safely across fresh sessions. Keep this audit workbench-specific; do not generalize it into a reusable readiness framework for unrelated repositories.

## Inputs

Inspect these surfaces first:

- `AGENTS.md`
- `README.md`
- `skills/`
- `.agents/skills`
- `.claude/skills`
- `.gitignore`
- `docs/index.md`
- `docs/decisions/index.md`
- `docs/lessons/index.md`
- `docs/runbooks/index.md`
- relevant `docs/` pages found through `rg`
- active task metadata when running inside `.worktrees/task__*/task/`

Prefer tracked, canonical files over generated or ignored state. Do not treat `.worktrees/` or `.codebases/` as primary source unless the audit is specifically about search noise or task isolation.

## Checklist

### 1. Instruction Discovery

- Confirm `AGENTS.md` is the canonical repo guidance and is not contradicted by `CLAUDE.md`.
- Confirm nested task `task/AGENTS.md` is self-contained and does not rely on root inheritance.
- Check whether Codex-specific facts are presented as examples or discovery paths, while the repo's agent-neutral policy stays intact.
- Flag oversized or stale guidance that could make Codex miss critical rules.

### 2. Skill Discovery

- Confirm canonical skill sources live under `skills/`.
- Confirm `.agents/skills` points to the canonical `skills/` directory for Codex repo-local discovery.
- Confirm `.claude/skills` points to the same canonical source without becoming the source of truth.
- Check that skill descriptions front-load trigger terms; descriptions are the main implicit invocation surface.
- Flag skills that require scripts, references, or assets but do not document when to load or run them.

### 3. Entrypoint Wording

- Treat `/task-*`, `/docs-*`, and similar names as workbench skill entrypoint labels.
- Flag wording that implies every agent has actual slash commands with those exact names.
- Recommend wording that works for Codex: mention explicit skill invocation, natural-language requests, and the underlying `skills/<name>/SKILL.md` source.
- Keep the public docs concise; do not duplicate each skill's procedure in README.

### 4. Tool State and Ignore Rules

- Check `.claude/`, `.agents/`, and `.codex/` for generated state files.
- Confirm generated state is ignored or intentionally tracked.
- Confirm symlinks that are part of discovery are tracked and documented.
- Flag untracked generated files that would make a clean checkout look dirty.

### 5. Search Noise and Worktrees

- Confirm `.worktrees/` and `.codebases/` are ignored infrastructure.
- Check whether examples and commands encourage agents to search tracked sources first.
- Flag repo-wide search commands that will accidentally include task workspaces or codebase clones.
- Prefer `rg` over slower search tools, with explicit paths when possible.

### 6. Docs Links and Drift

- Check README and docs for links to removed pages.
- Use `utils/docs check` for deterministic docs markdown link and `[[wikilink]]` integrity when available.
- Check remaining `[[wikilinks]]` against existing pages when the link is meant to be resolved now.
- Distinguish intentional future-page markers from stale links.
- Flag docs that conflict with adopted decisions in `docs/decisions/index.md`.

### 7. Verification Surface

- Check whether there is a deterministic command for the thing being claimed.
- If validation remains manual, confirm the boundary is explicit.
- For skills, run `skill-creator` validation when available.
- For docs, prefer `utils/docs check`; if unavailable, run stale-link searches that match the audited drift.
- Report commands actually run and commands not available.

## Output

Lead with findings. Use this format:

```md
**Findings**
- [severity] [area] `path:line`: issue, impact, and concrete fix.

**Checked**
- Files and commands inspected.

**Verification**
- Commands run and results.
- Any checks not run, with reason.

**Next Actions**
- Required fixes first, optional improvements second.
```

Use `critical`, `high`, `medium`, or `low` severity. Prefer concrete file references and avoid broad advice without an actionable change.
