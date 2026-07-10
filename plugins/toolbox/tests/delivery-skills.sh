#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
contracts = {
    "tdd-slice": [
        "observed failing test",
        "minimal vertical slice",
        "Refactor only after green",
        "workbench task required-check declare",
        "workbench task evidence record",
        "--subject-revision <commit-sha>",
        "--command <exact-command>",
        "profile.language",
    ],
    "release-review": [
        "acceptance criteria",
        "design states",
        "workbench task evidence list",
        "workbench task deliverable acceptance list",
        "workbench task harvest show",
        "workbench task verify --format json",
        "Do not deploy",
        "do not merge",
        "profile.language",
    ],
    "adopt-existing-product": [
        "existing repositories",
        "existing documentation",
        "existing tests",
        "existing design system",
        "toolbox workbench check",
        "toolbox product init",
        "toolbox product repository set",
        "compatibility",
        "Do not rewrite existing code",
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

echo "PASS: TDD delivery and adoption skill contracts"
