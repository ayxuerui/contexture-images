# contexture-runtime: the platform a Contexture store's harnesses run on, with no harness in it.
#
# See docs/design/harnesses-in-home.md. The image holds what must match across containers, needs
# root, or is run by something other than the agent: Debian, tini, supervisord, the `agent` user,
# Node, a platform python venv, ctxr, gh, the backup and skill tools, and the ctxr-*/harness-*
# scripts. Every harness -- Hermes, its WebUI, claude, codex, agy, agent-browser, cb -- is
# installed at boot into the harnesses volume by harness-install, chosen by the HARNESSES /
# HARNESS_SERVICES / HARNESS_PINS compose variables, and updated without an image.
#
# Built and tested by CI, not yet published or deployed: stores keep running contexture-hermes
# until they migrate (docs/design/harnesses-in-home.md, phase 3).
#
# Build context is the REPO ROOT, so lib/ is reachable:
#   docker build -f runtime/Dockerfile --build-arg CTXR_VERSION=$(cat CTXR_VERSION) .
ARG DEBIAN_IMAGE=debian:trixie-20261020-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
FROM ${DEBIAN_IMAGE}

# --- Base packages -------------------------------------------------------------------------
# tini is PID 1: it forwards signals and reaps the orphans remote sessions leave behind.
# supervisor runs the programs. python3 runs harness-install and the platform venv; it is
# Debian's, and nothing on this image opens a live Hermes database with it (see the design's
# SQLite section), which is why no sqlite3 CLI is installed. zstd lets claude's installer take
# its compressed download.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-client procps less \
      python3 python3-venv supervisor tini xz-utils zstd; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    rm -f /etc/supervisor/conf.d/*

# --- Libraries harnesses' own runtimes load -----------------------------------------------
# Harnesses bring their own toolchains, but those load system libraries the agent cannot install
# (no root). libatomic1: Hermes' package manager's pinned Node refuses to start without it.
# The rest is the shared-library set Chromium needs, copied from upstream Hermes' Dockerfile: the
# browser Hermes and agent-browser download is a prebuilt Chromium, and it is these libraries, not
# the browser, that only an image can provide.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      libatomic1 \
      libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 libcups2t64 \
      libdbus-1-3 libgbm1 libglib2.0-0t64 libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 \
      libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# --- The runtime user ----------------------------------------------------------------------
# `agent`, uid/gid 10000 unless PUID/PGID remap it at boot. Its home is the home volume, so
# `docker exec -u agent` lands where every harness keeps its state. Not `hermes`: nothing needs
# that name once Hermes' own Docker scripts and s6 backend are gone. Not root: see the design.
# /opt/harnesses is created here, owned by agent, so a fresh named volume mounted over it copies
# that ownership.
RUN set -eux; \
    groupadd -g 10000 agent; \
    useradd -u 10000 -g 10000 -m -d /home/agent -s /bin/bash agent; \
    install -d -o agent -g agent /opt/harnesses

# --- Node ------------------------------------------------------------------------------------
ARG NODE_VERSION=24.22.1
ARG NODE_SHA256_AMD64=6c172a9ab6718f7b801fb5a7bd486af2ee5e32758086a04b84fcce2aa77095e6
ARG NODE_SHA256_ARM64=dbabf7a1cbf947e6059ffad2c27b80041db97dea1e553b62afdee7f13fca336e
COPY lib/install-node.sh /tmp/install-node.sh
RUN /tmp/install-node.sh && rm -f /tmp/install-node.sh

# --- Contexture toolchain: gh + ctxr ---------------------------------------------------------
# The same script the Hermes image runs. CTXR_VERSION is still the image tag.
ARG GH_VERSION=2.98.0
ARG CTXR_VERSION
COPY lib/install-contexture-toolchain.sh /tmp/install-contexture-toolchain.sh
RUN /tmp/install-contexture-toolchain.sh && rm -f /tmp/install-contexture-toolchain.sh

# The image's ctxr is the fallback, not the first: it moves from /usr/local/bin to the END of PATH.
# In the agents container the `ctxr` harness (lib/harnesses/ctxr) is installed and updated in place
# and so wins; `serve` and the one-shots, which never mount the agent-writable harnesses volume,
# fall through to this one. See lib/harnesses/ctxr/recipe.toml for why there are two.
RUN set -eux; \
    install -d /usr/local/lib/contexture/bin; \
    ln -s /usr/local/lib/node_modules/ctxr-cli/dist/bin.js /usr/local/lib/contexture/bin/ctxr; \
    rm /usr/local/bin/ctxr; \
    /usr/local/lib/contexture/bin/ctxr --version

# --- Backup and skill tools ------------------------------------------------------------------
ARG RESTIC_VERSION=0.19.1
ARG RCLONE_VERSION=1.75.1
COPY lib/install-backup-tools.sh /tmp/install-backup-tools.sh
RUN /tmp/install-backup-tools.sh && rm -f /tmp/install-backup-tools.sh

ARG PANDOC_VERSION=3.11
ARG PANDOC_SHA256_AMD64=37edb3bbcf722f921a009941bf5874e2e0c09263226c9b4a2d980788cb062ab6
ARG PANDOC_SHA256_ARM64=56ed5566ec41d22ec9ee0704e6ac0b98ba102e92384efd5306173a22d314c79a
ARG JQ_VERSION=1.8.2
COPY lib/install-skill-tools.sh /tmp/install-skill-tools.sh
RUN /tmp/install-skill-tools.sh && rm -f /tmp/install-skill-tools.sh

# --- Platform venv ---------------------------------------------------------------------------
# The document-skill libraries the Hermes image installs into Hermes' own venv, here in a venv the
# platform owns, so no harness's update can remove them. First on PATH, so `python3` in an agent's
# shell has them. Same pins as harnesses/hermes/Dockerfile.
ARG PYPDF_VERSION=6.16.2
ARG REPORTLAB_VERSION=5.0.1
ARG PDFPLUMBER_VERSION=0.11.10
ARG PYPDFIUM2_VERSION=5.13.0
ARG PYTHON_DOCX_VERSION=1.2.0
ARG OPENPYXL_VERSION=3.1.5
ARG PYTHON_PPTX_VERSION=1.0.2
ARG BEAUTIFULSOUP4_VERSION=4.15.0
RUN set -eux; \
    python3 -m venv /opt/contexture/venv; \
    /opt/contexture/venv/bin/pip install --no-cache-dir --disable-pip-version-check \
      "pypdf==${PYPDF_VERSION}" \
      "reportlab==${REPORTLAB_VERSION}" \
      "pdfplumber==${PDFPLUMBER_VERSION}" \
      "pypdfium2==${PYPDFIUM2_VERSION}" \
      "python-docx==${PYTHON_DOCX_VERSION}" \
      "openpyxl==${OPENPYXL_VERSION}" \
      "python-pptx==${PYTHON_PPTX_VERSION}" \
      "beautifulsoup4==${BEAUTIFULSOUP4_VERSION}"; \
    /opt/contexture/venv/bin/python -c \
      "import pypdf, reportlab, pdfplumber, pypdfium2, docx, openpyxl, pptx, bs4"

# --- Platform scripts --------------------------------------------------------------------------
#   harness-install          installs, updates and supervises the harnesses; reads the recipes
#   harness-remote           the remote-control wrapper, shared with the Hermes image
#   harness-schedule         runs the daily update (and, in compose, the backup schedulers)
#   harness-backup           the whole home to restic, through the recipes' snapshots; and restore
#   harness-config-push      the home's config to a private git remote, allowlist from the recipes
#   harness-migrate-home     turns a Hermes-image volume into a runtime home, and back
#   runtime-store-update     the store update at start, then the harnesses' store-updated hooks
#   ctxr-update-store, ctxr-provision, ctxr-install-circleback-script   as in the Hermes image
COPY lib/harness-install.py /usr/local/bin/harness-install
COPY lib/harnesses /usr/local/share/contexture/harnesses
COPY lib/harness-remote.py /usr/local/bin/harness-remote
COPY lib/schedule.sh /usr/local/bin/harness-schedule
COPY lib/update-store.sh /usr/local/bin/ctxr-update-store
COPY lib/provision-store.sh /usr/local/bin/ctxr-provision
COPY lib/install-circleback-script.sh /usr/local/bin/ctxr-install-circleback-script
COPY lib/runtime-backup.py /usr/local/bin/harness-backup
COPY lib/config-push.sh /usr/local/lib/contexture/config-push.sh
COPY runtime/config-push.sh /usr/local/bin/harness-config-push
COPY lib/migrate-home.py /usr/local/bin/harness-migrate-home
COPY runtime/store-update.sh /usr/local/bin/runtime-store-update
COPY runtime/entrypoint.sh /usr/local/bin/runtime-entrypoint
COPY runtime/supervisord.conf /etc/supervisor/supervisord.conf
COPY runtime/profile.d/10-runtime-path.sh /etc/profile.d/10-runtime-path.sh
RUN set -eux; \
    rm -f /usr/local/share/contexture/harnesses/README.md; \
    chmod +x /usr/local/bin/harness-install /usr/local/bin/harness-remote /usr/local/bin/harness-schedule \
      /usr/local/bin/ctxr-update-store /usr/local/bin/ctxr-provision /usr/local/bin/runtime-entrypoint \
      /usr/local/bin/ctxr-install-circleback-script /usr/local/bin/harness-backup \
      /usr/local/lib/contexture/config-push.sh /usr/local/bin/harness-config-push \
      /usr/local/bin/harness-migrate-home /usr/local/bin/runtime-store-update; \
    chmod -R a+rX /usr/local/share/contexture /etc/profile.d/10-runtime-path.sh; \
    for script in runtime-entrypoint ctxr-install-circleback-script harness-config-push runtime-store-update; do \
      sh -n "/usr/local/bin/${script}"; \
    done; \
    sh -n /usr/local/lib/contexture/config-push.sh; \
    python3 -c 'import ast,sys; [ast.parse(open(p).read()) for p in sys.argv[1:]]' \
      /usr/local/bin/harness-install /usr/local/bin/harness-remote /usr/local/bin/harness-backup \
      /usr/local/bin/harness-migrate-home

# Platform first, the agent-writable /opt/harnesses/bin after it: a harness never shadows gh or the
# platform python. The image's ctxr comes after both, on purpose, so the in-place `ctxr` harness is
# the agents' ctxr and this one only serve's and the one-shots'. DISABLE_AUTOUPDATER keeps claude
# from rewriting itself; harness-install is the one writer of /opt/harnesses.
ENV PATH=/opt/contexture/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/harnesses/bin:/usr/local/lib/contexture/bin \
    DISABLE_AUTOUPDATER=1 \
    HARNESS_STATUS_FILE=/home/agent/.local/state/contexture/harness-status.json

# Every recipe parses, and the full selection -- what the shared compose file will default to --
# is consistent with them.
RUN HARNESSES=ctxr,hermes,hermes-webui,claude,codex,agy,agent-browser,cb \
    HARNESS_SERVICES=hermes-gateway,hermes-dashboard,hermes-webui,claude-remote,codex-remote,agy-remote \
      harness-install check

WORKDIR /home/agent
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/runtime-entrypoint"]
