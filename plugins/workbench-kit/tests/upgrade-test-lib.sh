#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPGRADE_FIXTURES="$KIT_ROOT/tests/fixtures/upgrade"

fixture_workspace() {
  local name="$1" target="$2" path link

  mkdir -p "$target"
  cp -R "$UPGRADE_FIXTURES/$name/root/." "$target"
  if [ -f "$UPGRADE_FIXTURES/$name/links.tsv" ]; then
    while IFS=$'\t' read -r path link; do
      [ -n "$path" ] || continue
      mkdir -p "$target/$(dirname "$path")"
      ln -s "$link" "$target/$path"
    done < "$UPGRADE_FIXTURES/$name/links.tsv"
  fi

  git -C "$target" init -q
  git -C "$target" config user.name Fixture
  git -C "$target" config user.email fixture@example.invalid
  git -C "$target" add -A
  git -C "$target" commit -qm "fixture: $name"
  git -C "$target" switch -qc task/27-upgrade
}
