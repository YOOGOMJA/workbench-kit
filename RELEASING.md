# Releasing workbench-kit

workbench-kit is a **marketplace repo** hosting three plugins (`workbench`,
`workbench-kit`, and the optional `toolbox`). Users install from this repo's
default branch, so a release is: land on `main` → bump version → tag → write notes.

## Versioning

- One semantic version for the whole marketplace; all three plugins share it.
- **Fixed (lockstep) versioning, on purpose.** All plugins always release at the same
  version, even when a change touched only one. `workbench-kit` and `workbench` are a
  coupled set, while `toolbox` is optional but targets their public contract. Shipping one
  tested tuple avoids a cross-plugin compatibility matrix. The no-op bump for an unchanged
  plugin is an accepted cost. **Revisit only if they decouple** — if one plugin
  starts iterating on its own cadence and lockstep bumps become noise, split to
  independent per-plugin versions + `{name}--v{version}` tags.
- The version is **explicit** in each plugin manifest. Both tools fall back to the git
  commit SHA when `version` is omitted (every commit becomes a "new version") — we don't
  want that for a framework, so we set it and bump deliberately.
- It lives in 6 files (3 plugins × `.claude-plugin/plugin.json` + `.codex-plugin/plugin.json`).
  Don't edit them by hand — run `scripts/bump-version.sh <X.Y.Z>`.

## Cut a release

Releasing is **GitOps**: the release happens automatically when a version bump lands on
`main`. You never tag by hand.

1. **Prep on a branch:** `scripts/release.sh X.Y.Z` — bumps all 6 manifests and runs the
   checks. Then edit `CHANGELOG.md`: rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`
   and add a fresh empty `## [Unreleased]` above it.
2. **Verify locally:** run `claude plugin validate --strict` on the marketplace and all
   three plugins, then add/list the local marketplace in an isolated Codex home. CI runs
   the dependency-light shared suite, but these real CLI gates stay local.
3. **Commit + PR + merge to `main`** (`chore(release): vX.Y.Z`). Install resolves against
   the default branch, so the work must be on `main` to be installable.
4. **Automatic.** On that push to `main`, `.github/workflows/release.yml` sees the new
   version (matching `CHANGELOG [X.Y.Z]`, no `vX.Y.Z` tag yet) and **cuts the tag +
   GitHub Release** from the CHANGELOG section. Nothing else to do.

Non-release pushes to `main` are no-ops for the workflow (version already tagged, or no
matching CHANGELOG section).

### Released sections are frozen (in-flight PRs)

Once a `## [X.Y.Z]` section lands on `main`, `release.yml` publishes it — so that section
is **frozen**. A PR branched *before* a release cut still targets the old `## [Unreleased]`;
if it merges *after* the cut, its entry can drop into the now-published `## [X.Y.Z]`,
making the changelog claim a version shipped something its tag never had (this happened
once — see #21). So:

- New entries always go under `## [Unreleased]`, never a dated section.
- If your branch predates a release cut, **rebase onto `main`** before merging so your
  entry re-targets `## [Unreleased]`.
- CI enforces this: the `changelog-frozen` job (`scripts/check-changelog-section.sh`)
  fails any PR that adds a bullet to an already-released section.

## How users get the update

- **Claude Code:** `/plugin marketplace update workbench-kit`, then update `workbench`,
  `workbench-kit`, and `toolbox` when installed. New installs use
  `/plugin marketplace add YOOGOMJA/workbench-kit`.
- **Codex:** `codex plugin marketplace upgrade workbench-kit` (git source), then re-add /
  update the plugins.

## Release-notes management — the convention

- **`CHANGELOG.md` is the single source of truth**, repo-wide, Keep-a-Changelog format.
  Every PR that changes behavior adds a line under `## [Unreleased]` (Added / Changed /
  Fixed / Removed). Note the plugin if an entry is plugin-specific.
- **GitHub Releases mirror** the CHANGELOG section for each tag — don't hand-author
  separate notes; copy the section so the two never diverge.
- Keep entries user-facing (what changed for someone using the plugin), not commit logs.
