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
  ! grep -Fq "Traceback (most recent call last)" <<<"$out" \
    || fail "failure leaked a Python traceback: $out"
}

supported='{"contract_version":"workbench-contract/v1","engine":{"name":"workbench","version":"0.2.0"},"workspace":{"root":"WORKSPACE_ROOT","schema":"workbench/v2","source":"marker"},"profile":{"contract_version":"workbench-profile/v1","language":"ko","source":"workspace"},"supported":{"workspace_schemas":{"read":["workbench/v1","workbench/v2"],"write":["workbench/v2"]},"profile_contracts":["workbench-profile/v1"],"capability_pack_contracts":["workbench-capability-pack/v1"]},"capabilities":["workspace.schema/v1","profile.language/v1"]}'
future='{"contract_version":"workbench-contract/v9","workspace":{"root":"WORKSPACE_ROOT","schema":"workbench/v2","source":"marker"}}'

wb="$tmp/workbench"
make_workspace "$wb"
make_fake_workbench "$tmp/workbench-supported" "$supported"
make_fake_workbench "$tmp/workbench-future" "$future"

extended_supported="$(python3 - "$supported" <<'PY'
import json
import sys

document = json.loads(sys.argv[1])
document["profile"]["language"] = "en-US-u-ca-gregory"
print(json.dumps(document, separators=(",", ":")))
PY
)"
make_fake_workbench "$tmp/workbench-extended-language" "$extended_supported"
wb_extended_language="$tmp/extended-language"
make_workspace "$wb_extended_language"
TOOLBOX_WORKBENCH_BIN="$tmp/workbench-extended-language" \
  "$TOOLBOX" --workspace "$wb_extended_language" product init \
    --id extended --name "Extended" --language en-US-u-ca-gregory \
    --objective "accept a well-formed BCP 47 extension" >/dev/null \
  || fail "extended BCP 47 language tag was rejected"
python3 - "$wb_extended_language/products/extended/product.json" <<'PY'
import json
import pathlib
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert document["language"] == "en-US-u-ca-gregory"
PY

wb_read_source="$tmp/read-source"
make_workspace "$wb_read_source"
TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb_read_source" product init \
    --id source --name "Source" --language ko --objective "safe source" >/dev/null

wb_products_link="$tmp/read-products-link"
make_workspace "$wb_products_link"
ln -s "$wb_read_source/products" "$wb_products_link/products"
expect_failure "must not be a symbolic link" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb_products_link" product inspect source

wb_product_link="$tmp/read-product-link"
make_workspace "$wb_product_link"
mkdir "$wb_product_link/products"
ln -s "$wb_read_source/products/source" "$wb_product_link/products/source"
expect_failure "must not be a symbolic link" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb_product_link" product inspect source

wb_scenarios_link="$tmp/read-scenarios-link"
make_workspace "$wb_scenarios_link"
mkdir "$wb_scenarios_link/products"
cp -R "$wb_read_source/products/source" "$wb_scenarios_link/products/source"
rm -rf "$wb_scenarios_link/products/source/scenarios"
ln -s "$wb_read_source/products/source/scenarios" \
  "$wb_scenarios_link/products/source/scenarios"
expect_failure "must not be a symbolic link" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb_scenarios_link" product inspect source

wb_json_link="$tmp/read-json-link"
outside_product_json="$tmp/outside-product.json"
make_workspace "$wb_json_link"
mkdir "$wb_json_link/products"
cp -R "$wb_read_source/products/source" "$wb_json_link/products/source"
mv "$wb_json_link/products/source/product.json" "$outside_product_json"
ln -s "$outside_product_json" "$wb_json_link/products/source/product.json"
expect_failure "must not be a symbolic link" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb_json_link" product inspect source

wb_language_mismatch="$tmp/language-mismatch"
make_workspace "$wb_language_mismatch"
expect_failure "does not match workbench profile language 'ko'" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb_language_mismatch" product init \
    --id mismatch --name "Mismatch" --language en \
    --objective "must use the governed profile language"
[ ! -e "$wb_language_mismatch/products" ] \
  || fail "language mismatch mutated product state"

wb_write_failure="$tmp/write-failure"
make_workspace "$wb_write_failure"
mkdir "$wb_write_failure/products"
chmod 500 "$wb_write_failure/products"
set +e
write_failure_out="$(TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb_write_failure" product init \
    --id unwritable --name "Unwritable" --language ko \
    --objective "normalize state mutation failures" 2>&1)"
write_failure_status=$?
set -e
chmod 700 "$wb_write_failure/products"
[ "$write_failure_status" -eq 1 ] \
  || fail "expected write failure exit 1, got $write_failure_status: $write_failure_out"
grep -Fq "unable to initialize product state" <<<"$write_failure_out" \
  || fail "missing normalized write diagnostic: $write_failure_out"
! grep -Fq "Traceback (most recent call last)" <<<"$write_failure_out" \
  || fail "write failure leaked a Python traceback: $write_failure_out"

wb_invalid="$tmp/invalid-product"
make_workspace "$wb_invalid"
overlong_name="$(printf '%121s' '' | tr ' ' x)"
expect_failure "$.name must be at most 120 character(s)" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb_invalid" product init \
    --id retryable --name "$overlong_name" --language ko \
    --objective "must be rejected before mutation"
[ ! -e "$wb_invalid/products" ] \
  || fail "invalid product init left a products directory behind"

TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb_invalid" product init \
    --id retryable --name "Retryable" --language ko \
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
    --id escaped --name "Escaped" --language ko \
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
    --id alpha --name "Replacement" --language ko --objective "overwrite"

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
