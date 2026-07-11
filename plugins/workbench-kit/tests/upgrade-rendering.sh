#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/lib" <<'PY'
import base64
import copy
import json
import pathlib
import subprocess
import sys
import tempfile

sys.path.insert(0, sys.argv[1])
from workbench_kit_contracts import ContractError, canonical_bytes, canonical_digest
from workbench_kit_render import (
    compose_agents,
    merge_gitattributes,
    merge_gitignore,
    merge_settings,
    render_authority,
    render_policy,
    render_profile,
    render_schema,
)


def rejected(callable_):
    try:
        callable_()
    except ContractError:
        return
    raise AssertionError("structured merge conflict was accepted")


settings = b'{"user":{"x":1},"enabledPlugins":{"other":true}}\n'
expected_settings = {
    "user": {"x": 1},
    "enabledPlugins": {
        "other": True,
        "workbench@workbench-kit": True,
    },
    "extraKnownMarketplaces": {
        "workbench-kit": {
            "source": {"source": "github", "repo": "YOOGOMJA/workbench-kit"}
        }
    },
}
merged_settings = merge_settings(settings)
assert merged_settings == canonical_bytes(expected_settings)
assert merge_settings(merged_settings) == merged_settings
rejected(lambda: merge_settings(
    b'{"enabledPlugins":{"workbench@workbench-kit":false}}\n'
))
rejected(lambda: merge_settings(
    b'{"enabledPlugins":{"workbench@workbench-kit":null}}\n'
))
rejected(lambda: merge_settings(
    b'{"extraKnownMarketplaces":{"workbench-kit":null}}\n'
))
rejected(lambda: merge_settings(b'{"enabledPlugins":null}\n'))
rejected(lambda: merge_settings(b'{"extraKnownMarketplaces":null}\n'))
rejected(lambda: merge_settings(b'{"extraKnownMarketplaces":[]}\n'))
rejected(lambda: merge_settings(b'{"duplicate":1,"duplicate":2}\n'))
rejected(lambda: merge_settings(b'{"bad":NaN}\n'))

gitignore = b"# user\r\ncustom/\r\n.codebases/\r\n.codebases/\r\n"
merged_gitignore = merge_gitignore(gitignore)
assert merged_gitignore == (
    b"# user\r\ncustom/\r\n.codebases/\r\n.worktrees/\r\n"
    b"task/codebases/\r\n.claude/scheduled_tasks.lock\r\n"
)
assert merge_gitignore(merged_gitignore) == merged_gitignore
rejected(lambda: merge_gitignore(b"!.worktrees/\n"))
rejected(lambda: merge_gitignore(b"!**/*\n"))
rejected(lambda: merge_gitignore(b"mixed\r\nnewline\n"))
rejected(lambda: merge_gitignore(b"nul\x00byte\n"))
rejected(lambda: merge_gitignore(b"\xff\n"))
effective_gitignore = merge_gitignore(
    b".worktrees/\n!**/.worktrees/\n"
)
assert effective_gitignore.rfind(b".worktrees/\n") > effective_gitignore.rfind(
    b"!**/.worktrees/\n"
)

attributes = b"*.bin binary\ndocs/log.md merge=union\ndocs/log.md merge=union\n"
merged_attributes = merge_gitattributes(attributes)
assert merged_attributes == (
    b"*.bin binary\ndocs/log.md merge=union\ntask/log.md merge=union\n"
)
assert merge_gitattributes(merged_attributes) == merged_attributes
rejected(lambda: merge_gitattributes(b"docs/log.md merge=ours\n"))
rejected(lambda: merge_gitattributes(b"task/log.md -merge\n"))
rejected(lambda: merge_gitattributes(b"docs/log.md union-macro\n"))
effective_attributes = merge_gitattributes(
    b"docs/log.md merge=union\ndocs/** -merge\n"
)
assert effective_attributes.rfind(
    b"docs/log.md merge=union\n"
) > effective_attributes.rfind(b"docs/** -merge\n")

with tempfile.TemporaryDirectory(prefix="workbench-render-git-") as temporary:
    repository = pathlib.Path(temporary)
    subprocess.run(["git", "-C", str(repository), "init", "-q"], check=True)
    (repository / ".gitignore").write_bytes(effective_gitignore)
    (repository / ".gitattributes").write_bytes(effective_attributes)
    (repository / ".worktrees").mkdir()
    (repository / ".worktrees/probe").write_text("ignored\n")
    (repository / "docs").mkdir()
    (repository / "docs/log.md").write_text("log\n")
    status = subprocess.check_output(
        ["git", "-C", str(repository), "status", "--porcelain", "--untracked-files=all"]
    )
    assert b".worktrees/probe" not in status
    attribute = subprocess.check_output([
        "git", "-C", str(repository), "check-attr", "merge", "--", "docs/log.md"
    ])
    assert attribute.endswith(b"merge: union\n"), attribute

descriptor = {
    "contract_version": "workbench-workspace-authority/v1",
    "authority_identity": "github:example/workbench",
    "origin_url": "https://github.com/example/workbench.git",
    "default_ref": "refs/heads/main",
    "workspace_home": "workbench",
    "hosting_adapter": "github",
    "hosting_ref": "github:repository/example/workbench",
}
assert render_schema() == b"workbench/v2\n"
assert render_profile("en-US") == b"schema=workbench-profile/v1\nlanguage=en-US\n"
assert render_policy() == b"schema=workbench-policy/v1\n"
assert render_authority(dict(reversed(list(descriptor.items())))) == canonical_bytes(descriptor)
rejected(lambda: render_profile("not_a_language"))

header = b"# Workbench\n\n"
core = b"# Core\n"
separator = b"\n# Persona\n\n"
receipt = {
    "contract_version": "workbench-kit-generator-receipt/v1",
    "receipt_id": "generator-0.1.1",
    "generator_id": "workbench-kit:generate-workbench",
    "generator_version": "0.1.1",
    "source_revision": "1" * 40,
    "compose_contract": "workbench-kit-compose/v1",
    "header_base64": base64.b64encode(header).decode(),
    "core_base64": base64.b64encode(core).decode(),
    "core_digest": canonical_digest(core, raw=True),
    "separator_base64": base64.b64encode(separator).decode(),
    "settings_owned": {
        "marketplace": {
            "source": {"source": "github", "repo": "YOOGOMJA/workbench-kit"}
        },
        "plugin_enabled": True,
    },
    "generated_nodes": [
        {"path": ".claude/settings.json", "node_type": "file", "mode": "100644"},
        {"path": "AGENTS.md", "node_type": "file", "mode": "100644"},
        {"path": "CLAUDE.md", "node_type": "file", "mode": "100644"},
    ],
    "receipt_digest": None,
}
receipt["receipt_digest"] = canonical_digest(receipt, null_field="receipt_digest")
overlay = b"Reviewed.\n"
assert compose_agents(receipt, overlay) == header + core + separator + overlay
bad = copy.deepcopy(receipt)
bad["core_base64"] = base64.b64encode(b"drift\n").decode()
bad["receipt_digest"] = canonical_digest(bad, null_field="receipt_digest")
rejected(lambda: compose_agents(bad, overlay))
rejected(lambda: compose_agents(receipt, b"missing-final-lf"))

print("PASS: deterministic structured merges and v2 rendering")
PY

if find "$ROOT" -type d -name __pycache__ -print -quit | grep -q .; then
  echo "Python bytecode cache escaped upgrade tests" >&2
  exit 1
fi
