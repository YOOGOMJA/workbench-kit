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

run "plugin version sync" bash scripts/check-version-sync.sh

root_tests=(
  tests/check-skill-frontmatter.sh
  tests/check-install-model.sh
  tests/check-codebases-yaml.sh
  tests/check-changelog-section-guard.sh
  tests/check-generated-scaffold-hygiene.sh
  tests/check-marketplace-parity.sh
  tests/check-marketplace-parity-guard.sh
)

plugin_tests=(
  plugins/toolbox/tests/delivery-skills.sh
  plugins/toolbox/tests/discovery-design-skills.sh
  plugins/toolbox/tests/packaging.sh
  plugins/toolbox/tests/policy-bridge.sh
  plugins/toolbox/tests/portfolio-state.sh
  plugins/toolbox/tests/primary-workflow-skills.sh
  plugins/toolbox/tests/product-start-skill.sh
  plugins/toolbox/tests/product-state.sh
  plugins/toolbox/tests/product-workflows.sh
  plugins/toolbox/tests/run-planning.sh
  plugins/toolbox/tests/state-contracts.sh
  plugins/toolbox/tests/workbench-contract.sh
  plugins/workbench/tests/task-lifecycle.sh
)

for test_path in "${root_tests[@]}" "${plugin_tests[@]}"; do
  run "$test_path" bash "$test_path"
done

printf '\nPASS repository test suite\n'
