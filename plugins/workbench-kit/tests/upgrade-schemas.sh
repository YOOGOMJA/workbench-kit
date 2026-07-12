#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v uv >/dev/null || {
  echo "uv is required for Draft 2020-12 schema validation" >&2
  exit 1
}
PYTHONDONTWRITEBYTECODE=1 uv run --quiet \
  --with-requirements "$ROOT/schemas/requirements.txt" \
  python3 - "$ROOT/lib" "$ROOT/schemas" <<'PY'
import base64
import copy
import hashlib
import json
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from workbench_kit_contracts import (
    ContractError,
    canonical_bytes,
    canonical_digest,
    decode_artifact,
    node_digest,
    parse_authority_approval,
    parse_reviewed_overlay,
    validate_equivalence_receipt,
    validate_generation_receipt,
    validate_generator_receipt,
    validate_migration_receipt,
    validate_operation,
    validate_plan,
    validate_path_set,
    validate_relative_path,
    validate_removal_approval,
    validate_result,
    validate_journal,
)
from workbench_kit_schema import load_schema_suite

SHA = "sha256:" + "a" * 64
OID = "1" * 40
schema_dir = pathlib.Path(sys.argv[2])
schema_suite = load_schema_suite(schema_dir)
schema_documents = schema_suite.documents


def schema_accepts(filename, value):
    validator = schema_suite.validator(filename)
    errors = list(validator.iter_errors(value))
    assert not errors, (filename, errors[0].json_path, errors[0].message)


def schema_rejects(filename, value):
    validator = schema_suite.validator(filename)
    assert list(validator.iter_errors(value)), filename

unordered = {"z": 1, "a": {"y": 2, "b": 3}}
reordered = {"a": {"b": 3, "y": 2}, "z": 1}
assert canonical_bytes(unordered) == canonical_bytes(reordered)
assert canonical_digest(unordered) == canonical_digest(reordered)


def rejected(callable_):
    try:
        callable_()
    except ContractError:
        return
    raise AssertionError("invalid contract was accepted")


authority = {
    "contract_version": "workbench-bootstrap-authority-approval/v1",
    "approval_id": "approval-1",
    "proposed_descriptor": {
        "contract_version": "workbench-workspace-authority/v1",
        "authority_identity": "github:example/workbench",
        "origin_url": "https://github.com/example/workbench.git",
        "default_ref": "refs/heads/main",
        "workspace_home": "workbench",
        "hosting_adapter": "github",
        "hosting_ref": "github:repository/example/workbench",
    },
    "default_revision": OID,
    "protection": {
        "ref": "refs/heads/main",
        "revision": OID,
        "direct_task_actor_writes": "blocked",
        "verified_at": "2026-07-11T00:00:00Z",
        "evidence_ref": "github:ruleset/example",
    },
    "actor": "github:user/example",
    "approved_at": "2026-07-11T00:00:00Z",
    "source_ref": "github:repository/example/workbench",
}
authority_sources = [
    json.dumps(authority, separators=(",", ":")).encode() + b"\n",
    canonical_bytes(authority),
    json.dumps(
        dict(reversed(list(authority.items()))), separators=(",", ":")
    ).encode() + b"\n",
]
authority_inputs = [parse_authority_approval(raw) for raw in authority_sources]
authority_input = authority_inputs[1]
assert all(item["receipt"] == authority for item in authority_inputs)
assert {
    item["object_digest"] for item in authority_inputs
} == {canonical_digest(authority)}
assert {
    item["source_digest"] for item in authority_inputs
} == {
    canonical_digest(raw, raw=True) for raw in authority_sources
}
assert len({item["source_digest"] for item in authority_inputs}) == 3
duplicate = authority_sources[0].replace(
    b'{"contract_version":',
    b'{"approval_id":"duplicate","contract_version":',
    1,
)
rejected(lambda: parse_authority_approval(duplicate))
for field in ("approved_at",):
    impossible = copy.deepcopy(authority)
    impossible[field] = "2026-99-99T99:99:99Z"
    rejected(lambda impossible=impossible: parse_authority_approval(
        canonical_bytes(impossible)
    ))
impossible = copy.deepcopy(authority)
impossible["protection"]["verified_at"] = "2026-02-29T00:00:00Z"
rejected(lambda: parse_authority_approval(canonical_bytes(impossible)))
nullable = copy.deepcopy(authority)
nullable["proposed_descriptor"]["hosting_adapter"] = None
nullable["proposed_descriptor"]["hosting_ref"] = None
rejected(lambda: parse_authority_approval(canonical_bytes(nullable)))
bad = copy.deepcopy(authority)
bad["proposed_descriptor"]["default_ref"] = "refs/heads/a//b"
rejected(lambda: parse_authority_approval(canonical_bytes(bad)))

overlay_bytes = b"# Persona\n\nReviewed.\n"
overlay = {
    "contract_version": "workbench-kit-reviewed-overlay/v1",
    "review_id": "review-1",
    "content_base64": base64.b64encode(overlay_bytes).decode(),
    "content_digest": canonical_digest(overlay_bytes, raw=True),
    "actor": "github:user/example",
    "reviewed_at": "2026-07-11T00:00:00Z",
    "source_ref": "github:issue/example/1",
}
reviewed = parse_reviewed_overlay(canonical_bytes(overlay))
assert reviewed["content"] == overlay_bytes
bad = dict(overlay)
bad["content_base64"] = base64.b64encode(b"no-final-lf").decode()
bad["content_digest"] = canonical_digest(b"no-final-lf", raw=True)
rejected(lambda: parse_reviewed_overlay(canonical_bytes(bad)))
bad = dict(overlay)
bad["reviewed_at"] = "2026-99-99T99:99:99Z"
rejected(lambda: parse_reviewed_overlay(canonical_bytes(bad)))

