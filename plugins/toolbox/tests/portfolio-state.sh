#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLBOX="$ROOT/bin/toolbox"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/toolbox-portfolio.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_workspace() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init -q
}

fake_workbench="$tmp/workbench"
cat >"$fake_workbench" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "contract show --format json" ] || exit 92
printf '{"contract_version":"workbench-contract/v1","engine":{"name":"workbench","version":"0.2.0"},"workspace":{"root":"%s","schema":"workbench/v2","source":"marker"},"profile":{"contract_version":"workbench-profile/v1","language":"en","source":"workspace"},"supported":{"workspace_schemas":{"read":["workbench/v1","workbench/v2"],"write":["workbench/v2"]},"profile_contracts":["workbench-profile/v1"],"capability_pack_contracts":["workbench-capability-pack/v1"]},"capabilities":["workspace.schema/v1","profile.language/v1"]}\n' "$PWD"
EOF
chmod +x "$fake_workbench"

toolbox() {
  local workspace="$1"
  shift
  TOOLBOX_WORKBENCH_BIN="$fake_workbench" "$TOOLBOX" --workspace "$workspace" "$@"
}

init_product() {
  local workspace="$1" product_id="$2"
  toolbox "$workspace" product init \
    --id "$product_id" --name "$product_id" --language en \
    --objective "Test product $product_id" >/dev/null
}

