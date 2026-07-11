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

for product in \
  alpha beta gamma delta epsilon paused terminal multi mixed active-mixed; do
  toolbox product init --id "$product" --name "$product" --language en \
    --objective "Plan $product" >/dev/null
  toolbox product repository set "$product" --id "$product-web" \
    --path "codebases/$product-web" --role owner >/dev/null
  toolbox product quality check set "$product" --id unit --kind test \
    --owner "$product-web" --required true \
    --command-part npm --command-part test >/dev/null
  toolbox product quality check set "$product" --id optional-lint --kind lint \
    --owner "$product-web" --required false \
    --command-part npm --command-part lint >/dev/null
done
toolbox product repository set alpha --id alpha-api \
  --path codebases/alpha-api --role work >/dev/null
toolbox product quality check set alpha --id api-contract --owner alpha-api \
  --kind integration --required true \
  --command-part npm --command-part run --command-part test:contract >/dev/null

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
scenario epsilon SCN-EPSILON-READY ready 30 '[]'
scenario paused SCN-PAUSED-ACTIVE active 1 '[]'
scenario paused SCN-PAUSED-READY ready 2 '[]'
scenario terminal SCN-TERMINAL-READY ready 1 '[]'
scenario multi SCN-MULTI-A active 1 '[]'
scenario multi SCN-MULTI-B active 2 '[]'
scenario multi SCN-MULTI-READY ready 3 '[]'
scenario mixed SCN-MIXED-BLOCKED blocked 1 '[]'
scenario mixed SCN-MIXED-READY ready 0 '[]'
scenario active-mixed SCN-ACTIVE-MIXED-ACTIVE active 1 '[]'
scenario active-mixed SCN-ACTIVE-MIXED-BLOCKED blocked 2 '[]'
scenario active-mixed SCN-ACTIVE-MIXED-WAIT ready 3 '["SCN-ACTIVE-MIXED-BLOCKED"]'

python3 - "$wb/products/paused/product.json" "$wb/products/terminal/product.json" <<'PY'
import json
import pathlib
import sys

for raw_path, status in zip(sys.argv[1:], ("paused", "completed")):
    path = pathlib.Path(raw_path)
    document = json.loads(path.read_text())
    document["status"] = status
    path.write_text(json.dumps(document, indent=2) + "\n")
PY

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
paused_status="$(toolbox product status paused)" || fail "paused product status failed"
terminal_status="$(toolbox product status terminal)" || fail "terminal product status failed"
multi_status="$(toolbox product status multi)" || fail "multiple-active product status failed"
mixed_status="$(toolbox product status mixed)" || fail "ready-plus-blocked status failed"
active_mixed_status="$(toolbox product status active-mixed)" \
  || fail "active-plus-blocked status failed"
python3 - \
  "$beta_status" "$gamma_status" "$paused_status" "$terminal_status" \
  "$multi_status" "$mixed_status" "$active_mixed_status" <<'PY'
import json
import sys
beta = json.loads(sys.argv[1])
gamma = json.loads(sys.argv[2])
paused = json.loads(sys.argv[3])
terminal = json.loads(sys.argv[4])
multi = json.loads(sys.argv[5])
mixed = json.loads(sys.argv[6])
active_mixed = json.loads(sys.argv[7])
assert beta["active_scenario_ref"] == "toolbox:scenario/SCN-BETA-ACTIVE"
assert beta["next_action"] == "continue-active-scenario"
assert gamma["blockers"] == [{
    "code": "scenario-blocked",
    "ref": "toolbox:scenario/SCN-GAMMA-BLOCKED",
}]
assert gamma["next_action"] == "resolve-blocker"
assert paused["active_scenario_ref"] == "toolbox:scenario/SCN-PAUSED-ACTIVE"
assert paused["ready_candidates"][0]["scenario_ref"] == "toolbox:scenario/SCN-PAUSED-READY"
assert paused["blockers"] == [{
    "code": "product-paused",
    "ref": "toolbox:product/paused",
}]
assert paused["next_action"] == "resolve-blocker"
assert terminal["ready_candidates"][0]["scenario_ref"] == "toolbox:scenario/SCN-TERMINAL-READY"
assert terminal["blockers"] == [{
    "code": "product-terminal",
    "ref": "toolbox:product/terminal",
}]
assert terminal["next_action"] == "none"
assert multi["active_scenario_ref"] is None
assert multi["blockers"] == [{
    "code": "multiple-active-scenarios",
    "ref": "toolbox:product/multi",
}]
assert multi["next_action"] == "resolve-blocker"
assert mixed["ready_candidates"] == [{
    "priority": 0,
    "scenario_ref": "toolbox:scenario/SCN-MIXED-READY",
    "title": "SCN-MIXED-READY",
}]
assert mixed["blockers"] == [{
    "code": "scenario-blocked",
    "ref": "toolbox:scenario/SCN-MIXED-BLOCKED",
}]
assert mixed["next_action"] == "start-ready-scenario"
assert active_mixed["active_scenario_ref"] == (
    "toolbox:scenario/SCN-ACTIVE-MIXED-ACTIVE"
)
assert active_mixed["blockers"] == [
    {
        "code": "scenario-blocked",
        "ref": "toolbox:scenario/SCN-ACTIVE-MIXED-BLOCKED",
    },
    {
        "code": "scenario-dependency-incomplete",
        "ref": "toolbox:scenario/SCN-ACTIVE-MIXED-WAIT",
    },
]
assert active_mixed["next_action"] == "continue-active-scenario"
PY

