#!/usr/bin/env bash
set -euo pipefail

# ROOT = the workbench engine plugin (holds utils/). SCAFFOLD_TEMPLATES = the kit's
# scaffold/templates (profile defaults live there, not under the plugin).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAFFOLD_TEMPLATES="$(cd "$ROOT/../.." && pwd)/scaffold/templates"
TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/workbench-task-lifecycle.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1" pattern="$2"
  [ -f "$file" ] || fail "missing file: $file"
  grep -Fq "$pattern" "$file" || fail "expected $file to contain: $pattern"
}

assert_file_not_contains() {
  local file="$1" pattern="$2"
  [ ! -f "$file" ] && return 0
  ! grep -Fq "$pattern" "$file" || fail "expected $file not to contain: $pattern"
}

write_fake_gh() {
  local bin_dir="$1"
  cat > "$bin_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "$(pwd) $*" >> "$GH_LOG"

case "${1:-} ${2:-}" in
  "issue view")
    issue="$3"
    if [ "$issue" = "29" ]; then
      case "$*" in
        *"--json comments"*) cat "$GH_COMMENTS_DIR/$issue.comments" 2>/dev/null || true ;;
        *"--json title"*) printf '%s\n' "task-start claim lifecycle" ;;
        *"--json body"*) printf '%s\n' "issue body" ;;
        *) printf '%s\n' "{}" ;;
      esac
    else
      case "$*" in
        *"--json comments"*) cat "$GH_COMMENTS_DIR/$issue.comments" 2>/dev/null || true ;;
        *"--json title"*) printf '\n' ;;
        *"--json body"*) printf '\n' ;;
        *) printf '%s\n' "{}" ;;
      esac
    fi
    ;;
  "issue comment")
    issue="$3"
    body_file=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --body-file) body_file="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$body_file" ] || { echo "missing --body-file" >&2; exit 2; }
    if [ -n "${GH_ISSUE_COMMENT_FAIL_EVENT:-}" ] \
      && grep -Fq "event=$GH_ISSUE_COMMENT_FAIL_EVENT" "$body_file"; then
      echo "simulated issue comment failure" >&2
      exit 5
    fi
    mkdir -p "$GH_COMMENTS_DIR"
    cat "$body_file" >> "$GH_COMMENTS_DIR/$issue.comments"
    printf '\n' >> "$GH_COMMENTS_DIR/$issue.comments"
    printf 'https://example.invalid/issues/%s#issuecomment-1\n' "$issue"
    ;;
  "issue list")
    printf '29\ttask-start claim lifecycle\tOPEN\thttps://github.com/example/workbench/issues/29\n'
    printf '30\tunstarted ticket\tOPEN\thttps://github.com/example/workbench/issues/30\n'
    ;;
  "pr list")
    printf '\n'
    ;;
  "pr create")
    if [ "${GH_PR_CREATE_FAIL:-}" = "1" ]; then
      echo "simulated pr create failure" >&2
      exit 4
    fi
    printf 'https://github.com/example/workbench/pull/44\n'
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 9
    ;;
esac
EOF
  chmod +x "$bin_dir/gh"
}

setup_workbench() {
  local name="$1"
  local repo="$TMPDIR/$name/repo"
  local origin="$TMPDIR/$name/origin.git"
  local fake_bin="$TMPDIR/$name/bin"
  local comments="$TMPDIR/$name/comments"
  local home="$TMPDIR/$name/home"

  mkdir -p "$repo" "$fake_bin" "$comments" "$home"
  git init -q --bare "$origin"
  git init -q -b main "$repo"
  mkdir -p "$repo/utils" "$repo/templates"
  cp "$ROOT/utils/task" "$repo/utils/task"
  chmod +x "$repo/utils/task"
  cp "$SCAFFOLD_TEMPLATES/task-AGENTS.md" "$repo/templates/task-AGENTS.md"
  git -C "$repo" config user.name "Test User"
  git -C "$repo" config user.email "test@example.invalid"
  git -C "$repo" add utils/task templates/task-AGENTS.md
  git -C "$repo" commit -q -m "init"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q -u origin main

  : > "$TMPDIR/$name/gh.log"
  write_fake_gh "$fake_bin"

  printf '%s\n' "$repo"
}

