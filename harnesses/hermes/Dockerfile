# Hermes Agent image for a Contexture store.
#
# ONE image, and for the long-running case ONE container: the gateway, the dashboard and the
# WebUI are supervised together, with one-off jobs (provisioning, `ctxr serve`) running this
# same image. So there is exactly one toolchain and one set of version pins in play -- git, gh
# and ctxr are the same binaries wherever a tool call lands, because every tool call lands in
# the same place.
#
# The WebUI used to be a second image built FROM upstream's hermes-webui with the agent's
# source grafted in. That shape had no toolchain of its own, so browser chat had to be routed
# through the gateway's runs API to become useful -- and that bridge is what broke approvals.
# The gateway names its approval identity `request_id` (tools/approval.py,
# `_ApprovalEntry.__init__`) while WebUI 0.52.113 reads only `approval_id`/`id`
# (api/gateway_chat.py), so the card rendered with an empty id and every Approve click 400'd
# with "approval_id is required for gateway approvals". That is upstream
# nesquena/hermes-webui#6008, fixed by their #6446 but shipped only on the `exp-` channel;
# stable 0.52.113 (build revision c67fd2dd) still carries the old code.
#
# Folding the WebUI in here lets it run the agent IN-PROCESS -- upstream's default, and a path
# with no relay to mismatch -- while still having gh/ctxr/node on the same filesystem, which is
# upstream's own stated remedy for the gap they track as #681. The all-in-one shape is the one
# the community hermes-suite image uses; this takes that shape without taking that image, which
# pins older agent/WebUI versions and replaces s6 with supervisord (losing stage2-hook's UID
# remap and cont-init's per-profile gateway reconciliation).
#
# Build context is the REPO ROOT, not this directory, so lib/ is reachable:
#   docker build -f harnesses/hermes/Dockerfile --build-arg CTXR_VERSION=0.10.0 .
ARG HERMES_AGENT_IMAGE=nousresearch/hermes-agent:v2026.8.31

# Latest STABLE upstream WebUI release. Deliberately not :latest -- that floating tag currently
# resolves to an `exp-` prerelease build, which upstream's own docs say not to run in
# production. Only the source tree is lifted out of this image; it never becomes the base.
ARG HERMES_WEBUI_VERSION=0.52.113
FROM ghcr.io/nesquena/hermes-webui:${HERMES_WEBUI_VERSION} AS webui-src

FROM ${HERMES_AGENT_IMAGE}

# --- Runtime PATH ----------------------------------------------------------------------------
# The base image's own ENV PATH already puts /opt/hermes/bin and /opt/hermes/.venv/bin first,
# but Debian's /etc/profile unconditionally overwrites PATH for non-root users (see the comment
# in the dropped-in script for the exact mechanism and why it silently breaks every agent
# session, not just an interactive login). /etc/profile.d is empty in the base image, so this is
# a pure addition, not a race with anything already there.
COPY harnesses/hermes/profile.d/10-hermes-path.sh /etc/profile.d/10-hermes-path.sh
RUN chmod +r /etc/profile.d/10-hermes-path.sh

# --- Contexture toolchain -----------------------------------------------------------------
# gh + ctxr-cli, with their smoke tests, in one layer. Harness-agnostic by construction: this
# is the only file shared with any other harness image in this repo. See the script's header
# for why CTXR_VERSION is load-bearing and why it must equal the image tag.
ARG GH_VERSION=2.98.0
ARG CTXR_VERSION
COPY lib/install-contexture-toolchain.sh /tmp/install-contexture-toolchain.sh
RUN /tmp/install-contexture-toolchain.sh && rm -f /tmp/install-contexture-toolchain.sh

# --- Agent CLIs ----------------------------------------------------------------------------
# Other models and a browser driver, available to the agent's shell on every store running this
# image rather than only the one whose own Dockerfile installed them. A skill that reaches for
# `codex` or `claude` and does not find it cannot run at all.
ARG CODEX_VERSION=0.153.0
ARG AGENT_BROWSER_VERSION=0.26.0
ENV CLAUDE_TOOLCHAIN_HOME=/opt/toolchain
COPY lib/install-agent-clis.sh /tmp/install-agent-clis.sh
RUN TOOLCHAIN_HOME="${CLAUDE_TOOLCHAIN_HOME}" /tmp/install-agent-clis.sh \
    && rm -f /tmp/install-agent-clis.sh

# --- Hermes WebUI ---------------------------------------------------------------------------
# Source only. `/apptoo` is the pristine tree upstream's image ships (their init rsyncs it to
# /app at boot); nothing here needs that init, because this image already IS the agent -- the
# source tree, the venv and the installed hermes_agent module are all already present.
#
# Their requirements.txt is deliberately tiny -- "All heavy ML/agent deps live in the Hermes
# agent venv" -- and the agent venv already satisfies it (PyYAML, cryptography). The install is
# kept anyway so a future requirements bump fails HERE, at build time, rather than at boot.
#
# compileall is not decoration: this venv is Python 3.13 and upstream's WebUI image runs 3.12,
# so this layer is the only thing standing between a syntax-level incompatibility and a
# crash-looping container. Same-RUN smoke test, like every other install in this file.
#
# The tree stays root-owned. The WebUI writes nothing into its own source directory -- its
# mutable state goes to HERMES_WEBUI_STATE_DIR on the /opt/data volume.
COPY --from=webui-src /apptoo /opt/hermes-webui
RUN set -eux; \
    uv pip install --python /opt/hermes/.venv/bin/python \
      -r /opt/hermes-webui/requirements.txt; \
    /opt/hermes/.venv/bin/python -m compileall -q \
      /opt/hermes-webui/server.py /opt/hermes-webui/api; \
    /opt/hermes/.venv/bin/python -c "import yaml, cryptography"; \
    test -f /opt/hermes-webui/server.py

