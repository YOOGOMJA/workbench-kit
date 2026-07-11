#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_REPO="$(git -C "$PLUGIN_ROOT" rev-parse --show-toplevel)"
SOURCE_HEAD="$(git -C "$SOURCE_REPO" rev-parse HEAD)"
SOURCE_STATUS="$(git -C "$SOURCE_REPO" status --porcelain=v1)"
TASK_UTIL="$PLUGIN_ROOT/utils/task"
POLICY_UTIL="$PLUGIN_ROOT/utils/policy"
CONTRACT_HELPER="$PLUGIN_ROOT/lib/workbench_contract.py"
INTENT_HELPER="$PLUGIN_ROOT/lib/workbench_intent.py"
EFFECT_HELPER="$PLUGIN_ROOT/lib/workbench_effect.py"
WRITER_HELPER="$PLUGIN_ROOT/lib/workbench_writer.py"
TERMINAL_HELPER="$PLUGIN_ROOT/lib/workbench_terminal.py"
CLEANUP_HELPER="$PLUGIN_ROOT/lib/workbench_cleanup.py"
LEGACY_HELPER="$PLUGIN_ROOT/lib/workbench_legacy.py"
LEGACY_UTIL="$PLUGIN_ROOT/utils/legacy-inventory"
SCAFFOLD_TEMPLATES="$(cd "$PLUGIN_ROOT/../workbench-kit/scaffold/templates" && pwd)"
TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/workbench-task-v2.XXXXXX")"
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

assert_file_contains() {
  local file="$1" expected="$2"
  [ -f "$file" ] || fail "missing file: $file"
  grep -Fq -- "$expected" "$file" || fail "expected '$expected' in $file; got: $(cat "$file")"
}

assert_contains() {
  local value="$1" expected="$2"
  printf '%s' "$value" | grep -Fq -- "$expected" || fail "expected '$expected' in '$value'"
}

json_string_field() {
  local json="$1" key="$2"
  printf '%s\n' "$json" | sed -n "s/.*\"$key\":\"\([^\"]*\)\".*/\1/p" | head -1
}

json_get() {
  local json="$1" path="$2"
  printf '%s\n' "$json" | python3 -c '
import json
import sys

value = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    value = value[int(part)] if isinstance(value, list) else value[part]
if value is None:
    print("")
elif isinstance(value, bool):
    print(str(value).lower())
else:
    print(value)
' "$path"
}

write_authorization() {
  local file="$1" instance="$2" action="$3" claim="$4" target="$5" revision="$6"
  local manifest_digest="$7" decision="$8" actor="$9" authorized_at="${10}" source_ref="${11}"
  local intent_digest="${12:-}"
  python3 - "$file" "$instance" "$action" "$claim" "$target" "$revision" \
    "$manifest_digest" "$decision" "$actor" "$authorized_at" "$source_ref" "$intent_digest" <<'PY'
import json
import sys

keys = (
    "action_instance_id", "action_id", "task_claim_id", "target_ref", "revision",
    "policy_manifest_digest", "decision", "actor", "authorized_at", "source_ref", "intent_digest",
)
values = dict(zip(keys, sys.argv[2:]))
value = {
    "contract_version": "workbench-authorization/v1",
    "authorization_id": "auth_{}".format(values["action_instance_id"]),
    "action_instance_id": values["action_instance_id"],
    "action_id": values["action_id"],
    "task_claim_id": values["task_claim_id"],
    "target_ref": values["target_ref"],
    "revision": values["revision"],
}
if values["intent_digest"]:
    value["intent_digest"] = values["intent_digest"]
value.update({
    "policy_manifest_digest": values["policy_manifest_digest"],
    "decision": values["decision"],
    "actor": values["actor"],
    "authorized_at": values["authorized_at"],
    "source_ref": values["source_ref"],
})
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
}

write_fake_gh() {
  local bin_dir="$1"
  cat > "$bin_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$PWD" "$*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
  "issue view")
    issue="$3"; shift 3
    case "$*" in
      *"--json title"*) printf '%s\n' "v2 lifecycle fixture $issue" ;;
      *"--json body"*) printf '%s\n' "fixture body" ;;
      *"--json comments"*) cat "$GH_COMMENTS_DIR/$issue.comments" 2>/dev/null || true ;;
      *) echo "unexpected issue view args: $*" >&2; exit 9 ;;
    esac
    ;;
  "issue comment")
    issue="$3"; shift 3
    body_file=""
    while [ "$#" -gt 0 ]; do
      case "$1" in --body-file) body_file="$2"; shift 2 ;; *) shift ;; esac
    done
    mkdir -p "$GH_COMMENTS_DIR"
    if [ "${GH_FAIL_CLEANUP_STAGE:-}" = prepared ] \
      && grep -Fq '"stage":"prepared"' "$body_file"; then
      exit 41
    fi
    if [ "${GH_FAIL_CLEANUP_STAGE:-}" = completed ] \
      && grep -Fq '"stage":"completed"' "$body_file"; then
      exit 42
    fi
    if [ "${GH_FAIL_LIFECYCLE_EVENT:-}" = task-cleaned ] \
      && grep -Fq '"event":"task-cleaned"' "$body_file"; then
      exit 43
    fi
    cat "$body_file" >> "$GH_COMMENTS_DIR/$issue.comments"
    printf '\n' >> "$GH_COMMENTS_DIR/$issue.comments"
    ;;
  "pr view")
    printf '%s\t%s\t%s\n' "${GH_PR_STATE:-MERGED}" "${GH_PR_HEAD:-abc123}" "${GH_PR_MERGE:-merge789}"
    ;;
  "pr list") printf '\n' ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
EOF
  chmod +x "$bin_dir/gh"
}

write_fake_hosting_authority() {
  local file="$1"
  cat > "$file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = authority ] || exit 2
shift
authority="" revision=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --authority-file) authority="$2"; shift 2 ;;
    --default-revision) revision="$2"; shift 2 ;;
    --format) [ "$2" = json ]; shift 2 ;;
    *) exit 2 ;;
  esac
done
python3 - "$authority" "$revision" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    authority = json.load(handle)
value = {
    "contract_version": "workbench-hosting-authority-verification/v1",
    "authority_identity": authority["authority_identity"],
    "origin_url": authority["origin_url"],
    "default_ref": authority["default_ref"],
    "default_revision": sys.argv[2],
    "default_ref_protected": True,
    "direct_task_actor_writes": "blocked",
    "permission_source": authority["hosting_ref"] or "fixture:repository/local",
}
print(json.dumps(value, separators=(",", ":")))
PY
EOF
  chmod +x "$file"
}

write_fake_legacy_adapter() {
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

write_fake_empty_legacy_adapter() {
  local file="$1"
  cat > "$file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = collect ] || exit 2
shift
authority="" registry="" revision=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --authority-file) authority="$2"; shift 2 ;;
    --registry-file) registry="$2"; shift 2 ;;
    --default-revision) revision="$2"; shift 2 ;;
    --workspace-origin|--default-ref|--bootstrap-revision) shift 2 ;;
    --format) [ "${2:-}" = json ]; shift 2 ;;
    *) exit 2 ;;
  esac
done
python3 - "$authority" "$registry" "$revision" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    authority = json.load(handle)
rows = [(authority["workspace_home"], authority["origin_url"])]
for raw in open(sys.argv[2], encoding="utf-8"):
    line = raw.rstrip("\n")
    if not line or line.startswith("#"):
        continue
    home, origin = line.split(": ", 1)
    rows.append((home, origin))
pagination = {"complete": True, "pages_fetched": 1, "end_cursor": None, "failure": None}
value = {
    "contract_version": "workbench-legacy-observation/v1",
    "source_revision": sys.argv[3],
    "homes": [
        {
            "home": home,
            "origin_url": origin,
            "membership": "current",
            "pagination": pagination,
            "claims": [],
        }
        for home, origin in sorted(rows)
    ],
    "origin_replacements": [],
    "blockers": [],
}
print(json.dumps(value, separators=(",", ":")))
PY
EOF
  chmod +x "$file"
}

setup_workbench() {
  local name="$1" schema="${2-workbench/v2}"
  local repo="$TMPDIR/$name/repo" origin="$TMPDIR/$name/origin.git"
  local fake_bin="$TMPDIR/$name/bin" comments="$TMPDIR/$name/comments" home="$TMPDIR/$name/home"
  if [ -e "$repo" ]; then echo "fixture workspace already exists: $repo" >&2; return 1; fi
  mkdir -p "$repo" "$fake_bin" "$comments" "$home"
  git init -q --bare "$origin"
  git init -q -b main "$repo"
  mkdir -p "$repo/utils" "$repo/lib" "$repo/templates"
  cp "$TASK_UTIL" "$repo/utils/task"
  chmod +x "$repo/utils/task"
  if [ -f "$POLICY_UTIL" ]; then cp "$POLICY_UTIL" "$repo/utils/policy"; chmod +x "$repo/utils/policy"; fi
  cp "$CONTRACT_HELPER" "$repo/lib/workbench_contract.py"
  cp "$INTENT_HELPER" "$repo/lib/workbench_intent.py"
  cp "$EFFECT_HELPER" "$repo/lib/workbench_effect.py"
  cp "$WRITER_HELPER" "$repo/lib/workbench_writer.py"
  cp "$TERMINAL_HELPER" "$repo/lib/workbench_terminal.py"
  cp "$CLEANUP_HELPER" "$repo/lib/workbench_cleanup.py"
  cp "$LEGACY_HELPER" "$repo/lib/workbench_legacy.py"
  cp "$LEGACY_UTIL" "$repo/utils/legacy-inventory"
  chmod +x "$repo/utils/legacy-inventory"
  cp "$SCAFFOLD_TEMPLATES/task-AGENTS.md" "$repo/templates/task-AGENTS.md"
  if [ -n "$schema" ]; then
    mkdir -p "$repo/.workbench"
    printf '%s\n' "$schema" > "$repo/.workbench/schema"
  fi
  if [ "$schema" = workbench/v2 ]; then
    printf '%s\n' 'schema=workbench-profile/v1' 'language=ko' > "$repo/.workbench/profile.conf"
    printf '%s\n' 'schema=workbench-policy/v1' > "$repo/.workbench/policy.conf"
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
    printf '%s\n' '# no registered codebases' > "$repo/codebases.yaml"
  fi
  git -C "$repo" config user.name "Test User"
  git -C "$repo" config user.email "test@example.invalid"
  git -C "$repo" add .
  git -C "$repo" commit -q -m init >/dev/null
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q -u origin main
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  : > "$TMPDIR/$name/gh.log"
  write_fake_gh "$fake_bin"
  write_fake_hosting_authority "$fake_bin/hosting-authority"
  write_fake_empty_legacy_adapter "$fake_bin/legacy-adapter"
  printf '%s\n' "$repo"
}

run_task_in_dir() {
  local case_name="$1" dir="$2"; shift 2
  GH_LOG="$TMPDIR/$case_name/gh.log" \
  GH_COMMENTS_DIR="$TMPDIR/$case_name/comments" \
  HOME="$TMPDIR/$case_name/home" \
  PATH="$TMPDIR/$case_name/bin:$PATH" \
  WORKBENCH_PLATFORM_POLICY="${WORKBENCH_PLATFORM_POLICY:-}" \
  WORKBENCH_PLATFORM_POLICY_REF="${WORKBENCH_PLATFORM_POLICY_REF:-}" \
    WORKBENCH_TRUSTED_HOSTING_ADAPTER="$TMPDIR/$case_name/bin/hosting-authority" \
    WORKBENCH_TRUSTED_LEGACY_ADAPTER="${WORKBENCH_TRUSTED_LEGACY_ADAPTER:-$TMPDIR/$case_name/bin/legacy-adapter}" \
    WORKBENCH_TEST_FAIL_AFTER_ACCEPTANCE_PRIMARY="${WORKBENCH_TEST_FAIL_AFTER_ACCEPTANCE_PRIMARY:-0}" \
    WORKBENCH_TEST_FAIL_AFTER_CONTEXT_PRIMARY="${WORKBENCH_TEST_FAIL_AFTER_CONTEXT_PRIMARY:-}" \
    WORKBENCH_TEST_FAIL_AFTER_WRITER_CLAIM="${WORKBENCH_TEST_FAIL_AFTER_WRITER_CLAIM:-0}" \
    GH_PR_STATE="${GH_PR_STATE:-}" GH_PR_HEAD="${GH_PR_HEAD:-}" GH_PR_MERGE="${GH_PR_MERGE:-}" \
    WRITER_BARRIER_ID="${WRITER_BARRIER_ID:-}" \
    bash -c 'dir="$1"; shift; cd "$dir"; "$dir/utils/task" "$@"' bash "$dir" "$@"
}

run_policy_in_dir() {
  local case_name="$1" dir="$2"; shift 2
  GH_LOG="$TMPDIR/$case_name/gh.log" \
  GH_COMMENTS_DIR="$TMPDIR/$case_name/comments" \
  HOME="$TMPDIR/$case_name/home" \
  PATH="$TMPDIR/$case_name/bin:$PATH" \
  WORKBENCH_PLATFORM_POLICY="${WORKBENCH_PLATFORM_POLICY:-}" \
  WORKBENCH_PLATFORM_POLICY_REF="${WORKBENCH_PLATFORM_POLICY_REF:-}" \
    WORKBENCH_TRUSTED_HOSTING_ADAPTER="$TMPDIR/$case_name/bin/hosting-authority" \
    WORKBENCH_TRUSTED_LEGACY_ADAPTER="${WORKBENCH_TRUSTED_LEGACY_ADAPTER:-$TMPDIR/$case_name/bin/legacy-adapter}" \
    bash -c 'dir="$1"; shift; cd "$dir"; "$dir/utils/policy" "$@"' bash "$dir" "$@"
}

run_task() {
  local case_name="$1" repo="$2"; shift 2
  run_task_in_dir "$case_name" "$repo" "$@"
}

task_dir_for() {
  local repo="$1" issue="${2:-29}"
  printf '%s/.worktrees/task__%s-v2-lifecycle-fixture-%s\n' "$repo" "$issue" "$issue"
}

start_task() {
  local case_name="$1" repo="$2" issue="${3:-29}" schema output
  schema="$(cat "$repo/.workbench/schema" 2>/dev/null || true)"
  if [ "$schema" = workbench/v2 ]; then
    output="$TMPDIR/$case_name/start-$issue.json"
    run_task "$case_name" "$repo" start "$issue" "v2-lifecycle-fixture-$issue" --format json > "$output"
    assert_file_contains "$output" '"contract_version":"workbench-task-start/v2"'
  else
    run_task "$case_name" "$repo" start "$issue" "v2-lifecycle-fixture-$issue" >&2
  fi
  printf '%s/.worktrees/task__%s-v2-lifecycle-fixture-%s\n' "$repo" "$issue" "$issue"
}