plan="$(toolbox product run-plan alpha)" || fail "product run-plan failed"
python3 - "$plan" <<'PY'
import json
import sys
assert json.loads(sys.argv[1]) == {
    "contract_version": "toolbox-run-plan/v1",
    "product_ref": "toolbox:product/alpha",
    "repository_owners": ["alpha-api", "alpha-web"],
    "remaining_candidates": [],
    "required_quality_checks": [
        {
            "command": ["npm", "run", "test:contract"],
            "id": "api-contract",
            "kind": "integration",
            "owner": "alpha-api",
        },
        {
            "command": ["npm", "test"],
            "id": "unit",
            "kind": "test",
            "owner": "alpha-web",
        },
    ],
    "scenario_ref": "toolbox:scenario/SCN-ALPHA-READY",
    "selection_scope": "product",
    "skipped_products": [],
}
PY

explicit="$(toolbox product run-plan alpha --scenario SCN-ALPHA-READY)"
[ "$plan" = "$explicit" ] || fail "explicit ready scenario changed the plan"

mixed_plan="$(toolbox product run-plan mixed)" \
  || fail "ready scenario should outrank unrelated blocked backlog"
python3 - "$mixed_plan" <<'PY'
import json
import sys
actual = json.loads(sys.argv[1])
assert actual["product_ref"] == "toolbox:product/mixed"
assert actual["scenario_ref"] == "toolbox:scenario/SCN-MIXED-READY"
PY

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
expect_plan_failure "product-paused" product run-plan paused
expect_plan_failure "product-terminal" product run-plan terminal
expect_plan_failure "multiple-active-scenarios" product run-plan multi
expect_plan_failure "active-scenario-exists" product run-plan active-mixed

portfolio="$(toolbox portfolio run-plan)" || fail "portfolio run-plan failed"
portfolio_again="$(toolbox portfolio run-plan)" || fail "second portfolio run-plan failed"
[ "$portfolio" = "$portfolio_again" ] || fail "portfolio run-plan is not deterministic"
python3 - "$portfolio" <<'PY'
import json
import sys
actual = json.loads(sys.argv[1])
assert actual["contract_version"] == "toolbox-run-plan/v1"
assert actual["selection_scope"] == "portfolio"
assert actual["product_ref"] == "toolbox:product/mixed"
assert actual["scenario_ref"] == "toolbox:scenario/SCN-MIXED-READY"
assert actual["repository_owners"] == ["mixed-web"]
assert [(item["id"], item["owner"]) for item in actual["required_quality_checks"]] == [
    ("unit", "mixed-web"),
]
assert [item["product_ref"] for item in actual["skipped_products"]] == [
    "toolbox:product/active-mixed",
    "toolbox:product/alpha",
    "toolbox:product/beta",
    "toolbox:product/delta",
    "toolbox:product/epsilon",
    "toolbox:product/gamma",
    "toolbox:product/multi",
    "toolbox:product/paused",
    "toolbox:product/terminal",
]
assert actual["skipped_products"][0]["reasons"] == [{
    "code": "active-scenario-exists",
    "ref": "toolbox:scenario/SCN-ACTIVE-MIXED-ACTIVE",
}]
assert actual["skipped_products"][1]["reasons"] == [{
    "code": "lower-priority-candidate",
    "ref": "toolbox:scenario/SCN-ALPHA-READY",
}]
assert actual["skipped_products"][2]["reasons"] == [{
    "code": "active-scenario-exists",
    "ref": "toolbox:scenario/SCN-BETA-ACTIVE",
}]
assert actual["skipped_products"][3]["reasons"] == [{
    "code": "scenario-dependency-incomplete",
    "ref": "toolbox:scenario/SCN-DELTA-WAIT",
}]
assert actual["skipped_products"][4]["reasons"] == [{
    "code": "lower-priority-candidate",
    "ref": "toolbox:scenario/SCN-EPSILON-READY",
}]
assert actual["skipped_products"][5]["reasons"] == [{
    "code": "scenario-blocked",
    "ref": "toolbox:scenario/SCN-GAMMA-BLOCKED",
}]
assert actual["skipped_products"][6]["reasons"] == [{
    "code": "multiple-active-scenarios",
    "ref": "toolbox:product/multi",
}]
assert actual["skipped_products"][7]["reasons"] == [{
    "code": "product-paused",
    "ref": "toolbox:product/paused",
}]
assert actual["skipped_products"][8]["reasons"] == [{
    "code": "product-terminal",
    "ref": "toolbox:product/terminal",
}]
assert actual["remaining_candidates"] == [
    {
        "priority": 20,
        "product_ref": "toolbox:product/alpha",
        "scenario_ref": "toolbox:scenario/SCN-ALPHA-READY",
    },
    {
        "priority": 30,
        "product_ref": "toolbox:product/epsilon",
        "scenario_ref": "toolbox:scenario/SCN-EPSILON-READY",
    },
]
PY

after="$(find "$wb/products" -type f -print0 | sort -z | xargs -0 shasum | shasum)"
[ "$before" = "$after" ] || fail "status or run planning mutated product state"

echo "PASS: deterministic one-primary-work run planning"