for path in ("docs/index.md", ".workbench/schema", "AGENTS.md"):
    assert validate_relative_path(path) == path
for path in (
    "/tmp/x", "../x", "a/../x", ".git/config", ".GIT/config",
    ".worktrees/x", ".WorkTrees/x", "task/codebases/x", "TASK/CODEBASES/x",
):
    rejected(lambda path=path: validate_relative_path(path))
rejected(lambda: validate_path_set(["A", "a/x"], "paths", reject_ancestors=True))

language = {
    "contract_version": "workbench-kit-language-decision/v1",
    "tag": "en",
    "source": "workspace-profile",
    "source_ref": ".workbench/profile.conf",
    "digest": None,
}
language["digest"] = canonical_digest(language, null_field="digest")
unicode_artifact = {
    "path": "example.txt",
    "node_type": "file",
    "mode": "100644",
    "content_base64": base64.b64encode(b"x").decode("ascii"),
    "link_target": None,
    "source_ref": "artifact:\uc124\uacc4",
    "source_digest": canonical_digest(b"x", raw=True),
}
rejected(lambda: decode_artifact(unicode_artifact))
noncanonical_artifact = {
    **unicode_artifact,
    "content_base64": "AB==",
    "source_ref": "artifact:test",
    "source_digest": canonical_digest(b"\x00", raw=True),
}
rejected(lambda: decode_artifact(noncanonical_artifact))
active = {
    "contract_version": "workbench-kit-active-v1-tasks/v1",
    "source_inventory_object_digest": SHA,
    "tasks": [],
    "digest": None,
}
active["digest"] = canonical_digest(active, null_field="digest")
plan = {
    "contract_version": "workbench-kit-upgrade-plan/v1",
    "plan_digest": None,
    "classification_before": "already-current",
    "target_classification": "already-current",
    "embedded_engine": {
        "before": "absent", "after": "absent", "equivalence_receipt_digest": None
    },
    "provenance_before": {
        "kind": None, "state": "absent", "receipt_digest": None, "ref": None
    },
    "provenance_after": {
        "kind": None, "state": "absent", "receipt_digest": None, "ref": None
    },
    "workspace": {
        "root": "/tmp/workbench",
        "source_revision": OID,
        "default_revision": OID,
        "source_tree_digest": "git-tree:" + "2" * 40,
        "migration_task": {
            "task_id": "workbench#27",
            "claim_id": "claim-27",
            "task_contract": "workbench-task/v2",
            "branch": "task/27-remove-engine",
            "index_digest": SHA,
        },
    },
    "planner": {
        "contract_version": "workbench-kit-planner/v1",
        "plugin_version": "0.1.1",
        "planner_revision": "3" * 40,
    },
    "doctor": {
        "contract_version": "workbench-doctor/v1",
        "ready": True,
        "object_digest": SHA,
        "source_digest": SHA,
        "writer_coordination_digest": SHA,
    },
    "legacy_inventory": {
        "contract_version": "workbench-legacy-inventory/v1",
        "command": "show",
        "object_digest": SHA,
        "source_digest": SHA,
        "authority_revision": OID,
        "home_set_digest": SHA,
        "complete": True,
    },
    "inputs": {
        "language": language,
        "bootstrap_authority_approval": None,
        "reviewed_overlay": None,
    },
    "engine_manifest": None,
    "plugin_equivalence": None,
    "removal_plan_basis_digest": None,
    "removal_approval": None,
    "active_v1_tasks": active,
    "preserved": [],
    "parent_directories": [],
    "artifacts": [],
    "operations": [],
    "blockers": [],
    "changed": False,
    "actionable": False,
}
plan["plan_digest"] = canonical_digest(plan, null_field="plan_digest")
validated = validate_plan(dict(reversed(list(plan.items()))))
assert list(validated) == list(plan)
assert canonical_bytes(validated) == canonical_bytes(plan)
bad = dict(plan)
bad["future"] = True
rejected(lambda: validate_plan(bad))
bad = dict(plan)
bad["changed"] = True
rejected(lambda: validate_plan(bad))
bad = dict(plan)
bad["plan_digest"] = SHA
rejected(lambda: validate_plan(bad))
bad = copy.deepcopy(plan)
bad["plan_digest"] = None
bad["active_v1_tasks"]["source_inventory_object_digest"] = "sha256:" + "b" * 64
bad["active_v1_tasks"]["digest"] = canonical_digest(
    bad["active_v1_tasks"], null_field="digest"
)
bad["plan_digest"] = canonical_digest(bad, null_field="plan_digest")
rejected(lambda: validate_plan(bad))
bad = copy.deepcopy(plan)
bad["plan_digest"] = None
bad["legacy_inventory"]["authority_revision"] = "2" * 40
bad["plan_digest"] = canonical_digest(bad, null_field="plan_digest")
rejected(lambda: validate_plan(bad))

