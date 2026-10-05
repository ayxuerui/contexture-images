#!/bin/sh
# Regression tests for ctxr-update-store, the start-of-container store update.
#
# What it guards, each of which fails silently:
#
#   1. It never exits non-zero. It runs at boot; a failure here must cost a log line, not a
#      container that will not start.
#   2. The canonical clone is pulled only when clean. A dirty clone is in-flight agent work.
#   3. A due update is committed, pushed and opened as a PR -- and the canonical clone is
#      never written.
#   4. A branch left over from a MERGED update is recognized by patch, not by ancestry. These
#      stores squash-merge, so the branch is never an ancestor of main; an ancestry check would
#      leave the branch in place, and `ctxr update --worktree` would then no-op on every start
#      until the next release.
#   5. An unmerged branch is resumed, never duplicated: a commit whose push failed is pushed,
#      and a PR is opened only when the branch has none.
#
# `ctxr` and `gh` are stubs driven by a plan file, so this needs only sh, git and jq -- no image,
# no network, no root. The git it exercises is real: a bare origin, a clone, worktrees.
#
#   sh lib/tests/update-store-test.sh
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SOURCE="$SCRIPT_DIR/../update-store.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

[ -f "$SOURCE" ] || { echo "cannot find $SOURCE"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "needs jq"; exit 1; }
grep -q '^# >>> update-store' "$SOURCE" || { echo "FAIL: update-store markers missing from $SOURCE"; exit 1; }

export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
git config --global user.email ctxr-test@example.invalid
git config --global user.name "ctxr test"
git config --global init.defaultBranch main

BRANCH=session/ctxr-update-0.19.0
STUBS="$WORK/bin"
mkdir -p "$STUBS"

# ctxr stub. `--version` prints a fixed version. `update --worktree --json` consumes one line
# of $WORK/plan per call and acts it out against the real repository:
#   none      nothing due
#   change    create the update worktree on $BRANCH off origin/main and modify a file there
#   migrate   as change, but report a schema migration
#   existing  report the branch as already existing
#   fail      exit 2 with a refusal envelope
cat > "$STUBS/ctxr" <<'STUB'
#!/bin/sh
[ "$1" = --version ] && { echo 0.19.0; exit 0; }
echo "ctxr $*" >> "$WORK/calls"
step=$(head -1 "$WORK/plan"); sed -i 1d "$WORK/plan"
wt="$PWD/.worktrees/session-ctxr-update-0.19.0"
case "$step" in
  none) echo '{"data":{"changed":[],"worktree":null,"branch":"'"$BRANCH"'","existing":false}}' ;;
  change|migrate)
    git worktree add -q -b "$BRANCH" "$wt" origin/main
    echo "re-rendered" > "$wt/owned.md"
    m=''; [ "$step" = migrate ] && m=',"migrated":{"from":10,"to":11}'
    echo '{"data":{"changed":["owned.md"],"worktree":"'"$wt"'","branch":"'"$BRANCH"'","existing":false'"$m"'}}' ;;
  existing) echo '{"data":{"changed":[],"worktree":null,"branch":"'"$BRANCH"'","existing":true}}' ;;
  fail) echo '{"findings":[{"message":"schema_version (8) is older than supported"}]}'; exit 2 ;;
esac
STUB
# gh stub. `pr view` succeeds only when $WORK/pr-exists names the branch; `pr create` records
# its title and marks the PR as existing.
cat > "$STUBS/gh" <<'STUB'
#!/bin/sh
echo "gh $*" >> "$WORK/calls"
if [ "$1 $2" = "auth status" ]; then [ ! -f "$WORK/gh-unauthed" ]; exit $?; fi
if [ "$1 $2" = "pr view" ]; then grep -qx "$3" "$WORK/pr-exists" 2>/dev/null; exit $?; fi
if [ "$1 $2" = "pr create" ]; then
  while [ $# -gt 0 ]; do case "$1" in --head) echo "$2" >> "$WORK/pr-exists";; --title) echo "$2" > "$WORK/pr-title";; esac; shift; done
  echo "https://example.invalid/pull/1"; exit 0
fi
exit 0
STUB
chmod +x "$STUBS/ctxr" "$STUBS/gh"
export WORK BRANCH PATH="$STUBS:$PATH"

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then echo "  PASS: $1"; PASS=$((PASS + 1))
  else echo "  FAIL: $1 (want '$3', got '$2')"; FAIL=$((FAIL + 1)); fi
}

