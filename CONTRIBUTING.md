# Contributing to workbench-kit

Thanks for helping! This repo is a marketplace of two plugins (`workbench`,
`workbench-kit`). A few conventions keep it releasable.

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

Note the plugin (`workbench` / `workbench-kit`) when an entry is plugin-specific.
The next release bump is the **highest** impact among the `[Unreleased]` entries —
so classifying at PR time means the bump is derivable, not guessed (see
[RELEASING.md](RELEASING.md)).

CI enforces this: a PR with no `[Unreleased]` entry fails the **CHANGELOG entry**
check. If a PR genuinely needs no entry (CI-only, a typo, docs polish), add the
**`skip-changelog`** label.

## Tests & CI

CI (`.github/workflows/ci.yml`) is dependency-light and runs: skill-frontmatter
lint, JSON manifest parse, plugin version sync, ShellCheck, the engine lifecycle
test, the install-model test, the codebases.yaml parsing test, the compose smoke
test, and the CHANGELOG-entry check above. Run the shell tests locally before
pushing:

```
bash plugins/workbench/tests/task-lifecycle.sh
bash tests/check-codebases-yaml.sh
bash tests/check-install-model.sh
```

Authoritative plugin validation (`claude plugin validate`) needs the Claude Code
CLI, so it stays a local/manual gate.

## Releases

See [RELEASING.md](RELEASING.md). In short: land on `main`, bump the version
(`scripts/bump-version.sh X.Y.Z`), move `## [Unreleased]` to `## [X.Y.Z] - <date>`,
and the release workflow cuts the tag + GitHub Release.
