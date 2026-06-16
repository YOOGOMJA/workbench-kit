#!/usr/bin/env bash
# check-version-sync.sh — assert every plugin manifest carries the same version.
# The version lives in 4 files; this guards against drift (in CI and before a release).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

vers="$(grep -rhoE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' \
  "$ROOT"/plugins/*/.claude-plugin/plugin.json \
  "$ROOT"/plugins/*/.codex-plugin/plugin.json \
  | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/' | sort -u)"

count="$(printf '%s\n' "$vers" | grep -c .)"
if [ "$count" -ne 1 ]; then
  echo "✘ version drift across plugin manifests:" >&2
  printf '%s\n' "$vers" >&2
  echo "run scripts/bump-version.sh <X.Y.Z> to sync" >&2
  exit 1
fi
echo "✔ all plugin manifests at version $vers"
