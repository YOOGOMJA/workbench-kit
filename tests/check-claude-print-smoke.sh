#!/usr/bin/env bash
# Optional Claude Code print-mode smoke test.
#
# This is intentionally not part of the default deterministic CI path. It calls
# the model and therefore depends on auth, network, budget, and model behavior.
# Set RUN_CLAUDE_PRINT=1 to run it locally as a plugin-load diagnostic.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$ROOT/plugins/workbench"

if [ "${RUN_CLAUDE_PRINT:-}" != "1" ]; then
  echo "skip: set RUN_CLAUDE_PRINT=1 to run Claude print smoke"
  exit 0
fi

command -v claude >/dev/null 2>&1 || {
  echo "skip: claude CLI not found"
  exit 0
}

[ -x "$ENGINE/bin/workbench" ] || {
  echo "FAIL: missing executable: $ENGINE/bin/workbench" >&2
  exit 1
}

prompt='Use Bash to run `plugins/workbench/bin/workbench --help` from this repository. If the command exits 0 and its output contains `usage: workbench`, answer exactly `OK` and nothing else. If not, answer exactly `FAIL` and nothing else.'

if ! out="$(
  cd "$ROOT"
  claude -p \
    --plugin-dir "$ENGINE" \
    --permission-mode bypassPermissions \
    --allowedTools "Bash(plugins/workbench/bin/workbench --help)" \
    --max-budget-usd "${CLAUDE_PRINT_MAX_BUDGET_USD:-0.25}" \
    "$prompt" 2>&1
)"; then
  echo "FAIL: claude -p command failed:" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

if [ "$out" != "OK" ]; then
  echo "FAIL: unexpected claude -p output:" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

echo "PASS claude print smoke"