run_task() {
  local case_name="$1" repo="$2"; shift 2
  run_task_in_dir "$case_name" "$repo" "$@"
}

run_task_in_dir() {
  local case_name="$1" dir="$2"; shift 2
  GH_LOG="$TMPDIR/$case_name/gh.log" \
  GH_COMMENTS_DIR="$TMPDIR/$case_name/comments" \
  GH_ISSUE_COMMENT_FAIL_EVENT="${GH_ISSUE_COMMENT_FAIL_EVENT:-}" \
  GH_PR_CREATE_FAIL="${GH_PR_CREATE_FAIL:-}" \
  HOME="$TMPDIR/$case_name/home" \
  PATH="$TMPDIR/$case_name/bin:$PATH" \
    bash -c 'dir="$1"; shift; cd "$dir"; "$dir/utils/task" "$@"' bash "$dir" "$@"
}

task_dir_for() {
  local repo="$1"
  printf '%s/.worktrees/task__29-task-start-claim-lifecycle\n' "$repo"
}

codebase_task_dir_for() {
  local repo="$1"
  printf '%s/.worktrees/task__my-app__34-fix-auth\n' "$repo"
}

add_increment_commit() {
  local dir="$1"
  printf 'increment\n' > "$dir/README.md"
  if [ -f "$dir/task/index.md" ]; then
    cat > "$dir/task/status.md" <<'EOF'
# Status

상태: 테스트 증분 준비
EOF
    (cd "$dir" && utils/task commit code update -m "feat: add increment")
  else
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "feat: add increment"
  fi
}

test_start_emits_claim_and_active() {
  local repo
  repo="$(setup_workbench start_success)"

  run_task start_success "$repo" start 29

  assert_file_contains "$TMPDIR/start_success/comments/29.comments" "workbench-task-lifecycle:v1"
  assert_file_contains "$TMPDIR/start_success/comments/29.comments" "event=task-claimed"
  assert_file_contains "$TMPDIR/start_success/comments/29.comments" "event=task-active"
  assert_file_contains "$TMPDIR/start_success/comments/29.comments" "branch=task/29-task-start-claim-lifecycle"
  git -C "$repo" ls-remote --exit-code --heads origin \
    "refs/heads/task/29-task-start-claim-lifecycle" >/dev/null \
    || fail "expected task branch to be pushed during start"
}

test_start_validation_failure_writes_no_lifecycle_comment() {
  local repo
  repo="$(setup_workbench start_validation_failure)"

  if run_task start_validation_failure "$repo" start 30; then
    fail "expected start 30 to fail without title or explicit slug"
  fi

  assert_file_not_contains "$TMPDIR/start_validation_failure/comments/30.comments" \
    "workbench-task-lifecycle:v1"
}

test_start_succeeds_when_active_comment_fails_after_push() {
  local repo out
  repo="$(setup_workbench start_active_comment_failure)"
  out="$TMPDIR/start_active_comment_failure/start.out"

  GH_ISSUE_COMMENT_FAIL_EVENT=task-active run_task start_active_comment_failure "$repo" start 29 > "$out"

  assert_file_contains "$out" "완료. cd"
  assert_file_contains "$TMPDIR/start_active_comment_failure/comments/29.comments" "event=task-claimed"
  assert_file_not_contains "$TMPDIR/start_active_comment_failure/comments/29.comments" "event=task-active"
  git -C "$repo" ls-remote --exit-code --heads origin \
    "refs/heads/task/29-task-start-claim-lifecycle" >/dev/null \
    || fail "expected task branch to remain pushed when active comment fails"
}

test_submit_emits_submitted_after_pr_create_success() {
  local repo task_dir body
  repo="$(setup_workbench submit_success)"
  run_task submit_success "$repo" start 29
  task_dir="$(task_dir_for "$repo")"
  add_increment_commit "$task_dir"
  body="$TMPDIR/submit_success/pr-body.md"
  printf 'body\n' > "$body"

  run_task_in_dir submit_success "$task_dir" submit --title "submit test" --body-file "$body"

  assert_file_contains "$TMPDIR/submit_success/comments/29.comments" "event=task-submitted"
  assert_file_contains "$TMPDIR/submit_success/comments/29.comments" "pr=44"
}

