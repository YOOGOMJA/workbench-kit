#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="$ROOT/plugins/workbench-kit/receipts/upgrade-runtime.json"

python3 - "$ROOT" "$RUNTIME" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
runtime = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
receipt_path = runtime["plugin_equivalence_file"]
assert isinstance(receipt_path, str) and receipt_path, (
    "upgrade runtime must activate a bundled plugin-equivalence receipt"
)
receipt = root / "plugins/workbench-kit" / receipt_path
assert receipt.is_file(), "missing bundled plugin-equivalence receipt: {}".format(receipt)
archive = root / "tests/fixtures/legacy/workbench-ffb426f1-engine.tar.gz.b64"
assert archive.is_file(), "missing offline legacy-engine audit fixture"
PY

PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/equivalence-receipt.py" check

PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" <<'PY'
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
script = root / "scripts/equivalence-receipt.py"
spec = importlib.util.spec_from_file_location("equivalence_receipt", script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

receipt = json.loads(
    (root / "plugins/workbench-kit/receipts/workbench-ffb426f1-equivalence.json")
    .read_text(encoding="utf-8")
)
revision = receipt["replacement_plugin"]["source_revision"]

try:
    module.build("0" * 40)
except SystemExit:
    pass
else:
    raise AssertionError("receipt builder accepted a nonexistent Git object ID")

# This committed engine predates the 0.2.0 manifest bump. Reading the current checkout
# would report 0.2.0 and fail this historical-tree assertion.
historical = "5396c0d142fee0fd6e14c3ac5258bf35d4cfb4b7"
manifest, contract = module.revision_public_state(historical)
assert manifest["plugin"]["version"] == "0.1.1", manifest["plugin"]
assert contract["engine"]["version"] == "0.1.1", contract["engine"]

# The receipt revision changed the public E2E from its parent. Evidence must therefore
# hash the selected parent's blob, not the checked-out file.
parent = subprocess.check_output(
    ["git", "-C", str(root), "rev-parse", revision + "^"], text=True
).strip()
relative = "tests/cross_plugin_e2e.py"
blob = subprocess.check_output(
    ["git", "-C", str(root), "show", parent + ":" + relative]
)
expected = "sha256:" + hashlib.sha256(blob).hexdigest()
current = "sha256:" + hashlib.sha256((root / relative).read_bytes()).hexdigest()
assert expected != current, "historical evidence fixture no longer distinguishes checkout"
rows = {item["evidence_id"]: item for item in module.evidence(parent)}
assert rows["three-plugin-public-e2e"]["digest"] == expected
PY
