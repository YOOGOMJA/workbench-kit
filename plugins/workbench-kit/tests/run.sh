#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v uv >/dev/null || {
  echo "uv is required for the workbench-kit upgrade suite" >&2
  exit 1
}

tests=(
  upgrade-classification.sh
  upgrade-classifier.sh
  upgrade-cli.sh
  upgrade-journal.sh
  upgrade-json-schemas.sh
  upgrade-packaging.sh
  upgrade-planner.sh
  upgrade-public-adapter.sh
  upgrade-rendering.sh
  upgrade-schemas.sh
)

for test_name in "${tests[@]}"; do
  echo "==> $test_name"
  bash "$ROOT/$test_name"
done

echo "PASS: governed workbench upgrade suite"
