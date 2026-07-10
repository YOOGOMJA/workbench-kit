#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLBOX="$ROOT/bin/toolbox"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/toolbox-product.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

plugin_digest() {
  find "$ROOT" -type f ! -path '*/__pycache__/*' -print0 \
    | sort -z \
    | xargs -0 shasum \
    | shasum \
    | awk '{print $1}'
}

make_workspace() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init -q
}

make_fake_workbench() {
  local path="$1" contract="$2"
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ "\$*" = "contract show --format json" ] || exit 92
printf '%s\n' '$contract' | sed "s|WORKSPACE_ROOT|\$PWD|g"
EOF
  chmod +x "$path"
}

expect_failure() {
  local expected="$1"
  shift
  local out status
  set +e
  out="$("$@" 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $out"
  grep -Fq "$expected" <<<"$out" || fail "missing diagnostic '$expected': $out"
}

supported='{"contract_version":"workbench-contract/v1","engine":{"name":"workbench","version":"0.2.0"},"workspace":{"root":"WORKSPACE_ROOT","schema":"workbench/v2","source":"marker"},"supported":{"workspace_schemas":{"read":["workbench/v1","workbench/v2"],"write":["workbench/v2"]},"capability_pack_contracts":["workbench-capability-pack/v1"]},"capabilities":["workspace.schema/v1"]}'
future='{"contract_version":"workbench-contract/v9","workspace":{"root":"WORKSPACE_ROOT","schema":"workbench/v2","source":"marker"}}'

wb="$tmp/workbench"
make_workspace "$wb"
make_fake_workbench "$tmp/workbench-supported" "$supported"
make_fake_workbench "$tmp/workbench-future" "$future"

[ ! -e "$wb/products" ] || fail "fixture unexpectedly has product state"
before_digest="$(plugin_digest)"

out="$(TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb" product init \
    --id alpha --name "Alpha Product" --language ko \
    --objective "검증 가능한 첫 번째 사용자 흐름")" \
  || fail "product init failed"

python3 - "$out" "$wb" <<'PY'
import json
import pathlib
import sys

actual = json.loads(sys.argv[1])
root = pathlib.Path(sys.argv[2]).resolve()
assert actual == {
    "created": True,
    "product_id": "alpha",
    "product_ref": "toolbox:product/alpha",
    "state_root": str(root / "products/alpha"),
}

product_root = root / "products/alpha"
assert (product_root / "scenarios").is_dir()
assert json.loads((product_root / "product.json").read_text()) == {
    "schema": "toolbox-product/v1",
    "id": "alpha",
    "name": "Alpha Product",
    "language": "ko",
    "status": "draft",
    "objective": "검증 가능한 첫 번째 사용자 흐름",
    "repositories": [],
}
assert json.loads((product_root / "autonomy.json").read_text()) == {
    "schema": "toolbox-autonomy/v1",
    "default": "ask",
    "actions": {},
}
assert json.loads((product_root / "quality.json").read_text())["schema"] == "toolbox-quality/v1"
PY

after_digest="$(plugin_digest)"
[ "$before_digest" = "$after_digest" ] || fail "product init modified the plugin bundle"

expect_failure "product 'alpha' already exists" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb" product init \
    --id alpha --name "Replacement" --language en --objective "overwrite"

inspect="$(TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb" product inspect alpha)" \
  || fail "product inspect failed"
python3 - "$inspect" <<'PY'
import json
import sys

actual = json.loads(sys.argv[1])
assert actual["product"]["id"] == "alpha"
assert actual["product"]["language"] == "ko"
assert actual["autonomy"]["default"] == "ask"
assert actual["quality"]["development"]["tdd"] == "required"
assert actual["scenarios"] == []
PY

check="$(TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb" product check alpha)" \
  || fail "product check failed"
[ "$check" = '{"product_id":"alpha","valid":true}' ] \
  || fail "unexpected product check output: $check"

expect_failure "unsupported workbench contract 'workbench-contract/v9'" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/workbench-future" \
  "$TOOLBOX" --workspace "$wb" product init \
    --id beta --name "Beta" --language en --objective "must not be written"
[ ! -e "$wb/products/beta" ] || fail "incompatible workbench was mutated"

echo "PASS: lazy product state and caller isolation"
