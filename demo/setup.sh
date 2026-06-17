#!/usr/bin/env bash
# Build a self-contained, OFFLINE workbench so the loop demo runs for real
# (real utils/task commands + output) without touching GitHub. Modeled on the
# engine lifecycle test's fake-gh harness.
set -euo pipefail

KIT="${KIT:-/tmp/wbk}"                      # workbench-kit checkout (for utils/task + templates)
DEMO="/tmp/wbk-demo"
REPO="$DEMO/repo"
ORIGIN="$DEMO/origin.git"
BIN="$DEMO/bin"
HOMEDIR="$DEMO/home"
COMMENTS="$DEMO/comments"

rm -rf "$REPO" "$ORIGIN" "$BIN" "$HOMEDIR" "$COMMENTS" "$DEMO/gh.log"
mkdir -p "$REPO" "$BIN" "$HOMEDIR" "$COMMENTS"

# --- fake gh: canned issue #42 + PR create ---
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$(pwd) $*" >> "${GH_LOG:-/dev/null}"
case "${1:-} ${2:-}" in
  "issue view")
    case "$*" in
      *"--json title"*) printf '%s\n' "Add retry with backoff to the sync client" ;;
      *"--json body"*)  printf '%s\n' "The sync client gives up on the first network blip." ;;
      *) printf '%s\n' "{}" ;;
    esac ;;
  "issue comment")
    issue="$3"; bf=""
    while [ "$#" -gt 0 ]; do case "$1" in --body-file) bf="$2"; shift 2;; *) shift;; esac; done
    mkdir -p "$GH_COMMENTS_DIR"; cat "$bf" >> "$GH_COMMENTS_DIR/$issue.comments"; printf '\n' >> "$GH_COMMENTS_DIR/$issue.comments"
    printf 'https://github.com/acme/app/issues/%s#issuecomment-1\n' "$issue" ;;
  "pr list") printf '\n' ;;
  "pr create") printf 'https://github.com/acme/app/pull/128\n' ;;
  *) printf '%s\n' "{}" ;;
esac
EOF
chmod +x "$BIN/gh"

# --- the workbench repo ---
git init -q --bare "$ORIGIN"
git init -q -b main "$REPO"
mkdir -p "$REPO/utils" "$REPO/templates"
cp "$KIT/plugins/workbench/utils/task" "$REPO/utils/task"; chmod +x "$REPO/utils/task"
cp "$KIT/plugins/workbench-kit/scaffold/templates/task-AGENTS.md" "$REPO/templates/task-AGENTS.md"
git -C "$REPO" config user.name "you"
git -C "$REPO" config user.email "you@acme.dev"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "init"
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q -u origin main

# project-scoped: enable the workbench engine plugin for a claude session here
mkdir -p "$REPO/.claude"
printf '{\n  "enabledPlugins": { "workbench@workbench-kit": true }\n}\n' > "$REPO/.claude/settings.json"

echo "ready: $REPO"