# A store cloned from a bare origin, with the worktrees directory ignored the way init ignores it.
setup() {
  [ -d "$WORK/store" ] && chmod -R u+w "$WORK/store"
  rm -rf "$WORK/origin" "$WORK/store" "$WORK/other" "$WORK/calls" "$WORK/pr-exists" "$WORK/pr-title" "$WORK/plan" "$WORK/gh-unauthed"
  git init -q --bare "$WORK/origin"
  git clone -q "$WORK/origin" "$WORK/store" 2>/dev/null
  (cd "$WORK/store" && printf 'schema_version: 10\ngit:\n  default_branch: main\n' > contexture.yaml \
    && printf '.worktrees/\n' > .gitignore && echo original > owned.md && git add -A && git commit -qm init \
    && git push -q origin HEAD:main && git remote set-head origin main >/dev/null)
  : > "$WORK/plan"
}
plan() { printf '%s\n' "$@" > "$WORK/plan"; }
run() { STORE_DIR="$WORK/store" sh "$SOURCE" > "$WORK/out" 2>&1; echo $?; }
calls() { _n=$(grep -c "$1" "$WORK/calls" 2>/dev/null); echo "${_n:-0}"; }

echo "== no store: nothing to do, exit 0 =="
check "exit status" "$(STORE_DIR="$WORK/nowhere" sh "$SOURCE" >/dev/null 2>&1; echo $?)" "0"

echo "== a store git refuses is named as such, not as absent =="
setup; plan none
mv "$WORK/store/.git" "$WORK/store/.git-away"
check "exit status" "$(run)" "0"
check "names git's refusal" "$(grep -c 'git refuses it' "$WORK/out")" "1"
check "does not claim the store is absent" "$(grep -c 'no provisioned store' "$WORK/out")" "0"
check "never asked ctxr" "$(calls '^ctxr update')" "0"
mv "$WORK/store/.git-away" "$WORK/store/.git"

echo "== containers that cannot act on the store step aside quietly =="
# The default is on in every container of a stack, so these are normal, not faults.
if [ "$(id -u)" != 0 ]; then
  setup; plan change
  chmod a-w "$WORK/store" "$WORK/store/.git"
  check "read-only: exit status" "$(run)" "0"
  check "read-only: says so" "$(grep -c 'read-only in this container' "$WORK/out")" "1"
  check "read-only: not a warning" "$(grep -c 'WARNING' "$WORK/out")" "0"
  check "read-only: never asked ctxr" "$(calls '^ctxr update')" "0"
  chmod u+w "$WORK/store" "$WORK/store/.git"
else
  echo "  SKIP: read-only case (root ignores mode bits)"
fi
setup; plan change; touch "$WORK/gh-unauthed"
check "no credential: exit status" "$(run)" "0"
check "no credential: says so" "$(grep -c 'no gh credential' "$WORK/out")" "1"
check "no credential: never asked ctxr" "$(calls '^ctxr update')" "0"

echo "== the lock lets one container work, and the others step aside =="
if command -v flock >/dev/null 2>&1; then
  setup; plan change
  # Another container holding the lock: a background holder on the same file.
  ( flock 8; sleep 5 ) 8>"$WORK/store/.git/ctxr-update-store.lock" &
  holder=$!
  sleep 1
  check "lock held: exit status" "$(run)" "0"
  check "lock held: steps aside" "$(grep -c 'another container is updating' "$WORK/out")" "1"
  check "lock held: never asked ctxr" "$(calls '^ctxr update')" "0"
  wait "$holder"
  check "lock free: exit status" "$(run)" "0"
  check "lock free: does the work" "$(calls '^ctxr update')" "1"
  check "lock free: PR opened" "$(calls 'pr create')" "1"
else
  echo "  SKIP: flock not available"
fi

echo "== a clean canonical clone is pulled, a dirty one is not =="
setup; plan none
git clone -q "$WORK/origin" "$WORK/other" 2>/dev/null
(cd "$WORK/other" && echo upstream > upstream.md && git add -A && git commit -qm upstream && git push -q origin HEAD:main)
check "exit status" "$(run)" "0"
check "clean clone pulled" "$(test -f "$WORK/store/upstream.md" && echo yes)" "yes"
setup; plan none
git clone -q "$WORK/origin" "$WORK/other" 2>/dev/null
(cd "$WORK/other" && echo upstream > upstream.md && git add -A && git commit -qm upstream && git push -q origin HEAD:main)
echo "in flight" > "$WORK/store/draft.md"
check "exit status" "$(run)" "0"
check "dirty clone not pulled" "$(test -f "$WORK/store/upstream.md" && echo yes || echo no)" "no"
check "update still ran" "$(calls '^ctxr update')" "1"
check "draft untouched" "$(cat "$WORK/store/draft.md")" "in flight"

