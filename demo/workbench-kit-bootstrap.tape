Output workbench-kit-bootstrap.gif

Set Shell bash
Set FontSize 14
Set Width 1280
Set Height 820
Set Padding 16
Set Theme "Catppuccin Mocha"
Set TypingSpeed 30ms

# ---- hidden: empty work dir + bootstrap plugin enabled, launch claude, accept trust ----
Hide
Type "bash /tmp/wbk-demo/setup-bootstrap.sh >/dev/null 2>&1"
Enter
Type "cd /tmp/wbk-demo/bootstrap"
Enter
Type "export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_PAGER=cat PAGER=cat GIT_AUTHOR_NAME=you GIT_AUTHOR_EMAIL=you@acme.dev GIT_COMMITTER_NAME=you GIT_COMMITTER_EMAIL=you@acme.dev"
Enter
Type "clear"
Enter
Type "claude --dangerously-skip-permissions"
Enter
Sleep 7s
Enter
Sleep 4s
Show

# ---- bootstrap: interview for a persona, then generate the workbench ----
Sleep 800ms
Type "/workbench-kit:interview-for-personalizing"
Sleep 700ms
Enter
Sleep 32s
Type "Keep all defaults — language English. Target a fresh local repo at /tmp/wbk-demo/my-wb."
Sleep 700ms
Enter
Sleep 30s
Type "/workbench-kit:generate-workbench"
Sleep 700ms
Enter
Sleep 55s
