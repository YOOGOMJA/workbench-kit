#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/workbench-upgrade-adapter.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
workspace="$tmp/workspace"
mkdir -p "$workspace"
git -C "$workspace" init -q
workspace="$(cd "$workspace" && pwd -P)"

probe() {
  local mode="$1"
  UPGRADE_STUB_MODE="$mode" \
  UPGRADE_STUB_LOG="$tmp/$mode.log" \
  WORKBENCH_KIT_WORKBENCH_BIN="$ROOT/tests/upgrade-public-stub.sh" \
  python3 - "$ROOT/lib" "$workspace" <<'PY'
import json
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from workbench_kit_adapter import AdapterError, inspect_public_kernel

try:
    snapshot = inspect_public_kernel(pathlib.Path(sys.argv[2]))
except AdapterError as error:
    print(json.dumps({"code": error.code, "ref": error.ref}, sort_keys=True))
    raise SystemExit(1)
print(json.dumps(snapshot, sort_keys=True, separators=(",", ":")))
PY
}

set +e
ok="$(probe ok)"
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
expected="$workspace"$'\t'"contract show --format json"$'\n'
expected+="$workspace"$'\t'"doctor --format json"$'\n'
expected+="$workspace"$'\t'"legacy-inventory show --format json"
[ "$(cat "$tmp/ok.log")" = "$expected" ] || {
  echo "unexpected public adapter calls" >&2
  cat "$tmp/ok.log" >&2
  exit 1
}

probe extra-field >/dev/null || { echo "unknown public field was rejected" >&2; exit 1; }

expect_failure() {
  local mode="$1" code="$2" output status
  set +e
  output="$(probe "$mode" 2>/dev/null)"
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

if rg -n '\.worktrees|plugins/workbench/utils|task/codebases' "$ROOT/lib" 2>/dev/null; then
  echo "workbench-kit adapter references private/runtime workbench state" >&2
  exit 1
fi

echo "PASS: strict public workbench adapter boundary"
