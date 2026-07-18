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
import ast
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
claude = json.loads((root / ".claude-plugin/plugin.json").read_text())
codex = json.loads((root / ".codex-plugin/plugin.json").read_text())

for name, manifest in (("Claude", claude), ("Codex", codex)):
    assert manifest["name"] == "toolbox", f"{name} manifest name must be toolbox"
    assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", manifest["version"]), (
        f"{name} manifest version must be semantic"
    )

assert claude["version"] == codex["version"], (
    "Claude and Codex manifests must use the same toolbox version"
)

assert codex["skills"] == "./skills/", "Codex manifest must expose toolbox skills"
assert codex["interface"] == {
    "displayName": "Toolbox",
    "shortDescription": "Governed product state and delivery workflows",
    "longDescription": "Optional workbench capability pack for product, scenario, and portfolio workflows.",
    "developerName": "YOOGOMJA",
    "category": "Developer Tools",
    "capabilities": ["Product state", "Portfolio inspection", "Workflow skills"],
    "defaultPrompt": "Use $product-start to initialize governed product state in this workbench.",
}

for path in sorted((root / "lib").glob("*.py")):
    ast.parse(path.read_text(), filename=str(path), feature_version=(3, 9))

for skill in sorted((root / "skills").iterdir()):
    if not skill.is_dir():
        continue
    metadata_path = skill / "agents" / "openai.yaml"
    assert metadata_path.is_file(), f"missing Codex metadata for {skill.name}"
    metadata = metadata_path.read_text()
    match = re.search(
        r'^\s*default_prompt:\s*"([^"]*)"\s*$', metadata, re.MULTILINE
    )
    assert match, f"missing default_prompt for {skill.name}"
    tokens = re.findall(r"\$[a-z0-9-]+", match.group(1))
    expected = f"${skill.name}"
    assert expected in tokens, (
        f"default_prompt for {skill.name} must contain exact token {expected}"
    )
PY

[ -x "$ROOT/bin/toolbox" ] || fail "bin/toolbox is missing or not executable"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/toolbox-packaging.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
rm -rf "$ROOT/lib/__pycache__"

out="$(cd "$tmp" && CLAUDE_PLUGIN_ROOT="$ROOT" "$ROOT/bin/toolbox" help)" \
  || fail "dispatcher help failed"

grep -q '^usage: toolbox ' <<<"$out" || fail "dispatcher did not print toolbox usage"
grep -q 'product' <<<"$out" || fail "dispatcher help omitted product commands"
grep -q 'scenario' <<<"$out" || fail "dispatcher help omitted scenario commands"
grep -q 'portfolio' <<<"$out" || fail "dispatcher help omitted portfolio commands"
[ ! -e "$ROOT/lib/__pycache__" ] || fail "dispatcher wrote Python bytecode into the plugin bundle"

echo "PASS: toolbox packaging and dispatcher"
