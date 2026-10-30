# Debian's /etc/profile overwrites PATH for login shells, dropping the image's ENV PATH. Restore
# it, in the image's order: the platform first, then ~/.local/bin, where every harness's installer
# and npm's global prefix put their binaries.
#
# The agent's ~/.profile (Debian's skeleton, and what codex's and agy's installers append) prepends
# ~/.local/bin again after this; the home is the agent's, and so is that choice.
case ":${PATH}:" in
  *:/home/agent/.local/bin:*) ;;
  *) PATH="/opt/contexture/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/agent/.local/bin" ;;
esac
export PATH
