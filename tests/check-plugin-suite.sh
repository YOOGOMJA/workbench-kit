#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${1:-$DEFAULT_ROOT}"

python3 - "$ROOT" <<'PY'
import pathlib
import sys


root = pathlib.Path(sys.argv[1]).resolve()
registry_path = root / "tests" / "plugin-suite.tsv"
try:
    lines = registry_path.read_bytes().decode("utf-8", errors="strict").splitlines()
except (OSError, UnicodeError) as exc:
    raise SystemExit(f"unable to read plugin suite inventory: {exc}") from exc

entries = []
seen = set()
for number, line in enumerate(lines, start=1):
    fields = line.split("\t")
    if len(fields) != 2 or fields[0] not in {"test", "helper"}:
        raise SystemExit(f"plugin-suite.tsv:{number}: expected <test|helper><TAB><path>")
    role, relative = fields
    path = pathlib.PurePosixPath(relative)
    if (
        path.is_absolute()
        or ".." in path.parts
        or len(path.parts) < 4
        or path.parts[0] != "plugins"
        or path.parts[2] != "tests"
        or path.suffix != ".sh"
    ):
        raise SystemExit(f"plugin-suite.tsv:{number}: invalid plugin test path: {relative}")
    if relative in seen:
        raise SystemExit(f"plugin-suite.tsv:{number}: duplicate path: {relative}")
    seen.add(relative)
    entries.append((role, relative))

registered = [relative for _, relative in entries]
if registered != sorted(registered):
    raise SystemExit("plugin-suite.tsv: paths must be sorted")

actual = sorted(
    path.relative_to(root).as_posix()
    for path in (root / "plugins").glob("*/tests/*.sh")
    if path.is_file()
)
missing = sorted(set(registered) - set(actual))
unlisted = sorted(set(actual) - set(registered))
if missing or unlisted:
    raise SystemExit(f"plugin suite inventory mismatch; missing={missing}, unlisted={unlisted}")

tests = sum(role == "test" for role, _ in entries)
helpers = sum(role == "helper" for role, _ in entries)
if tests == 0:
    raise SystemExit("plugin suite inventory has no runnable tests")
print(f"OK plugin suite inventory: {tests} tests, {helpers} helpers")
PY
