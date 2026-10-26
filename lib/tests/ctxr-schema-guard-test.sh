#!/bin/sh
# The ctxr recipe's schema guard: a ctxr may update in place only within the image's store schema.
set -eu
GUARD="$(cd "$(dirname "$0")/.." && pwd)/recipes/ctxr/schema-guard"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mk() { printf 'export const SCHEMA_FLOOR = 7;\nexport const SUPPORTED_SCHEMA_VERSION = %s;\n' "$2" > "$tmp/$1.js"; }
pass=0; fail=0
check() {  # expect NEW IMAGE description
  if "$GUARD" "$tmp/$2.js" "$tmp/$3.js" >"$tmp/out" 2>&1; then got=0; else got=1; fi
  if [ "$got" = "$1" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $4"; cat "$tmp/out"; fi
}
mk s10 10; mk s11 11; mk s9 9
check 0 s10 s10 "same schema installs"
check 0 s9 s10 "an older schema installs"
check 1 s11 s10 "a newer schema waits for the image"
check 1 missing s10 "an unreadable new ctxr is refused"
check 0 s11 missing "no image ctxr, nothing to hold back"
"$GUARD" "$tmp/s11.js" "$tmp/s10.js" 2>&1 | grep -q "waits for an image release" \
  && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: the refusal says why"; }
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
