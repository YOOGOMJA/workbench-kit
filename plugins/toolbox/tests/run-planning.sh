#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLBOX="$ROOT/bin/toolbox"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/toolbox-planning.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

wb="$tmp/workspace"
mkdir -p "$wb"
git -C "$wb" init -q
cat >"$tmp/workbench" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "contract show --format json" ] || exit 92
printf '{"contract_version":"workbench-contract/v1","engine":{"name":"workbench","version":"0.2.0"},"workspace":{"root":"%s","schema":"workbench/v2","source":"marker"},"profile":{"contract_version":"workbench-profile/v1","language":"en","source":"workspace"},"supported":{"workspace_schemas":{"read":["workbench/v2"],"write":["workbench/v2"]},"profile_contracts":["workbench-profile/v1"],"capability_pack_contracts":["workbench-capability-pack/v1"]},"capabilities":["workspace.schema/v1","profile.language/v1"]}\n' "$PWD"
EOF
chmod +x "$tmp/workbench"

toolbox() {
  TOOLBOX_WORKBENCH_BIN="$tmp/workbench" "$TOOLBOX" --workspace "$wb" "$@"
}

for product in alpha beta gamma delta; do
  toolbox product init --id "$product" --name "$product" --language en \
    --objective "Plan $product" >/dev/null
  toolbox product repository set "$product" --id "$product-web" \
    --path "codebases/$product-web" --role owner >/dev/null
  toolbox product quality check set "$product" --id unit --kind test \
    --required true --command-part npm --command-part test >/dev/null
  toolbox product quality check set "$product" --id optional-lint --kind lint \
    --required false --command-part npm --command-part lint >/dev/null
done

scenario() {
  local product="$1" id="$2" status="$3" priority="$4" dependencies="$5"
  cat >"$tmp/$id.json" <<EOF
{"schema":"toolbox-scenario/v1","id":"$id","productId":"$product","title":"$id","status":"$status","priority":$priority,"dependsOn":$dependencies,"acceptanceCriteria":["observable"],"designRefs":[],"verificationRefs":[]}
EOF
  toolbox scenario apply --product "$product" --file "$tmp/$id.json" >/dev/null
}

scenario alpha SCN-ALPHA-DONE completed 1 '[]'
scenario alpha SCN-ALPHA-DRAFT draft 0 '[]'
scenario alpha SCN-ALPHA-READY ready 20 '["SCN-ALPHA-DONE"]'
scenario beta SCN-BETA-ACTIVE active 1 '[]'
scenario beta SCN-BETA-READY ready 2 '[]'
scenario gamma SCN-GAMMA-BLOCKED blocked 1 '[]'
scenario delta SCN-DELTA-WAIT ready 1 '["SCN-GAMMA-BLOCKED"]'

before="$(find "$wb/products" -type f -print0 | sort -z | xargs -0 shasum | shasum)"

status="$(toolbox product status alpha)" || fail "product status failed"
python3 - "$status" <<'PY'
import json
import sys
assert json.loads(sys.argv[1]) == {
    "active_scenario_ref": None,
    "blockers": [],
    "contract_version": "toolbox-product-status/v1",
    "next_action": "start-ready-scenario",
    "product_id": "alpha",
    "product_ref": "toolbox:product/alpha",
    "product_status": "draft",
    "ready_candidates": [{
        "priority": 20,
        "scenario_ref": "toolbox:scenario/SCN-ALPHA-READY",
        "title": "SCN-ALPHA-READY",
    }],
    "scenario_counts": {
        "abandoned": 0,
        "active": 0,
        "blocked": 0,
        "completed": 1,
        "draft": 1,
        "ready": 1,
    },
}
PY

beta_status="$(toolbox product status beta)" || fail "active product status failed"
gamma_status="$(toolbox product status gamma)" || fail "blocked product status failed"
python3 - "$beta_status" "$gamma_status" <<'PY'
import json
import sys
beta = json.loads(sys.argv[1])
gamma = json.loads(sys.argv[2])
assert beta["active_scenario_ref"] == "toolbox:scenario/SCN-BETA-ACTIVE"
assert beta["next_action"] == "continue-active-scenario"
assert gamma["blockers"] == [{
    "code": "scenario-blocked",
    "ref": "toolbox:scenario/SCN-GAMMA-BLOCKED",
}]
assert gamma["next_action"] == "resolve-blocker"
PY

plan="$(toolbox product run-plan alpha)" || fail "product run-plan failed"
python3 - "$plan" <<'PY'
import json
import sys
assert json.loads(sys.argv[1]) == {
    "contract_version": "toolbox-run-plan/v1",
    "product_ref": "toolbox:product/alpha",
    "repository_owners": ["alpha-web"],
    "required_quality_checks": [{
        "command": ["npm", "test"],
        "id": "unit",
        "kind": "test",
    }],
    "scenario_ref": "toolbox:scenario/SCN-ALPHA-READY",
    "selection_scope": "product",
    "skipped_products": [],
}
PY

explicit="$(toolbox product run-plan alpha --scenario SCN-ALPHA-READY)"
[ "$plan" = "$explicit" ] || fail "explicit ready scenario changed the plan"

expect_plan_failure() {
  local expected="$1"
  shift
  local out status
  set +e
  out="$(toolbox "$@" 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail "expected planning exit 1, got $status: $out"
  grep -Fq "$expected" <<<"$out" || fail "missing planning blocker '$expected': $out"
}

expect_plan_failure "scenario-not-ready" product run-plan alpha \
  --scenario SCN-ALPHA-DONE
expect_plan_failure "scenario-dependency-incomplete" product run-plan delta \
  --scenario SCN-DELTA-WAIT
expect_plan_failure "active-scenario-exists" product run-plan beta

portfolio="$(toolbox portfolio run-plan)" || fail "portfolio run-plan failed"
portfolio_again="$(toolbox portfolio run-plan)" || fail "second portfolio run-plan failed"
[ "$portfolio" = "$portfolio_again" ] || fail "portfolio run-plan is not deterministic"
python3 - "$portfolio" <<'PY'
import json
import sys
actual = json.loads(sys.argv[1])
assert actual["contract_version"] == "toolbox-run-plan/v1"
assert actual["selection_scope"] == "portfolio"
assert actual["product_ref"] == "toolbox:product/alpha"
assert actual["scenario_ref"] == "toolbox:scenario/SCN-ALPHA-READY"
assert actual["repository_owners"] == ["alpha-web"]
assert [item["product_ref"] for item in actual["skipped_products"]] == [
    "toolbox:product/beta",
    "toolbox:product/delta",
    "toolbox:product/gamma",
]
assert actual["skipped_products"][0]["reasons"] == [{
    "code": "active-scenario-exists",
    "ref": "toolbox:scenario/SCN-BETA-ACTIVE",
}]
assert actual["skipped_products"][1]["reasons"] == [{
    "code": "scenario-dependency-incomplete",
    "ref": "toolbox:scenario/SCN-DELTA-WAIT",
}]
assert actual["skipped_products"][2]["reasons"] == [{
    "code": "scenario-blocked",
    "ref": "toolbox:scenario/SCN-GAMMA-BLOCKED",
}]
PY

after="$(find "$wb/products" -type f -print0 | sort -z | xargs -0 shasum | shasum)"
[ "$before" = "$after" ] || fail "status or run planning mutated product state"

echo "PASS: deterministic one-primary-work run planning"
