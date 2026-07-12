#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/workbench-upgrade-adapter.XXXXXX")"
trap 'chmod -R u+rwx "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT
legacy_workspace="$tmp/legacy-workspace"
current_workspace="$tmp/current-workspace"
linked_source="$tmp/linked-source"
linked_workspace="$tmp/linked-workspace"
mkdir -p "$legacy_workspace" "$current_workspace/.workbench" "$linked_source"
printf 'workbench/v2\n' > "$current_workspace/.workbench/schema"
mkdir -p "$current_workspace/sealed"
printf 'sealed\n' > "$current_workspace/sealed/owned"
mkdir -p "$current_workspace/nested/parent/child"
printf 'nested\n' > "$current_workspace/nested/parent/child/owned"
git -C "$legacy_workspace" init -q
git -C "$current_workspace" init -q
for repo in "$legacy_workspace" "$current_workspace"; do
  git -C "$repo" config user.name Fixture
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" add -A
  git -C "$repo" commit --allow-empty -qm "fixture: public adapter"
done
mkdir -p "$current_workspace/.git/adapter-owned/child"
printf 'admin\n' > "$current_workspace/.git/adapter-owned/child/owned"
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
        directories[:] = sorted(
            item for item in directories
            if not item.startswith(".workbench-kit-private-")
        )
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
    directories[:] = sorted(
        item for item in directories
        if item != ".git" and not item.startswith(".workbench-kit-private-")
    )
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

mode_of() {
  python3 - "$1" <<'PY'
import os
import sys
print(oct(os.stat(sys.argv[1]).st_mode & 0o7777))
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
if find "$legacy_workspace" -name '.workbench-kit-private-*' -print -quit | grep -q .; then
  echo "read-only public adapter left a private residue" >&2
  exit 1
fi
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
expect_failure mutate-state public-adapter-restore-failed "$current_workspace" - show
[ "$mutating_before" = "$(git_state_digest "$current_workspace")" ] || {
  echo "mutating public adapter was not fully restored" >&2
  exit 1
}
find "$current_workspace" -path '*/.workbench-kit-private-*/node' \
  -type f -exec grep -Fq 'public adapter mutation' {} \; -print -quit \
  | grep -q . || {
  echo "worktree mutation was not preserved as a private residue" >&2
  exit 1
}

admin_before="$(git_state_digest "$current_workspace")"
expect_failure mutate-git-admin public-adapter-restore-failed "$current_workspace" - show
[ "$admin_before" = "$(git_state_digest "$current_workspace")" ] || {
  echo "Git control state was not restored exactly" >&2
  exit 1
}
common_dir="$(git -C "$current_workspace" rev-parse --path-format=absolute --git-common-dir)"
[ -f "$common_dir/objects/ff/00000000000000000000000000000000000000" ] || {
  echo "newly fetched object cache data was removed" >&2
  exit 1
}
find "$common_dir" -path '*/.workbench-kit-private-*/node' \
  -type f -exec grep -Fq 'admin = mutated' {} \; -print -quit \
  | grep -q . || {
  echo "Git admin mutation was not preserved as a private residue" >&2
  exit 1
}

pointer_before="$(git_state_digest "$linked_workspace")"
expect_failure mutate-git-pointer public-adapter-restore-failed "$linked_workspace" "$approval"
[ "$pointer_before" = "$(git_state_digest "$linked_workspace")" ] || {
  echo "linked-worktree .git pointer was not restored exactly" >&2
  exit 1
}
find "$linked_workspace" -path '*/.workbench-kit-private-*/node' \
  -type f -exec grep -Fq 'workbench-kit-mutated' {} \; -print -quit \
  | grep -q . || {
  echo "linked-worktree pointer mutation was not preserved as a private residue" >&2
  exit 1
}
git -C "$linked_workspace" status --porcelain=v2 >/dev/null

root_mode_before="$(mode_of "$current_workspace")"
expect_failure mutate-mode-root public-adapter-mutated "$current_workspace" - show
[ "$(mode_of "$current_workspace")" = "$root_mode_before" ] || {
  echo "workspace root access mode was not restored" >&2
  exit 1
}
worktree_mode_before="$(mode_of "$current_workspace/sealed")"
expect_failure mutate-mode-worktree public-adapter-mutated "$current_workspace" - show
[ "$(mode_of "$current_workspace/sealed")" = "$worktree_mode_before" ] || {
  echo "worktree directory access mode was not restored" >&2
  exit 1
}
common_dir="$(git -C "$current_workspace" rev-parse --path-format=absolute --git-common-dir)"
admin_mode_before="$(mode_of "$common_dir/hooks")"
expect_failure mutate-mode-admin public-adapter-mutated "$current_workspace" - show
[ "$(mode_of "$common_dir/hooks")" = "$admin_mode_before" ] || {
  echo "Git admin directory access mode was not restored" >&2
  exit 1
}

deleted_worktree_before="$(git_state_digest "$current_workspace")"
expect_failure mutate-delete-worktree public-adapter-mutated "$current_workspace" - show
[ "$deleted_worktree_before" = "$(git_state_digest "$current_workspace")" ] || {
  echo "deleted tracked worktree directory was not restored" >&2
  exit 1
}
deleted_nested_before="$(git_state_digest "$current_workspace")"
expect_failure mutate-delete-nested public-adapter-mutated "$current_workspace" - show
[ "$deleted_nested_before" = "$(git_state_digest "$current_workspace")" ] || {
  echo "deleted nested worktree directory was not restored" >&2
  exit 1
}
deleted_admin_before="$(git_state_digest "$current_workspace")"
expect_failure mutate-delete-admin public-adapter-mutated "$current_workspace" - show
[ "$deleted_admin_before" = "$(git_state_digest "$current_workspace")" ] || {
  echo "deleted Git admin child directory was not restored" >&2
  exit 1
}

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

UPGRADE_STUB_MODE=mutate-state \
UPGRADE_STUB_APPROVAL_FILE="$approval" \
WORKBENCH_KIT_WORKBENCH_BIN="$ROOT/tests/upgrade-public-stub.sh" \
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/lib" "$tmp" "$approval" <<'PY'
import os
import pathlib
import resource
import subprocess
import sys
import tempfile

sys.path.insert(0, sys.argv[1])
import workbench_kit_adapter as adapter

base = pathlib.Path(sys.argv[2])
approval = pathlib.Path(sys.argv[3])


def repository(name):
    root = pathlib.Path(tempfile.mkdtemp(prefix=name + "-", dir=base))
    subprocess.run(["git", "-C", str(root), "init", "-q"], check=True)
    subprocess.run(
        ["git", "-C", str(root), "config", "user.name", "Fixture"], check=True
    )
    subprocess.run(
        ["git", "-C", str(root), "config", "user.email", "fixture@example.invalid"],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(root), "commit", "--allow-empty", "-qm", "fixture"],
        check=True,
    )
    return root


