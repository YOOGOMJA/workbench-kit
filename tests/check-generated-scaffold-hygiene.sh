#!/usr/bin/env bash
# Regression test for generated workbench git hygiene. The minimal user repo must
# still carry the git rules that keep workbench infrastructure out of commits and
# preserve append-only logs across parallel task merges.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$ROOT/plugins/workbench-kit/skills/generate-workbench/scripts/compose.sh"
SCAFFOLD="$ROOT/plugins/workbench-kit/scaffold"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/wb-generated-hygiene.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

persona="$tmp/persona"
out="$tmp/generated-workbench"
mkdir -p "$persona"
printf '## Language\n- Operational output language: **English**.\n' > "$persona/overlay.md"

bash "$COMPOSE" \
  --persona "$persona" \
  --core "$SCAFFOLD/AGENTS.core.md" \
  --scaffold "$SCAFFOLD" \
  --out "$out" >/dev/null

git -C "$out" init -q
git -C "$out" config user.email generated-scaffold@example.invalid
git -C "$out" config user.name "Generated Scaffold Test"
git -C "$out" add .
git -C "$out" commit -qm 'chore: init generated workbench'

for path in \
  .codebases/example/README.md \
  .worktrees/example/HEAD \
  task/codebases/example/README.md \
  .claude/scheduled_tasks.lock
do
  mkdir -p "$out/$(dirname "$path")"
  printf 'generated infrastructure\n' > "$out/$path"
done

status="$(git -C "$out" status --short)"
[ -z "$status" ] || {
  echo "FAIL: generated infrastructure is visible to git status:" >&2
  echo "$status" >&2
  exit 1
}

for path in \
  .codebases/example/README.md \
  .worktrees/example/HEAD \
  task/codebases/example/README.md \
  .claude/scheduled_tasks.lock
do
  git -C "$out" check-ignore -q "$path" || {
    echo "FAIL: expected ignored path: $path" >&2
    exit 1
  }
done

for path in docs/log.md task/log.md; do
  attr="$(git -C "$out" check-attr merge -- "$path")"
  case "$attr" in
    "$path: merge: union") ;;
    *)
      echo "FAIL: expected merge=union for $path, got: $attr" >&2
      exit 1
      ;;
  esac
done

echo "OK generated scaffold hygiene"
