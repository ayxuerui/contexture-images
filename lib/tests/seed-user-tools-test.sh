#!/bin/sh
# Regression tests for 03-seed-user-tools, the boot hook that puts claude and agy in the agent's
# own prefix.
#
# Every property here fails silently in production, which is why it is worth a test:
#
#   1. Steady state is free. A boot that re-copies ~450 MB every time looks like a slow start,
#      not a bug, and runs the volume out of space on the day it matters.
#   2. An image bump must reach an UNTOUCHED copy, or seeding freezes every deployed store on
#      whatever version it first booted -- the failure seeding must not introduce.
#   3. An image bump must NEVER clobber what the agent changed or installed itself: that is
#      silently reverting someone's `claude update`.
#   4. It must never exit non-zero. s6-overlay stops the container on a failing cont-init.d
#      script, so a full or read-only volume would otherwise be a dead container.
#
# Needs sh, cp -p, stat, mv -T (GNU). Must NOT run as root. No network, no image.
#
#   sh lib/tests/seed-user-tools-test.sh
set -u

SCRIPT_DIR=$(dirname "$0")
HOOK="$SCRIPT_DIR/../../harnesses/hermes/cont-init.d/03-seed-user-tools"
[ -f "$HOOK" ] || { echo "cannot find $HOOK"; exit 1; }
# As root the hook drops to the hermes user, which cannot write this test's temp dirs -- and
# mode-bit checks below prove nothing for root. The privilege drop is covered by the image build.
[ "$(id -u)" != 0 ] || { echo "run this as a non-root user: sh $0"; exit 1; }

WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then echo "  PASS: $1"; PASS=$((PASS + 1))
  else echo "  FAIL: $1 (want '$3', got '$2')"; FAIL=$((FAIL + 1)); fi
}

SRC="$WORK/toolchain"
DEST="$WORK/home"

# Build a fake image: claude version $1 (launcher -> versions/$1) and an agy whose mtime is $2.
make_image() {
  rm -rf "$SRC"
  mkdir -p "$SRC/.local/bin" "$SRC/.local/share/claude/versions"
  echo "claude $1" > "$SRC/.local/share/claude/versions/$1"
  chmod +x "$SRC/.local/share/claude/versions/$1"
  ln -s "$SRC/.local/share/claude/versions/$1" "$SRC/.local/bin/claude"
  echo "agy $2" > "$SRC/.local/bin/agy"
  chmod +x "$SRC/.local/bin/agy"
  touch -d "@$2" "$SRC/.local/bin/agy"
}
seed() { SEED_SRC_HOME="$SRC" SEED_DEST_HOME="$DEST" sh "$HOOK" 2>&1; }
claude_version() { basename "$(readlink "$DEST/.local/bin/claude" 2>/dev/null)" 2>/dev/null; }
agy_mtime() { stat -c %Y "$DEST/.local/bin/agy" 2>/dev/null; }

echo "== first boot seeds both tools =="
make_image 1.0.0 1000000000
out=$(seed); rc=$?
check "exit status"            "$rc" "0"
check "claude launcher target" "$(claude_version)" "1.0.0"
check "claude version file"    "$(cat "$DEST/.local/share/claude/versions/1.0.0")" "claude 1.0.0"
check "agy copied"             "$(cat "$DEST/.local/bin/agy")" "agy 1000000000"
check "agy is executable"      "$(test -x "$DEST/.local/bin/agy" && echo yes)" "yes"
check "agy keeps the image mtime (the identity the marker relies on)" "$(agy_mtime)" "1000000000"
check "claude launcher resolves to an executable" "$(test -x "$DEST/.local/bin/claude" && echo yes)" "yes"
check "no temp files left"     "$(ls -A "$DEST/.local/bin" "$DEST/.local/share/claude/versions" | grep -c '\.seed')" "0"

