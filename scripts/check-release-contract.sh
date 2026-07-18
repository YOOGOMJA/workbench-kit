#!/usr/bin/env bash
set -euo pipefail

CHANGELOG_ONLY=false
if [ "${1:-}" = "--changelog-only" ]; then
  CHANGELOG_ONLY=true
  shift
fi
VERSION="${1:-}"
NOTES_FILE="${2:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! printf '%s\n' "$VERSION" \
  | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)([-+][0-9A-Za-z.-]+)?$'; then
  echo "usage: check-release-contract.sh [--changelog-only] <version> [notes-file]" >&2
  exit 2
fi

cd "$ROOT"
if [ "$CHANGELOG_ONLY" = false ]; then
  bash scripts/check-version-sync.sh >/dev/null
fi

python3 - "$VERSION" "$NOTES_FILE" "$CHANGELOG_ONLY" <<'PY'
import datetime
import json
import pathlib
import re
import sys

version, notes_file, changelog_only_raw = sys.argv[1:]
changelog_only = changelog_only_raw == "true"
root = pathlib.Path.cwd()

if not changelog_only:
    manifest_paths = sorted(root.glob("plugins/*/.claude-plugin/plugin.json"))
    manifest_paths += sorted(root.glob("plugins/*/.codex-plugin/plugin.json"))
    if len(manifest_paths) != 6:
        raise SystemExit(f"release requires six plugin manifests, got {len(manifest_paths)}")
    versions = {
        json.loads(path.read_text(encoding="utf-8"))["version"]
        for path in manifest_paths
    }
    if versions != {version}:
        raise SystemExit(
            f"release version mismatch: expected {version}, got {sorted(versions)}"
        )

changelog = (root / "CHANGELOG.md").read_text(encoding="utf-8")
if len(re.findall(r"^## \[Unreleased\]\s*$", changelog, re.MULTILINE)) != 1:
    raise SystemExit("CHANGELOG must contain exactly one fresh [Unreleased] section")

pattern = re.compile(
    rf"^## \[{re.escape(version)}\] - (\d{{4}}-\d{{2}}-\d{{2}})\n"
    r"(?P<body>.*?)(?=^## \[|\Z)",
    re.MULTILINE | re.DOTALL,
)
matches = list(pattern.finditer(changelog))
if len(matches) != 1:
    raise SystemExit(f"CHANGELOG must contain one dated [{version}] section")
try:
    datetime.date.fromisoformat(matches[0].group(1))
except ValueError as error:
    raise SystemExit(f"CHANGELOG [{version}] has an invalid release date") from error
body = matches[0].group("body").strip()
if not body or not any(line.startswith("- ") for line in body.splitlines()):
    raise SystemExit(f"CHANGELOG [{version}] has no release notes")

if notes_file:
    pathlib.Path(notes_file).write_text(body + "\n", encoding="utf-8")
PY

echo "OK release contract: v$VERSION"