append_repo_fact() {
  local task_dir="$1" line="$2" file
  file="$task_dir/task/index.md"
  awk -v line="$line" '/<!-- repos:end -->/ { print line } { print }' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

prepare_cleanup_fixture() {
  local case_name="$1" cleanup_payload cleanup_request parsed
  CLEANUP_REPO="$(setup_workbench "$case_name")"
  printf '%s\n' 'schema=workbench-policy/v1' 'action.task.abandon=allow' 'action.task.cleanup=allow' \
    > "$CLEANUP_REPO/.workbench/policy.conf"
  git -C "$CLEANUP_REPO" add .workbench/policy.conf
  git -C "$CLEANUP_REPO" commit -q -m "test: allow cleanup"
  git -C "$CLEANUP_REPO" push -q
  CLEANUP_TASK_DIR="$(start_task "$case_name" "$CLEANUP_REPO")"
  CLEANUP_CLAIM="$(sed -n 's/^claim_id: *//p' "$CLEANUP_TASK_DIR/task/index.md")"
  CLEANUP_PLATFORM_POLICY="$TMPDIR/$case_name/platform.policy"
  printf '%s\n' 'schema=workbench-policy/v1' 'action.task.abandon=allow' 'action.task.cleanup=allow' \
    > "$CLEANUP_PLATFORM_POLICY"
  run_task_in_dir "$case_name" "$CLEANUP_TASK_DIR" policy-context seal --format json >/dev/null
  WORKBENCH_PLATFORM_POLICY="$CLEANUP_PLATFORM_POLICY" \
  WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/cleanup \
    run_task_in_dir "$case_name" "$CLEANUP_TASK_DIR" abandon \
      --reason-code superseded --reason-ref issue:55 --format json >/dev/null
  CLEANUP_REVISION="$(sed -n 's/^revision=//p' "$CLEANUP_TASK_DIR/task/.workbench/terminal")"
  CLEANUP_REMOVAL_PLAN_DIGEST="$(sed -n 's/^removal_plan_digest=//p' \
    "$CLEANUP_TASK_DIR/task/.workbench/terminal")"
  cleanup_payload="$TMPDIR/$case_name/cleanup-payload.txt"
  cleanup_request="$TMPDIR/$case_name/cleanup-request.json"
  python3 "$INTENT_HELPER" build-payload --contract workbench-task-cleanup-intent/v1 \
    --field "terminal_revision=$CLEANUP_REVISION" \
    --field "removal_plan_digest=$CLEANUP_REMOVAL_PLAN_DIGEST" > "$cleanup_payload"
  python3 "$INTENT_HELPER" build-request --action-id task.cleanup \
    --task-claim-id "$CLEANUP_CLAIM" --target-ref "workbench:task/$CLEANUP_CLAIM" \
    --revision "$CLEANUP_REVISION" --payload-contract workbench-task-cleanup-intent/v1 \
    --payload-file "$cleanup_payload" > "$cleanup_request"
  parsed="$(python3 "$INTENT_HELPER" request "$cleanup_request" --format shell)"
  CLEANUP_INTENT_DIGEST="$(printf '%s\n' "$parsed" | sed -n 's/^intent_digest=//p')"
  CLEANUP_POLICY_OUTPUT="$TMPDIR/$case_name/cleanup-policy.json"
  WORKBENCH_PLATFORM_POLICY="$CLEANUP_PLATFORM_POLICY" \
  WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/cleanup \
    run_policy_in_dir "$case_name" "$CLEANUP_TASK_DIR" resolve \
      --request-file "$cleanup_request" --intent-digest "$CLEANUP_INTENT_DIGEST" \
      --format json > "$CLEANUP_POLICY_OUTPUT"
  CLEANUP_ACTION_INSTANCE="$(json_get "$(cat "$CLEANUP_POLICY_OUTPUT")" action_instance.id)"
  git -C "$CLEANUP_TASK_DIR" add .workbench task/.workbench
  git -C "$CLEANUP_TASK_DIR" commit -q -m "test: persist cleanup fixture"
  git -C "$CLEANUP_TASK_DIR" push -q
}

prepare_governed_fixture() {
  local case_name="$1"
  GOVERNED_REPO="$(setup_workbench "$case_name")"
  {
    printf '%s\n' 'schema=workbench-policy/v1'
    printf '%s\n' 'action.task.deliverable.weaken=ask'
    printf '%s\n' 'action.task.deliverable.waive=ask'
    printf '%s\n' 'action.task.deliverable.reject=ask'
    printf '%s\n' 'action.task.required-check.waive=ask'
  } > "$GOVERNED_REPO/.workbench/policy.conf"
  printf '%s\n' 'reporting: https://github.com/example/reporting.git' > "$GOVERNED_REPO/codebases.yaml"
  git -C "$GOVERNED_REPO" add .workbench/policy.conf codebases.yaml
  git -C "$GOVERNED_REPO" commit -q -m "test: require governed authorization"
  git -C "$GOVERNED_REPO" push -q
  GOVERNED_TASK_DIR="$(start_task "$case_name" "$GOVERNED_REPO")"
  GOVERNED_CLAIM="$(sed -n 's/^claim_id: *//p' "$GOVERNED_TASK_DIR/task/index.md")"
  GOVERNED_PLATFORM_POLICY="$TMPDIR/$case_name/platform.policy"
  cp "$GOVERNED_REPO/.workbench/policy.conf" "$GOVERNED_PLATFORM_POLICY"
  run_task_in_dir "$case_name" "$GOVERNED_TASK_DIR" policy-context seal --format json >/dev/null
}

prepare_pack_fixture() {
  local case_name="$1" registration pending instance target revision intent manifest auth policy_digest
  PACK_REPO="$(setup_workbench "$case_name")"
  printf '%s\n' \
    'schema=workbench-policy/v1' \
    'action.task.policy-context.register=allow' \
    'action.task.policy-context.seal=allow' \
    'action.task.deliverable.accept=allow' > "$PACK_REPO/.workbench/policy.conf"
  git -C "$PACK_REPO" add .workbench/policy.conf
  git -C "$PACK_REPO" commit -q -m "test: allow pack owner lifecycle"
  git -C "$PACK_REPO" push -q
  PACK_TASK_DIR="$(start_task "$case_name" "$PACK_REPO")"
  PACK_CLAIM="$(sed -n 's/^claim_id: *//p' "$PACK_TASK_DIR/task/index.md")"
  run_task_in_dir "$case_name" "$PACK_TASK_DIR" refs set \
    --context-ref toolbox:product/acme --format json >/dev/null
  mkdir -p "$PACK_TASK_DIR/contexts"
  printf '%s\n' \
    'schema=workbench-policy/v1' \
    'action.task.policy-context.seal=allow' \
    'action.task.deliverable.accept=allow' > "$PACK_TASK_DIR/contexts/acme.policy"
  policy_digest="sha256:$(python3 - "$PACK_TASK_DIR/contexts/acme.policy" <<'PY'
import hashlib
import sys

print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)"
  registration="$TMPDIR/$case_name/registration.json"
  python3 - "$registration" "$PACK_CLAIM" "$policy_digest" <<'PY'
import json
import sys

receipt = {
    "contract_version": "workbench-policy-authority-receipt/v1",
    "authority_identity": "toolbox:authority/product-owner",
    "authority_ref": "toolbox:policy/acme",
    "authority_revision": "sha256:" + "a" * 64,
    "policy_ref": "contexts/acme.policy",
    "policy_digest": sys.argv[3],
    "actor": "owner@example.com",
    "issued_at": "2026-07-11T05:00:00Z",
    "source_ref": "toolbox:approval/policy-acme-v1",
}
value = {
    "contract_version": "workbench-context-policy-registration/v1",
    "registration_id": "ctxreg-pack-acme",
    "task_claim_id": sys.argv[2],
    "task_context_ref": "toolbox:product/acme",
    "participants": [{
        "context_ref": "toolbox:product/acme",
        "policy_ref": "contexts/acme.policy",
        "policy_digest": sys.argv[3],
        "authority_ref": "toolbox:policy/acme",
        "authority_receipt": receipt,
    }],
    "task_policy": None,
    "actor": "owner@example.com",
    "registered_at": "2026-07-11T05:01:00Z",
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  if run_task_in_dir "$case_name" "$PACK_TASK_DIR" policy-context register \
    --registration-file "$registration" --format json > "$TMPDIR/$case_name/register.out"; then
    fail "pack registration must require owner authorization"
  fi
  pending="$(cat "$TMPDIR/$case_name/register.out")"
  instance="$(json_get "$pending" action_instance.id)"; target="$(json_get "$pending" action_instance.target_ref)"
  revision="$(json_get "$pending" action_instance.revision)"
  intent="$(json_get "$pending" action_instance.intent_digest)"
  manifest="$(json_get "$pending" action_instance.policy_manifest.digest)"
  auth="$TMPDIR/$case_name/register-auth.json"
  write_authorization "$auth" "$instance" task.policy-context.register "$PACK_CLAIM" "$target" \
    "$revision" "$manifest" allow owner@example.com 2026-07-11T05:01:00Z \
    conversation:message/register-pack "$intent"
  run_task_in_dir "$case_name" "$PACK_TASK_DIR" policy-context register \
    --registration-file "$registration" --action-instance-id "$instance" \
    --authorization-file "$auth" --format json >/dev/null
  run_task_in_dir "$case_name" "$PACK_TASK_DIR" policy-context seal --format json >/dev/null
}

setup_writer_workbench() {
  local case_name="$1" name="${2:-shared-api}" cache origin
  WRITER_REPO="$(setup_workbench "$case_name")"
  WRITER_PLATFORM_POLICY="$TMPDIR/$case_name/platform.policy"
  {
    printf '%s\n' 'schema=workbench-policy/v1'
    printf '%s\n' 'action.task.concurrent-write=allow'
    printf '%s\n' 'action.task.cleanup=allow'
  } > "$WRITER_PLATFORM_POLICY"
  cp "$WRITER_PLATFORM_POLICY" "$WRITER_REPO/.workbench/policy.conf"
  printf '%s\n' '.codebases/' 'task/codebases/' > "$WRITER_REPO/.gitignore"
  printf '%s: %s\n' "$name" "$TMPDIR/$case_name/$name.git" > "$WRITER_REPO/codebases.yaml"
  git -C "$WRITER_REPO" add .workbench/policy.conf .gitignore codebases.yaml
  git -C "$WRITER_REPO" commit -q -m "test: register writer codebase"
  git -C "$WRITER_REPO" push -q

  cache="$WRITER_REPO/.codebases/$name"; origin="$TMPDIR/$case_name/$name.git"
  mkdir -p "$WRITER_REPO/.codebases"
  git init -q --bare "$origin"
  git init -q -b main "$cache"
  git -C "$cache" config user.name "Test User"
  git -C "$cache" config user.email "test@example.invalid"
  printf '%s\n' "$name" > "$cache/README.md"
  git -C "$cache" add README.md
  git -C "$cache" commit -q -m init
  git -C "$cache" remote add origin "$origin"
  git -C "$cache" push -q -u origin main
}

prepare_writer_task() {
  local case_name="$1" issue="$2"
  WRITER_TASK_DIR="$(start_task "$case_name" "$WRITER_REPO" "$issue")"
  run_task_in_dir "$case_name" "$WRITER_TASK_DIR" policy-context seal --format json >/dev/null
  git -C "$WRITER_TASK_DIR" add task/.workbench
  git -C "$WRITER_TASK_DIR" commit -q -m "test: seal writer policy context"
  git -C "$WRITER_TASK_DIR" push -q
}

write_empty_legacy_observation() {
  local output="$1" revision="$2" workspace_origin="$3" home="$4" home_origin="$5"
  python3 - "$output" "$revision" "$workspace_origin" "$home" "$home_origin" <<'PY'
import json
import sys

pagination = {"complete": True, "pages_fetched": 1, "end_cursor": None, "failure": None}
value = {
    "contract_version": "workbench-legacy-observation/v1",
    "source_revision": sys.argv[2],
    "homes": [
        {
            "home": sys.argv[4],
            "origin_url": sys.argv[5],
            "membership": "current",
            "pagination": pagination,
            "claims": [],
        },
        {
            "home": "workbench",
            "origin_url": sys.argv[3],
            "membership": "current",
            "pagination": pagination,
            "claims": [],
        },
    ],
    "origin_replacements": [],
    "blockers": [],
}
value["homes"].sort(key=lambda item: item["home"])
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
}

write_active_legacy_observation() {
  local output="$1" revision="$2" workspace_origin="$3" home="$4" home_origin="$5"
  python3 - "$output" "$revision" "$workspace_origin" "$home" "$home_origin" <<'PY'
import json
import sys

pagination = {"complete": True, "pages_fetched": 1, "end_cursor": None, "failure": None}
claim = {
    "claim_id": "legacy-task-17",
    "task_claim_id": "legacy-task-17",
    "task_contract": "workbench-task/v1",
    "issue": 17,
    "home": "workbench",
    "parent": None,
    "branch": "task/17-legacy-writer",
    "lifecycle_digest": "sha256:" + "6" * 64,
    "lifecycle_state": "task-active",
    "classification": "active-v1",
    "submission": None,
    "source_revision": sys.argv[2],
    "pr_head_revision": None,
    "ancestry_complete": True,
    "repos": [{"owner": sys.argv[4], "branch": "task/17-legacy-writer", "role": "work"}],
}
homes = [
    {
        "home": sys.argv[4], "origin_url": sys.argv[5], "membership": "current",
        "pagination": pagination, "claims": [],
    },
    {
        "home": "workbench", "origin_url": sys.argv[3], "membership": "current",
        "pagination": pagination, "claims": [claim],
    },
]
value = {
    "contract_version": "workbench-legacy-observation/v1",
    "source_revision": sys.argv[2],
    "homes": sorted(homes, key=lambda item: item["home"]),
    "origin_replacements": [],
    "blockers": [],
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
}

install_writer_git_barrier() {
  local case_name="$1" real_git barrier log
  real_git="$(command -v git)"; barrier="$TMPDIR/$case_name/writer-barrier"; log="$TMPDIR/$case_name/writer-order.log"
  mkdir -p "$barrier"; : > "$log"
  cat > "$TMPDIR/$case_name/bin/git" <<EOF
#!/usr/bin/env bash
set -u
args=" \$* "
if [[ "\$args" == *" push "* && "\$args" == *"refs/heads/workbench-coordination/writer-claims"* ]]; then
  id="\${WRITER_BARRIER_ID:-single}"
  if [ -n "\${WRITER_BARRIER_ID:-}" ] && [ ! -f "$barrier/\$id.done" ]; then
    : > "$barrier/\$id.ready"
    for _ in \$(seq 1 200); do
      [ "\$(find "$barrier" -name '*.ready' | wc -l | tr -d ' ')" -ge 2 ] && break
      sleep 0.02
    done
    : > "$barrier/\$id.done"
  fi
  "$real_git" "\$@"; rc=\$?
  if [ "\$rc" -eq 0 ]; then printf 'push-success:%s\n' "\$id" >> "$log"; else printf 'push-failed:%s\n' "\$id" >> "$log"; fi
  exit "\$rc"
fi
if [[ "\$args" == *" worktree add "* ]]; then
  printf 'worktree-add:%s\n' "\${WRITER_BARRIER_ID:-single}" >> "$log"
fi
if [[ "\$args" == *" worktree remove "* ]]; then
  printf 'worktree-remove:%s\n' "\${WRITER_BARRIER_ID:-single}" >> "$log"
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$TMPDIR/$case_name/bin/git"
}

test_v1_rejects_v2_mutation_but_keeps_legacy_start() {
  local repo task_dir out invalid
  repo="$(setup_workbench v1_compat '')"
  invalid="$TMPDIR/v1_compat/invalid-home.out"
  if run_task v1_compat "$repo" start '../escape#31' safe-slug >"$invalid" 2>&1; then
    fail "v1 start must reject a noncanonical reference home"
  fi
  assert_file_contains "$invalid" "잘못된 ID"
  task_dir="$(start_task v1_compat "$repo")"
  assert_file_contains "$TMPDIR/v1_compat/comments/29.comments" "workbench-task-lifecycle:v1"
  out="$TMPDIR/v1_compat/refs.out"
  if run_task_in_dir v1_compat "$task_dir" refs set --work-ref pack:item/one --format json >"$out" 2>&1; then
    fail "v1 workspace must reject v2 task mutation"
  fi
  assert_file_contains "$out" "workbench/v1"
}

test_start_rejects_noncanonical_schema_slug_and_home() {
  local repo out
  repo="$(setup_workbench start_validation)"
  out="$TMPDIR/start_validation/invalid.out"
  for slug in '../escape' 'Upper-Case' 'trailing-' 'too-many-slug-words-here'; do
    if run_task start_validation "$repo" start 29 "$slug" --format json >"$out" 2>&1; then
      fail "v2 start accepted noncanonical slug: $slug"
    fi
  done
  if run_task start_validation "$repo" start '../shared-api#29' safe-slug \
    --format json >"$out" 2>&1; then
    fail "v2 start accepted a noncanonical reference home"
  fi
  printf 'workbench/v2\n\n' > "$repo/.workbench/schema"
  if run_task start_validation "$repo" start 29 safe-slug --format json >"$out" 2>&1; then
    fail "task entrypoint accepted a schema marker with a trailing blank line"
  fi
  [ ! -e "$repo/.worktrees/task__29-safe-slug" ] || fail "invalid start created a task workspace"
}

test_v2_start_and_resume_are_authority_bound_skeletons() {
  local repo task_dir started resumed status digest lifecycle observation revision origin legacy_adapter
  setup_writer_workbench start_skeleton shared-api
  repo="$WRITER_REPO"

  started="$(run_task start_skeleton "$repo" start shared-api#29 skeleton --format json)"
  task_dir="$repo/.worktrees/task__shared-api__29-skeleton"
  digest="$(python3 - "$repo/.workbench/authority.json" <<'PY'
import hashlib
import sys

with open(sys.argv[1], "rb") as handle:
    print("sha256:" + hashlib.sha256(handle.read()).hexdigest())
PY
)"

  [ "$(json_get "$started" contract_version)" = workbench-task-start/v2 ] || fail "wrong start contract"
  [ "$(json_get "$started" task_contract)" = workbench-task/v2 ] || fail "wrong task contract"
  [ "$(json_get "$started" workspace_authority_descriptor_digest)" = "$digest" ] \
    || fail "start did not bind the authority descriptor"
  [ "$(json_get "$started" context_ref)" = "" ] || fail "start inferred context_ref"
  [ "$(json_get "$started" work_ref)" = "" ] || fail "start inferred work_ref"
  [ "$(json_get "$started" context_policy_sealed)" = false ] || fail "start sealed context policy"
  [ "$(json_get "$started" work_owners)" = '[]' ] || fail "start attached a work owner"
  [ "$(json_get "$started" changed)" = true ] || fail "new start must report changed"
  [ ! -e "$task_dir/task/codebases/shared-api" ] || fail "v2 start auto-attached its codebase home"
  ! grep -q '^- shared-api |' "$task_dir/task/index.md" || fail "v2 start wrote a repo record"
  assert_file_contains "$task_dir/task/index.md" "workspace_authority_descriptor_digest: $digest"

  lifecycle="$TMPDIR/start_skeleton/comments/29.comments"
  assert_file_contains "$lifecycle" 'workbench-task-lifecycle:v2'
  assert_file_contains "$lifecycle" "\"workspace_authority_descriptor_digest\":\"$digest\""

  resumed="$(run_task start_skeleton "$repo" resume shared-api#29 --format json)"
  [ "$(json_get "$resumed" contract_version)" = workbench-task-start/v2 ] || fail "wrong resume contract"
  [ "$(json_get "$resumed" workspace_authority_descriptor_digest)" = "$digest" ] \
    || fail "resume lost authority binding"
  [ "$(json_get "$resumed" changed)" = false ] || fail "materialized resume must be unchanged"
  [ ! -e "$task_dir/task/codebases/shared-api" ] || fail "v2 resume auto-attached its codebase home"
  observation="$TMPDIR/start_skeleton/legacy-observation.json"
  revision="$(git -C "$repo" rev-parse origin/main)"
  origin="$(git -C "$repo" remote get-url origin)"
  write_empty_legacy_observation "$observation" "$revision" "$origin" shared-api \
    "$TMPDIR/start_skeleton/shared-api.git"
  legacy_adapter="$TMPDIR/start_skeleton/bin/legacy-adapter"
  write_fake_legacy_adapter "$legacy_adapter" "$observation"
  status="$(WORKBENCH_TRUSTED_LEGACY_ADAPTER="$legacy_adapter" \
    run_task start_skeleton "$repo" status --format json)"
  [ "$(json_get "$status" tasks.0.workspace_authority_descriptor_digest)" = "$digest" ] \
    || fail "status lost the task authority descriptor binding"
}

test_refs_are_opaque_and_duplicate_active_work_is_rejected() {
  local repo first second actual out
  repo="$(setup_workbench refs)"
  first="$(start_task refs "$repo" 29)"
  second="$(start_task refs "$repo" 31)"

  assert_file_contains "$first/task/index.md" "task_contract: workbench-task/v2"
  actual="$(run_task_in_dir refs "$first" refs set \
    --context-ref toolbox:product/acme --work-ref toolbox:scenario/SCN-001 --format json)"
  assert_contains "$actual" '"contract_version":"workbench-task-refs/v1"'
  assert_contains "$actual" '"changed":true'
  actual="$(run_task_in_dir refs "$first" refs show --format json)"
  assert_contains "$actual" '"task_contract":"workbench-task/v2"'
  assert_contains "$actual" '"context_ref":"toolbox:product/acme"'
  assert_contains "$actual" '"work_ref":"toolbox:scenario/SCN-001"'

  out="$TMPDIR/refs/duplicate.out"
  if run_task_in_dir refs "$second" refs set --work-ref toolbox:scenario/SCN-001 --format json >"$out" 2>&1; then
    fail "duplicate active work_ref must be rejected"
  fi
  assert_file_contains "$out" "duplicate active work_ref"

  if run_task_in_dir refs "$second" refs set --work-ref 'scenario without namespace' --format json >"$out" 2>&1; then
    fail "invalid namespaced ref must be rejected"
  fi
}

test_policy_context_is_owner_authorized_sealed_and_manifest_bound() {
  local repo task_dir claim registration actual out rc instance target revision intent manifest auth
  local policy_digest resolved old_instance new_instance request
  repo="$(setup_workbench policy_context)"
  printf '%s\n' \
    'schema=workbench-policy/v1' \
    'action.task.policy-context.register=allow' \
    'action.task.policy-context.seal=allow' \
    'action.task.abandon=allow' > "$repo/.workbench/policy.conf"
  git -C "$repo" add .workbench/policy.conf
  git -C "$repo" commit -q -m "test: allow policy context lifecycle"
  git -C "$repo" push -q
  task_dir="$(start_task policy_context "$repo")"
  claim="$(sed -n 's/^claim_id: *//p' "$task_dir/task/index.md")"
  run_task_in_dir policy_context "$task_dir" refs set \
    --context-ref toolbox:product/acme --format json >/dev/null

  mkdir -p "$task_dir/contexts"
  printf '%s\n' \
    'schema=workbench-policy/v1' \
    'action.task.policy-context.seal=allow' \
    'action.task.abandon=allow' > "$task_dir/contexts/acme.policy"
  policy_digest="sha256:$(python3 - "$task_dir/contexts/acme.policy" <<'PY'
import hashlib
import sys

print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)"

  registration="$TMPDIR/policy_context/registration.json"
  python3 - "$registration" "$claim" "$policy_digest" <<'PY'
import json
import sys

receipt = {
    "contract_version": "workbench-policy-authority-receipt/v1",
    "authority_identity": "toolbox:authority/product-owner",
    "authority_ref": "toolbox:policy/acme",
    "authority_revision": "sha256:" + "a" * 64,
    "policy_ref": "contexts/acme.policy",
    "policy_digest": sys.argv[3],
    "actor": "owner@example.com",
    "issued_at": "2026-07-11T03:09:00Z",
    "source_ref": "toolbox:approval/policy-acme-v1",
}
value = {
    "contract_version": "workbench-context-policy-registration/v1",
    "registration_id": "ctxreg-acme-1",
    "task_claim_id": sys.argv[2],
    "task_context_ref": "toolbox:product/acme",
    "participants": [
        {
            "context_ref": "toolbox:product/acme",
            "policy_ref": "contexts/acme.policy",
            "policy_digest": sys.argv[3],
            "authority_ref": "toolbox:policy/acme",
            "authority_receipt": receipt,
        }
    ],
    "task_policy": None,
    "actor": "owner@example.com",
    "registered_at": "2026-07-11T03:10:00Z",
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY

  out="$TMPDIR/policy_context/register.out"
  if run_task_in_dir policy_context "$task_dir" policy-context register \
    --registration-file "$registration" --format json >"$out"; then
    fail "owner registration must require explicit authorization"
  else rc=$?; fi
  [ "$rc" = 3 ] || fail "owner registration pending exit must be 3"
  actual="$(cat "$out")"
  instance="$(json_get "$actual" action_instance.id)"
  target="$(json_get "$actual" action_instance.target_ref)"
  revision="$(json_get "$actual" action_instance.revision)"
  intent="$(json_get "$actual" action_instance.intent_digest)"
  manifest="$(json_get "$actual" action_instance.policy_manifest.digest)"
  auth="$TMPDIR/policy_context/register-auth.json"
  write_authorization "$auth" "$instance" task.policy-context.register "$claim" "$target" \
    "$revision" "$manifest" allow owner@example.com 2026-07-11T03:10:00Z \
    conversation:message/register-1 "$intent"
  if WORKBENCH_TEST_FAIL_AFTER_CONTEXT_PRIMARY=register \
    run_task_in_dir policy_context "$task_dir" policy-context register \
      --registration-file "$registration" --action-instance-id "$instance" \
      --authorization-file "$auth" --format json >/dev/null 2>&1; then
    fail "context registration post-primary crash fixture must fail"
  fi
  assert_file_contains "$task_dir/task/.workbench/policy-context/state.record" \
    "registration_action_instance_id=$instance"
  assert_file_contains "$task_dir/task/.workbench/actions/$instance.record" 'status=authorized'
  actual="$(run_task_in_dir policy_context "$task_dir" policy-context register \
    --registration-file "$registration" --action-instance-id "$instance" --format json)"
  assert_contains "$actual" '"registration_ref":"workbench:context-registration/ctxreg-acme-1"'
  assert_contains "$actual" '"sealed":false'
  assert_contains "$actual" '"authority_identity":"toolbox:authority/product-owner"'
  assert_contains "$actual" "\"policy_digest\":\"$policy_digest\""

  out="$TMPDIR/policy_context/seal-crash.out"
  if WORKBENCH_TEST_FAIL_AFTER_CONTEXT_PRIMARY=seal \
    run_task_in_dir policy_context "$task_dir" policy-context seal --format json >"$out" 2>&1; then
    fail "context seal post-primary crash fixture must fail"
  fi
  instance="$(sed -n 's/^seal_action_instance_id=//p' \
    "$task_dir/task/.workbench/policy-context/state.record")"
  [ -n "$instance" ] || fail "context seal crash lost its action identity"
  assert_file_contains "$task_dir/task/.workbench/actions/$instance.record" 'status=authorized'
  actual="$(run_task_in_dir policy_context "$task_dir" policy-context seal \
    --action-instance-id "$instance" --format json)"
  assert_contains "$actual" '"sealed":true'
  assert_contains "$actual" '"digest":"sha256:'
  assert_contains "$actual" '"task_policy":null'

  revision="$(json_get "$(run_task_in_dir policy_context "$task_dir" verify --format json)" revision)"
  target="workbench:task/$claim"
  request="$TMPDIR/policy_context/abandon-request.json"
  python3 - "$request" "$claim" "$target" "$revision" <<'PY'
import json
import sys

payload = (
    "workbench-task-abandon-intent/v1\n"
    "outcome\tabandoned\n"
    "abandonment_revision\t" + sys.argv[4] + "\n"
    "reason_code\tfixture\n"
    "reason_ref\tnull\n"
)
value = {
    "contract_version": "workbench-action-request/v1",
    "action_id": "task.abandon",
    "task_claim_id": sys.argv[2],
    "target_ref": sys.argv[3],
    "revision": sys.argv[4],
    "payload_contract": "workbench-task-abandon-intent/v1",
    "payload": payload,
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  intent="$(python3 "$INTENT_HELPER" request "$request" --format shell \
    | sed -n 's/^intent_digest=//p')"
  printf '%s\n' \
    'schema=workbench-policy/v1' \
    'action.task.abandon=deny' > "$task_dir/.workbench/policy.conf"
  resolved="$(run_policy_in_dir policy_context "$task_dir" resolve \
    --request-file "$request" --intent-digest "$intent" --format json)"
  [ "$(json_get "$resolved" decision)" = allow ] || fail "task-branch workspace policy influenced authority"
  old_instance="$(json_get "$resolved" action_instance.id)"
  assert_contains "$resolved" '"layer":"workspace"'
  assert_contains "$resolved" '"authority_identity":"fixture:workspace/local"'
  assert_contains "$resolved" '"authority_ref":"refs/heads/main"'
  assert_contains "$resolved" '"authority_receipt_digest":"sha256:'
  assert_contains "$resolved" '"layer":"context","context_ref":"toolbox:product/acme"'

  printf '%s\n' \
    'schema=workbench-policy/v1' \
    'action.task.policy-context.seal=allow' \
    'action.task.abandon=deny' > "$task_dir/contexts/acme.policy"
  out="$TMPDIR/policy_context/tampered.out"
  if run_policy_in_dir policy_context "$task_dir" resolve \
    --request-file "$request" --intent-digest "$intent" \
    --action-instance-id "$old_instance" --format json >"$out" 2>&1; then
    fail "changed sealed context bytes must fail closed"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "tampered context must exit 1"
  assert_file_contains "$out" 'policy-source-tampered'
  assert_file_contains "$task_dir/task/.workbench/actions/$old_instance.record" 'status=authorized'
}

test_null_context_lazy_seal_and_frozen_action_registry() {
  local repo task_dir actual out rc claim request
  repo="$(setup_workbench lazy_context)"
  task_dir="$(start_task lazy_context "$repo")"
  claim="$(sed -n 's/^claim_id: *//p' "$task_dir/task/index.md")"

  actual="$(run_task_in_dir lazy_context "$task_dir" policy-context seal --format json)"
  assert_contains "$actual" '"task_context_ref":null'
  assert_contains "$actual" '"sealed":true'
  assert_contains "$actual" '"registration_ref":"workbench:context-registration/auto-null/'
  assert_contains "$actual" '"registration_digest":"sha256:'
  assert_contains "$actual" '"registration_action_instance_id":null'
  assert_contains "$actual" '"seal_action_instance_id":null'
  assert_contains "$actual" '"participants":[]'
  assert_contains "$actual" '"task_policy":null'

  out="$TMPDIR/lazy_context/immutable.out"
  if run_task_in_dir lazy_context "$task_dir" refs set \
    --context-ref toolbox:product/late --format json >"$out" 2>&1; then
    fail "lazy seal must freeze context_ref"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "immutable context must exit 1"
  assert_file_contains "$out" 'policy-context-immutable'

  out="$TMPDIR/lazy_context/unsupported.out"
  request="$TMPDIR/lazy_context/unsupported-request.json"
  python3 - "$request" "$claim" <<'PY'
import json
import sys

value = {
    "contract_version": "workbench-action-request/v1",
    "action_id": "toolbox.deploy",
    "task_claim_id": sys.argv[2],
    "target_ref": "workbench:task/" + sys.argv[2],
    "revision": "sha256:" + "a" * 64,
    "payload_contract": "toolbox-deploy-intent/v1",
    "payload": "toolbox-deploy-intent/v1\n",
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  if run_policy_in_dir lazy_context "$task_dir" resolve \
    --request-file "$request" \
    --intent-digest sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --format json >"$out" 2>&1; then
    fail "namespaced pack action must not enter the kernel registry"
  else rc=$?; fi
  [ "$rc" = 2 ] || fail "unsupported action must exit 2"
  assert_file_contains "$out" 'unsupported-action'
}

test_deliverables_and_revision_bound_evidence() {
  local repo task_dir actual out
  repo="$(setup_workbench evidence)"
  printf 'web: https://github.com/example/web.git\n' > "$repo/codebases.yaml"
  git -C "$repo" add codebases.yaml
  git -C "$repo" commit -q -m "test: register evidence owner"
  git -C "$repo" push -q
  task_dir="$(start_task evidence "$repo")"

  actual="$(run_task_in_dir evidence "$task_dir" deliverable declare --id web-pr --owner web \
    --kind codebase-pr --required false --external-ref https://example.invalid/web/pull/7 \
    --revision abc123 --format json)"
  assert_contains "$actual" '"changed":true'
  assert_contains "$actual" '"deliverable":{"deliverable_id":"web-pr"'
  actual="$(run_task_in_dir evidence "$task_dir" deliverable list --format json)"
  assert_contains "$actual" '"contract_version":"workbench-deliverables/v1"'
  assert_contains "$actual" '"deliverable_id":"web-pr"'
  assert_contains "$actual" '"required":false'
  assert_contains "$actual" '"state":"declared"'

  out="$TMPDIR/evidence/duplicate.out"
  actual="$(run_task_in_dir evidence "$task_dir" deliverable declare --id web-pr --owner web \
    --kind codebase-pr --required false --external-ref https://example.invalid/web/pull/7 \
    --revision abc123 --format json)"
  assert_contains "$actual" '"changed":false' "identical declare must be idempotent"

  run_task_in_dir evidence "$task_dir" required-check declare --id web-test --owner web \
    --deliverable-id web-pr --format json >/dev/null

  run_task_in_dir evidence "$task_dir" evidence record --id web-tests \
    --owner web --subject-ref workbench:deliverable/web-pr --subject-revision abc123 --check-id web-test \
    --command "npm test" --result passed --source local --format json >/dev/null
  actual="$(run_task_in_dir evidence "$task_dir" evidence list --format json)"
  assert_contains "$actual" '"evidence_id":"web-tests"'
  assert_contains "$actual" '"subject_ref":"workbench:deliverable/web-pr"'
  assert_contains "$actual" '"subject_revision":"abc123"'
  assert_contains "$actual" '"stale":false'

  run_task_in_dir evidence "$task_dir" deliverable update --id web-pr --revision def456 --state declared --format json >/dev/null
  actual="$(run_task_in_dir evidence "$task_dir" evidence list --format json)"
  assert_contains "$actual" '"stale":true'

  out="$TMPDIR/evidence/verify-stale.out"
  if run_task_in_dir evidence "$task_dir" verify --format json >"$out" 2>&1; then
    fail "stale evidence must not verify a changed revision"
  fi
  assert_file_contains "$out" '"code":"stale-evidence"'

  run_task_in_dir evidence "$task_dir" evidence record --id web-tests-def \
    --owner web --subject-ref workbench:deliverable/web-pr --subject-revision def456 --check-id web-test \
    --result passed --source ci --url https://ci.example.invalid/2 --format json >/dev/null
  actual="$(run_task_in_dir evidence "$task_dir" verify --format json)"
  assert_contains "$actual" '"verified":true'
  assert_contains "$actual" '"required_checks":[{"check_id":"web-test"'
  assert_file_contains "$TMPDIR/evidence/comments/29.comments" '"event":"task-verified"'
  assert_file_contains "$TMPDIR/evidence/comments/29.comments" "workbench-task-lifecycle:v2"
}

test_kernel_probe_acceptance_is_revision_and_owner_bound() {
  local repo task_dir actual out rc
  repo="$(setup_workbench acceptance)"
  printf 'web: https://github.com/example/web.git\n' > "$repo/codebases.yaml"
  git -C "$repo" add codebases.yaml
  git -C "$repo" commit -q -m "test: register acceptance owner"
  git -C "$repo" push -q
  task_dir="$(start_task acceptance "$repo")"
  printf 'web: https://github.com/attacker/forged.git\n' > "$task_dir/codebases.yaml"
  run_task_in_dir acceptance "$task_dir" deliverable declare --id web-pr --owner web \
    --kind codebase-pr --external-ref https://github.com/example/web/pull/7 \
    --revision abc123 --format json >/dev/null

  out="$TMPDIR/acceptance/declared.out"
  if run_task_in_dir acceptance "$task_dir" deliverable accept --id web-pr --format json >"$out" 2>&1; then
    fail "declared deliverable must be submitted before acceptance"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "invalid acceptance state must exit 1"
  assert_file_contains "$out" 'deliverable-not-submitted'
  run_task_in_dir acceptance "$task_dir" deliverable update --id web-pr --state submitted --format json >/dev/null

  actual="$(run_task_in_dir acceptance "$task_dir" deliverable accept --id web-pr --format json)"
  assert_contains "$actual" '"contract_version":"workbench-deliverable-acceptance/v1"'
  assert_contains "$actual" '"state":"accepted"'
  assert_contains "$actual" '"authority_type":"kernel-probe"'
  assert_contains "$actual" '"authority_contract":"workbench-probe/github-pr/v1"'
  assert_contains "$actual" '"authority_digest":"sha256:'
  assert_contains "$actual" '"action_instance_id":null'

  actual="$(run_task_in_dir acceptance "$task_dir" deliverable acceptance list --format json)"
  assert_contains "$actual" '"contract_version":"workbench-acceptances/v1"'
  assert_contains "$actual" '"deliverable_id":"web-pr"'
  actual="$(run_task_in_dir acceptance "$task_dir" verify --format json)"
  assert_contains "$actual" '"verified":true'

  run_task_in_dir acceptance "$task_dir" deliverable declare --id api-pr --owner web \
    --kind codebase-pr --required false --external-ref https://github.com/example/web/pull/8 \
    --revision expected456 --format json >/dev/null
  run_task_in_dir acceptance "$task_dir" deliverable update --id api-pr --state submitted --format json >/dev/null
  out="$TMPDIR/acceptance/mismatch.out"
  if GH_PR_HEAD=other999 run_task_in_dir acceptance "$task_dir" deliverable accept \
    --id api-pr --format json >"$out" 2>&1; then
    fail "merged PR with another head revision must not be accepted"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "external acceptance mismatch must exit 1"
  assert_file_contains "$out" 'external-not-accepted'
  actual="$(run_task_in_dir acceptance "$task_dir" deliverable list --format json)"
  assert_contains "$actual" '"deliverable_id":"api-pr","owner":"web","kind":"codebase-pr","owner_context_ref":null,"acceptance_authority_ref":null,"required":false'
  assert_contains "$actual" '"revision":"expected456","state":"submitted"'
}

test_accepted_deliverable_revision_reset_preserves_append_only_receipts() {
  local repo task_dir actual out rc
  repo="$(setup_workbench acceptance_reset)"
  printf 'web: https://github.com/example/web.git\n' > "$repo/codebases.yaml"
  git -C "$repo" add codebases.yaml
  git -C "$repo" commit -q -m "test: register reset owner"
  git -C "$repo" push -q
  task_dir="$(start_task acceptance_reset "$repo")"
  run_task_in_dir acceptance_reset "$task_dir" deliverable declare --id web-pr --owner web \
    --kind codebase-pr --external-ref https://github.com/example/web/pull/7 \
    --revision abc123 --format json >/dev/null
  run_task_in_dir acceptance_reset "$task_dir" deliverable update --id web-pr --state submitted --format json >/dev/null
  run_task_in_dir acceptance_reset "$task_dir" deliverable accept --id web-pr --format json >/dev/null

  out="$TMPDIR/acceptance_reset/update-accepted.out"
  if run_task_in_dir acceptance_reset "$task_dir" deliverable update --id web-pr \
    --state accepted --format json >"$out" 2>&1; then
    fail "deliverable update must not synthesize accepted state"
  else rc=$?; fi
  [ "$rc" = 2 ] || fail "accepted update misuse must exit 2"

  out="$TMPDIR/acceptance_reset/revision-only.out"
  if run_task_in_dir acceptance_reset "$task_dir" deliverable update --id web-pr \
    --revision def456 --format json >"$out" 2>&1; then
    fail "accepted revision replacement must select a reset state"
  else rc=$?; fi
  [ "$rc" = 2 ] || fail "accepted revision reset misuse must exit 2"

  actual="$(run_task_in_dir acceptance_reset "$task_dir" deliverable update --id web-pr \
    --revision def456 --state submitted --format json)"
  assert_contains "$actual" '"revision":"def456","state":"submitted","acceptance_ref":null'
  actual="$(run_task_in_dir acceptance_reset "$task_dir" deliverable acceptance list --format json)"
  assert_contains "$actual" '"revision":"abc123"'
  actual="$(GH_PR_HEAD=def456 run_task_in_dir acceptance_reset "$task_dir" \
    deliverable accept --id web-pr --format json)"
  assert_contains "$actual" '"revision":"def456","state":"accepted"'
}

test_pack_deliverable_owner_binding_is_immutable_and_authorized() {
  local task_dir out rc actual assertion pending instance target revision intent manifest auth mismatch
  local before_task_revision after_task_revision
  prepare_pack_fixture pack_acceptance; task_dir="$PACK_TASK_DIR"

  out="$TMPDIR/pack_acceptance/missing-owner.out"
  if run_task_in_dir pack_acceptance "$task_dir" deliverable declare \
    --id artifact --owner release-pack --kind toolbox:artifact/release \
    --revision sha256:7777777777777777777777777777777777777777777777777777777777777777 \
    --format json >"$out" 2>&1; then
    fail "pack deliverable declaration must bind owner context and authority"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "missing pack owner binding must exit 1"
  assert_file_contains "$out" 'acceptance-authority-mismatch'

  out="$TMPDIR/pack_acceptance/mismatched-owner.out"
  if run_task_in_dir pack_acceptance "$task_dir" deliverable declare \
    --id artifact --owner release-pack --kind toolbox:artifact/release \
    --owner-context-ref toolbox:product/acme --acceptance-authority-ref toolbox:policy/other \
    --revision sha256:7777777777777777777777777777777777777777777777777777777777777777 \
    --format json >"$out" 2>&1; then
    fail "pack owner bindings must resolve the same sealed participant"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "mismatched pack authority must exit 1"
  assert_file_contains "$out" 'acceptance-authority-mismatch'

  actual="$(run_task_in_dir pack_acceptance "$task_dir" deliverable declare \
    --id artifact --owner release-pack --kind toolbox:artifact/release \
    --owner-context-ref toolbox:product/acme --acceptance-authority-ref toolbox:policy/acme \
    --revision sha256:7777777777777777777777777777777777777777777777777777777777777777 \
    --format json)"
  assert_contains "$actual" '"owner_context_ref":"toolbox:product/acme"'
  assert_contains "$actual" '"acceptance_authority_ref":"toolbox:policy/acme"'
  run_task_in_dir pack_acceptance "$task_dir" deliverable update \
    --id artifact --state submitted --format json >/dev/null
  before_task_revision="$(json_get "$(run_task_in_dir pack_acceptance "$task_dir" verify --format json)" revision)"

  assertion="$TMPDIR/pack_acceptance/owner-acceptance.json"
  python3 - "$assertion" <<'PY'
import json
import sys

value = {
    "contract_version": "workbench-owner-acceptance/v1",
    "acceptance_id": "acc-artifact-1",
    "deliverable_id": "artifact",
    "owner": "release-pack",
    "kind": "toolbox:artifact/release",
    "owner_context_ref": "toolbox:product/acme",
    "acceptance_authority_ref": "toolbox:policy/acme",
    "revision": "sha256:" + "7" * 64,
    "actor": "release-owner@example.com",
    "accepted_at": "2026-07-11T05:10:00Z",
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  mismatch="$TMPDIR/pack_acceptance/owner-mismatch.json"
  python3 - "$assertion" "$mismatch" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
value["acceptance_authority_ref"] = "toolbox:policy/other"
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  out="$TMPDIR/pack_acceptance/assertion-mismatch.out"
  if run_task_in_dir pack_acceptance "$task_dir" deliverable accept --id artifact \
    --owner-acceptance-file "$mismatch" --format json >"$out" 2>&1; then
    fail "owner assertion must not select another authority"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "owner assertion mismatch must exit 1"
  assert_file_contains "$out" 'acceptance-authority-mismatch'

  out="$TMPDIR/pack_acceptance/pending.out"
  if run_task_in_dir pack_acceptance "$task_dir" deliverable accept --id artifact \
    --owner-acceptance-file "$assertion" --format json >"$out"; then
    fail "pack acceptance must require explicit owner authorization"
  else rc=$?; fi
  [ "$rc" = 3 ] || fail "pack acceptance pending must exit 3"
  pending="$(cat "$out")"; instance="$(json_get "$pending" action_instance.id)"
  target="$(json_get "$pending" action_instance.target_ref)"; revision="$(json_get "$pending" action_instance.revision)"
  intent="$(json_get "$pending" action_instance.intent_digest)"
  manifest="$(json_get "$pending" action_instance.policy_manifest.digest)"
  auth="$TMPDIR/pack_acceptance/accept-auth.json"
  write_authorization "$auth" "$instance" task.deliverable.accept "$PACK_CLAIM" "$target" \
    "$revision" "$manifest" allow release-owner@example.com 2026-07-11T05:10:00Z \
    conversation:message/accept-artifact "$intent"
  actual="$(run_task_in_dir pack_acceptance "$task_dir" deliverable accept --id artifact \
    --owner-acceptance-file "$assertion" --action-instance-id "$instance" \
    --authorization-file "$auth" --format json)"
  assert_contains "$actual" '"state":"accepted"'
  assert_contains "$actual" '"owner_context_ref":"toolbox:product/acme"'
  assert_contains "$actual" '"acceptance_authority_ref":"toolbox:policy/acme"'
  assert_contains "$actual" '"authority_type":"owner-authorization"'
  assert_contains "$actual" '"authority_contract":"workbench-owner-acceptance/v1"'
  assert_contains "$actual" '"authority_ref":"toolbox:policy/acme"'
  assert_contains "$actual" "\"intent_digest\":\"$intent\""
  assert_contains "$actual" "\"action_instance_id\":\"$instance\""
  assert_contains "$actual" '"actor":"release-owner@example.com"'
  after_task_revision="$(json_get "$(run_task_in_dir pack_acceptance "$task_dir" verify --format json)" revision)"
  [ "$before_task_revision" != "$after_task_revision" ] \
    || fail "acceptance receipt and immutable owner binding must change the task revision"
}

test_pack_acceptance_recovers_from_durable_primary() {
  local task_dir assertion out pending instance target revision intent manifest auth actual rc
  prepare_pack_fixture pack_acceptance_recovery; task_dir="$PACK_TASK_DIR"
  run_task_in_dir pack_acceptance_recovery "$task_dir" deliverable declare \
    --id artifact --owner release-pack --kind toolbox:artifact/release \
    --owner-context-ref toolbox:product/acme --acceptance-authority-ref toolbox:policy/acme \
    --revision sha256:7777777777777777777777777777777777777777777777777777777777777777 \
    --format json >/dev/null
  run_task_in_dir pack_acceptance_recovery "$task_dir" deliverable update \
    --id artifact --state submitted --format json >/dev/null
  assertion="$TMPDIR/pack_acceptance_recovery/owner-acceptance.json"
  python3 - "$assertion" <<'PY'
import json
import sys

value = {
    "contract_version": "workbench-owner-acceptance/v1",
    "acceptance_id": "acc-artifact-recovery",
    "deliverable_id": "artifact",
    "owner": "release-pack",
    "kind": "toolbox:artifact/release",
    "owner_context_ref": "toolbox:product/acme",
    "acceptance_authority_ref": "toolbox:policy/acme",
    "revision": "sha256:" + "7" * 64,
    "actor": "release-owner@example.com",
    "accepted_at": "2026-07-11T05:10:00Z",
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  out="$TMPDIR/pack_acceptance_recovery/pending.out"
  if run_task_in_dir pack_acceptance_recovery "$task_dir" deliverable accept --id artifact \
    --owner-acceptance-file "$assertion" --format json > "$out"; then
    fail "pack recovery fixture must first require authorization"
  else rc=$?; fi
  [ "$rc" = 3 ] || fail "pack recovery pending must exit 3"
  pending="$(cat "$out")"; instance="$(json_get "$pending" action_instance.id)"
  target="$(json_get "$pending" action_instance.target_ref)"
  revision="$(json_get "$pending" action_instance.revision)"
  intent="$(json_get "$pending" action_instance.intent_digest)"
  manifest="$(json_get "$pending" action_instance.policy_manifest.digest)"
  auth="$TMPDIR/pack_acceptance_recovery/accept-auth.json"
  write_authorization "$auth" "$instance" task.deliverable.accept "$PACK_CLAIM" "$target" \
    "$revision" "$manifest" allow release-owner@example.com 2026-07-11T05:10:00Z \
    conversation:message/accept-recovery "$intent"
  out="$TMPDIR/pack_acceptance_recovery/crash.out"
  if WORKBENCH_TEST_FAIL_AFTER_ACCEPTANCE_PRIMARY=1 run_task_in_dir pack_acceptance_recovery \
    "$task_dir" deliverable accept --id artifact --owner-acceptance-file "$assertion" \
    --action-instance-id "$instance" --authorization-file "$auth" --format json \
    >"$out" 2>&1; then
    fail "simulated post-primary crash must fail"
  fi
  assert_file_contains "$task_dir/task/.workbench/acceptances/acc-artifact-recovery.record" \
    "intent_digest=$intent"
  assert_file_contains "$task_dir/task/.workbench/deliverables/artifact.record" 'state=submitted'

  actual="$(run_task_in_dir pack_acceptance_recovery "$task_dir" deliverable accept \
    --id artifact --action-instance-id "$instance" --format json)"
  assert_contains "$actual" '"changed":true'
  assert_contains "$actual" '"state":"accepted"'
  assert_file_contains "$task_dir/task/.workbench/actions/$instance.record" 'status=consumed'
  assert_file_contains "$task_dir/task/.workbench/actions/$instance.record" \
    'consumed_provenance_digest=sha256:'
}

test_deliverable_governed_effect_is_single_bound_reasoned_and_resettable() {
  local task_dir out rc pending instance revision intent manifest auth actual before weakened restored
  prepare_governed_fixture governed_deliverable; task_dir="$GOVERNED_TASK_DIR"
  run_task_in_dir governed_deliverable "$task_dir" deliverable declare --id report --owner reporting \
    --kind workbench-increment --external-ref artifact:report/v1 --format json >/dev/null

  out="$TMPDIR/governed_deliverable/combined.out"
  if run_task_in_dir governed_deliverable "$task_dir" deliverable update --id report \
    --required false --revision sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
    --reason-code scope-reduced --format json >"$out" 2>&1; then
    fail "governed effect must not combine with an ordinary revision update"
  else rc=$?; fi
  [ "$rc" = 2 ] || fail "combined governed update must exit 2"

  out="$TMPDIR/governed_deliverable/missing-reason.out"
  if run_task_in_dir governed_deliverable "$task_dir" deliverable update --id report \
    --required false --format json >"$out" 2>&1; then
    fail "governed effect must require a reason code"
  else rc=$?; fi
  [ "$rc" = 2 ] || fail "missing governed reason must exit 2"

  out="$TMPDIR/governed_deliverable/pending.out"
  if WORKBENCH_PLATFORM_POLICY="$GOVERNED_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/governed \
    run_task_in_dir governed_deliverable "$task_dir" deliverable update --id report \
      --required false --reason-code scope-reduced --reason-ref issue:77 --format json >"$out"; then
    fail "ask policy must leave deliverable weakening pending"
  else rc=$?; fi
  [ "$rc" = 3 ] || fail "pending deliverable weakening must exit 3"
  pending="$(cat "$out")"; instance="$(json_get "$pending" action_instance.id)"
  revision="$(json_get "$pending" action_instance.revision)"
  intent="$(json_get "$pending" action_instance.intent_digest)"
  manifest="$(json_get "$pending" action_instance.policy_manifest.digest)"
  auth="$TMPDIR/governed_deliverable/stale-auth.json"
  write_authorization "$auth" "$instance" task.deliverable.weaken "$GOVERNED_CLAIM" \
    workbench:deliverable/report "$revision" "$manifest" allow reviewer@example.com \
    2026-07-11T04:31:00Z conversation:message/weaken-stale "$intent"

  run_task_in_dir governed_deliverable "$task_dir" deliverable update --id report \
    --external-ref artifact:report/v2 --format json >/dev/null
  out="$TMPDIR/governed_deliverable/stale.out"
  if WORKBENCH_PLATFORM_POLICY="$GOVERNED_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/governed \
    run_task_in_dir governed_deliverable "$task_dir" deliverable update --id report \
      --required false --reason-code scope-reduced --reason-ref issue:77 \
      --action-instance-id "$instance" --authorization-file "$auth" --format json >"$out" 2>&1; then
    fail "deliverable action must not replay after its record revision changes"
  fi
  assert_file_contains "$out" 'action instance binding mismatch: revision'

  actual="$(run_task_in_dir governed_deliverable "$task_dir" verify --format json || true)"
  before="$(json_get "$actual" revision)"
  out="$TMPDIR/governed_deliverable/fresh-pending.out"
  if WORKBENCH_PLATFORM_POLICY="$GOVERNED_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/governed \
    run_task_in_dir governed_deliverable "$task_dir" deliverable update --id report \
      --required false --reason-code scope-reduced --reason-ref issue:77 --format json >"$out"; then
    fail "fresh governed weakening must ask again"
  else rc=$?; fi
  [ "$rc" = 3 ] || fail "fresh governed weakening must exit 3"
  pending="$(cat "$out")"; instance="$(json_get "$pending" action_instance.id)"
  revision="$(json_get "$pending" action_instance.revision)"
  intent="$(json_get "$pending" action_instance.intent_digest)"
  manifest="$(json_get "$pending" action_instance.policy_manifest.digest)"
  auth="$TMPDIR/governed_deliverable/fresh-auth.json"
  write_authorization "$auth" "$instance" task.deliverable.weaken "$GOVERNED_CLAIM" \
    workbench:deliverable/report "$revision" "$manifest" allow reviewer@example.com \
    2026-07-11T04:32:00Z conversation:message/weaken-fresh "$intent"
  actual="$(WORKBENCH_PLATFORM_POLICY="$GOVERNED_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/governed \
    run_task_in_dir governed_deliverable "$task_dir" deliverable update --id report \
      --required false --reason-code scope-reduced --reason-ref issue:77 \
      --action-instance-id "$instance" --authorization-file "$auth" --format json)"
  assert_contains "$actual" '"required":false'
  assert_contains "$actual" '"governance_action":"task.deliverable.weaken"'
  assert_contains "$actual" '"reason_code":"scope-reduced"'
  assert_contains "$actual" '"reason_ref":"issue:77"'
  assert_contains "$actual" "\"governance_action_instance_id\":\"$instance\""
  assert_contains "$actual" "\"governance_intent_digest\":\"$intent\""
  assert_contains "$actual" '"authorization_ref":"conversation:message/weaken-fresh"'
  assert_file_contains "$task_dir/task/.workbench/actions/$instance.record" 'status=consumed'

  actual="$(run_task_in_dir governed_deliverable "$task_dir" verify --format json || true)"
  weakened="$(json_get "$actual" revision)"; [ "$weakened" != "$before" ] || fail "weaken did not change task content revision"
  actual="$(run_task_in_dir governed_deliverable "$task_dir" deliverable update --id report \
    --required false --reason-code scope-reduced --reason-ref issue:77 --format json)"
  assert_contains "$actual" '"changed":false'

  actual="$(run_task_in_dir governed_deliverable "$task_dir" deliverable update --id report \
    --required true --format json)"
  assert_contains "$actual" '"required":true'
  assert_contains "$actual" '"governance_action":null'
  assert_contains "$actual" '"reason_code":null'
  actual="$(run_task_in_dir governed_deliverable "$task_dir" verify --format json || true)"
  restored="$(json_get "$actual" revision)"; [ "$restored" = "$before" ] || fail "governance reset did not restore content revision"
}

test_required_check_waive_is_reasoned_revision_bound_and_idempotent() {
  local task_dir out rc pending instance revision intent manifest auth actual
  prepare_governed_fixture governed_check; task_dir="$GOVERNED_TASK_DIR"
  run_task_in_dir governed_check "$task_dir" required-check declare --id advisory --owner workbench --format json >/dev/null
  out="$TMPDIR/governed_check/missing-reason.out"
  if run_task_in_dir governed_check "$task_dir" required-check waive --id advisory --format json >"$out" 2>&1; then
    fail "required-check waiver must require a reason"
  else rc=$?; fi
  [ "$rc" = 2 ] || fail "missing check waiver reason must exit 2"

  out="$TMPDIR/governed_check/pending.out"
  if WORKBENCH_PLATFORM_POLICY="$GOVERNED_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/governed \
    run_task_in_dir governed_check "$task_dir" required-check waive --id advisory \
      --reason-code not-applicable --reason-ref issue:88 --format json >"$out"; then
    fail "ask policy must leave required-check waiver pending"
  else rc=$?; fi
  [ "$rc" = 3 ] || fail "pending required-check waiver must exit 3"
  pending="$(cat "$out")"; instance="$(json_get "$pending" action_instance.id)"
  revision="$(json_get "$pending" action_instance.revision)"
  intent="$(json_get "$pending" action_instance.intent_digest)"
  manifest="$(json_get "$pending" action_instance.policy_manifest.digest)"
  auth="$TMPDIR/governed_check/authorization.json"
  write_authorization "$auth" "$instance" task.required-check.waive "$GOVERNED_CLAIM" \
    workbench:required-check/advisory "$revision" "$manifest" allow reviewer@example.com \
    2026-07-11T04:33:00Z conversation:message/check-waive "$intent"
  actual="$(WORKBENCH_PLATFORM_POLICY="$GOVERNED_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/governed \
    run_task_in_dir governed_check "$task_dir" required-check waive --id advisory \
      --reason-code not-applicable --reason-ref issue:88 --action-instance-id "$instance" \
      --authorization-file "$auth" --format json)"
  assert_contains "$actual" '"state":"waived"'
  assert_contains "$actual" '"governance_action":"task.required-check.waive"'
  assert_contains "$actual" '"reason_code":"not-applicable"'
  assert_contains "$actual" '"reason_ref":"issue:88"'
  assert_contains "$actual" "\"action_instance_id\":\"$instance\""
  assert_contains "$actual" "\"intent_digest\":\"$intent\""
  assert_contains "$actual" '"authorization_ref":"conversation:message/check-waive"'
  actual="$(run_task_in_dir governed_check "$task_dir" required-check waive --id advisory \
    --reason-code not-applicable --reason-ref issue:88 --format json)"
  assert_contains "$actual" '"changed":false'
  actual="$(run_task_in_dir governed_check "$task_dir" verify --format json)"
  assert_contains "$actual" '"verified":true'
}

test_submitted_and_failed_deliverables_block_verification() {
  local repo task_dir out
  repo="$(setup_workbench blocked_verify)"
  printf 'api: https://github.com/example/api.git\n' > "$repo/codebases.yaml"
  git -C "$repo" add codebases.yaml
  git -C "$repo" commit -q -m "test: register blocked owner"
  git -C "$repo" push -q
  task_dir="$(start_task blocked_verify "$repo")"
  run_task_in_dir blocked_verify "$task_dir" deliverable declare --id api-pr --owner api \
    --kind codebase-pr --external-ref https://github.com/example/api/pull/8 --revision abc123 --format json >/dev/null
  run_task_in_dir blocked_verify "$task_dir" deliverable update --id api-pr --state submitted --format json >/dev/null
  run_task_in_dir blocked_verify "$task_dir" required-check declare --id api-test --owner api \
    --deliverable-id api-pr --format json >/dev/null
  run_task_in_dir blocked_verify "$task_dir" evidence record --id api-tests \
    --owner api --subject-ref workbench:deliverable/api-pr --subject-revision abc123 \
    --check-id api-test --result passed --source ci --format json >/dev/null
  out="$TMPDIR/blocked_verify/submitted.out"
  if run_task_in_dir blocked_verify "$task_dir" verify --format json >"$out" 2>&1; then
    fail "submitted (unaccepted/unmerged) deliverable must block verification"
  fi
  assert_file_contains "$out" '"code":"unaccepted-deliverable"'

  run_task_in_dir blocked_verify "$task_dir" deliverable accept --id api-pr --format json >/dev/null
  run_task_in_dir blocked_verify "$task_dir" evidence record --id api-tests-failed \
    --owner api --subject-ref workbench:deliverable/api-pr --subject-revision abc123 \
    --check-id api-test --result failed --source ci --format json >/dev/null
  out="$TMPDIR/blocked_verify/failed.out"
  if run_task_in_dir blocked_verify "$task_dir" verify --format json >"$out" 2>&1; then
    fail "current failed evidence must block verification"
  fi
  assert_file_contains "$out" '"code":"failed-evidence"'
}

test_harvest_ledger_is_explicit_sealed_and_governed() {
  local repo task_dir actual out rc
  repo="$(setup_workbench harvest)"
  printf 'schema=workbench-policy/v1\naction.task.harvest.dispose=allow\n' \
    > "$repo/.workbench/policy.conf"
  git -C "$repo" add .workbench/policy.conf
  git -C "$repo" commit -q -m "test: allow harvest disposition"
  git -C "$repo" push -q
  task_dir="$(start_task harvest "$repo")"

  actual="$(run_task_in_dir harvest "$task_dir" harvest show --format json)"
  assert_contains "$actual" '"contract_version":"workbench-harvest/v1"'
  assert_contains "$actual" '"sealed":false'
  assert_contains "$actual" '"candidates":[]'

  actual="$(run_task_in_dir harvest "$task_dir" harvest seal --format json)"
  assert_contains "$actual" '"sealed":true'
  assert_contains "$actual" '"changed":true'

  actual="$(run_task_in_dir harvest "$task_dir" harvest candidate declare \
    --id auth-runbook --kind runbook --source-ref task:document/auth-research --format json)"
  assert_contains "$actual" '"sealed":false'
  assert_contains "$actual" '"candidate_id":"auth-runbook"'
  assert_contains "$actual" '"state":"pending"'

  out="$TMPDIR/harvest/unsealed-complete.out"
  if run_task_in_dir harvest "$task_dir" complete --format json >"$out" 2>&1; then
    fail "unsealed harvest inventory must block completion"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "harvest blocker must exit 1"
  assert_file_contains "$out" '"code":"harvest-unsealed"'

  actual="$(run_task_in_dir harvest "$task_dir" harvest dispose --id auth-runbook \
    --decision absorb --reason-code cross-project-reuse --target-ref workbench:docs/auth-testing --format json)"
  assert_contains "$actual" '"state":"disposed"'
  assert_contains "$actual" '"decision":"absorb"'
  run_task_in_dir harvest "$task_dir" harvest seal --format json >/dev/null
  actual="$(run_task_in_dir harvest "$task_dir" harvest show --format json)"
  assert_contains "$actual" '"sealed":true'
  assert_contains "$actual" '"changed":false'
}

test_codebase_only_completion_is_policy_gated_and_cleanup_safe() {
  local repo task_dir out branch actual instance revision target intent manifest auth rc
  repo="$(setup_workbench complete)"
  printf '%s\n' 'schema=workbench-policy/v1' 'action.task.cleanup=allow' > "$repo/.workbench/policy.conf"
  printf '%s\n' 'app: https://github.com/example/app.git' > "$repo/codebases.yaml"
  git -C "$repo" add .workbench/policy.conf codebases.yaml
  git -C "$repo" commit -q -m "test: allow codebase-only cleanup"
  git -C "$repo" push -q
  task_dir="$(start_task complete "$repo")"
  branch="task/29-v2-lifecycle-fixture-29"
  run_task_in_dir complete "$task_dir" deliverable declare --id app-pr --owner app \
    --kind codebase-pr --external-ref https://github.com/example/app/pull/9 --revision c0ffee --format json >/dev/null
  run_task_in_dir complete "$task_dir" deliverable update --id app-pr --state submitted --format json >/dev/null
  GH_PR_HEAD=c0ffee GH_PR_MERGE=beadfeed run_task_in_dir complete "$task_dir" deliverable accept \
    --id app-pr --format json >/dev/null
  run_task_in_dir complete "$task_dir" required-check declare --id app-test --owner app \
    --deliverable-id app-pr --format json >/dev/null
  run_task_in_dir complete "$task_dir" evidence record --id app-tests \
    --owner app --subject-ref workbench:deliverable/app-pr --subject-revision c0ffee \
    --check-id app-test --result passed --source ci --format json >/dev/null
  run_task_in_dir complete "$task_dir" harvest seal --format json >/dev/null

  out="$TMPDIR/complete/default-ask.out"
  if GH_PR_HEAD=c0ffee GH_PR_MERGE=beadfeed \
    run_task_in_dir complete "$task_dir" complete --format json \
      >"$out" 2>"$TMPDIR/complete/default-ask.err"; then
    fail "missing completion policy must resolve ask and block"
  else rc=$?; fi
  [ "$rc" = 3 ] || fail "complete ask must exit 3, got $rc: \
$(cat "$TMPDIR/complete/default-ask.err") $(cat "$out")"
  actual="$(cat "$out")"
  assert_contains "$actual" '"decision":"ask"'
  instance="$(json_get "$actual" action_instance.id)"
  revision="$(json_get "$actual" action_instance.revision)"
  target="$(json_get "$actual" action_instance.target_ref)"
  intent="$(json_get "$actual" action_instance.intent_digest)"
  manifest="$(json_get "$actual" action_instance.policy_manifest.digest)"
  git -C "$task_dir" add task/.workbench/actions
  git -C "$task_dir" commit -q -m "test: persist pending action"
  auth="$TMPDIR/complete/authorization.json"
  write_authorization "$auth" "$instance" task.complete \
    "$(sed -n 's/^claim_id: *//p' "$task_dir/task/index.md")" "$target" "$revision" \
    "$manifest" allow human@example.com 2026-07-11T03:01:00Z \
    conversation:message/msg-complete "$intent"
  actual="$(GH_PR_HEAD=c0ffee GH_PR_MERGE=beadfeed \
    run_task_in_dir complete "$task_dir" complete --action-instance-id "$instance" \
      --authorization-file "$auth" --format json)"
  assert_contains "$actual" '"outcome":"completed"'
  assert_contains "$actual" '"changed":true'
  assert_file_contains "$TMPDIR/complete/comments/29.comments" '"event":"task-completed"'

  git -C "$task_dir" add task
  git -C "$task_dir" commit -q -m "test: persist terminal state"
  git -C "$task_dir" push -q
  actual="$(run_task complete "$repo" "done" 29 --format json)"
  assert_contains "$actual" '"contract_version":"workbench-task-cleanup/v1"'
  assert_contains "$actual" '"outcome":"cleaned"'
  assert_contains "$actual" '"task_workspace":true'
  assert_contains "$actual" '"local_branch":true'
  [ ! -d "$task_dir" ] || fail "completed v2 task workspace must be cleaned"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    fail "completed codebase-only task branch must be removed without a workbench PR"
  fi
  assert_file_contains "$TMPDIR/complete/comments/29.comments" '"event":"task-cleaned"'
}

test_abandonment_is_terminal_and_distinct_from_cleanup() {
  local repo task_dir out actual instance terminal request
  repo="$(setup_workbench abandon)"
  printf 'schema=workbench-policy/v1\naction.task.abandon=allow\naction.task.complete=allow\naction.task.cleanup=allow\n' > "$repo/.workbench/policy.conf"
  git -C "$repo" add .workbench/policy.conf
  git -C "$repo" commit -q -m "test: allow terminal lifecycle"
  git -C "$repo" push -q
  task_dir="$(start_task abandon "$repo")"

  actual="$(run_task_in_dir abandon "$task_dir" abandon --reason-code superseded --reason-ref issue:55 --format json)"
  assert_contains "$actual" '"outcome":"abandoned"'
  assert_contains "$actual" '"reason_code":"superseded"'
  assert_contains "$actual" '"removal_plan_digest":"sha256:'
  assert_contains "$actual" '"intent_digest":"sha256:'
  instance="$(json_get "$actual" action_instance_id)"
  terminal="$task_dir/task/.workbench/terminal"
  request="$task_dir/task/.workbench/actions/$instance.request.json"
  [ "$(json_get "$actual" revision)" = "$(sed -n 's/^revision=//p' "$terminal")" ] \
    || fail "abandonment output and terminal revision diverged"
  [ "$(json_get "$actual" removal_plan_digest)" = "$(sed -n 's/^removal_plan_digest=//p' "$terminal")" ] \
    || fail "abandonment did not freeze the cleanup plan"
  python3 - "$request" "$terminal" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    request = json.load(handle)
terminal = dict(
    line.rstrip("\n").split("=", 1)
    for line in open(sys.argv[2], encoding="utf-8")
)
assert list(request) == [
    "contract_version", "action_id", "task_claim_id", "target_ref", "revision",
    "payload_contract", "payload",
]
assert request["action_id"] == "task.abandon"
assert request["revision"] == terminal["revision"]
assert request["payload_contract"] == "workbench-task-abandon-intent/v1"
assert request["payload"] == (
    "workbench-task-abandon-intent/v1\n"
    "outcome\tabandoned\n"
    "abandonment_revision\t{}\n"
    "reason_code\tsuperseded\n"
    "reason_ref\tissue:55\n"
).format(terminal["revision"])
PY
  assert_file_contains "$TMPDIR/abandon/comments/29.comments" '"event":"task-abandoned"'
  out="$TMPDIR/abandon/complete.out"
  if run_task_in_dir abandon "$task_dir" complete --format json >"$out" 2>&1; then
    fail "abandoned task must not later complete"
  fi
  assert_file_contains "$out" '"outcome":null'

  git -C "$task_dir" add task .workbench/policy.conf
  git -C "$task_dir" commit -q -m "test: persist abandoned state"
  git -C "$task_dir" push -q
  actual="$(run_task abandon "$repo" "done" 29 --format json)"
  assert_contains "$actual" '"outcome":"cleaned"'
  assert_file_contains "$TMPDIR/abandon/comments/29.comments" '"event":"task-cleaned"'
}

test_terminal_outcome_freezes_mutations_and_verification_is_read_only() {
  local repo task_dir claim revision expected out actual verified_before verified_after
  repo="$(setup_workbench terminal_freeze)"
  task_dir="$(start_task terminal_freeze "$repo")"
  claim="$(sed -n 's/^claim_id: *//p' "$task_dir/task/index.md")"
  revision="sha256:$(printf terminal-fixture | shasum -a 256 | awk '{print $1}')"
  mkdir -p "$task_dir/task/.workbench"
  cat > "$task_dir/task/.workbench/terminal" <<EOF
outcome=abandoned
action_instance_id=action_terminal_fixture
revision=$revision
at=2026-07-11T04:00:00Z
reason_code=superseded
reason_ref=issue:55
EOF

  expected="{\"contract_version\":\"workbench-error/v1\",\"operation\":\"task.refs.set\",\"blockers\":[{\"code\":\"terminal-content-frozen\",\"ref\":\"workbench:task/$claim\"}]}"
  out="$TMPDIR/terminal_freeze/refs.out"
  if run_task_in_dir terminal_freeze "$task_dir" refs set \
    --work-ref toolbox:scenario/SCN-002 --format json >"$out" 2>"$TMPDIR/terminal_freeze/refs.err"; then
    fail "terminal task refs must be frozen"
  fi
  actual="$(cat "$out")"
  [ "$actual" = "$expected" ] || fail "unexpected terminal freeze error: $actual"
  [ ! -s "$TMPDIR/terminal_freeze/refs.err" ] || fail "terminal freeze must be emitted on stdout"
  [ -z "$(sed -n 's/^work_ref: *//p' "$task_dir/task/index.md")" ] \
    || fail "terminal refs mutation changed task/index.md"

  expected="{\"contract_version\":\"workbench-error/v1\",\"operation\":\"task.deliverable.declare\",\"blockers\":[{\"code\":\"terminal-content-frozen\",\"ref\":\"workbench:task/$claim\"}]}"
  out="$TMPDIR/terminal_freeze/deliverable.out"
  if run_task_in_dir terminal_freeze "$task_dir" deliverable declare --id frozen \
    --owner workbench --kind workbench-increment --format json >"$out" 2>/dev/null; then
    fail "terminal deliverable declaration must be frozen"
  fi
  [ "$(cat "$out")" = "$expected" ] || fail "unexpected terminal deliverable error: $(cat "$out")"
  [ ! -e "$task_dir/task/.workbench/deliverables/frozen.record" ] \
    || fail "terminal deliverable mutation created state"

  expected="{\"contract_version\":\"workbench-error/v1\",\"operation\":\"task.evidence.record\",\"blockers\":[{\"code\":\"terminal-content-frozen\",\"ref\":\"workbench:task/$claim\"}]}"
  out="$TMPDIR/terminal_freeze/evidence.out"
  if run_task_in_dir terminal_freeze "$task_dir" evidence record --id frozen \
    --owner workbench --subject-ref "workbench:task/$claim" --subject-revision "$revision" \
    --check-id frozen --result passed --source fixture --format json >"$out" 2>/dev/null; then
    fail "terminal evidence record must be frozen"
  fi
  [ "$(cat "$out")" = "$expected" ] || fail "unexpected terminal evidence error: $(cat "$out")"

  actual="$(run_task_in_dir terminal_freeze "$task_dir" abandon \
    --reason-code ignored-on-retry --format json)"
  assert_contains "$actual" '"outcome":"abandoned"'
  assert_contains "$actual" '"changed":false'

  verified_before="$(grep -c '"event":"task-verified"' "$TMPDIR/terminal_freeze/comments/29.comments" || true)"
  out="$TMPDIR/terminal_freeze/verify.out"
  run_task_in_dir terminal_freeze "$task_dir" verify --format json >"$out" 2>/dev/null || true
  assert_file_contains "$out" '"contract_version":"workbench-verification/v1"'
  run_task_in_dir terminal_freeze "$task_dir" verify --format json >/dev/null 2>&1 || true
  verified_after="$(grep -c '"event":"task-verified"' "$TMPDIR/terminal_freeze/comments/29.comments" || true)"
  [ "$verified_before" = "$verified_after" ] \
    || fail "post-terminal verification must not emit task-verified"
}

test_cleanup_prepared_journal_failure_deletes_nothing() {
  local out branch action_file
  prepare_cleanup_fixture cleanup_prepared_failure
  branch="task/29-v2-lifecycle-fixture-29"
  action_file="$CLEANUP_TASK_DIR/task/.workbench/actions/$CLEANUP_ACTION_INSTANCE.record"
  out="$TMPDIR/cleanup_prepared_failure/done.out"
  if GH_FAIL_CLEANUP_STAGE=prepared \
    WORKBENCH_PLATFORM_POLICY="$CLEANUP_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/cleanup \
    run_task cleanup_prepared_failure "$CLEANUP_REPO" "done" 29 \
      --action-instance-id "$CLEANUP_ACTION_INSTANCE" --format json >"$out" 2>/dev/null; then
    fail "cleanup must stop when its prepared journal is unavailable"
  fi
  assert_file_contains "$out" '"code":"cleanup-journal-unavailable"'
  assert_file_contains "$out" '"task_workspace":false'
  assert_file_contains "$out" '"local_branch":false'
  [ -d "$CLEANUP_TASK_DIR" ] || fail "prepared journal failure removed the task workspace"
  git -C "$CLEANUP_REPO" show-ref --verify --quiet "refs/heads/$branch" \
    || fail "prepared journal failure removed the local branch"
  [ "$(sed -n 's/^status=//p' "$action_file")" = authorized ] \
    || fail "failed prepared journal consumed the action instance"
  if grep -Fq 'workbench-task-cleanup:v1' "$TMPDIR/cleanup_prepared_failure/comments/29.comments"; then
    fail "failed prepared journal must not appear durable"
  fi
}

test_cleanup_journal_recovers_completed_and_lifecycle_after_deletion() {
  local out branch actual comments
  prepare_cleanup_fixture cleanup_recovery
  branch="task/29-v2-lifecycle-fixture-29"
  comments="$TMPDIR/cleanup_recovery/comments/29.comments"
  out="$TMPDIR/cleanup_recovery/completed-failure.out"
  if GH_FAIL_CLEANUP_STAGE=completed \
    WORKBENCH_PLATFORM_POLICY="$CLEANUP_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/cleanup \
    run_task cleanup_recovery "$CLEANUP_REPO" "done" 29 \
      --action-instance-id "$CLEANUP_ACTION_INSTANCE" --format json >"$out" 2>/dev/null; then
    fail "cleanup must report a completed journal write failure"
  fi
  assert_file_contains "$out" '"code":"cleanup-journal-unavailable"'
  [ ! -d "$CLEANUP_TASK_DIR" ] || fail "prepared cleanup did not remove the task workspace"
  if git -C "$CLEANUP_REPO" show-ref --verify --quiet "refs/heads/$branch"; then
    fail "prepared cleanup did not remove the local branch"
  fi
  assert_file_contains "$comments" '"stage":"prepared"'
  if grep -Fq '"stage":"completed"' "$comments"; then
    fail "failed completed journal must not appear durable"
  fi
  if grep -Fq '"event":"task-cleaned"' "$comments"; then
    fail "task-cleaned must follow a durable completed journal"
  fi

  python3 - "$comments" "$CLEANUP_POLICY_OUTPUT" "$CLEANUP_ACTION_INSTANCE" \
    "$CLEANUP_CLAIM" "$CLEANUP_REVISION" "$branch" "$CLEANUP_INTENT_DIGEST" \
    "$CLEANUP_REMOVAL_PLAN_DIGEST" <<'PY'
import json
import re
import sys


def unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise AssertionError("duplicate member: {}".format(key))
        value[key] = item
    return value


text = open(sys.argv[1], encoding="utf-8").read()
matches = re.findall(r"<!-- workbench-task-cleanup:v1\n([^\r\n]+)\n-->", text)
assert len(matches) == 1, matches
journal = json.loads(matches[0], object_pairs_hook=unique)
policy = json.load(open(sys.argv[2], encoding="utf-8"), object_pairs_hook=unique)
assert list(journal) == [
    "contract_version", "journal_id", "stage", "task_id", "claim_id", "branch",
    "revision", "action_instance_id", "intent_digest", "policy_manifest",
    "authorization_ref", "removal_plan_digest", "removal_plan",
    "effect_owner_events", "at",
]
assert journal["contract_version"] == "workbench-task-cleanup-journal/v1"
assert journal["journal_id"] == "cleanup-" + sys.argv[4]
assert journal["stage"] == "prepared"
assert journal["task_id"] == "29"
assert journal["claim_id"] == sys.argv[4]
assert journal["branch"] == sys.argv[6]
assert journal["revision"] == sys.argv[5]
assert journal["action_instance_id"] == sys.argv[3]
assert journal["intent_digest"] == sys.argv[7]
assert journal["policy_manifest"] == policy["action_instance"]["policy_manifest"]
assert journal["authorization_ref"] == policy["authorization_ref"]
assert journal["removal_plan_digest"] == sys.argv[8]
assert journal["removal_plan"] == {
    "writer_operations": [], "codebase_worktrees": [],
    "task_workspace": ".worktrees/task__29-v2-lifecycle-fixture-29",
    "local_branch": sys.argv[6],
}
assert journal["effect_owner_events"] == []
assert re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", journal["at"])
PY

  out="$TMPDIR/cleanup_recovery/lifecycle-failure.out"
  if GH_FAIL_LIFECYCLE_EVENT=task-cleaned \
    run_task cleanup_recovery "$CLEANUP_REPO" "done" 29 --format json >"$out" 2>/dev/null; then
    fail "cleanup must report task-cleaned lifecycle failure"
  fi
  assert_file_contains "$out" '"code":"lifecycle-write-failed"'
  assert_file_contains "$comments" '"stage":"completed"'
  if grep -Fq '"event":"task-cleaned"' "$comments"; then
    fail "failed lifecycle event must not appear durable"
  fi

  actual="$(run_task cleanup_recovery "$CLEANUP_REPO" "done" 29 --format json)"
  assert_contains "$actual" '"outcome":"cleaned"'
  assert_contains "$actual" '"changed":true'
  assert_file_contains "$comments" '"event":"task-cleaned"'
  actual="$(run_task cleanup_recovery "$CLEANUP_REPO" "done" 29 --format json)"
  assert_contains "$actual" '"outcome":"cleaned"'
  assert_contains "$actual" '"changed":false'

  python3 - "$comments" <<'PY'
import json
import re
import sys


def unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise AssertionError("duplicate member: {}".format(key))
        value[key] = item
    return value


text = open(sys.argv[1], encoding="utf-8").read()
matches = re.findall(r"<!-- workbench-task-cleanup:v1\n([^\r\n]+)\n-->", text)
journals = [json.loads(item, object_pairs_hook=unique) for item in matches]
assert [item["stage"] for item in journals] == ["prepared", "completed"]
assert text.index('"stage":"prepared"') < text.index('"stage":"completed"')
assert text.index('"stage":"completed"') < text.index('"event":"task-cleaned"')
for key in ("journal_id", "task_id", "claim_id", "branch", "revision", "action_instance_id", "intent_digest", "policy_manifest", "authorization_ref", "removal_plan_digest", "removal_plan", "effect_owner_events"):
    assert journals[0][key] == journals[1][key]
PY
}

test_v2_cleanup_requires_terminal_outcome_even_with_force() {
  local repo task_dir out branch rc
  repo="$(setup_workbench cleanup_guard)"
  task_dir="$(start_task cleanup_guard "$repo")"
  branch="task/29-v2-lifecycle-fixture-29"
  out="$TMPDIR/cleanup_guard/done.out"
  if run_task cleanup_guard "$repo" "done" 29 --force --format json >"$out" 2>&1; then
    fail "v2 force cleanup must not bypass terminal outcome"
  else rc=$?; fi
  [ "$rc" = 2 ] || fail "v2 --force must be usage exit 2"
  if run_task cleanup_guard "$repo" "done" 29 --format json >"$out" 2>&1; then
    fail "v2 cleanup without terminal outcome must be blocked"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "cleanup blocker must exit 1"
  assert_file_contains "$out" '"code":"missing-terminal-outcome"'
  [ -d "$task_dir" ] || fail "guarded v2 workspace must remain"
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" || fail "guarded v2 branch must remain"
}

test_writer_claim_cas_retry_rechecks_conflict_before_local_creation() {
  local first second out_first out_second rc_first rc_second ledger ref order
  setup_writer_workbench writer_cas
  prepare_writer_task writer_cas 29 a; first="$WRITER_TASK_DIR"
  prepare_writer_task writer_cas 31 b; second="$WRITER_TASK_DIR"
  install_writer_git_barrier writer_cas
  out_first="$TMPDIR/writer_cas/first.out"; out_second="$TMPDIR/writer_cas/second.out"

  (
    set +e
    WRITER_BARRIER_ID=first \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
      run_task_in_dir writer_cas "$first" add-repo shared-api --format json >"$out_first" 2>"$TMPDIR/writer_cas/first.err"
    printf '%s\n' "$?" > "$TMPDIR/writer_cas/first.rc"
  ) &
  local first_pid=$!
  (
    set +e
    WRITER_BARRIER_ID=second \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
      run_task_in_dir writer_cas "$second" add-repo shared-api --format json >"$out_second" 2>"$TMPDIR/writer_cas/second.err"
    printf '%s\n' "$?" > "$TMPDIR/writer_cas/second.rc"
  ) &
  local second_pid=$!
  wait "$first_pid"; wait "$second_pid"
  rc_first="$(cat "$TMPDIR/writer_cas/first.rc")"; rc_second="$(cat "$TMPDIR/writer_cas/second.rc")"
  [ "$rc_first" = 0 ] || fail "first writer failed: $(cat "$TMPDIR/writer_cas/first.err") $(cat "$out_first")"
  [ "$rc_second" = 0 ] || fail "second writer failed: $(cat "$TMPDIR/writer_cas/second.err") $(cat "$out_second")"

  assert_file_contains "$out_first" '"contract_version":"workbench-writer-claim/v1"'
  assert_file_contains "$out_second" '"contract_version":"workbench-writer-claim/v1"'
  [ -d "$first/task/codebases/shared-api" ] || fail "first local worktree was not created"
  [ -d "$second/task/codebases/shared-api" ] || fail "second local worktree was not created"
  assert_file_contains "$first/task/index.md" '- shared-api | task/29-v2-lifecycle-fixture-29 | work'
  assert_file_contains "$second/task/index.md" '- shared-api | task/31-v2-lifecycle-fixture-31 | work'

  ref=refs/heads/workbench-coordination/writer-claims
  ledger="$TMPDIR/writer_cas/writer-claims.tsv"
  git --git-dir="$TMPDIR/writer_cas/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
  python3 - "$out_first" "$out_second" "$ledger" <<'PY'
import json
import sys

first = json.load(open(sys.argv[1], encoding="utf-8"))
second = json.load(open(sys.argv[2], encoding="utf-8"))
assert first["claim_id"] != second["claim_id"]
assert sorted((len(first["conflicts"]), len(second["conflicts"]))) == [0, 1]
assert sorted((first["action_instance_id"] is None, second["action_instance_id"] is None)) == [False, True]
conflicted = first if first["conflicts"] else second
winner = second if first["conflicts"] else first
assert conflicted["conflicts"][0]["claim_id"] == winner["claim_id"]
lines = open(sys.argv[3], encoding="utf-8").read().splitlines()
assert lines[0] == "workbench-writer-claims/v1"
rows = [line.split("\t") for line in lines[1:]]
claims = [row for row in rows if row[0] == "claim"]
effects = [row for row in rows if row[0] == "effect-owner"]
assert len(claims) == 2 and len(effects) == 2
assert all(row[-1] == "active" for row in claims)
assert all(row[-1] == "acquired" for row in effects)
assert {row[2] for row in claims} == {first["claim_id"], second["claim_id"]}
assert {row[3] for row in effects} == {first["claim_id"], second["claim_id"]}
assert claims == sorted(claims, key=lambda row: (row[4], row[3], row[1], row[2], 0 if row[-1] == "active" else 1))
assert effects == sorted(effects, key=lambda row: (row[2], row[3], row[1]))
PY

  order="$TMPDIR/writer_cas/writer-order.log"
  python3 - "$order" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
for identity in ("first", "second"):
    assert lines.index("push-success:" + identity) < lines.index("worktree-add:" + identity), lines
assert any(line.startswith("push-failed:") for line in lines), lines
PY
}

test_writer_local_failure_releases_remote_claim_before_new_id() {
  local task_dir out actual first_claim second_claim ledger ref operation
  setup_writer_workbench writer_compensation
  prepare_writer_task writer_compensation 29 c; task_dir="$WRITER_TASK_DIR"
  mkdir -p "$task_dir/task/codebases/shared-api"
  printf '%s\n' occupied > "$task_dir/task/codebases/shared-api/occupied"
  out="$TMPDIR/writer_compensation/failed.out"
  if WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_compensation "$task_dir" add-repo shared-api --format json \
      >"$out" 2>"$TMPDIR/writer_compensation/failed.err"; then
    fail "local worktree failure must not report writer success"
  fi
  [ -s "$out" ] || fail "writer failure emitted no JSON: $(cat "$TMPDIR/writer_compensation/failed.err")"
  assert_file_contains "$out" '"code":"writer-lock-unavailable"'
  first_claim="$(json_get "$(cat "$out")" claim_id)"
  [ -n "$first_claim" ] || fail "failed local creation lost its stable claim ID"
  operation="$(python3 - "$task_dir/task/.workbench/writer-operations" "$first_claim" <<'PY'
import glob, json, os, sys
for path in glob.glob(os.path.join(sys.argv[1], "*.json")):
    value = json.load(open(path, encoding="utf-8"))
    if value["claim_id"] == sys.argv[2]:
        print(path); break
PY
)"
  [ -n "$operation" ] || fail "failed writer operation was not retained"
  [ "$(json_get "$(cat "$operation")" stage)" = released ] \
    || fail "failed writer operation did not reach released"
  if grep -Fq -- '- shared-api |' "$task_dir/task/index.md"; then
    fail "failed local creation wrote the task repo record"
  fi

  ref=refs/heads/workbench-coordination/writer-claims
  ledger="$TMPDIR/writer_compensation/writer-claims.tsv"
  git --git-dir="$TMPDIR/writer_compensation/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
  python3 - "$ledger" "$first_claim" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
matching = [row for row in rows if row[0] == "claim" and row[2] == sys.argv[2]]
assert [row[-1] for row in matching] == ["active", "released"]
assert all(row[1:-1] == matching[0][1:-1] for row in matching)
effects = [row for row in rows if row[0] == "effect-owner" and row[3] == sys.argv[2]]
assert [row[-1] for row in effects] == ["acquired", "released"]
PY

  rm -rf "$task_dir/task/codebases/shared-api"
  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_compensation "$task_dir" add-repo shared-api --format json)"
  assert_contains "$actual" '"changed":true'
  second_claim="$(json_get "$actual" claim_id)"
  [ "$second_claim" != "$first_claim" ] || fail "released writer claim ID was reactivated"
  [ -d "$task_dir/task/codebases/shared-api" ] || fail "writer retry did not create the local worktree"
  git --git-dir="$TMPDIR/writer_compensation/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
  python3 - "$ledger" "$first_claim" "$second_claim" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
assert [row[-1] for row in rows if row[0] == "claim" and row[2] == sys.argv[2]] == ["active", "released"]
assert [row[-1] for row in rows if row[0] == "claim" and row[2] == sys.argv[3]] == ["active"]
assert [row[-1] for row in rows if row[0] == "effect-owner" and row[3] == sys.argv[3]] == ["acquired"]
PY
}

test_writer_binds_protected_registry_and_rejects_cache_origin() {
  local task_dir expected_origin hostile out actual operation protected_revision protected_digest
  setup_writer_workbench writer_registry
  prepare_writer_task writer_registry 29 registry; task_dir="$WRITER_TASK_DIR"
  expected_origin="$TMPDIR/writer_registry/shared-api.git"
  hostile="$TMPDIR/writer_registry/hostile-shared-api.git"
  git init -q --bare "$hostile"
  git -C "$WRITER_REPO/.codebases/shared-api" remote set-url origin "$hostile"
  out="$TMPDIR/writer_registry/origin-mismatch.out"
  if WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_registry "$task_dir" add-repo shared-api --format json >"$out" 2>&1; then
    fail "writer add-repo trusted a mutable cache clone origin"
  fi
  assert_file_contains "$out" 'codebase-origin-mismatch: shared-api'
  if git --git-dir="$TMPDIR/writer_registry/origin.git" \
    show-ref --verify --quiet refs/heads/workbench-coordination/writer-claims; then
    fail "cache origin mismatch published a remote writer claim"
  fi

  git -C "$WRITER_REPO/.codebases/shared-api" remote set-url origin "$expected_origin"
  printf '%s\n' 'shared-api: /caller/forged/origin.git' > "$task_dir/codebases.yaml"
  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_registry "$task_dir" add-repo shared-api --format json)"
  assert_contains "$actual" '"changed":true'
  operation="$(find "$task_dir/task/.workbench/writer-operations" -name '*.json' -type f)"
  protected_revision="$(git -C "$WRITER_REPO" rev-parse origin/main)"
  protected_digest="sha256:$(git -C "$WRITER_REPO" show \
    "$protected_revision:codebases.yaml" | shasum -a 256 | awk '{print $1}')"
  python3 - "$operation" "$expected_origin" "$protected_revision" "$protected_digest" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    operation = json.load(handle)
assert operation["codebase_origin_url"] == sys.argv[2]
assert operation["registry_revision"] == sys.argv[3]
assert operation["registry_digest"] == sys.argv[4]
PY
}

