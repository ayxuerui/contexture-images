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
# Idempotent (checked, not just prepended) because that replay means a duplicate entry would be
# carried for the life of the session, not just the once.
case ":${PATH}:" in
  *:/opt/hermes/.venv/bin:*) ;;
  *) PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:/opt/data/.local/bin:${PATH}" ;;
esac
export PATH
