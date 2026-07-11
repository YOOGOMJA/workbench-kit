#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

run() {
  local label="$1"
  shift
  printf '\n== %s ==\n' "$label"
  "$@"
}

run "strict manifest JSON" bash tests/check-json-manifests.sh
run "shell entrypoints" bash tests/check-shell.sh
run "plugin version sync" bash scripts/check-version-sync.sh
run "plugin suite inventory" bash tests/check-plugin-suite.sh

root_tests=(
  tests/check-compose-smoke.sh
  tests/check-skill-frontmatter.sh
  tests/check-install-model.sh
  tests/check-codebases-yaml.sh
  tests/check-changelog-section-guard.sh
  tests/check-generated-scaffold-hygiene.sh
  tests/check-marketplace-parity.sh
  tests/check-marketplace-parity-guard.sh
  tests/check-plugin-suite-guard.sh
  tests/check-reader-docs.sh
  tests/check-release-gate.sh
  tests/check-repository-gate-guard.sh
)

for test_path in "${root_tests[@]}"; do
  run "$test_path" bash "$test_path"
done

while IFS=$'\t' read -r role test_path; do
  [ "$role" = "test" ] || continue
  run "$test_path" bash "$test_path"
done < tests/plugin-suite.tsv

printf '\nPASS repository test suite\n'
