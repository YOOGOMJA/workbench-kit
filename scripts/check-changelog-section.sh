#!/usr/bin/env bash
set -euo pipefail

# Released CHANGELOG sections are frozen. Fail a PR that adds an entry under an
# already-released, dated `## [X.Y.Z]` heading (instead of `## [Unreleased]`).
#
# Why: releasing is GitOps — a dated section is published by release.yml the moment
# it lands on main. A PR branched before a release cut can merge afterwards and drop
# its entry into the now-published section, making the changelog claim a version
# shipped something its tag never had (see #21 / the #16 incident).
#
# A release-cut PR is fine: it *creates* a new dated section, which isn't in the base,
# so it isn't checked. Only sections that already exist on the base are frozen.
#
# Usage: check-changelog-section.sh <base-ref>

base="${1:?usage: check-changelog-section.sh <base-ref>}"
file="CHANGELOG.md"
[ -f "$file" ] || { echo "error: $file not found" >&2; exit 1; }

# Count top-level `- ` bullets inside the section whose heading is exactly $1.
count_bullets() {
  awk -v h="$1" '
    index($0, h) == 1 && $0 == h { insec = 1; next }
    insec && /^## \[/ { exit }
    insec && /^- /    { c++ }
    END { print c + 0 }
  '
}

base_changelog="$(git show "$base:$file" 2>/dev/null || true)"
[ -n "$base_changelog" ] || { echo "ok: no base CHANGELOG to compare against"; exit 0; }

fail=0
while IFS= read -r heading; do
  case "$heading" in
    '## [Unreleased]'*) continue ;;   # the only mutable section
  esac
  bc="$(printf '%s\n' "$base_changelog" | count_bullets "$heading")"
  nc="$(count_bullets "$heading" < "$file")"
  if [ "$nc" -gt "$bc" ]; then
    echo "error: CHANGELOG: a new entry was added under the already-released section" >&2
    echo "       '$heading' (bullets $bc -> $nc). Released sections are frozen —" >&2
    echo "       put new entries under '## [Unreleased]'. If this branch predates a" >&2
    echo "       release cut, rebase onto main first." >&2
    fail=1
  fi
done < <(printf '%s\n' "$base_changelog" | grep -E '^## \[')

[ "$fail" -eq 0 ] && echo "ok: no edits to released CHANGELOG sections"
exit "$fail"
