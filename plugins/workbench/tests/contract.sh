#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKBENCH="$ROOT/bin/workbench"
SOURCE_REPO="$(git -C "$ROOT" rev-parse --show-toplevel)"
SOURCE_HEAD="$(git -C "$SOURCE_REPO" rev-parse HEAD)"
SOURCE_STATUS="$(git -C "$SOURCE_REPO" status --porcelain=v1)"
TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/workbench-contract.XXXXXX")"
cleanup() {
  local rc=$?
  trap - EXIT
  rm -rf "$TMPDIR"
  if [ "$SOURCE_HEAD" != "$(git -C "$SOURCE_REPO" rev-parse HEAD)" ] \
    || [ "$SOURCE_STATUS" != "$(git -C "$SOURCE_REPO" status --porcelain=v1)" ]; then
    echo "FAIL: test mutated source repository" >&2
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [ "$expected" = "$actual" ] || fail "$message
expected: $expected
actual:   $actual"
}

assert_contains() {
  local value="$1" needle="$2" message="$3"
  printf '%s' "$value" | grep -Fq "$needle" || fail "$message: missing '$needle' in '$value'"
}

assert_file_contains() {
  local file="$1" needle="$2"
  grep -Fq "$needle" "$file" || fail "missing '$needle' in $file"
}

json_string_field() {
  local json="$1" key="$2"
  printf '%s\n' "$json" | sed -n "s/.*\"$key\":\"\([^\"]*\)\".*/\1/p" | head -1
}

json_path() {
  local json="$1" path="$2"
  printf '%s\n' "$json" | python3 -c '
import json
import sys

value = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    value = value[int(part)] if isinstance(value, list) else value[part]
print("" if value is None else value)
' "$path"
}

write_policy_authorization() {
  local file="$1" instance="$2" action="$3" claim="$4" target="$5" revision="$6"
  local intent="$7" manifest="$8" source_ref="$9"
  python3 - "$file" "$instance" "$action" "$claim" "$target" "$revision" \
    "$intent" "$manifest" "$source_ref" <<'PY'
import json
import sys

value = {
    "contract_version": "workbench-authorization/v1",
    "authorization_id": "auth_" + sys.argv[2],
    "action_instance_id": sys.argv[2],
    "action_id": sys.argv[3],
    "task_claim_id": sys.argv[4],
    "target_ref": sys.argv[5],
    "revision": sys.argv[6],
    "intent_digest": sys.argv[7],
    "policy_manifest_digest": sys.argv[8],
    "decision": "allow",
    "actor": "human@example.com",
    "authorized_at": "2026-07-11T03:01:00Z",
    "source_ref": sys.argv[9],
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
}

write_completion_request() {
  local file="$1" revision="$2" target="${3:-workbench:task/claim-policy-42}"
  python3 - "$file" "$revision" "$target" <<'PY'
import json
import sys

payload = (
    "workbench-task-complete-intent/v1\n"
    "outcome\tcompleted\n"
    "completion_snapshot\t" + sys.argv[2] + "\n"
)
value = {
    "contract_version": "workbench-action-request/v1",
    "action_id": "task.complete",
    "task_claim_id": "claim-policy-42",
    "target_ref": sys.argv[3],
    "revision": sys.argv[2],
    "payload_contract": "workbench-task-complete-intent/v1",
    "payload": payload,
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
}

intent_for_request() {
  python3 "$ROOT/lib/workbench_intent.py" request "$1" --format json \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["intent_digest"])'
}

make_workspace() {
  local name="$1" schema="${2:-}"
  local repo="$TMPDIR/$name"
  if [ -e "$repo" ]; then echo "fixture workspace already exists: $repo" >&2; return 1; fi
  git init -q -b main "$repo"
  git -C "$repo" config user.name "Test User"
  git -C "$repo" config user.email "test@example.invalid"
  printf 'fixture\n' > "$repo/README.md"
  if [ -n "$schema" ]; then
    mkdir -p "$repo/.workbench"
    printf '%s\n' "$schema" > "$repo/.workbench/schema"
  fi
  git -C "$repo" add .
  git -C "$repo" commit -q -m init >/dev/null
  (cd "$repo" && pwd)
}

assert_source_repo_unchanged() {
  assert_eq "$SOURCE_HEAD" "$(git -C "$SOURCE_REPO" rev-parse HEAD)" "test must not commit in source repo"
  assert_eq "$SOURCE_STATUS" "$(git -C "$SOURCE_REPO" status --porcelain=v1)" "test must not modify source repo"
}

test_fixture_reuse_fails_before_git_mutation() {
  make_workspace collision workbench/v2 >/dev/null
  if make_workspace collision workbench/v2 >/dev/null 2>&1; then
    fail "reusing a fixture path must fail"
  fi
}

run_workbench() {
  local repo="$1"; shift
  (cd "$repo" && CLAUDE_PLUGIN_ROOT="$ROOT" \
    WORKBENCH_TRUSTED_HOSTING_ADAPTER="${WORKBENCH_TRUSTED_HOSTING_ADAPTER:-$DEFAULT_HOSTING_ADAPTER}" \
    "$WORKBENCH" "$@")
}

write_test_hosting_adapter() {
  local file="$1" protected="${2:-true}" direct_writes="${3:-blocked}"
  local authority_identity="${4:-}"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf 'protected=%q\n' "$protected"
    printf 'direct_writes=%q\n' "$direct_writes"
    printf 'authority_identity=%q\n' "$authority_identity"
    cat <<'EOF'
command="$1"; shift
authority=""
revision=""
coordination_ref=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --authority-file) authority="$2"; shift 2 ;;
    --default-revision) revision="$2"; shift 2 ;;
    --coordination-ref) coordination_ref="$2"; shift 2 ;;
    --format) [ "$2" = json ]; shift 2 ;;
    *) exit 2 ;;
  esac
done
python3 - "$command" "$authority" "$revision" "$coordination_ref" \
  "$protected" "$direct_writes" "$authority_identity" <<'PY'
import json
import sys

(
    command,
    authority_file,
    revision,
    coordination_ref,
    protected,
    direct_writes,
    authority_identity,
) = sys.argv[1:]
authority = json.load(open(authority_file, encoding="utf-8"))
if command == "authority":
    value = {
        "contract_version": "workbench-hosting-authority-verification/v1",
        "authority_identity": authority_identity or authority["authority_identity"],
        "origin_url": authority["origin_url"],
        "default_ref": authority["default_ref"],
        "default_revision": revision,
        "default_ref_protected": protected == "true",
        "direct_task_actor_writes": direct_writes,
        "permission_source": authority["hosting_ref"] or "fixture:repository/local",
    }
elif command == "doctor":
    value = {
        "contract_version": "workbench-hosting-readiness/v1",
        "authority_identity": authority["authority_identity"],
        "origin_url": authority["origin_url"],
        "default_ref": authority["default_ref"],
        "default_revision": revision,
        "default_ref_protected": protected == "true",
        "coordination_ref": coordination_ref,
        "push_permission": "allowed",
        "permission_source": authority["hosting_ref"] or "fixture:repository/local",
        "push_ready": True,
    }
else:
    raise SystemExit(2)
print(json.dumps(value, separators=(",", ":")))
PY
EOF
  } > "$file"
  chmod +x "$file"
}

DEFAULT_HOSTING_ADAPTER="$TMPDIR/default-hosting-adapter"
write_test_hosting_adapter "$DEFAULT_HOSTING_ADAPTER"

write_test_legacy_adapter() {
  local file="$1" observation="$2"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf 'observation=%q\n' "$observation"
    cat <<'EOF'
[ "${1:-}" = collect ] || exit 2
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --authority-file|--registry-file|--workspace-origin|--default-ref|--default-revision|--bootstrap-revision)
      [ -n "${2:-}" ]; shift 2 ;;
    --format) [ "${2:-}" = json ]; shift 2 ;;
    *) exit 2 ;;
  esac
done
cat "$observation"
EOF
  } > "$file"
  chmod +x "$file"
}

