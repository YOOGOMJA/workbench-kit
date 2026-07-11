#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/schemas" <<'PY'
import json
import pathlib
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

print("PASS: published upgrade JSON schemas are closed and discoverable")
PY
