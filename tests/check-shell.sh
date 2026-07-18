#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v shellcheck >/dev/null 2>&1 || {
  echo "FAIL: shellcheck is required" >&2
  exit 1
}

files=()
while IFS= read -r -d '' path; do
  if [[ "$path" == *.sh ]]; then
    files+=("$path")
    continue
  fi
  [ -x "$path" ] || continue
  first_line=""
  IFS= read -r first_line < "$path" || true
  case "$first_line" in
    '#!'*bash*|'#!/bin/sh'|'#!/usr/bin/sh'|'#!/usr/bin/env sh') files+=("$path") ;;
  esac
done < <(find . -path ./.git -prune -o -type f -print0)

[ "${#files[@]}" -gt 0 ] || {
  echo "FAIL: no shell entrypoints found" >&2
  exit 1
}

shellcheck -S error "${files[@]}"
echo "OK ShellCheck: ${#files[@]} shell entrypoints"
