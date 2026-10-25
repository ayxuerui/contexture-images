# Debian's /etc/profile overwrites PATH for login shells, dropping the image's ENV PATH -- the
# same trap harnesses/hermes/profile.d/10-hermes-path.sh documents for the Hermes image. Restore
# it. Order is deliberate: the platform first and the agent-writable /opt/harnesses/bin after it,
# so no harness can shadow gh or python3; the image's ctxr after both, so the agents' in-place
# `ctxr` harness wins (lib/harnesses/ctxr/recipe.toml).
case ":${PATH}:" in
  *:/opt/harnesses/bin:*) ;;
  *) PATH="/opt/contexture/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/harnesses/bin:/usr/local/lib/contexture/bin" ;;
esac
export PATH
