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

supported='{"contract_version":"workbench-contract/v1","engine":{"name":"workbench","version":"0.2.0"},"workspace":{"root":"WORKSPACE_ROOT","schema":"workbench/v2","source":"marker"},"profile":{"contract_version":"workbench-profile/v1","language":"ko","source":"workspace"},"supported":{"workspace_schemas":{"read":["workbench/v1","workbench/v2"],"write":["workbench/v2"]},"profile_contracts":["workbench-profile/v1"],"capability_pack_contracts":["workbench-capability-pack/v1"]},"capabilities":["workspace.schema/v1","profile.language/v1"]}'
future='{"contract_version":"workbench-contract/v9","workspace":{"root":"WORKSPACE_ROOT","schema":"workbench/v2","source":"marker"}}'

wb="$tmp/workbench"
make_workspace "$wb"
make_fake_workbench "$tmp/workbench-supported" "$supported"
make_fake_workbench "$tmp/workbench-future" "$future"

wb_invalid="$tmp/invalid-product"
make_workspace "$wb_invalid"
overlong_name="$(printf '%121s' '' | tr ' ' x)"
expect_failure "$.name must be at most 120 character(s)" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb_invalid" product init \
    --id retryable --name "$overlong_name" --language en \
    --objective "must be rejected before mutation"
[ ! -e "$wb_invalid/products" ] \
  || fail "invalid product init left a products directory behind"

TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb_invalid" product init \
    --id retryable --name "Retryable" --language en \
    --objective "valid retry after rejected materialization" >/dev/null \
  || fail "valid retry after rejected product init failed"
[ -d "$wb_invalid/products/retryable/scenarios" ] \
  || fail "valid retry did not create the product bundle"

wb_symlink="$tmp/symlink-product"
outside_products="$tmp/outside-products"
make_workspace "$wb_symlink"
mkdir -p "$outside_products"
ln -s "$outside_products" "$wb_symlink/products"
expect_failure "product state root must not be a symbolic link" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb_symlink" product init \
    --id escaped --name "Escaped" --language en \
    --objective "must not cross the caller workspace boundary"
[ -z "$(find "$outside_products" -mindepth 1 -print -quit)" ] \
  || fail "symlinked product init wrote outside the caller workspace"

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
