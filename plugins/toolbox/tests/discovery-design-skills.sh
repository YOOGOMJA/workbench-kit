#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
contracts = {
    "scenario-refine": [
        "toolbox scenario apply",
        "value risk",
        "usability risk",
        "feasibility risk",
        "observable user states",
        "acceptance criteria",
        "dependency refs",
        "design refs",
        "explicit non-goals",
        "`draft` to `ready`",
        "profile.language",
    ],
    "design-system": [
        "owning codebase",
        "existing tokens",
        "existing components",
        "loading, empty, error, and success",
        "responsive",
        "accessibility",
        "universal component library",
        "profile.language",
    ],
}
for name, required in contracts.items():
    skill = root / "skills" / name / "SKILL.md"
    agent = root / "skills" / name / "agents/openai.yaml"
    assert skill.is_file() and agent.is_file(), f"missing {name} artifacts"
    text = skill.read_text()
    assert text.startswith(f"---\nname: {name}\ndescription: Use when ")
    for phrase in required:
        assert phrase in text, f"{name} missing contract phrase: {phrase}"
    assert len(text.split()) < 500
    assert "persona.language" not in text
    assert not re.search(r"(?:cat|sed|jq)[^\n]*products/", text)
    assert "[TODO" not in text + agent.read_text()
PY

echo "PASS: scenario discovery and design skill contracts"