test_writer_conflict_uses_complete_legacy_and_v2_union() {
  local task_dir observation adapter revision actual
  setup_writer_workbench writer_legacy_union
  prepare_writer_task writer_legacy_union 29 union; task_dir="$WRITER_TASK_DIR"
  revision="$(git -C "$WRITER_REPO" rev-parse origin/main)"
  observation="$TMPDIR/writer_legacy_union/legacy-observation.json"
  write_active_legacy_observation "$observation" "$revision" \
    "$(git -C "$WRITER_REPO" remote get-url origin)" shared-api \
    "$TMPDIR/writer_legacy_union/shared-api.git"
  adapter="$TMPDIR/writer_legacy_union/bin/active-legacy-adapter"
  write_fake_legacy_adapter "$adapter" "$observation"

  actual="$(WORKBENCH_TRUSTED_LEGACY_ADAPTER="$adapter" \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_legacy_union "$task_dir" add-repo shared-api --format json)"
  ACTUAL="$actual" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["ACTUAL"])
assert value["changed"] is True
assert len(value["conflicts"]) == 1
conflict = value["conflicts"][0]
assert conflict["source"] == "legacy-v1"
assert conflict["operation_id"] is None
assert conflict["task_claim_id"] == "legacy-task-17"
assert conflict["owner"] == "shared-api"
assert conflict["context_policy_set_digest"] is None
assert conflict["source_revision"] is not None
assert conflict["lifecycle_digest"].startswith("sha256:")
assert value["action_instance_id"] is not None
PY
}

