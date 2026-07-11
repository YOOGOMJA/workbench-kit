#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v uv >/dev/null || {
  echo "uv is required for Draft 2020-12 schema validation" >&2
  exit 1
}
PYTHONDONTWRITEBYTECODE=1 uv run --quiet \
  --with-requirements "$ROOT/tests/requirements-schema.txt" \
  python3 - "$ROOT/schemas" <<'PY'
import copy
import json
import pathlib
import re
import sys

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

schema_dir = pathlib.Path(sys.argv[1])
contracts = {
    "bootstrap-authority-approval.schema.json": "workbench-bootstrap-authority-approval/v1",
    "generation-receipt.schema.json": "workbench-kit-generation-receipt/v1",
    "generator-receipt.schema.json": "workbench-kit-generator-receipt/v1",
    "migration-receipt.schema.json": "workbench-kit-migration-receipt/v1",
    "plugin-equivalence.schema.json": "workbench-plugin-equivalence/v1",
    "removal-approval.schema.json": "workbench-kit-removal-approval/v1",
    "reviewed-overlay.schema.json": "workbench-kit-reviewed-overlay/v1",
    "upgrade-journal.schema.json": "workbench-kit-upgrade-journal/v1",
    "upgrade-plan.schema.json": "workbench-kit-upgrade-plan/v1",
    "upgrade-result.schema.json": "workbench-kit-upgrade-result/v1",
}

actual = {path.name for path in schema_dir.glob("*.schema.json")}
assert actual == set(contracts), (actual, set(contracts))


def assert_closed_objects(value, ref):
    if isinstance(value, dict):
        if value.get("type") == "object" and "properties" in value:
            assert value.get("additionalProperties") is False, ref
            assert set(value.get("required", [])) == set(value["properties"]), ref
        for key, child in value.items():
            assert_closed_objects(child, f"{ref}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            assert_closed_objects(child, f"{ref}[{index}]")


documents = {}
for filename, contract in contracts.items():
    raw = (schema_dir / filename).read_bytes()
    assert raw.endswith(b"\n"), filename
    document = json.loads(raw)
    documents[filename] = document
    assert document["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert document["$id"] == (
        "https://github.com/YOOGOMJA/workbench-kit/schemas/"
        + contract.replace("/", "-")
    )
    assert document["properties"]["contract_version"] == {"const": contract}
    assert_closed_objects(document, filename)

registry = Registry().with_resources(
    (document["$id"], Resource.from_contents(document))
    for document in documents.values()
)
format_checker = FormatChecker()


def validator_for(filename):
    return Draft202012Validator(
        documents[filename], registry=registry, format_checker=format_checker
    )


def definition_accepts(filename, name, value):
    wrapper = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$ref": documents[filename]["$id"] + f"#/$defs/{name}",
    }
    validator = Draft202012Validator(
        wrapper, registry=registry, format_checker=format_checker
    )
    return not list(validator.iter_errors(value))

generation = json.loads((schema_dir / "generation-receipt.schema.json").read_bytes())
assert generation["properties"]["embedded_engine"]["properties"]["state"] == {
    "const": "absent"
}

journal = json.loads((schema_dir / "upgrade-journal.schema.json").read_bytes())
effect = journal["$defs"]["effect"]
assert effect["allOf"][0]["then"]["properties"]["temp_path"] == {
    "type": "null"
}
assert effect["allOf"][1]["then"]["properties"]["temp_path"] == {
    "$ref": (
        "https://github.com/YOOGOMJA/workbench-kit/schemas/"
        "workbench-kit-upgrade-plan-v1#/$defs/path"
    )
}

generator = json.loads((schema_dir / "generator-receipt.schema.json").read_bytes())
strict_semver = (
    generator["$defs"]["semver"]["pattern"],
    json.loads((schema_dir / "plugin-equivalence.schema.json").read_bytes())[
        "$defs"
    ]["semver"]["pattern"],
    json.loads((schema_dir / "upgrade-plan.schema.json").read_bytes())[
        "$defs"
    ]["planner"]["properties"]["plugin_version"]["pattern"],
)
for pattern in strict_semver:
    assert re.fullmatch(pattern, "1.2.3-alpha.1+build.5")
    for invalid in ("01.2.3", "1.2.3-..", "1.2.3-01", "1.2.3+"):
        assert re.fullmatch(pattern, invalid) is None, (pattern, invalid)

timestamp_schemas = (
    json.loads((schema_dir / "bootstrap-authority-approval.schema.json").read_bytes())[
        "$defs"
    ]["timestamp"],
    json.loads((schema_dir / "reviewed-overlay.schema.json").read_bytes())[
        "$defs"
    ]["timestamp"],
    json.loads((schema_dir / "removal-approval.schema.json").read_bytes())[
        "properties"
    ]["approved_at"],
    journal["$defs"]["timestamp"],
)
for timestamp in timestamp_schemas:
    assert timestamp["format"] == "date-time"
    assert re.fullmatch(timestamp["pattern"], "2026-07-11T23:59:59.123Z")
    assert re.fullmatch(timestamp["pattern"], "2026-99-99T99:99:99Z") is None

