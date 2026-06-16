# Changelog

All notable changes to workbench-kit are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims for
[Semantic Versioning](https://semver.org/).

This is one changelog for the whole marketplace (both the `workbench` and
`workbench-kit` plugins). When an entry touches only one plugin, it says which.
See [RELEASING.md](RELEASING.md) for how a release is cut.

## [Unreleased]

First release in progress (target: **0.1.0**). Everything below is the initial set.

### Added

- **`workbench` plugin (engine)** — task lifecycle skills (start/submit/done,
  docs query/ingest/lint, ticket-incubate, status/tickets, codebase-onboard, …),
  the `utils/` plumbing, and `bin/workbench` (on PATH when the plugin is enabled).
- **`workbench-kit` plugin (bootstrap)** — `interview-for-personalizing` (draws out
  your persona into a temporary `.persona/`) and `generate-workbench` (composes a
  minimal workbench repo via the bundled `scripts/compose.sh`, which self-checks its
  output).
- **Cross-tool packaging** — installs on both Claude Code (`.claude-plugin/`,
  `marketplace.json`) and Codex (`.codex-plugin/`, `.agents/plugins/marketplace.json`),
  sharing one `skills/` source. Load verified on both CLIs.
- **`AGENTS.core.md` (framework, fixed) + `AGENTS.overlay.md` (your persona)** split,
  composed into `AGENTS.md`. Framework content is English; `persona.language` governs
  operational output language.
- **`scaffold/`** — what `generate-workbench` lays into a user repo (overlay defaults,
  templates, `.github`, empty `docs/`, `codebases.yaml`).
- **`tests/check-skill-frontmatter.sh`** — lint guarding against malformed SKILL.md
  YAML frontmatter.

[Unreleased]: https://github.com/YOOGOMJA/workbench-kit/commits/main
