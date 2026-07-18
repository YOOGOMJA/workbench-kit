#!/usr/bin/env bash
# release.sh {prepare|finalize} <X.Y.Z> — two-phase lockstep release prep.
# It does NOT commit, tag, or push. Full procedure: RELEASING.md.
set -euo pipefail

COMMAND="${1:-}"
V="${2:-}"
case "$COMMAND" in
  prepare|finalize) ;;
  *) echo "usage: release.sh {prepare|finalize} <X.Y.Z>" >&2; exit 2 ;;
esac
[ -n "$V" ] || { echo "usage: release.sh {prepare|finalize} <X.Y.Z>" >&2; exit 2; }
printf '%s\n' "$V" \
  | grep -qE '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)([-+][0-9A-Za-z.-]+)?$' \
  || { echo "not a semver: $V" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TAG="workbench-equivalence-v$V"

case "$COMMAND" in
  prepare)
    bash scripts/check-release-contract.sh --changelog-only "$V" >/dev/null
    echo "== bump =="
    bash scripts/bump-version.sh "$V"
    echo "== pre-receipt checks =="
    bash tests/check-json-manifests.sh
    bash scripts/check-version-sync.sh
    bash tests/check-marketplace-parity.sh
    bash scripts/check-release-contract.sh "$V"

    cat <<NEXT

next:
  1) review and commit the prepared source revision
  2) preserve that exact commit, without moving or deleting the tag:
       git tag "$TAG" <full-source-commit>
       git push origin "refs/tags/$TAG"
  3) run: scripts/release.sh finalize $V
NEXT
    ;;
  finalize)
    bash scripts/check-release-contract.sh "$V" >/dev/null
    git fetch --quiet origin "refs/tags/$TAG:refs/tags/$TAG"
    REVISION="$(git rev-parse --verify "refs/tags/$TAG^{commit}")"
    echo "== equivalence receipt: $TAG -> $REVISION =="
    PYTHONDONTWRITEBYTECODE=1 python3 scripts/equivalence-receipt.py generate \
      --replacement-revision "$REVISION"
    echo "== full checks =="
    bash tests/run.sh

    cat <<NEXT

next:
  1) commit the generated receipt, open a PR, and merge to main
     -> .github/workflows/release.yml auto-tags v$V and cuts the GitHub Release
        from the CHANGELOG section. No manual release tagging.
NEXT
    ;;
esac