echo "== a second boot does nothing =="
touch -d '@1100000000' "$DEST/.local/share/claude/versions/1.0.0"
out=$(seed)
check "no seed message"        "$(echo "$out" | grep -c 'seeded')" "0"
check "claude copy untouched"  "$(stat -c %Y "$DEST/.local/share/claude/versions/1.0.0")" "1100000000"

echo "== an image bump replaces an UNTOUCHED copy and prunes the old version =="
make_image 2.0.0 2000000000
out=$(seed)
check "claude follows the image" "$(claude_version)" "2.0.0"
check "old claude version pruned" "$(test -e "$DEST/.local/share/claude/versions/1.0.0" && echo kept || echo gone)" "gone"
check "agy follows the image"  "$(agy_mtime)" "2000000000"
check "agy content"            "$(cat "$DEST/.local/bin/agy")" "agy 2000000000"

echo "== an image bump leaves what the agent changed =="
# `claude update` adds a version and repoints the launcher; an agy upgrade replaces the file.
echo "claude 9.0.0" > "$DEST/.local/share/claude/versions/9.0.0"
ln -sfn "$DEST/.local/share/claude/versions/9.0.0" "$DEST/.local/bin/claude"
echo "agy agent-upgraded" > "$DEST/.local/bin/agy"
make_image 3.0.0 3000000000
out=$(seed)
check "agent's claude kept"    "$(claude_version)" "9.0.0"
check "agent's agy kept"       "$(cat "$DEST/.local/bin/agy")" "agy agent-upgraded"
check "says so"                "$(echo "$out" | grep -c 'changed by the agent')" "2"
check "image version not copied in" "$(test -e "$DEST/.local/share/claude/versions/3.0.0" && echo copied || echo no)" "no"

echo "== an install that predates seeding is never claimed =="
rm -rf "$DEST"; mkdir -p "$DEST/.local/bin"
echo "hand-installed" > "$DEST/.local/bin/agy"
echo "hand-installed" > "$DEST/.local/bin/claude"     # a real file, not a launcher symlink
out=$(seed)
check "agy kept"               "$(cat "$DEST/.local/bin/agy")" "hand-installed"
check "claude kept"            "$(cat "$DEST/.local/bin/claude")" "hand-installed"
check "no marker written"      "$(ls "$DEST/.local/share/contexture-seed" 2>/dev/null | grep -c -v '^lock$')" "0"

echo "== deleting an override goes back to the image's copy =="
rm -rf "$DEST"
seed >/dev/null
rm -f "$DEST/.local/bin/agy" "$DEST/.local/bin/claude"
seed >/dev/null
check "claude re-seeded"       "$(claude_version)" "3.0.0"
check "agy re-seeded"          "$(cat "$DEST/.local/bin/agy")" "agy 3000000000"

echo "== the off switch does nothing =="
rm -rf "$DEST"
out=$(CONTEXTURE_SEED_USER_TOOLS=0 seed)
check "nothing created"        "$(test -e "$DEST" && echo created || echo none)" "none"

echo "== a tool the image does not ship is skipped, not fatal =="
rm -rf "$DEST" "$SRC"; mkdir -p "$SRC"
seed >/dev/null; rc=$?
check "exit status"            "$rc" "0"

echo "== a read-only destination never fails the boot =="
make_image 1.0.0 1000000000
rm -rf "$DEST"; mkdir -p "$DEST"; chmod a-w "$DEST"
out=$(seed); rc=$?
chmod u+w "$DEST"
check "exit status"            "$rc" "0"
check "says it skipped"        "$(echo "$out" | grep -c 'skipping')" "1"

echo "== a failed copy cleans up after itself =="
make_image 1.0.0 1000000000
rm -rf "$DEST"; mkdir -p "$DEST/.local/bin" "$DEST/.local/share/claude/versions"
chmod a-w "$DEST/.local/bin"
out=$(seed); rc=$?
chmod u+w "$DEST/.local/bin"
check "exit status"            "$rc" "0"
check "no partial files"       "$(find "$DEST" -name '.*.seed' -o -name '.seed-*' | wc -l | tr -d ' ')" "0"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
