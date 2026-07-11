#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for check in \
  tests/check-json-manifests.sh \
  tests/check-shell.sh \
  tests/check-compose-smoke.sh \
  tests/check-plugin-suite.sh; do
  grep -Fq "$check" "$ROOT/tests/run.sh" \
    || fail "the root test runner must invoke $check"
done

grep -Fq 'tests/plugin-suite.tsv' "$ROOT/tests/run.sh" \
  || fail "the root test runner must consume the plugin test inventory"
grep -Fq 'bash tests/run.sh' "$ROOT/.github/workflows/ci.yml" \
  || fail "CI must use the root test runner"
grep -Fq 'bash tests/run.sh' "$ROOT/scripts/release.sh" \
  || fail "release preparation must use the root test runner"

echo "PASS repository gate wiring"