def expect_restore_failure(root, inject):
    original = adapter._restore_worktree

    def raced(workspace, state, *remaining):
        inject(workspace)
        return original(workspace, state, *remaining)

    adapter._restore_worktree = raced
    try:
        try:
            adapter.inspect_public_kernel(root, approval)
        except adapter.AdapterError as error:
            assert error.code == "public-adapter-restore-failed", error.code
        else:
            raise AssertionError("raced worktree restore was accepted")
    finally:
        adapter._restore_worktree = original


worktree_root = repository("worktree-race")


def concurrent_nodes(root):
    (root / "concurrent-file").write_bytes(b"preserve concurrent file\n")
    (root / "concurrent-directory").mkdir()
    (root / "concurrent-directory/owned").write_bytes(b"preserve directory\n")
    (root / "concurrent-link").symlink_to("concurrent-file")


expect_restore_failure(worktree_root, concurrent_nodes)
assert (worktree_root / "concurrent-file").read_bytes() == b"preserve concurrent file\n"
assert (worktree_root / "concurrent-directory/owned").read_bytes() == b"preserve directory\n"
assert os.readlink(worktree_root / "concurrent-link") == "concurrent-file"

replacement_root = repository("root-replacement")
moved_root = replacement_root.with_name(replacement_root.name + "-original")


def replace_root(root):
    os.rename(root, moved_root)
    root.mkdir()
    (root / "replacement-file").write_bytes(b"do not touch replacement\n")
    (root / "replacement-directory").mkdir()
    (root / "replacement-directory/owned").write_bytes(b"replacement directory\n")
    (root / "replacement-link").symlink_to("replacement-file")


