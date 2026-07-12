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
LIFECYCLE_HELPER="$PLUGIN_ROOT/lib/workbench_lifecycle.py"
TIME_HELPER="$PLUGIN_ROOT/lib/workbench_time.py"
LEGACY_UTIL="$PLUGIN_ROOT/utils/legacy-inventory"
SCAFFOLD_TEMPLATES="$(cd "$PLUGIN_ROOT/../workbench-kit/scaffold/templates" && pwd)"
TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/workbench-task-v2.XXXXXX")"
cleanup() {
  local rc=$?
  trap - EXIT
  if [ "${WORKBENCH_TEST_KEEP_TMP:-0}" = 1 ]; then
    printf 'preserved test tmpdir: %s\n' "$TMPDIR" >&2
  else
    rm -rf "$TMPDIR"
  fi
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
    if [ -n "${GH_FAIL_LIFECYCLE_EVENT:-}" ] \
      && grep -Fq "\"event\":\"$GH_FAIL_LIFECYCLE_EVENT\"" "$body_file"; then
      exit 43
    fi
    {
      printf '%s\n' '<!-- fixture-comment-author:test@example.invalid -->'
      cat "$body_file"
      printf '%s\n' '<!-- fixture-comment-end -->'
    } >> "$GH_COMMENTS_DIR/$issue.comments"
    if [ -n "${GH_CLEANUP_RACE_DIRTY_WORKTREE:-}" ] \
      && grep -Fq '"stage":"prepared"' "$body_file"; then
      printf '%s\n' dirty-after-prepared > "$GH_CLEANUP_RACE_DIRTY_WORKTREE/RACE.txt"
    fi
    if [ -n "${GH_CLEANUP_RACE_SYMLINK_WORKTREE:-}" ] \
      && [ -n "${GH_CLEANUP_RACE_SYMLINK_TARGET:-}" ] \
      && grep -Fq '"stage":"prepared"' "$body_file"; then
      mv "$GH_CLEANUP_RACE_SYMLINK_WORKTREE" \
        "$GH_CLEANUP_RACE_SYMLINK_WORKTREE.original"
      ln -s "$GH_CLEANUP_RACE_SYMLINK_TARGET" "$GH_CLEANUP_RACE_SYMLINK_WORKTREE"
    fi
    ;;
  "pr view")
    if [[ "$*" == *"--json state,headRefOid,mergeCommit"* ]]; then
      printf '%s\t%s\t%s\n' "${GH_PR_STATE:-MERGED}" "${GH_PR_HEAD:-abc123}" "${GH_PR_MERGE:-merge789}"
    else
      [ -f "$GH_COMMENTS_DIR/pr-17.json" ] || exit 1
      cat "$GH_COMMENTS_DIR/pr-17.json"
    fi
    ;;
  "pr create")
    head=""; base=""; shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --head) head="$2"; shift 2 ;;
        --base) base="$2"; shift 2 ;;
        --title|--body-file) shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$head" ] && [ -n "$base" ] || exit 9
    head_oid="$(git rev-parse HEAD)"
    mkdir -p "$GH_COMMENTS_DIR"
    python3 - "$GH_COMMENTS_DIR/pr-17.json" "$head" "$head_oid" "$base" <<'PY'
import json
import sys

value = {
    "number": 17,
    "url": "https://github.com/example/workbench/pull/17",
    "headRefName": sys.argv[2],
    "headRefOid": sys.argv[3],
    "baseRefName": sys.argv[4],
    "state": "OPEN",
    "merged": False,
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
    printf '%s\n' 'https://github.com/example/workbench/pull/17'
    ;;
  "pr list")
    if [ -f "$GH_COMMENTS_DIR/pr-17.json" ]; then
      python3 - "$GH_COMMENTS_DIR/pr-17.json" <<'PY'
import json
import sys
print(json.dumps([json.load(open(sys.argv[1], encoding="utf-8"))], separators=(",", ":")))
PY
    else printf '[]\n'; fi
    ;;
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
[ -n "${1:-}" ] || exit 2
command="$1"
shift
authority="" revision="" default_ref="" issue="" repository="" head_branch="" head_revision="" legacy_inventory=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --authority-file) authority="$2"; shift 2 ;;
    --default-revision) revision="$2"; shift 2 ;;
    --default-ref) default_ref="$2"; shift 2 ;;
    --issue) issue="$2"; shift 2 ;;
    --repository) repository="$2"; shift 2 ;;
    --head-branch) head_branch="$2"; shift 2 ;;
    --head-revision) head_revision="$2"; shift 2 ;;
    --legacy-inventory-file) legacy_inventory="$2"; shift 2 ;;
    --format) [ "$2" = json ]; shift 2 ;;
    *) exit 2 ;;
  esac
done
if [ "$command" = active-tasks ]; then
  if [ -n "${WORKBENCH_TEST_ACTIVE_TASK_OBSERVATION:-}" ]; then
    cat "$WORKBENCH_TEST_ACTIVE_TASK_OBSERVATION"
    exit
  fi
  python3 - "$repository" "$legacy_inventory" "${GH_COMMENTS_DIR:-}" "$default_ref" <<'PY'
import json
import pathlib
import re
import subprocess
import sys

repository = pathlib.Path(sys.argv[1])
legacy = json.load(open(sys.argv[2], encoding="utf-8"))
comments_dir = pathlib.Path(sys.argv[3])
origin = subprocess.check_output(
    ["git", "-C", str(repository), "remote", "get-url", "origin"], text=True
).strip()
pagination = {"complete": True, "pages_fetched": 1, "end_cursor": None, "failure": None}
homes = [
    {
        "home": item["home"],
        "origin_url": item["origin_url"],
        "membership": item["membership"],
        "issue_pagination": pagination,
        "issues": [],
    }
    for item in legacy["homes"]
]
by_home = {item["home"]: item for item in homes}
workspace_home = next(
    item["home"] for item in homes if item["origin_url"] == origin
)
comment_paths = [path for path in comments_dir.glob("*.comments") if path.stem.isdigit()]
for path in sorted(comment_paths, key=lambda item: int(item.stem)):
    body = path.read_text(encoding="utf-8")
    marker_homes = {
        json.loads(raw)["home"]
        for raw in re.findall(
            r"<!-- workbench-task-lifecycle:v2\n([^\r\n]+)\n-->", body
        )
    }
    if not marker_homes:
        continue
    if len(marker_homes) != 1:
        raise SystemExit("fixture issue spans multiple homes")
    marker_home = marker_homes.pop()
    home = workspace_home if marker_home is None else marker_home
    fixture_comments = list(re.finditer(
        r"<!-- fixture-comment-author:([^\r\n ]+) -->\n(.*?)<!-- fixture-comment-end -->\n?",
        body,
        re.DOTALL,
    ))
    trusted_body = re.sub(
        r"<!-- fixture-comment-author:[^\r\n ]+ -->\n.*?<!-- fixture-comment-end -->\n?",
        "",
        body,
        flags=re.DOTALL,
    )
    observed = []
    if trusted_body.strip():
        observed.append({"author_identity": "test@example.invalid", "body": trusted_body})
    observed.extend(
        {"author_identity": match.group(1), "body": match.group(2)}
        for match in fixture_comments
    )
    by_home[home]["issues"].append({
        "number": int(path.stem),
        "lifecycle_pagination": pagination,
        "comments": observed,
    })
pull_requests = []
stored = comments_dir / "pr-17.json"
if stored.exists():
    item = json.load(open(stored, encoding="utf-8"))
    pull_requests.append({
        "number": item["number"],
        "url": item["url"],
        "head_branch": item["headRefName"],
        "head_revision": item["headRefOid"],
        "head_repository_origin_url": origin,
        "head_is_fork": False,
        "base_ref": item["baseRefName"],
        "state": "merged" if item["merged"] else "open",
    })
value = {
    "contract_version": "workbench-hosting-active-task-observation/v1",
    "workspace_origin_url": origin,
    "workspace_home": workspace_home,
    "default_ref": sys.argv[4],
    "default_revision": legacy["source_revision"],
    "home_pagination": pagination,
    "pr_pagination": pagination,
    "homes": homes,
    "pull_requests": pull_requests,
}
print(json.dumps(value, separators=(",", ":")))
PY
  exit
fi
if [ "$command" = lifecycle ]; then
  if [ -n "${WORKBENCH_TEST_LIFECYCLE_OBSERVATION:-}" ]; then
    cat "$WORKBENCH_TEST_LIFECYCLE_OBSERVATION"
    exit
  fi
  python3 - "$repository" "$issue" "${GH_COMMENTS_DIR:-}/$issue.comments" <<'PY'
import json
import pathlib
import re
import subprocess
import sys

repository = pathlib.Path(sys.argv[1])
origin = subprocess.check_output(
    ["git", "-C", str(repository), "remote", "get-url", "origin"], text=True
).strip()
comments = pathlib.Path(sys.argv[3])
body = comments.read_text(encoding="utf-8") if comments.exists() else ""
fixture_comments = list(re.finditer(
    r"<!-- fixture-comment-author:([^\r\n ]+) -->\n(.*?)<!-- fixture-comment-end -->\n?",
    body,
    re.DOTALL,
))
trusted_body = re.sub(
    r"<!-- fixture-comment-author:[^\r\n ]+ -->\n.*?<!-- fixture-comment-end -->\n?",
    "",
    body,
    flags=re.DOTALL,
)
observed_comments = []
if trusted_body.strip():
    observed_comments.append({"author_identity": "test@example.invalid", "body": trusted_body})
observed_comments.extend(
    {"author_identity": match.group(1), "body": match.group(2)}
    for match in fixture_comments
)
value = {
    "contract_version": "workbench-hosting-lifecycle-observation/v1",
    "repository_origin_url": origin,
    "issue": int(sys.argv[2]),
    "pagination": {"complete": True, "pages_fetched": 1, "end_cursor": None, "failure": None},
    "comments": observed_comments,
}
print(json.dumps(value, separators=(",", ":")))
PY
  exit
fi
if [ "$command" = submission ]; then
  if [ -n "${WORKBENCH_TEST_SUBMISSION_OBSERVATION:-}" ]; then
    cat "$WORKBENCH_TEST_SUBMISSION_OBSERVATION"
    exit
  fi
  python3 - "$repository" "$head_branch" "$head_revision" "${GH_COMMENTS_DIR:-}/pr-17.json" "$default_ref" <<'PY'
import json
import pathlib
import subprocess
import sys

repository = pathlib.Path(sys.argv[1])
origin = subprocess.check_output(
    ["git", "-C", str(repository), "remote", "get-url", "origin"], text=True
).strip()
stored = pathlib.Path(sys.argv[4])
pull_requests = []
if stored.exists():
    item = json.load(open(stored, encoding="utf-8"))
    pull_requests.append({
        "number": item["number"],
        "url": item["url"],
        "head_branch": item["headRefName"],
        "head_revision": item["headRefOid"],
        "head_repository_origin_url": origin,
        "head_is_fork": False,
        "base_ref": item["baseRefName"],
        "state": "merged" if item["merged"] else "open",
    })
value = {
    "contract_version": "workbench-hosting-submission-observation/v1",
    "repository_origin_url": origin,
    "head_branch": sys.argv[2],
    "base_ref": sys.argv[5],
    "pagination": {"complete": True, "pages_fetched": 1, "end_cursor": None, "failure": None},
    "pull_requests": pull_requests,
}
print(json.dumps(value, separators=(",", ":")))
PY
  exit
fi
[ "$command" = authority ] || exit 2
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
  cp "$LIFECYCLE_HELPER" "$repo/lib/workbench_lifecycle.py"
  cp "$TIME_HELPER" "$repo/lib/workbench_time.py"
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
    WORKBENCH_TEST_ACTIVE_TASK_OBSERVATION="${WORKBENCH_TEST_ACTIVE_TASK_OBSERVATION:-}" \
    WORKBENCH_TEST_FAIL_AFTER_ACCEPTANCE_PRIMARY="${WORKBENCH_TEST_FAIL_AFTER_ACCEPTANCE_PRIMARY:-0}" \
    WORKBENCH_TEST_FAIL_AFTER_ACCEPTANCE_ATTEMPT="${WORKBENCH_TEST_FAIL_AFTER_ACCEPTANCE_ATTEMPT:-0}" \
    WORKBENCH_TEST_FAIL_AFTER_ACCEPTANCE_PROBE="${WORKBENCH_TEST_FAIL_AFTER_ACCEPTANCE_PROBE:-0}" \
    WORKBENCH_TEST_FAIL_AFTER_CONTEXT_PRIMARY="${WORKBENCH_TEST_FAIL_AFTER_CONTEXT_PRIMARY:-}" \
    WORKBENCH_TEST_FAIL_AFTER_WRITER_CLAIM="${WORKBENCH_TEST_FAIL_AFTER_WRITER_CLAIM:-0}" \
    WORKBENCH_TEST_FAIL_WRITER_STAGE="${WORKBENCH_TEST_FAIL_WRITER_STAGE:-}" \
    WORKBENCH_TEST_FAIL_AFTER_WRITER_ROOT="${WORKBENCH_TEST_FAIL_AFTER_WRITER_ROOT:-0}" \
    WORKBENCH_TEST_FAIL_SUBMISSION_STAGE="${WORKBENCH_TEST_FAIL_SUBMISSION_STAGE:-}" \
    WORKBENCH_TEST_SUBMISSION_OBSERVATION="${WORKBENCH_TEST_SUBMISSION_OBSERVATION:-}" \
    WORKBENCH_TEST_LIFECYCLE_OBSERVATION="${WORKBENCH_TEST_LIFECYCLE_OBSERVATION:-}" \
    WORKBENCH_TEST_GOVERNED_FINAL_HOOK="${WORKBENCH_TEST_GOVERNED_FINAL_HOOK:-}" \
    WORKBENCH_TEST_CLEANUP_DESCRIPTOR_HOOK="${WORKBENCH_TEST_CLEANUP_DESCRIPTOR_HOOK:-}" \
    GH_FAIL_LIFECYCLE_EVENT="${GH_FAIL_LIFECYCLE_EVENT:-}" \
    GH_FAIL_CLEANUP_STAGE="${GH_FAIL_CLEANUP_STAGE:-}" \
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

prepare_submission_fixture() {
  local case_name="$1" completion="${2:-false}" cleanup_decision="${3:-allow}"
  local terminal_action="${4:-complete}"
  SUBMISSION_REPO="$(setup_workbench "$case_name")"
  if [ "$completion" = true ]; then
    printf '%s\n' \
      'schema=workbench-policy/v1' \
      "action.task.$terminal_action=allow" \
      "action.task.cleanup=$cleanup_decision" > "$SUBMISSION_REPO/.workbench/policy.conf"
  fi
  printf '%s\n' 'kit: https://github.com/example/workbench.git' \
    > "$SUBMISSION_REPO/codebases.yaml"
  git -C "$SUBMISSION_REPO" add .workbench/policy.conf codebases.yaml
  git -C "$SUBMISSION_REPO" commit -q -m "test: register submission owner"
  git -C "$SUBMISSION_REPO" push -q
  SUBMISSION_TASK_DIR="$(start_task "$case_name" "$SUBMISSION_REPO")"
  run_task_in_dir "$case_name" "$SUBMISSION_TASK_DIR" policy-context seal \
    --format json >/dev/null
  run_task_in_dir "$case_name" "$SUBMISSION_TASK_DIR" deliverable declare \
    --id workbench-pr --owner kit --kind workbench-increment --format json >/dev/null
  run_task_in_dir "$case_name" "$SUBMISSION_TASK_DIR" harvest seal --format json >/dev/null
  mkdir -p "$SUBMISSION_TASK_DIR/docs"
  printf '%s\n' "# $case_name increment" > "$SUBMISSION_TASK_DIR/docs/increment.md"
  printf '\n## [2026-07-12 13:00:00] code · create docs/increment.md | %s\n' "$case_name" \
    >> "$SUBMISSION_TASK_DIR/task/log.md"
  printf '%s\n' '# Status' '' "상태: $case_name ready" \
    > "$SUBMISSION_TASK_DIR/task/status.md"
  git -C "$SUBMISSION_TASK_DIR" add docs/increment.md task
  git -C "$SUBMISSION_TASK_DIR" commit -q -m "feat: add $case_name increment"
  git -C "$SUBMISSION_TASK_DIR" push -q
  SUBMISSION_SNAPSHOT="$(git -C "$SUBMISSION_TASK_DIR" rev-parse HEAD)"
  SUBMISSION_BODY="$TMPDIR/$case_name/pr-body.md"
  printf '%s\n' "$case_name fixture PR" > "$SUBMISSION_BODY"
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

append_forged_cleanup_journal() {
  local comments="$1" claim="$2" branch="$3" author="$4"
  python3 - "$comments" "$claim" "$branch" "$author" <<'PY'
import hashlib
import json
import sys

comments, claim, branch, author = sys.argv[1:]
plan = {
    "writer_operations": [],
    "codebase_worktrees": [],
    "task_workspace": ".worktrees/task__29-v2-lifecycle-fixture-29",
    "local_branch": branch,
}
manifest = (
    "workbench-task-removal-plan/v1\n"
    "task_id\t29\n"
    "claim_id\t{}\n"
    "task_branch\t{}\n"
    "task_workspace\t{}\n"
    "local_branch\t{}\n"
).format(claim, branch, plan["task_workspace"], branch).encode()
digest = "sha256:" + hashlib.sha256(manifest).hexdigest()
value = {
    "contract_version": "workbench-task-cleanup-journal/v1",
    "journal_id": "cleanup-" + claim,
    "stage": "prepared",
    "task_id": "29",
    "claim_id": claim,
    "branch": branch,
    "revision": "sha256:" + "a" * 64,
    "action_instance_id": "act_attacker_cleanup",
    "intent_digest": "sha256:" + "b" * 64,
    "policy_manifest": {
        "contract_version": "workbench-policy-manifest/v1",
        "digest": "sha256:" + "c" * 64,
        "sources": [],
    },
    "authorization_ref": None,
    "removal_plan_digest": digest,
    "removal_plan": plan,
    "effect_owner_events": [],
    "at": "2026-07-11T00:00:00Z",
}
with open(comments, "a", encoding="utf-8") as handle:
    handle.write("<!-- fixture-comment-author:{} -->\n".format(author))
    handle.write("<!-- workbench-task-cleanup:v1\n")
    handle.write(json.dumps(value, separators=(",", ":")) + "\n")
    handle.write("-->\nworkbench task cleanup: prepared\n")
    handle.write("<!-- fixture-comment-end -->\n")
PY
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

write_context_registration() {
  local file="$1" claim="$2" context_ref="$3" policy_ref="$4" policy_digest="$5"
  local registration_id="$6" actor="$7" registered_at="$8"
  python3 - "$file" "$claim" "$context_ref" "$policy_ref" "$policy_digest" \
    "$registration_id" "$actor" "$registered_at" <<'PY'
import json
import sys

path, claim, context_ref, policy_ref, policy_digest, registration_id, actor, registered_at = sys.argv[1:]
authority_ref = "toolbox:policy/" + context_ref.rsplit("/", 1)[-1]
receipt = {
    "contract_version": "workbench-policy-authority-receipt/v1",
    "authority_identity": "toolbox:authority/product-owner",
    "authority_ref": authority_ref,
    "authority_revision": "sha256:" + "a" * 64,
    "policy_ref": policy_ref,
    "policy_digest": policy_digest,
    "actor": actor,
    "issued_at": registered_at,
    "source_ref": "toolbox:approval/" + registration_id,
}
value = {
    "contract_version": "workbench-context-policy-registration/v1",
    "registration_id": registration_id,
    "task_claim_id": claim,
    "task_context_ref": context_ref,
    "participants": [{
        "context_ref": context_ref,
        "policy_ref": policy_ref,
        "policy_digest": policy_digest,
        "authority_ref": authority_ref,
        "authority_receipt": receipt,
    }],
    "task_policy": None,
    "actor": actor,
    "registered_at": registered_at,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
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

replace_writer_context() {
  local task_dir="$1" label="$2" decision="$3" claim policy digest registration output
  local set_digest registration_ref registration_digest state
  claim="$(sed -n 's/^claim_id: *//p' "$task_dir/task/index.md")"
  python3 - "$task_dir/task/index.md" "$label" <<'PY'
import sys

path, label = sys.argv[1:]
rows = open(path, encoding="utf-8").read().splitlines()
for index, row in enumerate(rows):
    if row.startswith("context_ref:"):
        rows[index] = "context_ref: toolbox:product/" + label
        break
else:
    closing = rows.index("---", 1)
    rows.insert(closing, "context_ref: toolbox:product/" + label)
with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(rows) + "\n")
PY
  mkdir -p "$task_dir/contexts" "$task_dir/task/.workbench/policy-context"
  policy="$task_dir/contexts/$label.policy"
  printf '%s\n' 'schema=workbench-policy/v1' "action.task.concurrent-write=$decision" > "$policy"
  digest="sha256:$(python3 - "$policy" <<'PY'
import hashlib
import sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)"
  registration="$task_dir/task/.workbench/policy-context/registration.json"
  python3 - "$registration" "$claim" "$label" "$digest" <<'PY'
import json
import sys

receipt = {
    "contract_version": "workbench-policy-authority-receipt/v1",
    "authority_identity": "toolbox:authority/" + sys.argv[3],
    "authority_ref": "toolbox:policy/" + sys.argv[3],
    "authority_revision": "sha256:" + "a" * 64,
    "policy_ref": "contexts/" + sys.argv[3] + ".policy",
    "policy_digest": sys.argv[4],
    "actor": "owner@example.com",
    "issued_at": "2026-07-11T05:00:00Z",
    "source_ref": "toolbox:approval/" + sys.argv[3],
}
value = {
    "contract_version": "workbench-context-policy-registration/v1",
    "registration_id": "ctxreg-" + sys.argv[3],
    "task_claim_id": sys.argv[2],
    "task_context_ref": "toolbox:product/" + sys.argv[3],
    "participants": [{
        "context_ref": "toolbox:product/" + sys.argv[3],
        "policy_ref": "contexts/" + sys.argv[3] + ".policy",
        "policy_digest": sys.argv[4],
        "authority_ref": "toolbox:policy/" + sys.argv[3],
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
  output="$(python3 "$CONTRACT_HELPER" context-set --registration-file "$registration" \
    --workspace-root "$task_dir" --sealed true --changed true --format shell)"
  set_digest="$(printf '%s\n' "$output" | sed -n 's/^digest=//p')"
  registration_ref="$(printf '%s\n' "$output" | sed -n 's/^registration_ref=//p')"
  registration_digest="$(printf '%s\n' "$output" | sed -n 's/^registration_digest=//p')"
  state="$task_dir/task/.workbench/policy-context/state.record"
  {
    printf 'registration_ref=%s\n' "$registration_ref"
    printf 'registration_digest=%s\n' "$registration_digest"
    printf 'task_context_ref=toolbox:product/%s\n' "$label"
    printf 'sealed=true\n'
    printf 'digest=%s\n' "$set_digest"
    printf 'registration_action_instance_id=\nregistration_intent_digest=\n'
    printf 'registration_policy_manifest_digest=\nregistration_authorization_ref=\n'
    printf 'seal_action_instance_id=\nseal_intent_digest=\nseal_policy_manifest_digest=\n'
    printf 'seal_authorization_ref=\nregistered_at=2026-07-11T05:01:00Z\n'
    printf 'sealed_at=2026-07-11T05:02:00Z\n'
  } > "$state"
  git -C "$task_dir" add task/index.md task/.workbench contexts
  git -C "$task_dir" commit -q -m "test: bind $label writer context"
  git -C "$task_dir" push -q
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

corrupt_writer_coordination_history() {
  local case_name="$1" mode="$2" ref tip ledger blob tree commit side
  ref=refs/heads/workbench-coordination/writer-claims
  tip="$(git --git-dir="$TMPDIR/$case_name/origin.git" rev-parse "$ref")"
  ledger="$TMPDIR/$case_name/corrupt-writer-claims.tsv"
  git --git-dir="$TMPDIR/$case_name/origin.git" show "$tip:writer-claims.tsv" > "$ledger"
  case "$mode" in
    rewritten-tip)
      tree="$(git -C "$WRITER_REPO" rev-parse "$tip^{tree}")"
      commit="$(printf '%s\n' 'test: rewrite valid-looking writer tip' \
        | git -C "$WRITER_REPO" commit-tree "$tree" -p "$tip")"
      ;;
    valid-rebuild)
      local rebuilt parent prefix row
      rebuilt="$TMPDIR/$case_name/rebuilt-writer-claims.tsv"
      printf '%s\n' workbench-writer-claims/v1 > "$rebuilt"
      blob="$(git -C "$WRITER_REPO" hash-object -w "$rebuilt")"
      tree="$(printf '100644 blob %s\twriter-claims.tsv\n' "$blob" \
        | git -C "$WRITER_REPO" mktree)"
      parent="$(printf '%s\n' 'test: rebuilt writer root' \
        | git -C "$WRITER_REPO" commit-tree "$tree")"
      while IFS= read -r row; do
        [ "$row" = workbench-writer-claims/v1 ] && continue
        printf '%s\n' "$row" >> "$rebuilt"
        blob="$(git -C "$WRITER_REPO" hash-object -w "$rebuilt")"
        tree="$(printf '100644 blob %s\twriter-claims.tsv\n' "$blob" \
          | git -C "$WRITER_REPO" mktree)"
        parent="$(printf '%s\n' 'test: rebuild legal writer event' \
          | git -C "$WRITER_REPO" commit-tree "$tree" -p "$parent")"
      done < "$ledger"
      commit="$parent"
      ;;
    new-root)
      tree="$(git -C "$WRITER_REPO" rev-parse "$tip^{tree}")"
      commit="$(printf '%s\n' 'test: replace writer history root' \
        | git -C "$WRITER_REPO" commit-tree "$tree")"
      ;;
    row-removal)
      printf '%s\n' workbench-writer-claims/v1 > "$ledger"
      blob="$(git -C "$WRITER_REPO" hash-object -w "$ledger")"
      tree="$(printf '100644 blob %s\twriter-claims.tsv\n' "$blob" \
        | git -C "$WRITER_REPO" mktree)"
      commit="$(printf '%s\n' 'test: remove writer rows' \
        | git -C "$WRITER_REPO" commit-tree "$tree" -p "$tip")"
      ;;
    historical-rewrite)
      python3 - "$ledger" <<'PY'
import sys

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines()
for index, line in enumerate(lines):
    fields = line.split("\t")
    if fields[0] == "claim" and fields[-1] == "active":
        fields[4] = "alternate-api"
        lines[index] = "\t".join(fields)
        break
else:
    raise AssertionError("missing active claim")
with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
PY
      blob="$(git -C "$WRITER_REPO" hash-object -w "$ledger")"
      tree="$(printf '100644 blob %s\twriter-claims.tsv\n' "$blob" \
        | git -C "$WRITER_REPO" mktree)"
      commit="$(printf '%s\n' 'test: rewrite historical writer row' \
        | git -C "$WRITER_REPO" commit-tree "$tree" -p "$tip")"
      ;;
    discontinuous-event)
      python3 - "$ledger" <<'PY'
import sys

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines()
events = [line.split("\t") for line in lines if line.startswith("effect-owner\t")]
assert events and events[-1][-1] == "acquired", events
last = events[-1]
lines.extend((
    "\t".join(("effect-owner", "event_zz_release", last[2], last[3], last[4], last[5], "released")),
    "\t".join(("effect-owner", "event_zzzz_acquire", last[2], last[3], last[4], last[5], "acquired")),
))
with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
PY
      blob="$(git -C "$WRITER_REPO" hash-object -w "$ledger")"
      tree="$(printf '100644 blob %s\twriter-claims.tsv\n' "$blob" \
        | git -C "$WRITER_REPO" mktree)"
      commit="$(printf '%s\n' 'test: append discontinuous writer events' \
        | git -C "$WRITER_REPO" commit-tree "$tree" -p "$tip")"
      ;;
    extra-tree-entry)
      blob="$(printf '%s\n' unexpected | git -C "$WRITER_REPO" hash-object -w --stdin)"
      tree="$({
        git -C "$WRITER_REPO" ls-tree "$tip"
        printf '100644 blob %s\textra.txt\n' "$blob"
      } | git -C "$WRITER_REPO" mktree)"
      commit="$(printf '%s\n' 'test: add extra writer tree entry' \
        | git -C "$WRITER_REPO" commit-tree "$tree" -p "$tip")"
      ;;
    operation-id-reuse|claim-id-reuse|global-event-id-reuse)
      local first_claim first_effect next_ledger first_commit reused_operation reused_claim
      first_claim="$(sed -n '/^claim\t/{p;q;}' "$ledger")"
      first_effect="$(sed -n '/^effect-owner\t/{p;q;}' "$ledger")"
      next_ledger="$TMPDIR/$case_name/reused-writer-claims.tsv"
      python3 - "$ledger" "$next_ledger" "$mode" <<'PY'
import sys

