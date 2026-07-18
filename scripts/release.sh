#!/usr/bin/env bash
# release.sh <X.Y.Z> — release prep after CHANGELOG promotion: validate the notes, bump
# every manifest, and run the checks. It does NOT commit, tag, or push. Full procedure:
# RELEASING.md.
set -euo pipefail
V="${1:-}"
[ -n "$V" ] || { echo "usage: release.sh <X.Y.Z>" >&2; exit 2; }
echo "$V" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-.].+)?$' || { echo "not a semver: $V" >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bash scripts/check-release-contract.sh --changelog-only "$V" >/dev/null

echo "== bump =="      ; bash scripts/bump-version.sh "$V"
echo "== checks =="
bash tests/run.sh

cat <<NEXT

next:
  1) commit, open a PR, and merge to main
     -> .github/workflows/release.yml auto-tags v$V and cuts the GitHub Release
        from the CHANGELOG section. No manual tagging.
NEXT