path_schemas = [
    json.loads((schema_dir / filename).read_bytes())["$defs"]["path"]
    for filename in (
        "generation-receipt.schema.json",
        "generator-receipt.schema.json",
        "migration-receipt.schema.json",
        "plugin-equivalence.schema.json",
        "upgrade-plan.schema.json",
    )
]
reserved_guards = {
    "^(?:\\.[gG][iI][tT]|\\.[wW][oO][rR][kK][tT][rR][eE][eE][sS]|\\.[cC][oO][dD][eE][bB][aA][sS][eE][sS])(?:/|$)",
    "^[tT][aA][sS][kK]/[cC][oO][dD][eE][bB][aA][sS][eE][sS](?:/|$)",
}
for path_schema in path_schemas:
    assert {
        item["not"]["pattern"] for item in path_schema["allOf"]
    } == reserved_guards
    base_pattern = path_schema["pattern"]
    for invalid in (
        ".", "../x", "a/../x", "./x", "a/./x", "a//x", "x/",
        "a\\x", ".git/config", ".WorkTrees/x", "task/codebases/x",
    ):
        base_match = re.fullmatch(base_pattern, invalid) is not None
        guard_match = all(
            re.search(item["not"]["pattern"], invalid) is None
            for item in path_schema["allOf"]
        )
        assert not (base_match and guard_match), invalid

