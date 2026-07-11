#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/check-release-workflow.sh"
CONTRACT="$ROOT/scripts/check-release-contract.sh"
PREFLIGHT="$ROOT/scripts/release-preflight.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/workbench-release-gate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$CHECKER" ] || fail "missing executable release workflow checker"
[ -x "$CONTRACT" ] || fail "missing executable release contract checker"
[ -x "$PREFLIGHT" ] || fail "missing executable release preflight"

bash "$CHECKER" "$ROOT/.github/workflows/ci.yml" \
  "$ROOT/.github/workflows/release.yml"
VERSION="$(python3 - "$ROOT/plugins/workbench/.claude-plugin/plugin.json" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])
PY
)"
bash "$CONTRACT" "$VERSION" >/dev/null

grep -Fq 'bash tests/run.sh' "$PREFLIGHT" \
  || fail "release preflight does not run the repository suite"
grep -Fq 'bash scripts/check-release-contract.sh' "$PREFLIGHT" \
  || fail "release preflight does not validate the release contract"

cp "$ROOT/.github/workflows/ci.yml" "$TMP/ci.yml"
cp "$ROOT/.github/workflows/release.yml" "$TMP/release.yml"

python3 - "$TMP/ci.yml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace("      - name: Set up uv\n", "      - name: Removed uv\n", 1)
path.write_text(text)
PY
if bash "$CHECKER" "$TMP/ci.yml" "$TMP/release.yml" >/dev/null 2>&1; then
  fail "release checker accepted CI without the pinned uv setup"
fi

cp "$ROOT/.github/workflows/ci.yml" "$TMP/ci.yml"
python3 - "$TMP/release.yml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace("bash scripts/release-preflight.sh", "bash scripts/removed-preflight.sh", 1)
path.write_text(text)
PY
if bash "$CHECKER" "$TMP/ci.yml" "$TMP/release.yml" >/dev/null 2>&1; then
  fail "release checker accepted publication without the full preflight"
fi

cp "$ROOT/.github/workflows/release.yml" "$TMP/release.yml"
python3 - "$TMP/release.yml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace("git rev-parse \"refs/tags/v$V^{commit}\"", "printf removed-tag-check")
path.write_text(text)
PY
if bash "$CHECKER" "$TMP/ci.yml" "$TMP/release.yml" >/dev/null 2>&1; then
  fail "release checker accepted publication without post-tag verification"
fi

cp "$ROOT/.github/workflows/release.yml" "$TMP/release.yml"
python3 - "$TMP/release.yml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "tagName,targetCommitish,isDraft,isPrerelease,body",
    "tagName,targetCommitish,isDraft,isPrerelease",
)
path.write_text(text)
PY
if bash "$CHECKER" "$TMP/ci.yml" "$TMP/release.yml" >/dev/null 2>&1; then
  fail "release checker accepted publication without release-note verification"
fi

echo "PASS release gate contract"
