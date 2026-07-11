#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/product-start/SKILL.md"
AGENT="$ROOT/skills/product-start/agents/openai.yaml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$SKILL" ] || fail "missing product-start skill"
[ -f "$AGENT" ] || fail "missing Codex skill interface metadata"

python3 - "$SKILL" "$AGENT" <<'PY'
import pathlib
import re
import sys

skill_path = pathlib.Path(sys.argv[1])
agent_path = pathlib.Path(sys.argv[2])
text = skill_path.read_text()
lines = text.splitlines()
assert lines[0] == "---"
end = lines.index("---", 1)
frontmatter = lines[1:end]
assert [line.split(":", 1)[0] for line in frontmatter] == ["name", "description"]
assert frontmatter[0] == "name: product-start"
assert frontmatter[1].startswith("description: Use when ")

required = [
    "profile.language/v1",
    ".profile.language",
    "toolbox workbench check",
    "toolbox product init",
    "toolbox product check",
    "toolbox product inspect",
    "Do not write `products/` files directly",
    "workbench-kit migration",
    "toolbox:product/<id>",
]
for phrase in required:
    assert phrase in text, f"skill is missing required contract phrase: {phrase}"

assert "persona.language" not in text
assert "established working language" not in text
assert "[TODO" not in text
assert len(text.split()) < 500

agent = agent_path.read_text()
for field in ("display_name:", "short_description:", "default_prompt:"):
    assert re.search(rf"^\s*{field}", agent, flags=re.MULTILINE), f"missing {field}"
assert "[TODO" not in agent
PY

echo "PASS: product-start skill contract"
