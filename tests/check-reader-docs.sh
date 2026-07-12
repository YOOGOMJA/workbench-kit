#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for readme in README.md README.ko.md; do
  for selector in \
    workbench@workbench-kit \
    workbench-kit@workbench-kit \
    toolbox@workbench-kit; do
    grep -Fq "codex plugin add $selector" "$ROOT/$readme" \
      || fail "$readme must use namespaced Codex selector $selector"
  done
  for skill in \
    '$generate-workbench' \
    '$task-start' \
    '$product-start'; do
    grep -Fq "$skill" "$ROOT/$readme" \
      || fail "$readme must explain the Codex $skill entrypoint"
  done
done

for expectation in \
  'three plugins' \
  '6 manifests' \
  'plugins/toolbox/' \
  'bash tests/run.sh'; do
  grep -Fq "$expectation" "$ROOT/AGENTS.md" \
    || fail "AGENTS.md is missing current fact: $expectation"
done

for expectation in '$task-start' '$generate-workbench' '$product-start'; do
  grep -Fq "$expectation" "$ROOT/.agents/plugins/marketplace.json" \
    || fail "Codex marketplace must advertise $expectation"
done
if grep -Fq '@workbench:' "$ROOT/.agents/plugins/marketplace.json" \
  || grep -Fq '@workbench-kit:' "$ROOT/.agents/plugins/marketplace.json" \
  || grep -Fq '@toolbox:' "$ROOT/.agents/plugins/marketplace.json"; then
  fail "Codex marketplace must not advertise Claude-style plugin skill syntax"
fi

grep -Fq 'optional toolbox' "$ROOT/.claude-plugin/marketplace.json" \
  || fail "Claude marketplace summary must include optional toolbox"
grep -Fq 'three plugins' "$ROOT/CHANGELOG.md" \
  || fail "CHANGELOG introduction must describe all three plugins"
grep -Fq 'Three-plugin marketplace integration' "$ROOT/CHANGELOG.md" \
  || fail "CHANGELOG must record toolbox marketplace integration"
if grep -Fq 'Marketplace registration remains follow-up work' "$ROOT/CHANGELOG.md"; then
  fail "CHANGELOG must not call completed marketplace registration follow-up work"
fi

grep -Fq 'auto-tags' "$ROOT/scripts/bump-version.sh" \
  || fail "bump-version guidance must point to automatic tagging"
if grep -Fq 'land on `main` → bump version → tag' "$ROOT/RELEASING.md"; then
  fail "RELEASING must not instruct a post-main manual version bump/tag"
fi
if grep -Fq 'land on `main`, bump the version' "$ROOT/CONTRIBUTING.md"; then
  fail "CONTRIBUTING must not instruct a post-main version bump"
fi

GENERATE_SKILL="$ROOT/plugins/workbench-kit/skills/generate-workbench/SKILL.md"
CORE="$ROOT/plugins/workbench-kit/scaffold/AGENTS.core.md"
grep -Fq 'CLAUDE.md real file' "$GENERATE_SKILL" \
  || fail "generate-workbench must describe the real CLAUDE.md output"
grep -Fq '$task-start' "$GENERATE_SKILL" \
  || fail "generate-workbench must hand Codex users to $task-start"
for entrypoint in '/workbench:task-start' '$task-start'; do
  grep -Fq "$entrypoint" "$CORE" \
    || fail "generated core must explain entrypoint $entrypoint"
done

echo "PASS reader documentation contracts"