source, output, mode = sys.argv[1:]
lines = open(source, encoding="utf-8").read().splitlines()
claims = [line.split("\t") for line in lines[1:] if line.startswith("claim\t")]
effects = [line.split("\t") for line in lines[1:] if line.startswith("effect-owner\t")]
assert len(claims) == 1 and len(effects) == 1
row = list(claims[0])
if mode != "operation-id-reuse":
    row[1] = "wop_reused_identity"
if mode != "claim-id-reuse":
    row[2] = "wc_reused_identity"
row[3] = "task__reused_identity"
row[4] = "zz-api"
row[5] = "task/99-reused-identity"
row[6] = "task/codebases/zz-api"
claims.append(row)
claims.sort(key=lambda item: (item[4], item[3], item[1], item[2], 0 if item[-1] == "active" else 1))
with open(output, "w", encoding="utf-8") as handle:
    handle.write(lines[0] + "\n")
    for item in claims:
        handle.write("\t".join(item) + "\n")
    for item in effects:
        handle.write("\t".join(item) + "\n")
PY
      blob="$(git -C "$WRITER_REPO" hash-object -w "$next_ledger")"
      tree="$(printf '100644 blob %s\twriter-claims.tsv\n' "$blob" \
        | git -C "$WRITER_REPO" mktree)"
      first_commit="$(printf '%s\n' 'test: append reused writer identity' \
        | git -C "$WRITER_REPO" commit-tree "$tree" -p "$tip")"
      if [ "$mode" = global-event-id-reuse ]; then
        reused_operation="$(sed -n '2p' "$next_ledger" | cut -f2)"
        reused_claim="$(sed -n '2p' "$next_ledger" | cut -f3)"
        case "$(sed -n '2p' "$next_ledger" | cut -f4)" in
          task__reused_identity) ;;
          *) reused_operation="$(sed -n '3p' "$next_ledger" | cut -f2)"; reused_claim="$(sed -n '3p' "$next_ledger" | cut -f3)" ;;
        esac
        printf 'effect-owner\t%s\t%s\t%s\t%s\t%s\tacquired\n' \
          "$(printf '%s\n' "$first_effect" | cut -f2)" "$reused_operation" "$reused_claim" \
          "$(printf '%s\n' "$first_effect" | cut -f5)" \
          "$(printf '%s\n' "$first_effect" | cut -f6)" >> "$next_ledger"
        blob="$(git -C "$WRITER_REPO" hash-object -w "$next_ledger")"
        tree="$(printf '100644 blob %s\twriter-claims.tsv\n' "$blob" \
          | git -C "$WRITER_REPO" mktree)"
        commit="$(printf '%s\n' 'test: reuse global writer event ID' \
          | git -C "$WRITER_REPO" commit-tree "$tree" -p "$first_commit")"
      else
        commit="$first_commit"
      fi
      ;;
    merge)
      printf '%s\n' workbench-writer-claims/v1 > "$ledger"
      blob="$(git -C "$WRITER_REPO" hash-object -w "$ledger")"
      tree="$(printf '100644 blob %s\twriter-claims.tsv\n' "$blob" \
        | git -C "$WRITER_REPO" mktree)"
      side="$(printf '%s\n' 'test: side writer root' \
        | git -C "$WRITER_REPO" commit-tree "$tree")"
      tree="$(git -C "$WRITER_REPO" rev-parse "$tip^{tree}")"
      commit="$(printf '%s\n' 'test: merge writer coordination history' \
        | git -C "$WRITER_REPO" commit-tree "$tree" -p "$tip" -p "$side")"
      ;;
    *) fail "unknown writer history corruption: $mode" ;;
  esac
  git -C "$WRITER_REPO" push -q --force origin "$commit:$ref"
}

writer_anchor_path() {
  local root="$1" common
  common="$(git -C "$root" rev-parse --git-common-dir)"
  case "$common" in /*) ;; *) common="$root/$common" ;; esac
  printf '%s/workbench-v2/writer-coordination-anchor\n' "$common"
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
  local repo out rc
  repo="$(setup_workbench start_validation)"
  out="$TMPDIR/start_validation/invalid.out"
  for slug in '../escape' 'Upper-Case' 'trailing-' 'too-many-slug-words-here'; do
    if run_task start_validation "$repo" start 29 "$slug" --format json >"$out" 2>&1; then
      fail "v2 start accepted noncanonical slug: $slug"
    else rc=$?; fi
    [ "$rc" = 2 ] || fail "invalid v2 slug returned $rc instead of usage exit 2"
  done
  if run_task start_validation "$repo" start '../shared-api#29' safe-slug \
    --format json >"$out" 2>&1; then
    fail "v2 start accepted a noncanonical reference home"
  else rc=$?; fi
  [ "$rc" = 2 ] || fail "invalid v2 home returned $rc instead of usage exit 2"
  if run_task start_validation "$repo" start 29 safe-slug --parent >"$out" 2>&1; then
    fail "v2 start accepted a missing --parent value"
  else rc=$?; fi
  [ "$rc" = 2 ] || fail "missing v2 option value returned $rc instead of usage exit 2"
  printf 'workbench/v2\n\n' > "$repo/.workbench/schema"
  if run_task start_validation "$repo" start 29 safe-slug --format json >"$out" 2>&1; then
    fail "task entrypoint accepted a schema marker with a trailing blank line"
  else rc=$?; fi
  [ "$rc" = 2 ] || fail "malformed schema returned $rc instead of usage exit 2"
  [ ! -e "$repo/.worktrees/task__29-safe-slug" ] || fail "invalid start created a task workspace"
}

test_v2_start_and_resume_are_authority_bound_skeletons() {
  local repo task_dir started resumed status digest lifecycle observation revision origin legacy_adapter
  local err mutation active_count
  setup_writer_workbench start_skeleton shared-api
  repo="$WRITER_REPO"

  err="$TMPDIR/start_skeleton/start.err"
  started="$(run_task start_skeleton "$repo" start shared-api#29 skeleton --format json 2>"$err")"
  [ ! -s "$err" ] || fail "successful JSON start wrote progress to stderr: $(cat "$err")"
  task_dir="$repo/.worktrees/task__shared-api__29-skeleton"
  digest="$(python3 - "$repo/.workbench/authority.json" <<'PY'
import hashlib
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
fields = (
    "contract_version", "authority_identity", "origin_url", "default_ref",
    "workspace_home", "hosting_adapter", "hosting_ref",
)
canonical = {field: value[field] for field in fields}
raw = (json.dumps(canonical, separators=(",", ":")) + "\n").encode()
print("sha256:" + hashlib.sha256(raw).hexdigest())
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
  active_count="$(grep -Fc '"event":"task-active"' "$lifecycle" || true)"
  [ "$active_count" = 0 ] || fail "v2 skeleton start emitted task-active"

  mutation="$(run_task_in_dir start_skeleton "$task_dir" refs set \
    --context-ref toolbox:product/acme --format json)"
  [ "$(json_get "$mutation" changed)" = true ] || fail "first configured mutation was unchanged"
  active_count="$(grep -Fc '"event":"task-active"' "$lifecycle" || true)"
  [ "$active_count" = 1 ] || fail "first configured mutation did not emit task-active once"
  mutation="$(run_task_in_dir start_skeleton "$task_dir" refs set \
    --context-ref toolbox:product/acme --format json)"
  [ "$(json_get "$mutation" changed)" = false ] || fail "repeated configured mutation changed state"
  active_count="$(grep -Fc '"event":"task-active"' "$lifecycle" || true)"
  [ "$active_count" = 1 ] || fail "configured mutation retry duplicated task-active"

  err="$TMPDIR/start_skeleton/resume.err"
  resumed="$(run_task start_skeleton "$repo" resume shared-api#29 --format json 2>"$err")"
  [ ! -s "$err" ] || fail "successful JSON resume wrote progress to stderr: $(cat "$err")"
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
  local repo first second actual out rc
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
  else rc=$?; fi
  [ "$rc" = 2 ] || fail "invalid namespaced ref returned $rc instead of usage exit 2"

  if run_task_in_dir refs "$second" refs set --context-ref --format json >"$out" 2>&1; then
    fail "refs set accepted a missing option value"
  else rc=$?; fi
  [ "$rc" = 2 ] || fail "missing refs option value returned $rc instead of usage exit 2"
}

test_work_ref_uniqueness_rejects_remote_only_task() {
  local repo first second branch out
  repo="$(setup_workbench remote_work_ref)"
  first="$(start_task remote_work_ref "$repo" 29)"
  run_task_in_dir remote_work_ref "$first" refs set \
    --work-ref toolbox:scenario/SCN-REMOTE --format json >/dev/null
  git -C "$first" add task/index.md
  git -C "$first" commit -q -m "test: persist remote work reference"
  git -C "$first" push -q
  branch="$(git -C "$first" branch --show-current)"
  git -C "$repo" worktree remove --force "$first"
  git -C "$repo" branch -D "$branch" >/dev/null

  second="$(start_task remote_work_ref "$repo" 31)"
  out="$TMPDIR/remote_work_ref/duplicate.out"
  if run_task_in_dir remote_work_ref "$second" refs set \
    --work-ref toolbox:scenario/SCN-REMOTE --format json >"$out" 2>&1; then
    fail "remote-only active work_ref must be rejected"
  fi
  assert_file_contains "$out" "duplicate active work_ref"
}

test_work_ref_uniqueness_retains_submitted_deleted_branch() {
  local repo first second branch body out
  repo="$(setup_workbench submitted_work_ref)"
  first="$(start_task submitted_work_ref "$repo" 29)"
  run_task_in_dir submitted_work_ref "$first" refs set \
    --work-ref toolbox:scenario/SCN-SUBMITTED --format json >/dev/null
  printf '%s\n' retained-increment > "$first/RETAINED.md"
  printf '\n## [2026-07-12 00:00:00] code · create RETAINED.md | submitted work-ref fixture\n' \
    >> "$first/task/log.md"
  printf '%s\n' '# Status' '' '상태: submitted work-ref fixture ready' > "$first/task/status.md"
  git -C "$first" add task RETAINED.md
  git -C "$first" commit -q -m "test: prepare submitted work reference"
  git -C "$first" push -q
  body="$TMPDIR/submitted_work_ref/body.md"
  printf '%s\n' 'submitted work-ref fixture' > "$body"
  run_task_in_dir submitted_work_ref "$first" submit \
    --title "test: submitted work ref" --body-file "$body" >/dev/null
  branch="$(git -C "$first" branch --show-current)"
  git -C "$first" push -q origin --delete "$branch"
  git -C "$repo" worktree remove --force "$first"
  git -C "$repo" branch -D "$branch" >/dev/null

  second="$(start_task submitted_work_ref "$repo" 31)"
  out="$TMPDIR/submitted_work_ref/duplicate.out"
  if run_task_in_dir submitted_work_ref "$second" refs set \
    --work-ref toolbox:scenario/SCN-SUBMITTED --format json >"$out" 2>&1; then
    fail "submitted task with a deleted branch released its active work_ref"
  fi
  assert_file_contains "$out" "duplicate active work_ref"
}

test_work_ref_inventory_requires_complete_pagination() {
  local repo task_dir observation origin revision mode out
  repo="$(setup_workbench work_ref_pagination)"
  task_dir="$(start_task work_ref_pagination "$repo" 29)"
  observation="$TMPDIR/work_ref_pagination/active-observation.json"
  origin="$(git -C "$repo" remote get-url origin)"
  revision="$(git -C "$repo" rev-parse origin/main)"
  for mode in home issue pr; do
    python3 - "$observation" "$origin" "$revision" "$mode" <<'PY'
import json
import sys

path, origin, revision, mode = sys.argv[1:]
complete = {"complete": True, "pages_fetched": 1, "end_cursor": None, "failure": None}
incomplete = {
    "complete": False,
    "pages_fetched": 1,
    "end_cursor": "cursor:2",
    "failure": {"code": "page-unavailable", "ref": "cursor:2"},
}
value = {
    "contract_version": "workbench-hosting-active-task-observation/v1",
    "workspace_origin_url": origin,
    "workspace_home": "workbench",
    "default_ref": "main",
    "default_revision": revision,
    "home_pagination": incomplete if mode == "home" else complete,
    "pr_pagination": incomplete if mode == "pr" else complete,
    "homes": [{
        "home": "workbench",
        "origin_url": origin,
        "membership": "current",
        "issue_pagination": incomplete if mode == "issue" else complete,
        "issues": [],
    }],
    "pull_requests": [],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
    out="$TMPDIR/work_ref_pagination/$mode.out"
    if WORKBENCH_TEST_ACTIVE_TASK_OBSERVATION="$observation" \
      run_task_in_dir work_ref_pagination "$task_dir" refs set \
        --work-ref toolbox:scenario/SCN-PAGE --format json >"$out" 2>&1; then
      fail "work_ref inventory accepted incomplete $mode pagination"
    fi
    assert_file_contains "$out" 'active-task-inventory-unavailable'
    [ -z "$(sed -n 's/^work_ref: *//p' "$task_dir/task/index.md")" ] \
      || fail "incomplete $mode pagination changed work_ref"
  done
}

test_work_ref_inventory_covers_removed_codebase_home() {
  local repo first second branch workspace_origin home_origin revision observation adapter out
  setup_writer_workbench removed_home_work_ref shared-api
  repo="$WRITER_REPO"
  run_task removed_home_work_ref "$repo" start shared-api#29 closed-home --format json >/dev/null
  first="$repo/.worktrees/task__shared-api__29-closed-home"
  run_task_in_dir removed_home_work_ref "$first" refs set \
    --work-ref toolbox:scenario/SCN-CLOSED --format json >/dev/null
  git -C "$first" add task/index.md
  git -C "$first" commit -q -m "test: persist removed-home work reference"
  git -C "$first" push -q
  branch="$(git -C "$first" branch --show-current)"
  git -C "$repo" worktree remove --force "$first"
  git -C "$repo" branch -D "$branch" >/dev/null

  workspace_origin="$(git -C "$repo" remote get-url origin)"
  home_origin="$TMPDIR/removed_home_work_ref/shared-api.git"
  printf '%s\n' '# no registered codebases' > "$repo/codebases.yaml"
  git -C "$repo" add codebases.yaml
  git -C "$repo" commit -q -m "test: remove codebase home"
  git -C "$repo" push -q
  revision="$(git -C "$repo" rev-parse origin/main)"
  observation="$TMPDIR/removed_home_work_ref/legacy-observation.json"
  python3 - "$observation" "$revision" "$workspace_origin" "$home_origin" <<'PY'
import json
import sys

path, revision, workspace_origin, home_origin = sys.argv[1:]
pagination = {"complete": True, "pages_fetched": 1, "end_cursor": None, "failure": None}
value = {
    "contract_version": "workbench-legacy-observation/v1",
    "source_revision": revision,
    "homes": [
        {
            "home": "shared-api",
            "origin_url": home_origin,
            "membership": "removed",
            "pagination": pagination,
            "claims": [],
        },
        {
            "home": "workbench",
            "origin_url": workspace_origin,
            "membership": "current",
            "pagination": pagination,
            "claims": [],
        },
    ],
    "origin_replacements": [{
        "home": "shared-api",
        "previous_origin_url": home_origin,
        "current_origin_url": None,
        "status": "removed-in-use",
    }],
    "blockers": [],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  adapter="$TMPDIR/removed_home_work_ref/bin/removed-home-legacy"
  write_fake_legacy_adapter "$adapter" "$observation"

  second="$(start_task removed_home_work_ref "$repo" 31)"
  out="$TMPDIR/removed_home_work_ref/duplicate.out"
  if WORKBENCH_TRUSTED_LEGACY_ADAPTER="$adapter" \
    run_task_in_dir removed_home_work_ref "$second" refs set \
      --work-ref toolbox:scenario/SCN-CLOSED --format json >"$out" 2>&1; then
    fail "removed codebase home released its active work_ref"
  fi
  assert_file_contains "$out" "duplicate active work_ref"
}

test_work_ref_inventory_is_cross_clone() {
  local repo first clone second out
  repo="$(setup_workbench cross_clone_work_ref)"
  first="$(start_task cross_clone_work_ref "$repo" 29)"
  run_task_in_dir cross_clone_work_ref "$first" refs set \
    --work-ref toolbox:scenario/SCN-CROSS --format json >/dev/null
  git -C "$first" add task/index.md
  git -C "$first" commit -q -m "test: persist cross-clone work reference"
  git -C "$first" push -q

  clone="$TMPDIR/cross_clone_work_ref/device-two"
  git clone -q "$TMPDIR/cross_clone_work_ref/origin.git" "$clone"
  git -C "$clone" config user.name "Test User"
  git -C "$clone" config user.email "test@example.invalid"
  run_task cross_clone_work_ref "$clone" start 31 cross-clone --format json >/dev/null
  second="$clone/.worktrees/task__31-cross-clone"
  out="$TMPDIR/cross_clone_work_ref/duplicate.out"
  if run_task_in_dir cross_clone_work_ref "$second" refs set \
    --work-ref toolbox:scenario/SCN-CROSS --format json >"$out" 2>&1; then
    fail "second clone accepted a duplicate active work_ref"
  fi
  assert_file_contains "$out" "duplicate active work_ref"
}

test_work_ref_inventory_uses_authority_default_ref() {
  local repo task_dir actual body
  repo="$(setup_workbench work_ref_trunk)"
  git -C "$repo" branch -m trunk
  printf '%s\n' 'kit: https://github.com/example/workbench.git' > "$repo/codebases.yaml"
  python3 - "$repo/.workbench/authority.json" <<'PY'
import json
import sys

path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["default_ref"] = "refs/heads/trunk"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  git -C "$repo" add .workbench/authority.json codebases.yaml
  git -C "$repo" commit -q -m "test: protect trunk by authority"
  git -C "$repo" push -q -u origin trunk
  git -C "$TMPDIR/work_ref_trunk/origin.git" symbolic-ref HEAD refs/heads/trunk
  git -C "$repo" remote set-head origin trunk

  run_task work_ref_trunk "$repo" start 29 trunk-ref --format json >/dev/null
  task_dir="$repo/.worktrees/task__29-trunk-ref"
  actual="$(run_task_in_dir work_ref_trunk "$task_dir" refs set \
    --work-ref toolbox:scenario/SCN-TRUNK --format json)"
  assert_contains "$actual" '"work_ref":"toolbox:scenario/SCN-TRUNK"'
  run_task_in_dir work_ref_trunk "$task_dir" deliverable declare --id workbench-pr \
    --owner kit --kind workbench-increment --format json >/dev/null
  printf '%s\n' trunk-increment > "$task_dir/TRUNK.md"
  printf '\n## [2026-07-12 14:30:00] code · create TRUNK.md | trunk submission fixture\n' \
    >> "$task_dir/task/log.md"
  printf '%s\n' '# Status' '' '상태: trunk submit ready' > "$task_dir/task/status.md"
  git -C "$task_dir" add task TRUNK.md
  git -C "$task_dir" commit -q -m "test: prepare trunk submission"
  git -C "$task_dir" push -q
  body="$TMPDIR/work_ref_trunk/body.md"; printf '%s\n' trunk > "$body"
  run_task_in_dir work_ref_trunk "$task_dir" submit \
    --title "test: trunk submission" --body-file "$body" >/dev/null
  assert_file_contains "$TMPDIR/work_ref_trunk/comments/pr-17.json" '"baseRefName":"trunk"'
  [ -f "$task_dir/task/index.md" ] \
    || fail "trunk submission did not restore its task state"
}

test_work_ref_inventory_fails_closed_on_identity_mismatch() {
  local repo first second branch out
  repo="$(setup_workbench work_ref_identity)"
  first="$(start_task work_ref_identity "$repo" 29)"
  run_task_in_dir work_ref_identity "$first" refs set \
    --work-ref toolbox:scenario/SCN-IDENTITY --format json >/dev/null
  python3 - "$first/task/index.md" <<'PY'
import sys

path = sys.argv[1]
rows = open(path, encoding="utf-8").read().splitlines()
for index, row in enumerate(rows):
    if row.startswith("claim_id:"):
        rows[index] = "claim_id: forged-remote-claim"
        break
else:
    raise AssertionError("missing claim_id")
with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(rows) + "\n")
PY
  git -C "$first" add task/index.md
  git -C "$first" commit -q -m "test: corrupt remote task identity"
  git -C "$first" push -q
  branch="$(git -C "$first" branch --show-current)"
  git -C "$repo" worktree remove --force "$first"
  git -C "$repo" branch -D "$branch" >/dev/null

  second="$(start_task work_ref_identity "$repo" 31)"
  out="$TMPDIR/work_ref_identity/rejected.out"
  if run_task_in_dir work_ref_identity "$second" refs set \
    --work-ref toolbox:scenario/SCN-OTHER --format json >"$out" 2>&1; then
    fail "work_ref inventory ignored a remote claim/index mismatch"
  fi
  assert_file_contains "$out" 'active-task-inventory-unavailable'
  [ -z "$(sed -n 's/^work_ref: *//p' "$second/task/index.md")" ] \
    || fail "identity-mismatched inventory changed the current work_ref"
}

