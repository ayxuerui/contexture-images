# Debian's /etc/profile (in the base image) hardcodes a non-root PATH that drops this image's
# own prefixes -- /opt/hermes/bin (the `hermes` CLI), /opt/hermes/.venv/bin (every dependency
# the agent venv carries: google-api-python-client, the document-skill libs, etc.) and
# /opt/data/.local/bin. /etc/profile sources /etc/profile.d/*.sh AFTER that assignment, so this
# restores them rather than fighting the assignment.
#
# This matters because Hermes snapshots the session environment with a LOGIN shell
# (tools/environments/local.py's _run_bash(login=True), used by init_session) and then re-plays
# that snapshot's PATH into every later non-login `bash -c` for the rest of the session. Without
# this file, `python`/`python3` resolve to the system interpreter -- which is PEP 668
# externally-managed, has no pip module, and carries none of the agent's dependencies -- for the
# entire session, not just the first command.
#
# /opt/data/home/.local/bin is the agent's OWN tool prefix, and it sits ahead of /usr/local/bin
# on purpose: the image's CLIs are root-owned and the agent has no sudo, so this is where it
# installs a new tool or upgrades one the image ships. Every standard installer already lands
# there for a user whose ~ is /opt/data/home -- claude's install.sh and `claude update`, agy's
# install.sh, `pip install --user`, `uv tool install` -- and `npm i -g` does too once its prefix
# is pointed at it, below. Hardcoded rather than $HOME-relative because `docker exec` as root
# has HOME=/root, and this must name the same directory on every surface. It is on the data
# volume, so an override survives a recreate AND an image bump: it keeps shadowing the image's
# copy until someone deletes it.
#
# The venv stays first so `python` is still the agent's interpreter.
#
# Idempotent (checked, not just prepended) because that replay means a duplicate entry would be
# carried for the life of the session, not just the once. Keyed on the user prefix, the entry the
# image-level ENV PATH also carries, so a login shell that re-derived PATH still gets it back.
case ":${PATH}:" in
  *:/opt/data/home/.local/bin:*) ;;
  *) PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:/opt/data/home/.local/bin:/opt/data/.local/bin:${PATH}" ;;
esac
export PATH

if [ "$(id -u)" != 0 ]; then
  # Non-root only. As an image-wide ENV this would also catch a downstream
  # `FROM contexture-hermes` + `RUN npm i -g` as root, which would then install into the
  # volume's mount point -- a path the volume hides at runtime, so the tool silently vanishes.
  NPM_CONFIG_PREFIX=/opt/data/home/.local
  export NPM_CONFIG_PREFIX

  # ctxr is an npm global like any other, so the prefix above lets the agent shadow the pinned
  # one. Unlike any other, a ctxr whose version does not match the store's contexture.yaml
  # `schema_version` fails EVERY call, both directions. Warn rather than refuse: an override is
  # sometimes exactly what is wanted. A file test, never `ctxr --version` -- this runs on every
  # login shell and node startup is not free.
  if [ -e /opt/data/home/.local/bin/ctxr ]; then
    echo "contexture: /opt/data/home/.local/bin/ctxr shadows the image's ctxr $(cat /usr/local/share/contexture/ctxr-version 2>/dev/null || echo '(unknown)'); a version that does not match the store's schema_version fails every ctxr call. Remove it to restore the image's copy." >&2
  fi
fi