test_submit_pr_create_failure_writes_no_submitted_event() {
  local repo task_dir body
  repo="$(setup_workbench submit_pr_failure)"
  run_task submit_pr_failure "$repo" start 29
  task_dir="$(task_dir_for "$repo")"
  add_increment_commit "$task_dir"
  body="$TMPDIR/submit_pr_failure/pr-body.md"
  printf 'body\n' > "$body"

  if GH_PR_CREATE_FAIL=1 run_task_in_dir submit_pr_failure "$task_dir" submit --title "submit test" --body-file "$body"; then
    fail "expected submit to fail when pr create fails"
  fi

  assert_file_not_contains "$TMPDIR/submit_pr_failure/comments/29.comments" "event=task-submitted"
}

test_submit_succeeds_when_submitted_comment_fails_after_pr_create() {
  local repo task_dir body out
  repo="$(setup_workbench submit_comment_failure)"
  run_task submit_comment_failure "$repo" start 29
  task_dir="$(task_dir_for "$repo")"
  add_increment_commit "$task_dir"
  body="$TMPDIR/submit_comment_failure/pr-body.md"
  out="$TMPDIR/submit_comment_failure/submit.out"
  printf 'body\n' > "$body"

  GH_ISSUE_COMMENT_FAIL_EVENT=task-submitted \
    run_task_in_dir submit_comment_failure "$task_dir" submit --title "submit test" --body-file "$body" > "$out"

  assert_file_contains "$out" "https://github.com/example/workbench/pull/44"
  assert_file_not_contains "$TMPDIR/submit_comment_failure/comments/29.comments" "event=task-submitted"
}

test_submit_retry_after_cleanup_preserves_codebase_home() {
  local repo task_dir branch body out
  repo="$(setup_workbench submit_retry_codebase_home)"
  mkdir -p "$repo/.codebases/my-app"
  branch="task/my-app/34-fix-auth"
  task_dir="$(codebase_task_dir_for "$repo")"
  git -C "$repo" worktree add -q -b "$branch" "$task_dir" main
  add_increment_commit "$task_dir"
  body="$TMPDIR/submit_retry_codebase_home/pr-body.md"
  out="$TMPDIR/submit_retry_codebase_home/submit.out"
  printf 'body\n' > "$body"

  run_task_in_dir submit_retry_codebase_home "$task_dir" submit --title "submit retry" --body-file "$body" > "$out"

  assert_file_contains "$out" "https://github.com/example/workbench/pull/44"
  assert_file_contains "$TMPDIR/submit_retry_codebase_home/gh.log" ".codebases/my-app issue comment 34"
  assert_file_contains "$TMPDIR/submit_retry_codebase_home/comments/34.comments" "event=task-submitted"
  assert_file_contains "$TMPDIR/submit_retry_codebase_home/comments/34.comments" "home=my-app"
}

test_done_emits_cleaned_without_closing_issue() {
  local repo
  repo="$(setup_workbench done_success)"
  run_task done_success "$repo" start 29

  run_task done_success "$repo" done 29

  assert_file_contains "$TMPDIR/done_success/comments/29.comments" "event=task-cleaned"
  assert_file_not_contains "$TMPDIR/done_success/gh.log" "issue close"
}

test_done_succeeds_when_cleaned_comment_fails_after_cleanup() {
  local repo branch
  repo="$(setup_workbench done_comment_failure)"
  run_task done_comment_failure "$repo" start 29
  branch="task/29-task-start-claim-lifecycle"

  GH_ISSUE_COMMENT_FAIL_EVENT=task-cleaned run_task done_comment_failure "$repo" done 29

  [ ! -d "$(task_dir_for "$repo")" ] || fail "expected task worktree to be removed"
  ! git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" \
    || fail "expected local task branch to be removed"
  assert_file_not_contains "$TMPDIR/done_comment_failure/comments/29.comments" "event=task-cleaned"
}

