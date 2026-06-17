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
- **`scaffold/`** (bundled in the `workbench-kit` plugin) — what `generate-workbench`
  lays into a user repo: overlay defaults, `AGENTS.core.md`, templates, `.github`, empty
  `docs/`, `codebases.yaml`.
- **`tests/`** — `check-skill-frontmatter.sh` (malformed YAML frontmatter),
  `check-install-model.sh` (engine utils target the caller repo, not the plugin bundle),
  plus the engine `task-lifecycle.sh`.
- **CI** (`.github/workflows/ci.yml`) — frontmatter lint, JSON manifest parse, version
  sync, ShellCheck, engine lifecycle test, install-model test, compose smoke.
- **Release tooling** — `AGENTS.md` (repo/dev guide), `RELEASING.md`, this changelog,
  `scripts/release.sh` (one-shot), `scripts/bump-version.sh`, `scripts/check-version-sync.sh`.
- **Auto-deploy** — `.github/workflows/release.yml` cuts the tag + GitHub Release
  automatically when a version bump (matching a `CHANGELOG` section) lands on `main`. No
  manual tagging.
- **README** — generated-workbench structure diagram (EN/KO) and repo layout reflecting
  scaffold bundled inside the bootstrap plugin; Codex install uses `codex plugin add`.

### Fixed

- **Generated workbench self-bootstraps.** `generate-workbench` now writes a real
  `CLAUDE.md` (not a symlink, so it survives every platform) and a `.claude/settings.json`
  that registers the marketplace and enables the `workbench` engine plugin on folder trust
  — no manual install. `workbench docs check` now resolves the caller's worktree
  (`--show-toplevel`) so checks on a task branch aren't skipped (PR #3 review). `workbench setup` likewise reads the caller's worktree manifest, and `release.sh` runs the lifecycle test on its own line so a failure aborts the release (PR #5 review).
- **Installed-plugin execution model** (PR #1 review). The engine now operates on the
  caller's workbench repo, not the plugin bundle: `scaffold/` (with `AGENTS.core.md`) moved
  inside the `workbench-kit` plugin so it's packaged on install; `workbench setup` and
  `workbench docs` resolve their root from the current repo (git) instead of the script's
  own path.

### Known gaps

- **Translation in progress.** Framework-facing content (README, `AGENTS.core`, scaffold,
  bootstrap skills) and all skill *descriptions* are English. The engine skill *bodies*
  and `framework-docs/` are still Korean — to be translated incrementally.

[Unreleased]: https://github.com/YOOGOMJA/workbench-kit/commits/main
