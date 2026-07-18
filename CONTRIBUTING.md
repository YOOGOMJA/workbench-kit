# Contributing to workbench-kit

Thanks for helping! This repo is a marketplace of three plugins (`workbench`,
`workbench-kit`, and the optional `toolbox`). A few conventions keep it releasable.

## Changelog — every behavior change, at PR time, by semver

[`CHANGELOG.md`](CHANGELOG.md) is the single source of truth for release notes
([Keep a Changelog](https://keepachangelog.com/) format). **Every PR that changes
behavior adds a line under `## [Unreleased]`**, in the right bucket, classified by
its [Semantic Versioning](https://semver.org/) impact:

| Bucket | Meaning | Version bump it implies |
|---|---|---|
| **Added** | new capability | **minor** |
| **Changed** | behavior change, non-breaking | **minor** |
| **Fixed** | bug fix, non-breaking | **patch** |
| **Removed** / any breaking change | incompatible change | **major** |

Note the plugin (`workbench` / `workbench-kit` / `toolbox`) when an entry is
plugin-specific.
The next release bump is the **highest** impact among the `[Unreleased]` entries —
so classifying at PR time means the bump is derivable, not guessed (see
[RELEASING.md](RELEASING.md)).

CI enforces this: a PR with no `[Unreleased]` entry fails the **CHANGELOG entry**
check. If a PR genuinely needs no entry (CI-only, a typo, docs polish), add the
**`skip-changelog`** label.

## Tests & CI

CI (`.github/workflows/ci.yml`) is dependency-light. The same deterministic root
suite used by release preparation covers repository contracts plus every registered
plugin test, including the v1/v2 engine, optional toolbox, and governed upgrades.
CI also exercises upgrades on the latest Python and runs the CHANGELOG checks above.
Run the shared suite locally before pushing:

```
bash tests/run.sh
```

Authoritative plugin validation (`claude plugin validate`) and an isolated real
Codex marketplace add/list need their respective CLIs, so they remain local
release gates.

## Releases

See [RELEASING.md](RELEASING.md). In short: promote `## [Unreleased]`, run
`scripts/release.sh prepare X.Y.Z`, commit and permanently tag the evidence source,
then run `scripts/release.sh finalize X.Y.Z`. Commit the receipt, merge the PR, and let
the release workflow cut the `vX.Y.Z` tag + GitHub Release.
