# contexture-runtime: the platform a Contexture store's harnesses run on, with no harness in it.
#
# See docs/design/harnesses-in-home.md. The image holds what must match across containers, needs
# root, or is run by something other than the agent: Debian, tini, supervisord, the `agent` user,
# Node, a platform python venv, gh, the backup and skill tools, and the runtime-*/home-*/ctxr-*
# scripts. No ctxr: every harness (Hermes, its WebUI, claude, codex, agy) and every tool (ctxr, cb,
# agent-browser) is installed into the agent's home by its publisher's own installer -- npm
# packages with `npm install -g` into NPM_CONFIG_PREFIX=~/.local -- chosen by the HARNESSES / TOOLS
# / HARNESS_SERVICES compose variables, backed up with the home, and updated without an image.
# `serve` runs this image too, with a home of its own (see lib/recipes/ctxr/recipe.toml).
#
# The image has its own version (RUNTIME_VERSION), no longer ctxr's.
#
# Build context is the REPO ROOT, so lib/ is reachable:
#   docker build -f runtime/Dockerfile .
ARG DEBIAN_IMAGE=debian:trixie-20261020-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
FROM ${DEBIAN_IMAGE}

# --- Base packages -------------------------------------------------------------------------
# tini is PID 1: it forwards signals and reaps the orphans remote sessions leave behind.
# supervisor runs the programs. python3 runs runtime-install and the platform venv; it is
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
RUN set -eux; \
    groupadd -g 10000 agent; \
    useradd -u 10000 -g 10000 -m -d /home/agent -s /bin/bash agent

# --- Node ------------------------------------------------------------------------------------
ARG NODE_VERSION=24.22.1
ARG NODE_SHA256_AMD64=6c172a9ab6718f7b801fb5a7bd486af2ee5e32758086a04b84fcce2aa77095e6
ARG NODE_SHA256_ARM64=dbabf7a1cbf947e6059ffad2c27b80041db97dea1e553b62afdee7f13fca336e
COPY lib/install-node.sh /tmp/install-node.sh
RUN /tmp/install-node.sh && rm -f /tmp/install-node.sh

# --- Contexture toolchain: gh only -----------------------------------------------------------
# The same script the Hermes image runs, told to skip ctxr: ctxr is a tool installed into the home.
ARG GH_VERSION=2.98.0
COPY lib/install-contexture-toolchain.sh /tmp/install-contexture-toolchain.sh
RUN CTXR_VERSION=none /tmp/install-contexture-toolchain.sh && rm -f /tmp/install-contexture-toolchain.sh

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
#   runtime-install          installs and updates the harnesses and tools; renders their programs
#   runtime-schedule         runs the daily update (and, in compose, the backup schedulers)
#   home-backup              the whole home to restic, through the recipes' snapshots; and restore
#   home-config-push         the home's config to a private git remote, allowlist from the recipes
#   home-migrate             turns a Hermes-image volume into a runtime home, and back
#   harness-remote           the remote-control wrapper, shared with the Hermes image
#   runtime-store-update     the store update at start, then the recipes' store-updated hooks
#   runtime-provision        workspace-init: ctxr into the home, then ctxr-provision
#   ctxr-update-store, ctxr-provision, ctxr-install-circleback-script   as in the Hermes image
# The names these replaced (harness-install, harness-schedule, harness-backup, harness-config-push,
# harness-migrate-home) stay as links, for a compose file or an operator's habit still using them.
COPY lib/runtime-install.py /usr/local/bin/runtime-install
COPY lib/recipes /usr/local/share/contexture/recipes
COPY lib/harness-remote.py /usr/local/bin/harness-remote
COPY lib/schedule.sh /usr/local/bin/runtime-schedule
COPY lib/update-store.sh /usr/local/bin/ctxr-update-store
COPY lib/provision-store.sh /usr/local/bin/ctxr-provision
COPY lib/install-circleback-script.sh /usr/local/bin/ctxr-install-circleback-script
COPY lib/home-backup.py /usr/local/bin/home-backup
COPY lib/config-push.sh /usr/local/lib/contexture/config-push.sh
COPY runtime/config-push.sh /usr/local/bin/home-config-push
COPY lib/home-migrate.py /usr/local/bin/home-migrate
COPY runtime/store-update.sh /usr/local/bin/runtime-store-update
COPY runtime/provision.sh /usr/local/bin/runtime-provision
COPY runtime/entrypoint.sh /usr/local/bin/runtime-entrypoint
COPY runtime/supervisord.conf /etc/supervisor/supervisord.conf
COPY runtime/profile.d/10-runtime-path.sh /etc/profile.d/10-runtime-path.sh
RUN set -eux; \
    rm -f /usr/local/share/contexture/recipes/README.md; \
    chmod +x /usr/local/bin/runtime-install /usr/local/bin/harness-remote /usr/local/bin/runtime-schedule \
      /usr/local/bin/ctxr-update-store /usr/local/bin/ctxr-provision /usr/local/bin/runtime-entrypoint \
      /usr/local/bin/ctxr-install-circleback-script /usr/local/bin/home-backup \
      /usr/local/lib/contexture/config-push.sh /usr/local/bin/home-config-push \
      /usr/local/bin/home-migrate /usr/local/bin/runtime-store-update /usr/local/bin/runtime-provision; \
    ln -s runtime-install /usr/local/bin/harness-install; \
    ln -s runtime-schedule /usr/local/bin/harness-schedule; \
    ln -s home-backup /usr/local/bin/harness-backup; \
    ln -s home-config-push /usr/local/bin/harness-config-push; \
    ln -s home-migrate /usr/local/bin/harness-migrate-home; \
    chmod -R a+rX /usr/local/share/contexture /etc/profile.d/10-runtime-path.sh; \
    for script in runtime-entrypoint ctxr-install-circleback-script home-config-push runtime-store-update runtime-provision; do \
      sh -n "/usr/local/bin/${script}"; \
    done; \
    sh -n /usr/local/lib/contexture/config-push.sh; \
    python3 -c 'import ast,sys; [ast.parse(open(p).read()) for p in sys.argv[1:]]' \
      /usr/local/bin/runtime-install /usr/local/bin/harness-remote /usr/local/bin/home-backup \
      /usr/local/bin/home-migrate

# PATH: the platform first, then ~/.local/bin, where every harness's installer and npm's global
# prefix put their binaries, so a harness never shadows gh or the platform python.
# NPM_CONFIG_PREFIX is what makes `npm install -g` work as the agent, and puts the package in the
# home, backed up with everything else.
ENV PATH=/opt/contexture/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/agent/.local/bin \
    NPM_CONFIG_PREFIX=/home/agent/.local \
    RUNTIME_STATUS_FILE=/home/agent/.local/state/contexture/runtime-status.json

# Every recipe parses, and the full selection -- what the shared compose file defaults to, with
# every service -- is consistent with them.
RUN HARNESSES=hermes,hermes-webui,claude,codex,agy \
    TOOLS=ctxr,cb,agent-browser \
    HARNESS_SERVICES=hermes-gateway,hermes-dashboard,hermes-webui,claude-remote,codex-remote,agy-remote,ctxr-serve \
      runtime-install check

WORKDIR /home/agent
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/runtime-entrypoint"]
