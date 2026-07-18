#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/check-release-workflow.sh"
CONTRACT="$ROOT/scripts/check-release-contract.sh"
PREFLIGHT="$ROOT/scripts/release-preflight.sh"
RELEASE_PREP="$ROOT/scripts/release.sh"
RELEASING="$ROOT/RELEASING.md"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/workbench-release-gate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$CHECKER" ] || fail "missing executable release workflow checker"
[ -x "$CONTRACT" ] || fail "missing executable release contract checker"
[ -x "$PREFLIGHT" ] || fail "missing executable release preflight"
[ -x "$RELEASE_PREP" ] || fail "missing executable release prep"

bash "$CHECKER" "$ROOT/.github/workflows/ci.yml" \
  "$ROOT/.github/workflows/release.yml"
VERSION="$(python3 - "$ROOT/plugins/workbench/.claude-plugin/plugin.json" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])
PY
)"
bash "$CONTRACT" "$VERSION" >/dev/null
bash "$CONTRACT" --changelog-only "$VERSION" >/dev/null
if bash "$CONTRACT" --changelog-only 9.9.9 >/dev/null 2>&1; then
  fail "changelog-only release contract accepted a missing release section"
fi

python3 - "$RELEASE_PREP" "$RELEASING" "$ROOT/.github/workflows/ci.yml" <<'PY'
import pathlib
import sys

release = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
steps = [
    'bash scripts/check-release-contract.sh --changelog-only "$V"',
    'bash scripts/bump-version.sh "$V"',
    'bash tests/run.sh',
]
positions = [release.find(step) for step in steps]
if -1 in positions or positions != sorted(positions):
    raise SystemExit(f"release prep order is not changelog -> bump -> tests: {positions}")

guide = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
cut = guide.split("## Cut a release", 1)[1].split("\n## ", 1)[0]
promote = cut.find("Promote `## [Unreleased]`")
prepare = cut.find("`scripts/release.sh X.Y.Z`")
if promote < 0 or prepare < 0 or promote >= prepare:
    raise SystemExit("RELEASING must promote CHANGELOG before running release.sh")

ci = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
checks = ci.split("\n  checks:\n", 1)[1].split("\n  upgrade-latest:\n", 1)[0]
checkout = "- uses: actions/checkout@v4\n        with:\n          fetch-depth: 0"
if checkout not in checks:
    raise SystemExit("repository suite checkout must fetch source-bound receipt history")
PY

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
python3 - "$TMP/ci.yml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
before, rest = text.split("\n  checks:\n", 1)
job, after = rest.split("\n  upgrade-latest:\n", 1)
job = job.replace("fetch-depth: 0", "fetch-depth: 1", 1)
path.write_text(before + "\n  checks:\n" + job + "\n  upgrade-latest:\n" + after)
PY
if bash "$CHECKER" "$TMP/ci.yml" "$TMP/release.yml" >/dev/null 2>&1; then
  fail "release checker accepted receipt verification without Git history"
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