test_work_ref_inventory_rejects_lifecycle_without_initial_claim() {
  local repo first second comments out
  repo="$(setup_workbench work_ref_sequence)"
  first="$(start_task work_ref_sequence "$repo" 29)"
  run_task_in_dir work_ref_sequence "$first" refs set \
    --work-ref toolbox:scenario/SCN-SEQUENCE --format json >/dev/null
  git -C "$first" add task/index.md
  git -C "$first" commit -q -m "test: persist sequence work reference"
  git -C "$first" push -q
  second="$(start_task work_ref_sequence "$repo" 31)"
  comments="$TMPDIR/work_ref_sequence/comments/29.comments"
  python3 - "$comments" <<'PY'
import json
import re
import sys

path = sys.argv[1]
raw = open(path, encoding="utf-8").read()
pattern = re.compile(
    r"<!-- workbench-task-lifecycle:v2\n([^\r\n]+)\n-->\n"
    r"workbench task lifecycle: task-claimed[^\r\n]*\n+"
)
matches = list(pattern.finditer(raw))
assert len(matches) == 1
marker = json.loads(matches[0].group(1))
assert marker["event"] == "task-claimed"
raw = raw[: matches[0].start()] + raw[matches[0].end() :]
open(path, "w", encoding="utf-8").write(raw)
PY

  out="$TMPDIR/work_ref_sequence/rejected.out"
  if run_task_in_dir work_ref_sequence "$second" refs set \
    --work-ref toolbox:scenario/SCN-OTHER --format json >"$out" 2>&1; then
    fail "active inventory accepted a lifecycle identity without task-claimed"
  fi
  assert_file_contains "$out" 'active-task-inventory-unavailable'
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

test_unsealed_policy_context_replacement_invalidates_old_actions() {
  local repo task_dir claim registration policy_digest out rc pending instance revision intent manifest auth
  repo="$(setup_workbench context_replace)"
  printf '%s\n' 'schema=workbench-policy/v1' \
    'action.task.policy-context.register=allow' > "$repo/.workbench/policy.conf"
  git -C "$repo" add .workbench/policy.conf
  git -C "$repo" commit -q -m "test: allow context replacement"
  git -C "$repo" push -q
  task_dir="$(start_task context_replace "$repo")"
  claim="$(sed -n 's/^claim_id: *//p' "$task_dir/task/index.md")"
  mkdir -p "$task_dir/contexts"
  printf '%s\n' 'schema=workbench-policy/v1' > "$task_dir/contexts/acme.policy"
  policy_digest="sha256:$(shasum -a 256 "$task_dir/contexts/acme.policy" | awk '{print $1}')"
  registration="$TMPDIR/context_replace/acme.json"
  write_context_registration "$registration" "$claim" toolbox:product/acme \
    contexts/acme.policy "$policy_digest" ctxreg-acme owner@example.com 2026-07-12T15:10:00Z
  run_task_in_dir context_replace "$task_dir" refs set \
    --context-ref toolbox:product/acme --format json >/dev/null
  out="$TMPDIR/context_replace/acme-pending.out"
  if run_task_in_dir context_replace "$task_dir" policy-context register \
    --registration-file "$registration" --format json >"$out"; then
    fail "context replacement fixture must first require authorization"
  else rc=$?; fi
  [ "$rc" = 3 ] || fail "context replacement pending action returned $rc"
  pending="$(cat "$out")"; instance="$(json_get "$pending" action_instance.id)"
  revision="$(json_get "$pending" action_instance.revision)"
  intent="$(json_get "$pending" action_instance.intent_digest)"
  manifest="$(json_get "$pending" action_instance.policy_manifest.digest)"
  auth="$TMPDIR/context_replace/acme-auth.json"
  write_authorization "$auth" "$instance" task.policy-context.register "$claim" \
    "workbench:task/$claim" "$revision" "$manifest" allow owner@example.com \
    2026-07-12T15:10:00Z conversation:message/context-acme "$intent"
  run_task_in_dir context_replace "$task_dir" policy-context register \
    --registration-file "$registration" --action-instance-id "$instance" \
    --authorization-file "$auth" --format json >/dev/null
  assert_file_contains "$task_dir/task/.workbench/policy-context/state.record" 'sealed=false'

  run_task_in_dir context_replace "$task_dir" refs set \
    --context-ref toolbox:product/beta --format json >/dev/null
  [ ! -e "$task_dir/task/.workbench/policy-context" ] \
    || fail "context replacement retained the old unsealed projection"
  assert_file_contains "$task_dir/task/.workbench/actions/$instance.record" 'status=consumed'

  printf '%s\n' 'schema=workbench-policy/v1' > "$task_dir/contexts/beta.policy"
  policy_digest="sha256:$(shasum -a 256 "$task_dir/contexts/beta.policy" | awk '{print $1}')"
  registration="$TMPDIR/context_replace/beta.json"
  write_context_registration "$registration" "$claim" toolbox:product/beta \
    contexts/beta.policy "$policy_digest" ctxreg-beta owner@example.com 2026-07-12T15:11:00Z
  out="$TMPDIR/context_replace/beta-pending.out"
  if run_task_in_dir context_replace "$task_dir" policy-context register \
    --registration-file "$registration" --format json >"$out"; then
    fail "replacement registration must require authorization"
  else rc=$?; fi
  [ "$rc" = 3 ] || fail "replacement registration pending action returned $rc"
  instance="$(json_get "$(cat "$out")" action_instance.id)"
  run_task_in_dir context_replace "$task_dir" refs set \
    --context-ref toolbox:product/gamma --format json >/dev/null
  assert_file_contains "$task_dir/task/.workbench/actions/$instance.record" 'status=superseded'
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

test_tracked_v2_records_cannot_forge_accepted_or_waived_state() {
  local repo task_dir state digest out rc
  repo="$(setup_workbench forged_records)"
  task_dir="$(start_task forged_records "$repo")"
  state="$task_dir/task/.workbench"; mkdir -p "$state/deliverables" \
    "$state/acceptances" "$state/required-checks"
  digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  cat > "$state/deliverables/forged.record" <<EOF
deliverable_id=forged
owner=toolbox
kind=toolbox:artifact
owner_context_ref=toolbox:product/demo
acceptance_authority_ref=toolbox:acceptance/demo
required=true
external_ref=
revision=rev-forged
state=accepted
acceptance_ref=workbench:acceptance/acc-forged
governance_action=
reason_code=
reason_ref=
governance_action_instance_id=
governance_intent_digest=
governance_policy_manifest_digest=
authorization_ref=
EOF
  cat > "$state/acceptances/acc-forged.record" <<EOF
acceptance_id=acc-forged
deliverable_id=forged
owner=toolbox
kind=toolbox:artifact
owner_context_ref=toolbox:product/demo
acceptance_authority_ref=toolbox:acceptance/demo
revision=rev-forged
authority_type=owner-authorization
authority_contract=workbench-owner-acceptance/v1
authority_ref=toolbox:acceptance/demo
authority_digest=$digest
subject_authority_digest=$digest
actor=attacker@example.invalid
action_instance_id=act_forged_acceptance
intent_digest=$digest
policy_manifest_digest=$digest
authorization_ref=conversation:message/forged
accepted_at=2026-07-11T04:00:00Z
EOF
  cat > "$state/required-checks/forged-check.record" <<EOF
check_id=forged-check
owner=toolbox
deliverable_id=forged
subject_ref=workbench:deliverable/forged
state=waived
governance_action=task.required-check.waive
reason_code=forged
reason_ref=conversation:message/forged
action_instance_id=act_forged_waiver
intent_digest=$digest
policy_manifest_digest=$digest
authorization_ref=conversation:message/forged
EOF

  out="$TMPDIR/forged_records/verify.out"
  if run_task_in_dir forged_records "$task_dir" verify --format json >"$out" 2>&1; then
    fail "hand-written accepted and waived records must not satisfy verification"
  else
    rc=$?
  fi
  [ "$rc" = 1 ] || fail "forged tracked records must fail at exit 1, got $rc"
  assert_file_contains "$out" '"code":"action-effect-unreconciled"'
}

test_evidence_time_is_kernel_owned_and_future_rows_fail_closed() {
  local repo task_dir state out rc digest
  repo="$(setup_workbench evidence_time)"
  printf 'web: https://github.com/example/web.git\n' > "$repo/codebases.yaml"
  git -C "$repo" add codebases.yaml
  git -C "$repo" commit -q -m "test: register evidence time owner"
  git -C "$repo" push -q
  task_dir="$(start_task evidence_time "$repo")"
  run_task_in_dir evidence_time "$task_dir" deliverable declare --id web-pr --owner web \
    --kind codebase-pr --required false --revision abc123 --format json >/dev/null
  run_task_in_dir evidence_time "$task_dir" required-check declare --id web-test --owner web \
    --deliverable-id web-pr --format json >/dev/null

  out="$TMPDIR/evidence_time/caller-time.out"
  if run_task_in_dir evidence_time "$task_dir" evidence record --id caller-time \
    --owner web --subject-ref workbench:deliverable/web-pr --subject-revision abc123 \
    --check-id web-test --result passed --source local --recorded-at 9999-12-31T23:59:59Z \
    --format json >"$out" 2>&1; then
    fail "evidence record must reject caller-controlled recorded-at"
  else
    rc=$?
  fi
  [ "$rc" = 1 ] || [ "$rc" = 2 ] \
    || fail "caller-controlled evidence time returned unexpected exit $rc"
  assert_file_contains "$out" 'unknown option: --recorded-at'

  state="$task_dir/task/.workbench/evidence"; mkdir -p "$state"
  cat > "$state/future.record" <<'EOF'
evidence_id=future
owner=web
subject_ref=workbench:deliverable/web-pr
subject_revision=abc123
check_id=web-test
command=npm test
result=passed
recorded_at=9999-12-31T23:59:59Z
source=local
url=
EOF
  digest="$(git hash-object "$state/future.record")"
  out="$TMPDIR/evidence_time/future.out"
  if run_task_in_dir evidence_time "$task_dir" verify --format json >"$out" 2>&1; then
    fail "a hand-written future evidence row must not win evidence selection"
  else
    rc=$?
  fi
  [ "$rc" = 1 ] || fail "future evidence must fail closed at exit 1, got $rc"
  assert_file_contains "$out" '"code":"action-effect-unreconciled"'
  [ "$(git hash-object "$state/future.record")" = "$digest" ] \
    || fail "future evidence rejection mutated the tracked row"
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

test_governed_authorization_ref_is_parsed_as_json() {
  local task_dir out rc pending instance revision intent manifest auth actual expected record
  prepare_governed_fixture governed_escaped_authorization; task_dir="$GOVERNED_TASK_DIR"
  run_task_in_dir governed_escaped_authorization "$task_dir" required-check declare \
    --id advisory --owner workbench --format json >/dev/null
  out="$TMPDIR/governed_escaped_authorization/pending.out"
  if WORKBENCH_PLATFORM_POLICY="$GOVERNED_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/governed \
    run_task_in_dir governed_escaped_authorization "$task_dir" required-check waive \
      --id advisory --reason-code not-applicable --format json >"$out"; then
    fail "escaped authorization fixture must first require authorization"
  else rc=$?; fi
  [ "$rc" = 3 ] || fail "escaped authorization pending returned $rc"
  pending="$(cat "$out")"; instance="$(json_get "$pending" action_instance.id)"
  revision="$(json_get "$pending" action_instance.revision)"
  intent="$(json_get "$pending" action_instance.intent_digest)"
  manifest="$(json_get "$pending" action_instance.policy_manifest.digest)"
  expected='conversation:message/escaped"quote\path'
  auth="$TMPDIR/governed_escaped_authorization/authorization.json"
  write_authorization "$auth" "$instance" task.required-check.waive "$GOVERNED_CLAIM" \
    workbench:required-check/advisory "$revision" "$manifest" allow reviewer@example.com \
    2026-07-11T04:33:00Z "$expected" "$intent"
  actual="$(WORKBENCH_PLATFORM_POLICY="$GOVERNED_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/governed \
    run_task_in_dir governed_escaped_authorization "$task_dir" required-check waive \
      --id advisory --reason-code not-applicable --action-instance-id "$instance" \
      --authorization-file "$auth" --format json)"
  [ "$(json_get "$actual" required_check.authorization_ref)" = "$expected" ] \
    || fail "governed result did not preserve escaped authorization_ref"
  record="$task_dir/task/.workbench/required-checks/advisory.record"
  [ "$(sed -n 's/^authorization_ref=//p' "$record")" = "$expected" ] \
    || fail "governed primary truncated escaped authorization_ref"
  assert_file_contains "$task_dir/task/.workbench/actions/$instance.record" 'status=consumed'
}

test_governed_primary_revalidates_policy_after_authorization() {
  local task_dir out rc pending instance revision intent manifest auth hook state
  prepare_governed_fixture governed_final_gate; task_dir="$GOVERNED_TASK_DIR"
  run_task_in_dir governed_final_gate "$task_dir" required-check declare \
    --id advisory --owner workbench --format json >/dev/null

  out="$TMPDIR/governed_final_gate/pending.out"
  if WORKBENCH_PLATFORM_POLICY="$GOVERNED_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/governed \
    run_task_in_dir governed_final_gate "$task_dir" required-check waive --id advisory \
      --reason-code not-applicable --format json >"$out"; then
    fail "governed final-gate fixture must first require authorization"
  else rc=$?; fi
  [ "$rc" = 3 ] || fail "governed final-gate pending action returned $rc"
  pending="$(cat "$out")"; instance="$(json_get "$pending" action_instance.id)"
  revision="$(json_get "$pending" action_instance.revision)"
  intent="$(json_get "$pending" action_instance.intent_digest)"
  manifest="$(json_get "$pending" action_instance.policy_manifest.digest)"
  auth="$TMPDIR/governed_final_gate/authorization.json"
  write_authorization "$auth" "$instance" task.required-check.waive "$GOVERNED_CLAIM" \
    workbench:required-check/advisory "$revision" "$manifest" allow reviewer@example.com \
    2026-07-12T15:00:00Z conversation:message/final-gate "$intent"
  hook="$TMPDIR/governed_final_gate/change-policy"
  cat > "$hook" <<EOF
#!/usr/bin/env bash
printf '%s\n' 'schema=workbench-policy/v1' 'action.task.required-check.waive=deny' > '$GOVERNED_PLATFORM_POLICY'
EOF
  chmod +x "$hook"

  out="$TMPDIR/governed_final_gate/rejected.out"
  if WORKBENCH_TEST_GOVERNED_FINAL_HOOK="$hook" \
    WORKBENCH_PLATFORM_POLICY="$GOVERNED_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/governed \
    run_task_in_dir governed_final_gate "$task_dir" required-check waive --id advisory \
      --reason-code not-applicable --action-instance-id "$instance" \
      --authorization-file "$auth" --format json >"$out" 2>&1; then
    fail "governed primary ignored policy drift after authorization"
  fi
  state="$(sed -n 's/^state=//p' "$task_dir/task/.workbench/required-checks/advisory.record")"
  [ "$state" = required ] || fail "stale governed action wrote its primary"
  assert_file_contains "$task_dir/task/.workbench/actions/$instance.record" 'status=authorized'
}

test_governed_primary_revalidates_local_preimage() {
  local task_dir record out rc pending instance revision intent manifest auth hook
  prepare_governed_fixture governed_preimage_gate; task_dir="$GOVERNED_TASK_DIR"
  run_task_in_dir governed_preimage_gate "$task_dir" required-check declare \
    --id advisory --owner workbench --format json >/dev/null
  record="$task_dir/task/.workbench/required-checks/advisory.record"
  out="$TMPDIR/governed_preimage_gate/pending.out"
  if WORKBENCH_PLATFORM_POLICY="$GOVERNED_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/governed \
    run_task_in_dir governed_preimage_gate "$task_dir" required-check waive --id advisory \
      --reason-code not-applicable --format json >"$out"; then
    fail "governed preimage fixture must first require authorization"
  else rc=$?; fi
  [ "$rc" = 3 ] || fail "governed preimage pending action returned $rc"
  pending="$(cat "$out")"; instance="$(json_get "$pending" action_instance.id)"
  revision="$(json_get "$pending" action_instance.revision)"
  intent="$(json_get "$pending" action_instance.intent_digest)"
  manifest="$(json_get "$pending" action_instance.policy_manifest.digest)"
  auth="$TMPDIR/governed_preimage_gate/authorization.json"
  write_authorization "$auth" "$instance" task.required-check.waive "$GOVERNED_CLAIM" \
    workbench:required-check/advisory "$revision" "$manifest" allow reviewer@example.com \
    2026-07-12T15:01:00Z conversation:message/preimage-gate "$intent"
  hook="$TMPDIR/governed_preimage_gate/change-record"
  cat > "$hook" <<EOF
#!/usr/bin/env bash
python3 - '$record' <<'PY'
from pathlib import Path
path = Path(__import__('sys').argv[1])
path.write_text(path.read_text().replace('owner=workbench\n', 'owner=tampered\n'))
PY
EOF
  chmod +x "$hook"
  out="$TMPDIR/governed_preimage_gate/rejected.out"
  if WORKBENCH_TEST_GOVERNED_FINAL_HOOK="$hook" \
    WORKBENCH_PLATFORM_POLICY="$GOVERNED_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/governed \
    run_task_in_dir governed_preimage_gate "$task_dir" required-check waive --id advisory \
      --reason-code not-applicable --action-instance-id "$instance" \
      --authorization-file "$auth" --format json >"$out" 2>&1; then
    fail "governed primary ignored its changed local preimage"
  fi
  assert_file_contains "$record" 'owner=tampered'
  assert_file_contains "$record" 'state=required'
  assert_file_contains "$task_dir/task/.workbench/actions/$instance.record" 'status=authorized'
}

test_governed_revalidation_does_not_recreate_missing_context() {
  local task_dir out rc pending instance revision intent manifest auth hook record
  prepare_governed_fixture governed_read_only_gate; task_dir="$GOVERNED_TASK_DIR"
  run_task_in_dir governed_read_only_gate "$task_dir" required-check declare \
    --id advisory --owner workbench --format json >/dev/null
  record="$task_dir/task/.workbench/required-checks/advisory.record"

  out="$TMPDIR/governed_read_only_gate/pending.out"
  if WORKBENCH_PLATFORM_POLICY="$GOVERNED_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/governed \
    run_task_in_dir governed_read_only_gate "$task_dir" required-check waive --id advisory \
      --reason-code not-applicable --format json >"$out"; then
    fail "governed read-only fixture must first require authorization"
  else rc=$?; fi
  [ "$rc" = 3 ] || fail "governed read-only pending action returned $rc"
  pending="$(cat "$out")"; instance="$(json_get "$pending" action_instance.id)"
  revision="$(json_get "$pending" action_instance.revision)"
  intent="$(json_get "$pending" action_instance.intent_digest)"
  manifest="$(json_get "$pending" action_instance.policy_manifest.digest)"
  auth="$TMPDIR/governed_read_only_gate/authorization.json"
  write_authorization "$auth" "$instance" task.required-check.waive "$GOVERNED_CLAIM" \
    workbench:required-check/advisory "$revision" "$manifest" allow reviewer@example.com \
    2026-07-12T15:02:00Z conversation:message/read-only-gate "$intent"
  hook="$TMPDIR/governed_read_only_gate/remove-context"
  cat > "$hook" <<EOF
#!/usr/bin/env bash
rm -rf '$task_dir/task/.workbench/policy-context'
EOF
  chmod +x "$hook"

  out="$TMPDIR/governed_read_only_gate/rejected.out"
  if WORKBENCH_TEST_GOVERNED_FINAL_HOOK="$hook" \
    WORKBENCH_PLATFORM_POLICY="$GOVERNED_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/governed \
    run_task_in_dir governed_read_only_gate "$task_dir" required-check waive --id advisory \
      --reason-code not-applicable --action-instance-id "$instance" \
      --authorization-file "$auth" --format json >"$out" 2>&1; then
    fail "governed primary accepted a missing policy context"
  fi
  [ ! -e "$task_dir/task/.workbench/policy-context" ] \
    || fail "read-only governed revalidation recreated policy context state"
  assert_file_contains "$record" 'state=required'
  assert_file_contains "$task_dir/task/.workbench/actions/$instance.record" 'status=authorized'
}

test_governed_revalidation_binds_exact_action_record() {
  local task_dir out rc pending instance revision intent manifest auth hook record action_record
  prepare_governed_fixture governed_action_record_gate; task_dir="$GOVERNED_TASK_DIR"
  run_task_in_dir governed_action_record_gate "$task_dir" required-check declare \
    --id advisory --owner workbench --format json >/dev/null
  record="$task_dir/task/.workbench/required-checks/advisory.record"

  out="$TMPDIR/governed_action_record_gate/pending.out"
  if WORKBENCH_PLATFORM_POLICY="$GOVERNED_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/governed \
    run_task_in_dir governed_action_record_gate "$task_dir" required-check waive --id advisory \
      --reason-code not-applicable --format json >"$out"; then
    fail "governed action-record fixture must first require authorization"
  else rc=$?; fi
  [ "$rc" = 3 ] || fail "governed action-record pending action returned $rc"
  pending="$(cat "$out")"; instance="$(json_get "$pending" action_instance.id)"
  revision="$(json_get "$pending" action_instance.revision)"
  intent="$(json_get "$pending" action_instance.intent_digest)"
  manifest="$(json_get "$pending" action_instance.policy_manifest.digest)"
  auth="$TMPDIR/governed_action_record_gate/authorization.json"
  write_authorization "$auth" "$instance" task.required-check.waive "$GOVERNED_CLAIM" \
    workbench:required-check/advisory "$revision" "$manifest" allow reviewer@example.com \
    2026-07-12T15:03:00Z conversation:message/action-record-gate "$intent"
  action_record="$task_dir/task/.workbench/actions/$instance.record"
  hook="$TMPDIR/governed_action_record_gate/change-action-record"
  cat > "$hook" <<EOF
#!/usr/bin/env bash
python3 - '$action_record' <<'PY'
from pathlib import Path
path = Path(__import__('sys').argv[1])
path.write_text(path.read_text().replace(
    'authorization_actor=reviewer@example.com\n',
    'authorization_actor=other@example.com\n',
))
PY
EOF
  chmod +x "$hook"

  out="$TMPDIR/governed_action_record_gate/rejected.out"
  if WORKBENCH_TEST_GOVERNED_FINAL_HOOK="$hook" \
    WORKBENCH_PLATFORM_POLICY="$GOVERNED_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/governed \
    run_task_in_dir governed_action_record_gate "$task_dir" required-check waive --id advisory \
      --reason-code not-applicable --action-instance-id "$instance" \
      --authorization-file "$auth" --format json >"$out" 2>&1; then
    fail "governed primary accepted a changed authorization record"
  fi
  assert_file_contains "$record" 'state=required'
  assert_file_contains "$action_record" 'authorization_actor=other@example.com'
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
  printf '%s\n' 'action.task.abandon=allow' >> "$repo/.workbench/policy.conf"
  git -C "$repo" add .workbench/policy.conf
  git -C "$repo" commit -q -m "test: allow terminal freeze fixture"
  git -C "$repo" push -q
  task_dir="$(start_task terminal_freeze "$repo")"
  claim="$(sed -n 's/^claim_id: *//p' "$task_dir/task/index.md")"
  actual="$(run_task_in_dir terminal_freeze "$task_dir" abandon \
    --reason-code superseded --reason-ref issue:55 --format json)"
  revision="$(json_get "$actual" revision)"

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

test_terminal_lifecycle_rejects_post_terminal_reactivation() {
  local repo task_dir claim branch descriptor comments out rc
  repo="$(setup_workbench terminal_absorbing)"
  printf '%s\n' 'action.task.abandon=allow' >> "$repo/.workbench/policy.conf"
  git -C "$repo" add .workbench/policy.conf
  git -C "$repo" commit -q -m "test: allow absorbing terminal fixture"
  git -C "$repo" push -q
  task_dir="$(start_task terminal_absorbing "$repo")"
  claim="$(sed -n 's/^claim_id: *//p' "$task_dir/task/index.md")"
  branch="$(git -C "$task_dir" branch --show-current)"
  descriptor="$(sed -n 's/^workspace_authority_descriptor_digest: *//p' "$task_dir/task/index.md")"
  run_task_in_dir terminal_absorbing "$task_dir" abandon \
    --reason-code superseded --format json >/dev/null
  comments="$TMPDIR/terminal_absorbing/comments/29.comments"
  python3 - "$comments" "$claim" "$branch" "$descriptor" <<'PY'
import json
import sys
value = {
    "task_contract": "workbench-task/v2",
    "event": "task-active",
    "claim_id": sys.argv[2],
    "issue": 29,
    "home": None,
    "branch": sys.argv[3],
    "workspace_authority_descriptor_digest": sys.argv[4],
    "pr": None,
    "revision": None,
    "action_instance_id": None,
    "intent_digest": None,
    "actor": "test@example.invalid",
    "tool": "workbench",
    "at": "2026-07-11T05:30:00Z",
}
with open(sys.argv[1], "a", encoding="utf-8") as handle:
    handle.write("<!-- fixture-comment-author:test@example.invalid -->\n")
    handle.write("<!-- workbench-task-lifecycle:v2\n")
    handle.write(json.dumps(value, separators=(",", ":")) + "\n")
    handle.write("-->\nworkbench task lifecycle: task-active\n")
    handle.write("<!-- fixture-comment-end -->\n")
PY
  out="$TMPDIR/terminal_absorbing/retry.out"
  if run_task_in_dir terminal_absorbing "$task_dir" abandon \
    --reason-code ignored --format json >"$out" 2>&1; then
    fail "terminal outcome accepted a post-terminal task-active event"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "post-terminal transition returned $rc"
  assert_file_contains "$out" '"code":"action-effect-unreconciled"'

  out="$TMPDIR/terminal_absorbing/mutation.out"
  if run_task_in_dir terminal_absorbing "$task_dir" refs set \
    --work-ref toolbox:scenario/SCN-099 --format json >"$out" 2>&1; then
    fail "post-terminal lifecycle corruption reopened mutable task content"
  fi
  assert_file_contains "$out" '"code":"action-effect-unreconciled"'
}

test_forged_local_terminal_has_no_freeze_or_outcome_authority() {
  local repo task_dir claim digest out rc actual
  repo="$(setup_workbench forged_terminal)"
  task_dir="$(start_task forged_terminal "$repo")"
  claim="$(sed -n 's/^claim_id: *//p' "$task_dir/task/index.md")"
  digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir -p "$task_dir/task/.workbench"
  cat > "$task_dir/task/.workbench/terminal" <<EOF
outcome=completed
action_instance_id=act_forged_terminal
intent_digest=$digest
policy_manifest_digest=$digest
authorization_ref=conversation:message/forged
revision=$digest
removal_plan_digest=
at=2026-07-11T04:00:00Z
reason_code=
reason_ref=
EOF

  out="$TMPDIR/forged_terminal/complete.out"
  if run_task_in_dir forged_terminal "$task_dir" complete --format json >"$out" 2>&1; then
    fail "a forged local terminal must not become an idempotent outcome"
  else
    rc=$?
  fi
  [ "$rc" = 1 ] || fail "forged terminal must fail closed at exit 1, got $rc"
  assert_file_contains "$out" '"code":"action-effect-unreconciled"'

  actual="$(run_task_in_dir forged_terminal "$task_dir" refs set \
    --work-ref toolbox:scenario/SCN-009 --format json)"
  assert_contains "$actual" '"changed":true'
  [ "$(sed -n 's/^work_ref: *//p' "$task_dir/task/index.md")" = toolbox:scenario/SCN-009 ] \
    || fail "forged terminal incorrectly froze mutable task content"
  [ "$claim" = "$(sed -n 's/^claim_id: *//p' "$task_dir/task/index.md")" ] \
    || fail "forged terminal test changed the task claim"
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

test_cleanup_rejects_untrusted_prepared_journal() {
  local repo task_dir claim branch comments out rc
  repo="$(setup_workbench cleanup_untrusted_journal)"
  task_dir="$(start_task cleanup_untrusted_journal "$repo")"
  claim="$(sed -n 's/^claim_id: *//p' "$task_dir/task/index.md")"
  branch="$(git -C "$task_dir" symbolic-ref --quiet --short HEAD)"
  comments="$TMPDIR/cleanup_untrusted_journal/comments/29.comments"
  printf '%s\n' unsynced > "$task_dir/UNSYNCED.txt"
  git -C "$task_dir" add UNSYNCED.txt
  git -C "$task_dir" commit -q -m "test: retain unpushed cleanup state"
  printf '%s\n' dirty > "$task_dir/DIRTY.txt"
  append_forged_cleanup_journal "$comments" "$claim" "$branch" attacker@example.invalid

  out="$TMPDIR/cleanup_untrusted_journal/done.out"
  if run_task cleanup_untrusted_journal "$repo" done 29 --format json >"$out" 2>&1; then
    fail "an untrusted cleanup journal deleted a dirty, unpushed active task"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "untrusted cleanup journal returned $rc"
  assert_file_contains "$out" '"code":"cleanup-journal-untrusted"'
  [ -d "$task_dir" ] || fail "untrusted cleanup journal removed the task workspace"
  [ -f "$task_dir/DIRTY.txt" ] || fail "untrusted cleanup journal removed dirty state"
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" \
    || fail "untrusted cleanup journal removed the local branch"
  [ "$(git -C "$repo" rev-list --count "origin/$branch..$branch")" = 1 ] \
    || fail "untrusted cleanup journal changed the unpushed branch"
}

test_cleanup_rejects_prepared_journal_without_terminal_action_join() {
  local repo task_dir claim branch comments out rc
  repo="$(setup_workbench cleanup_unjoined_journal)"
  task_dir="$(start_task cleanup_unjoined_journal "$repo")"
  claim="$(sed -n 's/^claim_id: *//p' "$task_dir/task/index.md")"
  branch="$(git -C "$task_dir" symbolic-ref --quiet --short HEAD)"
  comments="$TMPDIR/cleanup_unjoined_journal/comments/29.comments"
  printf '%s\n' unsynced > "$task_dir/UNSYNCED.txt"
  git -C "$task_dir" add UNSYNCED.txt
  git -C "$task_dir" commit -q -m "test: retain unjoined cleanup state"
  printf '%s\n' dirty > "$task_dir/DIRTY.txt"
  append_forged_cleanup_journal "$comments" "$claim" "$branch" test@example.invalid

  out="$TMPDIR/cleanup_unjoined_journal/done.out"
  if run_task cleanup_unjoined_journal "$repo" done 29 --format json >"$out" 2>&1; then
    fail "a cleanup journal without terminal/action provenance deleted an active task"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "unjoined cleanup journal returned $rc"
  assert_file_contains "$out" '"code":"cleanup-journal-unreconciled"'
  [ -d "$task_dir" ] || fail "unjoined cleanup journal removed the task workspace"
  [ -f "$task_dir/DIRTY.txt" ] || fail "unjoined cleanup journal removed dirty state"
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" \
    || fail "unjoined cleanup journal removed the local branch"
  [ "$(git -C "$repo" rev-list --count "origin/$branch..$branch")" = 1 ] \
    || fail "unjoined cleanup journal changed the unpushed branch"
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

test_cleanup_deleted_retry_rejects_tampered_immutable_intent() {
  local out comments rc
  prepare_cleanup_fixture cleanup_tampered_retry
  out="$TMPDIR/cleanup_tampered_retry/completed-failure.out"
  if GH_FAIL_CLEANUP_STAGE=completed \
    WORKBENCH_PLATFORM_POLICY="$CLEANUP_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/cleanup \
    run_task cleanup_tampered_retry "$CLEANUP_REPO" done 29 \
      --action-instance-id "$CLEANUP_ACTION_INSTANCE" --format json >"$out" 2>/dev/null; then
    fail "cleanup fixture must stop after deleting the workspace"
  fi
  [ ! -d "$CLEANUP_TASK_DIR" ] || fail "tampered retry fixture retained its workspace"
  comments="$TMPDIR/cleanup_tampered_retry/comments/29.comments"
  python3 - "$comments" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text, count = re.subn(
    r'(<!-- workbench-task-cleanup:v1\n[^\r\n]*"intent_digest":")sha256:[0-9a-f]{64}("[^\r\n]*\n-->)',
    lambda match: match.group(1) + 'sha256:' + 'f' * 64 + match.group(2),
    text,
)
assert count == 1, count
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
  out="$TMPDIR/cleanup_tampered_retry/retry.out"
  if run_task cleanup_tampered_retry "$CLEANUP_REPO" done 29 --format json >"$out" 2>&1; then
    fail "deleted cleanup retry accepted an intent-tampered authenticated journal"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "tampered deleted retry returned $rc"
  assert_file_contains "$out" '"code":"cleanup-journal-unreconciled"'
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
conflict_lengths = sorted((len(first["conflicts"]), len(second["conflicts"])))
assert conflict_lengths in ([0, 1], [1, 1]), conflict_lengths
for value, peer in ((first, second), (second, first)):
    assert all(item["claim_id"] == peer["claim_id"] for item in value["conflicts"])
lines = open(sys.argv[3], encoding="utf-8").read().splitlines()
assert lines[0] == "workbench-writer-claims/v1"
rows = [line.split("\t") for line in lines[1:]]
claims = [row for row in rows if row[0] == "claim"]
effects = [row for row in rows if row[0] == "effect-owner"]
assert len(claims) == 2 and len(effects) == 2
assert all(row[-1] == "active" for row in claims)
assert all(row[-1] == "acquired" for row in effects)
assert sorted(row[9] == "null" for row in claims) == [False, True]
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

test_writer_rejects_non_append_only_coordination_history() {
  local mode case_name first second out status_out rc
  for mode in rewritten-tip valid-rebuild new-root row-removal historical-rewrite \
    discontinuous-event extra-tree-entry operation-id-reuse claim-id-reuse \
    global-event-id-reuse merge; do
    case_name="writer_history_${mode//-/_}"
    setup_writer_workbench "$case_name"
    prepare_writer_task "$case_name" 29 history; first="$WRITER_TASK_DIR"
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
      run_task_in_dir "$case_name" "$first" add-repo shared-api --format json >/dev/null
    corrupt_writer_coordination_history "$case_name" "$mode"
    status_out="$TMPDIR/$case_name/status.out"
    if run_task "$case_name" "$WRITER_REPO" status --format json >"$status_out" 2>&1; then
      fail "status accepted corrupt coordination history: $mode"
    fi
    assert_file_contains "$status_out" '"code":"writer-lock-unavailable"'
    prepare_writer_task "$case_name" 31 history; second="$WRITER_TASK_DIR"
    out="$TMPDIR/$case_name/rejected.out"
    if WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
      WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
      run_task_in_dir "$case_name" "$second" add-repo shared-api --format json >"$out" 2>&1; then
      fail "writer accepted corrupt coordination history: $mode"
    else rc=$?; fi
    [ "$rc" = 1 ] || fail "corrupt writer history $mode returned $rc"
    assert_file_contains "$out" '"code":"writer-lock-unavailable"'
    [ ! -e "$second/task/codebases/shared-api" ] \
      || fail "corrupt writer history $mode created a worktree"
    ! grep -Fq -- '- shared-api |' "$second/task/index.md" \
      || fail "corrupt writer history $mode created a repo row"
  done
}

test_writer_anchor_is_nofollow_and_exact() {
  local first second actual anchor saved out rc
  setup_writer_workbench writer_anchor_nofollow
  prepare_writer_task writer_anchor_nofollow 29 anchor; first="$WRITER_TASK_DIR"
  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_anchor_nofollow "$first" add-repo shared-api --format json)"
  anchor="$(writer_anchor_path "$WRITER_REPO")"
  [ -f "$anchor" ] || fail "writer publication did not persist a coordination anchor"
  saved="$TMPDIR/writer_anchor_nofollow/saved-anchor"
  mv "$anchor" "$saved"; ln -s "$saved" "$anchor"
  prepare_writer_task writer_anchor_nofollow 31 anchor; second="$WRITER_TASK_DIR"
  out="$TMPDIR/writer_anchor_nofollow/rejected.out"
  if WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_anchor_nofollow "$second" add-repo shared-api --format json \
      >"$out" 2>&1; then
    fail "writer followed a symlinked coordination anchor"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "symlinked writer anchor returned $rc"
  assert_file_contains "$out" '"code":"writer-lock-unavailable"'
  [ ! -e "$second/task/codebases/shared-api" ] || fail "symlinked anchor created a worktree"
}

test_writer_anchor_rejects_symlinked_parent() {
  local task_dir anchor parent saved out rc
  setup_writer_workbench writer_anchor_parent
  prepare_writer_task writer_anchor_parent 29 anchor; task_dir="$WRITER_TASK_DIR"
  anchor="$(writer_anchor_path "$WRITER_REPO")"
  parent="$(dirname "$anchor")"
  saved="$TMPDIR/writer_anchor_parent/saved-workbench-v2"
  mkdir -p "$saved"; ln -s "$saved" "$parent"
  out="$TMPDIR/writer_anchor_parent/rejected.out"
  if WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_anchor_parent "$task_dir" add-repo shared-api --format json \
      >"$out" 2>&1; then
    fail "writer accepted a symlinked anchor parent"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "symlinked writer anchor parent returned $rc"
  assert_file_contains "$out" '"code":"writer-lock-unavailable"'
  [ ! -e "$saved/writer-coordination-anchor" ] \
    || fail "writer wrote its trusted anchor through a symlinked parent"
  [ ! -e "$task_dir/task/codebases/shared-api" ] \
    || fail "symlinked anchor parent created a worktree"
}

test_writer_anchor_rejects_hardlink() {
  local task_dir anchor linked out
  setup_writer_workbench writer_anchor_hardlink
  prepare_writer_task writer_anchor_hardlink 29 anchor; task_dir="$WRITER_TASK_DIR"
  WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
  WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_anchor_hardlink "$task_dir" add-repo shared-api --format json >/dev/null
  anchor="$(writer_anchor_path "$WRITER_REPO")"
  linked="$anchor.link"; ln "$anchor" "$linked"
  out="$TMPDIR/writer_anchor_hardlink/rejected.out"
  if run_task writer_anchor_hardlink "$WRITER_REPO" status --format json >"$out" 2>&1; then
    fail "writer accepted a multiply linked coordination anchor"
  fi
  assert_file_contains "$out" '"code":"writer-lock-unavailable"'
  python3 - "$linked" <<'PY' || fail "writer altered the hardlinked anchor while rejecting it"
import os
import sys

assert os.stat(sys.argv[1], follow_symlinks=False).st_nlink == 2
PY
}

test_writer_anchor_temp_creation_is_exclusive() {
  local common victim
  common="$TMPDIR/writer_anchor_temp/common"
  victim="$TMPDIR/writer_anchor_temp/victim"
  mkdir -p "$common/workbench-v2"
  printf '%s\n' unchanged > "$victim"
  python3 - "$SOURCE_REPO/plugins/workbench/lib/workbench_writer.py" "$common" "$victim" <<'PY'
import importlib.util
import os
import sys

module_path, common, victim = sys.argv[1:]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("workbench_writer", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
module.secrets.token_hex = lambda _: "fixed"
temporary = os.path.join(
    common, "workbench-v2", ".writer-coordination-anchor.tmp-fixed"
)
os.symlink(victim, temporary)
try:
    module.write_coordination_anchor(common, "a" * 40)
except (OSError, ValueError):
    pass
else:
    raise AssertionError("writer anchor replaced a pre-existing temporary path")
assert open(victim, encoding="utf-8").read() == "unchanged\n"
assert os.path.islink(temporary)
os.unlink(temporary)

module.secrets.token_hex = lambda _: "residue"
residue = os.path.join(
    common, "workbench-v2", ".writer-coordination-anchor.tmp-residue"
)
real_replace = module.os.replace
def fail_replace(*args, **kwargs):
    raise OSError("simulated atomic replace failure")
module.os.replace = fail_replace
try:
    module.write_coordination_anchor(common, "b" * 40)
except OSError:
    pass
else:
    raise AssertionError("writer anchor ignored its atomic replace failure")
finally:
    module.os.replace = real_replace
assert os.path.isfile(residue) and not os.path.islink(residue)
assert open(residue, encoding="ascii").read() == "b" * 40 + "\n"
PY
}

test_writer_root_initialization_recovers_once() {
  local task_dir out actual rc ref ledger
  setup_writer_workbench writer_root_recovery
  prepare_writer_task writer_root_recovery 29 root; task_dir="$WRITER_TASK_DIR"
  out="$TMPDIR/writer_root_recovery/interrupted.out"
  if WORKBENCH_TEST_FAIL_AFTER_WRITER_ROOT=1 \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_root_recovery "$task_dir" add-repo shared-api --format json \
      >"$out" 2>&1; then
    fail "writer root interruption unexpectedly completed the first claim"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "writer root interruption returned $rc"
  assert_file_contains "$out" '"code":"writer-lock-unavailable"'
  ref=refs/heads/workbench-coordination/writer-claims
  [ "$(git --git-dir="$TMPDIR/writer_root_recovery/origin.git" rev-list --count "$ref")" = 1 ] \
    || fail "writer root interruption published a non-root event"
  [ "$(git --git-dir="$TMPDIR/writer_root_recovery/origin.git" show "$ref:writer-claims.tsv")" \
    = workbench-writer-claims/v1 ] || fail "writer initialization root is not header-only"
  [ ! -e "$task_dir/task/codebases/shared-api" ] || fail "root interruption created a worktree"

  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_root_recovery "$task_dir" add-repo shared-api --format json)"
  assert_contains "$actual" '"changed":true'
  [ "$(git --git-dir="$TMPDIR/writer_root_recovery/origin.git" rev-list --count "$ref")" = 3 ] \
    || fail "writer root retry did not append claim and owner exactly once"
  ledger="$TMPDIR/writer_root_recovery/writer-claims.tsv"
  git --git-dir="$TMPDIR/writer_root_recovery/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
  [ "$(grep -c '^claim\t' "$ledger")" = 1 ] || fail "writer root retry duplicated its claim"
  [ "$(grep -c '^effect-owner\t' "$ledger")" = 1 ] || fail "writer root retry duplicated owner acquisition"
}

test_writer_first_observation_adopts_durable_anchor() {
  local first second anchor nested out rc
  setup_writer_workbench writer_anchor_adoption
  prepare_writer_task writer_anchor_adoption 29 anchor; first="$WRITER_TASK_DIR"
  WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
  WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_anchor_adoption "$first" add-repo shared-api --format json >/dev/null
  nested="$first/task/codebases/shared-api"
  git -C "$WRITER_REPO/.codebases/shared-api" worktree remove --force "$nested"
  git -C "$WRITER_REPO" worktree remove --force "$first"
  anchor="$(writer_anchor_path "$WRITER_REPO")"; rm -f "$anchor"

  run_task writer_anchor_adoption "$WRITER_REPO" status --format json >/dev/null \
    || fail "fresh writer observation rejected a valid remote history"
  [ -f "$anchor" ] && [ "$(wc -l < "$anchor" | tr -d ' ')" = 1 ] \
    || fail "first valid writer observation did not adopt a durable anchor"
  corrupt_writer_coordination_history writer_anchor_adoption valid-rebuild
  prepare_writer_task writer_anchor_adoption 31 anchor; second="$WRITER_TASK_DIR"
  out="$TMPDIR/writer_anchor_adoption/rejected.out"
  if WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_anchor_adoption "$second" add-repo shared-api --format json \
      >"$out" 2>&1; then
    fail "writer accepted a legal force-rebuild after adopting the prior tip"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "post-observation force-rebuild returned $rc"
  assert_file_contains "$out" '"code":"writer-lock-unavailable"'
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
  local task_dir observation adapter revision actual pending out instance target intent manifest auth claim
  setup_writer_workbench writer_legacy_union
  prepare_writer_task writer_legacy_union 29 union; task_dir="$WRITER_TASK_DIR"
  revision="$(git -C "$WRITER_REPO" rev-parse origin/main)"
  observation="$TMPDIR/writer_legacy_union/legacy-observation.json"
  write_active_legacy_observation "$observation" "$revision" \
    "$(git -C "$WRITER_REPO" remote get-url origin)" shared-api \
    "$TMPDIR/writer_legacy_union/shared-api.git"
  adapter="$TMPDIR/writer_legacy_union/bin/active-legacy-adapter"
  write_fake_legacy_adapter "$adapter" "$observation"

  out="$TMPDIR/writer_legacy_union/pending.out"
  if WORKBENCH_TRUSTED_LEGACY_ADAPTER="$adapter" \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_legacy_union "$task_dir" add-repo shared-api --format json >"$out"; then
    fail "legacy writer conflict must require explicit authorization"
  else
    [ "$?" = 3 ] || fail "legacy writer conflict must ask at exit 3"
  fi
  pending="$(cat "$out")"; assert_contains "$pending" '"decision":"ask"'
  instance="$(json_get "$pending" action_instance.id)"
  target="$(json_get "$pending" action_instance.target_ref)"
  revision="$(json_get "$pending" action_instance.revision)"
  intent="$(json_get "$pending" action_instance.intent_digest)"
  manifest="$(json_get "$pending" action_instance.policy_manifest.digest)"
  claim="$(sed -n 's/^claim_id: *//p' "$task_dir/task/index.md")"
  auth="$TMPDIR/writer_legacy_union/authorization.json"
  write_authorization "$auth" "$instance" task.concurrent-write "$claim" "$target" \
    "$revision" "$manifest" allow owner@example.com 2026-07-11T05:30:00Z \
    conversation:message/writer-legacy-union "$intent"
  actual="$(WORKBENCH_TRUSTED_LEGACY_ADAPTER="$adapter" \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_legacy_union "$task_dir" add-repo shared-api \
      --action-instance-id "$instance" --authorization-file "$auth" --format json)"
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

test_writer_zero_history_rejects_nonexact_remote_binding() {
  local mode case_name task_dir out operation_id operation ledger ref old blob tree commit retry
  local header root_commit anchor
  for mode in expected-path origin context action; do
    case_name="writer_zero_binding_${mode//-/_}"
    setup_writer_workbench "$case_name"
    prepare_writer_task "$case_name" 29 exact; task_dir="$WRITER_TASK_DIR"
    out="$TMPDIR/$case_name/claim-crash.out"
    if WORKBENCH_TEST_FAIL_AFTER_WRITER_CLAIM=1 \
      WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
      WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
      run_task_in_dir "$case_name" "$task_dir" add-repo shared-api --format json >"$out"; then
      fail "zero-history nonexact fixture must stop after its remote claim: $mode"
    fi
    operation_id="$(json_get "$(cat "$out")" operation_id)"
    operation="$task_dir/task/.workbench/writer-operations/$operation_id.json"
    rm "$operation"

    ref=refs/heads/workbench-coordination/writer-claims
    ledger="$TMPDIR/$case_name/writer-claims.tsv"
    git --git-dir="$TMPDIR/$case_name/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
    python3 - "$ledger" "$operation_id" "$mode" <<'PY'
import sys

path, operation_id, mode = sys.argv[1:]
lines = open(path, encoding="utf-8").read().splitlines()
rows = [line.split("\t") for line in lines[1:]]
row = next(item for item in rows if item[0] == "claim" and item[1] == operation_id)
if mode == "expected-path":
    row[6] = "task/codebases/stale-api"
elif mode == "origin":
    row[7] = "/stale/protected/origin.git"
elif mode == "context":
    row[8] = "sha256:" + "a" * 64
elif mode == "action":
    row[9] = "writer-action-stale"
    row[10] = "sha256:" + "b" * 64
    row[11] = "sha256:" + "c" * 64
    row[12] = "null"
else:
    raise AssertionError(mode)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(lines[0] + "\n")
    handle.write("\n".join("\t".join(item) for item in rows) + "\n")
PY
    old="$(git --git-dir="$TMPDIR/$case_name/origin.git" rev-parse "$ref")"
    header="$TMPDIR/$case_name/writer-root.tsv"
    printf '%s\n' workbench-writer-claims/v1 > "$header"
    blob="$(git --git-dir="$TMPDIR/$case_name/origin.git" hash-object -w "$header")"
    tree="$(printf '100644 blob %s\twriter-claims.tsv\n' "$blob" | \
      git --git-dir="$TMPDIR/$case_name/origin.git" mktree)"
    root_commit="$(printf '%s\n' "test: rebuild writer root" | \
      GIT_AUTHOR_NAME='Test User' GIT_AUTHOR_EMAIL=test@example.invalid \
      GIT_COMMITTER_NAME='Test User' GIT_COMMITTER_EMAIL=test@example.invalid \
      git --git-dir="$TMPDIR/$case_name/origin.git" commit-tree "$tree")"
    blob="$(git --git-dir="$TMPDIR/$case_name/origin.git" hash-object -w "$ledger")"
    tree="$(printf '100644 blob %s\twriter-claims.tsv\n' "$blob" | \
      git --git-dir="$TMPDIR/$case_name/origin.git" mktree)"
    commit="$(printf '%s\n' "test: mutate writer binding" | \
      GIT_AUTHOR_NAME='Test User' GIT_AUTHOR_EMAIL=test@example.invalid \
      GIT_COMMITTER_NAME='Test User' GIT_COMMITTER_EMAIL=test@example.invalid \
      git --git-dir="$TMPDIR/$case_name/origin.git" commit-tree "$tree" -p "$root_commit")"
    git --git-dir="$TMPDIR/$case_name/origin.git" update-ref "$ref" "$commit" "$old"
    anchor="$(writer_anchor_path "$WRITER_REPO")"
    rm -f "$anchor"

    retry="$TMPDIR/$case_name/retry.out"
    if WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
      WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
      run_task_in_dir "$case_name" "$task_dir" add-repo shared-api --format json >"$retry"; then
      fail "zero-history recovery accepted a stale $mode binding"
    fi
    assert_file_contains "$retry" '"code":"writer-recovery-blocked"'
    [ ! -e "$task_dir/task/codebases/shared-api" ] \
      || fail "stale $mode binding created a local worktree"
    git --git-dir="$TMPDIR/$case_name/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
    python3 - "$ledger" "$operation_id" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
assert not [row for row in rows if row[0] == "effect-owner" and row[2] == sys.argv[2]]
PY
  done
}

test_writer_operation_cancel_distinguishes_no_effect_from_external_effect() {
  local task_dir observation adapter revision ask_policy out operation operation_id actual
  local claim_task claim_out claim_operation claim_operation_id ledger ref
  setup_writer_workbench writer_operation_cancel
  sed -i.bak 's/action.task.concurrent-write=allow/action.task.concurrent-write=ask/' \
    "$WRITER_REPO/.workbench/policy.conf"
  rm "$WRITER_REPO/.workbench/policy.conf.bak"
  git -C "$WRITER_REPO" add .workbench/policy.conf
  git -C "$WRITER_REPO" commit -q -m "test: require writer authorization"
  git -C "$WRITER_REPO" push -q
  prepare_writer_task writer_operation_cancel 29 cancel; task_dir="$WRITER_TASK_DIR"
  revision="$(git -C "$WRITER_REPO" rev-parse origin/main)"
  observation="$TMPDIR/writer_operation_cancel/legacy-observation.json"
  write_active_legacy_observation "$observation" "$revision" \
    "$(git -C "$WRITER_REPO" remote get-url origin)" shared-api \
    "$TMPDIR/writer_operation_cancel/shared-api.git"
  adapter="$TMPDIR/writer_operation_cancel/bin/active-legacy-adapter"
  write_fake_legacy_adapter "$adapter" "$observation"
  ask_policy="$TMPDIR/writer_operation_cancel/ask.policy"
  printf '%s\n' 'schema=workbench-policy/v1' 'action.task.concurrent-write=ask' > "$ask_policy"
  out="$TMPDIR/writer_operation_cancel/authorization-pending.out"
  if WORKBENCH_TRUSTED_LEGACY_ADAPTER="$adapter" \
    WORKBENCH_PLATFORM_POLICY="$ask_policy" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer-ask \
    run_task_in_dir writer_operation_cancel "$task_dir" add-repo shared-api --format json >"$out"; then
    fail "ask policy must leave a no-effect writer operation pending"
  fi
  operation="$(find "$task_dir/task/.workbench/writer-operations" -name '*.json' -type f)"
  operation_id="$(json_get "$(cat "$operation")" operation_id)"
  [ "$(json_get "$(cat "$operation")" stage)" = authorization-pending ] \
    || fail "ask policy did not retain an authorization-pending operation"

  actual="$(run_task_in_dir writer_operation_cancel "$task_dir" writer-operation show \
    --operation-id "$operation_id" --format json)"
  ACTUAL="$actual" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["ACTUAL"])
assert value["contract_version"] == "workbench-writer-operation-status/v1"
assert value["operation"]["stage"] == "authorization-pending"
assert value["remote_claim_state"] == "absent"
assert value["effect_owner"] is None
assert value["cancellable"] is True
assert value["blockers"] == []
PY

  actual="$(run_task_in_dir writer_operation_cancel "$task_dir" writer-operation cancel \
    --operation-id "$operation_id" --format json)"
  assert_contains "$actual" '"contract_version":"workbench-writer-operation-transition/v1"'
  assert_contains "$actual" '"transition":"cancel"'
  assert_contains "$actual" '"changed":true'
  assert_contains "$actual" '"operation_stage":"cancelled"'
  [ ! -e "$task_dir/task/codebases/shared-api" ] || fail "no-effect cancel created a worktree"
  ! grep -q '^- shared-api |' "$task_dir/task/index.md" \
    || fail "no-effect cancel created a repo row"
  actual="$(run_task_in_dir writer_operation_cancel "$task_dir" writer-operation cancel \
    --operation-id "$operation_id" --format json)"
  assert_contains "$actual" '"changed":false'

  prepare_writer_task writer_operation_cancel 31 claim; claim_task="$WRITER_TASK_DIR"
  claim_out="$TMPDIR/writer_operation_cancel/remote-claim.out"
  if WORKBENCH_TEST_FAIL_AFTER_WRITER_CLAIM=1 \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_operation_cancel "$claim_task" add-repo shared-api --format json \
      >"$claim_out"; then
    fail "remote-claim fixture must stop before local effects"
  fi
  claim_operation_id="$(json_get "$(cat "$claim_out")" operation_id)"
  claim_operation="$claim_task/task/.workbench/writer-operations/$claim_operation_id.json"
  out="$TMPDIR/writer_operation_cancel/cancel-blocked.out"
  if run_task_in_dir writer_operation_cancel "$claim_task" writer-operation cancel \
    --operation-id "$claim_operation_id" --format json >"$out"; then
    fail "cancel must reject an operation with a published claim"
  fi
  assert_file_contains "$out" '"code":"writer-cancel-has-effects"'
  [ "$(json_get "$(cat "$claim_operation")" stage)" = remote-claimed ] \
    || fail "blocked cancel mutated the operation stage"
  [ ! -e "$claim_task/task/codebases/shared-api" ] \
    || fail "blocked cancel unexpectedly created a worktree"
  ref=refs/heads/workbench-coordination/writer-claims
  ledger="$TMPDIR/writer_operation_cancel/writer-claims.tsv"
  git --git-dir="$TMPDIR/writer_operation_cancel/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
  python3 - "$ledger" "$claim_operation_id" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
claims = [row for row in rows if row[0] == "claim" and row[1] == sys.argv[2]]
assert [row[-1] for row in claims] == ["active"]
assert not [row for row in rows if row[0] == "effect-owner" and row[2] == sys.argv[2]]
PY
}

test_writer_operation_handoff_transfers_to_explicit_clone() {
  local task_dir actual operation_id operation common target_device target_clone ledger ref
  setup_writer_workbench writer_operation_handoff
  prepare_writer_task writer_operation_handoff 29 handoff; task_dir="$WRITER_TASK_DIR"
  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_operation_handoff "$task_dir" add-repo shared-api --format json)"
  operation_id="$(json_get "$actual" operation_id)"
  operation="$task_dir/task/.workbench/writer-operations/$operation_id.json"
  target_device=device:fixture/handoff-recipient
  target_clone=11111111-1111-4111-8111-111111111111

  actual="$(run_task_in_dir writer_operation_handoff "$task_dir" writer-operation handoff \
    --operation-id "$operation_id" --to-device-id "$target_device" \
    --to-clone-id "$target_clone" --format json)"
  assert_contains "$actual" '"contract_version":"workbench-writer-operation-transition/v1"'
  assert_contains "$actual" '"transition":"handoff"'
  assert_contains "$actual" '"changed":true'
  assert_contains "$actual" '"operation_stage":"handoff-ready"'
  [ ! -e "$task_dir/task/codebases/shared-api" ] || fail "handoff retained the old worktree"
  ! grep -q '^- shared-api |' "$task_dir/task/index.md" || fail "handoff retained the repo index row"
  [ ! -e "$task_dir/task/.workbench/writer-rows/shared-api.record" ] \
    || fail "handoff retained the writer row"
  python3 - "$operation" "$target_device" "$target_clone" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["stage"] == "handoff-ready"
assert value["device_id"] == sys.argv[2]
assert value["clone_id"] == sys.argv[3]
assert value["effect_owner_state"] == "released"
assert value["worktree_ownership"] == "none"
assert value["repo_record_ownership"] == "none"
PY

  common="$(git -C "$WRITER_REPO" rev-parse --git-common-dir)"
  common="$(cd "$WRITER_REPO" && cd "$common" && pwd)"
  printf '%s\n' "$target_device" > "$common/workbench-v2/device-id"
  printf '%s\n' "$target_clone" > "$common/workbench-v2/clone-id"
  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_operation_handoff "$task_dir" add-repo shared-api --format json)"
  assert_contains "$actual" '"operation_stage":"consumed"'
  [ "$(json_get "$actual" operation_id)" = "$operation_id" ] \
    || fail "handoff recipient replaced the stable operation"
  [ -d "$task_dir/task/codebases/shared-api" ] || fail "handoff recipient did not restore the worktree"
  assert_file_contains "$task_dir/task/index.md" '- shared-api | task/29-v2-lifecycle-fixture-29 | work'

  ref=refs/heads/workbench-coordination/writer-claims
  ledger="$TMPDIR/writer_operation_handoff/writer-claims.tsv"
  git --git-dir="$TMPDIR/writer_operation_handoff/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
  python3 - "$ledger" "$operation_id" "$target_device" "$target_clone" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
claims = [row for row in rows if row[0] == "claim" and row[1] == sys.argv[2]]
effects = [row for row in rows if row[0] == "effect-owner" and row[2] == sys.argv[2]]
assert [row[-1] for row in claims] == ["active"]
assert [row[-1] for row in effects] == ["acquired", "released", "acquired"]
assert effects[-1][4:6] == [sys.argv[3], sys.argv[4]]
assert effects[0][4:6] == effects[1][4:6]
PY
}

test_writer_effect_prefix_crashes_resume_once_only() {
  local stage case_name task_dir out first operation_id claim_id actual ledger ref row_count
  for stage in effect-owner-acquired worktree-attached marker-written repo-index-written writer-row-written; do
    [ -z "${WORKBENCH_PREFIX_STAGE_FILTER:-}" ] \
      || [ "$WORKBENCH_PREFIX_STAGE_FILTER" = "$stage" ] || continue
    case_name="writer_prefix_${stage//-/_}"
    setup_writer_workbench "$case_name"
    prepare_writer_task "$case_name" 29 prefix; task_dir="$WRITER_TASK_DIR"
    out="$TMPDIR/$case_name/interrupted.out"
    if WORKBENCH_TEST_FAIL_WRITER_STAGE="$stage" \
      WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
      WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
      run_task_in_dir "$case_name" "$task_dir" add-repo shared-api --format json >"$out"; then
      fail "writer prefix fixture did not interrupt at $stage"
    fi
    first="$(cat "$out")"
    assert_contains "$first" '"code":"writer-test-interruption"'
    operation_id="$(json_get "$first" operation_id)"; claim_id="$(json_get "$first" claim_id)"
    [ -n "$operation_id" ] && [ -n "$claim_id" ] \
      || fail "writer prefix interruption lost stable identity at $stage"

    if actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
      WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
      run_task_in_dir "$case_name" "$task_dir" add-repo shared-api --format json)"; then
      :
    else
      fail "writer prefix retry failed at $stage: $actual"
    fi
    assert_contains "$actual" '"operation_stage":"consumed"'
    [ "$(json_get "$actual" operation_id)" = "$operation_id" ] \
      || fail "writer prefix retry replaced operation at $stage"
    [ "$(json_get "$actual" claim_id)" = "$claim_id" ] \
      || fail "writer prefix retry replaced claim at $stage"
    row_count="$(grep -Fxc -- '- shared-api | task/29-v2-lifecycle-fixture-29 | work' \
      "$task_dir/task/index.md" || true)"
    [ "$row_count" = 1 ] || fail "writer prefix retry duplicated repo index row at $stage"
    [ -d "$task_dir/task/codebases/shared-api" ] \
      || fail "writer prefix retry did not retain the worktree at $stage"

    ref=refs/heads/workbench-coordination/writer-claims
    ledger="$TMPDIR/$case_name/writer-claims.tsv"
    git --git-dir="$TMPDIR/$case_name/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
    python3 - "$ledger" "$operation_id" "$claim_id" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
claims = [row for row in rows if row[0] == "claim" and row[1:3] == sys.argv[2:4]]
effects = [row for row in rows if row[0] == "effect-owner" and row[2:4] == sys.argv[2:4]]
assert [row[-1] for row in claims] == ["active"]
assert [row[-1] for row in effects] == ["acquired"]
PY
  done
}

test_writer_effect_prefix_mismatch_preserves_external_effects() {
  local task_dir out first operation_id claim_id gitdir marker retry ledger ref
  setup_writer_workbench writer_prefix_mismatch
  prepare_writer_task writer_prefix_mismatch 29 mismatch; task_dir="$WRITER_TASK_DIR"
  out="$TMPDIR/writer_prefix_mismatch/interrupted.out"
  if WORKBENCH_TEST_FAIL_WRITER_STAGE=worktree-attached \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_prefix_mismatch "$task_dir" add-repo shared-api --format json >"$out"; then
    fail "writer mismatch fixture did not stop after worktree attachment"
  fi
  first="$(cat "$out")"; operation_id="$(json_get "$first" operation_id)"
  claim_id="$(json_get "$first" claim_id)"
  gitdir="$(git -C "$task_dir/task/codebases/shared-api" rev-parse --git-dir)"
  marker="$gitdir/workbench-writer-owner.json"
  printf '%s\n' '{"contract_version":"workbench-writer-worktree-owner/v1","operation_id":"wrong"}' \
    > "$marker"
  retry="$TMPDIR/writer_prefix_mismatch/retry.out"
  if WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_prefix_mismatch "$task_dir" add-repo shared-api --format json >"$retry"; then
    fail "writer prefix retry adopted a mismatched ownership marker"
  fi
  assert_file_contains "$retry" '"code":"writer-recovery-blocked"'
  [ -d "$task_dir/task/codebases/shared-api" ] \
    || fail "blocked writer recovery deleted the external worktree"
  ref=refs/heads/workbench-coordination/writer-claims
  ledger="$TMPDIR/writer_prefix_mismatch/writer-claims.tsv"
  git --git-dir="$TMPDIR/writer_prefix_mismatch/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
  python3 - "$ledger" "$operation_id" "$claim_id" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
claims = [row for row in rows if row[0] == "claim" and row[1:3] == sys.argv[2:4]]
effects = [row for row in rows if row[0] == "effect-owner" and row[2:4] == sys.argv[2:4]]
assert [row[-1] for row in claims] == ["active"]
assert [row[-1] for row in effects] == ["acquired"]
PY
}

test_writer_effect_prefix_resumes_bound_conflict_action() {
  local task_dir observation adapter revision out first operation_id action_id actual operation
  local pending instance target intent manifest auth claim
  setup_writer_workbench writer_prefix_action
  prepare_writer_task writer_prefix_action 29 action; task_dir="$WRITER_TASK_DIR"
  revision="$(git -C "$WRITER_REPO" rev-parse origin/main)"
  observation="$TMPDIR/writer_prefix_action/legacy-observation.json"
  write_active_legacy_observation "$observation" "$revision" \
    "$(git -C "$WRITER_REPO" remote get-url origin)" shared-api \
    "$TMPDIR/writer_prefix_action/shared-api.git"
  adapter="$TMPDIR/writer_prefix_action/bin/active-legacy-adapter"
  write_fake_legacy_adapter "$adapter" "$observation"
  out="$TMPDIR/writer_prefix_action/pending.out"
  if WORKBENCH_TRUSTED_LEGACY_ADAPTER="$adapter" \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_prefix_action "$task_dir" add-repo shared-api --format json >"$out"; then
    fail "legacy prefix action must require explicit authorization"
  else
    [ "$?" = 3 ] || fail "legacy prefix action must ask at exit 3"
  fi
  pending="$(cat "$out")"; instance="$(json_get "$pending" action_instance.id)"
  target="$(json_get "$pending" action_instance.target_ref)"
  revision="$(json_get "$pending" action_instance.revision)"
  intent="$(json_get "$pending" action_instance.intent_digest)"
  manifest="$(json_get "$pending" action_instance.policy_manifest.digest)"
  claim="$(sed -n 's/^claim_id: *//p' "$task_dir/task/index.md")"
  auth="$TMPDIR/writer_prefix_action/authorization.json"
  write_authorization "$auth" "$instance" task.concurrent-write "$claim" "$target" \
    "$revision" "$manifest" allow owner@example.com 2026-07-11T05:31:00Z \
    conversation:message/writer-prefix-action "$intent"
  out="$TMPDIR/writer_prefix_action/interrupted.out"
  if WORKBENCH_TEST_FAIL_WRITER_STAGE=writer-row-written \
    WORKBENCH_TRUSTED_LEGACY_ADAPTER="$adapter" \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_prefix_action "$task_dir" add-repo shared-api \
      --action-instance-id "$instance" --authorization-file "$auth" --format json >"$out"; then
    fail "bound action fixture did not interrupt after its writer row"
  fi
  first="$(cat "$out")"; operation_id="$(json_get "$first" operation_id)"
  action_id="$(json_get "$first" action_instance_id)"
  [ -n "$action_id" ] || fail "conflicted writer prefix did not bind an action"
  if actual="$(WORKBENCH_TRUSTED_LEGACY_ADAPTER="$adapter" \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_prefix_action "$task_dir" add-repo shared-api \
      --action-instance-id "$instance" --authorization-file "$auth" --format json)"; then
    :
  else
    fail "bound writer action did not resume: $actual"
  fi
  [ "$(json_get "$actual" operation_id)" = "$operation_id" ] \
    || fail "bound action recovery replaced the operation"
  [ "$(json_get "$actual" action_instance_id)" = "$action_id" ] \
    || fail "bound action recovery replaced the action"
  assert_contains "$actual" '"operation_stage":"consumed"'
  operation="$task_dir/task/.workbench/writer-operations/$operation_id.json"
  [ "$(json_get "$(cat "$operation")" action_instance_id)" = "$action_id" ] \
    || fail "consumed operation lost its conflict action binding"
  assert_file_contains "$task_dir/task/.workbench/actions/$action_id.record" 'status=consumed'
}

test_writer_revalidates_stale_policy_at_effect_boundaries() {
  local decision case_name task_dir first_task policy out first operation_id claim_id
  local retry operation ledger ref rc
  for decision in ask deny; do
    case_name="writer_revalidate_${decision}"
    setup_writer_workbench "$case_name"
    prepare_writer_task "$case_name" 31 first; first_task="$WRITER_TASK_DIR"
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
      run_task_in_dir "$case_name" "$first_task" add-repo shared-api --format json >/dev/null
    prepare_writer_task "$case_name" 29 "${decision}gate"; task_dir="$WRITER_TASK_DIR"
    out="$TMPDIR/$case_name/interrupted.out"
    if WORKBENCH_TEST_FAIL_WRITER_STAGE=worktree-ready \
      WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
      WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
      run_task_in_dir "$case_name" "$task_dir" add-repo shared-api --format json >"$out"; then
      fail "stale $decision policy fixture did not stop after its owned worktree"
    fi
    first="$(cat "$out")"; operation_id="$(json_get "$first" operation_id)"
    claim_id="$(json_get "$first" claim_id)"
    policy="$TMPDIR/$case_name/$decision.policy"
    printf '%s\n' 'schema=workbench-policy/v1' \
      "action.task.concurrent-write=$decision" > "$policy"
    retry="$TMPDIR/$case_name/retry.out"
    if WORKBENCH_PLATFORM_POLICY="$policy" \
      WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
      run_task_in_dir "$case_name" "$task_dir" add-repo shared-api --format json >"$retry"; then
      fail "writer ignored stale allow-to-$decision before its repo record"
    else
      rc=$?
    fi
    operation="$task_dir/task/.workbench/writer-operations/$operation_id.json"
    ! grep -q '^- shared-api |' "$task_dir/task/index.md" \
      || fail "stale $decision policy wrote a repo index row"
    [ ! -e "$task_dir/task/.workbench/writer-rows/shared-api.record" ] \
      || fail "stale $decision policy wrote a writer row"

    ref=refs/heads/workbench-coordination/writer-claims
    ledger="$TMPDIR/$case_name/writer-claims.tsv"
    git --git-dir="$TMPDIR/$case_name/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
    if [ "$decision" = ask ]; then
      [ "$rc" = 3 ] || fail "stale ask must exit 3, got $rc"
      assert_file_contains "$retry" '"decision":"ask"'
      [ ! -e "$task_dir/task/codebases/shared-api" ] \
        || fail "ask compensation retained an owned local worktree"
      [ "$(json_get "$(cat "$operation")" stage)" = remote-claimed ] \
        || fail "ask compensation did not return to the reservation stage"
      [ "$(json_get "$(cat "$operation")" compensation_target)" = "" ] \
        || fail "ask compensation did not clear its completed cursor"
      python3 - "$ledger" "$operation_id" "$claim_id" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
claims = [row for row in rows if row[0] == "claim" and row[1:3] == sys.argv[2:4]]
effects = [row for row in rows if row[0] == "effect-owner" and row[2:4] == sys.argv[2:4]]
assert [row[-1] for row in claims] == ["active"]
assert [row[-1] for row in effects] == ["acquired", "released"]
PY
    else
      [ "$rc" = 4 ] || fail "stale deny must exit 4, got $rc"
      assert_file_contains "$retry" '"decision":"deny"'
      [ ! -e "$task_dir/task/codebases/shared-api" ] \
        || fail "deny compensation retained the owned worktree"
      [ "$(json_get "$(cat "$operation")" stage)" = released ] \
        || fail "deny compensation did not release the operation"
      python3 - "$ledger" "$operation_id" "$claim_id" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
claims = [row for row in rows if row[0] == "claim" and row[1:3] == sys.argv[2:4]]
effects = [row for row in rows if row[0] == "effect-owner" and row[2:4] == sys.argv[2:4]]
assert [row[-1] for row in claims] == ["active", "released"]
assert [row[-1] for row in effects] == ["acquired", "released"]
PY
    fi
  done
}

test_writer_revalidates_legacy_union_before_first_primary() {
  local task_dir out first operation_id claim_id observation adapter revision retry operation ledger ref rc
  setup_writer_workbench writer_revalidate_union
  prepare_writer_task writer_revalidate_union 29 uniongate; task_dir="$WRITER_TASK_DIR"
  out="$TMPDIR/writer_revalidate_union/claim.out"
  if WORKBENCH_TEST_FAIL_AFTER_WRITER_CLAIM=1 \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_revalidate_union "$task_dir" add-repo shared-api --format json >"$out"; then
    fail "legacy union drift fixture did not stop after its claim"
  fi
  first="$(cat "$out")"; operation_id="$(json_get "$first" operation_id)"
  claim_id="$(json_get "$first" claim_id)"
  revision="$(git -C "$WRITER_REPO" rev-parse origin/main)"
  observation="$TMPDIR/writer_revalidate_union/active-legacy.json"
  write_active_legacy_observation "$observation" "$revision" \
    "$(git -C "$WRITER_REPO" remote get-url origin)" shared-api \
    "$TMPDIR/writer_revalidate_union/shared-api.git"
  adapter="$TMPDIR/writer_revalidate_union/bin/active-legacy-adapter"
  write_fake_legacy_adapter "$adapter" "$observation"
  retry="$TMPDIR/writer_revalidate_union/retry.out"
  if WORKBENCH_TRUSTED_LEGACY_ADAPTER="$adapter" \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_revalidate_union "$task_dir" add-repo shared-api --format json >"$retry"; then
    fail "writer ignored a changed legacy union before effect ownership"
  else
    rc=$?
  fi
  [ "$rc" = 3 ] || fail "new legacy conflict must reserve at exit 3, got $rc"
  assert_file_contains "$retry" '"decision":"ask"'
  [ ! -e "$task_dir/task/codebases/shared-api" ] \
    || fail "legacy union drift created a local worktree"
  operation="$task_dir/task/.workbench/writer-operations/$operation_id.json"
  [ "$(json_get "$(cat "$operation")" stage)" = remote-claimed ] \
    || fail "legacy union drift did not retain its reservation"
  [ -n "$(json_get "$(cat "$operation")" action_instance_id)" ] \
    || fail "legacy union drift did not persist its replacement action"
  ref=refs/heads/workbench-coordination/writer-claims
  ledger="$TMPDIR/writer_revalidate_union/writer-claims.tsv"
  git --git-dir="$TMPDIR/writer_revalidate_union/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
  python3 - "$ledger" "$operation_id" "$claim_id" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
assert [row[-1] for row in rows if row[0] == "claim" and row[1:3] == sys.argv[2:4]] == ["active"]
assert not [row for row in rows if row[0] == "effect-owner" and row[2:4] == sys.argv[2:4]]
PY
}

test_writer_union_ambiguity_preserves_claim_and_cursor() {
  local task_dir out first operation_id claim_id operation operation_before
  local retry ledger ref coordination_before rc
  setup_writer_workbench writer_revalidate_union_ambiguous
  prepare_writer_task writer_revalidate_union_ambiguous 29 unionunknown; task_dir="$WRITER_TASK_DIR"
  out="$TMPDIR/writer_revalidate_union_ambiguous/claim.out"
  if WORKBENCH_TEST_FAIL_AFTER_WRITER_CLAIM=1 \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_revalidate_union_ambiguous "$task_dir" \
      add-repo shared-api --format json >"$out"; then
    fail "union ambiguity fixture did not stop after its claim"
  fi
  first="$(cat "$out")"; operation_id="$(json_get "$first" operation_id)"
  claim_id="$(json_get "$first" claim_id)"
  operation="$task_dir/task/.workbench/writer-operations/$operation_id.json"
  operation_before="$(git hash-object "$operation")"
  ref=refs/heads/workbench-coordination/writer-claims
  coordination_before="$(git --git-dir="$TMPDIR/writer_revalidate_union_ambiguous/origin.git" \
    rev-parse "$ref")"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 9' \
    > "$TMPDIR/writer_revalidate_union_ambiguous/bin/legacy-adapter"
  chmod +x "$TMPDIR/writer_revalidate_union_ambiguous/bin/legacy-adapter"

  retry="$TMPDIR/writer_revalidate_union_ambiguous/retry.out"
  if WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_revalidate_union_ambiguous "$task_dir" \
      add-repo shared-api --format json >"$retry"; then
    fail "writer proceeded with an incomplete legacy union"
  else
    rc=$?
  fi
  [ "$rc" = 1 ] || fail "union ambiguity must exit 1, got $rc"
  assert_file_contains "$retry" '"code":"writer-recovery-blocked"'
  [ "$(git hash-object "$operation")" = "$operation_before" ] \
    || fail "union ambiguity mutated the operation cursor"
  [ "$(git --git-dir="$TMPDIR/writer_revalidate_union_ambiguous/origin.git" \
    rev-parse "$ref")" = "$coordination_before" ] \
    || fail "union ambiguity mutated the coordination ledger"
  [ ! -e "$task_dir/task/codebases/shared-api" ] \
    || fail "union ambiguity created a local worktree"
  ledger="$TMPDIR/writer_revalidate_union_ambiguous/writer-claims.tsv"
  git --git-dir="$TMPDIR/writer_revalidate_union_ambiguous/origin.git" \
    show "$ref:writer-claims.tsv" > "$ledger"
  python3 - "$ledger" "$operation_id" "$claim_id" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
assert [row[-1] for row in rows if row[0] == "claim" and row[1:3] == sys.argv[2:4]] == ["active"]
assert not [row for row in rows if row[0] == "effect-owner" and row[2:4] == sys.argv[2:4]]
PY
}

test_writer_compensation_prefixes_resume_exact_cursor() {
  local decision case_name first_task task_dir policy out first operation_id claim_id
  local interrupted resumed operation ledger ref rc expected_stage expected_cursor
  local prefix_stage compensation_stage
  for decision in ask deny; do
    case_name="writer_compensation_resume_$decision"
    setup_writer_workbench "$case_name"
    prepare_writer_task "$case_name" 31 first; first_task="$WRITER_TASK_DIR"
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
      run_task_in_dir "$case_name" "$first_task" add-repo shared-api --format json >/dev/null
    prepare_writer_task "$case_name" 29 "${decision}resume"; task_dir="$WRITER_TASK_DIR"
    if [ "$decision" = ask ]; then
      prefix_stage=writer-row-written; compensation_stage=record-removed
    else
      prefix_stage=worktree-ready; compensation_stage=claim-released
    fi
    out="$TMPDIR/$case_name/prefix.out"
    if WORKBENCH_TEST_FAIL_WRITER_STAGE="$prefix_stage" \
      WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
      WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
      run_task_in_dir "$case_name" "$task_dir" add-repo shared-api --format json >"$out"; then
      fail "compensation $decision fixture did not stop at $prefix_stage"
    fi
    first="$(cat "$out")"; operation_id="$(json_get "$first" operation_id)"
    claim_id="$(json_get "$first" claim_id)"
    operation="$task_dir/task/.workbench/writer-operations/$operation_id.json"
    policy="$TMPDIR/$case_name/$decision.policy"
    printf '%s\n' 'schema=workbench-policy/v1' \
      "action.task.concurrent-write=$decision" > "$policy"
    interrupted="$TMPDIR/$case_name/compensation-interrupted.out"
    if WORKBENCH_TEST_FAIL_WRITER_STAGE="compensation-$compensation_stage" \
      WORKBENCH_PLATFORM_POLICY="$policy" \
      WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
      run_task_in_dir "$case_name" "$task_dir" add-repo shared-api --format json \
        >"$interrupted"; then
      fail "compensation $decision interruption unexpectedly succeeded"
    else
      rc=$?
    fi
    [ "$rc" = 1 ] || fail "compensation $decision interruption must exit 1, got $rc"
    assert_file_contains "$interrupted" '"code":"writer-recovery-blocked"'
    if [ "$decision" = ask ]; then
      expected_stage=compensation-pending; expected_cursor=record
    else
      expected_stage=release-pending; expected_cursor=claim
    fi
    [ "$(json_get "$(cat "$operation")" stage)" = "$expected_stage" ] \
      || fail "compensation $decision lost its durable stage"
    [ "$(json_get "$(cat "$operation")" compensation_next_step)" = "$expected_cursor" ] \
      || fail "compensation $decision advanced past its interrupted cursor"

    resumed="$TMPDIR/$case_name/resumed.out"
    if WORKBENCH_PLATFORM_POLICY="$policy" \
      WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
      run_task_in_dir "$case_name" "$task_dir" add-repo shared-api --format json >"$resumed"; then
      fail "compensation $decision retry unexpectedly returned success"
    else
      rc=$?
    fi
    [ "$rc" = "$([ "$decision" = ask ] && printf 3 || printf 4)" ] \
      || fail "compensation $decision retry returned $rc"
    [ ! -e "$task_dir/task/codebases/shared-api" ] \
      || fail "compensation $decision retry retained its worktree"
    ref=refs/heads/workbench-coordination/writer-claims
    ledger="$TMPDIR/$case_name/writer-claims.tsv"
    git --git-dir="$TMPDIR/$case_name/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
    python3 - "$ledger" "$operation_id" "$claim_id" "$decision" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
claims = [row[-1] for row in rows if row[0] == "claim" and row[1:3] == sys.argv[2:4]]
effects = [row[-1] for row in rows if row[0] == "effect-owner" and row[2:4] == sys.argv[2:4]]
assert claims == (["active"] if sys.argv[4] == "ask" else ["active", "released"])
assert effects == ["acquired", "released"]
PY
    [ "$(json_get "$(cat "$operation")" stage)" \
      = "$([ "$decision" = ask ] && printf remote-claimed || printf released)" ] \
      || fail "compensation $decision retry did not finish its exact target"
  done
}

test_writer_persists_allow_replacement_before_first_effect() {
  local task_dir competing out first operation_id claim_id actual operation ledger ref
  setup_writer_workbench writer_revalidate_allow
  prepare_writer_task writer_revalidate_allow 29 allowgate; task_dir="$WRITER_TASK_DIR"
  out="$TMPDIR/writer_revalidate_allow/claim.out"
  if WORKBENCH_TEST_FAIL_AFTER_WRITER_CLAIM=1 \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_revalidate_allow "$task_dir" add-repo shared-api --format json >"$out"; then
    fail "allow replacement fixture did not stop after its claim"
  fi
  first="$(cat "$out")"; operation_id="$(json_get "$first" operation_id)"
  claim_id="$(json_get "$first" claim_id)"
  [ "$(json_get "$first" action_instance_id)" = "" ] \
    || fail "allow replacement fixture unexpectedly started with a conflict action"

  prepare_writer_task writer_revalidate_allow 31 competitor; competing="$WRITER_TASK_DIR"
  WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
  WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_revalidate_allow "$competing" add-repo shared-api --format json >/dev/null

  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_revalidate_allow "$task_dir" add-repo shared-api --format json)"
  assert_contains "$actual" '"operation_stage":"consumed"'
  [ "$(json_get "$actual" operation_id)" = "$operation_id" ] \
    || fail "allow replacement changed the stable operation"
  [ -n "$(json_get "$actual" action_instance_id)" ] \
    || fail "allow replacement did not persist its new action binding"
  operation="$task_dir/task/.workbench/writer-operations/$operation_id.json"
  [ -n "$(json_get "$(cat "$operation")" action_instance_id)" ] \
    || fail "allow replacement operation retained the claim-time null binding"

  ref=refs/heads/workbench-coordination/writer-claims
  ledger="$TMPDIR/writer_revalidate_allow/writer-claims.tsv"
  git --git-dir="$TMPDIR/writer_revalidate_allow/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
  python3 - "$ledger" "$operation_id" "$claim_id" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
claim = next(row for row in rows if row[0] == "claim" and row[1:3] == sys.argv[2:4])
assert claim[9:13] == ["null", "null", "null", "null"]
assert [row[-1] for row in rows if row[0] == "effect-owner" and row[2:4] == sys.argv[2:4]] == ["acquired"]
PY
}

test_writer_authority_revalidation_fails_closed_without_compensation() {
  local task_dir out first operation_id claim_id retry ledger ref
  setup_writer_workbench writer_revalidate_authority
  prepare_writer_task writer_revalidate_authority 29 authgate; task_dir="$WRITER_TASK_DIR"
  out="$TMPDIR/writer_revalidate_authority/claim.out"
  if WORKBENCH_TEST_FAIL_AFTER_WRITER_CLAIM=1 \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_revalidate_authority "$task_dir" add-repo shared-api --format json >"$out"; then
    fail "authority drift fixture did not stop after its claim"
  fi
  first="$(cat "$out")"; operation_id="$(json_get "$first" operation_id)"
  claim_id="$(json_get "$first" claim_id)"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 9' \
    > "$TMPDIR/writer_revalidate_authority/bin/hosting-authority"
  chmod +x "$TMPDIR/writer_revalidate_authority/bin/hosting-authority"
  retry="$TMPDIR/writer_revalidate_authority/retry.out"
  if WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_revalidate_authority "$task_dir" add-repo shared-api --format json \
      >"$retry" 2>&1; then
    fail "writer proceeded after authority revalidation failed"
  fi
  assert_file_contains "$retry" 'policy-authority-unavailable'
  [ ! -e "$task_dir/task/codebases/shared-api" ] \
    || fail "authority failure created a local worktree"
  ref=refs/heads/workbench-coordination/writer-claims
  ledger="$TMPDIR/writer_revalidate_authority/writer-claims.tsv"
  git --git-dir="$TMPDIR/writer_revalidate_authority/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
  python3 - "$ledger" "$operation_id" "$claim_id" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
assert [row[-1] for row in rows if row[0] == "claim" and row[1:3] == sys.argv[2:4]] == ["active"]
assert not [row for row in rows if row[0] == "effect-owner" and row[2:4] == sys.argv[2:4]]
PY
}

test_terminal_writer_verification_joins_exact_record_and_lifecycle_provenance() {
  local task_dir actual operation_id row out rc
  setup_writer_workbench writer_terminal_join
  prepare_writer_task writer_terminal_join 29 terminaljoin; task_dir="$WRITER_TASK_DIR"
  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_terminal_join "$task_dir" add-repo shared-api --format json)"
  operation_id="$(json_get "$actual" operation_id)"
  row="$task_dir/task/.workbench/writer-rows/shared-api.record"
  python3 - "$row" <<'PY'
import sys

path = sys.argv[1]
rows = []
for raw in open(path, encoding="utf-8"):
    key, value = raw.rstrip("\n").split("=", 1)
    if key == "branch":
        value = "task/forged-lifecycle"
    rows.append((key, value))
with open(path, "w", encoding="utf-8") as handle:
    for key, value in rows:
        handle.write(f"{key}={value}\n")
PY

  out="$TMPDIR/writer_terminal_join/verify.out"
  if run_task_in_dir writer_terminal_join "$task_dir" verify --format json >"$out" 2>&1; then
    fail "writer verification accepted a row detached from operation and task lifecycle provenance"
  else
    rc=$?
  fi
  [ "$rc" = 1 ] || fail "detached writer provenance must fail at exit 1, got $rc"
  assert_file_contains "$out" '"code":"writer-claim-unreconciled"'
  assert_file_contains "$out" "\"ref\":\"$operation_id\""
}

