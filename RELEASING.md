# Releasing workbench-kit

workbench-kit is a **marketplace repo** hosting three plugins (`workbench`,
`workbench-kit`, and the optional `toolbox`). Users install from this repo's
default branch, so a release is: prepare the version and notes on a branch → merge
to `main` → let the release workflow tag and publish it.

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

1. **Promote `## [Unreleased]` on a branch:** rename it to
   `## [X.Y.Z] - YYYY-MM-DD` and add a fresh empty `## [Unreleased]` above it.
2. **Prepare:** run `scripts/release.sh prepare X.Y.Z`. It validates the dated notes, bumps
   all 6 manifests, and runs only receipt-independent manifest/release checks.
3. **Commit the evidence source:** review and commit the prepared version plus every intended
   engine/evidence change. Record its full commit ID; this intermediate commit stays on the
   release branch and will be folded by the final squash merge.
4. **Preserve the source revision:** create lightweight tag
   `workbench-equivalence-vX.Y.Z` at that exact commit and push it to `origin`. This tag is
   permanent evidence: never move, reuse, or delete it. The receipt checker requires the
   version-matched tag to resolve to its recorded source commit, so task-branch deletion
   cannot make the audit object disappear.
5. **Finalize:** run `scripts/release.sh finalize X.Y.Z`. It fetches the remote evidence tag,
   refuses checked-out engine/evidence drift, generates the source-bound equivalence receipt
   from that tag, and runs the complete repository suite.
6. **Verify locally:** run `claude plugin validate --strict` on the marketplace and all
   three plugins, then add/list the local marketplace in an isolated Codex home. CI runs
   the dependency-light shared suite, but these real CLI gates stay local. A release that
   changes the `workbench` plugin or its embedded-engine coverage must use the tagged source
   revision above and pass its offline manifest audit.
7. **Commit + PR + merge to `main`** (`chore(release): vX.Y.Z`). Commit the generated
   receipt. Install resolves against
   the default branch, so the work must be on `main` to be installable.
8. **Automatic.** On that push to `main`, `.github/workflows/release.yml` sees the new
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
