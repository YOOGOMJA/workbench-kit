#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=upgrade-test-lib.sh
source "$ROOT/upgrade-test-lib.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/workbench-upgrade-classify.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

for name in \
  generated-minimal \
  embedded-legacy \
  migration-staged \
  already-current \
  malformed \
  unrecognized
do
  fixture_workspace "$name" "$tmp/$name"
done

PYTHONDONTWRITEBYTECODE=1 python3 - "$KIT_ROOT/lib" "$KIT_ROOT" "$tmp" <<'PY'
import base64
import copy
import hashlib
import json
import os
import pathlib
import subprocess
import sys

sys.path.insert(0, sys.argv[1])

from workbench_kit_classifier import _inspect_node, diagnose_workspace
from workbench_kit_cli import CliError
from workbench_kit_contracts import canonical_bytes, canonical_digest
from workbench_kit_upgrade import load_runtime_bundle, route_for_diagnosis


PLUGIN_ROOT = pathlib.Path(sys.argv[2]).resolve()
FIXTURE_ROOT = PLUGIN_ROOT / "tests/fixtures/upgrade"
WORKSPACES = pathlib.Path(sys.argv[3]).resolve()
BASE_ARTIFACTS = (
    ".claude/settings.json",
    ".gitattributes",
    ".gitignore",
    ".workbench/authority.json",
    ".workbench/policy.conf",
    ".workbench/profile.conf",
    ".workbench/schema",
    "AGENTS.md",
    "CLAUDE.md",
)
SHA = "sha256:" + "a" * 64
OID = "1" * 40


def write(root, relative, content):
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(content)
    target.chmod(0o644)


def workspace_digest(root):
    rows = []
    for current, directories, files in os.walk(
        root, topdown=True, followlinks=False
    ):
        current_path = pathlib.Path(current)
        directories[:] = sorted(
            item for item in directories if item != ".git"
        )
        for name in sorted(directories + files):
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                rows.append(("link", relative, os.readlink(path)))
            elif path.is_file():
                rows.append((
                    "file",
                    relative,
                    hashlib.sha256(path.read_bytes()).hexdigest(),
                ))
    rows.append((
        "git-status",
        subprocess.check_output([
            "git", "-C", str(root), "status", "--porcelain=v2",
            "--untracked-files=all",
        ]).decode("utf-8"),
    ))
    return hashlib.sha256(canonical_bytes(rows)).hexdigest()


def materialize_generated(root, generator, fixture_name):
    overlay = (root / "AGENTS.overlay.md").read_bytes()
    composed = b"".join((
        base64.b64decode(generator["header_base64"], validate=True),
        base64.b64decode(generator["core_base64"], validate=True),
        base64.b64decode(generator["separator_base64"], validate=True),
        overlay,
    ))
    write(root, "AGENTS.md", composed)
    write(root, "CLAUDE.md", composed)
    enabled = {"workbench@workbench-kit": True}
    if fixture_name == "generated-minimal":
        enabled["user-plugin@example"] = True
    settings = {
        "permissions": {"allow": ["Read"]},
        "extraKnownMarketplaces": {
            "workbench-kit": generator["settings_owned"]["marketplace"]
        },
        "enabledPlugins": enabled,
    }
    write(root, ".claude/settings.json", canonical_bytes(settings))


def artifact(root, relative):
    node = _inspect_node(root, relative)
    return {
        "path": relative,
        "node_type": node["node_type"],
        "mode": node["mode"],
        "digest": node["digest"],
    }