test_cleanup_retires_consumed_writer_before_local_deletion() {
  local task_dir actual operation_id claim_id ledger ref comments operation gitdir marker backup out
  local observation revision legacy_adapter frozen_task_oid
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
  frozen_task_oid="$(git -C "$task_dir" rev-parse HEAD)"
  actual="$(WORKBENCH_TRUSTED_LEGACY_ADAPTER="$legacy_adapter" \
    run_task writer_cleanup "$WRITER_REPO" status --format json)"
  assert_contains "$actual" "\"claim_id\":\"$(sed -n 's/^claim_id: *//p' "$task_dir/task/index.md")\""
  assert_contains "$actual" '"task_contract":"workbench-task/v2"'

  out="$TMPDIR/writer_cleanup/completed-journal-failure.out"
  if GH_FAIL_CLEANUP_STAGE=completed \
    run_task writer_cleanup "$WRITER_REPO" done 29 --format json >"$out" 2>&1; then
    fail "writer cleanup must report a completed journal failure after deletion"
  fi
  assert_file_contains "$out" '"code":"cleanup-journal-unavailable"'
  [ ! -d "$task_dir" ] || fail "prepared writer cleanup did not remove the task workspace"
  [ "$(git --git-dir="$TMPDIR/writer_cleanup/origin.git" \
    rev-parse refs/heads/task/29-v2-lifecycle-fixture-29)" = "$frozen_task_oid" ] \
    || fail "cleanup rewrote frozen terminal task content"
  out="$TMPDIR/writer_cleanup/retry-after-deletion.out"
  if run_task writer_cleanup "$WRITER_REPO" done 29 --format json >"$out" 2>&1; then
    actual="$(cat "$out")"
  else
    fail "external cleanup journal could not recover its writer after workspace deletion: $(cat "$out")"
  fi
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

test_cleanup_removal_failure_keeps_remote_claim_reserved() {
  local task_dir actual operation_id claim_id worktree out rc ledger ref
  setup_writer_workbench cleanup_removal_failure
  printf '%s\n' 'action.task.abandon=allow' >> "$WRITER_REPO/.workbench/policy.conf"
  git -C "$WRITER_REPO" add .workbench/policy.conf
  git -C "$WRITER_REPO" commit -q -m "test: allow cleanup removal failure fixture"
  git -C "$WRITER_REPO" push -q
  prepare_writer_task cleanup_removal_failure 29 cleanup; task_dir="$WRITER_TASK_DIR"
  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir cleanup_removal_failure "$task_dir" add-repo shared-api --format json)"
  operation_id="$(json_get "$actual" operation_id)"
  claim_id="$(json_get "$actual" claim_id)"
  worktree="$task_dir/task/codebases/shared-api"
  run_task_in_dir cleanup_removal_failure "$task_dir" abandon \
    --reason-code superseded --reason-ref issue:78 --format json >/dev/null
  git -C "$task_dir" add task
  if ! git -C "$task_dir" diff --cached --quiet; then
    git -C "$task_dir" commit -q -m "test: persist removal failure terminal"
  fi
  git -C "$task_dir" push -q

  out="$TMPDIR/cleanup_removal_failure/done.out"
  if GH_CLEANUP_RACE_DIRTY_WORKTREE="$worktree" \
    run_task cleanup_removal_failure "$WRITER_REPO" done 29 --format json >"$out" 2>&1; then
    fail "cleanup unexpectedly removed a worktree changed after its prepared journal"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "cleanup removal failure returned $rc"
  [ -d "$task_dir" ] || fail "cleanup removal failure removed the outer task workspace"
  [ -f "$worktree/RACE.txt" ] || fail "cleanup removal race did not reach the worktree"

  ref=refs/heads/workbench-coordination/writer-claims
  ledger="$TMPDIR/cleanup_removal_failure/writer-claims.tsv"
  git --git-dir="$TMPDIR/cleanup_removal_failure/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
  python3 - "$ledger" "$operation_id" "$claim_id" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
claims = [row for row in rows if row[0] == "claim" and row[1:3] == sys.argv[2:4]]
effects = [row for row in rows if row[0] == "effect-owner" and row[2:4] == sys.argv[2:4]]
assert claims[-1][-1] == "active", claims
assert effects[-1][-1] == "acquired", effects
PY
}

