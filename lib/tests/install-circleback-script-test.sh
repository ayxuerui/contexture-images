#!/bin/sh
# Regression tests for ctxr-install-circleback-script, run at container start after the store update.
#
# What it guards:
#
#   1. It never exits non-zero. It runs at boot.
#   2. A store that ships ctxr-capture-circleback gets the skill directory copied into Hermes's scripts
#      directory, beside a run.sh that sets the agent's HOME, changes into the store, and runs the
#      copied runner by absolute path -- a cron job's working directory is not guaranteed.
#   3. A store that stops shipping the skill loses the copy, so an opt-out retires the runner.
#   4. A store that never shipped it gets nothing.
#   5. The copy installed under the skill's former name, ctxr-circleback, is removed.
#
# Needs only sh and node (to run the launcher against a stand-in runner).
#
#   sh lib/tests/install-circleback-script-test.sh
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SOURCE="$SCRIPT_DIR/../install-circleback-script.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
FAILED=0
fail() { echo "FAIL: $*"; FAILED=1; }
pass() { echo "ok: $*"; }

STORE="$WORK/store"
HERMES="$WORK/hermes"
SKILL="$STORE/.agents/skills/ctxr-capture-circleback"
DEST="$HERMES/scripts/ctxr-capture-circleback"
mkdir -p "$STORE" "$HERMES/scripts"

install_runner() {
  STORE_DIR="$STORE" HERMES_HOME="$HERMES" sh "$SOURCE" > "$WORK/out" 2>&1
}

# 4. Nothing shipped, nothing installed.
install_runner || fail "exited non-zero with no skill"
[ ! -e "$DEST" ] && grep -q "does not ship ctxr-capture-circleback" "$WORK/out" \
  && pass "a store without the skill gets nothing" || fail "installed something for a store without the skill"

# 2. Shipped: copied, and the launcher runs the copy from the store with the agent's HOME.
mkdir -p "$SKILL"
cat > "$SKILL/sweep.mjs" <<'RUNNER'
console.log(JSON.stringify({ cwd: process.cwd(), home: process.env.HOME, root: process.env.CONTEXTURE_STORE_ROOT, here: import.meta.url }));
RUNNER
echo '{"tag":"t"}' > "$SKILL/settings.json"
install_runner || fail "exited non-zero installing the skill"
[ -f "$DEST/sweep.mjs" ] && [ -f "$DEST/settings.json" ] && pass "skill directory copied" || fail "skill directory not copied"
[ -x "$DEST/run.sh" ] && pass "run.sh is executable" || fail "run.sh missing or not executable"
OUT=$(cd "$WORK" && bash "$DEST/run.sh")
case "$OUT" in
  *"\"cwd\":\"$STORE\""*"\"home\":\"$HERMES/home\""*"\"root\":\"$STORE\""*"$DEST/sweep.mjs"*)
    pass "launcher runs the copied runner from the store with the agent's HOME" ;;
  *) fail "launcher ran with the wrong context: $OUT" ;;
esac

# A refreshed skill replaces the copy rather than merging into it.
rm "$SKILL/settings.json"
install_runner || fail "exited non-zero refreshing the skill"
[ ! -e "$DEST/settings.json" ] && pass "a file the store stopped shipping leaves the copy" || fail "stale file kept in the copy"

# The copy a ctxr 0.30.0 start installed under the skill's former name is removed.
mkdir -p "$HERMES/scripts/ctxr-circleback" && touch "$HERMES/scripts/ctxr-circleback/sweep.mjs"
install_runner || fail "exited non-zero with a former install present"
[ ! -e "$HERMES/scripts/ctxr-circleback" ] && [ -f "$DEST/sweep.mjs" ] \
  && pass "the former ctxr-circleback install is removed" || fail "former ctxr-circleback install left behind"

# 3. Opt-out removes the copy.
rm -rf "$SKILL"
install_runner || fail "exited non-zero removing the skill"
[ ! -e "$DEST" ] && grep -q "no longer ships" "$WORK/out" \
  && pass "opting out removes the installed runner" || fail "installed runner left behind after opt-out"

exit "$FAILED"
