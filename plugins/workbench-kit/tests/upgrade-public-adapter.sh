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
for repo in "$legacy_workspace" "$current_workspace"; do
  git -C "$repo" config user.name Fixture
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" add -A
  git -C "$repo" commit --allow-empty -qm "fixture: public adapter"
done
legacy_workspace="$(cd "$legacy_workspace" && pwd -P)"
current_workspace="$(cd "$current_workspace" && pwd -P)"
approval="$tmp/bootstrap-authority-approval.json"
printf '%s\n' '{"contract_version":"workbench-bootstrap-authority-approval/v1","approval_id":"approval-fixture-1","proposed_descriptor":{"contract_version":"workbench-workspace-authority/v1","authority_identity":"github:example/workbench","origin_url":"https://github.com/example/workbench.git","default_ref":"refs/heads/main","workspace_home":"workbench","hosting_adapter":"github","hosting_ref":"github:repository/example/workbench"},"default_revision":"1111111111111111111111111111111111111111","protection":{"ref":"refs/heads/main","revision":"1111111111111111111111111111111111111111","direct_task_actor_writes":"blocked","verified_at":"2026-07-11T00:00:00Z","evidence_ref":"github:ruleset/example"},"actor":"github:user/example","approved_at":"2026-07-11T00:00:00Z","source_ref":"github:repository/example/workbench"}' > "$approval"
approval="$(cd "$(dirname "$approval")" && pwd -P)/$(basename "$approval")"

git_state_digest() {
  python3 - "$1" <<'PY'
import hashlib
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
git_dir = pathlib.Path(subprocess.check_output(
    ["git", "-C", str(root), "rev-parse", "--absolute-git-dir"]
).decode().strip())
parts = []
for command in (
    ("symbolic-ref", "-q", "HEAD"),
    ("rev-parse", "HEAD"),
    ("for-each-ref", "--format=%(refname)%00%(objectname)"),
    ("status", "--porcelain=v2", "--untracked-files=all"),
):
    parts.append(subprocess.run(
        ["git", "-C", str(root), *command], capture_output=True, check=False
    ).stdout)
for name in ("index", "FETCH_HEAD"):
    path = git_dir / name
    parts.append(name.encode() + b"\0" + (path.read_bytes() if path.exists() else b"<absent>"))
for current, directories, files in os.walk(root, topdown=True, followlinks=False):
    directories[:] = sorted(item for item in directories if item != ".git")
    for name in sorted(files):
        path = pathlib.Path(current) / name
        relative = path.relative_to(root).as_posix().encode()
        if path.is_symlink():
            parts.append(b"L\0" + relative + b"\0" + os.readlink(path).encode())
        else:
            parts.append(b"F\0" + relative + b"\0" + path.read_bytes())
print(hashlib.sha256(b"\0".join(parts)).hexdigest())
PY
}

probe() {
  local mode="$1" workspace="$2" authority_file="${3:--}" \
    inventory_mode="${4:--}" include_manifest="${5:-false}"
  UPGRADE_STUB_MODE="$mode" \
  UPGRADE_STUB_LOG="$tmp/$mode.log" \
  UPGRADE_STUB_APPROVAL_FILE="$approval" \
  WORKBENCH_KIT_WORKBENCH_BIN="$ROOT/tests/upgrade-public-stub.sh" \
  python3 - "$ROOT/lib" "$workspace" "$authority_file" "$inventory_mode" \
    "$include_manifest" <<'PY'
import json
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from workbench_kit_adapter import AdapterError, inspect_public_kernel

try:
    approval = None if sys.argv[3] == "-" else pathlib.Path(sys.argv[3])
    inventory_mode = None if sys.argv[4] == "-" else sys.argv[4]
    snapshot = inspect_public_kernel(
        pathlib.Path(sys.argv[2]), approval, inventory_mode, sys.argv[5] == "true"
    )
except AdapterError as error:
    print(json.dumps({"code": error.code, "ref": error.ref}, sort_keys=True))
    raise SystemExit(1)
print(json.dumps(snapshot, sort_keys=True, separators=(",", ":")))
PY
}

set +e
legacy_git_before="$(git_state_digest "$legacy_workspace")"
ok="$(probe ok "$legacy_workspace" "$approval")"
status=$?
set -e
[ "$status" -eq 0 ] || { echo "$ok" >&2; exit 1; }
[ "$legacy_git_before" = "$(git_state_digest "$legacy_workspace")" ] \
  || { echo "legacy public calls mutated caller Git state" >&2; exit 1; }