test_cleanup_rejects_symlinked_external_worktree_with_copied_marker() {
  local task_dir actual operation_id claim_id worktree external original_gitdir external_gitdir
  local out rc ledger ref
  setup_writer_workbench cleanup_symlink_ownership
  printf '%s\n' 'action.task.abandon=allow' >> "$WRITER_REPO/.workbench/policy.conf"
  git -C "$WRITER_REPO" add .workbench/policy.conf
  git -C "$WRITER_REPO" commit -q -m "test: allow cleanup ownership fixture"
  git -C "$WRITER_REPO" push -q
  prepare_writer_task cleanup_symlink_ownership 29 cleanup; task_dir="$WRITER_TASK_DIR"
  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir cleanup_symlink_ownership "$task_dir" add-repo shared-api --format json)"
  operation_id="$(json_get "$actual" operation_id)"
  claim_id="$(json_get "$actual" claim_id)"
  worktree="$task_dir/task/codebases/shared-api"
  external="$TMPDIR/cleanup_symlink_ownership/external-shared-api"
  git clone -q "$TMPDIR/cleanup_symlink_ownership/shared-api.git" "$external"
  git -C "$external" switch -q -c task/29-v2-lifecycle-fixture-29 origin/main
  original_gitdir="$(git -C "$worktree" rev-parse --git-dir)"
  external_gitdir="$(git -C "$external" rev-parse --git-dir)"
  case "$original_gitdir" in /*) ;; *) original_gitdir="$worktree/$original_gitdir" ;; esac
  case "$external_gitdir" in /*) ;; *) external_gitdir="$external/$external_gitdir" ;; esac
  cp "$original_gitdir/workbench-writer-owner.json" \
    "$external_gitdir/workbench-writer-owner.json"
  run_task_in_dir cleanup_symlink_ownership "$task_dir" abandon \
    --reason-code superseded --reason-ref issue:79 --format json >/dev/null
  git -C "$task_dir" add task
  if ! git -C "$task_dir" diff --cached --quiet; then
    git -C "$task_dir" commit -q -m "test: persist ownership terminal"
  fi
  git -C "$task_dir" push -q

  out="$TMPDIR/cleanup_symlink_ownership/done.out"
  if GH_CLEANUP_RACE_SYMLINK_WORKTREE="$worktree" \
    GH_CLEANUP_RACE_SYMLINK_TARGET="$external" \
    run_task cleanup_symlink_ownership "$WRITER_REPO" done 29 --format json >"$out" 2>&1; then
    fail "cleanup accepted a symlinked external worktree with a copied marker"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "symlinked cleanup ownership returned $rc"
  assert_file_contains "$out" '"code":"cleanup-ownership-mismatch"'
  [ -L "$worktree" ] || fail "cleanup ownership check replaced the attack symlink"
  [ -d "$external" ] || fail "cleanup ownership check removed the external worktree"
  [ -d "$worktree.original" ] || fail "cleanup ownership check removed the owned worktree"

  ref=refs/heads/workbench-coordination/writer-claims
  ledger="$TMPDIR/cleanup_symlink_ownership/writer-claims.tsv"
  git --git-dir="$TMPDIR/cleanup_symlink_ownership/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
  python3 - "$ledger" "$operation_id" "$claim_id" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
claims = [row for row in rows if row[0] == "claim" and row[1:3] == sys.argv[2:4]]
effects = [row for row in rows if row[0] == "effect-owner" and row[2:4] == sys.argv[2:4]]
assert claims[-1][-1] == "active", claims
assert effects[-1][-1] == "acquired", effects
PY
}

test_cleanup_revalidates_exact_descriptor_before_removal() {
  local task_dir actual operation_id claim_id worktree hook out rc ledger ref
  setup_writer_workbench cleanup_descriptor_race
  printf '%s\n' 'action.task.abandon=allow' >> "$WRITER_REPO/.workbench/policy.conf"
  git -C "$WRITER_REPO" add .workbench/policy.conf
  git -C "$WRITER_REPO" commit -q -m "test: allow cleanup descriptor fixture"
  git -C "$WRITER_REPO" push -q
  prepare_writer_task cleanup_descriptor_race 29 cleanup; task_dir="$WRITER_TASK_DIR"
  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir cleanup_descriptor_race "$task_dir" add-repo shared-api --format json)"
  operation_id="$(json_get "$actual" operation_id)"
  claim_id="$(json_get "$actual" claim_id)"
  worktree="$task_dir/task/codebases/shared-api"
  hook="$TMPDIR/cleanup_descriptor_race/replace-worktree"
  cat > "$hook" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
worktree="$1"
origin="$2"
branch="$3"
original_gitdir="$(git -C "$worktree" rev-parse --git-dir)"
case "$original_gitdir" in /*) ;; *) original_gitdir="$worktree/$original_gitdir" ;; esac
mv "$worktree" "$worktree.original"
git clone -q "$origin" "$worktree"
git -C "$worktree" switch -q -c "$branch" origin/main
replacement_gitdir="$(git -C "$worktree" rev-parse --git-dir)"
case "$replacement_gitdir" in /*) ;; *) replacement_gitdir="$worktree/$replacement_gitdir" ;; esac
cp "$original_gitdir/workbench-writer-owner.json" \
  "$replacement_gitdir/workbench-writer-owner.json"
EOF
  chmod +x "$hook"
  run_task_in_dir cleanup_descriptor_race "$task_dir" abandon \
    --reason-code superseded --reason-ref issue:80 --format json >/dev/null
  git -C "$task_dir" add task
  if ! git -C "$task_dir" diff --cached --quiet; then
    git -C "$task_dir" commit -q -m "test: persist descriptor terminal"
  fi
  git -C "$task_dir" push -q

  out="$TMPDIR/cleanup_descriptor_race/done.out"
  if WORKBENCH_TEST_CLEANUP_DESCRIPTOR_HOOK="$hook" \
    run_task cleanup_descriptor_race "$WRITER_REPO" done 29 --format json >"$out" 2>&1; then
    fail "cleanup accepted a worktree replaced after its ownership snapshot"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "descriptor replacement returned $rc"
  assert_file_contains "$out" '"code":"cleanup-ownership-mismatch"'
  [ -d "$worktree" ] || fail "descriptor mismatch removed the replacement worktree"
  [ -d "$worktree.original" ] || fail "descriptor mismatch removed the owned worktree"

  ref=refs/heads/workbench-coordination/writer-claims
  ledger="$TMPDIR/cleanup_descriptor_race/writer-claims.tsv"
  git --git-dir="$TMPDIR/cleanup_descriptor_race/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
  python3 - "$ledger" "$operation_id" "$claim_id" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
claims = [row for row in rows if row[0] == "claim" and row[1:3] == sys.argv[2:4]]
effects = [row for row in rows if row[0] == "effect-owner" and row[2:4] == sys.argv[2:4]]
assert claims[-1][-1] == "active", claims
assert effects[-1][-1] == "acquired", effects
PY
}

test_cleanup_descriptor_pins_task_and_clone_common_dirs() {
  local task_dir actual operation_id operation worktree clone workspace_origin codebase_branch
  local helper alien_task alien_clone task_gitfile clone_admin out
  setup_writer_workbench cleanup_common_dirs
  prepare_writer_task cleanup_common_dirs 29 cleanup; task_dir="$WRITER_TASK_DIR"
  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir cleanup_common_dirs "$task_dir" add-repo shared-api --format json)"
  operation_id="$(json_get "$actual" operation_id)"
  operation="$task_dir/task/.workbench/writer-operations/$operation_id.json"
  worktree="$task_dir/task/codebases/shared-api"
  clone="$WRITER_REPO/.codebases/shared-api"
  workspace_origin="$(git -C "$WRITER_REPO" remote get-url origin)"
  codebase_branch="$(git -C "$worktree" symbolic-ref --short HEAD)"
  helper="$WRITER_REPO/lib/workbench_writer.py"
  python3 "$helper" cleanup-descriptor --workspace-root "$WRITER_REPO" \
    --workspace-origin-url "$workspace_origin" --task-dir "$task_dir" \
    --worktree "$worktree" --clone "$clone" --operation-file "$operation" \
    --codebase-branch "$codebase_branch" >/dev/null \
    || fail "canonical cleanup descriptor fixture was rejected"

  git -C "$worktree" switch -q -c cleanup-wrong-branch
  out="$TMPDIR/cleanup_common_dirs/wrong-branch.out"
  if python3 "$helper" cleanup-descriptor --workspace-root "$WRITER_REPO" \
    --workspace-origin-url "$workspace_origin" --task-dir "$task_dir" \
    --worktree "$worktree" --clone "$clone" --operation-file "$operation" \
    --codebase-branch "$codebase_branch" >"$out" 2>&1; then
    fail "cleanup descriptor accepted the wrong worktree branch"
  fi
  git -C "$worktree" switch -q "$codebase_branch"
  git -C "$worktree" branch -D cleanup-wrong-branch >/dev/null

  git -C "$worktree" remote set-url origin "$TMPDIR/cleanup_common_dirs/wrong-origin.git"
  out="$TMPDIR/cleanup_common_dirs/wrong-origin.out"
  if python3 "$helper" cleanup-descriptor --workspace-root "$WRITER_REPO" \
    --workspace-origin-url "$workspace_origin" --task-dir "$task_dir" \
    --worktree "$worktree" --clone "$clone" --operation-file "$operation" \
    --codebase-branch "$codebase_branch" >"$out" 2>&1; then
    fail "cleanup descriptor accepted the wrong worktree origin"
  fi
  git -C "$worktree" remote set-url origin "$TMPDIR/cleanup_common_dirs/shared-api.git"

  alien_task="$TMPDIR/cleanup_common_dirs/alien-task"
  git clone -q "$TMPDIR/cleanup_common_dirs/origin.git" "$alien_task"
  git -C "$alien_task" switch -q -c task/29-v2-lifecycle-fixture-29 \
    origin/task/29-v2-lifecycle-fixture-29
  task_gitfile="$task_dir/.git"
  cp "$task_gitfile" "$task_gitfile.saved"
  printf 'gitdir: %s/.git\n' "$alien_task" > "$task_gitfile"
  out="$TMPDIR/cleanup_common_dirs/task-common.out"
  if python3 "$helper" cleanup-descriptor --workspace-root "$WRITER_REPO" \
    --workspace-origin-url "$workspace_origin" --task-dir "$task_dir" \
    --worktree "$worktree" --clone "$clone" --operation-file "$operation" \
    --codebase-branch "$codebase_branch" >"$out" 2>&1; then
    fail "cleanup descriptor accepted a task detached from the workspace common directory"
  fi
  mv "$task_gitfile.saved" "$task_gitfile"

  alien_clone="$TMPDIR/cleanup_common_dirs/alien-clone-admin"
  clone_admin="$clone/.git"
  mv "$clone_admin" "$alien_clone"
  printf 'gitdir: %s\n' "$alien_clone" > "$clone_admin"
  out="$TMPDIR/cleanup_common_dirs/clone-common.out"
  if python3 "$helper" cleanup-descriptor --workspace-root "$WRITER_REPO" \
    --workspace-origin-url "$workspace_origin" --task-dir "$task_dir" \
    --worktree "$worktree" --clone "$clone" --operation-file "$operation" \
    --codebase-branch "$codebase_branch" >"$out" 2>&1; then
    fail "cleanup descriptor accepted a clone detached from its pinned admin directory"
  fi
}

test_cleanup_rejects_broken_symlink_worktree() {
  local task_dir actual operation_id claim_id worktree missing out rc ledger ref
  setup_writer_workbench cleanup_broken_symlink
  printf '%s\n' 'action.task.abandon=allow' >> "$WRITER_REPO/.workbench/policy.conf"
  git -C "$WRITER_REPO" add .workbench/policy.conf
  git -C "$WRITER_REPO" commit -q -m "test: allow broken symlink cleanup fixture"
  git -C "$WRITER_REPO" push -q
  prepare_writer_task cleanup_broken_symlink 29 cleanup; task_dir="$WRITER_TASK_DIR"
  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir cleanup_broken_symlink "$task_dir" add-repo shared-api --format json)"
  operation_id="$(json_get "$actual" operation_id)"
  claim_id="$(json_get "$actual" claim_id)"
  worktree="$task_dir/task/codebases/shared-api"
  missing="$TMPDIR/cleanup_broken_symlink/missing-target"
  run_task_in_dir cleanup_broken_symlink "$task_dir" abandon \
    --reason-code superseded --reason-ref issue:81 --format json >/dev/null
  git -C "$task_dir" add task
  if ! git -C "$task_dir" diff --cached --quiet; then
    git -C "$task_dir" commit -q -m "test: persist broken symlink terminal"
  fi
  git -C "$task_dir" push -q

  out="$TMPDIR/cleanup_broken_symlink/done.out"
  if GH_CLEANUP_RACE_SYMLINK_WORKTREE="$worktree" \
    GH_CLEANUP_RACE_SYMLINK_TARGET="$missing" \
    run_task cleanup_broken_symlink "$WRITER_REPO" done 29 --format json >"$out" 2>&1; then
    fail "cleanup treated a broken worktree symlink as an absent owned effect"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "broken symlink cleanup returned $rc"
  assert_file_contains "$out" '"code":"cleanup-ownership-mismatch"'
  [ -L "$worktree" ] || fail "cleanup removed the broken worktree symlink"
  [ -d "$worktree.original" ] || fail "cleanup removed the owned worktree behind the symlink"

  ref=refs/heads/workbench-coordination/writer-claims
  ledger="$TMPDIR/cleanup_broken_symlink/writer-claims.tsv"
  git --git-dir="$TMPDIR/cleanup_broken_symlink/origin.git" show "$ref:writer-claims.tsv" > "$ledger"
  python3 - "$ledger" "$operation_id" "$claim_id" <<'PY'
import sys

rows = [line.split("\t") for line in open(sys.argv[1], encoding="utf-8").read().splitlines()[1:]]
claims = [row for row in rows if row[0] == "claim" and row[1:3] == sys.argv[2:4]]
effects = [row for row in rows if row[0] == "effect-owner" and row[2:4] == sys.argv[2:4]]
assert claims[-1][-1] == "active", claims
assert effects[-1][-1] == "acquired", effects
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

test_v2_submit_reconciles_durable_submission_without_v1_fallback() {
  local repo task_dir body out rc actual comments marker branch head pr_creates
  repo="$(setup_workbench v2_submit)"
  printf '%s\n' 'kit: https://github.com/example/workbench.git' > "$repo/codebases.yaml"
  git -C "$repo" add codebases.yaml
  git -C "$repo" commit -q -m "test: register increment owner"
  git -C "$repo" push -q
  task_dir="$(start_task v2_submit "$repo")"
  run_task_in_dir v2_submit "$task_dir" policy-context seal --format json >/dev/null
  run_task_in_dir v2_submit "$task_dir" deliverable declare --id workbench-pr --owner kit \
    --kind workbench-increment --format json >/dev/null
  mkdir -p "$task_dir/docs"
  printf '%s\n' '# Durable increment' > "$task_dir/docs/increment.md"
  printf '\n## [2026-07-11 12:00:00] code · create docs/increment.md | v2 submit fixture\n' \
    >> "$task_dir/task/log.md"
  printf '%s\n' '# Status' '' '상태: submit fixture ready' > "$task_dir/task/status.md"
  git -C "$task_dir" add docs/increment.md task
  git -C "$task_dir" commit -q -m "feat: add submitted increment"
  git -C "$task_dir" push -q
  body="$TMPDIR/v2_submit/pr-body.md"; printf '%s\n' 'fixture PR' > "$body"

  out="$TMPDIR/v2_submit/first-submit.out"
  if GH_FAIL_LIFECYCLE_EVENT=task-submitted run_task_in_dir v2_submit "$task_dir" submit \
    --title "feat: durable v2 submit" --body-file "$body" >"$out" 2>&1; then
    fail "v2 submit succeeded after its durable submission fact failed"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "failed v2 lifecycle projection returned $rc"
  [ ! -e "$task_dir/task/index.md" ] || fail "v2 submit fixture did not exercise post-cleanup recovery"
  [ -f "$TMPDIR/v2_submit/comments/pr-17.json" ] || fail "v2 submit did not create its PR primary"

  actual="$(run_task_in_dir v2_submit "$task_dir" submit \
    --title "feat: durable v2 submit" --body-file "$body")"
  assert_contains "$actual" 'https://github.com/example/workbench/pull/17'
  pr_creates="$(grep -c 'pr create' "$TMPDIR/v2_submit/gh.log" || true)"
  [ "$pr_creates" = 1 ] || fail "submission retry created a second PR"
  comments="$TMPDIR/v2_submit/comments/29.comments"
  python3 - "$comments" "$TMPDIR/v2_submit/comments/pr-17.json" <<'PY'
import json
import re
import sys

comments = open(sys.argv[1], encoding="utf-8").read()
markers = [json.loads(raw) for raw in re.findall(
    r"<!-- workbench-task-lifecycle:v2\n([^\r\n]+)\n-->", comments
)]
submitted = [item for item in markers if item["event"] == "task-submitted"]
assert len(submitted) == 1
marker = submitted[0]
pr = json.load(open(sys.argv[2], encoding="utf-8"))
assert marker["task_contract"] == "workbench-task/v2"
assert marker["pr"] == pr["number"] == 17
assert marker["revision"] == pr["headRefOid"]
assert marker["action_instance_id"] is None and marker["intent_digest"] is None
assert marker["workspace_authority_descriptor_digest"].startswith("sha256:")
PY

  branch="$(git -C "$task_dir" branch --show-current)"; head="$(git -C "$task_dir" rev-parse HEAD)"
  marker="$(python3 - "$comments" <<'PY'
import json
import re
import sys
value = next(json.loads(raw) for raw in re.findall(
    r"<!-- workbench-task-lifecycle:v2\n([^\r\n]+)\n-->",
    open(sys.argv[1], encoding="utf-8").read(),
) if json.loads(raw)["event"] == "task-submitted")
keys = list(value)
value = {key: value[key] for key in reversed(keys)}
print(json.dumps(value, separators=(",", ":")))
PY
)"
  python3 - "$comments" "$marker" <<'PY'
import re
import sys
path, marker = sys.argv[1:]
raw = open(path, encoding="utf-8").read()
raw = re.sub(
    r'(<!-- workbench-task-lifecycle:v2\n)[^\r\n]+(\n-->\nworkbench task lifecycle: task-submitted)',
    lambda match: match.group(1) + marker + match.group(2),
    raw,
)
open(path, "w", encoding="utf-8").write(raw)
PY
  out="$TMPDIR/v2_submit/done.out"
  if run_task v2_submit "$repo" done 29 --format json >"$out" 2>&1; then
    fail "submitted v2 task entered the v1 done path"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "v2 merge-wait cleanup returned $rc"
  assert_file_contains "$out" '"contract_version":"workbench-task-cleanup/v1"'
  assert_file_contains "$out" '"outcome":null'
  assert_file_contains "$out" '"code":"missing-terminal-outcome"'
  git -C "$task_dir" rev-parse "$head^:task/index.md" >/dev/null \
    || fail "submission ancestry lost the pre-cleanup task identity"
  [ "$(git -C "$task_dir" branch --show-current)" = "$branch" ] || fail "submit changed task branch"
}

test_v1_submission_without_origin_head_uses_main_fallback() {
  local repo task_dir body actual
  repo="$(setup_workbench v1_submit_no_head workbench/v1)"
  task_dir="$(start_task v1_submit_no_head "$repo")"
  printf '%s\n' v1-increment > "$task_dir/V1.md"
  printf '\n## [2026-07-12 11:30:00] code · create V1.md | v1 no origin HEAD fixture\n' \
    >> "$task_dir/task/log.md"
  printf '%s\n' '# Status' '' '상태: v1 submit ready' > "$task_dir/task/status.md"
  git -C "$task_dir" add V1.md task
  git -C "$task_dir" commit -q -m "test: prepare v1 submission"
  git -C "$task_dir" push -q
  git -C "$repo" remote set-head origin -d
  body="$TMPDIR/v1_submit_no_head/body.md"; printf '%s\n' v1 > "$body"
  actual="$(run_task_in_dir v1_submit_no_head "$task_dir" submit \
    --title "test: v1 no origin head" --body-file "$body")"
  assert_contains "$actual" 'https://github.com/example/workbench/pull/17'
  assert_file_contains "$TMPDIR/v1_submit_no_head/comments/pr-17.json" '"baseRefName":"main"'
}

test_v2_submission_restores_authenticated_state_to_terminal_cleanup() {
  local repo task_dir body snapshot head actual branch common
  repo="$(setup_workbench v2_submit_terminal)"
  printf '%s\n' \
    'schema=workbench-policy/v1' \
    'action.task.complete=allow' \
    'action.task.cleanup=allow' > "$repo/.workbench/policy.conf"
  printf '%s\n' 'kit: https://github.com/example/workbench.git' > "$repo/codebases.yaml"
  git -C "$repo" add .workbench/policy.conf codebases.yaml
  git -C "$repo" commit -q -m "test: allow submitted increment completion"
  git -C "$repo" push -q
  task_dir="$(start_task v2_submit_terminal "$repo")"
  run_task_in_dir v2_submit_terminal "$task_dir" policy-context seal --format json >/dev/null
  run_task_in_dir v2_submit_terminal "$task_dir" deliverable declare \
    --id workbench-pr --owner kit --kind workbench-increment --format json >/dev/null
  run_task_in_dir v2_submit_terminal "$task_dir" harvest seal --format json >/dev/null
  mkdir -p "$task_dir/docs"
  printf '%s\n' '# Recoverable increment' > "$task_dir/docs/recoverable.md"
  printf '\n## [2026-07-12 12:00:00] code · create docs/recoverable.md | recoverable submit fixture\n' \
    >> "$task_dir/task/log.md"
  printf '%s\n' '# Status' '' '상태: recoverable submit fixture ready' \
    > "$task_dir/task/status.md"
  git -C "$task_dir" add docs/recoverable.md task
  git -C "$task_dir" commit -q -m "feat: add recoverable increment"
  git -C "$task_dir" push -q
  snapshot="$(git -C "$task_dir" rev-parse HEAD)"
  body="$TMPDIR/v2_submit_terminal/pr-body.md"
  printf '%s\n' 'recoverable fixture PR' > "$body"

  actual="$(run_task_in_dir v2_submit_terminal "$task_dir" submit \
    --title "feat: recoverable v2 submit" --body-file "$body")"
  assert_contains "$actual" 'https://github.com/example/workbench/pull/17'
  head="$(git -C "$task_dir" rev-parse HEAD)"
  branch="$(git -C "$task_dir" branch --show-current)"
  [ "$(git -C "$task_dir" rev-parse HEAD^)" = "$snapshot" ] \
    || fail "submission cleanup does not directly descend from its persisted snapshot"
  [ -f "$task_dir/task/index.md" ] \
    || fail "authenticated submission did not restore its live v2 task state"
  git -C "$task_dir" ls-files --error-unmatch task/index.md >/dev/null 2>&1 \
    && fail "restored v2 task state became tracked in the submitted PR"
  [ -z "$(git -C "$task_dir" diff origin/main...HEAD --name-only -- task)" ] \
    || fail "submitted PR diff contains task state"
  actual="$(run_task_in_dir v2_submit_terminal "$task_dir" deliverable list --format json)"
  assert_contains "$actual" '"kind":"workbench-increment"'
  assert_contains "$actual" '"external_ref":"https://github.com/example/workbench/pull/17"'
  assert_contains "$actual" "\"revision\":\"$head\",\"state\":\"submitted\""

  python3 - "$TMPDIR/v2_submit_terminal/comments/pr-17.json" <<'PY'
import json
import sys

path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["state"] = "MERGED"
value["merged"] = True
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  actual="$(GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir v2_submit_terminal "$task_dir" deliverable accept \
      --id workbench-pr --format json)"
  assert_contains "$actual" '"state":"accepted"'
  actual="$(GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir v2_submit_terminal "$task_dir" verify --format json)"
  assert_contains "$actual" '"verified":true'
  actual="$(GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir v2_submit_terminal "$task_dir" complete --format json)"
  assert_contains "$actual" '"outcome":"completed"'
  [ -z "$(git -C "$task_dir" diff origin/main...HEAD --name-only -- task)" ] \
    || fail "terminal operations changed the submitted PR diff"

  common="$(git -C "$task_dir" rev-parse --path-format=absolute --git-common-dir)"
  actual="$(run_task v2_submit_terminal "$repo" done 29 --format json)"
  assert_contains "$actual" '"outcome":"cleaned"'
  [ ! -d "$task_dir" ] || fail "completed submitted task workspace was not removed"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    fail "completed submitted task branch was not removed locally"
  fi
  python3 - "$common/workbench-v2" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
residue = [
    path.name
    for path in root.iterdir()
    if path.name.startswith("submission-")
    or path.name.startswith(".submission-task-stage-")
]
assert residue == [], residue
PY
}

test_v2_submission_crash_boundaries_are_idempotent() {
  local stage case_name out rc actual pr_creates common
  for stage in ${WORKBENCH_SUBMISSION_CRASH_STAGES:-cleanup-staged cleanup-committed pr-observed submitted restore-materialized restore-installed restored}; do
    case_name="submit_crash_${stage//-/_}"
    prepare_submission_fixture "$case_name"
    out="$TMPDIR/$case_name/failed.out"
    if WORKBENCH_TEST_FAIL_SUBMISSION_STAGE="$stage" \
      run_task_in_dir "$case_name" "$SUBMISSION_TASK_DIR" submit \
        --title "feat: $case_name" --body-file "$SUBMISSION_BODY" >"$out" 2>&1; then
      fail "submission crash hook $stage did not interrupt"
    else rc=$?; fi
    [ "$rc" = 1 ] || fail "submission crash hook $stage returned $rc"
    if [ "$stage" = restore-materialized ]; then
      [ ! -e "$SUBMISSION_TASK_DIR/task" ] \
        || fail "failed restore materialization exposed a partial task tree"
    fi
    actual="$(run_task_in_dir "$case_name" "$SUBMISSION_TASK_DIR" submit \
      --title "feat: $case_name" --body-file "$SUBMISSION_BODY")"
    assert_contains "$actual" 'https://github.com/example/workbench/pull/17'
    [ -f "$SUBMISSION_TASK_DIR/task/index.md" ] \
      || fail "submission retry after $stage did not restore task state"
    [ -z "$(git -C "$SUBMISSION_TASK_DIR" diff origin/main...HEAD --name-only -- task)" ] \
      || fail "submission retry after $stage added task state to the PR"
    common="$(git -C "$SUBMISSION_TASK_DIR" rev-parse --path-format=absolute --git-common-dir)"
    [ -z "$(find "$common/workbench-v2" -maxdepth 1 -name '.submission-task-stage-*' -print)" ] \
      || fail "submission retry after $stage retained restore staging"
    pr_creates="$(grep -c 'pr create' "$TMPDIR/$case_name/gh.log" || true)"
    [ "$pr_creates" = 1 ] || fail "submission retry after $stage created $pr_creates PRs"
  done
}

test_v2_submission_restore_never_overwrites_occupied_state() {
  local out rc branch common before staging staging_inode installed_inode
  prepare_submission_fixture submit_restore_safety
  out="$TMPDIR/submit_restore_safety/submitted.out"
  if WORKBENCH_TEST_FAIL_SUBMISSION_STAGE=submitted \
    run_task_in_dir submit_restore_safety "$SUBMISSION_TASK_DIR" submit \
      --title "feat: restore safety" --body-file "$SUBMISSION_BODY" >"$out" 2>&1; then
    fail "submission fixture did not stop before restoration"
  fi
  [ ! -e "$SUBMISSION_TASK_DIR/task" ] || fail "pre-restore fixture retained task state"
  branch="$(git -C "$SUBMISSION_TASK_DIR" branch --show-current)"

  mkdir "$SUBMISSION_TASK_DIR/task"
  printf '%s\n' foreign > "$SUBMISSION_TASK_DIR/task/FOREIGN"
  before="$(cat "$SUBMISSION_TASK_DIR/task/FOREIGN")"
  if run_task_in_dir submit_restore_safety "$SUBMISSION_TASK_DIR" submit \
    --title "feat: restore safety" --body-file "$SUBMISSION_BODY" >"$out" 2>&1; then
    fail "submission restoration overwrote an occupied task directory"
  fi
  [ "$(cat "$SUBMISSION_TASK_DIR/task/FOREIGN")" = "$before" ] \
    || fail "occupied task bytes changed during rejected restoration"
  rm "$SUBMISSION_TASK_DIR/task/FOREIGN"; rmdir "$SUBMISSION_TASK_DIR/task"

  mkdir "$SUBMISSION_TASK_DIR/task"
  git -C "$SUBMISSION_TASK_DIR" show "$SUBMISSION_SNAPSHOT:task/index.md" \
    > "$SUBMISSION_TASK_DIR/task/index.md"
  if run_task_in_dir submit_restore_safety "$SUBMISSION_TASK_DIR" submit \
    --title "feat: restore safety" --body-file "$SUBMISSION_BODY" >"$out" 2>&1; then
    fail "submission restoration adopted a partial task snapshot"
  fi
  [ ! -e "$SUBMISSION_TASK_DIR/task/status.md" ] \
    || fail "partial task snapshot was populated in place"
  rm "$SUBMISSION_TASK_DIR/task/index.md"; rmdir "$SUBMISSION_TASK_DIR/task"

  mkdir "$TMPDIR/submit_restore_safety/foreign-task"
  printf '%s\n' symlink-target > "$TMPDIR/submit_restore_safety/foreign-task/FOREIGN"
  ln -s "$TMPDIR/submit_restore_safety/foreign-task" "$SUBMISSION_TASK_DIR/task"
  if run_task_in_dir submit_restore_safety "$SUBMISSION_TASK_DIR" submit \
    --title "feat: restore safety" --body-file "$SUBMISSION_BODY" >"$out" 2>&1; then
    fail "submission restoration followed an occupied task symlink"
  fi
  [ "$(cat "$TMPDIR/submit_restore_safety/foreign-task/FOREIGN")" = symlink-target ] \
    || fail "task symlink target changed during rejected restoration"
  rm "$SUBMISSION_TASK_DIR/task"

  if python3 "$SUBMISSION_REPO/lib/workbench_lifecycle.py" submission-recovery-restore \
    --repository "$SUBMISSION_REPO" --branch "$branch" >"$out" 2>&1; then
    fail "recovery helper restored into a different worktree"
  fi
  [ ! -e "$SUBMISSION_REPO/task" ] \
    || fail "direct recovery helper misuse created task state in the root checkout"

  if WORKBENCH_TEST_FAIL_SUBMISSION_STAGE=restore-materialized \
    run_task_in_dir submit_restore_safety "$SUBMISSION_TASK_DIR" submit \
      --title "feat: restore safety" --body-file "$SUBMISSION_BODY" >"$out" 2>&1; then
    fail "mid-restore failure hook did not interrupt"
  fi
  [ ! -e "$SUBMISSION_TASK_DIR/task" ] \
    || fail "mid-restore failure exposed partial task state"
  common="$(git -C "$SUBMISSION_TASK_DIR" rev-parse --path-format=absolute --git-common-dir)"
  staging="$(find "$common/workbench-v2" -maxdepth 1 -name '.submission-task-stage-*' -type d)"
  [ -n "$staging" ] && [ "$(printf '%s\n' "$staging" | wc -l | tr -d ' ')" = 1 ] \
    || fail "mid-restore failure did not retain one deterministic private staging tree"
  staging_inode="$(ls -di "$staging" | awk '{print $1}')"
  printf '%s\n' foreign-stage > "$staging/FOREIGN"
  if run_task_in_dir submit_restore_safety "$SUBMISSION_TASK_DIR" submit \
    --title "feat: restore safety" --body-file "$SUBMISSION_BODY" >"$out" 2>&1; then
    fail "submission restoration adopted a foreign deterministic staging collision"
  fi
  [ "$(cat "$staging/FOREIGN")" = foreign-stage ] \
    || fail "foreign staging collision changed during rejected restoration"
  rm "$staging/FOREIGN"
  if WORKBENCH_TEST_FAIL_SUBMISSION_STAGE=restore-installed \
    run_task_in_dir submit_restore_safety "$SUBMISSION_TASK_DIR" submit \
      --title "feat: restore safety" --body-file "$SUBMISSION_BODY" >"$out" 2>&1; then
    fail "post-install failure hook did not interrupt"
  fi
  [ -f "$SUBMISSION_TASK_DIR/task/index.md" ] \
    || fail "post-install failure did not leave the exact atomic task tree"
  [ ! -e "$staging" ] || fail "successful restore retained its owned staging tree"
  installed_inode="$(ls -di "$SUBMISSION_TASK_DIR/task" | awk '{print $1}')"
  [ "$installed_inode" = "$staging_inode" ] \
    || fail "submission retry did not atomically reuse its deterministic staging tree"
  chmod 4644 "$SUBMISSION_TASK_DIR/task/index.md"
  if run_task_in_dir submit_restore_safety "$SUBMISSION_TASK_DIR" submit \
    --title "feat: restore safety" --body-file "$SUBMISSION_BODY" >"$out" 2>&1; then
    fail "submission restoration accepted special mode bits"
  fi
  chmod 0644 "$SUBMISSION_TASK_DIR/task/index.md"
  chmod 0755 "$SUBMISSION_TASK_DIR/task"
  if run_task_in_dir submit_restore_safety "$SUBMISSION_TASK_DIR" submit \
    --title "feat: restore safety" --body-file "$SUBMISSION_BODY" >"$out" 2>&1; then
    fail "submission restoration accepted a non-exact task directory mode"
  fi
  chmod 0700 "$SUBMISSION_TASK_DIR/task"
  run_task_in_dir submit_restore_safety "$SUBMISSION_TASK_DIR" submit \
    --title "feat: restore safety" --body-file "$SUBMISSION_BODY" >/dev/null
  [ -f "$SUBMISSION_TASK_DIR/task/index.md" ] \
    || fail "safe restoration did not recover after isolated materialization failure"
}

test_v2_submission_reconstructs_recovery_in_fresh_clone() {
  local clone device_task branch head common out mode observation origin lifecycle actual pr_creates
  local terminal_clone terminal_task terminal_common
  prepare_submission_fixture submit_cross_device true
  run_task_in_dir submit_cross_device "$SUBMISSION_TASK_DIR" submit \
    --title "feat: cross-device submission" --body-file "$SUBMISSION_BODY" >/dev/null
  branch="$(git -C "$SUBMISSION_TASK_DIR" branch --show-current)"
  head="$(git -C "$SUBMISSION_TASK_DIR" rev-parse HEAD)"

  clone="$TMPDIR/submit_cross_device/device-two"
  git clone -q "$TMPDIR/submit_cross_device/origin.git" "$clone"
  git -C "$clone" config user.name "Test User"
  git -C "$clone" config user.email "test@example.invalid"
  mkdir -p "$clone/.worktrees"
  device_task="$(task_dir_for "$clone")"
  git -C "$clone" worktree add -q -b "$branch" "$device_task" "origin/$branch"
  common="$(git -C "$device_task" rev-parse --path-format=absolute --git-common-dir)"
  [ ! -e "$common/workbench-v2" ] \
    || fail "fresh clone unexpectedly inherited local submission recovery state"
  origin="$(git -C "$device_task" remote get-url origin)"

  for mode in fork multiple changed-head bad-base; do
    observation="$TMPDIR/submit_cross_device/$mode.json"
    python3 - "$observation" "$origin" "$branch" "$head" "$mode" <<'PY'
import copy
import json
import sys

path, origin, branch, head, mode = sys.argv[1:]
pagination = {"complete": True, "pages_fetched": 1, "end_cursor": None, "failure": None}
item = {
    "number": 17,
    "url": "https://github.com/example/workbench/pull/17",
    "head_branch": branch,
    "head_revision": "0" * 40 if mode == "changed-head" else head,
    "head_repository_origin_url": origin,
    "head_is_fork": mode == "fork",
    "base_ref": "other" if mode == "bad-base" else "main",
    "state": "open",
}
items = [item]
if mode == "multiple":
    duplicate = copy.deepcopy(item)
    duplicate["number"] = 18
    duplicate["url"] = "https://github.com/example/workbench/pull/18"
    items.append(duplicate)
value = {
    "contract_version": "workbench-hosting-submission-observation/v1",
    "repository_origin_url": origin,
    "head_branch": branch,
    "base_ref": "other" if mode == "bad-base" else "main",
    "pagination": pagination,
    "pull_requests": items,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
    out="$TMPDIR/submit_cross_device/$mode.out"
    if WORKBENCH_TEST_SUBMISSION_OBSERVATION="$observation" \
      run_task_in_dir submit_cross_device "$device_task" submit \
        --title "feat: cross-device submission" --body-file "$SUBMISSION_BODY" \
        >"$out" 2>&1; then
      fail "fresh-clone recovery accepted $mode PR observation"
    fi
    [ ! -e "$device_task/task" ] \
      || fail "invalid $mode PR observation restored task state"
  done

  lifecycle="$TMPDIR/submit_cross_device/ambiguous-lifecycle.json"
  python3 - "$lifecycle" "$origin" "$TMPDIR/submit_cross_device/comments/29.comments" <<'PY'
import json
import re
import sys

path, origin, comments = sys.argv[1:]
body = open(comments, encoding="utf-8").read()
submitted = next(
    raw
    for raw in re.findall(r"<!-- workbench-task-lifecycle:v2\n([^\r\n]+)\n-->", body)
    if json.loads(raw)["event"] == "task-submitted"
)
body += (
    "<!-- workbench-task-lifecycle:v2\n"
    + submitted
    + "\n-->\nworkbench task lifecycle: task-submitted duplicate\n\n"
)
value = {
    "contract_version": "workbench-hosting-lifecycle-observation/v1",
    "repository_origin_url": origin,
    "issue": 29,
    "pagination": {"complete": True, "pages_fetched": 1, "end_cursor": None, "failure": None},
    "comments": [{"author_identity": "test@example.invalid", "body": body}],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  out="$TMPDIR/submit_cross_device/ambiguous-lifecycle.out"
  if WORKBENCH_TEST_LIFECYCLE_OBSERVATION="$lifecycle" \
    run_task_in_dir submit_cross_device "$device_task" submit \
      --title "feat: cross-device submission" --body-file "$SUBMISSION_BODY" \
      >"$out" 2>&1; then
    fail "fresh-clone recovery accepted ambiguous submission lifecycle"
  fi
  [ ! -e "$device_task/task" ] \
    || fail "ambiguous lifecycle restored fresh-clone task state"

  actual="$(run_task_in_dir submit_cross_device "$device_task" submit \
    --title "feat: cross-device submission" --body-file "$SUBMISSION_BODY")"
  assert_contains "$actual" 'https://github.com/example/workbench/pull/17'
  [ -f "$device_task/task/index.md" ] \
    || fail "fresh clone did not reconstruct and restore submitted task state"
  git -C "$device_task" ls-files --error-unmatch task/index.md >/dev/null 2>&1 \
    && fail "fresh-clone restored task state became tracked"
  pr_creates="$(grep -c 'pr create' "$TMPDIR/submit_cross_device/gh.log" || true)"
  [ "$pr_creates" = 1 ] || fail "fresh clone created a duplicate submitted PR"

  python3 - "$TMPDIR/submit_cross_device/comments/pr-17.json" <<'PY'
import json
import sys

path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["state"] = "MERGED"
value["merged"] = True
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_cross_device "$device_task" deliverable accept \
      --id workbench-pr --format json >/dev/null
  actual="$(GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_cross_device "$device_task" verify --format json)"
  assert_contains "$actual" '"verified":true'
  actual="$(GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_cross_device "$device_task" complete --format json)"
  assert_contains "$actual" '"outcome":"completed"'

  rm -rf "$clone"
  terminal_clone="$TMPDIR/submit_cross_device/device-three"
  git clone -q "$TMPDIR/submit_cross_device/origin.git" "$terminal_clone"
  git -C "$terminal_clone" config user.name "Test User"
  git -C "$terminal_clone" config user.email "test@example.invalid"
  mkdir -p "$terminal_clone/.worktrees"
  terminal_task="$(task_dir_for "$terminal_clone")"
  git -C "$terminal_clone" worktree add -q -b "$branch" "$terminal_task" "origin/$branch"
  terminal_common="$(git -C "$terminal_task" rev-parse --path-format=absolute --git-common-dir)"
  [ ! -e "$terminal_common/workbench-v2" ] \
    || fail "terminal handoff clone unexpectedly inherited submission recovery state"
  actual="$(run_task submit_cross_device "$terminal_clone" done 29 --format json)"
  assert_contains "$actual" '"outcome":"cleaned"'
  [ ! -d "$terminal_task" ] \
    || fail "fresh-clone submitted task workspace survived terminal cleanup"
  [ -z "$(find "$terminal_common/workbench-v2" -maxdepth 1 \
    \( -name 'submission-*' -o -name '.submission-task-stage-*' \) -print)" ] \
    || fail "fresh-clone terminal cleanup retained submission recovery state"
}

mark_submission_pr_merged() {
  local case_name="$1"
  python3 - "$TMPDIR/$case_name/comments/pr-17.json" <<'PY'
import json
import sys

path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["state"] = "MERGED"
value["merged"] = True
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
}

test_v2_submission_rejects_restored_deliverable_tampering() {
  local deliverable original head out
  prepare_submission_fixture submit_tampered_deliverable
  run_task_in_dir submit_tampered_deliverable "$SUBMISSION_TASK_DIR" submit \
    --title "feat: tampered restored deliverable" --body-file "$SUBMISSION_BODY" >/dev/null
  head="$(git -C "$SUBMISSION_TASK_DIR" rev-parse HEAD)"
  mark_submission_pr_merged submit_tampered_deliverable
  deliverable="$SUBMISSION_TASK_DIR/task/.workbench/deliverables/workbench-pr.record"
  original="$TMPDIR/submit_tampered_deliverable/workbench-pr.record"
  cp "$deliverable" "$original"
  sed 's/^required=true$/required=false/' "$original" > "$deliverable"
  out="$TMPDIR/submit_tampered_deliverable/accept.out"
  if GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_tampered_deliverable "$SUBMISSION_TASK_DIR" deliverable accept \
      --id workbench-pr --format json >"$out" 2>&1; then
    fail "submitted task accepted a deliverable that diverged from its authenticated snapshot"
  fi
  cp "$original" "$deliverable"
  GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_tampered_deliverable "$SUBMISSION_TASK_DIR" deliverable accept \
      --id workbench-pr --format json >/dev/null
}

test_v2_submission_rejects_deleted_restored_deliverable() {
  local deliverable head out verify_accepted=false complete_accepted=false
  prepare_submission_fixture submit_deleted_deliverable true
  run_task_in_dir submit_deleted_deliverable "$SUBMISSION_TASK_DIR" submit \
    --title "feat: deleted restored deliverable" --body-file "$SUBMISSION_BODY" >/dev/null
  head="$(git -C "$SUBMISSION_TASK_DIR" rev-parse HEAD)"
  deliverable="$SUBMISSION_TASK_DIR/task/.workbench/deliverables/workbench-pr.record"
  rm "$deliverable"
  out="$TMPDIR/submit_deleted_deliverable/verify.out"
  if GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_deleted_deliverable "$SUBMISSION_TASK_DIR" verify \
      --format json >"$out" 2>&1; then
    verify_accepted=true
  fi
  out="$TMPDIR/submit_deleted_deliverable/complete.out"
  if GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_deleted_deliverable "$SUBMISSION_TASK_DIR" complete \
      --format json >"$out" 2>&1; then
    complete_accepted=true
  fi
  [ "$verify_accepted" = false ] \
    || fail "submitted task verified after its required deliverable was deleted"
  [ "$complete_accepted" = false ] \
    || fail "submitted task completed after its required deliverable was deleted"
}

test_v2_submission_rejects_deleted_restored_required_check() {
  local check head out verify_accepted=false complete_accepted=false
  prepare_submission_fixture submit_deleted_check true
  run_task_in_dir submit_deleted_check "$SUBMISSION_TASK_DIR" required-check declare \
    --id restored-check --owner kit --format json >/dev/null
  printf '\n## [2026-07-12 13:01:00] code · create task/.workbench/required-checks/restored-check.record | require restored task check\n' \
    >> "$SUBMISSION_TASK_DIR/task/log.md"
  printf '%s\n' '# Status' '' '상태: restored task check required' \
    > "$SUBMISSION_TASK_DIR/task/status.md"
  git -C "$SUBMISSION_TASK_DIR" add task
  git -C "$SUBMISSION_TASK_DIR" commit -q -m "test: require restored task check"
  git -C "$SUBMISSION_TASK_DIR" push -q
  SUBMISSION_SNAPSHOT="$(git -C "$SUBMISSION_TASK_DIR" rev-parse HEAD)"
  run_task_in_dir submit_deleted_check "$SUBMISSION_TASK_DIR" submit \
    --title "feat: deleted restored check" --body-file "$SUBMISSION_BODY" >/dev/null
  head="$(git -C "$SUBMISSION_TASK_DIR" rev-parse HEAD)"
  mark_submission_pr_merged submit_deleted_check
  GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_deleted_check "$SUBMISSION_TASK_DIR" deliverable accept \
      --id workbench-pr --format json >/dev/null
  check="$SUBMISSION_TASK_DIR/task/.workbench/required-checks/restored-check.record"
  rm "$check"
  out="$TMPDIR/submit_deleted_check/verify.out"
  if GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_deleted_check "$SUBMISSION_TASK_DIR" verify \
      --format json >"$out" 2>&1; then
    verify_accepted=true
  fi
  out="$TMPDIR/submit_deleted_check/complete.out"
  if GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_deleted_check "$SUBMISSION_TASK_DIR" complete \
      --format json >"$out" 2>&1; then
    complete_accepted=true
  fi
  [ "$verify_accepted" = false ] \
    || fail "submitted task verified after its required check was deleted"
  [ "$complete_accepted" = false ] \
    || fail "submitted task completed after its required check was deleted"
}

test_v2_submission_rejects_restored_acceptance_tampering() {
  local acceptance original head out actual field forged
  prepare_submission_fixture submit_tampered_acceptance
  run_task_in_dir submit_tampered_acceptance "$SUBMISSION_TASK_DIR" submit \
    --title "feat: tampered restored acceptance" --body-file "$SUBMISSION_BODY" >/dev/null
  head="$(git -C "$SUBMISSION_TASK_DIR" rev-parse HEAD)"
  mark_submission_pr_merged submit_tampered_acceptance
  GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_tampered_acceptance "$SUBMISSION_TASK_DIR" deliverable accept \
      --id workbench-pr --format json >/dev/null
  acceptance="$(find "$SUBMISSION_TASK_DIR/task/.workbench/acceptances" \
    -maxdepth 1 -type f -name '*.record')"
  [ -n "$acceptance" ] \
    && [ "$(printf '%s\n' "$acceptance" | wc -l | tr -d ' ')" = 1 ] \
    || fail "acceptance tamper fixture did not create exactly one receipt"
  original="$TMPDIR/submit_tampered_acceptance/acceptance.record"
  cp "$acceptance" "$original"
  for field in authority_digest subject_authority_digest; do
    [ "$field" = authority_digest ] \
      && forged="sha256:1111111111111111111111111111111111111111111111111111111111111111" \
      || forged="sha256:2222222222222222222222222222222222222222222222222222222222222222"
    sed "s/^$field=sha256:[0-9a-f]*$/$field=$forged/" "$original" > "$acceptance"
    out="$TMPDIR/submit_tampered_acceptance/$field.out"
    if GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
      run_task_in_dir submit_tampered_acceptance "$SUBMISSION_TASK_DIR" verify \
        --format json >"$out" 2>&1; then
      fail "submitted task verified a tampered $field acceptance binding"
    fi
  done
  cp "$original" "$acceptance"
  actual="$(GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_tampered_acceptance "$SUBMISSION_TASK_DIR" verify --format json)"
  assert_contains "$actual" '"verified":true'
}

test_v2_submitted_completion_keeps_cleanup_authorization_separate() {
  local branch head clone task out rc pending instance claim target revision manifest intent auth actual
  prepare_submission_fixture submit_cleanup_gate true ask
  run_task_in_dir submit_cleanup_gate "$SUBMISSION_TASK_DIR" submit \
    --title "feat: separate terminal cleanup gate" --body-file "$SUBMISSION_BODY" >/dev/null
  branch="$(git -C "$SUBMISSION_TASK_DIR" branch --show-current)"
  head="$(git -C "$SUBMISSION_TASK_DIR" rev-parse HEAD)"
  mark_submission_pr_merged submit_cleanup_gate
  GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_cleanup_gate "$SUBMISSION_TASK_DIR" deliverable accept \
      --id workbench-pr --format json >/dev/null
  GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_cleanup_gate "$SUBMISSION_TASK_DIR" verify --format json >/dev/null
  actual="$(GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_cleanup_gate "$SUBMISSION_TASK_DIR" complete --format json)"
  assert_contains "$actual" '"outcome":"completed"'
  if grep -Fq 'workbench-task-cleanup:v1' "$TMPDIR/submit_cleanup_gate/comments/29.comments"; then
    fail "completion minted a cleanup journal before the cleanup authorization gate"
  fi
  if grep -Rqs '^action_id=task.cleanup$' "$SUBMISSION_TASK_DIR/task/.workbench/actions"; then
    fail "completion pre-authorized task.cleanup"
  fi

  rm -rf "$SUBMISSION_REPO"
  clone="$TMPDIR/submit_cleanup_gate/device-two"
  git clone -q "$TMPDIR/submit_cleanup_gate/origin.git" "$clone"
  git -C "$clone" config user.name "Test User"
  git -C "$clone" config user.email "test@example.invalid"
  mkdir -p "$clone/.worktrees"
  task="$(task_dir_for "$clone")"
  git -C "$clone" worktree add -q -b "$branch" "$task" "origin/$branch"
  out="$TMPDIR/submit_cleanup_gate/cleanup-ask.out"
  if run_task submit_cleanup_gate "$clone" done 29 --format json > "$out"; then
    fail "fresh-clone cleanup bypassed its independent authorization gate"
  else
    rc=$?
  fi
  [ "$rc" = 3 ] || fail "fresh-clone cleanup ask returned $rc"
  pending="$(cat "$out")"
  instance="$(json_get "$pending" action_instance.id)"
  claim="$(json_get "$pending" action_instance.task_claim_id)"
  target="$(json_get "$pending" action_instance.target_ref)"
  [ "$target" = "workbench:task/$claim" ] \
    || fail "fresh-clone cleanup action did not retain its claim-only target"
  revision="$(json_get "$pending" action_instance.revision)"
  manifest="$(json_get "$pending" action_instance.policy_manifest.digest)"
  intent="$(json_get "$pending" action_instance.intent_digest)"
  auth="$TMPDIR/submit_cleanup_gate/cleanup-authorization.json"
  write_authorization "$auth" "$instance" task.cleanup "$claim" "$target" \
    "$revision" "$manifest" allow cleanup-owner@example.com 2026-07-12T13:05:00Z \
    conversation:message/cleanup-terminal "$intent"
  actual="$(run_task submit_cleanup_gate "$clone" done 29 \
    --action-instance-id "$instance" --authorization-file "$auth" --format json)"
  assert_contains "$actual" '"outcome":"cleaned"'
}

test_v2_submitted_abandonment_publishes_one_terminal_checkpoint() {
  local branch clone task actual comments
  prepare_submission_fixture submit_abandon_checkpoint true allow abandon
  run_task_in_dir submit_abandon_checkpoint "$SUBMISSION_TASK_DIR" submit \
    --title "fix: abandon submitted task" --body-file "$SUBMISSION_BODY" >/dev/null
  branch="$(git -C "$SUBMISSION_TASK_DIR" branch --show-current)"
  actual="$(run_task_in_dir submit_abandon_checkpoint "$SUBMISSION_TASK_DIR" abandon \
    --reason-code superseded --reason-ref issue:55 --format json)"
  assert_contains "$actual" '"outcome":"abandoned"'
  comments="$TMPDIR/submit_abandon_checkpoint/comments/29.comments"
  python3 - "$comments" <<'PY'
import re
import sys

body = open(sys.argv[1], encoding="utf-8").read()
comments = [
    match.group(1)
    for match in re.finditer(
        r"<!-- fixture-comment-author:[^\r\n ]+ -->\n(.*?)<!-- fixture-comment-end -->",
        body,
        re.DOTALL,
    )
]
paired = [item for item in comments if "workbench-task-terminal-checkpoint:v1" in item]
assert len(paired) == 1
assert paired[0].count("workbench-task-terminal-checkpoint:v1") == 1
assert paired[0].count('"event":"task-abandoned"') == 1
assert body.count('"event":"task-abandoned"') == 1
PY

  rm -rf "$SUBMISSION_REPO"
  clone="$TMPDIR/submit_abandon_checkpoint/device-two"
  git clone -q "$TMPDIR/submit_abandon_checkpoint/origin.git" "$clone"
  git -C "$clone" config user.name "Test User"
  git -C "$clone" config user.email "test@example.invalid"
  mkdir -p "$clone/.worktrees"
  task="$(task_dir_for "$clone")"
  git -C "$clone" worktree add -q -b "$branch" "$task" "origin/$branch"
  actual="$(run_task submit_abandon_checkpoint "$clone" done 29 --format json)"
  assert_contains "$actual" '"outcome":"cleaned"'
}

test_v2_terminal_checkpoint_rejects_adversarial_observations() {
  local branch head valid mode observation clone task out rc comments before after retry_clone retry_task
  prepare_submission_fixture submit_checkpoint_adversarial true ask
  run_task_in_dir submit_checkpoint_adversarial "$SUBMISSION_TASK_DIR" submit \
    --title "fix: authenticate terminal checkpoint" --body-file "$SUBMISSION_BODY" >/dev/null
  branch="$(git -C "$SUBMISSION_TASK_DIR" branch --show-current)"
  head="$(git -C "$SUBMISSION_TASK_DIR" rev-parse HEAD)"
  mark_submission_pr_merged submit_checkpoint_adversarial
  GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_checkpoint_adversarial "$SUBMISSION_TASK_DIR" deliverable accept \
      --id workbench-pr --format json >/dev/null
  GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_checkpoint_adversarial "$SUBMISSION_TASK_DIR" verify \
      --format json >/dev/null
  GH_PR_HEAD="$head" GH_PR_MERGE=merge789 \
    run_task_in_dir submit_checkpoint_adversarial "$SUBMISSION_TASK_DIR" complete \
      --format json >/dev/null
  comments="$TMPDIR/submit_checkpoint_adversarial/comments/29.comments"
  valid="$TMPDIR/submit_checkpoint_adversarial/valid-lifecycle.json"
  GH_COMMENTS_DIR="$TMPDIR/submit_checkpoint_adversarial/comments" \
    "$TMPDIR/submit_checkpoint_adversarial/bin/hosting-authority" lifecycle \
      --repository "$SUBMISSION_REPO" --issue 29 --format json > "$valid"
  python3 - "$valid" "$TMPDIR/submit_checkpoint_adversarial" <<'PY'
import copy
import json
import pathlib
import re
import sys

source = json.load(open(sys.argv[1], encoding="utf-8"))
target = pathlib.Path(sys.argv[2])
index = next(
    offset
    for offset, comment in enumerate(source["comments"])
    if "workbench-task-terminal-checkpoint:v1" in comment["body"]
)
comment = source["comments"][index]
body = comment["body"]
pattern = re.compile(r"<!-- workbench-task-terminal-checkpoint:v1\n([^\r\n]+)\n-->")
match = pattern.search(body)
assert match is not None
checkpoint = json.loads(match.group(1))
marker = match.group(0)

def replace_checkpoint(value):
    encoded = json.dumps(value, separators=(",", ":"))
    return body[:match.start(1)] + encoded + body[match.end(1):]

def emit(name, value, replacement=None):
    observed = copy.deepcopy(source)
    if replacement is None:
        replacement = replace_checkpoint(value)
    observed["comments"][index]["body"] = replacement
    with open(target / ("adversarial-{}.json".format(name)), "w", encoding="utf-8") as handle:
        json.dump(observed, handle, separators=(",", ":"))
        handle.write("\n")

observed = copy.deepcopy(source)
observed["comments"][index]["author_identity"] = "attacker@example.invalid"
with open(target / "adversarial-wrong-author.json", "w", encoding="utf-8") as handle:
    json.dump(observed, handle, separators=(",", ":")); handle.write("\n")

emit("duplicate", checkpoint, body[:match.end()] + "\n" + marker + body[match.end():])
observed = copy.deepcopy(source)
terminal_body = body[:match.start()] + body[match.end():]
observed["comments"][index:index + 1] = [
    {"author_identity": comment["author_identity"], "body": marker + "\n"},
    {"author_identity": comment["author_identity"], "body": terminal_body},
]
with open(target / "adversarial-split.json", "w", encoding="utf-8") as handle:
    json.dump(observed, handle, separators=(",", ":")); handle.write("\n")
emit("malformed", checkpoint, body[:match.end() - 3] + "-- >" + body[match.end():])

value = copy.deepcopy(checkpoint); value["terminal"]["revision"] = "sha256:" + "1" * 64
emit("terminal", value)
value = copy.deepcopy(checkpoint); value["terminal_action"]["intent_digest"] = "sha256:" + "2" * 64
emit("action", value)
value = copy.deepcopy(checkpoint)
value["terminal_request"]["payload"] = value["terminal_request"]["payload"].replace(
    value["terminal"]["revision"], "sha256:" + "3" * 64
)
emit("request", value)
value = copy.deepcopy(checkpoint); value["claim_id"] = "task__forged-claim"
emit("claim", value)
value = copy.deepcopy(checkpoint)
value["workspace_authority_descriptor_digest"] = "sha256:" + "4" * 64
emit("descriptor", value)
value = copy.deepcopy(checkpoint); value["head_revision"] = value["snapshot_revision"]
emit("pr-head", value)
value = copy.deepcopy(checkpoint); value["pull_request_url"] = "https://github.com/example/workbench/pull/999"
emit("pr-url", value)
value = copy.deepcopy(checkpoint); value["at"] = "2026-07-12T00:00:00Z"
emit("at", value)
value = dict(reversed(list(copy.deepcopy(checkpoint).items())))
emit("top-order", value)
value = copy.deepcopy(checkpoint); value["terminal"] = dict(reversed(list(value["terminal"].items())))
emit("terminal-order", value)
value = copy.deepcopy(checkpoint); value["terminal_action"] = dict(reversed(list(value["terminal_action"].items())))
emit("action-order", value)
value = copy.deepcopy(checkpoint); value["terminal_request"] = dict(reversed(list(value["terminal_request"].items())))
emit("request-order", value)
PY

  before="$(grep -c 'workbench-task-cleanup:v1' "$comments" || true)"
  rm -rf "$SUBMISSION_REPO"
  for mode in wrong-author duplicate split malformed terminal action request claim descriptor \
    pr-head pr-url at top-order terminal-order action-order request-order; do
    observation="$TMPDIR/submit_checkpoint_adversarial/adversarial-$mode.json"
    clone="$TMPDIR/submit_checkpoint_adversarial/device-$mode"
    git clone -q "$TMPDIR/submit_checkpoint_adversarial/origin.git" "$clone"
    git -C "$clone" config user.name "Test User"
    git -C "$clone" config user.email "test@example.invalid"
    mkdir -p "$clone/.worktrees"
    task="$(task_dir_for "$clone")"
    git -C "$clone" worktree add -q -b "$branch" "$task" "origin/$branch"
    out="$TMPDIR/submit_checkpoint_adversarial/$mode.out"
    if WORKBENCH_TEST_LIFECYCLE_OBSERVATION="$observation" \
      run_task submit_checkpoint_adversarial "$clone" done 29 --format json > "$out" 2>&1; then
      fail "terminal checkpoint accepted adversarial $mode observation"
    else
      rc=$?
    fi
    [ "$rc" = 1 ] || fail "adversarial $mode observation returned $rc"
    [ ! -e "$task/task" ] \
      || fail "adversarial $mode observation restored task state"
    if [ "$mode" = pr-url ]; then
      retry_clone="$clone"; retry_task="$task"
    else
      rm -rf "$clone"
    fi
  done
  after="$(grep -c 'workbench-task-cleanup:v1' "$comments" || true)"
  [ "$before" = "$after" ] || fail "adversarial receipt emitted a cleanup journal"

  out="$TMPDIR/submit_checkpoint_adversarial/cursor-retry.out"
  if run_task submit_checkpoint_adversarial "$retry_clone" done 29 --format json > "$out"; then
    fail "valid retry bypassed its cleanup ask gate"
  else
    rc=$?
  fi
  [ "$rc" = 3 ] || fail "valid receipt could not recover an earlier fail-closed cursor"
  [ -f "$retry_task/task/index.md" ] || fail "valid receipt retry did not restore snapshot state"
}

test_v2_submission_rejects_noncanonical_pr_and_lifecycle_state() {
  local mode observation origin branch head out claim descriptor comments
  prepare_submission_fixture submit_invalid_current
  run_task_in_dir submit_invalid_current "$SUBMISSION_TASK_DIR" submit \
    --title "feat: invalid current" --body-file "$SUBMISSION_BODY" >/dev/null
  origin="$(git -C "$SUBMISSION_TASK_DIR" remote get-url origin)"
  branch="$(git -C "$SUBMISSION_TASK_DIR" branch --show-current)"
  head="$(git -C "$SUBMISSION_TASK_DIR" rev-parse HEAD)"
  for mode in fork multiple changed-head bad-base; do
    observation="$TMPDIR/submit_invalid_current/$mode.json"
    python3 - "$observation" "$origin" "$branch" "$head" "$mode" <<'PY'
import copy
import json
import sys

path, origin, branch, head, mode = sys.argv[1:]
pagination = {"complete": True, "pages_fetched": 1, "end_cursor": None, "failure": None}
item = {
    "number": 17,
    "url": "https://github.com/example/workbench/pull/17",
    "head_branch": branch,
    "head_revision": "0" * 40 if mode == "changed-head" else head,
    "head_repository_origin_url": origin,
    "head_is_fork": mode == "fork",
    "base_ref": "other" if mode == "bad-base" else "main",
    "state": "open",
}
items = [item]
if mode == "multiple":
    duplicate = copy.deepcopy(item)
    duplicate["number"] = 18
    duplicate["url"] = "https://github.com/example/workbench/pull/18"
    items.append(duplicate)
value = {
    "contract_version": "workbench-hosting-submission-observation/v1",
    "repository_origin_url": origin,
    "head_branch": branch,
    "base_ref": "other" if mode == "bad-base" else "main",
    "pagination": pagination,
    "pull_requests": items,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
    out="$TMPDIR/submit_invalid_current/$mode.out"
    if WORKBENCH_TEST_SUBMISSION_OBSERVATION="$observation" \
      run_task_in_dir submit_invalid_current "$SUBMISSION_TASK_DIR" \
        verify --format json >"$out" 2>&1; then
      fail "submitted task accepted $mode PR observation"
    fi
    assert_file_contains "$out" 'authenticated submitted task recovery is unavailable'
  done

  claim="$(sed -n 's/^claim_id: *//p' "$SUBMISSION_TASK_DIR/task/index.md")"
  descriptor="$(sed -n 's/^workspace_authority_descriptor_digest: *//p' \
    "$SUBMISSION_TASK_DIR/task/index.md")"
  comments="$TMPDIR/submit_invalid_current/comments/29.comments"
  python3 - "$comments" "$claim" "$branch" "$descriptor" <<'PY'
