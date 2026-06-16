#!/usr/bin/env bash
# bump-version.sh <X.Y.Z> — sync the version across every plugin manifest (Claude Code
# + Codex) in one shot. The version lives in 4 places (2 plugins × 2 tool manifests);
# bumping by hand drifts, so do it mechanically. Run from anywhere in the repo.
set -euo pipefail

V="${1:-}"
[ -n "$V" ] || { echo "usage: bump-version.sh <X.Y.Z>" >&2; exit 2; }
echo "$V" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-.].+)?$' \
  || { echo "not a semver: $V" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
n=0
while IFS= read -r -d '' f; do
  grep -q '"version"' "$f" || continue
  sed -i.bak -E 's/("version"[[:space:]]*:[[:space:]]*)"[^"]*"/\1"'"$V"'"/' "$f"
  rm -f "$f.bak"
  echo "  $V  ${f#"$ROOT"/}"
  n=$((n + 1))
done < <(find "$ROOT/plugins" \( -path '*/.claude-plugin/plugin.json' -o -path '*/.codex-plugin/plugin.json' \) -print0)

echo "bumped $n manifest(s) to $V"
echo "next: update CHANGELOG.md, commit, then tag (see RELEASING.md)"