schema_bytes = b"workbench/v2\n"
changed = copy.deepcopy(plan)
changed["plan_digest"] = None
changed["classification_before"] = "generated-minimal"
changed["target_classification"] = "migration-staged"
changed["provenance_after"] = {
    "kind": "migration",
    "state": "valid",
    "receipt_digest": "sha256:" + "9" * 64,
    "ref": ".workbench/migration.json",
}
changed["workspace"]["migration_task"]["task_contract"] = "workbench-task/v1"
changed["doctor"]["ready"] = False
changed["legacy_inventory"]["command"] = "bootstrap-show"
changed["inputs"]["language"] = copy.deepcopy(language)
changed["inputs"]["language"]["source"] = "explicit-cli"
changed["inputs"]["language"]["source_ref"] = "argv:--language"
changed["inputs"]["language"]["digest"] = canonical_digest(
    changed["inputs"]["language"], null_field="digest"
)
changed["inputs"]["bootstrap_authority_approval"] = authority_input
changed["parent_directories"] = [{
    "path": ".workbench",
    "before_type": None,
    "before_mode": None,
    "after_type": "directory",
    "after_mode": "040755",
}]
changed["artifacts"] = [{
    "path": ".workbench/schema",
    "node_type": "file",
    "mode": "100644",
    "content_base64": base64.b64encode(schema_bytes).decode(),
    "link_target": None,
    "source_ref": "constant:workbench/v2",
    "source_digest": canonical_digest(schema_bytes, raw=True),
}]
changed["operations"] = [{
    "op": "create",
    "path": ".workbench/schema",
    "before_type": None,
    "before_mode": None,
    "before_digest": None,
    "after_type": "file",
    "after_mode": "100644",
    "after_digest": node_digest("file", "100644", content=schema_bytes),
    "artifact_source_digest": canonical_digest(schema_bytes, raw=True),
    "equivalence_receipt_ref": None,
}]
changed["changed"] = True
changed["actionable"] = True
changed["plan_digest"] = canonical_digest(changed, null_field="plan_digest")
assert validate_plan(changed)["operations"] == changed["operations"]
bad = copy.deepcopy(changed)
bad["plan_digest"] = None
bad["parent_directories"][0]["path"] = ".workbench/schema"
bad["plan_digest"] = canonical_digest(bad, null_field="plan_digest")
rejected(lambda: validate_plan(bad))
bad = copy.deepcopy(changed)
bad["plan_digest"] = None
bad["preserved"] = [{
    "path": ".WORKBENCH/schema",
    "node_type": "file",
    "mode": "100644",
    "digest": SHA,
    "link_target": None,
}]
bad["plan_digest"] = canonical_digest(bad, null_field="plan_digest")
rejected(lambda: validate_plan(bad))
bad = copy.deepcopy(changed)
bad["plan_digest"] = None
bad["inputs"]["bootstrap_authority_approval"] = None
bad["plan_digest"] = canonical_digest(bad, null_field="plan_digest")
rejected(lambda: validate_plan(bad))

reviewed_plan = copy.deepcopy(changed)
reviewed_plan["plan_digest"] = None
reviewed_plan["inputs"]["reviewed_overlay"] = {
    "receipt": reviewed["receipt"],
    "object_digest": reviewed["object_digest"],
    "source_digest": reviewed["source_digest"],
}
reviewed_plan["plan_digest"] = canonical_digest(
    reviewed_plan, null_field="plan_digest"
)
assert validate_plan(reviewed_plan)["inputs"]["reviewed_overlay"] == (
    reviewed_plan["inputs"]["reviewed_overlay"]
)
pretty_reviewed = parse_reviewed_overlay(
    json.dumps(overlay, indent=2).encode("utf-8") + b"\n"
)
raw_bound_plan = copy.deepcopy(changed)
raw_bound_plan["plan_digest"] = None
raw_bound_plan["inputs"]["reviewed_overlay"] = {
    "receipt": pretty_reviewed["receipt"],
    "object_digest": pretty_reviewed["object_digest"],
    "source_digest": pretty_reviewed["source_digest"],
}
assert pretty_reviewed["source_digest"] != pretty_reviewed["object_digest"]
raw_bound_plan["plan_digest"] = canonical_digest(
    raw_bound_plan, null_field="plan_digest"
)
assert validate_plan(raw_bound_plan)["inputs"]["reviewed_overlay"] == (
    raw_bound_plan["inputs"]["reviewed_overlay"]
)

bad = copy.deepcopy(changed)
bad["artifacts"][0]["source_digest"] = SHA
bad["plan_digest"] = canonical_digest(bad, null_field="plan_digest")
rejected(lambda: validate_plan(bad))
bad = copy.deepcopy(changed)
bad["artifacts"][0]["path"] = ".git/config"
bad["operations"][0]["path"] = ".git/config"
bad["plan_digest"] = canonical_digest(bad, null_field="plan_digest")
rejected(lambda: validate_plan(bad))
bad = copy.deepcopy(changed)
bad["artifacts"] = []
bad["plan_digest"] = canonical_digest(bad, null_field="plan_digest")
rejected(lambda: validate_plan(bad))

bad = copy.deepcopy(changed)
bad["plan_digest"] = None
bad["parent_directories"] = []
bad["artifacts"][0]["path"] = "README.md"
bad["operations"][0]["path"] = "README.md"
bad["plan_digest"] = canonical_digest(bad, null_field="plan_digest")
rejected(lambda: validate_plan(bad))

overlay_plan = copy.deepcopy(changed)
overlay_plan["plan_digest"] = None
overlay_plan["parent_directories"] = []
overlay_plan["artifacts"] = [{
    "path": "AGENTS.overlay.md",
    "node_type": "file",
    "mode": "100644",
    "content_base64": base64.b64encode(overlay_bytes).decode(),
    "link_target": None,
    "source_ref": "input:reviewed-overlay#content",
    "source_digest": canonical_digest(overlay_bytes, raw=True),
}]
overlay_plan["operations"] = [{
    "op": "create",
    "path": "AGENTS.overlay.md",
    "before_type": None,
    "before_mode": None,
    "before_digest": None,
    "after_type": "file",
    "after_mode": "100644",
    "after_digest": node_digest("file", "100644", content=overlay_bytes),
    "artifact_source_digest": canonical_digest(overlay_bytes, raw=True),
    "equivalence_receipt_ref": None,
}]
overlay_plan["plan_digest"] = canonical_digest(
    overlay_plan, null_field="plan_digest"
)
rejected(lambda: validate_plan(overlay_plan))
overlay_plan["plan_digest"] = None
overlay_plan["inputs"]["reviewed_overlay"] = {
    "receipt": reviewed["receipt"],
    "object_digest": reviewed["object_digest"],
    "source_digest": reviewed["source_digest"],
}
overlay_plan["plan_digest"] = canonical_digest(
    overlay_plan, null_field="plan_digest"
)
assert validate_plan(overlay_plan)["artifacts"] == overlay_plan["artifacts"]

