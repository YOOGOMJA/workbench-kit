#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for manifest in \
  "$ROOT/.claude-plugin/plugin.json" \
  "$ROOT/.codex-plugin/plugin.json"; do
  [ -f "$manifest" ] || fail "missing manifest: ${manifest#$ROOT/}"
done

python3 - "$ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
claude = json.loads((root / ".claude-plugin/plugin.json").read_text())
codex = json.loads((root / ".codex-plugin/plugin.json").read_text())

for name, manifest in (("Claude", claude), ("Codex", codex)):
    assert manifest["name"] == "toolbox", f"{name} manifest name must be toolbox"
    assert manifest["version"] == "0.1.1", f"{name} manifest must join lockstep 0.1.1"

assert codex["skills"] == "./skills/", "Codex manifest must expose toolbox skills"
PY

[ -x "$ROOT/bin/toolbox" ] || fail "bin/toolbox is missing or not executable"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/toolbox-packaging.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q

out="$(cd "$tmp" && CLAUDE_PLUGIN_ROOT="$ROOT" "$ROOT/bin/toolbox" help)" \
  || fail "dispatcher help failed"

grep -q '^usage: toolbox ' <<<"$out" || fail "dispatcher did not print toolbox usage"
grep -q 'product' <<<"$out" || fail "dispatcher help omitted product commands"
grep -q 'scenario' <<<"$out" || fail "dispatcher help omitted scenario commands"
grep -q 'portfolio' <<<"$out" || fail "dispatcher help omitted portfolio commands"

echo "PASS: toolbox packaging and dispatcher"
