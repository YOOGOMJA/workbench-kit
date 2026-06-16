#!/usr/bin/env bash
# check-skill-frontmatter.sh — kit-wide lint for SKILL.md YAML frontmatter.
#
# Catches the failure class that bit us once: an unquoted inline scalar whose value
# contains a colon+space (e.g. `description: ... 트리거 의도: ...`) or a leading quote.
# YAML reads that as a nested mapping and silently drops the skill's metadata at
# runtime. Such a value must be a block scalar (`>-` / `|`) or be quoted.
#
# Pure python3, no third-party deps (PyYAML isn't guaranteed in CI). Authoritative
# parsing is `claude plugin validate`; this is the dependency-light gate for the bug
# class so it can't recur.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import sys, pathlib, re

root = pathlib.Path(sys.argv[1])
skills = sorted(root.glob("plugins/*/skills/*/SKILL.md"))
problems = []

def frontmatter_lines(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    fm = []
    for ln in lines[1:]:
        if ln.strip() == "---":
            return fm
        fm.append(ln)
    return None  # unterminated

def check(path, fm):
    issues = []
    keys = set()
    i = 0
    while i < len(fm):
        ln = fm[i]
        m = re.match(r"^([A-Za-z0-9_-]+):(.*)$", ln)
        if not m:
            i += 1
            continue
        key, rest = m.group(1), m.group(2).strip()
        keys.add(key)
        if rest in (">", ">-", "|", "|-", "|+", ">+"):
            # block scalar: following indented lines are literal — safe.
            has_body = i + 1 < len(fm) and (fm[i+1].startswith("  ") or fm[i+1].strip() == "")
            if not has_body:
                issues.append(f"{key}: block scalar with no body")
        elif rest == "":
            pass  # empty / nested; skip (our skills don't use these for name/desc)
        elif rest[0] in "\"'":
            pass  # quoted scalar — safe
        else:
            # plain inline scalar: a colon+space (or trailing colon) makes YAML read a
            # mapping; a leading quote also breaks. This is the bug class.
            if re.search(r":(\s|$)", rest):
                issues.append(f"{key}: plain scalar contains ': ' (use a `>-` block scalar or quote it)")
        i += 1
    for required in ("name", "description"):
        if required not in keys:
            issues.append(f"missing required field: {required}")
    return issues

for sk in skills:
    fm = frontmatter_lines(sk.read_text())
    rel = sk.relative_to(root)
    if fm is None:
        problems.append((rel, ["no parseable frontmatter (--- … ---)"]))
        continue
    issues = check(sk, fm)
    if issues:
        problems.append((rel, issues))

print(f"checked {len(skills)} SKILL.md frontmatter")
if problems:
    print(f"\n✘ {len(problems)} file(s) with issues:", file=sys.stderr)
    for rel, issues in problems:
        for it in issues:
            print(f"  {rel}: {it}", file=sys.stderr)
    sys.exit(1)
print("✔ all frontmatter OK")
PY
