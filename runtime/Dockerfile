# contexture-runtime: the platform a Contexture store's harnesses run on, with no harness in it.
#
# See docs/design/harnesses-in-home.md. The image holds what must match across containers, needs
# root, or is run by something other than the agent: Debian, tini, supervisord, the `agent` user,
# Node, a platform python venv, ctxr, gh, the backup and skill tools, and the ctxr-*/harness-*
# scripts. Every harness -- claude, codex, agy, agent-browser, cb, and in phase 2 Hermes and its
# WebUI -- is installed at boot into the harnesses volume by harness-install, chosen by the
# HARNESSES / HARNESS_SERVICES / HARNESS_PINS compose variables, and updated without an image.
#
# PHASE 1: built and tested by CI, not published and not deployed. Stores keep running
# contexture-hermes until phase 3.
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
# harness-install and its recipes; harness-remote (the remote-control wrapper, shared with the
# Hermes image); harness-schedule (runs the daily update); ctxr-update-store (the store update at
# container start); ctxr-provision (workspace-init). Phase 2 adds the recipe-driven harness-backup
# and harness-config-push.
COPY lib/harness-install.py /usr/local/bin/harness-install
COPY lib/harnesses /usr/local/share/contexture/harnesses
COPY lib/harness-remote.py /usr/local/bin/harness-remote
COPY lib/schedule.sh /usr/local/bin/harness-schedule
COPY lib/update-store.sh /usr/local/bin/ctxr-update-store
COPY lib/provision-store.sh /usr/local/bin/ctxr-provision
COPY runtime/entrypoint.sh /usr/local/bin/runtime-entrypoint
COPY runtime/supervisord.conf /etc/supervisor/supervisord.conf
COPY runtime/profile.d/10-runtime-path.sh /etc/profile.d/10-runtime-path.sh
RUN set -eux; \
    rm -f /usr/local/share/contexture/harnesses/README.md; \
    chmod +x /usr/local/bin/harness-install /usr/local/bin/harness-remote /usr/local/bin/harness-schedule \
      /usr/local/bin/ctxr-update-store /usr/local/bin/ctxr-provision /usr/local/bin/runtime-entrypoint; \
    chmod -R a+rX /usr/local/share/contexture /etc/profile.d/10-runtime-path.sh; \
    sh -n /usr/local/bin/runtime-entrypoint; \
    python3 -c 'import ast,sys; [ast.parse(open(p).read()) for p in sys.argv[1:]]' \
      /usr/local/bin/harness-install /usr/local/bin/harness-remote

# Platform first, the agent-writable /opt/harnesses/bin last: a harness never shadows ctxr, gh or
# the platform python. DISABLE_AUTOUPDATER keeps claude from rewriting itself; harness-install is
# the one writer of /opt/harnesses.
ENV PATH=/opt/contexture/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/harnesses/bin \
    DISABLE_AUTOUPDATER=1

# Every recipe parses, and the phase-1 selection is consistent with them.
RUN HARNESSES=claude,codex,agy,agent-browser,cb HARNESS_SERVICES=claude-remote,codex-remote,agy-remote \
      harness-install check

WORKDIR /home/agent
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/runtime-entrypoint"]
