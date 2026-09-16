#!/bin/sh
# Regression tests for ctxr-provision's refresh of an ALREADY-PROVISIONED store.
#
# This path has failed twice in the same way: silently doing nothing to a store that had moved
# on. First by gating the whole script on the sentinel, so the pull was unreachable; then by
# running git as root against a checkout the script itself had chowned to the runtime uid, so
# every git call was refused. Both left a live store sitting merges behind main. It is the
# hardest kind of bug to notice from outside -- the command exits, the container comes up, and
# only the content is stale -- which is why it gets a test rather than a third careful comment.
#
# Runs against real repositories on disk, as root, with the store owned by another uid: the
# exact shape of the production failure. Needs root (for chown) and git; no network.
#
#   docker run --rm --user root -v "$PWD:/w" -w /w --entrypoint sh <image> \
#     lib/tests/provision-refresh-test.sh
set -u

SCRIPT_DIR=$(dirname "$0")
SOURCE="$SCRIPT_DIR/../provision-store.sh"
# A private work area, not fixed /tmp paths. Leftovers from an earlier run of this file once
# made it report another version's results, which is the one failure mode a test must not have.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
BLOCK="$WORK/refresh-block.sh"
STORE_UID=10000

[ -f "$SOURCE" ] || { echo "cannot find $SOURCE"; exit 1; }
{
  echo 'log() { echo "[ctxr-provision] $*"; }'
  sed -n '/^# >>> refresh-block/,/^# <<< refresh-block/p' "$SOURCE"
} > "$BLOCK"
# Extraction is by marker, so a refactor that drops the markers fails here loudly rather than
# silently testing an empty file and reporting green.
grep -q 'pull --ff-only' "$BLOCK" || {
  echo "FAIL: could not extract the refresh block from $SOURCE (markers missing or moved)"
  exit 1
}

git config --global user.email ctxr-test@example.invalid
git config --global user.name "ctxr test"

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then echo "  PASS: $1"; PASS=$((PASS + 1))
  else echo "  FAIL: $1 (want '$3', got '$2')"; FAIL=$((FAIL + 1)); fi
}

# A store checked out from an origin, then handed to the runtime uid as provisioning does.
setup() {
  rm -rf "$WORK/origin" "$WORK/teststore" "$WORK/other"
  git init -q --bare "$WORK/origin"
  (cd "$WORK/origin" && git symbolic-ref HEAD refs/heads/main)
  git clone -q "$WORK/origin" "$WORK/teststore" 2>/dev/null
  (cd "$WORK/teststore" && echo a > a.txt && git add a.txt && git commit -qm one \
    && git push -q origin HEAD:main 2>/dev/null && git branch -q --set-upstream-to=origin/main 2>/dev/null)
  chown -R "$STORE_UID:$STORE_UID" "$WORK/teststore"
}

# Move origin ahead, so "did it pull" is observable rather than assumed.
advance_origin() {
  rm -rf "$WORK/other"
  git clone -q "$WORK/origin" "$WORK/other"
  (cd "$WORK/other" && echo "$1" > "$1" && git add "$1" && git commit -qm "$1" && git push -q origin HEAD:main)
}

STORE="$WORK/teststore"
REPO_URL="$WORK/origin"
export STORE REPO_URL

echo "== a store owned by another uid still refreshes =="
setup; advance_origin b.txt
out=$(sh "$BLOCK" 2>&1); rc=$?
check "exits 0" "$rc" "0"
check "pulled the new commit" "$([ -f "$WORK/teststore"/b.txt ] && echo yes || echo no)" "yes"
check "logged the pull" "$(echo "$out" | grep -qc 'pulling (fast-forward only)' >/dev/null && echo yes || echo no)" "yes"

echo "== a dirty store is never clobbered =="
setup; advance_origin c.txt
echo "in-flight agent work" > "$WORK/teststore"/wip.txt
chown "$STORE_UID:$STORE_UID" "$WORK/teststore"/wip.txt
out=$(sh "$BLOCK" 2>&1); rc=$?
check "exits 0" "$rc" "0"
check "held the pull" "$([ -f "$WORK/teststore"/c.txt ] && echo pulled || echo held)" "held"
check "kept the in-flight file" "$([ -f "$WORK/teststore"/wip.txt ] && echo yes || echo no)" "yes"
check "said why" "$(echo "$out" | grep -q 'store is dirty' && echo yes || echo no)" "yes"

echo "== an unreadable store fails closed, never open =="
setup; advance_origin d.txt
mv "$WORK/teststore"/.git/HEAD "$WORK/teststore"/.git/HEAD.bak
out=$(sh "$BLOCK" 2>&1); rc=$?
check "exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "did not attempt the pull" "$(echo "$out" | grep -q 'pulling (fast-forward only)' && echo no || echo yes)" "yes"
check "named the reason" "$(echo "$out" | grep -q 'not safe to pull' && echo yes || echo no)" "yes"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
