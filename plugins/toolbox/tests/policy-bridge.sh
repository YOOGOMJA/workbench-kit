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

policy_digest="$(python3 - "$wb/products/alpha/policy.conf" <<'PY'
import hashlib
import pathlib
import sys
print("sha256:" + hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
cat >"$tmp/authority-receipt.json" <<EOF
{
  "contract_version": "workbench-policy-authority-receipt/v1",
  "authority_identity": "toolbox:authority/product-owner",
  "authority_ref": "toolbox:policy/alpha",
  "authority_revision": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "policy_ref": "products/alpha/policy.conf",
  "policy_digest": "$policy_digest",
  "actor": "product-owner@example.com",
  "issued_at": "2026-07-11T03:00:00Z",
  "source_ref": "toolbox:approval/policy-alpha-v3"
}
EOF

registration="$(toolbox product context-registration alpha \
  --task-claim-id task__alpha__42-20260711T030000Z-1234 \
  --actor owner@example.com \
  --authority-receipt-file "$tmp/authority-receipt.json" \
  --registered-at 2026-07-11T03:20:00Z)" || fail "context registration failed"
python3 - "$registration" "$policy_digest" <<'PY'
import json
import sys
document = json.loads(sys.argv[1])
assert list(document) == [
    "contract_version",
    "registration_id",
    "task_claim_id",
    "task_context_ref",
    "participants",
    "task_policy",
    "actor",
    "registered_at",
]
assert list(document["participants"][0]) == [
    "context_ref",
    "policy_ref",
    "policy_digest",
    "authority_ref",
    "authority_receipt",
]
assert list(document["participants"][0]["authority_receipt"]) == [
    "contract_version",
    "authority_identity",
    "authority_ref",
    "authority_revision",
    "policy_ref",
    "policy_digest",
    "actor",
    "issued_at",
    "source_ref",
]
assert document == {
    "contract_version": "workbench-context-policy-registration/v1",
    "registration_id": "ctxreg-toolbox-alpha",
    "task_claim_id": "task__alpha__42-20260711T030000Z-1234",
    "task_context_ref": "toolbox:product/alpha",
    "participants": [{
        "context_ref": "toolbox:product/alpha",
        "policy_ref": "products/alpha/policy.conf",
        "policy_digest": sys.argv[2],
        "authority_ref": "toolbox:policy/alpha",
        "authority_receipt": {
            "contract_version": "workbench-policy-authority-receipt/v1",
            "authority_identity": "toolbox:authority/product-owner",
            "authority_ref": "toolbox:policy/alpha",
            "authority_revision": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "policy_ref": "products/alpha/policy.conf",
            "policy_digest": sys.argv[2],
            "actor": "product-owner@example.com",
            "issued_at": "2026-07-11T03:00:00Z",
            "source_ref": "toolbox:approval/policy-alpha-v3",
        },
    }],
    "task_policy": None,
    "actor": "owner@example.com",
    "registered_at": "2026-07-11T03:20:00Z",
}
PY

registration_again="$(toolbox product context-registration alpha \
  --task-claim-id task__alpha__42-20260711T030000Z-1234 \
  --actor owner@example.com \
  --authority-receipt-file "$tmp/authority-receipt.json" \
  --registered-at 2026-07-11T03:20:00Z)"
[ "$registration" = "$registration_again" ] || fail "registration output is not deterministic"

python3 - "$tmp/authority-receipt.json" "$tmp" <<'PY'
import json
import pathlib
import sys

source = json.loads(pathlib.Path(sys.argv[1]).read_text())
root = pathlib.Path(sys.argv[2])

def write(name, mutate):
    document = dict(source)
    mutate(document)
    (root / name).write_text(json.dumps(document) + "\n")

write("receipt-unknown.json", lambda value: value.update({"unexpected": True}))
write("receipt-bad-ref.json", lambda value: value.update({"policy_ref": "products/beta/policy.conf"}))
write("receipt-bad-digest.json", lambda value: value.update({"policy_digest": "sha256:" + "b" * 64}))
write("receipt-bad-revision.json", lambda value: value.update({"authority_revision": "latest"}))
write("receipt-bad-issued-at.json", lambda value: value.update({"issued_at": "2026-02-31T03:00:00Z"}))
(root / "receipt-duplicate.json").write_text(
    pathlib.Path(sys.argv[1]).read_text().replace(
        '  "source_ref":', '  "actor": "duplicate@example.com",\n  "source_ref":'
    )
)
(root / "receipt-nan.json").write_text(
    pathlib.Path(sys.argv[1]).read_text().replace(
        '"toolbox:approval/policy-alpha-v3"', 'NaN'
    )
)
(root / "receipt-invalid-utf8.json").write_bytes(b'{"contract_version":"' + bytes([0xff]) + b'"}\n')
PY

registration_command=(
  toolbox product context-registration alpha
  --task-claim-id task__alpha__42-20260711T030000Z-1234
  --actor owner@example.com
  --registered-at 2026-07-11T03:20:00Z
)
expect_failure "contains unknown field 'unexpected'" \
  "${registration_command[@]}" --authority-receipt-file "$tmp/receipt-unknown.json"
expect_failure "policy_ref does not match the product policy" \
  "${registration_command[@]}" --authority-receipt-file "$tmp/receipt-bad-ref.json"
expect_failure "policy_digest does not match the product policy" \
  "${registration_command[@]}" --authority-receipt-file "$tmp/receipt-bad-digest.json"
expect_failure "authority_revision is invalid" \
  "${registration_command[@]}" --authority-receipt-file "$tmp/receipt-bad-revision.json"
expect_failure "issued_at must be an RFC 3339 UTC timestamp" \
  "${registration_command[@]}" --authority-receipt-file "$tmp/receipt-bad-issued-at.json"
expect_failure "duplicate JSON member 'actor'" \
  "${registration_command[@]}" --authority-receipt-file "$tmp/receipt-duplicate.json"
expect_failure "invalid JSON constant 'NaN'" \
  "${registration_command[@]}" --authority-receipt-file "$tmp/receipt-nan.json"
expect_failure "authority receipt is not valid UTF-8" \
  "${registration_command[@]}" --authority-receipt-file "$tmp/receipt-invalid-utf8.json"
expect_failure "missing authority receipt" \
  "${registration_command[@]}" --authority-receipt-file "$tmp/missing-receipt.json"

expect_failure "registered-at must be an RFC 3339 UTC timestamp" \
  toolbox product context-registration alpha \
    --task-claim-id claim --actor owner@example.com \
    --authority-receipt-file "$tmp/authority-receipt.json" --registered-at yesterday
expect_failure "registered-at must be an RFC 3339 UTC timestamp" \
  toolbox product context-registration alpha \
    --task-claim-id claim --actor owner@example.com \
    --authority-receipt-file "$tmp/authority-receipt.json" \
    --registered-at 2026-02-31T03:20:00Z

echo "PASS: canonical workbench policy bridge"