test_writer_zero_history_recovery_rebinds_before_once_only_owner_acquire() {
  local task_dir out first operation claim operation_id common old_clone new_clone actual ledger ref
  setup_writer_workbench writer_zero_history
  prepare_writer_task writer_zero_history 29 z; task_dir="$WRITER_TASK_DIR"
  out="$TMPDIR/writer_zero_history/claim-crash.out"
  if WORKBENCH_TEST_FAIL_AFTER_WRITER_CLAIM=1 \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_zero_history "$task_dir" add-repo shared-api --format json >"$out"; then
    fail "writer claim crash fixture must stop before effect-owner acquisition"
  fi
  first="$(cat "$out")"; claim="$(json_get "$first" claim_id)"
  operation_id="$(json_get "$first" operation_id)"
  operation="$task_dir/task/.workbench/writer-operations/$operation_id.json"
  [ "$(json_get "$(cat "$operation")" stage)" = remote-claimed ] \
    || fail "claim crash did not persist remote-claimed"
  common="$(git -C "$WRITER_REPO" rev-parse --git-common-dir)"
  common="$(cd "$WRITER_REPO" && cd "$common" && pwd)"
  old_clone="$(cat "$common/workbench-v2/clone-id")"
  rm -f "$operation"
  python3 -c 'import uuid; print(uuid.uuid4())' > "$common/workbench-v2/clone-id"
  new_clone="$(cat "$common/workbench-v2/clone-id")"
  [ "$old_clone" != "$new_clone" ] || fail "zero-history fixture did not change clone identity"

  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_zero_history "$task_dir" add-repo shared-api --format json)"
  assert_contains "$actual" '"operation_stage":"consumed"'
  [ "$(json_get "$actual" claim_id)" = "$claim" ] \
    || fail "zero-history recovery minted a new claim"
  [ "$(json_get "$actual" operation_id)" = "$operation_id" ] \
    || fail "zero-history recovery minted a new operation"
  operation="$task_dir/task/.workbench/writer-operations/$operation_id.json"
  [ "$(json_get "$(cat "$operation")" clone_id)" = "$new_clone" ] \
    || fail "reconstructed operation did not bind the new clone before ownership"

  ref=refs/heads/workbench-coordination/writer-claims
  ledger="$TMPDIR/writer_zero_history/writer-claims.tsv"
  git --git-dir="$TMPDIR/writer_zero_history/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
  python3 - "$ledger" "$operation_id" "$claim" "$new_clone" <<'PY'
