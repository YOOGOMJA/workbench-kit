#!/usr/bin/env bash
# Sandbox for the bootstrap demo: an empty working dir where the agent runs the
# workbench-kit interview + generate skills to CREATE a fresh workbench at a local path.
set -euo pipefail
DEMO=/tmp/wbk-demo
WORK="$DEMO/bootstrap"     # where the agent works (interview drafts .persona/ here)
TARGET="$DEMO/my-wb"       # the new workbench it generates

rm -rf "$WORK" "$TARGET"
mkdir -p "$WORK/.claude"
printf '{\n  "enabledPlugins": {\n    "workbench-kit@workbench-kit": true,\n    "workbench@workbench-kit": true\n  }\n}\n' > "$WORK/.claude/settings.json"
echo "ready: $WORK (target $TARGET)"
