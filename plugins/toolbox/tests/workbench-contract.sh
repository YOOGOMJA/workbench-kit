#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLBOX="$ROOT/bin/toolbox"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/toolbox-contract.XXXXXX")"
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

make_fake_workbench() {
  local path="$1" body="$2"
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ "\$#" -eq 4 ] || { echo "unexpected argument count: \$#" >&2; exit 91; }
[ "\$1" = contract ] && [ "\$2" = show ] && [ "\$3" = --format ] && [ "\$4" = json ] \
  || { echo "unexpected arguments: \$*" >&2; exit 92; }
$body
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

wb="$tmp/supported"
make_workspace "$wb"
make_fake_workbench "$tmp/workbench-supported" \
  'printf '\''{"contract_version":"workbench-contract/v1","engine":{"name":"workbench","version":"0.2.0"},"workspace":{"root":"%s","schema":"workbench/v2","source":"marker"},"supported":{"workspace_schemas":{"read":["workbench/v1","workbench/v2"],"write":["workbench/v2"]},"lifecycle_markers":{"read":["workbench-task-lifecycle:v1","workbench-task-lifecycle:v2"],"write":["workbench-task-lifecycle:v2"]},"policy_contracts":["workbench-policy/v1"],"evidence_contracts":["workbench-evidence/v1"],"capability_pack_contracts":["workbench-capability-pack/v1"]},"capabilities":["workspace.schema/v1","task.refs/v1","task.deliverables/v1","task.lifecycle/v2","task.evidence/v1","task.completion/v1","policy.resolve/v1"]}\n'\'' "$PWD"'

out="$(TOOLBOX_WORKBENCH_BIN="$tmp/workbench-supported" \
  "$TOOLBOX" --workspace "$wb" workbench check)" \
  || fail "supported workbench contract was rejected"
[ -n "$out" ] || fail "supported contract check produced no JSON"
[[ "$out" == \{* ]] || fail "supported contract check produced non-JSON output: $out"

python3 - "$out" "$wb" <<'PY'
import json
import pathlib
import sys

actual = json.loads(sys.argv[1])
expected_root = str(pathlib.Path(sys.argv[2]).resolve())
assert actual == {
    "compatible": True,
    "contract_version": "workbench-contract/v1",
    "workspace_root": expected_root,
    "workspace_schema": "workbench/v2",
}
PY

wb_legacy="$tmp/legacy"
make_workspace "$wb_legacy"
make_fake_workbench "$tmp/workbench-legacy" \
  'printf '\''{"contract_version":"workbench-contract/v1","engine":{"name":"workbench","version":"0.2.0"},"workspace":{"root":"%s","schema":"workbench/v1","source":"implicit"},"supported":{"workspace_schemas":{"read":["workbench/v1","workbench/v2"],"write":["workbench/v2"]},"capability_pack_contracts":["workbench-capability-pack/v1"]}}\n'\'' "$PWD"'
expect_failure "unsupported caller workspace schema 'workbench/v1'" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/workbench-legacy" \
  "$TOOLBOX" --workspace "$wb_legacy" workbench check

wb_malformed="$tmp/malformed"
make_workspace "$wb_malformed"
make_fake_workbench "$tmp/workbench-malformed" 'printf '\''not-json\n'\'''
expect_failure "returned malformed JSON" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/workbench-malformed" \
  "$TOOLBOX" --workspace "$wb_malformed" workbench check

expect_failure "workbench CLI is unavailable" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/does-not-exist" \
  "$TOOLBOX" --workspace "$wb" workbench check

make_fake_workbench "$tmp/workbench-future" \
  'printf '\''{"contract_version":"workbench-contract/v9","workspace":{"root":"%s","schema":"workbench/v2"}}\n'\'' "$PWD"'
expect_failure "unsupported workbench contract 'workbench-contract/v9'" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/workbench-future" \
  "$TOOLBOX" --workspace "$wb" workbench check

make_fake_workbench "$tmp/workbench-read-only" \
  'printf '\''{"contract_version":"workbench-contract/v1","engine":{"name":"workbench","version":"0.2.0"},"workspace":{"root":"%s","schema":"workbench/v2","source":"marker"},"supported":{"workspace_schemas":{"read":["workbench/v2"],"write":[]},"capability_pack_contracts":["workbench-capability-pack/v1"]}}\n'\'' "$PWD"'
expect_failure "does not allow toolbox state mutation for 'workbench/v2'" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/workbench-read-only" \
  "$TOOLBOX" --workspace "$wb" workbench check

make_fake_workbench "$tmp/workbench-no-pack-contract" \
  'printf '\''{"contract_version":"workbench-contract/v1","engine":{"name":"workbench","version":"0.2.0"},"workspace":{"root":"%s","schema":"workbench/v2","source":"marker"},"supported":{"workspace_schemas":{"read":["workbench/v2"],"write":["workbench/v2"]},"capability_pack_contracts":[]},"capabilities":["workspace.schema/v1"]}\n'\'' "$PWD"'
expect_failure "does not support 'workbench-capability-pack/v1'" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/workbench-no-pack-contract" \
  "$TOOLBOX" --workspace "$wb" workbench check

make_fake_workbench "$tmp/workbench-no-workspace-capability" \
  'printf '\''{"contract_version":"workbench-contract/v1","engine":{"name":"workbench","version":"0.2.0"},"workspace":{"root":"%s","schema":"workbench/v2","source":"marker"},"supported":{"workspace_schemas":{"read":["workbench/v2"],"write":["workbench/v2"]},"capability_pack_contracts":["workbench-capability-pack/v1"]},"capabilities":[]}\n'\'' "$PWD"'
expect_failure "missing required capability 'workspace.schema/v1'" \
  env TOOLBOX_WORKBENCH_BIN="$tmp/workbench-no-workspace-capability" \
  "$TOOLBOX" --workspace "$wb" workbench check

echo "PASS: public workbench compatibility contract"
