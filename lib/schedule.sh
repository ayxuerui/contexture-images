#!/bin/sh
# Run a command on a fixed interval, forever, as a container's main process.
#
# Shipped as `harness-schedule`. Never run by this image -- a deployment points a service at it.
#
# This exists because the alternatives were worse for a BACKUP specifically. The harness's own
# cron dies with the harness: a gateway that wedges while still alive is never restarted (Docker
# restart policies act on process exit, not on healthcheck failure), so its scheduler stops and
# takes the backups -- and the delivery channel that would have reported them missing -- with
# it. A host timer avoids that but puts the schedule somewhere the compose file does not
# describe, and host-side units are exactly what rotted on the deployment this was written for:
# four of them vanished while a tracked runbook still promised them as a rollback.
#
# So: an ordinary container, with its own restart policy, scheduling itself.
#
# Required:
#   HARNESS_SCHEDULE_INTERVAL    seconds between runs
# Optional:
#   HARNESS_SCHEDULE_NOTIFY      `hermes send` target for failures (e.g. telegram).
#                                Unset = log only. Needs $HERMES_HOME on the volume.
#   HARNESS_SCHEDULE_NAME        label for log lines           (default: the command)
#   HARNESS_SCHEDULE_SKIP_FIRST  1 to wait for the first slot instead of running at startup
set -eu

: "${HARNESS_SCHEDULE_INTERVAL:?HARNESS_SCHEDULE_INTERVAL is required}"
[ "$#" -gt 0 ] || { echo "harness-schedule: a command is required" >&2; exit 1; }

INTERVAL="$HARNESS_SCHEDULE_INTERVAL"
NAME="${HARNESS_SCHEDULE_NAME:-$1}"

log() { echo "[harness-schedule:${NAME}] $*"; }

case "$INTERVAL" in
  ''|*[!0-9]*) echo "harness-schedule: HARNESS_SCHEDULE_INTERVAL must be whole seconds, got '$INTERVAL'" >&2; exit 1 ;;
esac
[ "$INTERVAL" -gt 0 ] || { echo "harness-schedule: HARNESS_SCHEDULE_INTERVAL must be > 0" >&2; exit 1; }

# >>> slot-maths (lib/tests/schedule-test.sh extracts between these markers; keep them around
# exactly the calculation) >>>
# Seconds until the next epoch-aligned slot, so runs land on stable wall-clock times instead of
# drifting from whenever the container happened to start. 86400 gives 00:00 UTC; 21600 gives
# 00/06/12/18. A plain `sleep $INTERVAL` would instead pin the schedule to the last restart,
# which means the backup time moves every time the stack is touched.
#
# Never returns 0: landing exactly on a boundary would otherwise busy-loop.
harness_schedule_seconds_to_next_slot() {   # $1 = interval, $2 = now (epoch)
  _i="$1"; _now="$2"
  _rem=$(( _now % _i ))
  _wait=$(( _i - _rem ))
  [ "$_wait" -gt 0 ] || _wait="$_i"
  echo "$_wait"
}
# <<< slot-maths <<<

# >>> interruptible-sleep >>>
# `sleep N & wait $!` rather than a bare `sleep N`, and the difference is not cosmetic. A bare
# sleep does not yield to a trap until it finishes: measured at 29s for a 30s sleep, versus 0s
# for this form. At a 24h interval that means every `docker compose down`, `stop` or `restart`
# blocks for the full stop_grace_period and is then SIGKILLed -- and a SIGKILL partway through a
# restic run strands a lock in the repository that the next run has to break.
harness_schedule_sleep() {   # $1 = seconds
  sleep "$1" &
  _sleep_pid=$!
  wait "$_sleep_pid"
}
# <<< interruptible-sleep <<<

_running=1
_stop() { log "signal received, stopping"; _running=0; kill "${_sleep_pid:-0}" 2>/dev/null || true; }
trap _stop TERM INT

notify() {   # $1 = message
  [ -n "${HARNESS_SCHEDULE_NOTIFY:-}" ] || return 0
  command -v hermes >/dev/null 2>&1 || { log "WARNING: HARNESS_SCHEDULE_NOTIFY set but hermes is not installed"; return 0; }
  # Best effort, and deliberately never fatal: a failed notification must not also kill the
  # scheduler. `hermes send` needs no running gateway for bot-token platforms, which is the
  # whole reason it can report the failure this loop exists to survive.
  hermes send --to "$HARNESS_SCHEDULE_NOTIFY" --subject "harness-schedule: ${NAME} FAILED" "$1" \
    >/dev/null 2>&1 || log "WARNING: notification failed"
}

log "every ${INTERVAL}s: $*"

if [ "${HARNESS_SCHEDULE_SKIP_FIRST:-0}" = 1 ]; then
  log "skipping the startup run (HARNESS_SCHEDULE_SKIP_FIRST=1)"
else
  # The startup run IS the catch-up mechanism. A container restarted after the host was down
  # runs immediately rather than waiting for the next slot, which is the one property a systemd
  # timer's Persistent=true would have given. The cost is an extra run per restart; for a restic
  # snapshot of an unchanged tree that is tens of megabytes, not a rewrite.
  log "startup run"
  if "$@"; then log "ok"; else
    _rc=$?
    log "FAILED (exit ${_rc})"
    notify "startup run exited ${_rc}"
  fi
fi

while [ "$_running" -eq 1 ]; do
  _wait="$(harness_schedule_seconds_to_next_slot "$INTERVAL" "$(date -u +%s)")"
  log "next run in ${_wait}s"
  harness_schedule_sleep "$_wait"
  [ "$_running" -eq 1 ] || break

  # A failure NEVER breaks the loop. Exiting here would meet `restart: unless-stopped` and turn
  # one bad run into a hot restart loop re-running the whole backup continuously -- which for a
  # destination billed per operation is a bill, and for a rate-limited one is a lockout.
  if "$@"; then log "ok"; else
    _rc=$?
    log "FAILED (exit ${_rc}) - staying up for the next slot"
    notify "run exited ${_rc}"
  fi
done

log "stopped"
