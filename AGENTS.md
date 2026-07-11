# workbench-kit — repo guide (for agents/contributors working ON the kit)

This repo is the **source + marketplace** for three plugins. It is **not** itself a
workbench you run tasks in — it ships the framework others install. (A user's *generated*
workbench has its own composed AGENTS.md; this file is for hacking on the kit.)

## Layout

- `plugins/workbench/` — engine plugin: `utils/` (plumbing), `skills/`, `bin/`, `tests/`
- `plugins/workbench-kit/` — bootstrap plugin: `interview`/`generate` skills + `scaffold/`
  (the scaffold, incl. `AGENTS.core.md`, ships **inside** this plugin so it's packaged on install)
- `plugins/toolbox/` — optional product-delivery plugin: caller-owned product/scenario state,
  governed workflow skills, deterministic CLI, schemas, templates, and tests
- `framework-docs/` — design rationale (reference)
- `scripts/`, `tests/`, `.github/workflows/` — repo tooling, CI, release

## Develop

- Validate (authoritative): `claude plugin validate --strict` on the marketplace and each of
  `plugins/workbench`, `plugins/workbench-kit`, and `plugins/toolbox`
- Tests (the same dependency-light suite used by CI and release prep): `bash tests/run.sh`
  (requires `uv`; CI pins Python 3.9 and also exercises governed upgrades on latest Python)

## Release & versioning (self-contained — keep it this way)

- **One semver across all three plugins**, living in 6 manifests. Never hand-edit — use the scripts.
- Cut a release (**GitOps — no manual tagging**): `scripts/release.sh X.Y.Z` (bumps all
  manifests, runs checks), update `CHANGELOG.md`, then merge to `main`. The push to `main`
  triggers `.github/workflows/release.yml`, which auto-tags `vX.Y.Z` and cuts the GitHub
  Release from the CHANGELOG section.
- Full procedure and rationale: **[RELEASING.md](RELEASING.md)**. Changelog: **[CHANGELOG.md](CHANGELOG.md)**.

## Language

Framework content here is English; a generated workbench's *output* language follows its
`persona.language`. (Engine skill bodies + `framework-docs/` translation is in progress —
see CHANGELOG "Known gaps".)