readonly_git_snapshot() {
  local repo="$1" common fetch index
  common="$(git -C "$repo" rev-parse --git-common-dir)"
  case "$common" in /*) ;; *) common="$repo/$common" ;; esac
  fetch="$common/FETCH_HEAD"; index="$(git -C "$repo" rev-parse --git-path index)"
  case "$index" in /*) ;; *) index="$repo/$index" ;; esac
  printf '%s\n' "HEAD=$(git -C "$repo" rev-parse HEAD)"
  printf '%s\n' 'REFS-BEGIN'; git -C "$repo" show-ref || true; printf '%s\n' 'REFS-END'
  printf '%s\n' 'STATUS-BEGIN'; git -C "$repo" status --porcelain=v1 --untracked-files=all; printf '%s\n' 'STATUS-END'
  if [ -f "$index" ]; then printf 'INDEX='; shasum -a 256 "$index" | awk '{print $1}'
  else printf '%s\n' 'INDEX=absent'; fi
  if [ -f "$fetch" ]; then printf 'FETCH_HEAD='; shasum -a 256 "$fetch" | awk '{print $1}'
  else printf '%s\n' 'FETCH_HEAD=absent'; fi
}

test_contract_show_exact_v2_json() {
  local repo root actual
  repo="$(make_workspace exact_v2 workbench/v2)"
  printf 'schema=workbench-profile/v1\nlanguage=ko\n' > "$repo/.workbench/profile.conf"
  root="$(git -C "$repo" rev-parse --show-toplevel)"
  actual="$(run_workbench "$repo" contract show --format json)"
  printf '%s\n' "$actual" | python3 -c '
import json
import sys

root = sys.argv[1]
value = json.load(sys.stdin)
expected = {
    "contract_version": "workbench-contract/v1",
    "engine": {"name": "workbench", "version": "0.1.1"},
    "workspace": {"root": root, "schema": "workbench/v2", "source": "marker"},
    "profile": {"contract_version": "workbench-profile/v1", "language": "ko", "source": "workspace"},
}
if list(value) != ["contract_version", "engine", "workspace", "profile", "supported", "capabilities"]:
    raise SystemExit("top-level contract fields/order mismatch")
for key, expected_value in expected.items():
    if value[key] != expected_value:
        raise SystemExit("contract identity mismatch: {}".format(key))
' "$root" || fail "contract discovery must match the G0 canonical identity shape"
}

test_contract_show_reads_implicit_v1() {
  local repo actual
  repo="$(make_workspace implicit_v1)"
  actual="$(run_workbench "$repo" contract show --format json)"
  assert_contains "$actual" "\"schema\":\"workbench/v1\"" "absent marker must map to v1"
  assert_contains "$actual" "\"source\":\"implicit\"" "absent marker source must be implicit"
}

test_contract_show_advertises_the_frozen_g0_surface() {
  local repo actual
  repo="$(make_workspace frozen_surface workbench/v2)"
  printf 'schema=workbench-profile/v1\nlanguage=ko\n' > "$repo/.workbench/profile.conf"
  actual="$(run_workbench "$repo" contract show --format json)"
  printf '%s\n' "$actual" | python3 -c '
import json
import sys

value = json.load(sys.stdin)
expected_supported = {
    "workspace_schemas": {"read": ["workbench/v1", "workbench/v2"], "write": ["workbench/v2"]},
    "task_contracts": {"read": ["workbench-task/v1", "workbench-task/v2"], "write": ["workbench-task/v2"]},
    "task_start_contracts": ["workbench-task-start/v2"],
    "lifecycle_markers": {"read": ["workbench-task-lifecycle:v1", "workbench-task-lifecycle:v2"], "write": ["workbench-task-lifecycle:v2"]},
    "profile_contracts": ["workbench-profile/v1"],
    "workspace_authority_contracts": ["workbench-workspace-authority/v1"],
    "policy_contracts": ["workbench-policy/v1"],
    "policy_manifest_contracts": ["workbench-policy-manifest/v1"],
    "engine_manifest_contracts": ["workbench-plugin-manifest/v1"],
    "policy_authority_receipt_contracts": ["workbench-policy-authority-receipt/v1"],
    "context_policy_contracts": ["workbench-context-policy-registration/v1", "workbench-context-policy-set/v1"],
    "authorization_contracts": ["workbench-authorization/v1"],
    "applied_effect_contracts": ["workbench-applied-action-provenance/v1"],
    "action_intent_contracts": [
        "workbench-action-request/v1", "workbench-action-intent/v1",
        "workbench-task-complete-intent/v1", "workbench-task-abandon-intent/v1",
        "workbench-deliverable-transition-intent/v1", "workbench-deliverable-accept-intent/v1",
        "workbench-required-check-waive-intent/v1", "workbench-harvest-disposition-intent/v1",
        "workbench-context-policy-registration/v1", "workbench-context-policy-set/v1",
        "workbench-writer-request/v1", "workbench-task-cleanup-intent/v1",
    ],
    "task_revision_contracts": [
        "workbench-task-content/v1", "workbench-task-revision/v1",
        "workbench-task-abandonment-revision/v1",
    ],
    "acceptance_contracts": ["workbench-acceptance/v1", "workbench-acceptances/v1", "workbench-deliverable-acceptance/v1", "workbench-owner-acceptance/v1"],
    "external_probe_contracts": ["workbench-probe/github-pr-subject/v1", "workbench-probe/github-pr/v1"],
    "cleanup_journal_contracts": ["workbench-task-removal-plan/v1", "workbench-task-cleanup-journal/v1"],
    "doctor_contracts": ["workbench-doctor/v1"],
    "evidence_contracts": ["workbench-evidence/v1"],
    "legacy_inventory_contracts": ["workbench-legacy-inventory/v1"],
    "bootstrap_authority_approval_contracts": ["workbench-bootstrap-authority-approval/v1"],
    "writer_claim_contracts": [
        "workbench-legacy-home-set/v1", "workbench-legacy-lifecycle-set/v1",
        "workbench-legacy-writer-identity/v1", "workbench-effect-owner-snapshot/v1",
        "workbench-writer-conflict/v1", "workbench-writer-claim/v1",
        "workbench-writer-claim-snapshot/v1", "workbench-writer-claims/v1",
        "workbench-writer-operation/v1", "workbench-writer-worktree-owner/v1",
        "workbench-worktree-set/v1", "workbench-writer-abandonment-snapshot/v1",
    ],
    "capability_pack_contracts": ["workbench-capability-pack/v1"],
    "action_ids": [
        "task.abandon", "task.cleanup", "task.complete", "task.concurrent-write",
        "task.deliverable.accept", "task.deliverable.reject", "task.deliverable.waive",
        "task.deliverable.weaken", "task.harvest.dispose", "task.policy-context.register",
        "task.policy-context.seal", "task.required-check.waive",
    ],
}
expected_capabilities = [
    "engine.manifest/v1", "knowledge.applicability/v1", "policy.authority/v1", "policy.authorization/v1",
    "policy.applied-effect-recovery/v1",
    "policy.context-set/v1", "policy.intent/v1", "policy.resolve/v1",
    "profile.language/v1", "task.acceptance/v1", "task.abandonment/v1",
    "task.cleanup/v1", "task.completion/v1", "task.contract/v2",
    "task.deliverables/v1", "task.evidence/v1", "task.harvest/v1",
    "task.lifecycle/v2", "task.legacy-writer-projection/v1", "task.refs/v1",
    "task.required-checks/v1", "task.start/v2", "task.writer-claims/v1",
    "task.writer-conflicts/v1", "task.writer-handoff/v1", "task.writer-recovery/v1",
    "task.writer-reconciliation/v1", "workspace.authority/v1", "workspace.doctor/v1",
    "workspace.legacy-inventory-bootstrap/v1", "workspace.legacy-inventory/v1",
    "workspace.schema/v1",
]
if value["supported"] != expected_supported or value["capabilities"] != expected_capabilities:
    raise SystemExit("frozen G0 discovery surface mismatch")
' || fail "contract discovery must advertise every frozen G0 contract and capability"
}

test_public_engine_manifest_is_complete_and_canonical() {
  local repo first second
  repo="$(make_workspace engine_manifest workbench/v2)"
  first="$(run_workbench "$repo" engine-manifest show --format json)"
  second="$(run_workbench "$repo" engine-manifest show --format json)"
  assert_eq "$first" "$second" "engine manifest must be deterministic"
  python3 - "$first" "$ROOT" <<'PY'
import hashlib
import json
import os
import stat
import sys

value = json.loads(sys.argv[1])
root = os.path.realpath(sys.argv[2])
assert list(value) == [
    "contract_version", "plugin", "source", "included_paths", "excluded_paths", "nodes", "digest",
]
assert value["contract_version"] == "workbench-plugin-manifest/v1"
assert list(value["plugin"]) == ["name", "version"]
assert value["plugin"] == {"name": "workbench", "version": "0.1.1"}
assert list(value["source"]) == ["ref", "revision"]
assert value["source"]["ref"] == "https://github.com/YOOGOMJA/workbench-kit#plugins/workbench"
assert value["included_paths"] == ["."]
assert value["excluded_paths"] == [
    {"path": ".DS_Store", "match": "exact"},
    {"path": ".git/", "match": "prefix"},
    {"path": "lib/__pycache__/", "match": "prefix"},
]
assert all(list(item) == ["path", "match"] for item in value["excluded_paths"])
nodes = value["nodes"]
assert [item["path"] for item in nodes] == sorted(item["path"] for item in nodes)
assert len(nodes) == len({item["path"] for item in nodes})
assert all(list(item) == ["path", "node_type", "mode", "digest", "link_target"] for item in nodes)
assert nodes[0]["path"] == "." and nodes[0]["node_type"] == "directory"
by_path = {item["path"]: item for item in nodes}
for required in (
    ".claude-plugin/plugin.json", ".codex-plugin/plugin.json", "bin/workbench",
    "lib/workbench_manifest.py", "utils/engine-manifest",
):
    assert required in by_path, required
assert not any(item["path"].startswith("lib/__pycache__") for item in nodes)

def row(*items):
    return json.dumps(items, ensure_ascii=False, separators=(",", ":")) + "\n"

source_rows = ["workbench-plugin-tree/v1\n"]
for path in value["included_paths"]:
    source_rows.append(row("included_path", path))
for item in value["excluded_paths"]:
    source_rows.append(row("excluded_path", item["path"], item["match"]))
for item in nodes:
    source_rows.append(row(
        "node", item["path"], item["node_type"], item["mode"], item["digest"], item["link_target"],
    ))
source_revision = "sha256:" + hashlib.sha256("".join(source_rows).encode("utf-8")).hexdigest()
assert value["source"]["revision"] == source_revision

unsigned = dict(value)
unsigned["digest"] = None
raw = (json.dumps(unsigned, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
digest = "sha256:" + hashlib.sha256(raw).hexdigest()
assert value["digest"] == digest

for item in nodes:
    path = root if item["path"] == "." else os.path.join(root, *item["path"].split("/"))
    mode = os.lstat(path).st_mode
    expected_mode = (
        "120000" if item["node_type"] == "symlink"
        else format(stat.S_IFMT(mode) | stat.S_IMODE(mode), "06o")
    )
    assert item["mode"] == expected_mode
    if item["node_type"] == "file":
        assert item["link_target"] is None
        with open(path, "rb") as handle:
            expected = "sha256:" + hashlib.sha256(handle.read()).hexdigest()
        assert item["digest"] == expected
    elif item["node_type"] == "symlink":
        target = os.readlink(path)
        assert item["link_target"] == target
        assert item["digest"] == "sha256:" + hashlib.sha256(target.encode("utf-8")).hexdigest()
    else:
        assert item["node_type"] == "directory" and item["link_target"] is None
PY
}

test_engine_manifest_rejects_links_and_path_swap() {
  local repo bundle external out err rc
  repo="$(make_workspace engine_manifest_links workbench/v2)"
  bundle="$TMPDIR/engine-manifest-bundle"
  cp -R "$ROOT" "$bundle"
  external="$TMPDIR/external-engine-bytes"
  printf '%s\n' external > "$external"
  ln "$external" "$bundle/external-hardlink"
  out="$TMPDIR/engine-manifest-hardlink.out"; err="$TMPDIR/engine-manifest-hardlink.err"
  if (cd "$repo" && CLAUDE_PLUGIN_ROOT="$bundle" "$bundle/bin/workbench" \
    engine-manifest show --format json) >"$out" 2>"$err"; then
    fail "engine manifest must reject a file hardlinked outside the bundle"
  else rc=$?; fi
  assert_eq 1 "$rc" "hardlink rejection is a state failure"
  [ ! -s "$out" ] || fail "hardlink rejection must emit no partial manifest"
  rm "$bundle/external-hardlink"

  printf '%s\n' first > "$bundle/first-link"
  ln "$bundle/first-link" "$bundle/second-link"
  if (cd "$repo" && CLAUDE_PLUGIN_ROOT="$bundle" "$bundle/bin/workbench" \
    engine-manifest show --format json) >"$out" 2>"$err"; then
    fail "engine manifest must reject two names for one in-bundle inode"
  fi
  [ ! -s "$out" ] || fail "same-tree hardlink rejection must emit no partial manifest"
  rm "$bundle/first-link" "$bundle/second-link"

  PYTHONPATH="$bundle/lib" python3 - "$bundle" <<'PY'
import os
import sys
from pathlib import Path

import workbench_manifest

root = Path(sys.argv[1])
target = root / "skills-lock.json"
replacement = root / ".replacement-skills-lock"
replacement.write_text('{"replacement":true}\n', encoding="utf-8")
real_open = workbench_manifest.os.open
swapped = False

def racing_open(path, flags, *args, **kwargs):
    global swapped
    if Path(path) == target and not swapped:
        swapped = True
        os.replace(replacement, target)
    return real_open(path, flags, *args, **kwargs)

workbench_manifest.os.open = racing_open
try:
    workbench_manifest.manifest(root)
except ValueError:
    pass
else:
    raise AssertionError("lstat-to-open path replacement was accepted")
assert swapped
PY
}

test_workspace_authority_descriptor_binds_workspace_home() {
  local descriptor actual missing out err rc
  descriptor="$TMPDIR/authority-with-home.json"
  python3 - "$descriptor" <<'PY'
import json
import sys

value = {
    "contract_version": "workbench-workspace-authority/v1",
    "authority_identity": "fixture:workspace/local",
    "origin_url": "https://github.com/example/workbench.git",
    "default_ref": "refs/heads/main",
    "workspace_home": "workbench",
    "hosting_adapter": "github",
    "hosting_ref": "github:repository/example/workbench",
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  actual="$(python3 "$ROOT/lib/workbench_contract.py" authority-descriptor "$descriptor")"
  assert_contains "$actual" 'workspace_home=workbench' \
    "authority parser must expose the immutable workspace home"

  missing="$TMPDIR/authority-without-home.json"
  python3 - "$descriptor" "$missing" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
del value["workspace_home"]
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  out="$TMPDIR/authority-without-home.out"; err="$TMPDIR/authority-without-home.err"
  if python3 "$ROOT/lib/workbench_contract.py" authority-descriptor "$missing" \
    >"$out" 2>"$err"; then
    fail "authority descriptor without workspace_home must fail"
  else rc=$?; fi
  assert_eq 2 "$rc" "missing workspace_home is malformed authority input"
  [ ! -s "$out" ] || fail "invalid authority descriptor must emit no partial output"
}

test_action_request_binds_the_exact_effect_intent() {
  local absorb discard first second first_digest second_digest expected
  absorb="$TMPDIR/harvest-absorb-request.json"
  discard="$TMPDIR/harvest-discard-request.json"
  python3 - "$absorb" "$discard" <<'PY'
import json
import sys

def write(path, decision, target):
    payload = (
        "workbench-harvest-disposition-intent/v1\n"
        "candidate_id\thv-1\n"
        "record_revision\tsha256:" + "1" * 64 + "\n"
        "decision\t" + decision + "\n"
        "target_ref\t" + target + "\n"
        "reason_code\tvalidated\n"
        "reason_ref\tnull\n"
    )
    value = {
        "contract_version": "workbench-action-request/v1",
        "action_id": "task.harvest.dispose",
        "task_claim_id": "claim-policy-42",
        "target_ref": "workbench:harvest/hv-1",
        "revision": "sha256:" + "1" * 64,
        "payload_contract": "workbench-harvest-disposition-intent/v1",
        "payload": payload,
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, separators=(",", ":"))
        handle.write("\n")

write(sys.argv[1], "absorb", "workbench:docs/harvest-hv-1")
write(sys.argv[2], "discard", "null")
PY
  first="$(python3 "$ROOT/lib/workbench_intent.py" request "$absorb" --format json)"
  second="$(python3 "$ROOT/lib/workbench_intent.py" request "$discard" --format json)"
  first_digest="$(json_path "$first" intent_digest)"
  second_digest="$(json_path "$second" intent_digest)"
  [ "$first_digest" != "$second_digest" ] \
    || fail "different harvest dispositions must not share an intent digest"
  expected="$(python3 - "$absorb" <<'PY'
import hashlib
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
payload_digest = "sha256:" + hashlib.sha256(value["payload"].encode()).hexdigest()
manifest = (
    "workbench-action-intent/v1\n"
    "action_id\t" + value["action_id"] + "\n"
    "task_claim_id\t" + value["task_claim_id"] + "\n"
    "target_ref\t" + value["target_ref"] + "\n"
    "subject_revision\t" + value["revision"] + "\n"
    "payload_contract\t" + value["payload_contract"] + "\n"
    "payload_digest\t" + payload_digest + "\n"
)
print("sha256:" + hashlib.sha256(manifest.encode()).hexdigest())
PY
)"
  assert_eq "$expected" "$first_digest" "generic intent digest must hash the canonical manifest"
}

test_applied_effect_reducer_recovers_without_reauthorization() {
  python3 - "$ROOT/lib" "$TMPDIR/applied-effect-request.json" <<'PY'
import json
import sys

sys.path.insert(0, sys.argv[1])
from workbench_effect import reduce_applied_effect
from workbench_intent import load_request

revision = "sha256:" + "4" * 64
payload = (
    "workbench-deliverable-accept-intent/v1\n"
    "deliverable_id\tpack-1\n"
    "record_revision\t" + revision + "\n"
    "mode\towner-assertion\n"
    "acceptance_id\tacc-pack-1\n"
    "deliverable_revision\tsha256:" + "5" * 64 + "\n"
    "owner_context_ref\ttoolbox:product/acme\n"
    "acceptance_authority_ref\ttoolbox:policy/acme\n"
    "authority_contract\tworkbench-owner-acceptance/v1\n"
    "subject_authority_digest\tsha256:" + "6" * 64 + "\n"
    "actor\towner@example.com\n"
    "accepted_at\t2026-07-11T03:01:00Z\n"
)
request_value = {
    "contract_version": "workbench-action-request/v1",
    "action_id": "task.deliverable.accept",
    "task_claim_id": "claim-policy-42",
    "target_ref": "workbench:deliverable/pack-1",
    "revision": revision,
    "payload_contract": "workbench-deliverable-accept-intent/v1",
    "payload": payload,
}
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(request_value, handle, separators=(",", ":"))
    handle.write("\n")
request = load_request(sys.argv[2])
manifest = "sha256:" + "7" * 64
primary_digest = "sha256:" + "8" * 64
action = {
    "id": "act_pack_1",
    "action_id": request["action_id"],
    "task_claim_id": request["task_claim_id"],
    "target_ref": request["target_ref"],
    "revision": request["revision"],
    "intent_digest": request["intent_digest"],
    "policy_manifest_digest": manifest,
    "authorization_ref": "conversation:message/msg-pack-1",
    "status": "authorized",
    "consumed_provenance_digest": None,
}
primary = {
    "action_instance_id": action["id"],
    "intent_digest": action["intent_digest"],
    "policy_manifest_digest": manifest,
    "authorization_ref": action["authorization_ref"],
    "primary_digest": primary_digest,
}
decision = reduce_applied_effect(action, request, [primary], "missing", mandatory_authorization=True)
assert decision == {
    "decision": "reconcile",
    "primary_digest": primary_digest,
    "write_secondary": True,
    "consume_action": True,
    "blocker": None,
}

duplicate = reduce_applied_effect(action, request, [primary, dict(primary)], "missing", mandatory_authorization=True)
assert duplicate["decision"] == "blocked"
assert duplicate["blocker"] == {"code": "action-effect-unreconciled", "ref": "act_pack_1"}

consumed = dict(action, status="consumed", consumed_provenance_digest=primary_digest)
idempotent = reduce_applied_effect(consumed, request, [], "missing", mandatory_authorization=True)
assert idempotent["decision"] == "idempotent"
assert idempotent["consume_action"] is False
PY
}

test_github_probe_separates_stable_subject_from_observation() {
  local first second subject_one subject_two receipt_one receipt_two helper
  helper="$ROOT/lib/workbench_contract.py"
  first="2026-07-11T03:20:00Z"; second="2026-07-11T03:21:00Z"
  subject_one="$(python3 "$helper" github-probe --repository example/web-app \
    --pull-request 12 --external-ref https://github.com/example/web-app/pull/12 \
    --state merged --head-revision 0123456789abcdef --merge-revision fedcba9876543210 \
    --observed-at "$first" --format subject-digest)"
  subject_two="$(python3 "$helper" github-probe --repository example/web-app \
    --pull-request 12 --external-ref https://github.com/example/web-app/pull/12 \
    --state merged --head-revision 0123456789abcdef --merge-revision fedcba9876543210 \
    --observed-at "$second" --format subject-digest)"
  assert_eq "$subject_one" "$subject_two" \
    "stable PR subject digest must exclude observation time"
  receipt_one="$(python3 "$helper" github-probe --repository example/web-app \
    --pull-request 12 --external-ref https://github.com/example/web-app/pull/12 \
    --state merged --head-revision 0123456789abcdef --merge-revision fedcba9876543210 \
    --observed-at "$first" --format digest)"
  receipt_two="$(python3 "$helper" github-probe --repository example/web-app \
    --pull-request 12 --external-ref https://github.com/example/web-app/pull/12 \
    --state merged --head-revision 0123456789abcdef --merge-revision fedcba9876543210 \
    --observed-at "$second" --format digest)"
  [ "$receipt_one" != "$receipt_two" ] \
    || fail "timestamped PR observation digest must include observation time"
}

test_writer_ledger_reduces_effect_owner_before_claim_release() {
  local active invalid valid actual out err rc helper digest
  helper="$ROOT/lib/workbench_writer.py"
  digest="sha256:$(printf '3%.0s' {1..64})"
  active="$TMPDIR/writer-ledger-active.tsv"
  {
    printf '%s\n' 'workbench-writer-claims/v1'
    printf 'claim\twop_1\twc_1\tclaim-policy-42\tshared-api\ttask/42-policy\ttask/codebases/shared-api\thttps://github.com/example/shared-api.git\t%s\tnull\tnull\tnull\tnull\tactive\n' "$digest"
    printf 'effect-owner\tevent_1\twop_1\twc_1\tdevice:trusted/mac-1\t123e4567-e89b-12d3-a456-426614174000\tacquired\n'
  } > "$active"
  actual="$(python3 "$helper" ledger-state "$active" --operation-id wop_1 \
    --claim-id wc_1 --format json)"
  assert_eq acquired "$(json_path "$actual" effect_owner.state)" \
    "ledger reducer must expose the current effect owner"
  assert_eq device:trusted/mac-1 "$(json_path "$actual" effect_owner.device_id)" \
    "effect owner identity must be preserved"

  invalid="$TMPDIR/writer-ledger-owned-release.tsv"
  {
    sed -n '1,2p' "$active"
    printf 'claim\twop_1\twc_1\tclaim-policy-42\tshared-api\ttask/42-policy\ttask/codebases/shared-api\thttps://github.com/example/shared-api.git\t%s\tnull\tnull\tnull\tnull\treleased\n' "$digest"
    sed -n '3p' "$active"
  } > "$invalid"
  out="$TMPDIR/writer-ledger-owned-release.out"; err="$TMPDIR/writer-ledger-owned-release.err"
  if python3 "$helper" ledger-state "$invalid" --operation-id wop_1 --claim-id wc_1 \
    --format json >"$out" 2>"$err"; then
    fail "claim release while effect owner is current must fail"
  else rc=$?; fi
  assert_eq 2 "$rc" "malformed writer ledger uses input-error exit"
  [ ! -s "$out" ] || fail "malformed writer ledger must emit no partial JSON"

  valid="$TMPDIR/writer-ledger-released.tsv"
  {
    sed -n '1,2p' "$active"
    printf 'claim\twop_1\twc_1\tclaim-policy-42\tshared-api\ttask/42-policy\ttask/codebases/shared-api\thttps://github.com/example/shared-api.git\t%s\tnull\tnull\tnull\tnull\treleased\n' "$digest"
    sed -n '3p' "$active"
    printf 'effect-owner\tevent_2\twop_1\twc_1\tdevice:trusted/mac-1\t123e4567-e89b-12d3-a456-426614174000\treleased\n'
  } > "$valid"
  actual="$(python3 "$helper" ledger-state "$valid" --operation-id wop_1 \
    --claim-id wc_1 --format json)"
  assert_eq released "$(json_path "$actual" claim_state)" \
    "claim may release only after the effect owner sequence releases"
  assert_eq released "$(json_path "$actual" effect_owner.state)" \
    "released effect-owner history remains auditable"
}

test_writer_operation_uses_the_exact_recovery_cursor_schema() {
  local operation reordered actual out err rc
  operation="$TMPDIR/writer-operation.json"
  reordered="$TMPDIR/writer-operation-reordered.json"
  python3 - "$operation" "$reordered" <<'PY'
import json
import sys

value = {
    "contract_version": "workbench-writer-operation/v1",
    "operation_id": "wop_1",
    "claim_id": "wc_1",
    "task_claim_id": "claim-policy-42",
    "owner": "shared-api",
    "branch": "task/42-policy",
    "expected_path": "task/codebases/shared-api",
    "codebase_origin_url": "https://github.com/example/shared-api.git",
    "registry_revision": "1" * 40,
    "registry_digest": "sha256:" + "2" * 64,
    "context_policy_set_digest": "sha256:" + "3" * 64,
    "device_id": "device:trusted/mac-1",
    "clone_id": "123e4567-e89b-12d3-a456-426614174000",
    "action_instance_id": None,
    "intent_digest": None,
    "policy_manifest": None,
    "authorization_ref": None,
    "effect_owner_state": "none",
    "worktree_ownership": "none",
    "repo_record_ownership": "none",
    "worktree_set_digest": None,
    "compensation_target": None,
    "compensation_reason": None,
    "compensation_next_step": None,
    "coordination_ref": "refs/heads/workbench-coordination/writer-claims",
    "coordination_oid": None,
    "stage": "prepared",
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
items = list(value.items())
items[-1], items[-2] = items[-2], items[-1]
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(dict(items), handle, separators=(",", ":"))
    handle.write("\n")
PY
  actual="$(python3 "$ROOT/lib/workbench_writer.py" operation "$operation" --format json)"
  assert_eq prepared "$(json_path "$actual" stage)" \
    "prepared writer operation must validate"
  out="$TMPDIR/writer-operation-reordered.out"; err="$TMPDIR/writer-operation-reordered.err"
  if python3 "$ROOT/lib/workbench_writer.py" operation "$reordered" --format json \
    >"$out" 2>"$err"; then
    fail "writer operation with reordered fields must fail"
  else rc=$?; fi
  assert_eq 2 "$rc" "reordered operation is malformed input"
  [ ! -s "$out" ] || fail "invalid writer operation must emit no partial JSON"
}

test_cleanup_journal_binds_the_exact_removal_plan_prefix() {
  local helper plan policy prepared completed comments actual digest manifest_digest intent
  helper="$ROOT/lib/workbench_cleanup.py"
  plan="$TMPDIR/cleanup-plan.json"; policy="$TMPDIR/cleanup-policy.json"
  prepared="$TMPDIR/cleanup-prepared.json"; completed="$TMPDIR/cleanup-completed.json"
  comments="$TMPDIR/cleanup-comments.txt"
  digest="sha256:$(printf 'workbench-task-removal-plan/v1\ntask_id\t42\nclaim_id\tclaim-policy-42\ntask_branch\ttask/42-policy\ntask_workspace\t.worktrees/task__42-policy\nlocal_branch\ttask/42-policy\n' | shasum -a 256 | awk '{print $1}')"
  manifest_digest="sha256:$(printf '9%.0s' {1..64})"
  intent="sha256:$(printf '7%.0s' {1..64})"
  python3 - "$plan" "$policy" "$manifest_digest" <<'PY'
import json
import sys

plan = {
    "writer_operations": [],
    "codebase_worktrees": [],
    "task_workspace": ".worktrees/task__42-policy",
    "local_branch": "task/42-policy",
}
manifest = {
    "contract_version": "workbench-policy-manifest/v1",
    "digest": sys.argv[3],
    "sources": [],
}
resolution = {
    "contract_version": "workbench-policy/v1",
    "action_instance": {
        "id": "act_cleanup_1",
        "action_id": "task.cleanup",
        "task_claim_id": "claim-policy-42",
        "target_ref": "workbench:task/claim-policy-42",
        "revision": "sha256:" + "2" * 64,
        "intent_digest": "sha256:" + "7" * 64,
        "policy_manifest": manifest,
        "status": "authorized",
    },
    "decision": "allow",
    "authorization_ref": "conversation:message/msg-cleanup",
}
for path, value in ((sys.argv[1], plan), (sys.argv[2], resolution)):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, separators=(",", ":"))
        handle.write("\n")
PY
  python3 "$helper" build --policy-resolution-file "$policy" --task-id 42 \
    --claim-id claim-policy-42 --branch task/42-policy \
    --revision "sha256:$(printf '2%.0s' {1..64})" --action-instance-id act_cleanup_1 \
    --intent-digest "$intent" --removal-plan-digest "$digest" --removal-plan-file "$plan" \
    --at 2026-07-11T03:30:00Z > "$prepared"
  python3 - "$prepared" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
assert list(value) == [
    "contract_version", "journal_id", "stage", "task_id", "claim_id", "branch",
    "revision", "action_instance_id", "intent_digest", "policy_manifest",
    "authorization_ref", "removal_plan_digest", "removal_plan",
    "effect_owner_events", "at",
]
assert value["stage"] == "prepared"
assert value["effect_owner_events"] == []
assert list(value["removal_plan"]) == [
    "writer_operations", "codebase_worktrees", "task_workspace", "local_branch",
]
PY
  python3 "$helper" stage "$prepared" --stage completed \
    --at 2026-07-11T03:31:00Z > "$completed"
  {
    printf '%s\n' '<!-- workbench-task-cleanup:v1'
    cat "$prepared"
    printf '%s\n' '-->' '<!-- workbench-task-cleanup:v1'
    cat "$completed"
    printf '%s\n' '-->'
  } > "$comments"
  actual="$(python3 "$helper" find --comments-file "$comments" --task-id 42 \
    --branch task/42-policy)"
  assert_eq completed "$(json_path "$actual" stage)" \
    "cleanup reducer must select the unique longest valid prefix"
}

test_closed_legacy_home_set_binds_registry_origins() {
  local authority registry changed first second first_digest second_digest
  authority="$TMPDIR/legacy-authority.json"
  registry="$TMPDIR/legacy-codebases.yaml"
  changed="$TMPDIR/legacy-codebases-changed.yaml"
  python3 - "$authority" <<'PY'
import json
import sys

value = {
    "contract_version": "workbench-workspace-authority/v1",
    "authority_identity": "github:example/workbench",
    "origin_url": "https://github.com/example/workbench.git",
    "default_ref": "refs/heads/main",
    "workspace_home": "workbench",
    "hosting_adapter": "github",
    "hosting_ref": "github:repository/example/workbench",
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  {
    printf '%s\n' 'shared-api: https://github.com/example/shared-api.git'
    printf '%s\n' 'web-app: https://github.com/example/web-app.git'
  } > "$registry"
  {
    printf '%s\n' 'shared-api: https://github.com/example/shared-api-v2.git'
    printf '%s\n' 'web-app: https://github.com/example/web-app.git'
  } > "$changed"
  first="$(python3 "$ROOT/lib/workbench_legacy.py" home-set --authority-file "$authority" \
    --registry-file "$registry" --format json)"
  second="$(python3 "$ROOT/lib/workbench_legacy.py" home-set --authority-file "$authority" \
    --registry-file "$changed" --format json)"
  assert_eq shared-api "$(json_path "$first" homes.0.home)" \
    "registry homes must be sorted canonically"
  assert_eq workbench "$(json_path "$first" homes.2.home)" \
    "workspace home must participate in the closed legacy inventory"
  first_digest="$(json_path "$first" digest)"; second_digest="$(json_path "$second" digest)"
  [ "$first_digest" != "$second_digest" ] \
    || fail "replacing a home origin must change the closed home-set digest"
}

test_public_legacy_inventory_is_exhaustive_and_repo_independent() {
  local repo revision observation incomplete actual out err rc before after adapter incomplete_adapter bad_hosting
  repo="$(make_policy_task legacy_inventory)"
  printf '%s\n' 'shared-api: https://github.com/example/shared-api.git' > "$repo/codebases.yaml"
  git -C "$repo" add codebases.yaml
  git -C "$repo" commit -q -m "test: register legacy home"
  git -C "$repo" push -q
  revision="$(git -C "$repo" rev-parse HEAD)"
  observation="$TMPDIR/legacy-observation.json"
  incomplete="$TMPDIR/legacy-observation-incomplete.json"
  python3 - "$observation" "$incomplete" "$revision" \
    "$(git -C "$repo" remote get-url origin)" <<'PY'
import json
import sys

pagination = {"complete": True, "pages_fetched": 1, "end_cursor": None, "failure": None}
claim = {
    "claim_id": "legacy-task-42",
    "task_claim_id": "legacy-task-42",
    "task_contract": "workbench-task/v1",
    "issue": 42,
    "home": "workbench",
    "parent": None,
    "branch": "task/42-legacy",
    "lifecycle_digest": "sha256:" + "8" * 64,
    "lifecycle_state": "task-submitted",
    "classification": "active-v1",
    "submission": {"pull_request": 7, "head_revision": sys.argv[3], "current": True},
    "source_revision": sys.argv[3],
    "pr_head_revision": sys.argv[3],
    "ancestry_complete": True,
    "repos": [],
}
value = {
    "contract_version": "workbench-legacy-observation/v1",
    "source_revision": sys.argv[3],
    "homes": [
        {
            "home": "shared-api",
            "origin_url": "https://github.com/example/shared-api.git",
            "membership": "current",
            "pagination": pagination,
            "claims": [],
        },
        {
            "home": "workbench",
            "origin_url": sys.argv[4],
            "membership": "current",
            "pagination": pagination,
            "claims": [claim],
        },
    ],
    "origin_replacements": [],
    "blockers": [],
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":")); handle.write("\n")
broken = json.loads(json.dumps(value))
broken["homes"][0]["pagination"] = {
    "complete": False, "pages_fetched": 1, "end_cursor": "cursor-1",
    "failure": {"code": "page-fetch-failed", "ref": "shared-api", "cursor": "cursor-1"},
}
broken["blockers"] = [{"code": "legacy-writer-source-unavailable", "ref": "shared-api"}]
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(broken, handle, separators=(",", ":")); handle.write("\n")
PY
  adapter="$TMPDIR/legacy-observation-adapter"
  incomplete_adapter="$TMPDIR/legacy-incomplete-adapter"
  write_test_legacy_adapter "$adapter" "$observation"
  write_test_legacy_adapter "$incomplete_adapter" "$incomplete"
  before="$(readonly_git_snapshot "$repo")"
  actual="$(WORKBENCH_TRUSTED_LEGACY_ADAPTER="$adapter" \
    WORKBENCH_LEGACY_INVENTORY_OBSERVATION="$incomplete" \
    run_workbench "$repo" legacy-inventory show --format json)"
  after="$(readonly_git_snapshot "$repo")"
  assert_eq "$before" "$after" "descriptor-backed inventory must not mutate caller Git state"
  printf '%s\n' "$actual" | python3 -c '
import json, sys
value = json.load(sys.stdin)
assert list(value) == [
    "contract_version", "source_revision", "authority", "home_set", "homes", "active_claims",
    "origin_replacements", "complete", "blockers",
]
assert value["contract_version"] == "workbench-legacy-inventory/v1"
assert value["source_revision"] == value["authority"]["default_revision"] == value["home_set"]["source_revision"]
assert value["complete"] is True and value["blockers"] == []
assert [item["home"] for item in value["homes"]] == ["shared-api", "workbench"]
claim = value["homes"][1]["claims"][0]
assert claim["task_contract"] == "workbench-task/v1"
assert claim["classification"] == "active-v1" and claim["repos"] == []
assert value["active_claims"] == []
' || fail "public legacy inventory must retain repo-less active v1 tasks"

  out="$TMPDIR/legacy-inventory-incomplete.out"; err="$TMPDIR/legacy-inventory-incomplete.err"
  if WORKBENCH_TRUSTED_LEGACY_ADAPTER="$incomplete_adapter" \
    run_workbench "$repo" legacy-inventory show --format json >"$out" 2>"$err"; then
    fail "partial legacy pagination must fail closed"
  else rc=$?; fi
  assert_eq 1 "$rc" "incomplete legacy inventory uses state-failure exit"
  assert_file_contains "$out" '"complete":false'
  assert_file_contains "$out" '"code":"legacy-writer-source-unavailable"'

  bad_hosting="$TMPDIR/legacy-unprotected-hosting-adapter"
  write_test_hosting_adapter "$bad_hosting" false blocked
  if WORKBENCH_TRUSTED_HOSTING_ADAPTER="$bad_hosting" \
    WORKBENCH_TRUSTED_LEGACY_ADAPTER="$adapter" \
    run_workbench "$repo" legacy-inventory show --format json >"$out" 2>"$err"; then
    fail "legacy inventory must authenticate protected registry authority"
  else rc=$?; fi
  assert_eq 1 "$rc" "unprotected legacy inventory authority is a state failure"
  assert_file_contains "$err" "protected default authority proof is invalid"

  if WORKBENCH_TRUSTED_LEGACY_ADAPTER="$TMPDIR/missing-legacy-adapter" \
    run_workbench "$repo" legacy-inventory show --format json >"$out" 2>"$err"; then
    fail "legacy inventory without a trusted executable adapter must fail"
  else rc=$?; fi
  assert_eq 1 "$rc" "missing legacy adapter is a state failure"
  assert_file_contains "$err" "trusted legacy adapter is unavailable"
}

write_bootstrap_approval() {
  local file="$1" origin="$2" revision="$3"
  python3 - "$file" "$origin" "$revision" <<'PY'
import json
import sys

descriptor = {
    "contract_version": "workbench-workspace-authority/v1",
    "authority_identity": "fixture:authority/approved",
    "origin_url": sys.argv[2],
    "default_ref": "refs/heads/main",
    "workspace_home": "workbench",
    "hosting_adapter": "fixture",
    "hosting_ref": "fixture:repository/approved-workbench",
}
value = {
    "contract_version": "workbench-bootstrap-authority-approval/v1",
    "approval_id": "approval_bootstrap_fixture",
    "proposed_descriptor": descriptor,
    "default_revision": sys.argv[3],
    "protection": {
        "ref": "refs/heads/main",
        "revision": sys.argv[3],
        "direct_task_actor_writes": "blocked",
        "verified_at": "2026-07-11T03:00:00Z",
        "evidence_ref": "fixture:protection/approved-workbench-main",
    },
    "actor": "human@example.com",
    "approved_at": "2026-07-11T03:01:00Z",
    "source_ref": "conversation:message/bootstrap-approval",
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
}

write_bootstrap_adapter() {
  local file="$1"
  cat > "$file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = verify ] && [ "$2" = --approval-file ] && [ "$4" = --format ] && [ "$5" = json ]
python3 - "$3" <<'PY'
import hashlib
import json
import sys

raw = open(sys.argv[1], "rb").read()
value = json.loads(raw)
descriptor = value["proposed_descriptor"]
output = {
    "contract_version": "workbench-bootstrap-authority-verification/v1",
    "approval_digest": "sha256:" + hashlib.sha256(raw).hexdigest(),
    "authenticated": True,
    "repository_identity_verified": True,
    "default_ref_protected": True,
    "direct_task_actor_writes": "blocked",
    "observed_default_revision": value["default_revision"],
    "permission_source": descriptor["hosting_ref"],
}
print(json.dumps(output, separators=(",", ":")))
PY
EOF
  chmod +x "$file"
}

write_complete_bootstrap_observation() {
  local file="$1" revision="$2" origin="$3"
  python3 - "$file" "$revision" "$origin" <<'PY'
import json
import sys

pagination = {"complete": True, "pages_fetched": 1, "end_cursor": None, "failure": None}
value = {
    "contract_version": "workbench-legacy-observation/v1",
    "source_revision": sys.argv[2],
    "homes": [{
        "home": "workbench",
        "origin_url": sys.argv[3],
        "membership": "current",
        "pagination": pagination,
        "claims": [],
    }],
    "origin_replacements": [],
    "blockers": [],
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
}

test_bootstrap_legacy_inventory_uses_only_authenticated_approval() {
  local layout repo approved hostile revision approval adapter legacy_adapter observation actual
  local out err rc before after
  adapter="$TMPDIR/bootstrap-authority-adapter"
  write_bootstrap_adapter "$adapter"

  for layout in generated-minimal embedded-legacy; do
    repo="$(make_workspace "bootstrap-$layout")"
    approved="$TMPDIR/bootstrap-$layout-approved.git"
    hostile="$TMPDIR/bootstrap-$layout-hostile.git"
    git init -q --bare "$approved"
    git init -q --bare "$hostile"
    printf '%s\n' '# no registered codebases' > "$repo/codebases.yaml"
    if [ "$layout" = embedded-legacy ]; then
      mkdir -p "$repo/docs" "$repo/skills/local"
      printf '%s\n' '# Preserved overlay' > "$repo/AGENTS.md"
      printf '%s\n' '# Accumulated knowledge' > "$repo/docs/index.md"
    fi
    git -C "$repo" add .
    git -C "$repo" commit -q -m "test: prepare $layout"
    git -C "$repo" push -q "$approved" main
    git -C "$approved" symbolic-ref HEAD refs/heads/main
    git -C "$hostile" symbolic-ref HEAD refs/heads/main
    git -C "$repo" remote add origin "$hostile"
    revision="$(git -C "$repo" rev-parse HEAD)"
    approval="$TMPDIR/bootstrap-$layout-approval.json"
    observation="$TMPDIR/bootstrap-$layout-observation.json"
    write_bootstrap_approval "$approval" "$approved" "$revision"
    write_complete_bootstrap_observation "$observation" "$revision" "$approved"
    legacy_adapter="$TMPDIR/bootstrap-$layout-legacy-adapter"
    write_test_legacy_adapter "$legacy_adapter" "$observation"

    mkdir -p "$repo/.workbench"
    if [ "$layout" = embedded-legacy ]; then
      printf '%s\n' workbench/v2 > "$repo/.workbench/schema"
    fi
    printf '%s\n' '{"caller":"authored-and-untrusted"}' > "$repo/.workbench/authority.json"
    before="$(readonly_git_snapshot "$repo")"
    actual="$(WORKBENCH_TRUSTED_BOOTSTRAP_AUTHORITY_ADAPTER="$adapter" \
      WORKBENCH_TRUSTED_LEGACY_ADAPTER="$legacy_adapter" \
      run_workbench "$repo" legacy-inventory bootstrap-show \
        --authority-approval-file "$approval" --format json)"
    after="$(readonly_git_snapshot "$repo")"
    assert_eq "$before" "$after" "bootstrap inventory must not mutate caller Git state"
    ACTUAL="$actual" python3 - "$approval" "$revision" <<'PY'
import hashlib
import json
import os
import sys

approval = json.load(open(sys.argv[1], encoding="utf-8"))
value = json.loads(os.environ["ACTUAL"])
descriptor_raw = (json.dumps(
    approval["proposed_descriptor"], separators=(",", ":")
) + "\n").encode()
assert value["contract_version"] == "workbench-legacy-inventory/v1"
assert value["source_revision"] == value["authority"]["default_revision"]
assert value["source_revision"] == value["home_set"]["source_revision"] == sys.argv[2]
assert value["authority"]["authority_identity"] == "fixture:authority/approved"
assert value["authority"]["descriptor_digest"] == "sha256:" + hashlib.sha256(descriptor_raw).hexdigest()
assert value["authority"]["bootstrap_revision"] == sys.argv[2]
assert value["complete"] is True and value["blockers"] == []
assert [item["home"] for item in value["homes"]] == ["workbench"]
PY
  done

  printf '%s\n' moved >> "$repo/README.md"
  printf '%s\n' workbench/v2 > "$repo/.workbench/schema"
  git -C "$repo" add README.md .workbench/schema
  git -C "$repo" commit -q -m "test: advance approved default"
  git -C "$repo" push -q "$approved" main
  out="$TMPDIR/bootstrap-stale-approval.out"; err="$TMPDIR/bootstrap-stale-approval.err"
  if WORKBENCH_TRUSTED_BOOTSTRAP_AUTHORITY_ADAPTER="$adapter" \
    WORKBENCH_TRUSTED_LEGACY_ADAPTER="$legacy_adapter" \
    run_workbench "$repo" legacy-inventory bootstrap-show \
      --authority-approval-file "$approval" --format json >"$out" 2>"$err"; then
    fail "bootstrap inventory must reject an approval for a stale default OID"
  else rc=$?; fi
  assert_eq 1 "$rc" "stale bootstrap authority is a state failure"
  [ ! -s "$out" ] || fail "stale bootstrap approval must emit no inventory"

  revision="$(git -C "$repo" rev-parse HEAD)"
  write_bootstrap_approval "$approval" "$approved" "$revision"
  write_complete_bootstrap_observation "$observation" "$revision" "$approved"
  if WORKBENCH_TRUSTED_BOOTSTRAP_AUTHORITY_ADAPTER="$adapter" \
    WORKBENCH_TRUSTED_LEGACY_ADAPTER="$legacy_adapter" \
    run_workbench "$repo" legacy-inventory bootstrap-show \
      --authority-approval-file "$approval" --format json >"$out" 2>"$err"; then
    fail "bootstrap inventory must close once the approved default contains a v2 marker"
  else rc=$?; fi
  assert_eq 1 "$rc" "v2 approved default closes the bootstrap inventory path"
  [ ! -s "$out" ] || fail "v2-default bootstrap rejection must emit no inventory"
}

test_legacy_inventory_entrypoints_are_schema_scoped() {
  local v1 out err rc
  v1="$(make_workspace legacy-show-v1)"
  out="$TMPDIR/legacy-show-v1.out"; err="$TMPDIR/legacy-show-v1.err"
  if run_workbench "$v1" legacy-inventory show --format json >"$out" 2>"$err"; then
    fail "descriptor-backed legacy inventory show must require workbench/v2"
  else rc=$?; fi
  assert_eq 1 "$rc" "normal legacy inventory on implicit v1 is a state failure"
  [ ! -s "$out" ] || fail "schema-scoped legacy inventory failure emits no JSON"
}

write_doctor_hosting_adapter() {
  local file="$1"
  cat > "$file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = doctor ] && [ "$2" = --authority-file ] && [ "$4" = --default-revision ] \
  && [ "$6" = --coordination-ref ] && [ "$8" = --format ] && [ "$9" = json ]
python3 - "$3" "$5" "$7" <<'PY'
import json
import sys

authority = json.load(open(sys.argv[1], encoding="utf-8"))
value = {
    "contract_version": "workbench-hosting-readiness/v1",
    "authority_identity": authority["authority_identity"],
    "origin_url": authority["origin_url"],
    "default_ref": authority["default_ref"],
    "default_revision": sys.argv[2],
    "default_ref_protected": True,
    "coordination_ref": sys.argv[3],
    "push_permission": "allowed",
    "permission_source": authority["hosting_ref"] or "fixture:repository/local",
    "push_ready": True,
}
print(json.dumps(value, separators=(",", ":")))
PY
EOF
  chmod +x "$file"
}

test_doctor_is_read_only_and_reports_exact_readiness() {
  local v1 repo revision observation adapter legacy_adapter actual before after out err rc origin
  v1="$(make_workspace doctor-v1)"
  out="$TMPDIR/doctor-v1.out"; err="$TMPDIR/doctor-v1.err"
  if run_workbench "$v1" doctor --format json >"$out" 2>"$err"; then
    fail "implicit v1 doctor must not report v2 writer readiness"
  else rc=$?; fi
  assert_eq 1 "$rc" "not-ready doctor uses readiness exit 1"
  [ ! -s "$err" ] || fail "computed doctor blocker must not write stderr"
  python3 - "$out" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
assert list(value) == ["contract_version", "ready", "writer_coordination"]
assert value["contract_version"] == "workbench-doctor/v1" and value["ready"] is False
coordination = value["writer_coordination"]
assert list(coordination) == [
    "authority_identity", "origin_url", "default_ref", "default_ref_revision",
    "default_ref_protected", "descriptor_digest", "ref", "revision", "readable",
    "legacy_inventory_readable", "push_permission", "permission_source", "push_ready",
    "blocker",
]
assert coordination["authority_identity"] is None
assert coordination["origin_url"] is None
assert coordination["default_ref"] is None
assert coordination["default_ref_revision"] is None
assert coordination["default_ref_protected"] is False
assert coordination["descriptor_digest"] is None
assert coordination["ref"] == "refs/heads/workbench-coordination/writer-claims"
assert coordination["revision"] is None and coordination["readable"] is False
assert coordination["legacy_inventory_readable"] is False
assert coordination["push_permission"] == "unknown"
assert coordination["permission_source"] is None and coordination["push_ready"] is False
assert coordination["blocker"] == {
    "code": "writer-lock-unavailable",
    "ref": "refs/heads/workbench-coordination/writer-claims",
}
PY

  repo="$(make_policy_task doctor-ready)"
  printf '%s\n' '# no registered codebases' > "$repo/codebases.yaml"
  git -C "$repo" add codebases.yaml
  git -C "$repo" commit -q -m "test: add canonical registry"
  git -C "$repo" push -q
  revision="$(git -C "$repo" rev-parse HEAD)"
  origin="$(git -C "$repo" remote get-url origin)"
  observation="$TMPDIR/doctor-observation.json"
  write_complete_bootstrap_observation "$observation" "$revision" "$origin"
  adapter="$TMPDIR/doctor-hosting-adapter"
  legacy_adapter="$TMPDIR/doctor-legacy-adapter"
  write_test_hosting_adapter "$adapter"
  write_test_legacy_adapter "$legacy_adapter" "$observation"
  before="$(readonly_git_snapshot "$repo")"
  actual="$(WORKBENCH_TRUSTED_HOSTING_ADAPTER="$adapter" \
    WORKBENCH_TRUSTED_LEGACY_ADAPTER="$legacy_adapter" \
    run_workbench "$repo" doctor --format json)"
  after="$(readonly_git_snapshot "$repo")"
  assert_eq "$before" "$after" "doctor must not mutate caller Git state"
  ACTUAL="$actual" python3 - "$revision" "$origin" <<'PY'
import json
import os
import sys

value = json.loads(os.environ["ACTUAL"])
assert value["contract_version"] == "workbench-doctor/v1" and value["ready"] is True
coordination = value["writer_coordination"]
assert coordination["authority_identity"] == "fixture:workspace/local"
assert coordination["origin_url"] == sys.argv[2]
assert coordination["default_ref"] == "refs/heads/main"
assert coordination["default_ref_revision"] == sys.argv[1]
assert coordination["default_ref_protected"] is True
assert coordination["descriptor_digest"].startswith("sha256:")
assert coordination["revision"] is None and coordination["readable"] is True
assert coordination["legacy_inventory_readable"] is True
assert coordination["push_permission"] == "allowed"
assert coordination["permission_source"] == "fixture:repository/local"
assert coordination["push_ready"] is True and coordination["blocker"] is None
PY

  if WORKBENCH_TRUSTED_HOSTING_ADAPTER="$TMPDIR/missing-doctor-hosting-adapter" \
    WORKBENCH_TRUSTED_LEGACY_ADAPTER="$legacy_adapter" \
    run_workbench "$repo" doctor --format json >"$out" 2>"$err"; then
    fail "doctor without trusted ref-permission proof must not be ready"
  else rc=$?; fi
  assert_eq 1 "$rc" "unknown hosting permission is a readiness failure"
  assert_file_contains "$out" '"push_permission":"unknown"'
  assert_file_contains "$out" '"push_ready":false'
}

test_policy_resolution_and_authorization_bind_intent_digest() {
  local repo request changed pending replacement instance intent manifest auth actual rc
  repo="$(make_policy_task policy_intent_binding)"
  request="$TMPDIR/policy-intent-request.json"
  changed="$TMPDIR/policy-intent-changed.json"
  python3 - "$request" "$changed" <<'PY'
import json
import sys

revision = "sha256:" + "2" * 64
for path, decision, target in (
    (sys.argv[1], "absorb", "workbench:docs/hv-2"),
    (sys.argv[2], "discard", "null"),
):
    payload = (
        "workbench-harvest-disposition-intent/v1\n"
        "candidate_id\thv-2\n"
        "record_revision\t" + revision + "\n"
        "decision\t" + decision + "\n"
        "target_ref\t" + target + "\n"
        "reason_code\tvalidated\n"
        "reason_ref\tnull\n"
    )
    value = {
        "contract_version": "workbench-action-request/v1",
        "action_id": "task.harvest.dispose",
        "task_claim_id": "claim-policy-42",
        "target_ref": "workbench:harvest/hv-2",
        "revision": revision,
        "payload_contract": "workbench-harvest-disposition-intent/v1",
        "payload": payload,
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, separators=(",", ":"))
        handle.write("\n")
PY
  intent="$(python3 "$ROOT/lib/workbench_intent.py" request "$request" --format json \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["intent_digest"])')"
  if pending="$(run_workbench "$repo" policy resolve --request-file "$request" \
    --intent-digest "$intent" --format json)"; then
    fail "missing harvest policy must resolve ask"
  else rc=$?; fi
  assert_eq 3 "$rc" "intent-bound ask must use exit 3"
  assert_contains "$pending" '"intent_digest":"' "policy output must expose intent binding"
  instance="$(json_path "$pending" action_instance.id)"
  manifest="$(json_path "$pending" action_instance.policy_manifest.digest)"
  cmp -s "$request" "$repo/task/.workbench/actions/$instance.request.json" \
    || fail "policy resolver must persist the exact validated action request"

  replacement="$(python3 "$ROOT/lib/workbench_intent.py" request "$changed" --format json \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["intent_digest"])')"
  if actual="$(run_workbench "$repo" policy resolve --request-file "$changed" \
    --intent-digest "$replacement" --action-instance-id "$instance" --format json)"; then
    fail "replacement harvest intent must remain ask"
  else rc=$?; fi
  assert_eq 3 "$rc" "changed intent must resolve a replacement"
  [ "$(json_path "$actual" action_instance.id)" != "$instance" ] \
    || fail "changed requested effect must supersede the old action instance"
  assert_file_contains "$repo/task/.workbench/actions/$instance.record" 'status=superseded'

  instance="$(json_path "$actual" action_instance.id)"
  manifest="$(json_path "$actual" action_instance.policy_manifest.digest)"
  auth="$TMPDIR/policy-intent-authorization.json"
  python3 - "$auth" "$instance" "$replacement" "$manifest" <<'PY'
import json
import sys

value = {
    "contract_version": "workbench-authorization/v1",
    "authorization_id": "auth_" + sys.argv[2],
    "action_instance_id": sys.argv[2],
    "action_id": "task.harvest.dispose",
    "task_claim_id": "claim-policy-42",
    "target_ref": "workbench:harvest/hv-2",
    "revision": "sha256:" + "2" * 64,
    "intent_digest": sys.argv[3],
    "policy_manifest_digest": sys.argv[4],
    "decision": "allow",
    "actor": "human@example.com",
    "authorized_at": "2026-07-11T03:01:00Z",
    "source_ref": "conversation:message/msg-intent",
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  actual="$(run_workbench "$repo" policy resolve --request-file "$changed" \
    --intent-digest "$replacement" --action-instance-id "$instance" \
    --authorization-file "$auth" --format json)"
  assert_contains "$actual" '"status":"authorized"' \
    "matching intent-bound authorization must authorize the instance"
}

test_discovery_uses_the_caller_linked_worktree_and_emits_valid_json() {
  local repo worktree caller_root actual decoded profile
  repo="$(make_workspace linked_base)"
  worktree="$TMPDIR/linked space \"quote\" \\slash"
  git -C "$repo" worktree add -q -b linked-discovery "$worktree"
  caller_root="$(git -C "$worktree" rev-parse --show-toplevel)"
  mkdir -p "$worktree/.workbench"
  printf 'workbench/v2\n' > "$worktree/.workbench/schema"
  printf 'schema=workbench-profile/v1\nlanguage=en-US-u-ca-gregory\n' \
    > "$worktree/.workbench/profile.conf"
  printf 'schema=workbench-policy/v1\naction.task.complete=allow\n' \
    > "$worktree/.workbench/policy.conf"
  mkdir -p "$worktree/task"
  cat > "$worktree/task/index.md" <<'EOF'
---
id: 77
issue: 77
home:
slug: linked-discovery
branch: task/77-linked-discovery
claim_id: claim-linked-77
task_contract: workbench-task/v2
---
EOF

  actual="$(run_workbench "$worktree" contract show --format json)"
  decoded="$(printf '%s\n' "$actual" | python3 -c \
    'import json, sys; print(json.load(sys.stdin)["workspace"]["root"])')" \
    || fail "contract output must remain RFC 8259 JSON for a special-character worktree path"
  assert_eq "$caller_root" "$decoded" "workspace.root must be the caller linked worktree"
  assert_contains "$actual" '"schema":"workbench/v2"' "linked worktree schema must be caller-owned"

  profile="$(run_workbench "$worktree" profile show --format json)"
  printf '%s\n' "$profile" | python3 -c 'import json, sys; json.load(sys.stdin)' \
    || fail "profile output must be RFC 8259 JSON"
  assert_contains "$profile" '"language":"en-US-u-ca-gregory"' \
    "profile must be read from the caller linked worktree"
}

test_policy_uses_canonical_authority_from_a_linked_worktree() {
  local repo worktree policy request revision intent
  repo="$(make_policy_task linked_policy allow)"
  worktree="$TMPDIR/linked policy"
  git -C "$repo" worktree add -q -b linked-policy "$worktree"
  printf 'schema=workbench-policy/v1\naction.task.complete=deny\n' > "$worktree/.workbench/policy.conf"
  revision="sha256:$(printf '1%.0s' {1..64})"
  request="$TMPDIR/linked-policy-request.json"
  write_completion_request "$request" "$revision"
  intent="$(intent_for_request "$request")"

  policy="$(run_workbench "$worktree" policy resolve --request-file "$request" \
    --intent-digest "$intent" --format json)"
  assert_contains "$policy" '"decision":"allow"' \
    "workspace policy must be read from protected default, not the caller worktree"
  printf '%s\n' "$policy" | python3 -c 'import json, sys; json.load(sys.stdin)' \
    || fail "policy provenance must remain RFC 8259 JSON for a special-character path"
}

test_contract_show_rejects_invalid_inputs_without_partial_json() {
  local repo out err outside rc
  local -a args
  repo="$(make_workspace invalid_schema workbench/v3)"
  out="$TMPDIR/invalid-schema.out"; err="$TMPDIR/invalid-schema.err"
  if run_workbench "$repo" contract show --format json >"$out" 2>"$err"; then
    fail "unsupported workspace schema must fail"
  else rc=$?; fi
  assert_eq 2 "$rc" "unsupported schema is malformed input"
  [ ! -s "$out" ] || fail "invalid schema must emit no partial JSON"

  repo="$(make_workspace invalid_marker workbench/v2)"
  printf 'workbench/v2\nextra\n' > "$repo/.workbench/schema"
  if run_workbench "$repo" contract show --format json >"$out" 2>"$err"; then
    fail "multi-line schema marker must fail"
  else rc=$?; fi
  assert_eq 2 "$rc" "multi-line schema marker is malformed input"
  [ ! -s "$out" ] || fail "malformed marker must emit no partial JSON"

  printf 'workbench/v2\n\nextra' > "$repo/.workbench/schema"
  if run_workbench "$repo" contract show --format json >"$out" 2>"$err"; then
    fail "schema marker with a blank second and third line must fail"
  else rc=$?; fi
  assert_eq 2 "$rc" "every physical line after the schema ID is invalid"
  [ ! -s "$out" ] || fail "three-line marker must emit no partial JSON"

  printf 'workbench/v2\n\n' > "$repo/.workbench/schema"
  for entrypoint in profile doctor legacy-inventory; do
    case "$entrypoint" in
      profile) args=(profile show --format json) ;;
      doctor) args=(doctor --format json) ;;
      legacy-inventory) args=(legacy-inventory show --format json) ;;
    esac
    if run_workbench "$repo" "${args[@]}" >"$out" 2>"$err"; then
      fail "$entrypoint accepted a schema marker with a trailing blank line"
    fi
    assert_file_contains "$err" "schema marker"
    [ ! -s "$out" ] || fail "$entrypoint schema failure emitted partial JSON"
  done

  repo="$(make_workspace invalid_format workbench/v2)"
  if run_workbench "$repo" contract show --format yaml >"$out" 2>"$err"; then
    fail "unsupported contract format must fail"
  else rc=$?; fi
  assert_eq 2 "$rc" "unsupported format is malformed input"
  [ ! -s "$out" ] || fail "unsupported format must emit no partial JSON"

  outside="$TMPDIR/outside"; mkdir -p "$outside"
  if (cd "$outside" && CLAUDE_PLUGIN_ROOT="$ROOT" "$WORKBENCH" contract show --format json) >"$out" 2>"$err"; then
    fail "contract discovery outside a workbench must fail"
  else rc=$?; fi
  assert_eq 1 "$rc" "outside-workbench discovery is a state failure"
  [ ! -s "$out" ] || fail "outside-workbench failure must emit no partial JSON"
}

make_policy_task() {
  local name="$1" complete_decision="${2:-}" repo origin descriptor_digest
  repo="$(make_workspace "$name" workbench/v2)"
  origin="$TMPDIR/$name-origin.git"
  git init -q --bare "$origin"
  printf 'schema=workbench-profile/v1\nlanguage=ko\n' > "$repo/.workbench/profile.conf"
  printf 'schema=workbench-policy/v1\n' > "$repo/.workbench/policy.conf"
  [ -z "$complete_decision" ] || printf 'action.task.complete=%s\n' "$complete_decision" \
    >> "$repo/.workbench/policy.conf"
  python3 - "$repo/.workbench/authority.json" "$origin" <<'PY'
import json
import sys

value = {
    "contract_version": "workbench-workspace-authority/v1",
    "authority_identity": "fixture:workspace/local",
    "origin_url": sys.argv[2],
    "default_ref": "refs/heads/main",
    "workspace_home": "workbench",
    "hosting_adapter": None,
    "hosting_ref": None,
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  descriptor_digest="sha256:$(python3 - "$repo/.workbench/authority.json" <<'PY'
import hashlib
import sys

print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)"
  mkdir -p "$repo/task"
  cat > "$repo/task/index.md" <<EOF
---
id: 42
issue: 42
home:
slug: policy-fixture
branch: task/42-policy-fixture
claim_id: claim-policy-42
task_contract: workbench-task/v2
workspace_authority_descriptor_digest: $descriptor_digest
---
EOF
  git -C "$repo" add .workbench task/index.md
  git -C "$repo" commit -q -m task
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q -u origin main
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  printf '%s\n' "$repo"
}

test_policy_requires_authenticated_hosting_authority() {
  local repo request revision intent before after adapter actual out err rc
  repo="$(make_policy_task authenticated_policy_authority allow)"
  revision="sha256:$(printf '8%.0s' {1..64})"
  request="$TMPDIR/authenticated-policy-request.json"
  write_completion_request "$request" "$revision"
  intent="$(intent_for_request "$request")"

  before="$(readonly_git_snapshot "$repo" | sed '/STATUS-BEGIN/,/STATUS-END/d')"
  actual="$(run_workbench "$repo" policy resolve --request-file "$request" \
    --intent-digest "$intent" --format json)"
  after="$(readonly_git_snapshot "$repo" | sed '/STATUS-BEGIN/,/STATUS-END/d')"
  assert_contains "$actual" '"decision":"allow"' \
    "authenticated protected-default proof must allow policy resolution"
  assert_eq "$before" "$after" \
    "policy authority observation must not write FETCH_HEAD, refs, or the index"

  out="$TMPDIR/policy-authority.out"; err="$TMPDIR/policy-authority.err"
  if WORKBENCH_TRUSTED_HOSTING_ADAPTER="$TMPDIR/missing-hosting-adapter" \
    run_workbench "$repo" policy resolve --request-file "$request" \
      --intent-digest "$intent" --format json >"$out" 2>"$err"; then
    fail "policy resolution without an executable trusted hosting adapter must fail"
  else rc=$?; fi
  assert_eq 1 "$rc" "unavailable trusted authority is an integrity failure"
  assert_file_contains "$err" "policy-authority-unavailable"
  [ ! -s "$out" ] || fail "unavailable authority must emit no policy JSON"

  adapter="$TMPDIR/unprotected-hosting-adapter"
  write_test_hosting_adapter "$adapter" false blocked
  if WORKBENCH_TRUSTED_HOSTING_ADAPTER="$adapter" run_workbench "$repo" policy resolve \
    --request-file "$request" --intent-digest "$intent" --format json >"$out" 2>"$err"; then
    fail "unprotected default ref must not authorize policy resolution"
  else rc=$?; fi
  assert_eq 1 "$rc" "unprotected authority is an integrity failure"
  assert_file_contains "$err" "policy-authority-mismatch"

  adapter="$TMPDIR/direct-writes-hosting-adapter"
  write_test_hosting_adapter "$adapter" true allowed
  if WORKBENCH_TRUSTED_HOSTING_ADAPTER="$adapter" run_workbench "$repo" policy resolve \
    --request-file "$request" --intent-digest "$intent" --format json >"$out" 2>"$err"; then
    fail "direct task-actor writes to the policy authority must block resolution"
  else rc=$?; fi
  assert_eq 1 "$rc" "direct task-actor write permission is an integrity failure"
  assert_file_contains "$err" "policy-authority-mismatch"

  adapter="$TMPDIR/mismatched-hosting-adapter"
  write_test_hosting_adapter "$adapter" true blocked fixture:workspace/other
  if WORKBENCH_TRUSTED_HOSTING_ADAPTER="$adapter" run_workbench "$repo" policy resolve \
    --request-file "$request" --intent-digest "$intent" --format json >"$out" 2>"$err"; then
    fail "hosting proof for another authority identity must fail"
  else rc=$?; fi
  assert_eq 1 "$rc" "mismatched authority proof is an integrity failure"
  assert_file_contains "$err" "policy-authority-mismatch"
}

test_policy_rejects_obsolete_scalar_public_bindings() {
  local repo out err rc
  repo="$(make_policy_task obsolete_policy_api allow)"
  out="$TMPDIR/obsolete-policy.out"; err="$TMPDIR/obsolete-policy.err"
  if run_workbench "$repo" policy resolve --action-id task.complete \
    --task-claim-id claim-policy-42 --target-ref workbench:task/claim-policy-42 \
    --revision "sha256:$(printf '7%.0s' {1..64})" --format json >"$out" 2>"$err"; then
    fail "public policy resolution must reject obsolete scalar bindings"
  else rc=$?; fi
  assert_eq 2 "$rc" "obsolete public policy bindings are malformed input"
  assert_file_contains "$err" "unknown option: --action-id"
  [ ! -s "$out" ] || fail "obsolete binding rejection must emit no JSON"
}

test_policy_defaults_to_ask_and_applies_lattice() {
  local repo actual platform rc initial_instance replacement_instance request revision intent
  repo="$(make_policy_task policy)"
  revision="sha256:$(printf 'a%.0s' {1..64})"
  request="$TMPDIR/policy-default-request.json"
  write_completion_request "$request" "$revision"
  intent="$(intent_for_request "$request")"
  if actual="$(run_workbench "$repo" policy resolve --request-file "$request" \
    --intent-digest "$intent" --format json)"; then
    fail "missing policy must resolve ask at exit 3"
  else rc=$?; fi
  assert_eq 3 "$rc" "ask must use exit 3"
  assert_contains "$actual" '"status":"pending"' "ask must persist a pending instance"
  assert_contains "$actual" '"decision":"ask"' "missing action must fail closed"
  assert_contains "$actual" '"authorization_ref":null' "pending resolution has no authorization"
  initial_instance="$(json_path "$actual" action_instance.id)"

  platform="$TMPDIR/platform.policy"
  printf 'schema=workbench-policy/v1\naction.task.complete=allow\n' > "$platform"
  printf 'schema=workbench-policy/v1\naction.task.complete=deny\n' > "$repo/.workbench/policy.conf"
  git -C "$repo" add .workbench/policy.conf
  git -C "$repo" commit -q -m "test: deny completion"
  git -C "$repo" push -q

  if actual="$(WORKBENCH_PLATFORM_POLICY="$platform" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/default \
    run_workbench "$repo" policy resolve --request-file "$request" \
    --intent-digest "$intent" --action-instance-id "$initial_instance" --format json)"; then
    fail "deny lattice must return exit 4"
  else rc=$?; fi
  assert_eq 4 "$rc" "deny must use exit 4"
  assert_contains "$actual" '"decision":"deny"' "deny must dominate ask and allow"
  assert_contains "$actual" '"status":"denied"' "denied action must be persisted"
  assert_contains "$actual" '"layer":"platform"' "platform source must be reported"
  assert_contains "$actual" '"layer":"workspace"' "workspace source must be reported"
  assert_contains "$actual" '"policy_digest":"sha256:' "policy digest must be reported"
  assert_contains "$actual" '"authority_identity":"fixture:workspace/local"' \
    "workspace authority provenance must be reported"
  replacement_instance="$(json_path "$actual" action_instance.id)"
  [ "$replacement_instance" != "$initial_instance" ] \
    || fail "changed protected-default policy must replace the pending action instance"
  assert_file_contains "$repo/task/.workbench/actions/$initial_instance.record" 'status=superseded'
}

test_policy_rejects_duplicate_context_sources() {
  local repo out err rc request revision
  repo="$(make_policy_task unsupported_action)"
  revision="sha256:$(printf 'b%.0s' {1..64})"
  request="$TMPDIR/unsupported-action-request.json"
  python3 - "$request" "$revision" <<'PY'
import json
import sys

value = {
    "contract_version": "workbench-action-request/v1",
    "action_id": "toolbox.deploy",
    "task_claim_id": "claim-policy-42",
    "target_ref": "toolbox:scenario/SCN-001",
    "revision": sys.argv[2],
    "payload_contract": "toolbox-deploy-intent/v1",
    "payload": "toolbox-deploy-intent/v1\n",
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  out="$TMPDIR/unsupported-action.out"; err="$TMPDIR/unsupported-action.err"
  if run_workbench "$repo" policy resolve --request-file "$request" \
    --intent-digest "sha256:$(printf 'c%.0s' {1..64})" --format json >"$out" 2>"$err"; then
    fail "namespaced pack action must not enter the kernel registry"
  else rc=$?; fi
  assert_eq 2 "$rc" "unsupported action is malformed input"
  [ ! -s "$out" ] || fail "unsupported action failure must emit no JSON"
  assert_file_contains "$err" "unsupported-action"
}

test_policy_authorization_resolves_ask_but_not_deny() {
  local repo actual instance manifest auth rc request revision intent
  repo="$(make_policy_task policy_authorization)"
  revision="sha256:$(printf 'd%.0s' {1..64})"
  request="$TMPDIR/policy-authorization-request.json"
  write_completion_request "$request" "$revision"
  intent="$(intent_for_request "$request")"

  if actual="$(run_workbench "$repo" policy resolve --request-file "$request" \
    --intent-digest "$intent" --format json)"; then
    fail "ask must mint pending instance"
  else rc=$?; fi
  assert_eq 3 "$rc" "pending instance exit"
  instance="$(json_string_field "$actual" id)"
  [ -n "$instance" ] || fail "pending policy object must expose action instance ID"
  manifest="$(json_path "$actual" action_instance.policy_manifest.digest)"

  auth="$TMPDIR/authorization.json"
  write_policy_authorization "$auth" "$instance" task.complete claim-policy-42 \
    workbench:task/claim-policy-42 "$revision" "$intent" "$manifest" conversation:message/msg-123
  actual="$(run_workbench "$repo" policy resolve --request-file "$request" \
    --intent-digest "$intent" --action-instance-id "$instance" \
    --authorization-file "$auth" --format json)"
  assert_contains "$actual" '"status":"authorized"' "matching authorization must authorize instance"
  assert_contains "$actual" '"decision":"allow"' "matching authorization resolves allow"
  assert_contains "$actual" '"authorization_ref":"conversation:message/msg-123"' "source_ref is the authorization reference"

  python3 - "$auth" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
value["intent_digest"] = "sha256:" + "e" * 64
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  if run_workbench "$repo" policy resolve --request-file "$request" \
    --intent-digest "$intent" --action-instance-id "$instance" \
    --authorization-file "$auth" --format json > "$TMPDIR/mismatch.out" 2> "$TMPDIR/mismatch.err"; then
    fail "authorization for another intent must not be accepted"
  else rc=$?; fi
  assert_eq 1 "$rc" "authorization intent mismatch must use exit 1"
  [ ! -s "$TMPDIR/mismatch.out" ] || fail "binding mismatch must emit no JSON"
}

test_policy_authorization_uses_strict_rfc8259_json() {
  local repo actual instance manifest auth decoded out err rc request revision intent
  repo="$(make_policy_task strict_authorization)"
  revision="sha256:$(printf 'f%.0s' {1..64})"
  request="$TMPDIR/strict-authorization-request.json"
  write_completion_request "$request" "$revision"
  intent="$(intent_for_request "$request")"
  if actual="$(run_workbench "$repo" policy resolve --request-file "$request" \
    --intent-digest "$intent" --format json)"; then
    fail "ask must mint a pending strict-JSON fixture"
  else rc=$?; fi
  assert_eq 3 "$rc" "strict-JSON fixture must start pending"
  instance="$(json_string_field "$actual" id)"
  manifest="$(json_path "$actual" action_instance.policy_manifest.digest)"

  auth="$TMPDIR/strict-authorization.json"
  python3 - "$auth" "$instance" "$revision" "$intent" "$manifest" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(
        {
            "contract_version": "workbench-authorization/v1",
            "authorization_id": "auth_strict_1",
            "action_instance_id": sys.argv[2],
            "action_id": "task.complete",
            "task_claim_id": "claim-policy-42",
            "target_ref": "workbench:task/claim-policy-42",
            "revision": sys.argv[3],
            "intent_digest": sys.argv[4],
            "policy_manifest_digest": sys.argv[5],
            "decision": "allow",
            "actor": "human@example.com",
            "authorized_at": "2026-07-11T03:01:00Z",
            "source_ref": 'conversation:message/msg-"quoted"\\tail',
        },
        handle,
    )
PY
  actual="$(run_workbench "$repo" policy resolve --request-file "$request" \
    --intent-digest "$intent" --action-instance-id "$instance" \
    --authorization-file "$auth" --format json)"
  decoded="$(printf '%s\n' "$actual" | python3 -c \
    'import json, sys; print(json.load(sys.stdin)["authorization_ref"])')"
  assert_eq 'conversation:message/msg-"quoted"\tail' "$decoded" \
    "escaped authorization strings must be decoded and re-serialized"

  repo="$(make_policy_task duplicate_authorization)"
  revision="sha256:$(printf '9%.0s' {1..64})"
  request="$TMPDIR/duplicate-authorization-request.json"
  write_completion_request "$request" "$revision"
  intent="$(intent_for_request "$request")"
  if actual="$(run_workbench "$repo" policy resolve --request-file "$request" \
    --intent-digest "$intent" --format json)"; then
    fail "duplicate-key fixture must start pending"
  else rc=$?; fi
  instance="$(json_string_field "$actual" id)"
  manifest="$(json_path "$actual" action_instance.policy_manifest.digest)"
  cat > "$auth" <<EOF
{"contract_version":"workbench-authorization/v1","authorization_id":"auth_duplicate_1","action_instance_id":"$instance","action_id":"task.complete","task_claim_id":"claim-policy-42","target_ref":"workbench:task/claim-policy-42","revision":"$revision","intent_digest":"$intent","policy_manifest_digest":"$manifest","decision":"allow","actor":"first@example.com","actor":"second@example.com","authorized_at":"2026-07-11T03:01:00Z","source_ref":"conversation:message/msg-duplicate"}
EOF
  out="$TMPDIR/duplicate-authorization.out"; err="$TMPDIR/duplicate-authorization.err"
  if run_workbench "$repo" policy resolve --request-file "$request" \
    --intent-digest "$intent" --action-instance-id "$instance" \
    --authorization-file "$auth" --format json >"$out" 2>"$err"; then
    fail "duplicate authorization members must fail"
  else rc=$?; fi
  assert_eq 2 "$rc" "duplicate JSON members are malformed input"
  [ ! -s "$out" ] || fail "duplicate authorization failure must emit no JSON"
}

test_profile_show_is_structured_and_does_not_infer_prose() {
  local repo actual out err rc
  repo="$(make_workspace profile_unavailable)"
  printf 'persona.language: ko\n' > "$repo/AGENTS.md"
  actual="$(run_workbench "$repo" profile show --format json)"
  assert_eq '{"contract_version":"workbench-profile/v1","language":null,"source":"unavailable"}' "$actual" \
    "profile discovery must not infer language from AGENTS prose"

  repo="$(make_workspace profile_workspace workbench/v2)"
  printf 'schema=workbench-profile/v1\nlanguage=ko\n' > "$repo/.workbench/profile.conf"
  actual="$(run_workbench "$repo" profile show --format json)"
  assert_eq '{"contract_version":"workbench-profile/v1","language":"ko","source":"workspace"}' "$actual" \
    "tracked profile language must be returned"

  printf 'schema=workbench-profile/v1\nlanguage=i-klingon\n' > "$repo/.workbench/profile.conf"
  actual="$(run_workbench "$repo" profile show --format json)"
  assert_contains "$actual" '"language":"i-klingon"' "grandfathered BCP 47 tags must be accepted"

  printf 'schema=workbench-profile/v1\nlanguage=en-u-ca-gregory-u-nu-latn\n' \
    > "$repo/.workbench/profile.conf"
  out="$TMPDIR/profile-invalid.out"; err="$TMPDIR/profile-invalid.err"
  if run_workbench "$repo" profile show --format json >"$out" 2>"$err"; then
    fail "duplicate BCP 47 extension singletons must fail"
  else rc=$?; fi
  assert_eq 1 "$rc" "invalid v2 profile content fails closed as workspace state"

  printf 'workbench/v2\n\nextra' > "$repo/.workbench/schema"
  if run_workbench "$repo" profile show --format json >"$out" 2>"$err"; then
    fail "profile discovery must reject a three-line schema marker"
  else rc=$?; fi
  assert_eq 2 "$rc" "profile schema reader counts all physical lines"
  printf 'workbench/v2\n' > "$repo/.workbench/schema"

  printf 'schema=workbench-profile/v1\nlanguage=ko\nlanguage=en\n' > "$repo/.workbench/profile.conf"
  if run_workbench "$repo" profile show --format json >"$out" 2>"$err"; then
    fail "duplicate profile keys must fail"
  else rc=$?; fi
  assert_eq 1 "$rc" "invalid v2 profile content fails closed as workspace state"
  [ ! -s "$out" ] || fail "invalid profile must emit no partial JSON"

  if run_workbench "$repo" profile show --format >"$out" 2>"$err"; then
    fail "missing profile format value must fail"
  else rc=$?; fi
  assert_eq 2 "$rc" "missing profile format value is malformed input"
  [ ! -s "$out" ] || fail "missing format failure must emit no partial JSON"
}

test_v2_profile_is_required_and_python_dependency_fails_clearly() {
  local repo out err rc shim
  repo="$(make_workspace profile_required workbench/v2)"
  out="$TMPDIR/profile-required.out"; err="$TMPDIR/profile-required.err"
  if run_workbench "$repo" profile show --format json >"$out" 2>"$err"; then
    fail "v2 profile discovery without profile.conf must fail closed"
  else rc=$?; fi
  assert_eq 1 "$rc" "missing v2 profile is a state failure"
  [ ! -s "$out" ] || fail "missing v2 profile must emit no JSON"

  if run_workbench "$repo" contract show --format json >"$out" 2>"$err"; then
    fail "v2 contract discovery without profile.conf must fail closed"
  else rc=$?; fi
  assert_eq 1 "$rc" "contract discovery propagates missing v2 profile"
  [ ! -s "$out" ] || fail "missing v2 profile contract must emit no JSON"

  printf 'schema=workbench-profile/v1\nlanguage=ko\n' > "$repo/.workbench/profile.conf"
  shim="$TMPDIR/python-shim"; mkdir -p "$shim"
  cat > "$shim/python3" <<'EOF'
#!/bin/sh
exit 127
EOF
  chmod +x "$shim/python3"
  if (cd "$repo" && PATH="$shim:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT" \
    "$WORKBENCH" contract show --format json) >"$out" 2>"$err"; then
    fail "v2 contract discovery without Python 3.9 must fail"
  else rc=$?; fi
  assert_eq 1 "$rc" "missing Python is a runtime state failure"
  assert_file_contains "$err" "Python 3.9 or newer is required"
  [ ! -s "$out" ] || fail "missing Python must emit no partial JSON"
}

run_case() {
  local name="$1"
  [ -z "${WORKBENCH_TEST_FILTER:-}" ] || [ "$WORKBENCH_TEST_FILTER" = "$name" ] || return 0
  "$name"
}

run_case test_contract_show_exact_v2_json
run_case test_fixture_reuse_fails_before_git_mutation
run_case test_contract_show_reads_implicit_v1
run_case test_contract_show_advertises_the_frozen_g0_surface
run_case test_public_engine_manifest_is_complete_and_canonical
run_case test_engine_manifest_rejects_links_and_path_swap
run_case test_workspace_authority_descriptor_binds_workspace_home
run_case test_action_request_binds_the_exact_effect_intent
run_case test_applied_effect_reducer_recovers_without_reauthorization
run_case test_github_probe_separates_stable_subject_from_observation
run_case test_writer_ledger_reduces_effect_owner_before_claim_release
run_case test_writer_operation_uses_the_exact_recovery_cursor_schema
run_case test_cleanup_journal_binds_the_exact_removal_plan_prefix
run_case test_closed_legacy_home_set_binds_registry_origins
run_case test_public_legacy_inventory_is_exhaustive_and_repo_independent
run_case test_bootstrap_legacy_inventory_uses_only_authenticated_approval
run_case test_legacy_inventory_entrypoints_are_schema_scoped
run_case test_doctor_is_read_only_and_reports_exact_readiness
run_case test_policy_resolution_and_authorization_bind_intent_digest
run_case test_discovery_uses_the_caller_linked_worktree_and_emits_valid_json
run_case test_policy_uses_canonical_authority_from_a_linked_worktree
run_case test_contract_show_rejects_invalid_inputs_without_partial_json
run_case test_policy_requires_authenticated_hosting_authority
run_case test_policy_rejects_obsolete_scalar_public_bindings
run_case test_policy_defaults_to_ask_and_applies_lattice
run_case test_policy_authorization_resolves_ask_but_not_deny
run_case test_policy_authorization_uses_strict_rfc8259_json
run_case test_policy_rejects_duplicate_context_sources
run_case test_profile_show_is_structured_and_does_not_infer_prose
run_case test_v2_profile_is_required_and_python_dependency_fails_clearly
assert_source_repo_unchanged

echo "PASS workbench contract and policy tests"