import json
import sys

value = {
    "task_contract": "workbench-task/v2",
    "event": "task-active",
    "claim_id": sys.argv[2],
    "issue": 29,
    "home": None,
    "branch": sys.argv[3],
    "workspace_authority_descriptor_digest": sys.argv[4],
    "pr": None,
    "revision": None,
    "action_instance_id": None,
    "intent_digest": None,
    "actor": "test@example.invalid",
    "tool": "workbench",
    "at": "2026-07-12T14:00:00Z",
}
with open(sys.argv[1], "a", encoding="utf-8") as handle:
    handle.write("<!-- fixture-comment-author:test@example.invalid -->\n")
    handle.write("<!-- workbench-task-lifecycle:v2\n")
    handle.write(json.dumps(value, separators=(",", ":")) + "\n")
    handle.write("-->\nworkbench task lifecycle: task-active\n")
    handle.write("<!-- fixture-comment-end -->\n")
PY
  out="$TMPDIR/submit_invalid_current/reactivated.out"
  if run_task_in_dir submit_invalid_current "$SUBMISSION_TASK_DIR" \
    verify --format json >"$out" 2>&1; then
    fail "reactivation did not invalidate the submitted PR recovery"
  fi
  assert_file_contains "$out" 'authenticated submitted task recovery is unavailable'
}