# --- WebUI as a supervised service ----------------------------------------------------------
# Modelled on the image's own `dashboard` service and wired the same way: a service dir plus a
# marker file in the `user` bundle's contents.d. s6-overlay compiles /etc/s6-overlay/s6-rc.d at
# container boot, so dropping the files in is the whole installation.
#
# Opt-in via HERMES_WEBUI_ENABLED, exactly like HERMES_DASHBOARD -- the image stays generic, so
# a one-off provisioning or `ctxr serve` container running this same image without that
# variable never starts a web server. See s6-rc.d/webui/run for the rest.
COPY harnesses/hermes/s6-rc.d/webui /etc/s6-overlay/s6-rc.d/webui
RUN set -eux; \
    chmod +x /etc/s6-overlay/s6-rc.d/webui/run /etc/s6-overlay/s6-rc.d/webui/finish; \
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/webui; \
    test -f /etc/s6-overlay/s6-rc.d/webui/type; \
    test -f /etc/s6-overlay/s6-rc.d/webui/dependencies.d/base

# --- Bundled document-skill Python deps -----------------------------------------------------
# The agent's bundled productivity skills (pdf, docx, xlsx, powerpoint) name these as
# prerequisites in their own SKILL.md, but none of them ship in the upstream agent venv. Absent
# this layer, an agent hitting any of the four falls back to a per-task venv under /tmp -- the
# venv is root-owned by design (see Write safety, below) so the agent can't repair it -- which
# is disposable, repeated on every session, and exactly what this store's own runbooks tell an
# agent not to do. Installing them here, once, in the shared venv is the durable fix.
#
# Same pattern as the WebUI install above: pinned versions, one layer, import smoke test in the
# same RUN so a broken or yanked release fails the build instead of a live session.
#
# The base image's /opt/hermes/pyproject.toml sets `exclude-newer = "14 days"` (a rolling
# supply-chain quarantine against a just-published/compromised release) and `uv` auto-discovers
# it from this layer's cwd (WORKDIR /opt/hermes, inherited from the base). Pin the latest release
# of each package that is already >14 days old as of this writing (2026-09-11) rather than
# fighting the quarantine -- an exact pin only needs to clear that floor once; it never ages
# backward. Bumping any of these to a release still inside the 14-day window will fail the build
# with "No solution found ... there is no version of X==Y" (uv's phrasing for "quarantined", not
# "does not exist" -- same trap the base file documents for its own deps).
ARG PYPDF_VERSION=6.16.2
ARG REPORTLAB_VERSION=5.0.1
ARG PDFPLUMBER_VERSION=0.11.10
ARG PYPDFIUM2_VERSION=5.13.0
ARG PYTHON_DOCX_VERSION=1.2.0
ARG OPENPYXL_VERSION=3.1.5
ARG PYTHON_PPTX_VERSION=1.0.2
ARG BEAUTIFULSOUP4_VERSION=4.15.0
RUN set -eux; \
    uv pip install --python /opt/hermes/.venv/bin/python \
      "pypdf==${PYPDF_VERSION}" \
      "reportlab==${REPORTLAB_VERSION}" \
      "pdfplumber==${PDFPLUMBER_VERSION}" \
      "pypdfium2==${PYPDFIUM2_VERSION}" \
      "python-docx==${PYTHON_DOCX_VERSION}" \
      "openpyxl==${OPENPYXL_VERSION}" \
      "python-pptx==${PYTHON_PPTX_VERSION}" \
      "beautifulsoup4==${BEAUTIFULSOUP4_VERSION}"; \
    /opt/hermes/.venv/bin/python -c \
      "import pypdf, reportlab, pdfplumber, pypdfium2, docx, openpyxl, pptx, bs4"

# --- Write safety ---------------------------------------------------------------------------
# The base image ships HERMES_WRITE_SAFE_ROOT=/opt/data, and agent/file_safety.py restricts the
# native write_file/patch tools to those prefixes -- so a Contexture store mounted at /store,
# which is the entire point of this image, is not writable by the agent's own file tools without
# being named here.
#
# get_safe_write_roots() splits this on os.pathsep (`:` here), so the value is a LIST and this is
# an append, not a replacement: /opt/data must stay on it or the agent loses file-tool writes to
# its own HERMES_HOME -- config.yaml, OAuth state, and HERMES_LAZY_INSTALL_TARGET all live there.
#
# /tmp is the third root, and it closes a trap rather than widening reach. The shell tool could
# always write /tmp; only the native write_file/patch could not. An agent that hit that refusal
# fell back to $HOME -- which for the in-process WebUI agent is /opt/data, a git repo whose
# backup cron commits and pushes. Scratch that had nowhere legal to go ended up pushed to a
# config repo, and the `auto: ignore ...` commits in that history are the whack-a-mole that
# followed. Making the two write paths agree removes the reason to reach for $HOME at all.
#
# Deliberately NOT accompanied by TMPDIR, and that omission is load-bearing.
# tools/environments/local.py::get_temp_dir() calls _prune_terminal_temp_once() ONLY on its
# HERMES_HOME/cache/terminal branch. Setting TMPDIR selects an earlier branch that returns
# without pruning, silently disabling the 72h sweep of hermes_bg_*.log and code-exec sandboxes
# in a container that runs for weeks. Leave TMPDIR unset -- do not "complete" this later.
ENV HERMES_WRITE_SAFE_ROOT=/opt/data:/store:/tmp

# Deliberately NOT set here: EXPOSE, ENTRYPOINT, CMD, HEALTHCHECK, VOLUME. Every consumer drives
# those from its own compose file, and baking them in would silently override a deployment's
# choices. Provisioning scripts are consumer policy too, and are not baked in.
