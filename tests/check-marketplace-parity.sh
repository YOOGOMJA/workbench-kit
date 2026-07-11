#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import json
import pathlib
import re
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


def load_json(relative):
    path = root / relative
    try:
        text = path.read_bytes().decode("utf-8", errors="strict")
        return json.loads(
            text,
            object_pairs_hook=reject_pairs,
            parse_constant=reject_constant,
        )
    except (OSError, UnicodeError, ValueError) as exc:
        raise SystemExit(f"invalid JSON at {relative}: {exc}") from exc


def entries_by_name(document, relative):
    plugins = document.get("plugins")
    if not isinstance(plugins, list):
        raise SystemExit(f"{relative}: plugins must be an array")
    result = {}
    for entry in plugins:
        if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
            raise SystemExit(f"{relative}: every plugin must have a string name")
        name = entry["name"]
        if name in result:
            raise SystemExit(f"{relative}: duplicate plugin name: {name}")
        result[name] = entry
    return result


expected = {"workbench", "workbench-kit", "toolbox"}
expected_marketplace = "workbench-kit"
semver = re.compile(
    r"^(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)"
    r"(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)
claude_path = ".claude-plugin/marketplace.json"
codex_path = ".agents/plugins/marketplace.json"
claude_document = load_json(claude_path)
codex_document = load_json(codex_path)

for relative, document in ((claude_path, claude_document), (codex_path, codex_document)):
    if document.get("name") != expected_marketplace:
        raise SystemExit(f"{relative}: marketplace name must be {expected_marketplace}")

claude = entries_by_name(claude_document, claude_path)
codex = entries_by_name(codex_document, codex_path)

for relative, actual in ((claude_path, set(claude)), (codex_path, set(codex))):
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise SystemExit(f"{relative}: plugin parity mismatch; missing={missing}, extra={extra}")

versions = {}
for name in sorted(expected):
    plugin_root = f"./plugins/{name}"
    if claude[name].get("source") != plugin_root:
        raise SystemExit(f"{claude_path}: {name} source must be {plugin_root}")
    expected_codex_source = {"source": "local", "path": plugin_root}
    if codex[name].get("source") != expected_codex_source:
        raise SystemExit(f"{codex_path}: {name} source must be {expected_codex_source}")
    if codex[name].get("policy") != {"installation": "AVAILABLE"}:
        raise SystemExit(f"{codex_path}: {name} must be AVAILABLE")
    for tool in (".claude-plugin", ".codex-plugin"):
        manifest_path = pathlib.Path("plugins") / name / tool / "plugin.json"
        manifest = load_json(str(manifest_path))
        if manifest.get("name") != name:
            raise SystemExit(f"{manifest_path}: manifest name must be {name}")
        version = manifest.get("version")
        if not isinstance(version, str) or semver.fullmatch(version) is None:
            raise SystemExit(f"{manifest_path}: version must be valid SemVer")
        versions[str(manifest_path)] = version

unique_versions = set(versions.values())
if len(versions) != 6 or len(unique_versions) != 1:
    details = ", ".join(f"{path}={version}" for path, version in sorted(versions.items()))
    raise SystemExit(f"plugin manifest versions must match across all six files: {details}")

if not claude["toolbox"].get("description", "").startswith("Optional"):
    raise SystemExit(f"{claude_path}: toolbox must be described as optional")
if not codex["toolbox"].get("description", "").startswith("Optional"):
    raise SystemExit(f"{codex_path}: toolbox must be described as optional")

print(f"OK marketplace parity: 3 plugins, 6 manifests at {unique_versions.pop()}")
PY
