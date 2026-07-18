#!/usr/bin/env bash
set -euo pipefail

CI_FILE="${1:-}"
RELEASE_FILE="${2:-}"
[ -f "$CI_FILE" ] && [ -f "$RELEASE_FILE" ] || {
  echo "usage: check-release-workflow.sh <ci.yml> <release.yml>" >&2
  exit 2
}

python3 - "$CI_FILE" "$RELEASE_FILE" <<'PY'
import pathlib
import sys

ci = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
release = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")

python_action = "actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065"
uv_action = "astral-sh/setup-uv@d0cc045d04ccac9d8b7881df0226f9e82c39688e"
for name, workflow in (("CI", ci), ("release", release)):
    required = (
        "- name: Set up Python",
        python_action,
        "python-version: '3.9.22'",
        "- name: Set up uv",
        uv_action,
        'version: "0.7.6"',
    )
    for item in required:
        if item not in workflow:
            raise SystemExit(f"{name} workflow is missing pinned runtime item: {item}")

if ci.index("- name: Set up uv") > ci.index("bash tests/run.sh"):
    raise SystemExit("CI provisions uv after the repository suite")

history_checkout = "- uses: actions/checkout@v4\n        with:\n          fetch-depth: 0"
checks_job = ci.split("\n  checks:\n", 1)[1].split("\n  upgrade-latest:\n", 1)[0]
if history_checkout not in checks_job:
    raise SystemExit("CI repository suite does not fetch receipt-bound Git history")
if history_checkout not in release:
    raise SystemExit("release preflight does not fetch receipt-bound Git history")

preflight = 'bash scripts/release-preflight.sh "${{ steps.rel.outputs.version }}"'
publish = 'gh release create "v${{ steps.rel.outputs.version }}"'
tag_check = 'git rev-parse "refs/tags/v$V^{commit}"'
release_check = (
    'gh release view "v$V" --json '
    'tagName,targetCommitish,isDraft,isPrerelease,body'
)
notes_check = 'pathlib.Path("notes.md").read_text'
for item in (preflight, publish, tag_check, release_check, notes_check):
    if item not in release:
        raise SystemExit(f"release workflow is missing gate item: {item}")
if not (
    release.index(preflight)
    < release.index(publish)
    < release.rindex(tag_check)
    < release.rindex(release_check)
    < release.rindex(notes_check)
):
    raise SystemExit("release workflow gate order is invalid")
PY

echo "OK release workflow gate"
