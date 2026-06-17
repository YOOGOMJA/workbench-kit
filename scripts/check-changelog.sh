#!/usr/bin/env bash
set -euo pipefail

# Fail a PR that ships a change without a CHANGELOG "## [Unreleased]" entry.
# Usage: check-changelog.sh <base-ref>   (the PR's base commit/branch)
#
# The entry is classified by semantic-versioning impact at PR time (see CONTRIBUTING.md):
#   Added / Changed (non-breaking)  → minor
#   Fixed                            → patch
#   Removed / any breaking change    → major
# PRs that genuinely need no entry (CI-only, typo) bypass this via the
# 'skip-changelog' label (handled in the workflow, not here).

base="${1:?usage: check-changelog.sh <base-ref>}"
file="CHANGELOG.md"

[ -f "$file" ] || { echo "error: $file not found" >&2; exit 1; }
grep -q '^## \[Unreleased\]' "$file" \
  || { echo "error: $file has no '## [Unreleased]' section" >&2; exit 1; }

# Any added list entry in CHANGELOG.md relative to the base counts.
added="$(git diff "$base" -- "$file" | grep -E '^\+( *- |  +)' || true)"
if [ -z "$added" ]; then
  cat >&2 <<'MSG'
error: this PR adds nothing under CHANGELOG.md "## [Unreleased]".

Add a one-line entry there, in the right Keep-a-Changelog bucket, classified by
its semantic-versioning impact:

  - Added / Changed (non-breaking)  -> minor
  - Fixed                            -> patch
  - Removed / any breaking change    -> major

Note the plugin if the change is plugin-specific. If this PR genuinely needs no
entry (CI-only, a typo, etc.), add the 'skip-changelog' label.
MSG
  exit 1
fi

echo "ok: CHANGELOG [Unreleased] updated"
