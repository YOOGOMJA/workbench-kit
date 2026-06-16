# Releasing workbench-kit

workbench-kit is a **marketplace repo** hosting two plugins (`workbench`,
`workbench-kit`). Users install from this repo's default branch, so a release is:
land on `main` → bump version → tag → write notes.

## Versioning

- One version for the whole marketplace; both plugins share it (simpler than tracking
  two cadences for one repo). Semantic versioning.
- The version is **explicit** in each plugin manifest. Both tools fall back to the git
  commit SHA when `version` is omitted (every commit becomes a "new version") — we don't
  want that for a framework, so we set it and bump deliberately.
- It lives in 4 files (2 plugins × `.claude-plugin/plugin.json` + `.codex-plugin/plugin.json`).
  Don't edit them by hand — run `scripts/bump-version.sh <X.Y.Z>`.

## Cut a release

1. **Land the work on `main`.** Install resolves against the default branch, so unmerged
   branches aren't installable. Merge via PR.
2. **Bump:** `scripts/bump-version.sh X.Y.Z` (syncs all 4 manifests).
3. **Notes:** in `CHANGELOG.md`, rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`
   and start a fresh empty `## [Unreleased]` above it.
4. **Verify:** `claude plugin validate plugins/workbench` and `… plugins/workbench-kit`,
   and `tests/check-skill-frontmatter.sh`.
5. **Commit:** `chore(release): vX.Y.Z` on `main`.
6. **Tag** (per plugin — Claude Code's convention is `{name}--v{version}`, validated
   against the manifest):
   ```
   claude plugin tag plugins/workbench      --push -m "workbench %s"
   claude plugin tag plugins/workbench-kit  --push -m "workbench-kit %s"
   ```
7. **GitHub Release:** create a release for the tag(s) and paste the CHANGELOG section as
   the body. This is the human-facing release note; the CHANGELOG is the source of truth.

## How users get the update

- **Claude Code:** `/plugin marketplace update workbench-kit`, then `/plugin update workbench`
  (and `workbench-kit`). New installs: `/plugin marketplace add YOOGOMJA/workbench-kit`.
- **Codex:** `codex plugin marketplace upgrade workbench-kit` (git source), then re-add /
  update the plugins.

## Release-notes management — the convention

- **`CHANGELOG.md` is the single source of truth**, repo-wide, Keep-a-Changelog format.
  Every PR that changes behavior adds a line under `## [Unreleased]` (Added / Changed /
  Fixed / Removed). Note the plugin if an entry is plugin-specific.
- **GitHub Releases mirror** the CHANGELOG section for each tag — don't hand-author
  separate notes; copy the section so the two never diverge.
- Keep entries user-facing (what changed for someone using the plugin), not commit logs.