python3 - "$ok" <<'PY'
import json
import sys
snapshot = json.loads(sys.argv[1])
assert snapshot["contract"]["workspace"]["schema"] == "workbench/v1"
assert snapshot["doctor"]["ready"] is False
assert snapshot["legacy_inventory"]["complete"] is True
assert snapshot["active_v1_tasks"] == [{
    "source": "legacy-inventory:homes[].claims",
    "home": "workbench",
    "claim_id": "task__workbench__55-legacy",
    "task_claim_id": "task__workbench__55-legacy",
    "task_contract": "workbench-task/v1",
    "issue": 55,
    "parent": None,
    "branch": "task/55-legacy",
    "lifecycle_state": "task-claimed",
    "lifecycle_digest": "sha256:" + "c" * 64,
    "source_revision": "2" * 40,
    "pr_head_revision": None,
    "ancestry_complete": True,
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

current_git_before="$(git_state_digest "$current_workspace")"
v2="$(probe v2-ok "$current_workspace")" || { echo "$v2" >&2; exit 1; }
[ "$current_git_before" = "$(git_state_digest "$current_workspace")" ] \
  || { echo "v2 public calls mutated caller Git state" >&2; exit 1; }
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

staged="$(probe staged-v2 "$current_workspace" "$approval" bootstrap-show)" \
  || { echo "$staged" >&2; exit 1; }
python3 - "$staged" <<'PY'
import json
import sys
snapshot = json.loads(sys.argv[1])
assert snapshot["contract"]["workspace"]["schema"] == "workbench/v2"
assert snapshot["doctor"]["ready"] is False
assert snapshot["legacy_inventory_command"] == "bootstrap-show"
PY
expected_staged="$current_workspace"$'\t'"contract show --format json"$'\n'
expected_staged+="$current_workspace"$'\t'"doctor --format json"$'\n'
expected_staged+="$current_workspace"$'\t'"legacy-inventory bootstrap-show --authority-approval-file $approval --format json"
[ "$(cat "$tmp/staged-v2.log")" = "$expected_staged" ] || {
  cat "$tmp/staged-v2.log" >&2
  exit 1
}

removal="$(probe removal "$current_workspace" - show true)" \
  || { echo "$removal" >&2; exit 1; }
python3 - "$removal" <<'PY'
import json
import sys
snapshot = json.loads(sys.argv[1])
assert snapshot["engine_manifest"]["plugin"] == {
    "name": "workbench", "version": "0.2.0"
}
PY
expected_removal="$current_workspace"$'\t'"contract show --format json"$'\n'
expected_removal+="$current_workspace"$'\t'"doctor --format json"$'\n'
expected_removal+="$current_workspace"$'\t'"legacy-inventory show --format json"$'\n'
expected_removal+="$current_workspace"$'\t'"engine-manifest show --format json"
[ "$(cat "$tmp/removal.log")" = "$expected_removal" ] || {
  cat "$tmp/removal.log" >&2
  exit 1
}

inventory="$({
  cd "$current_workspace"
  UPGRADE_STUB_MODE=v2-ok UPGRADE_STUB_APPROVAL_FILE="$approval" \
    "$ROOT/tests/upgrade-public-stub.sh" legacy-inventory show --format json
})"
python3 - "$ROOT/lib" "$inventory" <<'PY'
import copy
import json
import sys

sys.path.insert(0, sys.argv[1])
from workbench_kit_adapter import AdapterError, validate_inventory

valid = json.loads(sys.argv[2])
tasks = validate_inventory(valid, 0, "show")
assert len(tasks) == 1 and tasks[0]["issue"] == 55
assert valid["homes"][0]["claims"][0]["classification"] == "cleaned-v1"
assert valid["homes"][0]["claims"][0]["ancestry_complete"] is False

def rejected(mutator):
    candidate = copy.deepcopy(valid)
    mutator(candidate)
    try:
        validate_inventory(candidate, 0, "show")
    except AdapterError as error:
        assert error.code == "legacy-inventory-unavailable"
    else:
        raise AssertionError("invalid nested inventory was accepted")

rejected(lambda value: value["authority"].update({"future": True}))
rejected(lambda value: value["homes"][0]["claims"][1].update({
    "task_claim_id": "task__workbench__55-mismatch"
}))
rejected(lambda value: value["homes"][0]["claims"][1].update({
    "ancestry_complete": False
}))
rejected(lambda value: value.update({"active_claims": [{
    "source": "legacy-v1", "claim_id": "wrong", "operation_id": None,
    "task_claim_id": "wrong", "owner": "workbench", "branch": "task/wrong",
    "context_policy_set_digest": None, "source_revision": "2" * 40,
    "pr_head_revision": None, "lifecycle_digest": "sha256:" + "c" * 64,
}]}))
rejected(lambda value: value["origin_replacements"][0].update({"status": "unavailable"}))
rejected(lambda value: value.update({
    "authority": dict(reversed(list(value["authority"].items())))
}))
PY

expect_failure() {
  local mode="$1" code="$2" workspace="${3:-$legacy_workspace}" \
    authority_file="${4:-$approval}" inventory_mode="${5:--}" \
    include_manifest="${6:-false}" output status
  set +e
  output="$(probe "$mode" "$workspace" "$authority_file" "$inventory_mode" \
    "$include_manifest" 2>/dev/null)"
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
expect_failure doctor-extra public-contract-invalid
expect_failure inventory-incomplete legacy-inventory-unavailable
expect_failure missing-bootstrap-contract public-contract-missing
expect_failure missing-bootstrap-capability public-capability-missing
expect_failure no-approval bootstrap-authority-approval-required "$legacy_workspace" -
expect_failure missing-manifest-contract public-contract-missing "$current_workspace" - show true
expect_failure missing-manifest-capability public-capability-missing "$current_workspace" - show true
expect_failure manifest-bad-digest public-contract-invalid "$current_workspace" - show true

if rg -n '\.worktrees|plugins/workbench/utils|task/codebases' \
  "$ROOT/lib/workbench_kit_adapter.py" 2>/dev/null; then
  echo "workbench-kit adapter references private/runtime workbench state" >&2
  exit 1
fi

echo "PASS: strict public workbench adapter boundary"
