#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wbk-marketplace-parity.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TMP/tests" "$TMP/.claude-plugin" "$TMP/.agents/plugins"
cp "$ROOT/tests/check-marketplace-parity.sh" "$TMP/tests/"
cp "$ROOT/.claude-plugin/marketplace.json" "$TMP/.claude-plugin/"
cp "$ROOT/.agents/plugins/marketplace.json" "$TMP/.agents/plugins/"
cp -R "$ROOT/plugins" "$TMP/"

run_checker() {
  bash "$TMP/tests/check-marketplace-parity.sh"
}

run_checker >/dev/null || fail "the repository marketplace contract must pass"

python3 - "$TMP/.claude-plugin/marketplace.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text())
document["name"] = "wrong-marketplace"
path.write_text(json.dumps(document))
PY
if run_checker >/dev/null 2>&1; then
  fail "a wrong marketplace identity must fail"
fi
cp "$ROOT/.claude-plugin/marketplace.json" "$TMP/.claude-plugin/"

python3 - "$TMP/plugins/toolbox/.codex-plugin/plugin.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text())
document["version"] = "0.1.2"
path.write_text(json.dumps(document))
PY
if run_checker >/dev/null 2>&1; then
  fail "manifest version drift must fail"
fi
cp "$ROOT/plugins/toolbox/.codex-plugin/plugin.json" \
  "$TMP/plugins/toolbox/.codex-plugin/"

python3 - "$TMP/plugins/toolbox/.codex-plugin/plugin.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text())
document["version"] = "01.2.3"
path.write_text(json.dumps(document))
PY
if run_checker >/dev/null 2>&1; then
  fail "an invalid SemVer manifest version must fail"
fi
cp "$ROOT/plugins/toolbox/.codex-plugin/plugin.json" \
  "$TMP/plugins/toolbox/.codex-plugin/"

rm "$TMP/plugins/toolbox/.codex-plugin/plugin.json"
if run_checker >/dev/null 2>&1; then
  fail "a missing manifest must fail"
fi
cp "$ROOT/plugins/toolbox/.codex-plugin/plugin.json" \
  "$TMP/plugins/toolbox/.codex-plugin/"

python3 - "$TMP/plugins/toolbox/.codex-plugin/plugin.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text())
del document["interface"]
path.write_text(json.dumps(document))
PY
if run_checker >/dev/null 2>&1; then
  fail "a Codex manifest without interface metadata must fail"
fi

grep -Fq 'tests/check-marketplace-parity.sh' "$ROOT/tests/run.sh" \
  || fail "the root test runner must run the marketplace parity contract"
grep -Fq 'bash tests/run.sh' "$ROOT/.github/workflows/ci.yml" \
  || fail "CI must use the root test runner"
grep -Fq 'bash tests/run.sh' "$ROOT/scripts/release.sh" \
  || fail "release preparation must use the root test runner"

echo "PASS marketplace parity guard tests"
