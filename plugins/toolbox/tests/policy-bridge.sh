#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLBOX="$ROOT/bin/toolbox"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/toolbox-policy.XXXXXX")"
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
}

wb="$tmp/workspace"
mkdir -p "$wb"
git -C "$wb" init -q

cat >"$tmp/workbench" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "contract show --format json" ] || exit 92
printf '{"contract_version":"workbench-contract/v1","engine":{"name":"workbench","version":"0.2.0"},"workspace":{"root":"%s","schema":"workbench/v2","source":"marker"},"profile":{"contract_version":"workbench-profile/v1","language":"en","source":"workspace"},"supported":{"workspace_schemas":{"read":["workbench/v2"],"write":["workbench/v2"]},"profile_contracts":["workbench-profile/v1"],"policy_contracts":["workbench-policy/v1"],"context_policy_contracts":["workbench-context-policy-registration/v1","workbench-context-policy-set/v1"],"capability_pack_contracts":["workbench-capability-pack/v1"]},"capabilities":["workspace.schema/v1","profile.language/v1","policy.context-set/v1"]}\n' "$PWD"
EOF
chmod +x "$tmp/workbench"

toolbox() {
  TOOLBOX_WORKBENCH_BIN="$tmp/workbench" "$TOOLBOX" --workspace "$wb" "$@"
}

toolbox product init --id alpha --name Alpha --language en --objective Delivery >/dev/null
toolbox product autonomy set alpha --action task.complete --decision allow >/dev/null
toolbox product autonomy set alpha --action task.cleanup --decision deny >/dev/null

expect_failure "unsupported workbench action 'product.deploy'" \
  toolbox product autonomy set alpha --action product.deploy --decision allow

sync="$(toolbox product policy sync alpha)" || fail "policy sync failed"
python3 - "$sync" <<'PY'
import json
import sys
assert json.loads(sys.argv[1]) == {
    "changed": True,
    "policy_ref": "products/alpha/policy.conf",
    "product_id": "alpha",
}
PY

cat >"$tmp/expected-policy" <<'EOF'
schema=workbench-policy/v1
action.task.abandon=ask
action.task.cleanup=deny
action.task.complete=allow
action.task.concurrent-write=ask
action.task.deliverable.accept=ask
action.task.deliverable.reject=ask
action.task.deliverable.waive=ask
action.task.deliverable.weaken=ask
action.task.harvest.dispose=ask
action.task.policy-context.register=ask
action.task.policy-context.seal=ask
action.task.required-check.waive=ask
EOF
cmp "$tmp/expected-policy" "$wb/products/alpha/policy.conf" \
  || fail "policy sync did not emit the canonical complete action set"

sync_again="$(toolbox product policy sync alpha)" || fail "second policy sync failed"
python3 - "$sync_again" <<'PY'
import json
import sys
assert json.loads(sys.argv[1])["changed"] is False
PY

rm "$wb/products/alpha/policy.conf"
ln -s "$tmp/outside-policy" "$wb/products/alpha/policy.conf"
expect_failure "must not be a symbolic link" toolbox product policy sync alpha
[ ! -e "$tmp/outside-policy" ] || fail "policy sync followed an escaping symlink"
rm "$wb/products/alpha/policy.conf"
toolbox product policy sync alpha >/dev/null

registration="$(toolbox product context-registration alpha \
  --task-claim-id task__alpha__42-20260711T030000Z-1234 \
  --actor owner@example.com \
  --authority-ref toolbox:authority/product-owner \
  --registered-at 2026-07-11T03:20:00Z)" || fail "context registration failed"
python3 - "$registration" <<'PY'
import json
import sys
assert json.loads(sys.argv[1]) == {
    "contract_version": "workbench-context-policy-registration/v1",
    "registration_id": "ctxreg-toolbox-alpha",
    "task_claim_id": "task__alpha__42-20260711T030000Z-1234",
    "task_context_ref": "toolbox:product/alpha",
    "participants": [{
        "context_ref": "toolbox:product/alpha",
        "policy_ref": "products/alpha/policy.conf",
    }],
    "authority_ref": "toolbox:authority/product-owner",
    "actor": "owner@example.com",
    "registered_at": "2026-07-11T03:20:00Z",
}
PY

registration_again="$(toolbox product context-registration alpha \
  --task-claim-id task__alpha__42-20260711T030000Z-1234 \
  --actor owner@example.com \
  --authority-ref toolbox:authority/product-owner \
  --registered-at 2026-07-11T03:20:00Z)"
[ "$registration" = "$registration_again" ] || fail "registration output is not deterministic"

expect_failure "registered-at must be an RFC 3339 UTC timestamp" \
  toolbox product context-registration alpha \
    --task-claim-id claim --actor owner@example.com \
    --authority-ref toolbox:authority/product-owner --registered-at yesterday
expect_failure "registered-at must be an RFC 3339 UTC timestamp" \
  toolbox product context-registration alpha \
    --task-claim-id claim --actor owner@example.com \
    --authority-ref toolbox:authority/product-owner \
    --registered-at 2026-02-31T03:20:00Z

echo "PASS: canonical workbench policy bridge"
