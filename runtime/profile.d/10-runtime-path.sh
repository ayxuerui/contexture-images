# Debian's /etc/profile overwrites PATH for login shells, dropping the image's ENV PATH -- the
# same trap harnesses/hermes/profile.d/10-hermes-path.sh documents for the Hermes image. Restore
# it, in the image's order: the platform first, then ~/.local/bin, where every harness's installer
# and npm's global prefix put their binaries, then the image's own ctxr last, so the ctxr installed
# in the home wins and the image's is only the fallback.
#
# The agent's ~/.profile (Debian's skeleton, and what codex's installer appends) prepends
# ~/.local/bin again after this; the home is the agent's, and so is that choice.
case ":${PATH}:" in
  *:/home/agent/.local/bin:*) ;;
  *) PATH="/opt/contexture/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/agent/.local/bin:/usr/local/lib/contexture/bin" ;;
esac
export PATH
