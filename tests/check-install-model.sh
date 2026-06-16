#!/usr/bin/env bash
# Regression test for the installed-plugin execution model (PR #1 review): the engine's
# utils must operate on the CALLER's workbench repo (cwd), not the plugin bundle they
# ship in. Guards against ROOT being resolved from $0 again.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$ROOT/plugins/workbench"
SCAFFOLD="$ROOT/plugins/workbench-kit/scaffold"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/wb-install-model.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT

wb="$tmp/wb"; mkdir -p "$wb"; git -C "$wb" init -q
cp -R "$SCAFFOLD/docs" "$wb/docs"
cp "$SCAFFOLD/codebases.yaml" "$wb/codebases.yaml"

# docs check must inspect the caller's docs/, not the plugin's (which has none)
out="$(cd "$wb" && CLAUDE_PLUGIN_ROOT="$ENGINE" "$ENGINE/utils/docs" check 2>&1)" \
  || { echo "FAIL: docs check errored: $out" >&2; exit 1; }
echo "$out" | grep -q 'docs check' || { echo "FAIL: unexpected docs check output: $out" >&2; exit 1; }

# setup must read the caller's codebases.yaml and never write into the plugin bundle
( cd "$wb" && CLAUDE_PLUGIN_ROOT="$ENGINE" "$ENGINE/utils/workbench" setup >/dev/null 2>&1 ) \
  || { echo "FAIL: setup errored" >&2; exit 1; }
[ ! -e "$ENGINE/.codebases" ] || { echo "FAIL: setup polluted the plugin bundle" >&2; exit 1; }

echo "✔ install-model: engine utils operate on the caller repo, not the plugin bundle"
