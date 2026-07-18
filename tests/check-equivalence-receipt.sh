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
