#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLBOX="$ROOT/bin/toolbox"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/toolbox-workflows.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
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

toolbox product init --id alpha --name Alpha --language en \
  --objective "Ship observable outcomes" >/dev/null

repository="$(toolbox product repository set alpha \
  --id web --path codebases/web --role owner)" || fail "repository set failed"
python3 - "$repository" <<'PY'
import json
import sys

assert json.loads(sys.argv[1]) == {
    "changed": True,
    "product_id": "alpha",
    "repository": {"id": "web", "path": "codebases/web", "role": "owner"},
}
PY

repository_again="$(toolbox product repository set alpha \
  --id web --path codebases/web --role owner)" || fail "idempotent repository set failed"
python3 - "$repository_again" <<'PY'
import json
import sys
assert json.loads(sys.argv[1])["changed"] is False
PY

expect_failure "already belongs to repository 'web'" toolbox product repository set alpha \
  --id duplicate --path codebases/web --role work
expect_failure "must be workspace-relative" toolbox product repository set alpha \
  --id escaped --path ../outside --role work

mkdir -p "$wb/codebases" "$tmp/outside-repository"
ln -s "$tmp/outside-repository" "$wb/codebases/escaped-link"
expect_failure "repository path must not be a symbolic link" \
  toolbox product repository set alpha --id symlink-escape \
    --path codebases/escaped-link/checkout --role work

future_repository="$(toolbox product repository set alpha --id future \
  --path codebases/future/checkout --role reference)" \
  || fail "absent repository leaf should be allowed"
python3 - "$future_repository" <<'PY'
import json
import sys
repository = json.loads(sys.argv[1])["repository"]
assert repository == {
    "id": "future",
    "path": "codebases/future/checkout",
    "role": "reference",
}
PY

autonomy="$(toolbox product autonomy set alpha \
  --action task.complete --decision allow)" || fail "autonomy set failed"
python3 - "$autonomy" <<'PY'
import json
import sys
assert json.loads(sys.argv[1]) == {
    "action_id": "task.complete",
    "changed": True,
    "decision": "allow",
    "product_id": "alpha",
}
PY

quality="$(toolbox product quality check set alpha --id unit \
  --owner web --kind test --required true --command-part npm --command-part test)" \
  || fail "quality check set failed"
python3 - "$quality" <<'PY'
import json
import sys
assert json.loads(sys.argv[1]) == {
    "changed": True,
    "product_id": "alpha",
    "quality_check": {
        "command": ["npm", "test"],
        "id": "unit",
        "kind": "test",
        "owner": "web",
        "required": True,
    },
}
PY

expect_failure "references unknown repository owner 'missing'" \
  toolbox product quality check set alpha --id missing-owner --owner missing \
    --kind test --required true --command-part make --command-part test
toolbox product repository set alpha --id docs --path codebases/docs \
  --role reference >/dev/null
expect_failure "references non-writable repository owner 'docs'" \
  toolbox product quality check set alpha --id reference-owner --owner docs \
    --kind lint --required true --command-part make --command-part lint

cat >"$tmp/scenario.json" <<'EOF'
{
  "schema": "toolbox-scenario/v1",
  "id": "SCN-ALPHA-1",
  "productId": "alpha",
  "title": "A complete first outcome",
  "status": "ready",
  "priority": 10,
  "dependsOn": [],
  "acceptanceCriteria": ["The outcome is observable"],
  "designRefs": ["codebases/web/docs/design.md"],
  "verificationRefs": []
}
EOF

scenario="$(toolbox scenario apply --product alpha --file "$tmp/scenario.json")" \
  || fail "scenario apply failed"
python3 - "$scenario" <<'PY'
import json
import sys
actual = json.loads(sys.argv[1])
assert actual["changed"] is True
assert actual["product_id"] == "alpha"
assert actual["scenario_ref"] == "toolbox:scenario/SCN-ALPHA-1"
assert actual["scenario"]["status"] == "ready"
PY

scenario_again="$(toolbox scenario apply --product alpha --file "$tmp/scenario.json")" \
  || fail "idempotent scenario apply failed"
python3 - "$scenario_again" <<'PY'
import json
import sys
assert json.loads(sys.argv[1])["changed"] is False
PY

python3 - "$tmp/scenario.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text())
document["productId"] = "other"
path.write_text(json.dumps(document))
PY
before="$(shasum "$wb/products/alpha/scenarios/SCN-ALPHA-1.json" | awk '{print $1}')"
expect_failure "belongs to product 'other'" toolbox scenario apply \
  --product alpha --file "$tmp/scenario.json"
after="$(shasum "$wb/products/alpha/scenarios/SCN-ALPHA-1.json" | awk '{print $1}')"
[ "$before" = "$after" ] || fail "invalid scenario partially replaced valid state"

cp "$wb/products/alpha/quality.json" "$tmp/quality-valid.json"
python3 - "$wb/products/alpha/quality.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text())
del document["checks"][0]["owner"]
path.write_text(json.dumps(document))
PY
expect_failure "is missing required field 'owner'" toolbox product check alpha
cp "$tmp/quality-valid.json" "$wb/products/alpha/quality.json"

toolbox product check alpha >/dev/null || fail "mutations left invalid product state"
echo "PASS: atomic product workflow mutations"
