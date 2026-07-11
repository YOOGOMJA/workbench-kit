#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/workbench-upgrade-adapter.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
legacy_workspace="$tmp/legacy-workspace"
current_workspace="$tmp/current-workspace"
linked_source="$tmp/linked-source"
linked_workspace="$tmp/linked-workspace"
mkdir -p "$legacy_workspace" "$current_workspace/.workbench" "$linked_source"
printf 'workbench/v2\n' > "$current_workspace/.workbench/schema"
git -C "$legacy_workspace" init -q
git -C "$current_workspace" init -q
for repo in "$legacy_workspace" "$current_workspace"; do
  git -C "$repo" config user.name Fixture
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" add -A
  git -C "$repo" commit --allow-empty -qm "fixture: public adapter"
done
git -C "$linked_source" init -q
git -C "$linked_source" config user.name Fixture
git -C "$linked_source" config user.email fixture@example.invalid
git -C "$linked_source" commit --allow-empty -qm "fixture: linked public adapter"
git -C "$linked_source" worktree add -qb task/27-linked "$linked_workspace"
legacy_workspace="$(cd "$legacy_workspace" && pwd -P)"
current_workspace="$(cd "$current_workspace" && pwd -P)"
linked_workspace="$(cd "$linked_workspace" && pwd -P)"
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
common_dir = pathlib.Path(subprocess.check_output([
    "git", "-C", str(root), "rev-parse", "--path-format=absolute",
    "--git-common-dir",
]).decode().strip())
parts = []

pointer = root / ".git"
pointer_node = os.lstat(pointer)
if pointer.is_dir():
    parts.append(b"P\0directory\0" + oct(pointer_node.st_mode & 0o7777).encode())
elif pointer.is_file():
    parts.append(
        b"P\0file\0" + oct(pointer_node.st_mode & 0o7777).encode()
        + b"\0" + pointer.read_bytes()
    )
else:
    parts.append(b"P\0link\0" + os.readlink(pointer).encode())

for admin_root in sorted({git_dir, common_dir}, key=str):
    label = str(admin_root).encode()
    for current, directories, files in os.walk(
        admin_root, topdown=True, followlinks=False
    ):
        current_path = pathlib.Path(current)
        relative_root = current_path.relative_to(admin_root)
        if admin_root == common_dir and relative_root == pathlib.Path("objects"):
            directories[:] = []
            files[:] = []
        directories[:] = sorted(directories)
        for name in sorted(directories + files):
            path = current_path / name
            relative = (relative_root / name).as_posix().encode()
            node = os.lstat(path)
            mode = oct(node.st_mode & 0o7777).encode()
            if path.is_symlink():
                payload = b"L\0" + os.readlink(path).encode()
            elif path.is_dir():
                payload = b"D"
            else:
                payload = b"F\0" + path.read_bytes()
            parts.append(b"G\0" + label + b"\0" + relative + b"\0" + mode + b"\0" + payload)
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
  PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/lib" "$workspace" "$authority_file" "$inventory_mode" \
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
print(json.dumps(snapshot, separators=(",", ":")))
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
import hashlib
import json
import sys
snapshot = json.loads(sys.argv[1])

def digest(value):
    raw = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    return "sha256:" + hashlib.sha256(raw).hexdigest()

def raw_digest(value):
    raw = (json.dumps(value, separators=(",", ":")) + "\n").encode()
    return "sha256:" + hashlib.sha256(raw).hexdigest()

