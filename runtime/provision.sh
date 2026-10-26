#!/bin/sh
# workspace-init on the runtime image: ctxr into the agent's home first, then ctxr-provision.
#
# The image carries no ctxr; it is a tool installed into the home (lib/recipes/ctxr), and on a
# fresh store this one-shot runs before the agents container ever has. So install it here, as the
# agent's uid -- exactly as the agents container's first boot would, so that boot then finds it --
# and only then hand over to ctxr-provision, which runs as root and needs ctxr on PATH.
set -eu
log() { echo "runtime-provision: $*"; }
PUID="${PUID:-10000}"
PGID="${PGID:-10000}"
HOME_DIR="${HARNESS_AGENT_HOME:-/home/agent}"
[ "$(id -u)" = 0 ] || { log "must run as root (ctxr-provision chowns the store)"; exit 1; }
owner="$(stat -c %u "${HOME_DIR}")"
if [ "${owner}" != "${PUID}" ]; then
  log "${HOME_DIR} is owned by uid ${owner}, not ${PUID}; changing it once"
  chown -R "${PUID}:${PGID}" "${HOME_DIR}"
fi
setpriv --reuid="${PUID}" --regid="${PGID}" --clear-groups \
  env HOME="${HOME_DIR}" HARNESSES= TOOLS=ctxr HARNESS_SERVICES= runtime-install --install-only
exec ctxr-provision "$@"
