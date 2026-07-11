#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import json
import pathlib
import sys


root = pathlib.Path(sys.argv[1])


def reject_pairs(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON member: {key}")
        value[key] = item
    return value


def reject_constant(value):
    raise ValueError(f"non-finite JSON constant: {value}")


paths = sorted(
    path
    for path in root.rglob("*.json")
    if path.name in {"plugin.json", "marketplace.json"} and ".git" not in path.parts
)
if not paths:
    raise SystemExit("no plugin or marketplace manifests found")

for path in paths:
    relative = path.relative_to(root)
    try:
        json.loads(
            path.read_bytes().decode("utf-8", errors="strict"),
            object_pairs_hook=reject_pairs,
            parse_constant=reject_constant,
        )
    except (OSError, UnicodeError, ValueError) as exc:
        raise SystemExit(f"invalid JSON at {relative}: {exc}") from exc

print(f"OK strict JSON: {len(paths)} marketplace/plugin manifests")
PY
