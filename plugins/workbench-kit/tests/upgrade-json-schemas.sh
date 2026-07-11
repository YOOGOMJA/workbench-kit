#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/schemas" <<'PY'
import json
import pathlib
import re
import sys

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


for filename, contract in contracts.items():
    raw = (schema_dir / filename).read_bytes()
    assert raw.endswith(b"\n"), filename
    document = json.loads(raw)
    assert document["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert document["$id"] == (
        "https://github.com/YOOGOMJA/workbench-kit/schemas/"
        + contract.replace("/", "-")
    )
    assert document["properties"]["contract_version"] == {"const": contract}
    assert_closed_objects(document, filename)

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
    "$ref": "upgrade-plan.schema.json#/$defs/path"
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