expect_restore_failure(replacement_root, replace_root)
assert (replacement_root / "replacement-file").read_bytes() == b"do not touch replacement\n"
assert (replacement_root / "replacement-directory/owned").read_bytes() == b"replacement directory\n"
assert os.readlink(replacement_root / "replacement-link") == "replacement-file"


def removal_race(kind):
    root = pathlib.Path(tempfile.mkdtemp(prefix=f"remove-{kind}-", dir=base))
    target = root / "owned"
    replacement = root / "replacement"
    if kind == "file":
        target.write_bytes(b"adapter mutation\n")
        replacement.write_bytes(b"concurrent file\n")
    elif kind == "directory":
        target.mkdir()
        replacement.mkdir()
        (replacement / "child").write_bytes(b"concurrent directory\n")
    else:
        target.symlink_to("adapter-target")
        replacement.symlink_to("concurrent-target")
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    expected = adapter._state_node_at(descriptor, "owned", "owned")
    original = adapter._rename_noreplace
    injected = False

    def raced(source_fd, source, destination_fd, destination, ref):
        nonlocal injected
        if source == "owned" and not injected:
            injected = True
            os.rename(
                "owned", "adapter-before-race",
                src_dir_fd=source_fd, dst_dir_fd=source_fd,
            )
            os.rename(
                "replacement", "owned",
                src_dir_fd=source_fd, dst_dir_fd=source_fd,
            )
        return original(
            source_fd, source, destination_fd, destination, ref
        )

    adapter._rename_noreplace = raced
    try:
        try:
            adapter._remove_state_node_at(
                descriptor, "owned", expected, "owned"
            )
        except adapter.AdapterError as error:
            assert error.code == "public-adapter-restore-failed", error.code
        else:
            raise AssertionError("replacement node race was accepted")
    finally:
        adapter._rename_noreplace = original
        os.close(descriptor)
    assert not target.exists() and not target.is_symlink()
    assert (root / "adapter-before-race").exists() or (
        root / "adapter-before-race"
    ).is_symlink()
    residues = list(root.glob(".workbench-kit-private-*"))
    assert len(residues) == 1
    if kind == "file":
        assert (residues[0] / "node").read_bytes() == b"concurrent file\n"
        assert (root / "adapter-before-race").read_bytes() == b"adapter mutation\n"
    elif kind == "directory":
        assert (residues[0] / "node/child").read_bytes() == b"concurrent directory\n"
    else:
        assert os.readlink(residues[0] / "node") == "concurrent-target"
        assert os.readlink(root / "adapter-before-race") == "adapter-target"


for node_kind in ("file", "directory", "symlink"):
    removal_race(node_kind)


def private_quarantine_residue(kind):
    root = pathlib.Path(tempfile.mkdtemp(prefix=f"quarantine-{kind}-", dir=base))
    target = root / "owned"
    if kind == "file":
        target.write_bytes(b"adapter file\n")
    elif kind == "directory":
        target.mkdir()
    else:
        target.symlink_to("adapter-target")
    parent_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    expected = adapter._state_node_at(parent_fd, "owned", "owned")
    try:
        residue_name, _ = adapter._remove_state_node_at(
            parent_fd, "owned", expected, "owned"
        )
    finally:
        os.close(parent_fd)
    assert not target.exists() and not target.is_symlink()
    residue = root / residue_name / "node"
    if kind == "file":
        assert residue.read_bytes() == b"adapter file\n"
    elif kind == "directory":
        assert residue.is_dir()
    else:
        assert os.readlink(residue) == "adapter-target"


for node_kind in ("file", "directory", "symlink"):
    private_quarantine_residue(node_kind)