echo "== nothing due: no commit, no push, no PR =="
setup; plan none
check "exit status" "$(run)" "0"
check "no PR" "$(calls 'pr create')" "0"
check "says up to date" "$(grep -c 'already up to date' "$WORK/out")" "1"

echo "== a due update is committed, pushed and opened; the clone is not written =="
setup; plan change
check "exit status" "$(run)" "0"
check "branch on origin" "$(git -C "$WORK/store" ls-remote --heads origin "$BRANCH" | wc -l | tr -d ' ')" "1"
check "commit carries the change" "$(git -C "$WORK/store" show "$BRANCH:owned.md")" "re-rendered"
check "PR opened" "$(calls 'pr create')" "1"
check "PR title" "$(cat "$WORK/pr-title")" "Re-render contexture-owned files for ctxr 0.19.0"
check "canonical clone clean" "$(git -C "$WORK/store" status --porcelain | wc -l | tr -d ' ')" "0"
check "canonical owned.md untouched" "$(cat "$WORK/store/owned.md")" "original"

echo "== a migration is named in the PR title =="
setup; plan migrate
run >/dev/null
check "PR title" "$(cat "$WORK/pr-title")" "Migrate store schema 10 to 11 and re-render for ctxr 0.19.0"

echo "== a SQUASH-merged branch is removed, and the update runs again =="
setup; plan change
run >/dev/null
# Squash-merge it upstream: the same patch as one new commit on main, so the branch is NOT an ancestor.
git clone -q "$WORK/origin" "$WORK/other" 2>/dev/null
(cd "$WORK/other" && git merge -q --squash "origin/$BRANCH" && git commit -qm "Re-render (#1)" && git push -q origin HEAD:main)
check "branch is not an ancestor of main" \
  "$(git -C "$WORK/other" merge-base --is-ancestor "origin/$BRANCH" HEAD && echo ancestor || echo not)" "not"
: > "$WORK/calls"; plan existing none
check "exit status" "$(run)" "0"
check "local branch removed" "$(git -C "$WORK/store" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null && echo kept || echo gone)" "gone"
check "remote branch removed" "$(git -C "$WORK/store" ls-remote --heads origin "$BRANCH" | wc -l | tr -d ' ')" "0"
check "update ran twice" "$(calls '^ctxr update')" "2"
check "no new PR" "$(calls 'pr create')" "0"

echo "== an unmerged, pushed branch with a PR is left alone =="
setup; plan change
run >/dev/null
: > "$WORK/calls"; plan existing
check "exit status" "$(run)" "0"
check "branch kept on origin" "$(git -C "$WORK/store" ls-remote --heads origin "$BRANCH" | wc -l | tr -d ' ')" "1"
check "no second PR" "$(calls 'pr create')" "0"
check "update ran once" "$(calls '^ctxr update')" "1"

echo "== a pushed branch whose PR was never opened gets one =="
setup; plan change
run >/dev/null
rm -f "$WORK/pr-exists"
: > "$WORK/calls"; plan existing
run >/dev/null
check "PR opened on resume" "$(calls 'pr create')" "1"

echo "== a commit whose push failed is pushed on the next start =="
setup; plan change
# Make the first push fail by pointing origin somewhere that does not exist, then restore it.
git -C "$WORK/store" remote set-url --push origin "$WORK/missing.git"
check "exit status despite failed push" "$(run)" "0"
check "nothing on origin yet" "$(git -C "$WORK/store" ls-remote --heads origin "$BRANCH" | wc -l | tr -d ' ')" "0"
check "no PR without a push" "$(calls 'pr create')" "0"
git -C "$WORK/store" remote set-url --push origin "$WORK/origin"
: > "$WORK/calls"; plan existing
check "exit status" "$(run)" "0"
check "pushed on resume" "$(git -C "$WORK/store" ls-remote --heads origin "$BRANCH" | wc -l | tr -d ' ')" "1"
check "PR opened on resume" "$(calls 'pr create')" "1"

echo "== a refusing ctxr costs a log line, not the boot =="
setup; plan fail
check "exit status" "$(run)" "0"
check "names the refusal" "$(grep -c 'older than supported' "$WORK/out")" "1"

echo "== dry run changes nothing remote =="
setup; plan change
check "exit status" "$(CTXR_UPDATE_STORE_DRY_RUN=1 STORE_DIR="$WORK/store" sh "$SOURCE" > "$WORK/out" 2>&1; echo $?)" "0"
check "nothing pushed" "$(git -C "$WORK/store" ls-remote --heads origin "$BRANCH" | wc -l | tr -d ' ')" "0"
check "no PR" "$(calls 'pr create')" "0"
check "says what it would do" "$(grep -c 'DRY RUN: would commit' "$WORK/out")" "1"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
