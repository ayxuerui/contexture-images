#!/bin/sh
# Regression tests for harness-schedule.
#
# Three properties, each of which fails in a way that is invisible until it matters:
#
#   1. Slot maths. A drifting schedule still runs, so nothing alerts -- the backup just happens
#      at a different time after every restart, and the retention policy quietly stops lining up
#      with the runs.
#   2. Interruptible sleep. A bare `sleep` ignores its trap until it finishes; at a 24h interval
#      every `compose down` then blocks for the grace period and SIGKILLs, which can strand a
#      restic lock mid-run. A container that stops "slowly" looks like a slow machine, not a bug.
#   3. A failing command must not end the loop. Exiting meets `restart: unless-stopped` and
#      turns one failure into a hot loop re-running the job continuously.
#
# Needs sh, and a few seconds. No root, no network, no image.
#
#   sh lib/tests/schedule-test.sh
set -u

SCRIPT_DIR=$(dirname "$0")
SOURCE="$SCRIPT_DIR/../schedule.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

[ -f "$SOURCE" ] || { echo "cannot find $SOURCE"; exit 1; }

# Extraction is by marker, so a refactor that drops one fails loudly here rather than silently
# testing an empty file and reporting green.
SLOT="$WORK/slot.sh"
sed -n '/^# >>> slot-maths/,/^# <<< slot-maths/p' "$SOURCE" > "$SLOT"
grep -q 'harness_schedule_seconds_to_next_slot' "$SLOT" || {
  echo "FAIL: could not extract the slot maths (markers missing or moved)"; exit 1; }
grep -q 'wait $!' "$SOURCE" || {
  echo "FAIL: the interruptible-sleep idiom (sleep & wait) is gone from $SOURCE"; exit 1; }
. "$SLOT"

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then echo "  PASS: $1"; PASS=$((PASS + 1))
  else echo "  FAIL: $1 (want '$3', got '$2')"; FAIL=$((FAIL + 1)); fi
}

echo "== slot maths lands on wall-clock boundaries =="
# 86400 = midnight UTC. 1700000000 is 2023-11-14T22:13:20Z, so 6400s remain in the day.
check "daily, mid-day"      "$(harness_schedule_seconds_to_next_slot 86400 1700000000)" "6400"
# 21600 = 00/06/12/18. Same instant is 4h13m20s past 18:00, so 6400s to 00:00.
check "6-hourly, mid-slot"  "$(harness_schedule_seconds_to_next_slot 21600 1700000000)" "6400"
check "1-hourly, mid-slot"  "$(harness_schedule_seconds_to_next_slot 3600 1700000000)"  "2800"
# Exactly on a boundary must return a FULL interval, never 0 -- 0 would busy-loop.
check "exactly on a boundary" "$(harness_schedule_seconds_to_next_slot 3600 1700002800)" "3600"
check "one second past"       "$(harness_schedule_seconds_to_next_slot 3600 1700002801)" "3599"
check "one second before"     "$(harness_schedule_seconds_to_next_slot 3600 1700002799)" "1"

echo "== a long sleep still stops promptly on SIGTERM =="
# The whole point: an interval far longer than the test could ever wait out.
env HARNESS_SCHEDULE_INTERVAL=86400 HARNESS_SCHEDULE_NAME=t sh "$SOURCE" true >"$WORK/sig.log" 2>&1 &
sigpid=$!
sleep 2
t0=$(date +%s)
kill -TERM "$sigpid" 2>/dev/null
wait "$sigpid" 2>/dev/null
elapsed=$(( $(date +%s) - t0 ))
check "exits within 3s of SIGTERM" "$([ "$elapsed" -le 3 ] && echo yes || echo "no (${elapsed}s)")" "yes"
check "logged the signal" "$(grep -q 'signal received' "$WORK/sig.log" && echo yes || echo no)" "yes"

echo "== a failing command does not end the loop =="
env HARNESS_SCHEDULE_INTERVAL=2 HARNESS_SCHEDULE_NAME=t sh "$SOURCE" false >"$WORK/fail.log" 2>&1 &
failpid=$!
sleep 7
still_running=$(kill -0 "$failpid" 2>/dev/null && echo yes || echo no)
kill -TERM "$failpid" 2>/dev/null; wait "$failpid" 2>/dev/null
check "still running after repeated failures" "$still_running" "yes"
check "kept scheduling" \
  "$([ "$(grep -c 'staying up for the next slot' "$WORK/fail.log")" -ge 2 ] && echo yes || echo no)" "yes"

echo "== guards fail closed =="
out=$(env HARNESS_SCHEDULE_INTERVAL=abc sh "$SOURCE" true 2>&1); rc=$?
check "non-numeric interval refused" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
out=$(env HARNESS_SCHEDULE_INTERVAL=0 sh "$SOURCE" true 2>&1); rc=$?
check "zero interval refused" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
out=$(env HARNESS_SCHEDULE_INTERVAL=60 sh "$SOURCE" 2>&1); rc=$?
check "missing command refused" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
out=$(sh "$SOURCE" true 2>&1); rc=$?
check "missing interval refused" \
  "$(echo "$out" | grep -q 'HARNESS_SCHEDULE_INTERVAL is required' && echo yes || echo no)" "yes"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