def private_node_swap_after_stat(kind):
    root = pathlib.Path(tempfile.mkdtemp(prefix=f"private-swap-{kind}-", dir=base))
    target = root / "owned"
    if kind == "file":
        target.write_bytes(b"adapter file\n")
    else:
        target.symlink_to("adapter-target")
    parent_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    expected = adapter._state_node_at(parent_fd, "owned", "owned")
    original_stat = adapter.os.stat
    injected = False

    def raced_stat(path, *args, dir_fd=None, follow_symlinks=True, **kwargs):
        nonlocal injected
        node = original_stat(
            path,
            *args,
            dir_fd=dir_fd,
            follow_symlinks=follow_symlinks,
            **kwargs,
        )
        if path == "node" and dir_fd != parent_fd and not injected:
            injected = True
            os.rename(
                "node", "adapter-node",
                src_dir_fd=dir_fd, dst_dir_fd=dir_fd,
            )
            if kind == "file":
                replacement = os.open(
                    "node", os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o644, dir_fd=dir_fd,
                )
                os.write(replacement, b"concurrent private file\n")
                os.close(replacement)
            else:
                os.symlink("concurrent-private-target", "node", dir_fd=dir_fd)
        return node

    adapter.os.stat = raced_stat
    try:
        try:
            adapter._remove_state_node_at(parent_fd, "owned", expected, "owned")
        except adapter.AdapterError as error:
            assert error.code == "public-adapter-restore-failed", error.code
    finally:
        adapter.os.stat = original_stat
        os.close(parent_fd)
    assert injected
    residues = list(root.glob(".workbench-kit-private-*"))
    assert len(residues) == 1
    if kind == "file":
        assert (residues[0] / "node").read_bytes() == b"concurrent private file\n"
        assert (residues[0] / "adapter-node").read_bytes() == b"adapter file\n"
    else:
        assert os.readlink(residues[0] / "node") == "concurrent-private-target"
        assert os.readlink(residues[0] / "adapter-node") == "adapter-target"


for node_kind in ("file", "symlink"):
    private_node_swap_after_stat(node_kind)