test_v2_submission_rejects_noncanonical_cleanup_history() {
  local out
  prepare_submission_fixture submit_bad_cleanup
  out="$TMPDIR/submit_bad_cleanup/prepared.out"
  if WORKBENCH_TEST_FAIL_SUBMISSION_STAGE=prepared \
    run_task_in_dir submit_bad_cleanup "$SUBMISSION_TASK_DIR" submit \
      --title "feat: bad cleanup" --body-file "$SUBMISSION_BODY" >"$out" 2>&1; then
    fail "bad cleanup fixture did not stop after preparation"
  fi
  git -C "$SUBMISSION_TASK_DIR" rm -r -q task
  mkdir -p "$SUBMISSION_TASK_DIR/"$'FORGED\ntask'
  printf '%s\n' forged > "$SUBMISSION_TASK_DIR/"$'FORGED\ntask/looks-safe'
  git -C "$SUBMISSION_TASK_DIR" add -A
  git -C "$SUBMISSION_TASK_DIR" commit -q -m "test: forge noncanonical cleanup"
  if run_task_in_dir submit_bad_cleanup "$SUBMISSION_TASK_DIR" submit \
    --title "feat: bad cleanup" --body-file "$SUBMISSION_BODY" >"$out" 2>&1; then
    fail "submission accepted cleanup history with non-task changes"
  fi
  [ ! -e "$TMPDIR/submit_bad_cleanup/comments/pr-17.json" ] \
    || fail "noncanonical cleanup history created a PR"
}

