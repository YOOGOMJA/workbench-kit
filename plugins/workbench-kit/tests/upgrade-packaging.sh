#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

[ -x "$PLUGIN_ROOT/bin/workbench-kit" ] || {
  echo "packaged upgrade CLI is not executable" >&2
  exit 1
}

PYTHONDONTWRITEBYTECODE=1 python3 - "$PLUGIN_ROOT" "$REPO_ROOT" <<'PY'
import json
import pathlib
import sys

plugin = pathlib.Path(sys.argv[1])
repo = pathlib.Path(sys.argv[2])

required = {
    ".claude-plugin/plugin.json",
    ".codex-plugin/plugin.json",
    "bin/workbench-kit",
    "receipts/upgrade-runtime.json",
    "skills/upgrade-workbench/SKILL.md",
    "skills/upgrade-workbench/agents/openai.yaml",
    "skills/upgrade-workbench/references/cli.md",
}
required.update({
    "schemas/bootstrap-authority-approval.schema.json",
    "schemas/generation-receipt.schema.json",
    "schemas/generator-receipt.schema.json",
    "schemas/migration-receipt.schema.json",
    "schemas/plugin-equivalence.schema.json",
    "schemas/removal-approval.schema.json",
    "schemas/reviewed-overlay.schema.json",
    "schemas/upgrade-journal.schema.json",
    "schemas/upgrade-plan.schema.json",
    "schemas/upgrade-result.schema.json",
})
missing = sorted(path for path in required if not (plugin / path).is_file())
assert not missing, missing

claude_manifest = json.loads(
    (plugin / ".claude-plugin/plugin.json").read_text(encoding="utf-8")
)
codex_manifest = json.loads(
    (plugin / ".codex-plugin/plugin.json").read_text(encoding="utf-8")
)
assert claude_manifest["name"] == codex_manifest["name"] == "workbench-kit"
assert claude_manifest["version"] == codex_manifest["version"]
assert codex_manifest["skills"] == "./skills/"
assert "upgrade" in claude_manifest["description"].lower()
assert "upgrade" in codex_manifest["description"].lower()
assert codex_manifest["interface"]["displayName"] == "Workbench Kit"
assert "$upgrade-workbench" in codex_manifest["interface"]["defaultPrompt"]

runtime = json.loads(
    (plugin / "receipts/upgrade-runtime.json").read_text(encoding="utf-8")
)
assert runtime["contract_version"] == "workbench-kit-upgrade-runtime/v1"
assert runtime["plugin_equivalence_file"] is None
assert runtime["legacy_engine_markers"] == sorted(
    runtime["legacy_engine_markers"]
)

skill = (plugin / "skills/upgrade-workbench/SKILL.md").read_text(
    encoding="utf-8"
)
cli = (plugin / "skills/upgrade-workbench/references/cli.md").read_text(
    encoding="utf-8"
)
surface = skill + "\n" + cli
for required_text in (
    "--workspace",
    "upgrade-workbench",
    "--dry-run",
    "--apply",
    "--plan-file",
    "--authority-approval-file",
    "--reviewed-overlay-file",
    "--remove-embedded-engine",
    "--removal-approval-file",
    "--journal-dir",
    "--format json",
    "implicit-v1",
    "staged-v2",
    "current-v2",
    "plugin-equivalence-unavailable",
):
    assert required_text in surface, required_text
assert "--authority-file" not in surface
assert "generator-composition-invalid" in skill
assert "human-supplied reviewed-overlay" in skill
assert "All other `malformed`" in skill

changelog = (repo / "CHANGELOG.md").read_text(encoding="utf-8")
unreleased = changelog.split("## [Unreleased]", 1)[1].split("\n## [", 1)[0]
assert "upgrade-workbench" in unreleased
assert "#27" in unreleased
PY

bash "$REPO_ROOT/tests/check-skill-frontmatter.sh"
"$PLUGIN_ROOT/bin/workbench-kit" --help | grep -q 'upgrade-workbench'

echo "PASS: packaged upgrade CLI, skill, contracts, and fail-closed runtime inventory"

if find "$PLUGIN_ROOT" -type d -name __pycache__ -print -quit | grep -q .; then
  echo "Python bytecode cache escaped upgrade tests" >&2
  exit 1
fi
