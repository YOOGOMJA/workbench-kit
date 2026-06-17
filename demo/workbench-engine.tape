Output workbench-engine.gif

Set Shell bash
Set FontSize 14
Set Width 1280
Set Height 820
Set Padding 16
Set Theme "Catppuccin Mocha"
Set TypingSpeed 35ms

# ---- hidden: build offline workbench, launch claude, accept trust ----
Hide
Type "bash /tmp/wbk-demo/setup.sh >/dev/null 2>&1"
Enter
Type "cd /tmp/wbk-demo/repo"
Enter
Type "export PATH=/tmp/wbk-demo/bin:$PATH GH_LOG=/tmp/wbk-demo/gh.log GH_COMMENTS_DIR=/tmp/wbk-demo/comments GH_MERGED_HEAD='' GIT_PAGER=cat PAGER=cat GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null"
Enter
Type "clear"
Enter
Type "claude --dangerously-skip-permissions"
Enter
Sleep 7s
Enter
Sleep 4s
Show

# ---- the engine: drive the task lifecycle by its skill name ----
Sleep 800ms
Type "/workbench:task-start 42"
Sleep 700ms
Enter
Sleep 70s