import sys
rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
claims = [row for row in rows if row[0] == "claim" and row[1:3] == sys.argv[2:4]]
effects = [row for row in rows if row[0] == "effect-owner" and row[2:4] == sys.argv[2:4]]
assert len(claims) == 1 and claims[0][-1] == "active"
assert len(effects) == 1 and effects[0][-1] == "acquired"
assert effects[0][5] == sys.argv[4]
PY
}

test_cleanup_retires_consumed_writer_before_local_deletion() {
  local task_dir actual operation_id claim_id ledger ref comments operation gitdir marker backup out
  local observation revision legacy_adapter
  setup_writer_workbench writer_cleanup
  printf '%s\n' 'action.task.abandon=allow' >> "$WRITER_REPO/.workbench/policy.conf"
  git -C "$WRITER_REPO" add .workbench/policy.conf
  git -C "$WRITER_REPO" commit -q -m "test: allow writer abandonment"
  git -C "$WRITER_REPO" push -q
  prepare_writer_task writer_cleanup 29 cleanup; task_dir="$WRITER_TASK_DIR"
  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_cleanup "$task_dir" add-repo shared-api --format json)"
  operation_id="$(json_get "$actual" operation_id)"; claim_id="$(json_get "$actual" claim_id)"
  operation="$task_dir/task/.workbench/writer-operations/$operation_id.json"
  assert_contains "$actual" '"operation_stage":"consumed"'
  [ -d "$task_dir/task/codebases/shared-api" ] || fail "writer cleanup fixture has no worktree"
  python3 - "$operation" "$WRITER_REPO/.codebases/shared-api" \
    "$TMPDIR/writer_cleanup/shared-api.git" <<'PY'