symlink_plan = copy.deepcopy(changed)
symlink_plan["plan_digest"] = None
symlink_plan["parent_directories"] = []
symlink_plan["artifacts"] = [{
    "path": "CLAUDE.md",
    "node_type": "symlink",
    "mode": "120000",
    "content_base64": None,
    "link_target": "AGENTS.md",
    "source_ref": "compose:workbench-kit-compose/v1",
    "source_digest": canonical_digest(b"AGENTS.md", raw=True),
}]
symlink_plan["operations"] = [{
    "op": "create",
    "path": "CLAUDE.md",
    "before_type": None,
    "before_mode": None,
    "before_digest": None,
    "after_type": "symlink",
    "after_mode": "120000",
    "after_digest": node_digest("symlink", "120000", link_target="AGENTS.md"),
    "artifact_source_digest": canonical_digest(b"AGENTS.md", raw=True),
    "equivalence_receipt_ref": None,
}]
symlink_plan["plan_digest"] = canonical_digest(
    symlink_plan, null_field="plan_digest"
)
assert validate_plan(symlink_plan)["operations"] == symlink_plan["operations"]

receipt_artifact_paths = sorted([
    ".claude/settings.json",
    ".gitattributes",
    ".gitignore",
    ".workbench/authority.json",
    ".workbench/policy.conf",
    ".workbench/profile.conf",
    ".workbench/schema",
    "AGENTS.md",
    "CLAUDE.md",
])
receipt_artifacts = [{
    "path": path,
    "node_type": "file",
    "mode": "100644",
    "digest": SHA,
} for path in receipt_artifact_paths]
generation_language = copy.deepcopy(language)
generation_language["source"] = "generation-input"
generation_language["source_ref"] = "generator:language"
generation_language["digest"] = canonical_digest(
    generation_language, null_field="digest"
)
generation_receipt = {
    "contract_version": "workbench-kit-generation-receipt/v1",
    "generator_receipt_digest": SHA,
    "workspace_home": "workbench",
    "language": generation_language,
    "authority_descriptor_digest": canonical_digest(authority["proposed_descriptor"]),
    "embedded_engine": {
        "state": "absent",
        "equivalence_receipt_digest": None,
    },
    "artifacts": receipt_artifacts,
    "candidate_basis_digest": None,
}
generation_receipt["candidate_basis_digest"] = canonical_digest(
    generation_receipt, null_field="candidate_basis_digest"
)
assert validate_generation_receipt(generation_receipt) == generation_receipt

migration_receipt = {
    "contract_version": "workbench-kit-migration-receipt/v1",
    "source_revision": changed["workspace"]["source_revision"],
    "source_tree_digest": changed["workspace"]["source_tree_digest"],
    "planner": changed["planner"],
    "migration_task": changed["workspace"]["migration_task"],
    "language": changed["inputs"]["language"],
    "authority_approval_object_digest": authority_input["object_digest"],
    "authority_approval_source_digest": authority_input["source_digest"],
    "reviewed_overlay_object_digest": None,
    "reviewed_overlay_source_digest": None,
    "legacy_inventory_object_digest": changed["legacy_inventory"]["object_digest"],
    "legacy_inventory_source_digest": changed["legacy_inventory"]["source_digest"],
    "active_v1_tasks_digest": changed["active_v1_tasks"]["digest"],
    "embedded_engine": changed["embedded_engine"],
    "artifacts": receipt_artifacts,
    "candidate_basis_digest": None,
}
migration_receipt["candidate_basis_digest"] = canonical_digest(
    migration_receipt, null_field="candidate_basis_digest"
)
assert validate_migration_receipt(migration_receipt) == migration_receipt
known_overlay_receipt = copy.deepcopy(migration_receipt)
known_overlay_receipt["candidate_basis_digest"] = None
known_overlay_receipt["artifacts"] = sorted(
    known_overlay_receipt["artifacts"] + [{
        "path": "AGENTS.overlay.md",
        "node_type": "file",
        "mode": "100644",
        "digest": canonical_digest(overlay_bytes, raw=True),
    }],
    key=lambda item: item["path"],
)
known_overlay_receipt["candidate_basis_digest"] = canonical_digest(
    known_overlay_receipt, null_field="candidate_basis_digest"
)
rejected(lambda: validate_migration_receipt(known_overlay_receipt))
reviewed_overlay_receipt = copy.deepcopy(known_overlay_receipt)
reviewed_overlay_receipt["candidate_basis_digest"] = None
reviewed_overlay_receipt["reviewed_overlay_object_digest"] = SHA
reviewed_overlay_receipt["reviewed_overlay_source_digest"] = "sha256:" + "b" * 64
reviewed_overlay_receipt["candidate_basis_digest"] = canonical_digest(
    reviewed_overlay_receipt, null_field="candidate_basis_digest"
)
assert validate_migration_receipt(reviewed_overlay_receipt) == reviewed_overlay_receipt
bad = copy.deepcopy(migration_receipt)
bad["reviewed_overlay_object_digest"] = SHA
bad["candidate_basis_digest"] = canonical_digest(
    bad, null_field="candidate_basis_digest"
)
rejected(lambda: validate_migration_receipt(bad))