def private_temp_swap_before_failure_cleanup(kind):
    root = pathlib.Path(tempfile.mkdtemp(prefix=f"private-temp-{kind}-", dir=base))
    parent_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    image = (
        ("file", 0o644, b"restored file\n")
        if kind == "file"
        else ("symlink", 0o777, "restored-target")
    )
    original_state = adapter._state_node_at
    calls = 0

    def raced_state(descriptor, name, ref):
        nonlocal calls
        image_at_target = original_state(descriptor, name, ref)
        if descriptor == parent_fd and name == "installed":
            calls += 1
            if calls == 2:
                private = next(root.glob(".workbench-kit-private-*"))
                private_fd = os.open(private, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.stat("node", dir_fd=private_fd, follow_symlinks=False)
                    os.rename(
                        "node", "adapter-node",
                        src_dir_fd=private_fd, dst_dir_fd=private_fd,
                    )
                    if kind == "file":
                        replacement = os.open(
                            "node", os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                            0o644, dir_fd=private_fd,
                        )
                        os.write(replacement, b"concurrent temp file\n")
                        os.close(replacement)
                    else:
                        os.symlink(
                            "concurrent-temp-target", "node", dir_fd=private_fd
                        )
                finally:
                    os.close(private_fd)
                concurrent = os.open(
                    "installed", os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o644, dir_fd=parent_fd,
                )
                os.write(concurrent, b"concurrent destination\n")
                os.close(concurrent)
                return original_state(descriptor, name, ref)
        return image_at_target

    adapter._state_node_at = raced_state
    try:
        try:
            adapter._create_state_node_at(parent_fd, "installed", image, "installed")
        except adapter.AdapterError as error:
            assert error.code == "public-adapter-restore-failed", error.code
        else:
            raise AssertionError("occupied restore destination was accepted")
    finally:
        adapter._state_node_at = original_state
        os.close(parent_fd)
    residues = list(root.glob(".workbench-kit-private-*"))
    assert len(residues) == 1
    assert (root / "installed").read_bytes() == b"concurrent destination\n"
    if kind == "file":
        assert (residues[0] / "node").read_bytes() == b"concurrent temp file\n"
        assert (residues[0] / "adapter-node").read_bytes() == b"restored file\n"
    else:
        assert os.readlink(residues[0] / "node") == "concurrent-temp-target"
        assert os.readlink(residues[0] / "adapter-node") == "restored-target"


for node_kind in ("file", "symlink"):
    private_temp_swap_before_failure_cleanup(node_kind)


def shared_quarantine_cleanup(kind):
    root = pathlib.Path(tempfile.mkdtemp(prefix=f"cleanup-{kind}-", dir=base))
    target = root / "owned"
    if kind == "file":
        target.write_bytes(b"adapter mutation\n")
    else:
        target.symlink_to("adapter-target")
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    expected = adapter._state_node_at(descriptor, "owned", "owned")
    original_state = adapter._state_node_at
    exposed = False

    def raced_state(parent_fd, name, ref):
        nonlocal exposed
        image = original_state(parent_fd, name, ref)
        if parent_fd == descriptor and name != "owned" and image == expected:
            exposed = True
            os.rename(
                name, name + "-adapter",
                src_dir_fd=parent_fd, dst_dir_fd=parent_fd,
            )
            if kind == "file":
                replacement_fd = os.open(
                    name, os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o644, dir_fd=parent_fd,
                )
                os.write(replacement_fd, b"concurrent quarantine bytes\n")
                os.close(replacement_fd)
            else:
                os.symlink("concurrent-quarantine", name, dir_fd=parent_fd)
        return image

    adapter._state_node_at = raced_state
    try:
        try:
            adapter._remove_state_node_at(
                descriptor, "owned", expected, "owned"
            )
        except adapter.AdapterError:
            pass
    finally:
        adapter._state_node_at = original_state
        os.close(descriptor)
    assert not exposed, f"{kind} cleanup used a shared verified name before unlink"


def shared_temp_cleanup(kind):
    root = pathlib.Path(tempfile.mkdtemp(prefix=f"temp-{kind}-", dir=base))
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    image = (
        ("file", 0o644, b"restored file\n")
        if kind == "file"
        else ("symlink", 0o777, "restored-target")
    )
    original_stat = adapter.os.stat
    exposed = False

    def raced_stat(path, *args, dir_fd=None, follow_symlinks=True, **kwargs):
        nonlocal exposed
        node = original_stat(
            path,
            *args,
            dir_fd=dir_fd,
            follow_symlinks=follow_symlinks,
            **kwargs,
        )
        if (
            isinstance(path, str)
            and path != "installed"
            and dir_fd == descriptor
            and not exposed
        ):
            try:
                target = original_stat(
                    "installed", dir_fd=descriptor, follow_symlinks=False
                )
            except FileNotFoundError:
                target = None
            if target is not None and (node.st_dev, node.st_ino) == (
                target.st_dev, target.st_ino
            ):
                exposed = True
                os.rename(
                    path, path + "-adapter",
                    src_dir_fd=descriptor, dst_dir_fd=descriptor,
                )
                if kind == "file":
                    replacement = os.open(
                        path, os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                        0o644, dir_fd=descriptor,
                    )
                    os.write(replacement, b"concurrent temp bytes\n")
                    os.close(replacement)
                else:
                    os.symlink("concurrent-temp", path, dir_fd=descriptor)
        return node

    adapter.os.stat = raced_stat
    try:
        adapter._create_state_node_at(
            descriptor, "installed", image, "installed"
        )
    finally:
        adapter.os.stat = original_stat
        os.close(descriptor)
    assert not exposed, f"{kind} install cleaned a shared temporary name"


for node_kind in ("file", "symlink"):
    shared_quarantine_cleanup(node_kind)
    shared_temp_cleanup(node_kind)

chmod_root = pathlib.Path(tempfile.mkdtemp(prefix="chmod-race-", dir=base))
(chmod_root / "owned").mkdir(mode=0o755)
(chmod_root / "replacement").mkdir(mode=0o711)
chmod_fd = os.open(chmod_root, os.O_RDONLY | os.O_DIRECTORY)
original_open = adapter.os.open
injected_chmod = False


def raced_open(path, flags, *args, dir_fd=None, **kwargs):
    global injected_chmod
    if path == "owned" and dir_fd == chmod_fd and not injected_chmod:
        injected_chmod = True
        os.rename(
            "owned", "adapter-before-chmod",
            src_dir_fd=chmod_fd, dst_dir_fd=chmod_fd,
        )
        os.rename(
            "replacement", "owned",
            src_dir_fd=chmod_fd, dst_dir_fd=chmod_fd,
        )
    return original_open(path, flags, *args, dir_fd=dir_fd, **kwargs)


adapter.os.open = raced_open
try:
    try:
        adapter._chmod_directory_at(
            chmod_fd, "owned", ("directory", 0o755, None), 0o700, "owned"
        )
    except adapter.AdapterError as error:
        assert error.code == "public-adapter-restore-failed", error.code
    else:
        raise AssertionError("replacement directory was chmodded")
finally:
    adapter.os.open = original_open
    os.close(chmod_fd)
assert os.stat(chmod_root / "owned").st_mode & 0o777 == 0o711

detached_root = repository("detached-access").resolve()
(detached_root / "parent/child").mkdir(parents=True)
detached_root_fd = adapter._open_workspace_root(detached_root)
detached_state = adapter._capture_caller_state(detached_root, detached_root_fd)
detached_groups = adapter._capture_directory_access(
    detached_root, detached_root_fd, detached_state
)
os.rename(detached_root / "parent", detached_root / "detached-parent")
(detached_root / "parent/child").mkdir(parents=True)
os.chmod(detached_root / "detached-parent/child", 0o000)
try:
    repaired = adapter._restore_directory_access(
        detached_root, detached_root_fd, detached_groups
    )
    assert not repaired
    assert os.stat(detached_root / "detached-parent/child").st_mode & 0o777 == 0
finally:
    adapter._close_directory_access(detached_groups)
    os.close(detached_root_fd)

exhaustion_root = repository("descriptor-exhaustion").resolve()
(exhaustion_root / "level-one/level-two").mkdir(parents=True)
exhaustion_fd = adapter._open_workspace_root(exhaustion_root)
exhaustion_state = adapter._capture_caller_state(exhaustion_root, exhaustion_fd)
descriptor_count = len(os.listdir("/dev/fd"))
original_open = adapter.os.open


def exhausted_open(path, flags, *args, dir_fd=None, **kwargs):
    if path == "level-two" and dir_fd is not None:
        raise OSError(24, "fixture descriptor exhaustion")
    return original_open(path, flags, *args, dir_fd=dir_fd, **kwargs)


adapter.os.open = exhausted_open
try:
    try:
        adapter._capture_directory_access(
            exhaustion_root, exhaustion_fd, exhaustion_state
        )
    except adapter.AdapterError as error:
        assert error.code == "public-state-unavailable", error.code
    else:
        raise AssertionError("descriptor exhaustion was accepted")
finally:
    adapter.os.open = original_open
    os.close(exhaustion_fd)
assert len(os.listdir("/dev/fd")) == descriptor_count - 1

capacity_root = repository("descriptor-capacity").resolve()
for index in range(320):
    (capacity_root / f"directory-{index:03d}").mkdir()
limit_before = resource.getrlimit(resource.RLIMIT_NOFILE)
mode_before = os.environ["UPGRADE_STUB_MODE"]
os.environ["UPGRADE_STUB_MODE"] = "ok"
try:
    capacity_snapshot = adapter.inspect_public_kernel(capacity_root, approval)
finally:
    os.environ["UPGRADE_STUB_MODE"] = mode_before
assert capacity_snapshot["contract"]["workspace"]["schema"] == "workbench/v1"
assert resource.getrlimit(resource.RLIMIT_NOFILE) == limit_before

if sys.platform == "darwin":
    symlink_root = pathlib.Path(tempfile.mkdtemp(prefix="darwin-symlink-", dir=base))
    (symlink_root / "owned").symlink_to("target")
    symlink_parent_fd = os.open(symlink_root, os.O_RDONLY | os.O_DIRECTORY)
    saved_flags = {
        name: getattr(adapter.os, name)
        for name in ("O_SYMLINK", "O_PATH")
        if hasattr(adapter.os, name)
    }
    try:
        for name in saved_flags:
            delattr(adapter.os, name)
        handle = adapter._open_state_handle_at(
            symlink_parent_fd, "owned", "symlink", "owned"
        )
        try:
            assert os.path.samestat(
                os.fstat(handle), os.stat("owned", dir_fd=symlink_parent_fd, follow_symlinks=False)
            )
        finally:
            os.close(handle)
    finally:
        for name, value in saved_flags.items():
            setattr(adapter.os, name, value)
        os.close(symlink_parent_fd)
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
