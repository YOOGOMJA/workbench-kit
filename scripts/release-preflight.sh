#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bash scripts/check-release-contract.sh "$VERSION"
bash tests/run.sh

echo "PASS release preflight: v$VERSION"
