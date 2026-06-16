#!/usr/bin/env bash
# release.sh <X.Y.Z> — one-shot release prep: bump version across all manifests and run
# the checks. It does NOT commit, tag, or push — it prints those steps for you to do on
# main. Keeps releasing self-contained in the repo. Full procedure: RELEASING.md.
set -euo pipefail
V="${1:-}"
[ -n "$V" ] || { echo "usage: release.sh <X.Y.Z>" >&2; exit 2; }
echo "$V" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-.].+)?$' || { echo "not a semver: $V" >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

grep -q '## \[Unreleased\]' CHANGELOG.md || { echo "CHANGELOG.md has no [Unreleased] section" >&2; exit 1; }

echo "== bump =="      ; bash scripts/bump-version.sh "$V"
echo "== checks =="
bash scripts/check-version-sync.sh
bash tests/check-skill-frontmatter.sh
bash tests/check-install-model.sh
bash plugins/workbench/tests/task-lifecycle.sh >/dev/null && echo "✔ lifecycle test"

cat <<NEXT

next:
  1) CHANGELOG.md: rename '## [Unreleased]' -> '## [$V] - $(date +%F)', add a fresh [Unreleased]
  2) commit, open a PR, and merge to main
     -> .github/workflows/release.yml auto-tags v$V and cuts the GitHub Release
        from the CHANGELOG section. No manual tagging.
NEXT