test_tickets_reports_lifecycle_facts_read_only() {
  local repo out
  repo="$(setup_workbench tickets_readonly)"
  run_task tickets_readonly "$repo" start 29
  : > "$TMPDIR/tickets_readonly/gh.log"

  out="$TMPDIR/tickets_readonly/tickets.out"
  run_task tickets_readonly "$repo" tickets > "$out"

  assert_file_contains "$out" "issue: 29"
  assert_file_contains "$out" "title: task-start claim lifecycle"
  assert_file_contains "$out" "branch: task/29-task-start-claim-lifecycle"
  assert_file_contains "$out" "lifecycle_event: task-active"
  assert_file_contains "$out" "issue: 30"
  assert_file_contains "$out" "title: unstarted ticket"
  assert_file_not_contains "$TMPDIR/tickets_readonly/gh.log" "issue comment"
  assert_file_not_contains "$TMPDIR/tickets_readonly/gh.log" "issue close"
}

test_tickets_detects_remote_only_task_branch_without_fetch() {
  local repo fresh out branch
  repo="$(setup_workbench tickets_remote_only)"
  run_task tickets_remote_only "$repo" start 29
  branch="task/29-task-start-claim-lifecycle"
  fresh="$TMPDIR/tickets_remote_only/fresh"
  git clone -q "$TMPDIR/tickets_remote_only/origin.git" "$fresh"
  mkdir -p "$fresh/utils" "$fresh/templates"
  cp "$ROOT/utils/task" "$fresh/utils/task"
  chmod +x "$fresh/utils/task"
  cp "$SCAFFOLD_TEMPLATES/task-AGENTS.md" "$fresh/templates/task-AGENTS.md"

  out="$TMPDIR/tickets_remote_only/tickets.out"
  run_task_in_dir tickets_remote_only "$fresh" tickets > "$out"

  assert_file_contains "$out" "branch: $branch"
  assert_file_contains "$out" "branch_local: no"
  assert_file_contains "$out" "branch_remote: yes"
}

test_lifecycle_latest_for_branch_uses_exact_branch_match() {
  local repo out comments
  repo="$(setup_workbench tickets_exact_branch)"
  comments="$TMPDIR/tickets_exact_branch/comments/29.comments"
  mkdir -p "$(dirname "$comments")"
  cat > "$comments" <<'EOF'
<!-- workbench-task-lifecycle:v1 event=task-active claim_id=right issue=29 home=- branch=task/29-task-start-claim-lifecycle pr=- actor=test tool=utils/task at=2026-06-13T00:00:00Z -->
workbench task lifecycle: task-active `task/29-task-start-claim-lifecycle`
<!-- workbench-task-lifecycle:v1 event=task-active claim_id=wrong issue=29 home=- branch=task/29-task-start-claim-lifecycle-extra pr=- actor=test tool=utils/task at=2026-06-13T00:00:01Z -->
workbench task lifecycle: task-active `task/29-task-start-claim-lifecycle-extra`
EOF
  git -C "$repo" checkout -q -b task/29-task-start-claim-lifecycle
  git -C "$repo" push -q -u origin task/29-task-start-claim-lifecycle
  git -C "$repo" checkout -q main

  out="$TMPDIR/tickets_exact_branch/tickets.out"
  run_task tickets_exact_branch "$repo" tickets > "$out"

  assert_file_contains "$out" "lifecycle_claim_id: right"
}

test_start_emits_claim_and_active
test_start_validation_failure_writes_no_lifecycle_comment
test_start_succeeds_when_active_comment_fails_after_push
test_submit_emits_submitted_after_pr_create_success
test_submit_pr_create_failure_writes_no_submitted_event
test_submit_succeeds_when_submitted_comment_fails_after_pr_create
test_submit_retry_after_cleanup_preserves_codebase_home
test_done_emits_cleaned_without_closing_issue
test_done_succeeds_when_cleaned_comment_fails_after_cleanup
test_tickets_reports_lifecycle_facts_read_only
test_tickets_detects_remote_only_task_branch_without_fetch
test_lifecycle_latest_for_branch_uses_exact_branch_match

echo "PASS task lifecycle tests"