receipt_plan = copy.deepcopy(changed)
receipt_plan["plan_digest"] = None
receipt_bytes = canonical_bytes(migration_receipt)
receipt_plan["artifacts"] = [{
    "path": ".workbench/migration.json",
    "node_type": "file",
    "mode": "100644",
    "content_base64": base64.b64encode(receipt_bytes).decode(),
    "link_target": None,
    "source_ref": "render:workbench-kit-migration-receipt/v1",
    "source_digest": canonical_digest(receipt_bytes, raw=True),
}]
receipt_plan["operations"] = [{
    "op": "create",
    "path": ".workbench/migration.json",
    "before_type": None,
    "before_mode": None,
    "before_digest": None,
    "after_type": "file",
    "after_mode": "100644",
    "after_digest": node_digest("file", "100644", content=receipt_bytes),
    "artifact_source_digest": canonical_digest(receipt_bytes, raw=True),
    "equivalence_receipt_ref": None,
}]
receipt_plan["plan_digest"] = canonical_digest(
    receipt_plan, null_field="plan_digest"
)
assert validate_plan(receipt_plan)["artifacts"] == receipt_plan["artifacts"]
bad = copy.deepcopy(receipt_plan)
bad["plan_digest"] = None
bad_receipt = copy.deepcopy(migration_receipt)
bad_receipt["candidate_basis_digest"] = None
bad_receipt["authority_approval_object_digest"] = "sha256:" + "f" * 64
bad_receipt["candidate_basis_digest"] = canonical_digest(
    bad_receipt, null_field="candidate_basis_digest"
)
bad_bytes = canonical_bytes(bad_receipt)
bad["artifacts"][0]["content_base64"] = base64.b64encode(bad_bytes).decode()
bad["artifacts"][0]["source_digest"] = canonical_digest(bad_bytes, raw=True)
bad["operations"][0]["after_digest"] = node_digest(
    "file", "100644", content=bad_bytes
)
bad["operations"][0]["artifact_source_digest"] = canonical_digest(
    bad_bytes, raw=True
)
bad["plan_digest"] = canonical_digest(bad, null_field="plan_digest")
rejected(lambda: validate_plan(bad))

