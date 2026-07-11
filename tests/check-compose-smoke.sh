#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wbk-compose.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/persona"
printf '## Language\n- Operational output language: **English**.\n' \
  > "$TMP/persona/overlay.md"

bash "$ROOT/plugins/workbench-kit/skills/generate-workbench/scripts/compose.sh" \
  --persona "$TMP/persona" \
  --core "$ROOT/plugins/workbench-kit/scaffold/AGENTS.core.md" \
  --scaffold "$ROOT/plugins/workbench-kit/scaffold" \
  --out "$TMP/generated-workbench"

echo "OK compose smoke"