assert snapshot["contract"]["workspace"]["schema"] == "workbench/v1"
assert snapshot["doctor"]["ready"] is False
assert snapshot["legacy_inventory"]["complete"] is True
expected_doctor_projection = {
    "contract_version": "workbench-doctor/v1",
    "ready": False,
    "object_digest": digest(snapshot["doctor"]),
    "source_digest": raw_digest(snapshot["doctor"]),
    "writer_coordination_digest": digest(snapshot["doctor"]["writer_coordination"]),
}
assert snapshot["doctor_projection"] == expected_doctor_projection, (
    snapshot["doctor_projection"], expected_doctor_projection
)
expected_inventory_projection = {
    "contract_version": "workbench-legacy-inventory/v1",
    "command": "bootstrap-show",
    "object_digest": digest(snapshot["legacy_inventory"]),
    "source_digest": raw_digest(snapshot["legacy_inventory"]),
    "authority_revision": "1" * 40,
    "home_set_digest": "sha256:" + "b" * 64,
    "complete": True,
}
assert snapshot["legacy_inventory_projection"] == expected_inventory_projection, (
    snapshot["legacy_inventory_projection"], expected_inventory_projection
)
assert snapshot["active_v1_tasks"] == [{
    "source": "legacy-inventory:homes[].claims",
    "home": "workbench",
    "claim_id": "claim-27",
    "task_claim_id": "claim-27",
    "task_contract": "workbench-task/v1",
    "issue": 27,
    "parent": None,
    "branch": "task/27-upgrade",
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

probe task-status-with-v1 "$current_workspace" >/dev/null \
  || { echo "unrelated local-only v1 status row was rejected" >&2; exit 1; }

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
assert snapshot["migration_task_claim"]["claim_id"] == "claim-27"
assert snapshot["migration_task_claim"]["task_id"] == "27"
assert snapshot["migration_task_claim"]["issue"] == 27
assert snapshot["migration_task_claim"]["home"] is None
assert snapshot["migration_task_claim"]["parent"] is None
assert snapshot["migration_task_claim"]["task_contract"] == "workbench-task/v2"
assert snapshot["migration_task_claim"]["branch"]
assert snapshot["migration_task_claim"]["workspace_authority_descriptor_digest"].startswith(
    "sha256:"
)
assert snapshot["migration_task_claim"]["context_ref"] is None
assert snapshot["migration_task_claim"]["work_ref"] is None
assert snapshot["migration_task_claim"]["work_owners"] == []
PY
expected_v2="$current_workspace"$'\t'"contract show --format json"$'\n'
expected_v2+="$current_workspace"$'\t'"doctor --format json"$'\n'
expected_v2+="$current_workspace"$'\t'"legacy-inventory show --format json"
expected_v2+=$'\n'"$current_workspace"$'\t'"task status --format json"
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
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/lib" "$removal" <<'PY'
import copy
import hashlib
import json
import sys

sys.path.insert(0, sys.argv[1])
from workbench_kit_adapter import AdapterError, validate_doctor, validate_engine_manifest

snapshot = json.loads(sys.argv[2])
assert snapshot["engine_manifest"]["plugin"] == {
    "name": "workbench", "version": "0.2.0"
}
projection = snapshot["engine_manifest_projection"]
assert projection["contract_version"] == "workbench-plugin-manifest/v1"
assert projection["command"] == "engine-manifest show"
assert projection["content_revision"] == snapshot["engine_manifest"]["source"]["revision"]
assert projection["manifest_digest"] == snapshot["engine_manifest"]["digest"]
assert projection["object_digest"].startswith("sha256:")
assert projection["source_digest"].startswith("sha256:")

def line(value):
    return (json.dumps(value, separators=(",", ":")) + "\n").encode()

def digest(raw):
    return "sha256:" + hashlib.sha256(raw).hexdigest()

def resign(document):
    tree = bytearray(b"workbench-plugin-tree/v1\n")
    for path in document["included_paths"]:
        tree.extend(line(["included_path", path]))
    for item in document["excluded_paths"]:
        tree.extend(line(["excluded_path", item["path"], item["match"]]))
    for node in document["nodes"]:
        tree.extend(line([
            "node", node["path"], node["node_type"], node["mode"],
            node["digest"], node["link_target"],
        ]))
    document["source"]["revision"] = digest(bytes(tree))
    document["digest"] = None
    document["digest"] = digest(line(document))

def rejected(document):
    try:
        validate_engine_manifest(document, "0.2.0")
    except AdapterError:
        return
    raise AssertionError("invalid manifest topology was accepted")

bad = copy.deepcopy(snapshot["engine_manifest"])
bad["nodes"][1]["digest"] = "sha256:" + "e" * 64
resign(bad)
rejected(bad)

bad = copy.deepcopy(snapshot["engine_manifest"])
bad["nodes"][2]["path"] = "other/workbench"
resign(bad)
rejected(bad)

bad = copy.deepcopy(snapshot["engine_manifest"])
bad["nodes"][2]["path"] = "task/codebases/embedded"
resign(bad)
rejected(bad)

def doctor_rejected(mutator):
    bad_doctor = copy.deepcopy(snapshot["doctor"])
    mutator(bad_doctor["writer_coordination"])
    try:
        validate_doctor(bad_doctor, 0)
    except AdapterError:
        return
    raise AssertionError("invalid authority grammar was accepted")

doctor_rejected(lambda value: value.update({"default_ref": "refs/heads/a/../b"}))
doctor_rejected(lambda value: value.update({"default_ref": "refs/heads/a//b"}))
doctor_rejected(lambda value: value.update({
    "origin_url": "git@github.com:example/workbench.git"
}))
reordered_doctor = copy.deepcopy(snapshot["doctor"])
reordered_doctor["writer_coordination"] = dict(reversed(list(
    reordered_doctor["writer_coordination"].items()
)))
reordered_doctor = dict(reversed(list(reordered_doctor.items())))
validate_doctor(reordered_doctor, 0)

reordered_manifest = copy.deepcopy(snapshot["engine_manifest"])
reordered_manifest["plugin"] = dict(reversed(list(
    reordered_manifest["plugin"].items()
)))
reordered_manifest = dict(reversed(list(reordered_manifest.items())))
validate_engine_manifest(reordered_manifest, "0.2.0")
PY
expected_removal="$current_workspace"$'\t'"contract show --format json"$'\n'
expected_removal+="$current_workspace"$'\t'"doctor --format json"$'\n'
expected_removal+="$current_workspace"$'\t'"legacy-inventory show --format json"$'\n'
expected_removal+="$current_workspace"$'\t'"engine-manifest show --format json"
expected_removal+=$'\n'"$current_workspace"$'\t'"task status --format json"
[ "$(cat "$tmp/removal.log")" = "$expected_removal" ] || {
  cat "$tmp/removal.log" >&2
  exit 1
}

inventory="$({
  cd "$current_workspace"
  UPGRADE_STUB_MODE=v2-ok UPGRADE_STUB_APPROVAL_FILE="$approval" \
    "$ROOT/tests/upgrade-public-stub.sh" legacy-inventory show --format json
})"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/lib" "$inventory" <<'PY'
import copy
import json
import sys