test_lifecycle_parser_is_strict_trusted_and_key_order_independent() {
  local observation valid_snapshot valid out rc
  observation="$TMPDIR/lifecycle-observation.json"
  python3 - "$observation" <<'PY'
import json
import sys

value = {
    "task_contract": "workbench-task/v2",
    "event": "task-submitted",
    "claim_id": "task__29-fixture",
    "issue": 29,
    "home": None,
    "branch": "task/29-fixture",
    "workspace_authority_descriptor_digest": "sha256:" + "a" * 64,
    "pr": 17,
    "revision": "a" * 40,
    "action_instance_id": None,
    "intent_digest": None,
    "actor": "test@example.invalid",
    "tool": "workbench",
    "at": "2026-07-11T05:02:00Z",
}
value = {key: value[key] for key in reversed(list(value))}
body = "<!-- workbench-task-lifecycle:v2\n" + json.dumps(value, separators=(",", ":")) + "\n-->\n"
observation = {
    "contract_version": "workbench-hosting-lifecycle-observation/v1",
    "repository_origin_url": "https://github.com/example/workbench.git",
    "issue": 29,
    "pagination": {"complete": True, "pages_fetched": 1, "end_cursor": None, "failure": None},
    "comments": [{"author_identity": "test@example.invalid", "body": body}],
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(observation, handle, separators=(",", ":"))
    handle.write("\n")
PY
  valid_snapshot="$TMPDIR/lifecycle-valid-observation.json"; cp "$observation" "$valid_snapshot"
  out="$(python3 "$LIFECYCLE_HELPER" markers --observation-file "$observation" \
    --repository-origin-url https://github.com/example/workbench.git --issue 29 --format jsonl)"
  valid="$(printf '%s\n' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["event"])')"
  [ "$valid" = task-submitted ] || fail "reordered valid lifecycle marker was rejected"

  python3 - "$observation" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["comments"][0]["body"] = value["comments"][0]["body"].replace(
    '{"at":', '{"event":"task-active","at":', 1
)
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(value, separators=(",", ":")) + "\n")
PY
  if python3 "$LIFECYCLE_HELPER" markers --observation-file "$observation" \
    --repository-origin-url https://github.com/example/workbench.git --issue 29 --format jsonl \
    >"$TMPDIR/lifecycle-duplicate.out" 2>&1; then
    fail "lifecycle parser accepted a duplicate JSON member"
  else rc=$?; fi
  [ "$rc" = 1 ] || [ "$rc" = 2 ] || fail "duplicate lifecycle member returned $rc"

  cp "$valid_snapshot" "$observation"
  python3 - "$observation" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["pagination"]["complete"] = False
value["pagination"]["failure"] = {"code": "page-unavailable", "ref": "cursor:2"}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(value, separators=(",", ":")) + "\n")
PY
  if python3 "$LIFECYCLE_HELPER" markers --observation-file "$observation" \
    --repository-origin-url https://github.com/example/workbench.git --issue 29 --format jsonl \
    >"$TMPDIR/lifecycle-partial.out" 2>&1; then
    fail "lifecycle parser treated incomplete pagination as an empty trusted source"
  fi
}

test_status_rejects_forged_current_v2_task_identity() {
  local repo task_dir actual index original_claim original_descriptor branch out err rc
  repo="$(setup_workbench status_identity)"
  task_dir="$(start_task status_identity "$repo")"
  index="$task_dir/task/index.md"
  original_claim="$(sed -n 's/^claim_id: *//p' "$index")"
  original_descriptor="$(sed -n 's/^workspace_authority_descriptor_digest: *//p' "$index")"
  branch="$(git -C "$task_dir" symbolic-ref --quiet --short HEAD)"
  actual="$(run_task_in_dir status_identity "$task_dir" status --format json)"
  assert_contains "$actual" '"task_id":"29"'
  assert_contains "$actual" '"issue":29'
  assert_contains "$actual" '"home":null'
  assert_contains "$actual" '"parent":null'
  assert_contains "$actual" "\"claim_id\":\"$original_claim\""
  assert_contains "$actual" "\"branch\":\"$branch\""
  assert_contains "$actual" "\"workspace_authority_descriptor_digest\":\"$original_descriptor\""

  python3 - "$index" <<'PY'
import sys

path = sys.argv[1]
rows = open(path, encoding="utf-8").read().splitlines()
rows = ["claim_id: forged-local-claim" if row.startswith("claim_id:") else row for row in rows]
open(path, "w", encoding="utf-8").write("\n".join(rows) + "\n")
PY
  out="$TMPDIR/status_identity/forged.out"; err="$TMPDIR/status_identity/forged.err"
  if run_task_in_dir status_identity "$task_dir" status --format json >"$out" 2>"$err"; then
    fail "public task status projected a forged current v2 identity"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "forged current v2 status returned $rc"
  [ ! -s "$out" ] || fail "forged current v2 status emitted a public projection"
  assert_file_contains "$err" 'task-status-identity-unreconciled'
}

test_kernel_acceptance_attempt_is_stable_and_crash_reducible() {
  local repo task_dir out rc attempt acceptance_id actual receipt before_views after_views
  repo="$(setup_workbench acceptance_attempt)"
  printf 'web: https://github.com/example/web.git\n' > "$repo/codebases.yaml"
  git -C "$repo" add codebases.yaml
  git -C "$repo" commit -q -m "test: register acceptance attempt owner"
  git -C "$repo" push -q
  task_dir="$(start_task acceptance_attempt "$repo")"
  run_task_in_dir acceptance_attempt "$task_dir" deliverable declare --id web-pr --owner web \
    --kind codebase-pr --external-ref https://github.com/example/web/pull/7 \
    --revision abc123 --format json >/dev/null
  run_task_in_dir acceptance_attempt "$task_dir" deliverable update --id web-pr \
    --state submitted --format json >/dev/null
  before_views="$(grep -c 'pr view' "$TMPDIR/acceptance_attempt/gh.log" || true)"
  out="$TMPDIR/acceptance_attempt/pre-probe.out"
  if WORKBENCH_TEST_FAIL_AFTER_ACCEPTANCE_ATTEMPT=1 run_task_in_dir acceptance_attempt \
    "$task_dir" deliverable accept --id web-pr --format json >"$out" 2>&1; then
    fail "kernel acceptance ignored the pre-probe attempt crash"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "pre-probe attempt crash returned $rc"
  attempt="$task_dir/task/.workbench/acceptance-attempts/web-pr.record"
  [ -f "$attempt" ] || fail "kernel acceptance did not persist its attempt before probing"
  acceptance_id="$(sed -n 's/^acceptance_id=//p' "$attempt")"
  [ -n "$acceptance_id" ] || fail "acceptance attempt has no stable ID"
  after_views="$(grep -c 'pr view' "$TMPDIR/acceptance_attempt/gh.log" || true)"
  [ "$before_views" = "$after_views" ] || fail "pre-probe crash queried the PR"

  out="$TMPDIR/acceptance_attempt/post-probe.out"
  if WORKBENCH_TEST_FAIL_AFTER_ACCEPTANCE_PROBE=1 run_task_in_dir acceptance_attempt \
    "$task_dir" deliverable accept --id web-pr --format json >"$out" 2>&1; then
    fail "kernel acceptance ignored the post-probe crash"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "post-probe acceptance crash returned $rc"
  [ "$(sed -n 's/^acceptance_id=//p' "$attempt")" = "$acceptance_id" ] \
    || fail "post-probe retry replaced the stable attempt ID"
  [ ! -e "$task_dir/task/.workbench/acceptances/$acceptance_id.record" ] \
    || fail "post-probe crash wrote an acceptance receipt"

  out="$TMPDIR/acceptance_attempt/post-primary.out"
  if WORKBENCH_TEST_FAIL_AFTER_ACCEPTANCE_PRIMARY=1 run_task_in_dir acceptance_attempt \
    "$task_dir" deliverable accept --id web-pr --format json >"$out" 2>&1; then
    fail "kernel acceptance ignored the post-primary crash"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "post-primary acceptance crash returned $rc"
  receipt="$task_dir/task/.workbench/acceptances/$acceptance_id.record"
  [ -f "$receipt" ] || fail "kernel acceptance crash lost its durable receipt"
  assert_file_contains "$task_dir/task/.workbench/deliverables/web-pr.record" 'state=submitted'

  actual="$(run_task_in_dir acceptance_attempt "$task_dir" deliverable accept \
    --id web-pr --format json)"
  assert_contains "$actual" "\"acceptance_id\":\"$acceptance_id\""
  assert_contains "$actual" '"state":"accepted"'
  out="$TMPDIR/acceptance_attempt/changed-subject.out"
  if GH_PR_MERGE=changed789 run_task_in_dir acceptance_attempt "$task_dir" deliverable accept \
    --id web-pr --format json >"$out" 2>&1; then
    fail "kernel acceptance retained a receipt after immutable PR subject drift"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "changed immutable acceptance subject returned $rc"
  assert_file_contains "$out" 'acceptance-authority-mismatch'
}

test_concurrent_writer_uses_complete_sealed_context_union() {
  local first second third out rc actual registration registration_backup
  local first_branch first_head cleanup_tree cleanup_commit corrupt_tree corrupt_commit
  setup_writer_workbench writer_context_union
  prepare_writer_task writer_context_union 29; first="$WRITER_TASK_DIR"
  replace_writer_context "$first" first deny
  WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
  WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_context_union "$first" add-repo shared-api --format json >/dev/null
  first_branch="$(sed -n 's/^branch: *//p' "$first/task/index.md")"
  first_head="$(git -C "$first" rev-parse HEAD)"
  cleanup_tree="$(git -C "$first" rev-parse 'origin/main^{tree}')"
  cleanup_commit="$(printf '%s\n' 'test: publish cleanup-only task tip' \
    | git -C "$first" commit-tree "$cleanup_tree" -p "$first_head")"
  git -C "$first" push -q origin "$cleanup_commit:refs/heads/$first_branch"
  prepare_writer_task writer_context_union 31; second="$WRITER_TASK_DIR"
  replace_writer_context "$second" second allow
  registration="$first/task/.workbench/policy-context/registration.json"
  registration_backup="$TMPDIR/writer_context_union/first-registration.json"
  mv "$registration" "$registration_backup"
  out="$TMPDIR/writer_context_union/second.out"
  if WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_context_union "$second" add-repo shared-api --format json \
      >"$out" 2>&1; then
    fail "concurrent writer omitted the competing sealed deny context"
  else rc=$?; fi
  mv "$registration_backup" "$registration"
  [ "$rc" = 4 ] || fail "complete context union deny returned $rc: $(cat "$out")"
  actual="$(cat "$out")"
  assert_contains "$actual" '"context_ref":"toolbox:product/first"'
  assert_contains "$actual" '"context_ref":"toolbox:product/second"'
  [ ! -e "$second/task/codebases/shared-api" ] || fail "denied context union created a worktree"

  rm "$first/task/.workbench/policy-context/registration.json"
  git -C "$first" add -u task/.workbench/policy-context/registration.json
  git -C "$first" commit -q -m "test: corrupt competing remote context"
  corrupt_tree="$(git -C "$first" rev-parse 'HEAD^{tree}')"
  corrupt_commit="$(printf '%s\n' 'test: publish corrupt task snapshot' \
    | git -C "$first" commit-tree "$corrupt_tree" -p "$cleanup_commit")"
  git -C "$first" push -q origin "$corrupt_commit:refs/heads/$first_branch"
  prepare_writer_task writer_context_union 33; third="$WRITER_TASK_DIR"
  replace_writer_context "$third" third allow
  out="$TMPDIR/writer_context_union/missing.out"
  if WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_context_union "$third" add-repo shared-api --format json \
      >"$out" 2>&1; then
    fail "concurrent writer accepted an incomplete competing sealed context"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "missing competing context returned $rc"
  assert_file_contains "$out" 'policy-context-unavailable'
  [ ! -e "$third/task/codebases/shared-api" ] || fail "missing context created a worktree"
}

test_concurrent_policy_union_includes_competing_task_policy() {
  local current competing claim policy digest registration state output set_digest
  local registration_ref registration_digest union payload request intent actual rc current_claim
  setup_writer_workbench writer_task_policy_union
  prepare_writer_task writer_task_policy_union 29; current="$WRITER_TASK_DIR"
  prepare_writer_task writer_task_policy_union 31; competing="$WRITER_TASK_DIR"
  replace_writer_context "$competing" competing allow
  claim="$(sed -n 's/^claim_id: *//p' "$competing/task/index.md")"
  policy="$competing/task/.workbench/policy.conf"
  printf '%s\n' 'schema=workbench-policy/v1' 'action.task.concurrent-write=deny' > "$policy"
  digest="sha256:$(python3 - "$policy" <<'PY'
import hashlib
import sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)"
  registration="$competing/task/.workbench/policy-context/registration.json"
  python3 - "$registration" "$digest" <<'PY'
import json
import sys

path, digest = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    value = json.load(handle)
receipt = {
    "contract_version": "workbench-policy-authority-receipt/v1",
    "authority_identity": "toolbox:authority/competing-task",
    "authority_ref": "toolbox:policy/competing-task",
    "authority_revision": "sha256:" + "b" * 64,
    "policy_ref": "task/.workbench/policy.conf",
    "policy_digest": digest,
    "actor": "owner@example.com",
    "issued_at": "2026-07-11T05:03:00Z",
    "source_ref": "toolbox:approval/competing-task",
}
value["task_policy"] = {
    "policy_ref": "task/.workbench/policy.conf",
    "policy_digest": digest,
    "authority_ref": "toolbox:policy/competing-task",
    "authority_receipt": receipt,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(value, handle, separators=(",", ":"))
    handle.write("\n")
PY
  output="$(python3 "$CONTRACT_HELPER" context-set --registration-file "$registration" \
    --workspace-root "$competing" --sealed true --changed true --format shell)"
  set_digest="$(printf '%s\n' "$output" | sed -n 's/^digest=//p')"
  registration_ref="$(printf '%s\n' "$output" | sed -n 's/^registration_ref=//p')"
  registration_digest="$(printf '%s\n' "$output" | sed -n 's/^registration_digest=//p')"
  state="$competing/task/.workbench/policy-context/state.record"
  sed -e "s|^registration_ref=.*|registration_ref=$registration_ref|" \
    -e "s|^registration_digest=.*|registration_digest=$registration_digest|" \
    -e "s|^digest=.*|digest=$set_digest|" "$state" > "$state.next"
  mv "$state.next" "$state"

  union="$TMPDIR/writer_task_policy_union/union.manifest"
  {
    printf '%s\n' 'workbench-concurrent-context-union/v1'
    printf 'context\t%s\t%s\t%s\t%s\n' "$claim" "$set_digest" "$competing" "$registration"
  } > "$union"
  current_claim="$(sed -n 's/^claim_id: *//p' "$current/task/index.md")"
  payload="$TMPDIR/writer_task_policy_union/payload.txt"
  python3 "$INTENT_HELPER" build-payload --contract workbench-writer-request/v1 \
    --field operation_id=wop_task_policy_union --field claim_id=wc_task_policy_union \
    --field owner=shared-api \
    --field "branch=$(git -C "$current" branch --show-current)" \
    --field expected_path=task/codebases/shared-api \
    --field codebase_origin_url=https://github.com/example/shared-api.git \
    --field "context_policy_set_digest=$(sed -n 's/^digest=//p' \
      "$current/task/.workbench/policy-context/state.record")" \
    --field conflict_revision=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    > "$payload"
  request="$TMPDIR/writer_task_policy_union/request.json"
  python3 "$INTENT_HELPER" build-request --action-id task.concurrent-write \
    --task-claim-id "$current_claim" \
    --target-ref workbench:codebase/shared-api \
    --revision sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --payload-contract workbench-writer-request/v1 --payload-file "$payload" \
    > "$request"
  intent="$(python3 "$INTENT_HELPER" request "$request" --format shell \
    | sed -n 's/^intent_digest=//p')"
  if WORKBENCH_CONCURRENT_CONTEXTS_FILE="$union" \
    WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_policy_in_dir writer_task_policy_union "$current" resolve --request-file "$request" \
      --intent-digest "$intent" --format json \
      > "$TMPDIR/writer_task_policy_union/resolution.json"; then
    fail "concurrent policy union dropped a competing task-level deny"
  else rc=$?; fi
  [ "$rc" = 4 ] || fail "competing task policy deny returned $rc"
  actual="$(cat "$TMPDIR/writer_task_policy_union/resolution.json")"
  assert_contains "$actual" '"layer":"task"'
  python3 - "$TMPDIR/writer_task_policy_union/resolution.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    sources = json.load(handle)["action_instance"]["policy_manifest"]["sources"]
rank = {"platform": 0, "workspace": 1, "context": 2, "task": 3}
keys = [(rank[item["layer"]], item["context_ref"] or "", item["authority_identity"], item["policy_ref"]) for item in sources]
assert keys == sorted(keys), keys
PY
}

test_terminal_writer_join_rejects_remote_claim_without_local_operation() {
  local task_dir actual operation_id operation_backup out rc
  setup_writer_workbench writer_bijection
  prepare_writer_task writer_bijection 29; task_dir="$WRITER_TASK_DIR"
  actual="$(WORKBENCH_PLATFORM_POLICY="$WRITER_PLATFORM_POLICY" \
    WORKBENCH_PLATFORM_POLICY_REF=platform:fixture/writer \
    run_task_in_dir writer_bijection "$task_dir" add-repo shared-api --format json)"
  operation_id="$(json_get "$actual" operation_id)"
  operation_backup="$TMPDIR/writer_bijection/$operation_id.json"
  mv "$task_dir/task/.workbench/writer-operations/$operation_id.json" "$operation_backup"
  out="$TMPDIR/writer_bijection/verify.out"
  if run_task_in_dir writer_bijection "$task_dir" verify --format json >"$out" 2>&1; then
    fail "verification accepted an authoritative remote claim without its local operation"
  else rc=$?; fi
  [ "$rc" = 1 ] || fail "orphan remote claim returned $rc"
  assert_file_contains "$out" '"code":"writer-claim-unreconciled"'
  assert_file_contains "$out" "\"ref\":\"$operation_id\""
  mv "$operation_backup" "$task_dir/task/.workbench/writer-operations/$operation_id.json"
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
run_case test_work_ref_uniqueness_rejects_remote_only_task
run_case test_work_ref_uniqueness_retains_submitted_deleted_branch
run_case test_work_ref_inventory_requires_complete_pagination
run_case test_work_ref_inventory_covers_removed_codebase_home
run_case test_work_ref_inventory_is_cross_clone
run_case test_work_ref_inventory_uses_authority_default_ref
run_case test_work_ref_inventory_fails_closed_on_identity_mismatch
run_case test_work_ref_inventory_rejects_lifecycle_without_initial_claim
run_case test_deliverables_and_revision_bound_evidence
run_case test_tracked_v2_records_cannot_forge_accepted_or_waived_state
run_case test_evidence_time_is_kernel_owned_and_future_rows_fail_closed
run_case test_kernel_probe_acceptance_is_revision_and_owner_bound
run_case test_accepted_deliverable_revision_reset_preserves_append_only_receipts
run_case test_pack_deliverable_owner_binding_is_immutable_and_authorized
run_case test_pack_acceptance_recovers_from_durable_primary
run_case test_deliverable_governed_effect_is_single_bound_reasoned_and_resettable
run_case test_required_check_waive_is_reasoned_revision_bound_and_idempotent
run_case test_governed_authorization_ref_is_parsed_as_json
run_case test_governed_primary_revalidates_policy_after_authorization
run_case test_governed_primary_revalidates_local_preimage
run_case test_governed_revalidation_does_not_recreate_missing_context
run_case test_governed_revalidation_binds_exact_action_record
run_case test_policy_context_is_owner_authorized_sealed_and_manifest_bound
run_case test_null_context_lazy_seal_and_frozen_action_registry
run_case test_unsealed_policy_context_replacement_invalidates_old_actions
run_case test_submitted_and_failed_deliverables_block_verification
run_case test_harvest_ledger_is_explicit_sealed_and_governed
run_case test_codebase_only_completion_is_policy_gated_and_cleanup_safe
run_case test_abandonment_is_terminal_and_distinct_from_cleanup
run_case test_terminal_outcome_freezes_mutations_and_verification_is_read_only
run_case test_terminal_lifecycle_rejects_post_terminal_reactivation
run_case test_forged_local_terminal_has_no_freeze_or_outcome_authority
run_case test_cleanup_prepared_journal_failure_deletes_nothing
run_case test_cleanup_rejects_untrusted_prepared_journal
run_case test_cleanup_rejects_prepared_journal_without_terminal_action_join
run_case test_cleanup_journal_recovers_completed_and_lifecycle_after_deletion
run_case test_cleanup_deleted_retry_rejects_tampered_immutable_intent
run_case test_v2_cleanup_requires_terminal_outcome_even_with_force
run_case test_writer_claim_cas_retry_rechecks_conflict_before_local_creation
run_case test_writer_rejects_non_append_only_coordination_history
run_case test_writer_anchor_is_nofollow_and_exact
run_case test_writer_anchor_rejects_symlinked_parent
run_case test_writer_anchor_rejects_hardlink
run_case test_writer_anchor_temp_creation_is_exclusive
run_case test_writer_root_initialization_recovers_once
run_case test_writer_first_observation_adopts_durable_anchor
run_case test_writer_local_failure_releases_remote_claim_before_new_id
run_case test_writer_binds_protected_registry_and_rejects_cache_origin
run_case test_writer_conflict_uses_complete_legacy_and_v2_union
run_case test_writer_zero_history_recovery_rebinds_before_once_only_owner_acquire
run_case test_writer_zero_history_rejects_nonexact_remote_binding
run_case test_writer_operation_cancel_distinguishes_no_effect_from_external_effect
run_case test_writer_operation_handoff_transfers_to_explicit_clone
run_case test_writer_effect_prefix_crashes_resume_once_only
run_case test_writer_effect_prefix_mismatch_preserves_external_effects
run_case test_writer_effect_prefix_resumes_bound_conflict_action
run_case test_writer_revalidates_stale_policy_at_effect_boundaries
run_case test_writer_revalidates_legacy_union_before_first_primary
run_case test_writer_union_ambiguity_preserves_claim_and_cursor
run_case test_writer_compensation_prefixes_resume_exact_cursor
run_case test_writer_persists_allow_replacement_before_first_effect
run_case test_writer_authority_revalidation_fails_closed_without_compensation
run_case test_terminal_writer_verification_joins_exact_record_and_lifecycle_provenance
run_case test_cleanup_retires_consumed_writer_before_local_deletion
run_case test_cleanup_removal_failure_keeps_remote_claim_reserved
run_case test_cleanup_rejects_symlinked_external_worktree_with_copied_marker
run_case test_cleanup_revalidates_exact_descriptor_before_removal
run_case test_cleanup_descriptor_pins_task_and_clone_common_dirs
run_case test_cleanup_rejects_broken_symlink_worktree
run_case test_status_reports_concurrent_writer_conflicts
run_case test_v2_submit_reconciles_durable_submission_without_v1_fallback
run_case test_v1_submission_without_origin_head_uses_main_fallback
run_case test_v2_submission_restores_authenticated_state_to_terminal_cleanup
run_case test_v2_submission_crash_boundaries_are_idempotent
run_case test_v2_submission_restore_never_overwrites_occupied_state
run_case test_v2_submission_reconstructs_recovery_in_fresh_clone
run_case test_v2_submission_rejects_restored_deliverable_tampering
run_case test_v2_submission_rejects_deleted_restored_deliverable
run_case test_v2_submission_rejects_deleted_restored_required_check
run_case test_v2_submission_rejects_restored_acceptance_tampering
run_case test_v2_submitted_completion_keeps_cleanup_authorization_separate
run_case test_v2_submitted_abandonment_publishes_one_terminal_checkpoint
run_case test_v2_terminal_checkpoint_rejects_adversarial_observations
run_case test_v2_submission_rejects_noncanonical_pr_and_lifecycle_state
run_case test_v2_submission_rejects_noncanonical_cleanup_history
run_case test_lifecycle_parser_is_strict_trusted_and_key_order_independent
run_case test_status_rejects_forged_current_v2_task_identity
run_case test_kernel_acceptance_attempt_is_stable_and_crash_reducible
run_case test_concurrent_writer_uses_complete_sealed_context_union
run_case test_concurrent_policy_union_includes_competing_task_policy
run_case test_terminal_writer_join_rejects_remote_claim_without_local_operation

[ "$SOURCE_HEAD" = "$(git -C "$SOURCE_REPO" rev-parse HEAD)" ] || fail "test committed in source repo"
[ "$SOURCE_STATUS" = "$(git -C "$SOURCE_REPO" status --porcelain=v1)" ] || fail "test modified source repo"

echo "PASS workbench v2 task lifecycle tests"
