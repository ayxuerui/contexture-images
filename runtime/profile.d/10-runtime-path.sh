# Debian's /etc/profile overwrites PATH for login shells, dropping the image's ENV PATH -- the
# same trap harnesses/hermes/profile.d/10-hermes-path.sh documents for the Hermes image. Restore
# it. Order is deliberate: the platform first, the agent-writable /opt/harnesses/bin last, so no
# harness can shadow ctxr, gh or python3.
case ":${PATH}:" in
  *:/opt/harnesses/bin:*) ;;
  *) PATH="/opt/contexture/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/harnesses/bin" ;;
esac
export PATH
