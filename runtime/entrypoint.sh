#!/bin/sh
# The runtime image's entrypoint, under tini as PID 1.
#
#   as root:   apply PUID/PGID to the `agent` user, give it /run/harness, own the two volumes,
#              then re-exec this script as `agent` -- nothing after that runs as root
#   as agent:  with arguments, run them (a one-off like `docker run <image> ctxr --version`);
#              without, install what is missing and hand the container to supervisord
#
# The remap is what upstream Hermes' stage2-hook.sh did for its `hermes` user: the uid on the
# volumes is fixed by the deployment (PUID, 10000 by default), so the user follows it rather than
# the files. A container started with `user:` (the one-shot compose services) skips all of it.
set -eu

log() { echo "runtime-entrypoint: $*"; }

if [ "$(id -u)" = 0 ]; then
  PUID="${PUID:-10000}"
  PGID="${PGID:-10000}"
  case "${PUID}:${PGID}" in
    *[!0-9:]*|:*|*:) log "PUID and PGID must be numbers, got ${PUID}:${PGID}"; exit 1 ;;
  esac
  [ "${PUID}" != 0 ] && [ "${PGID}" != 0 ] || { log "PUID/PGID 0 would run the agent as root; refusing"; exit 1; }
  [ "$(id -g agent)" = "${PGID}" ] || groupmod -o -g "${PGID}" agent
  [ "$(id -u agent)" = "${PUID}" ] || usermod -o -u "${PUID}" agent
  install -d -o agent -g agent -m 0700 /run/harness
  # Only when the top of a volume belongs to someone else: a fresh named volume copies the
  # image's ownership, and an unchanged PUID finds nothing to do.
  for dir in /home/agent /opt/harnesses; do
    owner="$(stat -c %u "${dir}")"
    if [ "${owner}" != "${PUID}" ]; then
      log "${dir} is owned by uid ${owner}, not ${PUID}; changing it once"
      chown -R agent:agent "${dir}"
    fi
  done
  # supervisord, as agent, reopens /dev/stdout for every program's log -- and Docker's log pipe
  # belongs to root, so that open is refused (EACCES). Hand the pipe to the agent first. A
  # terminal (`docker run -t`) is the same; a redirect to a file the agent cannot own is left be.
  chown --dereference agent:agent /proc/self/fd/1 /proc/self/fd/2 2>/dev/null || true
  exec setpriv --reuid=agent --regid=agent --init-groups -- "$0" "$@"
fi

# setpriv keeps root's environment; the agent's HOME is its passwd home, the home volume.
if [ "$(id -un 2>/dev/null)" = agent ]; then
  export HOME=/home/agent USER=agent LOGNAME=agent
fi

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

# A configuration mistake (an unknown harness, a service no selected harness offers) exits 2 and
# stops the container, loudly. A harness that fails to install does not: it is reported, its
# programs are left out, and the rest start.
harness-install
exec supervisord -c /etc/supervisor/supervisord.conf
