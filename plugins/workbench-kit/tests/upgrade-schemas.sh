#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/lib" <<'PY'
import base64
import copy
import hashlib
import json
import sys

sys.path.insert(0, sys.argv[1])
from workbench_kit_contracts import (
    ContractError,
    canonical_bytes,
    canonical_digest,
    node_digest,
    parse_authority_approval,
    parse_reviewed_overlay,
    validate_equivalence_receipt,
    validate_generation_receipt,
    validate_generator_receipt,
    validate_migration_receipt,
    validate_plan,
    validate_relative_path,
    validate_removal_approval,
    validate_result,
    validate_journal,
)

SHA = "sha256:" + "a" * 64
OID = "1" * 40


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
authority_raw = canonical_bytes(authority)
authority_input = parse_authority_approval(authority_raw)
assert authority_input["receipt"] == authority
assert authority_input["source_digest"] == canonical_digest(authority_raw, raw=True)
assert authority_input["object_digest"] == canonical_digest(authority)
rejected(lambda: parse_authority_approval(json.dumps(authority, indent=2).encode() + b"\n"))
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

for path in ("docs/index.md", ".workbench/schema", "AGENTS.md"):
    assert validate_relative_path(path) == path
for path in ("/tmp/x", "../x", "a/../x", ".git/config", ".worktrees/x", "task/codebases/x"):
    rejected(lambda path=path: validate_relative_path(path))

language = {
    "contract_version": "workbench-kit-language-decision/v1",
    "tag": "en",
    "source": "workspace-profile",
    "source_ref": ".workbench/profile.conf",
    "digest": None,
}
language["digest"] = canonical_digest(language, null_field="digest")
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
assert validate_migration_receipt(known_overlay_receipt) == known_overlay_receipt
bad = copy.deepcopy(migration_receipt)
bad["reviewed_overlay_object_digest"] = SHA
bad["candidate_basis_digest"] = canonical_digest(
    bad, null_field="candidate_basis_digest"
)
rejected(lambda: validate_migration_receipt(bad))

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
bad = copy.deepcopy(journal)
bad["cursor"] = 1
rejected(lambda: validate_journal(bad))
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

print("PASS: strict migration schemas and canonical digests")
PY