write_scenario() {
  local workspace="$1" product_id="$2" scenario_id="$3" status="$4"
  local priority="$5" dependencies="$6" title="$7"
  cat >"$workspace/products/$product_id/scenarios/$scenario_id.json" <<EOF
{
  "schema": "toolbox-scenario/v1",
  "id": "$scenario_id",
  "productId": "$product_id",
  "title": "$title",
  "status": "$status",
  "priority": $priority,
  "dependsOn": $dependencies,
  "acceptanceCriteria": [],
  "designRefs": [],
  "verificationRefs": []
}
EOF
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

# Valid two-product portfolio with a cross-product dependency.
wb="$tmp/valid"
make_workspace "$wb"
init_product "$wb" alpha
init_product "$wb" beta
write_scenario "$wb" alpha SCN-ALPHA-BASE completed 10 '[]' "Alpha base"
write_scenario "$wb" alpha SCN-ALPHA-NEXT ready 20 '["SCN-ALPHA-BASE"]' "Alpha next"
write_scenario "$wb" beta SCN-BETA-NEXT ready 5 '["SCN-ALPHA-BASE"]' "Beta next"
write_scenario "$wb" beta SCN-BETA-DRAFT draft 1 '[]' "Beta draft"

check="$(toolbox "$wb" portfolio check)" || fail "valid portfolio check failed"
[ "$check" = '{"products":2,"scenarios":4,"valid":true}' ] \
  || fail "unexpected portfolio check output: $check"

inspect="$(toolbox "$wb" portfolio inspect)" || fail "portfolio inspect failed"
python3 - "$inspect" <<'PY'
import json
import sys

actual = json.loads(sys.argv[1])
assert [entry["product"]["id"] for entry in actual["products"]] == ["alpha", "beta"]
assert [scenario["id"] for entry in actual["products"] for scenario in entry["scenarios"]] == [
    "SCN-ALPHA-BASE",
    "SCN-ALPHA-NEXT",
    "SCN-BETA-DRAFT",
    "SCN-BETA-NEXT",
]
PY

scenario="$(toolbox "$wb" scenario inspect SCN-BETA-NEXT)" \
  || fail "scenario inspect failed"
python3 - "$scenario" <<'PY'
import json
import sys

actual = json.loads(sys.argv[1])
assert actual["product_id"] == "beta"
assert actual["scenario"]["id"] == "SCN-BETA-NEXT"
assert actual["scenario_ref"] == "toolbox:scenario/SCN-BETA-NEXT"
PY

scenario_check="$(toolbox "$wb" scenario check SCN-ALPHA-NEXT)" \
  || fail "scenario check failed"
[ "$scenario_check" = '{"scenario_id":"SCN-ALPHA-NEXT","valid":true}' ] \
  || fail "unexpected scenario check output: $scenario_check"

candidates="$(toolbox "$wb" portfolio candidates)" \
  || fail "portfolio candidates failed"
python3 - "$candidates" <<'PY'
import json
import sys

actual = json.loads(sys.argv[1])
assert actual == {
    "candidates": [
        {
            "priority": 5,
            "product_id": "beta",
            "product_ref": "toolbox:product/beta",
            "scenario_id": "SCN-BETA-NEXT",
            "scenario_ref": "toolbox:scenario/SCN-BETA-NEXT",
            "title": "Beta next",
        },
        {
            "priority": 20,
            "product_id": "alpha",
            "product_ref": "toolbox:product/alpha",
            "scenario_id": "SCN-ALPHA-NEXT",
            "scenario_ref": "toolbox:scenario/SCN-ALPHA-NEXT",
            "title": "Alpha next",
        },
    ]
}
PY

alpha_candidates="$(toolbox "$wb" scenario candidates --product alpha)" \
  || fail "filtered scenario candidates failed"
python3 - "$alpha_candidates" <<'PY'
import json
import sys

actual = json.loads(sys.argv[1])
assert [item["scenario_id"] for item in actual["candidates"]] == ["SCN-ALPHA-NEXT"]
PY

# Malformed JSON is reported with its owning path.
wb_malformed="$tmp/malformed"
make_workspace "$wb_malformed"
init_product "$wb_malformed" malformed
printf '{broken\n' >"$wb_malformed/products/malformed/product.json"
expect_failure "malformed JSON" toolbox "$wb_malformed" product check malformed

# State read failures are normalized instead of leaking Python tracebacks.
wb_invalid_utf8="$tmp/invalid-utf8"
make_workspace "$wb_invalid_utf8"
init_product "$wb_invalid_utf8" invalid-utf8
printf '\377' >"$wb_invalid_utf8/products/invalid-utf8/product.json"
expect_failure "state document is not valid UTF-8" \
  toolbox "$wb_invalid_utf8" product check invalid-utf8

# Semantically malformed state is checked against the shipped v1 schema.
wb_semantic="$tmp/semantic"
make_workspace "$wb_semantic"
init_product "$wb_semantic" semantic
cat >"$wb_semantic/products/semantic/autonomy.json" <<'EOF'
{"schema":"toolbox-autonomy/v1","default":"sometimes","actions":{}}
EOF
expect_failure "$.default must be one of: allow, ask, deny" \
  toolbox "$wb_semantic" product check semantic

# Scenario document identity includes the canonical <scenario-id>.json filename.
wb_filename="$tmp/scenario-filename"
make_workspace "$wb_filename"
init_product "$wb_filename" filename
write_scenario "$wb_filename" filename SCN-CANONICAL ready 1 '[]' "Canonical filename"
mv "$wb_filename/products/filename/scenarios/SCN-CANONICAL.json" \
  "$wb_filename/products/filename/scenarios/SCN-WRONG.json"
expect_failure "scenario file 'SCN-WRONG.json' must be named 'SCN-CANONICAL.json'" \
  toolbox "$wb_filename" product check filename

# Product document IDs cannot alias another product directory.
wb_duplicate_product="$tmp/duplicate-product"
make_workspace "$wb_duplicate_product"
init_product "$wb_duplicate_product" one
init_product "$wb_duplicate_product" two
cat >"$wb_duplicate_product/products/two/product.json" <<'EOF'
{
  "schema": "toolbox-product/v1",
  "id": "one",
  "name": "Duplicate one",
  "language": "en",
  "status": "draft",
  "objective": "Duplicate product identity",
  "repositories": []
}
EOF
expect_failure "duplicate product ID 'one'" \
  toolbox "$wb_duplicate_product" portfolio check

# Scenario references are globally unique across products.
wb_duplicate="$tmp/duplicate"
make_workspace "$wb_duplicate"
init_product "$wb_duplicate" one
init_product "$wb_duplicate" two
write_scenario "$wb_duplicate" one SCN-DUP ready 1 '[]' "First duplicate"
write_scenario "$wb_duplicate" two SCN-DUP ready 2 '[]' "Second duplicate"
expect_failure "duplicate scenario ID 'SCN-DUP'" \
  toolbox "$wb_duplicate" portfolio check

# Every dependency must exist in the joined portfolio.
wb_missing="$tmp/missing"
make_workspace "$wb_missing"
init_product "$wb_missing" missing
write_scenario "$wb_missing" missing SCN-MISSING ready 1 '["SCN-UNKNOWN"]' "Missing dependency"
expect_failure "scenario 'SCN-MISSING' depends on unknown scenario 'SCN-UNKNOWN'" \
  toolbox "$wb_missing" portfolio check

# Dependency cycles are deterministic and actionable.
wb_cycle="$tmp/cycle"
make_workspace "$wb_cycle"
init_product "$wb_cycle" cycle
write_scenario "$wb_cycle" cycle SCN-CYCLE-A ready 1 '["SCN-CYCLE-B"]' "Cycle A"
write_scenario "$wb_cycle" cycle SCN-CYCLE-B ready 2 '["SCN-CYCLE-A"]' "Cycle B"
expect_failure "scenario dependency cycle: SCN-CYCLE-A -> SCN-CYCLE-B -> SCN-CYCLE-A" \
  toolbox "$wb_cycle" portfolio check

echo "PASS: multi-product portfolio validation and candidates"