import hashlib
import json
import os
import subprocess
import sys

operation = json.load(open(sys.argv[1], encoding="utf-8"))
clone = sys.argv[2]
origin = sys.argv[3]
raw = subprocess.check_output(
    ["git", "-C", clone, "worktree", "list", "--porcelain", "-z"]
)
records = []
for block in raw.split(b"\0\0"):
    fields = {}
    for item in block.strip(b"\0").split(b"\0"):
        if not item:
            continue
        key, _, value = item.partition(b" ")
        fields[key.decode()] = value.decode()
    if fields.get("branch") == "refs/heads/main":
        records.append(fields)
assert len(records) == 1
path = records[0]["worktree"]
common = subprocess.check_output(
    ["git", "-C", clone, "rev-parse", "--git-common-dir"], text=True
).strip()
if not os.path.isabs(common):
    common = os.path.normpath(os.path.join(clone, common))
common = os.path.realpath(common)
manifest = (
    "workbench-worktree-set/v1\n"
    f"worktree\t{path}\trefs/heads/main\t{common}\t{origin}\n"
).encode()
expected = "sha256:" + hashlib.sha256(manifest).hexdigest()
assert operation["worktree_set_digest"] == expected, (
    operation["worktree_set_digest"], expected, manifest
)
PY
  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_cleanup "$task_dir" add-repo shared-api --format json)"
  assert_contains "$actual" '"changed":false'
  gitdir="$(git -C "$task_dir/task/codebases/shared-api" rev-parse --git-dir)"
  marker="$gitdir/workbench-writer-owner.json"; backup="$TMPDIR/writer_cleanup/owner-marker.json"
  cp "$marker" "$backup"; rm "$marker"
  out="$TMPDIR/writer_cleanup/unreconciled.out"
  if WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_cleanup "$task_dir" add-repo shared-api --format json >"$out" 2>&1; then
    fail "consumed writer retry must reject a missing ownership marker"
  fi
  assert_file_contains "$out" '"code":"writer-recovery-blocked"'
  observation="$TMPDIR/writer_cleanup/legacy-observation.json"
  revision="$(git -C "$WRITER_REPO" rev-parse origin/main)"
  write_empty_legacy_observation "$observation" "$revision" \
    "$(git -C "$WRITER_REPO" remote get-url origin)" shared-api \
    "$TMPDIR/writer_cleanup/shared-api.git"
  legacy_adapter="$TMPDIR/writer_cleanup/bin/legacy-adapter"
  write_fake_legacy_adapter "$legacy_adapter" "$observation"
  out="$TMPDIR/writer_cleanup/status-unreconciled.out"
  if WORKBENCH_TRUSTED_LEGACY_ADAPTER="$legacy_adapter" \
    run_task writer_cleanup "$WRITER_REPO" status --format json >"$out" 2>&1; then
    fail "status must fail closed for a consumed writer with no ownership marker"
  fi
  assert_file_contains "$out" '"code":"writer-claim-unreconciled"'
  assert_file_contains "$out" "\"ref\":\"${operation_id}\""
  mv "$backup" "$marker"

  actual="$(run_task_in_dir writer_cleanup "$task_dir" abandon \
    --reason-code superseded --reason-ref issue:77 --format json)"
  assert_contains "$actual" '"outcome":"abandoned"'
  git -C "$task_dir" add task
  if ! git -C "$task_dir" diff --cached --quiet; then
    git -C "$task_dir" commit -q -m "test: persist writer terminal state"
  fi
  git -C "$task_dir" push -q
  actual="$(WORKBENCH_TRUSTED_LEGACY_ADAPTER="$legacy_adapter" \
    run_task writer_cleanup "$WRITER_REPO" status --format json)"
  assert_contains "$actual" "\"claim_id\":\"$(sed -n 's/^claim_id: *//p' "$task_dir/task/index.md")\""
  assert_contains "$actual" '"task_contract":"workbench-task/v2"'

  actual="$(run_task writer_cleanup "$WRITER_REPO" done 29 --format json)"
  assert_contains "$actual" '"outcome":"cleaned"'
  assert_contains "$actual" "\"released_writer_operations\":[{\"operation_id\":\"$operation_id\",\"claim_id\":\"$claim_id\"}]"
  [ ! -d "$task_dir" ] || fail "writer cleanup retained the task workspace"

  ref=refs/heads/workbench-coordination/writer-claims
  ledger="$TMPDIR/writer_cleanup/writer-claims.tsv"
  git --git-dir="$TMPDIR/writer_cleanup/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
  python3 - "$ledger" "$operation_id" "$claim_id" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
