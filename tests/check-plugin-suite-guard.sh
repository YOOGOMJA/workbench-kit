#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/tests/check-plugin-suite.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wbk-plugin-suite.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$CHECKER" ] || fail "missing executable plugin suite checker"
mkdir -p "$TMP/tests"
cp "$ROOT/tests/plugin-suite.tsv" "$TMP/tests/"

while IFS=$'\t' read -r role test_path; do
  [ -n "${role:-}" ] || continue
  mkdir -p "$TMP/$(dirname "$test_path")"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/$test_path"
  chmod +x "$TMP/$test_path"
done < "$TMP/tests/plugin-suite.tsv"

bash "$CHECKER" "$TMP" >/dev/null \
  || fail "the declared plugin suite inventory must pass"

mkdir -p "$TMP/plugins/unlisted/tests"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/plugins/unlisted/tests/new-test.sh"
chmod +x "$TMP/plugins/unlisted/tests/new-test.sh"
if bash "$CHECKER" "$TMP" >/dev/null 2>&1; then
  fail "an unlisted plugin test must fail inventory validation"
fi

rm "$TMP/plugins/unlisted/tests/new-test.sh"
registered="$(awk -F '\t' '$1 == "test" { print $2; exit }' "$TMP/tests/plugin-suite.tsv")"
rm "$TMP/$registered"
if bash "$CHECKER" "$TMP" >/dev/null 2>&1; then
  fail "a missing registered plugin test must fail inventory validation"
fi

echo "PASS plugin suite inventory guard"
