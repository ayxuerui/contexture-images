#!/bin/sh
# Put a store's ctxr-circleback runner where Hermes cron can run it.
#
# Shipped as `ctxr-install-circleback-script`, and run at container start by the `store-update`
# s6 service, right after `ctxr-update-store` has pulled the canonical clone. Safe to run by hand,
# too, as the runtime user.
#
# WHY. ctxr ships the `ctxr-circleback` skill, with its runner `sweep.mjs` and a rendered
# `settings.json`, into a store that declares a `circleback` block. A Hermes cron job's
# `--script` must live under $HERMES_HOME/scripts, and Hermes runs a `.sh` with bash and anything
# else with Python. So the skill directory is copied there, beside a `run.sh` launcher that:
#   - sets HOME to the agent's home, where `cb` and `gh` are signed in;
#   - changes into the store, which the runner reads as CONTEXTURE_STORE_ROOT;
#   - runs the copied runner by absolute path, because a job's working directory is not
#     guaranteed.
# The copy is ctxr's, refreshed at every start; editing it changes nothing for long.
#
# A store that does not ship the skill gets nothing, and a copy left from an earlier start is
# removed, so opting out of the block in contexture.yaml retires the runner too.
#
# WHY IT NEVER EXITS NON-ZERO. Same contract as ctxr-update-store: it runs at boot, and a failure
# here costs a log line, not a container that will not start.
#
# Inputs, all optional:
#   STORE_DIR    the store checkout (default $CONTEXTURE_STORE_ROOT, else /store)
#   SKILLS_DIR   where the store's skills are (default $STORE/.agents/skills)
#   HERMES_HOME  Hermes's home (default /opt/data)
set -u

STORE="${STORE_DIR:-${CONTEXTURE_STORE_ROOT:-/store}}"
SKILLS="${SKILLS_DIR:-$STORE/.agents/skills}"
HERMES="${HERMES_HOME:-/opt/data}"
SOURCE="$SKILLS/ctxr-circleback"
DEST="$HERMES/scripts/ctxr-circleback"

log() { echo "[ctxr-install-circleback-script] $*"; }

if [ ! -f "$SOURCE/sweep.mjs" ]; then
  if [ -d "$DEST" ]; then
    rm -rf "$DEST" && log "removed $DEST: the store no longer ships ctxr-circleback"
  else
    log "the store does not ship ctxr-circleback; nothing to install"
  fi
  exit 0
fi

if ! { rm -rf "$DEST" && mkdir -p "$DEST" && cp -R "$SOURCE/." "$DEST/"; }; then
  log "WARNING: could not copy $SOURCE to $DEST (the next start retries)"
  exit 0
fi

if ! cat > "$DEST/run.sh" <<LAUNCHER
#!/bin/sh
# Written by ctxr-install-circleback-script at container start. Do not edit: the next start rewrites it.
export HOME="$HERMES/home"
export CONTEXTURE_STORE_ROOT="$STORE"
cd "$STORE" || { echo "COLLECTION FAILED: no store at $STORE"; exit 0; }
exec node "$DEST/sweep.mjs"
LAUNCHER
then
  log "WARNING: could not write $DEST/run.sh (the next start retries)"
  exit 0
fi
chmod +x "$DEST/run.sh" 2>/dev/null
log "installed $DEST (run.sh launches the store's ctxr-circleback runner)"
exit 0
