#!/bin/sh
# Put a store's ctxr-capture-circleback runner where Hermes cron can run it.
#
# Shipped as `ctxr-install-circleback-script`, and run at container start by the `store-update`
# s6 service, right after `ctxr-update-store` has pulled the canonical clone. Safe to run by hand,
# too, as the runtime user.
#
# WHY. ctxr ships the `ctxr-capture-circleback` skill (capture's retrieval step for Circleback), with its runner `sweep.mjs` and a rendered
# `settings.json`, into a store that declares a `circleback` block. A Hermes cron job's
# `--script` must live under $HERMES_HOME/scripts, and Hermes runs a `.sh` with bash and anything
# else with Python. So the skill directory is copied there, beside a `run.sh` launcher that:
#   - checks it runs with the agent's real HOME, where `cb` and `gh` are signed in. Hermes'
#     recipe sets TERMINAL_HOME_MODE=real so it does; if Hermes hands it another HOME (its
#     container default, $HERMES_HOME/home), it stops with a COLLECTION FAILED line naming both,
#     rather than failing later on a git credential error. It does not set HOME itself: the home
#     is Hermes' to get right, for its other tools too;
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
#   HERMES_HOME  Hermes's home (default $HOME/.hermes)
set -u

STORE="${STORE_DIR:-${CONTEXTURE_STORE_ROOT:-/store}}"
SKILLS="${SKILLS_DIR:-$STORE/.agents/skills}"
HERMES="${HERMES_HOME:-${HOME:-/home/agent}/.hermes}"
SOURCE="$SKILLS/ctxr-capture-circleback"
DEST="$HERMES/scripts/ctxr-capture-circleback"
# ctxr 0.30.0 shipped the skill as ctxr-circleback; a start on that release installed it here.
FORMER="$HERMES/scripts/ctxr-circleback"

log() { echo "[ctxr-install-circleback-script] $*"; }

if [ -d "$FORMER" ]; then
  rm -rf "$FORMER" && log "removed $FORMER: the skill is now ctxr-capture-circleback"
fi

if [ ! -f "$SOURCE/sweep.mjs" ]; then
  if [ -d "$DEST" ]; then
    rm -rf "$DEST" && log "removed $DEST: the store no longer ships ctxr-capture-circleback"
  else
    log "the store does not ship ctxr-capture-circleback; nothing to install"
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
# Hermes sets HERMES_REAL_HOME to the agent's home on every subprocess. Run by hand, it is unset.
if [ -n "\${HERMES_REAL_HOME:-}" ] && [ "\$HOME" != "\$HERMES_REAL_HOME" ]; then
  echo "COLLECTION FAILED: Hermes ran this with HOME=\$HOME, not the agent's home \$HERMES_REAL_HOME, so git, gh and cb have no sign-ins. Set TERMINAL_HOME_MODE=real for the gateway."
  exit 0
fi
export CONTEXTURE_STORE_ROOT="$STORE"
cd "$STORE" || { echo "COLLECTION FAILED: no store at $STORE"; exit 0; }
exec node "$DEST/sweep.mjs"
LAUNCHER
then
  log "WARNING: could not write $DEST/run.sh (the next start retries)"
  exit 0
fi
chmod +x "$DEST/run.sh" 2>/dev/null
log "installed $DEST (run.sh launches the store's ctxr-capture-circleback runner)"
exit 0
