# Changelog

All notable changes to workbench-kit are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims for
[Semantic Versioning](https://semver.org/).

This is one changelog for the whole marketplace (both the `workbench` and
`workbench-kit` plugins). When an entry touches only one plugin, it says which.
See [RELEASING.md](RELEASING.md) for how a release is cut.

## [Unreleased]

_Nothing yet._

## [0.1.0] - 2026-06-17

First release. Everything below is the initial set.

### Added

- **README demo GIFs** — `demo/` holds two recorded walkthroughs (a real Claude Code
  agent driving the skills, offline): `workbench-engine.gif` (`/workbench:task-start`) and
  `workbench-kit-bootstrap.gif` (`/workbench-kit:interview-for-personalizing` →
  `generate-workbench`), embedded in the README, with the `.tape`/setup scripts for
  regeneration (part of #9).
- **CHANGELOG enforcement at PR time, by semver** — a CI `changelog` job fails any
  pull request that ships without a `## [Unreleased]` entry (`scripts/check-changelog.sh`),
  bypassable with the `skip-changelog` label. A new `CONTRIBUTING.md` documents the
  Keep-a-Changelog buckets and their semantic-versioning impact, so the next version bump
  is derivable rather than guessed (#4).
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

- **`workbench setup` validates `codebases.yaml` instead of silently misparsing**
  (`workbench` plugin). The line-based parser now rejects unsupported shapes — quotes,
  nested mappings, list syntax, inline comments, numeric names, value-less keys — with a
  clear, line-numbered error, while the supported `name: <git-url>` form (comments/blank
  lines allowed) still clones. Adds `tests/check-codebases-yaml.sh` to CI (#8).
- **`task done` no longer silently force-deletes an unmerged branch** (`workbench`
  plugin). It deleted the local branch with `branch -D ... 2>/dev/null || true`
  regardless of merge state, swallowing errors. It now deletes only when a **merged PR**
  is found (the right signal under squash-merge, where `git branch -d` misjudges pushed
  branches) or when `--force` is given; otherwise it refuses loudly and preserves the
  branch and its commits (#7).
- **`task` branch resolution now respects `parent`** (`workbench` plugin). `find_branches`
  matches on `(home, issue)` and, when given, `parent`, so two sub-tasks of the same issue
  under different parents no longer alias each other. `start`/`resume`/`done` take
  `--parent`; an ambiguous ID fails loudly with the candidates instead of silently acting
  on the first match (#6).
- **Generated workbench self-bootstraps.** `generate-workbench` now writes a real
  `CLAUDE.md` (not a symlink, so it survives every platform) and a `.claude/settings.json`
  that registers the marketplace and enables the `workbench` engine plugin on folder trust
  — no manual install. `workbench docs check` now resolves the caller's worktree
  (`--show-toplevel`) so checks on a task branch aren't skipped (PR #3 review). `workbench setup` likewise reads the caller's worktree manifest, and `release.sh` runs the lifecycle test on its own line so a failure aborts the release (PR #5 review).
- **Generated workbench git hygiene.** `generate-workbench` now carries scaffold
  `.gitignore` / `.gitattributes` into user repos, keeping `.codebases/`, `.worktrees/`,
  task codebase copies, and Claude runtime locks out of commits while preserving
  append-only logs with `merge=union`.
- **Installed-plugin execution model** (PR #1 review). The engine now operates on the
  caller's workbench repo, not the plugin bundle: `scaffold/` (with `AGENTS.core.md`) moved
  inside the `workbench-kit` plugin so it's packaged on install; `workbench setup` and
  `workbench docs` resolve their root from the current repo (git) instead of the script's
  own path.

### Changed

- **Flagship design doc translated to English** — `framework-docs/workbench-knowledge-ecosystem.md`
  is now English (the page the README links curious readers to); the Korean original is
  preserved as `workbench-knowledge-ecosystem.ko.md`, and the two cross-link (#9).

### Known gaps

- **Translation in progress.** Framework-facing content (README, `AGENTS.core`, scaffold,
  bootstrap skills, the knowledge-ecosystem design doc) and all skill *descriptions* are
  English. The engine skill *bodies* and the rest of `framework-docs/` are still Korean —
  to be translated incrementally.

[Unreleased]: https://github.com/YOOGOMJA/workbench-kit/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/YOOGOMJA/workbench-kit/releases/tag/v0.1.0