SHA = "sha256:" + "a" * 64
OID = "1" * 40
authority = {
    "contract_version": "workbench-bootstrap-authority-approval/v1",
    "approval_id": "approval-schema",
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
authority_validator = validator_for("bootstrap-authority-approval.schema.json")
assert not list(authority_validator.iter_errors(authority))
for bad_ref in ("refs/heads/a/../b", "refs/heads/a//b"):
    candidate = copy.deepcopy(authority)
    candidate["proposed_descriptor"]["default_ref"] = bad_ref
    assert list(authority_validator.iter_errors(candidate)), bad_ref

absent_provenance = {
    "kind": None, "state": "absent", "receipt_digest": None, "ref": None,
}
valid_provenance = {
    "kind": "migration", "state": "valid", "receipt_digest": SHA,
    "ref": ".workbench/migration.json",
}
assert definition_accepts(
    "upgrade-plan.schema.json", "provenance", absent_provenance
)
assert definition_accepts(
    "upgrade-plan.schema.json", "provenance", valid_provenance
)
for invalid in (
    {**absent_provenance, "kind": "migration"},
    {**valid_provenance, "state": "stale", "receipt_digest": None},
    {**valid_provenance, "state": "invalid", "ref": None},
):
    assert not definition_accepts(
        "upgrade-plan.schema.json", "provenance", invalid
    ), invalid
assert definition_accepts(
    "upgrade-plan.schema.json",
    "provenance",
    {**valid_provenance, "state": "invalid", "receipt_digest": None},
)

create_operation = {
    "op": "create", "path": "AGENTS.md",
    "before_type": None, "before_mode": None, "before_digest": None,
    "after_type": "file", "after_mode": "100644", "after_digest": SHA,
    "artifact_source_digest": SHA, "equivalence_receipt_ref": None,
}
update_operation = {
    **create_operation,
    "op": "update",
    "before_type": "file", "before_mode": "100644", "before_digest": SHA,
}
remove_operation = {
    **update_operation,
    "op": "remove",
    "after_type": None, "after_mode": None, "after_digest": None,
    "artifact_source_digest": None, "equivalence_receipt_ref": "equivalence-1",
}
for operation in (create_operation, update_operation, remove_operation):
    assert definition_accepts(
        "upgrade-plan.schema.json", "operation", operation
    ), operation
for invalid in (
    {**create_operation, "before_digest": SHA},
    {**create_operation, "artifact_source_digest": None},
    {**update_operation, "equivalence_receipt_ref": "equivalence-1"},
    {**remove_operation, "after_digest": SHA},
    {**remove_operation, "equivalence_receipt_ref": None},
):
    assert not definition_accepts(
        "upgrade-plan.schema.json", "operation", invalid
    ), invalid

absent_image = {
    "node_type": "absent", "mode": None, "content_base64": None,
    "link_target": None, "digest": None,
}
directory_image = {
    "node_type": "directory", "mode": "040755", "content_base64": None,
    "link_target": None, "digest": SHA,
}
file_image = {
    "node_type": "file", "mode": "100644", "content_base64": "eA==",
    "link_target": None, "digest": SHA,
}
ensure_effect = {
    "effect_id": "effect-0001", "kind": "ensure-directory",
    "path": ".workbench", "temp_path": None,
    "before": absent_image, "after": directory_image,
    "artifact_source_digest": None, "equivalence_receipt_ref": None,
}
create_effect = {
    **ensure_effect,
    "kind": "create", "path": "AGENTS.md",
    "temp_path": ".workbench-kit.upgrade-test.effect-0001.tmp",
    "after": file_image, "artifact_source_digest": SHA,
}
remove_effect = {
    **create_effect,
    "kind": "remove", "before": file_image, "after": absent_image,
    "artifact_source_digest": None, "equivalence_receipt_ref": "equivalence-1",
}
for effect_value in (ensure_effect, create_effect, remove_effect):
    assert definition_accepts(
        "upgrade-journal.schema.json", "effect", effect_value
    ), effect_value
for invalid in (
    {**ensure_effect, "artifact_source_digest": SHA},
    {**create_effect, "equivalence_receipt_ref": "equivalence-1"},
    {**remove_effect, "after": file_image},
):
    assert not definition_accepts(
        "upgrade-journal.schema.json", "effect", invalid
    ), invalid

for applied in (
    {"op": "create", "path": "AGENTS.md", "before_digest": None, "after_digest": SHA},
    {"op": "update", "path": "AGENTS.md", "before_digest": SHA, "after_digest": SHA},
    {"op": "remove", "path": "AGENTS.md", "before_digest": SHA, "after_digest": None},
):
    assert definition_accepts(
        "upgrade-result.schema.json", "appliedOperation", applied
    ), applied
assert not definition_accepts(
    "upgrade-result.schema.json",
    "appliedOperation",
    {"op": "remove", "path": "AGENTS.md", "before_digest": SHA, "after_digest": SHA},
)

pending_validation = {
    "status": "pending", "classification_after": None, "basis_kind": None,
    "basis_digest": None, "blockers": [], "digest": SHA,
}
passed_validation = {
    **pending_validation,
    "status": "passed", "classification_after": "migration-staged",
    "basis_kind": "migration-candidate", "basis_digest": SHA,
}
failed_validation = {
    **pending_validation,
    "status": "failed",
    "blockers": [{"code": "candidate-invalid", "ref": "workspace"}],
}
for validation in (pending_validation, passed_validation, failed_validation):
    assert definition_accepts(
        "upgrade-result.schema.json", "validation", validation
    ), validation
for invalid in (
    {**pending_validation, "basis_digest": SHA},
    {**passed_validation, "blockers": [{"code": "x", "ref": "y"}]},
    {**failed_validation, "basis_kind": "removal-plan"},
):
    assert not definition_accepts(
        "upgrade-result.schema.json", "validation", invalid
    ), invalid


def conditional_modes(schema, type_field="node_type", mode_field="mode"):
    result = {}
    for rule in schema["allOf"]:
        kind = rule["if"]["properties"][type_field]["const"]
        mode = rule["then"]["properties"][mode_field]
        result[kind] = tuple(mode.get("enum", (mode.get("const"),)))
    return result


simple_nodes = (
    generator["properties"]["generated_nodes"]["items"],
    json.loads((schema_dir / "generation-receipt.schema.json").read_bytes())[
        "$defs"
    ]["artifactNode"],
    json.loads((schema_dir / "migration-receipt.schema.json").read_bytes())[
        "$defs"
    ]["artifactNode"],
    json.loads((schema_dir / "plugin-equivalence.schema.json").read_bytes())[
        "$defs"
    ]["node"],
)
for node in simple_nodes:
    modes = conditional_modes(node)
    assert modes["symlink"] == ("120000",)
    assert set(modes["file"]) <= {"100644", "100755"}

plan = json.loads((schema_dir / "upgrade-plan.schema.json").read_bytes())
for node_name in ("artifact", "preservedNode"):
    modes = conditional_modes(plan["$defs"][node_name])
    assert modes["symlink"] == ("120000",)
    assert set(modes["file"]) == {"100644", "100755"}

journal_rules = {
    rule["if"]["properties"]["node_type"]["const"]:
    rule["then"]["properties"]["mode"]
    for rule in journal["$defs"]["nodeImage"]["allOf"]
}
assert journal_rules["absent"] == {"type": "null"}
assert journal_rules["directory"] == {
    "type": "string", "pattern": "^04[0-7]{4}$"
}
assert journal_rules["symlink"] == {"const": "120000"}
assert set(journal_rules["file"]["enum"]) == {"100644", "100755"}

print("PASS: published upgrade JSON schemas are closed and discoverable")
PY

if find "$ROOT" -type d -name __pycache__ -print -quit | grep -q .; then
  echo "Python bytecode cache escaped upgrade tests" >&2
  exit 1
fi