header = b"# Workbench\n\n"
core = b"# Core\n"
separator = b"\n# Persona\n\n"
generator = {
    "contract_version": "workbench-kit-generator-receipt/v1",
    "receipt_id": "generator-0.1.1",
    "generator_id": "workbench-kit:generate-workbench",
    "generator_version": "0.1.1",
    "source_revision": "4" * 40,
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
generator["receipt_digest"] = canonical_digest(generator, null_field="receipt_digest")
assert validate_generator_receipt(dict(reversed(list(generator.items())))) == generator
bad = copy.deepcopy(generator)
bad["generator_version"] = "1.2.3-.."
bad["receipt_digest"] = canonical_digest(bad, null_field="receipt_digest")
rejected(lambda: validate_generator_receipt(bad))
bad = copy.deepcopy(generator)
bad["core_digest"] = SHA
bad["receipt_digest"] = canonical_digest(bad, null_field="receipt_digest")
rejected(lambda: validate_generator_receipt(bad))
bad = copy.deepcopy(generator)
bad["generated_nodes"] = []
bad["receipt_digest"] = canonical_digest(bad, null_field="receipt_digest")
rejected(lambda: validate_generator_receipt(bad))

legacy_node = {
    "path": "utils/task",
    "node_type": "file",
    "mode": "100755",
    "digest": node_digest("file", "100755", content=b"#!/bin/sh\n"),
    "link_target": None,
}
legacy_manifest = {
    "contract_version": "workbench-legacy-engine-manifest/v1",
    "source_ref": "github:YOOGOMJA/workbench-kit#legacy-engine",
    "source_revision": "5" * 40,
    "allowed_roots": ["utils"],
    "removable_nodes": [legacy_node],
    "discovery_links": [],
}
equivalence = {
    "contract_version": "workbench-plugin-equivalence/v1",
    "receipt_id": "equivalence-fixture-1",
    "replacement_plugin": {
        "plugin_name": "workbench",
        "plugin_version": "0.2.0",
        "source_revision": "6" * 40,
        "plugin_manifest_digest": SHA,
        "source_ref": "github:YOOGOMJA/workbench-kit#plugins/workbench",
    },
    "public_contract": {
        "contract_version": "workbench-contract/v1",
        "engine_name": "workbench",
        "engine_version": "0.2.0",
        "supported_object_digest": "sha256:" + "b" * 64,
        "capabilities": ["engine.manifest/v1", "workspace.schema/v1"],
    },
    "required_capabilities": ["engine.manifest/v1", "workspace.schema/v1"],
    "legacy_source": {
        "source_ref": legacy_manifest["source_ref"],
        "source_revision": legacy_manifest["source_revision"],
    },
    "legacy_manifest_digest": canonical_digest(legacy_manifest),
    "allowed_roots": legacy_manifest["allowed_roots"],
    "removable_nodes": legacy_manifest["removable_nodes"],
    "discovery_links": legacy_manifest["discovery_links"],
    "verification_evidence": [
        {"evidence_id": "contract-1", "kind": "contract-test", "source_ref": "ci:test/1", "source_revision": "7" * 40, "digest": SHA},
        {"evidence_id": "integration-1", "kind": "integration-test", "source_ref": "ci:test/2", "source_revision": "7" * 40, "digest": SHA},
        {"evidence_id": "audit-1", "kind": "manifest-audit", "source_ref": "ci:audit/1", "source_revision": "7" * 40, "digest": SHA},
    ],
}
assert validate_equivalence_receipt(equivalence) == equivalence
bad = copy.deepcopy(equivalence)
bad["verification_evidence"] = bad["verification_evidence"][1:]
rejected(lambda: validate_equivalence_receipt(bad))
bad = copy.deepcopy(equivalence)
bad["legacy_manifest_digest"] = SHA
rejected(lambda: validate_equivalence_receipt(bad))
bad = copy.deepcopy(equivalence)
escaping_link = {
    "path": "utils/link",
    "node_type": "symlink",
    "mode": "120000",
    "digest": node_digest("symlink", "120000", link_target="../../etc/passwd"),
    "link_target": "../../etc/passwd",
}
bad["removable_nodes"] = [escaping_link]
bad["discovery_links"] = [escaping_link]
bad_manifest = {
    "contract_version": "workbench-legacy-engine-manifest/v1",
    "source_ref": bad["legacy_source"]["source_ref"],
    "source_revision": bad["legacy_source"]["source_revision"],
    "allowed_roots": bad["allowed_roots"],
    "removable_nodes": bad["removable_nodes"],
    "discovery_links": bad["discovery_links"],
}
bad["legacy_manifest_digest"] = canonical_digest(bad_manifest)
rejected(lambda: validate_equivalence_receipt(bad))

removal = {
    "contract_version": "workbench-kit-removal-approval/v1",
    "approval_id": "removal-1",
    "equivalence_receipt_id": equivalence["receipt_id"],
    "equivalence_receipt_digest": canonical_digest(equivalence),
    "approved_plan_basis_digest": "sha256:" + "c" * 64,
    "actor": "github:user/example",
    "approved_at": "2026-07-11T00:00:00Z",
    "source_ref": "github:issue/example/27",
}
assert validate_removal_approval(removal) == removal
bad = dict(removal)
bad["approved_at"] = "yesterday"
rejected(lambda: validate_removal_approval(bad))
bad = dict(removal)
bad["approved_at"] = "2026-99-99T99:99:99Z"
rejected(lambda: validate_removal_approval(bad))

preserved_node = {
    "path": "docs/index.md",
    "node_type": "file",
    "mode": "100644",
    "digest": node_digest("file", "100644", content=b"# Docs\n"),
    "link_target": None,
}
remove_operation = {
    "op": "remove",
    "path": legacy_node["path"],
    "before_type": legacy_node["node_type"],
    "before_mode": legacy_node["mode"],
    "before_digest": legacy_node["digest"],
    "after_type": None,
    "after_mode": None,
    "after_digest": None,
    "artifact_source_digest": None,
    "equivalence_receipt_ref": equivalence["receipt_id"],
}
bad_operation = copy.deepcopy(remove_operation)
bad_operation["before_mode"] = "120000"
rejected(lambda: validate_operation(bad_operation))
removal_plan = copy.deepcopy(plan)
removal_plan["plan_digest"] = None
removal_plan["planner"]["plugin_version"] = equivalence["replacement_plugin"][
    "plugin_version"
]
removal_plan["embedded_engine"] = {
    "before": "present-verified",
    "after": "absent",
    "equivalence_receipt_digest": canonical_digest(equivalence),
}
removal_plan["engine_manifest"] = {
    "contract_version": "workbench-plugin-manifest/v1",
    "command": "engine-manifest show",
    "object_digest": "sha256:" + "d" * 64,
    "source_digest": "sha256:" + "e" * 64,
    "content_revision": "sha256:" + "f" * 64,
    "manifest_digest": equivalence["replacement_plugin"]["plugin_manifest_digest"],
}
removal_plan["plugin_equivalence"] = {
    "receipt": equivalence,
    "object_digest": canonical_digest(equivalence),
    "source_digest": canonical_digest(canonical_bytes(equivalence), raw=True),
}
removal_basis = {
    "contract_version": "workbench-kit-removal-plan-basis/v1",
    "workspace_source_revision": removal_plan["workspace"]["source_revision"],
    "workspace_source_tree_digest": removal_plan["workspace"]["source_tree_digest"],
    "migration_task_claim_id": removal_plan["workspace"]["migration_task"]["claim_id"],
    "planner_revision": removal_plan["planner"]["planner_revision"],
    "legacy_inventory_digest": removal_plan["legacy_inventory"]["object_digest"],
    "equivalence_receipt_digest": canonical_digest(equivalence),
    "remove_operations": [remove_operation],
}
removal_plan["removal_plan_basis_digest"] = canonical_digest(removal_basis)
removal_plan["preserved"] = [preserved_node]
removal_plan["parent_directories"] = [{
    "path": "utils",
    "before_type": "directory",
    "before_mode": "040755",
    "after_type": "directory",
    "after_mode": "040755",
}]
removal_plan["operations"] = [remove_operation]
removal_plan["blockers"] = [{
    "code": "removal-approval-required",
    "ref": removal_plan["removal_plan_basis_digest"],
}]
removal_plan["changed"] = True
removal_plan["actionable"] = False
removal_plan["plan_digest"] = canonical_digest(removal_plan, null_field="plan_digest")
assert validate_plan(removal_plan)["removal_plan_basis_digest"] == (
    removal_plan["removal_plan_basis_digest"]
)

approved_removal = copy.deepcopy(removal)
approved_removal["equivalence_receipt_id"] = equivalence["receipt_id"]
approved_removal["equivalence_receipt_digest"] = canonical_digest(equivalence)
approved_removal["approved_plan_basis_digest"] = removal_plan["removal_plan_basis_digest"]
approved_plan = copy.deepcopy(removal_plan)
approved_plan["plan_digest"] = None
approved_plan["removal_approval"] = {
    "receipt": approved_removal,
    "object_digest": canonical_digest(approved_removal),
    "source_digest": canonical_digest(canonical_bytes(approved_removal), raw=True),
}
approved_plan["blockers"] = []
approved_plan["actionable"] = True
approved_plan["plan_digest"] = canonical_digest(approved_plan, null_field="plan_digest")
assert validate_plan(approved_plan)["removal_approval"] == approved_plan["removal_approval"]

bad = copy.deepcopy(approved_plan)
bad["engine_manifest"]["manifest_digest"] = "sha256:" + "0" * 64
bad["plan_digest"] = canonical_digest(bad, null_field="plan_digest")
rejected(lambda: validate_plan(bad))

validation = {
    "status": "passed",
    "classification_after": "migration-staged",
    "basis_kind": "migration-candidate",
    "basis_digest": "sha256:" + "9" * 64,
    "blockers": [],
    "digest": None,
}
validation["digest"] = canonical_digest(validation, null_field="digest")
journal_hex = changed["plan_digest"].removeprefix("sha256:")
workspace_id = "ws-" + hashlib.sha256(
    (
        "workbench-kit-workspace-id/v1\nroot\t"
        + changed["workspace"]["root"]
        + "\n"
    ).encode("utf-8")
).hexdigest()
result = {
    "contract_version": "workbench-kit-upgrade-result/v1",
    "result_digest": None,
    "plan_digest": changed["plan_digest"],
    "classification_before": changed["classification_before"],
    "target_classification": changed["target_classification"],
    "embedded_engine": changed["embedded_engine"],
    "provenance_final": changed["provenance_after"],
    "workspace": changed["workspace"],
    "transaction": {
        "journal_id": "upgrade-" + journal_hex,
        "workspace_id": workspace_id,
        "stage": "completed",
        "direction": "none",
        "cursor": 2,
        "resumed": False,
    },
    "changed": True,
    "applied": [{
        "op": "create",
        "path": ".workbench/schema",
        "before_digest": None,
        "after_digest": changed["operations"][0]["after_digest"],
    }],
    "preserved": [],
    "active_v1_tasks": changed["active_v1_tasks"],
    "validation": validation,
    "blockers": [],
}
result["result_digest"] = canonical_digest(result, null_field="result_digest")
assert validate_result(result) == result
bad = copy.deepcopy(result)
bad["transaction"]["direction"] = "forward"
bad["result_digest"] = canonical_digest(bad, null_field="result_digest")
rejected(lambda: validate_result(bad))
bad = copy.deepcopy(result)
bad["plan_digest"] = SHA
bad["result_digest"] = canonical_digest(bad, null_field="result_digest")
rejected(lambda: validate_result(bad))
bad = copy.deepcopy(result)
bad["transaction"]["workspace_id"] = "ws-" + "7" * 64
bad["result_digest"] = canonical_digest(bad, null_field="result_digest")
rejected(lambda: validate_result(bad))

absent_image = {
    "node_type": "absent", "mode": None, "content_base64": None,
    "link_target": None, "digest": None,
}
directory_image = {
    "node_type": "directory", "mode": "040755", "content_base64": None,
    "link_target": None, "digest": node_digest("directory", "040755"),
}
file_image = {
    "node_type": "file", "mode": "100644",
    "content_base64": base64.b64encode(schema_bytes).decode(),
    "link_target": None,
    "digest": node_digest("file", "100644", content=schema_bytes),
}
effects = [
    {
        "effect_id": "effect-0001",
        "kind": "ensure-directory",
        "path": ".workbench",
        "temp_path": None,
        "before": absent_image,
        "after": directory_image,
        "artifact_source_digest": None,
        "equivalence_receipt_ref": None,
    },
    {
        "effect_id": "effect-0002",
        "kind": "create",
        "path": ".workbench/schema",
        "temp_path": ".workbench/.workbench-kit.upgrade-" + journal_hex + ".effect-0002.tmp",
        "before": absent_image,
        "after": file_image,
        "artifact_source_digest": changed["artifacts"][0]["source_digest"],
        "equivalence_receipt_ref": None,
    },
]
pending_validation = {
    "status": "pending",
    "classification_after": None,
    "basis_kind": None,
    "basis_digest": None,
    "blockers": [],
    "digest": None,
}
pending_validation["digest"] = canonical_digest(
    pending_validation, null_field="digest"
)
journal = {
    "contract_version": "workbench-kit-upgrade-journal/v1",
    "journal_id": "upgrade-" + journal_hex,
    "workspace_id": workspace_id,
    "plan_digest": changed["plan_digest"],
    "plan_source_digest": "sha256:" + "6" * 64,
    "workspace": changed["workspace"],
    "stage": "prepared",
    "direction": "forward",
    "cursor": 0,
    "effects": effects,
    "applied": [],
    "validation": pending_validation,
    "completion_result": None,
    "created_at": "2026-07-11T00:00:00Z",
    "updated_at": "2026-07-11T00:00:00Z",
}
assert validate_journal(journal) == journal
assert validate_journal(journal, changed) == journal
fractional_journal = copy.deepcopy(journal)
fractional_journal["created_at"] = "2024-02-29T00:00:00.123Z"
fractional_journal["updated_at"] = "2024-02-29T00:00:00.456Z"
assert validate_journal(fractional_journal, changed) == fractional_journal
for field, invalid_timestamp in (
    ("created_at", "2026-02-29T00:00:00Z"),
    ("created_at", "2026-02-31T00:00:00Z"),
    ("updated_at", "2026-07-11T24:00:00Z"),
    ("updated_at", "2026-07-11T00:00:00.Z"),
):
    bad = copy.deepcopy(journal)
    bad[field] = invalid_timestamp
    rejected(lambda bad=bad: validate_journal(bad, changed))
bad = copy.deepcopy(journal)
bad["cursor"] = 1
rejected(lambda: validate_journal(bad))
bad = copy.deepcopy(journal)
bad["effects"][0]["path"] = ".workbench/schema"
rejected(lambda: validate_journal(bad))
bad = copy.deepcopy(journal)
duplicate_parent = copy.deepcopy(bad["effects"][0])
bad["effects"] = [duplicate_parent, copy.deepcopy(duplicate_parent), bad["effects"][1]]
for index, effect in enumerate(bad["effects"], 1):
    effect["effect_id"] = f"effect-{index:04d}"
bad["effects"][2]["temp_path"] = (
    ".workbench/.workbench-kit.upgrade-" + journal_hex + ".effect-0003.tmp"
)
rejected(lambda: validate_journal(bad))
bad = copy.deepcopy(journal)
bad["effects"] = [bad["effects"][1]]
bad["effects"][0]["effect_id"] = "effect-0001"
bad["effects"][0]["temp_path"] = (
    ".workbench/.workbench-kit.upgrade-" + journal_hex + ".effect-0001.tmp"
)
rejected(lambda: validate_journal(bad, changed))

symlink_journal = copy.deepcopy(journal)
symlink_hex = symlink_plan["plan_digest"].removeprefix("sha256:")
symlink_journal["journal_id"] = "upgrade-" + symlink_hex
symlink_journal["plan_digest"] = symlink_plan["plan_digest"]
symlink_journal["effects"] = [{
    "effect_id": "effect-0001",
    "kind": "create",
    "path": "CLAUDE.md",
    "temp_path": ".workbench-kit.upgrade-" + symlink_hex + ".effect-0001.tmp",
    "before": absent_image,
    "after": {
        "node_type": "symlink",
        "mode": "120000",
        "content_base64": None,
        "link_target": "AGENTS.md",
        "digest": node_digest("symlink", "120000", link_target="AGENTS.md"),
    },
    "artifact_source_digest": canonical_digest(b"AGENTS.md", raw=True),
    "equivalence_receipt_ref": None,
}]
assert validate_journal(symlink_journal, symlink_plan) == symlink_journal
completed = copy.deepcopy(journal)
completed["stage"] = "completed"
completed["direction"] = "none"
completed["cursor"] = 2
completed["applied"] = ["effect-0001", "effect-0002"]
completed["validation"] = validation
completed["completion_result"] = result
assert validate_journal(completed) == completed
bad = copy.deepcopy(completed)
bad["applied"] = ["effect-0002", "effect-0001"]
rejected(lambda: validate_journal(bad))
bad = copy.deepcopy(completed)
bad["completion_result"]["result_digest"] = SHA
rejected(lambda: validate_journal(bad))
bad = copy.deepcopy(completed)
bad["completion_result"]["applied"][0]["path"] = ".workbench/other"
bad["completion_result"]["result_digest"] = canonical_digest(
    bad["completion_result"], null_field="result_digest"
)
rejected(lambda: validate_journal(bad))

for filename, document in (
    ("bootstrap-authority-approval.schema.json", authority),
    ("generation-receipt.schema.json", generation_receipt),
    ("generator-receipt.schema.json", generator),
    ("migration-receipt.schema.json", migration_receipt),
    ("plugin-equivalence.schema.json", equivalence),
    ("removal-approval.schema.json", removal),
    ("reviewed-overlay.schema.json", overlay),
    ("upgrade-plan.schema.json", changed),
    ("upgrade-result.schema.json", result),
    ("upgrade-journal.schema.json", journal),
):
    schema_accepts(filename, document)

bad_overlay = copy.deepcopy(overlay)
bad_overlay["content_base64"] = "AB=="
bad_overlay["content_digest"] = canonical_digest(b"\x00", raw=True)
rejected(lambda: parse_reviewed_overlay(canonical_bytes(bad_overlay)))
schema_rejects("reviewed-overlay.schema.json", bad_overlay)

bad_generator = copy.deepcopy(generator)
bad_generator["header_base64"] = "AB=="
bad_generator["receipt_digest"] = canonical_digest(
    bad_generator, null_field="receipt_digest"
)
rejected(lambda: validate_generator_receipt(bad_generator))
schema_rejects("generator-receipt.schema.json", bad_generator)

bad_authority = copy.deepcopy(authority)
bad_authority["actor"] = "bad\nactor"
rejected(lambda: parse_authority_approval(canonical_bytes(bad_authority)))
schema_rejects("bootstrap-authority-approval.schema.json", bad_authority)

bad_equivalence = copy.deepcopy(equivalence)
bad_equivalence["legacy_source"]["source_ref"] = "bad\nsource"
rejected(lambda: validate_equivalence_receipt(bad_equivalence))
schema_rejects("plugin-equivalence.schema.json", bad_equivalence)

bad_removal = copy.deepcopy(removal)
bad_removal["actor"] = "actor:\uc124\uacc4"
rejected(lambda: validate_removal_approval(bad_removal))
schema_rejects("removal-approval.schema.json", bad_removal)

bad_generation = copy.deepcopy(generation_receipt)
bad_generation["artifacts"][0]["path"] = "Cafe\u0301"
rejected(lambda: validate_generation_receipt(bad_generation))
schema_rejects("generation-receipt.schema.json", bad_generation)

bad_schema_plan = copy.deepcopy(changed)
bad_schema_plan["changed"] = False
schema_rejects("upgrade-plan.schema.json", bad_schema_plan)
bad_schema_plan = copy.deepcopy(changed)
bad_schema_plan["actionable"] = False
schema_rejects("upgrade-plan.schema.json", bad_schema_plan)
bad_schema_journal = copy.deepcopy(journal)
bad_schema_journal["direction"] = "none"
schema_rejects("upgrade-journal.schema.json", bad_schema_journal)
bad_schema_result = copy.deepcopy(result)
bad_schema_result["changed"] = False
schema_rejects("upgrade-result.schema.json", bad_schema_result)

print("PASS: strict migration schemas and canonical digests")
PY

if find "$ROOT" -type d -name __pycache__ -print -quit | grep -q .; then
  echo "Python bytecode cache escaped upgrade tests" >&2
  exit 1
fi
