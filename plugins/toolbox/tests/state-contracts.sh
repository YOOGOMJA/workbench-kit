#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
contracts = {
    "product": "toolbox-product/v1",
    "scenario": "toolbox-scenario/v1",
    "autonomy": "toolbox-autonomy/v1",
    "quality": "toolbox-quality/v1",
}

for kind, discriminator in contracts.items():
    schema_path = root / "schemas" / f"{kind}.schema.json"
    template_path = root / "templates" / f"{kind}.json"
    assert schema_path.is_file(), f"missing schema: {schema_path.relative_to(root)}"
    assert template_path.is_file(), f"missing template: {template_path.relative_to(root)}"

    schema = json.loads(schema_path.read_text())
    template = json.loads(template_path.read_text())

    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert schema["type"] == "object"
    assert schema["additionalProperties"] is False
    assert schema["properties"]["schema"]["const"] == discriminator
    assert "schema" in schema["required"]
    assert template["schema"] == discriminator
    assert schema["x-workbench"] == {
        "capability_pack_contract": "workbench-capability-pack/v1",
        "workspace_schemas": ["workbench/v2"],
        "capabilities": ["workspace.schema/v1", "profile.language/v1"],
    }

assert not (root / "products").exists(), "plugin bundle must not contain caller product state"

product = json.loads((root / "templates/product.json").read_text())
assert product["language"] == "en"
assert product["status"] == "draft"
assert product["repositories"] == []
product_schema = json.loads((root / "schemas/product.schema.json").read_text())
language_pattern = product_schema["properties"]["language"]["pattern"]
assert re.fullmatch(language_pattern, "en-US-u-ca-gregory")

scenario = json.loads((root / "templates/scenario.json").read_text())
assert scenario["id"] == "SCN-001"
assert scenario["status"] == "draft"
assert scenario["dependsOn"] == []
assert scenario["acceptanceCriteria"] == []

autonomy = json.loads((root / "templates/autonomy.json").read_text())
assert autonomy == {
    "schema": "toolbox-autonomy/v1",
    "default": "ask",
    "actions": {},
}

quality = json.loads((root / "templates/quality.json").read_text())
assert quality["development"]["tdd"] == "required"
assert quality["development"]["designSystem"] == "required"
assert quality["checks"] == []
PY

echo "PASS: versioned state schemas and templates"