claims = [row for row in rows if row[0] == "claim" and row[1:3] == sys.argv[2:4]]
effects = [row for row in rows if row[0] == "effect-owner" and row[2:4] == sys.argv[2:4]]
assert [row[-1] for row in claims] == ["active", "released"]
assert [row[-1] for row in effects] == ["acquired", "released"]
assert effects[0][4:6] == effects[1][4:6]
PY
  comments="$TMPDIR/writer_cleanup/comments/29.comments"
  python3 - "$comments" "$operation_id" "$claim_id" <<'PY'
import json
import re
import sys

documents = [
    json.loads(raw)
    for raw in re.findall(r"<!-- workbench-task-cleanup:v1\n([^\r\n]+)\n-->", open(sys.argv[1], encoding="utf-8").read())
]
assert documents[0]["stage"] == "prepared"
assert documents[-1]["stage"] == "completed"
events = documents[-1]["effect_owner_events"]
assert [(item["state"], item["phase"]) for item in events] == [
    ("acquired", "intended"), ("acquired", "verified"),
    ("released", "intended"), ("released", "verified"),
]
assert all(item["operation_id"] == sys.argv[2] and item["claim_id"] == sys.argv[3] for item in events)
for previous, current in zip(documents, documents[1:]):
    assert current["effect_owner_events"][:len(previous["effect_owner_events"])] == previous["effect_owner_events"]
