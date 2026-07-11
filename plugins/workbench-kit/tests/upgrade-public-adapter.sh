#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/workbench-upgrade-adapter.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
legacy_workspace="$tmp/legacy-workspace"
current_workspace="$tmp/current-workspace"
mkdir -p "$legacy_workspace" "$current_workspace/.workbench"
printf 'workbench/v2\n' > "$current_workspace/.workbench/schema"
git -C "$legacy_workspace" init -q
git -C "$current_workspace" init -q
legacy_workspace="$(cd "$legacy_workspace" && pwd -P)"
current_workspace="$(cd "$current_workspace" && pwd -P)"
approval="$tmp/bootstrap-authority-approval.json"
printf '%s\n' '{"contract_version":"workbench-bootstrap-authority-approval/v1","approval_id":"approval-fixture-1","proposed_descriptor":{"contract_version":"workbench-workspace-authority/v1","authority_identity":"github:example/workbench","origin_url":"https://github.com/example/workbench.git","default_ref":"refs/heads/main","workspace_home":"workbench","hosting_adapter":"github","hosting_ref":"github:repository/example/workbench"},"default_revision":"1111111111111111111111111111111111111111","protection":{"ref":"refs/heads/main","revision":"1111111111111111111111111111111111111111","direct_task_actor_writes":"blocked","verified_at":"2026-07-11T00:00:00Z","evidence_ref":"github:ruleset/example"},"actor":"github:user/example","approved_at":"2026-07-11T00:00:00Z","source_ref":"github:repository/example/workbench"}' > "$approval"
approval="$(cd "$(dirname "$approval")" && pwd -P)/$(basename "$approval")"

probe() {
  local mode="$1" workspace="$2" authority_file="${3:--}"
  UPGRADE_STUB_MODE="$mode" \
  UPGRADE_STUB_LOG="$tmp/$mode.log" \
  UPGRADE_STUB_APPROVAL_FILE="$approval" \
  WORKBENCH_KIT_WORKBENCH_BIN="$ROOT/tests/upgrade-public-stub.sh" \
  python3 - "$ROOT/lib" "$workspace" "$authority_file" <<'PY'
import json
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from workbench_kit_adapter import AdapterError, inspect_public_kernel

try:
    approval = None if sys.argv[3] == "-" else pathlib.Path(sys.argv[3])
    snapshot = inspect_public_kernel(pathlib.Path(sys.argv[2]), approval)
except AdapterError as error:
    print(json.dumps({"code": error.code, "ref": error.ref}, sort_keys=True))
    raise SystemExit(1)
print(json.dumps(snapshot, sort_keys=True, separators=(",", ":")))
PY
}

set +e
ok="$(probe ok "$legacy_workspace" "$approval")"
status=$?
set -e
[ "$status" -eq 0 ] || { echo "$ok" >&2; exit 1; }
python3 - "$ok" <<'PY'
import json
import sys
snapshot = json.loads(sys.argv[1])
assert snapshot["contract"]["workspace"]["schema"] == "workbench/v1"
assert snapshot["doctor"]["ready"] is False
assert snapshot["legacy_inventory"]["complete"] is True
assert snapshot["active_v1_tasks"] == [{
    "branch": "task/55-legacy",
    "claim_id": "legacy-claim-1",
    "home": "workbench",
    "issue": 55,
    "lifecycle_digest": "sha256:" + "c" * 64,
    "source_revision": "2" * 40,
    "task_claim_id": "task__workbench__55-legacy",
}]
PY
expected="$legacy_workspace"$'\t'"contract show --format json"$'\n'
expected+="$legacy_workspace"$'\t'"doctor --format json"$'\n'
expected+="$legacy_workspace"$'\t'"legacy-inventory bootstrap-show --authority-approval-file $approval --format json"
[ "$(cat "$tmp/ok.log")" = "$expected" ] || {
  echo "unexpected public adapter calls" >&2
  cat "$tmp/ok.log" >&2
  exit 1
}

probe extra-field "$legacy_workspace" "$approval" >/dev/null \
  || { echo "unknown public field was rejected" >&2; exit 1; }

v2="$(probe v2-ok "$current_workspace")" || { echo "$v2" >&2; exit 1; }
python3 - "$v2" <<'PY'
import json
import sys
snapshot = json.loads(sys.argv[1])
assert snapshot["contract"]["workspace"]["schema"] == "workbench/v2"
assert snapshot["legacy_inventory_command"] == "show"
PY
expected_v2="$current_workspace"$'\t'"contract show --format json"$'\n'
expected_v2+="$current_workspace"$'\t'"doctor --format json"$'\n'
expected_v2+="$current_workspace"$'\t'"legacy-inventory show --format json"
[ "$(cat "$tmp/v2-ok.log")" = "$expected_v2" ] || fail=1
[ "${fail:-0}" -eq 0 ] || { cat "$tmp/v2-ok.log" >&2; exit 1; }

expect_failure() {
  local mode="$1" code="$2" workspace="${3:-$legacy_workspace}" \
    authority_file="${4:-$approval}" output status
  set +e
  output="$(probe "$mode" "$workspace" "$authority_file" 2>/dev/null)"
  status=$?
  set -e
  [ "$status" -eq 1 ] || { echo "expected $mode failure" >&2; exit 1; }
  grep -Fq "\"code\": \"$code\"" <<<"$output" || {
    echo "missing $code for $mode: $output" >&2
    exit 1
  }
}

expect_failure bad-root caller-root-mismatch
expect_failure stderr public-adapter-stderr
expect_failure duplicate-json public-json-invalid
expect_failure doctor-bad-exit public-adapter-exit
expect_failure inventory-incomplete legacy-inventory-unavailable
expect_failure missing-bootstrap-contract public-contract-missing
expect_failure missing-bootstrap-capability public-capability-missing
expect_failure no-approval bootstrap-authority-approval-required "$legacy_workspace" -

if rg -n '\.worktrees|plugins/workbench/utils|task/codebases' "$ROOT/lib" 2>/dev/null; then
  echo "workbench-kit adapter references private/runtime workbench state" >&2
  exit 1
fi

echo "PASS: strict public workbench adapter boundary"
