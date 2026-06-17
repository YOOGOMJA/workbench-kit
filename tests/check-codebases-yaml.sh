#!/usr/bin/env bash
set -euo pipefail

# Functional test for `utils/workbench setup`'s codebases.yaml parsing: malformed
# inputs must be rejected with a clear, line-numbered error (never silently
# misparsed), while the supported `name: <git-url>` form clones.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKBENCH="$ROOT/plugins/workbench/utils/workbench"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wbk-codebases.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# A local bare repo to clone from (offline happy path).
SRC="$TMP/src.git"
git init -q --bare "$SRC"
seed="$TMP/seed"
git init -q "$seed"
git -C "$seed" config user.email t@e.invalid
git -C "$seed" config user.name t
: > "$seed/f"; git -C "$seed" add f; git -C "$seed" commit -qm init
git -C "$seed" remote add origin "$SRC"; git -C "$seed" push -q origin HEAD:refs/heads/main

new_repo() {
  local d="$TMP/repo.$1"
  git init -q "$d"
  mkdir -p "$d/utils"
  cp "$WORKBENCH" "$d/utils/workbench"; chmod +x "$d/utils/workbench"
  printf '%s\n' "$d"
}

# run setup; echoes combined output, returns its exit code
run_setup() { ( cd "$1" && ./utils/workbench setup ) 2>&1; }

# --- malformed inputs must be rejected ---
assert_rejected() {
  local label="$1" manifest="$2" needle="$3" d out
  d="$(new_repo "$label")"
  printf '%s\n' "$manifest" > "$d/codebases.yaml"
  if out="$(run_setup "$d")"; then
    fail "$label: expected non-zero exit, got success: $out"
  fi
  grep -Fq "$needle" <<<"$out" || fail "$label: error missing '$needle' — got: $out"
  if [ -d "$d/.codebases" ] && find "$d/.codebases" -mindepth 1 | grep -q .; then
    fail "$label: nothing should be cloned on a rejected manifest"
  fi
}

assert_rejected numeric "123: $SRC"            "순수 숫자"
assert_rejected indented "  app: $SRC"          "들여쓰기"
assert_rejected list     "- app"                "리스트"
assert_rejected nocolon  "appurl"               "형식이 아님"
assert_rejected quotes   "\"app\": $SRC"        "따옴표"
assert_rejected inline   "app: $SRC # comment"  "인라인 주석"
assert_rejected emptyurl "app:"                 "비어 있음"

# --- comments / blanks only → no repos ---
d="$(new_repo onlycomments)"
printf '# a comment\n\n   # indented comment\n' > "$d/codebases.yaml"
out="$(run_setup "$d")" || fail "comments-only should succeed: $out"
grep -Fq "등록된 repo가 없다" <<<"$out" || fail "comments-only: expected 'no repos' — got: $out"

# --- valid line clones (offline, from local bare repo) ---
d="$(new_repo valid)"
printf '# target\nmy-app: %s\n' "$SRC" > "$d/codebases.yaml"
out="$(run_setup "$d")" || fail "valid manifest should succeed: $out"
[ -d "$d/.codebases/my-app/.git" ] || fail "valid: my-app was not cloned"
grep -Fq "clone: my-app" <<<"$out" || fail "valid: missing clone line — got: $out"

# re-running is idempotent (skip already-cloned)
out="$(run_setup "$d")" || fail "re-run should succeed: $out"
grep -Fq "skip: my-app" <<<"$out" || fail "re-run: expected skip — got: $out"

echo "PASS codebases.yaml parsing tests"
