#!/usr/bin/env bash
set -euo pipefail

# Regression test for scripts/check-changelog-section.sh: released CHANGELOG
# sections are frozen; adding entries to them fails, while [Unreleased] and a
# brand-new (release-cut) dated section pass.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-changelog-section.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wbk-clsection.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

repo="$TMP/repo"
git init -q "$repo"
git -C "$repo" config user.email t@e.invalid
git -C "$repo" config user.name t

cat > "$repo/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

_Nothing yet._

## [0.1.0] - 2026-06-17

### Added

- **Thing one** that shipped in 0.1.0.
EOF
git -C "$repo" add CHANGELOG.md
git -C "$repo" commit -q -m base
base="$(git -C "$repo" rev-parse HEAD)"
cp "$GUARD" "$repo/guard.sh"

run() { ( cd "$repo" && bash guard.sh "$base" ) 2>&1; }

# 1) adding under [Unreleased] → pass
cat > "$repo/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

### Fixed

- **A new fix** under Unreleased.

## [0.1.0] - 2026-06-17

### Added

- **Thing one** that shipped in 0.1.0.
EOF
run >/dev/null || fail "adding under [Unreleased] should pass"

# 2) adding under the released [0.1.0] → fail (the #16 incident)
cat > "$repo/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

_Nothing yet._

## [0.1.0] - 2026-06-17

### Added

- **Thing one** that shipped in 0.1.0.
- **A sneaky late addition** to a released section.
EOF
if run >/dev/null; then fail "adding under a released section must fail"; fi
out="$(run || true)"
grep -Fq "already-released section" <<<"$out" || fail "missing explanatory error — got: $out"

# 3) release-cut: a brand-new dated section with bullets (not in base) → pass
cat > "$repo/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

_Nothing yet._

## [0.2.0] - 2026-06-18

### Fixed

- **Promoted from Unreleased** at release time.

## [0.1.0] - 2026-06-17

### Added

- **Thing one** that shipped in 0.1.0.
EOF
run >/dev/null || fail "a brand-new dated section (release cut) should pass"

# 4) removing a line from a released section (correction) → pass
cat > "$repo/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

_Nothing yet._

## [0.1.0] - 2026-06-17

### Added
EOF
run >/dev/null || fail "removing from a released section should pass"

echo "PASS changelog-section guard tests"
