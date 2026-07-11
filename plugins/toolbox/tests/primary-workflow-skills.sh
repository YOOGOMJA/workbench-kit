#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
contracts = {
    "product-status": [
        "toolbox workbench check",
        ".profile.language",
        "toolbox product status <product-id>",
        "read-only",
    ],
    "product-run": [
        "docs-query",
        "toolbox product run-plan",
        "workbench task refs set",
        "--context-ref <product-ref>",
        "--work-ref <scenario-ref>",
        "toolbox product policy sync",
        "toolbox product context-registration",
        "workbench task policy-context register",
        "workbench task policy-context seal",
        "workbench task deliverable declare",
        "--id <deliverable-id> --owner <owner> --kind codebase-pr",
        "workbench task required-check declare",
        "check.owner",
        "Do not guess",
        "profile.language",
        "unresolved `ask`",
        "unaccepted deliverable",
        "human merge",
    ],
    "portfolio-run": [
        "toolbox portfolio run-plan",
        "skipped_products",
        "product-run",
        "profile.language",
        "exactly one",
        "Re-evaluate",
        "task-start",
        "ticket-incubate",
        "Never invent an issue ID",
    ],
}

for name, required in contracts.items():
    skill = root / "skills" / name / "SKILL.md"
    agent = root / "skills" / name / "agents" / "openai.yaml"
    assert skill.is_file(), f"missing {name} skill"
    assert agent.is_file(), f"missing {name} Codex metadata"
    text = skill.read_text()
    lines = text.splitlines()
    assert lines[0] == "---"
    end = lines.index("---", 1)
    assert lines[1] == f"name: {name}"
    assert lines[2].startswith("description: Use when ")
    for phrase in required:
        assert phrase in text, f"{name} missing contract phrase: {phrase}"
    assert len(text.split()) < 500, f"{name} exceeds 500 words"
    assert "persona.language" not in text
    assert not re.search(r"(?:cat|sed|jq)[^\n]*products/", text)
    assert "task/.workbench/" not in text
    metadata = agent.read_text()
    for field in ("display_name:", "short_description:", "default_prompt:"):
        assert re.search(rf"^\s*{field}", metadata, re.MULTILINE)
    assert "[TODO" not in text + metadata

product_start = (root / "skills/product-start/SKILL.md").read_text()
assert "toolbox product policy sync <id>" in product_start
assert "context registration belongs to `product-run`" in product_start
PY

echo "PASS: primary product workflow skill contracts"