PY
}

test_status_reports_concurrent_writer_conflicts() {
  local repo first second actual observation revision legacy_adapter
  setup_writer_workbench writer_conflicts
  repo="$WRITER_REPO"
  prepare_writer_task writer_conflicts 29 a; first="$WRITER_TASK_DIR"
  prepare_writer_task writer_conflicts 31 b; second="$WRITER_TASK_DIR"
  WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
  WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_conflicts "$first" add-repo shared-api --format json >/dev/null
  WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
  WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_conflicts "$second" add-repo shared-api --format json >/dev/null

  revision="$(git -C "$repo" rev-parse origin/main)"
  observation="$TMPDIR/writer_conflicts/legacy-observation.json"
  write_empty_legacy_observation "$observation" "$revision" \
    "$(git -C "$repo" remote get-url origin)" shared-api \
    "$TMPDIR/writer_conflicts/shared-api.git"
  legacy_adapter="$TMPDIR/writer_conflicts/bin/legacy-adapter"
  write_fake_legacy_adapter "$legacy_adapter" "$observation"

  actual="$(WORKBENCH_TRUSTED_LEGACY_ADAPTER="$legacy_adapter" \
    run_task writer_conflicts "$repo" status --format json)"
  python3 - "$actual" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])
assert list(value) == [
    "contract_version", "tasks", "writer_conflicts", "writer_integrity_blockers",
]
assert value["contract_version"] == "workbench-task-status/v2"
assert value["writer_integrity_blockers"] == []
assert len(value["tasks"]) == 2
assert all(item["work_owners"] == ["shared-api"] for item in value["tasks"])
assert len(value["writer_conflicts"]) == 1
conflict = value["writer_conflicts"][0]
assert list(conflict) == ["owner", "claims"] and conflict["owner"] == "shared-api"
claims = conflict["claims"]
assert len(claims) == 2
assert all(list(item) == [
    "source", "claim_id", "operation_id", "task_claim_id", "owner", "branch",
    "context_policy_set_digest", "source_revision", "pr_head_revision", "lifecycle_digest",
] for item in claims)
assert all(item["source"] == "ledger-v2" for item in claims)
assert len({item["claim_id"] for item in claims}) == 2
assert len({item["operation_id"] for item in claims}) == 2
assert [item["branch"] for item in claims] == [
    "task/29-v2-lifecycle-fixture-29", "task/31-v2-lifecycle-fixture-31",
]
PY
}

run_case() {
  local name="$1"
  [ -z "${WORKBENCH_TEST_FILTER:-}" ] || [ "$WORKBENCH_TEST_FILTER" = "$name" ] || return 0
  "$name"
}

run_case test_v1_rejects_v2_mutation_but_keeps_legacy_start
run_case test_start_rejects_noncanonical_schema_slug_and_home
run_case test_v2_start_and_resume_are_authority_bound_skeletons
run_case test_refs_are_opaque_and_duplicate_active_work_is_rejected
run_case test_deliverables_and_revision_bound_evidence
run_case test_kernel_probe_acceptance_is_revision_and_owner_bound
run_case test_accepted_deliverable_revision_reset_preserves_append_only_receipts
run_case test_pack_deliverable_owner_binding_is_immutable_and_authorized
run_case test_pack_acceptance_recovers_from_durable_primary
run_case test_deliverable_governed_effect_is_single_bound_reasoned_and_resettable
run_case test_required_check_waive_is_reasoned_revision_bound_and_idempotent
run_case test_policy_context_is_owner_authorized_sealed_and_manifest_bound
run_case test_null_context_lazy_seal_and_frozen_action_registry
run_case test_submitted_and_failed_deliverables_block_verification
run_case test_harvest_ledger_is_explicit_sealed_and_governed
run_case test_codebase_only_completion_is_policy_gated_and_cleanup_safe
run_case test_abandonment_is_terminal_and_distinct_from_cleanup
run_case test_terminal_outcome_freezes_mutations_and_verification_is_read_only
run_case test_cleanup_prepared_journal_failure_deletes_nothing
run_case test_cleanup_journal_recovers_completed_and_lifecycle_after_deletion
run_case test_v2_cleanup_requires_terminal_outcome_even_with_force
run_case test_writer_claim_cas_retry_rechecks_conflict_before_local_creation
run_case test_writer_local_failure_releases_remote_claim_before_new_id
run_case test_writer_binds_protected_registry_and_rejects_cache_origin
run_case test_writer_conflict_uses_complete_legacy_and_v2_union
run_case test_writer_zero_history_recovery_rebinds_before_once_only_owner_acquire
run_case test_cleanup_retires_consumed_writer_before_local_deletion
run_case test_status_reports_concurrent_writer_conflicts

[ "$SOURCE_HEAD" = "$(git -C "$SOURCE_REPO" rev-parse HEAD)" ] || fail "test committed in source repo"
[ "$SOURCE_STATUS" = "$(git -C "$SOURCE_REPO" status --porcelain=v1)" ] || fail "test modified source repo"

echo "PASS workbench v2 task lifecycle tests"
