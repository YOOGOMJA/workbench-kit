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
version = receipt["replacement_plugin"]["plugin_version"]
expected_tag = "workbench-equivalence-v" + version
assert module.require_evidence_tag(revision, version) == expected_tag
assert receipt["receipt_id"] == (
    "workbench-{}-replaces-workbench-ffb426f1".format(version)
)

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

# The permanent 0.2.0 evidence revision changed the public E2E from its parent. Use that
# fixed historical pair so a later release need not modify the E2E merely to test binding.
tagged = subprocess.check_output(
    [
        "git", "-C", str(root), "rev-parse",
        "refs/tags/workbench-equivalence-v0.2.0^{commit}",
    ],
    text=True,
).strip()
parent = subprocess.check_output(
    ["git", "-C", str(root), "rev-parse", tagged + "^"], text=True
).strip()
relative = "tests/cross_plugin_e2e.py"
blob = subprocess.check_output(
    ["git", "-C", str(root), "show", parent + ":" + relative]
)
expected = "sha256:" + hashlib.sha256(blob).hexdigest()
tagged_blob = subprocess.check_output(
    ["git", "-C", str(root), "show", tagged + ":" + relative]
)
newer = "sha256:" + hashlib.sha256(tagged_blob).hexdigest()
assert expected != newer, "fixed historical evidence pair no longer differs"
rows = {item["evidence_id"]: item for item in module.evidence(parent)}
assert rows["three-plugin-public-e2e"]["digest"] == expected
PY

TAG="$(python3 - "$ROOT/plugins/workbench-kit/receipts/workbench-ffb426f1-equivalence.json" <<'PY'
import json
import sys

receipt = json.load(open(sys.argv[1], encoding="utf-8"))
print("workbench-equivalence-v" + receipt["replacement_plugin"]["plugin_version"])
PY
)"
REVISION="$(git -C "$ROOT" rev-parse "refs/tags/$TAG^{commit}")"
RECEIPT_REVISION="$(python3 - "$ROOT/plugins/workbench-kit/receipts/workbench-ffb426f1-equivalence.json" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["replacement_plugin"]["source_revision"])
PY
)"
[ "$REVISION" = "$RECEIPT_REVISION" ] || {
  echo "evidence tag does not preserve the receipt source revision" >&2
  exit 1
}

# Simulate a post-squash remote with only main plus the permanent evidence tag. The task
# branch is intentionally absent; full-history/tag fetch must still make the receipt auditable.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/workbench-receipt-fresh.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
git init -q --bare "$TMP/origin.git"
SNAPSHOT="$(git -C "$ROOT" stash create 'receipt fresh-main simulation')"
[ -n "$SNAPSHOT" ] || SNAPSHOT="$(git -C "$ROOT" rev-parse HEAD)"
git -C "$ROOT" push -q "$TMP/origin.git" \
  "$SNAPSHOT:refs/heads/main" "refs/tags/$TAG:refs/tags/$TAG"
git init -q "$TMP/checkout"
git -C "$TMP/checkout" remote add origin "$TMP/origin.git"
git -C "$TMP/checkout" fetch -q origin \
  '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*'
git -C "$TMP/checkout" checkout -q --detach origin/main
PYTHONDONTWRITEBYTECODE=1 python3 \
  "$TMP/checkout/scripts/equivalence-receipt.py" check

# Exercise the next normal release without requiring its E2E blob to change. The generated
# 0.3.0 receipt remains uncommitted, exactly as it is when `release.sh finalize` starts the
# full suite; the synthetic main commit must include that working-tree receipt.
git clone -q --no-local "$TMP/origin.git" "$TMP/next-release"
git -C "$TMP/next-release" config user.name test
git -C "$TMP/next-release" config user.email test@example.invalid
bash "$TMP/next-release/scripts/bump-version.sh" 0.3.0 >/dev/null
git -C "$TMP/next-release" add plugins
git -C "$TMP/next-release" commit -q -m 'test: prepare 0.3.0 evidence source'
NEXT_REVISION="$(git -C "$TMP/next-release" rev-parse HEAD)"
git -C "$TMP/next-release" tag workbench-equivalence-v0.3.0 "$NEXT_REVISION"
PYTHONDONTWRITEBYTECODE=1 python3 \
  "$TMP/next-release/scripts/equivalence-receipt.py" generate \
  --replacement-revision "$NEXT_REVISION" >/dev/null
python3 - "$TMP/next-release/plugins/workbench-kit/receipts/workbench-ffb426f1-equivalence.json" <<'PY'
import json
import sys

receipt = json.load(open(sys.argv[1], encoding="utf-8"))
assert receipt["receipt_id"] == "workbench-0.3.0-replaces-workbench-ffb426f1"
assert receipt["replacement_plugin"]["plugin_version"] == "0.3.0"
PY
NEXT_SNAPSHOT="$(git -C "$TMP/next-release" stash create '0.3.0 finalized receipt')"
[ -n "$NEXT_SNAPSHOT" ] || {
  echo "next-release simulation did not capture the generated receipt" >&2
  exit 1
}
git init -q --bare "$TMP/next-origin.git"
git -C "$TMP/next-release" push -q "$TMP/next-origin.git" \
  "$NEXT_SNAPSHOT:refs/heads/main" \
  'refs/tags/workbench-equivalence-v0.3.0:refs/tags/workbench-equivalence-v0.3.0'
git init -q "$TMP/next-checkout"
git -C "$TMP/next-checkout" remote add origin "$TMP/next-origin.git"
git -C "$TMP/next-checkout" fetch -q origin \
  '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*'
git -C "$TMP/next-checkout" checkout -q --detach origin/main
PYTHONDONTWRITEBYTECODE=1 python3 \
  "$TMP/next-checkout/scripts/equivalence-receipt.py" check

if find "$ROOT/plugins/workbench-kit" "$ROOT/scripts" -type d -name __pycache__ \
  -print -quit | grep -q .; then
  echo "equivalence receipt audit left Python bytecode cache in the repository" >&2
  exit 1
fi
