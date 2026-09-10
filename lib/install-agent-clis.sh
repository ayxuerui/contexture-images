#!/bin/sh
# Agent CLIs a harness image makes available to the agent's shell.
#
# Separate from install-contexture-toolchain.sh on purpose. That script installs what
# CONTEXTURE needs (`gh`, because the forge adapter shells out to it; `ctxr` itself). This one
# installs what an AGENT needs -- other models and a browser driver it can call as tools. The
# two answer to different owners and change for different reasons, so they are not one file.
#
# Universal rather than per-store: a skill that reaches for `codex` or `claude` should find it
# on any store running this image, not only the one whose Dockerfile happened to install it.
# Upstream hermes issue #681 calls the equivalent gap in their WebUI container "architectural,
# not a bug" -- an agent whose shell lacks the tool cannot run the skill at all.
#
# Inputs, all required, fed from Dockerfile ARGs:
#   CODEX_VERSION          @openai/codex
#   AGENT_BROWSER_VERSION  agent-browser
#   TOOLCHAIN_HOME         throwaway HOME for the curl|bash installers (see below)
set -eu

fail() { echo "install-agent-clis: $*" >&2; exit 1; }

: "${CODEX_VERSION:?CODEX_VERSION is required}"
: "${AGENT_BROWSER_VERSION:?AGENT_BROWSER_VERSION is required}"
: "${TOOLCHAIN_HOME:?TOOLCHAIN_HOME is required}"

command -v npm >/dev/null 2>&1 || fail "needs Node/npm on the base image"

# --- npm-distributed --------------------------------------------------------------------
# Pinned, and smoke-tested in the same layer, so a moved or broken package fails the BUILD
# rather than a cron job at 03:00.
echo "install-agent-clis: installing codex ${CODEX_VERSION}, agent-browser ${AGENT_BROWSER_VERSION}"
npm install -g \
  "@openai/codex@${CODEX_VERSION}" \
  "agent-browser@${AGENT_BROWSER_VERSION}"
npm cache clean --force
codex --version
command -v agent-browser >/dev/null 2>&1 || fail "agent-browser did not land on PATH"

# --- curl|bash installers ---------------------------------------------------------------
# Neither claude nor agy ships on npm, and neither installer takes a version flag -- so these
# two are the only unpinned components here, re-pinned implicitly by the image tag once built.
#
# Installed against a throwaway HOME rather than the real one. At runtime HOME is a VOLUME
# (/opt/data on the Hermes base), which would put these binaries in mutable state instead of
# in the image; they would then survive a rebuild and drift invisibly. Symlinked into
# /usr/local/bin, which is already on PATH and root-owned -- the agent runs unprivileged and
# so cannot rewrite its own toolchain.
echo "install-agent-clis: installing claude and agy into ${TOOLCHAIN_HOME}"
mkdir -p "${TOOLCHAIN_HOME}"
HOME="${TOOLCHAIN_HOME}" sh -c 'curl -fsSL https://claude.ai/install.sh | bash'
HOME="${TOOLCHAIN_HOME}" sh -c 'curl -fsSL https://antigravity.google/cli/install.sh | bash'
ln -sf "${TOOLCHAIN_HOME}/.local/bin/claude" /usr/local/bin/claude
ln -sf "${TOOLCHAIN_HOME}/.local/bin/agy" /usr/local/bin/agy
claude --version
agy --version

echo "install-agent-clis: ok"