def materialize_migration_receipt(root, planner):
    language = {
        "contract_version": "workbench-kit-language-decision/v1",
        "tag": "en",
        "source": "explicit-cli",
        "source_ref": "argv:--language",
        "digest": None,
    }
    language["digest"] = canonical_digest(language, null_field="digest")
    index = (root / "task/index.md").read_bytes()
    receipt = {
        "contract_version": "workbench-kit-migration-receipt/v1",
        "source_revision": OID,
        "source_tree_digest": "git-tree:" + "2" * 40,
        "planner": copy.deepcopy(planner),
        "migration_task": {
            "task_id": "workbench#27",
            "claim_id": "fixture-staged-claim",
            "task_contract": "workbench-task/v1",
            "branch": "task/27-upgrade",
            "index_digest": canonical_digest(index, raw=True),
        },
        "language": language,
        "authority_approval_object_digest": SHA,
        "authority_approval_source_digest": "sha256:" + "b" * 64,
        "reviewed_overlay_object_digest": None,
        "reviewed_overlay_source_digest": None,
        "legacy_inventory_object_digest": "sha256:" + "c" * 64,
        "legacy_inventory_source_digest": "sha256:" + "d" * 64,
        "active_v1_tasks_digest": "sha256:" + "e" * 64,
        "embedded_engine": {
            "before": "absent",
            "after": "absent",
            "equivalence_receipt_digest": None,
        },
        "artifacts": [artifact(root, path) for path in BASE_ARTIFACTS],
        "candidate_basis_digest": None,
    }
    receipt["candidate_basis_digest"] = canonical_digest(
        receipt, null_field="candidate_basis_digest"
    )
    write(root, ".workbench/migration.json", canonical_bytes(receipt))


def public_snapshot(schema, ready):
    return {
        "contract": {"workspace": {"schema": schema}},
        "doctor": {"ready": ready},
    }


bundle = load_runtime_bundle(PLUGIN_ROOT)
assert bundle["plugin_equivalence_input"] is not None

for metadata_path in sorted(FIXTURE_ROOT.glob("*/fixture.json")):
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    name = metadata_path.parent.name
    root = WORKSPACES / name
    materialization = metadata.get("materialize")
    if materialization == "runtime-generated":
        materialize_generated(
            root, bundle["target_generator_receipt"], name
        )
    elif materialization == "migration-receipt":
        materialize_migration_receipt(root, bundle["planner"])
    elif materialization is not None:
        raise AssertionError((name, materialization))

    before = workspace_digest(root)
    arguments = {
        "generator_receipts": bundle["generator_receipts"],
        "equivalence_receipt": bundle["plugin_equivalence_input"]["receipt"],
        "legacy_engine_markers": bundle["legacy_engine_markers"],
    }
    snapshot = public_snapshot(
        metadata["workspace_schema"], metadata["doctor_ready"]
    )
    first = diagnose_workspace(root, snapshot, **arguments)
    second = diagnose_workspace(root, snapshot, **arguments)
    assert first == second, name
    assert before == workspace_digest(root), name
    assert list(first) == [
        "contract_version",
        "classification",
        "embedded_engine",
        "provenance",
        "language",
        "blockers",
    ]
    assert first["classification"] == metadata["classification"], (
        name, first
    )
    assert first["embedded_engine"]["state"] == metadata["embedded_state"]
    assert first["blockers"] == metadata["blockers"]

    expected_route = metadata.get("route")
    if expected_route is None:
        try:
            route_for_diagnosis(first, metadata["workspace_schema"])
        except CliError as error:
            assert error.code == "classification-not-actionable"
        else:
            raise AssertionError(f"{name}: blocked diagnosis became actionable")
    else:
        assert route_for_diagnosis(
            first, metadata["workspace_schema"]
        ) == expected_route

    if name == "migration-staged":
        assert first["provenance"]["state"] == "valid"
    if name == "embedded-legacy":
        assert first["blockers"] == [{
            "code": "embedded-engine-unverified",
            "ref": "embedded-engine",
        }]

print("PASS: filesystem upgrade classification and migration route fixtures")
PY

if find "$KIT_ROOT" -type d -name __pycache__ -print -quit | grep -q .; then
  echo "Python bytecode cache escaped upgrade tests" >&2
  exit 1
fi