sys.path.insert(0, sys.argv[1])
from workbench_kit_adapter import AdapterError, validate_inventory

valid = json.loads(sys.argv[2])
tasks = validate_inventory(valid, 0, "show")
assert len(tasks) == 1 and tasks[0]["issue"] == 27
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
rejected(lambda value: value["authority"].update({
    "default_ref": "refs/heads/a/../b"
}))
rejected(lambda value: value["authority"].update({
    "default_ref": "refs/heads/a//b"
}))
rejected(lambda value: value["homes"][0]["claims"][1].update({
    "task_claim_id": "claim-mismatch"
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
reordered = copy.deepcopy(valid)
reordered["authority"] = dict(reversed(list(reordered["authority"].items())))
assert validate_inventory(reordered, 0, "show") == tasks
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
expect_failure task-status-duplicate public-task-status-invalid "$current_workspace" - show
expect_failure task-status-blocker public-adapter-exit "$current_workspace" - show

mutating_before="$(git_state_digest "$current_workspace")"
expect_failure mutate-state public-adapter-mutated "$current_workspace" - show
[ "$mutating_before" = "$(git_state_digest "$current_workspace")" ] || {
  echo "mutating public adapter was not fully restored" >&2
  exit 1
}

admin_before="$(git_state_digest "$current_workspace")"
expect_failure mutate-git-admin public-adapter-mutated "$current_workspace" - show
[ "$admin_before" = "$(git_state_digest "$current_workspace")" ] || {
  echo "Git control state was not restored exactly" >&2
  exit 1
}
common_dir="$(git -C "$current_workspace" rev-parse --path-format=absolute --git-common-dir)"
[ -f "$common_dir/objects/ff/00000000000000000000000000000000000000" ] || {
  echo "newly fetched object cache data was removed" >&2
  exit 1
}

pointer_before="$(git_state_digest "$linked_workspace")"
expect_failure mutate-git-pointer public-adapter-mutated "$linked_workspace" "$approval"
[ "$pointer_before" = "$(git_state_digest "$linked_workspace")" ] || {
  echo "linked-worktree .git pointer was not restored exactly" >&2
  exit 1
}
git -C "$linked_workspace" status --porcelain=v2 >/dev/null

UPGRADE_STUB_MODE=mutate-state \
UPGRADE_STUB_APPROVAL_FILE="$approval" \
WORKBENCH_KIT_WORKBENCH_BIN="$ROOT/tests/upgrade-public-stub.sh" \
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/lib" "$current_workspace" <<'PY'
import pathlib
import subprocess
import sys

sys.path.insert(0, sys.argv[1])
import workbench_kit_adapter as adapter

workspace = pathlib.Path(sys.argv[2])
common = pathlib.Path(subprocess.check_output([
    "git", "-C", str(workspace), "rev-parse", "--path-format=absolute",
    "--git-common-dir",
]).decode().strip())
original = adapter._restore_caller_state
third_party = b"[upgrade]\n\tconcurrent = preserved\n"

def race_restore(root, before, *remaining):
    (common / "config").write_bytes(third_party)
    return original(root, before, *remaining)

adapter._restore_caller_state = race_restore
try:
    try:
        adapter.inspect_public_kernel(workspace, inventory_mode="show")
    except adapter.AdapterError as error:
        assert error.code == "public-adapter-restore-failed", error.code
    else:
        raise AssertionError("concurrent Git admin mutation was overwritten")
finally:
    adapter._restore_caller_state = original
assert (common / "config").read_bytes() == third_party
PY

if rg -n '\.worktrees|plugins/workbench/utils|task/codebases' \
  "$ROOT/lib/workbench_kit_adapter.py" 2>/dev/null; then
  echo "workbench-kit adapter references private/runtime workbench state" >&2
  exit 1
fi

echo "PASS: strict public workbench adapter boundary"

if find "$ROOT" -type d -name __pycache__ -print -quit | grep -q .; then
  echo "Python bytecode cache escaped upgrade tests" >&2
  exit 1
fi
